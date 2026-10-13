#!/bin/bash
# Builds CleanPaste and produces build/CleanPaste.app
set -euo pipefail
cd "$(dirname "$0")"

# Build and sign in a scratch directory: folders synced by iCloud (Documents/Desktop)
# get Finder attributes re-added, which makes codesign fail.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/CleanPaste.app"

mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/CleanPaste" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

rm -rf build
mkdir -p build
ditto --norsrc --noextattr --noqtn "$APP" "build/CleanPaste.app"
echo "OK: build/CleanPaste.app"
