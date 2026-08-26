import Foundation
import HelixCompiler
import HelixCore

/// Canonical, cacheable source Pack for pure Swift adapters owned by one
/// imported module. The Pack identity excludes application paths and transient
/// NativeImport IDs so identical SDK/dependency APIs can be shared by projects.
public enum NativeAdapterPack {}

extension NativeAdapterPack {
public struct Identity: Codable, Hashable, Sendable {
    public var schemaVersion: UInt16 = 1
    public var compilerFingerprint: String
    public var sdkBuild: String
    public var targetTriple: String
    public var minimumDeployment: Core.SemanticVersion
    public var transformPipelineHash: Core.Digest
    public var moduleName: String
    public var importedModules: [String]
    public var keys: [Core.NativeCall.Key]

    public init(
        compilerFingerprint: String,
        sdkBuild: String,
        targetTriple: String,
        minimumDeployment: Core.SemanticVersion,
        transformPipelineHash: Core.Digest,
        moduleName: String,
        importedModules: [String],
        keys: [Core.NativeCall.Key]
    ) {
        self.compilerFingerprint = compilerFingerprint
        self.sdkBuild = sdkBuild
        self.targetTriple = targetTriple
        self.minimumDeployment = minimumDeployment
        self.transformPipelineHash = transformPipelineHash
        self.moduleName = moduleName
        self.importedModules = Array(Set(importedModules)).sorted()
        self.keys = keys.sorted()
    }

    public var cacheKey: Core.Digest {
        var hasher = Core.StableHasher(domain: "HLX.AdapterPack.v1")
        hasher.append(schemaVersion)
        hasher.append(compilerFingerprint)
        hasher.append(sdkBuild)
        hasher.append(targetTriple)
        hasher.append(minimumDeployment.description)
        hasher.append(transformPipelineHash)
        hasher.append(moduleName)
        hasher.append(UInt64(importedModules.count))
        for module in importedModules { hasher.append(module) }
        hasher.append(UInt64(keys.count))
        for key in keys { hasher.append(key.rawValue) }
        return hasher.finalize()
    }

    public func validate() throws {
        guard schemaVersion == 1,
              Self.isBound(compilerFingerprint, maximum: 64 * 1_024),
              Self.isToken(sdkBuild, maximum: 256),
              Self.isToken(targetTriple, maximum: 512),
              Self.isModulePath(moduleName),
              importedModules == importedModules.sorted(),
              Set(importedModules).count == importedModules.count,
              importedModules.contains(moduleName),
              importedModules.count <= 1_024,
              importedModules.allSatisfy(Self.isModulePath),
              keys == keys.sorted(),
              Set(keys).count == keys.count,
              !keys.isEmpty,
              keys.count <= 250_000
        else {
            throw NativeAdapterPack.Error.invalid
        }
    }

    private static func isModulePath(_ value: String) -> Bool {
        !value.isEmpty && value.split(
            separator: ".",
            omittingEmptySubsequences: false
        ).allSatisfy { component in
            guard let first = component.first,
                  first == "_" || first.isLetter
            else { return false }
            return component.dropFirst().allSatisfy {
                $0 == "_" || $0.isLetter || $0.isNumber
            }
        }
    }

    private static func isBound(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func isToken(_ value: String, maximum: Int) -> Bool {
        isBound(value, maximum: maximum)
            && value.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7f }
    }
}

public struct Document: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var identity: NativeAdapterPack.Identity
    public var sourcePath: String
    public var sourceHash: Core.Digest
    public var sourceByteCount: UInt64

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        identity: NativeAdapterPack.Identity,
        sourcePath: String,
        source: String
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.sourcePath = sourcePath
        let bytes = Data(source.utf8)
        sourceHash = .sha256(bytes)
        sourceByteCount = UInt64(bytes.count)
    }

    public func validate(source: String) throws {
        try identity.validate()
        let bytes = Data(source.utf8)
        guard schemaVersion == Self.currentSchemaVersion,
              sourcePath == BridgeGeneration.Generator.adapterPackSourcePath(
                  moduleName: identity.moduleName
              ),
              sourcePath.hasPrefix("Generated/AdapterPacks/"),
              sourcePath.hasSuffix(".swift"),
              sourceByteCount > 0,
              sourceByteCount <= UInt64(64 * 1_024 * 1_024),
              UInt64(bytes.count) == sourceByteCount,
              Core.Digest.sha256(bytes) == sourceHash,
              !source.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw NativeAdapterPack.Error.invalid
        }
    }
}

struct CachedArtifact: Codable, Sendable {
    var document: NativeAdapterPack.Document
    var source: String

    func validated() throws -> Self {
        try document.validate(source: source)
        return self
    }

    func validated(
        against expectedDocument: NativeAdapterPack.Document,
        source expectedSource: String
    ) throws -> Self {
        _ = try validated()
        guard document == expectedDocument, source == expectedSource else {
            throw NativeAdapterPack.Error.invalid
        }
        return self
    }
}

public enum Error: Swift.Error, Equatable, Sendable {
    case invalid
    case nonCanonical
}

enum Codec {
    static let maximumBytes = 80 * 1_024 * 1_024

    static func encode(_ artifact: CachedArtifact) throws -> Data {
        _ = try artifact.validated()
        return try Core.CanonicalJSON.encode(artifact)
    }

    static func decode(_ data: Data) throws -> CachedArtifact {
        guard !data.isEmpty, data.count <= maximumBytes,
              let artifact = try? JSONDecoder().decode(
                  CachedArtifact.self,
                  from: data
              )
        else { throw NativeAdapterPack.Error.invalid }
        guard try Core.CanonicalJSON.encode(artifact) == data else {
            throw NativeAdapterPack.Error.nonCanonical
        }
        return try artifact.validated()
    }
}
}
