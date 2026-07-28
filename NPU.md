# NPU AI — Surface Pro 11 (Hexagon DSP / QNN / llama.cpp)

## Hardware

| Component | Details |
| --- | --- |
| NPU | Hexagon v73 DSP (compute DSP / CDSP) |
| Access | FastRPC via `/dev/fastrpc-cdsp` |
| Host libraries | `libQnnHtp.so`, `libQnnCpu.so`, `libQnnSystem.so` |
| DSP skeleton | `libQnnHtpV73Skel.so` (hexagon-v73) |
| SDK | Qualcomm AI Engine Direct (QAIRT) 2.48.0.260626 |
| Backend | llama.cpp `GGML_HEXAGON` backend |

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

### Available test models

| Script | Model | Params | Quant | Size | Best for | CDSP reset |
| --- | --- | --- | --- | --- | --- | --- |
| `test_llama.sh` | [Llama-3.2-1B-Instruct](https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF) | 1B | Q4_0 | 738 MB | General chat; fastest | Optional |
| `test_vibe.sh` | [VibeThinker-1.5B](https://huggingface.co/WeiboAI/VibeThinker-1.5B) | 1.5B | Q4_K_M | ~1.2 GB | Math/reasoning (fine-tuned from Qwen2.5-Math) | Yes |
| `test_gemma.sh` | [Gemma-4-E2B-it QAT mobile](https://huggingface.co/unsloth/gemma-4-E2B-it-qat-mobile-GGUF) | 2.3B effective | UD-Q2_K_XL | 2.0 GB | Multimodal (text/image/audio), 128K context, Apache 2.0 | Yes |
| `test_qwen.sh` | [Qwen2.5-Coder-3B-Instruct](https://huggingface.co/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF) | 3B | Q4_0 | 1.8 GB | Code generation/coding | Yes |

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

## Setup

### Step 1: FastRPC device permissions

```bash
sudo cp udev/99-fastrpc.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Sets mode `0666` on `/dev/fastrpc-adsp`, `/dev/fastrpc-cdsp`, `/dev/fastrpc-cdsp-secure`.

### Step 2: Install hexagonrpcd

```bash
sudo apt install -y hexagonrpcd hexagon-dsp-binaries-qualcomm-hamoa-iot-evk libhexagonrpc-dev
sudo systemctl enable hexagonrpcd.service
```

### Step 3: Install QNN SDK

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

### Step 4: Build llama.cpp

```bash
git clone https://github.com/ggml-org/llama.cpp.git ~/llama.cpp
cd ~/llama.cpp
cp /path/to/ubuntu-surface-pro-11/npu/CMakeUserPresets.json .

export HEXAGON_SDK_ROOT=$QNN_SDK_ROOT
export HEXAGON_TOOLS_ROOT=$QNN_SDK_ROOT/bin/x86_64-linux-clang

cmake -B build-snapdragon --preset arm64-linux-snapdragon -DGGML_HEXAGON=ON
cmake --build build-snapdragon --config Release -j$(nproc)
```

Key flags: `GGML_HEXAGON=ON`, `-march=armv8.2a+fp16+dotprod`, `GGML_OPENCL=OFF`, `GGML_OPENMP=OFF`.

### Step 5: Run inference on the NPU (HTP0)

```bash
export LD_LIBRARY_PATH="\
$PWD/build-snapdragon/bin:\
$QNN_SDK_ROOT/lib/aarch64-ubuntu-gcc9.4:\
$QNN_SDK_ROOT/lib/hexagon-v73/unsigned:$LD_LIBRARY_PATH"
export ADSP_LIBRARY_PATH="\
$QNN_SDK_ROOT/lib/hexagon-v73/unsigned:\
/usr/share/fastrpc:/usr/lib/dsp:/usr/lib/rfsa/adsp"

cd build-snapdragon

# Reset CDSP remoteproc to defragment rpcmem heap (required for 3B+ models)
echo stop | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 2
echo start | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 3

./bin/llama-cli \
    -m /path/to/model.gguf \
    --device HTP0 -ngl 99 \
    -p "The capital of France is" -n 16
```

Verified: **48.8 t/s** (Llama-3.2-1B), **21.3 t/s** (Qwen2.5-Coder-3B).

**If you see `rpcmem_alloc failed`:** CDSP heap fragmentation, not a hard memory limit. Reset the CDSP remoteproc before each run. Do not run many invocations back-to-back.

### Interactive chat

Four interactive chat scripts are included, each with a different model:

```bash
./scripts/test_llama.sh    # Llama-3.2-1B — general chat, fastest (~48 t/s)
./scripts/test_vibe.sh     # VibeThinker-1.5B — math/reasoning (~45 t/s)
./scripts/test_gemma.sh    # Gemma-4-E2B-it — multimodal, newest (Gemma 4)
./scripts/test_qwen.sh     # Qwen2.5-Coder-3B — code specialist (~21 t/s)
```

Each script auto-downloads the model if missing, resets the CDSP remoteproc, loads all layers onto HTP0 (`-ngl 99`), and drops into an interactive chat prompt. Type your messages, Ctrl+C to exit.

| Script | Model | Source |
| --- | --- | --- |
| `test_llama.sh` | Llama-3.2-1B-Instruct Q4_0 | [bartowski/Llama-3.2-1B-Instruct-GGUF](https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF) |
| `test_vibe.sh` | VibeThinker-1.5B Q4_K_M | [mradermacher/VibeThinker-1.5B-GGUF](https://huggingface.co/mradermacher/VibeThinker-1.5B-GGUF) (based on [WeiboAI/VibeThinker-1.5B](https://huggingface.co/WeiboAI/VibeThinker-1.5B)) |
| `test_gemma.sh` | Gemma-4-E2B-it QAT mobile | [unsloth/gemma-4-E2B-it-qat-mobile-GGUF](https://huggingface.co/unsloth/gemma-4-E2B-it-qat-mobile-GGUF) |
| `test_qwen.sh` | Qwen2.5-Coder-3B-Instruct Q4_0 | [bartowski/Qwen2.5-Coder-3B-Instruct-GGUF](https://huggingface.co/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF) |

## Debugging

```bash
ls -la /dev/fastrpc-*
systemctl status hexagonrpcd.service
sudo dmesg -w | grep -i fastrpc
sudo dmesg | grep -iE 'fastrpc|rpcmem|Bad page|context ID'
# "HTP0 failed to allocate buffer" = CDSP DSP-side heap fragmentation — reset remoteproc before run
# "BUG: Bad page state" = kernel dma_buf_release bug from heavy alloc/free — reboot the machine
$QNN_SDK_ROOT/bin/envcheck
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

| Dependency | Source |
| --- | --- |
| QAIRT SDK 2.48.0.260626 | [Qualcomm Developer Network](https://www.qualcomm.com/developer/software/qualcomm-ai-engine-direct) |
| llama.cpp | [github.com/ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) |
| hexagonrpcd | `apt install hexagonrpcd` |
| hexagon-dsp-binaries | `apt install hexagon-dsp-binaries-qualcomm-hamoa-iot-evk` |
