import Foundation
import HelixCore

extension XcodeIntegration {
/// Stable filenames and proxy rendering for exact Xcode Swift invocation capture.
public enum CompilerCapture {
    // Swift Driver selects its mode from argv[0]. The proxy must retain the
    // canonical basename even though it is generated outside the toolchain.
    public static let proxyFileName = "swiftc"
    public static let integrationProxyPath = "Scripts/Compiler/\(proxyFileName)"
    public static let invocationFileName = "FrontendInvocation.hlxswiftc"
    public static let shellRelativeInvocationPath =
        "Compiler/\(invocationFileName)"
    public static let targetTriggerDirectory = "Compiler/Targets"
    public static let recordMarker = Core.CompilerCapture.recordMarker

    public static func profileProxyPath(profileID: String) -> String {
        "Profiles/\(profileID)/Compiler/\(proxyFileName)"
    }

    public static func profilePostCompilePath(profileID: String) -> String {
        "Profiles/\(profileID)/Compiler/post-compile.sh"
    }

    /// One inert source per Xcode target forces Swift Driver to run before the
    /// target-level compiler proxy performs its post-compile work. Sharing the
    /// trigger across profiles prevents workflow-specific generated sources
    /// from leaking into every configuration of the same target.
    public static func targetTriggerPath(targetName: String) -> String {
        let suffix = Core.Digest.sha256(targetName).hex.prefix(24)
        return "\(targetTriggerDirectory)/HelixBuildTrigger_\(suffix).swift"
    }

    public static func isTargetTriggerLogicalPath(
        _ logicalPath: String,
        integrationRoot: String
    ) -> Bool {
        let prefix = "\(integrationRoot)/\(targetTriggerDirectory)/"
        guard logicalPath.hasPrefix(prefix) else { return false }
        let name = logicalPath.dropFirst(prefix.count)
        return !name.contains("/")
            && name.hasPrefix("HelixBuildTrigger_")
            && name.hasSuffix(".swift")
    }

    /// The proxy is toolchain-independent so it exists before the first clean
    /// Feature build. It derives a target-private capture directory from
    /// Swift Driver's own output paths because XCBuild does not export custom
    /// build settings to a custom compiler process.
    public static func proxyScript(
        postCompileScriptName: String? = nil
    ) -> Data {
        let postCompile: String
        if let postCompileScriptName {
            postCompile = """
                script_directory=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
                /bin/sh "$script_directory/\(postCompileScriptName)" "$capture_file"
            """
        } else {
            postCompile = ""
        }
        return Data(
            """
            #!/bin/sh
            set -eu
            umask 077

            # XCBuild queries a custom SWIFT_EXEC before it creates a target
            # build environment. Forward those discovery calls through xcrun;
            # real target compilation supplies the exact selected toolchain.
            real_compiler="${HELIX_REAL_SWIFT_EXEC:-}"
            if [ -z "$real_compiler" ]; then
                real_compiler=$(/usr/bin/xcrun --find swiftc)
            fi
            case "$real_compiler" in
                /*/swiftc|/*/swift-driver) ;;
                *)
                    echo "error: HELIX_REAL_SWIFT_EXEC is not an absolute Swift compiler" >&2
                    exit 2
                    ;;
            esac
            if [ ! -x "$real_compiler" ]; then
                echo "error: Helix cannot execute the selected Swift compiler" >&2
                exit 2
            fi
            temporary=

            cleanup() {
                if [ -n "$temporary" ]; then
                    /bin/rm -f "$temporary"
                fi
            }
            trap cleanup 0 1 2 15

            has_module=false
            has_target=false
            has_sdk=false
            next_output=
            output_file_map=
            module_output=
            for argument in "$@"; do
                if [ -n "$next_output" ]; then
                    if [ "$next_output" = map ]; then
                        output_file_map="$argument"
                    else
                        module_output="$argument"
                    fi
                    next_output=
                    continue
                fi
                case "$argument" in
                    -module-name) has_module=true ;;
                    -target) has_target=true ;;
                    -sdk) has_sdk=true ;;
                    -output-file-map) next_output=map ;;
                    -output-file-map=*) output_file_map="${argument#*=}" ;;
                    -emit-module-path) next_output=module ;;
                    -emit-module-path=*) module_output="${argument#*=}" ;;
                esac
            done
            should_capture=false
            if [ "$has_module" = true ] && [ "$has_target" = true ] && [ "$has_sdk" = true ]; then
                compiler_output="${output_file_map:-$module_output}"
                case "$compiler_output" in
                    /*) ;;
                    *)
                        echo "error: Helix cannot locate the Xcode Swift object directory" >&2
                        exit 2
                        ;;
                esac
                architecture_directory=$(/usr/bin/dirname "$compiler_output")
                objects_directory=$(/usr/bin/dirname "$architecture_directory")
                case $(/usr/bin/basename "$objects_directory") in
                    Objects-*) ;;
                    *)
                        echo "error: Helix received an unexpected Xcode Swift output path" >&2
                        exit 2
                        ;;
                esac
                should_capture=true
                proxy_directory="$(/usr/bin/dirname "$objects_directory")/Helix"
                capture_file="$proxy_directory/\(invocationFileName)"
                /bin/mkdir -p "$proxy_directory"
            fi
            set +e
            "$real_compiler" "$@"
            compiler_status=$?
            set -e
            if [ "$compiler_status" -ne 0 ]; then
                exit "$compiler_status"
            fi

            if [ "$should_capture" = true ]; then
                temporary=$(/usr/bin/mktemp "$proxy_directory/.FrontendInvocation.XXXXXX")
                {
                    /usr/bin/printf '%s\\0' '\(recordMarker)' "$real_compiler"
                    for argument in "$@"; do
                        /usr/bin/printf '%s\\0' "$argument"
                    done
                } > "$temporary"
                /bin/mv -f "$temporary" "$capture_file"
            \(postCompile)
            fi
            temporary=
            trap - 0 1 2 15
            exit 0

            """.utf8
        )
    }
}
}
