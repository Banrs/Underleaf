#!/bin/sh
# Xcode pre-build step: the Rust core as a static library for the app to link.
# Debug builds link target/debug, Release builds target/release.
set -e
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$SRCROOT/../.."
if [ "$CONFIGURATION" = "Release" ]; then
  cargo build -p texlocal-ffi --release
else
  cargo build -p texlocal-ffi
fi
