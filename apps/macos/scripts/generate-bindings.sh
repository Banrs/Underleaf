#!/bin/sh
# The Swift bindings to the core's editor API (crates/texlocal-syntax), for the
# TeXLocalSyntax package. Run it after changing that API; CI checks that the
# committed ones are current.
set -e
cd "$(dirname "$0")/../../.."
cargo build -q -p texlocal-ffi
out=$(mktemp -d)
# Unformatted, so every machine writes the same file.
cargo run -q -p texlocal-bindgen -- generate target/debug/libtexlocal_ffi.dylib \
  --crate texlocal_syntax --language swift --no-format --out-dir "$out"
package=apps/macos/TeXLocalSyntax/Sources
cp "$out/texlocal_syntax.swift" "$package/TeXLocalSyntax/"
cp "$out/texlocal_syntaxFFI.h" "$package/texlocal_syntaxFFI/"
rm -r "$out"
