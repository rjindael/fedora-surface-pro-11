#!/bin/bash
# Interactive chat with VibeThinker-1.5B on the Hexagon NPU (HTP0).
# VibeThinker-1.5B is a math/reasoning model fine-tuned from Qwen2.5-Math-1.5B.
# Usage: ./test_vibe.sh
# Type your messages, Ctrl+C to exit.
set -uo pipefail

PKG_DIR="$HOME/npu-re/llama.cpp/pkg-snapdragon"
MODEL_DIR="$HOME/npu-re/llama-hexagon"
MODEL_URL="https://huggingface.co/mradermacher/VibeThinker-1.5B-GGUF/resolve/main/VibeThinker-1.5B.Q4_K_M.gguf"
MODEL_FILE="$MODEL_DIR/VibeThinker-1.5B.Q4_K_M.gguf"

if [ ! -f "$MODEL_FILE" ]; then
    echo "Downloading $MODEL_FILE ..."
    wget -c -O "$MODEL_FILE" "$MODEL_URL"
fi

export LD_LIBRARY_PATH="$PKG_DIR/lib"
export ADSP_LIBRARY_PATH="$PKG_DIR/lib:/usr/share/fastrpc:/usr/lib/dsp:/usr/lib/rfsa/adsp"

# Reset CDSP to defragment rpcmem heap before loading
echo "Resetting CDSP ..."
echo stop | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 2
echo start | sudo tee /sys/class/remoteproc/remoteproc1/state > /dev/null
sleep 3

echo "Starting interactive chat on HTP0 (VibeThinker-1.5B-Q4_K_M) ..."
echo

exec "$PKG_DIR/bin/llama-cli" \
    -m "$MODEL_FILE" \
    --device HTP0 \
    -ngl 99 \
    -c 2048
