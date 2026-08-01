# Camera Bring-Up Playbook — Surface Pro 11

This is the **how-to**: concrete commands, devicetree templates, and driver
options for actually getting the camera (and eventually IR/Windows Hello)
working. [CAMERA.md](CAMERA.md) is the **status/research** doc — read that
first for context on what's blocking this and why. This file assumes you
have physical access to a Surface Pro 11 running this project's Fedora
setup, with Windows still dual-booted, and are comfortable building and
booting custom kernels.

Nothing in this file has been executed against real hardware. It's built
from verified upstream sources (real driver source code, a real in-review
patch series for a sibling device) — not guesses — but "verified against
upstream source" and "verified on this hardware" are different things.
Expect to hit surprises at Phase A3 onward; that's normal bring-up, not a
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

- Fedora's mainline `drivers/media/i2c/ov02c10.c` already has devicetree
  support (`compatible = "ovti,ov02c10"`) — confirmed by reading the current
  source, not assumed. If the Surface Pro 11 does use this sensor, **you
  very likely do not need to write a new sensor driver.**
- `CONFIG_VIDEO_QCOM_CAMSS` (the SoC-side ISP driver) has X1E80100 support
  landing upstream (Bryan O'Donoghue's CAMSS series — check its current
  merge status; if you're building against a kernel new enough to have it,
  you're starting ahead).
- A sibling X1E80100 board (Lenovo Yoga Slim7x) has real in-review
  devicetree patches wiring OV02C10 to CSIPHY4 — the best structural
  reference available. Details and the confirmed fragment are in
  [CAMERA.md](CAMERA.md#a-sibling-x1e80100-laptop-has-real-board-level-camera-work-in-flight).

None of this confirms the Surface Pro 11 uses OV02C10 specifically — that's
Phase A1.

### A1. Identify the sensor

Do this before touching the kernel. It's pure software/data work, low risk,
and everything downstream depends on getting it right.

**Try these in order — stop as soon as one gives you a clear answer:**

1. **Grep the Windows DriverStore for a matching INF** (same technique this
   project already uses for sensors — see [SENSORS.md](SENSORS.md)):
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
   the camera:
   ```bash
   sudo acpidump -o sp11-acpi.dat
   iasl -d sp11-acpi.dat   # produces sp11-acpi.dsl
   grep -i -B5 -A20 "cam\|ov02\|ovti" sp11-acpi.dsl
   ```
   Caveat: Intel IPU6 platforms use predictable ACPI HIDs like `OVTI02C1`
   for this exact sensor. **Don't assume the same pattern here** — this is
   a Qualcomm platform, and this project's own [SENSORS.md](SENSORS.md)
   already found that Windows-on-Snapdragon uses a largely non-ACPI,
   Qualcomm-proprietary enumeration path (SSC/QMI + a DriverData registry
   blob) for its sensor hub. The camera may or may not follow the same
   pattern — this is genuinely unknown until you look. Treat "camera has a
   normal ACPI HID" as one hypothesis to check, not a certainty.

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

Whatever you find — even a partial answer — **update
[CAMERA.md](CAMERA.md)'s "What we don't know yet" section with it.** That's
the single highest-value thing you can contribute if you don't get further
than this step.

### A2. Confirm the kernel config

Once you have (or are betting on) a sensor identity:

```bash
cd ~/linux-sp11   # from install.sh --kernel's clone, see README Step 1
grep -E 'CONFIG_VIDEO_QCOM_CAMSS|CONFIG_VIDEO_OV02C10|CONFIG_VIDEO_OV02E10' .config
```

If missing, enable via `scripts/config` (avoids a full `menuconfig` pass):

```bash
scripts/config --enable CONFIG_VIDEO_QCOM_CAMSS
scripts/config --module CONFIG_VIDEO_OV02C10   # or whatever A1 identified
make olddefconfig
```

If `CONFIG_VIDEO_QCOM_CAMSS` doesn't exist as an option at all, the CAMSS
series hasn't landed in the tree you're building — check whether a newer
upstream tag includes it, or whether you need to cherry-pick the series
manually before proceeding.

### A3. Write the devicetree nodes

This is the actual bring-up work, and the part that's genuinely
device-specific — nobody can hand you exact values for the Surface Pro 11
sight-unseen. What follows is a template built from **verified real
values** (the Slim7x CAMSS-side fragment, and the OV02C10 driver's actual
`probe()` requirements read from source) with **SP11-specific placeholders**
you fill in from Phase A1's findings.

Put this as a patch under `kernel-patches/camera/` (that directory already
exists and `install.sh --kernel` already picks up `*.patch` files from it —
no script changes needed once you have a real patch).

**Sensor node** (goes under the relevant I2C/QUP controller node — which
bus depends on A1's findings):

```dts
&i2c_TODO {  /* which QUP/I2C instance the sensor is on — from A1 */
    status = "okay";

    camera@TODO {  /* I2C address — from A1 */
        compatible = "ovti,ov02c10";   /* confirmed compatible string, from mainline driver source */
        reg = <0x TODO>;

        /* Regulator names are exactly these three — confirmed from the
         * driver's regulator_bulk_get() call. Which PMIC rails they map to
         * on the SP11 is NOT the same as any other X1E80100 board — the
         * Slim7x/T14s regulator-naming mixup in CAMERA.md is exactly the
         * mistake to avoid here. Get these from the Windows INF (A1) or by
         * testing candidate rails. */
        dovdd-supply = <&TODO_io_rail>;
        avdd-supply  = <&TODO_analog_rail>;
        dvdd-supply  = <&TODO_core_rail>;

        reset-gpios = <&tlmm TODO GPIO_ACTIVE_LOW>;  /* optional in the driver, but likely present */

        /* Driver requires exactly 19.2 MHz in; confirm your parent clock
         * actually supplies this or the driver will reject it outright
         * (OV02C10_MCLK check in probe()). */
        clocks = <&TODO_camera_clk>;

        port {
            ov02c10_ep: endpoint {
                remote-endpoint = <&camss_csiphyN_inep0>;  /* N = whichever CSIPHY, from A3 CAMSS side below */
                data-lanes = <0 1>;              /* 2-lane, matches Slim7x's confirmed pattern — verify for SP11 */
                link-frequencies = /bits/ 64 <400000000>;  /* OV02C10_LINK_FREQ_400MHZ, confirmed from driver source */
            };
        };
    };
};
```

**CAMSS side** (adapted directly from the confirmed Slim7x fragment — CSIPHY
index, port number, and clock-lanes value are Slim7x-specific and must be
re-verified for the SP11; they will not necessarily be the same CSIPHY):

```dts
&camss {
    ports {
        port@N {  /* CSIPHY index — TODO, don't assume it matches Slim7x's CSIPHY4 */
            camss_csiphyN_inep0: endpoint@0 {
                clock-lanes = <7>;      /* Slim7x's value for its CSIPHY — re-verify */
                data-lanes = <0 1>;
                remote-endpoint = <&ov02c10_ep>;
            };
        };
    };
};
```

Generate the patch the same way the rest of this repo's kernel patches are
formatted:

```bash
cd ~/linux-sp11
git add arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali*.dts
git commit -m "arm64: dts: qcom: x1e80100-microsoft-denali: Add <sensor> camera"
git format-patch -1 -o ~/fedora-surface-pro-11/kernel-patches/camera/
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
dmesg | grep -i ov02c10

# Is there a V4L2 device node at all?
v4l2-ctl --list-devices

# Media graph — confirms CAMSS successfully linked sensor -> CSIPHY -> ISP
media-ctl -p

# Actual frames (once the above look sane)
v4l2-ctl --device=/dev/videoN --stream-mmap --stream-count=1 --stream-to=/tmp/frame.raw
```

A chip-ID mismatch in dmesg (expecting `0x5602`, reading something else)
means either the wrong I2C address, or it's a different sensor than A1
guessed — go back to A1 with that data point.

### A5. Status LEDs

Not independently investigated. If the sensor node in A3 works, check
whether the same regulator/GPIO group also drives the white "camera active"
LED (common pattern — Windows lights it whenever the sensor is streaming).
Likely a `leds-gpio` devicetree node next to the camera node, triggered by
whatever the SP11's ACPI/Windows driver names its "camera privacy light."

---

## Phase B — IR camera + illuminator (Windows Hello)

Only start this once Phase A actually produces frames. Repeat **A1**
(sensor identification) independently for the IR sensor — it's a different
part, will show up separately in the DriverStore/ACPI/I2C-scan searches
above, and needs its own devicetree node following the **A3** pattern (a
different `compatible` string once you identify it — there is currently no
known-good reference for an IR sensor's Linux driver on this platform the
way OV02C10 is known-good for RGB, so budget time for "no driver exists
yet" as a real possibility here, unlike Phase A).

### Illuminator

No confirmed reference for this part exists (unlike the RGB sensor, no
sibling-board patch has surfaced covering an IR illuminator). The realistic
options, in order of how much kernel work they need:

1. **Simple GPIO-driven LED** — if A1's identification work shows the
   illuminator is just a GPIO-switched IR LED (no I2C, no PWM strobing
   logic on-die), a standard `leds-gpio` devicetree node is enough:
   ```dts
   leds {
       compatible = "gpio-leds";
       led-ir-illuminator {
           gpios = <&tlmm TODO GPIO_ACTIVE_HIGH>;
           /* if Windows Hello needs sync with capture, this alone isn't
            * enough — see option 2 */
       };
   };
   ```
2. **V4L2 flash sub-device** — if the illuminator needs to be strobed in
   sync with sensor exposure (likely, since that's how Windows Hello
   normally works), wrap the LED as a proper V4L2 flash subdev using the
   kernel's `CONFIG_V4L2_FLASH_LED_CLASS` framework
   (`Documentation/leds/leds-class-flash.rst`,
   `include/media/v4l2-flash-led-class.h`) so `howdy`/any V4L2 app can
   trigger it through the standard flash API instead of a side-channel GPIO
   toggle. This is real kernel driver work, not a devicetree-only change,
   unless an existing flash-LED driver already matches the illuminator's
   control chip (check I2C scan results from A1 against known flash-LED
   driver compatible strings, e.g. `qcom,pm8350c-flash-led` and similar
   Qualcomm PMIC flash-LED nodes — plausible on this platform, unconfirmed).
3. **Do not assume `linux-enable-ir-emitter` applies.** It works by probing
   USB/UVC Extension Unit controls. Confirm during A1 whether the IR camera
   enumerates as USB at all (`lsusb` before any driver work) — if it does,
   this whole Phase B section is likely moot and the standard x86-laptop
   playbook (`linux-enable-ir-emitter` + any UVC-class IR camera) applies
   directly instead. If it doesn't show up on USB, it's CSI-attached and
   options 1/2 above are the real path.

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

- **Phase A (RGB)** is more tractable than [CAMERA.md](CAMERA.md) made it
  sound before this research: a real driver almost certainly exists
  already, and a real sibling-board devicetree reference exists to adapt.
  The remaining work is genuinely SP11-specific (exact I2C address,
  regulator names, GPIO, CSIPHY index) and **requires the physical
  hardware** to determine and iterate on — there is no way to shortcut
  A1/A3/A4 from a description alone.
- **Phase B (IR)** has no comparable head start. Budget for it being a
  from-scratch driver + devicetree effort, possibly including writing a new
  V4L2 sensor driver if A1 doesn't find an existing one, which is a
  materially bigger undertaking than Phase A.
- Expect **iterative reboots** — each devicetree change needs a rebuild
  (`install.sh --kernel`) and reboot to test. Budget accordingly; this is
  measured in multiple sessions, not one sitting.
- Update [CAMERA.md](CAMERA.md) and this file as you go, even with partial
  results. The value of this project has always been exactly that — the
  next person building on documented dead ends and partial progress instead
  of starting cold.

## References

Same sources as [CAMERA.md](CAMERA.md#references), plus:

- `drivers/media/i2c/ov02c10.c` in mainline Linux — read directly for the
  `probe()` power-sequencing requirements cited above (regulator names,
  clock rate, chip-ID register/value, `of_device_id` table).
- `Documentation/leds/leds-class-flash.rst`, `include/media/v4l2-flash-led-class.h` — V4L2 flash subdev framework, relevant if Phase B's illuminator needs synchronized strobing.
