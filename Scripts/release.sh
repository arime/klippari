#!/bin/sh
# Builds a universal, Developer ID signed Klippari.app and packs it in a
# signed and notarized disk image for a GitHub release, as
# build/Klippari-<version>.dmg. The version comes from
# CFBundleShortVersionString in Resources/Info.plist.
#
# Neither the signing identity nor the notarization credentials are
# stored in the repository. Store the credentials in the keychain once:
#
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
#
# and pass the profile name with --notary-profile.
set -eu
cd "$(dirname "$0")/.."

usage() {
    cat >&2 <<'EOF'
usage: Scripts/release.sh --identity <name> --notary-profile <profile> [--skip-notarize]

  --identity <name>          'Developer ID Application: ...' identity, as
                             listed by 'security find-identity -v -p codesigning'.
                             Defaults to the RELEASE_IDENTITY environment variable.
  --notary-profile <profile> notarytool keychain profile. Defaults to the
                             NOTARY_PROFILE environment variable.
  --skip-notarize            Build and sign only, for testing the script.
EOF
    exit "${1:-2}"
}

IDENTITY="${RELEASE_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-}"
NOTARIZE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --identity)
            [ $# -ge 2 ] || usage
            IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            [ $# -ge 2 ] || usage
            PROFILE="$2"
            shift 2
            ;;
        --skip-notarize)
            NOTARIZE=0
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage
            ;;
    esac
done

case "$IDENTITY" in
    "Developer ID Application:"*) ;;
    "")
        echo "error: no signing identity given" >&2
        usage
        ;;
    *)
        echo "error: releases must be signed with a 'Developer ID Application:' identity" >&2
        exit 1
        ;;
esac
if [ "$NOTARIZE" -eq 1 ] && [ -z "$PROFILE" ]; then
    echo "error: no notarytool profile given" >&2
    usage
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
APP="build/release/Klippari.app"
DMG="build/Klippari-$VERSION.dmg"

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf build/release "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Klippari" "$APP/Contents/MacOS/Klippari"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# The disk image shows the app next to a link to /Applications, so it is
# installed by dragging one onto the other.
STAGE="build/release/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Klippari.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Klippari $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$NOTARIZE" -eq 1 ]; then
    LOG="build/release/notarize.log"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tee "$LOG"
    if ! grep -q 'status: Accepted' "$LOG"; then
        echo "error: notarization was not accepted; see the log with" >&2
        echo "  xcrun notarytool log <submission id> --keychain-profile $PROFILE" >&2
        exit 1
    fi
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

lipo -archs "$APP/Contents/MacOS/Klippari"
shasum -a 256 "$DMG"
echo "Built $DMG (version $VERSION)"
