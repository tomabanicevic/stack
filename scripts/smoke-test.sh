#!/bin/bash
# Quick runtime check after a local build: opens Stack's settings and verifies it stays alive.
APP="/Applications/Stack.app"
pkill -f "$APP/Contents/MacOS/Stack" 2>/dev/null; sleep 0.5
open -n "$APP" --args --settings
sleep 4
if pgrep -f "$APP/Contents/MacOS/Stack" >/dev/null; then
  echo "SMOKE: Stack is running ✅"
else
  echo "SMOKE: Stack is NOT running ❌"
fi
# Dock state of the apps set to Hidden / Always hidden
CFG="$HOME/Library/Application Support/Stack/config.json"
/usr/bin/python3 - "$CFG" <<'PY' | while read -r id mode; do
import json, sys
config = json.load(open(sys.argv[1]))
for group in config.get("groups", []):
    for app in group.get("apps", []):
        if app.get("mode") in ("hidden", "alwaysHidden") and app.get("bundleID"):
            print(app["bundleID"], app["mode"])
PY
  echo "$id ($mode): $(/usr/bin/lsappinfo info -only ApplicationType -app "$id" 2>/dev/null | tr '\n' ' ')"
done
ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i '^Stack' | head -3
