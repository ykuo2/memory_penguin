#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_APP_DIR="$ROOT_DIR/dist/MemoryPenguin.app"
DIST_ARCHIVE="$ROOT_DIR/dist/MemoryPenguin.zip"
STAGING_ROOT="${TMPDIR:-/tmp}/memory-penguin-build"
APP_DIR="$STAGING_ROOT/MemoryPenguin.app"
ARCHIVE_VERIFY_ROOT="$STAGING_ROOT/archive-verify"
CONTENTS_DIR="$APP_DIR/Contents"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

cd "$ROOT_DIR"
CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")"
SHORT_VERSION="$CURRENT_VERSION"

swift build -c release

rm -rf "$STAGING_ROOT"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/MemoryPenguin" "$CONTENTS_DIR/MacOS/MemoryPenguin"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/icon.png" "$CONTENTS_DIR/Resources/icon.png"
cp "$ROOT_DIR/Resources/memory_icon.png" "$CONTENTS_DIR/Resources/memory_icon.png"
cp "$ROOT_DIR/Resources/Generated/StatusIcons/memory_status_calm.png" "$CONTENTS_DIR/Resources/memory_status_calm.png"
cp "$ROOT_DIR/Resources/Generated/StatusIcons/memory_status_elevated.png" "$CONTENTS_DIR/Resources/memory_status_elevated.png"
cp "$ROOT_DIR/Resources/Generated/StatusIcons/memory_status_high.png" "$CONTENTS_DIR/Resources/memory_status_high.png"
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
codesign --verify --deep --strict "$APP_DIR"

rm -rf "$DIST_APP_DIR"
rm -f "$DIST_ARCHIVE"
mkdir -p "$(dirname "$DIST_APP_DIR")"
ditto --noextattr "$APP_DIR" "$DIST_APP_DIR"
xattr -cr "$DIST_APP_DIR"
codesign --verify --deep --strict "$DIST_APP_DIR"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP_DIR" "$DIST_ARCHIVE"
mkdir -p "$ARCHIVE_VERIFY_ROOT"
ditto -x -k "$DIST_ARCHIVE" "$ARCHIVE_VERIFY_ROOT"
codesign --verify --deep --strict "$ARCHIVE_VERIFY_ROOT/MemoryPenguin.app"

echo "Built $DIST_APP_DIR and $DIST_ARCHIVE (version $SHORT_VERSION, build $BUILD_NUMBER)"
