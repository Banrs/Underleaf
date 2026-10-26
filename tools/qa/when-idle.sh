#!/bin/zsh
S=${QA_SCRATCH:?export QA_SCRATCH=<scratchpad>, set up by tools/qa/setup.sh}
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}' }
end=$(( $(date +%s) + ${2:-120} * 60 ))
until (( $(idle) > ${3:-610} )); do
  (( $(date +%s) > end )) && { echo "never idle: not run"; exit 3 }
  sleep 20
done
echo "idle at $(date +%H:%M): running $1"
"$S/qa/qa" lock -- zsh ${1:A}
