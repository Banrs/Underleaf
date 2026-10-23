#!/bin/sh
# run-sim.sh <build folder> <doc folder> <out folder> [TeX tree]
#
# Builds host.c against <build folder>/Texpresso.xcframework and runs it in a
# booted iPad simulator (xcrun simctl spawn: a process of the simulator's iOS,
# without an app's window), as the app would run the engine. The TeX tree is
# read in place: by default this Mac's TeX Live, or a tree made by tree.sh.
set -eu
BUILD=$(cd "$1" && pwd) DOC=$(cd "$2" && pwd)
mkdir -p "$3"
OUT=$(cd "$3" && pwd)
TREE=${4:-$(kpsewhich -var-value=TEXMFROOT)}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEVICE=${TEXPRESSO_SIM:-booted}
SLICE=$BUILD/Texpresso.xcframework/ios-arm64-simulator

xcrun --sdk iphonesimulator clang -O2 -target arm64-apple-ios17.0-simulator \
  -I"$SLICE/Headers" "$HERE/host.c" "$SLICE/libtexpresso.a" -lz -lc++ -o "$OUT/host"

lsr=""
for f in "$TREE"/texmf-dist/ls-R "$TREE"/texmf-var/ls-R "$TREE"/texmf-config/ls-R; do
  [ -f "$f" ] && lsr="$lsr${lsr:+:}$f"
done
mkdir -p "$OUT/texmf-var" "$OUT/cache"
export SIMCTL_CHILD_TEXMFCNF="$TREE/texmf-dist/web2c"
export SIMCTL_CHILD_TEXMFROOT="$TREE"
export SIMCTL_CHILD_TEXMFDIST="$TREE/texmf-dist"
export SIMCTL_CHILD_TEXMFVAR="$OUT/texmf-var"
export SIMCTL_CHILD_TEXPRESSO_LSR="$lsr"
export SIMCTL_CHILD_TEXPRESSO_CACHE="$OUT/cache"
export SIMCTL_CHILD_ICU_DATA="$BUILD/texpresso/engines/build-wasm2c-xetex"
export SIMCTL_CHILD_HOST_LOG="$OUT/live.log"
export SIMCTL_CHILD_HOST_TEX_LOG="$OUT/compile.log"
xcrun simctl spawn "$DEVICE" "$OUT/host" "$DOC" "$OUT"
