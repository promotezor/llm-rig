#!/usr/bin/env bash
# Verifies multiple ssh keys are accepted from one env variable.
set -u
T="$HOME/llmrig-local-test"
K1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICrSppjYabkSY5KQrNIrKFtz7UyC1n3ZREnWsJHwsFn6 sanya-mac-202610"
K2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYTESTKEYTESTKEYTESTKEYTESTKEYTESTKEY000 friend-key"
NAME=llmrig-keys

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" --platform linux/amd64 \
  -v "$T/bin:/fakebin:ro" -v "$T/store:/store" \
  -e PATH=/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -e SSH_PUBLIC_KEY="$K1" \
  -e SSH_PUBLIC_KEY_2="$K2" \
  -e SSH_KEYS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITHIRDKEYTHIRDKEYTHIRDKEYTHIRDKEYTHIRDKEY00 third-key" \
  -e STATUS_PORT=8090 -e LLAMA_PORT=8090 \
  -e STATUS_FILE=/store/status.json -e LOG_FILE=/store/keys-test.log \
  -e MODEL_DIR=/store -e CTX=8192 \
  llm-rig:test >/dev/null

sleep 8
echo "--- log line ---"
docker logs "$NAME" 2>&1 | grep -i "ssh is up"
echo "--- authorized_keys ---"
docker exec "$NAME" sh -c 'wc -l < /root/.ssh/authorized_keys; cut -c1-60 /root/.ssh/authorized_keys'
echo "--- ssh reachable ---"
docker port "$NAME" >/dev/null 2>&1
(exec 3<>/dev/tcp/127.0.0.1/12222 && timeout 3 head -c 25 <&3) 2>/dev/null | tr -d '\0' || echo "no banner on 12222 (port not published in this test)"
docker rm -f "$NAME" >/dev/null 2>&1
