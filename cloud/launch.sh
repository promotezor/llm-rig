#!/bin/sh
# Detached launcher: survives the shell/session clore used to run this script.
LOG=/dev/shm/llm-rig.log

if pgrep -f '/app/entrypoint.sh' >/dev/null 2>&1; then
  echo "llm-rig is already running"
  exit 0
fi

if ! command -v setsid >/dev/null 2>&1; then
  echo "setsid not found" >&2
  exit 1
fi

setsid /app/entrypoint.sh </dev/null >/dev/null 2>&1 &
sleep 2

if pgrep -f '/app/entrypoint.sh' >/dev/null 2>&1; then
  echo "llm-rig started in background, log: $LOG"
  exit 0
fi

echo "llm-rig failed to start, check $LOG" >&2
exit 1
