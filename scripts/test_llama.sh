#!/bin/bash
# Interactive chat with Llama-3.2-1B-Instruct on the Hexagon NPU (HTP0).
# Usage: ./test_llama.sh
# Type your messages, Ctrl+C to exit.
set -uo pipefail

PKG_DIR="$HOME/npu-re/llama.cpp/pkg-snapdragon"
MODEL_DIR="$HOME/npu-re/llama-hexagon"
MODEL_URL="https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_0.gguf"
MODEL_FILE="$MODEL_DIR/Llama-3.2-1B-Instruct-Q4_0.gguf"

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

echo "Starting interactive chat on HTP0 (Llama-3.2-1B-Instruct-Q4_0) ..."
echo

exec "$PKG_DIR/bin/llama-cli" \
    -m "$MODEL_FILE" \
    --device HTP0 \
    -ngl 99 \
    -c 2048
