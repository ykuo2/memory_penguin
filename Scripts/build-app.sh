#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/MemoryPenguin.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/MemoryPenguin" "$CONTENTS_DIR/MacOS/MemoryPenguin"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/icon.png" "$CONTENTS_DIR/Resources/icon.png"
cp "$ROOT_DIR/Resources/memory_icon.png" "$CONTENTS_DIR/Resources/memory_icon.png"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
sips -z 16 16 "$ROOT_DIR/Resources/icon.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ROOT_DIR/Resources/icon.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ROOT_DIR/Resources/icon.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ROOT_DIR/Resources/icon.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ROOT_DIR/Resources/icon.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ROOT_DIR/Resources/icon.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ROOT_DIR/Resources/icon.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ROOT_DIR/Resources/icon.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ROOT_DIR/Resources/icon.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ROOT_DIR/Resources/icon.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS_DIR/Resources/AppIcon.icns"
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built $APP_DIR (build $BUILD_NUMBER)"
