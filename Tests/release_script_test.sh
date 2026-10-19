#!/bin/bash
# Tests Scripts/release.sh with stand-in codesign, hdiutil, xcrun, spctl and security commands, so nothing is
# signed, uploaded or installed. Checks the order of the steps, the flags, and that it stops cleanly when
# something is missing or rejected.
cd "$(dirname "$0")/.."
SCRIPT="$PWD/Scripts/release.sh"
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# A fresh sandbox: stand-in commands that log every call, and fake built apps.
new_sandbox() {
    BOX=$(mktemp -d); mkdir -p "$BOX/bin" "$BOX/build/TBDisplay Server.app/Contents" "$BOX/build/TBDisplay Client.app/Contents" "$BOX/out"
    : > "$BOX/calls.log"
    for tool in codesign hdiutil xcrun spctl security; do
        cat > "$BOX/bin/$tool" <<SHIM
#!/bin/bash
echo "$tool \$*" >> "$BOX/calls.log"
case "$tool" in
  security)
    if [ "\${FAKE_IDENTITIES:-1}" = "1" ]; then
      echo '  1) AAAA "Apple Development: Someone (XXXX)"'
      echo '  2) BBBB "Developer ID Application: Test Person (TEAM123456)"'
    else
      echo '  1) AAAA "Apple Development: Someone (XXXX)"'
    fi ;;
  codesign) [ "\${FAKE_VERIFY_FAIL:-0}" = "1" ] && [[ "\$*" == *--verify* ]] && { echo "code object is not signed" >&2; exit 1; }; exit 0 ;;
  hdiutil)
    for last; do :; done
    src=""; prev=""; for a in "\$@"; do [ "\$prev" = "-srcfolder" ] && src="\$a"; prev="\$a"; done
    [ -n "\$src" ] && ls -l "\$src" >> "$BOX/staging.log"
    : > "\$last" ;;
  xcrun)
    if [[ "\$*" == *notarytool*submit* ]]; then
      if [ "\${FAKE_NOTARY:-Accepted}" = "Accepted" ]; then echo "  id: 1234"; echo "  status: Accepted"; else echo "  id: 1234"; echo "  status: Invalid"; fi
    fi ;;
esac
exit 0
SHIM
        chmod +x "$BOX/bin/$tool"
    done
}
run() { PATH="$BOX/bin:$PATH" BUILD_DIR="$BOX/build" OUT_DIR="$BOX/out" SKIP_BUILD=1 "$SCRIPT" "$@" > "$BOX/stdout" 2> "$BOX/stderr"; echo $? > "$BOX/status"; }
status() { cat "$BOX/status"; }
calls() { cat "$BOX/calls.log"; }
line_of() { grep -n -- "$1" "$BOX/calls.log" | head -1 | cut -d: -f1; }

# 1. The happy path: right order, right flags
new_sandbox; run
[ "$(status)" = "0" ] && pass "a full release succeeds" || fail "a full release failed (status $(status)): $(head -c 200 "$BOX/stderr")"
n=$(calls | grep -c "codesign --force --options runtime --timestamp --sign Developer ID Application: Test Person (TEAM123456)")
[ "$n" -ge 2 ] && pass "both apps are signed with the Developer ID, hardened runtime and a timestamp" || fail "apps not signed as expected (found $n)"
a=$(line_of "codesign --verify"); b=$(line_of "hdiutil create"); c=$(line_of "notarytool submit"); d=$(line_of "stapler staple"); e=$(line_of "stapler validate"); f=$(line_of "spctl")
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$e" ] && [ -n "$f" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] && [ "$e" -lt "$f" ] && pass "verify, disk image, notarise, staple, validate, assess run in that order" || fail "steps out of order ($a $b $c $d $e $f)"
calls | grep -q "notarytool submit .*TBDisplay-.*\.dmg --keychain-profile notary --wait" && pass "the disk image is submitted with the default profile and --wait" || fail "notarytool submit not as expected"
grep -q "Applications -> /Applications" "$BOX/staging.log" && grep -q "TBDisplay Server.app" "$BOX/staging.log" && grep -q "TBDisplay Client.app" "$BOX/staging.log" && pass "the disk image holds both apps and an Applications shortcut" || fail "disk image contents wrong: $(cat "$BOX/staging.log" 2>/dev/null | head -5)"
ls "$BOX/out" | grep -qE "^TBDisplay-[0-9]+\.[0-9]+\.[0-9]+\.dmg$" && pass "the disk image is named with the app version" || fail "disk image name wrong: $(ls "$BOX/out")"
calls | grep -q "codesign --force --timestamp --sign Developer ID Application: Test Person (TEAM123456) .*\.dmg" && pass "the disk image itself is signed" || fail "disk image not signed"

# 2. No Developer ID certificate: stop before touching anything
new_sandbox; FAKE_IDENTITIES=0 run
[ "$(status)" = "3" ] && pass "no Developer ID certificate stops with status 3" || fail "expected status 3, got $(status)"
grep -q "Developer ID Application" "$BOX/stderr" && pass "the message names the missing certificate" || fail "unclear message: $(head -c 150 "$BOX/stderr")"
! calls | grep -qE "^(codesign|hdiutil|xcrun) " && pass "nothing was signed, built or sent" || fail "something ran despite no certificate"

# 3. Apple rejects it: no stapling, and the way to see why
new_sandbox; FAKE_NOTARY=Invalid run
[ "$(status)" = "4" ] && pass "a rejected submission stops with status 4" || fail "expected status 4, got $(status)"
grep -q "notarytool log" "$BOX/stderr" && pass "the message says how to read Apple's reason" || fail "no pointer to the log"
! calls | grep -q "stapler" && pass "a rejected disk image is never stapled" || fail "stapled a rejected image"

# 4. A custom profile name
new_sandbox; NOTARY_PROFILE=mine run
calls | grep -q -- "--keychain-profile mine" && pass "NOTARY_PROFILE chooses the profile" || fail "custom profile ignored"

# 5. No notarisation requested
new_sandbox; run --no-notarize
[ "$(status)" = "0" ] && ! calls | grep -qE "notarytool|stapler" && pass "--no-notarize signs and builds without contacting Apple" || fail "--no-notarize still contacted Apple"
grep -qi "not notarised" "$BOX/stdout" && pass "it says plainly that the image is not notarised" || fail "no not-notarised warning"

# 6. Apps not built
new_sandbox; rm -rf "$BOX/build/TBDisplay Client.app"; run
[ "$(status)" = "2" ] && grep -q "TBDisplay Client.app" "$BOX/stderr" && pass "a missing app stops with status 2 and names it" || fail "missing app not handled (status $(status))"

# 7. A signature that does not verify stops before the disk image
new_sandbox; FAKE_VERIFY_FAIL=1 run
[ "$(status)" != "0" ] && ! calls | grep -q "hdiutil" && pass "a signature that fails to verify stops before the disk image" || fail "carried on after a bad signature"

echo
[ $fails -eq 0 ] && echo "Release script checks passed" || echo "$fails release script check(s) failed"
exit $fails
