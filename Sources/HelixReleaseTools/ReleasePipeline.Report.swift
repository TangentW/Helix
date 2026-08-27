import Foundation
import HelixCore

extension ReleasePipeline {
public struct ChangedFunction: Codable, Hashable, Sendable {
    public var functionKey: Core.FunctionKey
    public var entryIndex: Core.EntryIndex
    public var declaration: String
    public var bodyFingerprint: Core.Digest

    public init(
        functionKey: Core.FunctionKey,
        entryIndex: Core.EntryIndex,
        declaration: String,
        bodyFingerprint: Core.Digest
    ) {
        self.functionKey = functionKey
        self.entryIndex = entryIndex
        self.declaration = declaration
        self.bodyFingerprint = bodyFingerprint
    }
}

public struct Report: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var packageID: String
    public var packageSHA256: Core.Digest
    public var packageByteLength: UInt64
    public var bytecodeSHA256: Core.Digest
    public var bytecodeByteLength: UInt64
    public var shellInterfaceHash: Core.Digest
    public var nativeCapabilityManifestHash: Core.Digest
    public var toolchainFingerprint: String
    public var capabilities: [Core.Capability]
    public var changedFunctions: [ReleasePipeline.ChangedFunction]
    public var signingKeyID: String
    public var signingRootKeyID: String

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        packageID: String,
        packageSHA256: Core.Digest,
        packageByteLength: UInt64,
        bytecodeSHA256: Core.Digest,
        bytecodeByteLength: UInt64,
        shellInterfaceHash: Core.Digest,
        nativeCapabilityManifestHash: Core.Digest,
        toolchainFingerprint: String,
        capabilities: [Core.Capability],
        changedFunctions: [ReleasePipeline.ChangedFunction],
        signingKeyID: String,
        signingRootKeyID: String
    ) {
        self.schemaVersion = schemaVersion
        self.packageID = packageID
        self.packageSHA256 = packageSHA256
        self.packageByteLength = packageByteLength
        self.bytecodeSHA256 = bytecodeSHA256
        self.bytecodeByteLength = bytecodeByteLength
        self.shellInterfaceHash = shellInterfaceHash
        self.nativeCapabilityManifestHash = nativeCapabilityManifestHash
        self.toolchainFingerprint = toolchainFingerprint
        self.capabilities = capabilities
        self.changedFunctions = changedFunctions
        self.signingKeyID = signingKeyID
        self.signingRootKeyID = signingRootKeyID
    }
}
}
