#!/bin/zsh
# Installs the built app and runs one self-test: ./selftest.sh native
set -e
cd "$(dirname "$0")"
pkill -f "Mac Control.app/Contents/MacOS" || true; sleep 1
rm -rf "/Applications/Mac Control.app"; ditto MacControl.app "/Applications/Mac Control.app"
LOG=~/Library/Logs/MacControl.log
START=$(( $(wc -l < $LOG | tr -d " ") + 1 ))
for t in "$@"; do
  open -n "/Applications/Mac Control.app" --args --selftest $t
  for i in {1..120}; do tail -n +$START $LOG | grep -q "TEST end $t" && break; sleep 1; done
done
tail -n +$START $LOG | grep -E "TEST|ui scan|decided|error" | cut -c27-400
open "/Applications/Mac Control.app"
