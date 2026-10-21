#!/bin/zsh
# build.sh [repo root]: builds the QA copy (bundle com.texlocal.mac.qa, Debug) into $QA_SCRATCH/dd-frontend and signs it
# ad hoc. The repo defaults to the one this script is in, so a worktree builds its own sources.
S=${QA_SCRATCH:?export QA_SCRATCH=<scratchpad>, set up by tools/qa/setup.sh}; R=${1:-${0:A:h:h:h}}
mkdir -p $S/logs
xcodebuild -project $R/apps/macos/TeXLocal.xcodeproj -scheme TeXLocal -configuration Debug -destination platform=macOS \
  -derivedDataPath $S/dd-frontend TEXLOCAL_APP_IDENTIFIER=com.texlocal.mac.qa CODE_SIGNING_ALLOWED=NO build > $S/logs/qa-build.log 2>&1
r=$?
grep -E "error:|BUILD (SUCCEEDED|FAILED)" $S/logs/qa-build.log | sort -u | tail -8
(( r == 0 )) && codesign --force --deep --sign - $S/dd-frontend/Build/Products/Debug/TeXLocal.app 2>&1 | tail -1
exit $r
