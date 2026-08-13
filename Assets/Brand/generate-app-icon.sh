#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/../.." && pwd)
SOURCE="$SCRIPT_DIRECTORY/Helix.AppIcon.svg"
OUTPUT="$REPOSITORY_ROOT/Hub/SupportingFiles/Helix.icns"
WORK_DIRECTORY=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/helix-app-icon.XXXXXX")

cleanup() {
    /bin/rm -rf -- "$WORK_DIRECTORY"
}
trap cleanup EXIT INT TERM

/usr/bin/qlmanage -t -s 1024 -o "$WORK_DIRECTORY" "$SOURCE" >/dev/null
MASTER="$WORK_DIRECTORY/Helix.AppIcon.svg.png"
ICONSET="$WORK_DIRECTORY/Helix.iconset"
/bin/mkdir -p "$ICONSET"

/bin/cp "$MASTER" "$ICONSET/icon_512x512@2x.png"
/usr/bin/sips -z 512 512 "$MASTER" --out "$ICONSET/icon_512x512.png" >/dev/null
/bin/cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
/usr/bin/sips -z 256 256 "$MASTER" --out "$ICONSET/icon_256x256.png" >/dev/null
/bin/cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
/usr/bin/sips -z 128 128 "$MASTER" --out "$ICONSET/icon_128x128.png" >/dev/null
/usr/bin/sips -z 64 64 "$MASTER" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$MASTER" --out "$ICONSET/icon_32x32.png" >/dev/null
/bin/cp "$ICONSET/icon_32x32.png" "$ICONSET/icon_16x16@2x.png"
/usr/bin/sips -z 16 16 "$MASTER" --out "$ICONSET/icon_16x16.png" >/dev/null

/usr/bin/iconutil -c icns -o "$WORK_DIRECTORY/Helix.icns" "$ICONSET"
/usr/bin/install -m 0644 "$WORK_DIRECTORY/Helix.icns" "$OUTPUT"
/usr/bin/file "$OUTPUT"
