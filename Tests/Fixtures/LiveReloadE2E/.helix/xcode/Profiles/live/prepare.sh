#!/bin/sh
set -eu
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
integration_root=$(CDPATH= cd -- "$script_directory/../.." && pwd -P)

# Scheme pre-actions run before target xcconfig values are exported.
export HELIX_INTEGRATION_ROOT="$integration_root"
export HELIX_HOST_PLAN="$integration_root/HostPlan.json"
export HELIX_PROFILE_ID="live"

exec /bin/sh "${HELIX_INTEGRATION_ROOT:?}/Scripts/helix-phase.sh" prepare
