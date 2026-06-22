#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CTX"
BUNDLE_ID="dev.eliasafa.CTX"
APP_VERSION="${CTX_RELEASE_VERSION:-0.1.0}"
APP_VERSION="${APP_VERSION#v}"
APP_BUILD="${GITHUB_RUN_NUMBER:-1}"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RESOURCES_DIR="$APP_CONTENTS/Resources"
ICON_SVG="$ROOT_DIR/Resources/CTXIcon.svg"
ICONSET_DIR="$DIST_DIR/CTX.iconset"
ICON_FILE="$RESOURCES_DIR/CTX.icns"

cd "$ROOT_DIR"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

killall "$APP_NAME" >/dev/null 2>&1 || true

BUILD_CONFIG="debug"
if [[ "$MODE" == "release" ]]; then
  BUILD_CONFIG="release"
fi

swift build -c "$BUILD_CONFIG"
BUILD_BINARY="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$RESOURCES_DIR"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -f "$ICON_SVG" ]]; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  for size in 16 32 128 256 512; do
    qlmanage -t -s "$size" -o "$ICONSET_DIR" "$ICON_SVG" >/dev/null 2>&1
    mv "$ICONSET_DIR/CTXIcon.svg.png" "$ICONSET_DIR/icon_${size}x${size}.png"
    qlmanage -t -s "$((size * 2))" -o "$ICONSET_DIR" "$ICON_SVG" >/dev/null 2>&1
    mv "$ICONSET_DIR/CTXIcon.svg.png" "$ICONSET_DIR/icon_${size}x${size}@2x.png"
  done
  iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundleIconFile</key>
  <string>CTX</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Eliasaf Abargel</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  release)
    cd "$DIST_DIR"
    zip -qy -r "$APP_NAME.app.zip" "$APP_NAME.app"
    echo "Release packaged: $DIST_DIR/$APP_NAME.app.zip"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|release|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
