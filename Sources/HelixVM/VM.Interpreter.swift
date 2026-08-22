import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVerifier
#endif

private final class ExecutionTrace {
    var programCounter: VM.ProgramCounter?
}

private final class ExecutionFrame {
    let function: Bytecode.Function
    let blocks: [Bytecode.BlockID: Bytecode.Block]
    var registers: [VM.Value?]
    var stackSlots: [VM.MemoryCell]
    var currentBlock: Bytecode.BlockID
    var instructionOffset: Int

    init(
        function: Bytecode.Function,
        registers: [VM.Value?],
        stackSlots: [VM.MemoryCell]
    ) {
        self.function = function
        blocks = Dictionary(uniqueKeysWithValues: function.blocks.map { ($0.id, $0) })
        self.registers = registers
        self.stackSlots = stackSlots
        currentBlock = function.entryBlock
        instructionOffset = 0
    }
}

private enum CallContinuation {
    case returning(
        result: Bytecode.Register?,
        programCounter: VM.ProgramCounter
    )
    case throwing(
        normalTarget: Bytecode.BlockID,
        errorTarget: Bytecode.BlockID,
        programCounter: VM.ProgramCounter
    )
}

private struct SuspendedFrame {
    var frame: ExecutionFrame
    var continuation: CallContinuation
}

private struct FrameCall {
    var functionID: Bytecode.FunctionID
    var arguments: [VM.Value]
    var continuation: CallContinuation
}

private enum FrameOutcome {
    case call(FrameCall)
    case returned(VM.Value?)
}

extension VM {
public struct Interpreter: Sendable {
    public var nativeCatalog: VM.NativeCatalog
    public var nativeTypeCatalog: VM.NativeTypeCatalog
    public var entryInvocation: VM.EntryInvocation?
    public var objectHost: VM.ObjectHost?
    public var nativeCallbackHost: VM.NativeCallbackHost?
    public var trapObserver: VM.TrapObserver?

    public init(
        nativeCatalog: VM.NativeCatalog = .init(),
        nativeTypeCatalog: VM.NativeTypeCatalog = .init(),
        entryInvocation: VM.EntryInvocation? = nil,
        objectHost: VM.ObjectHost? = nil,
        nativeCallbackHost: VM.NativeCallbackHost? = nil,
        trapObserver: VM.TrapObserver? = nil
    ) {
        self.nativeCatalog = nativeCatalog
        self.nativeTypeCatalog = nativeTypeCatalog
        self.entryInvocation = entryInvocation
        self.objectHost = objectHost
        self.nativeCallbackHost = nativeCallbackHost
        self.trapObserver = trapObserver
    }

    public func invoke(
        entry: Core.EntryIndex,
        image: Verification.Image,
        arguments: [VM.Value],
        budget: VM.InvocationBudget? = nil,
        rootContext: VM.RootExecutionContext = .synchronous
    ) -> VM.ExecutionResult {
        guard let mapping = image.module.entries.first(where: { $0.entryIndex == entry }) else {
            let trap = VM.RuntimeTrap.unknownEntry(entry)
            trapObserver?(.init(trap: trap, programCounter: nil))
            return .trapped(trap)
        }
        return invoke(
            function: mapping.functionID,
            image: image,
            arguments: arguments,
            budget: budget,
            rootContext: rootContext
        )
    }

    public func invoke(
        function: Bytecode.FunctionID,
        image: Verification.Image,
        arguments: [VM.Value],
        budget: VM.InvocationBudget? = nil,
        rootContext: VM.RootExecutionContext = .synchronous
    ) -> VM.ExecutionResult {
        let trace = ExecutionTrace()
        do {
            try validate(image: image)
            let resolvedBudget = budget ?? VM.InvocationBudget(limits: image.effectiveResourceLimits)
            let functions = Dictionary(uniqueKeysWithValues: image.module.functions.map { ($0.id, $0) })
            let localTypes = Dictionary(
                uniqueKeysWithValues: image.module.localTypes.map { ($0.key, $0) }
            )
            guard let rootFunction = functions[function] else {
                throw VM.RuntimeTrap.unknownFunction(function)
            }
            guard !rootFunction.effects.isAsync
                    || rootContext == .generatedAsyncBridge
            else {
                throw VM.RuntimeTrap.explicit(
                    "async HLBC entry requires its generated Swift async Bridge"
                )
            }
            guard !rootFunction.effects.requiresMainActor || Thread.isMainThread else {
                throw VM.RuntimeTrap.mainActorViolation
            }
            guard !rootFunction.parameterConventions.contains(.inout),
                  !rootFunction.parameterRegisters.contains(where: {
                      guard let type = rootFunction.type(of: $0) else { return false }
                      return switch type {
                      case .address, .mutableCell, .nonOwningReference,
                           .arrayState,
                           .dictionaryState: true
                      default: false
                      }
                  })
            else {
                throw VM.RuntimeTrap.explicit(
                    "internal storage values cannot cross the root invocation boundary"
                )
            }
            guard arguments.count == rootFunction.parameterRegisters.count else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .tuple(rootFunction.parameterRegisters.map { rootFunction.type(of: $0)! }),
                    actual: .tuple(arguments.map(\.type))
                )
            }
            for (register, value) in zip(rootFunction.parameterRegisters, arguments) {
                if case .object = value,
                   rootContext.permitsPatchLocalObjectArguments {
                    // The Runtime reconstructed this identity from storage
                    // already owned by the pinned image; no boundary heap was
                    // introduced, but the validation work still consumes fuel.
                    try resolvedBudget.consumeWork(units: 1)
                } else {
                    try resolvedBudget.consumeBoundaryValue(value)
                }
                try validateRuntimeValue(
                    value,
                    expected: rootFunction.type(of: register)!,
                    localTypes: localTypes,
                    budget: resolvedBudget
                )
                try resolvedBudget.checkDeadline()
            }
            let value = try execute(
                functionID: function,
                functions: functions,
                arguments: arguments,
                localTypes: localTypes,
                budget: resolvedBudget,
                trace: trace
            )
            return .returned(value)
        } catch let business as VM.BusinessError {
            return .businessError(business.message)
        } catch let trap as VM.RuntimeTrap {
            trapObserver?(.init(trap: trap, programCounter: trace.programCounter))
            return .trapped(trap)
        } catch {
            let trap = VM.RuntimeTrap.nativeFailure(String(describing: error))
            trapObserver?(.init(trap: trap, programCounter: trace.programCounter))
            return .trapped(trap)
        }
    }

    /// Re-enters one closure through a Runtime-owned native callback host.
    /// Callback arguments cross a native boundary, while captures remain
    /// image-internal values validated against the closure body's trailing ABI.
    package func invokeNativeCallback(
        _ closure: VM.Closure,
        image: Verification.Image,
        arguments: [VM.Value],
        budget: VM.InvocationBudget
    ) -> VM.ExecutionResult {
        let trace = ExecutionTrace()
        do {
            // Runtime can only construct this route from an already verified,
            // catalog-bound image. Revalidating the full image on every callback
            // would create unmetered work outside the callback fuel budget.
            try budget.checkDeadline()
            try closure.dynamicScope?.requireActive()
            try budget.consumeLinearWork(
                elementCount: image.module.functions.count
                    + image.module.localTypes.count
            )
            let functions = Dictionary(
                uniqueKeysWithValues: image.module.functions.map { ($0.id, $0) }
            )
            let localTypes = Dictionary(
                uniqueKeysWithValues: image.module.localTypes.map { ($0.key, $0) }
            )
            try budget.checkDeadline()
            guard let functionID = closure.imageFunctionID,
                  let function = functions[functionID],
                  function.kind == .closureBody,
                  function.resultType == closure.signature.result,
                  closure.signature.hasCanonicalCallableEffects,
                  closure.signature.hasCanonicalThrownType,
                  function.hasCanonicalThrownType,
                  function.thrownType == closure.signature.thrownType,
                  Bytecode.ClosureSignature.callableEffects(
                      from: function.effects
                  ) == closure.signature.effects,
                  !function.effects.isAsync,
                  !function.effects.mayThrow,
                  function.parameterRegisters.count
                    == arguments.count + closure.captures.count,
                  arguments.count == closure.signature.parameters.count,
                  Array(function.parameterConventions.prefix(arguments.count))
                    == closure.signature.parameterConventions
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native callback closure disagrees with its verified body ABI"
                )
            }
            guard !function.effects.requiresMainActor || Thread.isMainThread else {
                throw VM.RuntimeTrap.mainActorViolation
            }
            for (value, expected) in zip(arguments, closure.signature.parameters) {
                try budget.consumeNativeCallableBoundaryValue(value)
                try validateRuntimeValue(
                    value,
                    expected: expected,
                    localTypes: localTypes,
                    budget: budget
                )
            }
            let captureRegisters = function.parameterRegisters.suffix(
                closure.captures.count
            )
            for (value, register) in zip(closure.captures, captureRegisters) {
                guard let expected = function.type(of: register) else {
                    throw VM.RuntimeTrap.invalidProgramCounter
                }
                try validateRuntimeValue(
                    value,
                    expected: expected,
                    localTypes: localTypes,
                    budget: budget
                )
            }
            let callValues = arguments + closure.captures
            try chargeCallShape(callValues, budget: budget)
            let value = try execute(
                functionID: functionID,
                functions: functions,
                arguments: callValues,
                localTypes: localTypes,
                budget: budget,
                trace: trace
            )
            if closure.signature.result == .void {
                guard value == nil else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: .void,
                        actual: value?.type
                    )
                }
            } else {
                guard let value,
                      value.matches(closure.signature.result)
                else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: closure.signature.result,
                        actual: value?.type
                    )
                }
            }
            return .returned(value)
        } catch let business as VM.BusinessError {
            return .businessError(business.message)
        } catch let trap as VM.RuntimeTrap {
            trapObserver?(.init(trap: trap, programCounter: trace.programCounter))
            return .trapped(trap)
        } catch {
            let trap = VM.RuntimeTrap.nativeFailure(String(describing: error))
            trapObserver?(.init(trap: trap, programCounter: trace.programCounter))
            return .trapped(trap)
        }
    }

    /// Binds generated native catalogs to the immutable descriptors that were
    /// verified from the target Shell. Catalog metadata is executable ABI and
    /// therefore cannot be trusted merely because it was registered in-process.
    public func validate(image: Verification.Image) throws {
        for requirement in image.module.imports {
            guard let expected = image.shell.imports[requirement.id] else {
                throw VM.RuntimeTrap.unknownNativeImport(requirement.id)
            }
            guard let invoker = nativeCatalog[requirement.id] else {
                throw VM.RuntimeTrap.unknownNativeImport(requirement.id)
            }
            guard invoker.key == expected.key,
                  invoker.parameterTypes == expected.parameterTypes,
                  invoker.resultType == expected.resultType,
                  invoker.effects == expected.effects,
                  invoker.contract == expected.contract
            else {
                throw VM.RuntimeTrap.nativeImportDescriptorMismatch(requirement.id)
            }
        }

        for id in referencedNativeTypes(in: image) {
            guard let expected = image.shell.types[id] else {
                throw VM.RuntimeTrap.unknownNativeType(id)
            }
            guard let operations = nativeTypeCatalog[id] else {
                throw VM.RuntimeTrap.unknownNativeType(id)
            }
            let expectedKind: VM.NativeTypeKind = switch expected.kind {
            case .value: .value
            case .reference: .reference
            case .enumeration: .enumeration
            }
            guard operations.canonicalName == expected.canonicalName,
                  operations.kind == expectedKind,
                  operations.layoutFingerprint == expected.layoutFingerprint,
                  operations.isCopyable == expected.isCopyable,
                  operations.requiresMainActor == expected.requiresMainActor,
                  operations.estimatedSize == expected.estimatedSize
            else {
                throw VM.RuntimeTrap.nativeTypeDescriptorMismatch(id)
            }
        }
    }

    private func referencedNativeTypes(in image: Verification.Image) -> Set<Core.TypeID> {
        var result = Set<Core.TypeID>()
        func visit(_ type: Bytecode.ValueType) {
            switch type {
            case let .native(id):
                result.insert(id)
            case let .tuple(elements):
                elements.forEach(visit)
            case let .optional(wrapped), let .address(wrapped),
                 let .mutableCell(wrapped),
                 let .nonOwningReference(_, wrapped),
                 let .arrayState(_, wrapped):
                visit(wrapped)
            case let .array(element), let .set(element):
                visit(element)
            case let .dictionary(key, value):
                visit(key)
                visit(value)
            case let .dictionaryState(key, value):
                visit(key)
                visit(value)
            case let .closure(signature):
                signature.componentTypes.forEach(visit)
            case .void, .never, .bool, .integer, .float, .string, .any, .local,
                 .error:
                break
            }
        }
        for function in image.module.functions {
            function.registerTypes.forEach(visit)
            function.stackSlotTypes.forEach(visit)
            visit(function.resultType)
        }
        for requirement in image.module.imports {
            guard let descriptor = image.shell.imports[requirement.id] else { continue }
            descriptor.parameterTypes.forEach(visit)
            visit(descriptor.resultType)
        }
        return result
    }

    private func execute(
        functionID: Bytecode.FunctionID,
        functions: [Bytecode.FunctionID: Bytecode.Function],
        arguments: [VM.Value],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        budget: VM.InvocationBudget,
        trace: ExecutionTrace
    ) throws -> VM.Value? {
        var current = try makeFrame(
            functionID: functionID,
            functions: functions,
            arguments: arguments,
            localTypes: localTypes,
            budget: budget
        )
        var suspended: [SuspendedFrame] = []
        var activeFrameCount = 1
        defer {
            while activeFrameCount > 0 {
                budget.leaveFrame()
                activeFrameCount -= 1
            }
        }

        while true {
            let outcome: FrameOutcome
            do {
                outcome = try executeFrame(
                    current,
                    functions: functions,
                    localTypes: localTypes,
                    budget: budget,
                    trace: trace
                )
            } catch let business as VM.BusinessError {
                budget.leaveFrame()
                activeFrameCount -= 1

                let pendingError = business
                var didFindHandler = false
                while let caller = suspended.popLast() {
                    current = caller.frame
                    switch caller.continuation {
                    case .returning:
                        budget.leaveFrame()
                        activeFrameCount -= 1
                    case let .throwing(_, errorTarget, programCounter):
                        trace.programCounter = programCounter
                        try transferBusinessError(
                            pendingError,
                            to: current.blocks[errorTarget]!,
                            function: current.function,
                            registers: &current.registers,
                            localTypes: localTypes,
                            budget: budget
                        )
                        current.currentBlock = errorTarget
                        current.instructionOffset = 0
                        didFindHandler = true
                    }
                    if didFindHandler { break }
                }
                guard didFindHandler else { throw pendingError }
                continue
            }

            switch outcome {
            case let .call(call):
                let callee = try makeFrame(
                    functionID: call.functionID,
                    functions: functions,
                    arguments: call.arguments,
                    localTypes: localTypes,
                    budget: budget
                )
                activeFrameCount += 1
                suspended.append(
                    SuspendedFrame(frame: current, continuation: call.continuation)
                )
                current = callee

            case let .returned(value):
                budget.leaveFrame()
                activeFrameCount -= 1
                guard let caller = suspended.popLast() else { return value }
                current = caller.frame
                switch caller.continuation {
                case let .returning(result, programCounter):
                    trace.programCounter = programCounter
                    try storeCallResult(
                        value,
                        in: result,
                        function: current.function,
                        registers: &current.registers,
                        localTypes: localTypes,
                        budget: budget
                    )
                case let .throwing(normalTarget, _, programCounter):
                    trace.programCounter = programCounter
                    try transferCallOutcome(
                        value,
                        to: current.blocks[normalTarget]!,
                        function: current.function,
                        registers: &current.registers,
                        localTypes: localTypes,
                        budget: budget
                    )
                    current.currentBlock = normalTarget
                    current.instructionOffset = 0
                }
            }
        }
    }

    private func makeFrame(
        functionID: Bytecode.FunctionID,
        functions: [Bytecode.FunctionID: Bytecode.Function],
        arguments: [VM.Value],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        budget: VM.InvocationBudget
    ) throws -> ExecutionFrame {
        guard let function = functions[functionID] else { throw VM.RuntimeTrap.unknownFunction(functionID) }
        guard arguments.count == function.parameterRegisters.count else {
            throw VM.RuntimeTrap.typeMismatch(expected: .tuple(function.parameterRegisters.map { function.type(of: $0)! }), actual: .tuple(arguments.map(\.type)))
        }
        try budget.enterFrame()
        do {
            let frameValues = function.registerTypes.count.addingReportingOverflow(
                function.stackSlotTypes.count
            )
            guard !frameValues.overflow else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
            let frameBytes = UInt64(frameValues.partialValue).multipliedReportingOverflow(
                by: UInt64(MemoryLayout<VM.Value?>.stride)
            )
            guard !frameBytes.overflow else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
            try budget.consumeVMHeap(bytes: frameBytes.partialValue)
            var registers = Array<VM.Value?>(repeating: nil, count: function.registerTypes.count)
            let stackSlots = try function.stackSlotTypes.map { type in
                let shape = try storageShape(type, localTypes: localTypes)
                guard let nodeCount = shape.nodeCount else {
                    throw VM.RuntimeTrap.vmHeapLimitExceeded
                }
                try budget.consumeLinearWork(elementCount: nodeCount)
                try chargeAggregate(elementCount: nodeCount, budget: budget)
                return VM.MemoryCell(
                    storageShape: shape
                )
            }
            for ((register, convention), value) in zip(
                zip(function.parameterRegisters, function.parameterConventions),
                arguments
            ) {
                let expected = function.type(of: register)!
                try validateRuntimeValue(
                    value,
                    expected: expected,
                    localTypes: localTypes
                )
                if convention == .inout {
                    guard case let .address(address) = value, address.canModify else {
                        throw VM.RuntimeTrap.addressWriteRequiresModifyAccess
                    }
                }
                try initialize(value, register: register, registers: &registers)
            }
            return ExecutionFrame(
                function: function,
                registers: registers,
                stackSlots: stackSlots
            )
        } catch {
            budget.leaveFrame()
            throw error
        }
    }

    private func executeFrame(
        _ frame: ExecutionFrame,
        functions: [Bytecode.FunctionID: Bytecode.Function],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        budget: VM.InvocationBudget,
        trace: ExecutionTrace
    ) throws -> FrameOutcome {
        let function = frame.function
        var registers = frame.registers
        var stackSlots = frame.stackSlots
        var currentBlock = frame.currentBlock

        while true {
            guard let block = frame.blocks[currentBlock] else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            var advancedToNextBlock = false
            for instructionIndex in frame.instructionOffset..<block.instructions.count {
                let instruction = block.instructions[instructionIndex]
                guard let instructionOffset = UInt32(exactly: instructionIndex) else {
                    throw VM.RuntimeTrap.invalidProgramCounter
                }
                let programCounter = VM.ProgramCounter(
                    functionID: function.id,
                    blockID: block.id,
                    instructionOffset: instructionOffset
                )
                trace.programCounter = programCounter
                try budget.consumeInstruction()
                switch instruction {
                case let .constantInteger(result, bitPattern):
                    guard case let .integer(width, signed) = function.type(of: result)! else {
                        throw VM.RuntimeTrap.typeMismatch(expected: .int64, actual: function.type(of: result))
                    }
                    try initialize(
                        .integer(
                            VM.Integer(
                                rawBits: bitPattern,
                                bitWidth: width,
                                isSigned: signed
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .constantBool(result, value):
                    try initialize(.bool(value), register: result, registers: &registers)
                case let .constantFloat(result, bitPattern):
                    guard case let .float(width) = function.type(of: result)! else {
                        throw VM.RuntimeTrap.typeMismatch(expected: .float(bitWidth: 64), actual: function.type(of: result))
                    }
                    try initialize(
                        .float(
                            VM.FloatingValue(
                                bitPattern: bitPattern,
                                bitWidth: width
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .constantString(result, value):
                    try budget.consumeVMHeap(bytes: UInt64(value.utf8.count))
                    try initialize(.string(value), register: result, registers: &registers)
                case let .copyValue(result, source):
                    let copied = try copyCharging(
                        try read(source, registers: registers),
                        budget: budget
                    )
                    try initialize(copied, register: result, registers: &registers)
                case let .moveValue(result, source):
                    let value = try consume(
                        source,
                        type: function.type(of: source)!,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    try initialize(value, register: result, registers: &registers)
                case let .destroyValue(register):
                    // SIL lifetime-ending operations must release the value in
                    // the register even when the verifier does not model it as
                    // linear. This is observable for weak references to local
                    // class objects that die before their invocation frame.
                    _ = try take(register, registers: &registers)
                case let .makeTuple(result, elements):
                    try budget.consumeLinearWork(elementCount: elements.count)
                    try chargeAggregate(elementCount: elements.count, budget: budget)
                    let values = try elements.map {
                        try consume(
                            $0,
                            type: function.type(of: $0)!,
                            localTypes: localTypes,
                            registers: &registers
                        )
                    }
                    try initialize(.tuple(values), register: result, registers: &registers)
                case let .unpackTuple(results, tuple):
                    try budget.consumeLinearWork(elementCount: results.count)
                    let tupleValue = try consume(
                        tuple,
                        type: function.type(of: tuple)!,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    guard case let .tuple(values) = tupleValue, values.count == results.count else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: tuple)!,
                            actual: tupleValue.type
                        )
                    }
                    for (result, value) in zip(results, values) {
                        try initialize(value, register: result, registers: &registers)
                    }
                case let .makeStruct(result, fields):
                    guard case let .local(key) = function.type(of: result),
                          let definition = localTypes[key],
                          case let .structure(expectedFields) = definition.kind,
                          expectedFields.count == fields.count
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result)!,
                            actual: nil
                        )
                    }
                    try budget.consumeLinearWork(elementCount: fields.count)
                    try chargeAggregate(elementCount: fields.count, budget: budget)
                    let values = try fields.map {
                        try consume(
                            $0,
                            type: function.type(of: $0)!,
                            localTypes: localTypes,
                            registers: &registers
                        )
                    }
                    try initialize(
                        .structure(type: key, fields: values),
                        register: result,
                        registers: &registers
                    )
                case let .structExtract(result, structure, fieldIndex):
                    let value = try read(structure, registers: registers)
                    guard case let .structure(_, fields) = value,
                          let index = Int(exactly: fieldIndex),
                          fields.indices.contains(index)
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: structure)!,
                            actual: value.type
                        )
                    }
                    try initialize(fields[index], register: result, registers: &registers)
                case let .allocateObject(result):
                    guard case let .local(key) = function.type(of: result),
                          let definition = localTypes[key],
                          case let .class(fields, hostedSuperclass, _) = definition.kind
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result)!,
                            actual: nil
                        )
                    }
                    try budget.consumeLinearWork(elementCount: fields.count)
                    try chargeAggregate(elementCount: fields.count, budget: budget)
                    let reference = VM.ObjectReference(
                        typeKey: key,
                        fieldCount: fields.count
                    )
                    if let hostedSuperclass {
                        guard let objectHost else {
                            throw VM.RuntimeTrap.explicit(
                                "hosted class allocation requires a Runtime object host"
                            )
                        }
                        let native = try objectHost.allocate(
                            object: reference,
                            definition: definition
                        )
                        guard native.typeID == hostedSuperclass.typeID else {
                            throw VM.RuntimeTrap.nativeTypeMismatch(
                                expected: hostedSuperclass.typeID
                            )
                        }
                        try budget.consumeNativeOwned(
                            bytes: native.estimatedByteCount
                        )
                        try reference.attach(nativeHost: native)
                    }
                    try initialize(
                        .object(reference),
                        register: result,
                        registers: &registers
                    )
                case let .projectObjectAddress(result, object, fieldIndex):
                    let value = try read(object, registers: registers)
                    guard case let .object(reference) = value,
                          case let .address(pointee) = function.type(of: result)
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: object)!,
                            actual: value.type
                        )
                    }
                    try initialize(
                        .address(
                            try reference.address(
                                field: fieldIndex,
                                pointee: pointee
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .projectHostedObject(result, object):
                    let value = try read(object, registers: registers)
                    guard case let .object(reference) = value,
                          let native = reference.nativeHost
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: object)!,
                            actual: value.type
                        )
                    }
                    try initialize(
                        try copyCharging(.native(native), budget: budget),
                        register: result,
                        registers: &registers
                    )
                case let .hostedSuperApply(object, methodIndex, arguments):
                    let value = try read(object, registers: registers)
                    guard case let .object(reference) = value,
                          let definition = localTypes[reference.typeKey],
                          case let .class(_, _, methods) = definition.kind,
                          let index = Int(exactly: methodIndex),
                          methods.indices.contains(index),
                          let objectHost
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: object)!,
                            actual: value.type
                        )
                    }
                    let argumentValues = try arguments.map {
                        try read($0, registers: registers)
                    }
                    try budget.consumeNativeCall(hasSideEffects: true)
                    try objectHost.invokeSuper(
                        object: reference,
                        method: methods[index],
                        arguments: argumentValues
                    )
                case let .makeEnum(result, caseIndex, payload):
                    guard case let .local(key) = function.type(of: result),
                          let definition = localTypes[key],
                          case let .enumeration(enumCases) = definition.kind,
                          let index = Int(exactly: caseIndex),
                          enumCases.indices.contains(index)
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result)!,
                            actual: nil
                        )
                    }
                    let value = try payload.map {
                        try consume(
                            $0,
                            type: function.type(of: $0)!,
                            localTypes: localTypes,
                            registers: &registers
                        )
                    }
                    try chargeAggregate(elementCount: value == nil ? 0 : 1, budget: budget)
                    try initialize(
                        .enumeration(type: key, caseIndex: caseIndex, payload: value),
                        register: result,
                        registers: &registers
                    )
                case let .switchEnum(enumeration, cases, defaultTarget):
                    let value = try consume(
                        enumeration,
                        type: function.type(of: enumeration)!,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    guard case let .enumeration(_, caseIndex, payload) = value else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: enumeration)!,
                            actual: value.type
                        )
                    }
                    let target = cases.first(where: { $0.caseIndex == caseIndex })?.target
                        ?? defaultTarget
                    guard let target else { throw VM.RuntimeTrap.invalidProgramCounter }
                    try transferValues(
                        payload.map { [$0] } ?? [],
                        to: frame.blocks[target]!,
                        registers: &registers
                    )
                    currentBlock = target
                    advancedToNextBlock = true
                case let .makeError(result, payload):
                    let value = try consume(
                        payload,
                        type: function.type(of: payload)!,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    guard case let .local(key) = function.type(of: payload),
                          let definition = localTypes[key],
                          definition.conformsToError
                    else {
                        throw VM.RuntimeTrap.typeMismatch(expected: .error, actual: value.type)
                    }
                    let message: String
                    if case let .enumeration(_, caseIndex, _) = value,
                       case let .enumeration(enumCases) = definition.kind,
                       let index = Int(exactly: caseIndex),
                       enumCases.indices.contains(index) {
                        message = "\(key).\(enumCases[index].name)"
                    } else {
                        message = key.rawValue
                    }
                    try chargeAggregate(elementCount: 1, budget: budget)
                    let error = VM.Value.error(
                        .init(concreteType: key, payload: value, message: message)
                    )
                    // Error is a dynamic leaf in a local type's static graph.
                    // Charge and cap the concrete value tree here so internal
                    // code cannot build an overdeep existential before the
                    // next Shell boundary.
                    try chargeShapeValidation(error, budget: budget)
                    try initialize(
                        error,
                        register: result,
                        registers: &registers
                    )
                case let .castError(result, error, expectedType):
                    let value = try consume(
                        error,
                        type: .error,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    guard case let .error(errorValue) = value else {
                        throw VM.RuntimeTrap.typeMismatch(expected: .error, actual: value.type)
                    }
                    let projected = errorValue.concreteType == expectedType
                        ? errorValue.payload
                        : nil
                    try chargeAggregate(elementCount: projected == nil ? 0 : 1, budget: budget)
                    try initialize(.optional(projected), register: result, registers: &registers)
                case let .eraseToAny(result, source, dynamicType):
                    let sourceType = function.type(of: source)!
                    let value = try consume(
                        source,
                        type: sourceType,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    let erased: VM.Value
                    if sourceType == .any {
                        guard dynamicType == .any, case .any = value else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .any,
                                actual: value.type
                            )
                        }
                        erased = value
                    } else {
                        // Logical validation may traverse the complete value
                        // tree (for example nested Character collections).
                        // Charge that work before creating the existential.
                        try budget.consumeValueTraversal(value)
                        guard dynamicType.isAnyPayloadV1,
                              dynamicType.storageType == sourceType,
                              value.matches(dynamicType)
                        else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: sourceType,
                                actual: value.type
                            )
                        }
                        try chargeAggregate(elementCount: 1, budget: budget)
                        erased = .any(
                            .init(dynamicType: dynamicType, payload: value)
                        )
                    }
                    try initialize(erased, register: result, registers: &registers)
                case let .checkedCastAny(result, source, targetType):
                    let value = try consume(
                        source,
                        type: .any,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    guard case let .any(erased) = value,
                          case let .optional(resultType) = function.type(of: result),
                          resultType == targetType.storageType
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .any,
                            actual: value.type
                        )
                    }
                    let converted = try VM.DynamicCaster(budget: budget).cast(
                        erased.payload,
                        from: erased.dynamicType,
                        to: targetType
                    )
                    try chargeAggregate(
                        elementCount: converted == nil ? 0 : 1,
                        budget: budget
                    )
                    try initialize(
                        .optional(converted),
                        register: result,
                        registers: &registers
                    )
                case let .forceCastAny(result, source, targetType):
                    let value = try consume(
                        source,
                        type: .any,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    guard case let .any(erased) = value,
                          function.type(of: result) == targetType.storageType
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .any,
                            actual: value.type
                        )
                    }
                    guard let converted = try VM.DynamicCaster(budget: budget).cast(
                        erased.payload,
                        from: erased.dynamicType,
                        to: targetType
                    ) else {
                        throw VM.RuntimeTrap.dynamicCastFailure(
                            actual: erased.dynamicType,
                            expected: targetType
                        )
                    }
                    try initialize(converted, register: result, registers: &registers)
                case let .makeOptionalSome(result, value):
                    try chargeAggregate(elementCount: 1, budget: budget)
                    let payload = try consume(
                        value,
                        type: function.type(of: value)!,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    try initialize(.optional(payload), register: result, registers: &registers)
                case let .makeOptionalNone(result):
                    try chargeAggregate(elementCount: 0, budget: budget)
                    try initialize(.optional(nil), register: result, registers: &registers)
                case let .optionalIsSome(result, optional):
                    guard case let .optional(value) = try read(optional, registers: registers) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: optional)!,
                            actual: try read(optional, registers: registers).type
                        )
                    }
                    try initialize(.bool(value != nil), register: result, registers: &registers)
                case let .unwrapOptional(result, optional):
                    let optionalValue = try consume(
                        optional,
                        type: function.type(of: optional)!,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    guard case let .optional(value) = optionalValue else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: optional)!,
                            actual: optionalValue.type
                        )
                    }
                    guard let value else { throw VM.RuntimeTrap.optionalUnwrapOfNil }
                    try initialize(value, register: result, registers: &registers)
                case let .switchOptional(optional, someTarget, noneTarget):
                    let optionalValue = try consume(
                        optional,
                        type: function.type(of: optional)!,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    guard case let .optional(value) = optionalValue else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: optional)!,
                            actual: optionalValue.type
                        )
                    }
                    let target = value == nil ? noneTarget : someTarget
                    let values = value.map { [$0] } ?? []
                    try transferValues(
                        values,
                        to: frame.blocks[target]!,
                        registers: &registers
                    )
                    currentBlock = target
                    advancedToNextBlock = true
                case let .storeStack(slot, source, mode):
                    let value = try consume(
                        source,
                        type: function.type(of: source)!,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    try store(
                        value,
                        in: slot,
                        mode: mode,
                        stackSlots: &stackSlots
                    )
                case let .loadStack(result, slot, mode):
                    let value: VM.Value
                    switch mode {
                    case .copy:
                        value = try copyCharging(
                            try read(slot, stackSlots: stackSlots),
                            budget: budget
                        )
                    case .take:
                        value = try take(slot, stackSlots: &stackSlots)
                    }
                    try initialize(value, register: result, registers: &registers)
                case let .destroyStack(slot):
                    _ = try take(slot, stackSlots: &stackSlots)
                case let .destroyStackIfInitialized(slot):
                    guard let index = Int(exactly: slot.rawValue),
                          stackSlots.indices.contains(index)
                    else {
                        throw VM.RuntimeTrap.unknownStackSlot(slot)
                    }
                    try stackSlots[index].directDestroyIfInitialized()
                case let .stackAddress(result, slot):
                    guard let index = Int(exactly: slot.rawValue),
                          stackSlots.indices.contains(index),
                          case let .address(pointee) = function.type(of: result)
                    else {
                        throw VM.RuntimeTrap.unknownStackSlot(slot)
                    }
                    try initialize(
                        .address(.init(cell: stackSlots[index], pointee: pointee)),
                        register: result,
                        registers: &registers
                    )
                case let .projectAggregateAddress(result, base, fieldIndex):
                    guard case let .address(address) = try read(base, registers: registers),
                          case let .address(pointee) = function.type(of: result)
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: base)!,
                            actual: try read(base, registers: registers).type
                        )
                    }
                    try initialize(
                        .address(address.projected(field: fieldIndex, pointee: pointee)),
                        register: result,
                        registers: &registers
                    )
                case let .makeMutableCell(result, initialValue):
                    guard case let .mutableCell(pointee) = function.type(of: result)
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .mutableCell(
                                initialValue.flatMap {
                                    function.type(of: $0)
                                } ?? .never
                            ),
                            actual: function.type(of: result)
                        )
                    }
                    let value = try initialValue.map {
                        try consume(
                            $0,
                            type: pointee,
                            localTypes: localTypes,
                            registers: &registers
                        )
                    }
                    let shape = try storageShape(
                        pointee,
                        localTypes: localTypes
                    )
                    guard let nodeCount = shape.nodeCount else {
                        throw VM.RuntimeTrap.vmHeapLimitExceeded
                    }
                    try budget.consumeLinearWork(elementCount: nodeCount)
                    try chargeAggregate(
                        elementCount: nodeCount,
                        budget: budget
                    )
                    try initialize(
                        .mutableCell(
                            .init(
                                initialValue: value,
                                pointee: pointee,
                                shape: shape
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .borrowMutableCell(result, addressRegister):
                    guard case let .address(address) = try read(
                        addressRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: addressRegister)
                                ?? .never,
                            actual: try read(
                                addressRegister,
                                registers: registers
                            ).type
                        )
                    }
                    try initialize(
                        .mutableCell(try .init(borrowing: address)),
                        register: result,
                        registers: &registers
                    )
                case let .projectMutableCell(result, cellRegister, fieldIndex):
                    guard case let .mutableCell(cell) = try read(
                        cellRegister,
                        registers: registers
                    ), case let .mutableCell(aggregate) = function.type(
                        of: cellRegister
                    ), let fieldType = mutableCellFieldType(
                        aggregate,
                        fieldIndex: fieldIndex,
                        localTypes: localTypes
                    ),
                       function.type(of: result)
                        == .mutableCell(fieldType)
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: function.type(of: cellRegister)
                        )
                    }
                    try initialize(
                        .mutableCell(
                            cell.projected(
                                field: fieldIndex,
                                pointee: fieldType
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .loadMutableCell(result, cellRegister):
                    guard case let .mutableCell(cell) = try read(
                        cellRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: cellRegister) ?? .never,
                            actual: try read(
                                cellRegister,
                                registers: registers
                            ).type
                        )
                    }
                    try initialize(
                        try copyCharging(cell.read(), budget: budget),
                        register: result,
                        registers: &registers
                    )
                case let .storeMutableCell(cellRegister, source, mode):
                    guard case let .mutableCell(cell) = try read(
                        cellRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: cellRegister) ?? .never,
                            actual: try read(
                                cellRegister,
                                registers: registers
                            ).type
                        )
                    }
                    let value = try consume(
                        source,
                        type: cell.pointee,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    try cell.store(value, mode: mode)
                case let .makeNonOwningReference(result, initialValue):
                    guard case let .nonOwningReference(kind, pointee) = function.type(
                        of: result
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .nonOwningReference(
                                kind: .weak,
                                pointee: .never
                            ),
                            actual: function.type(of: result)
                        )
                    }
                    let target = try nonOwningReferenceTarget(
                        kind: kind,
                        pointee: pointee,
                        localTypes: localTypes
                    )
                    let reference = VM.NonOwningReference(
                        kind: kind,
                        pointee: pointee,
                        target: target
                    )
                    if let initialValue {
                        try store(
                            try read(initialValue, registers: registers),
                            in: reference,
                            mode: .initialize
                        )
                    }
                    try chargeAggregate(elementCount: 1, budget: budget)
                    try initialize(
                        .nonOwningReference(reference),
                        register: result,
                        registers: &registers
                    )
                case let .loadNonOwningReference(result, referenceRegister, mode):
                    guard case let .nonOwningReference(reference) = try read(
                        referenceRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: referenceRegister)
                                ?? .never,
                            actual: try read(
                                referenceRegister,
                                registers: registers
                            ).type
                        )
                    }
                    try initialize(
                        try load(from: reference, mode: mode, budget: budget),
                        register: result,
                        registers: &registers
                    )
                case let .storeNonOwningReference(referenceRegister, source, mode):
                    guard case let .nonOwningReference(reference) = try read(
                        referenceRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: referenceRegister)
                                ?? .never,
                            actual: try read(
                                referenceRegister,
                                registers: registers
                            ).type
                        )
                    }
                    try store(
                        try read(source, registers: registers),
                        in: reference,
                        mode: mode
                    )
                case let .beginAccess(result, base, kind):
                    guard case let .address(address) = try read(base, registers: registers) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: base)!,
                            actual: try read(base, registers: registers).type
                        )
                    }
                    try initialize(
                        .address(try address.begin(kind)),
                        register: result,
                        registers: &registers
                    )
                case let .endAccess(register):
                    guard case let .address(address) = try take(register, registers: &registers) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: register)!,
                            actual: nil
                        )
                    }
                    try address.end()
                case let .loadAddress(result, register, mode):
                    guard case let .address(address) = try read(register, registers: registers) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: register)!,
                            actual: try read(register, registers: registers).type
                        )
                    }
                    let value: VM.Value
                    switch mode {
                    case .copy:
                        value = try copyCharging(
                            try address.read(),
                            budget: budget
                        )
                    case .take:
                        try budget.consumeLinearWork(
                            elementCount: try address.projectedRemovalWork()
                        )
                        value = try address.take()
                    }
                    try initialize(
                        value,
                        register: result,
                        registers: &registers
                    )
                case let .storeAddress(register, source, mode):
                    guard case let .address(address) = try read(register, registers: registers) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: register)!,
                            actual: try read(register, registers: registers).type
                        )
                    }
                    let value = try consume(
                        source,
                        type: function.type(of: source)!,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    try address.store(value, mode: mode)
                case let .destroyAddress(register):
                    guard case let .address(address) = try read(
                        register,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: register)!,
                            actual: try read(register, registers: registers).type
                        )
                    }
                    try budget.consumeLinearWork(
                        elementCount: try address.projectedRemovalWork()
                    )
                    try address.destroy(ifInitialized: false)
                case let .destroyAddressIfInitialized(register):
                    guard case let .address(address) = try read(
                        register,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: register)!,
                            actual: try read(register, registers: registers).type
                        )
                    }
                    try budget.consumeLinearWork(
                        elementCount: try address.projectedRemovalWork()
                    )
                    try address.destroy(ifInitialized: true)
                case let .checkedBinary(result, overflow, operation, lhs, rhs):
                    let lhsValue = try integer(lhs, registers: registers)
                    let rhsValue = try integer(rhs, registers: registers)
                    let calculation = try calculate(operation, lhs: lhsValue, rhs: rhsValue)
                    try initialize(.integer(calculation.value), register: result, registers: &registers)
                    try initialize(.bool(calculation.overflow), register: overflow, registers: &registers)
                case let .floatingBinary(result, operation, lhs, rhs):
                    let lhsValue = try floating(lhs, registers: registers)
                    let rhsValue = try floating(rhs, registers: registers)
                    guard lhsValue.bitWidth == rhsValue.bitWidth else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .float(bitWidth: lhsValue.bitWidth),
                            actual: .float(bitWidth: rhsValue.bitWidth)
                        )
                    }
                    let value: VM.FloatingValue
                    if lhsValue.bitWidth == 32 {
                        let left = lhsValue.floatValue
                        let right = rhsValue.floatValue
                        let result: Float = switch operation {
                        case .add: left + right
                        case .subtract: left - right
                        case .multiply: left * right
                        case .divide: left / right
                        case .remainder: left.remainder(dividingBy: right)
                        case .truncatingRemainder:
                            left.truncatingRemainder(dividingBy: right)
                        case .minimum: Float.minimum(left, right)
                        case .maximum: Float.maximum(left, right)
                        case .minimumMagnitude:
                            Float.minimumMagnitude(left, right)
                        case .maximumMagnitude:
                            Float.maximumMagnitude(left, right)
                        }
                        value = .init(result)
                    } else {
                        let left = lhsValue.doubleValue
                        let right = rhsValue.doubleValue
                        let result: Double = switch operation {
                        case .add: left + right
                        case .subtract: left - right
                        case .multiply: left * right
                        case .divide: left / right
                        case .remainder: left.remainder(dividingBy: right)
                        case .truncatingRemainder:
                            left.truncatingRemainder(dividingBy: right)
                        case .minimum: Double.minimum(left, right)
                        case .maximum: Double.maximum(left, right)
                        case .minimumMagnitude:
                            Double.minimumMagnitude(left, right)
                        case .maximumMagnitude:
                            Double.maximumMagnitude(left, right)
                        }
                        value = .init(result)
                    }
                    try initialize(.float(value), register: result, registers: &registers)
                case let .floatingUnary(result, operation, operand):
                    let operandValue = try floating(operand, registers: registers)
                    let value: VM.FloatingValue
                    if operandValue.bitWidth == 32 {
                        let result: Float = switch operation {
                        case .negate: -operandValue.floatValue
                        case .absolute: abs(operandValue.floatValue)
                        case .squareRoot: operandValue.floatValue.squareRoot()
                        case .ulp: operandValue.floatValue.ulp
                        case .nextUp: operandValue.floatValue.nextUp
                        case .binade: operandValue.floatValue.binade
                        case .significand: operandValue.floatValue.significand
                        case .roundDown: operandValue.floatValue.rounded(.down)
                        case .roundUp: operandValue.floatValue.rounded(.up)
                        case .roundTowardZero: operandValue.floatValue.rounded(.towardZero)
                        case .roundAwayFromZero: operandValue.floatValue.rounded(.awayFromZero)
                        case .roundToNearestOrAwayFromZero:
                            operandValue.floatValue.rounded(.toNearestOrAwayFromZero)
                        case .roundToNearestOrEven:
                            operandValue.floatValue.rounded(.toNearestOrEven)
                        }
                        value = .init(result)
                    } else {
                        let result: Double = switch operation {
                        case .negate: -operandValue.doubleValue
                        case .absolute: abs(operandValue.doubleValue)
                        case .squareRoot: operandValue.doubleValue.squareRoot()
                        case .ulp: operandValue.doubleValue.ulp
                        case .nextUp: operandValue.doubleValue.nextUp
                        case .binade: operandValue.doubleValue.binade
                        case .significand: operandValue.doubleValue.significand
                        case .roundDown: operandValue.doubleValue.rounded(.down)
                        case .roundUp: operandValue.doubleValue.rounded(.up)
                        case .roundTowardZero: operandValue.doubleValue.rounded(.towardZero)
                        case .roundAwayFromZero: operandValue.doubleValue.rounded(.awayFromZero)
                        case .roundToNearestOrAwayFromZero:
                            operandValue.doubleValue.rounded(.toNearestOrAwayFromZero)
                        case .roundToNearestOrEven:
                            operandValue.doubleValue.rounded(.toNearestOrEven)
                        }
                        value = .init(result)
                    }
                    try initialize(.float(value), register: result, registers: &registers)
                case let .floatingPredicate(result, operation, operand):
                    let value = try floating(operand, registers: registers)
                    let predicate: Bool
                    if value.bitWidth == 32 {
                        let scalar = value.floatValue
                        predicate = switch operation {
                        case .isFinite: scalar.isFinite
                        case .isInfinite: scalar.isInfinite
                        case .isNaN: scalar.isNaN
                        case .isSignalingNaN: scalar.isSignalingNaN
                        case .isNormal: scalar.isNormal
                        case .isSubnormal: scalar.isSubnormal
                        case .isZero: scalar.isZero
                        case .isSignMinus: scalar.bitPattern >> 31 == 1
                        case .isCanonical: scalar.isCanonical
                        }
                    } else {
                        let scalar = value.doubleValue
                        predicate = switch operation {
                        case .isFinite: scalar.isFinite
                        case .isInfinite: scalar.isInfinite
                        case .isNaN: scalar.isNaN
                        case .isSignalingNaN: scalar.isSignalingNaN
                        case .isNormal: scalar.isNormal
                        case .isSubnormal: scalar.isSubnormal
                        case .isZero: scalar.isZero
                        case .isSignMinus: scalar.bitPattern >> 63 == 1
                        case .isCanonical: scalar.isCanonical
                        }
                    }
                    try initialize(.bool(predicate), register: result, registers: &registers)
                case let .floatingBinaryPredicate(result, operation, lhs, rhs):
                    let left = try floating(lhs, registers: registers)
                    let right = try floating(rhs, registers: registers)
                    guard left.bitWidth == right.bitWidth else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .float(bitWidth: left.bitWidth),
                            actual: .float(bitWidth: right.bitWidth)
                        )
                    }
                    let predicate: Bool
                    switch operation {
                    case .isTotallyOrderedBelowOrEqual:
                        predicate = left.bitWidth == 32
                            ? left.floatValue.isTotallyOrdered(
                                belowOrEqualTo: right.floatValue
                            )
                            : left.doubleValue.isTotallyOrdered(
                                belowOrEqualTo: right.doubleValue
                            )
                    }
                    try initialize(
                        .bool(predicate),
                        register: result,
                        registers: &registers
                    )
                case let .floatingTernary(
                    result, operation, multiplicand, multiplier, addend
                ):
                    let first = try floating(multiplicand, registers: registers)
                    let second = try floating(multiplier, registers: registers)
                    let third = try floating(addend, registers: registers)
                    guard first.bitWidth == second.bitWidth,
                          second.bitWidth == third.bitWidth
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .float(bitWidth: first.bitWidth),
                            actual: .float(bitWidth: second.bitWidth)
                        )
                    }
                    let value: VM.FloatingValue
                    switch operation {
                    case .fusedMultiplyAdd:
                        value = first.bitWidth == 32
                            ? .init(
                                third.floatValue.addingProduct(
                                    first.floatValue,
                                    second.floatValue
                                )
                            )
                            : .init(
                                third.doubleValue.addingProduct(
                                    first.doubleValue,
                                    second.doubleValue
                                )
                            )
                    }
                    try initialize(
                        .float(value),
                        register: result,
                        registers: &registers
                    )
                case let .floatingIntegerProperty(result, operation, operand):
                    let value = try floating(operand, registers: registers)
                    guard case let .integer(resultWidth, resultSigned)
                        = function.type(of: result)!
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .int64,
                            actual: function.type(of: result)
                        )
                    }
                    let rawBits: UInt64
                    if value.bitWidth == 32 {
                        let scalar = value.floatValue
                        rawBits = switch operation {
                        case .exponent:
                            UInt64(bitPattern: Int64(scalar.exponent))
                        case .exponentBitPattern:
                            UInt64(scalar.exponentBitPattern)
                        case .significandBitPattern:
                            UInt64(scalar.significandBitPattern)
                        case .significandWidth:
                            UInt64(bitPattern: Int64(scalar.significandWidth))
                        }
                    } else {
                        let scalar = value.doubleValue
                        rawBits = switch operation {
                        case .exponent:
                            UInt64(bitPattern: Int64(scalar.exponent))
                        case .exponentBitPattern:
                            UInt64(scalar.exponentBitPattern)
                        case .significandBitPattern:
                            scalar.significandBitPattern
                        case .significandWidth:
                            UInt64(bitPattern: Int64(scalar.significandWidth))
                        }
                    }
                    try initialize(
                        .integer(
                            try VM.Integer(
                                rawBits: rawBits,
                                bitWidth: resultWidth,
                                isSigned: resultSigned
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .integerUnary(result, operation, operand):
                    let source = try integer(operand, registers: registers)
                    guard case let .integer(resultWidth, resultSigned) = function.type(of: result)!
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .integer(
                                bitWidth: source.bitWidth,
                                signed: source.isSigned
                            ),
                            actual: function.type(of: result)
                        )
                    }
                    let rawBits: UInt64
                    switch operation {
                    case .magnitude:
                        rawBits = source.isSigned && source.signedValue < 0
                            ? (0 &- source.rawBits) & VM.Integer.mask(for: source.bitWidth)
                            : source.rawBits
                    case .nonzeroBitCount:
                        rawBits = UInt64(source.rawBits.nonzeroBitCount)
                    case .leadingZeroBitCount:
                        rawBits = UInt64(
                            source.rawBits.leadingZeroBitCount
                                - (64 - Int(source.bitWidth))
                        )
                    case .trailingZeroBitCount:
                        rawBits = UInt64(
                            min(source.rawBits.trailingZeroBitCount, Int(source.bitWidth))
                        )
                    case .byteSwapped:
                        rawBits = VM.IntegerSemantics.byteSwapped(source)
                    case .bigEndian:
                        rawBits = VM.IntegerSemantics.endianAdjusted(
                            source,
                            bigEndian: true
                        )
                    case .littleEndian:
                        rawBits = VM.IntegerSemantics.endianAdjusted(
                            source,
                            bigEndian: false
                        )
                    case .signum:
                        rawBits = UInt64(bitPattern: source.signedValue == 0
                            ? 0
                            : source.signedValue < 0 ? -1 : 1)
                    }
                    try initialize(
                        .integer(
                            try VM.Integer(
                                rawBits: rawBits,
                                bitWidth: resultWidth,
                                isSigned: resultSigned
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .integerFullWidthMultiply(high, low, lhs, rhs):
                    let product = try VM.IntegerSemantics.fullWidthProduct(
                        try integer(lhs, registers: registers),
                        try integer(rhs, registers: registers)
                    )
                    try initialize(
                        .integer(product.high),
                        register: high,
                        registers: &registers
                    )
                    try initialize(
                        .integer(product.low),
                        register: low,
                        registers: &registers
                    )
                case let .integerFullWidthDivide(
                    quotient, remainder, dividendHigh, dividendLow, divisor
                ):
                    let division = try VM.IntegerSemantics.fullWidthQuotient(
                        dividendHigh: try integer(
                            dividendHigh,
                            registers: registers
                        ),
                        dividendLow: try integer(
                            dividendLow,
                            registers: registers
                        ),
                        divisor: try integer(divisor, registers: registers)
                    )
                    try initialize(
                        .integer(division.quotient),
                        register: quotient,
                        registers: &registers
                    )
                    try initialize(
                        .integer(division.remainder),
                        register: remainder,
                        registers: &registers
                    )
                case let .scalarBitCast(result, operand):
                    let resultType = function.type(of: result)!
                    let value: VM.Value
                    switch (try read(operand, registers: registers), resultType) {
                    case let (.integer(source), .float(width))
                    where source.bitWidth == width:
                        value = .float(
                            try VM.FloatingValue(
                                bitPattern: source.rawBits,
                                bitWidth: width
                            )
                        )
                    case let (.float(source), .integer(width, signed))
                    where source.bitWidth == width:
                        value = .integer(
                            try VM.Integer(
                                rawBits: source.bitPattern,
                                bitWidth: width,
                                isSigned: signed
                            )
                        )
                    default:
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: resultType,
                            actual: try read(operand, registers: registers).type
                        )
                    }
                    try initialize(
                        value,
                        register: result,
                        registers: &registers
                    )
                case let .integerConvert(result, operation, operand):
                    let source = try integer(operand, registers: registers)
                    guard case let .integer(targetWidth, targetSigned) = function.type(of: result)!
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .int64,
                            actual: function.type(of: result)
                        )
                    }
                    let rawBits: UInt64 = switch operation {
                    case .truncate, .reinterpret:
                        source.rawBits
                    case .signExtend:
                        UInt64(bitPattern: source.signedValue)
                    case .zeroExtend:
                        source.unsignedValue
                    case .clamp:
                        try VM.IntegerSemantics.clamped(
                            source,
                            bitWidth: targetWidth,
                            isSigned: targetSigned
                        ).rawBits
                    }
                    try initialize(
                        .integer(
                            VM.Integer(
                                rawBits: rawBits,
                                bitWidth: targetWidth,
                                isSigned: targetSigned
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .floatingConvert(result, operation, operand):
                    guard case let .float(targetWidth) = function.type(of: result)! else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .float(bitWidth: 64),
                            actual: function.type(of: result)
                        )
                    }
                    let converted: VM.FloatingValue
                    switch operation {
                    case .truncate:
                        guard case let .float(value) = try read(operand, registers: registers),
                              value.bitWidth == 64
                        else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .float(bitWidth: 64),
                                actual: try read(operand, registers: registers).type
                            )
                        }
                        converted = .init(value.floatValue)
                    case .extend:
                        guard case let .float(value) = try read(operand, registers: registers),
                              value.bitWidth == 32
                        else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .float(bitWidth: 32),
                                actual: try read(operand, registers: registers).type
                            )
                        }
                        converted = .init(value.doubleValue)
                    case .signedIntegerToFloat:
                        let value = try integer(operand, registers: registers)
                        converted = targetWidth == 32
                            ? .init(Float(value.signedValue))
                            : .init(Double(value.signedValue))
                    case .unsignedIntegerToFloat:
                        let value = try integer(operand, registers: registers)
                        converted = targetWidth == 32
                            ? .init(Float(value.unsignedValue))
                            : .init(Double(value.unsignedValue))
                    }
                    try initialize(
                        .float(converted),
                        register: result,
                        registers: &registers
                    )
                case let .booleanBinary(result, operation, lhs, rhs):
                    guard case let .bool(left) = try read(lhs, registers: registers),
                          case let .bool(right) = try read(rhs, registers: registers)
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .bool,
                            actual: try read(lhs, registers: registers).type
                        )
                    }
                    let value: Bool = switch operation {
                    case .and: left && right
                    case .or: left || right
                    case .xor: left != right
                    }
                    try initialize(.bool(value), register: result, registers: &registers)
                case let .select(result, condition, trueValue, falseValue):
                    guard case let .bool(selectTrue) = try read(
                        condition,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .bool,
                            actual: try read(condition, registers: registers).type
                        )
                    }
                    let selected = try read(
                        selectTrue ? trueValue : falseValue,
                        registers: registers
                    )
                    try initialize(
                        try copyCharging(selected, budget: budget),
                        register: result,
                        registers: &registers
                    )
                case let .stringConcat(result, lhs, rhs):
                    let left = try string(lhs, registers: registers)
                    let right = try string(rhs, registers: registers)
                    try budget.consumeUTF8Work(byteCount: left.utf8.count)
                    try budget.consumeUTF8Work(byteCount: right.utf8.count)
                    let byteCount = UInt64(left.utf8.count).addingReportingOverflow(
                        UInt64(right.utf8.count)
                    )
                    guard !byteCount.overflow else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
                    try budget.consumeVMHeap(bytes: byteCount.partialValue)
                    try initialize(.string(left + right), register: result, registers: &registers)
                case let .stringCount(result, operand):
                    let value = try string(operand, registers: registers)
                    try budget.consumeUTF8Work(byteCount: value.utf8.count)
                    guard let count = Int64(exactly: value.count) else {
                        throw VM.RuntimeTrap.integerOverflow
                    }
                    try initialize(
                        .integer(VM.Integer(signed: count, bitWidth: 64, isSigned: true)),
                        register: result,
                        registers: &registers
                    )
                case let .stringIsEmpty(result, operand):
                    let value = try string(operand, registers: registers)
                    try initialize(.bool(value.isEmpty), register: result, registers: &registers)
                case let .stringPredicate(result, operation, string, pattern):
                    let value = try self.string(string, registers: registers)
                    let candidate = try self.string(pattern, registers: registers)
                    let matched: Bool
                    switch operation {
                    case .hasPrefix:
                        try budget.consumeUTF8Work(byteCount: value.utf8.count)
                        try budget.consumeUTF8Work(byteCount: candidate.utf8.count)
                        matched = value.hasPrefix(candidate)
                    case .hasSuffix:
                        try budget.consumeUTF8Work(byteCount: value.utf8.count)
                        try budget.consumeUTF8Work(byteCount: candidate.utf8.count)
                        matched = value.hasSuffix(candidate)
                    case .contains:
                        try budget.consumeSubstringSearchWork(
                            haystackByteCount: value.utf8.count,
                            patternByteCount: candidate.utf8.count
                        )
                        matched = value.contains(candidate)
                    }
                    try initialize(.bool(matched), register: result, registers: &registers)
                case let .stringTransform(result, operation, string):
                    let source = try self.string(string, registers: registers)
                    try budget.consumeUTF8Work(byteCount: source.utf8.count)
                    let maximumBytes = try VM.StringAllocation
                        .maximumCaseMappingUTF8ByteCount(for: source)
                    let transformed = try budget.withReservedVMHeap(
                        maximumBytes: maximumBytes
                    ) {
                        let value = switch operation {
                        case .uppercase: source.uppercased()
                        case .lowercase: source.lowercased()
                        }
                        return (value, UInt64(value.utf8.count))
                    }
                    try budget.consumeUTF8Work(byteCount: transformed.utf8.count)
                    try budget.checkDeadline()
                    try initialize(
                        .string(transformed),
                        register: result,
                        registers: &registers
                    )
                case let .stringCharacters(result, string):
                    let source = try self.string(string, registers: registers)
                    let byteCount = source.utf8.count
                    try budget.consumeUTF8Work(byteCount: byteCount)
                    let characterCount = source.count
                    try budget.consumeAggregateStorage(
                        elementCount: characterCount
                    )
                    try budget.consumeVMHeap(bytes: UInt64(byteCount))
                    // `count` and materialization each traverse the grapheme
                    // view. Reserve both deterministic passes before the
                    // output Array allocates storage.
                    try budget.consumeUTF8Work(byteCount: byteCount)
                    var characters: [VM.Value] = []
                    characters.reserveCapacity(characterCount)
                    for (offset, character) in source.enumerated() {
                        if offset.isMultiple(of: 64) {
                            try budget.checkDeadline()
                        }
                        characters.append(.string(String(character)))
                    }
                    try budget.checkDeadline()
                    try initialize(
                        .array(characters, elementType: .string),
                        register: result,
                        registers: &registers
                    )
                case let .stringJoin(
                    result,
                    elementsRegister,
                    separatorRegister,
                    elementKind
                ):
                    let elementsValue = try read(
                        elementsRegister,
                        registers: registers
                    )
                    guard case let .array(storage) = elementsValue,
                          storage.elementType == .string
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(.string),
                            actual: elementsValue.type
                        )
                    }
                    let elements = storage.elements
                    let separator = try separatorRegister.map {
                        try self.string($0, registers: registers)
                    }
                    if elementKind == .character, separator != nil {
                        throw VM.RuntimeTrap.invalidProgramCounter
                    }
                    try budget.consumeLinearWork(elementCount: elements.count)
                    var totalBytes: UInt64 = 0
                    for element in elements {
                        guard case let .string(component) = element else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .string,
                                actual: element.type
                            )
                        }
                        let componentByteCount = component.utf8.count
                        try budget.consumeUTF8Work(
                            byteCount: componentByteCount
                        )
                        if elementKind == .character, component.count != 1 {
                            throw VM.RuntimeTrap.explicit(
                                "Character sequence contains a value that is not one extended grapheme cluster"
                            )
                        }
                        let next = totalBytes.addingReportingOverflow(
                            UInt64(componentByteCount)
                        )
                        guard !next.overflow else {
                            throw VM.RuntimeTrap.vmHeapLimitExceeded
                        }
                        totalBytes = next.partialValue
                    }
                    if let separator, elements.count > 1 {
                        let separatorByteCount = separator.utf8.count
                        try budget.consumeUTF8Work(
                            byteCount: separatorByteCount
                        )
                        let repetitions = UInt64(elements.count - 1)
                        let separatorBytes = UInt64(separatorByteCount)
                            .multipliedReportingOverflow(by: repetitions)
                        let combined = totalBytes.addingReportingOverflow(
                            separatorBytes.partialValue
                        )
                        guard !separatorBytes.overflow, !combined.overflow else {
                            throw VM.RuntimeTrap.vmHeapLimitExceeded
                        }
                        totalBytes = combined.partialValue
                    }
                    guard let capacity = Int(exactly: totalBytes) else {
                        throw VM.RuntimeTrap.vmHeapLimitExceeded
                    }
                    // Joining traverses the element array once to prove the
                    // output bound and once to construct it. Charge both passes
                    // and the exact output before allocating any String storage.
                    try budget.consumeLinearWork(elementCount: elements.count)
                    try budget.consumeUTF8Work(byteCount: capacity)
                    let joined = try budget.withReservedVMHeap(
                        maximumBytes: totalBytes
                    ) {
                        var value = String()
                        value.reserveCapacity(capacity)
                        for (offset, element) in elements.enumerated() {
                            if offset.isMultiple(of: 64) {
                                try budget.checkDeadline()
                            }
                            if offset > 0, let separator {
                                value.append(contentsOf: separator)
                            }
                            guard case let .string(component) = element else {
                                throw VM.RuntimeTrap.invalidProgramCounter
                            }
                            value.append(contentsOf: component)
                        }
                        // String concatenation preserves the input UTF-8 code
                        // units, so the proven bound is also the exact payload.
                        return (value, totalBytes)
                    }
                    try budget.checkDeadline()
                    try initialize(
                        .string(joined),
                        register: result,
                        registers: &registers
                    )
                case let .scalarFromString(result, stringRegister, radixRegister):
                    let source = try string(stringRegister, registers: registers)
                    let radix = try radixRegister.map {
                        try VM.ScalarText.radix(
                            from: integer($0, registers: registers)
                        )
                    }
                    // Preserve Swift's radix precondition before charging work
                    // proportional to an input that parsing will never inspect.
                    try budget.consumeUTF8Work(byteCount: source.utf8.count)
                    guard case let .optional(target) = function.type(of: result) else {
                        throw VM.RuntimeTrap.invalidProgramCounter
                    }
                    let parsed = try VM.ScalarText.parse(
                        source,
                        as: target,
                        radix: radix
                    )
                    try budget.checkDeadline()
                    try initialize(
                        .optional(parsed),
                        register: result,
                        registers: &registers
                    )
                case let .integerToString(
                    result,
                    valueRegister,
                    radixRegister,
                    uppercaseRegister
                ):
                    let value = try integer(valueRegister, registers: registers)
                    let radix = try VM.ScalarText.radix(
                        from: integer(radixRegister, registers: registers)
                    )
                    let uppercase = try boolean(
                        uppercaseRegister,
                        registers: registers
                    )
                    let maximumBytes = VM.ScalarText
                        .maximumFormattedUTF8ByteCount(for: value)
                    try budget.consumeUTF8Work(
                        byteCount: Int(maximumBytes)
                    )
                    let formatted = try budget.withReservedVMHeap(
                        maximumBytes: maximumBytes
                    ) {
                        let string = try VM.ScalarText.format(
                            value,
                            radix: radix,
                            uppercase: uppercase
                        )
                        return (string, UInt64(string.utf8.count))
                    }
                    try budget.checkDeadline()
                    try initialize(
                        .string(formatted),
                        register: result,
                        registers: &registers
                    )
                case let .stringify(result, operand):
                    let source = try read(operand, registers: registers)
                    let maximumBytes = try VM.StringAllocation
                        .maximumStringificationUTF8ByteCount(for: source)
                    let value = try budget.withReservedVMHeap(
                        maximumBytes: maximumBytes
                    ) {
                        let string = try VM.StringAllocation.stringify(source)
                        return (string, UInt64(string.utf8.count))
                    }
                    try initialize(.string(value), register: result, registers: &registers)
                case let .makeArray(result, elements):
                    guard case let .array(elementType) = function.type(of: result)! else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(.never),
                            actual: function.type(of: result)
                        )
                    }
                    try budget.consumeLinearWork(elementCount: elements.count)
                    try chargeAggregate(elementCount: elements.count, budget: budget)
                    let values = try elements.map {
                        try consume(
                            $0,
                            type: function.type(of: $0)!,
                            localTypes: localTypes,
                            registers: &registers
                        )
                    }
                    try initialize(
                        .array(values, elementType: elementType),
                        register: result,
                        registers: &registers
                    )
                case let .arrayCount(result, operand):
                    let (values, _) = try array(operand, registers: registers)
                    guard let count = Int64(exactly: values.count) else {
                        throw VM.RuntimeTrap.integerOverflow
                    }
                    try initialize(
                        .integer(VM.Integer(signed: count, bitWidth: 64, isSigned: true)),
                        register: result,
                        registers: &registers
                    )
                case let .arrayIsEmpty(result, operand):
                    let (values, _) = try array(operand, registers: registers)
                    try initialize(.bool(values.isEmpty), register: result, registers: &registers)
                case let .arrayIndexBase(result, operand):
                    let storage = try arrayStorage(
                        operand,
                        registers: registers
                    )
                    _ = try storage.endIndex()
                    try initialize(
                        .integer(
                            VM.Integer(
                                signed: storage.indexBase,
                                bitWidth: 64,
                                isSigned: true
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .arrayRebase(result, operand, indexBase):
                    guard let arrayType = function.type(of: operand),
                          case .array = arrayType,
                          case let .array(storage) = try consume(
                            operand,
                            type: arrayType,
                            localTypes: localTypes,
                            registers: &registers
                          )
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(.never),
                            actual: function.type(of: operand)
                        )
                    }
                    let base = try integer(
                        indexBase,
                        registers: registers
                    ).signedValue
                    let rebased = VM.ArrayStorage(
                        elements: storage.elements,
                        elementType: storage.elementType,
                        indexBase: base
                    )
                    _ = try rebased.endIndex()
                    try initialize(
                        .array(rebased),
                        register: result,
                        registers: &registers
                    )
                case let .arrayGet(result, array, index):
                    let storage = try arrayStorage(
                        array,
                        registers: registers
                    )
                    let integer = try integer(index, registers: registers)
                    let exact = try storage.physicalOffset(
                        for: integer.signedValue
                    )
                    let value = try copyCharging(
                        storage.elements[exact],
                        budget: budget
                    )
                    try initialize(value, register: result, registers: &registers)
                case let .arrayBoundary(result, operation, operand):
                    let (values, _) = try array(operand, registers: registers)
                    let value: VM.Value?
                    let boundary = switch operation {
                    case .first: values.first
                    case .last: values.last
                    }
                    if let boundary {
                        try chargeAggregate(elementCount: 1, budget: budget)
                        value = try copyCharging(boundary, budget: budget)
                    } else {
                        try chargeAggregate(elementCount: 0, budget: budget)
                        value = nil
                    }
                    try initialize(.optional(value), register: result, registers: &registers)
                case let .arraySearch(result, operation, array, value):
                    let storage = try arrayStorage(
                        array,
                        registers: registers
                    )
                    let needle = try read(value, registers: registers)
                    let index = try VM.CollectionSemantics.searchIndex(
                        in: storage.elements,
                        matching: needle,
                        operation: operation
                    ) { left, right in
                        try vmValuesEqual(
                            left,
                            right,
                            budget: budget
                        )
                    }
                    let wrapped: VM.Value?
                    if let index {
                        guard let offset = Int64(exactly: index) else {
                            throw VM.RuntimeTrap.integerOverflow
                        }
                        let exact = storage.indexBase.addingReportingOverflow(
                            offset
                        )
                        guard !exact.overflow else {
                            throw VM.RuntimeTrap.integerOverflow
                        }
                        wrapped = .integer(
                            try VM.Integer(
                                signed: exact.partialValue,
                                bitWidth: 64,
                                isSigned: true
                            )
                        )
                    } else {
                        wrapped = nil
                    }
                    try chargeAggregate(
                        elementCount: wrapped == nil ? 0 : 1,
                        budget: budget
                    )
                    try initialize(
                        .optional(wrapped),
                        register: result,
                        registers: &registers
                    )
                case let .arrayAdapter(result, operation, array):
                    let (elements, elementType) = try self.array(
                        array,
                        registers: registers
                    )
                    let adapted = try adaptArray(
                        elements,
                        elementType: elementType,
                        operation: operation,
                        budget: budget
                    )
                    guard let resultType = function.type(of: result),
                          adapted.type == resultType
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: adapted.type
                        )
                    }
                    try initialize(
                        adapted,
                        register: result,
                        registers: &registers
                    )
                case let .arrayRepeat(result, value, count):
                    let element = try read(value, registers: registers)
                    let count = try integer(count, registers: registers)
                    guard case let .array(elementType) = function.type(
                        of: result
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(.never),
                            actual: function.type(of: result)
                        )
                    }
                    let repeated = try repeatedArray(
                        element,
                        elementType: elementType,
                        count: count.signedValue,
                        budget: budget
                    )
                    try initialize(
                        repeated,
                        register: result,
                        registers: &registers
                    )
                case let .arraySubsequence(
                    result,
                    operation,
                    array,
                    bound
                ):
                    let storage = try arrayStorage(
                        array,
                        registers: registers
                    )
                    let bound = try integer(bound, registers: registers)
                    let slice = try VM.ArrayAdapters.subsequence(
                        storage: storage,
                        bound: bound.signedValue,
                        operation: operation
                    )
                    let sliced = try copiedArray(
                        storage.elements,
                        elementType: storage.elementType,
                        bounds: slice.bounds,
                        indexBase: slice.indexBase,
                        budget: budget
                    )
                    try initialize(
                        sliced,
                        register: result,
                        registers: &registers
                    )
                case let .arrayRangeSlice(
                    result,
                    array,
                    lowerBound,
                    upperBound
                ):
                    let storage = try arrayStorage(
                        array,
                        registers: registers
                    )
                    let lower = try integer(
                        lowerBound,
                        registers: registers
                    )
                    let upper = try integer(
                        upperBound,
                        registers: registers
                    )
                    let slice = try VM.ArrayAdapters.rangeSlice(
                        storage: storage,
                        lowerBound: lower.signedValue,
                        upperBound: upper.signedValue
                    )
                    let sliced = try copiedArray(
                        storage.elements,
                        elementType: storage.elementType,
                        bounds: slice.bounds,
                        indexBase: slice.indexBase,
                        budget: budget
                    )
                    try initialize(
                        sliced,
                        register: result,
                        registers: &registers
                    )
                case let .arrayZip(result, lhs, rhs):
                    let (left, leftElement) = try self.array(
                        lhs,
                        registers: registers
                    )
                    let (right, rightElement) = try self.array(
                        rhs,
                        registers: registers
                    )
                    let zipped = try zippedArray(
                        left,
                        leftElement: leftElement,
                        right,
                        rightElement: rightElement,
                        budget: budget
                    )
                    guard let resultType = function.type(of: result),
                          zipped.type == resultType
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: zipped.type
                        )
                    }
                    try initialize(
                        zipped,
                        register: result,
                        registers: &registers
                    )
                case let .arrayJoined(result, arrays, separator):
                    let (nested, nestedType) = try self.array(
                        arrays,
                        registers: registers
                    )
                    guard case let .array(elementType) = nestedType else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(.never),
                            actual: nestedType
                        )
                    }
                    let separatorValues: [VM.Value]?
                    if let separator {
                        let (values, actualType) = try self.array(
                            separator,
                            registers: registers
                        )
                        guard actualType == elementType else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: elementType,
                                actual: actualType
                            )
                        }
                        separatorValues = values
                    } else {
                        separatorValues = nil
                    }
                    let joined = try joinedArray(
                        nested,
                        elementType: elementType,
                        separator: separatorValues,
                        budget: budget
                    )
                    guard let resultType = function.type(of: result),
                          joined.type == resultType
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: joined.type
                        )
                    }
                    try initialize(
                        joined,
                        register: result,
                        registers: &registers
                    )
                case let .arrayReplaceSubrange(
                    result,
                    array,
                    lowerBound,
                    upperBound,
                    replacement
                ):
                    let storage = try arrayStorage(
                        array,
                        registers: registers
                    )
                    let (replacementElements, replacementElementType) =
                        try self.array(replacement, registers: registers)
                    guard replacementElementType == storage.elementType else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(storage.elementType),
                            actual: .array(replacementElementType)
                        )
                    }
                    let lower = try integer(
                        lowerBound,
                        registers: registers
                    )
                    let upper = try integer(
                        upperBound,
                        registers: registers
                    )
                    _ = try storage.endIndex()
                    let bounds = try storage.physicalBounds(
                        lowerBound: lower.signedValue,
                        upperBound: upper.signedValue
                    )
                    let replaced = try replacingArraySubrange(
                        storage.elements,
                        elementType: storage.elementType,
                        bounds: bounds,
                        with: replacementElements,
                        indexBase: storage.indexBase,
                        budget: budget
                    )
                    try initialize(
                        replaced,
                        register: result,
                        registers: &registers
                    )
                case let .arraySwap(
                    result,
                    array,
                    lhsIndex,
                    rhsIndex
                ):
                    let storage = try arrayStorage(
                        array,
                        registers: registers
                    )
                    let lhs = try integer(
                        lhsIndex,
                        registers: registers
                    )
                    let rhs = try integer(
                        rhsIndex,
                        registers: registers
                    )
                    let swapped = try swappingArrayElements(
                        storage,
                        lhsIndex: lhs.signedValue,
                        rhsIndex: rhs.signedValue,
                        budget: budget
                    )
                    try initialize(
                        swapped,
                        register: result,
                        registers: &registers
                    )
                case let .arrayAppend(result, array, value):
                    let storage = try arrayStorage(
                        array,
                        registers: registers
                    )
                    _ = try storage.endIndex()
                    let elements = storage.elements
                    let newCount = elements.count.addingReportingOverflow(1)
                    guard !newCount.overflow else {
                        throw VM.RuntimeTrap.vmHeapLimitExceeded
                    }
                    _ = try VM.ArrayStorage.validatedEndIndex(
                        elementCount: newCount.partialValue,
                        indexBase: storage.indexBase
                    )
                    let sourceElement = try read(value, registers: registers)
                    try budget.consumeLinearWork(elementCount: newCount.partialValue)
                    try chargeAggregate(
                        elementCount: newCount.partialValue,
                        budget: budget
                    )
                    for element in elements {
                        try prepareCopy(element, budget: budget)
                    }
                    try prepareCopy(sourceElement, budget: budget)
                    var appended = try elements.map(copy)
                    let newElement = try copy(sourceElement)
                    appended.append(newElement)
                    try budget.checkDeadline()
                    let appendedValue = try validatedArrayValue(
                        appended,
                        elementType: storage.elementType,
                        indexBase: storage.indexBase
                    )
                    try initialize(
                        appendedValue,
                        register: result,
                        registers: &registers
                    )
                case let .makeArrayBuilder(result):
                    guard case let .arrayState(.builder, element) = function.type(
                        of: result
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .arrayState(
                                kind: .builder,
                                element: .never
                            ),
                            actual: function.type(of: result)
                        )
                    }
                    try chargeAggregate(elementCount: 0, budget: budget)
                    try initialize(
                        .arrayBuilder(.init(elementType: element)),
                        register: result,
                        registers: &registers
                    )
                case let .arrayBuilderAppend(builderRegister, value):
                    guard case let .arrayBuilder(builder) = try read(
                        builderRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: builderRegister)
                                ?? .never,
                            actual: try read(
                                builderRegister,
                                registers: registers
                            ).type
                        )
                    }
                    let sourceElement = try read(value, registers: registers)
                    try budget.consumeLinearWork(elementCount: 1)
                    try budget.consumeAggregateElementStorage(elementCount: 1)
                    try prepareCopy(sourceElement, budget: budget)
                    try builder.append(copy(sourceElement))
                    try budget.checkDeadline()
                case let .arrayBuilderAppendContents(builderRegister, array):
                    let builderValue = try read(
                        builderRegister,
                        registers: registers
                    )
                    guard case let .arrayBuilder(builder) = builderValue else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: builderRegister)
                                ?? .never,
                            actual: builderValue.type
                        )
                    }
                    let (elements, elementType) = try self.array(
                        array,
                        registers: registers
                    )
                    guard builder.elementType == elementType else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: builder.elementType,
                            actual: elementType
                        )
                    }
                    try budget.consumeLinearWork(elementCount: elements.count)
                    try budget.consumeAggregateElementStorage(
                        elementCount: elements.count
                    )
                    for element in elements {
                        try prepareCopy(element, budget: budget)
                    }
                    let copied = try elements.map(copy)
                    try builder.append(contentsOf: copied)
                    try budget.checkDeadline()
                case let .finishArrayBuilder(result, builderRegister):
                    guard case let .arrayState(.builder, element) = function.type(
                        of: builderRegister
                    ), function.type(of: result) == .array(element),
                       case let .arrayBuilder(builder) = try consume(
                        builderRegister,
                        type: .arrayState(kind: .builder, element: element),
                        localTypes: localTypes,
                        registers: &registers
                       )
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: function.type(of: builderRegister)
                        )
                    }
                    try initialize(
                        .array(
                            try builder.finish(),
                            elementType: element
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .makeArrayMutationState(result, arrayRegister):
                    guard case let .arrayState(.mutation, expectedElement) =
                            function.type(of: result)
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .arrayState(
                                kind: .mutation,
                                element: .never
                            ),
                            actual: function.type(of: result)
                        )
                    }
                    let storage = try arrayStorage(
                        arrayRegister,
                        registers: registers
                    )
                    guard storage.elementType == expectedElement else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(expectedElement),
                            actual: .array(storage.elementType)
                        )
                    }
                    let state = try makeArrayMutationState(
                        storage,
                        budget: budget
                    )
                    try initialize(
                        .arrayMutationState(state),
                        register: result,
                        registers: &registers
                    )
                case let .arrayMutationGet(result, stateRegister, indexRegister):
                    guard case let .arrayMutationState(state) = try read(
                        stateRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: stateRegister) ?? .never,
                            actual: try read(
                                stateRegister,
                                registers: registers
                            ).type
                        )
                    }
                    let index = try integer(
                        indexRegister,
                        registers: registers
                    ).signedValue
                    let element = try state.element(at: index, budget: budget)
                    try initialize(
                        try copyCharging(element, budget: budget),
                        register: result,
                        registers: &registers
                    )
                case let .arrayMutationSwap(
                    stateRegister,
                    lhsIndexRegister,
                    rhsIndexRegister
                ):
                    guard case let .arrayMutationState(state) = try read(
                        stateRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: stateRegister) ?? .never,
                            actual: try read(
                                stateRegister,
                                registers: registers
                            ).type
                        )
                    }
                    try state.swapAt(
                        try integer(
                            lhsIndexRegister,
                            registers: registers
                        ).signedValue,
                        try integer(
                            rhsIndexRegister,
                            registers: registers
                        ).signedValue,
                        budget: budget
                    )
                    try budget.checkDeadline()
                case let .finishArrayMutation(result, stateRegister):
                    guard case let .arrayState(.mutation, element) = function.type(
                        of: stateRegister
                    ), function.type(of: result) == .array(element),
                       case let .arrayMutationState(state) = try consume(
                        stateRegister,
                        type: .arrayState(kind: .mutation, element: element),
                        localTypes: localTypes,
                        registers: &registers
                       )
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: function.type(of: stateRegister)
                        )
                    }
                    let storage = try state.finish()
                    try budget.checkDeadline()
                    try initialize(
                        .array(
                            storage.elements,
                            elementType: element,
                            indexBase: storage.indexBase
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .makeDictionaryBuilder(result, initialValue):
                    guard case let .dictionaryState(keyType, valueType) =
                            function.type(of: result),
                          keyType.isVMHashable
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .dictionaryState(
                                key: .never,
                                value: .never
                            ),
                            actual: function.type(of: result)
                        )
                    }
                    var entries: [VM.DictionaryEntry] = []
                    try chargeAggregate(elementCount: 0, budget: budget)
                    if let initialValue {
                        let (source, sourceKey, sourceValue) = try dictionary(
                            initialValue,
                            registers: registers
                        )
                        guard sourceKey == keyType, sourceValue == valueType else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .dictionary(
                                    key: keyType,
                                    value: valueType
                                ),
                                actual: function.type(of: initialValue)
                            )
                        }
                        let elementCount = source.count
                            .multipliedReportingOverflow(by: 2)
                        guard !elementCount.overflow else {
                            throw VM.RuntimeTrap.vmHeapLimitExceeded
                        }
                        try budget.consumeLinearWork(
                            elementCount: source.count
                        )
                        try budget.consumeAggregateElementStorage(
                            elementCount: elementCount.partialValue
                        )
                        for entry in source {
                            try prepareCopy(entry.key, budget: budget)
                            try prepareCopy(entry.value, budget: budget)
                        }
                        entries.reserveCapacity(source.count)
                        for entry in source {
                            entries.append(
                                .init(
                                    key: try copy(entry.key),
                                    value: try copy(entry.value)
                                )
                            )
                        }
                    }
                    try budget.checkDeadline()
                    try initialize(
                        .dictionaryBuilder(
                            .init(
                                keyType: keyType,
                                valueType: valueType,
                                entries: entries
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .dictionaryBuilderGet(result, builderRegister, key):
                    guard case let .dictionaryState(keyType, valueType) =
                            function.type(of: builderRegister),
                          function.type(of: key) == keyType,
                          function.type(of: result) == .optional(valueType),
                          case let .dictionaryBuilder(builder) = try read(
                            builderRegister,
                            registers: registers
                          )
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: function.type(of: builderRegister)
                        )
                    }
                    let needle = try read(key, registers: registers)
                    let match = try builder.withEntries { entries in
                        let index = try dictionaryIndex(
                            of: needle,
                            in: entries,
                            budget: budget
                        )
                        return (
                            index: index,
                            value: index.map { entries[$0].value }
                        )
                    }
                    try chargeAggregate(
                        elementCount: match.index == nil ? 0 : 1,
                        budget: budget
                    )
                    let value = try match.value.map {
                        try copyCharging($0, budget: budget)
                    }
                    try initialize(
                        .optional(value),
                        register: result,
                        registers: &registers
                    )
                case let .dictionaryBuilderSet(builderRegister, key, value):
                    guard case let .dictionaryState(keyType, valueType) =
                            function.type(of: builderRegister),
                          function.type(of: key) == keyType,
                          function.type(of: value) == valueType,
                          case let .dictionaryBuilder(builder) = try read(
                            builderRegister,
                            registers: registers
                          )
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: builderRegister)
                                ?? .never,
                            actual: try read(
                                builderRegister,
                                registers: registers
                            ).type
                        )
                    }
                    let sourceKey = try read(key, registers: registers)
                    let sourceValue = try read(value, registers: registers)
                    let matchingIndex = try builder.withEntries { entries in
                        try dictionaryIndex(
                            of: sourceKey,
                            in: entries,
                            budget: budget
                        )
                    }
                    try budget.consumeLinearWork(elementCount: 1)
                    if matchingIndex == nil {
                        try budget.consumeAggregateElementStorage(
                            elementCount: 2
                        )
                        try prepareCopy(sourceKey, budget: budget)
                    }
                    try prepareCopy(sourceValue, budget: budget)
                    let copiedKey: VM.Value
                    if matchingIndex == nil {
                        copiedKey = try copy(sourceKey)
                    } else {
                        copiedKey = sourceKey
                    }
                    let copiedValue = try copy(sourceValue)
                    try budget.checkDeadline()
                    try builder.set(
                        key: copiedKey,
                        value: copiedValue,
                        matchingIndex: matchingIndex
                    )
                case let .dictionaryBuilderAppendArrayElement(
                    builderRegister,
                    key,
                    element
                ):
                    guard case let .dictionaryState(
                        keyType,
                        .array(elementType)
                    ) = function.type(of: builderRegister),
                          function.type(of: key) == keyType,
                          function.type(of: element) == elementType,
                          case let .dictionaryBuilder(builder) = try read(
                            builderRegister,
                            registers: registers
                          )
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: builderRegister)
                                ?? .never,
                            actual: try read(
                                builderRegister,
                                registers: registers
                            ).type
                        )
                    }
                    let sourceKey = try read(key, registers: registers)
                    let sourceElement = try read(
                        element,
                        registers: registers
                    )
                    let matchingIndex = try builder.withEntries { entries in
                        try dictionaryIndex(
                            of: sourceKey,
                            in: entries,
                            budget: budget
                        )
                    }
                    try builder.preflightArrayElementAppend(
                        matchingIndex: matchingIndex
                    )
                    try budget.consumeLinearWork(elementCount: 1)
                    if matchingIndex == nil {
                        try budget.consumeAggregateElementStorage(
                            elementCount: 2
                        )
                        try chargeAggregate(elementCount: 1, budget: budget)
                        try prepareCopy(sourceKey, budget: budget)
                    } else {
                        try budget.consumeAggregateElementStorage(
                            elementCount: 1
                        )
                    }
                    try prepareCopy(sourceElement, budget: budget)
                    let copiedKey: VM.Value
                    if matchingIndex == nil {
                        copiedKey = try copy(sourceKey)
                    } else {
                        copiedKey = sourceKey
                    }
                    let copiedElement = try copy(sourceElement)
                    try budget.checkDeadline()
                    try builder.appendArrayElement(
                        key: copiedKey,
                        element: copiedElement,
                        matchingIndex: matchingIndex
                    )
                case let .finishDictionaryBuilder(result, builderRegister):
                    guard case let .dictionaryState(keyType, valueType) =
                            function.type(of: builderRegister),
                          function.type(of: result) == .dictionary(
                            key: keyType,
                            value: valueType
                          ),
                          case let .dictionaryBuilder(builder) = try consume(
                            builderRegister,
                            type: .dictionaryState(
                                key: keyType,
                                value: valueType
                            ),
                            localTypes: localTypes,
                            registers: &registers
                          )
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: function.type(of: builderRegister)
                        )
                    }
                    try initialize(
                        .dictionary(
                            try builder.finish(),
                            keyType: keyType,
                            valueType: valueType
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .arraySorted(result, arrayRegister):
                    let (elements, elementType) = try array(
                        arrayRegister,
                        registers: registers
                    )
                    let state = try makeArraySortState(
                        elements,
                        elementType: elementType,
                        budget: budget
                    )
                    while let comparison = try state.nextComparison(
                        budget: budget
                    ) {
                        let rightPrecedesLeft = try compare(
                            .lessThan,
                            lhs: comparison.right,
                            rhs: comparison.left,
                            type: elementType,
                            budget: budget
                        )
                        try state.acceptComparison(
                            rightPrecedesLeft: rightPrecedesLeft,
                            budget: budget
                        )
                    }
                    let sorted = try finishArraySort(
                        state,
                        budget: budget
                    )
                    try initialize(
                        .array(sorted, elementType: elementType),
                        register: result,
                        registers: &registers
                    )
                case let .makeArraySortState(result, arrayRegister):
                    let (elements, elementType) = try array(
                        arrayRegister,
                        registers: registers
                    )
                    let state = try makeArraySortState(
                        elements,
                        elementType: elementType,
                        budget: budget
                    )
                    try initialize(
                        .arraySortState(state),
                        register: result,
                        registers: &registers
                    )
                case let .arraySortNextComparison(result, stateRegister):
                    guard case let .arraySortState(state) = try read(
                        stateRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: stateRegister) ?? .never,
                            actual: try read(
                                stateRegister,
                                registers: registers
                            ).type
                        )
                    }
                    let value: VM.Value
                    if let comparison = try state.nextComparison(
                        budget: budget
                    ) {
                        try chargeAggregate(elementCount: 2, budget: budget)
                        try chargeAggregate(elementCount: 1, budget: budget)
                        value = .optional(
                            .tuple([
                                try copyCharging(
                                    comparison.right,
                                    budget: budget
                                ),
                                try copyCharging(
                                    comparison.left,
                                    budget: budget
                                ),
                            ])
                        )
                    } else {
                        try chargeAggregate(elementCount: 0, budget: budget)
                        value = .optional(nil)
                    }
                    try initialize(
                        value,
                        register: result,
                        registers: &registers
                    )
                case let .arraySortAcceptComparison(
                    stateRegister,
                    predicateRegister
                ):
                    guard case let .arraySortState(state) = try read(
                        stateRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: stateRegister) ?? .never,
                            actual: try read(
                                stateRegister,
                                registers: registers
                            ).type
                        )
                    }
                    guard case let .bool(rightPrecedesLeft) = try read(
                        predicateRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .bool,
                            actual: try read(
                                predicateRegister,
                                registers: registers
                            ).type
                        )
                    }
                    try state.acceptComparison(
                        rightPrecedesLeft: rightPrecedesLeft,
                        budget: budget
                    )
                case let .finishArraySort(result, stateRegister):
                    guard case let .arrayState(.stableSort, element) = function.type(
                        of: stateRegister
                    ), function.type(of: result) == .array(element),
                       case let .arraySortState(state) = try consume(
                        stateRegister,
                        type: .arrayState(
                            kind: .stableSort,
                            element: element
                        ),
                        localTypes: localTypes,
                        registers: &registers
                       )
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: function.type(of: stateRegister)
                        )
                    }
                    let sorted = try finishArraySort(
                        state,
                        budget: budget
                    )
                    try initialize(
                        .array(sorted, elementType: element),
                        register: result,
                        registers: &registers
                    )
                case let .arraySplitSeparator(
                    result,
                    arrayRegister,
                    separatorRegister,
                    maximumSplitsRegister,
                    omittingEmptyRegister
                ):
                    let storage = try arrayStorage(
                        arrayRegister,
                        registers: registers
                    )
                    let maximumSplits = try splitMaximum(
                        maximumSplitsRegister,
                        registers: registers
                    )
                    let omitsEmpty = try boolean(
                        omittingEmptyRegister,
                        registers: registers
                    )
                    let separator = try read(
                        separatorRegister,
                        registers: registers
                    )
                    let state = try makeArraySplitState(
                        storage.elements,
                        elementType: storage.elementType,
                        indexBase: storage.indexBase,
                        maximumSplits: maximumSplits,
                        omitsEmptySubsequences: omitsEmpty,
                        budget: budget
                    )
                    while let element = try state.nextElement() {
                        try state.acceptElement(
                            isSeparator: try compare(
                                .equal,
                                lhs: element,
                                rhs: separator,
                                type: storage.elementType,
                                budget: budget
                            ),
                            budget: budget
                        )
                    }
                    let segments = try state.finish(budget: budget)
                    try budget.checkDeadline()
                    try initialize(
                        .array(
                            segments,
                            elementType: .array(storage.elementType)
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .makeArraySplitState(
                    result,
                    arrayRegister,
                    maximumSplitsRegister,
                    omittingEmptyRegister
                ):
                    let storage = try arrayStorage(
                        arrayRegister,
                        registers: registers
                    )
                    let state = try makeArraySplitState(
                        storage.elements,
                        elementType: storage.elementType,
                        indexBase: storage.indexBase,
                        maximumSplits: try splitMaximum(
                            maximumSplitsRegister,
                            registers: registers
                        ),
                        omitsEmptySubsequences: try boolean(
                            omittingEmptyRegister,
                            registers: registers
                        ),
                        budget: budget
                    )
                    try initialize(
                        .arraySplitState(state),
                        register: result,
                        registers: &registers
                    )
                case let .arraySplitNextElement(result, stateRegister):
                    guard case let .arraySplitState(state) = try read(
                        stateRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: stateRegister) ?? .never,
                            actual: try read(
                                stateRegister,
                                registers: registers
                            ).type
                        )
                    }
                    let value: VM.Value
                    if let element = try state.nextElement() {
                        try chargeAggregate(elementCount: 1, budget: budget)
                        value = .optional(
                            try copyCharging(element, budget: budget)
                        )
                    } else {
                        try chargeAggregate(elementCount: 0, budget: budget)
                        value = .optional(nil)
                    }
                    try initialize(
                        value,
                        register: result,
                        registers: &registers
                    )
                case let .arraySplitAcceptElement(
                    stateRegister,
                    predicateRegister
                ):
                    guard case let .arraySplitState(state) = try read(
                        stateRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: stateRegister) ?? .never,
                            actual: try read(
                                stateRegister,
                                registers: registers
                            ).type
                        )
                    }
                    try state.acceptElement(
                        isSeparator: try boolean(
                            predicateRegister,
                            registers: registers
                        ),
                        budget: budget
                    )
                case let .finishArraySplit(result, stateRegister):
                    guard case let .arrayState(.split, element) = function.type(
                        of: stateRegister
                    ), function.type(of: result) == .array(.array(element)),
                       case let .arraySplitState(state) = try consume(
                        stateRegister,
                        type: .arrayState(kind: .split, element: element),
                        localTypes: localTypes,
                        registers: &registers
                       )
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: function.type(of: stateRegister)
                        )
                    }
                    let segments = try state.finish(budget: budget)
                    try budget.checkDeadline()
                    try initialize(
                        .array(segments, elementType: .array(element)),
                        register: result,
                        registers: &registers
                    )
                case let .arrayUpdate(result, array, index, value):
                    let storage = try arrayStorage(
                        array,
                        registers: registers
                    )
                    let offset = try integer(index, registers: registers).signedValue
                    let exact = try storage.physicalOffset(for: offset)
                    let elements = storage.elements
                    let replacement = try read(value, registers: registers)
                    try budget.consumeLinearWork(elementCount: elements.count)
                    try chargeAggregate(elementCount: elements.count, budget: budget)
                    for position in elements.indices {
                        try prepareCopy(
                            position == exact ? replacement : elements[position],
                            budget: budget
                        )
                    }
                    var updated: [VM.Value] = []
                    updated.reserveCapacity(elements.count)
                    for position in elements.indices {
                        updated.append(
                            try copy(position == exact ? replacement : elements[position])
                        )
                    }
                    try budget.checkDeadline()
                    try initialize(
                        .array(
                            updated,
                            elementType: storage.elementType,
                            indexBase: storage.indexBase
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .arrayPopLast(elementResult, arrayResult, array):
                    let storage = try arrayStorage(
                        array,
                        registers: registers
                    )
                    _ = try storage.endIndex()
                    let elements = storage.elements
                    let remainingCount = max(elements.count - 1, 0)
                    try budget.consumeLinearWork(elementCount: elements.count)
                    try chargeAggregate(elementCount: remainingCount, budget: budget)
                    try chargeAggregate(
                        elementCount: elements.isEmpty ? 0 : 1,
                        budget: budget
                    )
                    for element in elements.dropLast() {
                        try prepareCopy(element, budget: budget)
                    }
                    if let last = elements.last {
                        try prepareCopy(last, budget: budget)
                    }
                    let remaining = try elements.dropLast().map(copy)
                    let removed = try elements.last.map(copy)
                    try budget.checkDeadline()
                    try initialize(
                        .optional(removed),
                        register: elementResult,
                        registers: &registers
                    )
                    try initialize(
                        .array(
                            remaining,
                            elementType: storage.elementType,
                            indexBase: storage.indexBase
                        ),
                        register: arrayResult,
                        registers: &registers
                    )
                case let .collectionMaterialize(result, collectionRegister):
                    let collection = try read(
                        collectionRegister,
                        registers: registers
                    )
                    let materialized = try materializeManagedCollection(
                        collection,
                        budget: budget
                    )
                    guard materialized.type == function.type(of: result) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: result) ?? .never,
                            actual: materialized.type
                        )
                    }
                    try initialize(
                        materialized,
                        register: result,
                        registers: &registers
                    )
                case let .collectionNext(
                    result,
                    collectionRegister,
                    indexSlot,
                    direction
                ):
                    let collection = try read(
                        collectionRegister,
                        registers: registers
                    )
                    let elementCount: Int
                    switch collection {
                    case let .array(storage):
                        elementCount = storage.elements.count
                    case let .dictionary(entries, _, _):
                        guard direction == .forward else {
                            throw VM.RuntimeTrap.invalidProgramCounter
                        }
                        elementCount = entries.count
                    case let .set(value):
                        guard direction == .forward else {
                            throw VM.RuntimeTrap.invalidProgramCounter
                        }
                        elementCount = value.elements.count
                    default:
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: collectionRegister) ?? .never,
                            actual: collection.type
                        )
                    }
                    let indexValue = try read(indexSlot, stackSlots: stackSlots)
                    guard case let .integer(integer) = indexValue,
                          integer.bitWidth == 64,
                          integer.isSigned
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .int64,
                            actual: indexValue.type
                        )
                    }
                    let index = integer.signedValue
                    guard index >= 0,
                          let exactIndex = Int(exactly: index),
                          exactIndex <= elementCount
                    else {
                        throw VM.RuntimeTrap.collectionCursorOutOfBounds(
                            index: index,
                            count: elementCount
                        )
                    }
                    let selectedIndex: Int?
                    let advancedIndex: Int64?
                    switch direction {
                    case .forward where exactIndex < elementCount:
                        selectedIndex = exactIndex
                        let advanced = index.addingReportingOverflow(1)
                        guard !advanced.overflow else {
                            throw VM.RuntimeTrap.integerOverflow
                        }
                        advancedIndex = advanced.partialValue
                    case .reverse where exactIndex > 0:
                        selectedIndex = exactIndex - 1
                        let advanced = index.subtractingReportingOverflow(1)
                        guard !advanced.overflow else {
                            throw VM.RuntimeTrap.integerOverflow
                        }
                        advancedIndex = advanced.partialValue
                    case .forward, .reverse:
                        selectedIndex = nil
                        advancedIndex = nil
                    }
                    let next: VM.Value?
                    if let selectedIndex, let advancedIndex {
                        switch collection {
                        case let .array(storage):
                            try chargeAggregate(elementCount: 1, budget: budget)
                            next = try copyCharging(
                                storage.elements[selectedIndex],
                                budget: budget
                            )
                        case let .dictionary(entries, _, _):
                            try chargeAggregate(elementCount: 2, budget: budget)
                            try chargeAggregate(elementCount: 1, budget: budget)
                            let entry = entries[selectedIndex]
                            next = .tuple([
                                try copyCharging(entry.key, budget: budget),
                                try copyCharging(entry.value, budget: budget),
                            ])
                        case let .set(value):
                            try chargeAggregate(elementCount: 1, budget: budget)
                            next = try copyCharging(
                                value.elements[selectedIndex],
                                budget: budget
                            )
                        default:
                            throw VM.RuntimeTrap.invalidProgramCounter
                        }
                        try store(
                            .integer(
                                VM.Integer(
                                    signed: advancedIndex,
                                    bitWidth: 64,
                                    isSigned: true
                                )
                            ),
                            in: indexSlot,
                            mode: .assign,
                            stackSlots: &stackSlots
                        )
                    } else {
                        try chargeAggregate(elementCount: 0, budget: budget)
                        next = nil
                    }
                    try initialize(
                        .optional(next),
                        register: result,
                        registers: &registers
                    )
                case let .progressionNext(
                    result,
                    cursorSlot,
                    end,
                    stride,
                    boundary
                ):
                    let step = try VM.Progression.next(
                        cursor: read(cursorSlot, stackSlots: stackSlots),
                        end: read(end, registers: registers),
                        stride: read(stride, registers: registers),
                        boundary: boundary
                    )
                    try store(
                        step.cursor,
                        in: cursorSlot,
                        mode: .assign,
                        stackSlots: &stackSlots
                    )
                    try initialize(
                        step.result,
                        register: result,
                        registers: &registers
                    )
                case let .makeDictionary(result, pairs):
                    guard case let .dictionary(keyType, valueType) = function.type(of: result),
                          case let .array(storage) = try read(
                              pairs,
                              registers: registers
                          ),
                          storage.elementType == .tuple([keyType, valueType])
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(.never),
                            actual: function.type(of: pairs)
                        )
                    }
                    let pairValues = storage.elements
                    try budget.consumeLinearWork(elementCount: pairValues.count)
                    try chargeAggregate(
                        elementCount: pairValues.count,
                        budget: budget
                    )
                    var uniqueKeys: [VM.Value] = []
                    uniqueKeys.reserveCapacity(pairValues.count)
                    for pair in pairValues {
                        guard case let .tuple(elements) = pair, elements.count == 2 else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .tuple([keyType, valueType]),
                                actual: pair.type
                            )
                        }
                        guard try collectionIndex(
                            of: elements[0],
                            in: uniqueKeys,
                            budget: budget
                        ) == nil else {
                            throw VM.RuntimeTrap.explicit(
                                "Dictionary construction contains duplicate keys"
                            )
                        }
                        uniqueKeys.append(elements[0])
                    }
                    try chargeDictionaryStorage(entryCount: pairValues.count, budget: budget)
                    for pair in pairValues {
                        guard case let .tuple(elements) = pair else {
                            throw VM.RuntimeTrap.invalidProgramCounter
                        }
                        try prepareCopy(elements[0], budget: budget)
                        try prepareCopy(elements[1], budget: budget)
                    }
                    var entries: [VM.DictionaryEntry] = []
                    entries.reserveCapacity(pairValues.count)
                    for pair in pairValues {
                        guard case let .tuple(elements) = pair else {
                            throw VM.RuntimeTrap.invalidProgramCounter
                        }
                        entries.append(
                            .init(
                                key: try copy(elements[0]),
                                value: try copy(elements[1])
                            )
                        )
                    }
                    try budget.checkDeadline()
                    try initialize(
                        .dictionary(entries, keyType: keyType, valueType: valueType),
                        register: result,
                        registers: &registers
                    )
                case let .dictionaryCount(result, operand):
                    let (entries, _, _) = try dictionary(operand, registers: registers)
                    guard let count = Int64(exactly: entries.count) else {
                        throw VM.RuntimeTrap.integerOverflow
                    }
                    try initialize(
                        .integer(VM.Integer(signed: count, bitWidth: 64, isSigned: true)),
                        register: result,
                        registers: &registers
                    )
                case let .dictionaryIsEmpty(result, operand):
                    let (entries, _, _) = try dictionary(operand, registers: registers)
                    try initialize(
                        .bool(entries.isEmpty),
                        register: result,
                        registers: &registers
                    )
                case let .dictionaryGet(result, operand, key):
                    let (entries, _, _) = try dictionary(operand, registers: registers)
                    let needle = try read(key, registers: registers)
                    let value: VM.Value?
                    if let index = try dictionaryIndex(
                        of: needle,
                        in: entries,
                        budget: budget
                    ) {
                        try chargeAggregate(elementCount: 1, budget: budget)
                        let copied = try copyCharging(
                            entries[index].value,
                            budget: budget
                        )
                        value = copied
                    } else {
                        try chargeAggregate(elementCount: 0, budget: budget)
                        value = nil
                    }
                    try initialize(.optional(value), register: result, registers: &registers)
                case let .dictionarySet(
                    previousValueResult,
                    dictionaryResult,
                    operand,
                    key,
                    value
                ):
                    let (source, keyType, valueType) = try dictionary(
                        operand,
                        registers: registers
                    )
                    let needle = try read(key, registers: registers)
                    let update = try read(value, registers: registers)
                    guard case let .optional(wrapped) = update else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .optional(valueType),
                            actual: update.type
                        )
                    }
                    let matchingIndex = try dictionaryIndex(
                        of: needle,
                        in: source,
                        budget: budget
                    )
                    let finalCount: Int
                    switch (matchingIndex, wrapped) {
                    case (.some, .none):
                        finalCount = source.count - 1
                    case (.none, .some):
                        let count = source.count.addingReportingOverflow(1)
                        guard !count.overflow else {
                            throw VM.RuntimeTrap.vmHeapLimitExceeded
                        }
                        finalCount = count.partialValue
                    default:
                        finalCount = source.count
                    }
                    try budget.consumeLinearWork(
                        elementCount: max(source.count, finalCount)
                    )
                    try chargeDictionaryStorage(entryCount: finalCount, budget: budget)
                    try chargeAggregate(
                        elementCount: matchingIndex == nil ? 0 : 1,
                        budget: budget
                    )
                    for (index, entry) in source.enumerated() {
                        if index == matchingIndex {
                            try prepareCopy(entry.value, budget: budget)
                            guard let wrapped else { continue }
                            try prepareCopy(entry.key, budget: budget)
                            try prepareCopy(wrapped, budget: budget)
                            continue
                        }
                        let selectedValue: VM.Value
                        selectedValue = entry.value
                        try prepareCopy(entry.key, budget: budget)
                        try prepareCopy(selectedValue, budget: budget)
                    }
                    if matchingIndex == nil, let wrapped {
                        try prepareCopy(needle, budget: budget)
                        try prepareCopy(wrapped, budget: budget)
                    }
                    let previous = try matchingIndex.map {
                        try copy(source[$0].value)
                    }
                    var entries: [VM.DictionaryEntry] = []
                    entries.reserveCapacity(finalCount)
                    for (index, entry) in source.enumerated() {
                        if index == matchingIndex, wrapped == nil { continue }
                        let selectedValue: VM.Value
                        if index == matchingIndex, let wrapped {
                            selectedValue = wrapped
                        } else {
                            selectedValue = entry.value
                        }
                        entries.append(
                            .init(
                                key: try copy(entry.key),
                                value: try copy(selectedValue)
                            )
                        )
                    }
                    if matchingIndex == nil, let wrapped {
                        entries.append(
                            .init(key: try copy(needle), value: try copy(wrapped))
                        )
                    }
                    try budget.checkDeadline()
                    try initialize(
                        .optional(previous),
                        register: previousValueResult,
                        registers: &registers
                    )
                    try initialize(
                        .dictionary(entries, keyType: keyType, valueType: valueType),
                        register: dictionaryResult,
                        registers: &registers
                    )
                case let .dictionaryProject(result, operand, projection):
                    let (source, keyType, valueType) = try dictionary(
                        operand,
                        registers: registers
                    )
                    let elementType = projection == .keys ? keyType : valueType
                    try budget.consumeLinearWork(elementCount: source.count)
                    try chargeAggregate(
                        elementCount: source.count,
                        budget: budget
                    )
                    for entry in source {
                        let element = projection == .keys
                            ? entry.key
                            : entry.value
                        try prepareCopy(element, budget: budget)
                    }
                    var projected: [VM.Value] = []
                    projected.reserveCapacity(source.count)
                    for entry in source {
                        let element = projection == .keys
                            ? entry.key
                            : entry.value
                        projected.append(try copy(element))
                    }
                    try budget.checkDeadline()
                    try initialize(
                        .array(projected, elementType: elementType),
                        register: result,
                        registers: &registers
                    )
                case let .makeSet(result, source):
                    guard case let .set(elementType) = function.type(of: result) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .set(.never),
                            actual: function.type(of: result) ?? .never
                        )
                    }
                    let sourceValue = try read(source, registers: registers)
                    let set: VM.SetValue
                    switch sourceValue {
                    case let .array(storage)
                    where storage.elementType == elementType:
                        set = try normalizedSetValue(
                            storage.elements,
                            elementType: elementType,
                            budget: budget
                        )
                    case let .set(value) where value.elementType == elementType:
                        set = try copySetValue(value, budget: budget)
                    default:
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(elementType),
                            actual: sourceValue.type
                        )
                    }
                    try initialize(.set(set), register: result, registers: &registers)
                case let .setCount(result, operand):
                    let value = try set(operand, registers: registers)
                    guard let count = Int64(exactly: value.elements.count) else {
                        throw VM.RuntimeTrap.integerOverflow
                    }
                    try initialize(
                        .integer(VM.Integer(signed: count, bitWidth: 64, isSigned: true)),
                        register: result,
                        registers: &registers
                    )
                case let .setIsEmpty(result, operand):
                    let value = try set(operand, registers: registers)
                    try initialize(
                        .bool(value.elements.isEmpty),
                        register: result,
                        registers: &registers
                    )
                case let .setContains(result, operand, element):
                    let value = try set(operand, registers: registers)
                    let needle = try read(element, registers: registers)
                    try budget.consumeLinearWork(elementCount: value.elements.count)
                    let contains = try collectionIndex(
                        of: needle,
                        in: value.elements,
                        budget: budget
                    ) != nil
                    try initialize(.bool(contains), register: result, registers: &registers)
                case let .setInsert(
                    insertedResult,
                    memberResult,
                    setResult,
                    operand,
                    element
                ):
                    let source = try set(operand, registers: registers)
                    let needle = try read(element, registers: registers)
                    try budget.consumeLinearWork(elementCount: source.elements.count)
                    let matchingIndex = try collectionIndex(
                        of: needle,
                        in: source.elements,
                        budget: budget
                    )
                    let updatedCount = source.elements.count.addingReportingOverflow(
                        matchingIndex == nil ? 1 : 0
                    )
                    guard !updatedCount.overflow else {
                        throw VM.RuntimeTrap.vmHeapLimitExceeded
                    }
                    try chargeAggregate(
                        elementCount: updatedCount.partialValue,
                        budget: budget
                    )
                    var updatedElements = source.elements
                    if matchingIndex == nil { updatedElements.append(needle) }
                    let updated = try copySetElements(
                        updatedElements,
                        elementType: source.elementType,
                        budget: budget
                    )
                    let member = try copyCharging(
                        matchingIndex.map { source.elements[$0] } ?? needle,
                        budget: budget
                    )
                    try initialize(
                        .bool(matchingIndex == nil),
                        register: insertedResult,
                        registers: &registers
                    )
                    try initialize(member, register: memberResult, registers: &registers)
                    try initialize(.set(updated), register: setResult, registers: &registers)
                case let .setUpdate(
                    oldMemberResult,
                    setResult,
                    operand,
                    element
                ):
                    let source = try set(operand, registers: registers)
                    let needle = try read(element, registers: registers)
                    try budget.consumeLinearWork(elementCount: source.elements.count)
                    let matchingIndex = try collectionIndex(
                        of: needle,
                        in: source.elements,
                        budget: budget
                    )
                    let updatedCount = source.elements.count.addingReportingOverflow(
                        matchingIndex == nil ? 1 : 0
                    )
                    guard !updatedCount.overflow else {
                        throw VM.RuntimeTrap.vmHeapLimitExceeded
                    }
                    try chargeAggregate(
                        elementCount: updatedCount.partialValue,
                        budget: budget
                    )
                    var updatedElements = source.elements
                    if let matchingIndex {
                        updatedElements[matchingIndex] = needle
                    } else {
                        updatedElements.append(needle)
                    }
                    let updated = try copySetElements(
                        updatedElements,
                        elementType: source.elementType,
                        budget: budget
                    )
                    let oldMember = try matchingIndex.map {
                        try copyCharging(source.elements[$0], budget: budget)
                    }
                    try chargeAggregate(
                        elementCount: oldMember == nil ? 0 : 1,
                        budget: budget
                    )
                    try initialize(
                        .optional(oldMember),
                        register: oldMemberResult,
                        registers: &registers
                    )
                    try initialize(.set(updated), register: setResult, registers: &registers)
                case let .setRemove(
                    removedResult,
                    setResult,
                    operand,
                    element
                ):
                    let source = try set(operand, registers: registers)
                    let needle = try read(element, registers: registers)
                    try budget.consumeLinearWork(elementCount: source.elements.count)
                    let matchingIndex = try collectionIndex(
                        of: needle,
                        in: source.elements,
                        budget: budget
                    )
                    let updated = try copySetElements(
                        source.elements,
                        excluding: matchingIndex,
                        elementType: source.elementType,
                        budget: budget
                    )
                    let removed = try matchingIndex.map {
                        try copyCharging(source.elements[$0], budget: budget)
                    }
                    try chargeAggregate(
                        elementCount: removed == nil ? 0 : 1,
                        budget: budget
                    )
                    try initialize(
                        .optional(removed),
                        register: removedResult,
                        registers: &registers
                    )
                    try initialize(.set(updated), register: setResult, registers: &registers)
                case let .setPopFirst(elementResult, setResult, operand):
                    let source = try set(operand, registers: registers)
                    try budget.consumeLinearWork(elementCount: source.elements.count)
                    let removed = try source.elements.first.map {
                        try copyCharging($0, budget: budget)
                    }
                    try chargeAggregate(
                        elementCount: removed == nil ? 0 : 1,
                        budget: budget
                    )
                    let updated = try copySetElements(
                        source.elements.dropFirst(),
                        elementType: source.elementType,
                        budget: budget
                    )
                    try initialize(
                        .optional(removed),
                        register: elementResult,
                        registers: &registers
                    )
                    try initialize(
                        .set(updated),
                        register: setResult,
                        registers: &registers
                    )
                case let .setAlgebra(result, operation, lhs, rhs):
                    let left = try set(lhs, registers: registers)
                    let right = try set(rhs, registers: registers)
                    try budget.consumeLinearWork(elementCount: left.elements.count)
                    try budget.consumeLinearWork(elementCount: right.elements.count)
                    let temporaryLimit: Int
                    switch operation {
                    case .intersection, .subtracting:
                        temporaryLimit = left.elements.count
                    case .union, .symmetricDifference:
                        let count = left.elements.count.addingReportingOverflow(
                            right.elements.count
                        )
                        guard !count.overflow else {
                            throw VM.RuntimeTrap.vmHeapLimitExceeded
                        }
                        temporaryLimit = count.partialValue
                    }
                    try chargeAggregate(
                        elementCount: temporaryLimit,
                        budget: budget
                    )
                    var selected: [VM.Value] = []
                    selected.reserveCapacity(temporaryLimit)
                    switch operation {
                    case .union:
                        selected = left.elements
                        for element in right.elements where try collectionIndex(
                            of: element,
                            in: selected,
                            budget: budget
                        ) == nil {
                            selected.append(element)
                        }
                    case .intersection:
                        for element in left.elements where try collectionIndex(
                            of: element,
                            in: right.elements,
                            budget: budget
                        ) != nil {
                            selected.append(element)
                        }
                    case .subtracting:
                        for element in left.elements where try collectionIndex(
                            of: element,
                            in: right.elements,
                            budget: budget
                        ) == nil {
                            selected.append(element)
                        }
                    case .symmetricDifference:
                        for element in left.elements where try collectionIndex(
                            of: element,
                            in: right.elements,
                            budget: budget
                        ) == nil {
                            selected.append(element)
                        }
                        for element in right.elements where try collectionIndex(
                            of: element,
                            in: left.elements,
                            budget: budget
                        ) == nil {
                            selected.append(element)
                        }
                    }
                    let value = try copySetElements(
                        selected,
                        elementType: left.elementType,
                        budget: budget
                    )
                    try initialize(.set(value), register: result, registers: &registers)
                case let .setRelation(result, operation, lhs, rhs):
                    let left = try set(lhs, registers: registers)
                    let right = try set(rhs, registers: registers)
                    let relation: Bool
                    switch operation {
                    case .equal:
                        relation = if left.sharesStorage(with: right) {
                            true
                        } else if left.elements.count == right.elements.count {
                            try setIsSubset(left, of: right, budget: budget)
                        } else {
                            false
                        }
                    case .subset:
                        relation = try setIsSubset(left, of: right, budget: budget)
                    case .strictSubset:
                        relation = if left.elements.count < right.elements.count {
                            try setIsSubset(left, of: right, budget: budget)
                        } else {
                            false
                        }
                    case .superset:
                        relation = try setIsSubset(right, of: left, budget: budget)
                    case .strictSuperset:
                        relation = if left.elements.count > right.elements.count {
                            try setIsSubset(right, of: left, budget: budget)
                        } else {
                            false
                        }
                    case .disjoint:
                        relation = try setsAreDisjoint(left, right, budget: budget)
                    }
                    try initialize(.bool(relation), register: result, registers: &registers)
                case let .compare(result, predicate, lhs, rhs):
                    let comparison = try compare(
                        predicate,
                        lhs: read(lhs, registers: registers),
                        rhs: read(rhs, registers: registers),
                        type: function.type(of: lhs)!,
                        budget: budget
                    )
                    try initialize(.bool(comparison), register: result, registers: &registers)
                case let .branch(target, arguments):
                    try transfer(
                        arguments,
                        to: frame.blocks[target]!,
                        function: function,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    currentBlock = target
                    advancedToNextBlock = true
                case let .conditionalBranch(condition, trueTarget, trueArguments, falseTarget, falseArguments):
                    guard case let .bool(value) = try read(condition, registers: registers) else {
                        throw VM.RuntimeTrap.typeMismatch(expected: .bool, actual: try read(condition, registers: registers).type)
                    }
                    let target = value ? trueTarget : falseTarget
                    let arguments = value ? trueArguments : falseArguments
                    try transfer(
                        arguments,
                        to: frame.blocks[target]!,
                        function: function,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    currentBlock = target
                    advancedToNextBlock = true
                case let .apply(result, callee, arguments):
                    guard let calleeFunction = functions[callee] else {
                        throw VM.RuntimeTrap.unknownFunction(callee)
                    }
                    let values = try arguments.map { try read($0, registers: registers) }
                    try chargeCallShape(values, budget: budget)
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: calleeFunction.parameterConventions,
                        function: function,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    persist(
                        frame,
                        registers: registers,
                        stackSlots: stackSlots,
                        currentBlock: currentBlock,
                        nextInstruction: instructionIndex + 1
                    )
                    try budget.checkDeadline()
                    return .call(
                        FrameCall(
                            functionID: callee,
                            arguments: values,
                            continuation: .returning(
                                result: result,
                                programCounter: programCounter
                            )
                        )
                    )
                case let .entryApply(result, entry, arguments):
                    guard let entryInvocation else { throw VM.RuntimeTrap.unknownEntry(entry) }
                    let values = try arguments.map { try read($0, registers: registers) }
                    try chargeCallShape(values, budget: budget)
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: Array(repeating: .owned, count: arguments.count),
                        function: function,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    switch entryInvocation(entry, values, budget) {
                    case let .returned(value):
                        try storeCallResult(
                            value,
                            in: result,
                            function: function,
                            registers: &registers,
                            localTypes: localTypes,
                            budget: budget
                        )
                    case let .businessError(message):
                        throw VM.BusinessError(message: message, requiresBoundaryCharge: true)
                    case let .trapped(trap): throw trap
                    }
                case let .nativeApply(result, importID, arguments):
                    guard let invoker = nativeCatalog[importID] else { throw VM.RuntimeTrap.unknownNativeImport(importID) }
                    let values = try arguments.map { try read($0, registers: registers) }
                    try chargeCallShape(values, budget: budget)
                    guard values.count == invoker.parameterTypes.count,
                          zip(values, invoker.parameterTypes).allSatisfy({
                              $0.matches($1)
                          })
                    else {
                        throw VM.RuntimeTrap.nativeFailure("runtime argument check failed for import \(importID)")
                    }
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: nativeParameterConventions(invoker),
                        function: function,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    switch try invokeNative(
                        invoker,
                        id: importID,
                        arguments: values,
                        budget: budget
                    ) {
                    case let .returned(value):
                        if let value {
                            try budget.consumeNativeCallableBoundaryValue(value)
                        }
                        if let value {
                            try validateRuntimeValue(
                                value,
                                expected: invoker.resultType,
                                localTypes: localTypes,
                                budget: budget
                            )
                        }
                        try storeCallResult(
                            value,
                            in: result,
                            function: function,
                            registers: &registers,
                            localTypes: localTypes,
                            budget: budget
                        )
                    case let .businessError(message):
                        guard invoker.effects.mayThrow else {
                            throw VM.RuntimeTrap.nativeFailure(
                                "nonthrowing import \(importID) returned a business error"
                            )
                        }
                        throw VM.BusinessError(message: message, requiresBoundaryCharge: true)
                    }
                case let .makeClosure(result, callee, captures, lifetime):
                    guard case let .closure(signature) = function.type(of: result) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .closure(
                                .init(
                                    parameters: [],
                                    parameterConventions: [],
                                    result: .void
                                )
                            ),
                            actual: function.type(of: result)
                        )
                    }
                    let capturedValues = try captures.map { register in
                        try copyCharging(
                            try read(register, registers: registers),
                            budget: budget
                        )
                    }
                    try chargeAggregate(elementCount: capturedValues.count, budget: budget)
                    try initialize(
                        .closure(
                            .init(
                                target: .image(callee),
                                signature: signature,
                                captures: capturedValues,
                                dynamicScope: lifetime == .lexical
                                    ? .init() : nil
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .beginClosureScope(result, closureRegister):
                    guard case let .closure(closure) = try read(
                        closureRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: closureRegister)
                                ?? .never,
                            actual: try read(
                                closureRegister,
                                registers: registers
                            ).type
                        )
                    }
                    try initialize(
                        .closure(
                            .init(
                                target: closure.target,
                                signature: closure.signature,
                                captures: closure.captures,
                                dynamicScope: .init(
                                    parent: closure.dynamicScope
                                )
                            )
                        ),
                        register: result,
                        registers: &registers
                    )
                case let .endClosureScope(closureRegister):
                    guard case let .closure(closure) = try read(
                        closureRegister,
                        registers: registers
                    ), let scope = closure.dynamicScope else {
                        throw VM.RuntimeTrap.explicit(
                            "end_closure_scope requires a scoped closure"
                        )
                    }
                    let escaped = try closureScopeIsReachable(
                        scope,
                        excluding: closureRegister,
                        registers: registers,
                        stackSlots: stackSlots,
                        function: function,
                        blockID: block.id,
                        instructionIndex: instructionIndex,
                        budget: budget
                    )
                    try scope.end()
                    guard !escaped else {
                        throw VM.RuntimeTrap.explicit(
                            "dynamically scoped closure escaped its lifetime"
                        )
                    }
                    // Scope end is a consuming operation. Clearing this exact
                    // SSA root also releases any inner lexical closure it
                    // captured before the inner scope performs its own escape
                    // scan; aliases and aggregate copies were already checked
                    // above and still trap.
                    _ = try take(
                        closureRegister,
                        registers: &registers
                    )
                case let .closureApply(result, closureRegister, arguments):
                    guard case let .closure(closure) = try read(
                        closureRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: closureRegister) ?? .never,
                            actual: try read(closureRegister, registers: registers).type
                        )
                    }
                    try closure.dynamicScope?.requireActive()
                    let values = try arguments.map { try read($0, registers: registers) }
                    switch closure.target {
                    case let .image(functionID):
                        guard let calleeFunction = functions[functionID],
                              calleeFunction.parameterConventions.count
                                >= arguments.count
                        else {
                            throw VM.RuntimeTrap.unknownFunction(functionID)
                        }
                        let callValues = values + closure.captures
                        try chargeCallShape(callValues, budget: budget)
                        try consumeOwnedCallArguments(
                            arguments,
                            conventions: Array(
                                calleeFunction.parameterConventions.prefix(
                                    arguments.count
                                )
                            ),
                            function: function,
                            localTypes: localTypes,
                            registers: &registers
                        )
                        persist(
                            frame,
                            registers: registers,
                            stackSlots: stackSlots,
                            currentBlock: currentBlock,
                            nextInstruction: instructionIndex + 1
                        )
                        try budget.checkDeadline()
                        return .call(
                            FrameCall(
                                functionID: functionID,
                                arguments: callValues,
                                continuation: .returning(
                                    result: result,
                                    programCounter: programCounter
                                )
                            )
                        )
                    case let .native(nativeClosure):
                        guard closure.captures.isEmpty,
                              nativeClosure.signature == closure.signature,
                              closure.signature.isNativeBridgeCallable,
                              arguments.count == closure.signature.parameters.count
                        else {
                            throw VM.RuntimeTrap.nativeFailure(
                                "native closure value disagrees with its callable ABI"
                            )
                        }
                        try chargeCallShape(values, budget: budget)
                        try consumeOwnedCallArguments(
                            arguments,
                            conventions: closure.signature.parameterConventions,
                            function: function,
                            localTypes: localTypes,
                            registers: &registers
                        )
                        // Calling an SDK-provided closure is an externally
                        // observable native action even when its Swift function
                        // type carries no explicit effect annotation.
                        try budget.consumeNativeCall(hasSideEffects: true)
                        try budget.checkDeadline()
                        let value = try nativeClosure.invoke(
                            arguments: values,
                            budget: budget
                        )
                        try budget.checkDeadline()
                        if let value {
                            // Native callable signatures are closure-free at
                            // their own result boundary; do not extend the
                            // NativeImport-only callable-result exception.
                            try budget.consumeBoundaryValue(value)
                            try validateRuntimeValue(
                                value,
                                expected: closure.signature.result,
                                localTypes: localTypes,
                                budget: budget
                            )
                        }
                        try storeCallResult(
                            value,
                            in: result,
                            function: function,
                            registers: &registers,
                            localTypes: localTypes,
                            budget: budget
                        )
                    }
                case let .closureTryApply(
                    closureRegister,
                    arguments,
                    normalTarget,
                    errorTarget
                ):
                    guard case let .closure(closure) = try read(
                        closureRegister,
                        registers: registers
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .closure(
                                .init(
                                    parameters: [],
                                    parameterConventions: [],
                                    result: .void
                                )
                            ),
                            actual: try read(
                                closureRegister,
                                registers: registers
                            ).type
                        )
                    }
                    try closure.dynamicScope?.requireActive()
                    guard let functionID = closure.imageFunctionID else {
                        throw VM.RuntimeTrap.nativeFailure(
                            "closure_try_apply requires an image closure body"
                        )
                    }
                    guard let calleeFunction = functions[functionID],
                          calleeFunction.parameterConventions.count
                            >= arguments.count
                    else {
                        throw VM.RuntimeTrap.unknownFunction(functionID)
                    }
                    let values = try arguments.map {
                        try read($0, registers: registers)
                    }
                    let callValues = values + closure.captures
                    try chargeCallShape(callValues, budget: budget)
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: Array(
                            calleeFunction.parameterConventions.prefix(
                                arguments.count
                            )
                        ),
                        function: function,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    persist(
                        frame,
                        registers: registers,
                        stackSlots: stackSlots,
                        currentBlock: currentBlock,
                        nextInstruction: instructionIndex + 1
                    )
                    try budget.checkDeadline()
                    return .call(
                        FrameCall(
                            functionID: functionID,
                            arguments: callValues,
                            continuation: .throwing(
                                normalTarget: normalTarget,
                                errorTarget: errorTarget,
                                programCounter: programCounter
                            )
                        )
                    )
                case let .tryApply(callee, arguments, normalTarget, errorTarget):
                    guard let calleeFunction = functions[callee] else {
                        throw VM.RuntimeTrap.unknownFunction(callee)
                    }
                    let values = try arguments.map { try read($0, registers: registers) }
                    try chargeCallShape(values, budget: budget)
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: calleeFunction.parameterConventions,
                        function: function,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    persist(
                        frame,
                        registers: registers,
                        stackSlots: stackSlots,
                        currentBlock: currentBlock,
                        nextInstruction: instructionIndex + 1
                    )
                    try budget.checkDeadline()
                    return .call(
                        FrameCall(
                            functionID: callee,
                            arguments: values,
                            continuation: .throwing(
                                normalTarget: normalTarget,
                                errorTarget: errorTarget,
                                programCounter: programCounter
                            )
                        )
                    )
                case let .entryTryApply(entry, arguments, normalTarget, errorTarget):
                    guard let entryInvocation else { throw VM.RuntimeTrap.unknownEntry(entry) }
                    let values = try arguments.map { try read($0, registers: registers) }
                    try chargeCallShape(values, budget: budget)
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: Array(repeating: .owned, count: arguments.count),
                        function: function,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    switch entryInvocation(entry, values, budget) {
                    case let .returned(value):
                        try transferCallOutcome(
                            value,
                            to: frame.blocks[normalTarget]!,
                            function: function,
                            registers: &registers,
                            localTypes: localTypes,
                            budget: budget
                        )
                        currentBlock = normalTarget
                    case let .businessError(message):
                        try transferBusinessError(
                            VM.BusinessError(message: message, requiresBoundaryCharge: true),
                            to: frame.blocks[errorTarget]!,
                            function: function,
                            registers: &registers,
                            localTypes: localTypes,
                            budget: budget
                        )
                        currentBlock = errorTarget
                    case let .trapped(trap):
                        throw trap
                    }
                    advancedToNextBlock = true
                case let .nativeTryApply(importID, arguments, normalTarget, errorTarget):
                    guard let invoker = nativeCatalog[importID] else {
                        throw VM.RuntimeTrap.unknownNativeImport(importID)
                    }
                    let values = try arguments.map { try read($0, registers: registers) }
                    try chargeCallShape(values, budget: budget)
                    guard values.count == invoker.parameterTypes.count,
                          zip(values, invoker.parameterTypes).allSatisfy({
                              $0.matches($1)
                          })
                    else {
                        throw VM.RuntimeTrap.nativeFailure(
                            "runtime argument check failed for import \(importID)"
                        )
                    }
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: nativeParameterConventions(invoker),
                        function: function,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    switch try invokeNative(
                        invoker,
                        id: importID,
                        arguments: values,
                        budget: budget
                    ) {
                    case let .returned(value):
                        if let value {
                            try budget.consumeBoundaryValue(value)
                            try validateRuntimeValue(
                                value,
                                expected: invoker.resultType,
                                localTypes: localTypes,
                                budget: budget
                            )
                        }
                        try transferCallOutcome(
                            value,
                            to: frame.blocks[normalTarget]!,
                            function: function,
                            registers: &registers,
                            localTypes: localTypes,
                            budget: budget
                        )
                        currentBlock = normalTarget
                    case let .businessError(message):
                        guard invoker.effects.mayThrow else {
                            throw VM.RuntimeTrap.nativeFailure(
                                "nonthrowing import \(importID) returned a business error"
                            )
                        }
                        try transferBusinessError(
                            VM.BusinessError(message: message, requiresBoundaryCharge: true),
                            to: frame.blocks[errorTarget]!,
                            function: function,
                            registers: &registers,
                            localTypes: localTypes,
                            budget: budget
                        )
                        currentBlock = errorTarget
                    }
                    advancedToNextBlock = true
                case let .returnValue(register):
                    try budget.checkDeadline()
                    return .returned(
                        try register.map { try read($0, registers: registers) }
                    )
                case let .throwError(error):
                    let value = try consume(
                        error,
                        type: function.type(of: error)!,
                        localTypes: localTypes,
                        registers: &registers
                    )
                    throw VM.BusinessError(
                        value: value,
                        requiresBoundaryCharge: false
                    )
                case let .sourceFailure(prefix, detailRegister):
                    let detail = try read(detailRegister, registers: registers)
                    switch detail {
                    case let .string(message):
                        throw VM.RuntimeTrap.sourceFailure(
                            prefix: prefix,
                            detail: message
                        )
                    case let .error(error):
                        throw VM.RuntimeTrap.sourceFailure(
                            prefix: prefix,
                            detail: error.message
                        )
                    default:
                        guard let diagnostic = localErrorDiagnostic(
                            detail,
                            localTypes: localTypes
                        )
                        else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .error,
                                actual: detail.type
                            )
                        }
                        throw VM.RuntimeTrap.sourceFailure(
                            prefix: prefix,
                            detail: diagnostic
                        )
                    }
                case let .trap(reason):
                    throw runtimeTrap(for: reason)
                }
                try budget.checkDeadline()
                if advancedToNextBlock {
                    frame.currentBlock = currentBlock
                    frame.instructionOffset = 0
                    break
                }
            }
            guard advancedToNextBlock else { throw VM.RuntimeTrap.invalidProgramCounter }
        }
    }

    private func persist(
        _ frame: ExecutionFrame,
        registers: [VM.Value?],
        stackSlots: [VM.MemoryCell],
        currentBlock: Bytecode.BlockID,
        nextInstruction: Int
    ) {
        frame.registers = registers
        frame.stackSlots = stackSlots
        frame.currentBlock = currentBlock
        frame.instructionOffset = nextInstruction
    }

    private func initialize(
        _ value: VM.Value,
        register: Bytecode.Register,
        registers: inout [VM.Value?]
    ) throws {
        let index = Int(register.rawValue)
        guard registers.indices.contains(index) else { throw VM.RuntimeTrap.undefinedRegister(register) }
        guard registers[index] == nil else { throw VM.RuntimeTrap.registerAlreadyInitialized(register) }
        registers[index] = value
    }

    private func consumeOwnedCallArguments(
        _ arguments: [Bytecode.Register],
        conventions: [Bytecode.ParameterConvention],
        function: Bytecode.Function,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        registers: inout [VM.Value?]
    ) throws {
        for (argument, convention) in zip(arguments, conventions)
        where convention == .owned {
            if let type = function.type(of: argument),
               requiresManagedOwnership(type, localTypes: localTypes) {
                _ = try take(argument, registers: &registers)
            }
        }
    }

    private func validateRuntimeValue(
        _ value: VM.Value,
        expected: Bytecode.ValueType,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition] = [:],
        budget: VM.InvocationBudget? = nil,
        depth: Int = 0
    ) throws {
        guard depth <= VM.ValueLimits.maximumNestingDepth else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(
                maximum: VM.ValueLimits.maximumNestingDepth
            )
        }
        switch (value, expected) {
        case (.bool, .bool), (.string, .string):
            break
        case let (.any(erased), .any):
            guard erased.dynamicType.isAnyPayloadV1 else {
                throw VM.RuntimeTrap.typeMismatch(expected: .any, actual: .any)
            }
            try validateRuntimeValue(
                erased.payload,
                expected: erased.dynamicType.storageType,
                localTypes: localTypes,
                budget: budget,
                depth: depth + 1
            )
            guard erased.payload.matches(erased.dynamicType) else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: erased.dynamicType.storageType,
                    actual: erased.payload.type
                )
            }
        case let (.address(address), .address(pointee)):
            guard address.pointee == pointee, address.isScoped else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
        case let (.mutableCell(cell), .mutableCell(pointee)):
            guard cell.pointee == pointee else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: expected,
                    actual: value.type
                )
            }
        case let (
            .nonOwningReference(reference),
            .nonOwningReference(kind, pointee)
        ):
            guard reference.kind == kind, reference.pointee == pointee else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: expected,
                    actual: value.type
                )
            }
        case let (.arrayBuilder(builder), .arrayState(.builder, element)):
            guard builder.elementType == element else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: expected,
                    actual: value.type
                )
            }
        case let (
            .arrayMutationState(state),
            .arrayState(.mutation, element)
        ):
            guard state.elementType == element else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: expected,
                    actual: value.type
                )
            }
        case let (
            .dictionaryBuilder(builder),
            .dictionaryState(key, valueType)
        ):
            guard builder.keyType == key, builder.valueType == valueType else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: expected,
                    actual: value.type
                )
            }
        case let (.arraySortState(state), .arrayState(.stableSort, element)):
            guard state.elementType == element else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: expected,
                    actual: value.type
                )
            }
        case let (.arraySplitState(state), .arrayState(.split, element)):
            guard state.elementType == element else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: expected,
                    actual: value.type
                )
            }
        case let (.closure(closure), .closure(signature)):
            guard closure.signature == signature else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
        case let (.integer(integer), .integer(bitWidth, signed)):
            guard integer.bitWidth == bitWidth, integer.isSigned == signed else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
        case let (.float(floating), .float(expectedBitWidth)):
            guard floating.bitWidth == expectedBitWidth else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
        case let (.native(native), .native(id)):
            guard native.typeID == id else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
            guard let operations = nativeTypeCatalog[id] else {
                throw VM.RuntimeTrap.unknownNativeType(id)
            }
            guard native.canonicalTypeName == operations.canonicalName,
                  native.layoutFingerprint == operations.layoutFingerprint
            else {
                throw VM.RuntimeTrap.nativeTypeDescriptorMismatch(id)
            }
        case let (.structure(actualKey, values), .local(expectedKey)):
            guard actualKey == expectedKey,
                  let definition = localTypes[expectedKey],
                  case let .structure(fields) = definition.kind,
                  values.count == fields.count
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
            for (value, field) in zip(values, fields) {
                try validateRuntimeValue(
                    value,
                    expected: field.type,
                    localTypes: localTypes,
                    budget: budget,
                    depth: depth + 1
                )
            }
        case let (.enumeration(actualKey, caseIndex, payload), .local(expectedKey)):
            guard actualKey == expectedKey,
                  let definition = localTypes[expectedKey],
                  case let .enumeration(cases) = definition.kind,
                  let index = Int(exactly: caseIndex),
                  cases.indices.contains(index)
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
            switch (payload, cases[index].payloadType) {
            case (nil, nil):
                break
            case let (.some(value), .some(type)):
                try validateRuntimeValue(
                    value,
                    expected: type,
                    localTypes: localTypes,
                    budget: budget,
                    depth: depth + 1
                )
            default:
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
        case let (.object(object), .local(expectedKey)):
            guard object.typeKey == expectedKey,
                  let definition = localTypes[expectedKey],
                  case let .class(fields, _, _) = definition.kind,
                  object.storage.fieldCount == fields.count
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
        case let (.error(error), .error):
            switch (error.concreteType, error.payload) {
            case (nil, nil):
                break
            case let (.some(key), .some(payload)):
                guard localTypes[key]?.conformsToError == true else {
                    throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
                }
                try validateRuntimeValue(
                    payload,
                    expected: .local(key),
                    localTypes: localTypes,
                    budget: budget,
                    depth: depth + 1
                )
            default:
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
        case let (.tuple(values), .tuple(types)):
            guard values.count == types.count else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
            for (element, type) in zip(values, types) {
                try validateRuntimeValue(
                    element,
                    expected: type,
                    localTypes: localTypes,
                    budget: budget,
                    depth: depth + 1
                )
            }
        case let (.array(storage), .array(expectedElement)):
            guard storage.elementType == expectedElement else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
            _ = try storage.endIndex()
            for element in storage.elements {
                try validateRuntimeValue(
                    element,
                    expected: expectedElement,
                    localTypes: localTypes,
                    budget: budget,
                    depth: depth + 1
                )
            }
        case let (
            .dictionary(entries, actualKey, actualValue),
            .dictionary(expectedKey, expectedValue)
        ):
            guard actualKey == expectedKey, actualValue == expectedValue else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
            let validateEntries = {
                var keys: [VM.Value] = []
                keys.reserveCapacity(entries.count)
                for entry in entries {
                    try validateRuntimeValue(
                        entry.key,
                        expected: expectedKey,
                        localTypes: localTypes,
                        budget: budget,
                        depth: depth + 1
                    )
                    try validateRuntimeValue(
                        entry.value,
                        expected: expectedValue,
                        localTypes: localTypes,
                        budget: budget,
                        depth: depth + 1
                    )
                    var isDuplicate = false
                    for key in keys {
                        if try vmValuesEqual(
                            key,
                            entry.key,
                            budget: budget
                        ) {
                            isDuplicate = true
                            break
                        }
                    }
                    guard !isDuplicate else {
                        throw VM.RuntimeTrap.nativeFailure(
                            "Dictionary boundary value contains a duplicate key"
                        )
                    }
                    keys.append(entry.key)
                }
            }
            if let budget {
                // Duplicate detection owns only transient scratch.
                try budget.withTemporaryAggregateStorage(
                    elementCount: entries.count,
                    validateEntries
                )
            } else {
                try validateEntries()
            }
        case let (.set(set), .set(expectedElement)):
            guard expectedElement.isVMHashable,
                  set.elementType == expectedElement
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
            let validateElements = {
                var unique: [VM.Value] = []
                unique.reserveCapacity(set.elements.count)
                for element in set.elements {
                    try validateRuntimeValue(
                        element,
                        expected: expectedElement,
                        localTypes: localTypes,
                        budget: budget,
                        depth: depth + 1
                    )
                    var isDuplicate = false
                    for existing in unique {
                        if try vmValuesEqual(
                            existing,
                            element,
                            budget: budget
                        ) {
                            isDuplicate = true
                            break
                        }
                    }
                    guard !isDuplicate else {
                        throw VM.RuntimeTrap.nativeFailure(
                            "Set boundary value contains a duplicate element"
                        )
                    }
                    unique.append(element)
                }
            }
            if let budget {
                try budget.withTemporaryAggregateStorage(
                    elementCount: set.elements.count,
                    validateElements
                )
            } else {
                try validateElements()
            }
        case let (.optional(.some(wrapped)), .optional(type)):
            try validateRuntimeValue(
                wrapped,
                expected: type,
                localTypes: localTypes,
                budget: budget,
                depth: depth + 1
            )
        case (.optional(nil), .optional):
            break
        default:
            throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
        }
    }

    private func read(_ register: Bytecode.Register, registers: [VM.Value?]) throws -> VM.Value {
        let index = Int(register.rawValue)
        guard registers.indices.contains(index) else { throw VM.RuntimeTrap.undefinedRegister(register) }
        guard let value = registers[index] else { throw VM.RuntimeTrap.consumedRegister(register) }
        return value
    }

    private func take(_ register: Bytecode.Register, registers: inout [VM.Value?]) throws -> VM.Value {
        let value = try read(register, registers: registers)
        registers[Int(register.rawValue)] = nil
        return value
    }

    private func consume(
        _ register: Bytecode.Register,
        type: Bytecode.ValueType,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        registers: inout [VM.Value?]
    ) throws -> VM.Value {
        guard requiresManagedOwnership(type, localTypes: localTypes) else {
            return try read(register, registers: registers)
        }
        return try take(register, registers: &registers)
    }

    /// Managed ownership is a property of the verified type graph, not of the
    /// aggregate's current element count. Keeping this check structural avoids
    /// unmetered value traversal on every move, call, or block transfer while
    /// still ending owners for local/native class references nested in values.
    private func requiresManagedOwnership(
        _ type: Bytecode.ValueType,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) -> Bool {
        if type.requiresLinearOwnership { return true }
        var visiting = Set<Bytecode.LocalTypeKey>()

        func visit(_ type: Bytecode.ValueType) -> Bool {
            switch type {
            case let .local(key):
                guard visiting.insert(key).inserted,
                      let definition = localTypes[key]
                else { return false }
                defer { visiting.remove(key) }
                switch definition.kind {
                case .class:
                    return true
                case let .structure(fields):
                    return fields.contains { visit($0.type) }
                case let .enumeration(cases):
                    return cases.contains { item in
                        item.payloadType.map(visit) == true
                    }
                }
            case let .optional(wrapped), let .array(wrapped),
                 let .set(wrapped):
                return visit(wrapped)
            case let .dictionary(key, value):
                return visit(key) || visit(value)
            case let .tuple(elements):
                return elements.contains(where: visit)
            case .any, .error:
                return true
            case .void, .never, .bool, .integer, .float, .string,
                 .native, .address, .mutableCell,
                 .nonOwningReference, .arrayState, .dictionaryState,
                 .closure:
                return false
            }
        }

        return visit(type)
    }

    private func read(
        _ slot: Bytecode.StackSlot,
        stackSlots: [VM.MemoryCell]
    ) throws -> VM.Value {
        let index = Int(slot.rawValue)
        guard stackSlots.indices.contains(index) else {
            throw VM.RuntimeTrap.unknownStackSlot(slot)
        }
        do { return try stackSlots[index].directRead() } catch VM.RuntimeTrap.uninitializedAddress {
            throw VM.RuntimeTrap.uninitializedStackSlot(slot)
        }
    }

    private func take(
        _ slot: Bytecode.StackSlot,
        stackSlots: inout [VM.MemoryCell]
    ) throws -> VM.Value {
        let index = Int(slot.rawValue)
        guard stackSlots.indices.contains(index) else {
            throw VM.RuntimeTrap.unknownStackSlot(slot)
        }
        do { return try stackSlots[index].directTake() } catch VM.RuntimeTrap.uninitializedAddress {
            throw VM.RuntimeTrap.uninitializedStackSlot(slot)
        }
    }

    private func store(
        _ value: VM.Value,
        in slot: Bytecode.StackSlot,
        mode: Bytecode.StackStoreMode,
        stackSlots: inout [VM.MemoryCell]
    ) throws {
        let index = Int(slot.rawValue)
        guard stackSlots.indices.contains(index) else {
            throw VM.RuntimeTrap.unknownStackSlot(slot)
        }
        do {
            try stackSlots[index].directStore(value, mode: mode)
        } catch VM.RuntimeTrap.addressAlreadyInitialized {
            throw VM.RuntimeTrap.stackSlotAlreadyInitialized(slot)
        } catch VM.RuntimeTrap.uninitializedAddress {
            throw VM.RuntimeTrap.uninitializedStackSlot(slot)
        }
    }

    private func chargeAggregate(
        elementCount: Int,
        budget: VM.InvocationBudget
    ) throws {
        try budget.consumeAggregateStorage(elementCount: elementCount)
    }

    private func integer(_ register: Bytecode.Register, registers: [VM.Value?]) throws -> VM.Integer {
        let value = try read(register, registers: registers)
        guard case let .integer(integer) = value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .int64, actual: value.type)
        }
        return integer
    }

    private func boolean(
        _ register: Bytecode.Register,
        registers: [VM.Value?]
    ) throws -> Bool {
        let value = try read(register, registers: registers)
        guard case let .bool(boolean) = value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .bool, actual: value.type)
        }
        return boolean
    }

    private func splitMaximum(
        _ register: Bytecode.Register,
        registers: [VM.Value?]
    ) throws -> Int {
        let value = try integer(register, registers: registers).signedValue
        guard value >= 0, let exact = Int(exactly: value) else {
            throw VM.RuntimeTrap.explicit(
                "maximum split count cannot be negative"
            )
        }
        return exact
    }

    private func nonOwningReferenceTarget(
        kind: Bytecode.NonOwningReferenceKind,
        pointee: Bytecode.ValueType,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) throws -> VM.NonOwningReference.Target {
        let strongType: Bytecode.ValueType
        if case let .optional(wrapped) = pointee {
            strongType = wrapped
        } else {
            guard kind == .unowned else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .optional(pointee),
                    actual: pointee
                )
            }
            strongType = pointee
        }

        switch strongType {
        case let .local(key):
            guard let definition = localTypes[key],
                  case .class = definition.kind
            else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: strongType,
                    actual: strongType
                )
            }
            return .local(key)
        case let .native(id):
            guard nativeTypeCatalog[id]?.kind == .reference else {
                throw VM.RuntimeTrap.nativeTypeMismatch(expected: id)
            }
            return .native(id)
        default:
            throw VM.RuntimeTrap.typeMismatch(
                expected: strongType,
                actual: strongType
            )
        }
    }

    private func store(
        _ value: VM.Value,
        in reference: VM.NonOwningReference,
        mode: Bytecode.StackStoreMode
    ) throws {
        guard value.hasRuntimeType(reference.pointee) else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: reference.pointee,
                actual: value.type
            )
        }

        let payload: VM.Value?
        if case .optional = reference.pointee {
            guard case let .optional(wrapped) = value else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: reference.pointee,
                    actual: value.type
                )
            }
            payload = wrapped
        } else {
            payload = value
        }

        let object: AnyObject?
        switch (reference.target, payload) {
        case (_, nil):
            object = nil
        case let (.local(expected), .some(.object(value))):
            guard value.typeKey == expected else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .local(expected),
                    actual: .local(value.typeKey)
                )
            }
            object = value
        case let (.native(expected), .some(.native(value))):
            guard value.typeID == expected else {
                throw VM.RuntimeTrap.nativeTypeMismatch(expected: expected)
            }
            object = try nativeTypeCatalog.referencedObject(in: value)
        default:
            throw VM.RuntimeTrap.typeMismatch(
                expected: reference.pointee,
                actual: value.type
            )
        }
        try reference.store(object: object, mode: mode)
    }

    private func load(
        from reference: VM.NonOwningReference,
        mode: Bytecode.StackLoadMode,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        guard let object = try reference.loadObject(mode: mode) else {
            guard case .optional = reference.pointee else {
                throw VM.RuntimeTrap.danglingUnownedReference
            }
            return .optional(nil)
        }

        let strong: VM.Value
        switch reference.target {
        case let .local(expected):
            guard let value = object as? VM.ObjectReference,
                  value.typeKey == expected
            else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .local(expected),
                    actual: nil
                )
            }
            strong = .object(value)
        case let .native(expected):
            let value = try nativeTypeCatalog.boxReference(
                object,
                as: expected
            )
            try budget.consumeNativeOwned(bytes: value.estimatedByteCount)
            strong = .native(value)
        }
        if case .optional = reference.pointee {
            return .optional(strong)
        }
        return strong
    }

    private func copy(_ value: VM.Value) throws -> VM.Value {
        if value.type.isVMHashable {
            // This closed family contains no native handles or mutable cells.
            // Sharing its immutable COW storage is both safe and required for
            // Swift's reflexive collection equality when payloads contain NaN.
            return value
        }
        return switch value {
        case let .native(native):
            .native(try nativeTypeCatalog.copy(native))
        case let .any(erased):
            .any(
                .init(
                    dynamicType: erased.dynamicType,
                    payload: try copy(erased.payload)
                )
            )
        case let .tuple(elements):
            .tuple(try elements.map(copy))
        case let .array(storage):
            .array(
                try storage.elements.map(copy),
                elementType: storage.elementType,
                indexBase: storage.indexBase
            )
        case let .dictionary(entries, keyType, valueType):
            .dictionary(
                try entries.map {
                    .init(key: try copy($0.key), value: try copy($0.value))
                },
                keyType: keyType,
                valueType: valueType
            )
        case let .set(set):
            // Malformed non-VM-hashable Set types are rejected by verification;
            // keep this total for diagnostics and direct unit fixtures.
            .set(set)
        case let .optional(.some(wrapped)):
            .optional(try copy(wrapped))
        case .optional(nil):
            .optional(nil)
        case let .structure(type, fields):
            .structure(type: type, fields: try fields.map(copy))
        case let .enumeration(type, caseIndex, payload):
            .enumeration(
                type: type,
                caseIndex: caseIndex,
                payload: try payload.map(copy)
            )
        case .object:
            value
        case let .error(error):
            .error(
                VM.ErrorValue(
                    concreteType: error.concreteType,
                    payload: try error.payload.map(copy),
                    message: error.message
                )
            )
        case let .closure(closure):
            .closure(
                .init(
                    target: closure.target,
                    signature: closure.signature,
                    captures: try closure.captures.map(copy),
                    dynamicScope: closure.dynamicScope
                )
            )
        case .mutableCell:
            value
        case .nonOwningReference:
            value
        case .arrayBuilder, .arrayMutationState, .dictionaryBuilder,
             .arraySortState, .arraySplitState:
            throw VM.RuntimeTrap.explicit(
                "collection construction state cannot be copied"
            )
        case .address:
            throw VM.RuntimeTrap.inactiveAddressAccess
        case .bool, .integer, .float, .string:
            value
        }
    }

    private func closureScopeIsReachable(
        _ scope: VM.ClosureScope,
        excluding closureRegister: Bytecode.Register,
        registers: [VM.Value?],
        stackSlots: [VM.MemoryCell],
        function: Bytecode.Function,
        blockID: Bytecode.BlockID,
        instructionIndex: Int,
        budget: VM.InvocationBudget
    ) throws -> Bool {
        func inspectCell(
            _ cell: VM.MemoryCell,
            depth: Int,
            visitedReferences: inout Set<ObjectIdentifier>
        ) throws -> Bool {
            guard visitedReferences.insert(ObjectIdentifier(cell)).inserted
            else { return false }
            for value in cell.initializedValuesForInspection() {
                if try inspect(
                    value,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                ) {
                    return true
                }
            }
            return false
        }

        func inspect(
            _ value: VM.Value,
            depth: Int,
            visitedReferences: inout Set<ObjectIdentifier>
        ) throws -> Bool {
            guard depth <= VM.ValueLimits.maximumNestingDepth else {
                throw VM.RuntimeTrap.valueNestingDepthExceeded(
                    maximum: VM.ValueLimits.maximumNestingDepth
                )
            }
            try budget.consumeWork(units: 1)
            switch value {
            case let .closure(closure):
                if let dynamicScope = closure.dynamicScope,
                   dynamicScope.depends(on: scope) {
                    return true
                }
                for capture in closure.captures {
                    if try inspect(
                        capture,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .any(erased):
                return try inspect(
                    erased.payload,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                )
            case let .tuple(elements):
                for element in elements {
                    if try inspect(
                        element,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .array(storage):
                for element in storage.elements {
                    if try inspect(
                        element,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .dictionary(entries, _, _):
                for entry in entries {
                    if try inspect(
                        entry.key,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) || inspect(
                        entry.value,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .set(set):
                for element in set.elements {
                    if try inspect(
                        element,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .optional(.some(wrapped)):
                return try inspect(
                    wrapped,
                    depth: depth + 1,
                    visitedReferences: &visitedReferences
                )
            case let .structure(_, fields):
                for field in fields {
                    if try inspect(
                        field,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .enumeration(_, _, payload):
                if let payload {
                    return try inspect(
                        payload,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    )
                }
            case let .object(object):
                let identity = ObjectIdentifier(object.storage)
                guard visitedReferences.insert(identity).inserted else {
                    return false
                }
                for field in object.storage.initializedValuesForInspection() {
                    if try inspect(
                        field,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .error(error):
                if let payload = error.payload {
                    return try inspect(
                        payload,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    )
                }
            case let .address(address):
                return try inspectCell(
                    address.cell,
                    depth: depth,
                    visitedReferences: &visitedReferences
                )
            case let .mutableCell(cell):
                return try inspectCell(
                    cell.storageForInspection,
                    depth: depth,
                    visitedReferences: &visitedReferences
                )
            case let .arrayBuilder(builder):
                for element in builder.valuesForInspection() {
                    if try inspect(
                        element,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .arrayMutationState(state):
                for element in state.valuesForInspection() {
                    if try inspect(
                        element,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .dictionaryBuilder(builder):
                for value in builder.valuesForInspection() {
                    if try inspect(
                        value,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .arraySortState(state):
                for element in state.valuesForInspection() {
                    if try inspect(
                        element,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case let .arraySplitState(state):
                for element in state.valuesForInspection() {
                    if try inspect(
                        element,
                        depth: depth + 1,
                        visitedReferences: &visitedReferences
                    ) {
                        return true
                    }
                }
            case .optional(nil), .native, .nonOwningReference, .bool,
                 .integer, .float, .string:
                break
            }
            return false
        }

        func containsScope(_ value: VM.Value) throws -> Bool {
            var visitedReferences = Set<ObjectIdentifier>()
            return try inspect(
                value,
                depth: 0,
                visitedReferences: &visitedReferences
            )
        }

        var candidateRegisters = Set<Bytecode.Register>()
        for (index, value) in registers.enumerated()
        where UInt32(index) != closureRegister.rawValue {
            guard let raw = UInt32(exactly: index), let value else { continue }
            if try containsScope(value) {
                candidateRegisters.insert(.init(rawValue: raw))
            }
        }
        for slot in stackSlots {
            var visitedReferences = Set<ObjectIdentifier>()
            if try inspectCell(
                slot,
                depth: 0,
                visitedReferences: &visitedReferences
            ) {
                return true
            }
        }
        return try registersAreUsedAfter(
            candidateRegisters,
            function: function,
            blockID: blockID,
            instructionIndex: instructionIndex,
            budget: budget
        )
    }

    /// SSA values remain physically present in the register array after their
    /// final semantic use. A dynamically scoped closure escapes only when a
    /// root that still reaches it is used after the scope-end instruction.
    /// This forward, candidate-only analysis also handles loop redefinitions
    /// without materializing a dense liveness table for untrusted bytecode.
    private func registersAreUsedAfter(
        _ candidates: Set<Bytecode.Register>,
        function: Bytecode.Function,
        blockID: Bytecode.BlockID,
        instructionIndex: Int,
        budget: VM.InvocationBudget
    ) throws -> Bool {
        guard !candidates.isEmpty else { return false }
        let blocks = Dictionary(
            uniqueKeysWithValues: function.blocks.map { ($0.id, $0) }
        )

        func traverse(
            _ block: Bytecode.Block,
            from start: Int,
            surviving: Set<Bytecode.Register>
        ) throws -> (used: Bool, surviving: Set<Bytecode.Register>) {
            var surviving = surviving
            for instruction in block.instructions.dropFirst(start) {
                try budget.consumeWork(units: 1)
                if instruction.operandRegisters.contains(
                    where: surviving.contains
                ) {
                    return (true, surviving)
                }
                surviving.subtract(instruction.resultRegisters)
                if surviving.isEmpty { break }
            }
            return (false, surviving)
        }

        guard let current = blocks[blockID] else {
            throw VM.RuntimeTrap.invalidProgramCounter
        }
        let suffix = try traverse(
            current,
            from: instructionIndex + 1,
            surviving: candidates
        )
        if suffix.used { return true }
        guard !suffix.surviving.isEmpty else { return false }

        var incoming: [Bytecode.BlockID: Set<Bytecode.Register>] = [:]
        var pending: [Bytecode.BlockID] = []
        var queued = Set<Bytecode.BlockID>()

        func forward(
            _ surviving: Set<Bytecode.Register>,
            to targetID: Bytecode.BlockID
        ) throws {
            guard let target = blocks[targetID] else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            let edge = surviving.subtracting(target.parameters)
            guard !edge.isEmpty else { return }
            let prior = incoming[targetID] ?? []
            let additions = edge.subtracting(prior)
            guard !additions.isEmpty else { return }
            incoming[targetID] = prior.union(additions)
            if queued.insert(targetID).inserted {
                pending.append(targetID)
            }
        }

        for successor in current.instructions.last?.successorBlocks ?? [] {
            try forward(suffix.surviving, to: successor)
        }

        while let nextID = pending.popLast() {
            queued.remove(nextID)
            guard let block = blocks[nextID],
                  let state = incoming[nextID]
            else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            let traversed = try traverse(
                block,
                from: 0,
                surviving: state
            )
            if traversed.used { return true }
            guard !traversed.surviving.isEmpty else { continue }
            for successor in block.instructions.last?.successorBlocks ?? [] {
                try forward(traversed.surviving, to: successor)
            }
        }
        return false
    }

    private func mutableCellFieldType(
        _ aggregate: Bytecode.ValueType,
        fieldIndex: UInt32,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) -> Bytecode.ValueType? {
        guard let index = Int(exactly: fieldIndex) else { return nil }
        switch aggregate {
        case let .tuple(elements):
            guard elements.indices.contains(index) else { return nil }
            return elements[index]
        case let .local(key):
            guard let definition = localTypes[key],
                  case let .structure(fields) = definition.kind,
                  fields.indices.contains(index)
            else { return nil }
            return fields[index].type
        default:
            return nil
        }
    }

    private func storageShape(
        _ type: Bytecode.ValueType,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        depth: Int = 0,
        visiting: Set<Bytecode.LocalTypeKey> = []
    ) throws -> VM.StorageShape {
        guard depth <= VM.ValueLimits.maximumNestingDepth else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(
                maximum: VM.ValueLimits.maximumNestingDepth
            )
        }
        switch type {
        case .tuple([]):
            // Empty products still require an explicit Swift initialization;
            // model them as a leaf so runtime and verifier state agree.
            return .leaf
        case let .tuple(elements):
            return .tuple(
                try elements.map {
                    try storageShape(
                        $0,
                        localTypes: localTypes,
                        depth: depth + 1,
                        visiting: visiting
                    )
                }
            )
        case let .local(key):
            guard !visiting.contains(key),
                  let definition = localTypes[key]
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: type, actual: nil)
            }
            guard case let .structure(fields) = definition.kind else {
                return .leaf
            }
            guard !fields.isEmpty else { return .leaf }
            var nextVisiting = visiting
            nextVisiting.insert(key)
            return .structure(
                key,
                try fields.map {
                    try storageShape(
                        $0.type,
                        localTypes: localTypes,
                        depth: depth + 1,
                        visiting: nextVisiting
                    )
                }
            )
        default:
            return .leaf
        }
    }

    private func prepareCopy(
        _ value: VM.Value,
        budget: VM.InvocationBudget
    ) throws {
        try chargeCopiedValue(value, budget: budget)
    }

    private func copyCharging(
        _ value: VM.Value,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        try prepareCopy(value, budget: budget)
        let result = try copy(value)
        try budget.checkDeadline()
        return result
    }

    private func chargeCopiedValue(
        _ value: VM.Value,
        budget: VM.InvocationBudget,
        depth: Int = 0
    ) throws {
        guard depth <= VM.ValueLimits.maximumNestingDepth else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(
                maximum: VM.ValueLimits.maximumNestingDepth
            )
        }
        try budget.consumeWork(units: 1)
        switch value {
        case let .native(native):
            try budget.consumeNativeOwned(bytes: native.estimatedByteCount)
        case let .any(erased):
            try budget.consumeAggregateStorage(elementCount: 1)
            try chargeCopiedValue(
                erased.payload,
                budget: budget,
                depth: depth + 1
            )
        case let .tuple(elements):
            try budget.consumeAggregateStorage(elementCount: elements.count)
            for element in elements {
                try chargeCopiedValue(element, budget: budget, depth: depth + 1)
            }
        case let .array(storage):
            try budget.consumeAggregateStorage(
                elementCount: storage.elements.count
            )
            for element in storage.elements {
                try chargeCopiedValue(element, budget: budget, depth: depth + 1)
            }
        case let .dictionary(entries, _, _):
            try chargeDictionaryStorage(entryCount: entries.count, budget: budget)
            for entry in entries {
                try chargeCopiedValue(entry.key, budget: budget, depth: depth + 1)
                try chargeCopiedValue(entry.value, budget: budget, depth: depth + 1)
            }
        case let .set(set):
            try budget.consumeAggregateStorage(elementCount: set.elements.count)
            for element in set.elements {
                try chargeCopiedValue(element, budget: budget, depth: depth + 1)
            }
        case let .optional(.some(wrapped)):
            try budget.consumeAggregateStorage(elementCount: 1)
            try chargeCopiedValue(wrapped, budget: budget, depth: depth + 1)
        case .optional(nil):
            try budget.consumeAggregateStorage(elementCount: 0)
        case let .structure(_, fields):
            try budget.consumeAggregateStorage(elementCount: fields.count)
            for field in fields {
                try chargeCopiedValue(field, budget: budget, depth: depth + 1)
            }
        case let .enumeration(_, _, payload):
            try budget.consumeAggregateStorage(elementCount: payload == nil ? 0 : 1)
            if let payload {
                try chargeCopiedValue(payload, budget: budget, depth: depth + 1)
            }
        case .object:
            break
        case let .error(error):
            try budget.consumeAggregateStorage(elementCount: error.payload == nil ? 0 : 1)
            if let payload = error.payload {
                try chargeCopiedValue(payload, budget: budget, depth: depth + 1)
            }
        case let .closure(closure):
            try budget.consumeAggregateStorage(elementCount: closure.captures.count)
            for capture in closure.captures {
                try chargeCopiedValue(capture, budget: budget, depth: depth + 1)
            }
        case .bool, .integer, .float, .string, .address, .mutableCell,
             .nonOwningReference,
             .arrayBuilder, .arrayMutationState, .dictionaryBuilder,
             .arraySortState, .arraySplitState:
            break
        }
    }

    /// Runtime shape checks walk aggregate values recursively at every call
    /// boundary. Charge that work so repeated calls cannot bypass fuel with a
    /// large, already-allocated collection.
    private func chargeCallShape(
        _ values: [VM.Value],
        budget: VM.InvocationBudget
    ) throws {
        for value in values {
            try chargeShapeValidation(value, budget: budget)
        }
    }

    private func chargeShapeValidation(
        _ value: VM.Value,
        budget: VM.InvocationBudget,
        depth: Int = 0
    ) throws {
        try budget.consumeValueTraversal(value, depth: depth)
    }

    private func chargeComparisonWork(
        lhs: VM.Value,
        rhs: VM.Value,
        budget: VM.InvocationBudget
    ) throws {
        try budget.consumeValueTraversal(lhs)
        try budget.consumeValueTraversal(rhs)
    }

    private func vmValuesEqual(
        _ lhs: VM.Value,
        _ rhs: VM.Value,
        budget: VM.InvocationBudget?
    ) throws -> Bool {
        guard let budget else { return VM.HashableValue.equal(lhs, rhs) }
        return try budget.valuesEqual(lhs, rhs)
    }

    private func transfer(
        _ arguments: [Bytecode.Register],
        to target: Bytecode.Block,
        function: Bytecode.Function,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        registers: inout [VM.Value?]
    ) throws {
        var values: [VM.Value] = []
        for (argument, parameter) in zip(arguments, target.parameters) {
            let value = try read(argument, registers: registers)
            if let type = function.type(of: parameter),
               requiresManagedOwnership(type, localTypes: localTypes) {
                values.append(try take(argument, registers: &registers))
            } else {
                values.append(value)
            }
        }
        try transferValues(values, to: target, registers: &registers)
    }

    private func transferValues(
        _ values: [VM.Value],
        to target: Bytecode.Block,
        registers: inout [VM.Value?]
    ) throws {
        guard values.count == target.parameters.count else {
            throw VM.RuntimeTrap.invalidProgramCounter
        }
        for result in target.instructions.flatMap(\.resultRegisters) {
            registers[Int(result.rawValue)] = nil
        }
        for (parameter, value) in zip(target.parameters, values) {
            let index = Int(parameter.rawValue)
            registers[index] = nil
            try initialize(value, register: parameter, registers: &registers)
        }
    }

    private func transferCallOutcome(
        _ value: VM.Value?,
        to target: Bytecode.Block,
        function: Bytecode.Function,
        registers: inout [VM.Value?],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        budget: VM.InvocationBudget
    ) throws {
        switch (value, target.parameters.first) {
        case (nil, nil):
            try transferValues([], to: target, registers: &registers)
        case let (.some(value), .some(parameter)) where target.parameters.count == 1:
            guard let expected = function.type(of: parameter) else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            try chargeShapeValidation(value, budget: budget)
            try validateRuntimeValue(
                value,
                expected: expected,
                localTypes: localTypes
            )
            try transferValues([value], to: target, registers: &registers)
        case (.none, .some):
            throw VM.RuntimeTrap.nativeFailure("non-Void try_apply returned no value")
        case (.some, .none):
            throw VM.RuntimeTrap.nativeFailure("Void try_apply returned a value")
        case (.some, .some):
            throw VM.RuntimeTrap.invalidProgramCounter
        }
    }

    private func transferBusinessError(
        _ error: VM.BusinessError,
        to target: Bytecode.Block,
        function: Bytecode.Function,
        registers: inout [VM.Value?],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        budget: VM.InvocationBudget
    ) throws {
        guard target.parameters.count == 1, let parameter = target.parameters.first else {
            throw VM.RuntimeTrap.invalidProgramCounter
        }
        guard let expected = function.type(of: parameter) else {
            throw VM.RuntimeTrap.invalidProgramCounter
        }
        let value: VM.Value
        switch error.payload {
        case let .value(thrown):
            guard thrown.matches(expected) else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: expected,
                    actual: thrown.type
                )
            }
            try chargeShapeValidation(thrown, budget: budget)
            try validateRuntimeValue(
                thrown,
                expected: expected,
                localTypes: localTypes
            )
            value = thrown
        case let .boundaryMessage(message):
            value = switch expected {
            case .string:
                .string(message)
            case .error:
                .error(.init(message: message))
            default:
                throw VM.RuntimeTrap.invalidProgramCounter
            }
        }
        if error.requiresBoundaryCharge {
            try budget.consumeBoundaryValue(value)
        }
        try transferValues([value], to: target, registers: &registers)
    }

    /// Produces a bounded diagnostic identity without recursively rendering a
    /// potentially large Error payload after execution has already failed.
    private func localErrorDiagnostic(
        _ value: VM.Value,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) -> String? {
        switch value {
        case let .enumeration(key, caseIndex, _):
            guard let definition = localTypes[key],
                  definition.conformsToError,
                  case let .enumeration(cases) = definition.kind,
                  let index = Int(exactly: caseIndex),
                  cases.indices.contains(index)
            else { return nil }
            return "\(key).\(cases[index].name)"
        case let .structure(key, _):
            guard let definition = localTypes[key],
                  definition.conformsToError,
                  case .structure = definition.kind
            else { return nil }
            return key.rawValue
        case let .object(object):
            let key = object.typeKey
            guard let definition = localTypes[key],
                  definition.conformsToError,
                  case .class = definition.kind
            else { return nil }
            return key.rawValue
        default:
            return nil
        }
    }

    private func storeCallResult(
        _ value: VM.Value?,
        in register: Bytecode.Register?,
        function: Bytecode.Function,
        registers: inout [VM.Value?],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        budget: VM.InvocationBudget
    ) throws {
        switch (value, register) {
        case (nil, nil): break
        case let (.some(value), .some(register)):
            guard let expected = function.type(of: register) else {
                throw VM.RuntimeTrap.typeMismatch(expected: .never, actual: value.type)
            }
            try chargeShapeValidation(value, budget: budget)
            try validateRuntimeValue(
                value,
                expected: expected,
                localTypes: localTypes
            )
            try initialize(value, register: register, registers: &registers)
        case (.none, .some): throw VM.RuntimeTrap.nativeFailure("non-Void call returned no value")
        case (.some, .none): throw VM.RuntimeTrap.nativeFailure("Void call returned a value")
        }
    }

    private func calculate(
        _ operation: Bytecode.BinaryOperation,
        lhs: VM.Integer,
        rhs: VM.Integer
    ) throws -> (value: VM.Integer, overflow: Bool) {
        guard lhs.bitWidth == rhs.bitWidth, lhs.isSigned == rhs.isSigned else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .integer(bitWidth: lhs.bitWidth, signed: lhs.isSigned),
                actual: .integer(bitWidth: rhs.bitWidth, signed: rhs.isSigned)
            )
        }
        if lhs.isSigned {
            return try calculateSigned(operation, lhs: lhs, rhs: rhs)
        }
        return try calculateUnsigned(operation, lhs: lhs, rhs: rhs)
    }

    private func floating(
        _ register: Bytecode.Register,
        registers: [VM.Value?]
    ) throws -> VM.FloatingValue {
        let value = try read(register, registers: registers)
        guard case let .float(number) = value else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .float(bitWidth: 64),
                actual: value.type
            )
        }
        return number
    }

    private func string(
        _ register: Bytecode.Register,
        registers: [VM.Value?]
    ) throws -> String {
        let value = try read(register, registers: registers)
        guard case let .string(string) = value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .string, actual: value.type)
        }
        return string
    }

    private func array(
        _ register: Bytecode.Register,
        registers: [VM.Value?]
    ) throws -> (values: [VM.Value], elementType: Bytecode.ValueType) {
        let storage = try arrayStorage(register, registers: registers)
        return (storage.elements, storage.elementType)
    }

    private func arrayStorage(
        _ register: Bytecode.Register,
        registers: [VM.Value?]
    ) throws -> VM.ArrayStorage {
        let value = try read(register, registers: registers)
        guard case let .array(storage) = value else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .array(.never),
                actual: value.type
            )
        }
        _ = try storage.endIndex()
        return storage
    }

    private func dictionary(
        _ register: Bytecode.Register,
        registers: [VM.Value?]
    ) throws -> (
        entries: [VM.DictionaryEntry],
        keyType: Bytecode.ValueType,
        valueType: Bytecode.ValueType
    ) {
        let value = try read(register, registers: registers)
        guard case let .dictionary(entries, keyType, valueType) = value else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .dictionary(key: .never, value: .never),
                actual: value.type
            )
        }
        return (entries, keyType, valueType)
    }

    private func set(
        _ register: Bytecode.Register,
        registers: [VM.Value?]
    ) throws -> VM.SetValue {
        let value = try read(register, registers: registers)
        guard case let .set(set) = value else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .set(.never),
                actual: value.type
            )
        }
        return set
    }

    private func materializeManagedCollection(
        _ collection: VM.Value,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        let elements: [VM.Value]
        let elementType: Bytecode.ValueType
        switch collection {
        case let .array(storage):
            elements = storage.elements
            elementType = storage.elementType
        case let .set(source):
            elements = source.elements
            elementType = source.elementType
        case let .dictionary(entries, keyType, valueType):
            // Each output entry occupies one Array element slot plus one
            // two-field tuple (header and fields). The aggregate charge adds
            // the outer Array header once, so four slots per entry is exact.
            let aggregateCount = entries.count.multipliedReportingOverflow(
                by: 4
            )
            guard !aggregateCount.overflow else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            try chargeAggregate(
                elementCount: aggregateCount.partialValue,
                budget: budget
            )
            try budget.consumeLinearWork(elementCount: entries.count)
            for entry in entries {
                try prepareCopy(entry.key, budget: budget)
                try prepareCopy(entry.value, budget: budget)
            }
            var pairs: [VM.Value] = []
            pairs.reserveCapacity(entries.count)
            for entry in entries {
                pairs.append(
                    .tuple([
                        try copy(entry.key),
                        try copy(entry.value),
                    ])
                )
            }
            try budget.checkDeadline()
            return .array(
                pairs,
                elementType: .tuple([keyType, valueType])
            )
        default:
            throw VM.RuntimeTrap.typeMismatch(
                expected: .array(.never),
                actual: collection.type
            )
        }

        try budget.consumeLinearWork(elementCount: elements.count)
        try chargeAggregate(elementCount: elements.count, budget: budget)
        for element in elements {
            try prepareCopy(element, budget: budget)
        }
        let copied = try elements.map(copy)
        try budget.checkDeadline()
        return .array(copied, elementType: elementType)
    }

    private func normalizedSetValue(
        _ elements: [VM.Value],
        elementType: Bytecode.ValueType,
        budget: VM.InvocationBudget
    ) throws -> VM.SetValue {
        try budget.consumeLinearWork(elementCount: elements.count)
        try chargeAggregate(elementCount: elements.count, budget: budget)
        var unique: [VM.Value] = []
        unique.reserveCapacity(elements.count)
        for element in elements where try collectionIndex(
            of: element,
            in: unique,
            budget: budget
        ) == nil {
            unique.append(element)
        }
        return try copySetElements(
            unique,
            elementType: elementType,
            budget: budget
        )
    }

    private func copySetValue(
        _ set: VM.SetValue,
        budget: VM.InvocationBudget
    ) throws -> VM.SetValue {
        try chargeAggregate(elementCount: set.elements.count, budget: budget)
        for element in set.elements {
            try prepareCopy(element, budget: budget)
        }
        try budget.checkDeadline()
        return set
    }

    private func copySetElements<Elements: Collection>(
        _ elements: Elements,
        elementType: Bytecode.ValueType,
        budget: VM.InvocationBudget
    ) throws -> VM.SetValue where Elements.Element == VM.Value {
        try chargeAggregate(elementCount: elements.count, budget: budget)
        for element in elements {
            try prepareCopy(element, budget: budget)
        }
        let copied = try elements.map(copy)
        try budget.checkDeadline()
        return .init(uncheckedElements: copied, elementType: elementType)
    }

    private func copySetElements(
        _ elements: [VM.Value],
        excluding excludedIndex: Int?,
        elementType: Bytecode.ValueType,
        budget: VM.InvocationBudget
    ) throws -> VM.SetValue {
        let count = elements.count - (excludedIndex == nil ? 0 : 1)
        try chargeAggregate(elementCount: count, budget: budget)
        for (index, element) in elements.enumerated()
        where index != excludedIndex {
            try prepareCopy(element, budget: budget)
        }
        var copied: [VM.Value] = []
        copied.reserveCapacity(count)
        for (index, element) in elements.enumerated()
        where index != excludedIndex {
            copied.append(try copy(element))
        }
        try budget.checkDeadline()
        return .init(uncheckedElements: copied, elementType: elementType)
    }

    private func setIsSubset(
        _ subset: VM.SetValue,
        of superset: VM.SetValue,
        budget: VM.InvocationBudget
    ) throws -> Bool {
        try budget.consumeLinearWork(elementCount: subset.elements.count)
        for element in subset.elements where try collectionIndex(
            of: element,
            in: superset.elements,
            budget: budget
        ) == nil {
            return false
        }
        return true
    }

    private func setsAreDisjoint(
        _ lhs: VM.SetValue,
        _ rhs: VM.SetValue,
        budget: VM.InvocationBudget
    ) throws -> Bool {
        let smaller = lhs.elements.count <= rhs.elements.count ? lhs : rhs
        let larger = lhs.elements.count <= rhs.elements.count ? rhs : lhs
        try budget.consumeLinearWork(elementCount: smaller.elements.count)
        for element in smaller.elements where try collectionIndex(
            of: element,
            in: larger.elements,
            budget: budget
        ) != nil {
            return false
        }
        return true
    }

    private func dictionaryIndex(
        of needle: VM.Value,
        in entries: [VM.DictionaryEntry],
        budget: VM.InvocationBudget
    ) throws -> Int? {
        for (index, entry) in entries.enumerated() {
            if try vmValuesEqual(entry.key, needle, budget: budget) {
                return index
            }
        }
        return nil
    }

    private func collectionIndex(
        of needle: VM.Value,
        in values: [VM.Value],
        budget: VM.InvocationBudget
    ) throws -> Int? {
        for (index, value) in values.enumerated() {
            if try vmValuesEqual(value, needle, budget: budget) {
                return index
            }
        }
        return nil
    }

    private func adaptArray(
        _ elements: [VM.Value],
        elementType: Bytecode.ValueType,
        operation: Bytecode.ArrayAdapterOperation,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        try budget.consumeLinearWork(elementCount: elements.count)
        switch operation {
        case .reversed:
            try chargeAggregate(elementCount: elements.count, budget: budget)
            for element in elements {
                try prepareCopy(element, budget: budget)
            }
            let reversed = try elements.reversed().map(copy)
            try budget.checkDeadline()
            return .array(reversed, elementType: elementType)

        case .enumerated:
            let aggregateCount = elements.count.multipliedReportingOverflow(
                by: 3
            )
            guard !aggregateCount.overflow else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            try chargeAggregate(
                elementCount: aggregateCount.partialValue,
                budget: budget
            )
            for element in elements {
                try prepareCopy(element, budget: budget)
            }
            var result: [VM.Value] = []
            result.reserveCapacity(elements.count)
            for (offset, element) in elements.enumerated() {
                guard let exact = Int64(exactly: offset) else {
                    throw VM.RuntimeTrap.integerOverflow
                }
                result.append(
                    .tuple([
                        .integer(
                            try VM.Integer(
                                signed: exact,
                                bitWidth: 64,
                                isSigned: true
                            )
                        ),
                        try copy(element),
                    ])
                )
            }
            try budget.checkDeadline()
            return .array(
                result,
                elementType: .tuple([.int64, elementType])
            )
        }
    }

    private func repeatedArray(
        _ element: VM.Value,
        elementType: Bytecode.ValueType,
        count: Int64,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        guard count >= 0 else {
            throw VM.RuntimeTrap.explicit(
                "Array repeat count must not be negative"
            )
        }
        guard let count = Int(exactly: count) else {
            throw VM.RuntimeTrap.vmHeapLimitExceeded
        }
        try budget.consumeLinearWork(elementCount: count)
        try chargeAggregate(elementCount: count, budget: budget)
        for _ in 0..<count {
            try prepareCopy(element, budget: budget)
        }
        var result: [VM.Value] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try copy(element))
        }
        try budget.checkDeadline()
        return .array(result, elementType: elementType)
    }

    private func copiedArray(
        _ elements: [VM.Value],
        elementType: Bytecode.ValueType,
        bounds: Range<Int>,
        indexBase: Int64 = 0,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        guard bounds.lowerBound >= 0,
              bounds.upperBound <= elements.count
        else {
            throw VM.RuntimeTrap.invalidProgramCounter
        }
        _ = try VM.ArrayStorage.validatedEndIndex(
            elementCount: bounds.count,
            indexBase: indexBase
        )
        if bounds.lowerBound == 0, bounds.upperBound == elements.count {
            return try copyCharging(
                validatedArrayValue(
                    elements,
                    elementType: elementType,
                    indexBase: indexBase
                ),
                budget: budget
            )
        }
        try budget.consumeLinearWork(elementCount: bounds.count)
        try chargeAggregate(elementCount: bounds.count, budget: budget)
        for element in elements[bounds] {
            try prepareCopy(element, budget: budget)
        }
        let result = try elements[bounds].map(copy)
        try budget.checkDeadline()
        return try validatedArrayValue(
            result,
            elementType: elementType,
            indexBase: indexBase
        )
    }

    private func replacingArraySubrange(
        _ elements: [VM.Value],
        elementType: Bytecode.ValueType,
        bounds: Range<Int>,
        with replacement: [VM.Value],
        indexBase: Int64 = 0,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        guard bounds.lowerBound >= 0,
              bounds.upperBound <= elements.count
        else {
            throw VM.RuntimeTrap.invalidProgramCounter
        }
        let remainingCount = elements.count - bounds.count
        let newCount = remainingCount.addingReportingOverflow(
            replacement.count
        )
        guard !newCount.overflow else {
            throw VM.RuntimeTrap.vmHeapLimitExceeded
        }
        let outputCount = newCount.partialValue
        _ = try VM.ArrayStorage.validatedEndIndex(
            elementCount: outputCount,
            indexBase: indexBase
        )
        try budget.consumeLinearWork(elementCount: outputCount)
        try chargeAggregate(elementCount: outputCount, budget: budget)
        for element in elements[..<bounds.lowerBound] {
            try prepareCopy(element, budget: budget)
        }
        for element in replacement {
            try prepareCopy(element, budget: budget)
        }
        for element in elements[bounds.upperBound...] {
            try prepareCopy(element, budget: budget)
        }
        var result: [VM.Value] = []
        result.reserveCapacity(outputCount)
        for element in elements[..<bounds.lowerBound] {
            result.append(try copy(element))
        }
        for element in replacement {
            result.append(try copy(element))
        }
        for element in elements[bounds.upperBound...] {
            result.append(try copy(element))
        }
        try budget.checkDeadline()
        return try validatedArrayValue(
            result,
            elementType: elementType,
            indexBase: indexBase
        )
    }

    private func validatedArrayValue(
        _ elements: [VM.Value],
        elementType: Bytecode.ValueType,
        indexBase: Int64
    ) throws -> VM.Value {
        let storage = VM.ArrayStorage(
            elements: elements,
            elementType: elementType,
            indexBase: indexBase
        )
        _ = try storage.endIndex()
        return .array(storage)
    }

    private func makeArraySortState(
        _ elements: [VM.Value],
        elementType: Bytecode.ValueType,
        budget: VM.InvocationBudget
    ) throws -> VM.ArraySortState {
        let indexStorage = elements.count.multipliedReportingOverflow(by: 2)
        guard !indexStorage.overflow else {
            throw VM.RuntimeTrap.vmHeapLimitExceeded
        }
        try budget.consumeLinearWork(elementCount: elements.count)
        try chargeAggregate(elementCount: elements.count, budget: budget)
        try budget.consumeAggregateElementStorage(
            elementCount: indexStorage.partialValue
        )
        for element in elements {
            try prepareCopy(element, budget: budget)
        }
        let copied = try elements.map(copy)
        try budget.checkDeadline()
        return try .init(elementType: elementType, elements: copied)
    }

    private func makeArrayMutationState(
        _ storage: VM.ArrayStorage,
        budget: VM.InvocationBudget
    ) throws -> VM.ArrayMutationState {
        try budget.consumeLinearWork(elementCount: storage.elements.count)
        try chargeAggregate(
            elementCount: storage.elements.count,
            budget: budget
        )
        for element in storage.elements {
            try prepareCopy(element, budget: budget)
        }
        let copied = try storage.elements.map(copy)
        try budget.checkDeadline()
        return try .init(
            elementType: storage.elementType,
            elements: copied,
            indexBase: storage.indexBase
        )
    }

    private func makeArraySplitState(
        _ elements: [VM.Value],
        elementType: Bytecode.ValueType,
        indexBase: Int64,
        maximumSplits: Int,
        omitsEmptySubsequences: Bool,
        budget: VM.InvocationBudget
    ) throws -> VM.ArraySplitState {
        try budget.consumeLinearWork(elementCount: elements.count)
        try chargeAggregate(elementCount: elements.count, budget: budget)
        for element in elements {
            try prepareCopy(element, budget: budget)
        }
        let copied = try elements.map(copy)
        try budget.checkDeadline()
        return try .init(
            elementType: elementType,
            elements: copied,
            indexBase: indexBase,
            maximumSplits: maximumSplits,
            omitsEmptySubsequences: omitsEmptySubsequences
        )
    }

    private func finishArraySort(
        _ state: VM.ArraySortState,
        budget: VM.InvocationBudget
    ) throws -> [VM.Value] {
        let count = state.elementCount
        try budget.consumeLinearWork(elementCount: count)
        try chargeAggregate(elementCount: count, budget: budget)
        let result = try state.finish()
        try budget.checkDeadline()
        return result
    }

    private func swappingArrayElements(
        _ storage: VM.ArrayStorage,
        lhsIndex: Int64,
        rhsIndex: Int64,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        let elements = storage.elements
        let lhs = try storage.physicalOffset(for: lhsIndex)
        let rhs = try storage.physicalOffset(for: rhsIndex)
        try budget.consumeLinearWork(elementCount: elements.count)
        try chargeAggregate(elementCount: elements.count, budget: budget)
        for element in elements {
            try prepareCopy(element, budget: budget)
        }
        var result = try elements.map(copy)
        result.swapAt(lhs, rhs)
        try budget.checkDeadline()
        return .array(
            result,
            elementType: storage.elementType,
            indexBase: storage.indexBase
        )
    }

    private func zippedArray(
        _ lhs: [VM.Value],
        leftElement: Bytecode.ValueType,
        _ rhs: [VM.Value],
        rightElement: Bytecode.ValueType,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        let count = min(lhs.count, rhs.count)
        let aggregateCount = count.multipliedReportingOverflow(by: 3)
        guard !aggregateCount.overflow else {
            throw VM.RuntimeTrap.vmHeapLimitExceeded
        }
        try budget.consumeLinearWork(elementCount: count)
        try chargeAggregate(
            elementCount: aggregateCount.partialValue,
            budget: budget
        )
        for index in 0..<count {
            try prepareCopy(lhs[index], budget: budget)
            try prepareCopy(rhs[index], budget: budget)
        }
        var result: [VM.Value] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            result.append(
                .tuple([
                    try copy(lhs[index]),
                    try copy(rhs[index]),
                ])
            )
        }
        try budget.checkDeadline()
        return .array(
            result,
            elementType: .tuple([leftElement, rightElement])
        )
    }

    private func joinedArray(
        _ nested: [VM.Value],
        elementType: Bytecode.ValueType,
        separator: [VM.Value]?,
        budget: VM.InvocationBudget
    ) throws -> VM.Value {
        try budget.consumeLinearWork(elementCount: nested.count)
        var resultCount = 0
        for value in nested {
            guard case let .array(storage) = value,
                  storage.elementType == elementType
            else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .array(elementType),
                    actual: value.type
                )
            }
            let sum = resultCount.addingReportingOverflow(
                storage.elements.count
            )
            guard !sum.overflow else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            resultCount = sum.partialValue
        }
        if let separator, nested.count > 1 {
            let separatorCount = separator.count.multipliedReportingOverflow(
                by: nested.count - 1
            )
            let total = resultCount.addingReportingOverflow(
                separatorCount.partialValue
            )
            guard !separatorCount.overflow, !total.overflow else {
                throw VM.RuntimeTrap.vmHeapLimitExceeded
            }
            resultCount = total.partialValue
        }
        try budget.consumeLinearWork(elementCount: resultCount)
        try chargeAggregate(elementCount: resultCount, budget: budget)
        for (index, value) in nested.enumerated() {
            if index > 0, let separator {
                for element in separator {
                    try prepareCopy(element, budget: budget)
                }
            }
            guard case let .array(storage) = value else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            for element in storage.elements {
                try prepareCopy(element, budget: budget)
            }
        }

        var result: [VM.Value] = []
        result.reserveCapacity(resultCount)
        for (index, value) in nested.enumerated() {
            if index > 0, let separator {
                for element in separator {
                    result.append(try copy(element))
                }
            }
            guard case let .array(storage) = value else {
                throw VM.RuntimeTrap.invalidProgramCounter
            }
            for element in storage.elements {
                result.append(try copy(element))
            }
        }
        try budget.checkDeadline()
        return .array(result, elementType: elementType)
    }

    private func chargeDictionaryStorage(
        entryCount: Int,
        budget: VM.InvocationBudget
    ) throws {
        let elementCount = entryCount.multipliedReportingOverflow(by: 2)
        guard !elementCount.overflow else { throw VM.RuntimeTrap.vmHeapLimitExceeded }
        try chargeAggregate(elementCount: elementCount.partialValue, budget: budget)
    }

    private func calculateSigned(
        _ operation: Bytecode.BinaryOperation,
        lhs: VM.Integer,
        rhs: VM.Integer
    ) throws -> (VM.Integer, Bool) {
        let left = lhs.signedValue
        let right = rhs.signedValue
        let raw: Int64
        let machineOverflow: Bool
        switch operation {
        case .add: (raw, machineOverflow) = left.addingReportingOverflow(right)
        case .subtract: (raw, machineOverflow) = left.subtractingReportingOverflow(right)
        case .multiply: (raw, machineOverflow) = left.multipliedReportingOverflow(by: right)
        case .divide:
            guard right != 0 else { return (lhs, true) }
            if left == VM.Integer.signedBounds(bitWidth: lhs.bitWidth).min, right == -1 {
                return (
                    try VM.Integer(
                        rawBits: UInt64(bitPattern: left),
                        bitWidth: lhs.bitWidth,
                        isSigned: true
                    ),
                    true
                )
            }
            raw = left / right
            machineOverflow = false
        case .remainder:
            guard right != 0 else { return (lhs, true) }
            if left == VM.Integer.signedBounds(bitWidth: lhs.bitWidth).min, right == -1 {
                return (
                    try VM.Integer(rawBits: 0, bitWidth: lhs.bitWidth, isSigned: true),
                    true
                )
            }
            raw = left % right
            machineOverflow = false
        case .bitAnd: raw = Int64(bitPattern: lhs.rawBits & rhs.rawBits); machineOverflow = false
        case .bitOr: raw = Int64(bitPattern: lhs.rawBits | rhs.rawBits); machineOverflow = false
        case .bitXor: raw = Int64(bitPattern: lhs.rawBits ^ rhs.rawBits); machineOverflow = false
        case .shiftLeft:
            return try shift(lhs, signedAmount: right, direction: .left)
        case .shiftRight:
            return try shift(lhs, signedAmount: right, direction: .right)
        }
        let bounds = VM.Integer.signedBounds(bitWidth: lhs.bitWidth)
        let widthOverflow = raw < bounds.min || raw > bounds.max
        return (
            try VM.Integer(rawBits: UInt64(bitPattern: raw), bitWidth: lhs.bitWidth, isSigned: true),
            machineOverflow || widthOverflow
        )
    }

    private func calculateUnsigned(
        _ operation: Bytecode.BinaryOperation,
        lhs: VM.Integer,
        rhs: VM.Integer
    ) throws -> (VM.Integer, Bool) {
        let left = lhs.unsignedValue
        let right = rhs.unsignedValue
        let raw: UInt64
        let machineOverflow: Bool
        switch operation {
        case .add: (raw, machineOverflow) = left.addingReportingOverflow(right)
        case .subtract: (raw, machineOverflow) = left.subtractingReportingOverflow(right)
        case .multiply: (raw, machineOverflow) = left.multipliedReportingOverflow(by: right)
        case .divide:
            guard right != 0 else { return (lhs, true) }
            raw = left / right; machineOverflow = false
        case .remainder:
            guard right != 0 else { return (lhs, true) }
            raw = left % right; machineOverflow = false
        case .bitAnd: raw = left & right; machineOverflow = false
        case .bitOr: raw = left | right; machineOverflow = false
        case .bitXor: raw = left ^ right; machineOverflow = false
        case .shiftLeft:
            return try shift(lhs, unsignedAmount: right, direction: .left)
        case .shiftRight:
            return try shift(lhs, unsignedAmount: right, direction: .right)
        }
        let mask = VM.Integer.mask(for: lhs.bitWidth)
        return (
            try VM.Integer(rawBits: raw, bitWidth: lhs.bitWidth, isSigned: false),
            machineOverflow || raw > mask
        )
    }

    private enum ShiftDirection: Equatable { case left, right }

    private func shift(
        _ value: VM.Integer,
        signedAmount: Int64,
        direction: ShiftDirection
    ) throws -> (VM.Integer, Bool) {
        let effectiveDirection: ShiftDirection = signedAmount < 0
            ? (direction == .left ? .right : .left)
            : direction
        return try shift(
            value,
            magnitude: signedAmount.magnitude,
            direction: effectiveDirection
        )
    }

    private func shift(
        _ value: VM.Integer,
        unsignedAmount: UInt64,
        direction: ShiftDirection
    ) throws -> (VM.Integer, Bool) {
        try shift(value, magnitude: unsignedAmount, direction: direction)
    }

    private func shift(
        _ value: VM.Integer,
        magnitude: UInt64,
        direction: ShiftDirection
    ) throws -> (VM.Integer, Bool) {
        let bits: UInt64
        switch direction {
        case .left:
            bits = magnitude >= value.bitWidth ? 0 : value.rawBits << magnitude
        case .right where value.isSigned:
            if magnitude >= value.bitWidth {
                bits = value.signedValue < 0 ? VM.Integer.mask(for: value.bitWidth) : 0
            } else {
                bits = UInt64(bitPattern: value.signedValue >> magnitude)
            }
        case .right:
            bits = magnitude >= value.bitWidth ? 0 : value.rawBits >> magnitude
        }
        return (
            try VM.Integer(rawBits: bits, bitWidth: value.bitWidth, isSigned: value.isSigned),
            false
        )
    }

    private func compare(
        _ predicate: Bytecode.ComparisonPredicate,
        lhs: VM.Value,
        rhs: VM.Value,
        type: Bytecode.ValueType,
        budget: VM.InvocationBudget
    ) throws -> Bool {
        let lhsMatches = lhs.hasRuntimeType(type)
        guard lhsMatches, rhs.hasRuntimeType(type) else {
            let actual = lhsMatches ? rhs.type : lhs.type
            throw VM.RuntimeTrap.typeMismatch(expected: type, actual: actual)
        }
        switch predicate {
        case .equal, .notEqual:
            guard type.isVMEquatable else {
                throw VM.RuntimeTrap.nativeFailure(
                    "equality is unsupported for \(type)"
                )
            }
            let equal = try vmValuesEqual(
                lhs,
                rhs,
                budget: budget
            )
            return predicate == .equal ? equal : !equal
        case .lessThan, .lessThanOrEqual,
             .greaterThan, .greaterThanOrEqual:
            guard type.isVMComparable else {
                throw VM.RuntimeTrap.nativeFailure(
                    "ordering is unsupported for \(type)"
                )
            }
        }
        try chargeComparisonWork(lhs: lhs, rhs: rhs, budget: budget)
        if case let (.float(rawLeft), .float(rawRight)) = (lhs, rhs) {
            // Preserve Swift/IEEE-754 unordered semantics. Mapping NaN to a total
            // ComparisonResult would incorrectly make it greater than every value.
            if rawLeft.bitWidth == 32 {
                return compareFloating(
                    predicate,
                    lhs: rawLeft.floatValue,
                    rhs: rawRight.floatValue
                )
            }
            return compareFloating(
                predicate,
                lhs: rawLeft.doubleValue,
                rhs: rawRight.doubleValue
            )
        }
        if case let (.string(left), .string(right)) = (lhs, rhs) {
            // Swift String ordering is lexicographical over extended grapheme
            // clusters. Foundation's locale-sensitive compare is not equivalent.
            return switch predicate {
            case .equal, .notEqual:
                throw VM.RuntimeTrap.nativeFailure(
                    "equality reached the ordered comparison path"
                )
            case .lessThan: left < right
            case .lessThanOrEqual: left <= right
            case .greaterThan: left > right
            case .greaterThanOrEqual: left >= right
            }
        }
        let ordering: ComparisonResult
        switch (lhs, rhs) {
        case let (.integer(left), .integer(right)):
            if left.isSigned {
                ordering = left.signedValue == right.signedValue ? .orderedSame : (left.signedValue < right.signedValue ? .orderedAscending : .orderedDescending)
            } else {
                ordering = left.unsignedValue == right.unsignedValue ? .orderedSame : (left.unsignedValue < right.unsignedValue ? .orderedAscending : .orderedDescending)
            }
        default:
            throw VM.RuntimeTrap.nativeFailure("comparison is unsupported for \(lhs.type)")
        }
        return switch predicate {
        case .equal, .notEqual:
            throw VM.RuntimeTrap.nativeFailure(
                "equality reached the ordered comparison path"
            )
        case .lessThan: ordering == .orderedAscending
        case .lessThanOrEqual: ordering != .orderedDescending
        case .greaterThan: ordering == .orderedDescending
        case .greaterThanOrEqual: ordering != .orderedAscending
        }
    }

    private func compareFloating<Value: BinaryFloatingPoint>(
        _ predicate: Bytecode.ComparisonPredicate,
        lhs: Value,
        rhs: Value
    ) -> Bool {
        switch predicate {
        case .equal: lhs == rhs
        case .notEqual: lhs != rhs
        case .lessThan: lhs < rhs
        case .lessThanOrEqual: lhs <= rhs
        case .greaterThan: lhs > rhs
        case .greaterThanOrEqual: lhs >= rhs
        }
    }

    private func invokeNative(
        _ invoker: any VM.NativeInvoker,
        id: Core.NativeImportID,
        arguments: [VM.Value],
        budget: VM.InvocationBudget
    ) throws -> VM.NativeInvocationResult {
        let context = try budget.beginNativeInvocation(
            id: id,
            effects: invoker.effects,
            contract: invoker.contract,
            parameterTypes: invoker.parameterTypes,
            callbackHost: nativeCallbackHost
        )
        let result: VM.NativeInvocationResult
        do {
            result = try invoker.invoke(arguments: arguments, context: context)
        } catch {
            do {
                try context.finish(requireCooperation: false)
            } catch {
                throw error
            }
            if let trap = error as? VM.RuntimeTrap { throw trap }
            throw VM.RuntimeTrap.nativeFailure(
                "native import \(id) threw an undeclared runtime error: \(error)"
            )
        }
        try context.finish(requireCooperation: true)
        return result
    }

    private func nativeParameterConventions(
        _ invoker: any VM.NativeInvoker
    ) -> [Bytecode.ParameterConvention] {
        let nonescaping = Set(invoker.contract.callbacks.compactMap { callback in
            callback.lifetime == .nonescaping
                ? Int(callback.parameterIndex) : nil
        })
        return invoker.parameterTypes.indices.map {
            nonescaping.contains($0) ? .borrowed : .owned
        }
    }

    private func runtimeTrap(for reason: Bytecode.TrapReason) -> VM.RuntimeTrap {
        switch reason {
        case .integerOverflow: .integerOverflow
        case .divisionByZero: .divisionByZero
        case .optionalUnwrapOfNil: .optionalUnwrapOfNil
        case .quotaExceeded: .instructionFuelExhausted
        case let .explicit(message): .explicit(message)
        }
    }
}

private struct BusinessError: Error {
    enum Payload {
        case value(VM.Value)
        case boundaryMessage(String)
    }

    var payload: Payload
    var requiresBoundaryCharge: Bool

    var message: String {
        switch payload {
        case let .boundaryMessage(message), let .value(.string(message)):
            message
        case let .value(.error(error)):
            error.message
        case let .value(value):
            value.description
        }
    }

    init(message: String, requiresBoundaryCharge: Bool) {
        payload = .boundaryMessage(message)
        self.requiresBoundaryCharge = requiresBoundaryCharge
    }

    init(value: VM.Value, requiresBoundaryCharge: Bool) {
        payload = .value(value)
        self.requiresBoundaryCharge = requiresBoundaryCharge
    }
}
}
