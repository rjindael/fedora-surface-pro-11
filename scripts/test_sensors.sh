#!/bin/bash
# test_sensors.sh — Test all Surface Pro 11 sensors via Qualcomm Sensor Core (SSC)
#
# Prerequisites:
#   - hexagonrpcd running with -s (sensorspd) and sensor config deployed
#   - libssc installed (ssccli)
#   - QRTR kernel module loaded
#
# Usage: ./test_sensors.sh
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SSCCLI="$(command -v ssccli 2>/dev/null || echo /usr/local/bin/ssccli)"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/lib/aarch64-linux-gnu"

# Colours
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'

echo "${B}═══ Surface Pro 11 Sensor Test ═══${N}"
echo ""

# ── 1. Infrastructure ──────────────────────────────────────────────────
echo "${B}── Infrastructure ──${N}"

# hexagonrpcd may have crashed after initialising sensors — that's OK
if pgrep -f 'hexagonrpc/hexagonrpcd' >/dev/null 2>&1; then
    echo "  ${G}✓${N} hexagonrpcd running"
else
    echo "  ${Y}⚠${N} hexagonrpcd not running (sensors may still work if ADSP initialised)"
fi

if [ -c /dev/fastrpc-adsp ]; then
    echo "  ${G}✓${N} /dev/fastrpc-adsp present"
else
    echo "  ${R}✗${N} /dev/fastrpc-adsp missing"
fi

if ! command -v "$SSCCLI" >/dev/null 2>&1; then
    echo "  ${R}✗${N} ssccli not found — install libssc"
    exit 1
fi
echo "  ${G}✓${N} ssccli available"

SNS_ROOT="/usr/share/qcom/x1e80100/Microsoft/Surface-Pro-11"
REG_COUNT=$(ls "$SNS_ROOT/sensors/registry/" 2>/dev/null | wc -l)
if [ "$REG_COUNT" -gt 100 ]; then
    echo "  ${G}✓${N} Sensor registry ($REG_COUNT files)"
else
    echo "  ${R}✗${N} Sensor registry missing ($REG_COUNT files — need Windows registry copy)"
fi
echo ""

# Check uptime — motion sensors need ~60s to init on ADSP
UPTIME_SEC=$(cut -d. -f1 /proc/uptime)
if [ "$UPTIME_SEC" -lt 60 ]; then
    echo "  ${Y}⚠${N} System uptime ${UPTIME_SEC}s — motion sensors need ~60s to init"
    echo "  ${D}  Waiting for ADSP sensor initialization...${N}"
    sleep $((60 - UPTIME_SEC))
    echo "  ${G}✓${N} Wait complete"
fi

# ── 2. Sensor inventory ─────────────────────────────────────────────────
echo "${B}── Configured Sensors ──${N}"
echo "  ${D}Sensor configs in $SNS_ROOT/sensors/config/:${N}"
ls "$SNS_ROOT/sensors/config/"*.json 2>/dev/null | while read -r f; do basename "$f"; done | head -10 | sed 's/^/    /'
echo ""

# ── 3. Sensor readings ──────────────────────────────────────────────────
echo "${B}── Sensor Readings ──${N}"

# Use fast C tool if available (1s), fall back to ssccli (20s)
FAST_READ="$SCRIPT_DIR/sensors/sp11-sensor-read"
if [ ! -x "$FAST_READ" ]; then
    FAST_READ="$(dirname "$SCRIPT_DIR")/sensors/sp11-sensor-read"
fi

if [ -x "$FAST_READ" ]; then
    # Fast path: all sensors in parallel, exits after first reading each
    output=$(LD_LIBRARY_PATH="${LD_LIBRARY_PATH}" timeout 12 "$FAST_READ" 10 2>/dev/null) || true
    if [ -n "$output" ]; then
        while IFS= read -r line; do
            echo "  ${G}✓${N} $line"
        done <<< "$output"
    else
        echo "  ${R}✗${N} No sensor data (reboot may be needed for ADSP init)"
    fi
else
    # Fallback: sequential ssccli (slower)
    test_sensor() {
        local label="$1" sensor="$2" timeout="${3:-5}"
        printf "  %-20s " "$label"
        local output
        output=$(timeout "$((timeout + 3))" "$SSCCLI" --sensor "$sensor" --timeout "$timeout" 2>&1) || true
        if grep -q 'measurement' <<< "$output"; then
            echo "${G}DATA${N}"
        elif grep -q 'unavailable' <<< "$output"; then
            echo "${Y}registry empty${N}"
        else
            echo "${R}unreachable${N}"
        fi
    }
    test_sensor "Accelerometer" "accelerometer" 5
    test_sensor "Gyroscope" "gyroscope" 5
    test_sensor "Magnetometer" "magnetometer" 5
    test_sensor "Light (ALS)" "light" 5
fi

# ── 4. Direct-access sensors ────────────────────────────────────────────
echo "${B}── Direct Access Sensors ──${N}"

TABLET_PATH="/sys/devices/platform/surface_aggregator_platform_hub.0/01:0e:01:00:01/state"
if [ -f "$TABLET_PATH" ]; then
    echo "  ${G}✓${N} Tablet mode switch: $(cat "$TABLET_PATH" 2>/dev/null)"
else
    echo "  ${Y}⚠${N} Tablet mode switch not found"
fi

IIO_COUNT=$(ls /sys/bus/iio/devices/ 2>/dev/null | wc -l)
if [ "$IIO_COUNT" -gt 0 ]; then
    echo "  ${G}✓${N} IIO devices ($IIO_COUNT)"
    for dev in /sys/bus/iio/devices/iio:device*; do
        echo "    $(cat "$dev/name" 2>/dev/null)"
    done
else
    echo "  ${D}No IIO devices (install libssc for IIO bridge)${N}"
fi

echo ""

# ── 5. Debug hints ──────────────────────────────────────────────────────
echo "${B}── Troubleshooting ──${N}"
echo "  ${D}Registry empty:${N} reboot to reload (ADSP reset crashes this SoC)"
echo "  ${D}SSC unreachable:${N} check hexagonrpcd, QRTR, sensor config"
echo "  ${D}FastRPC debug:${N}  sudo dmesg | grep 'client_id=1.*pd=2'"
echo "  ${D}Full details:${N}    SENSORS.md"
