#!/bin/sh
# Xcode pre-build step of both apps: the Rust core as a static library for the SDK Xcode builds with.
set -e
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/.."
case "$PLATFORM_NAME" in
  iphoneos) set -- --target aarch64-apple-ios ;;
  iphonesimulator) set -- --target aarch64-apple-ios-sim ;;
  *) set -- ;;
esac
if [ "$CONFIGURATION" = "Release" ]; then
  cargo build -p texlocal-ffi --release "$@"
else
  cargo build -p texlocal-ffi "$@"
fi
