#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Menubar Native Control"
BUNDLE_ID="com.local.MenubarNativeControl"
EXECUTABLE_NAME="MenubarNativeControl"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

# Authoritative version; bumped by the release job via Scripts/set-version.mjs.
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"

cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

# Set MACOS_UNIVERSAL=1 to ship a universal (arm64 + x86_64) binary; otherwise build
# for the host architecture only. Each architecture is built separately and merged
# with lipo, which uses SwiftPM's native build system and needs only the Command Line
# Tools (the combined `swift build --arch a --arch b` form requires a full Xcode).
build_arch() {
    swift build -c release --arch "$1" >&2
    swift build -c release --arch "$1" --show-bin-path
}

if [[ -n "${MACOS_UNIVERSAL:-}" ]]; then
    ARM_DIR="$(build_arch arm64)"
    X86_DIR="$(build_arch x86_64)"
    lipo -create \
        "$ARM_DIR/$EXECUTABLE_NAME" \
        "$X86_DIR/$EXECUTABLE_NAME" \
        -output "$MACOS_DIR/$EXECUTABLE_NAME"
else
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
    cp "$BIN_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
