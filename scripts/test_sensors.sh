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

# ── 2. Sensor inventory ─────────────────────────────────────────────────
echo "${B}── Configured Sensors ──${N}"
echo "  ${D}Sensor configs in $SNS_ROOT/sensors/config/:${N}"
ls "$SNS_ROOT/sensors/config/"*.json 2>/dev/null | while read -r f; do basename "$f"; done | head -10 | sed 's/^/    /'
echo ""

# ── 3. Test each sensor ─────────────────────────────────────────────────
echo "${B}── Sensor Readings ──${N}"

test_sensor() {
    local label="$1"
    local sensor="$2"
    local timeout="${3:-10}"

    printf "  %-20s " "$label"

    local output
    output=$(timeout "$((timeout + 5))" "$SSCCLI" -v --sensor "$sensor" --timeout "$timeout" 2>&1) || true

    local has_data reg_empty ssc_ok
    echo "$output" | grep -q 'measurement' && has_data=1 || has_data=0
    echo "$output" | grep -q 'registry.*unavailable' && reg_empty=1 || reg_empty=0
    echo "$output" | grep -q 'QRTR node discovered' && ssc_ok=1 || ssc_ok=0

    if [ "$has_data" = "1" ]; then
        echo "${G}DATA${N}"
        echo "$output" | grep -iE 'measurement' | tail -3 | sed 's/^/                      /'
    elif [ "$ssc_ok" = "1" ] && [ "$reg_empty" = "1" ]; then
        echo "${Y}registry empty (reboot to reload)${N}"
    elif [ "$ssc_ok" = "1" ]; then
        echo "${Y}connected but no data${N}"
    else
        echo "${R}SSC unreachable${N}"
    fi
}

test_sensor "Accelerometer" "accelerometer" 15
test_sensor "Gyroscope" "gyroscope" 15
test_sensor "Magnetometer" "magnetometer" 15
test_sensor "Light (ALS)" "light" 15
test_sensor "Proximity" "proximity" 15

echo ""

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
