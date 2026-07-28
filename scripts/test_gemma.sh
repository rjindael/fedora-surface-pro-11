#!/bin/bash
# Interactive chat with Gemma 4 E2B-it (QAT mobile) on the Hexagon NPU (HTP0).
# Gemma 4 E2B = 2.3B effective params, multimodal (text/image/audio),
# mobile-optimized QAT quantization, 128K context, Apache 2.0 license.
# CDSP reset is required — the model's REPACK buffer needs a clean heap.
# Usage: ./test_gemma.sh
# Type your messages, Ctrl+C to exit.
set -uo pipefail

PKG_DIR="$HOME/npu-re/llama.cpp/pkg-snapdragon"
MODEL_DIR="$HOME/npu-re/llama-hexagon"
MODEL_URL="https://huggingface.co/unsloth/gemma-4-E2B-it-qat-mobile-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf"
MODEL_FILE="$MODEL_DIR/gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf"

if [ ! -f "$MODEL_FILE" ]; then
    echo "Downloading $MODEL_FILE ..."
    wget -c -O "$MODEL_FILE" "$MODEL_URL"
fi

export LD_LIBRARY_PATH="$PKG_DIR/lib"
export ADSP_LIBRARY_PATH="$PKG_DIR/lib:/usr/share/fastrpc:/usr/lib/dsp:/usr/lib/rfsa/adsp"

# Reset CDSP to defragment rpcmem heap before loading (required for 2B+ models)
echo "Resetting CDSP ..."
echo stop | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 2
echo start | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 3

echo "Starting interactive chat on HTP0 (Gemma-4-E2B-it QAT mobile) ..."
echo

exec "$PKG_DIR/bin/llama-cli" \
    -m "$MODEL_FILE" \
    --device HTP0 \
    -ngl 99 \
    -c 2048
