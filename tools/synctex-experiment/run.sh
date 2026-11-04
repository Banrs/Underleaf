#!/usr/bin/env bash
set -euo pipefail

# The source is an experimental dependency, never part of the application build.
pin=04cf8e3e8665ff203248d7af78ee1129afbc1b64
results="$1"
native="$results/upstream"
mkdir -p "$native"
curl --retry 3 -fsSL "https://codeload.github.com/jlaurens/synctex/tar.gz/$pin" \
  | tar -xz --strip-components=1 -C "$native"
cc -O2 -D__SYNCTEX_STRONG_DISPLAY_QUERY__ -I "$native" \
  tools/synctex-experiment/probe.c \
  "$native/synctex_parser.c" "$native/synctex_parser_utils.c" \
  -lz -o "$results/upstream-probe"
cargo build --locked --release -p texlocal-core --example synctex_probe
python3 tools/synctex-experiment/generate.py "$results"
python3 tools/synctex-experiment/compare.py "$results" \
  "$PWD/target/release/examples/synctex_probe" "$results/upstream-probe"
