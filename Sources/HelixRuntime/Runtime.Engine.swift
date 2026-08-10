import Foundation
import HelixBytecode
import HelixCore
import HelixVM

extension Runtime {
public protocol Observing: Sendable {
    func didActivate(generation: Runtime.GenerationID)
    func didRollback(from: Runtime.GenerationID, to: Runtime.GenerationID?)
    func didTrap(generation: Runtime.GenerationID, entry: Core.EntryIndex, trap: VM.RuntimeTrap)
}

public struct NoopObserver: Runtime.Observing {
    public init() {}
    public func didActivate(generation: Runtime.GenerationID) {}
    public func didRollback(from: Runtime.GenerationID, to: Runtime.GenerationID?) {}
    public func didTrap(generation: Runtime.GenerationID, entry: Core.EntryIndex, trap: VM.RuntimeTrap) {}
}

public enum BridgeRoutingResult: Equatable, Sendable {
    case originalRequired
    case executed(VM.ExecutionResult)
}

public final class Engine: @unchecked Sendable {
    private enum OriginalResolution: Equatable {
        case catalog
        case signalBridge
    }

    private enum InvocationOutcome {
        case originalRequired
        case executed(VM.ExecutionResult)
    }

    public let shellInterfaceHash: Core.Digest?
    public let registry: Runtime.GenerationRegistry
    public let originals: Runtime.OriginalCatalog
    public let nativeCatalog: VM.NativeCatalog
    public let nativeTypeCatalog: VM.NativeTypeCatalog
    public let observer: any Runtime.Observing
    public let bridgeInputLimits: Runtime.BridgeInputLimits
    private let contexts = Runtime.ExecutionContextStorage()

    public init(
        registry: Runtime.GenerationRegistry = .init(),
        originals: Runtime.OriginalCatalog,
        shellInterfaceHash: Core.Digest? = nil,
        nativeCatalog: VM.NativeCatalog = .init(),
        nativeTypeCatalog: VM.NativeTypeCatalog = .init(),
        observer: any Runtime.Observing = Runtime.NoopObserver(),
        bridgeInputLimits: Runtime.BridgeInputLimits = .init()
    ) {
        self.registry = registry
        self.originals = originals
        self.shellInterfaceHash = shellInterfaceHash
        self.nativeCatalog = nativeCatalog
        self.nativeTypeCatalog = nativeTypeCatalog
        self.observer = observer
        self.bridgeInputLimits = bridgeInputLimits
    }

    @discardableResult
    public func activate(_ generation: Runtime.Generation, expectedActiveID: Runtime.GenerationID?) throws -> Runtime.GenerationLease {
        try validateForActivation(generation)
        let lease = try registry.activate(generation, expectedActiveID: expectedActiveID)
        observer.didActivate(generation: generation.id)
        return lease
    }

    public func rollback(expectedActiveID: Runtime.GenerationID, to targetID: Runtime.GenerationID?) throws {
        _ = try registry.rollback(expectedActiveID: expectedActiveID, to: targetID)
        observer.didRollback(from: expectedActiveID, to: targetID)
    }

    public func invoke(entry: Core.EntryIndex, arguments: [VM.Value]) -> VM.ExecutionResult {
        executionResult(
            invoke(entry: entry, arguments: arguments, originalResolution: .catalog)
        )
    }

    /// Pins one generation before generated bridge code starts encoding. This
    /// both avoids work for tombstoned routes and derives input limits from the
    /// same immutable generation that will execute the call.
    func routeEncodedFromBridge(
        entry: Core.EntryIndex,
        arguments: (Runtime.BridgeValueCodec.Encoder) throws -> [VM.Value]
    ) throws -> Runtime.BridgeRoutingResult {
        if let context = contexts.current {
            return try routeEncodedFromBridgePinned(
                entry: entry,
                arguments: arguments,
                context: context
            )
        }
        guard let lease = registry.activeLease() else {
            return .originalRequired
        }
        let context = Runtime.ExecutionContext(lease: lease)
        return try contexts.withContext(context) {
            try routeEncodedFromBridgePinned(
                entry: entry,
                arguments: arguments,
                context: context
            )
        }
    }

    public var requiresRouting: Bool {
        guard registry.hasEverActivated else { return false }
        return contexts.current != nil || registry.activeLease() != nil
    }

    private func invoke(
        entry: Core.EntryIndex,
        arguments: [VM.Value],
        originalResolution: OriginalResolution
    ) -> InvocationOutcome {
        if let context = contexts.current {
            return invokePinned(
                entry: entry,
                arguments: arguments,
                context: context,
                originalResolution: originalResolution
            )
        }
        guard let lease = registry.activeLease() else {
            return invokeOriginal(
                entry: entry,
                arguments: arguments,
                resolution: originalResolution
            )
        }
        let context = Runtime.ExecutionContext(lease: lease)
        return contexts.withContext(context) {
            invokePinned(
                entry: entry,
                arguments: arguments,
                context: context,
                originalResolution: originalResolution
            )
        }
    }

    private func invokePinned(
        entry: Core.EntryIndex,
        arguments: [VM.Value],
        context: Runtime.ExecutionContext,
        originalResolution: OriginalResolution
    ) -> InvocationOutcome {
        let route = registry.route(
            for: entry,
            startingAt: context.lease.generation.id
        )
        markNestedEntrySideEffectsIfNeeded(entry: entry, context: context)
        guard let route else {
            let budget = context.isExecutingPatch ? context.budget() : nil
            return invokeOriginal(
                entry: entry,
                arguments: arguments,
                budget: budget,
                resolution: originalResolution
            )
        }
        return invokePatched(
            route: route,
            entry: entry,
            arguments: arguments,
            context: context,
            originalResolution: originalResolution
        )
    }

    private func invokePatched(
        route: Runtime.Route,
        entry: Core.EntryIndex,
        arguments: [VM.Value],
        context: Runtime.ExecutionContext,
        originalResolution: OriginalResolution
    ) -> InvocationOutcome {
        guard context.enter(entry: entry) else {
            return .executed(
                .trapped(.explicit("unexpected native re-entry into patched entry \(entry)"))
            )
        }
        defer { context.leave(entry: entry) }

        let budget = context.budget()
        let interpreter = VM.Interpreter(
            nativeCatalog: nativeCatalog,
            nativeTypeCatalog: nativeTypeCatalog,
            entryInvocation: { [weak self, weak context] nestedEntry, nestedArguments, nestedBudget in
                guard let self, let context else {
                    return .trapped(.explicit("Helix Runtime was released during a nested invocation"))
                }
                guard nestedBudget === budget else {
                    return .trapped(.explicit("nested entry attempted to replace the root invocation budget"))
                }
                return self.executionResult(
                    self.invokePinned(
                        entry: nestedEntry,
                        arguments: nestedArguments,
                        context: context,
                        originalResolution: .catalog
                    )
                )
            }
        )
        let result = interpreter.invoke(
            function: route.functionID,
            image: route.image,
            arguments: arguments,
            budget: budget,
            rootContext: originalResolution == .signalBridge
                ? .generatedAsyncBridge
                : .synchronous
        )
        guard case let .trapped(trap) = result else { return .executed(result) }
        observer.didTrap(generation: context.lease.generation.id, entry: entry, trap: trap)

        if isRuntimeInvariantViolation(trap) {
            let activeBeforeQuarantine = registry.snapshot().activeGenerationID
            registry.quarantine(context.lease.generation.id)
            let activeAfterQuarantine = registry.snapshot().activeGenerationID
            if activeBeforeQuarantine == context.lease.generation.id,
               activeAfterQuarantine != activeBeforeQuarantine {
                observer.didRollback(from: context.lease.generation.id, to: activeAfterQuarantine)
            }
        }
        if let original = originals[entry], original.fallbackAllowed, !budget.sideEffectsCommitted {
            return invokeOriginal(
                entry: entry,
                arguments: arguments,
                resolution: originalResolution
            )
        }
        return .executed(result)
    }

    private func routeEncodedFromBridgePinned(
        entry: Core.EntryIndex,
        arguments: (Runtime.BridgeValueCodec.Encoder) throws -> [VM.Value],
        context: Runtime.ExecutionContext
    ) throws -> Runtime.BridgeRoutingResult {
        guard originals[entry] != nil else {
            return .executed(.trapped(.unknownEntry(entry)))
        }
        guard let route = registry.route(
            for: entry,
            startingAt: context.lease.generation.id
        ) else {
            markNestedEntrySideEffectsIfNeeded(entry: entry, context: context)
            return .originalRequired
        }

        let budget = context.budget()
        let encoder = Runtime.BridgeValueCodec.Encoder(
            limits: bridgeInputLimits.constrained(
                by: context.lease.generation.resourceLimits
            ),
            checkDeadline: { try budget.checkDeadline() }
        )
        let encoded: [VM.Value]
        do {
            encoded = try arguments(encoder)
            try encoder.finalize(arguments: encoded)
        } catch let error as Runtime.BridgeInputError {
            guard originals[entry]?.fallbackAllowed == true else { throw error }
            return .originalRequired
        } catch VM.RuntimeTrap.wallTimeExceeded {
            guard originals[entry]?.fallbackAllowed == true else {
                throw VM.RuntimeTrap.wallTimeExceeded
            }
            return .originalRequired
        }

        markNestedEntrySideEffectsIfNeeded(entry: entry, context: context)
        switch invokePatched(
            route: route,
            entry: entry,
            arguments: encoded,
            context: context,
            originalResolution: .signalBridge
        ) {
        case .originalRequired:
            return .originalRequired
        case let .executed(result):
            return .executed(result)
        }
    }

    private func markNestedEntrySideEffectsIfNeeded(
        entry: Core.EntryIndex,
        context: Runtime.ExecutionContext
    ) {
        guard context.isExecutingPatch,
              registry.entryEffects(
                  for: entry,
                  startingAt: context.lease.generation.id
              )?.hasExternalSideEffects == true
        else {
            return
        }
        // Nested entry calls may execute an original Shell body without
        // passing through a NativeInvoker. Mark before dispatch so a later
        // outer trap can never replay already-committed work.
        context.budget().markSideEffectsCommitted()
    }

    private func invokeOriginal(
        entry: Core.EntryIndex,
        arguments: [VM.Value],
        budget: VM.InvocationBudget? = nil,
        resolution: OriginalResolution
    ) -> InvocationOutcome {
        guard let original = originals[entry] else {
            return .executed(.trapped(.unknownEntry(entry)))
        }
        guard arguments.count == original.parameterTypes.count,
              zip(arguments, original.parameterTypes).allSatisfy({ $0.matches($1) })
        else {
            return .executed(
                .trapped(.nativeFailure("original entry \(entry) argument mismatch"))
            )
        }
        if case .signalBridge = resolution {
            return .originalRequired
        }
        let result = original.invoke(arguments)
        if case let .returned(value) = result {
            if original.resultType == .void, value != nil {
                return .executed(
                    .trapped(.nativeFailure("Void original entry \(entry) returned a value"))
                )
            }
            if original.resultType != .void, !(value?.matches(original.resultType) ?? false) {
                return .executed(
                    .trapped(.nativeFailure("original entry \(entry) result mismatch"))
                )
            }
            if let value, let budget {
                do {
                    try budget.consumeBoundaryValue(value)
                } catch let trap as VM.RuntimeTrap {
                    return .executed(.trapped(trap))
                } catch {
                    return .executed(.trapped(.nativeFailure(String(describing: error))))
                }
            }
        }
        return .executed(result)
    }

    private func executionResult(_ outcome: InvocationOutcome) -> VM.ExecutionResult {
        switch outcome {
        case let .executed(result):
            result
        case .originalRequired:
            .trapped(.explicit("internal Bridge routing signal escaped into catalog dispatch"))
        }
    }

    private func validateForActivation(_ generation: Runtime.Generation) throws {
        let interpreter = VM.Interpreter(
            nativeCatalog: nativeCatalog,
            nativeTypeCatalog: nativeTypeCatalog
        )
        for image in generation.images {
            if let shellInterfaceHash,
               !image.shell.interfaceHash.constantTimeEquals(shellInterfaceHash) {
                throw Runtime.ActivationError.invalidGeneration("image targets a different Shell interface")
            }
            do {
                try interpreter.validate(image: image)
            } catch {
                throw Runtime.ActivationError.invalidGeneration("native catalog binding failed: \(error)")
            }
            for entry in image.module.entries {
                guard let shellEntry = image.shell.entries[entry.entryIndex],
                      let original = originals[entry.entryIndex]
                else {
                    throw Runtime.ActivationError.invalidGeneration(
                        "entry \(entry.entryIndex) has no frozen Shell/original descriptor"
                    )
                }
                guard original.parameterTypes == shellEntry.parameterTypes,
                      original.resultType == shellEntry.resultType,
                      original.fallbackAllowed == shellEntry.fallbackAllowed
                else {
                    throw Runtime.ActivationError.invalidGeneration(
                        "original descriptor mismatch for entry \(entry.entryIndex)"
                    )
                }
            }
        }
        for entry in generation.removedEntries where originals[entry] == nil {
            throw Runtime.ActivationError.invalidGeneration(
                "original-route tombstone references unknown entry \(entry)"
            )
        }
    }

    private func isRuntimeInvariantViolation(_ trap: VM.RuntimeTrap) -> Bool {
        switch trap {
        case .invalidIntegerWidth, .undefinedRegister, .registerAlreadyInitialized,
             .consumedRegister, .unknownStackSlot, .uninitializedStackSlot,
             .stackSlotAlreadyInitialized, .unknownFunction, .invalidProgramCounter,
             .typeMismatch, .unknownNativeImport, .nativeImportDescriptorMismatch,
             .unknownNativeType, .nativeTypeDescriptorMismatch, .nativeTypeMismatch,
             .nativeValueIsNotCopyable, .uninitializedAddress,
             .addressAlreadyInitialized, .invalidAddressProjection,
             .inactiveAddressAccess, .addressWriteRequiresModifyAccess,
             .exclusivityViolation:
            true
        case .integerOverflow, .divisionByZero, .optionalUnwrapOfNil,
             .arrayIndexOutOfBounds, .unknownEntry,
             .instructionFuelExhausted, .callDepthExceeded, .nativeCallLimitExceeded,
             .vmHeapLimitExceeded, .nativeOwnedMemoryLimitExceeded,
             .wallTimeExceeded, .mainActorViolation, .nativeImportThreadViolation,
             .nativeImportDeadlineExceeded, .nativeImportCooperationViolation,
             .nativeFailure, .explicit:
            false
        }
    }
}
}
