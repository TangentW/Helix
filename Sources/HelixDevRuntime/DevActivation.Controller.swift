import CryptoKit
import Foundation
import HelixBytecode
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI
import HelixRuntime
import HelixVerifier

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
        maximumHLBCPayloadBytes: Int = 16 * 1_024 * 1_024,
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

    /// Human-readable configuration failure detail.
    public var description: String {
        switch self {
        case .invalidLimits: "Dev activation limits are inconsistent or nonpositive"
        case .invalidCacheDirectory: "Dev activation cache must be a local file URL"
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
    /// Total native image count, including images loaded before a reconnect.
    public var loadedNativeImageCount: Int
    /// Total mapped native image bytes, including images loaded before reconnect.
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
    /// Generation registry that atomically switches HLBC dispatch routes.
    public let registry: Runtime.GenerationRegistry
    /// Private local directory used for incoming and mapped development artifacts.
    public let cacheDirectory: URL
    /// Resource ceilings enforced before bytes are accepted or mapped.
    public let limits: DevActivation.Limits

    private let nativeLoader: any NativeImage.Loading
    private let reloadHandler: ReloadHandler
    private var highestOfferedRevision = DevProtocol.SourceRevision(rawValue: 0)
    private var highestAppliedRevision: DevProtocol.SourceRevision
    private var activeGenerationID: DevProtocol.GenerationID?
    private var pending: PendingTransfer?
    private var loadedNativeImages: [NativeImage.LoadedImage] = []
    private let initialNativeImageCount: Int
    private let initialNativeImageBytes: Int
    private var nativeStateUncertain = false
    private var activeBackendByFunction: [Core.FunctionKey: LiveReload.Backend] = [:]

    /// Creates an explicitly assembled activation controller.
    ///
    /// - Important: `registry` must be the registry installed on the runtime
    ///   executing instrumented calls.
    public init(
        identity: DevProtocol.SessionIdentity,
        shell: Verification.ShellInterface,
        runtimePolicy: Core.RuntimePolicy,
        registry: Runtime.GenerationRegistry = .init(
            maximumGenerationCount: 512,
            maximumEstimatedBytes: 256 * 1_024 * 1_024
        ),
        cacheDirectory: URL,
        limits: DevActivation.Limits = .init(),
        nativeLoader: any NativeImage.Loading = NativeImage.SystemLoader(),
        reloadHandler: @escaping ReloadHandler = { _, _ in .notRequested }
    ) throws {
        try identity.validate()
        try limits.validate()
        guard cacheDirectory.isFileURL, !cacheDirectory.path.isEmpty else {
            throw DevActivation.ConfigurationError.invalidCacheDirectory
        }
        self.identity = identity
        self.shell = shell
        self.runtimePolicy = runtimePolicy
        self.registry = registry
        self.cacheDirectory = cacheDirectory
        self.limits = limits
        self.nativeLoader = nativeLoader
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
                totalNativeImageCount >= limits.nativeImageSoftWarningCount,
            nativeStateUncertain: nativeStateUncertain,
            hasPendingTransfer: pending != nil,
            pendingGenerationID: pending?.offer.generationID,
            activeFunctionRoutes: activeRoutes(),
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
        current.loadedNativeImageCount = UInt32(totalNativeImageCount)
        current.loadedNativeImageBytes = UInt64(totalNativeImageBytes)
        current.nativeImageSoftLimitReached =
            totalNativeImageCount >= limits.nativeImageSoftWarningCount
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
            _ = try registry.activate(generation, expectedActiveID: parent)
            return
        }
        let image = try Verification.Engine().verify(
            bytes: bytes,
            shell: shell,
            policy: runtimePolicy
        )
        let patchedFunctions = Set(offer.changedFunctions)
            .subtracting(offer.restoredFunctions)
        guard Set(image.module.entries.map(\.functionKey)) == patchedFunctions else {
            throw DevProtocol.Diagnostic(
                code: "HLXLR503",
                message: "HLBC entries do not match the offered FunctionKeys",
                sourceRevision: offer.sourceRevision,
                generationID: offer.generationID,
                backend: .hlbc,
                nextAction: "rebuild the Dev artifact from the latest snapshot"
            )
        }
        let parent = registry.activeLease()?.generation.id
        let generation = try Runtime.Generation(
            id: .init(rawValue: offer.generationID.rawValue),
            parentID: parent,
            packageID: "HLXLive-\(identity.sessionID)-\(offer.sourceRevision.rawValue)",
            packageHash: offer.payloadSHA256,
            images: [image],
            removedEntries: removedEntries,
            estimatedByteCount: bytes.count
        )
        _ = try registry.activate(generation, expectedActiveID: parent)
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
                code: "HLXLR503",
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
        let bytes = totalNativeImageBytes
        let newBytes = bytes.addingReportingOverflow(additionalBytes)
        guard totalNativeImageCount < limits.maximumNativeImageCount,
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
