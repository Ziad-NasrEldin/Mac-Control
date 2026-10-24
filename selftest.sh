#!/bin/zsh
# Installs the built app and runs one self-test: ./selftest.sh native
set -e
cd "$(dirname "$0")"
pkill -f "Voice Control.app/Contents/MacOS" || true; sleep 1
rm -rf "/Applications/Voice Control.app"; ditto VoiceControl.app "/Applications/Voice Control.app"
LOG=~/Library/Logs/VoiceControl.log
START=$(( $(wc -l < $LOG | tr -d " ") + 1 ))
for t in "$@"; do
  open -n "/Applications/Voice Control.app" --args --selftest $t
  for i in {1..120}; do tail -n +$START $LOG | grep -q "TEST end $t" && break; sleep 1; done
done
tail -n +$START $LOG | grep -E "TEST|ui scan|decided|error" | cut -c27-400
open "/Applications/Voice Control.app"
