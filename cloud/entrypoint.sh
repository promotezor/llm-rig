#!/usr/bin/env bash
set -uo pipefail

LOG_FILE="${LOG_FILE:-/dev/shm/llm-rig.log}"
STATUS_FILE="${STATUS_FILE:-/dev/shm/llm-rig.status.json}"
STATUS_PORT="${STATUS_PORT-8080}"
STATUS_PID=""
START_EPOCH="$(date +%s)"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s [llm-rig] %s\n' "$(ts)" "$*"; }
die() { write_status failed "$*"; log "error: $*"; exit 1; }

write_status() {
  printf '{"stage":"%s","note":"%s","updated":"%s","elapsed_s":%s,"gpu":"%s","vram_mib":%s,"storage":"%s","model":"%s","model_bytes":%s,"model_expected":%s,"context":%s,"llama_port":%s}\n' \
    "$1" "$2" "$(ts)" "$(( $(date +%s) - START_EPOCH ))" \
    "${GPU_NAME:-}" "${TOTAL_VRAM_MIB:-0}" "${MODEL_DIR:-}" "${MODEL_FILE:-}" \
    "${MODEL_BYTES:-0}" "${EXPECTED:-0}" "${CTX:-0}" "${LLAMA_PORT:-8080}" \
    > "$STATUS_FILE.tmp" 2>/dev/null && mv "$STATUS_FILE.tmp" "$STATUS_FILE" 2>/dev/null
}

if mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && [ -w "$(dirname "$LOG_FILE")" ]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "logging to stdout and $LOG_FILE"
fi

log "start: pid $$, host $(hostname), $(uname -sr)"
write_status booting "script started"

if [ -n "$STATUS_PORT" ] && command -v node >/dev/null 2>&1; then
  STATUS_PORT="$STATUS_PORT" STATUS_FILE="$STATUS_FILE" LOG_FILE="$LOG_FILE" node /app/status.mjs &
  STATUS_PID=$!
  log "status page on 0.0.0.0:$STATUS_PORT (open the public address to follow progress)"
fi

SSH_PORT="${SSH_PORT:-2222}"
KEYS_RAW=""
for kvar in SSH_PUBLIC_KEY SSH_PUBLIC_KEYS SSH_PUBLIC_KEY_2 SSH_PUBLIC_KEY_3 \
            SSH_PUBLIC_KEY_4 SSH_PUBLIC_KEY_5 SSH_KEYS EXTRA_SSH_KEYS; do
  kval="${!kvar:-}"
  [ -n "$kval" ] && KEYS_RAW="$KEYS_RAW
$kval"
done
KEYS_CLEAN="$(printf '%s' "$KEYS_RAW" | tr ';,' '\n\n' | sed 's/\\n/\
/g' | grep -E '^(ssh-|ecdsa-|sk-)' || true)"
KEY_COUNT="$(printf '%s' "$KEYS_CLEAN" | grep -c . || true)"

if [ "${KEY_COUNT:-0}" -ge 1 ]; then
  mkdir -p /root/.ssh /run/sshd && chmod 700 /root/.ssh
  printf '%s\n' "$KEYS_CLEAN" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  if /usr/sbin/sshd -e -p "$SSH_PORT" 2>>"$LOG_FILE"; then
    log "ssh is up on port $SSH_PORT for root, $KEY_COUNT key(s) accepted"
  else
    log "warning: sshd did not start, debugging over ssh is unavailable"
  fi
else
  log "no ssh keys given (SSH_PUBLIC_KEY, SSH_PUBLIC_KEY_2..5, SSH_KEYS), skipping sshd"
fi

MODEL_REPO="${MODEL_REPO:-mradermacher/ThinkingCap-Qwen3.8-27B-Uncensored-Heretic-GGUF}"
MODEL_BASE="${MODEL_BASE:-ThinkingCap-Qwen3.8-27B-Uncensored-Heretic}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
PROXY_PORT="${PROXY_PORT:-8000}"
BIND="${BIND:-0.0.0.0}"
OVERHEAD_MIB="${OVERHEAD_MIB:-2500}"
MAX_CTX="${MAX_CTX:-262144}"
MIN_CTX="${MIN_CTX:-8192}"
BYTES_PER_TOKEN="${BYTES_PER_TOKEN:-32768}"
LOG_INTERVAL="${LOG_INTERVAL:-30}"

command -v nvidia-smi >/dev/null 2>&1 || die "no nvidia-smi in container (image must run with GPU access)"
while read -r line; do log "gpu $line"; done < <(nvidia-smi -L)

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
write_status ready "gpu and storage picked, starting model download"

if [ -f "$MODEL_PATH" ] && { [ "$EXPECTED" -eq 0 ] || [ "$(stat -c%s "$MODEL_PATH")" -eq "$EXPECTED" ]; }; then
  log "model already present"
else
  log "downloading $MODEL_FILE to $MODEL_DIR (need ~$((NEED_MIB/1024)) GB free)"
  log "url $MODEL_URL"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    wget -c "$MODEL_URL" -O "$MODEL_PATH.part" >/dev/null 2>&1 &
    wpid=$!
    while kill -0 "$wpid" 2>/dev/null; do
      sleep "$LOG_INTERVAL"
      if [ -f "$MODEL_PATH.part" ]; then
        cur="$(stat -c%s "$MODEL_PATH.part")"
        MODEL_BYTES="$cur"
        if [ "$EXPECTED" -gt 0 ]; then
          log "downloaded $((cur/1048576)) MiB / $((EXPECTED/1048576)) MiB ($((cur * 100 / EXPECTED))%)"
          write_status downloading "$((cur * 100 / EXPECTED))% of the model"
        else
          log "downloaded $((cur/1048576)) MiB"
          write_status downloading "$((cur/1048576)) MiB downloaded"
        fi
      else
        log "waiting for download to start"
      fi
    done
    wait "$wpid" && break
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
  log "model ready, $((actual/1048576)) MiB"
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

log "versions: llama-server $(llama-server --version 2>&1 | head -1), node $(node --version 2>/dev/null || echo none)"
log "model $MODEL_FILE ($((MODEL_MIB/1024)) GB) on $MODEL_DIR"
log "context $CTX tokens, kv cache q8_0, vram ${TOTAL_VRAM_MIB}MiB"
log "llama-server will listen on $BIND:$LLAMA_PORT"
write_status loading "model ready, loading into vram"

if [ -n "$STATUS_PID" ]; then
  write_status launching "giving port $STATUS_PORT to llama-server"
  for _ in $(seq 1 30); do
    curl -sf -m 2 -o /dev/null "http://127.0.0.1:$STATUS_PORT/status" || break
    sleep 1
  done
  kill "$STATUS_PID" 2>/dev/null || true
  wait "$STATUS_PID" 2>/dev/null || true
  sleep 1
  log "status page stopped, port $STATUS_PORT is free"
fi

log "waiting for the server to answer on /health"

(
  i=0
  while [ "$i" -lt 240 ]; do
    if curl -sf -m 3 -o /dev/null "http://127.0.0.1:$LLAMA_PORT/health"; then
      log "server is ready, open the public address and enter the api key"
      exit 0
    fi
    i=$((i + 1))
    sleep 5
  done
  log "server did not answer /health within 20 minutes, check the log above"
) &

exec llama-server \
  -m "$MODEL_PATH" \
  -c "$CTX" \
  -ngl 99 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --host "$BIND" \
  --port "$LLAMA_PORT" \
  --api-key "$LLM_KEY"
