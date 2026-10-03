#!/bin/sh
# Xcode build step: what the app shares with the web version, into its
# Resources: the menu's chords (web/src/shortcuts.json), the editor's
# JetBrains Mono (EditorFont registers it) and KaTeX for the maths preview.
set -e
cd "$SRCROOT/../.."
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST/Fonts" "$DEST/KaTeX/fonts"

# Check contents without touching unchanged bundle files. Only this phase owns
# KaTeX/fonts, so removed package fonts can be removed there too.
/usr/bin/rsync -c web/src/shortcuts.json "$DEST/"
/usr/bin/rsync -c node_modules/@fontsource/jetbrains-mono/files/jetbrains-mono-latin-400-normal.woff2 node_modules/@fontsource/jetbrains-mono/LICENSE "$DEST/Fonts/"
/usr/bin/rsync -c node_modules/katex/dist/katex.min.js node_modules/katex/dist/katex.min.css node_modules/katex/LICENSE "$DEST/KaTeX/"
/usr/bin/rsync -rc --delete --include='*.woff2' --exclude='*' node_modules/katex/dist/fonts/ "$DEST/KaTeX/fonts/"
