#!/bin/zsh
# Type-checks the Mac app's sources, then its tests against them, without Xcode's build: about half a minute.
# usage: typecheck.sh [repo root, default the current directory]    exit 0 = no errors
root=${1:-$PWD}
[[ -d $root/apps/macos/TeXLocal ]] || { echo "typecheck: no apps/macos/TeXLocal under $root"; exit 2; }
PLAT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform
SDK=$PLAT/Developer/SDKs/MacOSX.sdk
out=$(mktemp -d)
base=(-Onone -DDEBUG -swift-version 6 -sdk $SDK -target arm64-apple-macos27.0 -I $root/crates/texlocal-ffi/include -parse-as-library)
# The main actor is the default isolation of the app target and of the tests (project.yml).
flags=($base -default-isolation=MainActor -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault)
show() { grep -E "(error|warning):" | sed "s#$root/##" | sort -u }
xcrun swiftc -emit-module -emit-module-path $out/TeXLocal.swiftmodule -module-name TeXLocal -enable-testing \
  $flags $root/apps/macos/TeXLocal/*.swift 2>&1 | show
app=${pipestatus[1]}
if (( app != 0 )); then echo "typecheck: the app's sources have errors (tests not checked)"; rm -rf $out; exit 1; fi
xcrun swiftc -typecheck -module-name TeXLocalTests $base -default-isolation=MainActor -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault -I $out \
  -F $PLAT/Developer/Library/Frameworks -I $PLAT/Developer/usr/lib -plugin-path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing \
  $root/apps/macos/TeXLocalTests/*.swift 2>&1 | show
tests=${pipestatus[1]}
rm -rf $out
(( tests == 0 )) && echo "typecheck: ok" || { echo "typecheck: the tests have errors"; exit 1; }
