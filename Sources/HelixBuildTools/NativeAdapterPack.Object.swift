import Foundation
import HelixCompiler
import HelixCore

extension NativeAdapterPack {
/// Complete identity of one compiled Adapter Pack object. Source Packs are
/// project-independent; executable objects additionally depend on the exact
/// compiler invocation and every non-SDK module interface visible to it.
public struct ObjectIdentity: Codable, Hashable, Sendable {
    public struct InputFile: Codable, Hashable, Sendable {
        public var path: String
        public var contentHash: Core.Digest

        public init(path: String, contentHash: Core.Digest) {
            self.path = path
            self.contentHash = contentHash
        }
    }

    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var pack: NativeAdapterPack.Identity
    public var sourceHash: Core.Digest
    public var compilerModuleName: String
    public var toolchain: ReleaseCompiler.ToolchainIdentity
    public var xcodeBuild: String
    public var compilerArguments: [String]
    public var compilerInputs: BuildCache.CompilerInputs.Snapshot
    public var moduleMaps: [InputFile]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        pack: NativeAdapterPack.Identity,
        sourceHash: Core.Digest,
        compilerModuleName: String,
        toolchain: ReleaseCompiler.ToolchainIdentity,
        xcodeBuild: String,
        compilerArguments: [String],
        compilerInputs: BuildCache.CompilerInputs.Snapshot,
        moduleMaps: [InputFile]
    ) {
        self.schemaVersion = schemaVersion
        self.pack = pack
        self.sourceHash = sourceHash
        self.compilerModuleName = compilerModuleName
        self.toolchain = toolchain
        self.xcodeBuild = xcodeBuild
        self.compilerArguments = compilerArguments
        self.compilerInputs = compilerInputs
        self.moduleMaps = moduleMaps.sorted { $0.path < $1.path }
    }

    public func validate() throws {
        try pack.validate()
        guard schemaVersion == Self.currentSchemaVersion,
              compilerModuleName == XcodeIntegration.AdapterPackCompilationPlanner
                .compilerModuleName(for: pack),
              Self.isToken(xcodeBuild, maximum: 256),
              compilerArguments.count <= 65_536,
              compilerArguments.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 64 * 1_024
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              }),
              !compilerArguments.contains("-o"),
              compilerArguments.contains("<helix-adapter-pack-source>"),
              compilerInputs.schemaVersion
                == BuildCache.CompilerInputs.Snapshot.currentSchemaVersion,
              compilerInputs.isComplete,
              compilerInputs.importedModules
                == Array(Set(compilerInputs.importedModules)).sorted(),
              moduleMaps == moduleMaps.sorted(by: { $0.path < $1.path }),
              Set(moduleMaps.map(\.path)).count == moduleMaps.count,
              moduleMaps.count <= 64,
              moduleMaps.allSatisfy({
                  $0.path.hasPrefix("/") && $0.path.hasSuffix(".modulemap")
                      && $0.path.utf8.count <= 64 * 1_024
                      && !$0.path.unicodeScalars.contains(where: {
                          $0.value == 0
                      })
              })
        else {
            throw NativeAdapterPack.Error.invalid
        }
    }

    public func cacheKey() throws -> Core.Digest {
        try validate()
        return try BuildCache.key(
            domain: "HLX.AdapterPack.Object.v1",
            value: self
        )
    }

    private static func isToken(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7f }
    }
}
}
