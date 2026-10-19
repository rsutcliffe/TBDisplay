#!/bin/bash
# Pairs a client with a server through the real windows on this Mac, driven by script (System Events).
# The server and client use separate temporary key files, so the pairing is a real one: the client starts with
# no key, ends with the server's key, and nothing real is touched. Needs Accessibility for the shell.
cd "$(dirname "$0")/.."
# The window checks need the screen awake: a sleeping display shows no windows to the scripts
caffeinate -u -t 3 &
caffeinate -d -w $$ &
S=./build/tbdisplay-server
C=./build/tbdisplay-client
LOG=$(mktemp -d)
export TBDISPLAY_LOG_DIR="$LOG/logs"      # the apps write their log files here, not into your real Library/Logs
export TBDISPLAY_LAYOUT_FILE="$LOG/layout.json"
SERVER_KEY="$LOG/server/pairing-key"
CLIENT_KEY="$LOG/client/pairing-key"
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
wait_text() {   # process window pattern seconds
    for _ in $(seq 1 $(( $4 * 2 ))); do
        t=$(ax "$1" "get value of every static text of window \"$2\"")
        echo "$t" | grep -qE -- "$3" && return 0
        sleep 0.5
    done
    return 1
}

if pgrep -f "tbdisplay-(server|client)" >/dev/null; then echo "tbdisplay is already running. Stop it first."; exit 2; fi

TBDISPLAY_KEY_FILE="$SERVER_KEY" TBDISPLAY_PAIR_PORT=47812 $S --port 47801 --any-interface 2> "$LOG/s" &
TBDISPLAY_KEY_FILE="$CLIENT_KEY" $C --any-interface --host 127.0.0.1 --port 47899 2> "$LOG/c" &   # nothing listens there, on purpose
sleep 4

# The MacBook opens its pairing panel from the menu bar item
ax tbdisplay-server 'click menu item "Pair a new Mac…" of menu 1 of menu bar item 1 of menu bar 1' >/dev/null
wait_text tbdisplay-server "Pair a new Mac" "Pair with MacBook" 6 && pass "the MacBook panel tells you what to press on the iMac" || fail "no MacBook pairing panel"
# Choosing it again while it is open must not leave a second listener behind or break the first
ax tbdisplay-server 'click menu item "Pair a new Mac…" of menu 1 of menu bar item 1 of menu bar 1' >/dev/null
sleep 1
wait_text tbdisplay-server "Pair a new Mac" "Pair with MacBook" 6 && pass "opening the pairing panel twice still works" || fail "the second opening broke the panel (got: $(ax tbdisplay-server 'get value of every static text of window "Pair a new Mac"' | head -c 120))"

# The iMac starts pairing from its window
wait_text tbdisplay-client "TBDisplay" "No pairing key" 6 && pass "the iMac window says it has no key" || fail "the iMac window did not show the missing key"
ax tbdisplay-client 'click button "Pair with MacBook…" of window "TBDisplay"' >/dev/null

wait_text tbdisplay-client "TBDisplay" "[0-9]{3} [0-9]{3}" 15 && pass "the iMac shows a code" || fail "the iMac never showed a code"
wait_text tbdisplay-server "Pair a new Mac" "[0-9]{3} [0-9]{3}" 15 && pass "the MacBook shows a code" || fail "the MacBook never showed a code"
imac=$(ax tbdisplay-client 'get value of every static text of window "TBDisplay"' | grep -oE "[0-9]{3} [0-9]{3}" | head -1)
mac=$(ax tbdisplay-server 'get value of every static text of window "Pair a new Mac"' | grep -oE "[0-9]{3} [0-9]{3}" | head -1)
[ -n "$imac" ] && [ "$imac" = "$mac" ] && pass "both screens show the same code ($imac)" || fail "the codes differ (iMac '$imac', MacBook '$mac')"
[ ! -f "$CLIENT_KEY" ] && pass "no key reaches the iMac before the person confirms" || fail "the key arrived before confirmation"

# The person confirms on the MacBook: the iMac must still wait for its own person
ax tbdisplay-server 'click button "Yes, it matches" of window "Pair a new Mac"' >/dev/null
wait_text tbdisplay-server "Pair a new Mac" "Paired" 10 && pass "the MacBook panel says it is paired" || fail "the MacBook never said paired"
sleep 1
[ ! -f "$CLIENT_KEY" ] && pass "the iMac stores nothing until its own person confirms" || fail "the iMac stored the key before its person said yes"
texts=$(ax tbdisplay-client 'get value of every static text of window "TBDisplay"')
echo "$texts" | grep -q "same code as on your MacBook" && pass "the iMac asks whether the codes match" || fail "the iMac did not ask (got: ${texts:0:100})"
# ... and now the iMac person confirms
ax tbdisplay-client 'click button "Yes, it matches" of window "TBDisplay"' >/dev/null
wait_text tbdisplay-client "TBDisplay" "Paired" 10 && pass "the iMac window says it is paired" || fail "the iMac never said paired"
cmp -s "$SERVER_KEY" "$CLIENT_KEY" && pass "the iMac holds exactly the MacBook's key" || fail "the keys differ or the iMac has none"
[ "$(stat -f %Lp "$CLIENT_KEY" 2>/dev/null)" = "600" ] && pass "the stored key is owner-only" || fail "the stored key is not private"

pkill -TERM -f "$C"; pkill -INT -f "$S"; sleep 4
pgrep -f "tbdisplay-(server|client)" >/dev/null && fail "processes left running" || pass "no processes left running"
echo "Logs in $LOG"
[ $fails -eq 0 ] && echo "Pairing UI checks passed" || echo "$fails pairing UI check(s) failed"
exit $fails
