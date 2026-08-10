import Foundation
import HelixCore

extension XcodeIntegration {
/// Stable filenames and proxy rendering for exact Xcode Swift invocation capture.
public enum CompilerCapture {
    // Swift Driver selects its mode from argv[0]. The proxy must therefore
    // retain the canonical basename even though it lives in a private output
    // directory distinct from the toolchain.
    public static let proxyFileName = "swiftc"
    public static let invocationFileName = "FrontendInvocation.hlxswiftc"
    public static let recordMarker = Core.CompilerCapture.recordMarker

    public static func proxyScript(realCompilerURL: URL) throws -> Data {
        let path = realCompilerURL.standardizedFileURL.path
        guard realCompilerURL.isFileURL,
              path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              ["swiftc", "swift-driver"].contains(realCompilerURL.lastPathComponent)
        else {
            throw XcodeIntegration.EnvironmentError.invalid(
                name: "HELIX_REAL_SWIFT_EXEC",
                value: path
            )
        }
        let compiler = shellSingleQuoted(path)
        return Data(
            """
            #!/bin/sh
            set -eu
            umask 077

            real_compiler=\(compiler)
            proxy_directory=$(/usr/bin/dirname "$0")
            capture_file="$proxy_directory/\(invocationFileName)"
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
            for argument in "$@"; do
                case "$argument" in
                    -module-name) has_module=true ;;
                    -target) has_target=true ;;
                    -sdk) has_sdk=true ;;
                esac
            done
            if [ "$has_module" = true ] && [ "$has_target" = true ] && [ "$has_sdk" = true ]; then
                temporary=$(/usr/bin/mktemp "$proxy_directory/.FrontendInvocation.XXXXXX")
                {
                    /usr/bin/printf '%s\\0' '\(recordMarker)' "$real_compiler"
                    for argument in "$@"; do
                        /usr/bin/printf '%s\\0' "$argument"
                    done
                } > "$temporary"
                /bin/mv -f "$temporary" "$capture_file"
            fi
            temporary=
            trap - 0 1 2 15

            exec "$real_compiler" "$@"

            """.utf8
        )
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'") + "'"
    }
}
}
