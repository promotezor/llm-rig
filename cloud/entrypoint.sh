#!/usr/bin/env bash
set -euo pipefail

MODEL_DIR="${MODEL_DIR:-/dev/shm}"
MODEL_REPO="${MODEL_REPO:-mradermacher/ThinkingCap-Qwen3.8-27B-Uncensored-Heretic-GGUF}"
MODEL_FILE="${MODEL_FILE:-ThinkingCap-Qwen3.8-27B-Uncensored-Heretic.IQ4_XS.gguf}"
MODEL_MIN_BYTES="${MODEL_MIN_BYTES:-15000000000}"
CTX="${CTX:-262144}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
PROXY_PORT="${PROXY_PORT:-8000}"
BIND="${BIND:-0.0.0.0}"

command -v nvidia-smi >/dev/null 2>&1 || { echo "no nvidia driver visible in container" >&2; exit 1; }
nvidia-smi -L || true

mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"

if [ -f "$MODEL_PATH" ] && [ "$(stat -c%s "$MODEL_PATH")" -ge "$MODEL_MIN_BYTES" ]; then
  echo "model already present: $MODEL_PATH"
else
  echo "downloading model $MODEL_REPO ($MODEL_FILE), this takes ~15 min at 140 Mbps"
  echo "download url: https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILE"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    if wget -c "https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILE" -O "$MODEL_PATH.part"; then
      break
    fi
    echo "download interrupted, retry $attempt"
    attempt=$((attempt + 1))
    sleep 5
  done
  [ -f "$MODEL_PATH.part" ] || { echo "model download failed" >&2; exit 1; }
  size="$(stat -c%s "$MODEL_PATH.part")"
  [ "$size" -ge "$MODEL_MIN_BYTES" ] || { echo "model incomplete: $size bytes" >&2; exit 1; }
  mv "$MODEL_PATH.part" "$MODEL_PATH"
  echo "model ready: $MODEL_PATH"
fi

LLM_KEY="${LLM_API_KEY:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"

if [ -n "${TAVILY_API_KEY:-}${EXA_API_KEY:-}" ]; then
  export PROXY_API_KEY="${PROXY_API_KEY:-$LLM_KEY}"
  export PORT="$PROXY_PORT"
  export USAGE_FILE="${USAGE_FILE:-$MODEL_DIR/usage.json}"
  echo "starting search proxy on 0.0.0.0:$PROXY_PORT"
  node /app/server.mjs &
fi

echo "starting llama-server: model=$MODEL_PATH ctx=$CTX bind=$BIND:$LLAMA_PORT"
echo "API key: $LLM_KEY"

exec llama-server \
  -m "$MODEL_PATH" \
  -c "$CTX" \
  -ngl 99 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --host "$BIND" \
  --port "$LLAMA_PORT" \
  --api-key "$LLM_KEY"
