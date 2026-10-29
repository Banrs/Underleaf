#!/bin/sh
set -eu
COMMIT=e8df7709077b2f86f6e16e6c86ceefb86de06f8d
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEST=${1:-"$HERE/source"}
[ $# -gt 0 ] && shift

[ -d "$DEST/.git" ] || git clone https://github.com/let-def/texpresso.git "$DEST"
cd "$DEST"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || git fetch origin "$COMMIT"
git checkout --quiet --force --detach "$COMMIT"
git clean --quiet --force -d src
git apply "$HERE/underleaf-pdf.patch"
cp -R "$HERE/src/." src/
ICU=$(brew list --formula | grep -E '^icu4c(@[0-9]+)?$' | sort -V | tail -1)
[ -n "$ICU" ] || { echo "build.sh: TeXpresso needs icu4c: brew install icu4c" >&2; exit 1; }
make -j4 all BREW_ICU4C="$(brew --prefix "$ICU")" "$@"
echo "Built $DEST/build/texpresso. Run $HERE/install.sh $DEST/build to install it."
