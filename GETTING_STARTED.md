# Getting Started — Fedora on the Surface Pro 11

A plain-language walkthrough for your **first** install. It hands off to
[README.md](README.md) (the complete reference) at every step, so you always
know where to go for the full detail.

## Before you start — read this part

This is a **hobbyist hardware bring-up project**, not a polished, one-click
distro. You are installing Linux on hardware Microsoft never officially
supported it on, using kernel patches and firmware extracted by the
community. Expect to:

- Use the terminal a lot.
- Hit something that doesn't work first try, and need to read a linked `.md`
  file to fix it.
- Reboot repeatedly (many steps here only take effect after a reboot).
- Keep Windows installed, dual-boot, the whole time (explained below).

If that sounds unappealing, this isn't ready for you yet — check back later.
If it sounds like a fun weekend project, keep reading.

**What works today:** Wi-Fi, Bluetooth, touchscreen (single-touch), the Slim
Pen 2, speakers + microphone, suspend/resume, all onboard sensors, and NPU AI
inference. **What doesn't:** cameras (front/rear) and status LEDs — see
[CAMERA.md](CAMERA.md) if you're curious why, or want to help fix it.
Multi-touch gestures and USB4/Thunderbolt external displays are also not
there yet. Check the [Status Summary table in README.md](README.md#status-summary)
for the current, authoritative list before you start, since it changes as
work continues.

**Target hardware:** Surface Pro 11, OLED display, 16 GB RAM, 1 TB NVMe, no
5G modem (SKU `Surface_Pro_11th_Edition_2076`, Snapdragon X1E80100). Other
configurations (5G model, X1P CPU, LCD panel) are untested by this project —
you're the test pilot if you try one.

**Time required:** Budget a free afternoon for the base install (Fedora +
`install.sh --all`), plus another hour if you also want to build the patched
kernel or set up NPU inference. It is *not* a 15-minute install.

## Step 0 — Why keep Windows?

Two of this project's hardest-won pieces — the ADSP/CDSP DSP firmware (used
for audio and NPU) and the pre-parsed sensor registry — are extracted
directly from your Windows installation the first time, not downloaded from
the internet. If you erase Windows first, you lose your only source for
them. Shrink the Windows partition to make room for Fedora; don't delete it.

If you've already erased Windows: firmware may still be available via
[WOA-Project's Qualcomm-Reference-Drivers](https://github.com/WOA-Project/Qualcomm-Reference-Drivers)
mirror for DSP firmware, but the sensor registry ([SENSORS.md](SENSORS.md))
currently has no known alternative source — that part will not work.

## Step 1 — Install Fedora

Full detail: [README.md → Prerequisites](README.md#prerequisites).

1. In Windows, use Disk Management (or `diskmgmt.msc`) to shrink the main
   partition and free up at least **60 GB** (more if you plan to build the
   kernel or download NPU models — those alone can use 10–15 GB).
2. Download the **aarch64 Fedora Workstation Live ISO** (44+) from
   [Fedora Media Writer](https://fedoraproject.org/workstation/download) and
   write it to a 16 GB+ USB-C flash drive.
3. Reboot into the Surface UEFI (hold **Volume-Up + Power**) and **disable
   Secure Boot**.
4. Boot from the USB drive. At the GRUB menu, press `e` and append to the
   kernel line:
   ```
   clk_ignore_unused pd_ignore_unused systemd.tpm2_wait=0 modprobe.blacklist=qcom_q6v5_pas
   ```
   then `Ctrl+X` / `F10` to boot. Without this the live session likely won't
   boot at all, or will hang for ~90 seconds on TPM2.
5. Run the installer. Choose **"Install alongside"** (not "Erase disk") so
   Windows survives. Install into the free space you made in step 1.
6. Reboot into your new Fedora install (remove the USB drive first). At the
   GRUB menu, apply the same kernel args again for this first boot — you
   haven't made them permanent yet.
7. Log in, open a terminal, and run Fedora's official post-install
   workarounds (full detail on the
   [Fedora Snapdragon WoA wiki](https://fedoraproject.org/wiki/Snapdragon_WoA_Laptop_Install)):
   ```bash
   sudo rm -f /etc/modprobe.d/anaconda-denylist.conf
   echo scmi-cpufreq | sudo tee /etc/modules-load.d/scmi-cpufreq.conf
   sudo grubby --update-kernel=ALL --args="systemd.tpm2_wait=0"
   ```

At this point you have plain Fedora booting on the Surface Pro 11, with
Wi-Fi/audio/sensors/etc. still not working — that's expected, and what the
rest of this guide fixes.

## Step 2 — Clone this repo and install build dependencies

```bash
sudo dnf install -y git curl python3 zstd m4 alsa-utils gcc gcc-c++ make cmake ninja-build kernel-devel kernel-headers
git clone <this-repo-url> ~/fedora-surface-pro-11
cd ~/fedora-surface-pro-11
```

(Wi-Fi won't work yet — use USB-C Ethernet, or tether from your phone, for
this and the next step.)

## Step 3 — Build and install the patched kernel

This is the step that actually enables the touchscreen, Wi-Fi rfkill bypass,
and correct microphone clock — the stock Fedora WoA kernel doesn't have
these patches yet.

```bash
sudo ./install.sh --kernel
```

Expect **~20–30 minutes** and **~15–20 GB** of disk space for the build.
Grab a coffee. When it finishes:

```bash
sudo reboot
```

After reboot, confirm you're on the patched kernel:

```bash
uname -r
# should show something ending in -sp11v2-qcom-x1e
```

If this step fails or you'd rather understand each part first, the fully
manual version is in [README.md → Step 1](README.md#step-1--build-and-install-the-patched-kernel).

## Step 4 — Everything else, in one command

```bash
sudo ./install.sh
```

This installs GRUB kernel arguments, Wi-Fi board data, audio firmware +
routing, the pen daemon, suspend/resume fixes, sensors, and NPU prerequisites
— all the remaining phases described in [README.md](README.md), steps 2
through 9. It takes a few minutes (NPU model download aside) and prints a
`✓`/`⚠` line per phase so you can see what succeeded.

Reboot when it's done — several phases (audio, sensors, new kernel args)
only take effect after a reboot:

```bash
sudo reboot
```

Prefer to install one piece at a time, understand what each does, or skip
something (e.g. NPU, if you don't want a ~2 GB QAIRT SDK download)? Run
`sudo ./install.sh --list` to see the phases, and read the matching section
of [README.md](README.md) — each phase has a "Step N" section there with the
same commands `install.sh` runs, explained individually.

## Step 5 — Verify

Work through [README.md → Verification checklist](README.md#verification-checklist).
The short version:

```bash
rfkill list                                 # Wi-Fi: no blocks
nmcli device wifi list                      # Wi-Fi: scan results
speaker-test -D hw:X1E80100Microso,1 -c 4 -t sine -f 440 -l 1   # Audio: you hear a tone
cat /proc/bus/input/devices | grep -A5 Touchscreen   # Touchscreen: device present
systemctl status sp11-pen-daemon.service    # Pen: active, "FINGER TOUCH MODE"
sensors/sp11-sensor-read                    # Sensors: all 13 read successfully
```

If something doesn't check out, the component's `.md` doc (linked from the
[README status table](README.md#status-summary)) has the deeper explanation
and a troubleshooting angle — these docs were written from the actual
bring-up process, including the dead ends, so they're the best source for
"why doesn't X work" specifically on this hardware.

## Common first-timer snags

- **Live USB won't boot / hangs at a black screen** — you likely missed the
  GRUB kernel-argument edit in Step 1.4. It has to be re-typed at every boot
  until Step 1.7 makes it permanent.
- **No Wi-Fi in the live installer** — expected; there's no board-data fix
  applied yet at that point. Use wired/USB-C Ethernet or tethering.
- **`install.sh --kernel` runs out of disk space** — you need ~15–20 GB free
  for kernel build artifacts alone, on top of the OS and Windows partition.
  Check with `df -h /home`.
- **Audio is silent after `install.sh`** — did you reboot? The DSP boot-race
  fix and PipeWire sink both need one. See [SOUND.md](SOUND.md) if it's
  still silent after that.
- **Suspend doesn't come back / hangs** — read [SUSPEND.md](SUSPEND.md)
  before filing this as "broken"; there's a known root cause and a fix
  `install.sh --suspend` already installs, but the mechanism (lid-close →
  60s → suspend, power button to wake) is easy to misread as "suspend
  doesn't work" if you were expecting instant lid-close suspend.
- **Camera doesn't work** — it doesn't for anyone yet. See
  [CAMERA.md](CAMERA.md); this isn't something you missed a step for.

## Getting further help / contributing back

- Read the relevant `.md` doc first — most "is this broken" questions are
  answered there, often with the specific error message you're seeing.
- If you get a component working that's marked partial/broken, or you learn
  something during bring-up (e.g. identify the camera sensor — see
  [CAMERA.md](CAMERA.md)), please contribute it back. This whole project
  exists because previous bring-up work (Arch, then Ubuntu) was documented
  well enough for the next person to build on.
