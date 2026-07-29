# Sensors — Surface Pro 11

Accelerometer, gyroscope, magnetometer, ambient light sensor, and tablet mode switch — all working via the Qualcomm Snapdragon Sensor Core (SSC).

## Status

| Sensor | Data type | Status | Source |
| --- | --- | --- | --- |
| **Physical sensors** | | | |
| Accelerometer | `accel` | ✅ Working | ST LSM6DSV (display, SPI) |
| Gyroscope | `gyro` | ✅ Working | ST LSM6DSV (display, SPI) |
| Magnetometer | `mag` | ✅ Working | AKM AK0991x (I2C) |
| Ambient Light | `light` | ✅ Working | AMS TCS3430 (I2C) |
| RGB Color | `color` | ✅ Data | AMS TCS3430 (TrueTone) |
| SAR | `sar` | ✅ Data | Body proximity for RF safety |
| **Fused / virtual sensors** | | | |
| Gravity | `gravity` | ✅ Data | Accel + gyro fusion |
| Rotation Vector | `rotv` | ✅ Data | Accel + gyro + mag fusion |
| Geomag Rot. Vector | `geomag_rv` | ✅ Data | Geomagnetic rotation |
| Game Rot. Vector | `game_rv` | ✅ Data | Accel + gyro (no mag) |
| Compass | `compass` | ✅ Data | Heading from magnetometer fusion |
| **Activity / gesture** | | | |
| Fast Motion | `fmv` | ✅ Data | Fast motion vector |
| Relative Motion | `rmd` | ✅ Data | Relative motion detection |
| **Other** | | | |
| Tablet Mode | — | ✅ Working | SAM GPIO (surface_aggregator) |

## Not available

Tested against the SSC but not working on this hardware, so excluded from the
discovery candidate list:

| Data type | Reason |
| --- | --- |
| `proximity` (TMD2755) | No SUID — not registered in the SNS framework |
| `linear_accel`, `pressure`, `significant_motion`, `flat`, `device_orient`, `hinge_angle` | No SUID |
| `step_detect`, `tilt`, `amd` | Registered (SUID present) but `open` fails — not operable via libssc |

Run `sensors/sp11-sensor-discover` to list every available sensor and verify it produces data.

## Architecture

```
┌──────────────────────────────────────────────────┐
│  Linux userspace                                  │
│  sp11-sensor-read / libssc  ←  QMI/QRTR  →  data  │
├──────────────────────────────────────────────────┤
│  hexagonrpcd  ←  /dev/fastrpc-adsp  ←  ADSP      │
│    -s (attach to sensorspd)                       │
│    Serves sensor config + registry via FastRPC    │
├──────────────────────────────────────────────────┤
│  ADSP firmware (qcadsp8380.mbn)                   │
│    SNS (Snapdragon Sensor Core) framework         │
│    ↕ I2C/SPI to physical sensor chips             │
└──────────────────────────────────────────────────┘
```

Physical sensor chips are on the ADSP's I2C/SPI buses, not the main SoC's.
The ADSP firmware handles all sensor I/O, calibration, and fusion. The host
accesses sensor data via QMI through hexagonrpcd's FastRPC file-serving tunnel.

## How it works

### Boot sequence (timing-critical)

1. **~1.9s**: Kernel loads ADSP firmware → SNS framework starts
2. **~5.4s**: FastRPC kernel module creates `/dev/fastrpc-adsp`
3. **~6s**: `hexagonrpcd` starts (early — `After=sysinit.target`)
4. **~7s**: hexagonrpcd attaches to sensorspd, serves sensor registry
5. **~8s**: SNS framework reads `sns_reg_config` (binary registry cache), initialises sensors
6. **~9s**: hexagonrpcd may crash on `fstempfile` write errors — **sensors stay alive** because the SNS framework on the ADSP runs independently

The SNS framework reads the pre-parsed binary registry during initialisation. Once
sensors are initialised, they keep running on the ADSP even if hexagonrpcd exits.
`Restart=always` in the systemd service keeps hexagonrpcd available for reconnection.

### Key requirement: pre-parsed registry

The ADSP firmware's SNS framework normally needs `oemconfig.so` (a Hexagon ELF)
to initialise sensors from JSON config files. This file does not exist outside
Android — it is not in the Windows filesystem or the ADSP firmware.

**Solution**: Copy the pre-parsed sensor registry from the Windows partition.
Windows already ran the SNS initialisation and cached the results as binary files
in `DriverData\Qualcomm\fastRPC\persist\sensors\registry\registry\`. These 321 files
(4 KB `sns_reg_config`, 36 KB `sns_secure_database.bin`, plus per-sensor platform
configs with calibration data) let the SNS framework skip oemconfig.so entirely.

### Custom hexagonrpcd

The stock hexagonrpcd v0.4.0 (Ubuntu `resolute`) crashes on an unsupported FastRPC
method (method 24) during early boot when the SNS framework is still initialising.
A custom build from [github.com/linux-msm/hexagonrpc](https://github.com/linux-msm/hexagonrpc)
adds:

- **Method 24 stub**: returns success for an unknown SNS file-system operation
- **Write support**: `mapped_openat` tries O_RDWR/O_CREAT, `fwrite` implemented, `hexagonfs_write` added
- **O_RDWR fallback**: files open read-write when possible, fall back to read-only

Sensors work even with the stock hexagonrpcd (the crash happens after the SNS
reads the registry), but the custom build prevents log spam and enables future
registry updates.

## Installation

```bash
sudo ./install.sh --sensors
```

This installs:
- hexagonrpcd + libhexagonrpc packages
- Sensor config JSONs from Windows DriverStore
- Pre-parsed sensor registry from Windows DriverData (321 files)
- `sns_reg.conf` with platform identification
- Custom hexagonrpcd build (method 24 + write support)
- Early-start systemd services (`sensors-platform-info`, `hexagonrpcd`)
- libssc + ssccli (QMI sensor client)
- `sp11-sensor-read` — fast C tool (reads all sensors in ~1s)

## Testing

```bash
# All sensors at once (~1.5s):
./scripts/test_sensors.sh

# Fast reader — pick specific sensors:
sensors/sp11-sensor-read                # all sensors
sensors/sp11-sensor-read accel          # accelerometer only (0.3s)
sensors/sp11-sensor-read accel light 5  # two sensors, 5s timeout

# Output format: one line per sensor, tab/space separated
#   accel 1.170 7.510 4.181
#   gyro 0.0577 0.0384 -0.0508
#   mag -48.6 4.5 24.0
#   light 28

# Legacy ssccli (slower, one sensor at a time):
export LD_LIBRARY_PATH="/usr/local/lib/aarch64-linux-gnu"
ssccli --sensor accelerometer --timeout 5
```

## Platform identification

The Surface Pro 11 identifies as:
- `soc_id`: 555
- `hw_platform`: CRD (Customer Reference Design)
- `revision`: 2.1

These match the sensor config files' `"soc_id": ["555", "635", "615", "616"]` filter.

## File layout

```
/usr/share/qcom/x1e80100/Microsoft/Surface-Pro-11/
  sensors/
    sns_reg.conf                    # Platform identification + path mapping
    config/                         # 67 JSON sensor configs (from Windows DriverStore)
      8380_crd_lsm6dsv_display.json
      8380_crd_ak991x_display.json
      8380_crd_tcs3430_0.json
      ...
    registry/                       # Pre-parsed registry (from Windows DriverData)
      sns_reg_config                # Binary registry cache (4 KB)
      sns_secure_database.bin       # Secure sensor database (36 KB)
      parsed_file_list.csv          # List of parsed config entries
      8380_crd_*.json.*_platform    # Per-sensor platform + calibration data
      ...                           # (321 files total)
```

```
<repo>/sensors/
  sp11-sensor-read.c               # Fast sensor reader source (libssc API)
  sp11-sensor-read                 # Compiled binary (built by install.sh --sensors)
```

## Windows sources

| Windows path | Linux deploy path | Purpose |
| --- | --- | --- |
| `DriverStore\FileRepository\surfacepro_snscfgcrd8380.inf_*\*.json` | `sensors/config/` | Sensor configuration (bus, address, orientation, sampling) |
| `DriverStore\FileRepository\surfacepro_snscfgcrd8380.inf_*\sns_reg_config` | `sensors/sns_reg.conf` | Registry config text |
| `DriverData\Qualcomm\fastRPC\persist\sensors\registry\registry\*` | `sensors/registry/` | Pre-parsed binary registry + calibration |
| `DriverData\Qualcomm\fastRPC\vendor\etc\sensors\config\*` | `sensors/config/` | Surface-specific calibration (accel, gyro, colour) |

## Troubleshooting

**Registry empty (no sensor data)**:
- Check that the registry files were copied: `ls /usr/share/qcom/.../sensors/registry/sns_reg_config`
- hexagonrpcd must start early — verify `systemctl show hexagonrpcd -p After` does NOT include `multi-user.target`
- Reboot after deploying config files (the SNS framework reads config only during ADSP boot)

**hexagonrpcd crashes after boot**:
- This is expected — hexagonrpcd crashes on `fstempfile` write errors after the SNS initialises
- Sensors stay alive because the SNS framework runs on the ADSP independently
- `Restart=always` keeps hexagonrpcd reconnecting

**"Could not open oemconfig.so"**:
- Non-fatal warning — the pre-parsed registry replaces oemconfig.so functionality

**DO NOT reset the ADSP**:
- `echo stop > /sys/class/remoteproc/remoteproc0/state` crashes the entire SoC
- Use a normal reboot to restart the ADSP

**FastRPC debug**:
```bash
sudo dmesg | grep 'fastrpc_dbg.*pd=2'  # FastRPC messages to sensorspd
sudo journalctl -u hexagonrpcd -b      # hexagonrpcd log
```
