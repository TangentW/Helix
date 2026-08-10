import Foundation
import HelixCore
import HelixInterface

extension ShellBuild {
public struct MetadataRequest: Hashable, Sendable {
    public var bundleID: String
    public var buildNumber: String
    public var namespaceSeed: String
    public var minimumOS: Core.SemanticVersion
    public var xcodeBuild: String
    public var frontendInvocation: InterfaceArchive.FrontendInvocation

    public init(
        bundleID: String,
        buildNumber: String,
        namespaceSeed: String,
        minimumOS: Core.SemanticVersion,
        xcodeBuild: String,
        frontendInvocation: InterfaceArchive.FrontendInvocation
    ) {
        self.bundleID = bundleID
        self.buildNumber = buildNumber
        self.namespaceSeed = namespaceSeed
        self.minimumOS = minimumOS
        self.xcodeBuild = xcodeBuild
        self.frontendInvocation = frontendInvocation
    }
}

public struct MetadataFactory: Sendable {
    public init() {}

    public func make(
        _ request: ShellBuild.MetadataRequest
    ) throws -> InterfaceArchive.ReleaseMetadata {
        try validateIdentity(request)
        try request.frontendInvocation.validate()
        guard Self.targetMinimumOS(request.frontendInvocation.targetTriple)
            == request.minimumOS else {
            throw ShellBuild.Error.invalidInput(
                "target triple and minimum deployment version disagree"
            )
        }
        let placeholder = try Core.Digest(
            bytes: repeatElement(UInt8(0), count: Core.Digest.byteCount)
        )
        return InterfaceArchive.ReleaseMetadata(
            bundleID: request.bundleID,
            buildNumber: request.buildNumber,
            shellNamespaceID: .derive(
                bundleID: request.bundleID,
                buildNumber: request.buildNumber,
                seed: request.namespaceSeed
            ),
            machOUUIDs: [],
            targetTriple: request.frontendInvocation.targetTriple,
            minimumOS: request.minimumOS,
            xcodeBuild: request.xcodeBuild,
            sdkBuild: request.frontendInvocation.sdkBuild,
            frontendInvocation: request.frontendInvocation,
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: placeholder
        )
    }

    private func validateIdentity(_ request: ShellBuild.MetadataRequest) throws {
        guard Self.isBundleID(request.bundleID),
              Self.isBuildComponent(request.buildNumber, maximumBytes: 128),
              Self.isBuildComponent(request.xcodeBuild, maximumBytes: 64),
              !request.namespaceSeed.isEmpty,
              request.namespaceSeed.utf8.count <= 256,
              !request.namespaceSeed.unicodeScalars.contains(where: { $0.value == 0 }),
              request.minimumOS.major > 0
        else {
            throw ShellBuild.Error.invalidInput("release metadata identity is invalid")
        }
    }

    private static func targetMinimumOS(_ target: String) -> Core.SemanticVersion? {
        guard let platform = target.split(separator: "-").first(where: {
            $0.hasPrefix("ios")
        }) else {
            return nil
        }
        return try? Core.SemanticVersion(parsing: String(platform.dropFirst(3)))
    }

    private static func isBundleID(_ value: String) -> Bool {
        guard value.utf8.count <= 255 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy {
                (48...57).contains($0)
                    || (65...90).contains($0)
                    || (97...122).contains($0)
                    || $0 == 45
            }
        }
    }

    private static func isBuildComponent(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && value.utf8.allSatisfy {
            (48...57).contains($0)
                || (65...90).contains($0)
                || (97...122).contains($0)
                || $0 == 45
                || $0 == 46
        }
    }
}
}
