#!/bin/bash
# Builds CleanPaste as a universal (Apple Silicon + Intel) app.
# Output: build/CleanPaste.app and build/CleanPaste-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"

# Build and sign in a scratch directory: folders synced by iCloud (Documents/Desktop)
# get Finder attributes re-added, which makes codesign fail.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/CleanPaste.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" \
        -o "$WORK/CleanPaste-$ARCH" Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/CleanPaste" "$WORK/CleanPaste-arm64" "$WORK/CleanPaste-x86_64"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

rm -rf build
mkdir -p build
ditto --norsrc --noextattr --noqtn "$APP" "build/CleanPaste.app"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "build/CleanPaste-$VERSION.zip"
echo "OK: build/CleanPaste.app (v$VERSION, $(lipo -archs build/CleanPaste.app/Contents/MacOS/CleanPaste))"
echo "OK: build/CleanPaste-$VERSION.zip"
