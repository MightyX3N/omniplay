#!/bin/sh
# Screenshots of every tab from the real app with simulated devices: tests/shots/out/*.png
set -e
cd "$(dirname "$0")/../.."
D=/tmp/omniplay-shots
rm -rf "$D" && mkdir -p "$D"
cp -r app/* "$D"/
mv "$D/main.lua" "$D/app_main.lua"
cp tests/shots/harness.lua "$D/main.lua"
SAVE="$HOME/.local/share/love/omniplay"
rm -f "$SAVE"/shot_*.png
timeout 60 xvfb-run -a -s "-screen 0 1280x800x24" love "$D" >/tmp/omniplay-shots.log 2>&1 || true
mkdir -p tests/shots/out
ls "$SAVE"/shot_*.png >/dev/null 2>&1 && cp "$SAVE"/shot_*.png tests/shots/out/
ls tests/shots/out
