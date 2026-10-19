#!/bin/bash
# Sign with the Developer ID certificate when installed: its identity (bundle id plus team) stays the same across
# rebuilds, so Screen Recording and Accessibility grants survive. Ad hoc signing changes identity every build.
SIGN_ID="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    SIGN_ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')
fi
# Builds tbdisplay-server (MacBook) and tbdisplay-client (iMac) with the Xcode command line tools.
# Usage: ./build.sh            builds both, as plain binaries and as .app bundles
#        ./build.sh server     builds the server only
#        ./build.sh client     builds the client only
#        ./build.sh test       runs the protocol checks
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install the command line tools with: xcode-select --install"
    exit 1
fi

TARGET="arm64-apple-macos14.0"
FLAGS=(-O -swift-version 5 -target "$TARGET")
mkdir -p build

what="${1:-all}"

# The version shown in Finder comes from the code, so the two cannot disagree
VERSION=$(sed -n 's/^let appVersion = "\(.*\)".*/\1/p' Sources/Shared/Shared.swift)
[[ -n "$VERSION" ]] || { echo "Could not read appVersion from Sources/Shared/Shared.swift"; exit 1; }

shopt -s nullglob
CORE=(Sources/Core/*.swift)    # logic with no window code, so tests can run it
UI=(Sources/UI/*.swift)        # windows both apps use

if [[ "$what" == "test" ]]; then
    swiftc -swift-version 5 -target "$TARGET" Sources/Shared/Shared.swift ${CORE[@]+"${CORE[@]}"} Tests/*.swift -o build/shared-tests
    ./build/shared-tests
    exit 0
fi

if [[ "$what" == "all" || "$what" == "server" ]]; then
    echo "Building tbdisplay-server"
    swiftc "${FLAGS[@]}" \
        -import-objc-header Sources/Server/CGVirtualDisplay.h \
        Sources/Shared/Shared.swift ${CORE[@]+"${CORE[@]}"} ${UI[@]+"${UI[@]}"} Sources/Server/*.swift \
        -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit \
        -framework VideoToolbox -framework CoreMedia -framework Network -framework ServiceManagement \
        -o build/tbdisplay-server
fi

if [[ "$what" == "all" || "$what" == "client" ]]; then
    echo "Building tbdisplay-client"
    swiftc "${FLAGS[@]}" \
        Sources/Shared/Shared.swift ${CORE[@]+"${CORE[@]}"} ${UI[@]+"${UI[@]}"} Sources/Client/*.swift \
        -framework AppKit -framework AVFoundation -framework CoreMedia \
        -framework Network -framework IOKit -framework ServiceManagement \
        -o build/tbdisplay-client
fi

# Wraps a binary in a .app so macOS attaches permissions to the app instead of Terminal.
# $1 role (server or client), $2 display name, $3 hide from the Dock (true or false)
make_app() {
    local role="$1" name="$2" agent="$3"
    local app="build/$name.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "build/tbdisplay-$role" "$app/Contents/MacOS/tbdisplay-$role"
    mkdir -p "$app/Contents/Resources"
    [[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.tbdisplay.$role</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleExecutable</key><string>tbdisplay-$role</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><$agent/>
    <key>NSLocalNetworkUsageDescription</key><string>TBDisplay talks to your other Mac over the cable or network.</string>
    <key>NSBonjourServices</key><array><string>_tbdisplay._tcp</string><string>_tbdisplay-pair._tcp</string></array>
    <key>NSScreenCaptureUsageDescription</key><string>TBDisplay captures the extra display it creates, so it can show it on the iMac.</string>
</dict>
</plist>
PLIST
    codesign --force --sign "$SIGN_ID" "$app" >/dev/null 2>&1 || true
}

if [[ "$what" == "all" || "$what" == "server" ]]; then make_app server "TBDisplay Server" true; fi
if [[ "$what" == "all" || "$what" == "client" ]]; then make_app client "TBDisplay Client" false; fi

# Ad hoc signature so macOS keeps permissions attached to a stable identity.
# The signature changes with every rebuild, so permission may need granting again.
for bin in build/tbdisplay-server build/tbdisplay-client; do
    [[ -f "$bin" ]] && codesign --force --sign "$SIGN_ID" "$bin" >/dev/null 2>&1 || true
done

echo "Done. Binaries and apps are in ./build"
