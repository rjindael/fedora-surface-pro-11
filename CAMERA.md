# Cameras — Surface Pro 11 (status: not working; hardware fully identified 2026-08)

> **This is a bring-up research doc, not a solution.** Nobody in the Surface
> Pro 11 Linux community — this project, [dwhinham/linux-surface-pro-11](https://github.com/dwhinham/linux-surface-pro-11),
> or the upstream kernel patch series — has working cameras yet. If you came
> here hoping to `sudo ./install.sh --camera` your way to a working webcam,
> that phase doesn't exist and shouldn't be faked. What follows is what's
> actually known, so whoever picks this up next doesn't start from zero.

## Confirmed hardware inventory (2026-08, from a real Surface Pro 11)

Everything in this section was pulled directly off a real unit — ACPI
`Get-PnpDevice`/`pnputil` enumeration, a full DSDT/SSDT disassembly
(`acpidump.exe` + `iasl.exe`), and the actual Windows DriverStore packages —
not inferred from other devices. This retires most of the "which sensor?"
uncertainty this doc used to lead with. Full raw data and the extraction
method are in [CAMERA_BRINGUP.md](CAMERA_BRINGUP.md); this is the distilled
result.

| Function | ACPI `_HID` | Part | Mainline Linux driver |
| --- | --- | --- | --- |
| ISP core | `QCOM0C25` | Qualcomm Spectra 695 (SC8380XP) | `qcom,x1e80100-camss` (landing, SoC-generic) |
| MIPI CSI controller | `QCOM0C98` | — (part of Spectra 695) | same CAMSS series |
| Camera platform (tuning loader) | `QCOM0C32` | — | n/a (Linux doesn't need this layer) |
| Flash/illuminator | `QCOM0C27` | — (see IR section) | unclear — see below |
| JPEG encoder | `QCOM0C33` | — | n/a for raw capture; needed only for HW JPEG |
| **Rear camera** | `OVTID858` (`VEN_OVTI&DEV_D858`) | **OmniVision OV13858**, 13MP | **`drivers/media/i2c/ov13858.c` exists**, but ACPI-match only — needs a small `of_device_id` patch (same pattern `ov02c10.c` already has) |
| **Front camera** | `SONY0681` (`VEN_SONY&DEV_0681`) | **Sony IMX681** | **No mainline driver found anywhere** (checked `drivers/media/i2c/Makefile` — no `imx681.o`; no known out-of-tree source either) |
| **IR camera (Windows Hello)** | `SMO55F0` (`VEN_SMO&DEV_55F0`) | **STMicroelectronics VD55G0** (see nuance below) | Mainline has `drivers/media/i2c/vd55g1.c` (`compatible = "st,vd55g1"`) — but that's the sibling **VD55G1** part, not confirmed to work with VD55G0 |

Two important corrections to earlier drafts of this doc:

- **OV02C10 (the Yoga Slim7x sensor) is not what's on this unit.** That
  earlier section is kept below because the Slim7x devicetree pattern is
  still the best structural reference for *how* to wire any sensor to this
  ISP — just not because it's the same sensor.
- **The Qualcomm ISP core (`QCOM0C25`/`QCOM0C98`/`QCOM0C32`/`QCOM0C33`)
  appears to be a shared reference design**, not Surface-specific: the exact
  same `ACPI\VEN_QCOM&DEV_0C32&SUBSYS_CRD08380` "Spectra 695 ISP Camera
  Platform Device" ID shows up in public driver listings for the **Lenovo
  Yoga Slim 7 14Q8X9 (83ED)** and **Samsung Galaxy Book4 Edge** — different
  OEMs, different sensor choices, same ISP core and ACPI ID scheme. Any
  CAMSS/devicetree work targeting this ISP core is likely to transfer
  across X1E80100 Copilot+ laptops generally, not just this one.

### What's still genuinely unknown

The one thing Windows' own ACPI tables do **not** expose: I2C bus, I2C
address, GPIO pins, and regulator names for the actual sensors. Unlike a
typical Intel IPU6 platform, `CAMS`/`CAMF`/`CAMI` (the sensor ACPI device
nodes) have **no `_CRS` resource method at all** — confirmed by reading the
disassembled DSDT directly. That wiring instead lives in proprietary binary
blobs (`SCFG_FRONT_MSHW0490.bin`, `SCFG_REAR_MSHW0491.bin`,
`SCFG_AUX_MSHW0492.bin`, found in the `surfacecam*sensor_extension8380.inf`
packages) whose format is undocumented — the same pattern this project
already hit with the sensor hub's `sns_reg` registry blobs (see
[SENSORS.md](SENSORS.md)), just not previously solved for camera. Getting
I2C address/GPIO/regulator mapping now realistically means either
reverse-engineering that blob format, or a live I2C bus scan + iterative
devicetree testing on real hardware (see [CAMERA_BRINGUP.md](CAMERA_BRINGUP.md)).

There's also a hardware-revision wrinkle: the ISP core's ACPI `_CRS` methods
(`MPCS`, `VFE0`) branch on an internal `\_SB.SDFE` value (`0x88` vs `0x9A`),
returning **different register/resource buffers** depending on which value
it reads — i.e. there are at least two distinct board revisions with
different ISP register layouts. Whoever writes the devicetree needs to
determine which `SDFE` value the target unit reports.

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
Pro 11, and what chip is on the other end" part hasn't been done by anyone
for this board specifically — but see the next section, because it's now
been done for a sibling board.

### A sibling X1E80100 laptop has real board-level camera work in flight

The **Lenovo Yoga Slim 7x** — a different OEM's X1E80100 Copilot+ PC, same
SoC family and same generation as the Surface Pro 11 — has an actual
in-review patch: **`[PATCH v8 17/18] arm64: dts: qcom: x1e80100-lenovo-yoga-slim7x:
Add ov02c10 RGB sensor on CSIPHY4`** (Bryan O'Donoghue / Christopher Obbard /
Aleksandrs Vinarskis, LKML, late Feb 2026, part of the same 18-patch CAMSS
series referenced above). This is a real, concrete, board-level example of
wiring an RGB sensor to X1E80100 CAMSS — the exact category of work this
board still needs. Confirmed details from the patch discussion:

- Sensor: **OmniVision OV02C10**, on **CSIPHY4**.
- Endpoint fragment (from review-thread quoting, real syntax, not invented):
  ```dts
  &camss {
      ports {
          port@3 {
              camss_csiphy4_inep0: endpoint@0 {
                  clock-lanes = <7>;
                  data-lanes = <0 1>;
                  remote-endpoint = <&ov02c10_ep>;
              };
          };
      };
  };
  ```
- Regulator naming went through review churn — reviewers caught that the
  first version copied `l7m`/`l2m`/`l4m` (the regulator rails used on the
  Lenovo T14s, a *different* X1E80100 board) instead of the Slim 7x's actual
  `l7b`/`l1m`/`l3m` rails. **This is the exact mistake to avoid copying
  Slim7x's own values wholesale onto the Surface Pro 11** — every X1E80100
  OEM board routes its own PMIC rails to the camera differently. Use the
  Slim7x patch as a *template for structure*, not a source of literal values.

As of this writing the patch (v8, part of an 18-patch series) had not yet
landed in mainline — treat it as "the best available structural reference,"
not "a merged, stable ABI to copy verbatim." Re-check its status before
starting; a merged version will be cleaner to crib from than any in-review
one. The concrete how-to for using this reference is in
[CAMERA_BRINGUP.md](CAMERA_BRINGUP.md).

**Update (2026-08):** now that the Surface Pro 11's own sensors are
confirmed (OV13858/IMX681/VD55G0, above — not OV02C10), this patch's value
is purely structural (the `port`/`endpoint`/CSIPHY wiring pattern), not as a
sensor match. Worth independently checking whether the **Lenovo Yoga Slim 7
14Q8X9** or **Samsung Galaxy Book4 Edge** — the two other devices confirmed
above to share this exact Spectra 695 ISP core — have any public Linux
bring-up activity; either would likely be a closer reference than the Slim7x
for the ISP-core side of the devicetree, even if their sensor picks also
differ from the Surface Pro 11's.

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

In rough dependency order. Step 1 is now done — kept here so the sequencing
still makes sense and so a future hardware revision (see the `SDFE`
wrinkle above) can be re-verified the same way.

1. ~~Identify the sensor(s).~~ **Done, 2026-08** — see the confirmed
   hardware inventory table above. Method (Windows `pnputil`/PowerShell,
   DriverStore extraction, `acpidump.exe`/`iasl.exe`) is in
   [CAMERA_BRINGUP.md → A1](CAMERA_BRINGUP.md#a1-identify-the-sensor--method-for-re-verification--a-different-unit)
   if you need to re-verify against a different unit or hardware revision.
2. **Confirm a Linux driver exists** for each sensor — also now done, see
   the table above: OV13858 (rear) exists but needs a small devicetree-match
   patch; VD55G1 (IR) exists but this unit's part is the sibling VD55G0,
   unconfirmed compatibility; IMX681 (front) has no known driver anywhere.
3. **Write the board devicetree nodes** once CAMSS + CSIPHY are in the
   X1E80100 `.dtsi` (patch series above): sensor I2C node with
   `compatible`, regulators, clocks, reset/powerdown GPIOs, plus the
   CSIPHY/CSID port/endpoint graph connecting it to CAMSS. The one piece
   step 1 could *not* recover from Windows — I2C bus/address and
   regulator/GPIO wiring, which live in an undocumented binary blob format
   rather than ACPI — still has to come from a live I2C bus scan or blob
   reverse-engineering. See [CAMERA_BRINGUP.md](CAMERA_BRINGUP.md).
4. **Test incrementally on real hardware** — `v4l2-ctl --list-devices`,
   `media-ctl -p`, `yavta`/`qcam` for raw frame capture — before expecting a
   GUI camera app to work. This is the step that cannot be done from a
   description; it requires the physical Surface Pro 11 and iterative
   `dtb`/driver changes with reboots between attempts.
5. **Status LEDs** (mentioned alongside cameras in the status table) are
   likely on the same power rail/GPIO group as the sensor and would probably
   fall out of step 3, but haven't been investigated independently.

## IR camera / Windows Hello (Face ID) — a harder superset of the same problem

This gets asked about separately often enough to spell out explicitly: **IR
face-auth support is not an independent, easier, or alternate path to camera
support — it depends on everything above, plus more.** Don't expect it to
land before, or instead of, plain RGB camera support.

### Confirmed, 2026-08: identity, and a real nuance

The IR camera is `ACPI\SMO55F0` (`VEN_SMO&DEV_55F0`, `_SUB = "MSHW0492"`),
enumerated by Windows as "Surface IR Camera Front" and — like the RGB
sensors — CSI-attached with no `_CRS` resource data (same undocumented
binary-blob wiring situation described above).

**"SMO" is STMicroelectronics's ACPI vendor prefix.** Cross-referencing the
Windows driver package's bundled tuning files narrows it further: the
`surfacecamauxsensor_extension8380.inf` package for `_SUB = MSHW0492` (this
unit's exact subsystem ID) ships
`com.surface.sensormodule.aux_vd55g0_MSHW0492.bin` — i.e. this is a
**VD55G0**, not its sibling VD55G1. That distinction matters a lot for
Linux driver availability: mainline has `drivers/media/i2c/vd55g1.c`
(`compatible = "st,vd55g1"`, real devicetree support, full binding example
available), but that driver identifies chips via an internal model-ID
register read (`VD55G1_MODEL_ID_VD55G1` / `_VD65G4`) with **no VD55G0
entry at all** — so it is not confirmed to probe successfully against a
real VD55G0, even though the two parts are closely related (VD55G0: 644×604,
VD55G1: 804×704, same ST global-shutter BSI family). Treat `vd55g1.c` as
the closest available structural reference and a plausible adaptation
starting point, not a known-working driver for this exact part.

The illuminator is a separate ACPI device, `FLSH` (`_HID = QCOM0C27`,
"Qualcomm(R) Spectra(TM) 695 ISP Camera Flash Device"), depending on `CAMP`
(the camera platform device) rather than being wired directly to the IR
sensor node. This confirms the illuminator is modeled as part of the
**ISP's own flash subsystem**, not a bare GPIO LED or a separate discrete
driver chip — which changes the Phase B guidance in
[CAMERA_BRINGUP.md](CAMERA_BRINGUP.md): check whether mainline CAMSS (or a
V4L2 flash-LED-class binding) already models ISP-integrated flash control
before assuming a from-scratch driver is needed. One promising lead: the
`st,vd55g1` devicetree binding itself has a `st,leds = <N>` property in its
example — worth checking whether that ties into strobe control already.

### Why this is still harder than RGB, just less blind now

- **It's a second, different sensor** needing its own devicetree node —
  now identified (VD55G0), but with a driver situation *worse* than the
  rear/front sensors: the closest mainline driver (`vd55g1.c`) explicitly
  doesn't recognize this part's model ID.
- **The illuminator is real, ISP-integrated hardware** (`FLSH`/`QCOM0C27`),
  not speculative — good, in that it's now a known target — but still
  needs its Linux-side control path worked out (see the flash-LED lead
  above).
- Same shared prerequisite as RGB: the I2C/GPIO/regulator wiring for `CAMI`
  isn't in ACPI, same as `CAMS`/`CAMF` — see the confirmed hardware section
  above.

### The userspace side (once/if the driver work above exists)

The Linux-side facial-auth story is otherwise in decent shape and doesn't
need reinventing:

- **[howdy](https://github.com/boltgolt/howdy)** — a mature, actively
  maintained PAM module providing Windows-Hello-style face auth (login, lock
  screen, `sudo`). Packaged for Fedora via COPR (not the official repos):
  `sudo dnf copr enable frsoftware/howdy && sudo dnf install howdy`.
  It just needs a working IR `/dev/videoN` V4L2 node — which is exactly what
  the CAMSS/devicetree/driver work above would provide, nothing SP11-special
  needed on the howdy side.
- **IR illuminator triggering is the one place this diverges from the usual
  Linux playbook.** The common tool, [linux-enable-ir-emitter](https://github.com/EmixamPP/linux-enable-ir-emitter),
  works by probing **UVC (USB Video Class) Extension Unit** vendor controls —
  it assumes the IR camera is a USB device. Confirmed above: this camera is
  CSI-attached with an ISP-integrated flash device, not USB/UVC, so
  `linux-enable-ir-emitter`'s approach does not apply here. Illuminator
  control needs to come from the kernel/devicetree side (V4L2 flash subdev
  or LED-class device tied to `FLSH`), not a userspace UVC workaround.

### Bottom line

Sequence this behind plain RGB camera bring-up — still true, but for a more
specific reason now: RGB bring-up (OV13858, which already has a mainline
driver needing only a small patch) is the more tractable proving ground for
the shared CAMSS/CSIPHY devicetree pattern and the I2C-wiring-discovery
problem both sensors share. IR/Face-ID adds a driver gap of its own
(VD55G0 vs. the mainline VD55G1) on top of that shared work, not instead of
it.

## If you want to pick this up

**Start with [CAMERA_BRINGUP.md](CAMERA_BRINGUP.md)** — a concrete,
step-by-step implementation playbook (commands, devicetree templates,
driver options) built around the Yoga Slim7x reference above. This file is
the status/research summary; that one is the "how to actually do it" guide.

- Sensor identification is done — the next highest-value contribution is
  the I2C bus/address and regulator/GPIO wiring (step 3), which needs
  either real-hardware I2C bus scanning or reverse-engineering the
  `SCFG_*.bin`/sensor-module blob format. Please update this file (or
  [CAMERA_BRINGUP.md](CAMERA_BRINGUP.md)) with whatever you find, even
  partial — a confirmed I2C address alone unblocks a lot.
- Track the upstream CAMSS series for X1E80100 landing in mainline; once
  merged, the board-devicetree step (3) becomes realistic to attempt.
- The [Qualcomm Camera Subsystem driver docs](https://docs.kernel.org/admin-guide/media/qcom_camss.html),
  the Yoga Slim7x `ov02c10`/CSIPHY4 patch, and any Lenovo Yoga Slim 7
  14Q8X9 / Samsung Galaxy Book4 Edge Linux bring-up (same ISP core,
  confirmed above) are the best resources for the node structure step 3
  needs.
- For the front sensor (IMX681, no known driver anywhere), writing a new
  V4L2 sensor driver is now the realistic path — `ov13858.c` and
  `vd55g1.c` are reasonable structural references for what a from-scratch
  driver needs to implement, even though neither is the same sensor.

## References

- Bryan O'Donoghue, *[PATCH v8 00/18] Add dt-bindings and dtsi changes for CAMSS on x1e80100 silicon*, LKML, 2026-02.
- *[PATCH v8 17/18] arm64: dts: qcom: x1e80100-lenovo-yoga-slim7x: Add ov02c10 RGB sensor on CSIPHY4*, same series — the best available board-level reference; check current status before relying on exact values.
- *dt-bindings: media: Add qcom,x1e80100-camss*, linux-arm-msm patchwork.
- [Qualcomm Camera Subsystem driver — kernel docs](https://docs.kernel.org/admin-guide/media/qcom_camss.html)
- [Linaro — X1e80100 mainline status tracker](https://linaro.github.io/msm/soc/x1e80100)
- [dwhinham/linux-surface-pro-11](https://github.com/dwhinham/linux-surface-pro-11) — same ❌ status, no additional notes there either.
- [boltgolt/howdy](https://github.com/boltgolt/howdy) — Windows-Hello-style PAM facial auth for Linux; Fedora via `frsoftware/howdy` COPR.
- [EmixamPP/linux-enable-ir-emitter](https://github.com/EmixamPP/linux-enable-ir-emitter) — USB/UVC IR-emitter control tool; confirmed **not applicable** here — this unit's IR camera is CSI-attached with an ISP-integrated flash device (`FLSH`/`QCOM0C27`), not USB/UVC.
- [Microsoft Surface Pro 11 Front Facing Camera Replacement — iFixit](https://www.ifixit.com/Guide/Microsoft+Surface+Pro+11+Front+Facing+Camera+Replacement/175373) — confirms a multi-component "front sensor assembly," not sensor-level detail (superseded by the ACPI/DSDT extraction above for actual identity).
- `drivers/media/i2c/ov13858.c`, `ov02c10.c`, `vd55g1.c` in mainline Linux — read directly for driver-match-table and power-sequencing status cited throughout this doc.
- STMicroelectronics [VD55G0](https://www.st.com/resource/en/datasheet/vd55g0.pdf) / [VD55G1](https://www.st.com/resource/en/datasheet/vd55g1.pdf) datasheets — confirms these are related but distinct parts (644×604 vs. 804×704), consistent with the mainline driver's model-ID check rejecting one for the other.
- `camera/` in this repo — raw extraction: `sensor-hardware-ids.log` (PowerShell/`pnputil` ACPI enumeration), `driver-extraction.log` + the copied DriverStore packages (`SCFG_*.bin`, sensor-module `.bin`/`.pb`/`.json` tuning files), `iasl-win-20260408/{dsdt,ssdt}.dsl` (full disassembled ACPI tables). This is the primary source for everything in the confirmed-hardware section above.
