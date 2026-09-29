#!/bin/sh
# Xcode build step: what the app shares with the web version, into its
# Resources: the menu's chords (web/src/shortcuts.json), the editor's
# JetBrains Mono (EditorFont registers it) and KaTeX for the maths preview.
set -e
cd "$SRCROOT/../.."
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
cp web/src/shortcuts.json "$DEST/"
mkdir -p "$DEST/Fonts" "$DEST/KaTeX/fonts"
cp node_modules/@fontsource/jetbrains-mono/files/jetbrains-mono-latin-400-normal.woff2 node_modules/@fontsource/jetbrains-mono/LICENSE "$DEST/Fonts/"
cp node_modules/katex/dist/katex.min.js node_modules/katex/dist/katex.min.css node_modules/katex/LICENSE "$DEST/KaTeX/"
cp node_modules/katex/dist/fonts/*.woff2 "$DEST/KaTeX/fonts/"
