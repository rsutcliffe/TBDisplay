#!/bin/bash
# The first-run checklist, read through the real windows. Uses a throwaway preferences suite, temporary key files
# and a closed port, so nothing real is touched. Needs Accessibility for the shell.
cd "$(dirname "$0")/.."
# The window checks need the screen awake: a sleeping display shows no windows to the scripts
caffeinate -u -t 3 &
caffeinate -d -w $$ &
S=./build/tbdisplay-server
C=./build/tbdisplay-client
LOG=$(mktemp -d)
export TBDISPLAY_LOG_DIR="$LOG/logs"      # the apps write their log files here, not into your real Library/Logs
SUITE="tbdisplay.test.$$"
export TBDISPLAY_PREFS_SUITE="$SUITE" TBDISPLAY_LAYOUT_FILE="$LOG/layout.json"
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
ax() { osascript -e "tell application \"System Events\" to tell process \"$1\" to $2" 2>&1; }
texts() { ax "$1" 'get value of every static text of window "Setup checklist"'; }
wait_for() {   # process pattern seconds
    for _ in $(seq 1 $(( $3 * 2 ))); do texts "$1" | grep -q -- "$2" && return 0; sleep 0.5; done
    return 1
}
cleanup() { defaults delete "$SUITE" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$SUITE.plist"; }

if pgrep -f "tbdisplay-(server|client)" >/dev/null; then echo "tbdisplay is already running. Stop it first."; exit 2; fi

# The MacBook, first launch: the checklist opens by itself
TBDISPLAY_KEY_FILE="$LOG/skey/k" $S --port 47801 --any-interface 2> "$LOG/s" &
wait_for tbdisplay-server "Allow Screen Recording" 20 && pass "the MacBook opens the checklist on first launch" || fail "no checklist on the MacBook (got: $(texts tbdisplay-server | head -c 100))"
t=$(texts tbdisplay-server)
for item in "Pair your iMac" "Connect the cable" "Local Network"; do echo "$t" | grep -q "$item" && pass "the MacBook checklist lists: $item" || fail "the MacBook checklist lacks: $item"; done
buttons=$(ax tbdisplay-server 'get name of every button of window "Setup checklist"')
echo "$buttons" | grep -q "Pair a new Mac…" && pass "there is a button to pair" || fail "no pairing button (got: $buttons)"
echo "$buttons" | grep -q "Close" && pass "there is a Close button" || fail "no Close button"
ax tbdisplay-server 'click button "Close" of window "Setup checklist"' >/dev/null
sleep 1
[ "$(ax tbdisplay-server 'get exists window "Setup checklist"')" = "false" ] && pass "Close closes it" || fail "the checklist did not close"
# It can be opened again from the menu
ax tbdisplay-server 'click menu item "Setup checklist…" of menu 1 of menu bar item 1 of menu bar 1' >/dev/null
wait_for tbdisplay-server "Allow Screen Recording" 5 && pass "the menu item reopens the checklist" || fail "the menu item did not reopen it"
pkill -INT -f "$S"; sleep 4

# The iMac, first launch
TBDISPLAY_KEY_FILE="$LOG/ckey/k" $C --any-interface --host 127.0.0.1 --port 47899 2> "$LOG/c" &
wait_for tbdisplay-client "Pair this iMac with your MacBook" 20 && pass "the iMac opens the checklist on first launch" || fail "no checklist on the iMac (got: $(texts tbdisplay-client | head -c 100))"
buttons=$(ax tbdisplay-client 'get name of every button of window "Setup checklist"')
echo "$buttons" | grep -q "Pair with MacBook…" && pass "the iMac checklist has the pairing button" || fail "no iMac pairing button (got: $buttons)"
pkill -TERM -f "$C"; sleep 2

cleanup
pgrep -f "tbdisplay-(server|client)" >/dev/null && fail "processes left running" || pass "no processes left running"
echo "Logs in $LOG"
[ $fails -eq 0 ] && echo "Checklist UI passed" || echo "$fails checklist UI check(s) failed"
exit $fails
