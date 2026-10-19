#!/bin/bash
# Quiet Timer / 静音倒计时 uninstaller
# Quits the app, deletes it from ~/Applications and removes its saved settings.
# Tip: if you enabled "Launch at login" in the app's menu, turn it off there first.
#
# Usage:  bash uninstall.sh

set -u

DEST_DIR="$HOME/Applications"

pkill -x QuietTimer 2>/dev/null || true
rm -rf "$DEST_DIR/Quiet Timer.app" "$DEST_DIR/静音倒计时.app"
defaults delete local.quiettimer.en 2>/dev/null || true
defaults delete local.quiettimer.app 2>/dev/null || true

echo "Quiet Timer has been removed. / 静音倒计时已卸载。"
