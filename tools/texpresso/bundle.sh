#!/bin/zsh
set -e
[[ $# == 2 && -n $2 ]] || { echo "usage: bundle.sh <TeXpresso build> <app>/Contents" >&2; exit 1 }
B=$1 H=$2/Helpers F=$2/Frameworks
sources=$(sh ${0:A:h}/sources.sh)
[[ $sources == "$(<$B/sources.sha256)" ]] 2>/dev/null || {
  echo "bundle.sh: $B wasn't built from the current tools/texpresso sources; run tools/texpresso/build.sh" >&2; exit 1 }
identity=${EXPANDED_CODE_SIGN_IDENTITY:-"-"}
sign=(codesign --force --sign $identity)
[[ $identity == - ]] || sign+=(--options runtime --timestamp)
stamp=${DERIVED_FILE_DIR:+$DERIVED_FILE_DIR/texpresso-bundle.stamp}
state="$identity $(stat -f %m $B/texpresso $B/texpresso-xetex)"
[[ -n $stamp && -x $H/texpresso && -x $H/texpresso-xetex && $state == "$(<$stamp)" ]] 2>/dev/null && exit 0
[[ -z $stamp ]] || rm -f $stamp
rm -rf $H $F; mkdir -p $H $F

copy() {
  local into=$1 from=$2 link found
  cp $from $into; chmod u+w $into
  codesign --remove-signature $into
  [[ $into == $F/* ]] && install_name_tool -id @loader_path/../Frameworks/${into:t} $into
  for link in $(otool -L $from | awk -v self="$(otool -D $from | sed 1d)" 'NR > 1 && $1 != self && $1 !~ "^(/usr/lib/|/System/)" { print $1 }'); do
    if [[ ! -e $F/${link:t} ]]; then
      [[ $link == @* ]] && found=${from:h}/${link#*/} || found=$link
      [[ -f $found ]] || { echo "bundle.sh: ${from:t} links $link, which isn't there" >&2; exit 1 }
      copy $F/${link:t} ${found:A}
    fi
    install_name_tool -change $link @loader_path/../Frameworks/${link:t} $into
  done
  $sign $into
}
for program in texpresso texpresso-xetex; do copy $H/$program $B/$program; done

outside=$(otool -L $H/* $F/* | awk '/^\t/ && $1 !~ "^(/usr/lib/|/System/|@loader_path/../Frameworks/)" { print $1 }')
[[ -z $outside ]] || { echo "bundle.sh: still links $outside" >&2; exit 1 }
$H/texpresso 2>&1 | grep -q "Usage: texpresso" || { echo "bundle.sh: the bundled texpresso doesn't run" >&2; exit 1 }
$H/texpresso-xetex 2>&1 | grep -q "Usage: " || { echo "bundle.sh: the bundled texpresso-xetex doesn't run" >&2; exit 1 }
[[ -z $stamp ]] || { mkdir -p ${stamp:h}; print -r -- $state > $stamp }
