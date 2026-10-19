#!/bin/bash
# Every unit test file must be wired in three places, or it is silently skipped by one of the runners:
# the explicit file list in Package.swift, the call list in Tests/main.swift, and the XCTest wrapper.
cd "$(dirname "$0")/.." || exit 2
fails=0
for f in Tests/*Tests.swift; do
    name=$(basename "$f")
    fn=$(grep -o -E 'func run[A-Za-z]+Tests' "$f" | head -1 | sed 's/func //')
    [ -n "$fn" ] || { echo "FAIL $name has no run...Tests function"; fails=$((fails + 1)); continue; }
    grep -q "\"$name\"" Package.swift && echo "ok   $name is listed in Package.swift" || { echo "FAIL $name is missing from Package.swift"; fails=$((fails + 1)); }
    grep -q "^$fn()" Tests/main.swift && echo "ok   $fn is called by Tests/main.swift" || { echo "FAIL $fn is not called by Tests/main.swift"; fails=$((fails + 1)); }
    grep -q "$fn)" Tests/XCTests/SuiteTests.swift && echo "ok   $fn has an XCTest wrapper" || { echo "FAIL $fn has no XCTest wrapper"; fails=$((fails + 1)); }
done
[ $fails -eq 0 ] && echo "All test files are wired in" || echo "$fails test wiring problem(s)"
exit $fails
