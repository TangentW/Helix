import Foundation
import HelixCore
import HelixDevProtocol
import HelixInterface
import HelixLiveReloadAPI

extension DevCompilation {
public struct BackendCompiler: Sendable {
    public typealias Build = @Sendable (
        DevSession.BuildRequest
    ) async throws -> DevSession.BuildOutcome
    public typealias ActivationRecorder = @Sendable (
        DevProtocol.PatchOffer
    ) async -> Bool

    public var backend: LiveReload.Backend
    public var eligibleFunctionKeys: Set<Core.FunctionKey>
    public var build: Build
    public var didActivate: ActivationRecorder

    public init(
        backend: LiveReload.Backend,
        eligibleFunctionKeys: Set<Core.FunctionKey>,
        build: @escaping Build,
        didActivate: @escaping ActivationRecorder
    ) {
        self.backend = backend
        self.eligibleFunctionKeys = eligibleFunctionKeys
        self.build = build
        self.didActivate = didActivate
    }

    public static func bytecode(
        _ builder: DevCompilation.BytecodeBuilder,
        eligibleFunctionKeys: Set<Core.FunctionKey>
    ) -> Self {
        .init(
            backend: .hlbc,
            eligibleFunctionKeys: eligibleFunctionKeys,
            build: { try await builder.build($0) },
            didActivate: { await builder.didActivate($0) }
        )
    }

    public static func native(
        _ builder: DevCompilation.NativeBuilder,
        eligibleFunctionKeys: Set<Core.FunctionKey>
    ) -> Self {
        .init(
            backend: .nativeDynamicReplacement,
            eligibleFunctionKeys: eligibleFunctionKeys,
            build: { try await builder.build($0) },
            didActivate: { await builder.didActivate($0) }
        )
    }
}

/// Owns backend affinity for a Dev process. Selection is made before compile,
/// and route state advances only after the App confirms code activation.
public actor Router {
    public let identity: DevProtocol.SessionIdentity
    public let reloadIndex: ReloadIndex.Document
    public let preference: DevBackendSelection.Preference
    public let deviceNativeMatrixQualified: Bool

    private let selector = DevBackendSelection.Selector()
    private let compilers: [LiveReload.Backend: DevCompilation.BackendCompiler]
    private var activeBackendByFunction: [Core.FunctionKey: LiveReload.Backend]
    private var nativeImageCount: UInt32
    private var nativeImageSoftLimitReached: Bool
    private var nativeStateUncertain: Bool
    private let nativeImageSoftLimit: UInt32

    public init(
        identity: DevProtocol.SessionIdentity,
        reloadIndex: ReloadIndex.Document,
        preference: DevBackendSelection.Preference = .automatic,
        deviceNativeMatrixQualified: Bool = false,
        nativeImageSoftLimit: UInt32 = 50,
        compilers: [DevCompilation.BackendCompiler]
    ) throws {
        try identity.validate()
        try reloadIndex.validate()
        guard nativeImageSoftLimit > 0, !compilers.isEmpty,
              Set(compilers.map(\.backend)).count == compilers.count,
              compilers.allSatisfy({ identity.supportedBackends.contains($0.backend) })
        else {
            throw DevProtocol.Error.malformedMessage(
                "Dev compiler backends are duplicated, unsupported, or misconfigured"
            )
        }
        let compilerMap = Dictionary(uniqueKeysWithValues: compilers.map { ($0.backend, $0) })
        let knownRoots = Set(reloadIndex.roots.map(\.functionKey))
        let activeRoutes = Dictionary(
            uniqueKeysWithValues: identity.activeFunctionRoutes.map {
                ($0.functionKey, $0.backend)
            }
        )
        guard compilers.allSatisfy({ $0.eligibleFunctionKeys.isSubset(of: knownRoots) }),
              Set(activeRoutes.keys).isSubset(of: knownRoots),
              activeRoutes.allSatisfy({ key, backend in
                  compilerMap[backend]?.eligibleFunctionKeys.contains(key) == true
              })
        else {
            throw DevProtocol.Error.malformedMessage(
                "the reconnect inventory cannot be served by this Reload Index and compiler set"
            )
        }
        self.identity = identity
        self.reloadIndex = reloadIndex
        self.preference = preference
        self.deviceNativeMatrixQualified = deviceNativeMatrixQualified
        self.nativeImageSoftLimit = nativeImageSoftLimit
        self.compilers = compilerMap
        activeBackendByFunction = activeRoutes
        nativeImageCount = identity.loadedNativeImageCount
        nativeImageSoftLimitReached = identity.nativeImageSoftLimitReached
        nativeStateUncertain = identity.nativeStateUncertain
    }

    public static func configured(
        identity: DevProtocol.SessionIdentity,
        archive: InterfaceArchive.Archive,
        manifest: DevBuildManifest.Document,
        reloadIndex: ReloadIndex.Document,
        compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
        nativeOutputDirectory: URL,
        preference: DevBackendSelection.Preference = .automatic,
        deviceNativeMatrixQualified: Bool = false,
        nativeImageSoftLimit: UInt32 = 50,
        runner: ProcessExecution.Runner = .init()
    ) throws -> DevCompilation.Router {
        let routes = Dictionary(
            uniqueKeysWithValues: identity.activeFunctionRoutes.map {
                ($0.functionKey, $0.backend)
            }
        )
        var compilers: [DevCompilation.BackendCompiler] = []
        if identity.supportedBackends.contains(.hlbc) {
            let eligible = Set(
                archive.functions.filter(\.patchability.isEligible).map(\.key)
            ).intersection(
                Set(reloadIndex.roots.map(\.functionKey))
            )
            let builder = DevCompilation.BytecodeBuilder(
                archive: archive,
                manifest: manifest,
                compilerURL: compilerURL,
                initiallyActiveFunctions: Set(routes.compactMap {
                    $0.value == .hlbc ? $0.key : nil
                })
            )
            compilers.append(.bytecode(builder, eligibleFunctionKeys: eligible))
        }
        if identity.supportedBackends.contains(.nativeDynamicReplacement) {
            let eligible = Set(reloadIndex.nativeReplacements.map(\.functionKey))
            let builder = try DevCompilation.NativeBuilder(
                archive: archive,
                manifest: manifest,
                reloadIndex: reloadIndex,
                compilerURL: compilerURL,
                outputDirectory: nativeOutputDirectory,
                initiallyActiveFunctions: Set(routes.compactMap {
                    $0.value == .nativeDynamicReplacement ? $0.key : nil
                }),
                runner: runner
            )
            compilers.append(.native(builder, eligibleFunctionKeys: eligible))
        }
        return try .init(
            identity: identity,
            reloadIndex: reloadIndex,
            preference: preference,
            deviceNativeMatrixQualified: deviceNativeMatrixQualified,
            nativeImageSoftLimit: nativeImageSoftLimit,
            compilers: compilers
        )
    }

    public func selection(
        for candidateFunctions: Set<Core.FunctionKey>
    ) -> DevBackendSelection.Decision {
        var current = identity
        current.activeFunctionRoutes = routes()
        current.loadedNativeImageCount = nativeImageCount
        current.nativeImageSoftLimitReached = nativeImageSoftLimitReached
            || nativeImageCount >= nativeImageSoftLimit
        current.nativeStateUncertain = nativeStateUncertain
        return selector.select(
            .init(
                identity: current,
                candidateFunctions: candidateFunctions,
                nativeEligibleFunctions: compilers[.nativeDynamicReplacement]?
                    .eligibleFunctionKeys ?? [],
                hlbcEligibleFunctions: compilers[.hlbc]?.eligibleFunctionKeys ?? [],
                preference: preference,
                deviceNativeMatrixQualified: deviceNativeMatrixQualified
            )
        )
    }

    public func build(
        _ request: DevSession.BuildRequest
    ) async throws -> DevSession.BuildOutcome {
        let decision = selection(for: request.candidateFunctionKeys)
        guard let backend = decision.backend, let compiler = compilers[backend] else {
            return .rebuildRequired(
                diagnostic(
                    code: decision.reason == .mixedActiveBackends ? "HLXLR504" : "HLXLR502",
                    message: "no safe Dev backend can compile this source transaction (\(decision.reason.rawValue))",
                    request: request,
                    backend: nil,
                    nextAction: decision.reason == .mixedActiveBackends
                        ? "restore the file to baseline or restart the App before changing its backend affinity"
                        : "select a supported backend or perform a full build"
                )
            )
        }
        let outcome = try await compiler.build(request)
        guard case let .patch(patch) = outcome else { return outcome }
        guard patch.backend == backend,
              !patch.changedFunctions.isEmpty,
              patch.changedFunctions.isSubset(of: request.candidateFunctionKeys),
              patch.changedFunctions.isSubset(of: compiler.eligibleFunctionKeys),
              patch.restoredFunctions.isSubset(of: patch.changedFunctions),
              patch.restoredFunctions.allSatisfy({ activeBackendByFunction[$0] == backend }),
              patch.changedFunctions.allSatisfy({
                  activeBackendByFunction[$0] == nil || activeBackendByFunction[$0] == backend
              })
        else {
            return .rebuildRequired(
                diagnostic(
                    code: "HLXLR504",
                    message: "compiler output violates the active backend affinity",
                    request: request,
                    backend: backend,
                    nextAction: "restart the App before switching backend for an active function"
                )
            )
        }
        return outcome
    }

    @discardableResult
    public func didActivate(_ offer: DevProtocol.PatchOffer) async -> Bool {
        guard (try? offer.validate()) != nil,
              offer.sessionID == identity.sessionID,
              let compiler = compilers[offer.backend],
              Set(offer.changedFunctions).isSubset(of: compiler.eligibleFunctionKeys),
              offer.restoredFunctions.allSatisfy({
                  activeBackendByFunction[$0] == offer.backend
              }),
              offer.changedFunctions.allSatisfy({
                  activeBackendByFunction[$0] == nil
                      || activeBackendByFunction[$0] == offer.backend
              }),
              await compiler.didActivate(offer)
        else { return false }
        let restored = Set(offer.restoredFunctions)
        for function in offer.changedFunctions {
            if restored.contains(function) {
                activeBackendByFunction.removeValue(forKey: function)
            } else {
                activeBackendByFunction[function] = offer.backend
            }
        }
        if offer.backend == .nativeDynamicReplacement, nativeImageCount < UInt32.max {
            nativeImageCount += 1
        }
        return true
    }

    /// Records both successful activation and terminal Native state reported by
    /// the App. Rejected code never advances compiler-side function affinity.
    @discardableResult
    public func didReceiveActivation(
        offer: DevProtocol.PatchOffer,
        result: DevProtocol.ActivationResult
    ) async -> Bool {
        guard result.sourceRevision == offer.sourceRevision,
              result.generationID == offer.generationID
        else { return false }
        switch result.codeStatus {
        case .codeActive:
            return await didActivate(offer)
        case .nativeStateUncertain:
            if offer.backend == .nativeDynamicReplacement { nativeStateUncertain = true }
        case .rejected:
            if offer.backend == .nativeDynamicReplacement,
               result.diagnostic?.code == "HLXLR701"
            {
                nativeImageSoftLimitReached = true
            }
        }
        return false
    }

    public var activeFunctionRoutes: [DevProtocol.ActiveFunctionRoute] {
        routes()
    }

    private func routes() -> [DevProtocol.ActiveFunctionRoute] {
        activeBackendByFunction.map {
            .init(functionKey: $0.key, backend: $0.value)
        }.sorted { $0.functionKey.description < $1.functionKey.description }
    }

    private func diagnostic(
        code: String,
        message: String,
        request: DevSession.BuildRequest,
        backend: LiveReload.Backend?,
        nextAction: String
    ) -> DevProtocol.Diagnostic {
        .init(
            code: code,
            message: message,
            sourceRevision: request.snapshot.revision,
            generationID: request.generationID,
            backend: backend,
            nextAction: nextAction
        )
    }
}
}
