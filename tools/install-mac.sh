#!/bin/zsh
# install-mac.sh [derived data dir]: builds the Release app of the checkout this script is in, quits TeXLocal,
# replaces /Applications/TeXLocal.app with it signed ad hoc, checks the signature and the binary, and reopens it.
set -e
R=${0:A:h:h}
D=${1:-/private/tmp/underleaf-release}
APP=$D/Build/Products/Release/TeXLocal.app
DEST=/Applications/TeXLocal.app

if ! xcodebuild -project $R/apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Release \
    -destination 'platform=macOS' -derivedDataPath $D CODE_SIGNING_ALLOWED=NO build > $D.log 2>&1; then
  grep -E "error:" $D.log | sort -u | tail -20
  echo "build failed: $D.log"
  exit 1
fi
codesign --force --deep --sign - $APP

# Quit the installed copy by its bundle id, leaving a QA or test copy alone; NSRunningApplication because
# osascript raises an Automation prompt.
xcrun swift -e 'import AppKit
NSRunningApplication.runningApplications(withBundleIdentifier: "com.texlocal.mac").forEach { $0.terminate() }' \
  2>/dev/null || true
for _ in {1..50}; do pgrep -qf "^$DEST/" || break; sleep 0.2; done
pgrep -qf "^$DEST/" && { echo "TeXLocal is still running: not installed"; exit 1 }

rm -rf $DEST
ditto $APP $DEST
codesign --verify --deep --strict $DEST
cmp -s $APP/Contents/MacOS/TeXLocal $DEST/Contents/MacOS/TeXLocal \
  || { echo "installed binary differs from the build"; exit 1 }
echo "installed $(git -C $R rev-parse --short HEAD) to $DEST"
open $DEST
