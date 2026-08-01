# Wi-Fi — Surface Pro 11 (WCN7850 / ath12k)

## Hardware

| Component | Value |
| --- | --- |
| Chip | Qualcomm WCN7850 (FastConnect 7800) |
| Bus | PCIe |
| Linux driver | `ath12k` (module `ath12k_wifi7_pci`) |
| Interface | `wlP4p1s0` |
| Firmware dir | `/lib/firmware/ath12k/WCN7850/hw2.0/` |

PCI identification: `vendor=17cb, device=1107, subsystem-vendor=17cb, subsystem-device=1107, qmi-chip-id=2, qmi-board-id=255`

## Problem

### 1. RFkill hard-blocked by UEFI firmware

On UEFI ARM64 systems, the firmware provides the devicetree and there is no way to add a `disable-rfkill` property. The UEFI firmware sets the rfkill hard-block flag, and `ath12k_core_rfkill_config()` respects it, leaving the radio permanently off.

### 2. Missing WCN7850 board data file

The `linux-firmware` package ships `board-2.bin` (a multi-board container) but may not include an exact match for `qmi-board-id=255`. The driver needs `board.bin` — a single board data file matching the hardware — or it fails to initialize the PHY.

## Solution

### Kernel patch: unconditional rfkill bypass

`drivers/net/wireless/ath/ath12k/core.c` — `ath12k_core_rfkill_config()` returns 0 unconditionally:

```c
/* Surface Pro 11: rfkill is hard-blocked by firmware, skip it */
return 0;
```

Patch: `kernel-patches/rfkill-wifi-mac/0002-wifi-ath12k-Add-support-for-disabling-rfkill-via-dev.patch`

### Board data file extraction

Script `scripts/sp11-wifi-board-fixup.sh` extracts a compatible board entry from `board-2.bin` using the Qualcomm `ath12k-bdencoder` tool.

### systemd path-unit hook

`sp11-wifi-board-fixup.path` watches `/lib/firmware/ath12k/WCN7850/hw2.0/`
and re-runs the fixup whenever `linux-firmware` (or anything else) overwrites
`board-2.bin`. (Ubuntu's version of this project used an apt Post-Invoke
hook instead; dnf has no direct equivalent, so this watches the firmware
directory rather than package-manager events.)

## Verification

```bash
rfkill list              # no hard/soft blocks
iw dev                   # wlP4p1s0 associated
nmcli device wifi list   # scanning
```

## Files

| File | Purpose |
| --- | --- |
| `kernel-patches/rfkill-wifi-mac/0002-*.patch` | ath12k rfkill bypass |
| `kernel-patches/rfkill-wifi-mac/0004-*.patch` | devicetree MAC address |
| `scripts/sp11-wifi-board-fixup.sh` | Board data file extraction |
| `systemd/sp11-wifi-board-fixup.service` + `.path` | Re-extraction path-unit hook |
| `scripts/troubleshoot-sp11-wifi-rfkill.sh` | rfkill diagnostics |
