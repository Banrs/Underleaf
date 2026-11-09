#!/bin/zsh
# Lists what this Mac still holds in the shapes builds before 2496 (October 31, 2026) wrote, which no build from
# 3011 on reads: a project's remembered place and shell-escape grant in its .texlocal.json, the opened folders and
# app settings in the library folder, and snapshot reasons written as sentences. Nothing printed means the Mac is
# clear. The first two kinds come back as you use the app; with --fix, run while TeXLocal is quit, the snapshot
# records are rewritten so those snapshots show in History again and the project's history prunes.
L=${TEXLOCAL_DATA:-$HOME/TeXLocal}; S=${TEXLOCAL_STATE:-$HOME/Library/Application Support/com.texlocal.mac}
for f in .opened .texlocal-app.json; do
  [[ -e $L/$f ]] && echo "library still holds $f: opened folders and app settings start afresh"
done
old='"(ui|shellEscapeFor)"'
for p in $L/*(/N); do
  grep -qsE $old $p/.texlocal.json && [[ ! -f $S/.ui/${p:t}.json ]] && echo "${p:t}: remembered place and grant start afresh"
done
for o in $S/.opened/*(/N); do
  r=$(plutil -extract path raw -o - $o/folder.json 2>/dev/null) || continue
  grep -qsE $old $r/.texlocal.json && [[ ! -f $o/project.json ]] && echo "${r:t}: remembered place and grant start afresh"
done
dirs=($L/*/.texlocal-history/snapshots(/N) $S/.opened/*/history/snapshots(/N))
(( $#dirs )) || exit 0
for rec in $(grep -rlsE '"reason":"Before ' $dirs); do
  if [[ $1 == --fix ]]; then
    sed -i '' 's/"reason":"Before Replace All"/"reason":"replaceAll"/;s/"reason":"Before Rename"/"reason":"rename"/;s/"reason":"Before Adding a Package"/"reason":"addPackage"/;s/"reason":"Before Restore"/"reason":"restore"/' $rec
    echo "$rec: reason rewritten"
  else
    echo "$rec: old snapshot reason, hidden from History until rewritten with --fix"
  fi
done
