#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../../.." && pwd -P)"
generated_directory="$script_directory/.helix-release"
derived_data="$generated_directory/DerivedData"
project="$script_directory/LiveReloadE2EHost.xcodeproj"
scheme="ReleaseRuntimeHost"
app="$derived_data/Build/Products/Release-iphonesimulator/ReleaseRuntimeHost.app"
build_log="$generated_directory/BuildConsole.log"
report="$generated_directory/ReleaseLeakage.json"
helix="$repository_root/.build/debug/helix"

failure_diagnostics() {
    local status=$?
    if [[ $status -ne 0 ]]; then
        echo "ReleaseRuntimeHost audit failed with status $status." >&2
        tail -n 100 "$build_log" 2>/dev/null >&2 || true
    fi
    exit "$status"
}
trap failure_diagnostics EXIT

mkdir -p "$generated_directory"
cd "$repository_root"
swift build --product helix

xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -sdk iphonesimulator \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$derived_data" \
    clean build 2>&1 | tee "$build_log" >/dev/null

"$helix" shell audit-release \
    --app "$app" \
    --output "$report" \
    --force

echo "ReleaseRuntimeHost passed the Helix release leakage audit."
echo "Report: $report"
