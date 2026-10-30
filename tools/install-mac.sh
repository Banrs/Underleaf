#!/bin/zsh
set -e
R=${0:A:h:h}
if [[ $1 == --dev ]]; then
  shift; NAME="TeXLocal Dev"; ID=com.texlocal.mac.devbuild; DEST=~/Applications/$NAME.app; D=${1:-/private/tmp/underleaf-dev}
else
  NAME=TeXLocal; ID=com.texlocal.mac; DEST=/Applications/TeXLocal.app; D=${1:-/private/tmp/underleaf-release}
fi
APP=$D/Build/Products/Release/TeXLocal.app

xcodebuild -project $R/apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Release \
  -destination 'platform=macOS' -derivedDataPath $D TEXLOCAL_APP_IDENTIFIER=$ID CURRENT_PROJECT_VERSION=$(git -C $R rev-list --count HEAD) CODE_SIGNING_ALLOWED=NO build > $D.log 2>&1 \
  || { grep -E "error:" $D.log | sort -u | tail -20; echo "build failed: $D.log"; exit 1; }
if [[ $NAME != TeXLocal ]]; then
  for key in CFBundleName CFBundleDisplayName; do plutil -replace $key -string $NAME $APP/Contents/Info.plist; done
  plutil -replace LSEnvironment -json "{\"TEXLOCAL_DATA\": \"$HOME/$NAME\"}" $APP/Contents/Info.plist
fi
codesign --force --deep --sign - $APP

xcrun swift -e "import AppKit
NSRunningApplication.runningApplications(withBundleIdentifier: \"$ID\").forEach { \$0.terminate() }" 2>/dev/null || true
for _ in {1..50}; do pgrep -qf "^$DEST/" || break; sleep 0.2; done
pgrep -qf "^$DEST/" && { echo "$NAME is still running: not installed"; exit 1; }

mkdir -p ${DEST:h}
rm -rf $DEST.new; ditto $APP $DEST.new
rm -rf $DEST; mv $DEST.new $DEST
codesign --verify --deep --strict $DEST
cmp -s $APP/Contents/MacOS/TeXLocal $DEST/Contents/MacOS/TeXLocal || { echo "installed binary differs from the build"; exit 1; }
echo "installed $(git -C $R rev-parse --short HEAD) to $DEST"
open $DEST
