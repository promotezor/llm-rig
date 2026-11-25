#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

command -v nvidia-smi >/dev/null 2>&1 || { echo "no nvidia driver on this box" >&2; exit 1; }
nvidia-smi -L

if ! command -v docker >/dev/null 2>&1; then
  echo "installing docker" >&2
  curl -fsSL https://get.docker.com | sh
fi

if ! docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
  echo "installing nvidia-container-toolkit" >&2
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker || true
fi

[ -f .env ] || { cp .env.example .env; echo "created .env - fill in your keys and rerun" >&2; exit 1; }

set -a
. ./.env
set +a

RAM_DIR="${RAM_DIR:-/mnt/ram}"
RAM_SIZE="${RAM_SIZE:-24G}"

if ! mountpoint -q "$RAM_DIR"; then
  mkdir -p "$RAM_DIR"
  mount -t tmpfs -o "size=$RAM_SIZE,mode=1777" tmpfs "$RAM_DIR"
  echo "mounted tmpfs $RAM_SIZE at $RAM_DIR" >&2
fi

mkdir -p "$RAM_DIR/models" "$RAM_DIR/data"
chown -R 1000:1000 "$RAM_DIR/data"

if ! command -v huggingface-cli >/dev/null 2>&1; then
  command -v pip3 >/dev/null 2>&1 || { apt-get update; apt-get install -y python3-pip; }
  pip3 install -U "huggingface_hub[cli]"
fi

if [ ! -e "$RAM_DIR/models/model.gguf" ]; then
  echo "downloading $MODEL_REPO ($MODEL_QUANT)" >&2
  HF_HOME="$RAM_DIR/hf" huggingface-cli download "$MODEL_REPO" \
    --include "$MODEL_QUANT" --local-dir "$RAM_DIR/models"
  first="$(find "$RAM_DIR/models" -name '*.gguf' | head -n1)"
  [ -n "$first" ] || { echo "no gguf found for $MODEL_QUANT" >&2; exit 1; }
  ( cd "$RAM_DIR/models" && ln -sf "$(basename "$first")" model.gguf )
fi

docker compose build
docker compose up -d

echo
echo "ready. tunnel from your laptop:"
echo "  ssh -L 8080:127.0.0.1:8080 -L 8000:127.0.0.1:8000 root@<server-ip>"
echo "llm:   http://127.0.0.1:8080/v1  (Authorization: Bearer \$LLM_API_KEY)"
echo "proxy: http://127.0.0.1:8000     (Authorization: Bearer \$PROXY_API_KEY)"
