#!/bin/zsh
S=${TMPDIR:-/tmp}/texlocal-xctest; R=${1:A}; D=$2; shift 2
zmodload zsh/system
mkdir -p $S/locks $S/logs
: >> $S/locks/xctest.lock
zsystem flock $S/locks/xctest.lock
# Named after the folder for reading and a digest of its whole path for telling apart, so the name stays one a disk takes.
L=$S/logs/xctest-${${D:A:t}[1,40]}-$(print -rn -- ${D:A} | shasum | cut -c1-12).log
rm -rf $D/Build/Intermediates.noindex/xctest-{data,state}
xcodebuild -project $R/apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath $D -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test "$@" > $L 2>&1
r=$?
grep -E "error:|✘|recorded an issue|Test run with|TEST (SUCCEEDED|FAILED)|BUILD FAILED|RENDER:" $L | sort -u | tail -30
echo "log: $L"
exit $r
