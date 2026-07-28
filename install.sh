#!/bin/bash
#
# install.sh — One-shot installer for all Surface Pro 11 (Snapdragon X Elite)
# components described in README.md.
#
# Usage:
#   sudo ./install.sh                 # install everything (default: --all)
#   sudo ./install.sh --suspend       # install just suspend/resume
#   sudo ./install.sh --wifi --audio  # pick specific phases
#   sudo ./install.sh --kernel        # build & install the patched kernel
#   sudo ./install.sh --list          # list available phases
#   sudo ./install.sh --uninstall     # remove everything this script installed
#
# Run from the repo root.  Most phases need root; the script will re-exec
# itself under sudo if not already root.
#
set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_DIM=''; C_RST=''
fi

# ── paths ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# The real (non-root) user, for per-user config (PipeWire etc.)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# ── helpers ───────────────────────────────────────────────────────────────
log()  { echo "${C_BLUE}▶${C_RST} $*"; }
ok()   { echo "${C_GREEN}✓${C_RST} $*"; }
warn() { echo "${C_YELLOW}⚠${C_RST} $*" >&2; }
err()  { echo "${C_RED}✗${C_RST} $*" >&2; }
die()  { err "$*"; exit 1; }

phase() { echo; echo "${C_BOLD}${C_BLUE}═══ $* ═══${C_RST}"; }

# Copy a file, creating the destination dir first.
install_file() {
    local src="$1" dst="$2"
    local dstdir
    dstdir="$(dirname "$dst")"
    mkdir -p "$dstdir"
    cp -f "$src" "$dst"
}

# Run a command as the real user (for per-user systemd / config).
as_user() { sudo -u "$REAL_USER" "$@"; }

# Run systemctl --user for the real user (works even under sudo via machine mode).
user_systemctl() { systemctl --user -M "${REAL_USER}@.host" "$@"; }

# ── phase flags ───────────────────────────────────────────────────────────
DO_GRUB=false; DO_WIFI=false; DO_AUDIO=false; DO_PEN=false
DO_SUSPEND=false; DO_NPU=false; DO_KERNEL=false
DO_UNINSTALL=false
EXPLICIT=false

USAGE="Usage: sudo ./install.sh [PHASE...] [--kernel]
Phases: --all --grub --wifi --audio --pen --suspend --npu --kernel
        --uninstall --list  (default: --all)"

while [ $# -gt 0 ]; do
    case "$1" in
        --all)      DO_GRUB=true; DO_WIFI=true; DO_AUDIO=true; DO_PEN=true
                    DO_SUSPEND=true; DO_NPU=true ;;
        --grub)     DO_GRUB=true;    EXPLICIT=true ;;
        --wifi)     DO_WIFI=true;    EXPLICIT=true ;;
        --audio)    DO_AUDIO=true;   EXPLICIT=true ;;
        --pen)      DO_PEN=true;     EXPLICIT=true ;;
        --suspend)  DO_SUSPEND=true; EXPLICIT=true ;;
        --npu)      DO_NPU=true;     EXPLICIT=true ;;
        --kernel)   DO_KERNEL=true;  EXPLICIT=true ;;
        --uninstall) DO_UNINSTALL=true ;;
        --list)     echo "$USAGE"; echo; echo "Available phases:"; \
                    echo "  grub      GRUB drop-in configs + update-grub"; \
                    echo "  wifi      WCN7850 board data + apt hook"; \
                    echo "  audio     DSP firmware + topology + UCM2 + boot-race fix + PipeWire sink"; \
                    echo "  pen       Stylus daemon (udev + build + service)"; \
                    echo "  suspend   cpu-sleep-0 fix + hexagonrpcd hooks + lid daemon"; \
                    echo "  npu       FastRPC udev + hexagonrpcd (SDK/build see NPU.md)"; \
                    echo "  kernel    Build & install patched kernel (long; needs ~20 GB)"; \
                    exit 0 ;;
        -h|--help)  echo "$USAGE"; exit 0 ;;
        *)          die "Unknown option: $1\n\n$USAGE" ;;
    esac
    shift
done

# Default: --all (but not --kernel)
if ! $EXPLICIT && ! $DO_UNINSTALL; then
    DO_GRUB=true; DO_WIFI=true; DO_AUDIO=true; DO_PEN=true
    DO_SUSPEND=true; DO_NPU=true
fi

# ── privilege check ───────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    log "Re-executing under sudo…"
    exec sudo -E bash "$0" "$@"
fi

echo "${C_BOLD}Surface Pro 11 installer${C_RST}"
echo "  user : $REAL_USER ($REAL_HOME)"
echo "  repo : $SCRIPT_DIR"
$DO_KERNEL && echo "  kernel: ${C_YELLOW}will build from source (~30 min)${C_RST}"

# ══════════════════════════════════════════════════════════════════════════
# UNINSTALL
# ══════════════════════════════════════════════════════════════════════════
if $DO_UNINSTALL; then
    phase "Uninstall"
    systemctl disable --now \
        sp11-lid-backlight.service sp11-pen-daemon.service \
        sp11-suspend-debug.service sp11-wsa-routing.service 2>/dev/null || true
    user_systemctl disable --now sp11-pipewire-restart.service 2>/dev/null || true
    rm -f /etc/systemd/system/sp11-{lid-backlight,pen-daemon,suspend-debug,wsa-routing}.service
    rm -f /usr/local/sbin/sp11-{lid-backlight,pen-daemon,enable-suspend-debug,enable-wsa-routing,wifi-board-fixup,grab-fw,fix-cpuidle-s2idle}
    rm -f /usr/lib/systemd/system-sleep/sp11-cpuidle-s2idle
    rm -rf /etc/systemd/system/hexagonrpcd-{suspend,resume}.service.d
    rm -f /etc/udev/rules.d/99-{sp11-pen,fastrpc}.rules
    rm -f /etc/apt/apt.conf.d/99surface-pro-11-wifi-fixup
    rm -f /etc/default/grub.d/{99-surface-pro-11,98-sp11-timeout,ubuntu-x1e-settings}.cfg
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    ok "Removed all installed files and services."
    warn "Kernel, firmware, topology, UCM2 configs, and PipeWire sink config left in place."
    warn "Run: sudo update-grub   to revert GRUB args."
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════
# STEP 1 — KERNEL (optional, --kernel)
# ══════════════════════════════════════════════════════════════════════════
install_kernel() {
    phase "Kernel — build & install patched kernel"
    local KSRC="${KERNEL_SRC:-$HOME/linux-sp11}"
    log "Cloning Jens Glathe's qcom-x1e tree to $KSRC …"
    if [ ! -d "$KSRC/.git" ]; then
        git clone --depth 1 --branch jg/ubuntu-qcom-x1e-7.1.3-jg-1 \
            https://github.com/jglathe/linux_ms_dev_kit.git "$KSRC"
    else
        ok "Kernel source already present at $KSRC"
    fi
    cd "$KSRC"
    log "Applying Surface Pro 11 patches…"
    git am --abort 2>/dev/null || true
    for patchset in sp11-touchscreen rfkill-wifi-mac dmic-clock; do
        local dir="$SCRIPT_DIR/kernel-patches/$patchset"
        if ls "$dir"/*.patch >/dev/null 2>&1; then
            git am "$dir"/*.patch || die "Failed to apply $patchset patches"
            ok "Applied $patchset patches"
        fi
    done
    log "Configuring…"
    cp /boot/config-"$(uname -r)" .config
    make olddefconfig
    log "Building deb packages (this takes a while)…"
    make -j"$(nproc)" bindeb-pkg
    log "Installing kernel packages…"
    local parent; parent="$(dirname "$KSRC")"
    dpkg -i "$parent"/linux-image-*.deb "$parent"/linux-headers-*.deb
    ok "Kernel installed. Reboot to use it: ${C_BOLD}sudo reboot${C_RST}"
    cd "$SCRIPT_DIR"
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 2 — GRUB
# ══════════════════════════════════════════════════════════════════════════
install_grub() {
    phase "GRUB configuration"
    for cfg in 99-surface-pro-11 98-sp11-timeout ubuntu-x1e-settings; do
        install_file "grub/${cfg}.cfg" "/etc/default/grub.d/${cfg}.cfg"
    done
    update-grub
    ok "GRUB drop-ins installed and grub updated"
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 3 — WI-FI
# ══════════════════════════════════════════════════════════════════════════
install_wifi() {
    phase "Wi-Fi (WCN7850 / ath12k)"
    install_file scripts/sp11-wifi-board-fixup.sh /usr/local/sbin/sp11-wifi-board-fixup
    chmod +x /usr/local/sbin/sp11-wifi-board-fixup
    log "Extracting board data file…"
    /usr/local/sbin/sp11-wifi-board-fixup || warn "Board fixup failed (may need firmware package first)"
    install_file apt/99surface-pro-11-wifi-fixup /etc/apt/apt.conf.d/99surface-pro-11-wifi-fixup
    ok "Wi-Fi board data + apt hook installed"
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 4 — AUDIO
# ══════════════════════════════════════════════════════════════════════════
install_audio() {
    phase "Audio (speakers + microphone)"

    # 4a — DSP firmware
    install_file scripts/sp11-grab-fw.sh /usr/local/sbin/sp11-grab-fw
    chmod +x /usr/local/sbin/sp11-grab-fw
    log "Downloading DSP firmware…"
    /usr/local/sbin/sp11-grab-fw --download || warn "Firmware download failed (check internet)"

    # 4b — topology
    install_file audio/firmware/X1E80100-Microsoft-Surface-Pro-11-tplg.bin \
        /lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin

    # 4c — UCM2
    mkdir -p /usr/share/alsa/ucm2/Qualcomm/x1e80100
    cp -f audio/ucm/MICROSOFT-Surface-Pro-11.conf /usr/share/alsa/ucm2/Qualcomm/x1e80100/
    cp -f audio/ucm/Surface11-HiFi.conf           /usr/share/alsa/ucm2/Qualcomm/x1e80100/
    mkdir -p /usr/share/alsa/ucm2/conf.d/x1e80100
    cp -f audio/ucm/x1e80100.conf                 /usr/share/alsa/ucm2/conf.d/x1e80100/
    ok "Topology + UCM2 installed"

    # 4d — boot-race fix
    install_file scripts/sp11-enable-wsa-routing.sh /usr/local/sbin/sp11-enable-wsa-routing.sh
    install_file systemd/sp11-wsa-routing.service   /etc/systemd/system/sp11-wsa-routing.service
    systemctl mask alsa-restore.service alsa-state.service 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable sp11-wsa-routing.service
    ok "WSA routing service enabled (alsactl masked)"

    # 4e — PipeWire speaker sink (per-user)
    log "Installing PipeWire speaker sink for user $REAL_USER…"
    as_user bash "$SCRIPT_DIR/scripts/sp11-pipewire-speaker-sink.sh" --install --enable-route || \
        warn "PipeWire sink install failed"
    mkdir -p "$REAL_HOME/.config/systemd/user"
    install_file systemd/sp11-pipewire-restart.service \
        "$REAL_HOME/.config/systemd/user/sp11-pipewire-restart.service"
    user_systemctl daemon-reload
    user_systemctl enable sp11-pipewire-restart.service || warn "Could not enable pipewire-restart (may need: systemctl --user enable sp11-pipewire-restart.service after login)"
    ok "PipeWire sink + restart service installed for $REAL_USER"
    warn "Audio requires a reboot to take effect."
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 5 — TOUCHSCREEN (automatic with kernel; nothing to install)
# ══════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════
# STEP 6 — PEN
# ══════════════════════════════════════════════════════════════════════════
install_pen() {
    phase "Stylus (Surface Slim Pen 2)"

    # 6a — udev rule
    install_file udev/99-sp11-pen.rules /etc/udev/rules.d/99-sp11-pen.rules
    udevadm control --reload-rules
    udevadm trigger

    # 6b — build daemon
    log "Building pen daemon…"
    ( cd pen-daemon && gcc -O2 -Wall -o sp11-pen-daemon sp11-pen-daemon.c -lm )
    install_file pen-daemon/sp11-pen-daemon /usr/local/sbin/sp11-pen-daemon

    # 6c — service
    install_file systemd/sp11-pen-daemon.service /etc/systemd/system/sp11-pen-daemon.service
    systemctl daemon-reload
    systemctl enable --now sp11-pen-daemon.service
    ok "Pen daemon installed and started"
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 7 — SUSPEND / RESUME
# ══════════════════════════════════════════════════════════════════════════
install_suspend() {
    phase "Suspend / resume (s2idle)"

    # 7a — HandleLidSwitch=ignore
    local logind=/etc/systemd/logind.conf
    if grep -q '^HandleLidSwitch=' "$logind"; then
        sed -i 's/^HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$logind"
    else
        sed -i 's/^#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' "$logind"
    fi
    # NOTE: do NOT restart systemd-logind — that kills all login sessions.
    # The setting takes effect on next boot (or next logind start).
    ok "HandleLidSwitch=ignore (takes effect on next boot; daemon owns suspend)"

    # 7b — cpuidle s2idle fix
    install_file scripts/sp11-fix-cpuidle-s2idle /usr/local/sbin/sp11-fix-cpuidle-s2idle
    install_file system-sleep/sp11-cpuidle-s2idle /usr/lib/systemd/system-sleep/sp11-cpuidle-s2idle
    chmod +x /usr/local/sbin/sp11-fix-cpuidle-s2idle \
             /usr/lib/systemd/system-sleep/sp11-cpuidle-s2idle
    ok "cpu-sleep-0 cpuidle fix installed (system-sleep hook)"

    # 7c — hexagonrpcd condition fix (if hexagonrpcd is installed)
    if systemctl list-unit-files --no-pager 2>/dev/null | grep -q hexagonrpcd-suspend; then
        mkdir -p /etc/systemd/system/hexagonrpcd-suspend.service.d
        mkdir -p /etc/systemd/system/hexagonrpcd-resume.service.d
        cp -f systemd/hexagonrpcd-condition-override.conf \
            /etc/systemd/system/hexagonrpcd-suspend.service.d/override.conf
        cp -f systemd/hexagonrpcd-condition-override.conf \
            /etc/systemd/system/hexagonrpcd-resume.service.d/override.conf
        ok "hexagonrpcd suspend-hook condition fixed"
    else
        warn "hexagonrpcd not installed — skipping its hook fix (install with --npu)"
    fi
    systemctl daemon-reload

    # 7d — lid-switch backlight/suspend daemon
    install_file scripts/sp11-lid-backlight /usr/local/sbin/sp11-lid-backlight
    install_file systemd/sp11-lid-backlight.service /etc/systemd/system/sp11-lid-backlight.service
    systemctl daemon-reload
    systemctl enable --now sp11-lid-backlight.service
    ok "Lid-switch backlight/suspend daemon enabled"

    # 7e — debug logging
    install_file scripts/sp11-enable-suspend-debug /usr/local/sbin/sp11-enable-suspend-debug
    install_file systemd/sp11-suspend-debug.service /etc/systemd/system/sp11-suspend-debug.service
    systemctl daemon-reload
    systemctl enable sp11-suspend-debug.service
    ok "Suspend debug logging enabled"
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 8 — NPU
# ══════════════════════════════════════════════════════════════════════════
install_npu() {
    phase "NPU (FastRPC + hexagonrpcd)"

    # 8a — FastRPC udev rule
    install_file udev/99-fastrpc.rules /etc/udev/rules.d/99-fastrpc.rules
    udevadm control --reload-rules
    udevadm trigger

    # 8b — hexagonrpcd
    if ! dpkg -l hexagonrpcd >/dev/null 2>&1; then
        log "Installing hexagonrpcd packages…"
        apt update
        apt install -y hexagonrpcd hexagon-dsp-binaries-qualcomm-hamoa-iot-evk \
                       libhexagonrpc-dev
    else
        ok "hexagonrpcd already installed"
    fi
    systemctl enable hexagonrpcd.service

    # If suspend was also requested (or already done), apply the condition fix now
    if systemctl list-unit-files --no-pager 2>/dev/null | grep -q hexagonrpcd-suspend; then
        mkdir -p /etc/systemd/system/hexagonrpcd-suspend.service.d
        mkdir -p /etc/systemd/system/hexagonrpcd-resume.service.d
        cp -f systemd/hexagonrpcd-condition-override.conf \
            /etc/systemd/system/hexagonrpcd-suspend.service.d/override.conf
        cp -f systemd/hexagonrpcd-condition-override.conf \
            /etc/systemd/system/hexagonrpcd-resume.service.d/override.conf
        systemctl daemon-reload
        ok "hexagonrpcd suspend-hook condition fixed"
    fi

    ok "NPU prerequisites installed"
    echo
    echo "${C_DIM}  QNN SDK download + llama.cpp build are not automated."
    echo "  See NPU.md for the full build/run instructions.${C_RST}"
}

# ══════════════════════════════════════════════════════════════════════════
# RUN
# ══════════════════════════════════════════════════════════════════════════
$DO_KERNEL  && install_kernel
$DO_GRUB    && install_grub
$DO_WIFI    && install_wifi
$DO_AUDIO   && install_audio
$DO_PEN     && install_pen
$DO_SUSPEND && install_suspend
$DO_NPU     && install_npu

# ── summary ───────────────────────────────────────────────────────────────
echo
echo "${C_BOLD}${C_GREEN}═══ Done ═══${C_RST}"
$DO_AUDIO  && echo "  ${C_YELLOW}→ Reboot for audio to take effect${C_RST}"
$DO_KERNEL && echo "  ${C_YELLOW}→ Reboot to use the new kernel${C_RST}"
$DO_GRUB   && echo "  ${C_YELLOW}→ Reboot for new kernel arguments${C_RST}"
echo
echo "Verify with:  ${C_BOLD}sudo ./install.sh --list${C_RST}  (phase list)"
echo "Full checklist: see README.md → Verification checklist"
