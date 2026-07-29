# Ubuntu on Surface Pro 11 (Snapdragon X Elite)

Complete, self-contained setup guide for enabling **Wi-Fi**, **touchscreen**, **stylus (Surface Slim Pen 2)**, **audio (speakers + microphone)**, **suspend/resume**, and **NPU AI** (llama.cpp via QNN) on a Microsoft Surface Pro 11 with Snapdragon X Elite (X1E80100).

Everything needed to reproduce from a stock Ubuntu install is in this repo — scripts, kernel patches, firmware files, configs, and source code.

> **Target device:** Microsoft Surface Pro 11, **OLED display**, **16 GB RAM**, **1 TB NVMe** (no 5G model). SKU `Surface_Pro_11th_Edition_2076`, Snapdragon X 12-core X1E80100 @ 3.40 GHz, UEFI firmware `175.222.235`.

## Status Summary

| **Feature** | **Status** | **Notes** |
| --- | :---: | --- |
| NVMe | ✅ | Boots from NVMe with custom DTB + patched kernel |
| Graphics | ✅ | 3D acceleration for X1E SoCs only; X1P support is on its way from upstream |
| Backlight | ✅ | Adjustable via `/sys/class/backlight/dp_aux_backlight/brightness` |
| USB3 | ⚠️ Partial | USB-C ports working; Surface Dock connector not verified |
| USB4 / Thunderbolt | ❌ | No external display output via [official USB4 dock](https://learn.microsoft.com/en-us/surface/surface-usb4-dock) |
| USB-C display output | ✅ | Working (DP alt mode, since 6.15-rc6) |
| Wi-Fi | ✅ | WCN7850 / ath12k — kernel rfkill bypass + board data file extraction. Scans, connects, passes traffic. |
| Bluetooth | ✅ | MAC address configured via `btmgmt` helper (`scripts/sp11-bluetooth-mac.sh`) |
| Audio — Speakers | ✅ | WSA884x dual speakers working via PipeWire manual sink + WSA routing service (includes speaker codec switch enable). |
| Audio — Microphone | ✅ | Dual far-field DMIC working via VA macro with 2.4 MHz clock (kernel patch) and unity gain (UCM2). Verified: clear stereo capture at 48 kHz. |
| Touchscreen | ✅ | Single-touch (tap, drag, scroll) working via HID-over-SPI with custom kernel patches (QSPI DMA + HID-SPI stack + Denali DTS node). Multi-touch not available. |
| Pen | ✅ | Surface Slim Pen 2 fully working via hybrid HEAT/uinput auto-switching daemon. 1–4095 pressure levels, hover, tip contact, eraser. |
| Flex Keyboard | ✅ | Type Cover touchpad and keyboard work when attached |
| Suspend / Resume | ✅ | `s2idle` working via lid-switch daemon (close → backlight off → 60s → suspend → power-button resume). Requires `cpu-sleep-0` cpuidle workaround (`pm_test`-bisected root cause) + hexagonrpcd suspend-hook condition fix. See [SUSPEND.md](SUSPEND.md). |
| Cameras (and status LEDs) | ❌ | Not working |
| Sensors | ✅ Working | 13 SSC sensors producing data: accelerometer, gyroscope, magnetometer, ambient light, RGB color, compass, SAR, gravity + rotation + game-rotation vectors, fast/relative motion. **Tablet mode** ✅ via SSAM. Pre-parsed registry from Windows DriverData + custom hexagonrpcd. See [SENSORS.md](SENSORS.md). |
| NPU — CPU inference | ✅ | llama.cpp CPU inference working via QNN SDK + Hexagon backend build |
| NPU — DSP (HTP0) offload | ✅ | llama.cpp runs on Hexagon NPU via `--device HTP0`. Verified: Llama-3.2-1B (~48 t/s), Qwen2.5-Coder-3B (~21 t/s). CDSP remoteproc reset recommended before each run to defragment rpcmem heap. See [NPU.md](NPU.md). |

## Documentation

| Document | Topic |
| --- | --- |
| [WIFI.md](WIFI.md) | Wi-Fi findings and solution (rfkill bypass + board data) |
| [SOUND.md](SOUND.md) | Audio findings and solution (DSP firmware + topology + boot-race fix) |
| [TOUCHSCREEN.md](TOUCHSCREEN.md) | Touchscreen findings (HID-over-SPI kernel patches) |
| [PEN.md](PEN.md) | Stylus findings (hybrid HEAT auto-switching daemon) |
| [SUSPEND.md](SUSPEND.md) | Suspend/resume findings (lid daemon + wake policy + DSP hooks) |
| [NPU.md](NPU.md) | NPU findings (QNN SDK + llama.cpp Hexagon backend) |
| [SENSORS.md](SENSORS.md) | Sensor setup (SSC/QMI, hexagonrpcd, Windows registry, libssc) |

---

## Prerequisites

- **Secure Boot disabled** in Surface UEFI (hold Volume-Up + Power at boot → UEFI settings).
- **Do NOT erase Windows.** Keep the Windows partition intact during Ubuntu installation — it is the primary source for Qualcomm DSP firmware (ADSP/CDSP `.mbn` files). If the pre-packaged firmware in this repo doesn't match your exact hardware revision, you can extract it directly from Windows. After installation, mount the Windows partition:

```bash
sudo mkdir -p /mnt/windows
sudo mount /dev/nvme0n1p3 /mnt/windows   # adjust partition number as needed
```

  Then extract firmware from it if needed:
  ```bash
  sudo ./scripts/sp11-grab-fw.sh --windows-root /mnt/windows
  ```

- **Ubuntu Resolute (concept ISO)** installed on NVMe. Download the Snapdragon X Elite desktop image:

```
https://people.canonical.com/~platform/images/ubuntu-concept/resolute-desktop-arm64+x1e-20260326.iso
```

  Write it to a USB-C flash drive (16 GB+) and boot the Surface Pro 11 from it. Install to NVMe alongside Windows (do not overwrite the Windows partition).

- Internet access for the initial firmware download step (Wi-Fi won't work in the live session — use USB-C Ethernet or phone tethering).
- `sudo` access.
- Clone this repo to the target machine:

```bash
git clone <your-repo-url> ubuntu-surface-pro-11
cd ubuntu-surface-pro-11
```

Install base build dependencies:

```bash
sudo apt update
sudo apt install -y \
    git curl python3 zstd m4 alsa-utils \
    build-essential gcc make cmake ninja-build \
    linux-headers-$(uname -r)
```

---

## Quick install

The `install.sh` script automates all post-kernel configuration (Steps 2–8 below):

```bash
sudo ./install.sh             # install everything (grub, Wi-Fi, audio, pen, suspend, NPU)
sudo ./install.sh --suspend   # install individual components only
sudo ./install.sh --kernel    # also build & install the patched kernel (~30 min)
sudo ./install.sh --list      # list all available phases
sudo ./install.sh --uninstall # remove everything this script installed
```

Prefer step-by-step? The **manual instructions** for each component follow below.

---

## Step 1 — Build and install the patched kernel

The stock Ubuntu `qcom-x1e` kernel lacks Surface Pro 11 patches. This repo includes all 18 kernel patches.

### What the patches do

| Patch set | Count | Purpose |
| --- | --- | --- |
| `kernel-patches/sp11-touchscreen/` | 15 | QSPI DMA + HID-over-SPI driver stack + Denali DTS touchscreen node |
| `kernel-patches/rfkill-wifi-mac/` | 2 | ath12k rfkill bypass + devicetree MAC address |
| `kernel-patches/dmic-clock/` | 1 | 2.4 MHz DMIC clock (fixes microphone noise) |

### Build

```bash
# Clone the kernel source (Jens Glathe's qcom-x1e tree)
git clone --depth 1 --branch jg/ubuntu-qcom-x1e-7.1.3-jg-1 \
    https://github.com/jglathe/linux_ms_dev_kit.git ~/linux-sp11
cd ~/linux-sp11

# Apply all Surface Pro 11 patches
git am ~/ubuntu-surface-pro-11/kernel-patches/sp11-touchscreen/*.patch
git am ~/ubuntu-surface-pro-11/kernel-patches/rfkill-wifi-mac/*.patch
git am ~/ubuntu-surface-pro-11/kernel-patches/dmic-clock/*.patch

# Configure
cp /boot/config-$(uname -r) .config
make olddefconfig

# Build deb packages
make -j$(nproc) bindeb-pkg
```

### Install and reboot

```bash
cd ..
sudo dpkg -i linux-image-*.deb linux-headers-*.deb
sudo reboot
```

After reboot verify:

```bash
uname -r
# Should show the 7.1.3-jg-1sp11v2-qcom-x1e kernel
```

---

## Step 2 — GRUB and boot configuration

Install the GRUB drop-in configs for X1E bring-up arguments:

```bash
sudo cp grub/99-surface-pro-11.cfg /etc/default/grub.d/
sudo cp grub/98-sp11-timeout.cfg /etc/default/grub.d/
sudo cp grub/ubuntu-x1e-settings.cfg /etc/default/grub.d/
sudo update-grub
```

Key kernel arguments applied: `clk_ignore_unused pd_ignore_unused arm64.nopauth systemd.tpm2_wait=0 mem_sleep_default=s2idle`

---

## Step 3 — Wi-Fi

> Details: [WIFI.md](WIFI.md)

The WCN7850 (FastConnect 7800) needs a board data file. The rfkill bypass is already in the patched kernel.

```bash
sudo cp scripts/sp11-wifi-board-fixup.sh /usr/local/sbin/sp11-wifi-board-fixup

# Run it (extracts a compatible board.bin from linux-firmware's board-2.bin)
sudo /usr/local/sbin/sp11-wifi-board-fixup

# Install the apt hook so board.bin is re-extracted after linux-firmware upgrades
sudo cp apt/99surface-pro-11-wifi-fixup /etc/apt/apt.conf.d/
```

Verify:

```bash
rfkill list              # no hard/soft blocks on phy0
iw dev                   # interface wlP4p1s0 should be up
nmcli device wifi list   # should show scan results
```

---

## Step 4 — Audio (speakers + microphone)

> Details: [SOUND.md](SOUND.md)

### 4a. Install DSP firmware

```bash
sudo cp scripts/sp11-grab-fw.sh /usr/local/sbin/sp11-grab-fw
sudo /usr/local/sbin/sp11-grab-fw --download
```

This downloads ADSP/CDSP firmware (`.mbn`, `.jsn`) from public Windows Qualcomm reference driver CABs and installs them to `/lib/firmware/qcom/x1e80100/microsoft/Denali/`.

### 4b. Install AudioReach topology

```bash
sudo mkdir -p /lib/firmware/qcom/x1e80100
sudo cp audio/firmware/X1E80100-Microsoft-Surface-Pro-11-tplg.bin \
    /lib/firmware/qcom/x1e80100/
```

### 4c. Install ALSA UCM2 configuration

```bash
sudo mkdir -p /usr/share/alsa/ucm2/Qualcomm/x1e80100
sudo cp audio/ucm/MICROSOFT-Surface-Pro-11.conf \
    /usr/share/alsa/ucm2/Qualcomm/x1e80100/
sudo cp audio/ucm/Surface11-HiFi.conf \
    /usr/share/alsa/ucm2/Qualcomm/x1e80100/

sudo mkdir -p /usr/share/alsa/ucm2/conf.d/x1e80100
sudo cp audio/ucm/x1e80100.conf \
    /usr/share/alsa/ucm2/conf.d/x1e80100/
```

### 4d. Fix the audio boot race

`alsactl` restores WSA mixer state before the DSP finishes loading, causing bus clash and silence. Fix it permanently:

```bash
# Install the routing script and service
sudo cp scripts/sp11-enable-wsa-routing.sh /usr/local/sbin/
sudo cp systemd/sp11-wsa-routing.service /etc/systemd/system/

# Mask alsactl so it doesn't race the DSP
sudo systemctl mask alsa-restore.service alsa-state.service

# Enable the WSA routing service (waits for DSP, enables speakers)
sudo systemctl daemon-reload
sudo systemctl enable sp11-wsa-routing.service
```

### 4e. Install PipeWire speaker sink (per-user)

```bash
# Install the speaker sink config (creates ~/.config/pipewire/...)
./scripts/sp11-pipewire-speaker-sink.sh --install --enable-route

# Install the PipeWire restart user service
mkdir -p ~/.config/systemd/user
cp systemd/sp11-pipewire-restart.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable sp11-pipewire-restart.service
```

### 4f. Reboot and verify

```bash
sudo reboot

# After reboot:
systemctl status sp11-wsa-routing.service   # should show "WSA speaker routing enabled"
speaker-test -D hw:X1E80100Microso,1 -c 4 -t sine -f 440 -l 1   # should hear tone
arecord -D hw:X1E80100Microso,3 -c 2 -d 3 /tmp/test.wav         # should record
```

Select **"Surface Pro 11 Speakers"** in your desktop sound settings.

---

## Step 5 — Touchscreen

> Details: [TOUCHSCREEN.md](TOUCHSCREEN.md)

The touchscreen works automatically once the patched kernel (Step 1) is running — the HID-over-SPI patches and Denali DTS node enable the digitizer. No additional setup needed beyond the kernel.

Single-touch (tap, drag, scroll) works out of the box. Multi-touch (pinch-to-zoom, two-finger gestures) is not available in standard HID mode.

Verify:

```bash
cat /proc/bus/input/devices | grep -A5 "Touchscreen"
# Should show the 045E:0C83 digitizer input device
```

---

## Step 6 — Stylus (Surface Slim Pen 2)

> Details: [PEN.md](PEN.md)

The pen requires a userspace daemon that switches the digitizer between finger-touch and HEAT (pen tracking) modes.

### 6a. Install udev rule (stable device symlink)

```bash
sudo cp udev/99-sp11-pen.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### 6b. Build the pen daemon

```bash
cd pen-daemon
gcc -O2 -Wall -o sp11-pen-daemon sp11-pen-daemon.c -lm
sudo cp sp11-pen-daemon /usr/local/sbin/
cd ..
```

### 6c. Install the systemd service

```bash
sudo cp systemd/sp11-pen-daemon.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sp11-pen-daemon.service
```

Verify:

```bash
systemctl status sp11-pen-daemon.service
# Should show: "Hybrid Auto-Switch Daemon started; FINGER TOUCH MODE active"
ls -la /dev/sp11-pen
# Should be a symlink to /dev/hidrawN
```

The daemon creates a virtual stylus (`SP11 G6 Virtual Stylus`) supporting 1–4095 pressure levels. It auto-switches: finger touch by default, switches to pen mode when the pen is detected (within 25ms probe), switches back to finger touch after 1s of pen inactivity.

---

## Step 7 — Suspend / resume

> Details: [SUSPEND.md](SUSPEND.md)

`s2idle` (suspend-to-idle) is working. Close the Flex cover → backlight off →
60s inactivity → suspend → power button resumes cleanly.

**Root cause of the earlier crash** (2026-07-28): the `cpu-sleep-0` PSCI
retention cpuidle state hard-faults the SoC during s2idle entry — proven by
`/sys/power/pm_test` bisection (freezer/devices/platform all pass; only the
final cpuidle idle entry crashes). The crash behaved as transient firmware
state and later cleared on its own, but the fix below is kept as a safety net:
it is a proven fix when the bad state is present and harmless otherwise.

### 7a. Disable systemd-logind lid handling

The lid daemon (not systemd-logind) must own suspend timing. Set `ignore` on
all power states so logind does not race the daemon:

```bash
sudo sed -i 's/^#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sudo systemctl restart systemd-logind
```

### 7b. Install the cpuidle s2idle fix (the root-cause workaround)

Disables `cpu-sleep-0` before every suspend and restores it on resume, so
runtime idle stays power-efficient (WFI during suspend, retention otherwise):

```bash
# Toggle script
sudo cp scripts/sp11-fix-cpuidle-s2idle /usr/local/sbin/

# system-sleep hook — MUST go in /usr/lib/, not /etc/ (systemd 259 only
# runs hooks from /usr/lib/systemd/system-sleep/)
sudo cp system-sleep/sp11-cpuidle-s2idle /usr/lib/systemd/system-sleep/
sudo chmod +x /usr/local/sbin/sp11-fix-cpuidle-s2idle \
              /usr/lib/systemd/system-sleep/sp11-cpuidle-s2idle
```

### 7c. Fix the hexagonrpcd suspend-hook condition (defensive)

The `hexagonrpcd` package ships suspend/resume hooks that stop the sensors
daemon across suspend, but they are guarded by the wrong SoC condition
(`qcom,sdm670` instead of `qcom,x1e80100`) so they never fire. Fix it:

```bash
sudo mkdir -p /etc/systemd/system/hexagonrpcd-suspend.service.d
sudo mkdir -p /etc/systemd/system/hexagonrpcd-resume.service.d
sudo cp systemd/hexagonrpcd-condition-override.conf \
    /etc/systemd/system/hexagonrpcd-suspend.service.d/override.conf
sudo cp systemd/hexagonrpcd-condition-override.conf \
    /etc/systemd/system/hexagonrpcd-resume.service.d/override.conf
sudo systemctl daemon-reload
```

### 7d. Install the lid-switch backlight/suspend daemon

The `sp11-lid-backlight` daemon: finds the lid switch (`gpio-keys SW_LID`),
disables all wake sources except the power button, turns off the backlight on
close (restores on open), and triggers `systemctl suspend` after 60s of lid-closed
inactivity (external input resets the timer):

```bash
sudo cp scripts/sp11-lid-backlight /usr/local/sbin/
sudo cp systemd/sp11-lid-backlight.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sp11-lid-backlight.service
```

### 7e. Suspend debug logging (optional)

```bash
sudo cp scripts/sp11-enable-suspend-debug /usr/local/sbin/
sudo cp systemd/sp11-suspend-debug.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable sp11-suspend-debug.service
```

### 7f. Verify

```bash
# cpuidle fix active (0/12 at runtime — disabled only during suspend by hook)
sp11-fix-cpuidle-s2idle status

# All services
systemctl status sp11-lid-backlight.service
systemctl is-active hexagonrpcd-suspend.service

# After a suspend/resume cycle (close lid, wait 60s, power button to wake):
cat /sys/power/suspend_stats/success   # should increment
journalctl -b 0 -g sp11-cpuidle-s2idle # hook fired (disabled pre, enabled post)
```

---
## Step 8 — Sensors (accelerometer, gyroscope, magnetometer, ambient light & more)

> Details: [SENSORS.md](SENSORS.md)

Sensors are managed by the ADSP's Snapdragon Sensor Core (SSC) framework and accessed via QMI over QRTR. The key requirement is copying the pre-parsed sensor registry from the Windows partition — this lets the SNS framework initialise sensors without `oemconfig.so`.

```bash
sudo ./install.sh --sensors
```

This installs:
- hexagonrpcd with early-start systemd service (`After=sysinit.target`)
- Sensor config JSONs from Windows DriverStore
- Pre-parsed sensor registry (321 files) from Windows DriverData
- Custom hexagonrpcd build (method 24 stub + write support)
- `sp11-sensor-read` — reads all 13 working sensors (values where the format is known; SAR/color as raw bytes)
- `sp11-sensor-discover` — lists every detected sensor and verifies it produces data
- `sensors-platform-info.service` (platform ID files for hexagonrpcd)

**Reboot** after installation — the SNS framework reads the registry only during ADSP boot.

Verify:

```bash
# All sensors (~1.5s):
./scripts/test_sensors.sh

# Or use the fast reader directly:
sensors/sp11-sensor-read                # all sensors
sensors/sp11-sensor-read accel          # accelerometer only
sensors/sp11-sensor-read accel light 5  # specific sensors, 5s timeout

# List every detected sensor + verify it produces data:
sensors/sp11-sensor-discover

# Legacy (slower, one sensor at a time):
export LD_LIBRARY_PATH="/usr/local/lib/aarch64-linux-gnu"
ssccli --sensor accelerometer --timeout 10
```

> **Note:** hexagonrpcd may crash after initialising sensors (non-fatal `fstempfile` write errors). Sensors stay alive because the SNS framework runs on the ADSP independently. `Restart=always` keeps hexagonrpcd reconnecting.

> **WARNING:** Do NOT reset the ADSP via `echo stop > /sys/class/remoteproc/remoteproc0/state` — this crashes the entire SoC. Use a normal reboot to restart the ADSP.

---


## Step 9 — NPU AI (llama.cpp via QNN)

> Details: [NPU.md](NPU.md)

### 9a. FastRPC device permissions

```bash
sudo cp udev/99-fastrpc.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### 9b. Install hexagonrpcd (DSP daemon)

```bash
sudo apt install -y hexagonrpcd hexagon-dsp-binaries-qualcomm-hamoa-iot-evk libhexagonrpc-dev
sudo systemctl enable hexagonrpcd.service
```

### 9c. Install QNN SDK

Download the **Qualcomm AI Runtime (QAIRT) SDK** v2.48.0.260626 (Community edition, all platforms):

```
https://apigwx-aws.qualcomm.com/qsc/public/v1/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.48.0.260626/v2.48.0.260626.zip
```

Also available from the [Qualcomm Developer Network](https://www.qualcomm.com/developer/software/qualcomm-ai-engine-direct).

```bash
# Download and extract
wget -O qairt.zip 'https://apigwx-aws.qualcomm.com/qsc/public/v1/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.48.0.260626/v2.48.0.260626.zip'
unzip qairt.zip -d ~/qairt
# The SDK extracts to ~/qairt/qairt-linux-aarch64-2.48.0.260626/
# Rename for consistency:
mv ~/qairt/qairt-linux-aarch64-2.48.0.260626 ~/qairt/2.48.0.260626

source ~/qairt/2.48.0.260626/bin/envsetup.sh

# Persist environment
cat >> ~/.bashrc << 'EOF'
export QAIRT_SDK_ROOT=$HOME/qairt/2.48.0.260626
export QNN_SDK_ROOT=$HOME/qairt/2.48.0.260626
EOF
```

### 9d. Build llama.cpp with Hexagon backend

```bash
git clone https://github.com/ggml-org/llama.cpp.git ~/llama.cpp
cd ~/llama.cpp
cp ~/ubuntu-surface-pro-11/npu/CMakeUserPresets.json .

export HEXAGON_SDK_ROOT=$QNN_SDK_ROOT
export HEXAGON_TOOLS_ROOT=$QNN_SDK_ROOT/bin/x86_64-linux-clang

cmake -B build-snapdragon --preset arm64-linux-snapdragon -DGGML_HEXAGON=ON
cmake --build build-snapdragon --config Release -j$(nproc)
```

### 9e. Run on the NPU (HTP0 device)

```bash
export LD_LIBRARY_PATH="\
$PWD/build-snapdragon/bin:\
$QNN_SDK_ROOT/lib/aarch64-ubuntu-gcc9.4:\
$QNN_SDK_ROOT/lib/hexagon-v73/unsigned:$LD_LIBRARY_PATH"
export ADSP_LIBRARY_PATH="\
$QNN_SDK_ROOT/lib/hexagon-v73/unsigned:\
/usr/share/fastrpc:/usr/lib/dsp:/usr/lib/rfsa/adsp"

cd build-snapdragon

# Reset the CDSP remoteproc to defragment the rpcmem heap before loading
# (skip this for small models like 1B, but required for 3B+ models)
echo stop | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 2
echo start | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 3

# Offload all layers to the NPU
./bin/llama-cli \
    -m ~/model.gguf \
    --device HTP0 -ngl 99 \
    -p "The capital of France is" -n 16
```

Verified benchmarks (all layers on HTP0):

| Model | Size | Generation t/s | Notes |
| --- | --- | --- | --- |
| Llama-3.2-1B-Instruct-Q4_0 | 738 MB | 48.8 | General chat; no CDSP reset needed |
| VibeThinker-1.5B Q4_K_M | ~1.2 GB | 45.0 | Math/reasoning; CDSP reset recommended |
| Qwen2.5-Coder-3B-Instruct-Q4_0 | 1.8 GB | 21.3 | Code specialist; CDSP reset required |
| Gemma-4-E2B-it QAT mobile | 2.0 GB | — | Newest (Gemma 4, April 2026); multimodal; CDSP reset required |

<details>
<summary>Sample output — code generation on HTP0 (click to expand)</summary>

Prompt: `write tiny prime number generator in js, just code, no comments`

```javascript
function isPrime(n) {
    if (n < 2) {
        return false;
    }
    for (let i = 2; i < n; i++) {
        if (n % i === 0) {
            return false;
        }
    }
    return true;
}

function tinyPrimeGenerator() {
    let num = 2;
    while (true) {
        if (isPrime(num)) {
            yield num;
        }
        num++;
    }
}

const generator = tinyPrimeGenerator();
for (let _ = 0; _ < 10; _++) {
    console.log(generator.next().value);
}
```

```
[ Prompt: 307.4 t/s | Generation: 45.0 t/s ]
```

</details>

### 8f. Interactive chat on the NPU

Four interactive chat scripts are included, each with a different model:

```bash
./scripts/test_llama.sh    # Llama-3.2-1B — general chat, fastest (~48 t/s)
./scripts/test_vibe.sh     # VibeThinker-1.5B — math/reasoning (~45 t/s)
./scripts/test_gemma.sh    # Gemma-4-E2B-it — multimodal, newest (Gemma 4)
./scripts/test_qwen.sh     # Qwen2.5-Coder-3B — code specialist (~21 t/s)
```

Each script auto-downloads the model if missing, resets the CDSP remoteproc, loads all layers onto HTP0 (`-ngl 99`), and drops into an interactive chat prompt. Type your messages, Ctrl+C to exit.


---

## Verification checklist

```bash
# Kernel
uname -r

# Wi-Fi
rfkill list                                # no blocks
iw dev                                     # wlP4p1s0 associated

# Audio
systemctl status sp11-wsa-routing.service  # active, "WSA speaker routing enabled"
speaker-test -D hw:X1E80100Microso,1 -c 4 -t sine -f 440 -l 1

# Touchscreen
cat /proc/bus/input/devices | grep -A5 "Touchscreen"

# Pen
systemctl status sp11-pen-daemon.service   # active, "FINGER TOUCH MODE"
cat /proc/bus/input/devices | grep -A8 "Virtual Stylus"

# Suspend
systemctl status sp11-lid-backlight.service  # active
sp11-fix-cpuidle-s2idle status               # cpu-sleep-0: 0/12 disabled (runtime)
ls /usr/lib/systemd/system-sleep/sp11-cpuidle-s2idle  # hook installed
cat /sys/power/suspend_stats/success         # increments per successful suspend

# NPU
ls /dev/fastrpc-*                           # adsp, cdsp, cdsp-secure
systemctl status hexagonrpcd.service         # active
# Test NPU inference on HTP0 (interactive chat):
#   ./scripts/test_llama.sh    # Llama-3.2-1B (~48 t/s)
#   ./scripts/test_gemma.sh    # Gemma-4-E2B-it (multimodal)
```

---

## Repository structure

```
ubuntu-surface-pro-11/
├── README.md               This file (full installation guide)
├── install.sh              One-shot installer (all components; see Quick install above)
├── INDEX.md                Document index
├── WIFI.md SOUND.md TOUCHSCREEN.md PEN.md SUSPEND.md NPU.md
├── scripts/                All installation, troubleshooting & NPU chat scripts (17 files)
├── pen-daemon/             Hybrid pen/touch daemon source (sp11-pen-daemon.c)
├── systemd/                systemd unit files + drop-in overrides (6 services)
├── system-sleep/           systemd system-sleep hooks (cpuidle s2idle fix)
├── udev/                   udev rules (fastrpc + pen symlink)
├── audio/                  AudioReach topology binary + UCM2 configs
├── kernel-patches/         All kernel patches (18 patches: touchscreen + wifi + dmic)
├── grub/                   GRUB configuration drop-ins
├── apt/                    apt post-invoke hook (wifi board file)
└── npu/                    llama.cpp CMakeUserPresets.json (Snapdragon build)
```

---

## References & Acknowledgements

This project builds on the work of the Snapdragon X Elite Linux community. The kernel patches, audio configuration, and bring-up methodology are derived from the following sources:

### Kernel

- **[Jens Glathe](https://github.com/jglathe)** — Continual kernel development for Snapdragon X Elite devices. The patched kernel in this repo is built from [`jglathe/linux_ms_dev_kit`](https://github.com/jglathe/linux_ms_dev_kit) (tag `jg/ubuntu-qcom-x1e-7.1.3-jg-1`), which provides the qcom-x1e kernel tree with X1E80100 support.

### Surface Pro 11 bring-up

- **[Dale Whinham — `dwhinham/linux-surface-pro-11`](https://github.com/dwhinham/linux-surface-pro-11)** — Arch Linux bring-up for the Surface Pro 11. The ath12k rfkill bypass patch and Wi-Fi MAC address patch in this repo are adapted from Dale's kernel patches. His [What's Working](https://github.com/dwhinham/linux-surface-pro-11#whats-working) tracker was an essential reference for feature status.

### Audio

- **[`linux-msm/audioreach-topology`](https://github.com/linux-msm/audioreach-topology)** — Source for the AudioReach DSP topology. The topology binary in `audio/firmware/` is built from this repo's `X1E80100-CRD.m4` template, customized for the Surface Pro 11.
- **[Srinivas Kandagatla (Linaro)](https://github.com/skandagatla)** — Original UCM2 configuration for X1E80100 devices. The `Surface11-HiFi.conf` UCM verb is based on his work.

### NPU / AI

- **[Qualcomm AI Engine Direct (QAIRT SDK)](https://www.qualcomm.com/developer/software/qualcomm-ai-engine-direct)** — QNN runtime libraries and tools used by the Hexagon backend.
- **[`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp)** — Inference engine with the `GGML_HEXAGON` backend for Qualcomm DSP offload. The `CMakeUserPresets.json` in `npu/` defines the Snapdragon build configuration.

### Firmware

- **[`WOA-Project/Qualcomm-Reference-Drivers`](https://github.com/WOA-Project/Qualcomm-Reference-Drivers)** — Public mirror of Qualcomm Windows driver CABs. The `sp11-grab-fw.sh` script downloads ADSP/CDSP firmware (`.mbn`, `.jsn`) from this repo's `Surface/8380_DEN` directory.
- **[`qca/qca-swiss-army-knife`](https://github.com/qca/qca-swiss-army-knife)** — Qualcomm's `ath12k-bdencoder` tool, used by `sp11-wifi-board-fixup.sh` to extract the WCN7850 board data file.

### Community

- **[Ubuntu Snapdragon X Elite Discourse](https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800)** — Ubuntu community discussion for Snapdragon X Elite devices.
- **[linux-surface](https://github.com/linux-surface)** — Surface device Linux community (Surface Laptop 7 work was used as reference).

---

## License

Kernel patches retain their upstream licenses (GPL-2.0). The pen daemon source is GPL-2.0-or-later. Scripts are BSD-3-Clause unless otherwise noted. Firmware and topology binaries are redistributable under their respective Qualcomm licenses.
