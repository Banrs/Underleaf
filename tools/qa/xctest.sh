#!/bin/zsh
# xctest.sh <repo root> <derived data dir> [xcodebuild args after `test`…]: the native tests of one checkout. One run
# at a time across the whole session (the test host shares a data folder), so it waits its turn.
S=${QA_SCRATCH:?export QA_SCRATCH=<scratchpad>, set up by tools/qa/setup.sh}; R=${1:A}; D=$2; shift 2
mkdir -p $S/locks $S/logs
while ! mkdir $S/locks/xctest 2>/dev/null; do
  # A run that was killed leaves its lock: one older than 25 minutes is taken over.
  if [[ -n $(find $S/locks/xctest -maxdepth 0 -mmin +25 2>/dev/null) ]]; then rmdir $S/locks/xctest 2>/dev/null; else sleep 4; fi
done
trap 'rmdir $S/locks/xctest 2>/dev/null' EXIT
L=$S/logs/xctest-${D:t}.log
xcodebuild -project $R/apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath $D -parallel-testing-enabled NO TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.dev CODE_SIGNING_ALLOWED=NO test "$@" > $L 2>&1
r=$?
grep -E "error:|✘|recorded an issue|Test run with|TEST (SUCCEEDED|FAILED)|BUILD FAILED|RENDER:" $L | sort -u | tail -30
echo "log: $L"
exit $r
