#!/bin/sh
# Builds, signs and (unless --no-install is given) installs and launches
# Klippari. The app must always run from /Applications so that its
# Accessibility grant and login item stay attached to one bundle.
#
# The signing identity is never stored in the repository: pass it with
# --identity, or set CODESIGN_IDENTITY. Use the same identity for every
# build, or macOS treats the new build as a different app and asks for
# the Accessibility permission again.
set -eu
cd "$(dirname "$0")/.."

usage() {
    cat >&2 <<'EOF'
usage: Scripts/build-app.sh --identity <name> [--no-install]

  --identity <name>  Code signing identity, as listed by
                     'security find-identity -v -p codesigning'.
                     Defaults to the CODESIGN_IDENTITY environment variable.
  --no-install       Build and sign into build/ without installing.
EOF
    exit "${1:-2}"
}

IDENTITY="${CODESIGN_IDENTITY:-}"
INSTALL=1
while [ $# -gt 0 ]; do
    case "$1" in
        --identity)
            [ $# -ge 2 ] || usage
            IDENTITY="$2"
            shift 2
            ;;
        --no-install)
            INSTALL=0
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

if [ -z "$IDENTITY" ]; then
    echo "error: no signing identity given" >&2
    usage
fi

APP="build/Klippari.app"
DEST="/Applications/Klippari.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Klippari "$APP/Contents/MacOS/Klippari"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign "$IDENTITY" "$APP"

if [ "$INSTALL" -eq 0 ]; then
    echo "Built $APP"
    exit 0
fi

pkill -x Klippari || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
