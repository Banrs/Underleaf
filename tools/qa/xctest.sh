#!/bin/zsh
S=${QA_SCRATCH:?export QA_SCRATCH=<scratchpad>, set up by tools/qa/setup.sh}; R=${1:A}; D=$2; shift 2
zmodload zsh/system
mkdir -p $S/locks $S/logs
: >> $S/locks/xctest.lock
zsystem flock $S/locks/xctest.lock
L=$S/logs/xctest-${D:t}.log
rm -rf $D/Build/Intermediates.noindex/xctest-{data,state}
xcodebuild -project $R/apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath $D -parallel-testing-enabled NO TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev CODE_SIGNING_ALLOWED=NO test "$@" > $L 2>&1
r=$?
grep -E "error:|✘|recorded an issue|Test run with|TEST (SUCCEEDED|FAILED)|BUILD FAILED|RENDER:" $L | sort -u | tail -30
echo "log: $L"
exit $r
