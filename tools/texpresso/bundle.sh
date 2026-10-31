#!/bin/zsh
set -e
[[ $# == 2 && -n $2 ]] || { echo "usage: bundle.sh <TeXpresso build> <app>/Contents" >&2; exit 1 }
B=$1 H=$2/Helpers F=$2/Frameworks
fresh() { [[ $(stat -f %m $B/$1) == "$(stat -f %m $H/$1 2>/dev/null)" ]] }
fresh texpresso && fresh texpresso-xetex && exit 0
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
  codesign --force --sign - $into
}
for program in texpresso texpresso-xetex; do copy $H/$program $B/$program; done

outside=$(otool -L $H/* $F/* | awk '/^\t/ && $1 !~ "^(/usr/lib/|/System/|@loader_path/../Frameworks/)" { print $1 }')
[[ -z $outside ]] || { echo "bundle.sh: still links $outside" >&2; exit 1 }
$H/texpresso 2>&1 | grep -q "Usage: texpresso" || { echo "bundle.sh: the bundled texpresso doesn't run" >&2; exit 1 }
$H/texpresso-xetex 2>&1 | grep -q "Usage: " || { echo "bundle.sh: the bundled texpresso-xetex doesn't run" >&2; exit 1 }
touch -r $B/texpresso $H/texpresso; touch -r $B/texpresso-xetex $H/texpresso-xetex
