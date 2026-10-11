#!/bin/sh
# build.sh [folder] [make arguments…]
#
# TeXpresso at the commit Underleaf is verified against, with Underleaf's patch. With
# TEXPRESSO_PDF_OUTPUT set (<folder>/live.pdf) it opens no window of its own: the Mac app
# shows the live preview in its PDF pane. The editor says which pages it shows; a change is
# typeset as far as those, and each of them that changed is written into that folder at once
# as a PDF of its own. The rest of the document follows when typing pauses, then the whole
# document with its SyncTeX beside it (live.synctex), for the app's jumps between source and
# PDF. References and contents come from finishing passes that a second TeX runs beside the
# first, and that a keystroke drops. TeX's Type 1 fonts go into the PDFs as CFF copies
# (src/dvi/type1_cff.c): MuPDF's writer would embed them as PDF doesn't allow, and PDFKit
# would draw the wrong glyphs. It quits when its standard input closes, as the app's pipe
# does when the app quits or crashes.
#
# Without the variable it behaves as upstream does, but for one thing, in texpresso-xetex
# too: TeX Live's doc and source folders are left out of the files TeX can read, where a
# package's example color.cfg, graphics.cfg or hyperref.cfg was found before the real one.
#
# Needs TeXpresso's build dependencies (see its INSTALL.md). Then install.sh <folder>/build
# puts it where Underleaf finds it automatically (or choose <folder>/build in Settings).
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
