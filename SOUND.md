# Audio — Surface Pro 11 (Speakers + Microphone)

## Hardware

| Component | Details |
| --- | --- |
| Speakers | Dual WSA884x smart speakers on SoundWire bus |
| Microphones | Dual internal DMIC (digital MEMS) |
| DSP | AudioReach graph on Hexagon ADSP |
| ALSA card | `X1E80100Microso` |
| Speaker PCM | `hw:X1E80100Microso,1` (4-channel) |
| Mic PCM | `hw:X1E80100Microso,3` (2-channel) |

## Problems

1. **Missing DSP firmware** — ADSP/CDSP `.mbn` files not in `linux-firmware`
2. **Missing AudioReach topology** — no SP11-specific `.tplg.bin`
3. **Missing UCM2 configuration** — PipeWire sees the card but creates no sinks/sources
4. **Audio boot race** — `alsactl` restores WSA mixer state before DSP finishes loading → APM CMD timeout, SoundWire bus clash, silence
5. **Right speaker channel instability** — ch2/ch3 swap between boots
6. **Microphone clipping** — default +16 dB gain clips Surface microphones
7. **Microphone static at 4.8 MHz DMIC clock** — needs 2.4 MHz

## Solution

### Step 1: Install DSP firmware

```bash
sudo cp scripts/sp11-grab-fw.sh /usr/local/sbin/sp11-grab-fw
sudo /usr/local/sbin/sp11-grab-fw --download
```

Installs to `/lib/firmware/qcom/x1e80100/microsoft/Denali/`: `qcadsp8380.mbn` (22 MB), `qccdsp8380.mbn` (3.2 MB), `adsp_dtb.mbn`, `cdsp_dtb.mbn`, `*.jsn`, `qcdxkmsuc8380.mbn`.

### Step 2: Install AudioReach topology

```bash
sudo mkdir -p /lib/firmware/qcom/x1e80100
sudo cp audio/firmware/X1E80100-Microsoft-Surface-Pro-11-tplg.bin /lib/firmware/qcom/x1e80100/
```

### Step 3: Install UCM2 configuration

```bash
sudo mkdir -p /usr/share/alsa/ucm2/Qualcomm/x1e80100
sudo cp audio/ucm/MICROSOFT-Surface-Pro-11.conf /usr/share/alsa/ucm2/Qualcomm/x1e80100/
sudo cp audio/ucm/Surface11-HiFi.conf /usr/share/alsa/ucm2/Qualcomm/x1e80100/
sudo mkdir -p /usr/share/alsa/ucm2/conf.d/x1e80100
sudo cp audio/ucm/x1e80100.conf /usr/share/alsa/ucm2/conf.d/x1e80100/
```

- `x1e80100.conf` — DMI regex match for Surface Pro 11
- `Surface11-HiFi.conf` — speakers (4-ch, WSA_CODEC_DMA_RX_0/MultiMedia2) + mic (2-ch, VA_CODEC_DMA_TX_0/MultiMedia4, unity gain 84)

### Step 4: Fix the audio boot race

```bash
sudo cp scripts/sp11-enable-wsa-routing.sh /usr/local/sbin/
sudo cp systemd/sp11-wsa-routing.service /etc/systemd/system/
sudo systemctl mask alsa-restore.service alsa-state.service
sudo systemctl daemon-reload
sudo systemctl enable sp11-wsa-routing.service
```

The WSA routing service waits for the DSP graph (SoundWire slaves → "Attached"), retries with sound-card rebind on bus clash, then enables WSA routing and balances right speaker PA volume.

### Step 5: Install PipeWire speaker sink (per-user)

```bash
./scripts/sp11-pipewire-speaker-sink.sh --install --enable-route
mkdir -p ~/.config/systemd/user
cp systemd/sp11-pipewire-restart.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable sp11-pipewire-restart.service
```

The mix matrix sends true stereo: L to ch0, R duplicated to both ch2+ch3 (handles unstable channel mapping).

### Step 6: 2.4 MHz DMIC clock (kernel patch)

Patch: `kernel-patches/dmic-clock/0001-arm64-dts-qcom-x1-denali-use-2.4-MHz-DMIC-clock.patch`

## Verification

```bash
systemctl status sp11-wsa-routing.service
speaker-test -D hw:X1E80100Microso,1 -c 4 -t sine -f 440 -l 1
arecord -D hw:X1E80100Microso,3 -c 2 -d 3 /tmp/test.wav
```

## Files

| File | Purpose |
| --- | --- |
| `scripts/sp11-grab-fw.sh` | Download DSP firmware |
| `scripts/sp11-enable-wsa-routing.sh` | Enable WSA routing after DSP load |
| `scripts/sp11-fix-audio-boot-race.sh` | Boot-race fix installer |
| `scripts/sp11-pipewire-speaker-sink.sh` | PipeWire speaker sink |
| `audio/firmware/X1E80100-Microsoft-Surface-Pro-11-tplg.bin` | Topology binary |
| `audio/ucm/MICROSOFT-Surface-Pro-11.conf` | UCM2 card profile |
| `audio/ucm/Surface11-HiFi.conf` | UCM2 HiFi verb |
| `audio/ucm/x1e80100.conf` | UCM2 DMI detection |
| `systemd/sp11-wsa-routing.service` | WSA routing service |
| `systemd/sp11-pipewire-restart.service` | PipeWire restart service |
| `kernel-patches/dmic-clock/*.patch` | DMIC clock fix |
