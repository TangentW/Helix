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

helix_executable="${HELIX_EXECUTABLE:-helix}"
if ! command -v "$helix_executable" >/dev/null 2>&1; then
    echo "error: Helix executable not found: $helix_executable" >&2
    echo "error: configure HELIX_EXECUTABLE as a user-defined Xcode build setting" >&2
    exit 1
fi

exec "$helix_executable" xcode phase     --plan "$HELIX_HOST_PLAN"     --profile "$HELIX_PROFILE_ID"     --phase "$phase"
