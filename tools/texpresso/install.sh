#!/bin/bash
# install.sh <build folder> [destination]: installs a TeXpresso built by build.sh where Underleaf finds it. The
# programs and the libraries linked from outside Homebrew go in <destination> (default ~/Library/Application
# Support/TeXLocal/TeXpresso), pointed at each other relatively, and /opt/homebrew/bin/texpresso links to its launcher
# (not with NO_LINK=1, to try an installation beside the one in use).
#
# The installation is staged beside the destination, checked by running it, and only then swapped in: a failure or
# an interruption leaves what was installed, and the link, as it was. The launcher keeps TeXpresso's cache (the TeX
# formats, five seconds to make) inside the installation; it moves to the new one when texpresso-xetex is the same.
set -euo pipefail
fail() { echo "install.sh: $*" >&2; exit 1; }
BUILD=$(CDPATH= cd -- "${1:?usage: install.sh <build folder> [destination]}" && pwd)
DEST=${2:-"$HOME/Library/Application Support/TeXLocal/TeXpresso"}
DEST=${DEST%/}
for file in texpresso texpresso-xetex; do
  [ -f "$BUILD/$file" ] || fail "$BUILD has no $file; build it with build.sh first"
done
# Only an earlier installation (or an empty folder) is replaced, never a folder of someone's files.
if [ -e "$DEST" ] && [ ! -x "$DEST/bin/texpresso" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  fail "$DEST exists and is not a TeXpresso installation"
fi
mkdir -p "$(dirname "$DEST")"
STAGE=$(mktemp -d "$DEST.new.XXXXXX")
OLD=
# On any exit, an installation stepped aside but not yet replaced is put back first.
cleanup() {
  if [ -n "$OLD" ] && [ -e "$OLD/previous" ] && [ ! -e "$DEST" ]; then mv "$OLD/previous" "$DEST"; fi
  rm -rf "$STAGE" ${OLD:+"$OLD"}
}
trap cleanup EXIT
shopt -s nullglob # lib/ stays empty when every library comes from Homebrew
chmod 755 "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/libexec" "$STAGE/lib"
cp "$BUILD/texpresso" "$BUILD/texpresso-xetex" "$STAGE/libexec/"

deps() { otool -L "$1" | tail -n +2 | sed 's/ (compat.*//; s/^[[:space:]]*//'; }
# A link into Homebrew's Cellar (the build's own deps/opt links) is used from Homebrew.
brewed() {
  case "$(realpath "$1")" in
    /opt/homebrew/Cellar/*) realpath "$1" | sed -E 's|Cellar/([^/]+)/[^/]+/|opt/\1/|' ;;
    *) return 1 ;;
  esac
}
rpaths() { otool -l "$1" | awk '/LC_RPATH/ { getline; getline; print $2 }'; }
external() { case "$1" in /usr/lib/* | /System/* | /opt/homebrew/* | @*) return 1 ;; esac; ! brewed "$1" >/dev/null; }

# Copy every library outside the system and Homebrew, following what each one links:
# by absolute path, or beside itself (@loader_path), as ICU does.
copy() { # copy <library> <real path>
  [ -e "$STAGE/lib/$1" ] && return
  cp -L "$2" "$STAGE/lib/$1"
  todo+=("$2")
}
todo=("$BUILD/texpresso" "$BUILD/texpresso-xetex")
while [ ${#todo[@]} -gt 0 ]; do
  file=$(realpath "${todo[0]}")
  todo=("${todo[@]:1}")
  while read -r dep; do
    case "$dep" in
      @loader_path/*)
        [ "${file#"$BUILD"}" = "$file" ] && copy "$(basename "$dep")" "$(dirname "$file")/${dep#@loader_path/}" ;;
      *) external "$dep" && copy "$(basename "$dep")" "$(realpath "$dep")" ;;
    esac
  done < <(deps "$file")
  # sdl2-compat opens SDL3 from its run paths when it starts.
  case "$file" in */libSDL2-2.0*.dylib)
    for rpath in $(rpaths "$file"); do
      sdl3=${rpath/@loader_path/$(dirname "$file")}/libSDL3.dylib
      [ -e "$sdl3" ] && copy libSDL3.dylib "$(realpath "$sdl3")"
    done ;;
  esac
done
chmod u+w "$STAGE"/lib/* "$STAGE"/libexec/*

for file in "$STAGE"/libexec/* "$STAGE"/lib/*; do
  args=()
  case "$file" in
    */libexec/*) to=@executable_path/../lib ;;
    *) to=@loader_path; args=(-id "@rpath/$(basename "$file")") ;;
  esac
  while read -r dep; do
    if external "$dep"; then
      args+=(-change "$dep" "$to/$(basename "$dep")")
    elif [ "${dep#/opt/homebrew/}" = "$dep" ] && brew=$(brewed "$dep" 2>/dev/null); then
      args+=(-change "$dep" "$brew")
    fi
  done < <(deps "$file")
  for rpath in $(rpaths "$file"); do
    args+=(-delete_rpath "$rpath")
  done
  if [ ${#args[@]} -gt 0 ]; then install_name_tool "${args[@]}" "$file" 2>/dev/null; fi
  codesign --force --sign - "$file" 2>/dev/null
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

# Loading the libraries is the check: texpresso prints its usage for an unknown option.
# It is given ten seconds, as a broken library can make it hang instead of fail.
"$STAGE/bin/texpresso" --help >"$STAGE/check.log" 2>&1 </dev/null & pid=$!
{ sleep 10; kill "$pid"; } >/dev/null 2>&1 & watchdog=$!
wait "$pid" || true
{ kill "$watchdog"; wait "$watchdog"; } 2>/dev/null || true
unchanged() { echo "($(head -c 300 "$STAGE/check.log")); $DEST is unchanged"; }
grep -q "Usage: texpresso" "$STAGE/check.log" || fail "the staged texpresso does not run $(unchanged)"
# And texpresso-xetex's, which the launcher only starts for a document: a build folder put
# together by hand can have it without the libraries it was linked to.
"$STAGE/libexec/texpresso-xetex" --help >"$STAGE/check.log" 2>&1 </dev/null || true
grep -q "Usage: " "$STAGE/check.log" || fail "the staged texpresso-xetex does not run $(unchanged)"
rm "$STAGE/check.log"

KEEP=
if [ -d "$DEST/cache" ] && cmp -s "$DEST/libexec/texpresso-xetex" "$STAGE/libexec/texpresso-xetex"; then KEEP=1; fi

# Swap: the old installation steps aside, the new one moves in, and only then is the old removed.
if [ -e "$DEST" ]; then OLD=$(mktemp -d "$DEST.old.XXXXXX"); mv "$DEST" "$OLD/previous"; fi
mv "$STAGE" "$DEST" || fail "could not move the installation into $DEST"
if [ -n "$KEEP" ]; then mv "$OLD/previous/cache" "$DEST/cache" || true; fi
if [ -n "${NO_LINK:-}" ]; then
  echo "Installed $DEST. Choose it in Underleaf's Settings: /opt/homebrew/bin/texpresso is as it was."
else
  ln -sf "$DEST/bin/texpresso" /opt/homebrew/bin/texpresso
  echo "Installed $DEST; /opt/homebrew/bin/texpresso links to it. Underleaf's Settings can stay on Automatic."
fi
