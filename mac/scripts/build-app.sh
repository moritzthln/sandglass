#!/usr/bin/env bash
# Builds Sandglass.app: the menu bar app, and nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."

# The pinned toolchain, and the one place it can be pinned for good. Every release binary is built
# by Swift 5.10 / Command Line Tools, whatever `swift` happens to be on PATH — an Xcode on the Mac
# makes the default a newer compiler, and SwiftUI layout depends on the SDK a build links against,
# so one pinned toolchain is what keeps a release looking like the build it was tested as. Here
# rather than in every caller, because `test-keepalive.sh` runs against whatever this produced.
# An explicit DEVELOPER_DIR from the environment still wins, for a deliberate toolchain switch.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"

# Universal, so the bundle runs on an Intel Mac as well as on Apple Silicon. A binary with only
# the host slice in it does not fail visibly on the other architecture — it does not launch at
# all, and the person it was sent to has nothing to read.
#
# Two ways there, and the toolchain decides which. `swift build --arch` needs xcbuild, which only
# a full Xcode carries; the Command Line Tools this script pins have no such thing, so each slice
# is built by its own triple and `lipo` joins them. The test is `DEVELOPER_DIR` rather than
# `xcode-select -p`, because the line above has already decided which toolchain this build uses
# and the system-wide selection has nothing to say about it.
if [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
  swift build -c release --product Sandglass --arch arm64 --arch x86_64
  BINARY=".build/apple/Products/Release/Sandglass"
else
  swift build -c release --product Sandglass --triple arm64-apple-macosx14.0
  swift build -c release --product Sandglass --triple x86_64-apple-macosx14.0
  BINARY="$(mktemp -d)/Sandglass"
  lipo -create ".build/arm64-apple-macosx/release/Sandglass" \
       ".build/x86_64-apple-macosx/release/Sandglass" -output "$BINARY"
fi

APP="build/Sandglass.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp "$BINARY" "$APP/Contents/MacOS/Sandglass"
# The page a blocked tab is navigated to. It is opened straight out of the bundle as a file:// URL
# — no local HTTP server — so it has to actually be in the bundle: without it every blocked site
# falls back to the overlay, silently. See `BlockPage`.
cp Resources/block.html "$APP/Contents/Resources/block.html"
# The icon. Committed rather than rendered here, so a build stays a build; `scripts/make-icon.swift`
# draws it and is the place to change it. It matters more than a menu-bar app's icon usually does:
# System Settings lists Sandglass in Accessibility and Automation, and after every reinstall that
# list is exactly where the user has to go.
cp Resources/Sandglass.icns "$APP/Contents/Resources/Sandglass.icns"

# Ad-hoc: there is no Developer ID behind this build, which is why a downloaded copy meets
# Gatekeeper on first launch (see the README) and why macOS drops the Accessibility grant
# every time the bundle is replaced.
codesign --force --sign - "$APP"
# Said out loud: a build that quietly lost a slice is the failure this exists to prevent,
# and it is invisible until somebody on the other architecture cannot open the app.
echo "Built $APP"
lipo -info "$APP/Contents/MacOS/Sandglass"
