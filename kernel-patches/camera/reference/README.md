# Reference driver source — not this project's own work

These files are **not written by this project**. They're saved here as
reference material because they're directly relevant to Surface Pro 11
camera bring-up and the upstream location they came from could move, get
merged/closed, or be force-pushed away.

## Provenance

- **Source:** [linux-surface/linux-surface#2153](https://github.com/linux-surface/linux-surface/issues/2153)
  and [linux-surface/linux-surface#2156](https://github.com/linux-surface/linux-surface/pull/2156)
  (branch `djmulder/linux-surface@feature/surface-pro-10-cameras`,
  `patches/7.0/0013-cameras.patch`, fetched 2026-08).
- **Authors:** `imx681.c` — Andre Gilerson (`andre.gilerson@gmail.com`,
  GitHub `@AndreGilerson`), for the **Intel/Lunar Lake SKU** of "Surface
  Pro 11". Ported to Surface Pro 10 (Intel/Meteor Lake) and the
  `ov13858.c` reset/regulator/clock additions by GitHub `@djmulder`.
- **License:** `imx681.c` carries `SPDX-License-Identifier: GPL-2.0` and
  `MODULE_LICENSE("GPL")` — compatible with this project's existing
  kernel-patches licensing (see the root README's License section).

## Why this matters for a *Qualcomm* Surface Pro 11 (this project's target)

Microsoft's "Surface Pro 11" / "11th Edition" name covers **two different
SKUs**: an Intel Core Ultra (Lunar Lake) model and the Qualcomm Snapdragon
X Elite (X1E80100) model this project targets. This driver work is for the
**Intel** SKU (confirmed: PR #2156 explicitly measured "Surface Pro 11
(LNL, 969.6 MHz D-PHY)" — LNL = Lunar Lake). It is not a driver for the
device this project targets, and won't bind or work as-is.

What *does* transfer, because the physical sensor silicon and — per the
ACPI extraction in [CAMERA.md](../../../CAMERA.md) — the same camera module
selection (OV13858 rear, IMX681 front, same ACPI IDs even) are shared
across both SKUs:

- **`imx681.c` already has real devicetree support**
  (`compatible = "sony,imx681"`, proper `.of_match_table`), confirmed
  regulator names (`avdd`, `dvdd`, `dovdd`), reset-gpio handling, and a
  register init sequence reverse-engineered from an actual Windows I2C
  trace of Surface Pro 11 hardware — chip ID register `0x0016` → `0x0681`,
  full mode/crop/binning/PLL register sequence, and a documented analog-gain
  inversion quirk (hardware code 0 = 16×, not 1×).
- **The `ov13858.c` patch** adds reset-GPIO + regulator + clock handling
  this driver was previously missing entirely — needed regardless of
  platform, since `ov13858.c` had no power-sequencing code of any kind
  before this.
- **What does NOT transfer**: the `ipu-bridge.c`, `int3472/*.c` files (all
  Intel-IPU6-specific bridge/power-controller code — irrelevant to Qualcomm
  CAMSS) and the hardcoded SP10 clock/PLL values in `imx681.c`
  (`IMX681_LINK_FREQ = 380800000LL`, `0x0307/0x030D` register values) —
  those need to be re-verified against the *Qualcomm* SP11's actual clock
  config, not assumed identical. The Intel-SP11 figure of 969.6 MHz
  (mentioned in the issue thread, not present in these saved files) is a
  reasonable first guess given it's the same physical camera module, not a
  confirmed fact for the Qualcomm board.

See [CAMERA.md](../../../CAMERA.md) and
[CAMERA_BRINGUP.md](../../../CAMERA_BRINGUP.md) for how this fits into the
overall bring-up picture and what's still unknown.

## Files

- `imx681.c` — full driver, as fetched (932 lines).
- `ov13858-reset-regulator-clock.patch` — the diff adding power sequencing
  to the existing mainline `ov13858.c`.
