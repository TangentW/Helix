#!/bin/sh
set -eu

capture="${1:?missing Swift compiler capture}"
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
integration_root=$(CDPATH= cd -- "$script_directory/../../.." && pwd -P)
export HELIX_INTEGRATION_ROOT="$integration_root"
export HELIX_HOST_PLAN="$integration_root/HostPlan.json"
export HELIX_PROFILE_ID="hot"

exec /bin/sh "$integration_root/Scripts/helix-phase.sh" post-compile "$capture"
