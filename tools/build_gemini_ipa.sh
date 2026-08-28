#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INPUT_PATH="${1:-$ROOT_DIR}"
OUTPUT_IPA="${2:-$ROOT_DIR/EasyComix-Gemini-unsigned.ipa}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easycomix-gemini.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

mkdir -p "$BUILD_DIR/package"
if [[ -f "$INPUT_PATH" ]]; then
  /usr/bin/ditto -x -k "$INPUT_PATH" "$BUILD_DIR/package"
elif [[ -d "$INPUT_PATH/Payload" ]]; then
  /usr/bin/ditto "$INPUT_PATH/Payload" "$BUILD_DIR/package/Payload"
elif [[ "$(basename "$INPUT_PATH")" == "Payload" ]]; then
  /usr/bin/ditto "$INPUT_PATH" "$BUILD_DIR/package/Payload"
else
  echo "Input must be an IPA, a directory containing Payload, or Payload itself." >&2
  exit 2
fi

APP_DIR="$(find "$BUILD_DIR/package/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_DIR" ]]; then
  echo "No .app found in Payload." >&2
  exit 3
fi

PLIST="$APP_DIR/Info.plist"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
EXECUTABLE="$APP_DIR/$EXECUTABLE_NAME"
DYLIB="$APP_DIR/Frameworks/EasyComixGemini.dylib"
mkdir -p "$(dirname "$DYLIB")"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -dynamiclib \
  -fobjc-arc \
  -fblocks \
  -miphoneos-version-min=18.0 \
  -isysroot "$SDK_PATH" \
  "$ROOT_DIR/EasyComixGemini.m" \
  -framework Foundation \
  -framework UIKit \
  -framework CoreGraphics \
  -framework QuartzCore \
  -install_name '@rpath/EasyComixGemini.dylib' \
  -o "$DYLIB"

/usr/bin/codesign --remove-signature "$EXECUTABLE" 2>/dev/null || true
python3 "$ROOT_DIR/tools/inject_dylib.py" \
  "$EXECUTABLE" \
  '@executable_path/Frameworks/EasyComixGemini.dylib'

rm -rf "$APP_DIR/_CodeSignature"
find "$APP_DIR/Frameworks" -type d -name _CodeSignature -prune -exec rm -rf {} +

mkdir -p "$(dirname "$OUTPUT_IPA")"
rm -f "$OUTPUT_IPA"
(
  cd "$BUILD_DIR/package"
  /usr/bin/zip -qry "$OUTPUT_IPA" Payload
)

test -s "$OUTPUT_IPA"
echo "Created unsigned IPA: $OUTPUT_IPA"
echo "Sign the IPA with your own certificate before installing it."
