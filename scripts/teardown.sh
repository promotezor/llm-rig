#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

docker compose down --rmi all -v 2>/dev/null || true
docker system prune -f 2>/dev/null || true

RAM_DIR="${RAM_DIR:-/mnt/ram}"
if mountpoint -q "$RAM_DIR" 2>/dev/null; then
  umount "$RAM_DIR"
fi

rm -f .env

echo "torn down, tmpfs unmounted"
