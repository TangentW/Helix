import Foundation
import HelixCore

extension XcodeIntegration {
/// Completion marker for one audited, distributable App build. Quick Patch
/// consumes this captured build identity without rebuilding the App or redefining the
/// source baseline after an incident edit.
public struct ReleaseBaseline: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var profileID: String
    public var bundleID: String
    public var marketingVersion: String
    public var buildNumber: String
    public var configurationName: String
    public var moduleName: String
    public var targetTriple: String
    public var minimumOS: Core.SemanticVersion
    public var xcodeBuild: String
    public var sdkBuild: String
    public var swiftCompilerFingerprint: String
    public var machOUUIDs: [UUID]
    public var shellInterfaceHash: Core.Digest
    public var interfaceArchiveSHA256: Core.Digest
    public var executableSHA256: Core.Digest
    public var releaseAuditSHA256: Core.Digest
    public var createdAtUnixSeconds: Int64

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        profileID: String,
        bundleID: String,
        marketingVersion: String,
        buildNumber: String,
        configurationName: String,
        moduleName: String,
        targetTriple: String,
        minimumOS: Core.SemanticVersion,
        xcodeBuild: String,
        sdkBuild: String,
        swiftCompilerFingerprint: String,
        machOUUIDs: [UUID],
        shellInterfaceHash: Core.Digest,
        interfaceArchiveSHA256: Core.Digest,
        executableSHA256: Core.Digest,
        releaseAuditSHA256: Core.Digest,
        createdAtUnixSeconds: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.bundleID = bundleID
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.configurationName = configurationName
        self.moduleName = moduleName
        self.targetTriple = targetTriple
        self.minimumOS = minimumOS
        self.xcodeBuild = xcodeBuild
        self.sdkBuild = sdkBuild
        self.swiftCompilerFingerprint = swiftCompilerFingerprint
        self.machOUUIDs = machOUUIDs.sorted { $0.uuidString < $1.uuidString }
        self.shellInterfaceHash = shellInterfaceHash
        self.interfaceArchiveSHA256 = interfaceArchiveSHA256
        self.executableSHA256 = executableSHA256
        self.releaseAuditSHA256 = releaseAuditSHA256
        self.createdAtUnixSeconds = createdAtUnixSeconds
    }

    public func validate() throws {
        let values = [
            profileID, bundleID, marketingVersion, buildNumber,
            configurationName, moduleName, targetTriple, xcodeBuild, sdkBuild,
            swiftCompilerFingerprint,
        ]
        guard schemaVersion == Self.currentSchemaVersion,
              values.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 4_096
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              }),
              !machOUUIDs.isEmpty,
              machOUUIDs.count <= 32,
              Set(machOUUIDs).count == machOUUIDs.count,
              machOUUIDs == machOUUIDs.sorted(by: { $0.uuidString < $1.uuidString }),
              createdAtUnixSeconds > 0,
              (try? Core.SemanticVersion(parsing: marketingVersion)) != nil
        else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "invalid audited Release baseline receipt"
            )
        }
    }
}

public enum ReleaseBaselineCodec {
    public static let maximumDocumentBytes = 1 * 1_024 * 1_024

    public static func encode(_ receipt: XcodeIntegration.ReleaseBaseline) throws -> Data {
        try receipt.validate()
        return try Core.CanonicalJSON.encode(receipt)
    }

    public static func decode(_ data: Data) throws -> XcodeIntegration.ReleaseBaseline {
        guard data.count <= maximumDocumentBytes else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "Release baseline receipt exceeds 1 MiB"
            )
        }
        let receipt: XcodeIntegration.ReleaseBaseline
        do {
            receipt = try JSONDecoder().decode(
                XcodeIntegration.ReleaseBaseline.self,
                from: data
            )
        } catch {
            throw XcodeIntegration.Error.invalidHostPlan(
                "Release baseline receipt JSON decoding failed"
            )
        }
        guard try Core.CanonicalJSON.encode(receipt) == data else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "Release baseline receipt is not canonical"
            )
        }
        try receipt.validate()
        return receipt
    }
}
}
