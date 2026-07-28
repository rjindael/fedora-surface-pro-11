# Suspend / Resume — Surface Pro 11

## Problems

1. **Backlight not controlled by lid switch** — panel stays on when Flex cover closed
2. **Spurious wakeups** — touchscreen, pen, gpio-keys all wake the system
3. **No automatic suspend on lid close** — needs configurable timeout
4. **DSP state corruption** — `hexagonrpcd` must be stopped/restarted across suspend

## Solution

### Lid-switch backlight/suspend daemon (`sp11-lid-backlight`)

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

### Suspend debug logging (`sp11-enable-suspend-debug`)

Enables selective kernel dynamic-debug for SSAM PM functions:

```bash
sudo cp scripts/sp11-enable-suspend-debug /usr/local/sbin/
sudo cp systemd/sp11-suspend-debug.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sp11-suspend-debug.service
```

### DSP suspend/resume hooks

Installed automatically with `hexagonrpcd` package:
- `hexagonrpcd-suspend.service` — stops daemon before suspend
- `hexagonrpcd-resume.service` — restarts after resume

### Kernel cmdline

`no_console_suspend pm_debug_messages` (in `grub/99-surface-pro-11.cfg`).

## Current State

- Lid suspend: working (60s timeout)
- Resume from lid open: working
- Power button wake: working
- Display resume: occasionally fails — may need lid re-open

## Verification

```bash
systemctl status sp11-lid-backlight.service
systemctl status sp11-suspend-debug.service
systemctl list-unit-files | grep hexagonrpcd
```

## Files

| File | Purpose |
| --- | --- |
| `scripts/sp11-lid-backlight` | Python 3 lid-switch backlight/suspend daemon |
| `scripts/sp11-enable-suspend-debug` | SSAM PM dynamic-debug enabler |
| `systemd/sp11-lid-backlight.service` | systemd unit for lid daemon |
| `systemd/sp11-suspend-debug.service` | systemd unit for debug logging |
| `grub/99-surface-pro-11.cfg` | Kernel arguments |
