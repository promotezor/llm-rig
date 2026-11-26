#!/usr/bin/env bash
set -uo pipefail

log() { echo "[llm-rig] $*"; }
die() { echo "[llm-rig] error: $*" >&2; exit 1; }

MODEL_REPO="${MODEL_REPO:-mradermacher/ThinkingCap-Qwen3.8-27B-Uncensored-Heretic-GGUF}"
MODEL_BASE="${MODEL_BASE:-ThinkingCap-Qwen3.8-27B-Uncensored-Heretic}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
PROXY_PORT="${PROXY_PORT:-8000}"
BIND="${BIND:-0.0.0.0}"
OVERHEAD_MIB="${OVERHEAD_MIB:-2500}"
MAX_CTX="${MAX_CTX:-262144}"
MIN_CTX="${MIN_CTX:-8192}"
BYTES_PER_TOKEN="${BYTES_PER_TOKEN:-32768}"

command -v nvidia-smi >/dev/null 2>&1 || die "no nvidia-smi in container"
nvidia-smi -L || true

GPU_COUNT="$(nvidia-smi -L | grep -c '^GPU' || true)"
VRAM_MIB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')"
[ -n "$VRAM_MIB" ] || die "cannot read VRAM size"
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
[ "${GPU_COUNT:-0}" -ge 1 ] || GPU_COUNT=1
TOTAL_VRAM_MIB=$(( VRAM_MIB * GPU_COUNT ))

if [ -z "${MODEL_FILE:-}" ]; then
  if   [ "$VRAM_MIB" -ge 29000 ]; then MODEL_FILE="$MODEL_BASE.IQ4_XS.gguf"
  elif [ "$VRAM_MIB" -ge 21000 ]; then MODEL_FILE="$MODEL_BASE.IQ4_XS.gguf"
  elif [ "$VRAM_MIB" -ge 15000 ]; then MODEL_FILE="$MODEL_BASE.Q3_K_M.gguf"
  elif [ "$VRAM_MIB" -ge 11000 ]; then MODEL_FILE="$MODEL_BASE.Q2_K.gguf"
  else die "VRAM ${VRAM_MIB}MiB too small for this model"
  fi
fi

MODEL_URL="https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILE"

expected_bytes() {
  curl -sIL "$1" | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}'
}

EXPECTED="$(expected_bytes "$MODEL_URL" || echo 0)"
if [ "$EXPECTED" -gt 0 ]; then
  NEED_MIB=$(( EXPECTED / 1048576 + 2048 ))
else
  NEED_MIB=20480
fi

if [ -n "${MODEL_DIR:-}" ]; then
  CANDIDATES="$MODEL_DIR"
else
  CANDIDATES="/dev/shm /tmp $HOME /models /"
fi

PICKED=""
for d in $CANDIDATES; do
  [ -d "$d" ] || continue
  free_mib="$(df -Pm "$d" 2>/dev/null | awk 'NR==2{print $4}')"
  fstype="$(stat -f -c %T "$d" 2>/dev/null || echo unknown)"
  [ -n "${free_mib:-}" ] || free_mib=0
  log "storage candidate $d: $((free_mib/1024)) GB free, type=$fstype"
  if [ "${free_mib:-0}" -ge "$NEED_MIB" ]; then PICKED="$d"; break; fi
done

[ -n "$PICKED" ] || die "no storage with $((NEED_MIB/1024)) GB free"
MODEL_DIR="$PICKED"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
log "using storage $MODEL_DIR"
log "gpu $GPU_NAME x$GPU_COUNT, vram ${VRAM_MIB}MiB per card, ${TOTAL_VRAM_MIB}MiB total"

if [ -f "$MODEL_PATH" ] && { [ "$EXPECTED" -eq 0 ] || [ "$(stat -c%s "$MODEL_PATH")" -eq "$EXPECTED" ]; }; then
  log "model already present"
else
  log "downloading $MODEL_FILE to $MODEL_DIR (~$((NEED_MIB/1024)) GB needed)"
  log "url $MODEL_URL"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    wget -c "$MODEL_URL" -O "$MODEL_PATH.part" && break
    log "download interrupted, retry $attempt"
    attempt=$((attempt + 1))
    sleep 5
  done
  [ -f "$MODEL_PATH.part" ] || die "download failed"
  actual="$(stat -c%s "$MODEL_PATH.part")"
  if [ "$EXPECTED" -gt 0 ] && [ "$actual" -ne "$EXPECTED" ]; then
    die "size mismatch: got $actual, expected $EXPECTED"
  fi
  mv "$MODEL_PATH.part" "$MODEL_PATH"
  log "model ready"
fi

MODEL_MIB=$(( $(stat -c%s "$MODEL_PATH") / 1048576 ))
BUDGET_MIB=$(( TOTAL_VRAM_MIB - MODEL_MIB - OVERHEAD_MIB ))
[ "$BUDGET_MIB" -lt 1024 ] && BUDGET_MIB=1024
CTX_AUTO=$(( BUDGET_MIB * 1048576 / BYTES_PER_TOKEN / 4096 * 4096 ))
[ "$CTX_AUTO" -gt "$MAX_CTX" ] && CTX_AUTO="$MAX_CTX"
[ "$CTX_AUTO" -lt "$MIN_CTX" ] && CTX_AUTO="$MIN_CTX"
CTX="${CTX:-$CTX_AUTO}"

LLM_KEY="${LLM_API_KEY:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"

if [ -n "${TAVILY_API_KEY:-}${EXA_API_KEY:-}" ]; then
  export PROXY_API_KEY="${PROXY_API_KEY:-$LLM_KEY}"
  export PORT="$PROXY_PORT"
  export USAGE_FILE="${USAGE_FILE:-$MODEL_DIR/usage.json}"
  log "starting search proxy on $BIND:$PROXY_PORT"
  node /app/server.mjs &
fi

log "model $MODEL_FILE ($((MODEL_MIB/1024)) GB) on $MODEL_DIR"
log "context $CTX tokens, kv cache q8_0"
log "llama-server on $BIND:$LLAMA_PORT, api key $LLM_KEY"

exec llama-server \
  -m "$MODEL_PATH" \
  -c "$CTX" \
  -ngl 99 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --host "$BIND" \
  --port "$LLAMA_PORT" \
  --api-key "$LLM_KEY"
