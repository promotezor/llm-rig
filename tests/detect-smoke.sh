#!/usr/bin/env bash
# Sandbox smoke test for cloud/entrypoint.sh detection logic (no GPU, fakes only).
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
mkdir -p "$T/bin" "$T/store"

cat > "$T/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *-L*) i=0; while [ "$i" -lt "${FAKE_GPU_COUNT:-1}" ]; do echo "GPU $i: NVIDIA GeForce RTX 5090 (UUID: GPU-x$i)"; i=$((i+1)); done ;;
  *memory.total*) echo "${FAKE_VRAM:-32607}" ;;
  *name*) echo "NVIDIA GeForce RTX 5090" ;;
  *) echo "fake" ;;
esac
EOF

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "content-length: ${FAKE_MODEL_BYTES:-15193918976}"
EOF

cat > "$T/bin/stat" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -c%s "*) echo "${FAKE_MODEL_BYTES:-15193918976}" ;;
  *" -c %T "*) echo "ext4" ;;
  *) echo 0 ;;
esac
EOF

cat > "$T/bin/wget" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -O) out="$2"; shift 2;; *) shift;; esac; done
[ -n "$out" ] && printf 'fake-gguf' > "$out"
exit 0
EOF

cat > "$T/bin/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "LLAMA-ARGS: $*"
EOF
chmod +x "$T"/bin/*

run_case() {
  local label="$1" vram="$2" bytes="$3" count="${4:-1}"
  echo "=== $label (vram ${vram}MiB x$count, model $((bytes/1073741824))GB) ==="
  rm -rf "$T/store"; mkdir -p "$T/store"
  PATH="$T/bin:$PATH" FAKE_VRAM="$vram" FAKE_GPU_COUNT="$count" FAKE_MODEL_BYTES="$bytes" \
    MODEL_DIR="$T/store" bash "$HERE/cloud/entrypoint.sh" 2>&1 \
    | grep -E 'using storage|gpu |downloading|model ready|context |llama-server on|LLAMA-ARGS' \
    | sed "s|$T/store|STORE|g"
  echo
}

run_case "A 32GB desktop" 32607 15193918976
run_case "B 24GB laptop" 24576 15193918976
run_case "C 16GB card" 16384 13500000000
run_case "D 2x5090" 32607 15193918976 2
rm -rf "$T"
