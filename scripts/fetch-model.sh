#!/usr/bin/env bash
# Fetches Qwen2.5-0.5B-Instruct Q4_K_M, the model of the llama-server smoke tests, into .tools/models (gitignored),
# checked against its sha256. A partial or wrong download never takes the final name.
set -euo pipefail
REPO="Qwen/Qwen2.5-0.5B-Instruct-GGUF"
FILE="qwen2.5-0.5b-instruct-q4_k_m.gguf"
SHA256="74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"
URL="https://huggingface.co/$REPO/resolve/main/$FILE"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/.tools/models/$FILE"
mkdir -p "$root/.tools/models"
if [ -f "$out" ] && echo "$SHA256  $out" | sha256sum -c - >/dev/null 2>&1; then
  echo "already fetched: $FILE"
  exit 0
fi

echo "fetching $URL"
curl -fL -o "$out.part" "$URL"
echo "$SHA256  $out.part" | sha256sum -c - || { rm -f "$out.part"; exit 1; }
mv "$out.part" "$out"
