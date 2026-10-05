#!/bin/bash
# install.sh <build folder> [destination]
#
# Installs a TeXpresso built by build.sh where Underleaf finds it automatically: the
# programs and the libraries the build linked from outside Homebrew go in <destination>
# (default ~/Library/Application Support/TeXLocal/TeXpresso), pointed at each other
# relatively, and /opt/homebrew/bin/texpresso links to its launcher. Libraries from
# /opt/homebrew stay where they are.
#
# The installation is prepared in a temporary folder beside the destination, checked by
# running its launcher, and only then swapped in: a failure leaves what was installed
# (and the /opt/homebrew/bin link) as it was.
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
trap 'rm -rf "$STAGE" ${OLD:+"$OLD"}' EXIT
chmod 755 "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/libexec" "$STAGE/lib"
cp "$BUILD/texpresso" "$BUILD/texpresso-xetex" "$STAGE/libexec/"

deps() { otool -L "$1" | tail -n +2 | sed 's/ (compat.*//; s/^[[:space:]]*//'; }
# A link into Homebrew's Cellar (the build's own deps/opt links) is used from Homebrew.
brewed() { case "$(realpath "$1")" in /opt/homebrew/Cellar/*) echo "$(realpath "$1" | sed -E 's|Cellar/([^/]+)/[^/]+/|opt/\1/|')" ;; *) return 1 ;; esac; }
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
  file=$(realpath "${todo[0]}"); todo=("${todo[@]:1}")
  while read -r dep; do
    case "$dep" in
      @loader_path/*) [ "${file#"$BUILD"}" = "$file" ] && copy "$(basename "$dep")" "$(dirname "$file")/${dep#@loader_path/}" ;;
      *) external "$dep" && copy "$(basename "$dep")" "$(realpath "$dep")" ;;
    esac
  done < <(deps "$file")
  # sdl2-compat opens SDL3 from its run paths when it starts.
  case "$file" in */libSDL2-2.0*.dylib)
    for rpath in $(otool -l "$file" | awk '/LC_RPATH/ { getline; getline; print $2 }'); do
      sdl3=${rpath/@loader_path/$(dirname "$file")}/libSDL3.dylib
      [ -e "$sdl3" ] && copy libSDL3.dylib "$(realpath "$sdl3")"
    done ;;
  esac
done
chmod u+w "$STAGE"/lib/* "$STAGE"/libexec/*

for file in "$STAGE"/libexec/* "$STAGE"/lib/*; do
  args=()
  case "$file" in */libexec/*) to=@executable_path/../lib ;; *) to=@loader_path; args=(-id "@rpath/$(basename "$file")") ;; esac
  while read -r dep; do
    if external "$dep"; then args+=(-change "$dep" "$to/$(basename "$dep")")
    elif [ "${dep#/opt/homebrew/}" = "$dep" ] && brew=$(brewed "$dep" 2>/dev/null); then args+=(-change "$dep" "$brew"); fi
  done < <(deps "$file")
  for rpath in $(otool -l "$file" | awk '/LC_RPATH/ { getline; getline; print $2 }'); do
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
{ sleep 10; kill "$pid" 2>/dev/null; } & watchdog=$!
wait "$pid" || true
{ kill "$watchdog"; wait "$watchdog"; } 2>/dev/null || true
grep -q "Usage: texpresso" "$STAGE/check.log" || fail "the staged texpresso does not run ($(head -c 300 "$STAGE/check.log")); $DEST is unchanged"
rm "$STAGE/check.log"

# Swap: the old installation steps aside, the new one moves in, and only then is the old removed.
if [ -e "$DEST" ]; then OLD=$(mktemp -d "$DEST.old.XXXXXX"); mv "$DEST" "$OLD/previous"; fi
mv "$STAGE" "$DEST" || { [ -z "$OLD" ] || mv "$OLD/previous" "$DEST"; fail "could not move the installation into $DEST"; }
[ -n "${NO_LINK:-}" ] || ln -sf "$DEST/bin/texpresso" /opt/homebrew/bin/texpresso
echo "Installed $DEST; /opt/homebrew/bin/texpresso links to it. Underleaf's Settings can stay on Automatic."
