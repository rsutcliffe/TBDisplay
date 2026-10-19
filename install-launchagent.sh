#!/bin/bash
# Starts TBDisplay at login. Opt in per Mac.
# Usage: ./install-launchagent.sh server|client [path to the .app] [options for the app]
#        ./install-launchagent.sh remove server|client
# Examples (MacBook): ./install-launchagent.sh server
#          (iMac):    ./install-launchagent.sh client "$HOME/Applications/TBDisplay Client.app" --any-interface --host MACBOOK-ADDRESS
# Keep secrets out of the arguments: they are stored in the plist and visible in the process list. The pairing key is a file.
set -euo pipefail

if [[ "${1:-}" == "remove" ]]; then
    role="${2:?server or client}"
    launchctl bootout "gui/$UID/local.tbdisplay.$role" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/local.tbdisplay.$role.plist"
    echo "Removed the $role launch agent."
    exit 0
fi

role="${1:?Usage: $0 server|client [path to .app] [options]}"
[[ "$role" == "server" || "$role" == "client" ]] || { echo "Say server or client."; exit 1; }
shift
name="TBDisplay $(tr '[:lower:]' '[:upper:]' <<< "${role:0:1}")${role:1}"
app="$(cd "$(dirname "$0")" && pwd)/build/$name.app"
if [[ $# -gt 0 && "$1" == *.app ]]; then app="$1"; shift; fi
exe="$app/Contents/MacOS/tbdisplay-$role"
[[ -x "$exe" ]] || { echo "Not found: $exe"; exit 1; }

label="local.tbdisplay.$role"
plist="$HOME/Library/LaunchAgents/$label.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "<key>Label</key><string>$label</string>"
    echo '<key>ProgramArguments</key><array>'
    echo "<string>$exe</string>"
    for a in "$@"; do printf '<string>%s</string>\n' "$(printf '%s' "$a" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"; done
    echo '</array>'
    echo '<key>RunAtLoad</key><true/>'
    echo '<key>KeepAlive</key><true/>'
    echo "<key>StandardErrorPath</key><string>$HOME/Library/Logs/tbdisplay-$role.log</string>"
    echo '</dict></plist>'
} > "$plist"

launchctl bootout "gui/$UID/$label" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$plist"
echo "Installed. $role starts at login. Log: ~/Library/Logs/tbdisplay-$role.log"
echo "Remove with: $0 remove $role"
