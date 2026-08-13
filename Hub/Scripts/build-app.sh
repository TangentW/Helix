#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/../.." && pwd)
CONFIGURATION=${1:-release}
OUTPUT=${2:-"$REPOSITORY_ROOT/Hub/.build/Helix.app"}

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release] [absolute-output.app]" >&2
        exit 64
        ;;
esac

case "$OUTPUT" in
    /*.app) ;;
    *)
        echo "output must be an absolute .app path" >&2
        exit 64
        ;;
esac

STAGING="$OUTPUT.staging.$$"
BACKUP="$OUTPUT.previous.$$"
cleanup() {
    /bin/rm -rf -- "$STAGING"
    if [ -e "$BACKUP" ] && [ ! -e "$OUTPUT" ]; then
        /bin/mv -- "$BACKUP" "$OUTPUT"
    fi
}
trap cleanup EXIT INT TERM

/usr/bin/xcrun swift build \
    --package-path "$REPOSITORY_ROOT" \
    --configuration "$CONFIGURATION" \
    --product helix-hub-app
/usr/bin/xcrun swift build \
    --package-path "$REPOSITORY_ROOT" \
    --configuration "$CONFIGURATION" \
    --product helix
BIN_DIRECTORY=$(/usr/bin/xcrun swift build \
    --package-path "$REPOSITORY_ROOT" \
    --configuration "$CONFIGURATION" \
    --show-bin-path)

/bin/mkdir -p \
    "$STAGING/Contents/MacOS" \
    "$STAGING/Contents/Helpers" \
    "$STAGING/Contents/Resources"
/usr/bin/install -m 0755 \
    "$BIN_DIRECTORY/helix-hub-app" \
    "$STAGING/Contents/MacOS/Helix"
/usr/bin/install -m 0755 \
    "$BIN_DIRECTORY/helix" \
    "$STAGING/Contents/Helpers/helix"
/usr/bin/install -m 0644 \
    "$REPOSITORY_ROOT/Hub/SupportingFiles/Info.plist" \
    "$STAGING/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none \
    "$STAGING/Contents/Helpers/helix"
/usr/bin/codesign --force --sign - --timestamp=none "$STAGING"
/usr/bin/codesign --verify --strict --verbose=2 "$STAGING"

if [ -e "$OUTPUT" ]; then
    /bin/mv -- "$OUTPUT" "$BACKUP"
fi
/bin/mv -- "$STAGING" "$OUTPUT"
/bin/rm -rf -- "$BACKUP"
trap - EXIT INT TERM
echo "$OUTPUT"
