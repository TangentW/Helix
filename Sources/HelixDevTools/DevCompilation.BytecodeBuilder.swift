import Foundation
import HelixBuildTools
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixInterface
import HelixLiveReloadAPI

public enum DevCompilation {}

extension DevCompilation {
/// Compiles a stable development source revision through the same canonical
/// SIL and HLBC path used by release patches.
public actor BytecodeBuilder {
    private static let maximumPendingCapabilityTransactions = 64

    public let archive: InterfaceArchive.Archive
    public let manifest: DevBuildManifest.Document
    public let receipt: ShellBuildReceipt.Document?
    public let compilerURL: URL
    public let requestedResources: Core.ResourceLimits

    private let driver: ReleaseCompiler.Driver
    private let adapterBuild: @Sendable (
        DevCompilation.AdapterBuildRequest
    ) throws -> DevCompilation.AdapterImage
    private let adapterOutputDirectory: URL?
    private var activeFunctions: Set<Core.FunctionKey>
    private var activeDevelopmentKeys: Set<Core.NativeCall.Key>
    private var pendingDevelopmentKeys: [
        DevProtocol.GenerationID: Set<Core.NativeCall.Key>
    ] = [:]

    public init(
        archive: InterfaceArchive.Archive,
        manifest: DevBuildManifest.Document,
        receipt: ShellBuildReceipt.Document? = nil,
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        adapterOutputDirectory: URL? = nil,
        adapterCache: BuildCache.Store? = nil,
        requestedResources: Core.ResourceLimits = .init(),
        initiallyActiveFunctions: Set<Core.FunctionKey> = [],
        initiallyActiveDevelopmentKeys: Set<Core.NativeCall.Key> = [],
        adapterBuild: (@Sendable (
            DevCompilation.AdapterBuildRequest
        ) throws -> DevCompilation.AdapterImage)? = nil,
        driver: ReleaseCompiler.Driver = .init()
    ) {
        self.archive = archive
        self.manifest = manifest
        self.receipt = receipt
        self.compilerURL = compilerURL
        self.adapterOutputDirectory = adapterOutputDirectory
        self.requestedResources = requestedResources
        self.driver = driver
        self.adapterBuild = adapterBuild ?? { request in
            try DevCompilation.DefaultAdapterBuilder(
                runner: ProcessExecution.Runner(),
                cache: adapterCache
            ).build(request)
        }
        activeFunctions = initiallyActiveFunctions
        activeDevelopmentKeys = initiallyActiveDevelopmentKeys
    }

    public func build(
        _ request: DevSession.BuildRequest
    ) async throws -> DevSession.BuildOutcome {
        do {
            try validateFrozenInputs()
        } catch {
            return .rebuildRequired(
                diagnostic(
                    code: "HLXLR301",
                    message: String(describing: error),
                    request: request,
                    nextAction: "rebuild the Dev Shell so its manifest and HLXI are regenerated together"
                )
            )
        }

        try validate(request)

        do {
            let capabilityPlan = try makeNativeCapabilityPlan()
            let result = try driver.build(
                .init(
                    archive: archive,
                    sourceFiles: manifest.sourceFiles.map {
                        URL(fileURLWithPath: $0.absolutePath)
                    },
                    selectedFunctionKeys: request.candidateFunctionKeys,
                    compilerURL: compilerURL,
                    enforceToolchainFingerprint: true,
                    requestedResources: requestedResources,
                    developmentNativeImports:
                        capabilityPlan?.developmentImports ?? []
                )
            )
            let replacements = Set(result.changedFunctions.map(\.key))
            let restorations = activeFunctions
                .intersection(request.candidateFunctionKeys)
                .subtracting(replacements)
            // Reject a compiler result if any captured file changed while the
            // frontend was reading the module.
            try validate(request)
            let payload = try makeDevelopmentPayload(
                result: result,
                capabilityPlan: capabilityPlan,
                generationID: request.generationID
            )
            return .patch(
                .init(
                    backend: .hlbc,
                    payload: payload,
                    changedFunctions: replacements.union(restorations),
                    restoredFunctions: restorations
                )
            )
        } catch ReleaseCompiler.DriverError.noSemanticChanges {
            try validate(request)
            let restorations = activeFunctions.intersection(request.candidateFunctionKeys)
            guard !restorations.isEmpty else { return .noSemanticChange }
            return .patch(
                .init(
                    backend: .hlbc,
                    payload: Data(),
                    changedFunctions: restorations,
                    restoredFunctions: restorations,
                    mode: .restoreOriginals
                )
            )
        } catch let error as ReleaseCompiler.DriverError {
            return map(error, request: request)
        } catch let error as SwiftFrontend.Error {
            return try map(error, request: request)
        } catch let error as DevCompilation.NativeCapabilityError {
            return try map(error, request: request)
        } catch let diagnostic as DevProtocol.Diagnostic {
            throw diagnostic
        } catch {
            throw diagnostic(
                code: "HLXLR299",
                message: String(describing: error),
                request: request,
                nextAction: "inspect the HLBC compiler diagnostic and save the corrected source"
            )
        }
    }

    /// Advances compiler-side route state only after the App confirms activation.
    @discardableResult
    public func didActivate(_ offer: DevProtocol.PatchOffer) -> Bool {
        guard offer.sessionID == manifest.sessionBuildID, offer.backend == .hlbc else {
            return false
        }
        let restored = Set(offer.restoredFunctions)
        activeFunctions.subtract(restored)
        activeFunctions.formUnion(Set(offer.changedFunctions).subtracting(restored))
        if let additions = pendingDevelopmentKeys.removeValue(
            forKey: offer.generationID
        ) {
            activeDevelopmentKeys.formUnion(additions)
        }
        pendingDevelopmentKeys = pendingDevelopmentKeys.filter {
            $0.key > offer.generationID
        }
        return true
    }

    public var activeFunctionKeys: Set<Core.FunctionKey> {
        activeFunctions
    }

    public var activeNativeCallKeys: Set<Core.NativeCall.Key> {
        activeDevelopmentKeys
    }

    private func validateFrozenInputs() throws {
        try archive.validate()
        try manifest.validate()

        let invocation = archive.metadata.frontendInvocation
        let archivedSources = Dictionary(
            uniqueKeysWithValues: archive.sources.map { ($0.logicalPath, $0) }
        )
        let manifestSources = Dictionary(
            uniqueKeysWithValues: manifest.sourceFiles.map { ($0.logicalPath, $0) }
        )
        guard archive.metadata.bundleID == manifest.bundleID,
              archive.metadata.machOUUIDs.contains(manifest.executableUUID),
              archive.metadata.targetTriple == manifest.targetTriple,
              archive.metadata.minimumOS == manifest.minimumOS,
              archive.metadata.xcodeBuild == manifest.xcodeBuild,
              archive.metadata.sdkBuild == manifest.sdkBuild,
              archive.compatibility.compilerFingerprint == manifest.swiftCompilerFingerprint,
              invocation.moduleName == manifest.moduleName,
              invocation.targetTriple == manifest.targetTriple,
              invocation.sdkBuild == manifest.sdkBuild,
              invocation.optimization == "-Onone"
        else {
            throw ContractError.identityMismatch
        }
        guard Set(archivedSources.keys) == Set(manifestSources.keys) else {
            throw ContractError.sourceMembershipMismatch
        }
        for (logicalPath, archived) in archivedSources {
            guard let source = manifestSources[logicalPath],
                  source.contentHash == archived.contentHash,
                  source.id == LiveReload.SourceFileID.derive(logicalPath: logicalPath)
            else {
                throw ContractError.sourceBaselineMismatch(logicalPath)
            }
        }
        let eligibleKeys = Set(archive.functions.filter(\.patchability.isEligible).map(\.key))
        guard activeFunctions.isSubset(of: eligibleKeys) else {
            throw ContractError.invalidActiveFunctionState
        }
        let candidateKeys = Set(archive.nativeImports.map(\.key))
        guard activeDevelopmentKeys.isSubset(of: candidateKeys) else {
            throw ContractError.invalidActiveNativeState
        }
        if archive.nativeImports.contains(where: { !$0.isEmittedToDevice }),
           receipt == nil {
            throw ContractError.missingNativeCapabilityReceipt
        }
    }

    private func makeNativeCapabilityPlan() throws
        -> DevCompilation.NativeCapabilityPlan?
    {
        guard let receipt else { return nil }
        return try .init(archive: archive, receipt: receipt)
    }

    private func makeDevelopmentPayload(
        result: ReleaseCompiler.BuildResult,
        capabilityPlan: DevCompilation.NativeCapabilityPlan?,
        generationID: DevProtocol.GenerationID
    ) throws -> Data {
        let baselineKeys = capabilityPlan?.baselineKeys
            ?? Set(archive.nativeImports.filter(\.isEmittedToDevice).map(\.key))
        let requirements = result.module.imports.filter {
            !baselineKeys.contains($0.key)
        }.sorted { $0.id < $1.id }
        guard !requirements.isEmpty else {
            return try DevProtocol.DevelopmentPayload.Artifact(
                shellInterfaceHash: archive.shellInterfaceHash,
                compilerFingerprint: manifest.swiftCompilerFingerprint,
                sdkBuild: manifest.sdkBuild,
                targetTriple: manifest.targetTriple,
                bytecode: result.bytecode
            ).encoded()
        }
        guard let capabilityPlan else {
            throw DevCompilation.NativeCapabilityError.receiptMismatch
        }

        var records: [InterfaceArchive.NativeImportRecord] = []
        var bindings: [ShellBuildReceipt.NativeImportBinding] = []
        for requirement in requirements {
            let record = try capabilityPlan.record(for: requirement)
            records.append(record)
            bindings.append(try capabilityPlan.binding(for: record))
        }
        let newSwiftPairs = Array(zip(records, bindings)).filter { pair in
            pair.1.strategy == .generatedSwiftAdapter
                && !activeDevelopmentKeys.contains(pair.0.key)
        }
        let adapterImage: DevCompilation.AdapterImage?
        if newSwiftPairs.isEmpty {
            adapterImage = nil
        } else {
            guard let adapterOutputDirectory else {
                throw DevCompilation.NativeCapabilityError
                    .invalidAdapterRequest
            }
            adapterImage = try adapterBuild(
                .init(
                    manifest: manifest,
                    compilerURL: compilerURL,
                    outputDirectory: adapterOutputDirectory,
                    records: newSwiftPairs.map(\.0),
                    bindings: try newSwiftPairs.map {
                        try $0.1.bridgeBinding(for: $0.0)
                    }
                )
            )
            guard let adapterImage,
                  !adapterImage.bytes.isEmpty,
                  Set(adapterImage.keys) == Set(newSwiftPairs.map(\.0.key)),
                  adapterImage.descriptor.installName
                    == adapterImage.installName
            else {
                throw DevCompilation.NativeCapabilityError.invalidAdapterImage(
                    "Adapter builder returned the wrong NativeCall set or image identity"
                )
            }
        }
        let imageDescriptor = try adapterImage.map { image in
            guard let uuid = image.descriptor.uuid else {
                throw DevCompilation.NativeCapabilityError.invalidAdapterImage(
                    "Adapter has no Mach-O UUID"
                )
            }
            return DevProtocol.DevelopmentPayload.Image(
                installName: image.installName,
                uuid: uuid,
                byteLength: UInt64(image.bytes.count),
                sha256: .sha256(image.bytes)
            )
        }
        let newlyBuiltKeys = Set(adapterImage?.keys ?? [])
        let nativeImports = try zip(records, bindings).map { record, binding in
            let isNewSwift = newlyBuiltKeys.contains(record.key)
            let payloadBinding: DevProtocol.DevelopmentPayload.Binding
            switch binding.strategy {
            case .objectiveCInvoker:
                payloadBinding = .objectiveCInvoker
            case .cInvoker:
                payloadBinding = .cInvoker
            case .generatedSwiftAdapter:
                payloadBinding = .swiftAdapter
            case .factory:
                throw DevCompilation.NativeCapabilityError
                    .unsupportedDevelopmentBinding(record.canonicalCallee)
            }
            guard let id = record.id else {
                throw DevCompilation.NativeCapabilityError
                    .compilerResultMismatch(record.key)
            }
            return DevProtocol.DevelopmentPayload.NativeImport(
                id: id,
                key: record.key,
                descriptor: record.descriptor,
                parameterTypes: record.parameterTypes,
                resultType: record.resultType,
                contract: record.contract,
                capability: record.capability,
                binding: payloadBinding,
                imageIndex: isNewSwift ? 0 : nil,
                exportSymbol: isNewSwift
                    ? BridgeGeneration.GeneratedNativeImport.exportSymbol(
                        key: record.key
                    ) : nil
            )
        }
        let artifact = DevProtocol.DevelopmentPayload.Artifact(
            shellInterfaceHash: archive.shellInterfaceHash,
            compilerFingerprint: manifest.swiftCompilerFingerprint,
            sdkBuild: manifest.sdkBuild,
            targetTriple: manifest.targetTriple,
            bytecode: result.bytecode,
            nativeImports: nativeImports,
            imageDescriptors: imageDescriptor.map { [$0] } ?? [],
            images: adapterImage.map { [$0.bytes] } ?? []
        )
        let payload = try artifact.encoded()
        recordPendingDevelopmentKeys(
            Set(records.map(\.key)).subtracting(activeDevelopmentKeys),
            for: generationID
        )
        return payload
    }

    private func recordPendingDevelopmentKeys(
        _ keys: Set<Core.NativeCall.Key>,
        for generationID: DevProtocol.GenerationID
    ) {
        guard !keys.isEmpty else {
            pendingDevelopmentKeys.removeValue(forKey: generationID)
            return
        }
        pendingDevelopmentKeys[generationID] = keys
        let stale = pendingDevelopmentKeys.keys.sorted().dropLast(
            Self.maximumPendingCapabilityTransactions
        )
        for generationID in stale {
            pendingDevelopmentKeys.removeValue(forKey: generationID)
        }
    }

    private func validate(_ request: DevSession.BuildRequest) throws {
        guard request.snapshot.revision.rawValue > 0,
              request.generationID.rawValue > 0,
              !request.snapshot.files.isEmpty,
              !request.candidateFunctionKeys.isEmpty
        else {
            throw diagnostic(
                code: "HLXLR205",
                message: "the compile request has no revision, source snapshot, or patchable roots",
                request: request,
                nextAction: "rebuild the Reload Index if this source should be reloadable"
            )
        }

        let byID = Dictionary(uniqueKeysWithValues: manifest.sourceFiles.map { ($0.id, $0) })
        let snapshotIDs = Set(request.snapshot.files.map(\.id))
        guard snapshotIDs.count == request.snapshot.files.count,
              Set(request.classification.changedFiles).isSubset(of: snapshotIDs),
              Set(request.classification.restoredToBaseline)
                .isSubset(of: request.classification.changedFiles)
        else {
            throw diagnostic(
                code: "HLXLR205",
                message: "the snapshot classification is inconsistent with its captured files",
                request: request,
                nextAction: "discard this compile and capture the source transaction again"
            )
        }

        for file in request.snapshot.files {
            let normalizedPath = URL(fileURLWithPath: file.absolutePath).standardizedFileURL.path
            guard let frozen = byID[file.id],
                  frozen.logicalPath == file.logicalPath,
                  URL(fileURLWithPath: frozen.absolutePath).standardizedFileURL.path == normalizedPath,
                  file.contentHash == .sha256(file.contents)
            else {
                throw diagnostic(
                    code: "HLXLR205",
                    message: "captured source \(file.logicalPath) does not match the Dev Manifest",
                    request: request,
                    nextAction: "discard this compile and rebuild the Dev Shell if source membership changed"
                )
            }
            let current = try Data(
                contentsOf: URL(fileURLWithPath: frozen.absolutePath),
                options: .mappedIfSafe
            )
            guard Core.Digest.sha256(current) == file.contentHash else {
                throw diagnostic(
                    code: "HLXLR206",
                    message: "source \(file.logicalPath) changed after its stable snapshot",
                    request: request,
                    nextAction: "wait for the newest save transaction"
                )
            }
        }
    }

    private func map(
        _ error: ReleaseCompiler.DriverError,
        request: DevSession.BuildRequest
    ) -> DevSession.BuildOutcome {
        let code: String
        let action: String
        switch error {
        case .changedIneligibleFunction, .functionMissingFromSIL,
             .loweredSignatureChanged, .generatedFunctionUnsupported:
            code = "HLXLR303"
            action = "rebuild the Dev Shell because its captured Swift interface or value layout changed"
        case .toolchainMismatch, .compilerIdentityFailed:
            code = "HLXLR304"
            action = "select the exact Xcode toolchain used by the Dev Shell, then rebuild if unavailable"
        case .emptySourceSet, .sourceDoesNotExist, .sourceSetMismatch, .mixedModules, .unknownFunction:
            code = "HLXLR302"
            action = "rebuild the Dev Shell because its source membership or Reload Index is stale"
        case .noSemanticChanges:
            return .noSemanticChange
        }
        return .rebuildRequired(
            diagnostic(
                code: code,
                message: error.description,
                request: request,
                nextAction: action
            )
        )
    }

    private func map(
        _ error: SwiftFrontend.Error,
        request: DevSession.BuildRequest
    ) throws -> DevSession.BuildOutcome {
        switch error {
        case let .compilationFailed(_, diagnostics):
            throw diagnostic(
                code: "HLXLR202",
                message: bounded(diagnostics.isEmpty ? error.description : diagnostics),
                request: request,
                nextAction: "fix the Swift diagnostic; the previous generation remains active"
            )
        case .sdkBuildMismatch, .executableNotFound:
            return .rebuildRequired(
                diagnostic(
                    code: "HLXLR304",
                    message: error.description,
                    request: request,
                    nextAction: "restore the exact Xcode, SDK, and Swift compiler used by the Dev Shell"
                )
            )
        case .launchFailed, .invalidUTF8Output, .symbolGraphFailed,
             .invalidSymbolGraph, .sdkResolutionFailed:
            throw diagnostic(
                code: "HLXLR203",
                message: bounded(error.description),
                request: request,
                nextAction: "repair the local Swift toolchain and save again"
            )
        }
    }

    private func map(
        _ error: DevCompilation.NativeCapabilityError,
        request: DevSession.BuildRequest
    ) throws -> DevSession.BuildOutcome {
        switch error {
        case .receiptMismatch, .tooManyImports, .missingBinding,
             .unsupportedDevelopmentBinding, .invalidAdapterRequest,
             .deviceAdapterUnqualified:
            return .rebuildRequired(
                diagnostic(
                    code: "HLXLR306",
                    message: error.description,
                    request: request,
                    nextAction: "rebuild the App when the required native capability cannot be added to this development process"
                )
            )
        case .compilerResultMismatch, .adapterCompilationFailed,
             .adapterSigningFailed, .invalidAdapterImage:
            throw diagnostic(
                code: "HLXLR207",
                message: error.description,
                request: request,
                nextAction: "fix the Adapter diagnostic and save again; the previous generation remains active"
            )
        }
    }

    private func diagnostic(
        code: String,
        message: String,
        request: DevSession.BuildRequest,
        nextAction: String
    ) -> DevProtocol.Diagnostic {
        .init(
            code: code,
            message: bounded(message),
            sourceRevision: request.snapshot.revision,
            generationID: request.generationID,
            backend: .hlbc,
            previousCodeRemainsActive: true,
            nextAction: nextAction
        )
    }

    private func bounded(_ value: String) -> String {
        let data = Data(value.utf8)
        guard data.count > 60 * 1_024 else {
            return value.isEmpty ? "Swift compiler emitted an empty diagnostic" : value
        }
        return String(decoding: data.prefix(60 * 1_024), as: UTF8.self)
    }
}
}

private enum ContractError: Error, CustomStringConvertible {
    case identityMismatch
    case sourceMembershipMismatch
    case sourceBaselineMismatch(String)
    case invalidActiveFunctionState
    case invalidActiveNativeState
    case missingNativeCapabilityReceipt

    var description: String {
        switch self {
        case .identityMismatch:
            "Dev Manifest and HLXI have different process, toolchain, target, or module identities"
        case .sourceMembershipMismatch:
            "Dev Manifest and HLXI contain different Swift source sets"
        case let .sourceBaselineMismatch(path):
            "Dev Manifest and HLXI disagree on the baseline identity of \(path)"
        case .invalidActiveFunctionState:
            "the restored Dev Session references a function that is not patchable in HLXI"
        case .invalidActiveNativeState:
            "the restored Dev Session references a native call that is absent from HLXI"
        case .missingNativeCapabilityReceipt:
            "HLXI contains development NativeImport candidates but no Shell Build Receipt"
        }
    }
}
