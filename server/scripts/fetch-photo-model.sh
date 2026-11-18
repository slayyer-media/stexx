#!/bin/sh
# Downloads the NSFW model used by the profile photo checks (docs/security.md "Photo checks") and verifies it.
#
#   scripts/fetch-photo-model.sh [DEST_DIR]     default: server/models (git-ignored)
#
# Model: NudeNet v3.4 "320n" detector, ONNX, 12,150,158 bytes, AGPL-3.0 (github.com/notAI-tech/NudeNet).
# Pinned by SHA-256. Source 1 is the GitHub release asset (through the API, because the plain release URL now
# redirects anonymous clients to a login page). Source 2 is the same file inside the nudenet 3.4.2 wheel on PyPI.
# Idempotent: exits early if the file is already there with the right checksum. Needs curl (and unzip for source 2).
set -eu

MODEL_SHA256="c15d8273adad2d0a92f014cc69ab2d6c311a06777a55545f2c4eb46f51911f0f"
GITHUB_URL="https://api.github.com/repos/notAI-tech/NudeNet/releases/assets/176831997" # v3.4-weights/320n.onnx
WHEEL_URL="https://files.pythonhosted.org/packages/1c/ee/1aa02d44ba958cc77e16ff1e41a0aac5e721037db7bf62b9c9d124917f87/nudenet-3.4.2-py3-none-any.whl"
WHEEL_SHA256="5937dbd84e5d8e5de038f08ffea5a1bb50a08475776bf2b4795914ce0eaf0331"
NAME="nudenet-320n.onnx"

DEST_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/models}"
DEST="$DEST_DIR/$NAME"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

if [ -f "$DEST" ] && [ "$(sha256 "$DEST")" = "$MODEL_SHA256" ]; then
  echo "photo model ok: $DEST"
  exit 0
fi

mkdir -p "$DEST_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

got=""
if curl -fsSL --max-time 300 -H "Accept: application/octet-stream" -o "$TMP/$NAME" "$GITHUB_URL" &&
  [ "$(sha256 "$TMP/$NAME")" = "$MODEL_SHA256" ]; then
  got="github"
elif command -v unzip >/dev/null 2>&1 &&
  curl -fsSL --max-time 300 -o "$TMP/nudenet.whl" "$WHEEL_URL" &&
  [ "$(sha256 "$TMP/nudenet.whl")" = "$WHEEL_SHA256" ] &&
  unzip -p "$TMP/nudenet.whl" nudenet/320n.onnx >"$TMP/$NAME" &&
  [ "$(sha256 "$TMP/$NAME")" = "$MODEL_SHA256" ]; then
  got="pypi"
fi

if [ -z "$got" ]; then
  echo "error: could not download $NAME with the expected SHA-256 ($MODEL_SHA256)" >&2
  exit 1
fi

# Same-directory rename, so a running server never sees a half-written file.
cp "$TMP/$NAME" "$DEST.partial"
chmod 0644 "$DEST.partial"
mv -f "$DEST.partial" "$DEST"
echo "photo model installed from $got: $DEST"
