# NPU AI — Surface Pro 11 (Hexagon DSP / QNN / llama.cpp)

## Hardware

| Component | Details |
| --- | --- |
| NPU | Hexagon v73 DSP (compute DSP / CDSP) |
| Access | FastRPC via `/dev/fastrpc-cdsp` |
| Host libraries | `libcdsprpc.so` (custom build), `libQnnHtp.so`, `libQnnCpu.so`, `libQnnSystem.so` |
| DSP skeleton | `libQnnHtpV73Skel.so` (hexagon-v73), `libggml-htp-v73.so` (ggml) |
| SDK | Qualcomm AI Runtime (QAIRT) 2.48.0.260626 |
| Backend | llama.cpp `GGML_HEXAGON` backend |
| CDSP firmware | `CDSP.HT.2.9.c1-00046.1-HAMOA-1` (Surface Pro 11 "Denali" variant) |
| Kernel | `7.1.3-jg-1sp11v2-qcom-x1e` (custom, with fastrpc/gpi GLINK patches) |

## Current Status

| Backend | Status | Notes |
| --- | --- | --- |
| **CPU** (`libggml-cpu.so`) | ✅ Working | llama.cpp CPU inference |
| **HTP/NPU** (`libQnnHtpV73.so`) | ✅ Working | llama.cpp runs fully on Hexagon NPU via `--device HTP0`. Verified with multiple models from 1B to 3B. |

### Verified benchmark

| Model | Size | Device | -ngl | Prompt t/s | Generation t/s | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Llama-3.2-1B-Instruct-Q4_0 | 738 MB | HTP0 | 99 | 722.7 | 48.8 | All layers on NPU; no CDSP reset needed |
| Qwen2.5-Coder-3B-Instruct-Q4_0 | 1.8 GB | HTP0 | 99 | 252.7 | 21.3 | All layers on NPU; CDSP reset required (REPACK buffer ~1 GB) |
| VibeThinker-1.5B Q4_K_M | ~1.2 GB | HTP0 | 99 | 307.4 | 45.0 | Math/reasoning; CDSP reset recommended |
| Gemma-4-E2B-it QAT mobile | 2.0 GB | HTP0 | 99 | — | — | Newest model (Gemma 4, April 2026); multimodal; CDSP reset required |

### CDSP heap fragmentation (critical operational detail)

Each `llama-cli` invocation loads the entire model fresh into DSP-side rpcmem (FastRPC DMA buffers, not Linux CMA). Back-to-back loads fragment the DSP heap — the next load fails with `rpcmem_alloc failed` / `HTP0-REPACK buffer` errors. The Qwen 3B model's REPACK buffer is ~1014 MB; after one run without reset, the fragmented heap can't satisfy a second contiguous allocation of that size.

**Fix:** Reset the CDSP remoteproc before each run:

```bash
echo stop | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 2
echo start | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 3
```

**Warning — kernel DMA buffer bug:** Heavy FastRPC DMA buffer alloc/free over extended periods can trigger `BUG: Bad page state in process llama-cli` (in `dma_buf_release`, kernel tainted `[B]=BAD_PAGE`) which has once cascaded into a full system hard-hang requiring a power cycle. This is a `dma_buf_release` kernel bug, not a CMA issue (system CMA is only 128 MB and unrelated to rpcmem). Do not loop many invocations back-to-back. Reboot proactively during heavy test sessions. Prefer 1.5B models for extended testing.

## Architecture: The npu-re Stack

The NPU runs through a 6-layer software stack, all built under `~/npu-re/`:

```
┌─────────────────────────────────────────────────────┐
│  Layer 6: llama.cpp (ggml-hexagon backend)          │
│  Host app + libggml-hexagon.so → libcdsprpc.so      │
├─────────────────────────────────────────────────────┤
│  Layer 5: QAIRT SDK 2.48.0.260626                   │
│  QNN runtime: libQnnHtp.so, converter tools          │
├─────────────────────────────────────────────────────┤
│  Layer 4: DSP runtime (/usr/lib/dsp/cdsp/)          │
│  fastrpc_shell_unsigned_3, libQnnHtpV73SkelDrv.so,  │
│  libggml-htp-v73.so, libc.so, libgcc.so             │
├─────────────────────────────────────────────────────┤
│  Layer 3: User-space fastrpc library                 │
│  libcdsprpc.so (from github.com/qualcomm/fastrpc)   │
├─────────────────────────────────────────────────────┤
│  Layer 2: CDSP firmware + fastrpc/gpi kernel modules │
│  qccdsp8380.mbn (CDSP.HT.2.9.c1), patched fastrpc.ko │
├─────────────────────────────────────────────────────┤
│  Layer 1: Custom kernel (7.1.3-jg-1sp11v2-qcom-x1e) │
│  fastrpc.ko (GLINK framing fix), gpi.ko (DMA fix)   │
└─────────────────────────────────────────────────────┘
```

### npu-re directory structure

```
~/npu-re/
├── fastrpc/                  # Qualcomm fastrpc user-space library
│   └── src/.libs/
│       └── libcdsprpc.so     # → deployed to /usr/lib/
├── hexagon-runtime/          # DSP-side C runtime
│   ├── libc.so               # → deployed to /usr/lib/dsp/cdsp/
│   └── libgcc.so             # → deployed to /usr/lib/dsp/cdsp/
├── llama.cpp/                # llama.cpp repo
│   ├── build-snapdragon/     # CMake build output
│   └── pkg-snapdragon/       # Packaged binaries + libraries
│       ├── bin/llama-cli     # → what test scripts run
│       └── lib/              # libggml-hexagon.so, libggml-htp-v73.so, libllama.so
├── llama-hexagon/            # GGUF model files
├── fastrpc.c.orig.bak        # Original kernel fastrpc.c (pre-patch backup)
├── fastrpc-debug.ko          # Patched fastrpc kernel module
├── fastrpc.ko.zst.orig-backup
├── gpi.ko.zst.orig-backup-*
├── test_env.sh               # NPU prerequisite checker (14 checks)
├── qnn_htp_probe             # QNN HTP probe binary
├── cap_probe                 # CDSP capability probe
└── htp_config.json           # HTP device config (soc_id=60, dsp_arch=v73)
```

## Setup

### Layer 1: Custom kernel with fastrpc/gpi patches

The kernel `7.1.3-jg-1sp11v2-qcom-x1e` is built by Jens Glathe from the `linux-qcom-x1e`
source using `ubuntu_x1e_defconfig`. It includes two critical patches:

1. **fastrpc.ko GLINK framing fix** — the stock mainline fastrpc driver has a framing
   mismatch with the CDSP firmware's GLINK transport, causing garbled responses
   (`0xabcdabcd` context IDs) on signed-PD calls. The patch fixes the message
   boundary handling.

2. **gpi.ko DMA fix** — the GSI DMA engine driver needs adjustments for the X1E
   compute buffer path.

If you already have this kernel installed, verify the patches are active:

```bash
# The patched fastrpc.ko should have debug logging ("fastrpc_dbg:")
sudo dmesg | grep fastrpc_dbg | head -1
# Module srcversion should match the debug build:
modinfo -F srcversion /lib/modules/$(uname -r)/kernel/drivers/misc/fastrpc.ko.zst
```

If you need to build the kernel from source, see the `rebuild.sh` script in the
kernel headers package. The fastrpc.c patch is applied to
`drivers/misc/fastrpc.c` before building. Keep the original as
`fastrpc.c.orig.bak` for reference.

### Layer 2: FastRPC device permissions

```bash
sudo cp udev/99-fastrpc.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Sets mode `0666` on `/dev/fastrpc-adsp`, `/dev/fastrpc-cdsp`, `/dev/fastrpc-cdsp-secure`.

### Layer 2: Install hexagonrpcd

```bash
sudo apt install -y hexagonrpcd hexagon-dsp-binaries-qualcomm-hamoa-iot-evk \
                    libhexagonrpc-dev
sudo systemctl enable hexagonrpcd.service
```

### Layer 3: Build user-space fastrpc library

The llama.cpp Hexagon backend calls `remote_handle64_open()` and
`remote_session_control()` — functions that the stock `libcdsprpc.so` (from
glibc/kernel package) does not export. You need the Qualcomm fastrpc
user-space library.

```bash
mkdir -p ~/npu-re && cd ~/npu-re
git clone -b development https://github.com/qualcomm/fastrpc.git fastrpc
cd fastrpc

# Build (autotools)
./autogen.sh
./configure --prefix=/usr/local
make -j$(nproc)

# Deploy to system
sudo cp src/.libs/libcdsprpc.so* /usr/lib/
sudo ldconfig
```

Verify the patched symbols are exported:

```bash
nm -D /usr/lib/libcdsprpc.so | grep -E 'remote_handle64_open|remote_session_control'
# Should show: T remote_handle64_open
#              T remote_session_control
```

### Layer 4: Deploy CDSP firmware + DSP runtime

The CDSP firmware and DSP-side runtime libraries are **not** available from apt
or the QAIRT SDK. They come from the CDSP.HT.2.9.c1 Qualcomm release for the
"Denali" (Surface Pro 11) board.

**CDSP firmware** — deploy to the firmware path that the device tree expects:

```bash
sudo mkdir -p /lib/firmware/qcom/x1e80100/microsoft/Denali
sudo cp qccdsp8380.mbn /lib/firmware/qcom/x1e80100/microsoft/Denali/

# Verify firmware version:
strings /lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn | grep 'CDSP.HT'
# Should show: CDSP.HT.2.9.c1-00046.1-HAMOA-1
```

**DSP-side runtime** — deploy to `/usr/lib/dsp/cdsp/`:

| File | Description | Source |
| --- | --- | --- |
| `fastrpc_shell_unsigned_3` | FastRPC shell for unsigned PD | CDSP.HT.2.9.c1 release |
| `fastrpc_shell_3` | Signed FastRPC shell | CDSP.HT.2.9.c1 release |
| `libQnnHtpV73SkelDrv.so` | QNN HTP v73 skeleton driver | QAIRT SDK `lib/hexagon-v73/unsigned/` |
| `libc.so` | DSP-side C library (Hexagon DSP6 ELF) | Hexagon SDK `target/hexagon/lib/v73/G0/pic/` |
| `libgcc.so` | DSP-side GCC runtime (Hexagon DSP6 ELF) | Hexagon SDK `target/hexagon/lib/v73/G0/pic/` |
| `libc++.so.1` | DSP-side C++ runtime | CDSP release |
| `libc++abi.so.1` | DSP-side C++ ABI runtime | CDSP release |
| `version.so` | Shell version info | CDSP release |

```bash
sudo mkdir -p /usr/lib/dsp/cdsp

# From QAIRT SDK:
sudo cp ~/qairt/2.48.0.260626/lib/hexagon-v73/unsigned/libQnnHtpV73SkelDrv.so \
        /usr/lib/dsp/cdsp/

# From CDSP release / Hexagon SDK:
sudo cp fastrpc_shell_unsigned_3 fastrpc_shell_3 \
        libc.so libgcc.so libc++.so.1 libc++abi.so.1 version.so \
        /usr/lib/dsp/cdsp/

# Also stage the QNN skeleton at the legacy path:
sudo mkdir -p /usr/share/fastrpc
sudo cp /usr/lib/dsp/cdsp/libQnnHtpV73SkelDrv.so /usr/share/fastrpc/
```

**Critical:** the `fastrpc_shell_unsigned_3` build must match the CDSP firmware
branch (both `CDSP.HT.2.9.c1`). Mismatched versions cause GLINK framing
corruption on session open. Verify:

```bash
strings /usr/lib/dsp/cdsp/fastrpc_shell_unsigned_3 | grep 'CDSP.HT.*c1' | head -1
strings /lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn | grep 'CDSP.HT' | head -1
# Both should contain: CDSP.HT.2.9.c1
```

### Layer 5: Install QAIRT SDK

Download **Qualcomm AI Runtime (QAIRT) SDK** v2.48.0.260626 (Community edition):

```
https://apigwx-aws.qualcomm.com/qsc/public/v1/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.48.0.260626/v2.48.0.260626.zip
```

```bash
wget -O qairt.zip 'https://apigwx-aws.qualcomm.com/qsc/public/v1/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.48.0.260626/v2.48.0.260626.zip'
unzip qairt.zip -d ~/qairt
mv ~/qairt/qairt-linux-aarch64-2.48.0.260626 ~/qairt/2.48.0.260626

source ~/qairt/2.48.0.260626/bin/envsetup.sh
cat >> ~/.bashrc << 'EOF'
export QAIRT_SDK_ROOT=$HOME/qairt/2.48.0.260626
export QNN_SDK_ROOT=$HOME/qairt/2.48.0.260626
EOF
```

SDK layout:
- `$QNN_SDK_ROOT/lib/aarch64-ubuntu-gcc9.4/` — host libraries (`libQnnHtp.so`, `libQnnCpu.so`, etc.)
- `$QNN_SDK_ROOT/lib/hexagon-v73/unsigned/` — DSP skeleton (`libQnnHtpV73Skel.so`)

### Layer 6: Build llama.cpp

The llama.cpp Hexagon backend has two build outputs:

1. **Host-side** (`libggml-hexagon.so`) — compiled with clang for aarch64 Linux
2. **DSP-side skeleton** (`libggml-htp-v73.so`) — compiled with the Hexagon DSP
   compiler for the CDSP

The host-side build only needs clang + cmake. The DSP skeleton build needs the
full **Hexagon SDK** (not QAIRT) for the Hexagon DSP cross-compiler and QuRT
runtime headers. Once the skeleton is built, it is cached and subsequent
host-only builds skip it.

```bash
cd ~/npu-re
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cp ~/ubuntu-surface-pro-11/npu/CMakeUserPresets.json .

# Environment for both host + DSP skeleton build
export HEXAGON_SDK_ROOT=$QNN_SDK_ROOT          # QAIRT SDK as Hexagon SDK base
export HEXAGON_TOOLS_ROOT=$QNN_SDK_ROOT/bin/x86_64-linux-clang  # DSP compiler

cmake -B build-snapdragon --preset arm64-linux-snapdragon-release -DGGML_HEXAGON=ON
cmake --build build-snapdragon --config Release -j$(nproc)
```

Key flags: `GGML_HEXAGON=ON`, `-march=armv8.2a+fp16+dotprod`, `GGML_OPENCL=OFF`, `GGML_OPENMP=OFF`.

**Note:** If the Hexagon DSP compiler (`hexagon-clang`) is not available, the
DSP skeleton build step will fail. In that case, obtain a pre-built
`libggml-htp-v73.so` and place it in `build-snapdragon/ggml/src/ggml-hexagon/`
before running the build. The host-side build will then proceed normally.

#### Package into pkg-snapdragon

```bash
cd ~/npu-re/llama.cpp
DEST=pkg-snapdragon

# Binaries
mkdir -p $DEST/bin
cp build-snapdragon/bin/llama-cli $DEST/bin/
cp build-snapdragon/bin/llama-server $DEST/bin/ 2>/dev/null || true

# Libraries (host-side)
mkdir -p $DEST/lib
cp build-snapdragon/bin/libggml*.so build-snapdragon/bin/libllama*.so \
   build-snapdragon/bin/libmtmd*.so \
   $DEST/lib/ 2>/dev/null

# DSP skeletons (from build cache)
cp build-snapdragon/ggml/src/ggml-hexagon/libggml-htp-v73.so $DEST/lib/

# Also deploy the ggml skeleton to the DSP search path:
sudo cp build-snapdragon/ggml/src/ggml-hexagon/libggml-htp-v73.so /usr/lib/dsp/cdsp/
sudo cp build-snapdragon/ggml/src/ggml-hexagon/libggml-htp-v73.so /usr/lib/dsp/
```

### Phase 7: Verify + run inference

Run the prerequisite checker first:

```bash
cd ~/npu-re && sudo bash test_env.sh
# Expected: 14 passed, 0 failed
```

Then run inference:

```bash
export LD_LIBRARY_PATH="$HOME/npu-re/llama.cpp/pkg-snapdragon/lib"
export ADSP_LIBRARY_PATH="$HOME/npu-re/llama.cpp/pkg-snapdragon/lib:\
/usr/share/fastrpc:/usr/lib/dsp:/usr/lib/rfsa/adsp"

# Reset CDSP to defragment rpcmem heap (required for 3B+ models)
echo stop | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 2
echo start | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 3

~/npu-re/llama.cpp/pkg-snapdragon/bin/llama-cli \
    -m ~/npu-re/llama-hexagon/Llama-3.2-1B-Instruct-Q4_0.gguf \
    --device HTP0 -ngl 99 -c 2048 \
    -p "The capital of France is" -n 16
```

Verified: **48.8 t/s** (Llama-3.2-1B), **21.3 t/s** (Qwen2.5-Coder-3B).

**If you see `rpcmem_alloc failed`:** CDSP heap fragmentation, not a hard memory limit. Reset the CDSP remoteproc before each run. Do not run many invocations back-to-back.

**If you see `failed to open session 0 : error 0x8000054f`:** GLINK framing
corruption. Do a **cold shutdown** (power off, wait 10s, power on) — not a
reboot. Warm reboots do not fully reset the GLINK transport.

## Interactive chat

Four interactive chat scripts are included, each with a different model:

```bash
./scripts/test_llama.sh    # Llama-3.2-1B — general chat, fastest (~48 t/s)
./scripts/test_vibe.sh     # VibeThinker-1.5B — math/reasoning (~45 t/s)
./scripts/test_gemma.sh    # Gemma-4-E2B-it — multimodal, newest (Gemma 4)
./scripts/test_qwen.sh     # Qwen2.5-Coder-3B — code specialist (~21 t/s)
```

Each script auto-downloads the model if missing, resets the CDSP remoteproc,
loads all layers onto HTP0 (`-ngl 99`), and drops into an interactive chat
prompt. Type your messages, Ctrl+C to exit.

| Script | Model | Source |
| --- | --- | --- |
| `test_llama.sh` | Llama-3.2-1B-Instruct Q4_0 | [bartowski/Llama-3.2-1B-Instruct-GGUF](https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF) |
| `test_vibe.sh` | VibeThinker-1.5B Q4_K_M | [mradermacher/VibeThinker-1.5B-GGUF](https://huggingface.co/mradermacher/VibeThinker-1.5B-GGUF) (based on [WeiboAI/VibeThinker-1.5B](https://huggingface.co/WeiboAI/VibeThinker-1.5B)) |
| `test_gemma.sh` | Gemma-4-E2B-it QAT mobile | [unsloth/gemma-4-E2B-it-qat-mobile-GGUF](https://huggingface.co/unsloth/gemma-4-E2B-it-qat-mobile-GGUF) |
| `test_qwen.sh` | Qwen2.5-Coder-3B-Instruct Q4_0 | [bartowski/Qwen2.5-Coder-3B-Instruct-GGUF](https://huggingface.co/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF) |

## Debugging

```bash
# Prerequisite checker (14 checks):
cd ~/npu-re && sudo bash test_env.sh

# Quick system checks:
ls -la /dev/fastrpc-*
systemctl status hexagonrpcd.service
cat /sys/class/remoteproc/remoteproc1/state   # should be "running"
cat /sys/class/remoteproc/remoteproc1/firmware # CDSP firmware path

# FastRPC transport debugging:
sudo dmesg -w | grep -i fastrpc
sudo dmesg | grep -iE 'fastrpc|rpcmem|Bad page|context ID|No context ID'
# "No context ID matches response" = GLINK framing corruption → cold boot
# "HTP0 failed to allocate buffer" = CDSP heap fragmentation → reset remoteproc
# "BUG: Bad page state" = kernel dma_buf_release bug → reboot the machine

# CDSP firmware/shell version match:
strings /lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn | grep CDSP.HT | head -1
strings /usr/lib/dsp/cdsp/fastrpc_shell_unsigned_3 | grep CDSP.HT | head -1

# Verify patched libcdsprpc.so:
nm -D /usr/lib/libcdsprpc.so | grep remote_handle64_open
```

## Files

| File | Purpose |
| --- | --- |
| `udev/99-fastrpc.rules` | FastRPC device permissions (0666) |
| `npu/CMakeUserPresets.json` | llama.cpp Snapdragon build presets |
| `scripts/test_llama.sh` | Interactive NPU chat — Llama-3.2-1B |
| `scripts/test_vibe.sh` | Interactive NPU chat — VibeThinker-1.5B |
| `scripts/test_gemma.sh` | Interactive NPU chat — Gemma-4-E2B-it |
| `scripts/test_qwen.sh` | Interactive NPU chat — Qwen2.5-Coder-3B |

## External Dependencies

| Dependency | Source | Layer |
| --- | --- | --- |
| Custom kernel `7.1.3-jg-1sp11v2-qcom-x1e` | Built from `linux-qcom-x1e` with fastrpc/gpi patches | 1 |
| fastrpc user-space library | [github.com/qualcomm/fastrpc](https://github.com/qualcomm/fastrpc) (`development` branch) | 3 |
| CDSP firmware (`qccdsp8380.mbn`) | CDSP.HT.2.9.c1 Qualcomm release (Denali/Surface Pro 11) | 2 |
| DSP runtime (`fastrpc_shell_unsigned_3`, etc.) | CDSP.HT.2.9.c1 Qualcomm release + Hexagon SDK | 4 |
| QAIRT SDK 2.48.0.260626 | [Qualcomm Developer Network](https://www.qualcomm.com/developer/software/qualcomm-ai-engine-direct) | 5 |
| Hexagon SDK (for DSP skeleton compiler) | [Qualcomm Developer Network](https://developer.qualcomm.com/software/hexagon-dsp-sdk) | 6 |
| llama.cpp | [github.com/ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | 6 |
| hexagonrpcd | `apt install hexagonrpcd` | 2 |
| hexagon-dsp-binaries | `apt install hexagon-dsp-binaries-qualcomm-hamoa-iot-evk` | 2 |
