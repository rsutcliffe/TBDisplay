#!/bin/bash
# Builds TBDisplay, signs both apps with your Developer ID, puts them in a disk image, has Apple notarise it,
# and staples the result, so it opens on any Mac without a security warning.
#
# Usage:  Scripts/release.sh                 build, sign, notarise, staple
#         Scripts/release.sh --no-notarize   build and sign only (works without Apple credentials)
# Needs:  a "Developer ID Application" certificate in your keychain, and, to notarise, a saved profile.
#         One-off, typed by you so the password never passes through anything else:
#           xcrun notarytool store-credentials notary --apple-id <your Apple ID> --team-id <your team ID>
#         NOTARY_PROFILE=name uses a different profile name.
# Exit codes: 2 build problem, 3 no certificate, 4 Apple rejected it, 5 signing failed.
set -uo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="${BUILD_DIR:-build}"
OUT_DIR="${OUT_DIR:-build/release}"
PROFILE="${NOTARY_PROFILE:-notary}"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0
APPS=("TBDisplay Server.app" "TBDisplay Client.app")

fail() { echo "$2" >&2; exit "$1"; }

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
[[ -n "$IDENTITY" ]] || fail 3 "No \"Developer ID Application\" certificate was found in your keychain, so nothing can be signed for sharing.
Create one in Xcode (Settings > Accounts > Manage Certificates) or at developer.apple.com, then run this again."

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    ./build.sh >/dev/null || fail 2 "The build failed. Run ./build.sh to see why."
fi
for app in "${APPS[@]}"; do
    [[ -d "$BUILD_DIR/$app" ]] || fail 2 "Missing $BUILD_DIR/$app. Run ./build.sh first."
done

VERSION=$(sed -n 's/^let appVersion = "\(.*\)".*/\1/p' Sources/Shared/Shared.swift)
[[ -n "$VERSION" ]] || fail 2 "Could not read the version from Sources/Shared/Shared.swift."

echo "Signing as: $IDENTITY"
for app in "${APPS[@]}"; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUILD_DIR/$app" || fail 5 "Signing $app failed."
    codesign --verify --strict --verbose=2 "$BUILD_DIR/$app" || fail 5 "The signature on $app does not verify."
done

mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/TBDisplay-$VERSION.dmg"
STAGE=$(mktemp -d)
for app in "${APPS[@]}"; do cp -R "$BUILD_DIR/$app" "$STAGE/"; done
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TBDisplay" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null || fail 2 "Could not make the disk image."
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG" || fail 5 "Signing the disk image failed."

if [[ $NOTARIZE -eq 0 ]]; then
    echo "Made $DMG. It is signed but NOT notarised, so other Macs will show a security warning."
    exit 0
fi

echo "Sending $DMG to Apple. This usually takes a few minutes."
RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1)
echo "$RESULT"
echo "$RESULT" | grep -q "status: Accepted" || fail 4 "Apple did not accept the disk image (or the profile \"$PROFILE\" is missing).
To see why: xcrun notarytool log <the id above> --keychain-profile $PROFILE
To save a profile: xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id <your team ID>"

xcrun stapler staple "$DMG" || fail 4 "Stapling failed."
xcrun stapler validate "$DMG" || fail 4 "The stapled ticket does not validate."
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || fail 4 "macOS would still warn about this disk image."
echo "Done: $DMG is signed, notarised and stapled."
