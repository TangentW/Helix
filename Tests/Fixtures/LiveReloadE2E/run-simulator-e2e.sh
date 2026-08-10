#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 SIMULATOR_UDID" >&2
    exit 2
fi

simulator_udid="$1"
script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../../.." && pwd -P)"
generated_directory="$script_directory/.helix-e2e"
derived_data="$generated_directory/DerivedData"
source_file="$script_directory/Sources/LiveReloadE2E.Feature.swift"
project="$script_directory/LiveReloadE2EHost.xcodeproj"
scheme="LiveReloadE2EHost"
bundle_id="dev.helix.live-reload-e2e"
app="$derived_data/Build/Products/Debug-iphonesimulator/LiveReloadE2EHost.app"
executable="$app/LiveReloadE2EHost"
daemon_log="$generated_directory/Daemon.log"
build_log="$generated_directory/BuildConsole.log"
helix="$repository_root/.build/debug/helix"
source_backup="$(mktemp "${TMPDIR:-/tmp}/helix-live-reload-source.XXXXXX")"
daemon_pid=""
app_pid=""

cleanup() {
    local status=$?
    if [[ $status -ne 0 ]]; then
        echo "LiveReloadE2E failed with status $status." >&2
        tail -n 80 "$daemon_log" 2>/dev/null >&2 || true
        tail -n 80 "$build_log" 2>/dev/null >&2 || true
    fi
    cp "$source_backup" "$source_file"
    if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
        kill -INT "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    fi
    xcrun simctl terminate "$simulator_udid" "$bundle_id" >/dev/null 2>&1 || true
    rm -f "$source_backup"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp "$source_file" "$source_backup"
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "LiveReloadE2E currently requires an arm64 Mac." >&2
    exit 1
fi

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

if [[ "$(grep -Fc 'HELIX BASELINE' "$source_file")" -ne 1 ]] \
    || [[ "$(grep -Fc 'HELIX PATCHED' "$source_file")" -ne 0 ]]; then
    echo "The fixture source is not at its committed HELIX BASELINE state." >&2
    exit 1
fi

wait_for_log() {
    local pattern="$1"
    local timeout_seconds="$2"
    local started=$SECONDS
    while ! grep -Fq "$pattern" "$daemon_log" 2>/dev/null; do
        if [[ -n "$daemon_pid" ]] && ! kill -0 "$daemon_pid" 2>/dev/null; then
            echo "Helix Dev Daemon exited before: $pattern" >&2
            tail -n 80 "$daemon_log" >&2 || true
            exit 1
        fi
        if (( SECONDS - started >= timeout_seconds )); then
            echo "Timed out waiting for: $pattern" >&2
            tail -n 80 "$daemon_log" >&2 || true
            exit 1
        fi
        sleep 0.1
    done
}

value_from_log() {
    local key="$1"
    awk -F= -v key="$key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }' "$daemon_log"
}

mkdir -p "$generated_directory"
cd "$repository_root"
swift build --product helix

xcode_build="$(xcodebuild -version | awk '/Build version/ { print $3; exit }')"
sdk_build="$(xcrun --sdk iphonesimulator --show-sdk-build-version)"
compiler="$(xcrun --find swiftc)"

"$helix" shell metadata \
    --bundle-id "$bundle_id" \
    --build-number 1 \
    --namespace-seed live-reload-e2e \
    --module LiveReloadE2E \
    --target arm64-apple-ios15.0-simulator \
    --minimum-os 15.0.0 \
    --xcode-build "$xcode_build" \
    --sdk-name iphonesimulator \
    --sdk-build "$sdk_build" \
    --optimization=-Onone \
    --semantic-argument=-parse-as-library \
    --semantic-argument=-Xfrontend \
    --semantic-argument=-enable-implicit-dynamic \
    --output "$generated_directory/ReleaseMetadata.json" \
    --force

"$helix" shell index \
    --metadata "$generated_directory/ReleaseMetadata.json" \
    --configuration "$script_directory/Helix.yml" \
    --source-map "Sources/LiveReloadE2E.Feature.swift=$source_file" \
    --compiler "$compiler" \
    --output "$generated_directory/ShellBuildReceipt.json" \
    --force

"$helix" shell build \
    --receipt "$generated_directory/ShellBuildReceipt.json" \
    --source-root "$script_directory" \
    --output "$generated_directory/ShellDerived" \
    --force

xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "id=$simulator_udid" \
    -derivedDataPath "$derived_data" \
    clean build 2>&1 | tee "$build_log" >/dev/null
echo "Built LiveReloadE2EHost."

"$helix" shell finalize \
    --archive "$generated_directory/ShellDerived/Shell.provisional.hlxi" \
    --executable "$executable" \
    --output "$generated_directory/Shell.final.hlxi" \
    --force

"$helix" dev prepare \
    --activity-log "$build_log" \
    --working-directory "$script_directory" \
    --workspace "$project" \
    --scheme "$scheme" \
    --configuration Debug \
    --bundle-id "$bundle_id" \
    --module LiveReloadE2E \
    --executable "$executable" \
    --reload-index "$generated_directory/ShellDerived/ReloadIndex.json" \
    --archive "$generated_directory/Shell.final.hlxi" \
    --manifest-output "$generated_directory/DevBuildManifest.json" \
    --native-output-directory "$generated_directory/Native" \
    --output "$generated_directory/HelixDev.json" \
    --no-bonjour \
    --force

xcrun simctl terminate "$simulator_udid" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl install "$simulator_udid" "$app"
: > "$daemon_log"
"$helix" dev run --config "$generated_directory/HelixDev.json" \
    > "$daemon_log" 2>&1 &
daemon_pid=$!
wait_for_log "HLX_DEV_SPKI_SHA256=" 20

session_port="$(value_from_log HLX_DEV_PORT)"
session_id="$(value_from_log HLX_DEV_SESSION_ID)"
session_secret="$(value_from_log HLX_DEV_SESSION_SECRET)"
spki_hash="$(value_from_log HLX_DEV_SPKI_SHA256)"
service_name="$(value_from_log HLX_DEV_SERVICE_NAME)"
protocol_version="$(value_from_log HLX_DEV_PROTOCOL_VERSION)"
if [[ -z "$session_port" || -z "$session_id" || -z "$session_secret" \
    || -z "$spki_hash" || -z "$service_name" || -z "$protocol_version" ]]; then
    echo "Daemon launch environment is incomplete." >&2
    exit 1
fi

launch_output="$(
    SIMCTL_CHILD_HLX_DEV_HOST=127.0.0.1 \
    SIMCTL_CHILD_HLX_DEV_PORT="$session_port" \
    SIMCTL_CHILD_HLX_DEV_PROTOCOL_VERSION="$protocol_version" \
    SIMCTL_CHILD_HLX_DEV_SERVICE_NAME="$service_name" \
    SIMCTL_CHILD_HLX_DEV_SESSION_ID="$session_id" \
    SIMCTL_CHILD_HLX_DEV_SESSION_SECRET="$session_secret" \
    SIMCTL_CHILD_HLX_DEV_SPKI_SHA256="$spki_hash" \
    xcrun simctl launch --terminate-running-process \
        "$simulator_udid" "$bundle_id"
)"
app_pid="${launch_output##*: }"
wait_for_log "Connected process $app_pid on iOSSimulator/arm64." 20

sed -i '' 's/"HELIX BASELINE"/"HELIX PATCHED"/' "$source_file"
wait_for_log "r1/g1: codeActive, UI refreshed." 30
kill -0 "$app_pid"

sed -i '' 's/"HELIX PATCHED"/"HELIX BASELINE"/' "$source_file"
wait_for_log "r2/g2: codeActive, UI refreshed." 30
kill -0 "$app_pid"

echo "LiveReloadE2E passed in process $app_pid."
echo "Daemon log: $daemon_log"
