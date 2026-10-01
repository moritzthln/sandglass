#!/usr/bin/env bash
# Builds a universal Sandglass.app and packs it as the zip a GitHub release carries.
#
# The version is read from scripts/Info.plist (CFBundleShortVersionString), so the bundle and the
# file name can never disagree. `ditto -c -k --sequesterRsrc --keepParent` is what Finder's own
# "Compress" does: the zip unpacks to Sandglass.app with its signature and attributes intact,
# which a plain `zip -r` does not guarantee.
#
#   usage: mac/scripts/release.sh
#   output: mac/build/Sandglass-<version>.zip, and its SHA-256 on stdout
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" scripts/Info.plist)
APP="build/Sandglass.app"
ZIP="build/Sandglass-$VERSION.zip"

echo "== building Sandglass $VERSION =="
scripts/build-app.sh

# A release that lost a slice is the one failure a user cannot diagnose: the app just does not
# open on their Mac. Refuse to pack it rather than ship it.
ARCHS=$(lipo -archs "$APP/Contents/MacOS/Sandglass")
for arch in arm64 x86_64; do
  case " $ARCHS " in
    *" $arch "*) ;;
    *) echo "FAIL: $APP has no $arch slice (has: $ARCHS)." >&2; exit 1 ;;
  esac
done

echo "== packing $ZIP =="
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

echo
echo "Release: $ZIP"
echo "SHA-256: $SHA"
