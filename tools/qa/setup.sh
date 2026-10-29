#!/bin/zsh
set -e
S=${1:?usage: setup.sh <scratchpad>}; S=${S:A}; T=${0:A:h}
mkdir -p $S/qa
xcrun swiftc -O -o $S/qa/qa $T/qa.swift
clang -dynamiclib -framework Cocoa -o $S/qa/appearance.dylib $T/appearance.m
rsync -a --delete --exclude='*.gz' $T/library-seed/ $S/qa-library-seed/
L="Test Long (400 pages)/main.tex"; gunzip -c "$T/library-seed/$L.gz" > "$S/qa-library-seed/$L"
rsync -a --delete $S/qa-library-seed/ $S/qa-library/
echo "ready: export QA_SCRATCH=$S"
