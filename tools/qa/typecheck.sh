#!/bin/zsh
# typecheck.sh [repo root, default the current directory]: type-checks the Mac app's sources, then its tests against
# them, without Xcode's build. Exits 0 with no errors.
root=${1:-$PWD}
[[ -d $root/apps/macos/TeXLocal ]] || { echo "typecheck: no apps/macos/TeXLocal under $root"; exit 2 }
DEV=/Applications/Xcode.app/Contents/Developer
PLAT=$DEV/Platforms/MacOSX.platform
out=$(mktemp -d)
trap 'rm -rf $out' EXIT
# The main actor is the default isolation of the app and of the tests (project.yml).
flags=(
  -Onone -DDEBUG -swift-version 6 -sdk $PLAT/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos27.0
  -I $root/crates/texlocal-ffi/include -parse-as-library -default-isolation=MainActor
  -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault
)
show() { grep -E "(error|warning):" | sed "s#$root/##" | sort -u }

xcrun swiftc -emit-module -emit-module-path $out/TeXLocal.swiftmodule -module-name TeXLocal -enable-testing \
  $flags $root/apps/macos/TeXLocal/*.swift 2>&1 | show
(( pipestatus[1] == 0 )) || { echo "typecheck: the app's sources have errors (tests not checked)"; exit 1 }

xcrun swiftc -typecheck -module-name TeXLocalTests $flags -I $out \
  -F $PLAT/Developer/Library/Frameworks -I $PLAT/Developer/usr/lib \
  -plugin-path $DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing \
  $root/apps/macos/TeXLocalTests/*.swift 2>&1 | show
(( pipestatus[1] == 0 )) || { echo "typecheck: the tests have errors"; exit 1 }
echo "typecheck: ok"
