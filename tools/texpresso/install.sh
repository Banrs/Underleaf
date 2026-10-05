#!/bin/bash
# install.sh <build folder> [destination]
#
# Installs a TeXpresso built by build.sh where Underleaf finds it automatically: the
# programs and the libraries the build linked from outside Homebrew go in <destination>
# (default ~/Library/Application Support/TeXLocal/TeXpresso), pointed at each other
# relatively, and /opt/homebrew/bin/texpresso links to its launcher. Libraries from
# /opt/homebrew stay where they are.
set -euo pipefail
BUILD=$(CDPATH= cd -- "$1" && pwd)
DEST=${2:-"$HOME/Library/Application Support/TeXLocal/TeXpresso"}
rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/libexec" "$DEST/lib"
cp "$BUILD/texpresso" "$BUILD/texpresso-xetex" "$DEST/libexec/"

deps() { otool -L "$1" | tail -n +2 | sed 's/ (compat.*//; s/^[[:space:]]*//'; }
# A link into Homebrew's Cellar (the build's own deps/opt links) is used from Homebrew.
brewed() { case "$(realpath "$1")" in /opt/homebrew/Cellar/*) echo "$(realpath "$1" | sed -E 's|Cellar/([^/]+)/[^/]+/|opt/\1/|')" ;; *) return 1 ;; esac; }
external() { case "$1" in /usr/lib/* | /System/* | /opt/homebrew/* | @*) return 1 ;; esac; ! brewed "$1" >/dev/null; }

# Copy every library outside the system and Homebrew, following what each one links:
# by absolute path, or beside itself (@loader_path), as ICU does.
copy() { # copy <library> <real path>
  [ -e "$DEST/lib/$1" ] && return
  cp -L "$2" "$DEST/lib/$1"
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
chmod u+w "$DEST"/lib/* "$DEST"/libexec/*

for file in "$DEST"/libexec/* "$DEST"/lib/*; do
  args=()
  case "$file" in */libexec/*) to=@executable_path/../lib ;; *) to=@loader_path; args=(-id "@rpath/$(basename "$file")") ;; esac
  while read -r dep; do
    if external "$dep"; then args+=(-change "$dep" "$to/$(basename "$dep")")
    elif [ "${dep#/opt/homebrew/}" = "$dep" ] && brew=$(brewed "$dep" 2>/dev/null); then args+=(-change "$dep" "$brew"); fi
  done < <(deps "$file")
  for rpath in $(otool -l "$file" | awk '/LC_RPATH/ { getline; getline; print $2 }'); do
    args+=(-delete_rpath "$rpath")
  done
  [ ${#args[@]} -gt 0 ] && install_name_tool "${args[@]}" "$file" 2>/dev/null
  codesign --force --sign - "$file" 2>/dev/null
done

cat > "$DEST/bin/texpresso" <<'EOF'
#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$(realpath -- "$0")")/.." && pwd)
export PATH="/Library/TeX/texbin:$PATH"
export XDG_CACHE_HOME="$ROOT/cache"
exec "$ROOT/libexec/texpresso" "$@"
EOF
chmod +x "$DEST/bin/texpresso"
[ -n "${NO_LINK:-}" ] || ln -sf "$DEST/bin/texpresso" /opt/homebrew/bin/texpresso
echo "Installed $DEST; /opt/homebrew/bin/texpresso links to it. Underleaf's Settings can stay on Automatic."
