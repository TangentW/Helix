import Foundation
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI

public enum DevBuildManifest {}

extension DevBuildManifest {
public struct SourceFile: Codable, Hashable, Sendable {
    public var id: LiveReload.SourceFileID
    public var logicalPath: String
    public var absolutePath: String
    public var contentHash: Core.Digest
    /// The basename Swift used for this source while emitting the shell module.
    /// It can differ from the editable basename when Xcode compiles a materialized
    /// Helix source. Older manifests omit it and therefore use the logical basename.
    public var privateImportSourceFile: String?

    public init(
        id: LiveReload.SourceFileID,
        logicalPath: String,
        absolutePath: String,
        contentHash: Core.Digest,
        privateImportSourceFile: String? = nil
    ) {
        self.id = id
        self.logicalPath = logicalPath
        self.absolutePath = absolutePath
        self.contentHash = contentHash
        self.privateImportSourceFile = privateImportSourceFile
    }

    public var effectivePrivateImportSourceFile: String {
        privateImportSourceFile
            ?? URL(fileURLWithPath: logicalPath).lastPathComponent
    }
}

public struct Product: Codable, Hashable, Sendable {
    public var kind: String
    public var path: String
    public var contentHash: Core.Digest?

    public init(kind: String, path: String, contentHash: Core.Digest? = nil) {
        self.kind = kind
        self.path = path
        self.contentHash = contentHash
    }
}

public struct ToolchainCapabilities: Codable, Hashable, Sendable {
    public var implicitDynamic: Bool
    public var privateImports: Bool
    public var dynamicReplacementChaining: Bool
    public var nativeInterposing: Bool
    public var canonicalSIL: Bool

    public init(
        implicitDynamic: Bool,
        privateImports: Bool,
        dynamicReplacementChaining: Bool,
        nativeInterposing: Bool,
        canonicalSIL: Bool
    ) {
        self.implicitDynamic = implicitDynamic
        self.privateImports = privateImports
        self.dynamicReplacementChaining = dynamicReplacementChaining
        self.nativeInterposing = nativeInterposing
        self.canonicalSIL = canonicalSIL
    }
}

public struct Document: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public var schemaVersion: UInt32
    public var sessionBuildID: UUID
    public var workspacePathHash: Core.Digest
    public var scheme: String
    public var configuration: String
    public var bundleID: String
    public var executableUUID: UUID
    public var moduleName: String
    public var targetTriple: String
    public var architecture: String
    public var platform: DevProtocol.ApplePlatform
    public var minimumOS: Core.SemanticVersion
    public var xcodeBuild: String
    public var swiftCompilerFingerprint: String
    public var sdkBuild: String
    public var frontendArguments: [String]
    public var linkArguments: [String]
    public var moduleSearchPaths: [String]
    public var sourceFiles: [DevBuildManifest.SourceFile]
    public var buildProducts: [DevBuildManifest.Product]
    public var expandedCodeSignIdentity: String?
    public var teamIdentifier: String?
    public var entitlementsHash: Core.Digest?
    public var liveReloadIndexHash: Core.Digest
    public var dependencyGraphHash: Core.Digest
    public var toolchainCapabilities: DevBuildManifest.ToolchainCapabilities

    public init(
        schemaVersion: UInt32 = Self.currentSchemaVersion,
        sessionBuildID: UUID,
        workspacePathHash: Core.Digest,
        scheme: String,
        configuration: String,
        bundleID: String,
        executableUUID: UUID,
        moduleName: String,
        targetTriple: String,
        architecture: String,
        platform: DevProtocol.ApplePlatform,
        minimumOS: Core.SemanticVersion,
        xcodeBuild: String,
        swiftCompilerFingerprint: String,
        sdkBuild: String,
        frontendArguments: [String],
        linkArguments: [String],
        moduleSearchPaths: [String],
        sourceFiles: [DevBuildManifest.SourceFile],
        buildProducts: [DevBuildManifest.Product],
        expandedCodeSignIdentity: String? = nil,
        teamIdentifier: String? = nil,
        entitlementsHash: Core.Digest? = nil,
        liveReloadIndexHash: Core.Digest,
        dependencyGraphHash: Core.Digest,
        toolchainCapabilities: DevBuildManifest.ToolchainCapabilities
    ) {
        self.schemaVersion = schemaVersion
        self.sessionBuildID = sessionBuildID
        self.workspacePathHash = workspacePathHash
        self.scheme = scheme
        self.configuration = configuration
        self.bundleID = bundleID
        self.executableUUID = executableUUID
        self.moduleName = moduleName
        self.targetTriple = targetTriple
        self.architecture = architecture
        self.platform = platform
        self.minimumOS = minimumOS
        self.xcodeBuild = xcodeBuild
        self.swiftCompilerFingerprint = swiftCompilerFingerprint
        self.sdkBuild = sdkBuild
        self.frontendArguments = frontendArguments
        self.linkArguments = linkArguments
        self.moduleSearchPaths = moduleSearchPaths
        self.sourceFiles = sourceFiles
        self.buildProducts = buildProducts
        self.expandedCodeSignIdentity = expandedCodeSignIdentity
        self.teamIdentifier = teamIdentifier
        self.entitlementsHash = entitlementsHash
        self.liveReloadIndexHash = liveReloadIndexHash
        self.dependencyGraphHash = dependencyGraphHash
        self.toolchainCapabilities = toolchainCapabilities
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BuildCapture.Error.invalidManifest("unsupported schema \(schemaVersion)")
        }
        guard !scheme.isEmpty, !configuration.isEmpty, !bundleID.isEmpty,
              !moduleName.isEmpty, !targetTriple.isEmpty, !architecture.isEmpty,
              !xcodeBuild.isEmpty, !swiftCompilerFingerprint.isEmpty, !sdkBuild.isEmpty
        else {
            throw BuildCapture.Error.invalidManifest("required build identity is missing")
        }
        guard !frontendArguments.isEmpty, !sourceFiles.isEmpty else {
            throw BuildCapture.Error.invalidManifest("frontend arguments or sources are empty")
        }
        guard frontendArguments.count <= 65_536,
              linkArguments.count <= 65_536,
              moduleSearchPaths.count <= 16_384,
              sourceFiles.count <= 65_536,
              buildProducts.count <= 65_536,
              frontendArguments.reduce(0, { $0 + $1.utf8.count }) <= 8 * 1_024 * 1_024,
              linkArguments.reduce(0, { $0 + $1.utf8.count }) <= 8 * 1_024 * 1_024,
              !frontendArguments.contains(where: containsNull),
              !linkArguments.contains(where: containsNull)
        else {
            throw BuildCapture.Error.invalidManifest("build inputs exceed limits or contain NUL")
        }
        guard Set(sourceFiles.map(\.id)).count == sourceFiles.count,
              Set(sourceFiles.map(\.logicalPath)).count == sourceFiles.count,
              Set(sourceFiles.map(\.absolutePath)).count == sourceFiles.count
        else {
            throw BuildCapture.Error.invalidManifest("duplicate source identity")
        }
        guard sourceFiles.allSatisfy({
            Self.isSafeLogicalPath($0.logicalPath)
                && $0.logicalPath.hasSuffix(".swift")
                && $0.absolutePath.hasPrefix("/")
                && $0.absolutePath.hasSuffix(".swift")
                && !$0.absolutePath.unicodeScalars.contains(where: { $0.value == 0 })
                && $0.effectivePrivateImportSourceFile.hasSuffix(".swift")
                && URL(fileURLWithPath: $0.effectivePrivateImportSourceFile).lastPathComponent
                    == $0.effectivePrivateImportSourceFile
                && $0.effectivePrivateImportSourceFile.utf8.count <= 1_024
                && !$0.effectivePrivateImportSourceFile.unicodeScalars.contains(
                    where: { $0.value == 0 }
                )
                && $0.id == LiveReload.SourceFileID.derive(logicalPath: $0.logicalPath)
        }) else {
            throw BuildCapture.Error.invalidManifest(
                "source identity is not derived from a safe logical and absolute Swift path"
            )
        }
        guard moduleSearchPaths.allSatisfy({
            $0.hasPrefix("/") && !$0.unicodeScalars.contains(where: { $0.value == 0 })
        }), buildProducts.allSatisfy({
            !$0.kind.isEmpty && $0.kind.utf8.count <= 256
                && $0.path.hasPrefix("/")
                && !$0.path.unicodeScalars.contains(where: { $0.value == 0 })
        }) else {
            throw BuildCapture.Error.invalidManifest("build product or module search path is invalid")
        }
        guard let capturedModule = try Self.uniqueValue(after: "-module-name", in: frontendArguments),
              let capturedTarget = try Self.uniqueValue(after: "-target", in: frontendArguments),
              let sdkPath = try Self.uniqueValue(after: "-sdk", in: frontendArguments),
              capturedModule == moduleName,
              capturedTarget == targetTriple,
              sdkPath.hasPrefix("/")
        else {
            throw BuildCapture.Error.invalidManifest(
                "captured frontend module, target, or SDK does not match the manifest"
            )
        }
        let target = targetTriple.lowercased()
        let targetMatchesPlatform: Bool
        switch platform {
        case .iOS:
            targetMatchesPlatform = target.contains("-apple-ios")
                && !target.contains("simulator")
        case .iOSSimulator:
            targetMatchesPlatform = target.contains("-apple-ios")
                && target.contains("simulator")
        case .macOS:
            targetMatchesPlatform = target.contains("-apple-macos")
        }
        guard targetMatchesPlatform,
              targetTriple.hasPrefix("\(architecture)-"),
              ["arm64", "arm64e", "x86_64"].contains(architecture)
        else {
            throw BuildCapture.Error.invalidManifest(
                "target triple, platform, and architecture disagree"
            )
        }
        guard frontendArguments.contains("-Onone") else {
            throw BuildCapture.Error.invalidManifest("Dev Shell frontend job is not -Onone")
        }
        guard toolchainCapabilities.implicitDynamic,
              frontendArguments.contains("-enable-implicit-dynamic")
        else {
            throw BuildCapture.Error.invalidManifest("module is not prepared for dynamic replacement")
        }
        guard toolchainCapabilities.canonicalSIL else {
            throw BuildCapture.Error.invalidManifest(
                "the exact toolchain did not pass the canonical SIL probe"
            )
        }
    }

    public func staleness(comparedWith current: Self) -> [DevBuildManifest.Change] {
        var changes: [DevBuildManifest.Change] = []
        if xcodeBuild != current.xcodeBuild { changes.append(.xcodeBuild) }
        if swiftCompilerFingerprint != current.swiftCompilerFingerprint { changes.append(.swiftCompiler) }
        if sdkBuild != current.sdkBuild { changes.append(.sdk) }
        if targetTriple != current.targetTriple { changes.append(.targetTriple) }
        if frontendArguments != current.frontendArguments { changes.append(.frontendArguments) }
        if linkArguments != current.linkArguments { changes.append(.linkArguments) }
        if dependencyGraphHash != current.dependencyGraphHash { changes.append(.dependencies) }
        if entitlementsHash != current.entitlementsHash { changes.append(.entitlements) }
        if executableUUID != current.executableUUID { changes.append(.executable) }
        if sourceFiles.map(\.logicalPath) != current.sourceFiles.map(\.logicalPath) {
            changes.append(.sourceMembership)
        }
        return changes
    }

    private static func uniqueValue(
        after flag: String,
        in arguments: [String]
    ) throws -> String? {
        let indices = arguments.indices.filter { arguments[$0] == flag }
        guard indices.count == 1, let index = indices.first, index + 1 < arguments.count else {
            throw BuildCapture.Error.invalidManifest(
                "captured frontend must contain exactly one \(flag)"
            )
        }
        let value = arguments[index + 1]
        guard !value.isEmpty, !value.hasPrefix("-") else {
            throw BuildCapture.Error.invalidManifest("\(flag) has no value")
        }
        return value
    }

    private static func isSafeLogicalPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..") && !components.contains("")
    }

    private func containsNull(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0 }
    }
}

public enum Change: String, Codable, Hashable, Sendable {
    case xcodeBuild
    case swiftCompiler
    case sdk
    case targetTriple
    case frontendArguments
    case linkArguments
    case dependencies
    case entitlements
    case executable
    case sourceMembership
}
}

extension BuildCapture {
public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case noActivityLog
    case noFrontendCommand
    case malformedCommand(String)
    case missingArgument(String)
    case responseFileCycle(String)
    case responseFileTooDeep
    case invalidManifest(String)
    case replayFailed(String)

    public var description: String {
        switch self {
        case .noActivityLog: "no Xcode activity log was found"
        case .noFrontendCommand: "activity log contains no Swift frontend command"
        case let .malformedCommand(reason): "malformed frontend command: \(reason)"
        case let .missingArgument(flag): "frontend command is missing \(flag)"
        case let .responseFileCycle(path): "response file cycle at \(path)"
        case .responseFileTooDeep: "response file nesting exceeds the safety limit"
        case let .invalidManifest(reason): "invalid Dev Build Manifest: \(reason)"
        case let .replayFailed(reason): "frontend replay probe failed: \(reason)"
        }
    }
}
}
