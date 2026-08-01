# Cameras — Surface Pro 11 (status: not working, upstream groundwork in progress)

> **This is a bring-up research doc, not a solution.** Nobody in the Surface
> Pro 11 Linux community — this project, [dwhinham/linux-surface-pro-11](https://github.com/dwhinham/linux-surface-pro-11),
> or the upstream kernel patch series — has working cameras yet. If you came
> here hoping to `sudo ./install.sh --camera` your way to a working webcam,
> that phase doesn't exist and shouldn't be faked. What follows is what's
> actually known, so whoever picks this up next doesn't start from zero.

## What we don't know yet

- **Which sensor(s) the Surface Pro 11 specifically uses.** Microsoft doesn't
  publish this, and no teardown/FCC filing/Windows driver inspection has
  been done against this specific unit as part of this project. This got a
  lot less speculative in 2026-02 though — see below.
- **The devicetree wiring** for camera on the Surface Pro 11 board
  (`arm64-dts-qcom-x1e80100-microsoft-denali*.dts`) — CSIPHY lane mapping,
  sensor I2C address, regulators/GPIOs/clocks the sensor needs, `port`/
  `endpoint` graph linking sensor → CSIPHY → CAMSS. None of this exists in
  any tree referenced by this project, though a sibling X1E80100 laptop now
  has a real reference to adapt from (see below).
- **Whether a Linux driver for the sensor exists in a usable state.** For
  OV02C10 specifically, yes: `drivers/media/i2c/ov02c10.c` is in mainline
  (`CONFIG_VIDEO_OV02C10`) and — confirmed by reading the current source —
  already has a devicetree `of_device_id` table (`compatible =
  "ovti,ov02c10"`), not just the ACPI matching Intel originally wrote it
  with. Verified requirements straight from the source: three regulator
  supplies (`dovdd`, `avdd`, `dvdd`), an optional `reset` GPIO, a 19.2 MHz
  input clock, and chip-ID register `0x300a` reading `0x5602`. See
  [CAMERA_BRINGUP.md](CAMERA_BRINGUP.md) for how to use this.

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
one. This is also the strongest evidence yet that **OV02C10 is a real,
in-use X1E80100 Copilot+ camera sensor** (Lenovo shipped it), which makes it
a much better first guess for the Surface Pro 11 than "industry pattern" —
still not confirmed for this specific device, but no longer a shot in the
dark either. The concrete how-to for using this reference is in
[CAMERA_BRINGUP.md](CAMERA_BRINGUP.md).

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

## IR camera / Windows Hello (Face ID) — a harder superset of the same problem

This gets asked about separately often enough to spell out explicitly: **IR
face-auth support is not an independent, easier, or alternate path to camera
support — it depends on everything above, plus more.** Don't expect it to
land before, or instead of, plain RGB camera support.

### What's likely there, unconfirmed for this specific unit

Every modern Surface with Windows Hello (Go, Pro 4 onward, including the
Pro 11 per Microsoft's own tech specs, which list "Windows Hello face
authentication camera") ships the same camera-bar pattern: an RGB camera, an
IR camera, an IR illuminator LED, a separate white "camera active" indicator
LED, and an ambient-light/color sensor, all clustered in one bezel assembly.
The Surface Pro 11 iFixit teardown confirms a "front sensor assembly" with
multiple discrete press-connector components in that same bezel area,
consistent with this pattern — but iFixit's repair guide doesn't break out
sensor-by-sensor identity or wiring, so **treat "there's a separate IR
sensor + illuminator" as a strong inference from the product line, not a
confirmed-for-SP11 fact**, same caveat as the RGB sensor identity above.

### Why this is harder than RGB, not easier

- **It's a second, different sensor.** IR-sensitive sensors are different
  parts from the RGB one (different part number, likely different I2C
  address, possibly a different CSI port on the same CAMSS instance). Step 1
  (identify the sensor) and step 3 (devicetree node) above have to be done
  *again*, independently, for this sensor.
- **The illuminator needs its own driver path.** Windows Hello strobes the
  IR LED in sync with sensor capture; it's not a simple always-on light.
  On Qualcomm/ARM platforms there's no reason to expect this is exposed the
  way x86 UVC Windows Hello cameras are — see below.
- **No CAMSS board wiring exists yet at all** (this file's whole point) —
  so IR is blocked on the exact same missing prerequisite as RGB, just with
  extra steps stacked on top once that prerequisite is met.

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
  it assumes the IR camera is a USB device. The Surface Pro 11's camera
  complex is almost certainly MIPI-CSI attached straight to the SoC's CAMSS
  ISP (Qualcomm Copilot+ platforms don't use a USB UVC bridge chip the way
  some older Intel-based Surface models did), so **`linux-enable-ir-emitter`'s
  approach likely does not apply here at all.** Illuminator control would
  need to be exposed by the kernel driver/devicetree itself — as a V4L2
  flash sub-device, an LED class device, or a regulator toggled alongside
  sensor streaming — which is kernel/devicetree work, not a userspace
  workaround. Confirm this assumption (USB vs. CSI) as part of step 1's
  hardware identification; if it turns out to be USB/UVC after all, the
  existing `linux-enable-ir-emitter` tooling would apply directly and this
  whole point is moot.

### Bottom line

Sequence this behind plain RGB camera bring-up. Getting the RGB sensor
working first establishes the CAMSS board wiring and proves out the
sensor-identification methodology (step 1) that IR support would reuse
directly. Attempting IR/Face-ID first means solving the same unsolved
prerequisite plus extra, harder-to-verify pieces (a second sensor, an
illuminator with no known Linux precedent on this platform type) with no
payoff until the shared blocker is gone anyway.

## If you want to pick this up

**Start with [CAMERA_BRINGUP.md](CAMERA_BRINGUP.md)** — a concrete,
step-by-step implementation playbook (commands, devicetree templates,
driver options) built around the Yoga Slim7x reference above. This file is
the status/research summary; that one is the "how to actually do it" guide.

- Start with sensor identification (step 1) — it's pure software work,
  doable without deep kernel experience, and unblocks everything else.
  Please update this file with what you find (sensor part number, ACPI HID,
  I2C address) even if you don't get further — that alone saves the next
  person days.
- Track the upstream CAMSS series for X1E80100 landing in mainline; once
  merged, the board-devicetree step (3) becomes realistic to attempt.
- The [Qualcomm Camera Subsystem driver docs](https://docs.kernel.org/admin-guide/media/qcom_camss.html)
  plus the Yoga Slim7x `ov02c10`/CSIPHY4 patch (best available board-level
  reference — see above) are the best resources for the node structure
  step 3 needs.

## References

- Bryan O'Donoghue, *[PATCH v8 00/18] Add dt-bindings and dtsi changes for CAMSS on x1e80100 silicon*, LKML, 2026-02.
- *[PATCH v8 17/18] arm64: dts: qcom: x1e80100-lenovo-yoga-slim7x: Add ov02c10 RGB sensor on CSIPHY4*, same series — the best available board-level reference; check current status before relying on exact values.
- *dt-bindings: media: Add qcom,x1e80100-camss*, linux-arm-msm patchwork.
- [Qualcomm Camera Subsystem driver — kernel docs](https://docs.kernel.org/admin-guide/media/qcom_camss.html)
- [Linaro — X1e80100 mainline status tracker](https://linaro.github.io/msm/soc/x1e80100)
- [dwhinham/linux-surface-pro-11](https://github.com/dwhinham/linux-surface-pro-11) — same ❌ status, no additional notes there either.
- [boltgolt/howdy](https://github.com/boltgolt/howdy) — Windows-Hello-style PAM facial auth for Linux; Fedora via `frsoftware/howdy` COPR.
- [EmixamPP/linux-enable-ir-emitter](https://github.com/EmixamPP/linux-enable-ir-emitter) — USB/UVC IR-emitter control tool; likely **not** applicable here if the SP11's IR camera turns out to be CSI-attached rather than USB — confirm before assuming it'll work.
- [Microsoft Surface Pro 11 Front Facing Camera Replacement — iFixit](https://www.ifixit.com/Guide/Microsoft+Surface+Pro+11+Front+Facing+Camera+Replacement/175373) — confirms a multi-component "front sensor assembly," not sensor-level detail.
