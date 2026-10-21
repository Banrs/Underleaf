#!/bin/zsh
# cmp-shots.sh <name>: captures for a before/after comparison, in the background, of the build QA_APP names. Each
# launch starts from the seed library and empty QA defaults, so two runs of one build differ only by noise.
S=${QA_SCRATCH:?export QA_SCRATCH=<scratchpad>, set up by tools/qa/setup.sh}
APP=${QA_APP:?QA_APP}
export QA_BG=1
# A locked screen hides every window from Accessibility and screencapture.
$S/qa/locked | grep -q "locked: 1" && { echo "screen locked: not captured"; exit 4 }
Q=($S/qa/qa --app $APP)
O=$S/shots/$1
mkdir -p $O
trap '$Q quit >/dev/null 2>&1' EXIT
shot() { $Q shot $O/$1.png >/dev/null 2>&1 || echo "shot failed: $1" }
fresh() {
  $Q quit >/dev/null 2>&1
  sleep 0.7
  defaults delete com.texlocal.mac.qa >/dev/null 2>&1
  rsync -a --delete $S/qa-library-seed/ $S/qa-library/
}
for mode in light dark; do
  fresh
  $Q launch --$mode -- -openProject "Test Errors and Warnings" \
    -sidebarVisible YES -inspectorVisible NO -showPDF YES >/dev/null
  sleep 6
  $Q resize 1400 820 >/dev/null; sleep 1
  shot workspace-1400-$mode
  $Q press "Inspector" >/dev/null 2>&1; sleep 1
  shot inspector-$mode
  $Q press "Inspector" >/dev/null 2>&1; sleep 0.8
  if [[ $mode == light ]]; then
    for w in 1000 800 620; do
      $Q resize $w 820 >/dev/null; sleep 0.8
      shot workspace-$w-$mode
      $Q toolbar > $O/toolbar-$w-$mode.json 2>/dev/null
    done
    $Q resize 1400 820 >/dev/null; sleep 0.8
  fi
  $Q press "Build Panel" >/dev/null 2>&1; sleep 1.2
  shot buildpanel-$mode
  [[ $mode == light ]] && $Q tree --depth 14 --help-tags > $O/tree-workspace.txt 2>/dev/null
  $Q press "Back" --role AXButton >/dev/null 2>&1; sleep 1.5
  shot home-$mode
  [[ $mode == light ]] && $Q tree --depth 12 --help-tags > $O/tree-home.txt 2>/dev/null
done
exit 0
