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
scenario_directory="$script_directory/Scenarios"
project="$script_directory/LiveReloadE2EHost.xcodeproj"
scheme="LiveReloadE2EHost"
bundle_id="dev.helix.live-reload-e2e"
app="$derived_data/Build/Products/Debug-iphonesimulator/LiveReloadE2EHost.app"
hub_log="$generated_directory/Hub.log"
debugger_log="$generated_directory/Debugger.log"
build_log="$generated_directory/BuildConsole.log"
build_settings="$generated_directory/BuildSettings.json"
helix="$repository_root/.build/debug/helix"
source_backup=""
hub_pid=""
debugger_pid=""
app_pid=""
evidence_file=""

cleanup() {
    local status=$?
    if ! restore_baseline_source; then
        echo "Failed to restore the Live Reload fixture source." >&2
        status=1
    fi
    if [[ $status -ne 0 ]]; then
        echo "LiveReloadE2E failed with status $status." >&2
        tail -n 80 "$hub_log" 2>/dev/null >&2 || true
        tail -n 80 "$debugger_log" 2>/dev/null >&2 || true
        tail -n 80 "$build_log" 2>/dev/null >&2 || true
    fi
    xcrun simctl terminate "$simulator_udid" "$bundle_id" >/dev/null 2>&1 || true
    if [[ -n "$debugger_pid" ]] && kill -0 "$debugger_pid" 2>/dev/null; then
        kill -TERM "$debugger_pid" 2>/dev/null || true
        wait "$debugger_pid" 2>/dev/null || true
    fi
    if [[ -n "$hub_pid" ]] && kill -0 "$hub_pid" 2>/dev/null; then
        kill -TERM "$hub_pid" 2>/dev/null || true
        wait "$hub_pid" 2>/dev/null || true
    fi
    rm -f "$source_backup"
    exit "$status"
}

restore_baseline_source() {
    local restored_source
    restored_source="$(mktemp "${TMPDIR:-/tmp}/helix-live-reload-baseline.XXXXXX")" \
        || return 1
    if ! cp "$source_backup" "$restored_source" \
        || ! mv "$restored_source" "$source_file"; then
        rm -f "$restored_source"
        return 1
    fi
}

source_backup="$(mktemp "${TMPDIR:-/tmp}/helix-live-reload-source.XXXXXX")"
if ! cp "$source_file" "$source_backup"; then
    rm -f "$source_backup"
    echo "Failed to back up the Live Reload fixture source." >&2
    exit 1
fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
if [[ "$(grep -Fc 'HELIX_E2E_SCENARIO_BEGIN' "$source_file")" -ne 1 ]] \
    || [[ "$(grep -Fc 'HELIX_E2E_SCENARIO_END' "$source_file")" -ne 1 ]]; then
    echo "The fixture source has an invalid scenario replacement region." >&2
    exit 1
fi

wait_for_log() {
    local pattern="$1"
    local timeout_seconds="$2"
    local started=$SECONDS
    while ! grep -Fq "$pattern" "$hub_log" 2>/dev/null; do
        if [[ -n "$hub_pid" ]] && ! kill -0 "$hub_pid" 2>/dev/null; then
            echo "Helix Hub exited before: $pattern" >&2
            tail -n 80 "$hub_log" >&2 || true
            exit 1
        fi
        if (( SECONDS - started >= timeout_seconds )); then
            echo "Timed out waiting for: $pattern" >&2
            tail -n 80 "$hub_log" >&2 || true
            exit 1
        fi
        sleep 0.1
    done
}

wait_for_evidence() {
    local pattern="$1"
    local timeout_seconds="$2"
    local started=$SECONDS
    while ! grep -Fq "$pattern" "$evidence_file" 2>/dev/null; do
        if [[ -n "$app_pid" ]] && ! kill -0 "$app_pid" 2>/dev/null; then
            echo "App exited before observable UI state: $pattern" >&2
            tail -n 20 "$evidence_file" >&2 || true
            exit 1
        fi
        if (( SECONDS - started >= timeout_seconds )); then
            echo "Timed out waiting for observable UI state: $pattern" >&2
            tail -n 20 "$evidence_file" >&2 || true
            exit 1
        fi
        sleep 0.1
    done
}

install_scenario() {
    local scenario_file="$1"
    local generated_source
    if [[ ! -f "$scenario_file" ]]; then
        echo "Missing Live Reload E2E scenario: $scenario_file" >&2
        exit 1
    fi
    generated_source="$(mktemp "${TMPDIR:-/tmp}/helix-live-reload-scenario.XXXXXX")"
    if ! awk -v scenario="$scenario_file" '
        /\/\/ HELIX_E2E_SCENARIO_BEGIN/ {
            print
            while ((getline line < scenario) > 0) print line
            close(scenario)
            replacing = 1
            next
        }
        /\/\/ HELIX_E2E_SCENARIO_END/ {
            replacing = 0
            print
            next
        }
        !replacing { print }
    ' "$source_file" > "$generated_source"; then
        rm -f "$generated_source"
        echo "Failed to install Live Reload E2E scenario: $scenario_file" >&2
        exit 1
    fi
    mv "$generated_source" "$source_file"
}

activate_scenario() {
    local revision="$1"
    local scenario_name="$2"
    local expected_evidence="$3"
    install_scenario "$scenario_directory/$scenario_name.swiftbody"
    wait_for_log "r$revision/g$revision: codeActive" 90
    kill -0 "$app_pid"
    touch "$data_container/Documents/HelixE2ERun-$revision"
    wait_for_evidence "$expected_evidence" 15
    kill -0 "$app_pid"
}

setting() {
    /usr/bin/plutil -extract "0.buildSettings.$1" raw -o - "$build_settings"
}

mkdir -p "$generated_directory"
cd "$repository_root"
swift build --product helix
"$helix" xcode doctor \
    --plan "$script_directory/.helix/xcode/HostPlan.json" \
    --profile live \
    --static
: > "$hub_log"
"$helix" hub run > "$hub_log" 2>&1 &
hub_pid=$!
wait_for_log "Helix is running" 20

xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "id=$simulator_udid" \
    -derivedDataPath "$derived_data" \
    clean build 2>&1 | tee "$build_log" >/dev/null
echo "Built LiveReloadE2EHost."
bonjour_services="$(/usr/bin/plutil -extract NSBonjourServices json -o - "$app/Info.plist")"
if [[ "$bonjour_services" != '["_helix._tcp"]' ]]; then
    echo "Helix did not configure development discovery in the processed App plist." >&2
    exit 1
fi
local_network_description="$({
    /usr/bin/plutil -extract NSLocalNetworkUsageDescription raw -o - "$app/Info.plist"
})"
if [[ -z "$local_network_description" ]]; then
    echo "Helix did not configure the development local-network description." >&2
    exit 1
fi
if /usr/bin/plutil -extract NSBonjourServices raw -o - \
    "$script_directory/Host/Info.plist" >/dev/null 2>&1; then
    echo "Helix modified the fixture's source Info.plist." >&2
    exit 1
fi
if [[ -e "$script_directory/.helix/xcode/ProjectConfigurations/live-Application-Info.plist" ]]; then
    echo "Helix left a stale copied Info.plist in the integration kit." >&2
    exit 1
fi
shell_receipt="$derived_data/Build/Products/Debug-iphonesimulator/HelixGenerated/live/Shell/ShellBuildReceipt.json"
if ! grep -Fq '"logicalPath":"Sources/LiveReloadE2E.Support.swift"' "$shell_receipt"; then
    echo "Helix did not capture the second Feature source automatically." >&2
    exit 1
fi
if grep -Fq 'HelixBuildTrigger_' "$shell_receipt"; then
    echo "Helix leaked its compiler scheduling source into the application Shell." >&2
    exit 1
fi

xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "id=$simulator_udid" \
    -derivedDataPath "$derived_data" \
    -showBuildSettings -json > "$build_settings"

env \
    SRCROOT="$(setting SRCROOT)" \
    BUILD_DIR="$(setting BUILD_DIR)" \
    BUILT_PRODUCTS_DIR="$(setting BUILT_PRODUCTS_DIR)" \
    CONFIGURATION="$(setting CONFIGURATION)" \
    PLATFORM_NAME="$(setting PLATFORM_NAME)" \
    SDKROOT="$(setting SDKROOT)" \
    SDK_DIR="$(setting SDK_DIR)" \
    GENERATED_MODULEMAP_DIR="$(setting GENERATED_MODULEMAP_DIR)" \
    SDK_PRODUCT_BUILD_VERSION="$(setting SDK_PRODUCT_BUILD_VERSION)" \
    XCODE_PRODUCT_BUILD_VERSION="$(setting XCODE_PRODUCT_BUILD_VERSION)" \
    IPHONEOS_DEPLOYMENT_TARGET="$(setting IPHONEOS_DEPLOYMENT_TARGET)" \
    CURRENT_PROJECT_VERSION="$(setting CURRENT_PROJECT_VERSION)" \
    ARCHS="$(setting ARCHS)" \
    TOOLCHAIN_DIR="$(setting TOOLCHAIN_DIR)" \
    TARGET_NAME="$(setting TARGET_NAME)" \
    PRODUCT_BUNDLE_IDENTIFIER="$(setting PRODUCT_BUNDLE_IDENTIFIER)" \
    TARGET_BUILD_DIR="$(setting TARGET_BUILD_DIR)" \
    WRAPPER_NAME="$(setting WRAPPER_NAME)" \
    EXECUTABLE_PATH="$(setting EXECUTABLE_PATH)" \
    MARKETING_VERSION="$(setting MARKETING_VERSION)" \
    HELIX_PROFILE_OUTPUT_DIR="$(setting HELIX_PROFILE_OUTPUT_DIR)" \
    "$helix" xcode phase \
        --plan "$script_directory/HostPlan.json" \
        --profile live \
        --phase live-register

xcrun simctl terminate "$simulator_udid" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl install "$simulator_udid" "$app"
data_container="$(xcrun simctl get_app_container "$simulator_udid" "$bundle_id" data)"
evidence_file="$data_container/Documents/HelixE2EEvidence.txt"
launch_output="$(xcrun simctl launch --wait-for-debugger "$simulator_udid" "$bundle_id")"
app_pid="${launch_output##*: }"
xcrun lldb --batch \
    -o "process attach --pid $app_pid" \
    -o "continue" > "$debugger_log" 2>&1 &
debugger_pid=$!
wait_for_log "Connected process $app_pid on iOSSimulator/arm64." 20

sed -i '' 's/"HELIX BASELINE"/"HELIX PATCHED"/' "$source_file"
wait_for_log "r1/g1: codeActive, UI refreshed." 30
kill -0 "$app_pid"

sed -i '' 's/"HELIX PATCHED"/"HELIX BASELINE"/' "$source_file"
wait_for_log "r2/g2: codeActive, UI refreshed." 30
kill -0 "$app_pid"

activate_scenario 3 ViewHierarchy "transient=true"
xcrun simctl io "$simulator_udid" screenshot \
    "$generated_directory/ViewHierarchy.png" >/dev/null

activate_scenario 4 ButtonConfiguration "button=Configured 2"

activate_scenario 5 Animation "state=animation-complete"

activate_scenario 6 Presentation "presented=HELIX PRESENTED"
xcrun simctl io "$simulator_udid" screenshot \
    "$generated_directory/Presentation.png" >/dev/null

activate_scenario 7 Dismissal "state=dismissed"
xcrun simctl io "$simulator_udid" screenshot \
    "$generated_directory/Dismissal.png" >/dev/null

restore_baseline_source
wait_for_log "r8/g8: codeActive" 90
kill -0 "$app_pid"
touch "$data_container/Documents/HelixE2ERun-8"
wait_for_evidence "state=baseline-action-6" 15
kill -0 "$app_pid"

echo "LiveReloadE2E passed eight generations and five UI scenarios in process $app_pid."
echo "Hub log: $hub_log"
echo "Debugger log: $debugger_log"
echo "Scenario screenshots: $generated_directory"
