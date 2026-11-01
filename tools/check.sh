#!/bin/zsh
# What CI checks of the sources, short of the app's tests (tools/xctest.sh) and cargo-deny. The Rust tests include the
# generated Models/Wire.swift being up to date.
set -e
cd ${0:A:h:h}
cargo fmt --all --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
if (( $+commands[cargo-shear] )); then cargo shear; else echo "cargo-shear isn't installed; CI runs it"; fi
zsh tools/typecheck.sh
