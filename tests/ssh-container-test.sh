#!/usr/bin/env bash
# Verifies the baked sshd: entrypoint writes authorized_keys and sshd listens on 2222.
set -u
T="$HOME/llmrig-local-test"
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICrSppjYabkSY5KQrNIrKFtz7UyC1n3ZREnWsJHwsFn6 sanya-mac-202610"
NAME=llmrig-ssh

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" --platform linux/amd64 \
  -p 12222:2222 \
  -v "$T/bin:/fakebin:ro" -v "$T/store:/store" \
  -e PATH=/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -e SSH_PUBLIC_KEY="$PUBKEY" \
  -e STATUS_PORT=8089 -e LLAMA_PORT=8089 \
  -e STATUS_FILE=/store/status.json -e LOG_FILE=/store/app.log \
  -e MODEL_DIR=/store -e CTX=8192 \
  llm-rig:test >/dev/null

sleep 8

echo "--- entrypoint log (ssh lines) ---"
docker logs "$NAME" 2>&1 | grep -iE "ssh|status page" | head -6

echo "--- inside the container ---"
docker exec "$NAME" sh -c 'ps -eo pid,args | grep -E "[s]shd" | head -5; echo "authorized_keys:"; cat /root/.ssh/authorized_keys 2>/dev/null; echo "listening:"; (ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null) | grep 2222'

echo "--- tcp reachability from the host ---"
(exec 3<>/dev/tcp/127.0.0.1/12222 && head -c 40 <&3) 2>/dev/null | tr -d '\0' | head -1

docker rm -f "$NAME" >/dev/null 2>&1
