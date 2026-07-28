# Touchscreen — Surface Pro 11 (HID-over-SPI)

## Hardware

| Component | Details |
| --- | --- |
| Device | HID-over-SPI digitizer |
| Vendor ID | `045E` (Microsoft) |
| Product ID | `0C83` |
| Bus | GENI SPI (`spi@a88000` / `a88000.spi`) |
| HID modes | Standard (`05 00`) and HEAT (`05 01`) |

## Problem

Three blockers in the stock kernel:

1. **SPI controller disabled** — UEFI firmware DTB marks `spi@a88000` as `disabled`
2. **Missing QSPI support** — `spi-geni-qcom` lacks 1-4-4 quad-SPI mode
3. **Missing HID-over-SPI stack** — no `spi_hid_of` driver

## Solution

### Kernel patches (15 patches in `kernel-patches/sp11-touchscreen/`)

| Patches | Purpose |
| --- | --- |
| `0001-dma-qcom-gpi-Add-QSPI-protocol-support.patch` | QSPI DMA protocol |
| `0002-spi-geni-qcom-Add-QSPI-1-4-4-mode-support.patch` | QSPI 1-4-4 mode |
| `0003-hid-spi-v4-01` through `0003-hid-spi-v4-11` | Complete HID-over-SPI driver stack |
| `0004-arm64-dts-qcom-x1-denali-Add-touchscreen-node.patch` | Denali DTS touchscreen node |
| `0005-sp11-touchscreen-update-annotations.patch` | Build annotations |

After patching: GENI SPI enabled → GPI DMA provides QSPI → `spi-geni-qcom` in 1-4-4 mode → HID-over-SPI probes `045E:0C83` → `hid-generic` creates input device → single-touch works.

## Current State

- **Working:** Single-touch (tap, drag, select, scroll)
- **Not working:** Multi-touch (pinch-to-zoom, two-finger scroll) — requires HEAT mode custom driver

## Verification

```bash
cat /proc/bus/input/devices | grep -A8 "045E:0C83"
ls -la /dev/sp11-pen
```

## Files

All patches in `kernel-patches/sp11-touchscreen/` (15 files).
