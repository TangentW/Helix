#!/bin/sh
set -eu

# Target phases exist at the target level, while one Helix profile owns
# only one build configuration. Unconfigured configurations are normal.
if [ "${CONFIGURATION:-}" != 'Debug' ]; then
    exit 0
fi
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
integration_root=$(CDPATH= cd -- "$script_directory/../.." && pwd -P)

# Keep wrappers usable from both target phases and Scheme actions.
export HELIX_INTEGRATION_ROOT="$integration_root"
export HELIX_HOST_PLAN="$integration_root/HostPlan.json"
export HELIX_PROFILE_ID="live"

exec /bin/sh "${HELIX_INTEGRATION_ROOT:?}/Scripts/helix-phase.sh" finalize
