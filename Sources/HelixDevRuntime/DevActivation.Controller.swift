import CryptoKit
import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI
import HelixRuntime
import HelixVerifier
import HelixVM
#endif

/// Validation, transfer, and activation primitives for development generations.
public enum DevActivation {}

extension DevActivation {
/// Resource ceilings for a single development-session activation controller.
///
/// Native images cannot be safely unloaded from a running Swift process, so both
/// their count and cumulative mapped bytes are bounded for the App lifetime.
public struct Limits: Hashable, Sendable {
    /// Maximum accepted byte length for one Native Dynamic Replacement image.
    public var maximumNativePayloadBytes: Int
    /// Maximum accepted byte length for one HLBC payload.
    public var maximumHLBCPayloadBytes: Int
    /// Hard limit for native images mapped during this process lifetime.
    public var maximumNativeImageCount: Int
    /// Image count at which diagnostics recommend restarting the Dev App.
    public var nativeImageSoftWarningCount: Int
    /// Hard limit for cumulative mapped native-image bytes.
    public var maximumNativeMappedBytes: Int

    /// Creates resource ceilings with conservative development defaults.
    public init(
        maximumNativePayloadBytes: Int = 64 * 1_024 * 1_024,
        maximumHLBCPayloadBytes: Int = 64 * 1_024 * 1_024,
        maximumNativeImageCount: Int = 80,
        nativeImageSoftWarningCount: Int = 50,
        maximumNativeMappedBytes: Int = 256 * 1_024 * 1_024
    ) {
        self.maximumNativePayloadBytes = maximumNativePayloadBytes
        self.maximumHLBCPayloadBytes = maximumHLBCPayloadBytes
        self.maximumNativeImageCount = maximumNativeImageCount
        self.nativeImageSoftWarningCount = nativeImageSoftWarningCount
        self.maximumNativeMappedBytes = maximumNativeMappedBytes
    }

    /// Validates that limits are positive and internally consistent.
    public func validate() throws {
        guard maximumNativePayloadBytes > 0,
              maximumHLBCPayloadBytes > 0,
              maximumNativeImageCount > 0,
              maximumNativeImageCount <= Int(UInt32.max),
              nativeImageSoftWarningCount > 0,
              nativeImageSoftWarningCount <= maximumNativeImageCount,
              maximumNativeMappedBytes >= maximumNativePayloadBytes
        else {
            throw DevActivation.ConfigurationError.invalidLimits
        }
    }
}

/// Invalid setup detected before a development activation session starts.
public enum ConfigurationError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// A payload, count, warning, or cumulative byte limit is inconsistent.
    case invalidLimits
    /// The native image cache is not a non-empty local file URL.
    case invalidCacheDirectory
    /// Runtime and generated Shell do not share the same interface/registry.
    case runtimeMismatch

    /// Human-readable configuration failure detail.
    public var description: String {
        switch self {
        case .invalidLimits: "Dev activation limits are inconsistent or nonpositive"
        case .invalidCacheDirectory: "Dev activation cache must be a local file URL"
        case .runtimeMismatch: "Dev activation Runtime does not match the generated Shell"
        }
    }
}

/// Point-in-time activation and native-image resource state.
public struct Snapshot: Hashable, Sendable {
    /// Highest source revision accepted for transfer in this process.
    public var highestOfferedRevision: DevProtocol.SourceRevision
    /// Highest source revision activated successfully.
    public var highestAppliedRevision: DevProtocol.SourceRevision
    /// Generation that currently supplies active development routes.
    public var activeGenerationID: DevProtocol.GenerationID?
    /// Dynamic Replacement image count, including images loaded before a reconnect.
    public var loadedNativeImageCount: Int
    /// Dynamic Replacement bytes, including images loaded before reconnect.
    public var loadedNativeBytes: Int
    /// Whether the configured soft image-count threshold has been reached.
    public var nativeImageSoftLimitReached: Bool
    /// Whether a partially registered native image makes further injection unsafe.
    public var nativeStateUncertain: Bool
    /// Whether an accepted payload transfer is currently open.
    public var hasPendingTransfer: Bool
    /// Generation associated with the open transfer, if any.
    public var pendingGenerationID: DevProtocol.GenerationID?
    /// Current backend selection for every function with an active override.
    public var activeFunctionRoutes: [DevProtocol.ActiveFunctionRoute]
    /// NativeCall keys published by successful development HLBC transactions.
    public var activeDevelopmentNativeCallKeys: [Core.NativeCall.Key]
    /// Swift Adapter images mapped for development HLBC, including orphaned
    /// images from transactions rejected after mapping.
    public var loadedDevelopmentAdapterCount: Int
    public var loadedDevelopmentAdapterBytes: Int
    /// HLBC generations retained for rollback or in-flight invocations.
    public var retainedHLBCGenerationIDs: [Runtime.GenerationID]
    /// Highest HLBC generation identity activated in this process.
    public var highestActivatedHLBCGenerationID: Runtime.GenerationID?
    /// Unique estimated HLBC artifact bytes retained by live snapshots.
    public var retainedHLBCBytes: Int
    /// Historical HLBC snapshots reclaimed during this process lifetime.
    public var compactedHLBCGenerationCount: UInt64
}

/// Serializes development payload transfer and activation inside the App.
///
/// This is an advanced integration point. `DevRuntime.ApplicationSession`
/// creates it, connects it to the authenticated transport, and supplies the UI
/// reload handler for normal applications.
public actor Controller {
    /// Callback run after code is active to refresh affected presentation targets.
    public typealias ReloadHandler = @Sendable (
        LiveReload.Context,
        [DevProtocol.ReloadHint]
    ) async -> DevProtocol.UIReloadStatus

    private struct PendingTransfer {
        var token: DevProtocol.OfferToken
        var offer: DevProtocol.PatchOffer
        var fileURL: URL
        var handle: FileHandle
        var receivedBytes: UInt64
        var hasher: SHA256
    }

    /// Immutable App and toolchain identity negotiated for this session.
    public let identity: DevProtocol.SessionIdentity
    /// Generated Shell interface used to verify HLBC imports and exports.
    public let shell: Verification.ShellInterface
    /// Runtime resource and execution policy used for HLBC verification.
    public let runtimePolicy: Core.RuntimePolicy
    /// Runtime that verifies native bindings and atomically switches dispatch.
    public let runtime: Runtime.Engine
    public var registry: Runtime.GenerationRegistry { runtime.registry }
    /// Private local directory used for incoming and mapped development artifacts.
    public let cacheDirectory: URL
    /// Resource ceilings enforced before bytes are accepted or mapped.
    public let limits: DevActivation.Limits

    private let nativeLoader: any NativeImage.Loading
    private let developmentAdapterLoader: any DevelopmentAdapter.Loading
    private let reloadHandler: ReloadHandler
    private var highestOfferedRevision = DevProtocol.SourceRevision(rawValue: 0)
    private var highestAppliedRevision: DevProtocol.SourceRevision
    private var activeGenerationID: DevProtocol.GenerationID?
    private var pending: PendingTransfer?
    private var loadedNativeImages: [NativeImage.LoadedImage] = []
    private var loadedDevelopmentAdapters: [DevelopmentAdapter.LoadedImage] = []
    private var developmentImports: [
        Core.NativeImportID: DevProtocol.DevelopmentPayload.NativeImport
    ] = [:]
    private var developmentNativeInvokers: [
        Core.NativeImportID: any VM.NativeInvoker
    ] = [:]
    private var developmentAsyncNativeInvokers: [
        Core.NativeImportID: any VM.AsyncNativeInvoker
    ] = [:]
    private let initialNativeImageCount: Int
    private let initialNativeImageBytes: Int
    private var nativeStateUncertain = false
    private var activeBackendByFunction: [Core.FunctionKey: LiveReload.Backend] = [:]

    /// Creates an explicitly assembled activation controller.
    ///
    /// - Important: `runtime` must be the engine executing instrumented calls.
    public init(
        identity: DevProtocol.SessionIdentity,
        shell: Verification.ShellInterface,
        runtimePolicy: Core.RuntimePolicy,
        runtime: Runtime.Engine,
        cacheDirectory: URL,
        limits: DevActivation.Limits = .init(),
        nativeLoader: any NativeImage.Loading = NativeImage.SystemLoader(),
        developmentAdapterLoader: any DevelopmentAdapter.Loading =
            DevelopmentAdapter.SystemLoader(),
        reloadHandler: @escaping ReloadHandler = { _, _ in .notRequested }
    ) throws {
        try identity.validate()
        try limits.validate()
        guard cacheDirectory.isFileURL, !cacheDirectory.path.isEmpty else {
            throw DevActivation.ConfigurationError.invalidCacheDirectory
        }
        guard runtime.registry.snapshot().activeGenerationID == nil,
              runtime.shellInterfaceHash == shell.interfaceHash
        else { throw DevActivation.ConfigurationError.runtimeMismatch }
        self.identity = identity
        self.shell = shell
        self.runtimePolicy = runtimePolicy
        self.runtime = runtime
        self.cacheDirectory = cacheDirectory
        self.limits = limits
        self.nativeLoader = nativeLoader
        self.developmentAdapterLoader = developmentAdapterLoader
        self.reloadHandler = reloadHandler
        guard let initialBytes = Int(exactly: identity.loadedNativeImageBytes) else {
            throw DevActivation.ConfigurationError.invalidLimits
        }
        initialNativeImageCount = Int(identity.loadedNativeImageCount)
        initialNativeImageBytes = initialBytes
        highestAppliedRevision = identity.highestAppliedSourceRevision
        activeGenerationID = identity.activeGenerationID
        nativeStateUncertain = identity.nativeStateUncertain
        activeBackendByFunction = Dictionary(
            uniqueKeysWithValues: identity.activeFunctionRoutes.map {
                ($0.functionKey, $0.backend)
            }
        )
        guard identity.activeDevelopmentNativeCallKeys.isEmpty,
              identity.loadedDevelopmentAdapterCount == 0,
              identity.loadedDevelopmentAdapterBytes == 0
        else {
            throw DevActivation.ConfigurationError.runtimeMismatch
        }
    }

    /// Validates an offer and opens its bounded, contiguous payload transfer.
    ///
    /// A successful call reserves a temporary file and returns the token that
    /// every subsequent chunk and commit must carry. Newer source revisions are
    /// monotonic; stale or cross-session offers are rejected before bytes arrive.
    public func accept(_ offer: DevProtocol.PatchOffer) throws -> DevProtocol.OfferToken {
        try offer.validate()
        guard offer.sessionID == identity.sessionID else {
            throw DevProtocol.Diagnostic.sessionMismatch("patch offer belongs to another session")
        }
        guard offer.sourceRevision > highestOfferedRevision,
              offer.sourceRevision > highestAppliedRevision
        else {
            throw DevProtocol.Diagnostic.staleRevision(
                offer.sourceRevision,
                highest: max(highestOfferedRevision, highestAppliedRevision)
            )
        }
        guard offer.generationID.rawValue > (activeGenerationID?.rawValue ?? 0) else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR102",
                message: "generation ID is not monotonic",
                sourceRevision: offer.sourceRevision,
                generationID: offer.generationID,
                backend: offer.backend,
                nextAction: "discard the stale generation"
            )
        }
        let maximum = offer.backend == .nativeDynamicReplacement
            ? limits.maximumNativePayloadBytes
            : limits.maximumHLBCPayloadBytes
        guard maximum > 0,
              offer.payloadByteLength <= UInt64(maximum),
              offer.payloadByteLength > 0 || offer.mode == .restoreOriginals
        else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR702",
                message: "payload exceeds the \(maximum)-byte backend limit",
                sourceRevision: offer.sourceRevision,
                generationID: offer.generationID,
                backend: offer.backend,
                nextAction: "reduce the patch surface or perform a full build"
            )
        }
        if offer.backend == .nativeDynamicReplacement {
            guard identity.supportedBackends.contains(.nativeDynamicReplacement),
                  identity.nativeChainingProbePassed,
                  !nativeStateUncertain
            else {
                throw DevProtocol.Diagnostic(
                    code: "HLXLR502",
                    message: "Native Dynamic Replacement is unavailable for this session",
                    sourceRevision: offer.sourceRevision,
                    generationID: offer.generationID,
                    backend: offer.backend,
                    nextAction: "use the HLBC backend or restart the Dev App"
                )
            }
            try enforceNativeBudget(additionalBytes: Int(offer.payloadByteLength), offer: offer)
        } else {
            guard identity.supportedBackends.contains(.hlbc) else {
                throw DevProtocol.Diagnostic(
                    code: "HLXLR505",
                    message: "HLBC backend is unavailable in this Dev Shell",
                    sourceRevision: offer.sourceRevision,
                    generationID: offer.generationID,
                    backend: offer.backend,
                    nextAction: "perform a full build with Helix Dev Runtime enabled"
                )
            }
        }
        for function in offer.changedFunctions {
            if let existing = activeBackendByFunction[function], existing != offer.backend {
                throw DevProtocol.Diagnostic(
                    code: "HLXLR504",
                    message: "function already has an active \(existing.rawValue) generation",
                    sourceRevision: offer.sourceRevision,
                    generationID: offer.generationID,
                    backend: offer.backend,
                    nextAction: "restart the App before switching backend for the same function"
                )
            }
        }

        discardPending()
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let token = DevProtocol.OfferToken(rawValue: UUID())
        let fileURL = cacheDirectory.appendingPathComponent(
            "\(token.rawValue.uuidString).partial",
            isDirectory: false
        )
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR401",
                message: "cannot create the payload staging file",
                sourceRevision: offer.sourceRevision,
                generationID: offer.generationID,
                backend: offer.backend,
                nextAction: "check App container storage and retry"
            )
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        pending = .init(
            token: token,
            offer: offer,
            fileURL: fileURL,
            handle: handle,
            receivedBytes: 0,
            hasher: SHA256()
        )
        highestOfferedRevision = offer.sourceRevision
        return token
    }

    /// Appends one contiguous chunk to the currently accepted transfer.
    ///
    /// Offsets must exactly equal the number of bytes already received. The
    /// running SHA-256 is finalized by ``commit(_:)``.
    public func append(_ chunk: DevProtocol.PatchChunk) throws {
        guard var pending, pending.token == chunk.token else {
            throw DevProtocol.Diagnostic.sessionMismatch("patch chunk has an unknown offer token")
        }
        guard chunk.offset == pending.receivedBytes else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR402",
                message: "patch chunk offset is not contiguous",
                sourceRevision: pending.offer.sourceRevision,
                generationID: pending.offer.generationID,
                backend: pending.offer.backend,
                nextAction: "abort and retransmit the latest patch"
            )
        }
        let total = pending.receivedBytes.addingReportingOverflow(UInt64(chunk.bytes.count))
        guard !total.overflow, total.partialValue <= pending.offer.payloadByteLength else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR403",
                message: "patch transfer exceeds the offered length",
                sourceRevision: pending.offer.sourceRevision,
                generationID: pending.offer.generationID,
                backend: pending.offer.backend,
                nextAction: "abort the malformed transfer"
            )
        }
        try pending.handle.write(contentsOf: chunk.bytes)
        pending.hasher.update(data: chunk.bytes)
        pending.receivedBytes = total.partialValue
        self.pending = pending
    }

    /// Verifies and activates the completed payload associated with `token`.
    ///
    /// HLBC activation verifies bytecode and atomically updates the generation
    /// registry. Native activation preflights and maps a signed image, then calls
    /// its generated registration root. UI reload runs only after code is active.
    /// Rejections normally leave the previous generation active and are returned
    /// as data so the transport can send a structured result.
    public func commit(_ token: DevProtocol.OfferToken) async -> DevProtocol.ActivationResult {
        guard let pending, pending.token == token else {
            return rejection(
                code: "HLXLR101",
                message: "commit token is stale",
                offer: nil,
                nextAction: "wait for the latest patch offer"
            )
        }
        defer {
            try? pending.handle.close()
            self.pending = nil
        }
        guard pending.offer.sourceRevision == highestOfferedRevision,
              pending.offer.sourceRevision > highestAppliedRevision
        else {
            return rejection(
                code: "HLXLR201",
                message: "a newer source revision superseded this transfer",
                offer: pending.offer,
                nextAction: "discard this payload"
            )
        }
        guard pending.receivedBytes == pending.offer.payloadByteLength else {
            return rejection(
                code: "HLXLR402",
                message: "payload is incomplete",
                offer: pending.offer,
                nextAction: "retransmit the latest payload"
            )
        }
        do {
            try pending.handle.synchronize()
            try pending.handle.close()
        } catch {
            return rejection(
                code: "HLXLR401",
                message: String(describing: error),
                offer: pending.offer,
                nextAction: "retry after checking App container storage"
            )
        }
        guard let digest = try? Core.Digest(bytes: Data(pending.hasher.finalize())),
              digest == pending.offer.payloadSHA256
        else {
            try? FileManager.default.removeItem(at: pending.fileURL)
            return rejection(
                code: "HLXLR403",
                message: "payload SHA-256 mismatch",
                offer: pending.offer,
                nextAction: "terminate the session and reconnect"
            )
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: pending.fileURL, options: [.mappedIfSafe])
        } catch {
            return rejection(
                code: "HLXLR401",
                message: String(describing: error),
                offer: pending.offer,
                nextAction: "retry the transfer"
            )
        }

        do {
            switch pending.offer.backend {
            case .hlbc:
                try activateHLBC(bytes, offer: pending.offer)
                try? FileManager.default.removeItem(at: pending.fileURL)
            case .nativeDynamicReplacement:
                let image = try nativeLoader.load(
                    bytes: bytes,
                    offer: pending.offer,
                    identity: identity,
                    cacheDirectory: cacheDirectory
                )
                loadedNativeImages.append(image)
                try? FileManager.default.removeItem(at: pending.fileURL)
            }
        } catch let error as NativeImage.Error {
            if case .stateUncertain = error { nativeStateUncertain = true }
            return rejection(
                code: error.isStateUncertain ? "HLXLR503" : "HLXLR404",
                message: error.description,
                offer: pending.offer,
                previousCodeRemainsActive: !error.isStateUncertain,
                nextAction: error.isStateUncertain
                    ? "restart the App; no further Native injection is safe"
                    : "use HLBC or fix signing/dependencies"
            )
        } catch let error as DevelopmentAdapter.Error {
            if error.isStateUncertain { nativeStateUncertain = true }
            return rejection(
                code: error.isStateUncertain ? "HLXLR503" : "HLXLR507",
                message: error.description,
                offer: pending.offer,
                previousCodeRemainsActive: true,
                nextAction: error.isStateUncertain
                    ? "restart the App before loading another native Adapter; the previous generation remains active"
                    : "fix the cataloged native call or Adapter; the previous generation remains active"
            )
        } catch var diagnostic as DevProtocol.Diagnostic {
            diagnostic.sourceRevision = diagnostic.sourceRevision
                ?? pending.offer.sourceRevision
            diagnostic.generationID = diagnostic.generationID
                ?? pending.offer.generationID
            diagnostic.backend = diagnostic.backend ?? pending.offer.backend
            return .init(
                sourceRevision: pending.offer.sourceRevision,
                generationID: pending.offer.generationID,
                codeStatus: .rejected,
                reloadStatus: .notRequested,
                diagnostic: diagnostic
            )
        } catch {
            return rejection(
                code: "HLXLR505",
                message: String(describing: error),
                offer: pending.offer,
                nextAction: "fix the rejected patch; the previous generation remains active"
            )
        }

        highestAppliedRevision = pending.offer.sourceRevision
        activeGenerationID = pending.offer.generationID
        for function in pending.offer.changedFunctions {
            if pending.offer.restoredFunctions.contains(function) {
                activeBackendByFunction.removeValue(forKey: function)
            } else {
                activeBackendByFunction[function] = pending.offer.backend
            }
        }
        let context = LiveReload.Context(
            generationID: pending.offer.generationID.rawValue,
            sourceRevision: pending.offer.sourceRevision.rawValue,
            changedSources: Set(pending.offer.changedSources),
            changedFunctions: Set(pending.offer.changedFunctions),
            backend: pending.offer.backend,
            reason: pending.offer.reason
        )
        let reloadStatus = await reloadHandler(context, pending.offer.reloadHints)
        return .init(
            sourceRevision: pending.offer.sourceRevision,
            generationID: pending.offer.generationID,
            codeStatus: .codeActive,
            reloadStatus: reloadStatus
        )
    }

    /// Returns the actor's current transfer, routing, and native-resource state.
    public func snapshot() -> DevActivation.Snapshot {
        let registrySnapshot = registry.snapshot()
        return .init(
            highestOfferedRevision: highestOfferedRevision,
            highestAppliedRevision: highestAppliedRevision,
            activeGenerationID: activeGenerationID,
            loadedNativeImageCount: totalNativeImageCount,
            loadedNativeBytes: totalNativeImageBytes,
            nativeImageSoftLimitReached:
                totalMappedNativeImageCount
                    >= limits.nativeImageSoftWarningCount,
            nativeStateUncertain: nativeStateUncertain,
            hasPendingTransfer: pending != nil,
            pendingGenerationID: pending?.offer.generationID,
            activeFunctionRoutes: activeRoutes(),
            activeDevelopmentNativeCallKeys:
                developmentImports.values.map(\.key).sorted(),
            loadedDevelopmentAdapterCount:
                loadedDevelopmentAdapters.count,
            loadedDevelopmentAdapterBytes:
                loadedDevelopmentAdapters.reduce(0) { $0 + $1.byteCount },
            retainedHLBCGenerationIDs: registrySnapshot.loadedGenerationIDs,
            highestActivatedHLBCGenerationID:
                registrySnapshot.highestActivatedGenerationID,
            retainedHLBCBytes: registrySnapshot.estimatedByteCount,
            compactedHLBCGenerationCount:
                registrySnapshot.compactedGenerationCount
        )
    }

    /// Returns the mutable activation inventory bound to the immutable process
    /// identity. A reconnect must advertise this value, not the launch snapshot.
    public func currentSessionIdentity() -> DevProtocol.SessionIdentity {
        var current = identity
        current.highestAppliedSourceRevision = highestAppliedRevision
        current.activeGenerationID = activeGenerationID
        current.activeFunctionRoutes = activeRoutes()
        current.activeDevelopmentNativeCallKeys = developmentImports.values
            .map(\.key).sorted()
        current.loadedDevelopmentAdapterCount = UInt32(
            loadedDevelopmentAdapters.count
        )
        current.loadedDevelopmentAdapterBytes = UInt64(
            loadedDevelopmentAdapters.reduce(0) { $0 + $1.byteCount }
        )
        current.loadedNativeImageCount = UInt32(totalNativeImageCount)
        current.loadedNativeImageBytes = UInt64(totalNativeImageBytes)
        current.nativeImageSoftLimitReached =
            totalMappedNativeImageCount >= limits.nativeImageSoftWarningCount
        current.nativeStateUncertain = nativeStateUncertain
        return current
    }

    /// Closes and deletes a pending transfer without changing active code.
    ///
    /// When `token` is non-`nil`, a different pending transfer is left untouched.
    public func abort(_ token: DevProtocol.OfferToken? = nil) {
        guard token == nil || pending?.token == token else { return }
        discardPending()
    }

    private func activateHLBC(_ bytes: Data, offer: DevProtocol.PatchOffer) throws {
        let removedEntries = try restoredEntries(for: offer)
        if offer.mode == .restoreOriginals {
            let parent = registry.activeLease()?.generation.id
            let generation = try Runtime.Generation(
                id: .init(rawValue: offer.generationID.rawValue),
                parentID: parent,
                packageID: "HLXLive-\(identity.sessionID)-\(offer.sourceRevision.rawValue)-restore",
                packageHash: offer.payloadSHA256,
                images: [],
                removedEntries: removedEntries,
                estimatedByteCount: 0
            )
            _ = try runtime.activate(generation, expectedActiveID: parent)
            return
        }
        let artifact = try DevProtocol.DevelopmentPayload.Artifact.decode(
            bytes,
            maximumPayloadBytes: limits.maximumHLBCPayloadBytes
        )
        guard artifact.manifest.shellInterfaceHash == shell.interfaceHash,
              artifact.manifest.compilerFingerprint
                == identity.swiftCompilerFingerprint,
              artifact.manifest.sdkBuild == identity.sdkBuild,
              targetTriple(
                artifact.manifest.targetTriple,
                matches: identity
              )
        else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR304",
                message: "development payload toolchain, target, or Shell identity does not match the running App",
                sourceRevision: offer.sourceRevision,
                generationID: offer.generationID,
                backend: .hlbc,
                nextAction: "discard this payload and rebuild the exact Dev Shell"
            )
        }

        let baselineKeys = Set(shell.imports.values.map(\.key))
        var candidateImports = developmentImports
        var newImports: [DevProtocol.DevelopmentPayload.NativeImport] = []
        for nativeImport in artifact.manifest.nativeImports {
            guard shell.imports[nativeImport.id] == nil,
                  !baselineKeys.contains(nativeImport.key)
            else {
                throw DevProtocol.Error.invalidArtifact(
                    "development NativeImport collides with the linked Shell"
                )
            }
            if let existing = candidateImports[nativeImport.id] {
                // A newer save can finish compiling while the transaction
                // that first publishes this Adapter is still in flight. Once
                // that earlier transaction activates, the newer payload is a
                // deterministic replay of the same capability. Accept it and
                // ignore its now-redundant image instead of rejecting a valid
                // latest-wins update or mapping the dylib twice.
                guard sessionEquivalent(existing, nativeImport) else {
                    throw DevProtocol.Error.invalidArtifact(
                        "development NativeImport changed after session publication"
                    )
                }
                continue
            }
            guard !candidateImports.values.contains(where: {
                $0.key == nativeImport.key
            }) else {
                throw DevProtocol.Error.invalidArtifact(
                    "development NativeCallKey collides with another compact ID"
                )
            }
            switch nativeImport.binding {
            case .swiftAdapter:
                guard nativeImport.imageIndex != nil,
                      nativeImport.exportSymbol != nil
                else {
                    throw DevProtocol.Error.invalidArtifact(
                        "a new Swift NativeImport has no Adapter image"
                    )
                }
            case .objectiveCInvoker, .cInvoker:
                guard nativeImport.imageIndex == nil,
                      nativeImport.exportSymbol == nil
                else {
                    throw DevProtocol.Error.invalidArtifact(
                        "a generic native invoker unexpectedly references an Adapter image"
                    )
                }
            }
            candidateImports[nativeImport.id] = normalized(nativeImport)
            newImports.append(nativeImport)
        }
        var effectiveCapabilities = shell.capabilities
        if !candidateImports.isEmpty {
            effectiveCapabilities.insert(.nativeImportsV1)
        }
        let effectiveShell = try Verification.ShellInterface(
            interfaceHash: shell.interfaceHash,
            compatibility: shell.compatibility,
            capabilities: effectiveCapabilities,
            entries: Array(shell.entries.values),
            imports: Array(shell.imports.values)
                + candidateImports.values.map(resolvedImport),
            types: Array(shell.types.values),
            frozenValueTypes: Array(shell.frozenValueTypes.values)
        )
        var developmentPolicy = runtimePolicy
        if !candidateImports.isEmpty {
            developmentPolicy.acceptedCapabilities.insert(.nativeImportsV1)
        }
        developmentPolicy.allowedNativeCalls.formUnion(
            candidateImports.values.map(\.key)
        )
        let image = try Verification.Engine().verify(
            bytes: artifact.bytecode,
            shell: effectiveShell,
            policy: developmentPolicy
        )
        let patchedFunctions = Set(offer.changedFunctions)
            .subtracting(offer.restoredFunctions)
        guard Set(image.module.entries.map(\.functionKey)) == patchedFunctions else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR505",
                message: "HLBC entries do not match the offered FunctionKeys",
                sourceRevision: offer.sourceRevision,
                generationID: offer.generationID,
                backend: .hlbc,
                nextAction: "rebuild the Dev artifact from the latest snapshot"
            )
        }

        var candidateNativeInvokers = developmentNativeInvokers
        var candidateAsyncInvokers = developmentAsyncNativeInvokers
        for nativeImport in newImports {
            switch nativeImport.binding {
            case .objectiveCInvoker:
                let invoker = Runtime.ObjectiveCInvoker(
                    id: nativeImport.id,
                    key: nativeImport.key,
                    descriptor: nativeImport.descriptor,
                    parameterTypes: nativeImport.parameterTypes,
                    resultType: nativeImport.resultType,
                    effects: nativeImport.descriptor.effects,
                    contract: nativeImport.contract
                )
                try invoker.validateConfiguration()
                guard candidateNativeInvokers.updateValue(
                    invoker,
                    forKey: nativeImport.id
                ) == nil else {
                    throw DevProtocol.Error.invalidArtifact(
                        "development native invoker ID is duplicated"
                    )
                }
            case .cInvoker:
                let invoker = try developmentAdapterLoader.makeCInvoker(
                    for: nativeImport
                )
                guard candidateNativeInvokers.updateValue(
                    invoker,
                    forKey: nativeImport.id
                ) == nil else {
                    throw DevProtocol.Error.invalidArtifact(
                        "development C invoker ID is duplicated"
                    )
                }
            case .swiftAdapter:
                break
            }
        }
        let imageIndexesToLoad = Set(newImports.compactMap {
            $0.imageIndex.map(Int.init)
        })
        if !imageIndexesToLoad.isEmpty {
            guard !nativeStateUncertain else {
                throw DevProtocol.Diagnostic(
                    code: "HLXLR502",
                    message: "development Adapter loading is unavailable after an uncertain native mapping",
                    sourceRevision: offer.sourceRevision,
                    generationID: offer.generationID,
                    backend: .hlbc,
                    nextAction: "restart the Dev App before loading another native Adapter"
                )
            }
            try enforceDevelopmentAdapterBudget(
                additionalImages: imageIndexesToLoad.count,
                additionalBytes: imageIndexesToLoad.reduce(0) {
                    $0 + artifact.images[$1].count
                },
                offer: offer
            )
        }
        for index in imageIndexesToLoad.sorted() {
            let imageImports = newImports.filter {
                $0.imageIndex.map(Int.init) == index
            }
            let loaded = try developmentAdapterLoader.load(
                bytes: artifact.images[index],
                descriptor: artifact.manifest.images[index],
                imports: imageImports,
                identity: identity,
                cacheDirectory: cacheDirectory.appendingPathComponent(
                    "Adapters",
                    isDirectory: true
                )
            )
            // Mapping cannot be undone safely after factories return executable
            // closures, so charge it even if the later generation CAS rejects.
            loadedDevelopmentAdapters.append(loaded)
            for invoker in loaded.nativeInvokers {
                guard candidateNativeInvokers.updateValue(
                    invoker,
                    forKey: invoker.id
                ) == nil else {
                    throw DevProtocol.Error.invalidArtifact(
                        "development Adapter returned a duplicate synchronous ID"
                    )
                }
            }
            for invoker in loaded.asyncNativeInvokers {
                guard candidateAsyncInvokers.updateValue(
                    invoker,
                    forKey: invoker.id
                ) == nil else {
                    throw DevProtocol.Error.invalidArtifact(
                        "development Adapter returned a duplicate async ID"
                    )
                }
            }
        }
        for nativeImport in newImports {
            if nativeImport.descriptor.effects.isAsync {
                guard candidateAsyncInvokers[nativeImport.id].map({
                    invokerMatches($0, nativeImport)
                }) == true else {
                    throw DevProtocol.Error.invalidArtifact(
                        "development async Adapter does not match its descriptor"
                    )
                }
            } else {
                guard candidateNativeInvokers[nativeImport.id].map({
                    invokerMatches($0, nativeImport)
                }) == true else {
                    throw DevProtocol.Error.invalidArtifact(
                        "development native invoker does not match its descriptor"
                    )
                }
            }
        }
        let nativeCapabilities = try runtime.baselineNativeCapabilities.appending(
            nativeInvokers: Array(candidateNativeInvokers.values),
            asyncNativeInvokers: Array(candidateAsyncInvokers.values)
        )
        let parent = registry.activeLease()?.generation.id
        let generation = try Runtime.Generation(
            id: .init(rawValue: offer.generationID.rawValue),
            parentID: parent,
            packageID: "HLXLive-\(identity.sessionID)-\(offer.sourceRevision.rawValue)",
            packageHash: offer.payloadSHA256,
            images: [image],
            removedEntries: removedEntries,
            nativeCapabilities: nativeCapabilities,
            // Adapter images have their own process-lifetime mapped-image
            // budget. The generation registry retains only verified HLBC.
            estimatedByteCount: artifact.bytecode.count
        )
        _ = try runtime.activate(generation, expectedActiveID: parent)
        developmentImports = candidateImports
        developmentNativeInvokers = candidateNativeInvokers
        developmentAsyncNativeInvokers = candidateAsyncInvokers
    }

    private func normalized(
        _ nativeImport: DevProtocol.DevelopmentPayload.NativeImport
    ) -> DevProtocol.DevelopmentPayload.NativeImport {
        var value = nativeImport
        value.imageIndex = nil
        value.exportSymbol = nil
        return value
    }

    private func sessionEquivalent(
        _ lhs: DevProtocol.DevelopmentPayload.NativeImport,
        _ rhs: DevProtocol.DevelopmentPayload.NativeImport
    ) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private func resolvedImport(
        _ nativeImport: DevProtocol.DevelopmentPayload.NativeImport
    ) -> Verification.ResolvedNativeImport {
        .init(
            id: nativeImport.id,
            key: nativeImport.key,
            descriptor: nativeImport.descriptor,
            parameterTypes: nativeImport.parameterTypes,
            resultType: nativeImport.resultType,
            contract: nativeImport.contract,
            capability: nativeImport.capability
        )
    }

    private func invokerMatches(
        _ invoker: any VM.NativeInvoker,
        _ nativeImport: DevProtocol.DevelopmentPayload.NativeImport
    ) -> Bool {
        invoker.id == nativeImport.id
            && invoker.key == nativeImport.key
            && invoker.parameterTypes == nativeImport.parameterTypes
            && invoker.resultType == nativeImport.resultType
            && invoker.effects == nativeImport.descriptor.effects
            && invoker.contract == nativeImport.contract
    }

    private func invokerMatches(
        _ invoker: any VM.AsyncNativeInvoker,
        _ nativeImport: DevProtocol.DevelopmentPayload.NativeImport
    ) -> Bool {
        invoker.id == nativeImport.id
            && invoker.key == nativeImport.key
            && invoker.parameterTypes == nativeImport.parameterTypes
            && invoker.resultType == nativeImport.resultType
            && invoker.effects == nativeImport.descriptor.effects
            && invoker.contract == nativeImport.contract
    }

    private func targetTriple(
        _ target: String,
        matches identity: DevProtocol.SessionIdentity
    ) -> Bool {
        let lowered = target.lowercased()
        guard target.hasPrefix("\(identity.architecture)-")
            || (identity.architecture == "arm64e"
                && target.hasPrefix("arm64-"))
        else { return false }
        switch identity.platform {
        case .iOS:
            return lowered.contains("-apple-ios")
                && !lowered.contains("simulator")
        case .iOSSimulator:
            return lowered.contains("-apple-ios")
                && lowered.contains("simulator")
        case .macOS:
            return lowered.contains("-apple-macos")
        }
    }

    private func enforceDevelopmentAdapterBudget(
        additionalImages: Int,
        additionalBytes: Int,
        offer: DevProtocol.PatchOffer
    ) throws {
        let candidateCount = totalMappedNativeImageCount
            .addingReportingOverflow(additionalImages)
        let candidateBytes = totalMappedNativeImageBytes
            .addingReportingOverflow(additionalBytes)
        guard !candidateCount.overflow,
              !candidateBytes.overflow,
              candidateCount.partialValue <= limits.maximumNativeImageCount,
              candidateBytes.partialValue <= limits.maximumNativeMappedBytes
        else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR701",
                message: "development Adapter count or mapped-byte budget is exhausted",
                sourceRevision: offer.sourceRevision,
                generationID: offer.generationID,
                backend: .hlbc,
                nextAction: "restart the Dev App to reclaim development Adapter images"
            )
        }
    }

    private func restoredEntries(
        for offer: DevProtocol.PatchOffer
    ) throws -> Set<Core.EntryIndex> {
        let keys = Set(offer.restoredFunctions)
        let entries = Set(
            shell.entries.values
                .filter { keys.contains($0.key) }
                .map(\.index)
        )
        guard entries.count == keys.count else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR505",
                message: "restore-originals offer references an unknown FunctionKey",
                sourceRevision: offer.sourceRevision,
                generationID: offer.generationID,
                backend: .hlbc,
                nextAction: "rebuild the Dev Shell and its Reload Index"
            )
        }
        return entries
    }

    private func enforceNativeBudget(
        additionalBytes: Int,
        offer: DevProtocol.PatchOffer
    ) throws {
        let newBytes = totalMappedNativeImageBytes.addingReportingOverflow(
            additionalBytes
        )
        guard totalMappedNativeImageCount < limits.maximumNativeImageCount,
              !newBytes.overflow,
              newBytes.partialValue <= limits.maximumNativeMappedBytes
        else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR701",
                message: "Native image count or mapped-byte budget is exhausted",
                sourceRevision: offer.sourceRevision,
                generationID: offer.generationID,
                backend: .nativeDynamicReplacement,
                nextAction: "restart the Dev App; old images will not be dlclose'd"
            )
        }
    }

    private func discardPending() {
        guard let pending else { return }
        try? pending.handle.close()
        try? FileManager.default.removeItem(at: pending.fileURL)
        self.pending = nil
    }

    private func activeRoutes() -> [DevProtocol.ActiveFunctionRoute] {
        activeBackendByFunction.map {
            .init(functionKey: $0.key, backend: $0.value)
        }.sorted { $0.functionKey.description < $1.functionKey.description }
    }

    private var totalNativeImageCount: Int {
        initialNativeImageCount + loadedNativeImages.count
    }

    private var totalNativeImageBytes: Int {
        initialNativeImageBytes + loadedNativeImages.reduce(0) { $0 + $1.byteCount }
    }

    private var totalMappedNativeImageCount: Int {
        totalNativeImageCount + loadedDevelopmentAdapters.count
    }

    private var totalMappedNativeImageBytes: Int {
        totalNativeImageBytes
            + loadedDevelopmentAdapters.reduce(0) { $0 + $1.byteCount }
    }

    private func rejection(
        code: String,
        message: String,
        offer: DevProtocol.PatchOffer?,
        previousCodeRemainsActive: Bool = true,
        nextAction: String
    ) -> DevProtocol.ActivationResult {
        .init(
            sourceRevision: offer?.sourceRevision ?? highestOfferedRevision,
            generationID: offer?.generationID ?? .init(rawValue: 0),
            codeStatus: code == "HLXLR503" ? .nativeStateUncertain : .rejected,
            reloadStatus: .notRequested,
            diagnostic: .init(
                code: code,
                message: message,
                sourceRevision: offer?.sourceRevision,
                generationID: offer?.generationID,
                backend: offer?.backend,
                previousCodeRemainsActive: previousCodeRemainsActive,
                nextAction: nextAction
            )
        )
    }
}
}

private extension NativeImage.Error {
    var isStateUncertain: Bool {
        if case .stateUncertain = self { return true }
        return false
    }
}
