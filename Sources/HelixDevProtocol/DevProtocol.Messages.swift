import CryptoKit
import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixLiveReloadAPI
#endif

public enum DevProtocol {}

extension DevProtocol {
public enum ApplePlatform: String, Codable, Hashable, Sendable {
    case iOS
    case iOSSimulator
    case macOS
}

public struct SourceRevision: RawRepresentable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "r\(rawValue)" }
}

public struct GenerationID: RawRepresentable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "g\(rawValue)" }
}

public struct ActiveFunctionRoute: Codable, Hashable, Sendable {
    public var functionKey: Core.FunctionKey
    public var backend: LiveReload.Backend

    public init(functionKey: Core.FunctionKey, backend: LiveReload.Backend) {
        self.functionKey = functionKey
        self.backend = backend
    }
}

public struct BuildIdentity: Codable, Hashable, Sendable {
    public var protocolVersion: UInt16
    public var sessionID: UUID
    public var bundleID: String
    public var executableUUID: UUID
    public var platform: DevProtocol.ApplePlatform
    public var architecture: String
    public var xcodeBuild: String
    public var sdkBuild: String
    public var swiftCompilerFingerprint: String
    public var liveReloadIndexHash: Core.Digest

    public init(
        protocolVersion: UInt16 = DevProtocol.SessionIdentity.currentProtocolVersion,
        sessionID: UUID,
        bundleID: String,
        executableUUID: UUID,
        platform: DevProtocol.ApplePlatform,
        architecture: String,
        xcodeBuild: String,
        sdkBuild: String,
        swiftCompilerFingerprint: String,
        liveReloadIndexHash: Core.Digest
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.bundleID = bundleID
        self.executableUUID = executableUUID
        self.platform = platform
        self.architecture = architecture
        self.xcodeBuild = xcodeBuild
        self.sdkBuild = sdkBuild
        self.swiftCompilerFingerprint = swiftCompilerFingerprint
        self.liveReloadIndexHash = liveReloadIndexHash
    }
}

public struct SessionIdentity: Codable, Hashable, Sendable {
    public static let currentProtocolVersion = DevProtocol.Metadata.currentProtocolVersion

    public var protocolVersion: UInt16
    public var sessionID: UUID
    public var bundleID: String
    public var executableUUID: UUID
    public var processID: Int32
    public var platform: DevProtocol.ApplePlatform
    public var architecture: String
    public var operatingSystemBuild: String
    public var xcodeBuild: String
    public var sdkBuild: String
    public var swiftCompilerFingerprint: String
    public var liveReloadIndexHash: Core.Digest
    public var supportedBackends: [LiveReload.Backend]
    public var nativeChainingProbePassed: Bool
    public var highestAppliedSourceRevision: DevProtocol.SourceRevision
    public var activeGenerationID: DevProtocol.GenerationID?
    public var activeFunctionRoutes: [DevProtocol.ActiveFunctionRoute]
    /// Session-local NativeCall capabilities published by successful HLBC
    /// development transactions. They are reconnect inventory, not release ABI.
    public var activeDevelopmentNativeCallKeys: [Core.NativeCall.Key]
    public var loadedDevelopmentAdapterCount: UInt32
    public var loadedDevelopmentAdapterBytes: UInt64
    public var loadedNativeImageCount: UInt32
    public var loadedNativeImageBytes: UInt64
    public var nativeImageSoftLimitReached: Bool
    public var nativeStateUncertain: Bool

    public init(
        protocolVersion: UInt16 = Self.currentProtocolVersion,
        sessionID: UUID,
        bundleID: String,
        executableUUID: UUID,
        processID: Int32,
        platform: DevProtocol.ApplePlatform,
        architecture: String,
        operatingSystemBuild: String,
        xcodeBuild: String,
        sdkBuild: String,
        swiftCompilerFingerprint: String,
        liveReloadIndexHash: Core.Digest,
        supportedBackends: [LiveReload.Backend],
        nativeChainingProbePassed: Bool,
        highestAppliedSourceRevision: DevProtocol.SourceRevision = .init(rawValue: 0),
        activeGenerationID: DevProtocol.GenerationID? = nil,
        activeFunctionRoutes: [DevProtocol.ActiveFunctionRoute] = [],
        activeDevelopmentNativeCallKeys: [Core.NativeCall.Key] = [],
        loadedDevelopmentAdapterCount: UInt32 = 0,
        loadedDevelopmentAdapterBytes: UInt64 = 0,
        loadedNativeImageCount: UInt32 = 0,
        loadedNativeImageBytes: UInt64 = 0,
        nativeImageSoftLimitReached: Bool = false,
        nativeStateUncertain: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.bundleID = bundleID
        self.executableUUID = executableUUID
        self.processID = processID
        self.platform = platform
        self.architecture = architecture
        self.operatingSystemBuild = operatingSystemBuild
        self.xcodeBuild = xcodeBuild
        self.sdkBuild = sdkBuild
        self.swiftCompilerFingerprint = swiftCompilerFingerprint
        self.liveReloadIndexHash = liveReloadIndexHash
        self.supportedBackends = supportedBackends.sorted { $0.rawValue < $1.rawValue }
        self.nativeChainingProbePassed = nativeChainingProbePassed
        self.highestAppliedSourceRevision = highestAppliedSourceRevision
        self.activeGenerationID = activeGenerationID
        self.activeFunctionRoutes = activeFunctionRoutes.sorted {
            $0.functionKey.description < $1.functionKey.description
        }
        self.activeDevelopmentNativeCallKeys = activeDevelopmentNativeCallKeys
            .sorted()
        self.loadedDevelopmentAdapterCount = loadedDevelopmentAdapterCount
        self.loadedDevelopmentAdapterBytes = loadedDevelopmentAdapterBytes
        self.loadedNativeImageCount = loadedNativeImageCount
        self.loadedNativeImageBytes = loadedNativeImageBytes
        self.nativeImageSoftLimitReached = nativeImageSoftLimitReached
        self.nativeStateUncertain = nativeStateUncertain
    }

    public func matchesBuild(of other: Self) -> Bool {
        buildIdentity == other.buildIdentity
    }

    public var buildIdentity: DevProtocol.BuildIdentity {
        .init(
            protocolVersion: protocolVersion,
            sessionID: sessionID,
            bundleID: bundleID,
            executableUUID: executableUUID,
            platform: platform,
            architecture: architecture,
            xcodeBuild: xcodeBuild,
            sdkBuild: sdkBuild,
            swiftCompilerFingerprint: swiftCompilerFingerprint,
            liveReloadIndexHash: liveReloadIndexHash
        )
    }
}

public struct ReloadHint: Codable, Hashable, Sendable {
    public var nominalTypeID: LiveReload.NominalTypeID?
    public var policy: LiveReload.Policy
    public var invalidationHints: LiveReload.InvalidationHints
    public var factoryID: LiveReload.FactoryID?

    public init(
        nominalTypeID: LiveReload.NominalTypeID?,
        policy: LiveReload.Policy,
        invalidationHints: LiveReload.InvalidationHints = [],
        factoryID: LiveReload.FactoryID? = nil
    ) {
        self.nominalTypeID = nominalTypeID
        self.policy = policy
        self.invalidationHints = invalidationHints
        self.factoryID = factoryID
    }
}

public enum PatchMode: String, Codable, Hashable, Sendable {
    case replacement
    case restoreOriginals
}

public struct PatchOffer: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var sourceRevision: DevProtocol.SourceRevision
    public var generationID: DevProtocol.GenerationID
    public var backend: LiveReload.Backend
    public var payloadByteLength: UInt64
    public var payloadSHA256: Core.Digest
    public var changedSources: [LiveReload.SourceFileID]
    public var changedFunctions: [Core.FunctionKey]
    public var restoredFunctions: [Core.FunctionKey]
    public var affectedNominalTypes: [LiveReload.NominalTypeID]
    public var reloadHints: [DevProtocol.ReloadHint]
    public var debugSymbolsUUID: UUID?
    public var reason: LiveReload.Reason
    public var mode: DevProtocol.PatchMode

    public init(
        sessionID: UUID,
        sourceRevision: DevProtocol.SourceRevision,
        generationID: DevProtocol.GenerationID,
        backend: LiveReload.Backend,
        payloadByteLength: UInt64,
        payloadSHA256: Core.Digest,
        changedSources: [LiveReload.SourceFileID],
        changedFunctions: [Core.FunctionKey],
        restoredFunctions: [Core.FunctionKey] = [],
        affectedNominalTypes: [LiveReload.NominalTypeID] = [],
        reloadHints: [DevProtocol.ReloadHint] = [],
        debugSymbolsUUID: UUID? = nil,
        reason: LiveReload.Reason = .sourceSaved,
        mode: DevProtocol.PatchMode = .replacement
    ) {
        self.sessionID = sessionID
        self.sourceRevision = sourceRevision
        self.generationID = generationID
        self.backend = backend
        self.payloadByteLength = payloadByteLength
        self.payloadSHA256 = payloadSHA256
        self.changedSources = changedSources.sorted { $0.description < $1.description }
        self.changedFunctions = changedFunctions.sorted { $0.description < $1.description }
        self.restoredFunctions = restoredFunctions.sorted { $0.description < $1.description }
        self.affectedNominalTypes = affectedNominalTypes.sorted { $0.description < $1.description }
        self.reloadHints = reloadHints
        self.debugSymbolsUUID = debugSymbolsUUID
        self.reason = reason
        self.mode = mode
    }
}

public struct OfferToken: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct PatchChunk: Codable, Hashable, Sendable {
    public var token: DevProtocol.OfferToken
    public var offset: UInt64
    public var bytes: Data

    public init(token: DevProtocol.OfferToken, offset: UInt64, bytes: Data) {
        self.token = token
        self.offset = offset
        self.bytes = bytes
    }
}

public enum CodeActivationStatus: String, Codable, Hashable, Sendable {
    case codeActive
    case rejected
    case nativeStateUncertain
}

public enum UIReloadStatus: String, Codable, Hashable, Sendable {
    case notRequested
    case refreshed
    case manualRefreshRequired
    case failed
}

public struct ActivationResult: Codable, Hashable, Sendable {
    public var sourceRevision: DevProtocol.SourceRevision
    public var generationID: DevProtocol.GenerationID
    public var codeStatus: DevProtocol.CodeActivationStatus
    public var reloadStatus: DevProtocol.UIReloadStatus
    public var diagnostic: DevProtocol.Diagnostic?

    public init(
        sourceRevision: DevProtocol.SourceRevision,
        generationID: DevProtocol.GenerationID,
        codeStatus: DevProtocol.CodeActivationStatus,
        reloadStatus: DevProtocol.UIReloadStatus,
        diagnostic: DevProtocol.Diagnostic? = nil
    ) {
        self.sourceRevision = sourceRevision
        self.generationID = generationID
        self.codeStatus = codeStatus
        self.reloadStatus = reloadStatus
        self.diagnostic = diagnostic
    }
}

public struct Diagnostic: Swift.Error, Codable, Hashable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var sourceRevision: DevProtocol.SourceRevision?
    public var generationID: DevProtocol.GenerationID?
    public var backend: LiveReload.Backend?
    public var previousCodeRemainsActive: Bool
    public var nextAction: String

    public init(
        code: String,
        message: String,
        sourceRevision: DevProtocol.SourceRevision? = nil,
        generationID: DevProtocol.GenerationID? = nil,
        backend: LiveReload.Backend? = nil,
        previousCodeRemainsActive: Bool = true,
        nextAction: String
    ) {
        self.code = code
        self.message = message
        self.sourceRevision = sourceRevision
        self.generationID = generationID
        self.backend = backend
        self.previousCodeRemainsActive = previousCodeRemainsActive
        self.nextAction = nextAction
    }

    public var description: String {
        "\(code) \(message) · \(nextAction)"
    }

    public static func sessionMismatch(_ message: String) -> Self {
        .init(
            code: "HLXLR101",
            message: message,
            nextAction: "restart or pair with the matching Helix Dev Session"
        )
    }

    public static func staleRevision(
        _ revision: DevProtocol.SourceRevision,
        highest: DevProtocol.SourceRevision
    ) -> Self {
        .init(
            code: "HLXLR201",
            message: "source revision \(revision) is not newer than \(highest)",
            sourceRevision: revision,
            nextAction: "discard the stale result and wait for the latest save"
        )
    }
}

public enum Message: Codable, Hashable, Sendable {
    case hello(identity: DevProtocol.SessionIdentity, clientNonce: Data)
    case helloAck(identity: DevProtocol.SessionIdentity, serverNonce: Data, proof: Data)
    case compileStarted(DevProtocol.SourceRevision)
    case diagnostics([DevProtocol.Diagnostic])
    case patchOffer(DevProtocol.PatchOffer)
    case patchAccept(DevProtocol.OfferToken)
    case patchReject(DevProtocol.Diagnostic)
    case patchChunk(DevProtocol.PatchChunk)
    case patchCommit(DevProtocol.OfferToken)
    case activationStarted(DevProtocol.SourceRevision, DevProtocol.GenerationID)
    case activationResult(DevProtocol.ActivationResult)
    case reloadRequest(LiveReload.Context)
    case reloadResult(DevProtocol.UIReloadStatus, String?)
    case heartbeat(UInt64)
    case sessionClose(String)
    case sessionCloseAcknowledged
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSecretLength
    case invalidNonceLength
    case frameTooLarge
    case truncatedFrame
    case invalidAuthentication
    case nonCanonicalMessage
    case malformedMessage(String)
    case invalidArtifact(String)
    case invalidPairingCode
    case secureRandomFailed
    case sessionTimedOut

    public var description: String {
        switch self {
        case .invalidSecretLength: "session secret must contain at least 32 bytes"
        case .invalidNonceLength: "handshake nonces must contain at least 16 bytes"
        case .frameTooLarge: "Dev Protocol frame exceeds its configured limit"
        case .truncatedFrame: "truncated Dev Protocol frame"
        case .invalidAuthentication: "Dev Protocol authentication failed"
        case .nonCanonicalMessage: "Dev Protocol message is not canonical"
        case let .malformedMessage(reason): "malformed Dev Protocol message: \(reason)"
        case let .invalidArtifact(reason): "invalid .hlxlive artifact: \(reason)"
        case .invalidPairingCode:
            "pair code must contain four case-insensitive Helix letters or digits"
        case .secureRandomFailed: "the operating system could not generate secure random bytes"
        case .sessionTimedOut: "Dev Session received no peer activity before its timeout"
        }
    }
}

public enum Metadata {
    public static let currentProtocolVersion: UInt16 = 1
    public static let version = Core.SemanticVersion(1, 0, 0)
}
}
