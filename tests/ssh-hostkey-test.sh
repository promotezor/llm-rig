#!/usr/bin/env bash
# Verifies that ssh host keys are unique per container (generated at start, not baked in).
set -u
T="$HOME/llmrig-local-test"
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICrSppjYabkSY5KQrNIrKFtz7UyC1n3ZREnWsJHwsFn6 sanya-mac-202610"

start_one() {
  local name="$1" port="$2"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" --platform linux/amd64 \
    -v "$T/bin:/fakebin:ro" -v "$T/store:/store" \
    -e PATH=/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -e SSH_PUBLIC_KEY="$PUBKEY" \
    -e STATUS_PORT="$port" -e LLAMA_PORT="$port" \
    -e STATUS_FILE=/store/status.json -e LOG_FILE=/store/hk-$name.log \
    -e MODEL_DIR=/store -e CTX=8192 \
    llm-rig:test >/dev/null
  sleep 8
}

fp() {
  docker exec "$1" sh -c 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk "{print \$2}"'
}

echo "--- image should have NO baked host keys ---"
docker run --rm --platform linux/amd64 --entrypoint sh llm-rig:test -c 'ls /etc/ssh/ssh_host_*_key 2>/dev/null || echo "none baked in (correct)"'

start_one hk-a 8091
start_one hk-b 8092

A="$(fp hk-a)"; B="$(fp hk-b)"
echo "container A fingerprint: $A"
echo "container B fingerprint: $B"

if [ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ]; then
  echo "PASS: host keys are unique per container"
else
  echo "FAIL: keys empty or identical"
fi

echo "--- log line ---"
docker logs hk-a 2>&1 | grep -i "ssh is up" | head -2

docker rm -f hk-a hk-b >/dev/null 2>&1
