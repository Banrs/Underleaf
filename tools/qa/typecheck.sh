#!/bin/zsh
root=${1:-$PWD}
[[ -d $root/apps/macos/TeXLocal ]] || { echo "typecheck: no apps/macos/TeXLocal under $root"; exit 2; }
PLAT=$(xcrun --sdk macosx --show-sdk-platform-path)
SDK=$(xcrun --sdk macosx --show-sdk-path)
out=$(mktemp -d)
common=(-Onone -DDEBUG -swift-version 6 -I $root/crates/texlocal-ffi/include -parse-as-library -default-isolation=MainActor -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature MemberImportVisibility -enable-upcoming-feature ExistentialAny)
flags=($common -sdk $SDK -target arm64-apple-macos27.0)
models=(Wire Core Concurrency Models AppModel WindowModel Commands ProjectModel ProjectModel+Build ProjectModel+Files ProjectModel+Live
  ProjectNotices ProjectSearch TeXpressoSession FileTree BuildPanelModel SourceDocument Undo LaTeX EditorCommand Outline
  FoldSet EditSync TextOffsets)
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
xcrun swiftc -typecheck -module-name TeXLocal $common -sdk $(xcrun --sdk iphoneos --show-sdk-path) \
  -target arm64-apple-ios$(xcrun --sdk iphoneos --show-sdk-version) $root/apps/macos/TeXLocal/${^models}.swift 2>&1 | show
ios=${pipestatus[1]}
(( tests == 0 )) || echo "typecheck: the tests have errors"
(( ios == 0 )) || echo "typecheck: the model files have errors for iOS"
(( tests == 0 && ios == 0 )) && echo "typecheck: ok"
