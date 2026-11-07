#!/bin/bash
# Opens the "Check connection" window from the MacBook menu item and from the iMac button, and reads what it says.
# Uses temporary key files and a closed port, so nothing real is touched. Needs Accessibility for the shell.
cd "$(dirname "$0")/.."
# The window checks need the screen awake: a sleeping display shows no windows to the scripts
caffeinate -u -t 3 &
caffeinate -d -w $$ &
S=./build/tbdisplay-server
C=./build/tbdisplay-client
LOG=$(mktemp -d)
export TBDISPLAY_LOG_DIR="$LOG/logs"      # the apps write their log files here, not into your real Library/Logs
export TBDISPLAY_LAYOUT_FILE="$LOG/layout.json"
fails=0
# Throwaway preferences, with the first-run checklist already dismissed, so these checks never touch your real settings
PREFS_SUITE="tbdisplay.test.$$"
export TBDISPLAY_PREFS_SUITE="$PREFS_SUITE"
defaults write "$PREFS_SUITE" tbdisplay.firstRunDone -bool true
defaults write "$PREFS_SUITE" tbdisplay.updateCheckDisabled -bool true      # the tests never contact GitHub
trap 'defaults delete "$PREFS_SUITE" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$PREFS_SUITE.plist"' EXIT
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
ax() { osascript -e "tell application \"System Events\" to tell process \"$1\" to $2" 2>&1; }
. "$(dirname "$0")/ui_edges.sh"
window_text() { ax "$1" 'get value of text area 1 of scroll area 1 of window "Connection check"'; }
wait_report() {   # process seconds
    for _ in $(seq 1 $(( $2 * 2 ))); do
        t=$(window_text "$1")
        echo "$t" | grep -q "TBDisplay" && echo "$t" | grep -q "Thunderbolt" && return 0
        sleep 0.5
    done
    return 1
}

if pgrep -f "tbdisplay-(server|client)" >/dev/null; then echo "tbdisplay is already running. Stop it first."; exit 2; fi

TBDISPLAY_KEY_FILE="$LOG/skey/k" $S --port 47801 --any-interface 2> "$LOG/s" &
TBDISPLAY_KEY_FILE="$LOG/ckey/k" $C --any-interface --host 127.0.0.1 --port 47899 2> "$LOG/c" &
sleep 4

ax tbdisplay-server 'click menu item "Check connection…" of menu 1 of menu bar item 1 of menu bar 1' >/dev/null
wait_report tbdisplay-server 40 && pass "the MacBook shows a connection report" || fail "no report on the MacBook (got: $(window_text tbdisplay-server | head -c 100))"
t=$(window_text tbdisplay-server)
echo "$t" | grep -qE "TBDisplay [0-9]+\.[0-9]+\.[0-9]+ \(protocol [0-9]+\)" && pass "the report names the versions" || fail "no versions in the report"
echo "$t" | grep -qE "^(Problem found|Everything looks right|Nothing wrong found|Nothing to report)" && pass "the report starts with a verdict" || fail "no verdict line"
check_inside tbdisplay-server "Connection check"
buttons=$(ax tbdisplay-server 'get name of every button of window "Connection check"')
for b in "Copy" "Check again" "Close"; do echo "$buttons" | grep -q "$b" && pass "the MacBook window has: $b" || fail "the MacBook window lacks: $b"; done

ax tbdisplay-client 'click button "Check connection…" of window "TBDisplay"' >/dev/null
wait_report tbdisplay-client 40 && pass "the iMac shows a connection report" || fail "no report on the iMac (got: $(window_text tbdisplay-client | head -c 100))"

pkill -TERM -f "$C"; pkill -INT -f "$S"; sleep 4
pgrep -f "tbdisplay-(server|client)" >/dev/null && fail "processes left running" || pass "no processes left running"
echo "Logs in $LOG"
[ $fails -eq 0 ] && echo "Connection check UI passed" || echo "$fails connection check UI check(s) failed"
exit $fails
