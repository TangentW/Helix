#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 SIMULATOR_UDID" >&2
    exit 2
fi

simulator_udid="$1"
script_directory="$(cd "$(dirname "$0")" && pwd -P)"
project="$script_directory/LiveReloadE2EHost.xcodeproj"
derived_data="$script_directory/.helix-ios-tests/DerivedData"

ensure_simulator_booted() {
    local boot_error
    if xcrun simctl list devices booted | grep -Fq "$simulator_udid"; then
        return
    fi
    if ! xcrun simctl list devices available | grep -Fq "$simulator_udid"; then
        echo "Simulator $simulator_udid is not available." >&2
        exit 1
    fi
    echo "Booting Simulator $simulator_udid."
    if ! boot_error="$(xcrun simctl boot "$simulator_udid" 2>&1)"; then
        if ! xcrun simctl list devices | grep -F "$simulator_udid" | grep -Eq '\((Booting|Booted)\)'; then
            echo "$boot_error" >&2
            exit 1
        fi
    fi
    xcrun simctl bootstatus "$simulator_udid" -b
}

ensure_simulator_booted

xcodebuild test \
    -quiet \
    -project "$project" \
    -scheme LiveReloadUIKitTests \
    -destination "id=$simulator_udid" \
    -derivedDataPath "$derived_data"
