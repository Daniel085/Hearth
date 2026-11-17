#!/bin/bash
# Builds "Hearth Spark.app" so it gets its own macOS permissions (Contacts, Full Disk
# Access) instead of borrowing the terminal's.
#
#   scripts/make-app.sh            build into ./build/Hearth Spark.app
#
# Signs with an Apple Development or Developer ID identity if one is in the keychain.
# Otherwise signs ad hoc: fine on this Mac, but macOS then forgets the app's
# permissions every time it's rebuilt.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Hearth Spark.app"
swift build -c release --product HearthSparkApp
BIN="$(swift build -c release --product HearthSparkApp --show-bin-path)/HearthSparkApp"

# Refuse to package a binary that could reach the network.
scripts/check-no-network.sh "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HearthSparkApp"
cp Sources/HearthSparkApp/Info.plist "$APP/Contents/Info.plist"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E '"(Developer ID Application|Apple Development):' | head -1 \
  | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp=none \
    --entitlements Sources/HearthSparkApp/HearthSpark.entitlements \
    --sign "$IDENTITY" "$APP"
else
  echo "No signing identity found; signing ad hoc. Permissions will reset on each rebuild."
  codesign --force --options runtime \
    --entitlements Sources/HearthSparkApp/HearthSpark.entitlements \
    --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built: $(pwd)/$APP"
