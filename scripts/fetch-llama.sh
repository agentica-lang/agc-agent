#!/usr/bin/env bash
# Fetches the pinned prebuilt CPU llama.cpp release into .tools/llama.cpp (gitignored), checked against its sha256.
# To bump it, change TAG and SHA256 together; CI caches by the hash of this file.
set -euo pipefail
TAG="b12426"
SHA256="011212b7a6052a213034d4c313f99f131cb09fb5fb5a4ee61cd7572b81febf67"
FILE="llama-${TAG}-bin-ubuntu-x64.tar.gz"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/${FILE}"

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/.tools/llama.cpp"
if [ -x "$dest/llama-server" ] && [ "$(cat "$dest/TAG" 2>/dev/null)" = "$TAG" ]; then
  echo "already fetched: llama.cpp $TAG"
  exit 0
fi

mkdir -p "$root/.tools"
part="$root/.tools/$FILE.part"
echo "fetching $URL"
curl -fL -o "$part" "$URL"
echo "$SHA256  $part" | sha256sum -c - || { rm -f "$part"; exit 1; }
rm -rf "$dest"
mkdir -p "$dest"
tar -xzf "$part" -C "$dest" --strip-components=1
rm -f "$part"
echo "$TAG" > "$dest/TAG"
