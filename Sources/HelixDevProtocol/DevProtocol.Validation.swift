import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixLiveReloadAPI
#endif

extension DevProtocol.BuildIdentity {
    public func validate() throws {
        guard protocolVersion == DevProtocol.SessionIdentity.currentProtocolVersion,
              !sessionID.isZero,
              !executableUUID.isZero,
              [bundleID, architecture, xcodeBuild, swiftCompilerFingerprint].allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 4_096
              })
        else {
            throw DevProtocol.Error.malformedMessage("captured build identity is invalid")
        }
    }

    public func matches(_ identity: DevProtocol.SessionIdentity) -> Bool {
        self == identity.buildIdentity
    }
}

extension DevProtocol.SessionIdentity {
    public func validate() throws {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw DevProtocol.Error.malformedMessage(
                "unsupported protocol version \(protocolVersion)"
            )
        }
        guard !sessionID.isZero, !executableUUID.isZero else {
            throw DevProtocol.Error.malformedMessage("session or executable UUID is zero")
        }
        guard processID > 0 else {
            throw DevProtocol.Error.malformedMessage("processID must be positive")
        }
        let requiredStrings = [
            bundleID, architecture, operatingSystemBuild, xcodeBuild, swiftCompilerFingerprint,
        ]
        guard requiredStrings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 }) else {
            throw DevProtocol.Error.malformedMessage("build identity contains an invalid string")
        }
        guard !supportedBackends.isEmpty,
              supportedBackends.count <= LiveReload.Backend.allCases.count,
              Set(supportedBackends).count == supportedBackends.count,
              supportedBackends == supportedBackends.sorted(by: { $0.rawValue < $1.rawValue })
        else {
            throw DevProtocol.Error.malformedMessage(
                "supported backends must be unique and canonically ordered"
            )
        }
        if nativeChainingProbePassed,
           !supportedBackends.contains(.nativeDynamicReplacement)
        {
            throw DevProtocol.Error.malformedMessage(
                "native chaining probe passed but the native backend is disabled"
            )
        }
        if let activeGenerationID, activeGenerationID.rawValue == 0 {
            throw DevProtocol.Error.malformedMessage(
                "active generation ID must be positive when present"
            )
        }
        if highestAppliedSourceRevision.rawValue == 0, activeGenerationID != nil {
            throw DevProtocol.Error.malformedMessage(
                "an active generation requires an applied source revision"
            )
        }
        guard activeFunctionRoutes.count <= 16_384,
              Set(activeFunctionRoutes.map(\.functionKey)).count == activeFunctionRoutes.count,
              activeFunctionRoutes == activeFunctionRoutes.sorted(by: {
                  $0.functionKey.description < $1.functionKey.description
              }),
              activeFunctionRoutes.allSatisfy({ supportedBackends.contains($0.backend) })
        else {
            throw DevProtocol.Error.malformedMessage(
                "active function routes are duplicated, unordered, oversized, or unsupported"
            )
        }
        if !activeFunctionRoutes.isEmpty, activeGenerationID == nil {
            throw DevProtocol.Error.malformedMessage(
                "active function routes require an active generation"
            )
        }
        if loadedNativeImageCount > 0 || loadedNativeImageBytes > 0
            || nativeImageSoftLimitReached || nativeStateUncertain
        {
            guard supportedBackends.contains(.nativeDynamicReplacement) else {
                throw DevProtocol.Error.malformedMessage(
                    "Native runtime state is present while the Native backend is disabled"
                )
            }
        }
        if loadedNativeImageCount == 0, loadedNativeImageBytes != 0 {
            throw DevProtocol.Error.malformedMessage(
                "Native image bytes require at least one loaded image"
            )
        }
        if loadedNativeImageCount > 0, activeGenerationID == nil {
            throw DevProtocol.Error.malformedMessage(
                "loaded Native images require an active generation"
            )
        }
    }

    public func matchesProcess(of other: Self) -> Bool {
        matchesBuild(of: other)
            && processID == other.processID
            && operatingSystemBuild == other.operatingSystemBuild
    }
}

extension DevProtocol.ReloadHint {
    public func validate() throws {
        try invalidationHints.validate()
        switch policy {
        case .observeOnly:
            guard invalidationHints.isEmpty, factoryID == nil else {
                throw DevProtocol.Error.malformedMessage(
                    "observeOnly cannot invalidate or recreate UI"
                )
            }
        case .invalidate:
            guard nominalTypeID != nil,
                  factoryID == nil,
                  !invalidationHints.isEmpty
            else {
                throw DevProtocol.Error.malformedMessage(
                    "invalidate requires a nominal type, invalidation hints, and no factory"
                )
            }
        case .invokeHook:
            guard nominalTypeID != nil, factoryID == nil else {
                throw DevProtocol.Error.malformedMessage(
                    "invokeHook requires a nominal type and no factory"
                )
            }
        case .recreate:
            guard nominalTypeID != nil,
                  let factoryID,
                  !factoryID.rawValue.isEmpty,
                  factoryID.rawValue.utf8.count <= 512
            else {
                throw DevProtocol.Error.malformedMessage(
                    "recreate requires a nominal type and nonempty factory ID"
                )
            }
        }
    }
}

extension DevProtocol.PatchOffer {
    public func validate() throws {
        guard !sessionID.isZero else {
            throw DevProtocol.Error.malformedMessage("patch offer session UUID is zero")
        }
        guard sourceRevision.rawValue > 0, generationID.rawValue > 0 else {
            throw DevProtocol.Error.malformedMessage(
                "patch offer revision and generation must be positive"
            )
        }
        switch mode {
        case .replacement:
            guard payloadByteLength > 0,
                  backend == .nativeDynamicReplacement
                    || !Set(changedFunctions).subtracting(restoredFunctions).isEmpty
            else {
                throw DevProtocol.Error.malformedMessage("replacement payload is empty")
            }
        case .restoreOriginals:
            guard backend == .hlbc,
                  payloadByteLength == 0,
                  payloadSHA256 == .sha256(Data()),
                  debugSymbolsUUID == nil,
                  reason == .baselineRestored,
                  restoredFunctions == changedFunctions
            else {
                throw DevProtocol.Error.malformedMessage(
                    "restore-originals offer has an invalid backend or payload descriptor"
                )
            }
        }
        guard !changedSources.isEmpty, !changedFunctions.isEmpty,
              changedSources.count <= 16_384,
              changedFunctions.count <= 16_384,
              restoredFunctions.count <= 16_384,
              affectedNominalTypes.count <= 16_384,
              reloadHints.count <= 16_384
        else {
            throw DevProtocol.Error.malformedMessage(
                "patch offer identity lists are empty or exceed their limit"
            )
        }
        try requireCanonicalUnique(changedSources, by: { $0.description })
        try requireCanonicalUnique(changedFunctions, by: { $0.description })
        try requireCanonicalUnique(restoredFunctions, by: { $0.description })
        guard Set(restoredFunctions).isSubset(of: changedFunctions) else {
            throw DevProtocol.Error.malformedMessage(
                "restored FunctionKeys must be a subset of changed FunctionKeys"
            )
        }
        if backend == .nativeDynamicReplacement, debugSymbolsUUID == nil {
            throw DevProtocol.Error.malformedMessage(
                "Native generation is missing its Mach-O UUID"
            )
        }
        try requireCanonicalUnique(affectedNominalTypes, by: { $0.description })
        for hint in reloadHints { try hint.validate() }
    }
}

extension DevProtocol.Diagnostic {
    public func validate() throws {
        let suffix = code.dropFirst("HLXLR".count)
        guard code.hasPrefix("HLXLR"), code.count == 8,
              suffix.count == 3, suffix.allSatisfy(\.isNumber),
              !message.isEmpty, message.utf8.count <= 64 * 1_024,
              !nextAction.isEmpty, nextAction.utf8.count <= 4_096
        else {
            throw DevProtocol.Error.malformedMessage("diagnostic fields are invalid")
        }
    }
}

extension DevProtocol.ActivationResult {
    public func validate() throws {
        guard sourceRevision.rawValue > 0, generationID.rawValue > 0 else {
            throw DevProtocol.Error.malformedMessage(
                "activation result revision and generation must be positive"
            )
        }
        if codeStatus == .codeActive {
            guard diagnostic == nil else {
                throw DevProtocol.Error.malformedMessage(
                    "successful activation cannot carry a rejection diagnostic"
                )
            }
        } else {
            guard reloadStatus == .notRequested, let diagnostic else {
                throw DevProtocol.Error.malformedMessage(
                    "rejected activation must carry a diagnostic and skip UI reload"
                )
            }
            try diagnostic.validate()
        }
    }
}

extension DevProtocol.Message {
    public func validate() throws {
        switch self {
        case let .hello(identity, clientNonce):
            try identity.validate()
            guard clientNonce.count >= 16, clientNonce.count <= 64 else {
                throw DevProtocol.Error.invalidNonceLength
            }
        case let .helloAck(identity, serverNonce, proof):
            try identity.validate()
            guard serverNonce.count >= 16, serverNonce.count <= 64 else {
                throw DevProtocol.Error.invalidNonceLength
            }
            guard proof.count == 32 else {
                throw DevProtocol.Error.malformedMessage("handshake proof must be 32 bytes")
            }
        case let .compileStarted(revision):
            guard revision.rawValue > 0 else {
                throw DevProtocol.Error.malformedMessage("compile revision must be positive")
            }
        case let .diagnostics(diagnostics):
            guard !diagnostics.isEmpty, diagnostics.count <= 256 else {
                throw DevProtocol.Error.malformedMessage("diagnostic batch size is invalid")
            }
            for diagnostic in diagnostics { try diagnostic.validate() }
        case let .patchOffer(offer):
            try offer.validate()
        case let .patchAccept(token), let .patchCommit(token):
            guard !token.rawValue.isZero else {
                throw DevProtocol.Error.malformedMessage("offer token UUID is zero")
            }
        case let .patchReject(diagnostic):
            try diagnostic.validate()
        case let .patchChunk(chunk):
            guard !chunk.token.rawValue.isZero,
                  !chunk.bytes.isEmpty,
                  chunk.bytes.count <= 1_024 * 1_024
            else {
                throw DevProtocol.Error.malformedMessage("patch chunk is empty or too large")
            }
        case let .activationStarted(revision, generation):
            guard revision.rawValue > 0, generation.rawValue > 0 else {
                throw DevProtocol.Error.malformedMessage(
                    "activation identity must be positive"
                )
            }
        case let .activationResult(result):
            try result.validate()
        case let .reloadRequest(context):
            try context.validate()
        case let .reloadResult(_, detail):
            guard detail?.utf8.count ?? 0 <= 16 * 1_024 else {
                throw DevProtocol.Error.malformedMessage("reload detail is too large")
            }
        case .heartbeat:
            break
        case let .sessionClose(reason):
            guard !reason.isEmpty, reason.utf8.count <= 4_096 else {
                throw DevProtocol.Error.malformedMessage("session close reason is invalid")
            }
        case .sessionCloseAcknowledged:
            break
        }
    }
}

private extension LiveReload.Backend {
    static var allCases: [Self] { [.hlbc, .nativeDynamicReplacement] }
}

private extension UUID {
    var isZero: Bool { uuidString == "00000000-0000-0000-0000-000000000000" }
}

private func requireCanonicalUnique<Value: Hashable>(
    _ values: [Value],
    by key: (Value) -> String
) throws {
    guard Set(values).count == values.count,
          values.map(key) == values.map(key).sorted()
    else {
        throw DevProtocol.Error.malformedMessage(
            "identity list must be unique and canonically ordered"
        )
    }
}
