#!/bin/sh
# build.sh [folder] [make arguments…]
#
# TeXpresso at the commit Underleaf is verified against, with Underleaf's patch (what it
# does is in docs/texpresso.md). Needs TeXpresso's build dependencies (see its INSTALL.md).
# Then install.sh <folder>/build puts it where Underleaf finds it automatically (or choose
# <folder>/build in Settings).
set -eu
COMMIT=e8df7709077b2f86f6e16e6c86ceefb86de06f8d
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEST=${1:-"$HERE/source"}
[ $# -gt 0 ] && shift

[ -d "$DEST/.git" ] || git clone https://github.com/let-def/texpresso.git "$DEST"
cd "$DEST"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || git fetch origin "$COMMIT"
# Already applied, as a rebuild finds it: build what's there.
if ! git apply --reverse --check "$HERE/underleaf-pdf.patch" 2>/dev/null; then
  git checkout --quiet --detach "$COMMIT"
  git apply "$HERE/underleaf-pdf.patch"
fi
make -j4 all "$@"
echo "Built $DEST/build/texpresso. Run $HERE/install.sh $DEST/build to install it."
