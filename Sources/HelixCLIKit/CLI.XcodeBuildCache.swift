import Darwin
import Foundation
import HelixBuildTools
import HelixCompiler
import HelixCore
import HelixInterface

extension CLI {
struct XcodePrepareInput: Codable, Sendable {
    struct Source: Codable, Sendable {
        var logicalPath: String
        var physicalPath: String
        var contentHash: Core.Digest
    }

    struct NativeAPICatalogIdentity: Codable, Sendable {
        var document: NativeAPICatalog.Document
        var compilerProjectionSHA256: Core.Digest
    }

    var schemaVersion: UInt16 = 1
    var profileID: String
    var featureID: String
    var compilerCaptureSHA256: Core.Digest
    var toolchain: ReleaseCompiler.ToolchainIdentity
    var compilerInputs: BuildCache.CompilerInputs.Snapshot
    var metadata: InterfaceArchive.ReleaseMetadata
    var configuration: PatchConfiguration.Document
    var nativeImportCatalog: NativeImportCatalog.Document
    var nativeAPICatalogs: [NativeAPICatalogIdentity]
    var callingSurfacePolicy: FrontendReceipt.CallingSurfacePolicy
    var sources: [Source]
}

struct XcodeBridgeInput: Codable, Sendable {
    struct File: Codable, Sendable {
        var path: String
        var contentHash: Core.Digest
    }

    struct AdapterObject: Codable, Sendable {
        var moduleName: String
        var inputHash: Core.Digest
    }

    struct HubContractObject: Codable, Sendable {
        var compilerArguments: [String]
        var compilerInputs: BuildCache.CompilerInputs.Snapshot
    }

    var schemaVersion: UInt16 = 1
    var profileID: String
    var transformPipelineHash: Core.Digest
    var toolchain: ReleaseCompiler.ToolchainIdentity
    var clangCompilerPath: String
    var clangCompilerHash: Core.Digest
    var xcodeBuild: String
    var sdkBuild: String
    var compilerArguments: [String]
    var compilerInputs: BuildCache.CompilerInputs.Snapshot
    var generatedSources: [ShellBuild.Artifact]
    var adapterObjects: [AdapterObject]
    var hubContractObject: HubContractObject?
    var moduleMaps: [File]
    var bootstrapSource: String
}

/// Exact semantic identity of the stable, application-specific Bridge object.
/// Invitation-specific development sources are deliberately absent and are
/// compiled as a separate object before the final relocatable link.
struct XcodeApplicationObjectInput: Codable, Sendable {
    var schemaVersion: UInt16 = 1
    var profileID: String
    var transformPipelineHash: Core.Digest
    var toolchain: ReleaseCompiler.ToolchainIdentity
    var xcodeBuild: String
    var sdkBuild: String
    var compilerArguments: [String]
    var compilerInputs: BuildCache.CompilerInputs.Snapshot
    var generatedSources: [ShellBuild.Artifact]
    var moduleMaps: [XcodeBridgeInput.File]
}
}

extension CLI.Application {
func hotPatchPrepareSourcesMatch(
    _ sources: [CLI.XcodePrepareInput.Source]
) -> Bool {
    sources.allSatisfy { source in
        guard let data = try? readRegularFile(
            URL(fileURLWithPath: source.physicalPath),
            maximumBytes: 64 * 1_024 * 1_024,
            label: "Hot Patch Prepare source confirmation"
        ) else { return false }
        return Core.Digest.sha256(data) == source.contentHash
    }
}

func makeHotPatchPrepareIdentity(
    context: XcodeIntegration.BuildContext,
    capture: XcodeFeatureCapture,
    compilerInputs: BuildCache.CompilerInputs.Snapshot,
    metadata: InterfaceArchive.ReleaseMetadata,
    configuration: PatchConfiguration.Document,
    toolchain: ReleaseCompiler.ToolchainIdentity,
    nativeAPICatalogs: [NativeAPICatalog.Snapshot]
) throws -> (
    inputHash: Core.Digest,
    sources: [CLI.XcodePrepareInput.Source]
) {
    let sources = try capture.frontendSources.sorted {
        $0.logicalPath < $1.logicalPath
    }.map { source -> CLI.XcodePrepareInput.Source in
        let url = source.url.resolvingSymlinksInPath().standardizedFileURL
        let data = try readRegularFile(
            url,
            maximumBytes: 64 * 1_024 * 1_024,
            label: "Hot Patch Prepare source"
        )
        return .init(
            logicalPath: source.logicalPath,
            physicalPath: url.path,
            contentHash: .sha256(data)
        )
    }
    let catalogIdentities = try nativeAPICatalogs.map {
        CLI.XcodePrepareInput.NativeAPICatalogIdentity(
            document: $0.document,
            compilerProjectionSHA256: try $0.compilerProjectionDigest()
        )
    }
    let input = CLI.XcodePrepareInput(
        profileID: context.profile.id,
        featureID: context.feature.id,
        compilerCaptureSHA256: .sha256(capture.recordBytes),
        toolchain: toolchain,
        compilerInputs: compilerInputs,
        metadata: metadata,
        configuration: configuration,
        nativeImportCatalog: .empty,
        nativeAPICatalogs: catalogIdentities,
        callingSurfacePolicy: .managedProductionModule,
        sources: sources
    )
    return (
        try BuildCache.key(
            domain: "HLX.Xcode.PrepareInput.v1",
            value: input
        ),
        sources
    )
}

func loadXcodeBridgeState(
    context: XcodeIntegration.BuildContext,
    expectedInputHash: Core.Digest
) -> XcodeIntegration.BridgeState? {
    let stateURL = context.environment.bridgeOutputURL.appendingPathComponent(
        XcodeIntegration.BridgeState.relativePath
    )
    guard let data = try? readRegularFile(
        stateURL,
        maximumBytes: XcodeIntegration.BridgeStateCodec.maximumDocumentBytes,
        label: "hidden Bridge state"
    ), let state = try? XcodeIntegration.BridgeStateCodec.decode(data),
       state.inputHash == expectedInputHash,
       (try? validateXcodeObject(
           context.environment.bridgeObjectURL,
           context: context,
           label: "cached hidden Bridge"
       )) != nil,
       (try? validateXcodeObject(
           context.environment.bootstrapObjectURL,
           context: context,
           label: "cached hidden bootstrap"
       )) != nil,
       bridgeObjectMatches(
           state.bridge,
           at: context.environment.bridgeObjectURL
       ),
       bridgeObjectMatches(
           state.bootstrap,
           at: context.environment.bootstrapObjectURL
       )
    else { return nil }
    return state
}

func bridgeObjectMatches(
    _ expected: XcodeIntegration.BridgeState.Object,
    at url: URL
) -> Bool {
    guard let maximumBytes = Int(exactly: expected.byteCount),
          let data = try? readRegularFile(
              url,
              maximumBytes: maximumBytes,
              label: "cached hidden object"
          )
    else { return false }
    return UInt64(data.count) == expected.byteCount
        && Core.Digest.sha256(data) == expected.contentHash
}

func loadHotPatchPrepareState(
    context: XcodeIntegration.BuildContext,
    expectedInputHash: Core.Digest
) -> XcodeIntegration.PrepareState? {
    let url = context.environment.profileOutputURL.appendingPathComponent(
        XcodeIntegration.PrepareState.relativePath
    )
    guard let data = try? readRegularFile(
        url,
        maximumBytes: XcodeIntegration.PrepareStateCodec.maximumDocumentBytes,
        label: "Hot Patch Prepare state"
    ), let state = try? XcodeIntegration.PrepareStateCodec.decode(data),
       state.inputHash == expectedInputHash,
       preparedShellMatches(
           state.artifacts,
           at: context.environment.shellOutputURL
       )
    else { return nil }
    return state
}

func preparedShellMatches(
    _ artifacts: [XcodeIntegration.PrepareState.Artifact],
    at root: URL
) -> Bool {
    var rootInformation = Darwin.stat()
    guard lstat(root.path, &rootInformation) == 0,
          rootInformation.st_mode & S_IFMT == S_IFDIR
    else { return false }
    let byPath = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.path, $0) })
    var expected = Set(byPath.keys)
    for path in byPath.keys {
        var current = ""
        for component in path.split(separator: "/").dropLast() {
            current = current.isEmpty
                ? String(component) : "\(current)/\(component)"
            expected.insert(current)
        }
    }
    guard let subpaths = CLI.DirectoryContents.exactSubpaths(
        of: root,
        expected: expected
    ) else { return false }
    for path in subpaths {
        let url = root.appendingPathComponent(path)
        if let artifact = byPath[path] {
            guard preparedArtifactMatches(artifact, at: url) else { return false }
        } else {
            var information = Darwin.stat()
            guard lstat(url.path, &information) == 0,
                  information.st_mode & S_IFMT == S_IFDIR
            else { return false }
        }
    }
    return true
}

func preparedArtifactMatches(
    _ artifact: XcodeIntegration.PrepareState.Artifact,
    at url: URL
) -> Bool {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var information = Darwin.stat()
    guard fstat(descriptor, &information) == 0,
          information.st_mode & S_IFMT == S_IFREG,
          information.st_mode & 0o777 == artifact.permissions,
          information.st_size >= 0,
          UInt64(information.st_size) == artifact.byteCount,
          artifact.byteCount <= UInt64(512 * 1_024 * 1_024)
    else { return false }
    do {
        let data = try handle.readToEnd() ?? Data()
        return UInt64(data.count) == artifact.byteCount
            && Core.Digest.sha256(data) == artifact.contentHash
    } catch {
        return false
    }
}

func privatePathsForPreparedShell(
    hubReservation: XcodeIntegration.HubReservationDocument?
) -> Set<String> {
    Set([
        XcodeIntegration.CompilerCapture.shellRelativeInvocationPath,
    ] + (hubReservation == nil ? [] : [
        XcodeIntegration.HubReservationDocument.relativePath,
    ]))
}

func xcodeBuildCacheStore() -> BuildCache.Store? {
    BuildCache.defaultStore(environment: environment)
}

func bridgeGeneratedSourcesMatch(
    _ artifacts: [ShellBuild.Artifact],
    at urls: [URL]
) -> Bool {
    guard artifacts.count == urls.count else { return false }
    return zip(artifacts, urls).allSatisfy { artifact, url in
        guard let maximumBytes = Int(exactly: artifact.byteCount),
              let data = try? readRegularFile(
                  url,
                  maximumBytes: maximumBytes,
                  label: "generated Bridge source confirmation"
              )
        else { return false }
        return UInt64(data.count) == artifact.byteCount
            && Core.Digest.sha256(data) == artifact.contentHash
    }
}
}
