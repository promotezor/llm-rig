#!/usr/bin/env bash
# Local end-to-end check of the container start path, without a GPU.
# Verifies: status page comes up, model is picked up, the port is handed over
# to llama-server, and /health answers afterwards.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$HOME/llmrig-local-test"
PORT=18081
INNER=8081
MODEL_BYTES=15193918976
MODEL_FILE="ThinkingCap-Qwen3.8-27B-Uncensored-Heretic.IQ4_XS.gguf"
NAME=llmrig-local-test

rm -rf "$T"; mkdir -p "$T/bin" "$T/store"
mkfile -n "$MODEL_BYTES" "$T/store/$MODEL_FILE"

cat > "$T/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *-L*) echo "GPU 0: NVIDIA GeForce RTX 5090 (UUID: GPU-local)" ;;
  *memory.total*) echo 32607 ;;
  *name*) echo "NVIDIA GeForce RTX 5090" ;;
  *) echo "fake" ;;
esac
EOF

cat > "$T/bin/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "FAKE llama-server args: $*"
port=8081
prev=""
for a in "$@"; do
  [ "$prev" = "--port" ] && port="$a"
  prev="$a"
done
export FAKE_PORT="$port"
exec node -e '
const http = require("http");
const port = process.env.FAKE_PORT;
http.createServer((req, res) => {
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ status: "ok", fake: true }));
}).listen(Number(port), "0.0.0.0", () => console.log("fake llama-server listening on " + port));
'
EOF
chmod +x "$T"/bin/*

docker rm -f "$NAME" >/dev/null 2>&1

docker run -d --name "$NAME" --platform linux/amd64 \
  -p "$PORT:$INNER" \
  -v "$T/bin:/fakebin:ro" \
  -v "$T/store:/store" \
  -e PATH=/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -e STATUS_PORT="$INNER" -e LLAMA_PORT="$INNER" \
  -e STATUS_FILE=/store/status.json -e LOG_FILE=/store/app.log \
  -e LOG_INTERVAL=1 -e MODEL_DIR=/store -e CTX=8192 \
  llm-rig:test >/dev/null

echo "container started, watching for up to 40s"
status_seen="no"
for i in $(seq 1 20); do
  sleep 2
  status="$(curl -s -m 3 "http://127.0.0.1:$PORT/status" 2>/dev/null)"
  health="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ -n "$status" ] && [ "$status_seen" = "no" ] && status_seen="yes"
  echo "t=$((i*2))s status_bytes=${#status} health=$health"
  if [ "$health" = "200" ]; then echo "PASS: forwarded port ends up served by llama-server"; break; fi
done
echo "status page ever answered: $status_seen"

echo "--- container stdout ---"
docker logs "$NAME" 2>&1 | tail -22
echo "--- status file ---"
cat "$T/store/status.json" 2>/dev/null; echo
docker rm -f "$NAME" >/dev/null 2>&1
