#!/bin/zsh
# install-mac.sh [derived data dir]: builds the Mac app's Release product, quits TeXLocal, replaces
# /Applications/TeXLocal.app with it signed ad hoc, checks the signature and that the installed binary is the one
# built, and reopens it. Run from any checkout: it builds the one this script is in.
set -e
R=${0:A:h:h}; D=${1:-/private/tmp/underleaf-release}
APP=$D/Build/Products/Release/TeXLocal.app; DEST=/Applications/TeXLocal.app

xcodebuild -project $R/apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Release \
  -destination 'platform=macOS' -derivedDataPath $D CODE_SIGNING_ALLOWED=NO build > $D.log 2>&1 \
  || { grep -E "error:" $D.log | sort -u | tail -20; echo "build failed: $D.log"; exit 1; }
codesign --force --deep --sign - $APP

# Quit the installed copy (by its bundle id, so a QA or test copy is left alone) and wait for it to go.
# NSRunningApplication rather than osascript, which raises an Automation prompt.
xcrun swift -e 'import AppKit
NSRunningApplication.runningApplications(withBundleIdentifier: "com.texlocal.mac").forEach { $0.terminate() }' 2>/dev/null || true
for _ in {1..50}; do pgrep -qf "^$DEST/" || break; sleep 0.2; done
pgrep -qf "^$DEST/" && { echo "TeXLocal is still running: not installed"; exit 1; }

# Copied beside it first, so a failed copy leaves the installed app as it was.
rm -rf $DEST.new; ditto $APP $DEST.new
rm -rf $DEST; mv $DEST.new $DEST
codesign --verify --deep --strict $DEST
cmp -s $APP/Contents/MacOS/TeXLocal $DEST/Contents/MacOS/TeXLocal || { echo "installed binary differs from the build"; exit 1; }
echo "installed $(git -C $R rev-parse --short HEAD) to $DEST"
open $DEST
