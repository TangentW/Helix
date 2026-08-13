#!/bin/sh
set -eu

phase="${1:?missing Helix Xcode phase}"
: "${HELIX_HOST_PLAN:?HELIX_HOST_PLAN is not configured}"
: "${HELIX_PROFILE_ID:?HELIX_PROFILE_ID is not configured}"

# Scheme Build pre/post-actions are also invoked by `xcodebuild clean`
# and some non-product actions. Those actions have no linked App to
# finalize or audit and must not materialize a new Shell baseline.
case "${ACTION:-}" in
    clean|analyze|installhdrs|installsrc)
        exit 0
        ;;
esac

if [ "${ENABLE_PREVIEWS:-NO}" = "YES" ]; then
    exit 0
fi

# Xcode exports these build-setting names, while Swift Driver reserves
# the SWIFT_DEBUG_* environment namespace for its own diagnostics.
unset SWIFT_DEBUG_INFORMATION_FORMAT SWIFT_DEBUG_INFORMATION_VERSION

helix_executable="${HELIX_EXECUTABLE:-}"
service_record="${HOME:?}/Library/Application Support/Helix/Service.json"
if [ -z "$helix_executable" ] && [ -f "$service_record" ] && [ ! -L "$service_record" ]; then
    record_owner=$(/usr/bin/stat -f "%u" "$service_record" 2>/dev/null || true)
    record_mode=$(/usr/bin/stat -f "%Lp" "$service_record" 2>/dev/null || true)
    if [ "$record_owner" = "$(/usr/bin/id -u)" ] && [ "$record_mode" = "600" ]; then
        record_schema=$(
            /usr/bin/plutil -extract schemaVersion raw -o - "$service_record" 2>/dev/null || true
        )
        record_pid=$(
            /usr/bin/plutil -extract processIdentifier raw -o - "$service_record" 2>/dev/null || true
        )
        case "$record_pid" in
            ''|*[!0-9]*) record_pid=0 ;;
        esac
        if [ "$record_schema" = "1" ] && [ "$record_pid" -gt 1 ]             && /bin/kill -0 "$record_pid" 2>/dev/null; then
            helix_executable=$(
                /usr/bin/plutil -extract toolExecutablePath raw -o - "$service_record" 2>/dev/null || true
            )
        fi
    fi
fi
if [ -z "$helix_executable" ]; then
    helix_executable=$(command -v helix 2>/dev/null || true)
fi
if [ -z "$helix_executable" ] || ! command -v "$helix_executable" >/dev/null 2>&1; then
    echo "error: no Helix build tool is available; open Helix and try again" >&2
    echo "error: headless workflows may install helix on PATH or set HELIX_EXECUTABLE" >&2
    exit 1
fi

exec "$helix_executable" xcode phase     --plan "$HELIX_HOST_PLAN"     --profile "$HELIX_PROFILE_ID"     --phase "$phase"
