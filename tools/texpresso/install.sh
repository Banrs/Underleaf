#!/bin/bash
set -euo pipefail
fail() { echo "install.sh: $*" >&2; exit 1; }
BUILD=$(CDPATH= cd -- "${1:?usage: install.sh <build folder> [destination]}" && pwd)
DEST=${2:-"$HOME/Library/Application Support/TeXLocal/TeXpresso"}
DEST=${DEST%/}
for file in texpresso texpresso-xetex; do
  [ -f "$BUILD/$file" ] || fail "$BUILD has no $file; build it with build.sh first"
done
if [ -e "$DEST" ] && [ ! -x "$DEST/bin/texpresso" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  fail "$DEST exists and is not a TeXpresso installation"
fi
mkdir -p "$(dirname "$DEST")"
STAGE=$(mktemp -d "$DEST.new.XXXXXX")
OLD=
cleanup() {
  if [ -n "$OLD" ] && [ -e "$OLD/previous" ] && [ ! -e "$DEST" ]; then mv "$OLD/previous" "$DEST"; fi
  rm -rf "$STAGE" ${OLD:+"$OLD"}
}
trap cleanup EXIT
chmod 755 "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/libexec"
cp "$BUILD/texpresso" "$BUILD/texpresso-xetex" "$STAGE/libexec/"
for file in "$STAGE"/libexec/*; do
  outside=$(otool -L "$file" | awk 'NR > 1 && $1 !~ "^(/usr/lib/|/System/|/opt/homebrew/)" { print $1 }')
  [ -z "$outside" ] || fail "$(basename "$file") links $outside, from neither the system nor Homebrew"
done

cat > "$STAGE/bin/texpresso" <<'EOF'
#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$(realpath -- "$0")")/.." && pwd)
export PATH="/Library/TeX/texbin:$PATH"
export XDG_CACHE_HOME="$ROOT/cache"
exec "$ROOT/libexec/texpresso" "$@"
EOF
chmod +x "$STAGE/bin/texpresso"

runs() {
  "$1" --help >"$STAGE/check.log" 2>&1 </dev/null || true
  grep -q "$2" "$STAGE/check.log" || fail "the staged $(basename "$1") does not run ($(head -c 300 "$STAGE/check.log")); $DEST is unchanged"
}
runs "$STAGE/bin/texpresso" "Usage: texpresso"
runs "$STAGE/libexec/texpresso-xetex" "Usage: "
rm "$STAGE/check.log"

KEEP=
if [ -d "$DEST/cache" ] && cmp -s "$DEST/libexec/texpresso-xetex" "$STAGE/libexec/texpresso-xetex"; then KEEP=1; fi

if [ -e "$DEST" ]; then OLD=$(mktemp -d "$DEST.old.XXXXXX"); mv "$DEST" "$OLD/previous"; fi
mv "$STAGE" "$DEST" || fail "could not move the installation into $DEST"
if [ -n "$KEEP" ]; then mv "$OLD/previous/cache" "$DEST/cache" || true; fi
if [ -n "${NO_LINK:-}" ]; then
  echo "Installed $DEST. Choose it in TeXLocal's Settings: /opt/homebrew/bin/texpresso is as it was."
else
  ln -sf "$DEST/bin/texpresso" /opt/homebrew/bin/texpresso
  echo "Installed $DEST; /opt/homebrew/bin/texpresso links to it. TeXLocal's Settings can stay on Automatic."
fi
