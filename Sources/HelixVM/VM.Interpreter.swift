import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier

extension VM {
public struct Interpreter: Sendable {
    public var nativeCatalog: VM.NativeCatalog
    public var nativeTypeCatalog: VM.NativeTypeCatalog
    public var entryInvocation: VM.EntryInvocation?

    public init(
        nativeCatalog: VM.NativeCatalog = .init(),
        nativeTypeCatalog: VM.NativeTypeCatalog = .init(),
        entryInvocation: VM.EntryInvocation? = nil
    ) {
        self.nativeCatalog = nativeCatalog
        self.nativeTypeCatalog = nativeTypeCatalog
        self.entryInvocation = entryInvocation
    }

    public func invoke(
        entry: Core.EntryIndex,
        image: Verification.Image,
        arguments: [VM.Value],
        budget: VM.InvocationBudget? = nil,
        rootContext: VM.RootExecutionContext = .synchronous
    ) -> VM.ExecutionResult {
        guard let mapping = image.module.entries.first(where: { $0.entryIndex == entry }) else {
            return .trapped(.unknownEntry(entry))
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
                      if case .address = type { return true }
                      return false
                  })
            else {
                throw VM.RuntimeTrap.explicit(
                    "address values cannot cross the root invocation boundary"
                )
            }
            guard arguments.count == rootFunction.parameterRegisters.count else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .tuple(rootFunction.parameterRegisters.map { rootFunction.type(of: $0)! }),
                    actual: .tuple(arguments.map(\.type))
                )
            }
            for (register, value) in zip(rootFunction.parameterRegisters, arguments) {
                try resolvedBudget.consumeBoundaryValue(value)
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
                budget: resolvedBudget
            )
            return .returned(value)
        } catch let business as VM.BusinessError {
            return .businessError(business.error.message)
        } catch let trap as VM.RuntimeTrap {
            return .trapped(trap)
        } catch {
            return .trapped(.nativeFailure(String(describing: error)))
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
            case let .optional(wrapped), let .address(wrapped):
                visit(wrapped)
            case let .array(element):
                visit(element)
            case let .dictionary(key, value):
                visit(key)
                visit(value)
            case let .closure(signature):
                (signature.parameters + [signature.result]).forEach(visit)
            case .void, .never, .bool, .integer, .float, .string, .local, .error:
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
        budget: VM.InvocationBudget
    ) throws -> VM.Value? {
        guard let function = functions[functionID] else { throw VM.RuntimeTrap.unknownFunction(functionID) }
        guard arguments.count == function.parameterRegisters.count else {
            throw VM.RuntimeTrap.typeMismatch(expected: .tuple(function.parameterRegisters.map { function.type(of: $0)! }), actual: .tuple(arguments.map(\.type)))
        }
        try budget.enterFrame()
        defer { budget.leaveFrame() }

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
        var stackSlots = (0..<function.stackSlotTypes.count).map { _ in VM.MemoryCell() }
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
        let blocks = Dictionary(uniqueKeysWithValues: function.blocks.map { ($0.id, $0) })
        var currentBlock = function.entryBlock

        while true {
            guard let block = blocks[currentBlock] else { throw VM.RuntimeTrap.invalidProgramCounter }
            var advancedToNextBlock = false
            for instruction in block.instructions {
                try budget.consumeInstruction()
                switch instruction {
                case let .constantInteger(result, value):
                    guard case let .integer(width, signed) = function.type(of: result)! else {
                        throw VM.RuntimeTrap.typeMismatch(expected: .int64, actual: function.type(of: result))
                    }
                    try initialize(.integer(VM.Integer(signed: value, bitWidth: width, isSigned: signed)), register: result, registers: &registers)
                case let .constantBool(result, value):
                    try initialize(.bool(value), register: result, registers: &registers)
                case let .constantFloat(result, value):
                    guard case let .float(width) = function.type(of: result)! else {
                        throw VM.RuntimeTrap.typeMismatch(expected: .float(bitWidth: 64), actual: function.type(of: result))
                    }
                    let normalized = width == 32 ? Double(Float(value)) : value
                    try initialize(.float(normalized, bitWidth: width), register: result, registers: &registers)
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
                        to: blocks[target]!,
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
                        to: blocks[target]!,
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
                case let .projectStructAddress(result, base, fieldIndex):
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
                case let .storeAddress(register, source, _):
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
                    try address.store(value)
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
                    let value: VM.Value
                    if lhsValue.bitWidth == 32 {
                        let left = Float(lhsValue.value)
                        let right = Float(rhsValue.value)
                        let result: Float = switch operation {
                        case .add: left + right
                        case .subtract: left - right
                        case .multiply: left * right
                        case .divide: left / right
                        }
                        value = .float(Double(result), bitWidth: 32)
                    } else {
                        let result: Double = switch operation {
                        case .add: lhsValue.value + rhsValue.value
                        case .subtract: lhsValue.value - rhsValue.value
                        case .multiply: lhsValue.value * rhsValue.value
                        case .divide: lhsValue.value / rhsValue.value
                        }
                        value = .float(result, bitWidth: 64)
                    }
                    try initialize(value, register: result, registers: &registers)
                case let .floatingUnary(result, operation, operand):
                    let operandValue = try floating(operand, registers: registers)
                    let value: VM.Value
                    if operandValue.bitWidth == 32 {
                        let result: Float = switch operation {
                        case .negate: -Float(operandValue.value)
                        }
                        value = .float(Double(result), bitWidth: 32)
                    } else {
                        let result: Double = switch operation {
                        case .negate: -operandValue.value
                        }
                        value = .float(result, bitWidth: 64)
                    }
                    try initialize(value, register: result, registers: &registers)
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
                    let converted: Double
                    switch operation {
                    case .truncate:
                        guard case let .float(value, 64) = try read(operand, registers: registers)
                        else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .float(bitWidth: 64),
                                actual: try read(operand, registers: registers).type
                            )
                        }
                        converted = Double(Float(value))
                    case .extend:
                        guard case let .float(value, 32) = try read(operand, registers: registers)
                        else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .float(bitWidth: 32),
                                actual: try read(operand, registers: registers).type
                            )
                        }
                        converted = value
                    case .signedIntegerToFloat:
                        let value = try integer(operand, registers: registers)
                        converted = targetWidth == 32
                            ? Double(Float(value.signedValue))
                            : Double(value.signedValue)
                    case .unsignedIntegerToFloat:
                        let value = try integer(operand, registers: registers)
                        converted = targetWidth == 32
                            ? Double(Float(value.unsignedValue))
                            : Double(value.unsignedValue)
                    }
                    try initialize(
                        .float(converted, bitWidth: targetWidth),
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
                case let .stringify(result, operand):
                    let source = try read(operand, registers: registers)
                    let value: String
                    switch source {
                    case let .bool(boolean):
                        value = String(boolean)
                    case let .integer(integer):
                        value = integer.description
                    case let .float(number, bitWidth):
                        value = bitWidth == 32
                            ? String(Float(number))
                            : String(number)
                    default:
                        throw VM.RuntimeTrap.nativeFailure(
                            "stringify is unsupported for \(source.type)"
                        )
                    }
                    try budget.consumeVMHeap(bytes: UInt64(value.utf8.count))
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
                case let .arrayFirst(result, operand):
                    let (values, _) = try array(operand, registers: registers)
                    let value: VM.Value?
                    if let first = values.first {
                        try chargeAggregate(elementCount: 1, budget: budget)
                        value = try copyCharging(first, budget: budget)
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
                        try chargeComparisonWork(
                            lhs: element,
                            rhs: needle,
                            budget: budget
                        )
                        if element == needle {
                            contains = true
                            break
                        }
                    }
                    try initialize(
                        .bool(contains),
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
                    var uniqueKeys = Set<VM.Value>()
                    uniqueKeys.reserveCapacity(pairValues.count)
                    for pair in pairValues {
                        guard case let .tuple(elements) = pair, elements.count == 2 else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .tuple([keyType, valueType]),
                                actual: pair.type
                            )
                        }
                        try chargeValueTraversal(elements[0], budget: budget)
                        guard uniqueKeys.insert(elements[0]).inserted else {
                            throw VM.RuntimeTrap.explicit(
                                "Dictionary literal contains duplicate keys"
                            )
                        }
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
                case let .compare(result, predicate, lhs, rhs):
                    let comparison = try compare(
                        predicate,
                        lhs: read(lhs, registers: registers),
                        rhs: read(rhs, registers: registers),
                        budget: budget
                    )
                    try initialize(.bool(comparison), register: result, registers: &registers)
                case let .branch(target, arguments):
                    try transfer(arguments, to: blocks[target]!, function: function, registers: &registers)
                    currentBlock = target
                    advancedToNextBlock = true
                case let .conditionalBranch(condition, trueTarget, trueArguments, falseTarget, falseArguments):
                    guard case let .bool(value) = try read(condition, registers: registers) else {
                        throw VM.RuntimeTrap.typeMismatch(expected: .bool, actual: try read(condition, registers: registers).type)
                    }
                    let target = value ? trueTarget : falseTarget
                    let arguments = value ? trueArguments : falseArguments
                    try transfer(arguments, to: blocks[target]!, function: function, registers: &registers)
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
                    let value = try execute(
                        functionID: callee,
                        functions: functions,
                        arguments: values,
                        localTypes: localTypes,
                        budget: budget
                    )
                    try storeCallResult(
                        value,
                        in: result,
                        function: function,
                        registers: &registers,
                        localTypes: localTypes,
                        budget: budget
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
                            expected: .closure(.init(parameters: [], result: .void)),
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
                    let value = try execute(
                        functionID: closure.functionID,
                        functions: functions,
                        arguments: callValues,
                        localTypes: localTypes,
                        budget: budget
                    )
                    try storeCallResult(
                        value,
                        in: result,
                        function: function,
                        registers: &registers,
                        localTypes: localTypes,
                        budget: budget
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
                    do {
                        let value = try execute(
                            functionID: callee,
                            functions: functions,
                            arguments: values,
                            localTypes: localTypes,
                            budget: budget
                        )
                        try transferCallOutcome(
                            value,
                            to: blocks[normalTarget]!,
                            function: function,
                            registers: &registers,
                            localTypes: localTypes,
                            budget: budget
                        )
                        currentBlock = normalTarget
                    } catch let error as VM.BusinessError {
                        try transferBusinessError(
                            error,
                            to: blocks[errorTarget]!,
                            function: function,
                            registers: &registers,
                            budget: budget
                        )
                        currentBlock = errorTarget
                    }
                    advancedToNextBlock = true
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
                            to: blocks[normalTarget]!,
                            function: function,
                            registers: &registers,
                            localTypes: localTypes,
                            budget: budget
                        )
                        currentBlock = normalTarget
                    case let .businessError(message):
                        try transferBusinessError(
                            VM.BusinessError(message: message, requiresBoundaryCharge: true),
                            to: blocks[errorTarget]!,
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
                            to: blocks[normalTarget]!,
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
                            to: blocks[errorTarget]!,
                            function: function,
                            registers: &registers,
                            budget: budget
                        )
                        currentBlock = errorTarget
                    }
                    advancedToNextBlock = true
                case let .returnValue(register):
                    try budget.checkDeadline()
                    return try register.map { try read($0, registers: registers) }
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
                if advancedToNextBlock { break }
            }
            guard advancedToNextBlock else { throw VM.RuntimeTrap.invalidProgramCounter }
        }
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
        budget: VM.InvocationBudget? = nil
    ) throws {
        switch (value, expected) {
        case (.bool, .bool), (.string, .string):
            break
        case let (.address(address), .address(pointee)):
            guard address.pointee == pointee, address.isScoped else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
        case let (.closure(closure), .closure(signature)):
            guard closure.signature == signature else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
        case let (.integer(integer), .integer(bitWidth, signed)):
            guard integer.bitWidth == bitWidth, integer.isSigned == signed else {
                throw VM.RuntimeTrap.typeMismatch(expected: expected, actual: value.type)
            }
        case let (.float(_, actualBitWidth), .float(expectedBitWidth)):
            guard actualBitWidth == expectedBitWidth else {
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
                    budget: budget
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
                    budget: budget
                )
            default:
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
                    budget: budget
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
                    budget: budget
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
                    budget: budget
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
                // Duplicate detection uses a transient hash set. Charge it even
                // though it is released after boundary validation.
                try budget.consumeAggregateStorage(elementCount: entries.count)
            }
            var keys = Set<VM.Value>()
            keys.reserveCapacity(entries.count)
            for entry in entries {
                guard keys.insert(entry.key).inserted else {
                    throw VM.RuntimeTrap.nativeFailure(
                        "Dictionary boundary value contains a duplicate key"
                    )
                }
                try validateRuntimeValue(
                    entry.key,
                    expected: expectedKey,
                    localTypes: localTypes,
                    budget: budget
                )
                try validateRuntimeValue(
                    entry.value,
                    expected: expectedValue,
                    localTypes: localTypes,
                    budget: budget
                )
            }
        case let (.optional(.some(wrapped)), .optional(type)):
            try validateRuntimeValue(
                wrapped,
                expected: type,
                localTypes: localTypes,
                budget: budget
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
        switch value {
        case let .native(native):
            .native(try nativeTypeCatalog.copy(native))
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
        case .address:
            throw VM.RuntimeTrap.inactiveAddressAccess
        case .bool, .integer, .float, .string:
            value
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

    private func chargeCopiedValue(_ value: VM.Value, budget: VM.InvocationBudget) throws {
        try budget.consumeWork(units: 1)
        switch value {
        case let .native(native):
            try budget.consumeNativeOwned(bytes: native.estimatedByteCount)
        case let .tuple(elements):
            try budget.consumeAggregateStorage(elementCount: elements.count)
            for element in elements { try chargeCopiedValue(element, budget: budget) }
        case let .array(elements, _):
            try budget.consumeAggregateStorage(elementCount: elements.count)
            for element in elements { try chargeCopiedValue(element, budget: budget) }
        case let .dictionary(entries, _, _):
            try chargeDictionaryStorage(entryCount: entries.count, budget: budget)
            for entry in entries {
                try chargeCopiedValue(entry.key, budget: budget)
                try chargeCopiedValue(entry.value, budget: budget)
            }
        case let .optional(.some(wrapped)):
            try budget.consumeAggregateStorage(elementCount: 1)
            try chargeCopiedValue(wrapped, budget: budget)
        case .optional(nil):
            try budget.consumeAggregateStorage(elementCount: 0)
        case let .structure(_, fields):
            try budget.consumeAggregateStorage(elementCount: fields.count)
            for field in fields { try chargeCopiedValue(field, budget: budget) }
        case let .enumeration(_, _, payload):
            try budget.consumeAggregateStorage(elementCount: payload == nil ? 0 : 1)
            if let payload { try chargeCopiedValue(payload, budget: budget) }
        case let .error(error):
            try budget.consumeAggregateStorage(elementCount: error.payload == nil ? 0 : 1)
            if let payload = error.payload {
                try chargeCopiedValue(payload, budget: budget)
            }
        case let .closure(closure):
            try budget.consumeAggregateStorage(elementCount: closure.captures.count)
            for capture in closure.captures {
                try chargeCopiedValue(capture, budget: budget)
            }
        case .bool, .integer, .float, .string, .address:
            break
        }
    }

    private func chargeValueTraversal(
        _ value: VM.Value,
        budget: VM.InvocationBudget
    ) throws {
        try budget.consumeWork(units: 1)
        switch value {
        case let .string(string):
            try budget.consumeUTF8Work(byteCount: string.utf8.count)
        case let .tuple(elements), let .array(elements, _):
            for element in elements {
                try chargeValueTraversal(element, budget: budget)
            }
        case let .dictionary(entries, _, _):
            for entry in entries {
                try chargeValueTraversal(entry.key, budget: budget)
                try chargeValueTraversal(entry.value, budget: budget)
            }
        case let .optional(.some(wrapped)):
            try chargeValueTraversal(wrapped, budget: budget)
        case let .structure(_, fields):
            for field in fields { try chargeValueTraversal(field, budget: budget) }
        case let .enumeration(_, _, payload):
            if let payload { try chargeValueTraversal(payload, budget: budget) }
        case let .error(error):
            try budget.consumeUTF8Work(byteCount: error.message.utf8.count)
            if let payload = error.payload {
                try chargeValueTraversal(payload, budget: budget)
            }
        case let .closure(closure):
            for capture in closure.captures {
                try chargeValueTraversal(capture, budget: budget)
            }
        case .optional(nil), .native, .bool, .integer, .float, .address:
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
        budget: VM.InvocationBudget
    ) throws {
        try budget.consumeWork(units: 1)
        switch value {
        case let .tuple(elements), let .array(elements, _):
            for element in elements {
                try chargeShapeValidation(element, budget: budget)
            }
        case let .dictionary(entries, _, _):
            for entry in entries {
                try chargeShapeValidation(entry.key, budget: budget)
                try chargeShapeValidation(entry.value, budget: budget)
            }
        case let .optional(.some(wrapped)):
            try chargeShapeValidation(wrapped, budget: budget)
        case let .structure(_, fields):
            for field in fields { try chargeShapeValidation(field, budget: budget) }
        case let .enumeration(_, _, payload):
            if let payload { try chargeShapeValidation(payload, budget: budget) }
        case let .error(error):
            if let payload = error.payload {
                try chargeShapeValidation(payload, budget: budget)
            }
        case let .closure(closure):
            for capture in closure.captures {
                try chargeShapeValidation(capture, budget: budget)
            }
        case .optional(nil), .native, .bool, .integer, .float, .string, .address:
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
    ) throws -> (value: Double, bitWidth: UInt16) {
        let value = try read(register, registers: registers)
        guard case let .float(number, bitWidth) = value else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: .float(bitWidth: 64),
                actual: value.type
            )
        }
        return (bitWidth == 32 ? Double(Float(number)) : number, bitWidth)
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

    private func dictionaryIndex(
        of needle: VM.Value,
        in entries: [VM.DictionaryEntry],
        budget: VM.InvocationBudget
    ) throws -> Int? {
        for (index, entry) in entries.enumerated() {
            try chargeComparisonWork(
                lhs: entry.key,
                rhs: needle,
                budget: budget
            )
            if entry.key == needle { return index }
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
            guard right != 0 else { throw VM.RuntimeTrap.divisionByZero }
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
            guard right != 0 else { throw VM.RuntimeTrap.divisionByZero }
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
            guard right != 0 else { throw VM.RuntimeTrap.divisionByZero }
            raw = left / right; machineOverflow = false
        case .remainder:
            guard right != 0 else { throw VM.RuntimeTrap.divisionByZero }
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
        if case let (.float(rawLeft, bitWidth), .float(rawRight, _)) = (lhs, rhs) {
            let left = bitWidth == 32 ? Double(Float(rawLeft)) : rawLeft
            let right = bitWidth == 32 ? Double(Float(rawRight)) : rawRight
            // Preserve Swift/IEEE-754 unordered semantics. Mapping NaN to a total
            // ComparisonResult would incorrectly make it greater than every value.
            return switch predicate {
            case .equal: left == right
            case .notEqual: left != right
            case .lessThan: left < right
            case .lessThanOrEqual: left <= right
            case .greaterThan: left > right
            case .greaterThanOrEqual: left >= right
            }
        }
        if case let (.string(left), .string(right)) = (lhs, rhs) {
            try chargeComparisonWork(lhs: lhs, rhs: rhs, budget: budget)
            // Swift String ordering is lexicographical over extended grapheme
            // clusters. Foundation's locale-sensitive compare is not equivalent.
            return switch predicate {
            case .equal: left == right
            case .notEqual: left != right
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
        case let (.bool(left), .bool(right)):
            ordering = left == right ? .orderedSame : (!left && right ? .orderedAscending : .orderedDescending)
        default:
            throw VM.RuntimeTrap.nativeFailure("comparison is unsupported for \(lhs.type)")
        }
        return switch predicate {
        case .equal: ordering == .orderedSame
        case .notEqual: ordering != .orderedSame
        case .lessThan: ordering == .orderedAscending
        case .lessThanOrEqual: ordering != .orderedDescending
        case .greaterThan: ordering == .orderedDescending
        case .greaterThanOrEqual: ordering != .orderedAscending
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
