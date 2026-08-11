import Foundation
import HelixBytecode
import HelixCore
import HelixVM

extension Runtime {
/// Receives Runtime activation, rollback, and trap telemetry.
public protocol Observing: Sendable {
    /// Called after a generation becomes active for new invocations.
    func didActivate(generation: Runtime.GenerationID)
    /// Called after an explicit or quarantine-induced rollback.
    func didRollback(from: Runtime.GenerationID, to: Runtime.GenerationID?)
    /// Called when patched execution traps before fallback or quarantine handling.
    func didTrap(generation: Runtime.GenerationID, entry: Core.EntryIndex, trap: VM.RuntimeTrap)
    /// Called with the deepest known HLBC and logical Swift trap coordinate.
    func didTrap(diagnostic: Runtime.TrapDiagnostic)
}

/// Observer implementation that intentionally discards every Runtime event.
public struct NoopObserver: Runtime.Observing {
    /// Creates a no-op observer.
    public init() {}
    /// Discards activation telemetry.
    public func didActivate(generation: Runtime.GenerationID) {}
    /// Discards rollback telemetry.
    public func didRollback(from: Runtime.GenerationID, to: Runtime.GenerationID?) {}
    /// Discards trap telemetry.
    public func didTrap(generation: Runtime.GenerationID, entry: Core.EntryIndex, trap: VM.RuntimeTrap) {}
}

/// Decision returned to generated bridges after lazy argument encoding.
public enum BridgeRoutingResult: Equatable, Sendable {
    /// No active route exists, or safe encoding fallback selected original code.
    case originalRequired
    /// Patched code executed and produced a VM-level result.
    case executed(VM.ExecutionResult)
}

/// Executes verified HLBC generations and routes instrumented App entry points.
///
/// A root call pins one generation for its complete nested call tree, so an
/// activation racing with execution cannot mix implementations. Generated App
/// code normally reaches this engine through ``Bridge``.
public final class Engine: @unchecked Sendable {
    private enum OriginalResolution: Equatable {
        case catalog
        case signalBridge
    }

    private enum InvocationOutcome {
        case originalRequired
        case executed(VM.ExecutionResult)
    }

    /// Frozen Shell interface identity, required for generated Bridge installation.
    public let shellInterfaceHash: Core.Digest?
    /// Registry that owns immutable generations and active routing state.
    public let registry: Runtime.GenerationRegistry
    /// Original App implementations available for fallback and unpatched routes.
    public let originals: Runtime.OriginalCatalog
    /// Native functions callable from verified bytecode.
    public let nativeCatalog: VM.NativeCatalog
    /// Native Swift value types allowed to cross generated bridges.
    public let nativeTypeCatalog: VM.NativeTypeCatalog
    /// Telemetry sink for activation, rollback, and trap events.
    public let observer: any Runtime.Observing
    /// Host-side ceilings applied before arguments enter the VM.
    public let bridgeInputLimits: Runtime.BridgeInputLimits
    private let contexts = Runtime.ExecutionContextStorage()

    /// Creates a Runtime engine from generated original and native catalogs.
    ///
    /// Pass a non-`nil` `shellInterfaceHash` when the generated ``Bridge`` will
    /// install on this engine.
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

    /// Validates and activates a verified generation with stale-state protection.
    @discardableResult
    public func activate(_ generation: Runtime.Generation, expectedActiveID: Runtime.GenerationID?) throws -> Runtime.GenerationLease {
        try validateForActivation(generation)
        let lease = try registry.activate(generation, expectedActiveID: expectedActiveID)
        observer.didActivate(generation: generation.id)
        return lease
    }

    /// Restores a verified durable generation after Runtime routing returned to
    /// original code, without weakening ordinary generation-ID monotonicity.
    @discardableResult
    public func restore(_ generation: Runtime.Generation) throws -> Runtime.GenerationLease {
        try validateForActivation(generation)
        let lease = try registry.restore(generation)
        observer.didActivate(generation: generation.id)
        return lease
    }

    /// Rolls new invocations back to an ancestor generation or original code.
    public func rollback(expectedActiveID: Runtime.GenerationID, to targetID: Runtime.GenerationID?) throws {
        _ = try registry.rollback(expectedActiveID: expectedActiveID, to: targetID)
        observer.didRollback(from: expectedActiveID, to: targetID)
    }

    /// Invokes a Shell entry from already encoded VM values.
    ///
    /// This low-level API is primarily for tests and nested VM entry calls.
    /// Generated Swift bridges use lazy encoding so original calls avoid bridge
    /// allocation when no patch route exists.
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

    /// Whether generated bridges must consult Runtime routing for this call context.
    ///
    /// The value stays true after the first activation so older thread-pinned
    /// generations can finish safely even if the active pointer rolls back.
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
        let route = context.lease.route(for: entry)
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
        let generationID = context.lease.generation.id
        let image = route.image
        let telemetryObserver = observer
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
            },
            trapObserver: { diagnostic in
                let function = diagnostic.programCounter.flatMap { programCounter in
                    image.module.functions.first { $0.id == programCounter.functionID }
                }
                let sourceLocation = diagnostic.programCounter.flatMap { programCounter in
                    image.module.sourceLocation(
                        functionID: programCounter.functionID,
                        blockID: programCounter.blockID,
                        instructionOffset: programCounter.instructionOffset
                    )
                } ?? function?.sourceLocation
                telemetryObserver.didTrap(
                    diagnostic: .init(
                        generationID: generationID,
                        entry: entry,
                        trap: diagnostic.trap,
                        programCounter: diagnostic.programCounter,
                        functionName: function?.name,
                        sourceLocation: sourceLocation
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
        guard let route = context.lease.route(for: entry) else {
            markNestedEntrySideEffectsIfNeeded(entry: entry, context: context)
            return .originalRequired
        }

        let budget = context.budget()
        let encoder = Runtime.BridgeValueCodec.Encoder(
            limits: bridgeInputLimits.constrained(
                by: context.lease.resourceLimits
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
              context.lease.entryEffects(for: entry)?.hasExternalSideEffects == true
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
