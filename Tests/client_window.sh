#!/bin/bash
# Checks the iMac client's setup window by reading it through System Events (needs Accessibility for the shell).
# Runs on one Mac with a temporary key folder, so nothing real is touched.
cd "$(dirname "$0")/.."
# The window checks need the screen awake: a sleeping display shows no windows to the scripts
caffeinate -u -t 3 &
caffeinate -d -w $$ &
C=./build/tbdisplay-client
LOG=$(mktemp -d)
export TBDISPLAY_LOG_DIR="$LOG/logs"      # the apps write their log files here, not into your real Library/Logs
export TBDISPLAY_KEY_FILE="$LOG/none/pairing-key"      # no key on purpose
fails=0
# Throwaway preferences, with the first-run checklist already dismissed, so these checks never touch your real settings
PREFS_SUITE="tbdisplay.test.$$"
export TBDISPLAY_PREFS_SUITE="$PREFS_SUITE"
defaults write "$PREFS_SUITE" tbdisplay.firstRunDone -bool true
defaults write "$PREFS_SUITE" tbdisplay.updateCheckDisabled -bool true      # the tests never contact GitHub
trap 'defaults delete "$PREFS_SUITE" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$PREFS_SUITE.plist"' EXIT
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
ax() { osascript -e "tell application \"System Events\" to tell process \"tbdisplay-client\" to $1" 2>&1; }
. "$(dirname "$0")/ui_edges.sh"

if pgrep -f "tbdisplay-client" >/dev/null; then echo "tbdisplay-client is already running. Stop it first."; exit 2; fi

$C --any-interface --host 127.0.0.1 --port 47801 2> "$LOG/c" &
PID=$!
sleep 4

[ "$(ax 'get exists window "TBDisplay"')" = "true" ] && pass "the setup window is shown and titled TBDisplay" || fail "no window titled TBDisplay"
texts=$(ax 'get value of every static text of window "TBDisplay"')
echo "$texts" | grep -q "No pairing key" && pass "the window says there is no pairing key" || fail "no 'No pairing key' text (got: ${texts:0:100})"
echo "$texts" | grep -qE "Version [0-9]+\.[0-9]+" && pass "the window shows the app version" || fail "no version shown"
buttons=$(ax 'get name of every button of window "TBDisplay"')
for b in "Pair with MacBook…" "Check connection…" "Show log" "Quit"; do
    echo "$buttons" | grep -q "$b" && pass "button: $b" || fail "missing button: $b (got: $buttons)"
done
# Every button must sit inside the window with a margin, not touch or pass its right edge
read -r wx wy < <(ax 'get position of window "TBDisplay"' | tr -d ',' | tr -s ' ')
read -r ww wh < <(ax 'get size of window "TBDisplay"' | tr -d ',' | tr -s ' ')
for b in "Pair with MacBook…" "Check connection…" "Show log" "Quit"; do
    read -r bx by < <(ax "get position of button \"$b\" of window \"TBDisplay\"" | tr -d ',' | tr -s ' ')
    read -r bw bh < <(ax "get size of button \"$b\" of window \"TBDisplay\"" | tr -d ',' | tr -s ' ')
    margin=$(( (wx + ww) - (bx + bw) ))
    [ "$margin" -ge 16 ] && [ "$bx" -ge $((wx + 16)) ] && pass "button \"$b\" sits inside the window (right margin ${margin} pt)" || fail "button \"$b\" touches or passes the window edge (right margin ${margin} pt, window ${wx}..$((wx + ww)))"
done
echo "$buttons" | grep -q "Check for updates…" && fail "the Check for updates button is still there" || pass "there is no Check for updates button (the link appears only when a release is newer)"
popup=$(ax 'get value of every pop up button of window "TBDisplay"')
echo "$popup" | grep -q "Thunderbolt" && pass "the Connect over pop-up shows Thunderbolt by default" || fail "no Connect over pop-up showing Thunderbolt (got: $popup)"
echo "$texts" | grep -q "Connect over" && pass "the Connect over label is shown" || fail "no Connect over label"
boxes=$(ax 'get name of every checkbox of window "TBDisplay"')
check_inside tbdisplay-client "TBDisplay"
echo "$boxes" | grep -q "Open at login" && pass "the Open at login checkbox is shown" || fail "no Open at login checkbox (got: $boxes)"
echo "$boxes" | grep -q "Check for updates automatically" && pass "the automatic update checkbox is shown" || fail "no automatic update checkbox (got: $boxes)"
ax 'click button "Quit" of window "TBDisplay"' >/dev/null
sleep 2
kill -0 $PID 2>/dev/null && fail "the Quit button did not quit" || pass "the Quit button quits the client"
kill $PID 2>/dev/null

# With a key but no MacBook, the window starts giving advice about the cable after 15 seconds
mkdir -p "$LOG/withkey"; head -c 32 /dev/urandom | xxd -p -c 64 > "$LOG/withkey/pairing-key"; chmod 600 "$LOG/withkey/pairing-key"
TBDISPLAY_KEY_FILE="$LOG/withkey/pairing-key" $C --any-interface --host 127.0.0.1 --port 47801 2> "$LOG/c2" &
PID=$!
sleep 6
texts=$(ax 'get value of every static text of window "TBDisplay"')
echo "$texts" | grep -q "Check the cable" && fail "the cable advice appeared too early (after 6 s)" || pass "no cable advice in the first seconds"
sleep 14
texts=$(ax 'get value of every static text of window "TBDisplay"')
echo "$texts" | grep -q "Check the cable is fully in at both ends" && pass "after 20 s with no MacBook the window gives cable advice" || fail "no cable advice after 20 s (got: ${texts:0:160})"
kill $PID 2>/dev/null
echo "Logs in $LOG"
[ $fails -eq 0 ] && echo "Client window checks passed" || echo "$fails client window check(s) failed"
exit $fails
