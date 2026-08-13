#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVerifier
#endif

public enum VM {}

extension VM {
public enum Metadata {
    public static let version = Core.Versions.runtime
}
}
