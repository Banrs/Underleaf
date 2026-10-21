#!/bin/zsh
# setup.sh <scratchpad>: builds the QA driver and its helpers into <scratchpad>/qa and lays out a fresh copy of the
# seed library (<scratchpad>/qa-library-seed, copied to qa-library before each launch that wants a clean state).
# Then: export QA_SCRATCH=<scratchpad>, and build the app under test with build.sh.
set -e
S=${1:?usage: setup.sh <scratchpad>}; S=${S:A}; T=${0:A:h}
mkdir -p $S/qa $S/logs $S/locks
xcrun swiftc -O -o $S/qa/qa $T/qa.swift
clang -dynamiclib -framework Cocoa -o $S/qa/appearance.dylib $T/appearance.m
for n in locked cgwin; do xcrun swiftc -O -o $S/qa/$n $T/$n.swift; done
rsync -a --delete --exclude='*.gz' $T/library-seed/ $S/qa-library-seed/
# Stored compressed: its text came from an unrecorded random generator, so it can't be regenerated.
L="Test Long (400 pages)/main.tex"; gunzip -c "$T/library-seed/$L.gz" > "$S/qa-library-seed/$L"
rsync -a --delete $S/qa-library-seed/ $S/qa-library/
echo "ready: export QA_SCRATCH=$S"
