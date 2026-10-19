#!/bin/bash
# End-to-end check on one Mac: server and client talk over 127.0.0.1, encrypted with a pairing key.
# Usage: Tests/loopback.sh   (from anywhere). Opens a client window on this Mac for a few seconds.
# Everything runs on port 47801 with temporary key and layout files, so a client on another Mac,
# your real pairing key and your saved display position are left alone.
cd "$(dirname "$0")/.."
# The window checks need the screen awake: a sleeping display shows no windows to the scripts
caffeinate -u -t 3 &
caffeinate -d -w $$ &
S=./build/tbdisplay-server
C=./build/tbdisplay-client
PORT=47801
LOG=$(mktemp -d)
export TBDISPLAY_LOG_DIR="$LOG/logs"      # the apps write their log files here, not into your real Library/Logs
export TBDISPLAY_KEY_FILE="$LOG/good/pairing-key"
export TBDISPLAY_LAYOUT_FILE="$LOG/layout.json"
export TBDISPLAY_LOCKOUT_SECONDS=6
fails=0
# Throwaway preferences, with the first-run checklist already dismissed, so these checks never touch your real settings
PREFS_SUITE="tbdisplay.test.$$"
export TBDISPLAY_PREFS_SUITE="$PREFS_SUITE"
defaults write "$PREFS_SUITE" tbdisplay.firstRunDone -bool true
trap 'defaults delete "$PREFS_SUITE" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$PREFS_SUITE.plist"' EXIT

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
stop_all() { pkill -INT -f "$S" 2>/dev/null; pkill -TERM -f "$C" 2>/dev/null; sleep 2; }
wait_for() {   # file pattern seconds
    for _ in $(seq 1 $(( $3 * 2 ))); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.5; done
    return 1
}
wait_count() {   # file pattern wanted-count seconds: waits for that many matching lines, not just one
    for _ in $(seq 1 $(( $4 * 2 ))); do [ "$(grep -c -- "$2" "$1" 2>/dev/null)" -ge "$3" ] && return 0; sleep 0.5; done
    return 1
}
client() { $C --port $PORT --windowed --any-interface --host 127.0.0.1 "$@"; }

if pgrep -f "tbdisplay-(server|client)" >/dev/null; then echo "tbdisplay is already running. Stop it first."; exit 2; fi

# A wrong key: 32 random bytes as hex, never the server's
mkdir -p "$LOG/wrong"; head -c 32 /dev/urandom | xxd -p -c 64 > "$LOG/wrong/pairing-key"; chmod 600 "$LOG/wrong/pairing-key"

# Both apps must declare the pairing Bonjour service, or the iMac may not find the MacBook while pairing
for app in "TBDisplay Server" "TBDisplay Client"; do
    /usr/libexec/PlistBuddy -c 'Print :NSBonjourServices' "build/$app.app/Contents/Info.plist" 2>/dev/null | grep -q "_tbdisplay-pair._tcp" \
        && pass "$app declares the pairing service" || fail "$app does not declare the pairing service (run ./build.sh)"
done

# The version in each app's Info.plist (what Finder shows) must be the version in the code
VERSION=$(sed -n 's/^let appVersion = "\(.*\)".*/\1/p' Sources/Shared/Shared.swift)
for app in "TBDisplay Server" "TBDisplay Client"; do
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "build/$app.app/Contents/Info.plist" 2>/dev/null)" = "$VERSION" ] \
        && pass "$app shows version $VERSION in Finder" || fail "$app shows the wrong version in Finder (code says $VERSION)"
done

# 0. Old options are refused with a clear message
$S --port $PORT --pin 1234 2> "$LOG/s_old"; [ $? -ne 0 ] && grep -q "removed" "$LOG/s_old" && pass "--pin is refused with an explanation" || fail "--pin was accepted"

# 1. A client started before the server waits for the key and the server, then connects
client 2> "$LOG/c0" &
sleep 3
grep -q "No pairing key" "$LOG/c0" && pass "client without a key says so and waits" || fail "client did not report the missing key"
$S --port $PORT --any-interface --bitrate 40 2> "$LOG/s1" &
wait_for "$LOG/s1" "Client connected" 20 && pass "client connected once the key and server existed" || fail "client never connected"
grep -q "Created a new pairing key" "$LOG/s1" && pass "server created a pairing key on first run" || fail "server did not create a key"
[ "$(stat -f %Lp "$TBDISPLAY_KEY_FILE")" = "600" ] && pass "key file is owner-only (0600)" || fail "key file permissions are loose"
grep -q "ChaCha20-Poly1305" "$LOG/s1" && pass "connection is encrypted (ECDHE-PSK ChaCha20-Poly1305)" || fail "no encryption reported"
wait_for "$LOG/s1" "Streaming" 25 && pass "server streams" || fail "server did not reach Streaming"
grep -q "look like" "$LOG/s1" && pass "HiDPI mode selected" || fail "no HiDPI mode line"
[ -s "$LOG/logs/server.log" ] && grep -q "Streaming" "$LOG/logs/server.log" && pass "the server writes its log to a file" || fail "the server wrote no log file"
[ -s "$LOG/logs/client.log" ] && pass "the client writes its log to a file" || fail "the client wrote no log file"
[ "$(stat -f %Lp "$LOG/logs/server.log" 2>/dev/null)" = "600" ] && pass "the log file is owner-only (0600)" || fail "the log file permissions are loose"
sleep 7
grep -q "No data from the MacBook" "$LOG/c0" && fail "client lost the heartbeat" || pass "client kept receiving heartbeats for 7 s"
pkill -TERM -f "$C"; sleep 2
[ -f "$LOG/layout.json" ] && grep -q "Saved display position" "$LOG/s1" && pass "display position saved on disconnect" || fail "display position not saved"
echo '{"dx":-700,"dy":-1500}' > "$LOG/layout.json"
client 2> "$LOG/c1" &
wait_for "$LOG/s1" "(saved position)" 20 && pass "saved display position restored" || fail "saved display position not restored"
pkill -TERM -f "$C"; sleep 1

# 2. A wrong key never connects
TBDISPLAY_KEY_FILE="$LOG/wrong/pairing-key" client 2> "$LOG/c2" &
wait_for "$LOG/s1" "Handshake failed" 12 && pass "wrong key refused at the handshake" || fail "wrong key not refused"
pkill -TERM -f "$C"; sleep 1

# 3. Plain, unencrypted bytes are refused
before=$(grep -c "Handshake failed" "$LOG/s1")
printf 'hello' | nc -w 2 127.0.0.1 $PORT >/dev/null 2>&1
sleep 2
after=$(grep -c "Handshake failed" "$LOG/s1")
[ "$after" -gt "$before" ] && pass "plain TCP without TLS refused" || fail "plain TCP was not refused"

# 3b. A connection that stays silent is cut off by the handshake timeout
( sleep 8 ) | nc -w 10 127.0.0.1 $PORT >/dev/null 2>&1 &
wait_for "$LOG/s1" "timed out" 9 && pass "a silent connection is cut off after the handshake timeout" || fail "silent connection was not cut off"

# 4. A fresh server, so the failure count starts at zero. A real client is not kicked off by
# failed attempts, and repeated failures start a lockout that later ends.
stop_all
$S --port $PORT --any-interface --bitrate 40 2> "$LOG/s3" &
sleep 2
client 2> "$LOG/c3" &
wait_count "$LOG/s3" "Streaming" 1 25 >/dev/null
for _ in 1 2 3 4 5; do printf 'junk' | nc -w 1 127.0.0.1 $PORT >/dev/null 2>&1; done
sleep 2
grep -q "Too many failed attempts" "$LOG/s3" && pass "repeated failures start a lockout" || fail "no lockout after repeated failures"
[ "$(grep -c "New client replacing" "$LOG/s3")" -eq 0 ] && pass "failed attempts never replaced the live session" || fail "a failed attempt replaced the live session"
pkill -TERM -f "$C"; sleep 1
client 2> "$LOG/c4" &
sleep 3
[ "$(grep -c "Streaming" "$LOG/s3")" -eq 1 ] && pass "the right key is refused during the lockout" || fail "lockout did not block the right key"
wait_count "$LOG/s3" "Streaming" 2 30 && pass "the right key works again after the lockout" || fail "lockout never ended"
pkill -TERM -f "$C"; stop_all

# 4b. Silent connections cannot use the server up: only 8 may be pending at once
$S --port $PORT --any-interface --bitrate 40 2> "$LOG/s4" &
sleep 2
for _ in 1 2 3 4 5 6 7 8 9 10; do ( ( sleep 4 ) | nc -w 5 127.0.0.1 $PORT >/dev/null 2>&1 & ); done
wait_for "$LOG/s4" "Too many unauthenticated" 5 && pass "more than 8 silent connections are refused" || fail "no cap on silent connections"
sleep 6; stop_all

# 5. Only the bridge interface is allowed by default
$S --port $PORT 2> "$LOG/s2" &
sleep 1
client 2> "$LOG/c5" &
wait_for "$LOG/s2" "Rejected" 10 && pass "loopback refused without --any-interface" || fail "interface limit not enforced"
pkill -TERM -f "$C"; stop_all

# 5b. A client with a different version is told which Mac to update
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/Shared/Shared.swift Tests/probe/main.swift -o "$LOG/probe" 2>/dev/null
$S --port $PORT --any-interface 2> "$LOG/s5" &
sleep 2
notice=$("$LOG/probe" $PORT oldhello | tail -1)
echo "$notice" | grep -q "Update TBDisplay on the iMac" && pass "an older client gets a notice saying to update the iMac" || fail "no update notice (got: ${notice:0:90})"
grep -q "1.6.0" "$LOG/s5" && pass "the server log names the client's version" || fail "the client version is not logged"
stop_all

# 5c. Ctrl-C on the server removes the virtual display and the windows return to this Mac (written after the code, so a weaker test)
displays() { system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution"; }
before=$(displays)
$S --port $PORT --any-interface --bitrate 40 2> "$LOG/s6" &
client 2> "$LOG/c6" &
wait_for "$LOG/s6" "Streaming" 25 && pass "server streams for the Ctrl-C check" || fail "server did not stream for the Ctrl-C check"
during=$(displays)
[ "$during" -gt "$before" ] && pass "a virtual display exists while streaming ($before then $during)" || fail "no virtual display appeared ($before then $during)"
pkill -INT -f "$S"
gone=no; for i in $(seq 1 20); do [ "$(displays)" -le "$before" ] && { gone=yes; break; }; sleep 1; done
[ "$gone" = yes ] && pass "Ctrl-C removed the virtual display" || fail "the virtual display was still there 20 s after Ctrl-C"
stop_all

# 6. Nothing left running
pgrep -f "tbdisplay-(server|client)" >/dev/null && fail "processes left running" || pass "no processes left running"

echo "Logs in $LOG"
[ $fails -eq 0 ] && echo "All loopback checks passed" || echo "$fails loopback check(s) failed"
exit $fails
