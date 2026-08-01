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
DO_SUSPEND=false; DO_NPU=false; DO_SENSORS=false; DO_KERNEL=false
DO_UNINSTALL=false
EXPLICIT=false

USAGE="Usage: sudo ./install.sh [PHASE...] [--kernel]
Phases: --all --grub --wifi --audio --pen --suspend --sensors --npu --kernel
        --uninstall --list  (default: --all)"

while [ $# -gt 0 ]; do
    case "$1" in
        --all)      DO_GRUB=true; DO_WIFI=true; DO_AUDIO=true; DO_PEN=true
                    DO_SUSPEND=true; DO_SENSORS=true; DO_NPU=true ;;
        --grub)     DO_GRUB=true;    EXPLICIT=true ;;
        --wifi)     DO_WIFI=true;    EXPLICIT=true ;;
        --audio)    DO_AUDIO=true;   EXPLICIT=true ;;
        --pen)      DO_PEN=true;     EXPLICIT=true ;;
        --suspend)  DO_SUSPEND=true; EXPLICIT=true ;;
        --npu)      DO_NPU=true;     EXPLICIT=true ;;
        --sensors) DO_SENSORS=true; EXPLICIT=true ;;
        --kernel)   DO_KERNEL=true;  EXPLICIT=true ;;
        --uninstall) DO_UNINSTALL=true ;;
        --list)     echo "$USAGE"; echo; echo "Available phases:"; \
                    echo "  grub      Kernel cmdline args (grubby) + GRUB timeout config"; \
                    echo "  wifi      WCN7850 board data + path-unit auto re-fixup"; \
                    echo "  audio     DSP firmware + topology + UCM2 + boot-race fix + PipeWire sink"; \
                    echo "  pen       Stylus daemon (udev + build + service)"; \
                    echo "  suspend   cpu-sleep-0 fix + hexagonrpcd hooks + lid daemon"; \
                    echo "  sensors   hexagonrpcd + sensor config/registry from Windows + libssc"; \
                    echo "  npu       FastRPC + QNN SDK + DSP runtime + llama.cpp build + model download"
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
    DO_SUSPEND=true; DO_SENSORS=true; DO_NPU=true
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
        sp11-suspend-debug.service sp11-wsa-routing.service \
        sp11-wifi-board-fixup.path 2>/dev/null || true
    user_systemctl disable --now sp11-pipewire-restart.service 2>/dev/null || true
    rm -f /etc/systemd/system/sp11-{lid-backlight,pen-daemon,suspend-debug,wsa-routing,wifi-board-fixup}.service
    rm -f /etc/systemd/system/sp11-wifi-board-fixup.path
    rm -f /usr/local/sbin/sp11-{lid-backlight,pen-daemon,enable-suspend-debug,enable-wsa-routing,wifi-board-fixup,grab-fw,fix-cpuidle-s2idle}
    rm -f /usr/lib/systemd/system-sleep/sp11-cpuidle-s2idle
    rm -rf /etc/systemd/system/hexagonrpcd-{suspend,resume}.service.d
    systemctl disable --now sensors-platform-info.service 2>/dev/null || true
    rm -f /etc/systemd/system/sensors-platform-info.service
    rm -f /etc/systemd/system/hexagonrpcd.service
    rm -rf /etc/systemd/system/hexagonrpcd.service.d
    rm -rf /usr/share/qcom/x1e80100/Microsoft/Surface-Pro-11/sensors
    rm -f /etc/udev/rules.d/99-{sp11-pen,fastrpc}.rules
    if command -v grubby >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/grub/sp11-x1e-cmdline.args" ]; then
        sp11_args="$(grep -v '^\s*#' "$SCRIPT_DIR/grub/sp11-x1e-cmdline.args" | grep -v '^\s*$' | tr '\n' ' ')"
        grubby --update-kernel=ALL --remove-args="$sp11_args" 2>/dev/null || true
    fi
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    ok "Removed all installed files and services; SP11 kernel arguments removed via grubby."
    warn "Kernel, firmware, topology, UCM2 configs, and PipeWire sink config left in place."
    warn "GRUB_TIMEOUT/GRUB_DISABLE_OS_PROBER lines added to /etc/default/grub were left in place (edit manually + grub2-mkconfig if you want them gone too)."
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════
# STEP 1 — KERNEL (optional, --kernel)
# ══════════════════════════════════════════════════════════════════════════
install_kernel() {
    phase "Kernel — build & install patched kernel"
    local KSRC="${KERNEL_SRC:-$HOME/linux-sp11}"
    # This is Jens Glathe's generic X1E80100 bring-up tree — the "ubuntu" in
    # the branch name is just upstream's naming (he tests against Ubuntu's
    # concept builds); the tree and patches themselves are distro-agnostic.
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
    for patchset in sp11-touchscreen rfkill-wifi-mac dmic-clock camera; do
        local dir="$SCRIPT_DIR/kernel-patches/$patchset"
        if ls "$dir"/*.patch >/dev/null 2>&1; then
            git am "$dir"/*.patch || die "Failed to apply $patchset patches"
            ok "Applied $patchset patches"
        fi
    done
    log "Configuring…"
    cp /boot/config-"$(uname -r)" .config
    make olddefconfig
    log "Building RPM packages (this takes a while)…"
    make -j"$(nproc)" binrpm-pkg
    log "Installing kernel packages…"
    local rpmdir rpm_files
    rpmdir="$(rpm --eval '%{_rpmdir}' 2>/dev/null)"
    [ -n "$rpmdir" ] && [ -d "$rpmdir" ] || rpmdir="$HOME/rpmbuild/RPMS"
    rpm_files="$(find "$rpmdir" -name '*.rpm' -newer .config 2>/dev/null)"
    [ -n "$rpm_files" ] || die "No kernel RPMs found under $rpmdir after build"
    # shellcheck disable=SC2086
    dnf install -y $rpm_files
    ok "Kernel installed. Reboot to use it: ${C_BOLD}sudo reboot${C_RST}"
    cd "$SCRIPT_DIR"
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 2 — GRUB
# ══════════════════════════════════════════════════════════════════════════
install_grub() {
    phase "GRUB configuration"

    # Fedora's Boot Loader Spec (BLS) setup keeps per-kernel cmdline args in
    # /boot/loader/entries/*.conf, managed via grubby — there's no sourced
    # /etc/default/grub.d/ the way Ubuntu's update-grub provides.
    local sp11_args
    sp11_args="$(grep -v '^\s*#' grub/sp11-x1e-cmdline.args | grep -v '^\s*$' | tr '\n' ' ')"
    grubby --update-kernel=ALL --remove-args="$sp11_args" >/dev/null 2>&1 || true
    grubby --update-kernel=ALL --args="$sp11_args"
    ok "Kernel arguments applied to all installed kernels"

    # GRUB_TIMEOUT / GRUB_DISABLE_OS_PROBER still go through the normal
    # /etc/default/grub + grub2-mkconfig path; merge our lines in idempotently.
    local defgrub=/etc/default/grub
    touch "$defgrub"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        local key="${line%%=*}"
        if grep -q "^${key}=" "$defgrub"; then
            sed -i "s|^${key}=.*|${line}|" "$defgrub"
        else
            echo "$line" >> "$defgrub"
        fi
    done < grub/sp11-default-grub.conf

    local grubcfg
    if [ -f /etc/grub2-efi.cfg ]; then
        grubcfg="$(readlink -f /etc/grub2-efi.cfg)"
    elif [ -f /etc/grub2.cfg ]; then
        grubcfg="$(readlink -f /etc/grub2.cfg)"
    else
        grubcfg="/boot/grub2/grub.cfg"
    fi
    grub2-mkconfig -o "$grubcfg"
    ok "GRUB config regenerated ($grubcfg)"
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

    # Re-run automatically whenever linux-firmware replaces board-2.bin.
    # (Ubuntu's version of this used an apt Post-Invoke hook; dnf has no
    # direct equivalent, so this watches the firmware directory instead.)
    install_file systemd/sp11-wifi-board-fixup.service /etc/systemd/system/sp11-wifi-board-fixup.service
    install_file systemd/sp11-wifi-board-fixup.path     /etc/systemd/system/sp11-wifi-board-fixup.path
    systemctl daemon-reload
    systemctl enable --now sp11-wifi-board-fixup.path
    ok "Wi-Fi board data installed; auto re-extracts after firmware updates (path unit)"
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
    if systemctl list-unit-files --no-pager 2>/dev/null | grep hexagonrpcd-suspend >/dev/null 2>&1; then
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
    phase "NPU (FastRPC + QNN SDK + llama.cpp)"

    local NPU_RE="$REAL_HOME/npu-re"
    local DSP_DIR="/usr/lib/dsp/cdsp"
    local QAIRT_VER="2.48.0.260626"
    local QAIRT_URL="https://apigwx-aws.qualcomm.com/qsc/public/v1/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/${QAIRT_VER}/v${QAIRT_VER}.zip"
    local LLAMA_MODEL_URL="https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_0.gguf"

    # ── 8a — FastRPC udev rule ────────────────────────────────────────────
    install_file udev/99-fastrpc.rules /etc/udev/rules.d/99-fastrpc.rules
    udevadm control --reload-rules
    udevadm trigger
    ok "FastRPC udev rule deployed (0666 on /dev/fastrpc-*)"

    # ── 8b — hexagonrpcd + DSP binaries ──────────────────────────────────
    # Ubuntu's concept archive ships prebuilt hexagonrpcd/DSP-binaries
    # packages; Fedora has no equivalent repo for these, and
    # hexagon-dsp-binaries-qualcomm-hamoa-iot-evk in particular doesn't exist
    # outside that archive. Try a Fedora package name on the off chance it's
    # been packaged, but don't fail the phase if not — install_sensors()
    # (or a manual build per NPU.md Layer 4) is the real path to a working
    # hexagonrpcd on Fedora, and the file-existence checks below already
    # degrade gracefully when nothing is installed yet.
    if ! rpm -q hexagonrpcd >/dev/null 2>&1 && [ ! -x /usr/libexec/hexagonrpc/hexagonrpcd ]; then
        log "hexagonrpcd not found — attempting dnf package (best-effort)…"
        dnf install -y hexagonrpcd libhexagonrpc0 2>/dev/null || \
            warn "hexagonrpcd package not available on Fedora; run --sensors first (it builds it from source), or see NPU.md Layer 4"
    else
        ok "hexagonrpcd already installed"
    fi
    warn "hexagon-dsp-binaries-qualcomm-hamoa-iot-evk has no Fedora equivalent — DSP runtime shell binaries (fastrpc_shell_unsigned_3 etc.) must be sourced manually; see NPU.md Layer 4."
    systemctl enable hexagonrpcd.service 2>/dev/null || warn "hexagonrpcd.service unit not present yet (installed by --sensors)"

    # If suspend was also requested (or already done), apply the condition fix
    if systemctl list-unit-files --no-pager 2>/dev/null | grep hexagonrpcd-suspend >/dev/null 2>&1; then
        mkdir -p /etc/systemd/system/hexagonrpcd-suspend.service.d
        mkdir -p /etc/systemd/system/hexagonrpcd-resume.service.d
        cp -f systemd/hexagonrpcd-condition-override.conf \
            /etc/systemd/system/hexagonrpcd-suspend.service.d/override.conf
        cp -f systemd/hexagonrpcd-condition-override.conf \
            /etc/systemd/system/hexagonrpcd-resume.service.d/override.conf
        systemctl daemon-reload
        ok "hexagonrpcd suspend-hook condition fixed"
    fi

    # ── 8c — Deploy DSP runtime from hexagon-dsp-binaries ────────────────
    local PKG_DSP="/usr/share/hexagon-dsp/x1e80100/Qualcomm/Hamoa-IoT-EVK/dsp/cdsp"
    mkdir -p "$DSP_DIR"
    if [ -f "$PKG_DSP/fastrpc_shell_unsigned_3" ]; then
        cp -f "$PKG_DSP/fastrpc_shell_unsigned_3" "$DSP_DIR/"
        cp -f "$PKG_DSP/fastrpc_shell_3" "$DSP_DIR/" 2>/dev/null || true
        cp -f "$PKG_DSP/version.so" "$DSP_DIR/" 2>/dev/null || true
        ok "DSP FastRPC shell deployed from hexagon-dsp-binaries"
    elif [ -f "$DSP_DIR/fastrpc_shell_unsigned_3" ]; then
        ok "DSP FastRPC shell already deployed"
    else
        warn "fastrpc_shell_unsigned_3 not found — manual deployment needed"
        warn "  See NPU.md Layer 4: Deploy CDSP firmware + DSP runtime"
    fi

    # ── 8d — Build user-space fastrpc library ────────────────────────────
    if [ -f /usr/lib/libcdsprpc.so ] && nm -D /usr/lib/libcdsprpc.so 2>/dev/null | grep 'T remote_handle64_open' >/dev/null 2>&1; then
        ok "libcdsprpc.so already deployed (has remote_handle64_open)"
    else
        log "Building fastrpc user-space library…"
        dnf install -y autoconf automake libtool pkgconf-pkg-config gcc gcc-c++ make >/dev/null 2>&1 || true
        mkdir -p "$NPU_RE"
        if [ ! -d "$NPU_RE/fastrpc" ]; then
            as_user git clone -b development https://github.com/qualcomm/fastrpc.git "$NPU_RE/fastrpc"
        fi
        as_user bash -c "cd '$NPU_RE/fastrpc' && chmod +x autogen.sh && bash autogen.sh && ./configure --prefix=/usr/local && make -j\$(nproc)"
        cp -f "$NPU_RE/fastrpc/src/.libs/libcdsprpc.so"* /usr/lib/
        ldconfig
        ok "libcdsprpc.so built and deployed"
    fi

    # ── 8e — Verify CDSP firmware ───────────────────────────────────────
    local CDSP_FW="/lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn"
    if [ -f "$CDSP_FW" ]; then
        ok "CDSP firmware present ($(strings "$CDSP_FW" | grep -o 'CDSP.HT.[0-9.a-z_-]*' | head -1))"
    else
        warn "CDSP firmware missing at $CDSP_FW"
        warn "  The remoteproc expects: $(cat /sys/class/remoteproc/remoteproc1/firmware 2>/dev/null)"
        warn "  This firmware is device-specific (Surface Pro 11 'Denali') and cannot be auto-downloaded."
        warn "  See NPU.md Layer 4 for deployment instructions."
    fi

    # ── 8f — Download QAIRT SDK ─────────────────────────────────────────
    local QAIRT_ROOT="$REAL_HOME/qairt/$QAIRT_VER"
    if [ -f "$QAIRT_ROOT/lib/hexagon-v73/unsigned/libQnnHtpV73Skel.so" ]; then
        ok "QAIRT SDK $QAIRT_VER already installed"
    else
        log "Downloading QAIRT SDK $QAIRT_VER (~1.5 GB)…"
        as_user bash -c "cd /tmp && wget -O qairt.zip '$QAIRT_URL' && unzip -q -o qairt.zip -d '$REAL_HOME/qairt' && rm qairt.zip"
        # The zip extracts to qairt-linux-aarch64-VERSION
        if [ -d "$REAL_HOME/qairt/qairt-linux-aarch64-$QAIRT_VER" ]; then
            as_user mv "$REAL_HOME/qairt/qairt-linux-aarch64-$QAIRT_VER" "$QAIRT_ROOT"
        fi
        if [ -f "$QAIRT_ROOT/lib/hexagon-v73/unsigned/libQnnHtpV73Skel.so" ]; then
            ok "QAIRT SDK $QAIRT_VER installed at $QAIRT_ROOT"
        else
            warn "QAIRT SDK download may have failed — check $REAL_HOME/qairt/"
        fi
    fi
    # Set up environment variables for the real user
    if ! grep -q 'QNN_SDK_ROOT' "$REAL_HOME/.bashrc" 2>/dev/null; then
        cat >> "$REAL_HOME/.bashrc" << EOF
export QAIRT_SDK_ROOT=\$HOME/qairt/$QAIRT_VER
export QNN_SDK_ROOT=\$HOME/qairt/$QAIRT_VER
EOF
        ok "QNN_SDK_ROOT added to ~/.bashrc"
    fi

    # ── 8g — Deploy QNN HTP skeleton from QAIRT SDK ─────────────────────
    if [ -f "$QAIRT_ROOT/lib/hexagon-v73/unsigned/libQnnHtpV73SkelDrv.so" ]; then
        cp -f "$QAIRT_ROOT/lib/hexagon-v73/unsigned/libQnnHtpV73SkelDrv.so" "$DSP_DIR/"
        mkdir -p /usr/share/fastrpc
        cp -f "$QAIRT_ROOT/lib/hexagon-v73/unsigned/libQnnHtpV73SkelDrv.so" /usr/share/fastrpc/
        ok "QNN HTP v73 skeleton deployed"
    elif [ -f "$DSP_DIR/libQnnHtpV73SkelDrv.so" ]; then
        ok "QNN HTP v73 skeleton already deployed"
    else
        warn "libQnnHtpV73SkelDrv.so not available — QAIRT SDK may be needed"
    fi

    # ── 8h — Verify DSP-side C runtime ──────────────────────────────────
    local dsp_libc_ok=true
    for lib in libc.so libgcc.so; do
        if [ ! -f "$DSP_DIR/$lib" ]; then
            dsp_libc_ok=false
            warn "DSP $lib missing at $DSP_DIR/ — needed by skeleton libraries at runtime"
        fi
    done
    if $dsp_libc_ok; then
        ok "DSP-side C runtime present (libc.so, libgcc.so)"
    else
        warn "  These come from the Hexagon SDK target/hexagon/lib/v73/G0/pic/ directory."
        warn "  See NPU.md Layer 4 for details."
    fi

    # ── 8i — Build llama.cpp ────────────────────────────────────────────
    local PKG_DIR="$NPU_RE/llama.cpp/pkg-snapdragon"
    if [ -x "$PKG_DIR/bin/llama-cli" ]; then
        ok "llama.cpp pkg-snapdragon already built"
    else
        log "Building llama.cpp with Hexagon backend…"
        dnf install -y cmake clang gcc gcc-c++ make >/dev/null 2>&1 || true

        # Clone llama.cpp
        if [ ! -d "$NPU_RE/llama.cpp/.git" ]; then
            as_user git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$NPU_RE/llama.cpp"
        fi

        # Copy build presets
        as_user cp "$SCRIPT_DIR/npu/CMakeUserPresets.json" "$NPU_RE/llama.cpp/"

        # Set up environment for cmake
        local CMAKE_ENV="HEXAGON_SDK_ROOT=\"$QAIRT_ROOT\" HEXAGON_TOOLS_ROOT=\"$QAIRT_ROOT/bin/x86_64-linux-clang\""

        # Configure + build
        if as_user bash -c "cd '$NPU_RE/llama.cpp' && export $CMAKE_ENV && \
                cmake -B build-snapdragon --preset arm64-linux-snapdragon-release -DGGML_HEXAGON=ON && \
                cmake --build build-snapdragon --config Release -j\$(nproc)"; then
            ok "llama.cpp built successfully"
        else
            warn "llama.cpp build failed — the Hexagon DSP skeleton compiler may be missing."
            warn "  If the host-side build succeeded, you can still create a CPU-only package."
            warn "  For full HTP0 support, you need the Hexagon SDK for the DSP skeleton."
            warn "  See NPU.md Layer 6 for details."
        fi

        # Package into pkg-snapdragon
        if [ -f "$NPU_RE/llama.cpp/build-snapdragon/bin/llama-cli" ]; then
            log "Packaging into pkg-snapdragon…"
            as_user bash -c "cd '$NPU_RE/llama.cpp' && \
                mkdir -p pkg-snapdragon/bin pkg-snapdragon/lib && \
                cp build-snapdragon/bin/llama-cli pkg-snapdragon/bin/ && \
                cp build-snapdragon/bin/llama-server pkg-snapdragon/bin/ 2>/dev/null || true && \
                cp build-snapdragon/bin/libggml*.so build-snapdragon/bin/libllama*.so \
                   build-snapdragon/bin/libmtmd*.so pkg-snapdragon/lib/ 2>/dev/null || true && \
                cp build-snapdragon/ggml/src/ggml-hexagon/libggml-htp-v73.so pkg-snapdragon/lib/ 2>/dev/null || true"

            # Deploy ggml skeleton to DSP search paths
            if [ -f "$NPU_RE/llama.cpp/build-snapdragon/ggml/src/ggml-hexagon/libggml-htp-v73.so" ]; then
                cp -f "$NPU_RE/llama.cpp/build-snapdragon/ggml/src/ggml-hexagon/libggml-htp-v73.so" "$DSP_DIR/"
                cp -f "$NPU_RE/llama.cpp/build-snapdragon/ggml/src/ggml-hexagon/libggml-htp-v73.so" /usr/lib/dsp/
                ok "ggml HTP v73 skeleton deployed to DSP search paths"
            fi
            ok "pkg-snapdragon packaged at $PKG_DIR"
        else
            warn "llama-cli binary not found — build may have failed"
        fi
    fi

    # ── 8j — Download default model ─────────────────────────────────────
    local MODEL_DIR="$NPU_RE/llama-hexagon"
    local MODEL_FILE="$MODEL_DIR/Llama-3.2-1B-Instruct-Q4_0.gguf"
    if [ -f "$MODEL_FILE" ]; then
        ok "Llama-3.2-1B model already downloaded"
    else
        log "Downloading Llama-3.2-1B-Instruct-Q4_0 (~738 MB)…"
        mkdir -p "$MODEL_DIR"
        as_user wget -c -O "$MODEL_FILE" "$LLAMA_MODEL_URL" || \
            warn "Model download failed — test_llama.sh will retry automatically"
        [ -f "$MODEL_FILE" ] && ok "Model downloaded" || true
    fi

    # ── 8k — Summary ────────────────────────────────────────────────────
    echo
    echo "${C_BOLD}NPU setup status:${C_RST}"
    local cdsprpc_ok="✗ MISSING"
    [ -f /usr/lib/libcdsprpc.so ] && nm -D /usr/lib/libcdsprpc.so 2>/dev/null | grep 'T remote_handle64_open' >/dev/null 2>&1 && cdsprpc_ok="✓ patched"
    echo "  ${C_DIM}CDSP firmware:${C_RST}    $([ -f "$CDSP_FW" ] && echo '✓ present' || echo '✗ MISSING — see NPU.md')"
    echo "  ${C_DIM}fastrpc shell:${C_RST}    $([ -f "$DSP_DIR/fastrpc_shell_unsigned_3" ] && echo '✓ present' || echo '✗ MISSING')"
    echo "  ${C_DIM}libcdsprpc.so:${C_RST}    $cdsprpc_ok"
    echo "  ${C_DIM}QNN skeleton:${C_RST}     $([ -f "$DSP_DIR/libQnnHtpV73SkelDrv.so" ] && echo '✓ present' || echo '✗ MISSING')"
    echo "  ${C_DIM}DSP libc/libgcc:${C_RST}  $([ -f "$DSP_DIR/libc.so" ] && [ -f "$DSP_DIR/libgcc.so" ] && echo '✓ present' || echo '✗ MISSING — see NPU.md')"
    echo "  ${C_DIM}ggml skeleton:${C_RST}    $([ -f "$DSP_DIR/libggml-htp-v73.so" ] && echo '✓ present' || echo '✗ will be built by llama.cpp')"
    echo "  ${C_DIM}llama-cli:${C_RST}        $([ -x "$PKG_DIR/bin/llama-cli" ] && echo '✓ built' || echo '✗ not built')"
    echo "  ${C_DIM}model:${C_RST}            $([ -f "$MODEL_FILE" ] && echo '✓ downloaded' || echo '✗ not downloaded')"
    echo
    echo "${C_DIM}  Run: ./scripts/test_llama.sh${C_RST}"
    echo "${C_DIM}  Or:  cd ~/npu-re && sudo bash test_env.sh  (14-check prerequisite test)${C_RST}"
}
# ══════════════════════════════════════════════════════════════════════════
# STEP — SENSORS (hexagonrpcd + config + libssc)
# ══════════════════════════════════════════════════════════════════════════
install_sensors() {
    phase "Sensors (SSC/QMI via hexagonrpcd + libssc)"

    local SNS_ROOT="/usr/share/qcom/x1e80100/Microsoft/Surface-Pro-11"

    # ── packages ──
    log "Installing hexagonrpcd packages"
    dnf install -y hexagonrpcd libhexagonrpc0 2>/dev/null || true

    # ── mount Windows partition ──
    local WIN="/mnt/windows"
    if ! mountpoint -q "$WIN"; then
        local winpart
        winpart="$(lsblk -lno NAME,FSTYPE | awk '$2=="ntfs"{print "/dev/"$1; exit}')"
        [ -n "$winpart" ] || die "Cannot find Windows NTFS partition"
        log "Mounting $winpart at $WIN (read-only)"
        mount -t ntfs3 -o ro "$winpart" "$WIN" 2>/dev/null || \
            mount -t ntfs-3g -o ro "$winpart" "$WIN" 2>/dev/null || \
            mount -o ro "$winpart" "$WIN"
    fi

    # ── sensor config (JSON files from Windows DriverStore) ──
    local DRVDIR="$WIN/Windows/System32/DriverStore/FileRepository"
    local SNSCFG
    SNSCFG="$(ls -d "$DRVDIR"/surfacepro_snscfgcrd8380.inf_* 2>/dev/null | head -1)"
    [ -n "$SNSCFG" ] || die "Cannot find surfacepro_snscfgcrd8380.inf in Windows DriverStore"

    log "Copying sensor config JSONs from Windows DriverStore"
    mkdir -p "$SNS_ROOT/sensors/config" "$SNS_ROOT/sensors/registry"
    cp "$SNSCFG"/*.json "$SNS_ROOT/sensors/config/"
    cp "$SNSCFG"/json.lst "$SNS_ROOT/sensors/config/" 2>/dev/null || true
    cp "$SNSCFG"/golden_color_calibration.bin "$SNS_ROOT/sensors/config/" 2>/dev/null || true

    # ── sns_reg.conf ──
    log "Deploying sns_reg.conf"
    install_file sensors/sns_reg.conf "$SNS_ROOT/sensors/sns_reg.conf"

    # ── pre-parsed registry (from Windows DriverData) ──
    local FSTRPC="$WIN/Windows/System32/drivers/DriverData/Qualcomm/fastRPC"
    if [ -d "$FSTRPC/persist/sensors/registry/registry" ]; then
        log "Copying pre-parsed sensor registry from Windows DriverData (321 files)"
        cp "$FSTRPC"/persist/sensors/registry/registry/* "$SNS_ROOT/sensors/registry/"
        cp "$FSTRPC"/persist/sensors/registry/parsed_file_list.csv "$SNS_ROOT/sensors/registry/" 2>/dev/null || true
        cp "$FSTRPC"/persist/sensors/registry/sns_reg_version "$SNS_ROOT/sensors/registry/" 2>/dev/null || true
        ok "Registry: $(ls "$SNS_ROOT/sensors/registry/" | wc -l) files"
    else
        warn "Windows DriverData/fastRPC not found — registry copy skipped"
        warn "Sensors will NOT work without the pre-parsed registry"
    fi

    # ── Surface-specific calibration from Windows ──
    if [ -d "$FSTRPC/vendor/etc/sensors/config" ]; then
        log "Copying Surface calibration files"
        cp "$FSTRPC"/vendor/etc/sensors/config/* "$SNS_ROOT/sensors/config/" 2>/dev/null || true
    fi

    # ── permissions ──
    # On Ubuntu the "fastrpc" system user/group comes from the hexagonrpcd
    # package's postinst; Fedora has no such package, so create it ourselves.
    getent group fastrpc >/dev/null || groupadd -r fastrpc
    getent passwd fastrpc >/dev/null || useradd -r -g fastrpc -M -s /sbin/nologin fastrpc
    chown -R fastrpc:fastrpc "$SNS_ROOT/sensors/"

    # ── custom hexagonrpcd (method 24 + write support) ──
    log "Building custom hexagonrpcd with method 24 + write support"
    if ! command -v meson >/dev/null 2>&1; then
        dnf install -y meson ninja-build gcc pkgconf-pkg-config libhexagonrpc-devel 2>/dev/null || true
    fi
    local HEXSRC="$SCRIPT_DIR/hexagonrpc-src"
    if [ ! -d "$HEXSRC" ]; then
        git clone https://github.com/linux-msm/hexagonrpc.git "$HEXSRC" 2>/dev/null || true
    fi

    if [ -d "$HEXSRC" ]; then
        # Apply patches for method 24 + write support
        # (These are already applied if this repo includes the patched source)
        if [ -f "$HEXSRC/hexagonrpcd/apps_std.c" ] && ! grep -q 'mkdir_stub' "$HEXSRC/hexagonrpcd/apps_std.c"; then
            warn "hexagonrpcd source needs patches — see SENSORS.md for manual build instructions"
        else
            meson setup "$HEXSRC/build" "$HEXSRC" 2>/dev/null || true
            ninja -C "$HEXSRC/build" 2>/dev/null && {
                cp "$HEXSRC/build/hexagonrpcd/hexagonrpcd" /usr/libexec/hexagonrpc/hexagonrpcd
                chown root:root /usr/libexec/hexagonrpc/hexagonrpcd
                chmod 755 /usr/libexec/hexagonrpc/hexagonrpcd
                ok "Custom hexagonrpcd installed"
            } || warn "hexagonrpcd build failed — stock version will be used (sensors still work)"
        fi
    else
        warn "Could not clone hexagonrpc — stock hexagonrpcd will be used"
        warn "Sensors still work but hexagonrpcd will crash after init (non-fatal)"
    fi

    # ── systemd services ──
    log "Installing systemd services"
    install_file systemd/sensors-platform-info.service /etc/systemd/system/sensors-platform-info.service
    install_file systemd/hexagonrpcd-sensors.service /etc/systemd/system/hexagonrpcd.service

    # hexagonrpcd env override
    mkdir -p /etc/systemd/system/hexagonrpcd.service.d
    cat > /etc/systemd/system/hexagonrpcd.service.d/override.conf << 'CONF'
[Service]
Environment="hexagonrpcd_device=/dev/fastrpc-adsp"
Environment="hexagonrpcd_dsp=adsp"
Environment="hexagonrpcd_fw_dir=/usr/share/qcom/x1e80100/Microsoft/Surface-Pro-11/"
Environment="hexagonrpcd_extra=-s"
CONF

    systemctl daemon-reload
    systemctl enable sensors-platform-info.service hexagonrpcd.service
    ok "Systemd services installed (early start + restart=always)"

    # ── libssc (QMI sensor client) ──
    log "Installing libssc + ssccli"
    dnf install -y meson ninja-build glib2-devel gstreamer1-devel \
        gstreamer1-plugins-base-devel systemd-devel libqmi-devel qrtr-glib-devel 2>/dev/null || true

    local LIBSSC_SRC="$SCRIPT_DIR/libssc-src"
    if [ ! -d "$LIBSSC_SRC" ]; then
        git clone https://github.com/DakkesheshRC/libssc.git "$LIBSSC_SRC" 2>/dev/null || true
    fi
    if [ -d "$LIBSSC_SRC" ]; then
        meson setup "$LIBSSC_SRC/build" "$LIBSSC_SRC" 2>/dev/null || true
        ninja -C "$LIBSSC_SRC/build" 2>/dev/null && {
            ninja -C "$LIBSSC_SRC/build" install 2>/dev/null
            ldconfig
            ok "libssc + ssccli installed"
        } || warn "libssc build failed — install manually (see SENSORS.md)"
    else
        warn "Could not clone libssc — install manually"
    fi


    # ── Fast sensor reader tool ──
    log "Building sp11-sensor-read"
    gcc -O2 -Wall -o "$SCRIPT_DIR/sensors/sp11-sensor-read" \
        "$SCRIPT_DIR/sensors/sp11-sensor-read.c" \
        $(pkg-config --cflags --libs libssc 2>/dev/null) 2>/dev/null && \
        ok "sp11-sensor-read built (reads all sensors in ~1s)" || \
        warn "sp11-sensor-read build failed (test script will use ssccli fallback)"
    # ── Sensor discovery tool ──
    log "Building sp11-sensor-discover"
    gcc -O2 -Wall -o "$SCRIPT_DIR/sensors/sp11-sensor-discover" \
        "$SCRIPT_DIR/sensors/sp11-sensor-discover.c" \
        $(pkg-config --cflags --libs libssc 2>/dev/null) 2>/dev/null && \
        ok "sp11-sensor-discover built" || \
        warn "sp11-sensor-discover build failed"

    ok "Sensor installation complete"
    warn "→ Reboot required for sensors to initialise"
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
$DO_SENSORS && install_sensors

# ── summary ───────────────────────────────────────────────────────────────
echo
echo "${C_BOLD}${C_GREEN}═══ Done ═══${C_RST}"
$DO_AUDIO  && echo "  ${C_YELLOW}→ Reboot for audio to take effect${C_RST}"
$DO_KERNEL && echo "  ${C_YELLOW}→ Reboot to use the new kernel${C_RST}"
$DO_GRUB   && echo "  ${C_YELLOW}→ Reboot for new kernel arguments${C_RST}"
$DO_SENSORS && echo "  ${C_YELLOW}→ Reboot for sensors to initialise${C_RST}"
echo
echo "Verify with:  ${C_BOLD}sudo ./install.sh --list${C_RST}  (phase list)"
echo "Full checklist: see README.md → Verification checklist"
