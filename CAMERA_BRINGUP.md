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

1. **Phase A — RGB camera.** The prerequisite for everything else, including IR.
2. **Phase B — IR camera + illuminator (Windows Hello).** Depends entirely on A.
3. **Phase C — Fedora userspace integration.** `howdy`, PAM, testing.

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
| Rear (RGB) | `OVTID858` | OmniVision **OV13858** | `drivers/media/i2c/ov13858.c` exists, ACPI-only — needs a small `of_device_id` patch |
| Front (RGB) | `SONY0681` | Sony **IMX681** | No mainline driver, no known out-of-tree source |
| IR (Hello) | `SMO55F0` | ST **VD55G0** | Mainline has `vd55g1.c` for the sibling part; not confirmed to match this one |

Start with the **rear camera (OV13858)** — it has the shortest path to a
working `/dev/videoN` of the three, since a real driver already exists and
just needs devicetree-match support added, following the exact pattern
`ov02c10.c` already demonstrates (see A3).

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

Verified from `ov13858.c` source: chip-ID register `0x300a` should read
`0x00d855`; the driver needs a `clocks` property (external clock — check
`ov13858_probe()`'s rate validation for the exact accepted value/range) and
calls `regulator_bulk_get`/`gpiod_get` for power sequencing — **check the
exact regulator/GPIO names in the current source before writing the node**,
since (unlike `ov02c10.c`) this wasn't fully cross-checked as part of this
research pass.

This is the actual bring-up work, and the part that's genuinely
device-specific — nobody can hand you exact values for the Surface Pro 11
sight-unseen. What follows is a template built from **verified real
values** (the Slim7x CAMSS-side fragment, confirmed OV13858 chip-ID) with
**SP11-specific placeholders** — I2C bus/address, regulator/GPIO names —
that ACPI could not provide (see A0) and that still need to come from a
live I2C bus scan (A1, technique 3) or `SCFG_REAR_MSHW0491.bin` reverse
engineering.

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

        /* Regulator/GPIO names below are placeholders, NOT read from
         * ov13858.c in this research pass (unlike ov02c10.c, which was
         * fully cross-checked) — confirm the actual regulator_bulk_get()/
         * gpiod_get() calls in the current driver source before relying on
         * these names, then get the rail mapping itself from an I2C scan
         * or the SCFG blob (see A0) — the Slim7x/T14s regulator-naming
         * mixup in CAMERA.md is exactly the mistake to avoid here. */
        dovdd-supply = <&TODO_io_rail>;
        avdd-supply  = <&TODO_analog_rail>;
        dvdd-supply  = <&TODO_core_rail>;

        reset-gpios = <&tlmm TODO GPIO_ACTIVE_LOW>;

        /* Confirm the accepted external clock rate in ov13858_probe()'s
         * validation before assuming a value. */
        clocks = <&TODO_camera_clk>;

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

- **All three sensors are now identified with a mainline driver situation
  known for each** (OV13858 rear: exists, needs a small devicetree-match
  patch; VD55G0 IR: closest relative exists, model-ID mismatch unconfirmed
  either way; IMX681 front: no driver anywhere). This is real, load-bearing
  progress — it turns "we don't know what's on this board" into "we know
  exactly what's on this board and what each piece needs," which is most of
  the uncertainty this doc used to carry.
- **What's now the single biggest blocker for all three**: I2C bus,
  address, and regulator/GPIO wiring aren't in ACPI at all (confirmed by
  reading the disassembled DSDT — the sensor device nodes have no `_CRS`).
  That data lives in proprietary `SCFG_*.bin`/sensor-module blobs with an
  undocumented format. Until someone either reverse-engineers that format
  or determines the wiring via live I2C bus scanning + trial devicetree
  entries on real hardware, A3/B1's devicetree templates stay templates.
  This — not "which sensor is it" — is now the highest-value open question.
- **Start with the rear camera (OV13858)**, not front or IR: shortest
  distance to a working `/dev/videoN` (existing driver, small patch,
  well-documented chip-ID register for verification), and proves out the
  I2C-wiring-discovery method the other two sensors will reuse.
- **Front camera (IMX681)** has no known Linux driver anywhere — budget for
  this being a from-scratch `drivers/media/i2c/` driver, using `ov13858.c`
  as a structural reference for what one needs to implement.
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
- This repo's `camera/` directory — the raw Windows-side extraction
  (`sensor-hardware-ids.log`, `driver-extraction.log`, disassembled
  `iasl-win-20260408/{dsdt,ssdt}.dsl`, and the copied DriverStore packages
  themselves) that everything sensor-identity-related in this file and
  CAMERA.md is derived from.
