#!/bin/bash
# Builds the app for the simulator without needing `sudo xcode-select`.
#   ./build.sh           build only
#   ./build.sh run       build, install and launch on the booted simulator
#   ./build.sh test      run the unit tests
set -o pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SCHEME="NTCGSimulator"
BUNDLE_ID="com.practiceMakesPerfect.personalProjects.NTCGSimulator"
# Pick whatever iPhone simulator this machine actually has — a hardcoded name
# breaks whenever Xcode's bundled device set changes.
SIM_NAME="$(xcrun simctl list devices available 2>/dev/null \
  | grep -oE 'iPhone [^(]*' | head -1 | sed 's/ *$//')"
DEST="platform=iOS Simulator,name=${SIM_NAME:-iPhone 15}"
DERIVED="$(cd "$(dirname "$0")" && pwd)/.build"

cd "$(dirname "$0")" || exit 1

case "${1:-build}" in
  test)
    xcodebuild test -scheme "$SCHEME" -destination "$DEST" \
      -derivedDataPath "$DERIVED" -quiet
    ;;
  run)
    xcodebuild build -scheme "$SCHEME" -destination "$DEST" \
      -derivedDataPath "$DERIVED" -quiet || exit 1
    APP="$DERIVED/Build/Products/Debug-iphonesimulator/$SCHEME.app"
    xcrun simctl install booted "$APP" || exit 1
    xcrun simctl launch booted "$BUNDLE_ID"
    ;;
  *)
    xcodebuild build -scheme "$SCHEME" -destination "$DEST" \
      -derivedDataPath "$DERIVED" -quiet
    ;;
esac
