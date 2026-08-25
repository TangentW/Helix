#if os(macOS)
import Foundation

extension Hub {
/// Adds local-development discovery declarations to the processed App plist.
///
/// Xcode's source plist and generated-plist settings remain authoritative. The
/// generated phase declares the processed plist as its input, runs before
/// signing, and is scoped to the selected configuration. Helix's generated
/// xcconfig grants the dynamic phase its required script access.
struct DevelopmentNetworkConfiguration {
    static let serviceType = "_helix._tcp"
    static let usageDescription =
        "Helix connects this development build to the Mac on your local network."

    func script(configurationName: String) -> String {
        let configuration = shellLiteral(configurationName)
        let service = shellLiteral(Self.serviceType)
        let description = shellLiteral(Self.usageDescription)
        return """
        set -eu
        if [ "${CONFIGURATION:-}" != \(configuration) ]; then
            exit 0
        fi

        info_plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
        build_root=$(CDPATH= cd -- "${TARGET_BUILD_DIR:?}" && pwd -P)
        info_directory=$(CDPATH= cd -- "$(/usr/bin/dirname "$info_plist")" && pwd -P)
        info_plist="$info_directory/$(/usr/bin/basename "$info_plist")"
        case "$info_plist" in
            "$build_root"/*) ;;
            *) echo "error: Helix resolved an Info.plist outside the target build directory" >&2; exit 1 ;;
        esac
        if [ ! -f "$info_plist" ] || [ -L "$info_plist" ]; then
            echo "error: Helix requires the processed App Info.plist before development setup" >&2
            exit 1
        fi

        service_type=$(/usr/bin/plutil -type NSBonjourServices "$info_plist" 2>/dev/null || true)
        case "$service_type" in
            '')
                /usr/bin/plutil -insert NSBonjourServices -json '["\(Self.serviceType)"]' "$info_plist"
                ;;
            array)
                service_count=$(/usr/bin/plutil -extract NSBonjourServices raw -o - "$info_plist")
                case "$service_count" in
                    ''|*[!0-9]*) echo "error: malformed NSBonjourServices in processed Info.plist" >&2; exit 1 ;;
                esac
                service_index=0
                service_found=0
                while [ "$service_index" -lt "$service_count" ]; do
                    current_service=$(/usr/bin/plutil -extract "NSBonjourServices.$service_index" raw -o - "$info_plist")
                    if [ "$current_service" = \(service) ]; then
                        service_found=1
                    fi
                    service_index=$((service_index + 1))
                done
                if [ "$service_found" -eq 0 ]; then
                    /usr/bin/plutil -insert NSBonjourServices -string \(service) -append "$info_plist"
                fi
                ;;
            *)
                echo "error: NSBonjourServices must be an array in the processed Info.plist" >&2
                exit 1
                ;;
        esac

        description_type=$(/usr/bin/plutil -type NSLocalNetworkUsageDescription "$info_plist" 2>/dev/null || true)
        case "$description_type" in
            '')
                /usr/bin/plutil -insert NSLocalNetworkUsageDescription -string \(description) "$info_plist"
                ;;
            string)
                current_description=$(/usr/bin/plutil -extract NSLocalNetworkUsageDescription raw -o - "$info_plist")
                if [ -z "$current_description" ]; then
                    /usr/bin/plutil -replace NSLocalNetworkUsageDescription -string \(description) "$info_plist"
                fi
                ;;
            *)
                echo "error: NSLocalNetworkUsageDescription must be a string in the processed Info.plist" >&2
                exit 1
                ;;
        esac
        """
    }

    private func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
}
#endif
