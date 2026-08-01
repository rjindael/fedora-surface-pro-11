# Cameras — Surface Pro 11 (status: not working, upstream groundwork in progress)

> **This is a bring-up research doc, not a solution.** Nobody in the Surface
> Pro 11 Linux community — this project, [dwhinham/linux-surface-pro-11](https://github.com/dwhinham/linux-surface-pro-11),
> or the upstream kernel patch series — has working cameras yet. If you came
> here hoping to `sudo ./install.sh --camera` your way to a working webcam,
> that phase doesn't exist and shouldn't be faked. What follows is what's
> actually known, so whoever picks this up next doesn't start from zero.

## What we don't know yet

- **Which sensor(s)** the Surface Pro 11 uses (front ~1440p webcam, and
  presumably a rear camera). Microsoft doesn't publish this, and no
  teardown/FCC filing/Windows driver inspection has been done against this
  specific unit as part of this project. Common Copilot+ PC front sensors in
  this class are OmniVision parts (e.g. `OV02C10`), but that is **an industry
  pattern, not a confirmed fact for this device** — do not assume it without
  checking the actual hardware.
- **The devicetree wiring** for camera on the Surface Pro 11 board
  (`arm64-dts-qcom-x1e80100-microsoft-denali*.dts`) — CSIPHY lane mapping,
  sensor I2C address, regulators/GPIOs/clocks the sensor needs, `port`/
  `endpoint` graph linking sensor → CSIPHY → CAMSS. None of this exists in
  any tree referenced by this project.
- **Whether a Linux driver for the sensor exists at all.** Some OmniVision
  parts have upstream V4L2 drivers (`ov02c10`, `ov08x40`, etc. under
  `drivers/media/i2c/`), others (especially ones bundled only with Windows
  IPU/ISP stacks) do not.

## What we do know (as of 2026-07)

### The SoC-side ISP driver is landing upstream — but it's generic, not board-specific

Qualcomm's CAMSS (Camera Subsystem) — the CSIPHY/CSID/ISP block — has
platform support for `x1e80100` merging into mainline:

- `media: dt-bindings: qcom,x1e80100-camss` — devicetree binding for the SoC's
  CAMSS instance (CSIPHY, CSID, CSID-lite, CSID wrapper).
- Bryan O'Donoghue's **`[PATCH v8 00/18] Add dt-bindings and dtsi changes for
  CAMSS on x1e80100 silicon`** (LKML, 2026-02) adds the driver-side plumbing
  and SoC `.dtsi` node for CAMSS on X1E80100.

This is necessary but nowhere near sufficient: it wires up the SoC's camera
*controller*, not any specific board's camera *sensor*. Think of it as "the
CPU can now talk to a camera ISP" — the "which wires go where on the Surface
Pro 11, and what chip is on the other end" part hasn't been done by anyone.

### The Surface Pro 11 devicetree patch series does not touch camera

The mainline **`arm64: dts: qcom: Add support for Surface Pro 11`** series
(9 patches: display panel, QSEECOM, `aggregator_registry`, base `.dts`,
ath12k rfkill, `x1e80100-denali` rfkill disable, dt-bindings doc, DP link-rate
workaround) has zero CAMSS/CSIPHY/sensor content. Camera is simply out of
scope for that series.

### The original Arch bring-up (dwhinham) never got past "not working" either

`linux-surface-pro-11`'s status table lists cameras as ❌ with no notes, same
as here. No sensor identification or devicetree work has surfaced from that
project either.

## What actual progress would look like

In rough dependency order:

1. **Identify the sensor(s).** With the Windows partition still intact (this
   project's install process deliberately keeps it — see README
   Prerequisites), the fastest path is *not* teardown but software
   inspection:
   - Windows Device Manager → camera device → Hardware Ids (gives an ACPI
     `\_SB.PEP0...` or `MSFT...` id, sometimes a sensor part number directly).
   - `Windows/System32/DriverStore/FileRepository/` on the Windows partition
     for a matching sensor `.inf` (the same technique this project already
     uses for sensors — see [SENSORS.md](SENSORS.md) — works for camera INFs
     too; look for `.inf` files referencing `ov`, `imx`, `hi846`, `gc`-prefixed
     sensor names, which are the common vendors in this segment).
   - ACPI dump (`sudo acpidump -o acpi.dat` on Fedora once booted to Linux; or
     from Windows via `WinDbg`/`RWEverything`) — the `_HID`/`_CID` of the
     camera's ACPI or devicetree-equivalent node names the sensor driver
     Windows loads.
2. **Confirm a Linux driver exists** for that sensor (check
   `drivers/media/i2c/` in mainline, or the sensor vendor's out-of-tree
   repos). If none exists, this becomes a driver-writing project, not just a
   devicetree one.
3. **Write the board devicetree nodes** once CAMSS + CSIPHY are in the
   X1E80100 `.dtsi` (patch series above): sensor I2C node with
   `compatible`, regulators, clocks, reset/powerdown GPIOs (pulled from the
   ACPI/Windows driver package), plus the CSIPHY/CSID port/endpoint graph
   connecting it to CAMSS.
4. **Test incrementally on real hardware** — `v4l2-ctl --list-devices`,
   `media-ctl -p`, `yavta`/`qcam` for raw frame capture — before expecting a
   GUI camera app to work. This is the step that cannot be done from a
   description; it requires the physical Surface Pro 11 and iterative
   `dtb`/driver changes with reboots between attempts.
5. **Status LEDs** (mentioned alongside cameras in the status table) are
   likely on the same power rail/GPIO group as the sensor and would probably
   fall out of step 3, but haven't been investigated independently.

## If you want to pick this up

- Start with sensor identification (step 1) — it's pure software work,
  doable without deep kernel experience, and unblocks everything else.
  Please update this file with what you find (sensor part number, ACPI HID,
  I2C address) even if you don't get further — that alone saves the next
  person days.
- Track the upstream CAMSS series for X1E80100 landing in mainline; once
  merged, the board-devicetree step (3) becomes realistic to attempt.
- The [Qualcomm Camera Subsystem driver docs](https://docs.kernel.org/admin-guide/media/qcom_camss.html)
  and an already-working X1E80100 CAMSS board (once one exists upstream —
  none does yet as of this writing) are the best reference for the node
  structure step 3 needs.

## References

- Bryan O'Donoghue, *[PATCH v8 00/18] Add dt-bindings and dtsi changes for CAMSS on x1e80100 silicon*, LKML, 2026-02.
- *dt-bindings: media: Add qcom,x1e80100-camss*, linux-arm-msm patchwork.
- [Qualcomm Camera Subsystem driver — kernel docs](https://docs.kernel.org/admin-guide/media/qcom_camss.html)
- [Linaro — X1e80100 mainline status tracker](https://linaro.github.io/msm/soc/x1e80100)
- [dwhinham/linux-surface-pro-11](https://github.com/dwhinham/linux-surface-pro-11) — same ❌ status, no additional notes there either.
