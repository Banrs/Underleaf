#!/bin/zsh
root=${1:-$PWD}
[[ -d $root/apps/macos/TeXLocal ]] || { echo "typecheck: no apps/macos/TeXLocal under $root"; exit 2; }
PLAT=$(xcrun --sdk macosx --show-sdk-platform-path)
SDK=$(xcrun --sdk macosx --show-sdk-path)
out=$(mktemp -d)
common=(-Onone -DDEBUG -swift-version 6 -I $root/crates/texlocal-ffi/include -parse-as-library -default-isolation=MainActor -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature MemberImportVisibility -enable-upcoming-feature ExistentialAny)
flags=($common -sdk $SDK -target arm64-apple-macos27.0)
show() { grep -E "(error|warning):" | sed "s#$root/##" | sort -u }
xcrun swiftc -emit-module -emit-module-path $out/TeXLocal.swiftmodule -module-name TeXLocal -enable-testing \
  $flags $root/apps/macos/TeXLocal/*.swift 2>&1 | show
app=${pipestatus[1]}
if (( app != 0 )); then echo "typecheck: the app's sources have errors (tests not checked)"; rm -rf $out; exit 1; fi
xcrun swiftc -typecheck -module-name TeXLocalTests $flags -I $out \
  -F $PLAT/Developer/Library/Frameworks -I $PLAT/Developer/usr/lib -plugin-path ${$(xcrun -f swiftc):h:h}/lib/swift/host/plugins/testing \
  $root/apps/macos/TeXLocalTests/*.swift 2>&1 | show
tests=${pipestatus[1]}
rm -rf $out
(( tests == 0 )) && echo "typecheck: ok" || { echo "typecheck: the tests have errors"; exit 1; }
