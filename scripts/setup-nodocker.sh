#!/usr/bin/env bash
set -euo pipefail

MODEL_REPO="mradermacher/ThinkingCap-Qwen3.8-27B-Uncensored-Heretic-GGUF"
MODEL_FILE="ThinkingCap-Qwen3.8-27B-Uncensored-Heretic.IQ4_XS.gguf"
MODEL_URL="https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILE"
LLAMA_URL="https://github.com/ai-dock/llama.cpp-cuda/releases/download/v1.0.0/llama.cpp-v1.0.0-cuda-12.8-amd64.tar.gz"
MODEL_DIR="${MODEL_DIR:-/dev/shm}"
BIN_DIR="/root/cuda-12.8"
CTX="${CTX:-262144}"
MODEL_MIN_BYTES=15000000000

command -v nvidia-smi >/dev/null 2>&1 || { echo "no nvidia driver, choose a clore image with driver" >&2; exit 1; }
nvidia-smi -L

mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"

if [ -f "$MODEL_PATH" ] && [ "$(stat -c%s "$MODEL_PATH")" -ge "$MODEL_MIN_BYTES" ]; then
  echo "model already downloaded"
else
  nohup wget -qc "$MODEL_URL" -O "$MODEL_PATH" >/dev/null 2>&1 &
  WGET_PID=$!
  echo "model downloading in background (pid $WGET_PID)"
fi

if ! ldconfig -p 2>/dev/null | grep -q libcudart.so.12; then
  echo "installing packages"
  apt-get update -qq
  apt-get install -y -qq libgomp1
  wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb
  dpkg -i /tmp/cuda-keyring.deb
  apt-get update -qq
  apt-get install -y -qq cuda-cudart-12-8 libcublas-12-8 libnccl2
fi

export PATH="$BIN_DIR:$PATH" LD_LIBRARY_PATH="$BIN_DIR"
if ! llama-server --version >/dev/null 2>&1; then
  echo "downloading llama.cpp binary"
  rm -rf "$BIN_DIR" /root/llama.tar.gz
  cd /root && wget -q "$LLAMA_URL" -O llama.tar.gz && tar xzf llama.tar.gz && rm -f llama.tar.gz
  llama-server --version >/dev/null 2>&1 || { echo "binary still broken" >&2; exit 1; }
fi

if [ -n "${WGET_PID:-}" ]; then
  echo "waiting for model download"
  wait "$WGET_PID"
fi

if [ ! -f "$MODEL_PATH" ] || [ "$(stat -c%s "$MODEL_PATH")" -lt "$MODEL_MIN_BYTES" ]; then
  echo "model download incomplete, rerun to resume" >&2
  exit 1
fi

if pgrep -f "llama-server -m" >/dev/null; then
  echo "llama-server already running"
else
  echo "launching llama-server"
  nohup llama-server -m "$MODEL_PATH" -c "$CTX" -ngl 99 --cache-type-k q8_0 --cache-type-v q8_0 --host 127.0.0.1 --port 8080 > "$MODEL_DIR/llama.log" 2>&1 &
fi

echo
echo "wait a couple minutes, then check:"
echo "  tail -25 $MODEL_DIR/llama.log"
echo "  nvidia-smi"
echo "chat: http://127.0.0.1:8080/ via SSH tunnel"
