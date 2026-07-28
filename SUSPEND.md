# Suspend / Resume — Surface Pro 11

## Current State

**Working.** Close the Flex cover → backlight off → 60s inactivity →
`s2idle` suspend → power button resumes cleanly.

## Problems & Root Causes

1. **`cpu-sleep-0` PSCI state hard-crashes the SoC during s2idle entry** ← the
   one that caused every suspend to reboot the machine. See below.
2. **Backlight not controlled by lid switch** — panel stays on when cover closed
3. **Spurious wakeups** — touchscreen, pen, gpio-keys all wake the system
4. **No automatic suspend on lid close** — needs configurable timeout
5. **`hexagonrpcd` suspend hooks never fired** — package guards them with the
   wrong SoC firmware condition (`qcom,sdm670` instead of `qcom,x1e80100`)

## Root Cause: `cpu-sleep-0` crashes s2idle (2026-07-28)

### Symptom

Every real suspend crashed at `PM: suspend entry (s2idle)` — the machine
rebooted (watchdog reset) instead of sleeping. The kernel log was lost on each
hard reset (no pstore/ramoops region in this device tree), so the failing point
was invisible in the journal.

### Diagnosis method: `pm_test` bisection

The kernel's `/sys/power/pm_test` suspends each phase then *immediately resumes*
without real SoC power-down, so each level is safe to test:

| pm_test level | What it exercises | Result |
| --- | --- | --- |
| `freezer` | freeze userspace tasks | ✅ pass |
| `devices` | suspend all device drivers | ✅ pass |
| `platform` | platform suspend ops | ✅ pass |
| `none` (real) | full s2idle incl. cpuidle entry | ❌ **hard crash** |

Every device and platform callback succeeds. Only the **final cpuidle idle
entry** — the SoC powering down to its deepest state — crashes. The cpuidle
driver (`psci_idle`) exposes exactly two states:

```
state0: WFI          (ARM WFI, 1µs latency)
state1: cpu-sleep-0  (PSCI retention, 500µs latency)  ← crashes
```

The `menu` governor picks the deepest state (`cpu-sleep-0`) for the long s2idle
idle. **Disabling `cpu-sleep-0` makes s2idle fall back to WFI, which is stable.**
Full suspend→resume then works.

> **Note:** the crash behaved as transient firmware state — it appeared after a
> period of instability, persisted across warm reboots, and eventually cleared
> (suspend succeeded even with `cpu-sleep-0` still enabled after accumulated
> cold boots). The `cpu-sleep-0` disable is kept as a proven workaround/safety
> net: it definitively fixes the crash when the bad state is present, and is
> harmless (WFI-only idle) when the state is clear. The hook path is critical —
> see the install note below.

### Fix: disable `cpu-sleep-0` during suspend only

A `systemd` system-sleep hook disables `cpu-sleep-0` before every suspend and
re-enables it on resume, so runtime idle stays power-efficient (the retention
state is used normally outside of suspend).

```bash
sudo cp scripts/sp11-fix-cpuidle-s2idle /usr/local/sbin/
sudo cp system-sleep/sp11-cpuidle-s2idle /usr/lib/systemd/system-sleep/
sudo chmod +x /usr/local/sbin/sp11-fix-cpuidle-s2idle \
              /usr/lib/systemd/system-sleep/sp11-cpuidle-s2idle
```
> **Install path matters:** systemd 259+ only runs hooks from
> `/usr/lib/systemd/system-sleep/`, **not** `/etc/systemd/system-sleep/`
> (confirmed via `strings /usr/lib/systemd/systemd-sleep`). The existing hooks
> (`hdparm`, `sysstat`) live in `/usr/lib/`.

Verify the toggle works:
```bash
sp11-fix-cpuidle-s2idle status      # cpu-sleep-0: 0/12 CPUs disabled
sp11-fix-cpuidle-s2idle disable     # (what suspend will do)
sp11-fix-cpuidle-s2idle status      # cpu-sleep-0: 12/12 CPUs disabled
sp11-fix-cpuidle-s2idle enable      # restore normal runtime
```

## Solution Components

### 1. Lid-switch backlight/suspend daemon (`sp11-lid-backlight`)

A Python 3 daemon that:

1. Finds the lid switch (`gpio-keys` with `SW_LID`)
2. Disables all wake sources except power button (`pwrkey`)
3. On lid close: saves brightness → writes 0 to backlight → starts 60s countdown
4. On lid open: restores brightness, cancels pending suspend
5. On 60s inactivity with lid closed: `systemctl suspend`
6. Input activity while closed: resets countdown (use external display with cover closed)

```bash
sudo cp scripts/sp11-lid-backlight /usr/local/sbin/
sudo cp systemd/sp11-lid-backlight.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sp11-lid-backlight.service
```

`HandleLidSwitch=ignore` must be set in `/etc/systemd/logind.conf` (all power
states) so systemd-logind does not race the daemon with its own immediate
suspend.

### 2. `hexagonrpcd` suspend/resume hooks — condition fix

The `hexagonrpcd` package ships suspend/resume hooks (`hexagonrpcd-suspend` /
`hexagonrpcd-resume`) that stop the sensors daemon before suspend and restart it
after. They are guarded by a **wrong** firmware condition
(`ConditionFirmware=device-tree-compatible(qcom,sdm670)`) that never matches this
board (`qcom,x1e80100`), so the hooks were silently skipped and the daemon held
`/dev/fastrpc-adsp` open across suspend.

```bash
sudo mkdir -p /etc/systemd/system/hexagonrpcd-suspend.service.d
sudo mkdir -p /etc/systemd/system/hexagonrpcd-resume.service.d
sudo cp systemd/hexagonrpcd-condition-override.conf \
    /etc/systemd/system/hexagonrpcd-suspend.service.d/override.conf
sudo cp systemd/hexagonrpcd-condition-override.conf \
    /etc/systemd/system/hexagonrpcd-resume.service.d/override.conf
sudo systemctl daemon-reload
```

### 3. Suspend debug logging (`sp11-enable-suspend-debug`)

Enables selective kernel dynamic-debug for SSAM PM functions:

```bash
sudo cp scripts/sp11-enable-suspend-debug /usr/local/sbin/
sudo cp systemd/sp11-suspend-debug.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sp11-suspend-debug.service
```

### 4. Kernel cmdline

`no_console_suspend pm_debug_messages mem_sleep_default=s2idle` plus the standard
X1E bring-up args — in `grub/99-surface-pro-11.cfg`.

## Verification

```bash
# The cpuidle fix is active (should show 0/12 disabled at runtime — disabled
# only during suspend by the system-sleep hook):
sp11-fix-cpuidle-s2idle status

# All suspend services:
systemctl status sp11-lid-backlight.service
systemctl status sp11-suspend-debug.service
systemctl list-unit-files | grep hexagonrpcd

# After a suspend/resume cycle, kernel counters should show success:
cat /sys/power/suspend_stats/success   # increments per successful suspend
cat /sys/power/suspend_stats/fail      # should stay 0

# Confirm the system-sleep hook fired (look for the logger line):
journalctl -b 0 -g sp11-cpuidle-s2idle
```

## Files

| File | Purpose |
| --- | --- |
| `scripts/sp11-fix-cpuidle-s2idle` | Toggle the broken `cpu-sleep-0` PSCI idle state (disable/enable/status) |
| `system-sleep/sp11-cpuidle-s2idle` | systemd system-sleep hook: disable `cpu-sleep-0` pre-suspend, restore post-resume |
| `systemd/hexagonrpcd-condition-override.conf` | Drop-in fixing the wrong `qcom,sdm670` → `qcom,x1e80100` condition on hexagonrpcd hooks |
| `scripts/sp11-lid-backlight` | Python 3 lid-switch backlight/suspend daemon |
| `scripts/sp11-enable-suspend-debug` | SSAM PM dynamic-debug enabler |
| `systemd/sp11-lid-backlight.service` | systemd unit for lid daemon |
| `systemd/sp11-suspend-debug.service` | systemd unit for debug logging |
| `grub/99-surface-pro-11.cfg` | Kernel arguments |
