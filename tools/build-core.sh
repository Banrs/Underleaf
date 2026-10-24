#!/bin/sh
# The Mac app's Xcode pre-build step: the Rust core as a static library.
set -e
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/.."
if [ "$CONFIGURATION" = "Release" ]; then
  cargo build -p texlocal-ffi --release
else
  cargo build -p texlocal-ffi
fi
