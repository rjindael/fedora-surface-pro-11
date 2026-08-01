# Fedora on Surface Pro 11 (Snapdragon X Elite) — Documentation Index

This repository contains everything needed to enable Wi-Fi, touchscreen, stylus, audio, suspend, and NPU AI on a Surface Pro 11 (Snapdragon X Elite / X1E80100) running Fedora, from a stock install.

## Documents

| Document | Topic | Status | Summary |
| --- | --- | --- | --- |
| [README.md](README.md) | Full installation guide | Complete | Step-by-step installation of all components from a stock Fedora system |
| [GETTING_STARTED.md](GETTING_STARTED.md) | First-time installer walkthrough | Complete | Plain-language guide for a first install, hands off to README.md |
| [WIFI.md](WIFI.md) | Wi-Fi (WCN7850 / ath12k) | Working | Kernel rfkill bypass + WCN7850 board data file extraction |
| [SOUND.md](SOUND.md) | Audio (speakers + microphone) | Partially working | DSP firmware, AudioReach topology, UCM2 config, boot-race fix, PipeWire sink |
| [TOUCHSCREEN.md](TOUCHSCREEN.md) | Touchscreen (HID-over-SPI) | Working (single-touch) | SPI/QSPI kernel patches, Denali DTS node, standard HID single-touch |
| [PEN.md](PEN.md) | Stylus (Surface Slim Pen 2) | Working | Hybrid HEAT/uinput auto-switching daemon, udev symlink, systemd service |
| [SUSPEND.md](SUSPEND.md) | Suspend / Resume | Partially working | Lid-switch backlight control, power-button-only wake, SSAM debug logging, DSP hooks |
| [NPU.md](NPU.md) | NPU AI (Hexagon DSP / QNN) | Working | FastRPC permissions, QNN SDK, llama.cpp Hexagon backend, HTP0 offload (48 t/s @ 1B, 21 t/s @ 3B with CDSP reset) |
| [SENSORS.md](SENSORS.md) | Sensors (accelerometer, gyro, mag, ALS) | Working | SSC/QMI via hexagonrpcd, pre-parsed registry from Windows, custom hexagonrpcd, libssc |
| [CAMERA.md](CAMERA.md) | Cameras | Not working | Research doc: upstream CAMSS status, what's needed, how to help |

## Repository Structure

```
fedora-surface-pro-11/
├── README.md                           Full installation guide (start here)
├── GETTING_STARTED.md                  First-time installer walkthrough
├── INDEX.md                            This file
├── WIFI.md                             Wi-Fi findings and solution
├── SOUND.md                            Audio findings and solution
├── TOUCHSCREEN.md                      Touchscreen findings and solution
├── PEN.md                              Pen/stylus findings and solution
├── SUSPEND.md                          Suspend/resume findings and solution
├── SENSORS.md                          Sensor setup (SSC, hexagonrpcd, libssc)
├── CAMERA.md                           Camera bring-up research (not working)
├── scripts/                            Installation and troubleshooting scripts
│   ├── sp11-grab-fw.sh                 Download DSP firmware from Windows CABs
│   ├── sp11-wifi-board-fixup.sh        Extract WCN7850 board data file
│   ├── sp11-enable-wsa-routing.sh      Enable WSA speaker routing after DSP load
│   ├── sp11-fix-audio-boot-race.sh     Permanent audio boot-race fix installer
│   ├── sp11-pipewire-speaker-sink.sh   PipeWire manual speaker sink
│   ├── sp11-audio-topology.sh          Build AudioReach topology from source
│   ├── sp11-bluetooth-mac.sh           Bluetooth MAC address configuration
│   ├── sp11-lid-backlight              Lid-switch backlight/suspend Python daemon
│   ├── sp11-enable-suspend-debug       Suspend debug logging enabler
│   ├── troubleshoot-sp11-wifi-rfkill.sh  WiFi rfkill diagnostics
│   ├── troubleshoot-sp11-audio.sh      Audio diagnostics
│   ├── test_vibe.sh                   NPU chat — VibeThinker-1.5B (math/reasoning)
│   ├── test_llama.sh                  NPU chat — Llama-3.2-1B-Instruct
│   ├── test_qwen.sh                   NPU chat — Qwen2.5-Coder-3B-Instruct
│   └── test_sensors.sh                 Test all sensors via SSC/QMI
├── pen-daemon/
│   └── sp11-pen-daemon.c               Hybrid pen/touch daemon source (compile to binary)
├── systemd/                            systemd unit files
│   ├── sp11-pen-daemon.service
│   ├── sp11-wsa-routing.service
│   ├── sp11-pipewire-restart.service
│   ├── sp11-lid-backlight.service
│   ├── sp11-wifi-board-fixup.service   Re-extracts board.bin on firmware changes
│   ├── sp11-wifi-board-fixup.path      Watches firmware dir, triggers the above
│   ├── sensors-platform-info.service   Platform ID files for hexagonrpcd
│   └── hexagonrpcd-sensors.service     Custom hexagonrpcd early-start service
├── udev/                               udev rules
│   ├── 99-fastrpc.rules                FastRPC NPU device permissions
│   └── 99-sp11-pen.rules               Stable pen device symlink
├── audio/
│   ├── firmware/
│   │   └── X1E80100-Microsoft-Surface-Pro-11-tplg.bin   AudioReach topology
│   └── ucm/                            ALSA UCM2 configuration
│       ├── MICROSOFT-Surface-Pro-11.conf
│       ├── Surface11-HiFi.conf
│       └── x1e80100.conf
├── kernel-patches/                     All kernel patches for SP11
│   ├── sp11-touchscreen/               SPI/QSPI/HID-over-SPI + DTS node (15 patches)
│   ├── rfkill-wifi-mac/                ath12k rfkill bypass + devicetree MAC (2 patches)
│   └── dmic-clock/                     2.4 MHz DMIC clock (1 patch)
├── grub/                               Kernel cmdline args (applied via grubby) + GRUB timeout config
│   ├── sp11-x1e-cmdline.args
│   └── sp11-default-grub.conf
├── npu/
│   └── CMakeUserPresets.json           llama.cpp Snapdragon build presets
└── sensors/
    ├── sns_reg.conf                    Sensor registry config template
    ├── sp11-sensor-read.c              Fast sensor reader (libssc API, ~1s)
    └── sp11-sensor-read                Compiled binary

## Quick Start

Read [README.md](README.md) for the full end-to-end guide. Each component document covers the technical findings, the problem, and the solution in depth.
