#!/bin/bash
# Tries safe software steps, in order, to bring a dead Thunderbolt link back, and records which one worked.
# Run it on the MacBook, in Terminal, when the iMac cannot connect over Thunderbolt. You type the admin password
# yourself when asked. It never stores or passes a password.
#
# Usage:  Scripts/tb-recover.sh                     check both Macs, then try the steps until the link is back
#         Scripts/tb-recover.sh --include-sleep     also try a system sleep and wake of the iMac (its screen goes dark)
#         Scripts/tb-recover.sh --dry-run           print the plan and the commands, change nothing
#         Scripts/tb-recover.sh --imac NAME         the iMac's name (default iMac.local)
# Needs:  Remote Login switched on in the iMac, and this Mac's SSH key accepted by it (no password prompt).
# Steps:  1 interface  take the bridge and its member interfaces down and up, on both Macs
#         2 service    switch the Thunderbolt Bridge network service off and on, on both Macs
#         3 sleep      (only with --include-sleep) schedule a wake, then sleep the iMac
# Log:    ~/Library/Logs/TBDisplay/recover.log gets one line per step: time, step, link before and after, result.
# Exit codes: 0 link is up (already, or after a step), 1 no step brought it back, 2 the iMac does not answer, 3 bad option.
#
# Nothing here is documented by Apple. The point is to learn which step, if any, works.
set -uo pipefail

IMAC="iMac.local"
DRY=0
SLEEP=0
LOG_FILE="${TBDISPLAY_LOG_DIR:-$HOME/Library/Logs/TBDisplay}/recover.log"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5)

# The two Thunderbolt commands. Single quotes, so they are expanded by the shell that runs them (this Mac or the iMac).
IFACE_CMD='m=$(ifconfig bridge0 | awk "/member:/{print \$2}"); for i in $m bridge0; do sudo ifconfig $i down; done; sleep 2; for i in bridge0 $m; do sudo ifconfig $i up; done'
SERVICE_CMD='sudo networksetup -setnetworkserviceenabled "Thunderbolt Bridge" off; sleep 2; sudo networksetup -setnetworkserviceenabled "Thunderbolt Bridge" on'
SLEEP_CMD='sudo pmset schedule wake "$(date -v+90S "+%m/%d/%y %H:%M:%S")"; sudo pmset sleepnow'

# The bridge carries traffic only when ifconfig says active. Empty text (a Mac that did not answer) is not active.
bridge_is_active() { grep -q "status: active" <<<"$1"; }

# "R1=0x2 R2=0x7 R4=0x100": the link status of each Thunderbolt receptacle. system_profiler prints a port's
# Link Status before its Receptacle, so the status is held until the receptacle line arrives.
parse_links() { awk '/Link Status/{ls=$3} /Receptacle/{print "R" $2 "=" ls}' <<<"$1" | sort | paste -sd' ' -; }

steps() { if [ "$SLEEP" = 1 ]; then echo "interface service sleep"; else echo "interface service"; fi; }

step_command() { case "$1" in interface) echo "$IFACE_CMD";; service) echo "$SERVICE_CMD";; sleep) echo "$SLEEP_CMD";; esac; }
step_title() {
    case "$1" in
        interface) echo "take the bridge and its member interfaces down and up, on both Macs";;
        service)   echo "switch the Thunderbolt Bridge service off and on, on both Macs";;
        sleep)     echo "schedule a wake, then put the iMac to sleep (its screen goes dark)";;
    esac
}

plan() {
    local n=0 s
    for s in $(steps); do
        n=$((n + 1))
        echo "Step $n, $s: $(step_title "$s")"
        echo "    $(step_command "$s")"
    done
}

# --- the parts that touch the two Macs ---

local_bridge() { ifconfig bridge0 2>&1; }
imac_bridge() { "${SSH[@]}" "$IMAC" ifconfig bridge0 2>&1; }
local_links() { parse_links "$(system_profiler SPThunderboltDataType 2>/dev/null)"; }
imac_links() { parse_links "$("${SSH[@]}" "$IMAC" 'system_profiler SPThunderboltDataType 2>/dev/null' 2>/dev/null)"; }
link_summary() { echo "MacBook [$(local_links)]  iMac [$(imac_links)]"; }
link_up() { bridge_is_active "$(local_bridge)" && bridge_is_active "$(imac_bridge)"; }

wait_for_link() {   # seconds
    local waited=0
    while [ "$waited" -lt "$1" ]; do
        link_up && return 0
        sleep 2; waited=$((waited + 2))
    done
    link_up
}

log_step() { mkdir -p "$(dirname "$LOG_FILE")"; echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

# The iMac's login shell is zsh, which does not split "$m" into words, so ifconfig got "en2 en3" as one name.
# Wrap the command so the iMac runs it under bash, the same as this Mac does.
as_bash() { echo "bash -c $(printf %q "$1")"; }

run_on_both() {   # command: the same command on this Mac, then on the iMac (with a terminal, so sudo can ask)
    bash -c "$1" || return 1
    "${SSH[@]}" -t "$IMAC" "$(as_bash "$1")" || return 1
}

run_step() {   # name; returns 0 when the link is up afterwards
    local name="$1" before after result
    before=$(link_summary)
    echo
    echo "Step $name: $(step_title "$name")"
    case "$name" in
        sleep)
            read -r -p "The iMac will sleep for about 90 seconds and any remote session to it will drop. Type yes to go on: " ok
            [ "$ok" = "yes" ] || { echo "Skipped."; log_step "$name skipped by the person | $before"; return 1; }
            "${SSH[@]}" -t "$IMAC" "$(as_bash "$SLEEP_CMD")" || true
            echo "Waiting for the iMac to wake and answer (up to 4 minutes)..."
            local waited=0
            while [ "$waited" -lt 240 ]; do
                sleep 10; waited=$((waited + 10))
                "${SSH[@]}" "$IMAC" true 2>/dev/null && break
            done
            wait_for_link 30
            ;;
        *)
            run_on_both "$(step_command "$name")" || echo "A command in this step failed (wrong password, or the iMac refused)."
            wait_for_link 20
            ;;
    esac
    local rc=$?
    after=$(link_summary)
    if [ "$rc" -eq 0 ]; then result="LINK UP"; else result="no link"; fi
    echo "After step $name: $after => $result"
    log_step "$name | before $before | after $after | $result"
    return $rc
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --include-sleep) SLEEP=1;;
            --dry-run) DRY=1;;
            --imac) shift; IMAC="${1:-}"; [ -n "$IMAC" ] || { echo "--imac needs a name"; exit 3; };;
            -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
            *) echo "Unknown option: $1 (see --help)"; exit 3;;
        esac
        shift
    done

    if [ "$DRY" = 1 ]; then
        echo "Dry run. Nothing is changed. The steps, in order:"
        plan
        exit 0
    fi

    if ! "${SSH[@]}" "$IMAC" true 2>/dev/null; then
        echo "The iMac ($IMAC) does not answer over SSH. Check that Remote Login is on in its Sharing settings and that it is awake."
        exit 2
    fi

    echo "Before: $(link_summary)"
    if link_up; then
        echo "The Thunderbolt link is already up on both Macs. Nothing to do."
        log_step "check | $(link_summary) | already up"
        exit 0
    fi
    echo "The link is down. Trying the steps in order, and stopping at the first that brings it back."

    local s
    for s in $(steps); do
        if run_step "$s"; then
            echo
            echo "RECOVERED by step: $s. Logged in $LOG_FILE"
            exit 0
        fi
    done

    echo
    echo "No software step brought the link back."
    echo "The only known fix: shut the iMac down, pull its power cable for 30 seconds, plug it back in, and boot it with the Thunderbolt cable already in both ends."
    log_step "no software step worked"
    exit 1
}

# The tests load the functions above without running anything.
if [ "${TB_RECOVER_SOURCE_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
main "$@"
