#!/bin/sh
set -eu
exec /bin/sh "${HELIX_INTEGRATION_ROOT:?}/Scripts/helix-phase.sh" bridge
