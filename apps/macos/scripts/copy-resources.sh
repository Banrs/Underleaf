#!/bin/sh
# Xcode build step: what the app shares with the web version, into its
# Resources: the menu's chords (web/src/shortcuts.json) and the editor's
# JetBrains Mono, which Info.plist's ATSApplicationFontsPath registers.
set -e
cd "$SRCROOT/../.."
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
cp web/src/shortcuts.json "$DEST/"
mkdir -p "$DEST/Fonts"
cp node_modules/@fontsource/jetbrains-mono/files/jetbrains-mono-latin-400-normal.woff2 node_modules/@fontsource/jetbrains-mono/LICENSE "$DEST/Fonts/"
