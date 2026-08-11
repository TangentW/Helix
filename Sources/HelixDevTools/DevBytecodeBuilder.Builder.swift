import Foundation
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixLiveReloadAPI

public enum DevBytecodeBuilder {}

extension DevBytecodeBuilder {
public struct Request: Sendable {
    public var sessionID: UUID
    public var sourceRevision: DevProtocol.SourceRevision
    public var generationID: DevProtocol.GenerationID
    public var compileRequest: PatchCompiler.Request
    public var changedSources: [LiveReload.SourceFileID]
    public var changedFunctions: [Core.FunctionKey]
    public var reloadHints: [DevProtocol.ReloadHint]

    public init(
        sessionID: UUID,
        sourceRevision: DevProtocol.SourceRevision,
        generationID: DevProtocol.GenerationID,
        compileRequest: PatchCompiler.Request,
        changedSources: [LiveReload.SourceFileID],
        changedFunctions: [Core.FunctionKey],
        reloadHints: [DevProtocol.ReloadHint] = []
    ) {
        self.sessionID = sessionID
        self.sourceRevision = sourceRevision
        self.generationID = generationID
        self.compileRequest = compileRequest
        self.changedSources = changedSources
        self.changedFunctions = changedFunctions
        self.reloadHints = reloadHints
    }
}

public struct Result: Sendable {
    public var compiledPatch: PatchCompiler.Result
    public var artifact: DevProtocol.LiveArtifact
}

public struct Builder: Sendable {
    public init() {}

    public func build(_ request: DevBytecodeBuilder.Request) throws -> DevBytecodeBuilder.Result {
        let compiled = try PatchCompiler.Driver().compile(request.compileRequest)
        let offer = DevProtocol.PatchOffer(
            sessionID: request.sessionID,
            sourceRevision: request.sourceRevision,
            generationID: request.generationID,
            backend: .hlbc,
            payloadByteLength: UInt64(compiled.bytecode.count),
            payloadSHA256: .sha256(compiled.bytecode),
            changedSources: request.changedSources,
            changedFunctions: request.changedFunctions,
            reloadHints: request.reloadHints
        )
        return .init(
            compiledPatch: compiled,
            artifact: .init(offer: offer, payload: compiled.bytecode)
        )
    }
}
}

public enum DevBackendSelection {}

extension DevBackendSelection {
public enum Reason: String, Codable, Hashable, Sendable {
    case hlbcUnifiedDefault
    case simulatorNativePreferred
    case deviceNativeQualified
    case forcedNative
    case forcedHLBC
    case activeBackendRequired
    case nativeProbeFailed
    case nativeBudgetReached
    case nativeMetadataUnavailable
    case nativeStateUncertain
    case mixedActiveBackends
    case forcedBackendUnavailable
    case unsupported
}

public enum Preference: String, Codable, Hashable, Sendable {
    /// Selects the verified HLBC backend. Automatic selection has the same
    /// behavior and never falls through to executable-image injection.
    case automatic
    /// Selects the internal Native Dynamic Replacement experiment explicitly.
    case native
    /// Selects the verified HLBC backend explicitly.
    case hlbc
}

public struct Input: Sendable {
    public var identity: DevProtocol.SessionIdentity
    public var candidateFunctions: Set<Core.FunctionKey>
    public var nativeEligibleFunctions: Set<Core.FunctionKey>
    public var hlbcEligibleFunctions: Set<Core.FunctionKey>
    public var preference: DevBackendSelection.Preference
    public var deviceNativeMatrixQualified: Bool

    public init(
        identity: DevProtocol.SessionIdentity,
        candidateFunctions: Set<Core.FunctionKey>,
        nativeEligibleFunctions: Set<Core.FunctionKey>,
        hlbcEligibleFunctions: Set<Core.FunctionKey>,
        preference: DevBackendSelection.Preference = .automatic,
        deviceNativeMatrixQualified: Bool = false
    ) {
        self.identity = identity
        self.candidateFunctions = candidateFunctions
        self.nativeEligibleFunctions = nativeEligibleFunctions
        self.hlbcEligibleFunctions = hlbcEligibleFunctions
        self.preference = preference
        self.deviceNativeMatrixQualified = deviceNativeMatrixQualified
    }
}

public struct Decision: Hashable, Sendable {
    public var backend: LiveReload.Backend?
    public var reason: DevBackendSelection.Reason
}

public struct Selector: Sendable {
    public init() {}

    public func select(_ input: DevBackendSelection.Input) -> DevBackendSelection.Decision {
        guard !input.candidateFunctions.isEmpty else {
            return .init(backend: nil, reason: .unsupported)
        }

        let routeMap = Dictionary(
            uniqueKeysWithValues: input.identity.activeFunctionRoutes.map {
                ($0.functionKey, $0.backend)
            }
        )
        let activeBackends = Set(input.candidateFunctions.compactMap { routeMap[$0] })
        if activeBackends.count > 1 {
            return .init(backend: nil, reason: .mixedActiveBackends)
        }
        if let active = activeBackends.first {
            let eligible = active == .nativeDynamicReplacement
                ? input.nativeEligibleFunctions : input.hlbcEligibleFunctions
            guard input.identity.supportedBackends.contains(active),
                  input.candidateFunctions.isSubset(of: eligible)
            else {
                return .init(backend: nil, reason: .unsupported)
            }
            return .init(backend: active, reason: .activeBackendRequired)
        }

        // Native code loading is retained only as an explicit research mode.
        // Product-default routing must remain identical on Simulator and device.
        let nativeAvailable = input.identity.supportedBackends.contains(.nativeDynamicReplacement)
            && input.identity.nativeChainingProbePassed
            && !input.identity.nativeImageSoftLimitReached
            && !input.identity.nativeStateUncertain
            && input.candidateFunctions.isSubset(of: input.nativeEligibleFunctions)
            && (input.identity.platform == .iOSSimulator
                || (input.identity.platform == .iOS && input.deviceNativeMatrixQualified))
        let hlbcAvailable = input.identity.supportedBackends.contains(.hlbc)
            && input.candidateFunctions.isSubset(of: input.hlbcEligibleFunctions)

        switch input.preference {
        case .native:
            return nativeAvailable
                ? .init(backend: .nativeDynamicReplacement, reason: .forcedNative)
                : .init(backend: nil, reason: .forcedBackendUnavailable)
        case .hlbc:
            return hlbcAvailable
                ? .init(backend: .hlbc, reason: .forcedHLBC)
                : .init(backend: nil, reason: .forcedBackendUnavailable)
        case .automatic:
            break
        }
        if hlbcAvailable {
            return .init(backend: .hlbc, reason: .hlbcUnifiedDefault)
        }
        return .init(backend: nil, reason: .unsupported)
    }
}
}
