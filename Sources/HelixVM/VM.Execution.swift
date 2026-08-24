import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

extension VM {
public enum RuntimeTrap: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidIntegerWidth(UInt16)
    case invalidFloatingPointWidth(UInt16)
    case invalidFloatingPointBitPattern(UInt64, bitWidth: UInt16)
    case integerOverflow
    case divisionByZero
    case typeMismatch(expected: Bytecode.ValueType, actual: Bytecode.ValueType?)
    case undefinedRegister(Bytecode.Register)
    case registerAlreadyInitialized(Bytecode.Register)
    case consumedRegister(Bytecode.Register)
    case unknownStackSlot(Bytecode.StackSlot)
    case uninitializedStackSlot(Bytecode.StackSlot)
    case stackSlotAlreadyInitialized(Bytecode.StackSlot)
    case uninitializedAddress
    case addressAlreadyInitialized
    case invalidAddressProjection
    case inactiveAddressAccess
    case addressWriteRequiresModifyAccess
    case exclusivityViolation
    case optionalUnwrapOfNil
    case danglingUnownedReference
    case dynamicCastFailure(
        actual: Bytecode.DynamicType,
        expected: Bytecode.DynamicType
    )
    case existentialCastFailure(actual: Bytecode.DynamicType)
    case existentialDispatchFailure(actual: Bytecode.DynamicType)
    case dynamicCastProducedDuplicateDictionaryKey
    case dynamicCastProducedDuplicateSetElement
    case valueNestingDepthExceeded(maximum: Int)
    case arrayIndexOutOfBounds(index: Int64, count: Int)
    case collectionCursorOutOfBounds(index: Int64, count: Int)
    case unknownFunction(Bytecode.FunctionID)
    case unknownEntry(Core.EntryIndex)
    case unknownNativeImport(Core.NativeImportID)
    case nativeImportDescriptorMismatch(Core.NativeImportID)
    case nativeImportThreadViolation(Core.NativeImportID)
    case nativeImportDeadlineExceeded(Core.NativeImportID)
    case nativeImportCooperationViolation(Core.NativeImportID)
    case unknownNativeType(Core.TypeID)
    case nativeTypeDescriptorMismatch(Core.TypeID)
    case nativeTypeMismatch(expected: Core.TypeID)
    case nativeValueIsNotCopyable(Core.TypeID)
    case mainActorViolation
    case invalidProgramCounter
    case instructionFuelExhausted
    case callDepthExceeded
    case nativeCallLimitExceeded
    case vmHeapLimitExceeded
    case nativeOwnedMemoryLimitExceeded
    case wallTimeExceeded
    case suspendedFrameLimitExceeded
    case executionCancelled
    case nativeFailure(String)
    case sourceFailure(prefix: String, detail: String)
    case explicit(String)

    public var description: String {
        switch self {
        case let .invalidIntegerWidth(width): "invalid integer width \(width)"
        case let .invalidFloatingPointWidth(width):
            "invalid floating-point width \(width)"
        case let .invalidFloatingPointBitPattern(bitPattern, width):
            "floating-point bit pattern 0x\(String(bitPattern, radix: 16)) does not fit \(width) bits"
        case .integerOverflow: "integer overflow"
        case .divisionByZero: "division by zero"
        case let .typeMismatch(expected, actual): "type mismatch: expected \(expected), got \(actual?.description ?? "no value")"
        case let .undefinedRegister(register): "undefined register \(register)"
        case let .registerAlreadyInitialized(register): "register \(register) is already initialized"
        case let .consumedRegister(register): "register \(register) was consumed"
        case let .unknownStackSlot(slot): "unknown stack slot \(slot)"
        case let .uninitializedStackSlot(slot): "stack slot \(slot) is uninitialized"
        case let .stackSlotAlreadyInitialized(slot): "stack slot \(slot) is already initialized"
        case .uninitializedAddress: "address points to uninitialized storage"
        case .addressAlreadyInitialized: "address storage is already initialized"
        case .invalidAddressProjection: "address projection does not match its stored value"
        case .inactiveAddressAccess: "address access is inactive"
        case .addressWriteRequiresModifyAccess: "address write requires modify access"
        case .exclusivityViolation: "overlapping address access violates exclusivity"
        case .optionalUnwrapOfNil: "attempted to unwrap a nil Optional"
        case .danglingUnownedReference:
            "attempted to load an unowned reference after deallocation"
        case let .dynamicCastFailure(actual, expected):
            "could not cast value of type \(actual) to \(expected)"
        case let .existentialCastFailure(actual):
            "value of type \(actual) does not satisfy the closed protocol cast"
        case let .existentialDispatchFailure(actual):
            "no closed protocol witness target exists for \(actual)"
        case .dynamicCastProducedDuplicateDictionaryKey:
            "Dictionary dynamic cast produced duplicate keys"
        case .dynamicCastProducedDuplicateSetElement:
            "Set dynamic cast produced duplicate elements"
        case let .valueNestingDepthExceeded(maximum):
            "VM value nesting exceeds \(maximum) levels"
        case let .arrayIndexOutOfBounds(index, count):
            "Array index \(index) is outside 0..<\(count)"
        case let .collectionCursorOutOfBounds(index, count):
            "collection cursor \(index) is outside 0...\(count)"
        case let .unknownFunction(function): "unknown HLBC function \(function)"
        case let .unknownEntry(entry): "unknown Shell entry \(entry)"
        case let .unknownNativeImport(importID): "unknown native import \(importID)"
        case let .nativeImportDescriptorMismatch(importID):
            "native invoker descriptor does not match the frozen Shell import \(importID)"
        case let .nativeImportThreadViolation(importID):
            "native import \(importID) is not qualified for main-thread execution"
        case let .nativeImportDeadlineExceeded(importID):
            "native import \(importID) exceeded its declared synchronous deadline"
        case let .nativeImportCooperationViolation(importID):
            "cooperative native import \(importID) returned without a deadline checkpoint"
        case let .unknownNativeType(typeID): "unknown native type \(typeID)"
        case let .nativeTypeDescriptorMismatch(typeID):
            "native TypeOps descriptor does not match the frozen Shell type \(typeID)"
        case let .nativeTypeMismatch(typeID): "native value does not match type \(typeID)"
        case let .nativeValueIsNotCopyable(typeID): "native value \(typeID) is not copyable"
        case .mainActorViolation: "MainActor HLBC entry ran off the main thread"
        case .invalidProgramCounter: "invalid HLBC program counter"
        case .instructionFuelExhausted: "instruction fuel exhausted"
        case .callDepthExceeded: "maximum HLBC call depth exceeded"
        case .nativeCallLimitExceeded: "maximum native call count exceeded"
        case .vmHeapLimitExceeded: "maximum HLVM heap budget exceeded"
        case .nativeOwnedMemoryLimitExceeded: "maximum native-owned memory budget exceeded"
        case .wallTimeExceeded: "HLBC wall-time budget exceeded"
        case .suspendedFrameLimitExceeded: "maximum suspended HLVM frame count exceeded"
        case .executionCancelled: "HLBC execution was cancelled"
        case let .nativeFailure(message): "native invocation failed: \(message)"
        case let .sourceFailure(prefix, detail):
            detail.isEmpty ? prefix : "\(prefix): \(detail)"
        case let .explicit(message): message
        }
    }
}

public enum ExecutionResult: Equatable, Sendable {
    case returned(VM.Value?)
    case businessError(String)
    case trapped(VM.RuntimeTrap)
}

/// Identifies the HLBC instruction that was executing when a Runtime trap began.
public struct ProgramCounter: Codable, Hashable, Sendable, CustomStringConvertible {
    public var functionID: Bytecode.FunctionID
    public var blockID: Bytecode.BlockID
    public var instructionOffset: UInt32

    public init(
        functionID: Bytecode.FunctionID,
        blockID: Bytecode.BlockID,
        instructionOffset: UInt32
    ) {
        self.functionID = functionID
        self.blockID = blockID
        self.instructionOffset = instructionOffset
    }

    public var description: String {
        "\(functionID).\(blockID)#\(instructionOffset)"
    }
}

/// Structured VM-only trap context. Runtime enriches this coordinate with the
/// active generation, Shell entry, function name, and logical Swift location.
public struct TrapDiagnostic: Equatable, Sendable {
    public var trap: VM.RuntimeTrap
    public var programCounter: VM.ProgramCounter?

    public init(
        trap: VM.RuntimeTrap,
        programCounter: VM.ProgramCounter?
    ) {
        self.trap = trap
        self.programCounter = programCounter
    }
}

public typealias TrapObserver = @Sendable (VM.TrapDiagnostic) -> Void

/// Identifies who owns values at one interpreter root boundary. Ordinary Shell
/// calls accept only portable boundary values; Runtime-hosted image callbacks
/// may re-enter with object identities already owned by the pinned image.
package enum RootArgumentDomain: Sendable {
    case shell
    case hostedImage

    var permitsPatchLocalObjectArguments: Bool {
        self == .hostedImage
    }
}

public final class InvocationBudget: @unchecked Sendable {
    private let lock = NSLock()
    package let resourceLimits: Core.ResourceLimits
    private var remainingFuel: UInt64
    private var currentDepth: UInt32 = 0
    private var nativeCalls: UInt32 = 0
    private let maximumDepth: UInt32
    private let maximumNativeCalls: UInt32
    private var remainingVMHeapBytes: UInt64
    private var remainingNativeOwnedBytes: UInt64
    private var deadlineNanoseconds: UInt64
    private let nowNanoseconds: @Sendable () -> UInt64
    private var sideEffectsCommittedStorage = false
    private var cancellationRequested = false
    private var suspensionStartedNanoseconds: UInt64?

    public convenience init(
        limits: Core.ResourceLimits,
        isMainThread: Bool = Thread.isMainThread
    ) {
        self.init(
            limits: limits,
            isMainThread: isMainThread,
            nowNanoseconds: { DispatchTime.now().uptimeNanoseconds }
        )
    }

    init(
        limits: Core.ResourceLimits,
        isMainThread: Bool,
        nowNanoseconds: @escaping @Sendable () -> UInt64
    ) {
        resourceLimits = limits
        remainingFuel = limits.instructionFuelPerEntry
        maximumDepth = limits.maxCallDepth
        maximumNativeCalls = limits.maxNativeCallsPerEntry
        remainingVMHeapBytes = limits.maxVMHeapBytes
        remainingNativeOwnedBytes = limits.maxNativeOwnedBytes
        self.nowNanoseconds = nowNanoseconds
        let milliseconds = isMainThread
            ? limits.maxWallTimeMainThreadMilliseconds
            : limits.maxWallTimeBackgroundMilliseconds
        let delta = UInt64(milliseconds) * 1_000_000
        let deadline = nowNanoseconds().addingReportingOverflow(delta)
        deadlineNanoseconds = deadline.overflow ? UInt64.max : deadline.partialValue
    }

    public var sideEffectsCommitted: Bool {
        lock.withLock { sideEffectsCommittedStorage }
    }

    public func markSideEffectsCommitted() {
        lock.withLock { sideEffectsCommittedStorage = true }
    }

    /// Requests cooperative cancellation. Async execution checks this before
    /// suspension, after resumption, and at every ordinary budget checkpoint.
    public func cancel() {
        lock.withLock { cancellationRequested = true }
    }

    /// Verifies that the currently retained HLBC frame stack may cross one
    /// suspension point. This check is separate from active-time accounting:
    /// actor hops and nested patched entries retain frames but continue to
    /// charge root time, while an exact async NativeImport pauses root time.
    package func checkSuspensionPoint() throws {
        try lock.withLock {
            try ensureWithinDeadline()
            guard currentDepth > 0,
                  currentDepth <= resourceLimits.maxSuspendedFrames
            else {
                throw VM.RuntimeTrap.suspendedFrameLimitExceeded
            }
        }
    }

    package func beginSuspension() throws {
        try lock.withLock {
            try ensureWithinDeadline()
            guard suspensionStartedNanoseconds == nil else {
                throw VM.RuntimeTrap.nativeFailure(
                    "one invocation attempted nested host suspension"
                )
            }
            guard currentDepth > 0,
                  currentDepth <= resourceLimits.maxSuspendedFrames else {
                throw VM.RuntimeTrap.suspendedFrameLimitExceeded
            }
            suspensionStartedNanoseconds = nowNanoseconds()
        }
    }

    package func endSuspension() throws {
        try lock.withLock {
            guard let started = suspensionStartedNanoseconds else {
                throw VM.RuntimeTrap.nativeFailure(
                    "one invocation resumed without an active suspension"
                )
            }
            suspensionStartedNanoseconds = nil
            let elapsed = nowNanoseconds().subtractingReportingOverflow(started)
            guard !elapsed.overflow else { throw VM.RuntimeTrap.wallTimeExceeded }
            let shifted = deadlineNanoseconds.addingReportingOverflow(
                elapsed.partialValue
            )
            deadlineNanoseconds = shifted.overflow
                ? UInt64.max : shifted.partialValue
            try ensureWithinDeadline()
        }
    }

    func consumeInstruction(weight: UInt64 = 1) throws {
        try lock.withLock {
            guard remainingFuel >= weight else { throw VM.RuntimeTrap.instructionFuelExhausted }
            remainingFuel -= weight
            try ensureWithinDeadline()
        }
    }

    /// Charges deterministic work performed inside one HLBC instruction. The
    /// instruction itself is charged separately, so zero additional work is valid.
    func consumeWork(units: UInt64) throws {
        guard units > 0 else {
            try checkDeadline()
            return
        }
        try consumeInstruction(weight: units)
    }

    /// One unit represents up to 16 UTF-8 bytes. Fuel remains useful for large
    /// Unicode operations without making ordinary UI strings prohibitively costly.
    func consumeUTF8Work(byteCount: Int) throws {
        guard byteCount >= 0 else { throw VM.RuntimeTrap.instructionFuelExhausted }
        let bytes = UInt64(byteCount)
        guard bytes > 0 else {
            try checkDeadline()
            return
        }
        let adjusted = bytes.addingReportingOverflow(15)
        guard !adjusted.overflow else { throw VM.RuntimeTrap.instructionFuelExhausted }
        try consumeWork(units: adjusted.partialValue / 16)
    }

    /// Conservatively bounds substring search even if the standard library
    /// selects a comparison strategy with input-dependent behavior.
    func consumeSubstringSearchWork(
        haystackByteCount: Int,
        patternByteCount: Int
    ) throws {
        guard haystackByteCount >= 0, patternByteCount >= 0 else {
            throw VM.RuntimeTrap.instructionFuelExhausted
        }
        try consumeUTF8Work(byteCount: haystackByteCount)
        try consumeUTF8Work(byteCount: patternByteCount)
        let haystack = UInt64(haystackByteCount)
        let pattern = UInt64(patternByteCount)
        let starts: UInt64
        if haystack >= pattern {
            let candidateCount = (haystack - pattern).addingReportingOverflow(1)
            guard !candidateCount.overflow else {
                throw VM.RuntimeTrap.instructionFuelExhausted
            }
            starts = candidateCount.partialValue
        } else {
            starts = 1
        }
        let width = max(pattern, 1)
        let comparisons = starts.multipliedReportingOverflow(by: width)
        guard !comparisons.overflow else {
            throw VM.RuntimeTrap.instructionFuelExhausted
        }
        let adjusted = comparisons.partialValue.addingReportingOverflow(15)
        guard !adjusted.overflow else {
            throw VM.RuntimeTrap.instructionFuelExhausted
        }
        try consumeWork(units: adjusted.partialValue / 16)
    }

    func consumeLinearWork(elementCount: Int) throws {
        guard elementCount >= 0, let units = UInt64(exactly: elementCount) else {
            throw VM.RuntimeTrap.instructionFuelExhausted
        }
        try consumeWork(units: units)
    }

    /// Charges one complete immutable VM value traversal. Hashing, equality,
    /// logical type validation, and similar helpers must use this instead of
    /// hiding aggregate or Unicode work inside a single HLBC instruction.
    func consumeValueTraversal(
        _ value: VM.Value,
        depth: Int = 0
    ) throws {
        guard depth <= VM.ValueLimits.maximumNestingDepth else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(
                maximum: VM.ValueLimits.maximumNestingDepth
            )
        }
        try consumeWork(units: 1)
        switch value {
        case let .string(string):
            try consumeUTF8Work(byteCount: string.utf8.count)
        case let .any(erased):
            try consumeValueTraversal(erased.payload, depth: depth + 1)
        case let .tuple(elements):
            for element in elements {
                try consumeValueTraversal(element, depth: depth + 1)
            }
        case let .array(storage):
            for element in storage.elements {
                try consumeValueTraversal(element, depth: depth + 1)
            }
        case let .dictionary(entries, _, _):
            for entry in entries {
                try consumeValueTraversal(entry.key, depth: depth + 1)
                try consumeValueTraversal(entry.value, depth: depth + 1)
            }
        case let .set(set):
            for element in set.elements {
                try consumeValueTraversal(element, depth: depth + 1)
            }
        case let .optional(.some(wrapped)):
            try consumeValueTraversal(wrapped, depth: depth + 1)
        case let .structure(_, fields):
            for field in fields {
                try consumeValueTraversal(field, depth: depth + 1)
            }
        case let .enumeration(_, _, payload):
            if let payload {
                try consumeValueTraversal(payload, depth: depth + 1)
            }
        case let .error(error):
            try consumeUTF8Work(byteCount: error.message.utf8.count)
            if let payload = error.payload {
                try consumeValueTraversal(payload, depth: depth + 1)
            }
        case let .closure(closure):
            for capture in closure.captures {
                try consumeValueTraversal(capture, depth: depth + 1)
            }
        case .object, .optional(nil), .native, .bool, .integer, .float,
             .address, .mutableCell, .nonOwningReference,
             .arrayBuilder, .arrayMutationState,
             .dictionaryBuilder, .arraySortState, .arraySplitState:
            break
        }
    }

    /// Evaluates recursive VM-defined equality with traversal fuel and the
    /// peak scratch needed by unordered nested collections.
    func valuesEqual(_ lhs: VM.Value, _ rhs: VM.Value) throws -> Bool {
        try consumeValueTraversal(lhs)
        try consumeValueTraversal(rhs)
        let scratchBytes = try VM.HashableValue.equalityScratchBytes(for: rhs)
        guard scratchBytes > 0 else {
            return VM.HashableValue.equal(lhs, rhs)
        }
        return try withReservedVMHeap(maximumBytes: scratchBytes) {
            (value: VM.HashableValue.equal(lhs, rhs), actualBytes: 0)
        }
    }

    public func checkDeadline() throws {
        try lock.withLock { try ensureWithinDeadline() }
    }

    func enterFrame() throws {
        try lock.withLock {
            guard currentDepth < maximumDepth else { throw VM.RuntimeTrap.callDepthExceeded }
            currentDepth += 1
        }
    }

    func leaveFrame() {
        lock.withLock {
            precondition(currentDepth > 0, "unbalanced HLVM frame budget")
            currentDepth -= 1
        }
    }

    func consumeNativeCall(hasSideEffects: Bool) throws {
        try lock.withLock {
            guard nativeCalls < maximumNativeCalls else { throw VM.RuntimeTrap.nativeCallLimitExceeded }
            nativeCalls += 1
            if hasSideEffects { sideEffectsCommittedStorage = true }
        }
    }

    func beginNativeInvocation(
        id: Core.NativeImportID,
        effects: Core.Effects,
        contract: Core.NativeImportContract,
        parameterTypes: [Bytecode.ValueType] = [],
        callbackHost: VM.NativeCallbackHost? = nil,
        isMainThread: Bool = Thread.isMainThread
    ) throws -> VM.NativeInvocationContext {
        try contract.validate(effects: effects)
        guard effects.isAsync
                || !isMainThread
                || contract.execution.allowsMainThread else {
            throw VM.RuntimeTrap.nativeImportThreadViolation(id)
        }
        guard effects.isAsync
                || !effects.requiresMainActor
                || isMainThread else {
            throw VM.RuntimeTrap.mainActorViolation
        }
        return try lock.withLock {
            try ensureWithinDeadline()
            guard nativeCalls < maximumNativeCalls else {
                throw VM.RuntimeTrap.nativeCallLimitExceeded
            }
            nativeCalls += 1
            if effects.hasExternalSideEffects { sideEffectsCommittedStorage = true }
            let delta = UInt64(contract.execution.maximumDurationMicroseconds)
                .multipliedReportingOverflow(by: 1_000)
            let now = nowNanoseconds()
            let candidate = now.addingReportingOverflow(delta.partialValue)
            let exactDeadline = delta.overflow || candidate.overflow
                ? UInt64.max : candidate.partialValue
            let importDeadline = contract.execution.deadlineMode == .suspending
                ? exactDeadline : min(deadlineNanoseconds, exactDeadline)
            return VM.NativeInvocationContext(
                id: id,
                budget: self,
                deadlineNanoseconds: importDeadline,
                requiresCooperation: contract.execution.deadlineMode == .cooperative,
                requiresMainActor: effects.requiresMainActor,
                requiresAsyncMainActorEntry: effects.isAsync
                    && effects.requiresMainActor,
                callbacks: contract.callbacks,
                parameterTypes: parameterTypes,
                callbackHost: callbackHost
            )
        }
    }

    func checkpointNativeInvocation(
        id: Core.NativeImportID,
        deadlineNanoseconds: UInt64,
        workUnits: UInt64
    ) throws {
        try lock.withLock {
            guard remainingFuel >= workUnits else {
                throw VM.RuntimeTrap.instructionFuelExhausted
            }
            remainingFuel -= workUnits
            try ensureWithinDeadline()
            guard nowNanoseconds() <= deadlineNanoseconds else {
                throw VM.RuntimeTrap.nativeImportDeadlineExceeded(id)
            }
        }
    }

    func checkNativeInvocationDeadline(
        id: Core.NativeImportID,
        deadlineNanoseconds: UInt64
    ) throws {
        try lock.withLock {
            try ensureWithinDeadline()
            guard nowNanoseconds() <= deadlineNanoseconds else {
                throw VM.RuntimeTrap.nativeImportDeadlineExceeded(id)
            }
        }
    }

    func finishNativeInvocation(
        id: Core.NativeImportID,
        deadlineNanoseconds: UInt64,
        requiresCooperation: Bool,
        checkpointCount: UInt32
    ) throws {
        try lock.withLock {
            try ensureWithinDeadline()
            guard nowNanoseconds() <= deadlineNanoseconds else {
                throw VM.RuntimeTrap.nativeImportDeadlineExceeded(id)
            }
            guard !requiresCooperation || checkpointCount > 0 else {
                throw VM.RuntimeTrap.nativeImportCooperationViolation(id)
            }
        }
    }

    func consumeVMHeap(bytes: UInt64) throws {
        try lock.withLock {
            guard remainingVMHeapBytes >= bytes else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
            remainingVMHeapBytes -= bytes
        }
    }

    /// Reserves a proven upper bound before an operation allocates variable-size
    /// VM storage, then retains only the measured allocation. This keeps dynamic
    /// output fail-closed without permanently charging a conservative bound.
    func withReservedVMHeap<Result>(
        maximumBytes: UInt64,
        _ allocate: () throws -> (value: Result, actualBytes: UInt64)
    ) throws -> Result {
        try consumeVMHeap(bytes: maximumBytes)
        do {
            let allocation = try allocate()
            guard allocation.actualBytes <= maximumBytes else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            refundVMHeap(bytes: maximumBytes - allocation.actualBytes)
            return allocation.value
        } catch {
            refundVMHeap(bytes: maximumBytes)
            throw error
        }
    }

    func consumeAggregateStorage(elementCount: Int) throws {
        try consumeVMHeap(bytes: aggregateStorageBytes(elementCount: elementCount))
    }

    /// Reserves scratch storage with the same conservative aggregate model as
    /// retained VM collections, then returns the complete reservation after
    /// the synchronous operation finishes.
    func withTemporaryAggregateStorage<Result>(
        elementCount: Int,
        _ operation: () throws -> Result
    ) throws -> Result {
        let bytes = try aggregateStorageBytes(elementCount: elementCount)
        return try withReservedVMHeap(maximumBytes: bytes) {
            (value: try operation(), actualBytes: 0)
        }
    }

    private func aggregateStorageBytes(elementCount: Int) throws -> UInt64 {
        guard elementCount >= 0 else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
        let count = UInt64(elementCount).addingReportingOverflow(1)
        let bytes = count.partialValue.multipliedReportingOverflow(by: 16)
        guard !count.overflow, !bytes.overflow else {
            throw VM.RuntimeTrap.vmHeapLimitExceeded
        }
        return bytes.partialValue
    }

    func consumeAggregateElementStorage(elementCount: Int) throws {
        guard elementCount >= 0 else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
        let bytes = UInt64(elementCount).multipliedReportingOverflow(by: 16)
        guard !bytes.overflow else {
            throw VM.RuntimeTrap.vmHeapLimitExceeded
        }
        try consumeVMHeap(bytes: bytes.partialValue)
    }

    /// Charges values created by a trusted Shell boundary before they become
    /// owned by the VM. HLBC-internal values are charged where they allocate.
    public func consumeBoundaryValue(_ value: VM.Value) throws {
        try consumeBoundaryValue(value, depth: 0)
    }

    /// Charges a NativeImport result or SDK callback argument graph. Unlike an
    /// ordinary Shell boundary, this path admits one direct bridge-created
    /// native closure or one Optional containing it. Other aggregates retain
    /// the ordinary rule, so a callable cannot be smuggled through Any or
    /// collection storage.
    package func consumeNativeCallableBoundaryValue(
        _ value: VM.Value
    ) throws {
        switch value {
        case let .closure(closure):
            try consumeNativeClosureBoundaryValue(closure)
        case let .optional(.some(.closure(closure))):
            try consumeWork(units: 1)
            try consumeAggregateStorage(elementCount: 1)
            try consumeNativeClosureBoundaryValue(closure)
        default:
            try consumeBoundaryValue(value)
        }
    }

    private func consumeNativeClosureBoundaryValue(
        _ closure: VM.Closure
    ) throws {
        try consumeWork(units: 1)
        guard let target = closure.nativeTarget,
              target.signature == closure.signature,
              closure.signature.isNativeBridgeCallable,
              closure.captures.isEmpty,
              closure.dynamicScope == nil
        else {
            throw VM.RuntimeTrap.explicit(
                "closure values cannot cross a VM boundary"
            )
        }
        try consumeVMHeap(bytes: VM.NativeClosure.estimatedVMByteCount)
    }

    private func consumeBoundaryValue(_ value: VM.Value, depth: Int) throws {
        guard depth <= VM.ValueLimits.maximumNestingDepth else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(
                maximum: VM.ValueLimits.maximumNestingDepth
            )
        }
        try consumeWork(units: 1)
        switch value {
        case let .string(string):
            try consumeUTF8Work(byteCount: string.utf8.count)
            try consumeVMHeap(bytes: UInt64(string.utf8.count))
        case let .array(storage):
            _ = try storage.endIndex()
            try consumeAggregateStorage(elementCount: storage.elements.count)
            for value in storage.elements {
                try consumeBoundaryValue(value, depth: depth + 1)
            }
        case let .dictionary(entries, _, _):
            let elementCount = entries.count.multipliedReportingOverflow(by: 2)
            guard !elementCount.overflow else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
            try consumeAggregateStorage(elementCount: elementCount.partialValue)
            for entry in entries {
                try consumeBoundaryValue(entry.key, depth: depth + 1)
                try consumeBoundaryValue(entry.value, depth: depth + 1)
            }
        case let .set(set):
            try consumeAggregateStorage(elementCount: set.elements.count)
            for element in set.elements {
                try consumeBoundaryValue(element, depth: depth + 1)
            }
        case let .native(native):
            try consumeNativeOwned(bytes: native.estimatedByteCount)
        case let .tuple(elements):
            try consumeAggregateStorage(elementCount: elements.count)
            for element in elements {
                try consumeBoundaryValue(element, depth: depth + 1)
            }
        case let .optional(.some(wrapped)):
            try consumeAggregateStorage(elementCount: 1)
            try consumeBoundaryValue(wrapped, depth: depth + 1)
        case .optional(nil):
            try consumeAggregateStorage(elementCount: 0)
        case let .structure(_, fields):
            try consumeAggregateStorage(elementCount: fields.count)
            for field in fields {
                try consumeBoundaryValue(field, depth: depth + 1)
            }
        case let .enumeration(_, _, payload):
            try consumeAggregateStorage(elementCount: payload == nil ? 0 : 1)
            if let payload {
                try consumeBoundaryValue(payload, depth: depth + 1)
            }
        case .object:
            throw VM.RuntimeTrap.explicit(
                "patch-local class values cannot cross a VM boundary"
            )
        case let .error(error):
            try consumeAggregateStorage(elementCount: error.payload == nil ? 0 : 1)
            try consumeUTF8Work(byteCount: error.message.utf8.count)
            try consumeVMHeap(bytes: UInt64(error.message.utf8.count))
            if let payload = error.payload {
                try consumeBoundaryValue(payload, depth: depth + 1)
            }
        case let .any(erased):
            try consumeAggregateStorage(elementCount: 1)
            try consumeBoundaryValue(erased.payload, depth: depth + 1)
        case .address:
            throw VM.RuntimeTrap.explicit("address values cannot cross a VM boundary")
        case .mutableCell:
            throw VM.RuntimeTrap.explicit(
                "mutable capture cells cannot cross a VM boundary"
            )
        case .nonOwningReference:
            throw VM.RuntimeTrap.explicit(
                "non-owning reference storage cannot cross a VM boundary"
            )
        case .arrayBuilder, .arrayMutationState, .dictionaryBuilder,
             .arraySortState, .arraySplitState:
            throw VM.RuntimeTrap.explicit(
                "collection operation states cannot cross a VM boundary"
            )
        case .closure:
            throw VM.RuntimeTrap.explicit("closure values cannot cross a VM boundary")
        case .bool, .integer, .float:
            break
        }
    }

    func consumeNativeOwned(bytes: UInt64) throws {
        try lock.withLock {
            guard remainingNativeOwnedBytes >= bytes else {
                throw VM.RuntimeTrap.nativeOwnedMemoryLimitExceeded
            }
            remainingNativeOwnedBytes -= bytes
        }
    }

    private func refundVMHeap(bytes: UInt64) {
        lock.withLock {
            let restored = remainingVMHeapBytes.addingReportingOverflow(bytes)
            precondition(!restored.overflow, "unbalanced HLVM heap reservation")
            remainingVMHeapBytes = restored.partialValue
        }
    }

    private func ensureWithinDeadline() throws {
        let currentTaskIsCancelled = withUnsafeCurrentTask {
            $0?.isCancelled ?? false
        }
        guard !cancellationRequested, !currentTaskIsCancelled else {
            throw VM.RuntimeTrap.executionCancelled
        }
        // Suspended host time is governed by the exact async NativeImport
        // deadline. The root budget resumes after its active-time deadline is
        // shifted by the measured suspension interval.
        guard suspensionStartedNanoseconds == nil else { return }
        guard nowNanoseconds() <= deadlineNanoseconds else {
            throw VM.RuntimeTrap.wallTimeExceeded
        }
    }
}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
