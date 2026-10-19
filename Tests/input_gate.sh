#!/bin/bash
# Checks the input permission on one Mac with a test client, no person needed:
# blocked at first, allowed after the menu bar toggle, blocked again after the next connection.
# The toggle is clicked by script, so the shell needs permission to control the Mac (Accessibility).
# Uses port 47801 and temporary key and layout files.
cd "$(dirname "$0")/.."
# The window checks need the screen awake: a sleeping display shows no windows to the scripts
caffeinate -u -t 3 &
caffeinate -d -w $$ &
S=./build/tbdisplay-server
LOG=$(mktemp -d)
export TBDISPLAY_LOG_DIR="$LOG/logs"      # the apps write their log files here, not into your real Library/Logs
export TBDISPLAY_KEY_FILE="$LOG/key/pairing-key"
export TBDISPLAY_LAYOUT_FILE="$LOG/layout.json"
PORT=47801
fails=0
# Throwaway preferences, with the first-run checklist already dismissed, so these checks never touch your real settings
PREFS_SUITE="tbdisplay.test.$$"
export TBDISPLAY_PREFS_SUITE="$PREFS_SUITE"
defaults write "$PREFS_SUITE" tbdisplay.firstRunDone -bool true
defaults write "$PREFS_SUITE" tbdisplay.updateCheckDisabled -bool true      # the tests never contact GitHub
trap 'defaults delete "$PREFS_SUITE" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$PREFS_SUITE.plist"' EXIT
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
skip() { echo "SKIP $1"; }

if pgrep -f "tbdisplay-(server|client)" >/dev/null; then echo "tbdisplay is already running. Stop it first."; exit 2; fi
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/Shared/Shared.swift Tests/probe/main.swift -o "$LOG/probe" 2>/dev/null || { echo "could not build the probe"; exit 2; }

$S --port $PORT --any-interface --bitrate 40 2> "$LOG/s" &
sleep 2
count() { grep -c -- "$1" "$LOG/s"; }
run_probe() { "$LOG/probe" $PORT | tail -1; sleep 4; }   # the pause lets the server finish closing the session

# 1. Blocked by default
[ "$(run_probe)" = "SENT" ] && [ "$(count 'Ignoring keyboard and mouse')" -ge 1 ] && pass "input is blocked until the user allows it" || fail "input was not blocked by default"

# 2. Allowed after the menu toggle (clicked by script)
osascript -e 'tell application "System Events" to tell process "tbdisplay-server" to click menu item "Allow iMac keyboard and mouse" of menu 1 of menu bar item 1 of menu bar 1' >"$LOG/osa" 2>&1
sleep 1
if [ "$(count 'are allowed')" -ge 1 ]; then
    pass "the menu toggle switches input on"
    before=$(count 'Ignoring keyboard and mouse')
    run_probe >/dev/null
    [ "$(count 'Ignoring keyboard and mouse')" -eq "$before" ] && pass "input is accepted while allowed" || fail "input still ignored after allowing"
    # 3. Permission lasts for one connection only
    run_probe >/dev/null
    [ "$(count 'Ignoring keyboard and mouse')" -gt "$before" ] && pass "permission switched off again after the connection ended" || fail "permission survived a reconnect"
else
    skip "could not click the menu item ($(head -c 120 "$LOG/osa")). Allow Accessibility for this shell to run steps 2 and 3"
fi

pkill -INT -f "$S"; sleep 3
pgrep -f "tbdisplay-(server|client)" >/dev/null && fail "processes left running" || pass "no processes left running"
echo "Logs in $LOG"
[ $fails -eq 0 ] && echo "Input gate checks finished without failures" || echo "$fails input gate check(s) failed"
exit $fails
