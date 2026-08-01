# Camera Bring-Up Playbook — Surface Pro 11

This is the **how-to**: concrete commands, devicetree templates, and driver
options for actually getting the camera (and eventually IR/Windows Hello)
working. [CAMERA.md](CAMERA.md) is the **status/research** doc — read that
first for context on what's blocking this and why. This file assumes you
have physical access to a Surface Pro 11 running this project's Fedora
setup, with Windows still dual-booted, and are comfortable building and
booting custom kernels.

**Update (2026-08):** Phase A1/B0's sensor identification *has* now been run
against a real Surface Pro 11 (ACPI enumeration + full DSDT/SSDT
disassembly + DriverStore extraction — raw data in this repo's `camera/`
directory) — that part is real hardware data, not inference. Everything
from devicetree-writing onward (A3 onward) is still untested: built from
verified upstream sources (real driver source code, a real in-review patch
series for a sibling device) — not guesses — but "verified against upstream
source" and "verified on this hardware" remain different things for that
part. Expect to hit surprises at A3 onward; that's normal bring-up, not a
sign you're doing it wrong.

## Phase map

1. **Phase A — Rear camera (OV13858).** Mainline driver + a real out-of-tree power-sequencing patch to adapt.
2. **Phase A2 — Front camera (IMX681).** No mainline driver, but a real out-of-tree devicetree-ready driver exists to adapt (saved in this repo).
3. **Phase B — IR camera + illuminator (Windows Hello).** Depends on A/A2's CAMSS-wiring groundwork.
4. **Phase C — Fedora userspace integration.** `howdy`, PAM, testing.

Do them in order. Don't start B before A works — see CAMERA.md's "harder
superset" section for why.

---

## Phase A — RGB camera

### A0. What's already true, so you don't redo it

**The sensors are identified — this was Phase A1/B1, done 2026-08 against a
real unit.** Full method and raw data below and in
[CAMERA.md](CAMERA.md#confirmed-hardware-inventory-2026-08-from-a-real-surface-pro-11);
headline results:

| Function | ACPI `_HID` | Part | Driver situation |
| --- | --- | --- | --- |
| Rear (RGB) | `OVTID858` | OmniVision **OV13858** | Mainline `ov13858.c` exists, ACPI-only, **no power-sequencing code at all** — needs devicetree-match + a real out-of-tree reset/regulator/clock patch already exists |
| Front (RGB) | `SONY0681` | Sony **IMX681** | No mainline driver, but a **real, devicetree-ready out-of-tree driver exists** — written for the *Intel* SKU of "Surface Pro 11," not this Qualcomm one; see Phase A2 |
| IR (Hello) | `SMO55F0` | ST **VD55G0** | Mainline has `vd55g1.c` for the sibling part; not confirmed to match this one |

Both rear and front cameras now have a real starting driver to adapt —
neither needs to be written from scratch. Start with whichever you find
more tractable; A1–A5 below cover the rear camera (OV13858) in detail, and
**Phase A2** covers the front camera (IMX681) using the saved reference
driver.

- `CONFIG_VIDEO_QCOM_CAMSS` (the SoC-side ISP driver) has X1E80100 support
  landing upstream (Bryan O'Donoghue's CAMSS series — check its current
  merge status; if you're building against a kernel new enough to have it,
  you're starting ahead).
- A sibling X1E80100 board (Lenovo Yoga Slim7x) has real in-review
  devicetree patches wiring a different sensor (OV02C10) to CSIPHY4 — still
  the best available structural reference for the CAMSS-side wiring
  pattern, just not a sensor match. Details and the confirmed fragment are
  in [CAMERA.md](CAMERA.md#a-sibling-x1e80100-laptop-has-real-board-level-camera-work-in-flight).
  Also worth checking: the **Lenovo Yoga Slim 7 14Q8X9** and **Samsung
  Galaxy Book4 Edge** share this unit's exact Spectra 695 ISP-core ACPI IDs
  (confirmed in CAMERA.md) — either may have closer Linux bring-up activity
  for the ISP-core side specifically.
- **What ACPI does *not* give you**: I2C bus, I2C address, GPIO pins, or
  regulator names for any of the three sensors. The `CAMS`/`CAMF`/`CAMI`
  ACPI device nodes have no `_CRS` resource method at all (confirmed by
  reading the disassembled DSDT) — that wiring lives in the proprietary
  `SCFG_*.bin` blobs instead. This is still the real unsolved piece; see A3.

### A1. Identify the sensor — method (for re-verification / a different unit)

This section is kept for reference — re-run it if you're working from a
different Surface Pro 11 unit, a different hardware revision (see
[CAMERA.md](CAMERA.md)'s `SDFE` note), or want to double check the results
above. **You don't need to repeat this for the confirmed sensors listed in
A0.**

**Try these in order — stop as soon as one gives you a clear answer.** The
first three all run *inside Windows* (boot back into it — you kept the
partition for exactly this); the last runs from Linux.

0. **Device Manager Hardware IDs, from an elevated PowerShell or Command
   Prompt in Windows:**
   ```powershell
   # List camera-class devices with full hardware IDs
   Get-PnpDevice -Class Camera | Get-PnpDeviceProperty -KeyName DEVPKEY_Device_HardwareIds | Format-List

   # Broader net — catches anything misclassified outside the "Camera" class
   Get-PnpDevice | Where-Object { $_.FriendlyName -match "camera|infrared|IR " } |
       Get-PnpDeviceProperty -KeyName DEVPKEY_Device_HardwareIds | Format-List
   ```
   Or the built-in CLI tool, no PowerShell module needed:
   ```
   pnputil /enum-devices /class Camera
   ```
   Expect **two separate entries** — RGB and IR are different PnP devices.
   Note both Hardware IDs; a `USB\VID_xxxx&PID_xxxx` prefix tells you it's
   USB/UVC (relevant for Phase B's illuminator section later), while
   anything else (an ACPI-style ID, or a bus-specific one) points at
   CSI-attached.

1. **Grep the Windows DriverStore for a matching INF.** From Windows itself,
   **prefer PowerShell's `Select-String` over `findstr`** — many INFs in the
   DriverStore are UTF-16LE, which plain `findstr` doesn't handle (you'll
   either get a "Unicode signature... some characters may be lost" warning
   or silently miss matches); `Select-String` auto-detects per-file encoding:
   ```powershell
   Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" -Recurse -Filter *.inf -ErrorAction SilentlyContinue |
       Select-String -Pattern "ov02c10","ov02e10","ovti","omnivision","hi846","imx","gc02","gc05" |
       Select-Object -Unique Path
   ```
   If you'd rather stick with `cmd.exe`, `findstr /U` forces UTF-16 mode and
   fixes the warning — but then assumes *every* matched file is UTF-16, so it
   can miss the plain-ANSI INFs mixed into the same tree:
   ```cmd
   cd /d C:\Windows\System32\DriverStore\FileRepository
   findstr /si /U "ov02 ovti omnivision hi846 imx gc02 gc05" *.inf
   dir /s /b C:\Windows\System32\DriverStore\FileRepository\*cam*
   ```
   Or the same idea from Linux, on the already-mounted Windows partition
   (same technique this project already uses for sensors — see
   [SENSORS.md](SENSORS.md)):
   ```bash
   sudo mkdir -p /mnt/windows
   sudo mount /dev/nvme0n1p3 /mnt/windows   # adjust partition number
   grep -ril -e "ov02c10" -e "ov02e10" -e "ovti" -e "omnivision" \
       /mnt/windows/Windows/System32/DriverStore/FileRepository/ 2>/dev/null
   ```
   A hit gives you the exact sensor and usually the `.inf` also documents
   power-sequencing (regulator names, delays) in `[AddReg]`/custom sections
   — worth reading in full if you find one.

2. **ACPI dump.** Even on a devicetree-booted ARM system, Windows itself
   still uses ACPI for a lot of device description, and the SSDT may name
   the camera. Windows has no built-in `acpidump`, but the same ACPICA
   project that ships Linux's does prebuilt Windows binaries at
   [acpica.org/downloads](https://acpica.org/downloads) (`acpidump.exe`,
   `iasl.exe`). Elevated:
   ```
   acpidump.exe -b
   iasl.exe -d *.dat
   findstr /si "CAM OVTI camera" *.dsl
   ```
   No command line preferred? **RWEverything** (free GUI) has an "ACPI
   Table" browser that does the same thing in a few clicks.

   Or from Linux, once booted (functionally identical, same caveat below):
   ```bash
   sudo acpidump -o sp11-acpi.dat
   iasl -d sp11-acpi.dat   # produces sp11-acpi.dsl
   grep -i -B5 -A20 "cam\|ov02\|ovti" sp11-acpi.dsl
   ```
   Caveat either way: Intel IPU6 platforms use predictable ACPI HIDs like
   `OVTI02C1` for this exact sensor. **Don't assume the same pattern here**
   — this is a Qualcomm platform, and this project's own
   [SENSORS.md](SENSORS.md) already found that Windows-on-Snapdragon uses a
   largely non-ACPI, Qualcomm-proprietary enumeration path (SSC/QMI + a
   DriverData registry blob) for its sensor hub. The camera may or may not
   follow the same pattern — this is genuinely unknown until you look. Treat
   "camera has a normal ACPI HID" as one hypothesis to check, not a
   certainty.

3. **I2C bus scan from Linux**, zero devicetree changes required:
   ```bash
   for bus in /dev/i2c-*; do
       n="${bus#/dev/i2c-}"
       echo "=== bus $n ==="
       sudo i2cdetect -y "$n"
   done
   ```
   If the camera's power rails are already enabled by firmware/bootloader
   at boot (not guaranteed — camera rails are often left off for privacy/
   power reasons until a driver claims them), you may see a device ACK at
   an unexpected address on one of the QUP I2C buses. This is fast and
   non-destructive, so it's worth a try even though it may come back empty.
   A hit here gives you the I2C address directly — genuinely useful even
   without a part number yet, since a datasheet-informed register probe
   (e.g. reading OV02C10's chip-ID register `0x300a`, expecting `0x5602` —
   see A0) can help identify or rule out a specific part.

Whatever you find that's new — a hardware-revision difference, a
disagreement with A0's results — **update [CAMERA.md](CAMERA.md) with it.**

### A2. Confirm the kernel config

```bash
cd ~/linux-sp11   # from install.sh --kernel's clone, see README Step 1
grep -E 'CONFIG_VIDEO_QCOM_CAMSS|CONFIG_VIDEO_OV13858' .config
```

If missing, enable via `scripts/config` (avoids a full `menuconfig` pass):

```bash
scripts/config --enable CONFIG_VIDEO_QCOM_CAMSS
scripts/config --module CONFIG_VIDEO_OV13858
make olddefconfig
```

If `CONFIG_VIDEO_QCOM_CAMSS` doesn't exist as an option at all, the CAMSS
series hasn't landed in the tree you're building — check whether a newer
upstream tag includes it, or whether you need to cherry-pick the series
manually before proceeding.

### A3. Patch the OV13858 driver for devicetree matching, then write the devicetree nodes

`drivers/media/i2c/ov13858.c` currently only matches via ACPI
(`ov13858_acpi_ids` in the `i2c_driver` struct) — confirmed by reading the
source; there's no `of_device_id` table at all, unlike `ov02c10.c` which
already has one. This is a small, well-understood patch: add an
`of_device_id` table and wire it into `.of_match_table`, following
`ov02c10.c`'s existing pattern exactly. Do this first — the devicetree node
below assumes `compatible = "ovti,ov13858"` exists, which it doesn't yet
upstream.

**Update (2026-08): the power-sequencing patch already exists.** Mainline
`ov13858.c` has *no* regulator/clock/reset-GPIO code at all — confirmed by
reading current source. A real out-of-tree patch fixing exactly that is
saved at [`kernel-patches/camera/reference/ov13858-reset-regulator-clock.patch`](kernel-patches/camera/reference/)
(from [linux-surface#2153](https://github.com/linux-surface/linux-surface/issues/2153),
tested on a real Surface Pro 10). Verified from that patch + current
mainline source:

- Chip-ID register `0x300a` should read `0x00d855`.
- Clock: `devm_clk_get_optional(dev, "xvclk")` — property name `xvclk`.
- Regulators in the reference patch: `"avdd"`, `"pwr1"` — but the patch's
  own code comment flags these as possibly-not-canonical ("`// Or use
  standard names that might be more correct`"), so don't treat them as
  gospel; verify against current source before relying on them.
- Confirmed real power-up sequence, in order: assert reset → enable clock →
  enable regulators → wait 5–10 ms → deassert reset → wait 20 ms. This
  ordering matters and isn't expressible in the devicetree node alone — the
  driver patch has to implement it.
- `.of_match_table` is still **not** in that patch — it only fixes
  power-sequencing via ACPI. Adding `compatible = "ovti,ov13858"` (below)
  is still separate, additional work this project needs to do.

This is the actual bring-up work, and the part that's genuinely
device-specific — nobody can hand you exact values for the Surface Pro 11
sight-unseen. What follows is a template built from **verified real
values** (the Slim7x CAMSS-side fragment, confirmed OV13858 chip-ID and
power-sequencing above) with **SP11-specific placeholders** — I2C
bus/address, regulator/GPIO *rail mapping* — that ACPI could not provide
(see A0) and that still need to come from a live I2C bus scan (A1,
technique 3) or `SCFG_REAR_MSHW0491.bin` reverse engineering.

Put this as a patch under `kernel-patches/camera/` (that directory already
exists and `install.sh --kernel` already picks up `*.patch` files from it —
no script changes needed once you have a real patch).

**Sensor node** (goes under the relevant I2C/QUP controller node — which
bus depends on A1's findings):

```dts
&i2c_TODO {  /* which QUP/I2C instance the sensor is on — from A1 */
    status = "okay";

    camera@TODO {  /* I2C address — unknown, see A0: not in ACPI, needs I2C scan or SCFG_REAR_MSHW0491.bin */
        compatible = "ovti,ov13858";   /* NOT yet real upstream — add this of_device_id in the A3 driver patch first */
        reg = <0x TODO>;

        /* Property names below match the reset/regulator/clock patch in
         * kernel-patches/camera/reference/ (real, tested on a Surface Pro
         * 10 — see A3 text). "avdd"/"pwr1" are flagged in that patch's own
         * comment as possibly-not-canonical; verify current source. Either
         * way, the actual PMIC rail each maps to on THIS board — the
         * Slim7x/T14s regulator-naming mixup in CAMERA.md is exactly the
         * mistake to avoid — still needs an I2C scan or SCFG blob RE. */
        avdd-supply = <&TODO_analog_rail>;
        pwr1-supply = <&TODO_core_rail>;   /* name per reference patch; may need renaming if not canonical */

        reset-gpios = <&tlmm TODO GPIO_ACTIVE_LOW>;

        /* Reference patch uses devm_clk_get_optional(dev, "xvclk") —
         * confirm the accepted rate in ov13858_probe()'s validation. */
        clocks = <&TODO_camera_clk>;
        clock-names = "xvclk";

        port {
            ov13858_ep: endpoint {
                remote-endpoint = <&camss_csiphyN_inep0>;  /* N = whichever CSIPHY, from A3 CAMSS side below */
                data-lanes = <0 1 2 3>;   /* OV13858 is commonly wired 4-lane on other platforms — verify for SP11, don't assume */
                link-frequencies = /bits/ 64 <TODO>;  /* read from ov13858.c's link-freq menu control, not yet cross-checked */
            };
        };
    };
};
```

**CAMSS side** (adapted directly from the confirmed Slim7x fragment for
structure — CSIPHY index, port number, and clock-lanes value are Slim7x
*and OV02C10*-specific and must be independently determined for the SP11's
actual rear-camera CSIPHY; there is no reason to assume it matches Slim7x's
CSIPHY4 since this is a different sensor on a different board):

```dts
&camss {
    ports {
        port@N {  /* CSIPHY index — TODO, unrelated to Slim7x's CSIPHY4 */
            camss_csiphyN_inep0: endpoint@0 {
                clock-lanes = <TODO>;    /* SP11-specific — Slim7x's <7> was for a different CSIPHY entirely */
                data-lanes = <0 1 2 3>;
                remote-endpoint = <&ov13858_ep>;
            };
        };
    };
};
```

Generate the patch the same way the rest of this repo's kernel patches are
formatted:

```bash
cd ~/linux-sp11
git add drivers/media/i2c/ov13858.c arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali*.dts
git commit -m "media: i2c: ov13858: Add devicetree support"      # the A3 driver patch, separately
git commit -m "arm64: dts: qcom: x1e80100-microsoft-denali: Add OV13858 rear camera"
git format-patch -2 -o ~/fedora-surface-pro-11/kernel-patches/camera/
```

### A4. Build and test

```bash
sudo ./install.sh --kernel   # picks up kernel-patches/camera/*.patch automatically
sudo reboot
```

Verification, cheapest checks first:

```bash
# Did the driver even probe? Chip-ID mismatches, regulator/clock failures,
# and -EPROBE_DEFER loops all show up here first.
dmesg | grep -i ov13858

# Is there a V4L2 device node at all?
v4l2-ctl --list-devices

# Media graph — confirms CAMSS successfully linked sensor -> CSIPHY -> ISP
media-ctl -p

# Actual frames (once the above look sane)
v4l2-ctl --device=/dev/videoN --stream-mmap --stream-count=1 --stream-to=/tmp/frame.raw
```

A chip-ID mismatch in dmesg (expecting `0x00d855` at register `0x300a`,
reading something else) means the wrong I2C address most likely, since the
sensor identity itself is already confirmed (A0) — try adjacent addresses
before doubting the part number.

### A5. Status LEDs

Not independently investigated. If the sensor node in A3 works, check
whether the same regulator/GPIO group also drives the white "camera active"
LED (common pattern — Windows lights it whenever the sensor is streaming).
Likely a `leds-gpio` devicetree node next to the camera node, triggered by
whatever the SP11's ACPI/Windows driver names its "camera privacy light."

---

## Phase A2 — Front camera (IMX681)

Unlike the rear camera, **don't start from mainline** — there is no
mainline `imx681.c` to patch. Start from the real, working, devicetree-
ready driver saved at
[`kernel-patches/camera/reference/imx681.c`](kernel-patches/camera/reference/imx681.c),
written for a different SKU of this exact device (see
[CAMERA.md](CAMERA.md#a-real-imx681-and-ov13858-driver-exists--for-the-other-surface-pro-11)
for full provenance and the license note). Full context on why this exists
and what does/doesn't transfer is in that file's directory README — read it
before starting.

### A2.0. What's already usable as-is

Confirmed by reading the saved source directly:

- **`compatible = "sony,imx681"`**, real `of_match_table`, already wired
  into the `i2c_driver` struct — copy this file into
  `drivers/media/i2c/imx681.c` in your kernel tree and it should build and
  bind on a devicetree system, same as any other sensor driver.
- Regulator names: **`avdd`, `dvdd`, `dovdd`** (three supplies, standard
  naming — more confidence in these than the OV13858 patch's `avdd`/`pwr1`,
  since these follow ordinary devicetree regulator-name convention rather
  than an ACPI/INT3472-idiom workaround).
- Reset GPIO: `"reset"`. Clock: unnamed (`devm_clk_get_optional(dev,
  NULL)`), same pattern as `ov02c10.c`.
- Chip-ID register `0x0016` → expected `0x0681`, with 5-attempt retry logic
  already built in (100 ms apart) — useful if power-up timing needs tuning
  on this board.
- **Confirmed hardware quirk, silicon-level not platform-level**: the
  analog-gain register (`0x0204`) is inverted — hardware code `0` = 16×
  gain, not 1×. The saved driver already handles this correctly
  (`ana_code = 960 - min(ctrl->val, 960)`); if you end up rewriting gain
  handling, don't reintroduce this bug.

### A2.1. What needs to change for this board

- **Clock/PLL values are wrong for this board and need re-verification.**
  The saved file hardcodes `IMX681_LINK_FREQ = 380800000` (380.8 MHz) —
  that's the *Intel Surface Pro 10's* value. The issue thread that produced
  this driver separately measured 969.6 MHz for the *Intel* Surface Pro 11
  (PLL multiplier `0x0307 = 0xE1`, `0x030D = 0x03012F`) — plausibly close
  to this Qualcomm board's actual clock given it's likely the same physical
  Leopard Imaging camera module, but **not confirmed for the Qualcomm SKU**
  and not present in the saved file itself (only in the issue thread's
  prose). Verify empirically: if chip-ID reads correctly but the PLL is
  wrong, streaming will typically fail or produce corrupt frames rather
  than a clean probe failure — don't assume PLL is right just because probe
  succeeds.
- **I2C bus/address, regulator rail mapping, reset GPIO number**: same gap
  as the rear camera (A0) — not in ACPI, needs I2C scan or
  `SCFG_FRONT_MSHW0490.bin` reverse engineering.
- **CSIPHY/CAMSS-side devicetree wiring**: same as A3's CAMSS-side
  template, different CSIPHY index (unknown, don't assume it matches the
  rear camera's).
- Everything Intel-specific in the original context (`ipu-bridge.c`,
  `int3472/*.c`, C-PHY-vs-D-PHY IPU6 driver debugging) is **not relevant**
  — CAMSS doesn't have an IPU6-shaped bridge layer, and the issue thread's
  own later correction found this exact sensor module is D-PHY, not C-PHY,
  which is one less variable to worry about.

### A2.2. Devicetree template

```dts
&i2c_TODO {
    status = "okay";

    camera@TODO {  /* I2C address unknown — see A2.1 */
        compatible = "sony,imx681";   /* real, already in the saved driver */
        reg = <0x TODO>;

        avdd-supply  = <&TODO_analog_rail>;
        dvdd-supply  = <&TODO_core_rail>;
        dovdd-supply = <&TODO_io_rail>;

        reset-gpios = <&tlmm TODO GPIO_ACTIVE_HIGH>;  /* driver deasserts with value 0 — check polarity */

        clocks = <&TODO_camera_clk>;  /* rate: verify, don't assume 969.6 MHz — see A2.1 */

        port {
            imx681_ep: endpoint {
                remote-endpoint = <&camss_csiphyN_inep0>;
                data-lanes = <0 1>;   /* confirmed 2-lane D-PHY in the saved driver/issue thread */
                link-frequencies = /bits/ 64 <TODO>;  /* NOT 380800000 — that's the Intel SP10 value; verify this board's actual rate */
            };
        };
    };
};
```

If the clock/PLL values (`0x0307`, `0x030D` in the saved driver's
`imx681_init_regs[]`) turn out wrong for this board's actual input clock,
recalculate using the same formula the issue thread used:
`external_clock_MHz × multiplier / pll_predivider / 2 = link_freq_MHz` —
solve for `multiplier` given this board's actual external clock and target
link frequency once both are known.

---

## Phase B — IR camera + illuminator (Windows Hello)

Only start this once Phase A actually produces frames — reuses the same
I2C-wiring-discovery problem and CAMSS devicetree pattern Phase A works out.

### B0. Confirmed hardware (2026-08)

- IR sensor: `ACPI\SMO55F0`, `_SUB = "MSHW0492"` → **STMicroelectronics
  VD55G0** (confirmed via the bundled `aux_vd55g0_MSHW0492.bin` tuning file
  matching this unit's exact subsystem ID — see
  [CAMERA.md](CAMERA.md#confirmed-2026-08-identity-and-a-real-nuance)).
- Illuminator: a **separate ACPI device**, `FLSH` (`_HID = QCOM0C27`,
  "Qualcomm(R) Spectra(TM) 695 ISP Camera Flash Device"), dependent on
  `CAMP` (camera platform) — i.e. Windows models this as part of the ISP's
  own flash subsystem, not a bare LED or third-party driver chip. `FLSH`
  has a tiny real `_CRS` (2 bytes, essentially just an end-tag) — no
  memory-mapped register range of its own, consistent with it being
  controlled *through* the ISP core rather than as an independent block.
- **Confirmed not USB**: all camera devices, IR included, enumerate under
  `ACPI\...`, not `USB\VID_...&PID_...`. `linux-enable-ir-emitter` (which
  works by probing USB/UVC Extension Unit controls) **does not apply here**
  — settled, not a hypothesis to check anymore.

### B1. Driver situation — closer than it looks, but not solved

Mainline has `drivers/media/i2c/vd55g1.c` (`compatible = "st,vd55g1"`,
real devicetree binding with a full working example — see below) for the
**sibling** VD55G1 part. Confirmed by reading the source: it identifies the
chip via an internal model-ID register (`VD55G1_MODEL_ID_VD55G1` /
`_VD65G4`) with **no VD55G0 case at all** — so it will very likely reject a
real VD55G0 outright at probe time rather than silently working. Options,
roughly in order of effort:

1. **Try `vd55g1.c` unmodified first anyway** — cheap to test, and if
   VD55G0/VD55G1 turn out to share enough register compatibility despite
   the explicit model-ID gate, you'd know immediately from the probe
   failure message (which model ID it actually read).
2. **Patch `vd55g1.c` to add a VD55G0 model-ID case** — if the probe
   failure in option 1 shows a recognizable model-ID value, and the rest of
   the register map is compatible (check the VD55G0 vs. VD55G1 datasheets:
   [VD55G0](https://www.st.com/resource/en/datasheet/vd55g0.pdf) is
   644×604, [VD55G1](https://www.st.com/resource/en/datasheet/vd55g1.pdf)
   804×704 — same sensor family, different resolution/generation), this
   could be a much smaller patch than writing a driver from scratch.
3. **Write a new driver** if 1/2 don't pan out — `vd55g1.c` is still the
   best structural reference (regulator/clock/reset handling, MIPI CSI-2
   endpoint parsing) even if the register map turns out to differ too much
   to share code directly.

Confirmed real devicetree example for `vd55g1.c` (adapt `compatible` if B1
determines a different string is needed):

```dts
i2c {
    camera-sensor@TODO {  /* I2C address unknown — see A0/Phase A's SCFG note, same problem here */
        compatible = "st,vd55g1";   /* or a new "st,vd55g0" if B1 needs one */
        reg = <0x TODO>;

        clocks = <&TODO_camera_clk>;   /* driver validates a supported rate range — check current source */

        vcore-supply = <&TODO_vcore_rail>;   /* confirmed regulator names from vd55g1.c source */
        vddio-supply = <&TODO_vddio_rail>;
        vana-supply  = <&TODO_vana_rail>;

        reset-gpios = <&tlmm TODO GPIO_ACTIVE_LOW>;

        port {
            endpoint {
                data-lanes = <TODO>;             /* driver/binding supports 1 or 2 lanes; SP11's wiring unknown */
                link-frequencies = /bits/ 64 <TODO>;
                remote-endpoint = <&camss_csiphyN_inep0>;
            };
        };
    };
};
```

### B2. Illuminator control

Since `FLSH` is confirmed to be modeled as part of the Spectra 695 ISP's
own flash subsystem (B0), check these before assuming a from-scratch driver
is needed:

1. **Check whether mainline CAMSS already models ISP-integrated flash
   control** as part of the X1E80100 CAMSS series (Phase A's `CONFIG_VIDEO_QCOM_CAMSS`)
   — this wasn't checked as part of this research pass and is the first
   thing to rule in/out, since it would mean no new driver at all, just a
   devicetree property.
2. **The `st,vd55g1` devicetree binding itself has an `st,leds = <N>`
   property** (visible in its official example) — worth checking what this
   controls in the driver source; if it ties into strobe/flash timing,
   that's a second, more direct lead than a standalone flash driver.
3. **Fall back to the generic V4L2 flash-LED-class framework**
   (`CONFIG_V4L2_FLASH_LED_CLASS`, `Documentation/leds/leds-class-flash.rst`,
   `include/media/v4l2-flash-led-class.h`) only if 1 and 2 don't pan out —
   this is real kernel driver work, wrapping whatever the illuminator's
   actual control mechanism turns out to be (GPIO, PMIC LED controller,
   etc. — still unknown) as a standard flash subdev so `howdy`/V4L2 apps
   can trigger it without SP11-specific glue.

---

## Phase C — Fedora userspace integration

Only relevant once Phase A (and, for face auth, Phase B) produce a working
`/dev/videoN`.

### RGB camera apps

```bash
sudo dnf install -y v4l-utils cheese
v4l2-ctl --device=/dev/videoN --list-formats-ext   # confirm supported resolutions/formats
```

### IR face auth via howdy

```bash
sudo dnf copr enable frsoftware/howdy
sudo dnf install -y howdy
sudo howdy config   # set the IR device path (e.g. /dev/videoN) and, if using
                     # the V4L2 flash subdev from Phase B, however howdy's
                     # config exposes IR-emitter triggering for your kernel setup
sudo howdy add       # enrolls a face
```

Enable it in PAM (howdy's installer usually offers to do this; if not,
`/etc/pam.d/sudo` and `/etc/pam.d/gdm-password` are the common targets — add
`auth sufficient pam_python.so /lib64/security/howdy/pam.py` above the
existing `auth` lines, keeping password auth as fallback).

### Wiring into `install.sh`

Don't add a `--camera` phase to `install.sh` until Phase A actually works
end-to-end on real hardware — a phase that silently no-ops or fails on
every install would be worse than no phase at all (same reasoning as why
[CAMERA.md](CAMERA.md) doesn't invent one today). Once A3/A4 produce a
working, reproducible devicetree patch, adding `install_camera()` to
`install.sh` following the existing phase pattern (see `install_wifi()` or
`install_pen()` for the shape) is straightforward — it would mostly be
`install_file` calls for any udev rules plus a `dnf install` for `v4l-utils`
and, for Phase B, `howdy`.

---

## Realistic assessment

- **All three sensors are identified, and none needs a driver written fully
  from scratch anymore.** OV13858 (rear): mainline driver + a real
  out-of-tree power-sequencing patch. IMX681 (front): no mainline driver,
  but a real, devicetree-ready out-of-tree driver exists and is saved in
  this repo. VD55G0 (IR): mainline has the closest relative (VD55G1),
  compatibility unconfirmed. This is a substantially better starting point
  than earlier drafts of this doc described — "no driver anywhere" for the
  front camera was simply wrong, corrected 2026-08.
- **What's now the single biggest blocker for all of them**: I2C bus,
  address, and regulator/GPIO wiring aren't in ACPI at all (confirmed by
  reading the disassembled DSDT — the sensor device nodes have no `_CRS`).
  That data lives in proprietary `SCFG_*.bin`/sensor-module blobs with an
  undocumented format. Until someone either reverse-engineers that format
  or determines the wiring via live I2C bus scanning + trial devicetree
  entries on real hardware, every devicetree template in this file stays a
  template. This — not "which sensor is it" or "is there a driver" — is now
  the highest-value open question.
- **The front camera's clock/PLL values need independent verification**,
  separately from the I2C-wiring problem above — the saved `imx681.c` was
  reverse-engineered against a *different* SoC's clock generation (Intel
  Lunar Lake), and while the same physical camera module makes the Intel
  SP11's 969.6 MHz figure a reasonable first guess, it's not confirmed for
  this Qualcomm board. See Phase A2.1.
- Start with whichever camera you find more tractable to get a first
  `/dev/videoN` — both rear and front now have comparable starting points
  (real driver + known chip-ID register + known power-sequencing pattern);
  the I2C-wiring-discovery method either one requires is directly reusable
  for the other.
- Expect **iterative reboots** — each devicetree change needs a rebuild
  (`install.sh --kernel`) and reboot to test. Budget accordingly; this is
  measured in multiple sessions, not one sitting.
- Update [CAMERA.md](CAMERA.md) and this file as you go, even with partial
  results. The value of this project has always been exactly that — the
  next person building on documented dead ends and partial progress instead
  of starting cold.

## References

Same sources as [CAMERA.md](CAMERA.md#references), plus:

- `drivers/media/i2c/ov02c10.c`, `ov13858.c`, `vd55g1.c` in mainline Linux —
  read directly for the `probe()` power-sequencing requirements, chip-ID
  register/value, and devicetree-match status cited above.
- `Documentation/devicetree/bindings/media/i2c/st,vd55g1.yaml` — full
  working devicetree example the B1 template above is based on.
- `Documentation/leds/leds-class-flash.rst`, `include/media/v4l2-flash-led-class.h` — V4L2 flash subdev framework, relevant if Phase B's illuminator needs synchronized strobing.
- [linux-surface/linux-surface#2153](https://github.com/linux-surface/linux-surface/issues/2153) / [#2156](https://github.com/linux-surface/linux-surface/pull/2156) — real Intel-SKU Surface Pro 10/11 camera bring-up; source of `kernel-patches/camera/reference/`. Read that directory's README before assuming anything from it transfers directly.
- This repo's `camera/` directory (git-ignored, local only) — the raw
  Windows-side extraction (`sensor-hardware-ids.log`, `driver-extraction.log`,
  disassembled `iasl-win-20260408/{dsdt,ssdt}.dsl`, and the copied
  DriverStore packages themselves) that everything sensor-identity-related
  in this file and CAMERA.md is derived from.
