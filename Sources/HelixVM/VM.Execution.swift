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
    case dynamicCastFailure(actual: Bytecode.ValueType, expected: Bytecode.ValueType)
    case valueNestingDepthExceeded(maximum: Int)
    case arrayIndexOutOfBounds(index: Int64, count: Int)
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
    case nativeFailure(String)
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
        case let .dynamicCastFailure(actual, expected):
            "could not cast value of type \(actual) to \(expected)"
        case let .valueNestingDepthExceeded(maximum):
            "VM value nesting exceeds \(maximum) levels"
        case let .arrayIndexOutOfBounds(index, count):
            "Array index \(index) is outside 0..<\(count)"
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
        case let .nativeFailure(message): "native invocation failed: \(message)"
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

/// Authorizes the executor prologue that lives in a generated Swift wrapper,
/// outside HLVM. The async authorization is package-scoped so application code
/// cannot manufacture it through the public interpreter API.
public struct RootExecutionContext: Equatable, Sendable {
    private enum Kind: Equatable, Sendable {
        case synchronous
        case generatedAsyncBridge
        case hostedCallback
    }

    private let kind: Kind

    public static let synchronous = Self(kind: .synchronous)
    package static let generatedAsyncBridge = Self(kind: .generatedAsyncBridge)
    package static let hostedCallback = Self(kind: .hostedCallback)

    var permitsPatchLocalObjectArguments: Bool {
        kind == .hostedCallback
    }
}

public final class InvocationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFuel: UInt64
    private var currentDepth: UInt32 = 0
    private var nativeCalls: UInt32 = 0
    private let maximumDepth: UInt32
    private let maximumNativeCalls: UInt32
    private var remainingVMHeapBytes: UInt64
    private var remainingNativeOwnedBytes: UInt64
    private let deadlineNanoseconds: UInt64
    private let nowNanoseconds: @Sendable () -> UInt64
    private var sideEffectsCommittedStorage = false

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
        isMainThread: Bool = Thread.isMainThread
    ) throws -> VM.NativeInvocationContext {
        try contract.validate(effects: effects)
        guard !isMainThread || contract.execution.allowsMainThread else {
            throw VM.RuntimeTrap.nativeImportThreadViolation(id)
        }
        guard !effects.requiresMainActor || isMainThread else {
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
            let importDeadline = delta.overflow || candidate.overflow
                ? deadlineNanoseconds
                : min(deadlineNanoseconds, candidate.partialValue)
            return VM.NativeInvocationContext(
                id: id,
                budget: self,
                deadlineNanoseconds: importDeadline,
                requiresCooperation: contract.execution.deadlineMode == .cooperative,
                requiresMainActor: effects.requiresMainActor
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
        guard elementCount >= 0 else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
        let count = UInt64(elementCount).addingReportingOverflow(1)
        let bytes = count.partialValue.multipliedReportingOverflow(by: 16)
        guard !count.overflow, !bytes.overflow else {
            throw VM.RuntimeTrap.vmHeapLimitExceeded
        }
        try consumeVMHeap(bytes: bytes.partialValue)
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
        case let .array(values, _):
            try consumeAggregateStorage(elementCount: values.count)
            for value in values { try consumeBoundaryValue(value, depth: depth + 1) }
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
            for field in fields { try consumeBoundaryValue(field, depth: depth + 1) }
        case let .enumeration(_, _, payload):
            try consumeAggregateStorage(elementCount: payload == nil ? 0 : 1)
            if let payload { try consumeBoundaryValue(payload, depth: depth + 1) }
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
        case .arrayBuilder:
            throw VM.RuntimeTrap.explicit(
                "Array builders cannot cross a VM boundary"
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
