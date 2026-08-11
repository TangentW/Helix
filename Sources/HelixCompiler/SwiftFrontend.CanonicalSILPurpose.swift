import Foundation

extension SwiftFrontend {
/// Distinguishes SIL used to identify an App implementation from SIL used as
/// the portable input of the HLBC lowering pipeline.
public enum CanonicalSILPurpose: Sendable {
    /// Replays the captured optimization settings exactly. Release indexing
    /// and change detection use this representation for stable fingerprints.
    case implementationIdentity

    /// Preserves source-level collection and value operations instead of
    /// exposing Swift standard-library private storage layouts to HLBC.
    case semanticLowering
}
}

extension SwiftFrontend.CanonicalSILPurpose {
    static let semanticPreservationOption = "-disable-sil-perf-optzns"

    func applying(
        to arguments: [String],
        compilerURL: URL
    ) -> [String] {
        guard self == .semanticLowering,
              !Self.containsSemanticPreservationOption(arguments)
        else { return arguments }

        if compilerURL.resolvingSymlinksInPath().lastPathComponent == "swift-frontend" {
            return arguments + [Self.semanticPreservationOption]
        }
        return arguments + ["-Xfrontend", Self.semanticPreservationOption]
    }

    private static func containsSemanticPreservationOption(_ arguments: [String]) -> Bool {
        arguments.contains(semanticPreservationOption)
            || arguments.contains("-Xfrontend=\(semanticPreservationOption)")
    }
}
