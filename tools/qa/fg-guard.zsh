# Sourced by the foreground scripts. Runs only while the Mac's owner is away: the Mac idle for five minutes, or no input since
# this session's own last synthetic event (which resets the idle counter), itself made while they were away. It also
# takes the test host's turn (xctest.sh): a test run brings its own app forward and takes the keyboard from the
# QA window, so the two never run together.
idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
last=$(cat $S/qa/last-fg 2>/dev/null || echo 0); now=$(date +%s)
if (( idle > 300 )) || (( last > 0 && now - last < 3600 && idle >= now - last - 3 )); then :; else echo "not idle ($idle s, own last event $(( now - last )) s ago): skipped"; exit 3; fi
mkdir -p $S/locks
while ! mkdir $S/locks/xctest 2>/dev/null; do
  if [[ -n $(find $S/locks/xctest -maxdepth 0 -mmin +25 2>/dev/null) ]]; then rmdir $S/locks/xctest 2>/dev/null; else sleep 3; fi
done
fg_done() { date +%s > $S/qa/last-fg; rmdir $S/locks/xctest 2>/dev/null }
# Also when the script fails, which would otherwise hold the test host's turn for 25 minutes.
trap fg_done EXIT
