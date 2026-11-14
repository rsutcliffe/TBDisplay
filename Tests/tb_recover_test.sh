#!/bin/bash
# Checks the pure parts of Scripts/tb-recover.sh against canned text. Nothing here touches the network or either Mac.
cd "$(dirname "$0")/.." || exit 2
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

[ -f Scripts/tb-recover.sh ] || { echo "FAIL Scripts/tb-recover.sh is missing"; exit 1; }
export TB_RECOVER_SOURCE_ONLY=1
# shellcheck source=/dev/null
source Scripts/tb-recover.sh

active=$'bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tmember: en2 flags=3<LEARNING,DISCOVER>\n\tstatus: active'
inactive=$'bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tmember: en2 flags=3<LEARNING,DISCOVER>\n\tstatus: inactive'
bridge_is_active "$active" && pass "an active bridge is recognised" || fail "an active bridge was not recognised"
bridge_is_active "$inactive" && fail "an inactive bridge was read as active" || pass "an inactive bridge is not read as active"
bridge_is_active "" && fail "empty text was read as active" || pass "empty text (Mac did not answer) is not read as active"

# system_profiler prints Link Status BEFORE Receptacle inside each port block
sp=$'Port:\n  Status: No device connected\n  Link Status: 0x100\n  Speed: Up to 40 Gb/s\n  Receptacle: 4\nPort:\n  Status: No device connected\n  Link Status: 0x7\n  Speed: Up to 40 Gb/s\n  Receptacle: 2\nPort:\n  Status: Device connected\n  Link Status: 0x2\n  Receptacle: 1'
[ "$(parse_links "$sp")" = "R1=0x2 R2=0x7 R4=0x100" ] && pass "link status is paired with its own receptacle" || fail "link status parsing gave: $(parse_links "$sp")"
[ -z "$(parse_links "")" ] && pass "no Thunderbolt text gives an empty summary" || fail "empty text gave a summary"

# Runs the date command exactly as written inside SLEEP_CMD, so a change to it is caught here
wake_cmd=$(sed -n 's/.*"\$(\(date [^)]*\))".*/\1/p' <<<"$SLEEP_CMD")
wake_date=$(eval "$wake_cmd")
[[ "$wake_date" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] && pass "wake time uses pmset's MM/dd/yy HH:mm:ss format" || fail "wake time format is wrong: '$wake_date' from '$wake_cmd'"

SLEEP=0; [ "$(steps)" = "interface service" ] && pass "the sleep step is left out by default" || fail "default steps were: $(steps)"
SLEEP=1; [ "$(steps)" = "interface service sleep" ] && pass "--include-sleep adds the sleep step last" || fail "steps with sleep were: $(steps)"

DRY=1; SLEEP=0
out=$(plan)
echo "$out" | grep -q "ifconfig" && echo "$out" | grep -q "networksetup" && pass "the plan names the interface and service steps" || fail "the plan is missing a step"
echo "$out" | grep -q "pmset" && fail "the plan mentions sleep without --include-sleep" || pass "the plan leaves out sleep without --include-sleep"

# The iMac's login shell is zsh. A command sent through as_bash must split member lists the way bash does.
got=$(zsh -c "$(as_bash 'm=$(printf "en2\nen3"); for i in $m bridge0; do echo "[$i]"; done')" | paste -sd' ' -)
[ "$got" = "[en2] [en3] [bridge0]" ] && pass "a command sent to the iMac's zsh splits members like bash" || fail "zsh ran the iMac command as: $got"

[ $fails -eq 0 ] && echo "tb-recover checks passed" || echo "$fails tb-recover check(s) failed"
exit $fails
