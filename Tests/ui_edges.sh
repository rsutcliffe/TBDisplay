# Sourced by the window scripts. Needs pass() and fail() to exist. It talks to System Events itself, because the scripts define ax() differently.
# check_inside PROCESS WINDOW: every button, label and checkbox must sit inside the window with at least 12 points to spare
# on the right and at the bottom. This is the fault that clipped the Quit button, so it is measured, not judged by eye.
# (Written for the bash 3.2 that macOS ships: no here-document inside a process substitution.)
read -r -d '' UI_EDGES_SCRIPT <<'APPLESCRIPT'
tell application "System Events" to tell process "PROCNAME"
    set out to ""
    repeat with e in (every UI element of window "WINNAME")
        try
            set c to class of e as string
            if c is in {"button", "static text", "checkbox"} then
                set p to position of e
                set s to size of e
                set out to out & c & "|" & (item 1 of p) & "|" & (item 2 of p) & "|" & (item 1 of s) & "|" & (item 2 of s) & "|" & (name of e) & linefeed
            end if
        end try
    end repeat
    return out
end tell
APPLESCRIPT

check_inside() {
    local proc="$1" win="$2" wx wy ww wh n=0 bad=0 kind x y w h name script
    read -r wx wy < <(osascript -e "tell application \"System Events\" to tell process \"$proc\" to get position of window \"$win\"" 2>/dev/null | tr -d ',' | tr -s ' ')
    read -r ww wh < <(osascript -e "tell application \"System Events\" to tell process \"$proc\" to get size of window \"$win\"" 2>/dev/null | tr -d ',' | tr -s ' ')
    [ -n "$ww" ] || { fail "could not read the size of \"$win\""; return; }
    script="${UI_EDGES_SCRIPT//PROCNAME/$proc}"
    script="${script//WINNAME/$win}"
    while IFS='|' read -r kind x y w h name; do
        [ -n "$kind" ] || continue
        [ "$y" -lt $((wy + 28)) ] && continue                  # the title bar buttons
        n=$((n + 1))
        if [ $((x + w)) -gt $((wx + ww - 12)) ] || [ $((y + h)) -gt $((wy + wh - 12)) ] || [ "$x" -lt $((wx + 8)) ]; then
            bad=$((bad + 1)); echo "     outside: $kind \"$name\" at $x,$y size ${w}x${h}, window $wx,$wy ${ww}x${wh}"
        fi
    done < <(osascript -e "$script" 2>/dev/null)
    [ "$n" -gt 0 ] && [ "$bad" -eq 0 ] && pass "all $n controls in \"$win\" sit inside the window with a margin" || fail "$bad of $n controls in \"$win\" touch or pass the window edge"
}
