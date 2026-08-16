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
    public var trapObserver: VM.TrapObserver?

    public init(
        nativeCatalog: VM.NativeCatalog = .init(),
        nativeTypeCatalog: VM.NativeTypeCatalog = .init(),
        entryInvocation: VM.EntryInvocation? = nil,
        objectHost: VM.ObjectHost? = nil,
        trapObserver: VM.TrapObserver? = nil
    ) {
        self.nativeCatalog = nativeCatalog
        self.nativeTypeCatalog = nativeTypeCatalog
        self.entryInvocation = entryInvocation
        self.objectHost = objectHost
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
                      case .address, .mutableCell, .arrayBuilder: true
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
            return .businessError(business.error.message)
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
                 let .mutableCell(wrapped), let .arrayBuilder(wrapped):
                visit(wrapped)
            case let .array(element), let .set(element):
                visit(element)
            case let .dictionary(key, value):
                visit(key)
                visit(value)
            case let .closure(signature):
                (signature.parameters + [signature.result]).forEach(visit)
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
                        registers: &registers
                    )
                    try initialize(value, register: result, registers: &registers)
                case let .destroyValue(register):
                    if function.type(of: register)?.requiresLinearOwnership == true {
                        _ = try take(register, registers: &registers)
                    }
                case let .makeTuple(result, elements):
                    try budget.consumeLinearWork(elementCount: elements.count)
                    try chargeAggregate(elementCount: elements.count, budget: budget)
                    let values = try elements.map {
                        try consume(
                            $0,
                            type: function.type(of: $0)!,
                            registers: &registers
                        )
                    }
                    try initialize(.tuple(values), register: result, registers: &registers)
                case let .unpackTuple(results, tuple):
                    try budget.consumeLinearWork(elementCount: results.count)
                    let tupleValue = try consume(
                        tuple,
                        type: function.type(of: tuple)!,
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
                    let value = try read(enumeration, registers: registers)
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
                    let value = try read(payload, registers: registers)
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
                    try initialize(
                        .error(.init(concreteType: key, payload: value, message: message)),
                        register: result,
                        registers: &registers
                    )
                case let .castError(result, error, expectedType):
                    let value = try read(error, registers: registers)
                    guard case let .error(errorValue) = value else {
                        throw VM.RuntimeTrap.typeMismatch(expected: .error, actual: value.type)
                    }
                    let projected = errorValue.concreteType == expectedType
                        ? errorValue.payload
                        : nil
                    try chargeAggregate(elementCount: projected == nil ? 0 : 1, budget: budget)
                    try initialize(.optional(projected), register: result, registers: &registers)
                case let .eraseToAny(result, source):
                    let sourceType = function.type(of: source)!
                    let value = try read(source, registers: registers)
                    let erased: VM.Value
                    if sourceType == .any {
                        guard case .any = value else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .any,
                                actual: value.type
                            )
                        }
                        erased = value
                    } else {
                        guard sourceType.isAnyPayloadV1 else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .any,
                                actual: sourceType
                            )
                        }
                        try chargeAggregate(elementCount: 1, budget: budget)
                        erased = .any(
                            .init(concreteType: sourceType, payload: value)
                        )
                    }
                    try initialize(erased, register: result, registers: &registers)
                case let .checkedCastAny(result, source):
                    let value = try read(source, registers: registers)
                    guard case let .any(erased) = value,
                          case let .optional(targetType) = function.type(of: result)
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .any,
                            actual: value.type
                        )
                    }
                    let converted = try VM.DynamicCaster(budget: budget).cast(
                        erased.payload,
                        from: erased.concreteType,
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
                case let .forceCastAny(result, source):
                    let value = try read(source, registers: registers)
                    guard case let .any(erased) = value else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .any,
                            actual: value.type
                        )
                    }
                    let targetType = function.type(of: result)!
                    guard let converted = try VM.DynamicCaster(budget: budget).cast(
                        erased.payload,
                        from: erased.concreteType,
                        to: targetType
                    ) else {
                        throw VM.RuntimeTrap.dynamicCastFailure(
                            actual: erased.concreteType,
                            expected: targetType
                        )
                    }
                    try initialize(converted, register: result, registers: &registers)
                case let .makeOptionalSome(result, value):
                    try chargeAggregate(elementCount: 1, budget: budget)
                    let payload = try consume(
                        value,
                        type: function.type(of: value)!,
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
                        registers: &registers
                    )
                    try cell.store(value, mode: mode)
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
                case let .loadAddress(result, register, _):
                    guard case let .address(address) = try read(register, registers: registers) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: function.type(of: register)!,
                            actual: try read(register, registers: registers).type
                        )
                    }
                    try initialize(
                        copyCharging(try address.read(), budget: budget),
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
                        registers: &registers
                    )
                    try address.store(value, mode: mode)
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
                case let .arrayGet(result, array, index):
                    let (values, _) = try self.array(array, registers: registers)
                    let integer = try integer(index, registers: registers)
                    let offset = integer.signedValue
                    guard offset >= 0,
                          let exact = Int(exactly: offset),
                          values.indices.contains(exact)
                    else {
                        throw VM.RuntimeTrap.arrayIndexOutOfBounds(
                            index: offset,
                            count: values.count
                        )
                    }
                    let value = try copyCharging(values[exact], budget: budget)
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
                case let .arrayContains(result, array, value):
                    let (values, _) = try self.array(array, registers: registers)
                    let needle = try read(value, registers: registers)
                    var contains = false
                    for element in values {
                        if try vmValuesEqual(
                            element,
                            needle,
                            budget: budget
                        ) {
                            contains = true
                            break
                        }
                    }
                    try initialize(
                        .bool(contains),
                        register: result,
                        registers: &registers
                    )
                case let .arraySearch(result, operation, array, value):
                    let (values, _) = try self.array(
                        array,
                        registers: registers
                    )
                    let needle = try read(value, registers: registers)
                    let index = try VM.CollectionSemantics.searchIndex(
                        in: values,
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
                        guard let exact = Int64(exactly: index) else {
                            throw VM.RuntimeTrap.integerOverflow
                        }
                        wrapped = .integer(
                            try VM.Integer(
                                signed: exact,
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
                case let .arrayExtremum(result, operation, array):
                    let (values, _) = try self.array(
                        array,
                        registers: registers
                    )
                    let selected = try VM.CollectionSemantics.extremum(
                        in: values,
                        operation: operation
                    ) { left, right in
                        try compare(
                            .lessThan,
                            lhs: left,
                            rhs: right,
                            budget: budget
                        )
                    }
                    try chargeAggregate(
                        elementCount: selected == nil ? 0 : 1,
                        budget: budget
                    )
                    let wrapped = try selected.map {
                        try copyCharging($0, budget: budget)
                    }
                    try initialize(
                        .optional(wrapped),
                        register: result,
                        registers: &registers
                    )
                case let .arrayRelation(result, operation, lhs, rhs):
                    let (left, leftElement) = try self.array(
                        lhs,
                        registers: registers
                    )
                    let (right, rightElement) = try self.array(
                        rhs,
                        registers: registers
                    )
                    guard leftElement == rightElement else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(leftElement),
                            actual: .array(rightElement)
                        )
                    }
                    let relation = try VM.CollectionSemantics.relation(
                        operation,
                        lhs: left,
                        rhs: right,
                        areEqual: { left, right in
                            try vmValuesEqual(
                                left,
                                right,
                                budget: budget
                            )
                        },
                        isOrderedBefore: { left, right in
                            try compare(
                                .lessThan,
                                lhs: left,
                                rhs: right,
                                budget: budget
                            )
                        }
                    )
                    try initialize(
                        .bool(relation),
                        register: result,
                        registers: &registers
                    )
                case let .arrayAppend(result, array, value):
                    let (elements, elementType) = try self.array(
                        array,
                        registers: registers
                    )
                    let newCount = elements.count.addingReportingOverflow(1)
                    guard !newCount.overflow else {
                        throw VM.RuntimeTrap.vmHeapLimitExceeded
                    }
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
                    try initialize(
                        .array(appended, elementType: elementType),
                        register: result,
                        registers: &registers
                    )
                case let .makeArrayBuilder(result):
                    guard case let .arrayBuilder(element) = function.type(
                        of: result
                    ) else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .arrayBuilder(.never),
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
                case let .finishArrayBuilder(result, builderRegister):
                    guard case let .arrayBuilder(element) = function.type(
                        of: builderRegister
                    ), function.type(of: result) == .array(element),
                       case let .arrayBuilder(builder) = try consume(
                        builderRegister,
                        type: .arrayBuilder(element),
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
                case let .arrayUpdate(result, array, index, value):
                    let (elements, elementType) = try self.array(
                        array,
                        registers: registers
                    )
                    let offset = try integer(index, registers: registers).signedValue
                    guard offset >= 0,
                          let exact = Int(exactly: offset),
                          elements.indices.contains(exact)
                    else {
                        throw VM.RuntimeTrap.arrayIndexOutOfBounds(
                            index: offset,
                            count: elements.count
                        )
                    }
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
                        .array(updated, elementType: elementType),
                        register: result,
                        registers: &registers
                    )
                case let .arrayPopLast(elementResult, arrayResult, array):
                    let (elements, elementType) = try self.array(
                        array,
                        registers: registers
                    )
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
                        .array(remaining, elementType: elementType),
                        register: arrayResult,
                        registers: &registers
                    )
                case let .arrayNext(result, array, indexSlot):
                    let (elements, _) = try self.array(array, registers: registers)
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
                    guard index >= 0, let exactIndex = Int(exactly: index) else {
                        throw VM.RuntimeTrap.arrayIndexOutOfBounds(
                            index: index,
                            count: elements.count
                        )
                    }
                    let next: VM.Value?
                    if elements.indices.contains(exactIndex) {
                        try chargeAggregate(elementCount: 1, budget: budget)
                        let copied = try copyCharging(
                            elements[exactIndex],
                            budget: budget
                        )
                        next = copied
                        let advanced = index.addingReportingOverflow(1)
                        guard !advanced.overflow else {
                            throw VM.RuntimeTrap.integerOverflow
                        }
                        try store(
                            .integer(
                                VM.Integer(
                                    signed: advanced.partialValue,
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
                          case let .array(pairValues, pairType) = try read(
                              pairs,
                              registers: registers
                          ),
                          pairType == .tuple([keyType, valueType])
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .array(.never),
                            actual: function.type(of: pairs)
                        )
                    }
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
                                "Dictionary literal contains duplicate keys"
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
                case let .dictionaryUpdate(result, operand, key, value):
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
                    try budget.consumeLinearWork(elementCount: finalCount)
                    try chargeDictionaryStorage(entryCount: finalCount, budget: budget)
                    for (index, entry) in source.enumerated() {
                        if index == matchingIndex, wrapped == nil { continue }
                        let selectedValue: VM.Value
                        if index == matchingIndex, let wrapped {
                            selectedValue = wrapped
                        } else {
                            selectedValue = entry.value
                        }
                        try prepareCopy(entry.key, budget: budget)
                        try prepareCopy(selectedValue, budget: budget)
                    }
                    if matchingIndex == nil, let wrapped {
                        try prepareCopy(needle, budget: budget)
                        try prepareCopy(wrapped, budget: budget)
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
                        .dictionary(entries, keyType: keyType, valueType: valueType),
                        register: result,
                        registers: &registers
                    )
                case let .dictionaryRemove(
                    valueResult,
                    dictionaryResult,
                    operand,
                    key
                ):
                    let (source, keyType, valueType) = try dictionary(
                        operand,
                        registers: registers
                    )
                    let needle = try read(key, registers: registers)
                    let matchingIndex = try dictionaryIndex(
                        of: needle,
                        in: source,
                        budget: budget
                    )
                    let finalCount = source.count - (matchingIndex == nil ? 0 : 1)
                    try budget.consumeLinearWork(elementCount: source.count)
                    try chargeDictionaryStorage(entryCount: finalCount, budget: budget)
                    try chargeAggregate(
                        elementCount: matchingIndex == nil ? 0 : 1,
                        budget: budget
                    )
                    for (index, entry) in source.enumerated() {
                        if index == matchingIndex {
                            try prepareCopy(entry.value, budget: budget)
                        } else {
                            try prepareCopy(entry.key, budget: budget)
                            try prepareCopy(entry.value, budget: budget)
                        }
                    }
                    let removed = try matchingIndex.map { try copy(source[$0].value) }
                    var entries: [VM.DictionaryEntry] = []
                    entries.reserveCapacity(finalCount)
                    for (index, entry) in source.enumerated() where index != matchingIndex {
                        entries.append(
                            .init(
                                key: try copy(entry.key),
                                value: try copy(entry.value)
                            )
                        )
                    }
                    try budget.checkDeadline()
                    try initialize(
                        .optional(removed),
                        register: valueResult,
                        registers: &registers
                    )
                    try initialize(
                        .dictionary(entries, keyType: keyType, valueType: valueType),
                        register: dictionaryResult,
                        registers: &registers
                    )
                case let .dictionaryNext(result, operand, indexSlot):
                    let (entries, _, _) = try dictionary(operand, registers: registers)
                    let indexValue = try read(indexSlot, stackSlots: stackSlots)
                    guard case let .integer(integer) = indexValue,
                          integer.bitWidth == 64,
                          integer.isSigned,
                          integer.signedValue >= 0,
                          let index = Int(exactly: integer.signedValue)
                    else {
                        throw VM.RuntimeTrap.invalidProgramCounter
                    }
                    let next: VM.Value?
                    if entries.indices.contains(index) {
                        try chargeAggregate(elementCount: 2, budget: budget)
                        try chargeAggregate(elementCount: 1, budget: budget)
                        let key = try copyCharging(
                            entries[index].key,
                            budget: budget
                        )
                        let value = try copyCharging(
                            entries[index].value,
                            budget: budget
                        )
                        next = .tuple([key, value])
                        let advanced = integer.signedValue.addingReportingOverflow(1)
                        guard !advanced.overflow else {
                            throw VM.RuntimeTrap.integerOverflow
                        }
                        try store(
                            .integer(
                                VM.Integer(
                                    signed: advanced.partialValue,
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
                    try initialize(.optional(next), register: result, registers: &registers)
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
                    case let .array(elements, actualType) where actualType == elementType:
                        set = try normalizedSetValue(
                            elements,
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
                case let .setNext(result, operand, indexSlot):
                    let value = try set(operand, registers: registers)
                    let indexValue = try read(indexSlot, stackSlots: stackSlots)
                    guard case let .integer(integer) = indexValue,
                          integer.bitWidth == 64,
                          integer.isSigned,
                          integer.signedValue >= 0,
                          let index = Int(exactly: integer.signedValue)
                    else {
                        throw VM.RuntimeTrap.invalidProgramCounter
                    }
                    let next: VM.Value?
                    if value.elements.indices.contains(index) {
                        try chargeAggregate(elementCount: 1, budget: budget)
                        next = try copyCharging(value.elements[index], budget: budget)
                        let advanced = integer.signedValue.addingReportingOverflow(1)
                        guard !advanced.overflow else {
                            throw VM.RuntimeTrap.integerOverflow
                        }
                        try store(
                            .integer(
                                VM.Integer(
                                    signed: advanced.partialValue,
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
                    try initialize(.optional(next), register: result, registers: &registers)
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
                        budget: budget
                    )
                    try initialize(.bool(comparison), register: result, registers: &registers)
                case let .branch(target, arguments):
                    try transfer(
                        arguments,
                        to: frame.blocks[target]!,
                        function: function,
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
                          zip(values, invoker.parameterTypes).allSatisfy({ $0.matches($1) })
                    else {
                        throw VM.RuntimeTrap.nativeFailure("runtime argument check failed for import \(importID)")
                    }
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: Array(repeating: .owned, count: arguments.count),
                        function: function,
                        registers: &registers
                    )
                    switch try invokeNative(
                        invoker,
                        id: importID,
                        arguments: values,
                        budget: budget
                    ) {
                    case let .returned(value):
                        if let value { try budget.consumeBoundaryValue(value) }
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
                case let .makeClosure(result, callee, captures):
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
                                functionID: callee,
                                signature: signature,
                                captures: capturedValues
                            )
                        ),
                        register: result,
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
                    guard let calleeFunction = functions[closure.functionID],
                          calleeFunction.parameterConventions.count >= arguments.count
                    else {
                        throw VM.RuntimeTrap.unknownFunction(closure.functionID)
                    }
                    let values = try arguments.map { try read($0, registers: registers) }
                    let callValues = values + closure.captures
                    try chargeCallShape(callValues, budget: budget)
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: Array(
                            calleeFunction.parameterConventions.prefix(arguments.count)
                        ),
                        function: function,
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
                            functionID: closure.functionID,
                            arguments: callValues,
                            continuation: .returning(
                                result: result,
                                programCounter: programCounter
                            )
                        )
                    )
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
                    guard let calleeFunction = functions[closure.functionID],
                          calleeFunction.parameterConventions.count
                            >= arguments.count
                    else {
                        throw VM.RuntimeTrap.unknownFunction(closure.functionID)
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
                            functionID: closure.functionID,
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
                          zip(values, invoker.parameterTypes).allSatisfy({ $0.matches($1) })
                    else {
                        throw VM.RuntimeTrap.nativeFailure(
                            "runtime argument check failed for import \(importID)"
                        )
                    }
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: Array(repeating: .owned, count: arguments.count),
                        function: function,
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
                        registers: &registers
                    )
                    switch value {
                    case let .string(message):
                        throw VM.BusinessError(
                            message: message,
                            requiresBoundaryCharge: false
                        )
                    case let .error(error):
                        throw VM.BusinessError(
                            error: error,
                            requiresBoundaryCharge: false
                        )
                    default:
                        throw VM.RuntimeTrap.typeMismatch(expected: .error, actual: value.type)
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
        registers: inout [VM.Value?]
    ) throws {
        for (argument, convention) in zip(arguments, conventions)
        where convention == .owned
            && function.type(of: argument)?.requiresLinearOwnership == true {
            _ = try take(argument, registers: &registers)
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
            guard erased.concreteType.isAnyPayloadV1 else {
                throw VM.RuntimeTrap.typeMismatch(expected: .any, actual: .any)
            }
            try validateRuntimeValue(
                erased.payload,
                expected: erased.concreteType,
                localTypes: localTypes,
                budget: budget,
                depth: depth + 1
            )
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
        case let (.arrayBuilder(builder), .arrayBuilder(element)):
            guard builder.elementType == element else {
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
        case let (.array(values, actualElement), .array(expectedElement)):
            guard actualElement == expectedElement else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
            for element in values {
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
            if let budget {
                // Duplicate detection uses a transient key index. Charge it even
                // though it is released after boundary validation.
                try budget.consumeAggregateStorage(elementCount: entries.count)
            }
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
        case let (.set(set), .set(expectedElement)):
            guard expectedElement.isVMHashable,
                  set.elementType == expectedElement
            else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
            if let budget {
                try budget.consumeAggregateStorage(
                    elementCount: set.elements.count
                )
            }
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
        registers: inout [VM.Value?]
    ) throws -> VM.Value {
        if !type.requiresLinearOwnership { return try read(register, registers: registers) }
        return try take(register, registers: &registers)
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
                    concreteType: erased.concreteType,
                    payload: try copy(erased.payload)
                )
            )
        case let .tuple(elements):
            .tuple(try elements.map(copy))
        case let .array(elements, elementType):
            .array(try elements.map(copy), elementType: elementType)
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
                    functionID: closure.functionID,
                    signature: closure.signature,
                    captures: try closure.captures.map(copy)
                )
            )
        case .mutableCell:
            value
        case .arrayBuilder:
            throw VM.RuntimeTrap.explicit("Array builders cannot be copied")
        case .address:
            throw VM.RuntimeTrap.inactiveAddressAccess
        case .bool, .integer, .float, .string:
            value
        }
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
        case let .array(elements, _):
            try budget.consumeAggregateStorage(elementCount: elements.count)
            for element in elements {
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
             .arrayBuilder:
            break
        }
    }

    private func chargeValueTraversal(
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
        case let .string(string):
            try budget.consumeUTF8Work(byteCount: string.utf8.count)
        case let .any(erased):
            try chargeValueTraversal(
                erased.payload,
                budget: budget,
                depth: depth + 1
            )
        case let .tuple(elements), let .array(elements, _):
            for element in elements {
                try chargeValueTraversal(element, budget: budget, depth: depth + 1)
            }
        case let .dictionary(entries, _, _):
            for entry in entries {
                try chargeValueTraversal(entry.key, budget: budget, depth: depth + 1)
                try chargeValueTraversal(entry.value, budget: budget, depth: depth + 1)
            }
        case let .set(set):
            for element in set.elements {
                try chargeValueTraversal(element, budget: budget, depth: depth + 1)
            }
        case let .optional(.some(wrapped)):
            try chargeValueTraversal(wrapped, budget: budget, depth: depth + 1)
        case let .structure(_, fields):
            for field in fields {
                try chargeValueTraversal(field, budget: budget, depth: depth + 1)
            }
        case let .enumeration(_, _, payload):
            if let payload {
                try chargeValueTraversal(payload, budget: budget, depth: depth + 1)
            }
        case .object:
            break
        case let .error(error):
            try budget.consumeUTF8Work(byteCount: error.message.utf8.count)
            if let payload = error.payload {
                try chargeValueTraversal(payload, budget: budget, depth: depth + 1)
            }
        case let .closure(closure):
            for capture in closure.captures {
                try chargeValueTraversal(capture, budget: budget, depth: depth + 1)
            }
        case .optional(nil), .native, .bool, .integer, .float, .address,
             .mutableCell, .arrayBuilder:
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
        guard depth <= VM.ValueLimits.maximumNestingDepth else {
            throw VM.RuntimeTrap.valueNestingDepthExceeded(
                maximum: VM.ValueLimits.maximumNestingDepth
            )
        }
        try budget.consumeWork(units: 1)
        switch value {
        case let .any(erased):
            try chargeShapeValidation(
                erased.payload,
                budget: budget,
                depth: depth + 1
            )
        case let .tuple(elements), let .array(elements, _):
            for element in elements {
                try chargeShapeValidation(element, budget: budget, depth: depth + 1)
            }
        case let .dictionary(entries, _, _):
            for entry in entries {
                try chargeShapeValidation(entry.key, budget: budget, depth: depth + 1)
                try chargeShapeValidation(entry.value, budget: budget, depth: depth + 1)
            }
        case let .set(set):
            for element in set.elements {
                try chargeShapeValidation(element, budget: budget, depth: depth + 1)
            }
        case let .optional(.some(wrapped)):
            try chargeShapeValidation(wrapped, budget: budget, depth: depth + 1)
        case let .structure(_, fields):
            for field in fields {
                try chargeShapeValidation(field, budget: budget, depth: depth + 1)
            }
        case let .enumeration(_, _, payload):
            if let payload {
                try chargeShapeValidation(payload, budget: budget, depth: depth + 1)
            }
        case .object:
            break
        case let .error(error):
            if let payload = error.payload {
                try chargeShapeValidation(payload, budget: budget, depth: depth + 1)
            }
        case let .closure(closure):
            for capture in closure.captures {
                try chargeShapeValidation(capture, budget: budget, depth: depth + 1)
            }
        case .optional(nil), .native, .bool, .integer, .float, .string,
             .address, .mutableCell, .arrayBuilder:
            break
        }
    }

    private func chargeComparisonWork(
        lhs: VM.Value,
        rhs: VM.Value,
        budget: VM.InvocationBudget
    ) throws {
        try chargeValueTraversal(lhs, budget: budget)
        try chargeValueTraversal(rhs, budget: budget)
    }

    private func vmValuesEqual(
        _ lhs: VM.Value,
        _ rhs: VM.Value,
        budget: VM.InvocationBudget?
    ) throws -> Bool {
        guard let budget else { return VM.HashableValue.equal(lhs, rhs) }
        try chargeComparisonWork(lhs: lhs, rhs: rhs, budget: budget)
        let scratchBytes = try VM.HashableValue.equalityScratchBytes(for: rhs)
        guard scratchBytes > 0 else {
            return VM.HashableValue.equal(lhs, rhs)
        }
        return try budget.withReservedVMHeap(maximumBytes: scratchBytes) {
            (value: VM.HashableValue.equal(lhs, rhs), actualBytes: 0)
        }
    }

    private func transfer(
        _ arguments: [Bytecode.Register],
        to target: Bytecode.Block,
        function: Bytecode.Function,
        registers: inout [VM.Value?]
    ) throws {
        var values: [VM.Value] = []
        for (argument, parameter) in zip(arguments, target.parameters) {
            if function.type(of: parameter)?.requiresLinearOwnership == true {
                values.append(try take(argument, registers: &registers))
            } else {
                values.append(try read(argument, registers: registers))
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
        budget: VM.InvocationBudget
    ) throws {
        guard target.parameters.count == 1, let parameter = target.parameters.first else {
            throw VM.RuntimeTrap.invalidProgramCounter
        }
        let value: VM.Value = switch function.type(of: parameter) {
        case .string:
            .string(error.error.message)
        case .error:
            .error(error.error)
        default:
            throw VM.RuntimeTrap.invalidProgramCounter
        }
        if error.requiresBoundaryCharge {
            try budget.consumeBoundaryValue(value)
        }
        try transferValues([value], to: target, registers: &registers)
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
        let value = try read(register, registers: registers)
        guard case let .array(values, elementType) = value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .array(.never), actual: value.type)
        }
        return (values, elementType)
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
        budget: VM.InvocationBudget
    ) throws -> Bool {
        guard lhs.type == rhs.type else { throw VM.RuntimeTrap.typeMismatch(expected: lhs.type, actual: rhs.type) }
        switch predicate {
        case .equal, .notEqual:
            guard lhs.type.isVMEquatable else {
                throw VM.RuntimeTrap.nativeFailure(
                    "equality is unsupported for \(lhs.type)"
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
            guard lhs.type.isVMComparable else {
                throw VM.RuntimeTrap.nativeFailure(
                    "ordering is unsupported for \(lhs.type)"
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
            contract: invoker.contract
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

    private func runtimeTrap(for reason: Bytecode.TrapReason) -> VM.RuntimeTrap {
        switch reason {
        case .integerOverflow: .integerOverflow
        case .divisionByZero: .divisionByZero
        case .quotaExceeded: .instructionFuelExhausted
        case let .explicit(message): .explicit(message)
        }
    }
}

private struct BusinessError: Error {
    var error: VM.ErrorValue
    var requiresBoundaryCharge: Bool

    init(message: String, requiresBoundaryCharge: Bool) {
        error = .init(message: message)
        self.requiresBoundaryCharge = requiresBoundaryCharge
    }

    init(error: VM.ErrorValue, requiresBoundaryCharge: Bool) {
        self.error = error
        self.requiresBoundaryCharge = requiresBoundaryCharge
    }
}
}
