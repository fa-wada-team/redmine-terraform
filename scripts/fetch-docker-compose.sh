#!/bin/bash
# Docker Compose (linux-aarch64) を GitHub から取得し、SHA256 を検証して保存する
# usage: fetch-docker-compose.sh <version> <output path>
set -euo pipefail

VERSION="$1"
OUT="$2"
FILE=docker-compose-linux-aarch64
URL="https://github.com/docker/compose/releases/download/${VERSION}/${FILE}"

if [ -f "$OUT" ]; then
  echo "already exists: $OUT"
  exit 0
fi

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL -o "$TMP/$FILE" "$URL"
curl -fsSL -o "$TMP/$FILE.sha256" "$URL.sha256"

EXPECTED="$(awk '{print $1}' "$TMP/$FILE.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$TMP/$FILE" | awk '{print $1}')"
else
  ACTUAL="$(shasum -a 256 "$TMP/$FILE" | awk '{print $1}')"
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "checksum mismatch: expected=$EXPECTED actual=$ACTUAL" >&2
  exit 1
fi

mv "$TMP/$FILE" "$OUT"
echo "downloaded: $OUT"
