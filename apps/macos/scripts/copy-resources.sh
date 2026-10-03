#!/bin/sh
# Xcode build step: KaTeX, which the app shares with the web version, into its
# Resources for the maths preview.
set -e
cd "$SRCROOT/../.."
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST/KaTeX/fonts"

# Check contents without touching unchanged bundle files. Only this phase owns
# KaTeX/fonts, so removed package fonts can be removed there too.
/usr/bin/rsync -c node_modules/katex/dist/katex.min.js node_modules/katex/dist/katex.min.css node_modules/katex/LICENSE "$DEST/KaTeX/"
/usr/bin/rsync -rc --delete --include='*.woff2' --exclude='*' node_modules/katex/dist/fonts/ "$DEST/KaTeX/fonts/"
