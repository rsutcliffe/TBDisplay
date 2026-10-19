#!/bin/bash
# Runs the project's checks, one after another (they share ports and the screen, so never in parallel).
#   Tests/all.sh        the quiet groups only: nothing opens a window, so it is safe to run while you work
#   Tests/all.sh full   everything. The window groups open real windows on this Mac and drive them by script,
#                       so leave the keyboard and mouse alone while it runs, and stop any running TBDisplay first.
cd "$(dirname "$0")/.."
# The window checks need the screen awake: a sleeping display shows no windows to the scripts
caffeinate -u -t 3 &
caffeinate -d -w $$ &
total=0; failed=()
OUT=/private/tmp/tbdisplay-checks; rm -rf "$OUT"; mkdir -p "$OUT"     # one log per group, kept for reading afterwards
run() {   # name command...
    local name="$1"; shift
    local log="$OUT/${name// /-}.log"
    echo "=== $name"
    if "$@" > "$log" 2>&1; then
        n=$(grep -c '^ok' "$log"); [ "$n" -gt 0 ] && echo "    passed: $n checks" || echo "    passed"
    else
        failed+=("$name"); grep -E "^FAIL|failed" "$log" | head -5 | sed 's/^/    /'
    fi
    total=$((total + 1))
}
./build.sh > /dev/null 2>&1 || { echo "The build failed."; exit 1; }
swift_tests() { local out; out=$(swift test 2>&1); echo "$out"; echo "$out" | grep -q "with 0 failures (0 unexpected)"; }
run "test wiring"           Tests/test_lists.sh
run "unit checks"            ./build.sh test
run "Xcode package (XCTest)" swift_tests
run "release script"         Tests/release_script_test.sh
run "encoder speed"          Tests/encoder_latency.sh
if [ "${1:-}" = "full" ]; then
    run "end to end (loopback)"  Tests/loopback.sh
    run "input permission"       Tests/input_gate.sh
    run "iMac window"            Tests/client_window.sh
    run "pairing windows"        Tests/pairing_ui.sh
    run "connection check"       Tests/connection_check_ui.sh
    run "setup checklist"        Tests/checklist_ui.sh
fi
echo "Logs: $OUT"
if [ ${#failed[@]} -eq 0 ]; then echo "All $total groups passed."; else echo "${#failed[@]} of $total groups failed: ${failed[*]}"; exit 1; fi
