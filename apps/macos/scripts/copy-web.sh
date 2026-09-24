#!/bin/sh
# Xcode build step: the embedded editor page and what it loads, into the app's
# Resources/web — only the embed files, not the browser UI.
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$SRCROOT/../.."
npm run build --silent
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/web"
rm -rf "$DEST"
mkdir -p "$DEST/dist" "$DEST/embed"
cp web/styles.css "$DEST/"
cp web/embed/editor.html "$DEST/embed/"
cp web/dist/embed-editor.js web/dist/katex.min.css "$DEST/dist/"
cp -R web/dist/fonts web/dist/fonts-jbm "$DEST/dist/"
