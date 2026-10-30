#!/bin/sh
set -e
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/.."
[ "$CONFIGURATION" = Release ] && set -- --release
cargo build --locked --target-dir target -p texlocal-ffi "$@"
