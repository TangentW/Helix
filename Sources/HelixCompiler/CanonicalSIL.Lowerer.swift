import Foundation
import HelixBytecode
import HelixCore

extension CanonicalSIL {
public struct Lowerer: Sendable {
    private let typeEnvironment: CanonicalSIL.TypeEnvironment

    private enum SwiftCoreIntrinsic: Equatable {
        case stringLiteral
        case stringEqual
        case stringLess
        case stringConcat
        case stringCount
        case stringIsEmpty
        case stringHasPrefix
        case stringHasSuffix
        case stringContains
        case stringInterpolationInit
        case stringInterpolationAppendLiteral
        case stringInterpolationAppendValue
        case stringFromInterpolation
        case arrayCount
        case collectionIsEmpty
        case arraySubscript
        case arraySubscriptModify
        case collectionFirst
        case sequenceContains
        case arrayAppend
        case collectionMakeIterator
        case indexingIteratorNext
        case dictionaryCount
        case dictionaryIsEmpty
        case dictionarySubscriptGet
        case dictionarySubscriptSet
        case dictionaryLiteral
        case dictionaryMakeIterator
        case dictionaryIteratorNext
        case allocateUninitializedArray
        case finalizeUninitializedArray

        init?(mangledName: String) {
            switch mangledName {
            case "$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC":
                self = .stringLiteral
            case "$sSS2eeoiySbSS_SStFZ": self = .stringEqual
            case "$sSS1loiySbSS_SStFZ": self = .stringLess
            case "$sSS1poiyS2S_SStFZ": self = .stringConcat
            case "$sSS5countSivg": self = .stringCount
            case "$sSS7isEmptySbvg": self = .stringIsEmpty
            case "$sSS9hasPrefixySbSSF": self = .stringHasPrefix
            case "$sSS9hasSuffixySbSSF": self = .stringHasSuffix
            case "$sSy17_StringProcessingE8containsySbSSF": self = .stringContains
            case "$ss26DefaultStringInterpolationV15literalCapacity18interpolationCountABSi_SitcfC":
                self = .stringInterpolationInit
            case "$ss26DefaultStringInterpolationV13appendLiteralyySSF":
                self = .stringInterpolationAppendLiteral
            case "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzlF":
                self = .stringInterpolationAppendValue
            case "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzs20TextOutputStreamableRzlF":
                self = .stringInterpolationAppendValue
            case "$sSS19stringInterpolationSSs013DefaultStringB0V_tcfC":
                self = .stringFromInterpolation
            case "$sSa5countSivg": self = .arrayCount
            case "$sSlsE7isEmptySbvg": self = .collectionIsEmpty
            case "$sSayxSicig": self = .arraySubscript
            case "$sSayxSiciM": self = .arraySubscriptModify
            case "$sSlsE5first7ElementQzSgvg": self = .collectionFirst
            case "$sSTsSQ7ElementRpzrlE8containsySbABF": self = .sequenceContains
            case "$sSa6appendyyxnF": self = .arrayAppend
            case "$sSlss16IndexingIteratorVyxG0B0RtzrlE04makeB0ACyF":
                self = .collectionMakeIterator
            case "$ss16IndexingIteratorV4next7ElementQzSgyF":
                self = .indexingIteratorNext
            case "$sSD5countSivg": self = .dictionaryCount
            case "$sSD7isEmptySbvg": self = .dictionaryIsEmpty
            case "$sSDyq_Sgxcig": self = .dictionarySubscriptGet
            case "$sSDyq_Sgxcis": self = .dictionarySubscriptSet
            case "$sSD17dictionaryLiteralSDyxq_Gx_q_td_tcfC": self = .dictionaryLiteral
            case "$sSD12makeIteratorSD0B0Vyxq__GyF": self = .dictionaryMakeIterator
            case "$sSD8IteratorV4nextx3key_q_5valuetSgyF": self = .dictionaryIteratorNext
            case "$ss27_allocateUninitializedArrayySayxG_BptBwlF":
                self = .allocateUninitializedArray
            case "$ss27_finalizeUninitializedArrayySayxGABnlF":
                self = .finalizeUninitializedArray
            default: return nil
            }
        }
    }

    private struct PendingArrayLiteral {
        var elementType: Bytecode.ValueType
        var count: Int
        var elements: [Int: Bytecode.Register] = [:]
        var elementComponents: [Int: [Int: Bytecode.Register]] = [:]
    }

    private struct ArrayLiteralAddress {
        var allocation: String
        var index: Int
    }

    private struct ArrayIteratorState {
        var elementType: Bytecode.ValueType
        var array: Bytecode.Register
        var indexSlot: Bytecode.StackSlot
    }

    private struct ArrayElementMutation {
        var arrayAddress: String
        var array: Bytecode.Register
        var index: Bytecode.Register
        var elementType: Bytecode.ValueType
        var didStore = false
    }

    private struct DictionaryIteratorState {
        var keyType: Bytecode.ValueType
        var valueType: Bytecode.ValueType
        var dictionary: Bytecode.Register
        var indexSlot: Bytecode.StackSlot
    }

    private struct ArrayLiteralComponentAddress {
        var allocation: String
        var index: Int
        var component: Int
    }

    public init(typeEnvironment: CanonicalSIL.TypeEnvironment = .empty) {
        self.typeEnvironment = typeEnvironment
    }

    public func lower(
        _ function: CanonicalSIL.Function,
        displayName: String,
        kind: Bytecode.FunctionKind = .ordinary,
        directCalls: CanonicalSIL.DirectCallTable = .empty,
        expectedEffects: Core.Effects? = nil
    ) throws -> IntermediateRepresentation.Function {
        let signature = try parseFunctionType(function.loweredType)
        let effectiveEffects = expectedEffects ?? signature.effects
        guard effectiveEffects.mayThrow == signature.effects.mayThrow,
              effectiveEffects.isAsync == signature.effects.isAsync
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "frozen throwing/async effects disagree with the lowered function convention"
            )
        }
        let usesRuntimeAddresses = signature.parameterConventions.contains(.inout)
            || directCalls.referencesInoutCallee(in: function.body)
        let normalizedBody = try CanonicalSIL.AsyncLeaf.normalizedBody(
            of: function,
            effects: effectiveEffects
        )
        let rawLines = normalizedBody.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let maximumOriginalBlock = rawLines.compactMap(parseBlockNumber).max() ?? 0
        var nextSyntheticBlock: UInt32? = maximumOriginalBlock == UInt32.max
            ? nil
            : maximumOriginalBlock + 1
        var registerTypes: [Bytecode.ValueType] = []
        var values: [String: Bytecode.Register] = [:]
        var functionReferences: [String: CanonicalSIL.DirectCallBinding] = [:]
        var swiftCoreReferences: [String: SwiftCoreIntrinsic] = [:]
        var localFactoryReferences: [String: Bytecode.LocalTypeKey] = [:]
        var stringLiterals: [String: String] = [:]
        var wordLiterals: [String: UInt64] = [:]
        var integerLiterals: [String: (bitWidth: UInt16, value: Int64)] = [:]
        var retypedIntegerLiterals: [String: [Bytecode.ValueType: Bytecode.Register]] = [:]
        var boolLiterals: [String: Bool] = [:]
        var metatypeValues = Set<String>()
        var localMetatypeValues: [String: Bytecode.LocalTypeKey] = [:]
        var dictionaryMetatypeValues: [String: (Bytecode.ValueType, Bytecode.ValueType)] = [:]
        var stackAddressTypes: [String: Bytecode.ValueType] = [:]
        var stackAddressValues: [String: Bytecode.Register] = [:]
        var stackSlotTypes: [Bytecode.ValueType] = []
        var runtimeStackSlots: [String: Bytecode.StackSlot] = [:]
        var runtimeAddressValues: [String: Bytecode.Register] = [:]
        var runtimeAddressPointees: [String: Bytecode.ValueType] = [:]
        var scopedRuntimeAddresses = Set<String>()
        var inoutParameterAddressBases = Set<String>()
        var passthroughRuntimeAccesses = Set<String>()
        var borrowedAddressValues: [String: Bytecode.Register] = [:]
        var addressAliases: [String: String] = [:]
        var pendingArrayIteratorTypes: [String: Bytecode.ValueType] = [:]
        var arrayIteratorStates: [String: ArrayIteratorState] = [:]
        var destroyedArrayIterators = Set<String>()
        var arrayElementMutations: [String: ArrayElementMutation] = [:]
        var arrayMutationYieldByToken: [String: String] = [:]
        var integerConversionResults = Set<String>()
        var pendingDictionaryIteratorTypes: [String: (Bytecode.ValueType, Bytecode.ValueType)] = [:]
        var pendingDictionaryIteratorValues: [String: DictionaryIteratorState] = [:]
        var dictionaryIteratorStates: [String: DictionaryIteratorState] = [:]
        var destroyedDictionaryIterators = Set<String>()
        var pendingStringInterpolationAddresses = Set<String>()
        var stringInterpolationAddressValues: [String: Bytecode.Register] = [:]
        var stringInterpolationValues: [String: Bytecode.Register] = [:]
        var stringInterpolationMetatypes = Set<String>()
        var pendingArrayLiterals: [String: PendingArrayLiteral] = [:]
        var arrayLiteralAllocationByValue: [String: String] = [:]
        var arrayLiteralStorageTokens: [String: String] = [:]
        var arrayLiteralAddresses: [String: ArrayLiteralAddress] = [:]
        var arrayLiteralComponentAddresses: [String: ArrayLiteralComponentAddress] = [:]
        var tupleValues: [String: (Bytecode.Register, Bytecode.Register)] = [:]
        var unpackedTuples: [String: [Bytecode.Register]] = [:]
        var onStackClosureValues = Set<String>()
        var voidValues = Set<String>()
        var optionalSourceBySomeBlock: [Bytecode.BlockID: String] = [:]
        var optionalSourceByNoneBlock: [Bytecode.BlockID: String] = [:]
        var reconstructedNoneValues: [Bytecode.BlockID: [String: Bytecode.Register]] = [:]
        var errorEnumMessages: [String: String] = [:]
        var existentialBoxes = Set<String>()
        var typedErrorBoxTypes: [String: Bytecode.LocalTypeKey] = [:]
        var projectedBoxByAddress: [String: String] = [:]
        var errorMessageByBox: [String: String] = [:]
        var catchScratchAddresses = Set<String>()
        var implicitStackValues: [
            Bytecode.BlockID: [(address: String, register: Bytecode.Register)]
        ] = [:]
        var blocks: [IntermediateRepresentation.Block] = []
        var current: IntermediateRepresentation.Block?
        var entryBlock: Bytecode.BlockID?
        var parameterRegisters: [Bytecode.Register] = []

        func allocate(type: Bytecode.ValueType) throws -> Bytecode.Register {
            guard let raw = UInt32(exactly: registerTypes.count) else {
                throw CanonicalSIL.LoweringError.malformedSIL("register table exceeds UInt32")
            }
            registerTypes.append(type)
            return .init(rawValue: raw)
        }

        func allocateStackSlot(type: Bytecode.ValueType) throws -> Bytecode.StackSlot {
            guard let raw = UInt32(exactly: stackSlotTypes.count) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "stack-slot table exceeds UInt32"
                )
            }
            stackSlotTypes.append(type)
            return .init(rawValue: raw)
        }

        func allocateSyntheticBlockID() throws -> Bytecode.BlockID {
            guard let raw = nextSyntheticBlock else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "synthetic block table exceeds UInt32"
                )
            }
            let advanced = raw.addingReportingOverflow(1)
            nextSyntheticBlock = advanced.overflow ? nil : advanced.partialValue
            return .init(rawValue: raw)
        }

        func addressBase(_ token: String) -> String {
            var current = token
            var visited = Set<String>()
            while let next = addressAliases[current], visited.insert(current).inserted {
                current = next
            }
            return current
        }

        func stackType(at token: String) -> Bytecode.ValueType? {
            runtimeAddressPointees[token]
                ?? stackAddressTypes[addressBase(token)]
        }

        func runtimeAddress(at token: String) -> Bytecode.Register? {
            runtimeAddressValues[token] ?? runtimeAddressValues[addressBase(token)]
        }

        func isScopedRuntimeAddress(_ token: String) -> Bool {
            scopedRuntimeAddresses.contains(token)
                || scopedRuntimeAddresses.contains(addressBase(token))
        }

        func stackValue(at token: String) -> Bytecode.Register? {
            stackAddressValues[addressBase(token)]
        }

        func assignStackValue(_ value: Bytecode.Register, at token: String) {
            stackAddressValues[addressBase(token)] = value
        }

        func resolve(_ token: String, line: Int) throws -> Bytecode.Register {
            if let blockID = current?.id,
               optionalSourceByNoneBlock[blockID] == token {
                if let replacement = reconstructedNoneValues[blockID]?[token] {
                    return replacement
                }
                guard let original = values[token] else {
                    throw CanonicalSIL.LoweringError.undefinedValue(line: line, value: token)
                }
                let type = registerTypes[Int(original.rawValue)]
                guard case .optional = type else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "switch_enum none edge does not reference an Optional"
                    )
                }
                let replacement = try allocate(type: type)
                current!.instructions.append(.makeOptionalNone(result: replacement))
                reconstructedNoneValues[blockID, default: [:]][token] = replacement
                return replacement
            }
            guard let register = values[token] else {
                throw CanonicalSIL.LoweringError.undefinedValue(line: line, value: token)
            }
            return register
        }

        func prepareDirectCallArguments(
            _ text: String,
            conventions: [Bytecode.ParameterConvention],
            line: Int,
            allowsSynthesizedAccess: Bool
        ) throws -> (arguments: [Bytecode.Register], accesses: [Bytecode.Register]) {
            let tokens = try parseApplyValueTokens(text, line: line)
            guard tokens.count == conventions.count else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "direct call argument and convention counts disagree"
                )
            }
            var arguments: [Bytecode.Register] = []
            var accesses: [Bytecode.Register] = []
            arguments.reserveCapacity(tokens.count)
            for (token, convention) in zip(tokens, conventions) {
                let value = try resolve(token, line: line)
                guard convention == .inout else {
                    arguments.append(value)
                    continue
                }
                guard case let .address(pointee) = registerTypes[Int(value.rawValue)] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "inout call argument is not an address"
                    )
                }
                if isScopedRuntimeAddress(token) {
                    arguments.append(value)
                    continue
                }
                guard allowsSynthesizedAccess else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: line,
                        text: "inout access across try_apply"
                    )
                }
                let access = try allocate(type: .address(pointee))
                current!.instructions.append(
                    .beginAccess(result: access, address: value, kind: .modify)
                )
                arguments.append(access)
                accesses.append(access)
            }
            return (arguments, accesses)
        }

        func materializeIntegerOperand(
            _ token: String,
            expected: Bytecode.ValueType,
            line: Int
        ) throws -> Bytecode.Register {
            let original = try resolve(token, line: line)
            if registerTypes[Int(original.rawValue)] == expected { return original }
            if let cached = retypedIntegerLiterals[token]?[expected] { return cached }
            guard case let .integer(bitWidth, signed) = expected,
                  let literal = integerLiterals[token],
                  literal.bitWidth == bitWidth,
                  signed || literal.value >= 0
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "integer literal does not match its builtin signedness"
                )
            }
            let result = try allocate(type: expected)
            current!.instructions.append(
                .constantInteger(result: result, value: literal.value)
            )
            retypedIntegerLiterals[token, default: [:]][expected] = result
            return result
        }

        func integerOperandType(
            bitWidth: UInt16,
            signedness: Bool?,
            lhsToken: String,
            lhs: Bytecode.Register,
            rhsToken: String,
            rhs: Bytecode.Register
        ) -> Bytecode.ValueType? {
            if bitWidth == 1 { return .bool }
            if let signedness {
                return .integer(bitWidth: bitWidth, signed: signedness)
            }
            let candidates = [(lhsToken, lhs), (rhsToken, rhs)]
            for (token, register) in candidates where integerLiterals[token] == nil {
                if case let .integer(width, signed) = registerTypes[Int(register.rawValue)],
                   width == bitWidth {
                    return .integer(bitWidth: width, signed: signed)
                }
            }
            for (_, register) in candidates {
                if case let .integer(width, signed) = registerTypes[Int(register.rawValue)],
                   width == bitWidth {
                    return .integer(bitWidth: width, signed: signed)
                }
            }
            return nil
        }

        func finishCurrent() {
            if let current { blocks.append(current) }
            current = nil
        }

        func materializeArrayLiteralElements(
            _ pending: PendingArrayLiteral
        ) throws -> [Bytecode.Register] {
            var result: [Bytecode.Register] = []
            result.reserveCapacity(pending.count)
            for index in 0..<pending.count {
                if let element = pending.elements[index] {
                    guard pending.elementComponents[index] == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array literal element mixes whole-value and component stores"
                        )
                    }
                    result.append(element)
                    continue
                }
                guard case let .tuple(types) = pending.elementType,
                      let components = pending.elementComponents[index],
                      components.count == types.count,
                      types.indices.allSatisfy({ components[$0] != nil })
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array literal element is incomplete"
                    )
                }
                var registers: [Bytecode.Register] = []
                registers.reserveCapacity(types.count)
                for index in types.indices {
                    guard let component = components[index] else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array literal tuple component is missing"
                        )
                    }
                    registers.append(component)
                }
                let tuple = try allocate(type: pending.elementType)
                current!.instructions.append(.makeTuple(result: tuple, elements: registers))
                result.append(tuple)
            }
            return result
        }

        func lowerSwiftCoreIntrinsic(
            _ intrinsic: SwiftCoreIntrinsic,
            resultToken: String,
            genericArguments: String,
            argumentText: String,
            line: Int
        ) throws {
            let arguments = try parseApplyValueTokens(argumentText, line: line)
            guard !resultToken.isEmpty else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Swift core intrinsic does not define a result"
                )
            }

            switch intrinsic {
            case .stringLiteral:
                guard genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String literal initializer unexpectedly has generic arguments"
                    )
                }
                guard arguments.count == 4,
                      let literal = stringLiterals[arguments[0]],
                      let expectedByteCount = wordLiterals[arguments[1]],
                      let expectedASCII = boolLiterals[arguments[2]],
                      metatypeValues.contains(arguments[3])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String literal initializer has unsupported arguments"
                    )
                }
                let actualByteCount = UInt64(literal.utf8.count)
                let actualASCII = literal.utf8.allSatisfy { $0 < 0x80 }
                guard actualByteCount == expectedByteCount,
                      actualASCII == expectedASCII
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String literal metadata does not match its UTF-8 payload"
                    )
                }
                let result = try allocate(type: .string)
                values[resultToken] = result
                current!.instructions.append(.constantString(result: result, value: literal))

            case .stringEqual, .stringLess:
                guard genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String comparison unexpectedly has generic arguments"
                    )
                }
                guard arguments.count == 3, metatypeValues.contains(arguments[2]) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String comparison has unsupported arguments"
                    )
                }
                let lhs = try resolve(arguments[0], line: line)
                let rhs = try resolve(arguments[1], line: line)
                guard registerTypes[Int(lhs.rawValue)] == .string,
                      registerTypes[Int(rhs.rawValue)] == .string
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String comparison operands must both be String"
                    )
                }
                let result = try allocate(type: .bool)
                values[resultToken] = result
                current!.instructions.append(
                    .compare(
                        result: result,
                        predicate: intrinsic == .stringEqual ? .equal : .lessThan,
                        lhs: lhs,
                        rhs: rhs
                    )
                )

            case .stringConcat:
                guard genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String concatenation unexpectedly has generic arguments"
                    )
                }
                guard arguments.count == 3, metatypeValues.contains(arguments[2]) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String concatenation has unsupported arguments"
                    )
                }
                let lhs = try resolve(arguments[0], line: line)
                let rhs = try resolve(arguments[1], line: line)
                guard registerTypes[Int(lhs.rawValue)] == .string,
                      registerTypes[Int(rhs.rawValue)] == .string
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String concatenation operands must both be String"
                    )
                }
                let result = try allocate(type: .string)
                values[resultToken] = result
                current!.instructions.append(.stringConcat(result: result, lhs: lhs, rhs: rhs))

            case .stringCount, .stringIsEmpty:
                guard genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String property getter unexpectedly has generic arguments"
                    )
                }
                guard arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String property getter has unsupported arguments"
                    )
                }
                let operand = try resolve(arguments[0], line: line)
                guard registerTypes[Int(operand.rawValue)] == .string else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String property getter operand must be String"
                    )
                }
                let resultType: Bytecode.ValueType = intrinsic == .stringCount ? .int64 : .bool
                let result = try allocate(type: resultType)
                values[resultToken] = result
                current!.instructions.append(
                    intrinsic == .stringCount
                        ? .stringCount(result: result, string: operand)
                        : .stringIsEmpty(result: result, string: operand)
                )

            case .stringHasPrefix, .stringHasSuffix:
                guard genericArguments.isEmpty, arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String prefix/suffix predicate has unsupported arguments"
                    )
                }
                let pattern = try resolve(arguments[0], line: line)
                let string = try resolve(arguments[1], line: line)
                guard registerTypes[Int(pattern.rawValue)] == .string,
                      registerTypes[Int(string.rawValue)] == .string
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String prefix/suffix operands must both be String"
                    )
                }
                let result = try allocate(type: .bool)
                values[resultToken] = result
                current!.instructions.append(
                    .stringPredicate(
                        result: result,
                        operation: intrinsic == .stringHasPrefix ? .hasPrefix : .hasSuffix,
                        string: string,
                        pattern: pattern
                    )
                )

            case .stringContains:
                guard arguments.count == 2,
                      try parseType(genericArguments) == .string
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String.contains has unsupported generic arguments"
                    )
                }
                let pattern = try resolve(arguments[0], line: line)
                guard let string = stackValue(at: arguments[1]) ?? values[arguments[1]],
                      registerTypes[Int(pattern.rawValue)] == .string,
                      registerTypes[Int(string.rawValue)] == .string
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String.contains operands must both be String"
                    )
                }
                let result = try allocate(type: .bool)
                values[resultToken] = result
                current!.instructions.append(
                    .stringPredicate(
                        result: result,
                        operation: .contains,
                        string: string,
                        pattern: pattern
                    )
                )

            case .stringInterpolationInit:
                guard genericArguments.isEmpty,
                      arguments.count == 3,
                      stringInterpolationMetatypes.contains(arguments[2])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "DefaultStringInterpolation initializer has unsupported arguments"
                    )
                }
                let literalCapacity = try resolve(arguments[0], line: line)
                let interpolationCount = try resolve(arguments[1], line: line)
                guard registerTypes[Int(literalCapacity.rawValue)] == .int64,
                      registerTypes[Int(interpolationCount.rawValue)] == .int64
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String interpolation capacities must be Int"
                    )
                }
                let accumulator = try allocate(type: .string)
                current!.instructions.append(
                    .constantString(result: accumulator, value: "")
                )
                stringInterpolationValues[resultToken] = accumulator

            case .stringInterpolationAppendLiteral:
                guard genericArguments.isEmpty,
                      arguments.count == 2,
                      let accumulator = stringInterpolationAddressValues[
                          addressBase(arguments[1])
                      ]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "appendLiteral has unsupported interpolation state"
                    )
                }
                let literal = try resolve(arguments[0], line: line)
                guard registerTypes[Int(literal.rawValue)] == .string else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "appendLiteral operand must be String"
                    )
                }
                let result = try allocate(type: .string)
                current!.instructions.append(
                    .stringConcat(result: result, lhs: accumulator, rhs: literal)
                )
                stringInterpolationAddressValues[addressBase(arguments[1])] = result
                voidValues.insert(resultToken)

            case .stringInterpolationAppendValue:
                guard arguments.count == 2,
                      !genericArguments.isEmpty,
                      let accumulator = stringInterpolationAddressValues[
                          addressBase(arguments[1])
                      ]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "appendInterpolation has unsupported arguments"
                    )
                }
                guard let value = stackValue(at: arguments[0]) ?? values[arguments[0]] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "appendInterpolation value is unavailable"
                    )
                }
                let valueType = stackType(at: arguments[0])
                    ?? registerTypes[Int(value.rawValue)]
                guard try parseType(genericArguments) == valueType,
                      registerTypes[Int(value.rawValue)] == valueType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "appendInterpolation generic type does not match its value"
                    )
                }
                let rendered: Bytecode.Register
                switch valueType {
                case .string:
                    rendered = value
                case .bool, .integer, .float:
                    rendered = try allocate(type: .string)
                    current!.instructions.append(
                        .stringify(result: rendered, value: value)
                    )
                default:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "String interpolation payload \(valueType)"
                    )
                }
                let result = try allocate(type: .string)
                current!.instructions.append(
                    .stringConcat(result: result, lhs: accumulator, rhs: rendered)
                )
                stringInterpolationAddressValues[addressBase(arguments[1])] = result
                voidValues.insert(resultToken)

            case .stringFromInterpolation:
                guard genericArguments.isEmpty,
                      arguments.count == 2,
                      metatypeValues.contains(arguments[1]),
                      let result = stringInterpolationValues.removeValue(
                          forKey: arguments[0]
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String interpolation finalizer has unsupported arguments"
                    )
                }
                values[resultToken] = result

            case .arrayCount, .collectionIsEmpty:
                guard arguments.count == 1, !genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array property getter has unsupported arguments"
                    )
                }
                let operand = try resolve(arguments[0], line: line)
                guard case let .array(element) = registerTypes[Int(operand.rawValue)] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array property getter operand must be Array"
                    )
                }
                let genericType = try parseType(genericArguments)
                let expectedGeneric: Bytecode.ValueType = intrinsic == .arrayCount
                    ? element
                    : .array(element)
                guard genericType == expectedGeneric else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array property getter generic type does not match its operand"
                    )
                }
                let resultType: Bytecode.ValueType = intrinsic == .arrayCount ? .int64 : .bool
                let result = try allocate(type: resultType)
                values[resultToken] = result
                current!.instructions.append(
                    intrinsic == .arrayCount
                        ? .arrayCount(result: result, array: operand)
                        : .arrayIsEmpty(result: result, array: operand)
                )

            case .arraySubscript:
                guard arguments.count == 3, !genericArguments.isEmpty,
                      let outputType = stackType(at: arguments[0])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array subscript has unsupported arguments"
                    )
                }
                let index = try resolve(arguments[1], line: line)
                let array = try resolve(arguments[2], line: line)
                let element = try parseType(genericArguments)
                guard registerTypes[Int(index.rawValue)] == .int64,
                      registerTypes[Int(array.rawValue)] == .array(element),
                      outputType == element
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array subscript types do not match"
                    )
                }
                let result = try allocate(type: element)
                assignStackValue(result, at: arguments[0])
                current!.instructions.append(.arrayGet(result: result, array: array, index: index))
                voidValues.insert(resultToken)

            case .arraySubscriptModify:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Array.subscript.modify must be consumed by begin_apply"
                )

            case .collectionFirst:
                guard arguments.count == 2, !genericArguments.isEmpty,
                      let outputType = stackType(at: arguments[0])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Collection.first has unsupported arguments"
                    )
                }
                let array = try resolve(arguments[1], line: line)
                let collectionType = try parseType(genericArguments)
                guard case let .array(element) = collectionType,
                      registerTypes[Int(array.rawValue)] == collectionType,
                      outputType == .optional(element)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Collection.first types do not match Array.Element"
                    )
                }
                let result = try allocate(type: .optional(element))
                assignStackValue(result, at: arguments[0])
                current!.instructions.append(.arrayFirst(result: result, array: array))
                voidValues.insert(resultToken)

            case .sequenceContains:
                guard arguments.count == 2, !genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Sequence.contains has unsupported arguments"
                    )
                }
                let needle = try resolve(arguments[0], line: line)
                let array = try resolve(arguments[1], line: line)
                let sequenceType = try parseType(genericArguments)
                guard case let .array(element) = sequenceType,
                      registerTypes[Int(array.rawValue)] == sequenceType,
                      registerTypes[Int(needle.rawValue)] == element
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Sequence.contains types do not match Array.Element"
                    )
                }
                let result = try allocate(type: .bool)
                values[resultToken] = result
                current!.instructions.append(
                    .arrayContains(result: result, array: array, value: needle)
                )

            case .arrayAppend:
                guard arguments.count == 2,
                      !genericArguments.isEmpty,
                      let valueType = stackType(at: arguments[0]),
                      let value = stackValue(at: arguments[0]),
                      let arrayType = stackType(at: arguments[1]),
                      let array = stackValue(at: arguments[1])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.append has unsupported inout arguments"
                    )
                }
                let element = try parseType(genericArguments)
                guard valueType == element,
                      registerTypes[Int(value.rawValue)] == element,
                      arrayType == .array(element),
                      registerTypes[Int(array.rawValue)] == arrayType,
                      !element.requiresLinearOwnership
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.append types do not match Array.Element"
                    )
                }
                let result = try allocate(type: arrayType)
                current!.instructions.append(
                    .arrayAppend(result: result, array: array, value: value)
                )
                assignStackValue(result, at: arguments[1])
                voidValues.insert(resultToken)

            case .collectionMakeIterator:
                guard arguments.count == 2,
                      !genericArguments.isEmpty,
                      let collectionType = try? parseType(genericArguments),
                      case let .array(element) = collectionType,
                      pendingArrayIteratorTypes[addressBase(arguments[0])] == element,
                      stackType(at: arguments[1]) == collectionType,
                      let array = stackValue(at: arguments[1]),
                      registerTypes[Int(array.rawValue)] == collectionType,
                      !element.requiresLinearOwnership
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.makeIterator has unsupported arguments"
                    )
                }
                let iteratorAddress = addressBase(arguments[0])
                guard arrayIteratorStates[iteratorAddress] == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array iterator address is initialized more than once"
                    )
                }
                let zero = try allocate(type: .int64)
                current!.instructions.append(.constantInteger(result: zero, value: 0))
                let slot = try allocateStackSlot(type: .int64)
                current!.instructions.append(
                    .storeStack(slot: slot, source: zero, mode: .initialize)
                )
                arrayIteratorStates[iteratorAddress] = .init(
                    elementType: element,
                    array: array,
                    indexSlot: slot
                )
                voidValues.insert(resultToken)

            case .indexingIteratorNext:
                guard arguments.count == 2,
                      !genericArguments.isEmpty,
                      let collectionType = try? parseType(genericArguments),
                      case let .array(element) = collectionType,
                      stackType(at: arguments[0]) == .optional(element),
                      let state = arrayIteratorStates[addressBase(arguments[1])],
                      state.elementType == element,
                      registerTypes[Int(state.array.rawValue)] == collectionType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "IndexingIterator<Array>.next has unsupported arguments"
                    )
                }
                let result = try allocate(type: .optional(element))
                current!.instructions.append(
                    .arrayNext(
                        result: result,
                        array: state.array,
                        indexSlot: state.indexSlot
                    )
                )
                assignStackValue(result, at: arguments[0])
                voidValues.insert(resultToken)

            case .dictionaryCount, .dictionaryIsEmpty:
                guard arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary property getter has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(genericArguments)
                let dictionary = try resolve(arguments[0], line: line)
                guard registerTypes[Int(dictionary.rawValue)]
                        == .dictionary(key: types.key, value: types.value)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary property getter generic types do not match its operand"
                    )
                }
                let resultType: Bytecode.ValueType = intrinsic == .dictionaryCount
                    ? .int64
                    : .bool
                let result = try allocate(type: resultType)
                values[resultToken] = result
                current!.instructions.append(
                    intrinsic == .dictionaryCount
                        ? .dictionaryCount(result: result, dictionary: dictionary)
                        : .dictionaryIsEmpty(result: result, dictionary: dictionary)
                )

            case .dictionarySubscriptGet:
                guard arguments.count == 3,
                      let outputType = stackType(at: arguments[0]),
                      let key = stackValue(at: arguments[1])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary subscript getter has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(genericArguments)
                let dictionary = try resolve(arguments[2], line: line)
                guard outputType == .optional(types.value),
                      registerTypes[Int(key.rawValue)] == types.key,
                      registerTypes[Int(dictionary.rawValue)]
                        == .dictionary(key: types.key, value: types.value)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary subscript getter types do not match"
                    )
                }
                let result = try allocate(type: outputType)
                current!.instructions.append(
                    .dictionaryGet(result: result, dictionary: dictionary, key: key)
                )
                assignStackValue(result, at: arguments[0])
                voidValues.insert(resultToken)

            case .dictionarySubscriptSet:
                guard arguments.count == 3,
                      let updateType = stackType(at: arguments[0]),
                      let update = stackValue(at: arguments[0]),
                      let keyType = stackType(at: arguments[1]),
                      let key = stackValue(at: arguments[1]),
                      let dictionaryType = stackType(at: arguments[2]),
                      let dictionary = stackValue(at: arguments[2])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary subscript setter has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(genericArguments)
                let expectedDictionary = Bytecode.ValueType.dictionary(
                    key: types.key,
                    value: types.value
                )
                guard updateType == .optional(types.value),
                      registerTypes[Int(update.rawValue)] == updateType,
                      keyType == types.key,
                      registerTypes[Int(key.rawValue)] == keyType,
                      dictionaryType == expectedDictionary,
                      registerTypes[Int(dictionary.rawValue)] == dictionaryType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary subscript setter types do not match"
                    )
                }
                let result = try allocate(type: dictionaryType)
                current!.instructions.append(
                    .dictionaryUpdate(
                        result: result,
                        dictionary: dictionary,
                        key: key,
                        value: update
                    )
                )
                assignStackValue(result, at: arguments[2])
                voidValues.insert(resultToken)

            case .dictionaryLiteral:
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary literal initializer has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(genericArguments)
                let pairs = try resolve(arguments[0], line: line)
                guard registerTypes[Int(pairs.rawValue)]
                        == .array(.tuple([types.key, types.value])),
                      let metatype = dictionaryMetatypeValues[arguments[1]],
                      metatype.0 == types.key,
                      metatype.1 == types.value
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary literal initializer types do not match"
                    )
                }
                let result = try allocate(
                    type: .dictionary(key: types.key, value: types.value)
                )
                values[resultToken] = result
                current!.instructions.append(
                    .makeDictionary(result: result, pairs: pairs)
                )

            case .dictionaryMakeIterator:
                guard arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.makeIterator has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(genericArguments)
                let dictionary = try resolve(arguments[0], line: line)
                guard registerTypes[Int(dictionary.rawValue)]
                        == .dictionary(key: types.key, value: types.value),
                      pendingDictionaryIteratorValues[resultToken] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.makeIterator types do not match"
                    )
                }
                let zero = try allocate(type: .int64)
                current!.instructions.append(.constantInteger(result: zero, value: 0))
                let slot = try allocateStackSlot(type: .int64)
                current!.instructions.append(
                    .storeStack(slot: slot, source: zero, mode: .initialize)
                )
                pendingDictionaryIteratorValues[resultToken] = .init(
                    keyType: types.key,
                    valueType: types.value,
                    dictionary: dictionary,
                    indexSlot: slot
                )

            case .dictionaryIteratorNext:
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.Iterator.next has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(genericArguments)
                let resultType = Bytecode.ValueType.optional(
                    .tuple([types.key, types.value])
                )
                guard stackType(at: arguments[0]) == resultType,
                      let state = dictionaryIteratorStates[addressBase(arguments[1])],
                      state.keyType == types.key,
                      state.valueType == types.value
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.Iterator.next types do not match"
                    )
                }
                let result = try allocate(type: resultType)
                current!.instructions.append(
                    .dictionaryNext(
                        result: result,
                        dictionary: state.dictionary,
                        indexSlot: state.indexSlot
                    )
                )
                assignStackValue(result, at: arguments[0])
                voidValues.insert(resultToken)

            case .allocateUninitializedArray:
                guard arguments.count == 1,
                      !genericArguments.isEmpty,
                      let rawCount = wordLiterals[arguments[0]],
                      let count = Int(exactly: rawCount),
                      pendingArrayLiterals[resultToken] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array literal allocation has unsupported arguments"
                    )
                }
                let element = try parseType(genericArguments)
                guard !element.requiresLinearOwnership else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Array literal with linearly owned element \(element)"
                    )
                }
                pendingArrayLiterals[resultToken] = .init(
                    elementType: element,
                    count: count
                )

            case .finalizeUninitializedArray:
                guard arguments.count == 1,
                      !genericArguments.isEmpty,
                      let allocation = arrayLiteralAllocationByValue[arguments[0]],
                      let pending = pendingArrayLiterals[allocation]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array literal finalization has unsupported arguments"
                    )
                }
                let element = try parseType(genericArguments)
                guard element == pending.elementType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array literal finalization is incomplete or has a mismatched element type"
                    )
                }
                let elements = try materializeArrayLiteralElements(pending)
                let result = try allocate(type: .array(element))
                values[resultToken] = result
                current!.instructions.append(
                    .makeArray(
                        result: result,
                        elements: elements
                    )
                )
                pendingArrayLiterals.removeValue(forKey: allocation)
            }
        }

        for (lineIndex, rawLine) in rawLines.enumerated() {
            let sourceLine = lineIndex + 1
            let line = stripSILComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  !line.hasPrefix("["),
                  !line.hasPrefix("debug_value"),
                  !line.hasPrefix("debug_step"),
                  !line.hasPrefix("end_borrow"),
                  !line.hasPrefix("fix_lifetime")
            else { continue }

            if let block = try parseBlockHeader(line, allocate: allocate) {
                finishCurrent()
                var loweredBlock = block.block
                if let implicit = implicitStackValues[block.block.id] {
                    loweredBlock.parameters.append(contentsOf: implicit.map(\.register))
                    for item in implicit {
                        stackAddressValues[addressBase(item.address)] = item.register
                        values[item.address] = item.register
                    }
                }
                current = loweredBlock
                for (silValue, register) in block.parameters { values[silValue] = register }
                if entryBlock == nil {
                    entryBlock = loweredBlock.id
                    parameterRegisters = loweredBlock.parameters
                    guard parameterRegisters.count == signature.parameters.count else {
                        throw CanonicalSIL.LoweringError.malformedSIL("entry parameter count does not match function type")
                    }
                    for (register, expected) in zip(parameterRegisters, signature.parameters)
                    where registerTypes[Int(register.rawValue)] != expected {
                        throw CanonicalSIL.LoweringError.malformedSIL("entry parameter type does not match function type")
                    }
                    for ((parameter, convention), type) in zip(
                        zip(block.parameters, signature.parameterConventions),
                        signature.parameters
                    ) where convention == .inout {
                        guard case let .address(pointee) = type else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "inout parameter does not have an address type"
                            )
                        }
                        runtimeAddressValues[parameter.0] = parameter.1
                        runtimeAddressPointees[parameter.0] = pointee
                        scopedRuntimeAddresses.insert(parameter.0)
                        inoutParameterAddressBases.insert(parameter.0)
                    }
                }
                continue
            }
            guard current != nil else { continue }

            if line == "unreachable" {
                current!.instructions.append(.trap(.explicit("Swift unreachable")))
                continue
            }

            if let literal = match(
                line,
                pattern: #"^(%[0-9]+) = string_literal utf8 \"(.*)\"$"#
            ) {
                stringLiterals[literal[0]] = try decodeSILUTF8Literal(literal[1])
                continue
            }

            if let literal = match(
                line,
                pattern: #"^(%[0-9]+) = integer_literal \$Builtin\.Word, ([0-9]+)$"#
            ) {
                guard let value = UInt64(literal[1]) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Builtin.Word literal is outside UInt64"
                    )
                }
                wordLiterals[literal[0]] = value
                continue
            }

            if let metatype = match(
                line,
                pattern: #"^(%[0-9]+) = metatype \$@thin (?:Swift\.)?String\.Type$"#
            ) {
                metatypeValues.insert(metatype[0])
                continue
            }

            if let metatype = match(
                line,
                pattern: #"^(%[0-9]+) = metatype \$@thin (?:Swift\.)?DefaultStringInterpolation\.Type$"#
            ) {
                stringInterpolationMetatypes.insert(metatype[0])
                continue
            }

            if let metatype = match(
                line,
                pattern: #"^(%[0-9]+) = metatype \$@thin (?:Swift\.)?Dictionary<(.+)>\.Type$"#
            ) {
                let types = try parseDictionaryGenericArguments(metatype[1])
                dictionaryMetatypeValues[metatype[0]] = (types.key, types.value)
                continue
            }

            if let metatype = match(
                line,
                pattern: #"^(%[0-9]+) = metatype \$@thin (.+)\.Type$"#
            ), let key = typeEnvironment.localKey(for: metatype[1]) {
                localMetatypeValues[metatype[0]] = key
                continue
            }

            if let stack = match(
                line,
                pattern: #"^(%[0-9]+) = alloc_stack(?: \[[^\]]+\])* \$(.+?)(?:, (?:var|let),.*)?$"#
            ) {
                if stack[1] == "DefaultStringInterpolation"
                    || stack[1] == "Swift.DefaultStringInterpolation" {
                    pendingStringInterpolationAddresses.insert(stack[0])
                    continue
                }
                if let element = try arrayIteratorElementType(stack[1]) {
                    pendingArrayIteratorTypes[stack[0]] = element
                    continue
                }
                if let types = try dictionaryIteratorTypes(stack[1]) {
                    pendingDictionaryIteratorTypes[stack[0]] = (types.key, types.value)
                    continue
                }
                let type = try parseType(stack[1])
                stackAddressTypes[stack[0]] = type
                if usesRuntimeAddresses {
                    let slot = try allocateStackSlot(type: type)
                    let address = try allocate(type: .address(type))
                    runtimeStackSlots[stack[0]] = slot
                    runtimeAddressValues[stack[0]] = address
                    runtimeAddressPointees[stack[0]] = type
                    values[stack[0]] = address
                    current!.instructions.append(.stackAddress(result: address, slot: slot))
                }
                continue
            }

            if let borrow = match(
                line,
                pattern: #"^(%[0-9]+) = store_borrow (%[0-9]+) to (%[0-9]+)$"#
            ) {
                let value = try resolve(borrow[1], line: sourceLine)
                guard stackType(at: borrow[2]) == registerTypes[Int(value.rawValue)] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "store_borrow value does not match its stack address"
                    )
                }
                borrowedAddressValues[borrow[0]] = value
                values[borrow[0]] = value
                continue
            }

            if let borrow = match(
                line,
                pattern: #"^(%[0-9]+) = load_borrow (%[0-9]+)$"#
            ) {
                guard let value = borrowedAddressValues[borrow[1]]
                    ?? stackValue(at: borrow[1])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "load_borrow references an unsupported address"
                    )
                }
                values[borrow[0]] = value
                continue
            }

            if let access = match(
                line,
                pattern: #"^(%[0-9]+) = begin_access \[(read|modify)\] \[(?:static|dynamic)\] (%[0-9]+)$"#
            ) {
                let source = access[2]
                let base = addressBase(source)
                if let sourceAddress = runtimeAddress(at: source),
                   let pointee = stackType(at: source) {
                    if isScopedRuntimeAddress(source),
                       inoutParameterAddressBases.contains(base) {
                        // An inout parameter already carries its caller-owned access
                        // scope. Canonical SIL may spell a lexical reborrow around it.
                        addressAliases[access[0]] = base
                        runtimeAddressValues[access[0]] = sourceAddress
                        runtimeAddressPointees[access[0]] = pointee
                        scopedRuntimeAddresses.insert(access[0])
                        passthroughRuntimeAccesses.insert(access[0])
                        values[access[0]] = sourceAddress
                        continue
                    }
                    let result = try allocate(type: .address(pointee))
                    let kind: Bytecode.AccessKind = access[1] == "modify" ? .modify : .read
                    current!.instructions.append(
                        .beginAccess(result: result, address: sourceAddress, kind: kind)
                    )
                    addressAliases[access[0]] = base
                    runtimeAddressValues[access[0]] = result
                    runtimeAddressPointees[access[0]] = pointee
                    scopedRuntimeAddresses.insert(access[0])
                    values[access[0]] = result
                    continue
                }
                guard stackAddressTypes[base] != nil
                        || pendingArrayIteratorTypes[base] != nil
                        || pendingDictionaryIteratorTypes[base] != nil
                        || pendingStringInterpolationAddresses.contains(base)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "begin_access references an unsupported address"
                    )
                }
                addressAliases[access[0]] = base
                continue
            }

            if let access = match(line, pattern: #"^end_access (%[0-9]+)$"#) {
                if passthroughRuntimeAccesses.remove(access[0]) != nil {
                    scopedRuntimeAddresses.remove(access[0])
                    runtimeAddressValues.removeValue(forKey: access[0])
                    runtimeAddressPointees.removeValue(forKey: access[0])
                    values.removeValue(forKey: access[0])
                    addressAliases.removeValue(forKey: access[0])
                    continue
                }
                if scopedRuntimeAddresses.remove(access[0]) != nil,
                   let register = runtimeAddressValues.removeValue(forKey: access[0]) {
                    current!.instructions.append(.endAccess(register))
                    runtimeAddressPointees.removeValue(forKey: access[0])
                    values.removeValue(forKey: access[0])
                    addressAliases.removeValue(forKey: access[0])
                    continue
                }
                guard addressAliases.removeValue(forKey: access[0]) != nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "end_access references an unsupported access"
                    )
                }
                continue
            }

            if let deallocation = match(line, pattern: #"^dealloc_stack (%[0-9]+)$"#) {
                let address = addressBase(deallocation[0])
                if onStackClosureValues.remove(address) != nil {
                    // SIL models an on-stack partial_apply as storage. The VM owns the
                    // corresponding closure value for the lifetime of its frame.
                    continue
                }
                if catchScratchAddresses.contains(address) { continue }
                if pendingStringInterpolationAddresses.remove(address) != nil {
                    guard stringInterpolationAddressValues.removeValue(forKey: address) == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "String interpolation storage is deallocated before take"
                        )
                    }
                    continue
                }
                if pendingArrayIteratorTypes.removeValue(forKey: address) != nil {
                    guard arrayIteratorStates[address] == nil,
                          destroyedArrayIterators.remove(address) != nil
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array iterator is deallocated before destroy_addr"
                        )
                    }
                    continue
                }
                if pendingDictionaryIteratorTypes.removeValue(forKey: address) != nil {
                    guard dictionaryIteratorStates[address] == nil,
                          destroyedDictionaryIterators.remove(address) != nil
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Dictionary iterator is deallocated before destroy_addr"
                        )
                    }
                    continue
                }
                if let slot = runtimeStackSlots.removeValue(forKey: address) {
                    if stackAddressValues.removeValue(forKey: address) != nil {
                        current!.instructions.append(.destroyStack(slot))
                    }
                    runtimeAddressValues.removeValue(forKey: address)
                    runtimeAddressPointees.removeValue(forKey: address)
                    values.removeValue(forKey: address)
                    guard stackAddressTypes.removeValue(forKey: address) != nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "runtime stack address lost its declared type"
                        )
                    }
                    continue
                }
                guard stackAddressTypes.removeValue(forKey: address) != nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "dealloc_stack references an unsupported address"
                    )
                }
                stackAddressValues.removeValue(forKey: address)
                continue
            }

            if let literal = match(line, pattern: #"^(%[0-9]+) = integer_literal \$Builtin\.Int(1|8|16|32|64), (-?[0-9]+)$"#) {
                guard let width = UInt16(literal[1]),
                      let value = Int64(literal[2])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer literal is outside its supported representation"
                    )
                }
                integerLiterals[literal[0]] = (width, value)
                if width == 1 {
                    let register = try allocate(type: .bool)
                    values[literal[0]] = register
                    let bool = value != 0
                    boolLiterals[literal[0]] = bool
                    current!.instructions.append(.constantBool(result: register, value: bool))
                } else {
                    let register = try allocate(type: .integer(bitWidth: width, signed: true))
                    values[literal[0]] = register
                    current!.instructions.append(.constantInteger(result: register, value: value))
                }
                continue
            }

            if let literal = match(
                line,
                pattern: #"^(%[0-9]+) = float_literal \$Builtin\.FPIEEE(32|64), 0x([0-9A-Fa-f]+)$"#
            ) {
                guard let width = UInt16(literal[1]) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating-point literal has an invalid bit width"
                    )
                }
                let expectedDigits = width == 32 ? 8 : 16
                guard literal[2].count == expectedDigits else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Float\(width) literal must contain \(expectedDigits) hexadecimal digits"
                    )
                }
                let value: Double
                if width == 32, let bits = UInt32(literal[2], radix: 16) {
                    value = Double(Float(bitPattern: bits))
                } else if width == 64, let bits = UInt64(literal[2], radix: 16) {
                    value = Double(bitPattern: bits)
                } else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating-point literal has an invalid bit pattern"
                    )
                }
                let result = try allocate(type: .float(bitWidth: width))
                values[literal[0]] = result
                current!.instructions.append(.constantFloat(result: result, value: value))
                continue
            }

            if let expectation = match(
                line,
                pattern: #"^(%[0-9]+) = builtin "int_expect_Int1"\((%[0-9]+), %[0-9]+\).*$"#
            ) {
                let condition = try resolve(expectation[1], line: sourceLine)
                guard registerTypes[Int(condition.rawValue)] == .bool else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "int_expect_Int1 operand is not Bool"
                    )
                }
                values[expectation[0]] = condition
                continue
            }

            if let comparison = parseIntegerComparison(line) {
                let unresolvedLHS = try resolve(comparison.lhs, line: sourceLine)
                let unresolvedRHS = try resolve(comparison.rhs, line: sourceLine)
                guard let operandType = integerOperandType(
                    bitWidth: comparison.bitWidth,
                    signedness: comparison.signedness,
                    lhsToken: comparison.lhs,
                    lhs: unresolvedLHS,
                    rhsToken: comparison.rhs,
                    rhs: unresolvedRHS
                ), comparison.accepts(operandType)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer comparison operands do not match its builtin"
                    )
                }
                let lhs = try materializeIntegerOperand(
                    comparison.lhs,
                    expected: operandType,
                    line: sourceLine
                )
                let rhs = try materializeIntegerOperand(
                    comparison.rhs,
                    expected: operandType,
                    line: sourceLine
                )
                let result = try allocate(type: .bool)
                values[comparison.result] = result
                current!.instructions.append(
                    .compare(result: result, predicate: comparison.predicate, lhs: lhs, rhs: rhs)
                )
                continue
            }

            if let boolean = match(
                line,
                pattern: #"^(%[0-9]+) = builtin "(and|or|xor)_Int1"\((%[0-9]+), (%[0-9]+)\).*$"#
            ) {
                let lhs = try resolve(boolean[2], line: sourceLine)
                let rhs = try resolve(boolean[3], line: sourceLine)
                guard registerTypes[Int(lhs.rawValue)] == .bool,
                      registerTypes[Int(rhs.rawValue)] == .bool
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Bool binary operands must both be Bool"
                    )
                }
                let result = try allocate(type: .bool)
                values[boolean[0]] = result
                let operation: Bytecode.BooleanBinaryOperation
                switch boolean[1] {
                case "and": operation = .and
                case "or": operation = .or
                default: operation = .xor
                }
                current!.instructions.append(
                    .booleanBinary(
                        result: result,
                        operation: operation,
                        lhs: lhs,
                        rhs: rhs
                    )
                )
                continue
            }

            if let binary = parseFloatingBinary(line) {
                let lhs = try resolve(binary.lhs, line: sourceLine)
                let rhs = try resolve(binary.rhs, line: sourceLine)
                let expected = Bytecode.ValueType.float(bitWidth: binary.bitWidth)
                guard registerTypes[Int(lhs.rawValue)] == expected,
                      registerTypes[Int(rhs.rawValue)] == expected
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating binary operands do not match its builtin"
                    )
                }
                let result = try allocate(type: expected)
                values[binary.result] = result
                current!.instructions.append(
                    .floatingBinary(
                        result: result,
                        operation: binary.operation,
                        lhs: lhs,
                        rhs: rhs
                    )
                )
                continue
            }

            if let unary = match(
                line,
                pattern: #"^(%[0-9]+) = builtin "fneg_FPIEEE(32|64)"\((%[0-9]+)\).*$"#
            ) {
                let operand = try resolve(unary[2], line: sourceLine)
                guard let bitWidth = UInt16(unary[1]) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating unary builtin has an invalid bit width"
                    )
                }
                let type = Bytecode.ValueType.float(bitWidth: bitWidth)
                guard registerTypes[Int(operand.rawValue)] == type else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating unary operand does not match its builtin"
                    )
                }
                let result = try allocate(type: type)
                values[unary[0]] = result
                current!.instructions.append(
                    .floatingUnary(result: result, operation: .negate, operand: operand)
                )
                continue
            }

            if let comparison = parseFloatingComparison(line) {
                let lhs = try resolve(comparison.lhs, line: sourceLine)
                let rhs = try resolve(comparison.rhs, line: sourceLine)
                let expected = Bytecode.ValueType.float(bitWidth: comparison.bitWidth)
                guard registerTypes[Int(lhs.rawValue)] == expected,
                      registerTypes[Int(rhs.rawValue)] == expected
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating comparison operands do not match its builtin"
                    )
                }
                let result = try allocate(type: .bool)
                values[comparison.result] = result
                current!.instructions.append(
                    .compare(
                        result: result,
                        predicate: comparison.predicate,
                        lhs: lhs,
                        rhs: rhs
                    )
                )
                continue
            }

            if let binary = parseUncheckedIntegerBinary(line) {
                let unresolvedLHS = try resolve(binary.lhs, line: sourceLine)
                let unresolvedRHS = try resolve(binary.rhs, line: sourceLine)
                guard let operandType = integerOperandType(
                    bitWidth: binary.bitWidth,
                    signedness: binary.signedness,
                    lhsToken: binary.lhs,
                    lhs: unresolvedLHS,
                    rhsToken: binary.rhs,
                    rhs: unresolvedRHS
                ), binary.accepts(operandType)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer binary operands do not match its builtin"
                    )
                }
                let lhs = try materializeIntegerOperand(
                    binary.lhs,
                    expected: operandType,
                    line: sourceLine
                )
                let rhs = try materializeIntegerOperand(
                    binary.rhs,
                    expected: operandType,
                    line: sourceLine
                )
                let result = try allocate(type: operandType)
                let overflow = try allocate(type: .bool)
                values[binary.result] = result
                current!.instructions.append(
                    .checkedBinary(
                        result: result,
                        overflow: overflow,
                        operation: binary.operation,
                        lhs: lhs,
                        rhs: rhs
                    )
                )
                continue
            }

            if let conversion = match(
                line,
                pattern: #"^(%[0-9]+) = builtin \"(truncOrBitCast|sextOrBitCast|sext|zextOrBitCast|zext)_Int(8|16|32|64)_Int(8|16|32|64)\"\((%[0-9]+)\).*$"#
            ) {
                guard let sourceWidth = UInt16(conversion[2]),
                      let targetWidth = UInt16(conversion[3])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer conversion has an invalid bit width"
                    )
                }
                let value = try resolve(conversion[4], line: sourceLine)
                guard case let .integer(actualWidth, actualSigned)
                    = registerTypes[Int(value.rawValue)],
                      actualWidth == sourceWidth
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer conversion operand does not match its builtin"
                    )
                }
                let operation: Bytecode.IntegerConversionOperation
                switch conversion[1] {
                case "truncOrBitCast":
                    guard targetWidth <= sourceWidth else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "truncOrBitCast unexpectedly widens its operand"
                        )
                    }
                    operation = targetWidth == sourceWidth ? .reinterpret : .truncate
                case "sextOrBitCast", "sext":
                    guard actualSigned, targetWidth >= sourceWidth else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "sign extension has an unsigned or wider operand"
                        )
                    }
                    operation = targetWidth == sourceWidth ? .reinterpret : .signExtend
                default:
                    guard !actualSigned, targetWidth >= sourceWidth else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "zero extension has a signed or wider operand"
                        )
                    }
                    operation = targetWidth == sourceWidth ? .reinterpret : .zeroExtend
                }
                // Builtin.IntN has no signedness. Use a signed provisional
                // register and reinterpret only when the enclosing Swift
                // nominal wrapper is UIntN.
                let result = try allocate(
                    type: .integer(bitWidth: targetWidth, signed: true)
                )
                values[conversion[0]] = result
                integerConversionResults.insert(conversion[0])
                current!.instructions.append(
                    .integerConvert(result: result, operation: operation, value: value)
                )
                continue
            }

            if let conversion = match(
                line,
                pattern: #"^(%[0-9]+) = builtin \"(fptrunc|fpext)_FPIEEE(32|64)_FPIEEE(32|64)\"\((%[0-9]+)\).*$"#
            ) {
                guard let sourceWidth = UInt16(conversion[2]),
                      let targetWidth = UInt16(conversion[3])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating conversion has an invalid bit width"
                    )
                }
                let value = try resolve(conversion[4], line: sourceLine)
                guard registerTypes[Int(value.rawValue)]
                        == .float(bitWidth: sourceWidth),
                      (conversion[1] == "fptrunc" && sourceWidth == 64 && targetWidth == 32)
                        || (conversion[1] == "fpext" && sourceWidth == 32 && targetWidth == 64)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating conversion operand does not match its builtin"
                    )
                }
                let result = try allocate(type: .float(bitWidth: targetWidth))
                values[conversion[0]] = result
                current!.instructions.append(
                    .floatingConvert(
                        result: result,
                        operation: conversion[1] == "fptrunc" ? .truncate : .extend,
                        value: value
                    )
                )
                continue
            }

            if let conversion = match(
                line,
                pattern: #"^(%[0-9]+) = builtin \"([su])itofp_Int(8|16|32|64)_FPIEEE(32|64)\"\((%[0-9]+)\).*$"#
            ) {
                guard let sourceWidth = UInt16(conversion[2]),
                      let targetWidth = UInt16(conversion[3])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer-to-float conversion has an invalid bit width"
                    )
                }
                let value = try resolve(conversion[4], line: sourceLine)
                let signed = conversion[1] == "s"
                guard registerTypes[Int(value.rawValue)]
                        == .integer(bitWidth: sourceWidth, signed: signed)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer-to-float operand does not match its builtin"
                    )
                }
                let result = try allocate(type: .float(bitWidth: targetWidth))
                values[conversion[0]] = result
                current!.instructions.append(
                    .floatingConvert(
                        result: result,
                        operation: signed ? .signedIntegerToFloat : .unsignedIntegerToFloat,
                        value: value
                    )
                )
                continue
            }

            if let projection = match(
                line,
                pattern: #"^(%[0-9]+) = struct_element_addr (%[0-9]+), #(.+)\.([^.]+)$"#
            ) {
                guard let base = runtimeAddress(at: projection[1]),
                      let basePointee = stackType(at: projection[1])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "struct_element_addr references an unsupported address"
                    )
                }
                let scalarWrappers: Set<String> = [
                    "Int", "Int8", "Int16", "Int32", "Int64",
                    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
                    "Bool", "Float", "Double",
                ]
                if scalarWrappers.contains(projection[2]), projection[3] == "_value" {
                    runtimeAddressValues[projection[0]] = base
                    runtimeAddressPointees[projection[0]] = basePointee
                    addressAliases[projection[0]] = addressBase(projection[1])
                    if isScopedRuntimeAddress(projection[1]) {
                        scopedRuntimeAddresses.insert(projection[0])
                    }
                    values[projection[0]] = base
                    continue
                }
                guard case let .local(key) = basePointee else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "struct_element_addr base is not a local struct"
                    )
                }
                let index = try typeEnvironment.structFieldIndex(
                    type: key,
                    name: projection[3]
                )
                let fields = try typeEnvironment.structFields(for: key)
                guard let fieldIndex = UInt32(exactly: index) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local struct field index exceeds UInt32"
                    )
                }
                let pointee = fields[index].type
                let result = try allocate(type: .address(pointee))
                current!.instructions.append(
                    .projectStructAddress(result: result, base: base, fieldIndex: fieldIndex)
                )
                runtimeAddressValues[projection[0]] = result
                runtimeAddressPointees[projection[0]] = pointee
                addressAliases[projection[0]] = addressBase(projection[1])
                if isScopedRuntimeAddress(projection[1]) {
                    scopedRuntimeAddresses.insert(projection[0])
                }
                values[projection[0]] = result
                continue
            }

            if let alias = match(
                line,
                pattern: #"^(%[0-9]+) = struct_extract (%[0-9]+), #(?:Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Bool|Float|Double)\._value$"#
            ) {
                values[alias[0]] = try resolve(alias[1], line: sourceLine)
                continue
            }
            if let alias = match(
                line,
                pattern: #"^(%[0-9]+) = struct \$(Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Bool|Float|Double) \((%[0-9]+)\)$"#
            ) {
                let operand = try resolve(alias[2], line: sourceLine)
                if let unsignedWidth = unsignedIntegerWidth(of: alias[1]) {
                    let expected = Bytecode.ValueType.integer(
                        bitWidth: unsignedWidth,
                        signed: false
                    )
                    if integerConversionResults.contains(alias[2]),
                       registerTypes[Int(operand.rawValue)]
                        == .integer(bitWidth: unsignedWidth, signed: true) {
                        let result = try allocate(type: expected)
                        current!.instructions.append(
                            .integerConvert(
                                result: result,
                                operation: .reinterpret,
                                value: operand
                            )
                        )
                        values[alias[0]] = result
                    } else {
                        values[alias[0]] = try materializeIntegerOperand(
                            alias[2],
                            expected: expected,
                            line: sourceLine
                        )
                    }
                } else {
                    values[alias[0]] = operand
                }
                continue
            }

            if let construction = match(
                line,
                pattern: #"^(%[0-9]+) = struct \$(.+) \((.*)\)$"#
            ), let key = typeEnvironment.localKey(for: construction[1]) {
                let fields = try typeEnvironment.structFields(for: key)
                let operands = try parseApplyValueTokens(
                    construction[2],
                    line: sourceLine
                )
                guard operands.count == fields.count else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local struct \(key) field count does not match its declaration"
                    )
                }
                let registers = try operands.map {
                    try resolve($0, line: sourceLine)
                }
                guard zip(registers, fields).allSatisfy({ register, field in
                    registerTypes[Int(register.rawValue)] == field.type
                }) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local struct \(key) field types do not match its declaration"
                    )
                }
                let result = try allocate(type: .local(key))
                values[construction[0]] = result
                current!.instructions.append(
                    .makeStruct(result: result, fields: registers)
                )
                continue
            }

            if let extraction = match(
                line,
                pattern: #"^(%[0-9]+) = struct_extract (%[0-9]+), #(.+)\.([^.]+)$"#
            ), let key = typeEnvironment.localKey(for: extraction[2]) {
                let structure = try resolve(extraction[1], line: sourceLine)
                guard registerTypes[Int(structure.rawValue)] == .local(key) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local struct_extract operand does not match \(key)"
                    )
                }
                let fields = try typeEnvironment.structFields(for: key)
                let index = try typeEnvironment.structFieldIndex(
                    type: key,
                    name: extraction[3]
                )
                guard let fieldIndex = UInt32(exactly: index) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local struct \(key) field index exceeds UInt32"
                    )
                }
                let result = try allocate(type: fields[index].type)
                values[extraction[0]] = result
                current!.instructions.append(
                    .structExtract(
                        result: result,
                        structure: structure,
                        fieldIndex: fieldIndex
                    )
                )
                continue
            }

            if let destructure = match(
                line,
                pattern: #"^\((%[0-9]+(?:, %[0-9]+)*)\) = destructure_struct (%[0-9]+)$"#
            ) {
                let structure = try resolve(destructure[1], line: sourceLine)
                guard case let .local(key) = registerTypes[Int(structure.rawValue)] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "destructure_struct operand is not a local struct"
                    )
                }
                let fields = try typeEnvironment.structFields(for: key)
                let names = destructure[0].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard names.count == fields.count else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "destructure_struct result count does not match \(key)"
                    )
                }
                // SIL transfers every stored field in declaration order. HLBC uses
                // the same stable indices and keeps native values out of local types.
                for (index, pair) in zip(fields.indices, zip(names, fields)) {
                    guard let fieldIndex = UInt32(exactly: index) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "local struct \(key) field index exceeds UInt32"
                        )
                    }
                    let result = try allocate(type: pair.1.type)
                    values[pair.0] = result
                    current!.instructions.append(
                        .structExtract(
                            result: result,
                            structure: structure,
                            fieldIndex: fieldIndex
                        )
                    )
                }
                continue
            }

            if let reference = match(
                line,
                pattern: #"^(%[0-9]+) = function_ref @([^\s:]+) : \$(.+)$"#
            ) {
                if let intrinsic = SwiftCoreIntrinsic(mangledName: reference[1]) {
                    swiftCoreReferences[reference[0]] = intrinsic
                    continue
                }
                if let key = typeEnvironment.trivialStructFactory(reference[1]) {
                    localFactoryReferences[reference[0]] = key
                    continue
                }
                guard let binding = directCalls.binding(for: reference[1]) else {
                    if let unavailable = directCalls.unavailableCall(for: reference[1]) {
                        throw CanonicalSIL.LoweringError.unavailableNativeImport(
                            line: sourceLine,
                            mangledName: reference[1],
                            canonicalCallee: unavailable.canonicalCallee,
                            reason: unavailable.reason
                        )
                    }
                    throw CanonicalSIL.LoweringError.unboundCallee(
                        line: sourceLine,
                        mangledName: reference[1]
                    )
                }
                let callee = try parseFunctionType(reference[2])
                guard callee.parameters == binding.parameterTypes,
                      callee.parameterConventions == binding.parameterConventions,
                      callee.result == binding.resultType,
                      callee.effects.mayThrow == binding.effects.mayThrow,
                      callee.effects.isAsync == binding.effects.isAsync
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: reference[1]
                    )
                }
                functionReferences[reference[0]] = binding
                continue
            }

            if let conversion = match(
                line,
                pattern: #"^(%[0-9]+) = thin_to_thick_function (%[0-9]+) to \$(.+)$"#
            ) {
                guard let binding = functionReferences[conversion[1]],
                      case let .function(functionID) = binding.target,
                      !binding.effects.mayThrow,
                      !binding.effects.isAsync,
                      case let .closure(signature) = try parseType(conversion[2]),
                      signature.parameters == binding.parameterTypes,
                      signature.result == binding.resultType,
                      signature.effects == binding.effects
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let result = try allocate(type: .closure(signature))
                values[conversion[0]] = result
                current!.instructions.append(
                    .makeClosure(result: result, function: functionID, captures: [])
                )
                continue
            }

            if let closure = match(
                line,
                pattern: #"^(%[0-9]+) = partial_apply(?: \[[^\]]+\])* (%[0-9]+)\((.*)\) : \$(.+)$"#
            ) {
                guard let binding = functionReferences[closure[1]],
                      case let .function(functionID) = binding.target,
                      !binding.effects.mayThrow,
                      !binding.effects.isAsync
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let physicalType = try parseFunctionType(closure[3])
                guard physicalType.parameters == binding.parameterTypes,
                      physicalType.parameterConventions == binding.parameterConventions,
                      physicalType.result == binding.resultType,
                      physicalType.effects.mayThrow == binding.effects.mayThrow,
                      physicalType.effects.isAsync == binding.effects.isAsync
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                let captureTokens = try parseApplyValueTokens(
                    closure[2],
                    line: sourceLine
                )
                let captures = try captureTokens.map {
                    try resolve($0, line: sourceLine)
                }
                guard captures.count <= binding.parameterTypes.count else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "partial_apply captures more values than its callee accepts"
                    )
                }
                let invocationCount = binding.parameterTypes.count - captures.count
                let invocationTypes = Array(binding.parameterTypes.prefix(invocationCount))
                let captureTypes = captures.map { registerTypes[Int($0.rawValue)] }
                guard captureTypes == Array(binding.parameterTypes.suffix(captures.count)) else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                let signature = Bytecode.ClosureSignature(
                    parameters: invocationTypes,
                    result: binding.resultType,
                    effects: binding.effects
                )
                let result = try allocate(type: .closure(signature))
                values[closure[0]] = result
                if line.contains("[on_stack]") {
                    onStackClosureValues.insert(closure[0])
                }
                current!.instructions.append(
                    .makeClosure(
                        result: result,
                        function: functionID,
                        captures: captures
                    )
                )
                continue
            }

            if let dependence = match(
                line,
                pattern: #"^(%[0-9]+) = mark_dependence (%[0-9]+) on (%[0-9]+)$"#
            ) {
                let source = try resolve(dependence[1], line: sourceLine)
                guard case .closure = registerTypes[Int(source.rawValue)] else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                // Captures are copied into the VM closure context. Preserve the
                // SIL value alias while validating that its dependency is live.
                _ = try resolve(dependence[2], line: sourceLine)
                values[dependence[0]] = source
                continue
            }

            if let conversion = match(
                line,
                pattern: #"^(%[0-9]+) = convert_escape_to_noescape (%[0-9]+) to \$(.+)$"#
            ) {
                let source = try resolve(conversion[1], line: sourceLine)
                guard case let .closure(actual) = registerTypes[Int(source.rawValue)],
                      case let .closure(expected) = try parseType(conversion[2]),
                      actual == expected
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "convert_escape_to_noescape changes the closure signature"
                    )
                }
                values[conversion[0]] = source
                continue
            }

            if let borrowed = match(line, pattern: #"^(%[0-9]+) = begin_borrow (%[0-9]+)$"#) {
                if let allocation = arrayLiteralAllocationByValue[borrowed[1]] {
                    arrayLiteralAllocationByValue[borrowed[0]] = allocation
                    arrayLiteralStorageTokens[borrowed[0]] = allocation
                } else if let reference = functionReferences[borrowed[1]] {
                    functionReferences[borrowed[0]] = reference
                } else if let reference = swiftCoreReferences[borrowed[1]] {
                    swiftCoreReferences[borrowed[0]] = reference
                } else if let key = localFactoryReferences[borrowed[1]] {
                    localFactoryReferences[borrowed[0]] = key
                } else {
                    values[borrowed[0]] = try resolve(borrowed[1], line: sourceLine)
                }
                continue
            }

            if let call = match(
                line,
                pattern: #"^\((%[0-9]+), (%[0-9]+)\) = begin_apply (%[0-9]+)(?:<(.+)>)?\((.*)\) : \$(.+)$"#
            ) {
                guard swiftCoreReferences[call[2]] == .arraySubscriptModify else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let arguments = splitTopLevel(call[4]).map { argument in
                    String(argument.split(separator: ":", maxSplits: 1)[0])
                        .trimmingCharacters(in: .whitespaces)
                }
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.subscript.modify has unsupported arguments"
                    )
                }
                let element = try parseType(call[3])
                let index = try resolve(arguments[0], line: sourceLine)
                let arrayAddress = addressBase(arguments[1])
                guard registerTypes[Int(index.rawValue)] == .int64,
                      stackType(at: arguments[1]) == .array(element),
                      let array = stackValue(at: arguments[1]),
                      registerTypes[Int(array.rawValue)] == .array(element),
                      !element.requiresLinearOwnership,
                      arrayElementMutations[call[0]] == nil,
                      arrayMutationYieldByToken[call[1]] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.subscript.modify types or access scope do not match"
                    )
                }
                arrayElementMutations[call[0]] = .init(
                    arrayAddress: arrayAddress,
                    array: array,
                    index: index,
                    elementType: element
                )
                arrayMutationYieldByToken[call[1]] = call[0]
                continue
            }

            if let apply = match(
                line,
                pattern: #"^(?:(%[0-9]+) = )?end_apply (%[0-9]+) as \$\(\)$"#
            ) {
                guard let yield = arrayMutationYieldByToken.removeValue(
                    forKey: apply[1]
                ), let mutation = arrayElementMutations.removeValue(forKey: yield),
                   mutation.didStore
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.subscript.modify ended without exactly one store"
                    )
                }
                if !apply[0].isEmpty { voidValues.insert(apply[0]) }
                continue
            }

            if let call = match(
                line,
                pattern: #"^try_apply (%[0-9]+)(?:<(.+)>)?\((.*)\) : \$(.+), normal bb([0-9]+), error bb([0-9]+)$"#
            ) {
                guard swiftCoreReferences[call[0]] == nil,
                      let binding = functionReferences[call[0]],
                      binding.effects.mayThrow,
                      !binding.effects.isAsync
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let appliedType = try parseFunctionType(call[3])
                guard appliedType.parameters == binding.parameterTypes,
                      appliedType.parameterConventions == binding.parameterConventions,
                      appliedType.result == binding.resultType,
                      appliedType.effects.mayThrow,
                      !appliedType.effects.isAsync,
                      call[1].isEmpty
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                let prepared = try prepareDirectCallArguments(
                    call[2],
                    conventions: binding.parameterConventions,
                    line: sourceLine,
                    allowsSynthesizedAccess: false
                )
                let arguments = prepared.arguments
                guard arguments.map({ registerTypes[Int($0.rawValue)] }) == binding.parameterTypes else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                let normalTarget = try parseBlockID(call[4])
                let errorTarget = try parseBlockID(call[5])
                let instruction: Bytecode.Instruction = switch binding.target {
                case let .function(id):
                    .tryApply(
                        function: id,
                        arguments: arguments,
                        normalTarget: normalTarget,
                        errorTarget: errorTarget
                    )
                case let .entry(index):
                    .entryTryApply(
                        entry: index,
                        arguments: arguments,
                        normalTarget: normalTarget,
                        errorTarget: errorTarget
                    )
                case let .nativeImport(requirement):
                    .nativeTryApply(
                        importID: requirement.id,
                        arguments: arguments,
                        normalTarget: normalTarget,
                        errorTarget: errorTarget
                    )
                }
                current!.instructions.append(instruction)
                continue
            }

            if let call = match(
                line,
                pattern: #"^(?:(%[0-9]+) = )?apply (%[0-9]+)(?:<(.+)>)?\((.*)\) : \$(.+)$"#
            ) {
                if let closure = values[call[1]],
                   case let .closure(signature) = registerTypes[Int(closure.rawValue)] {
                    guard call[2].isEmpty else {
                        throw CanonicalSIL.LoweringError.unsupportedInstruction(
                            line: sourceLine,
                            text: "generic closure apply"
                        )
                    }
                    let appliedType = try parseFunctionType(call[4])
                    guard appliedType.parameters == signature.parameters,
                          appliedType.result == signature.result,
                          appliedType.effects.mayThrow == signature.effects.mayThrow,
                          appliedType.effects.isAsync == signature.effects.isAsync,
                          !signature.effects.isAsync
                    else {
                        throw CanonicalSIL.LoweringError.callSignatureMismatch(
                            line: sourceLine,
                            mangledName: "<closure>"
                        )
                    }
                    let argumentTokens = try parseApplyValueTokens(
                        call[3],
                        line: sourceLine
                    )
                    let arguments = try argumentTokens.map {
                        try resolve($0, line: sourceLine)
                    }
                    guard arguments.map({ registerTypes[Int($0.rawValue)] })
                            == signature.parameters
                    else {
                        throw CanonicalSIL.LoweringError.callSignatureMismatch(
                            line: sourceLine,
                            mangledName: "<closure>"
                        )
                    }
                    let result: Bytecode.Register?
                    if signature.result == .void {
                        result = nil
                        if !call[0].isEmpty { voidValues.insert(call[0]) }
                    } else {
                        guard !call[0].isEmpty else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "non-Void closure apply does not define a result"
                            )
                        }
                        let register = try allocate(type: signature.result)
                        values[call[0]] = register
                        result = register
                    }
                    current!.instructions.append(
                        .closureApply(
                            result: result,
                            closure: closure,
                            arguments: arguments
                        )
                    )
                    continue
                }
                if let key = localFactoryReferences[call[1]] {
                    guard call[2].isEmpty, !call[0].isEmpty else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "local struct initializer has unsupported generic arguments or result"
                        )
                    }
                    let fields = try typeEnvironment.structFields(for: key)
                    let argumentTokens = try parseApplyValueTokens(
                        call[3],
                        line: sourceLine
                    )
                    guard argumentTokens.count == fields.count + 1,
                          let metatypeToken = argumentTokens.last,
                          localMetatypeValues[metatypeToken] == key
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "local struct initializer arguments do not match \(key)"
                        )
                    }
                    let fieldTokens = argumentTokens.dropLast()
                    let fieldRegisters = try fieldTokens.map {
                        try resolve($0, line: sourceLine)
                    }
                    guard zip(fieldRegisters, fields).allSatisfy({ register, field in
                        registerTypes[Int(register.rawValue)] == field.type
                    }) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "local struct initializer field types do not match \(key)"
                        )
                    }
                    let result = try allocate(type: .local(key))
                    values[call[0]] = result
                    current!.instructions.append(
                        .makeStruct(result: result, fields: Array(fieldRegisters))
                    )
                    continue
                }
                if let intrinsic = swiftCoreReferences[call[1]] {
                    try lowerSwiftCoreIntrinsic(
                        intrinsic,
                        resultToken: call[0],
                        genericArguments: call[2],
                        argumentText: call[3],
                        line: sourceLine
                    )
                    continue
                }
                guard let binding = functionReferences[call[1]] else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let appliedType = try parseFunctionType(call[4])
                guard appliedType.parameters == binding.parameterTypes,
                      appliedType.parameterConventions == binding.parameterConventions,
                      appliedType.result == binding.resultType,
                      appliedType.effects.mayThrow == binding.effects.mayThrow,
                      appliedType.effects.isAsync == binding.effects.isAsync,
                      !binding.effects.isAsync
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                let prepared = try prepareDirectCallArguments(
                    call[3],
                    conventions: binding.parameterConventions,
                    line: sourceLine,
                    allowsSynthesizedAccess: true
                )
                let arguments = prepared.arguments
                guard arguments.map({ registerTypes[Int($0.rawValue)] }) == binding.parameterTypes else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                let result: Bytecode.Register?
                if binding.resultType == .void {
                    result = nil
                    if !call[0].isEmpty { voidValues.insert(call[0]) }
                } else {
                    guard !call[0].isEmpty else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "non-Void apply does not define a result"
                        )
                    }
                    let register = try allocate(type: binding.resultType)
                    values[call[0]] = register
                    result = register
                }
                let instruction: Bytecode.Instruction = switch binding.target {
                case let .function(id):
                    .apply(result: result, function: id, arguments: arguments)
                case let .entry(index):
                    .entryApply(result: result, entry: index, arguments: arguments)
                case let .nativeImport(requirement):
                    .nativeApply(result: result, importID: requirement.id, arguments: arguments)
                }
                current!.instructions.append(instruction)
                for access in prepared.accesses.reversed() {
                    current!.instructions.append(.endAccess(access))
                }
                continue
            }

            if let tuple = match(
                line,
                pattern: #"^\((%[0-9]+), (%[0-9]+)\) = destructure_tuple (%[0-9]+)$"#
            ), pendingArrayLiterals[tuple[2]] != nil {
                arrayLiteralAllocationByValue[tuple[0]] = tuple[2]
                arrayLiteralStorageTokens[tuple[1]] = tuple[2]
                continue
            }

            if let tuple = match(
                line,
                pattern: #"^\((%[0-9]+(?:, %[0-9]+)*)\) = destructure_tuple (%[0-9]+)$"#
            ) {
                let names = tuple[0].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let source = try resolve(tuple[1], line: sourceLine)
                guard case let .tuple(types) = registerTypes[Int(source.rawValue)],
                      names.count == types.count
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "destructure_tuple result count does not match its operand"
                    )
                }
                let results = try types.map { try allocate(type: $0) }
                for (name, result) in zip(names, results) { values[name] = result }
                current!.instructions.append(.unpackTuple(results: results, tuple: source))
                continue
            }

            if let projection = match(
                line,
                pattern: #"^(%[0-9]+) = struct_extract (%[0-9]+), #(?:Array\._buffer|_ArrayBuffer\._storage|_BridgeStorage\.rawValue)$"#
            ), let allocation = arrayLiteralStorageTokens[projection[1]]
                ?? arrayLiteralAllocationByValue[projection[1]] {
                arrayLiteralStorageTokens[projection[0]] = allocation
                continue
            }

            if let cast = match(
                line,
                pattern: #"^(%[0-9]+) = unchecked_ref_cast (%[0-9]+) to \$__ContiguousArrayStorageBase$"#
            ), let allocation = arrayLiteralStorageTokens[cast[1]] {
                arrayLiteralStorageTokens[cast[0]] = allocation
                continue
            }

            if let address = match(
                line,
                pattern: #"^(%[0-9]+) = ref_tail_addr (%[0-9]+), \$(.+)$"#
            ), let allocation = arrayLiteralStorageTokens[address[1]],
               let pending = pendingArrayLiterals[allocation] {
                guard try parseType(address[2]) == pending.elementType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array literal tail address has a mismatched element type"
                    )
                }
                arrayLiteralAddresses[address[0]] = .init(
                    allocation: allocation,
                    index: 0
                )
                continue
            }

            if let address = match(
                line,
                pattern: #"^(%[0-9]+) = index_addr (%[0-9]+), (%[0-9]+)$"#
            ), let base = arrayLiteralAddresses[address[1]],
               let rawIndex = wordLiterals[address[2]],
               let index = Int(exactly: rawIndex) {
                let resolvedIndex = base.index.addingReportingOverflow(index)
                guard !resolvedIndex.overflow else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array literal address index overflows Int"
                    )
                }
                arrayLiteralAddresses[address[0]] = .init(
                    allocation: base.allocation,
                    index: resolvedIndex.partialValue
                )
                continue
            }

            if let component = match(
                line,
                pattern: #"^(%[0-9]+) = tuple_element_addr (%[0-9]+), ([0-9]+)$"#
            ), let base = arrayLiteralAddresses[component[1]],
               let pending = pendingArrayLiterals[base.allocation],
               case let .tuple(types) = pending.elementType,
               let index = Int(component[2]),
               types.indices.contains(index) {
                arrayLiteralComponentAddresses[component[0]] = .init(
                    allocation: base.allocation,
                    index: base.index,
                    component: index
                )
                continue
            }

            if let extraction = match(
                line,
                pattern: #"^(%[0-9]+) = unchecked_enum_data (%[0-9]+), #Optional\.some!enumelt$"#
            ) {
                guard let blockID = current?.id,
                      optionalSourceBySomeBlock[blockID] == extraction[1],
                      current?.parameters.count == 1,
                      let payload = current?.parameters.first
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "unchecked Optional payload is not dominated by its some edge"
                    )
                }
                values[extraction[0]] = payload
                continue
            }

            if let optional = match(
                line,
                pattern: #"^(%[0-9]+) = enum \$Optional<(.+)>, #Optional\.some!enumelt, (%[0-9]+)$"#
            ) {
                let payload = try resolve(optional[2], line: sourceLine)
                let wrapped = try parseType(optional[1])
                guard registerTypes[Int(payload.rawValue)] == wrapped else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional.some payload does not match its SIL type"
                    )
                }
                let result = try allocate(type: .optional(wrapped))
                values[optional[0]] = result
                current!.instructions.append(.makeOptionalSome(result: result, value: payload))
                continue
            }

            if let optional = match(
                line,
                pattern: #"^(%[0-9]+) = enum \$Optional<(.+)>, #Optional\.none!enumelt$"#
            ) {
                let result = try allocate(type: .optional(parseType(optional[1])))
                values[optional[0]] = result
                current!.instructions.append(.makeOptionalNone(result: result))
                continue
            }

            if let enumeration = match(
                line,
                pattern: #"^(%[0-9]+) = enum \$(.+), #([^!]+)!enumelt(?:, (%[0-9]+))?$"#
            ), case let .local(key) = try parseType(enumeration[1]) {
                let definition = try typeEnvironment.definition(for: key)
                guard case let .enumeration(cases) = definition.kind else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "enum instruction references non-enum local type \(key)"
                    )
                }
                let caseName = enumeration[2].split(separator: ".").last
                    .map(String.init) ?? enumeration[2]
                let index = try typeEnvironment.enumCaseIndex(
                    type: key,
                    name: caseName
                )
                guard let caseIndex = UInt32(exactly: index) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local enum \(key) case index exceeds UInt32"
                    )
                }
                let payload = try enumeration[3].isEmpty
                    ? nil
                    : resolve(enumeration[3], line: sourceLine)
                guard cases[index].payloadType
                    == payload.map({ registerTypes[Int($0.rawValue)] })
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local enum \(key).\(caseName) payload does not match its declaration"
                    )
                }
                if definition.conformsToError,
                   !typeEnvironment.preservesTypedErrors,
                   payload == nil {
                    errorEnumMessages[enumeration[0]] = enumeration[2]
                    continue
                }
                let result = try allocate(type: .local(key))
                values[enumeration[0]] = result
                current!.instructions.append(
                    .makeEnum(
                        result: result,
                        caseIndex: caseIndex,
                        payload: payload
                    )
                )
                continue
            }

            if let errorCase = match(
                line,
                pattern: #"^(%[0-9]+) = enum \$[^,]+, #([^!]+)!enumelt$"#
            ) {
                errorEnumMessages[errorCase[0]] = errorCase[1]
                continue
            }

            if let box = match(
                line,
                pattern: #"^(%[0-9]+) = alloc_existential_box \$any Error, \$(.+)$"#
            ) {
                existentialBoxes.insert(box[0])
                if typeEnvironment.preservesTypedErrors,
                   let key = typeEnvironment.localKey(for: box[1]) {
                    guard try typeEnvironment.definition(for: key).conformsToError else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "alloc_existential_box concrete type \(key) does not conform to Error"
                        )
                    }
                    typedErrorBoxTypes[box[0]] = key
                }
                continue
            }

            if let projection = match(
                line,
                pattern: #"^(%[0-9]+) = project_existential_box \$[^ ]+ in (%[0-9]+)$"#
            ) {
                guard existentialBoxes.contains(projection[1]) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "project_existential_box references an unknown error box"
                    )
                }
                projectedBoxByAddress[projection[0]] = projection[1]
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
            ), var mutation = arrayElementMutations[store[1]] {
                guard !mutation.didStore else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.subscript.modify stores more than once"
                    )
                }
                let value = try resolve(store[0], line: sourceLine)
                guard registerTypes[Int(value.rawValue)] == mutation.elementType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array subscript update value does not match Array.Element"
                    )
                }
                let result = try allocate(type: .array(mutation.elementType))
                current!.instructions.append(
                    .arrayUpdate(
                        result: result,
                        array: mutation.array,
                        index: mutation.index,
                        value: value
                    )
                )
                assignStackValue(result, at: mutation.arrayAddress)
                mutation.didStore = true
                arrayElementMutations[store[1]] = mutation
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
            ), let state = pendingDictionaryIteratorValues.removeValue(forKey: store[0]) {
                let address = addressBase(store[1])
                guard let expected = pendingDictionaryIteratorTypes[address],
                      expected.0 == state.keyType,
                      expected.1 == state.valueType,
                      dictionaryIteratorStates[address] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary iterator store does not match its stack address"
                    )
                }
                dictionaryIteratorStates[address] = state
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
            ), let box = projectedBoxByAddress[store[1]],
               let key = typedErrorBoxTypes[box] {
                let payload = try resolve(store[0], line: sourceLine)
                guard registerTypes[Int(payload.rawValue)] == .local(key),
                      values[box] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "typed Error existential box payload does not match \(key)"
                    )
                }
                let error = try allocate(type: .error)
                values[box] = error
                current!.instructions.append(
                    .makeError(result: error, payload: payload)
                )
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[trivial\] )?(%[0-9]+)$"#
            ),
               let message = errorEnumMessages[store[0]],
               let box = projectedBoxByAddress[store[1]] {
                errorMessageByBox[box] = message
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
            ), let accumulator = stringInterpolationValues.removeValue(
                forKey: store[0]
            ) {
                let address = addressBase(store[1])
                guard pendingStringInterpolationAddresses.contains(address),
                      stringInterpolationAddressValues[address] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String interpolation storage is invalid or initialized twice"
                    )
                }
                stringInterpolationAddressValues[address] = accumulator
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
            ), let address = arrayLiteralComponentAddresses[store[1]],
               var pending = pendingArrayLiterals[address.allocation],
               case let .tuple(types) = pending.elementType {
                let value = try resolve(store[0], line: sourceLine)
                guard address.index >= 0,
                      address.index < pending.count,
                      types.indices.contains(address.component),
                      registerTypes[Int(value.rawValue)] == types[address.component],
                      pending.elements[address.index] == nil,
                      pending.elementComponents[address.index]?[address.component] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array tuple component store is invalid, duplicated, or has the wrong type"
                    )
                }
                pending.elementComponents[address.index, default: [:]][address.component] = value
                pendingArrayLiterals[address.allocation] = pending
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
            ), let address = arrayLiteralAddresses[store[1]],
               var pending = pendingArrayLiterals[address.allocation] {
                let value = try resolve(store[0], line: sourceLine)
                guard address.index >= 0,
                      address.index < pending.count,
                      pending.elements[address.index] == nil,
                      registerTypes[Int(value.rawValue)] == pending.elementType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array literal store is out of bounds, duplicated, or has the wrong type"
                    )
                }
                pending.elements[address.index] = value
                pendingArrayLiterals[address.allocation] = pending
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
            ), let addressType = stackType(at: store[1]) {
                let value = try resolve(store[0], line: sourceLine)
                guard registerTypes[Int(value.rawValue)] == addressType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "store value does not match its stack address"
                    )
                }
                if let addressRegister = runtimeAddress(at: store[1]) {
                    let root = addressBase(store[1])
                    if isScopedRuntimeAddress(store[1]) {
                        current!.instructions.append(
                            .storeAddress(address: addressRegister, source: value, mode: .assign)
                        )
                    } else if let slot = runtimeStackSlots[root], store[1] == root {
                        let mode: Bytecode.StackStoreMode = stackAddressValues[root] == nil
                            ? .initialize
                            : .assign
                        current!.instructions.append(
                            .storeStack(slot: slot, source: value, mode: mode)
                        )
                    } else {
                        let access = try allocate(type: .address(addressType))
                        current!.instructions.append(
                            .beginAccess(
                                result: access,
                                address: addressRegister,
                                kind: .modify
                            )
                        )
                        current!.instructions.append(
                            .storeAddress(address: access, source: value, mode: .assign)
                        )
                        current!.instructions.append(.endAccess(access))
                    }
                    stackAddressValues[root] = value
                    continue
                }
                assignStackValue(value, at: store[1])
                values[store[1]] = value
                values[addressBase(store[1])] = value
                continue
            }

            if let load = match(
                line,
                pattern: #"^(%[0-9]+) = load(?: \[(trivial|copy|take)\])? (%[0-9]+)$"#
            ) {
                let mode = load[1]
                let address = addressBase(load[2])
                if pendingStringInterpolationAddresses.contains(address) {
                    guard mode == "take",
                          let accumulator = stringInterpolationAddressValues.removeValue(
                              forKey: address
                          )
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "String interpolation storage requires a taking load"
                        )
                    }
                    stringInterpolationValues[load[0]] = accumulator
                    continue
                }
                if let addressRegister = runtimeAddress(at: load[2]),
                   let addressType = stackType(at: load[2]) {
                    let result = try allocate(type: addressType)
                    if isScopedRuntimeAddress(load[2]) {
                        guard mode != "take" else {
                            throw CanonicalSIL.LoweringError.unsupportedInstruction(
                                line: sourceLine,
                                text: "taking load through inout address"
                            )
                        }
                        current!.instructions.append(
                            .loadAddress(result: result, address: addressRegister, mode: .copy)
                        )
                    } else if let slot = runtimeStackSlots[address], load[2] == address {
                        guard stackAddressValues[address] != nil else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "load references an uninitialized runtime stack address"
                            )
                        }
                        let loadMode: Bytecode.StackLoadMode = mode == "take" ? .take : .copy
                        current!.instructions.append(
                            .loadStack(result: result, slot: slot, mode: loadMode)
                        )
                        if loadMode == .take { stackAddressValues.removeValue(forKey: address) }
                    } else {
                        guard mode != "take" else {
                            throw CanonicalSIL.LoweringError.unsupportedInstruction(
                                line: sourceLine,
                                text: "taking load through projected address"
                            )
                        }
                        let access = try allocate(type: .address(addressType))
                        current!.instructions.append(
                            .beginAccess(result: access, address: addressRegister, kind: .read)
                        )
                        current!.instructions.append(
                            .loadAddress(result: result, address: access, mode: .copy)
                        )
                        current!.instructions.append(.endAccess(access))
                    }
                    values[load[0]] = result
                    continue
                }
                guard let value = stackValue(at: load[2]),
                      let addressType = stackType(at: load[2]),
                      registerTypes[Int(value.rawValue)] == addressType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "load references an uninitialized stack address"
                    )
                }
                if mode == "take" {
                    stackAddressValues.removeValue(forKey: address)
                    values[load[0]] = value
                } else if mode == "copy" || (mode.isEmpty && !addressType.isTrivial) {
                    let copy = try allocate(type: addressType)
                    current!.instructions.append(.copyValue(result: copy, source: value))
                    values[load[0]] = copy
                } else {
                    values[load[0]] = value
                }
                continue
            }

            if let destroy = match(line, pattern: #"^destroy_addr (%[0-9]+)$"#) {
                let address = addressBase(destroy[0])
                if catchScratchAddresses.contains(address) { continue }
                if let iterator = arrayIteratorStates.removeValue(forKey: address) {
                    current!.instructions.append(.destroyStack(iterator.indexSlot))
                    destroyedArrayIterators.insert(address)
                    continue
                }
                if let iterator = dictionaryIteratorStates.removeValue(forKey: address) {
                    current!.instructions.append(.destroyStack(iterator.indexSlot))
                    destroyedDictionaryIterators.insert(address)
                    continue
                }
                if let slot = runtimeStackSlots[address] {
                    guard stackAddressValues.removeValue(forKey: address) != nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "destroy_addr references uninitialized runtime storage"
                        )
                    }
                    current!.instructions.append(.destroyStack(slot))
                    continue
                }
                guard stackAddressTypes[address] != nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "destroy_addr references an unsupported address"
                    )
                }
                if let value = stackAddressValues.removeValue(forKey: address) {
                    current!.instructions.append(.destroyValue(value))
                }
                continue
            }

            if let cast = match(
                line,
                pattern: #"^checked_cast_addr_br copy_on_success any Error in (%[0-9]+) to (.+) in (%[0-9]+), bb([0-9]+), bb([0-9]+)$"#
            ) {
                let sourceAddress = addressBase(cast[0])
                let destinationAddress = addressBase(cast[2])
                guard stackType(at: cast[0]) == .error,
                      let error = stackValue(at: cast[0]),
                      registerTypes[Int(error.rawValue)] == .error,
                      let key = typeEnvironment.localKey(for: cast[1]),
                      try typeEnvironment.definition(for: key).conformsToError,
                      stackType(at: cast[2]) == .local(key)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "checked Error cast source or destination type does not match"
                    )
                }
                let successTarget = try parseBlockID(cast[3])
                let failureTarget = try parseBlockID(cast[4])
                guard implicitStackValues[successTarget] == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "multiple checked Error casts share a success block"
                    )
                }
                let optional = try allocate(type: .optional(.local(key)))
                let projected = try allocate(type: .local(key))
                current!.instructions.append(
                    .castError(result: optional, error: error, expectedType: key)
                )
                current!.instructions.append(
                    .switchOptional(
                        optional: optional,
                        someTarget: successTarget,
                        noneTarget: failureTarget
                    )
                )
                implicitStackValues[successTarget] = [(cast[2], projected)]
                catchScratchAddresses.insert(sourceAddress)
                catchScratchAddresses.insert(destinationAddress)
                continue
            }

            if let willThrow = match(
                line,
                pattern: #"^%[0-9]+ = builtin \"willThrow\"\((%[0-9]+)\) : \$\(\)$"#
            ), existentialBoxes.contains(willThrow[0]) {
                continue
            }

            if let tuple = match(
                line,
                pattern: #"^(%[0-9]+) = tuple(?: \$\([^\n]*\))? \((.*)\)$"#
            ) {
                let components = splitTopLevel(tuple[1])
                if components.count == 1, components[0].isEmpty {
                    voidValues.insert(tuple[0])
                    continue
                }
                let elements = try components.map { component in
                    let token = component.split(separator: ":", maxSplits: 1)[0]
                        .trimmingCharacters(in: .whitespaces)
                    return try resolve(token, line: sourceLine)
                }
                let result = try allocate(
                    type: .tuple(elements.map { registerTypes[Int($0.rawValue)] })
                )
                values[tuple[0]] = result
                current!.instructions.append(.makeTuple(result: result, elements: elements))
                continue
            }

            if let builtin = match(
                line,
                pattern: #"^(%[0-9]+) = builtin \"(sadd|ssub|smul|uadd|usub|umul)_with_overflow_Int(8|16|32|64)\"\((%[0-9]+), (%[0-9]+), %[-0-9]+\).*$"#
            ) {
                let operation: Bytecode.BinaryOperation = switch builtin[1] {
                case "sadd", "uadd": .add
                case "ssub", "usub": .subtract
                default: .multiply
                }
                let signed = builtin[1].first == "s"
                guard let width = UInt16(builtin[2]) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "overflow builtin has an invalid bit width"
                    )
                }
                let result = try allocate(type: .integer(bitWidth: width, signed: signed))
                let overflow = try allocate(type: .bool)
                let operandType = Bytecode.ValueType.integer(
                    bitWidth: width,
                    signed: signed
                )
                let lhs = try materializeIntegerOperand(
                    builtin[3],
                    expected: operandType,
                    line: sourceLine
                )
                let rhs = try materializeIntegerOperand(
                    builtin[4],
                    expected: operandType,
                    line: sourceLine
                )
                current!.instructions.append(
                    .checkedBinary(result: result, overflow: overflow, operation: operation, lhs: lhs, rhs: rhs)
                )
                tupleValues[builtin[0]] = (result, overflow)
                continue
            }

            if let extract = match(line, pattern: #"^(%[0-9]+) = tuple_extract (%[0-9]+), ([0-9]+)$"#) {
                if let tuple = tupleValues[extract[1]] {
                    guard extract[2] == "0" || extract[2] == "1" else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "overflow builtin tuple has only two elements"
                        )
                    }
                    values[extract[0]] = extract[2] == "0" ? tuple.0 : tuple.1
                    continue
                }
                let tuple = try resolve(extract[1], line: sourceLine)
                guard case let .tuple(elementTypes) = registerTypes[Int(tuple.rawValue)],
                      let index = Int(extract[2]),
                      elementTypes.indices.contains(index)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "tuple_extract index does not match its operand type"
                    )
                }
                let elements: [Bytecode.Register]
                if let existing = unpackedTuples[extract[1]] {
                    elements = existing
                } else {
                    elements = try elementTypes.map { try allocate(type: $0) }
                    unpackedTuples[extract[1]] = elements
                    current!.instructions.append(.unpackTuple(results: elements, tuple: tuple))
                }
                values[extract[0]] = elements[index]
                continue
            }

            if let failure = match(line, pattern: #"^cond_fail (%[0-9]+), \"([^\"]*)\"$"#) {
                let condition = try resolve(failure[0], line: sourceLine)
                let trapID = try allocateSyntheticBlockID()
                let continuationID = try allocateSyntheticBlockID()
                current!.instructions.append(
                    .conditionalBranch(
                        condition: condition,
                        trueTarget: trapID,
                        trueArguments: [],
                        falseTarget: continuationID,
                        falseArguments: []
                    )
                )
                finishCurrent()
                blocks.append(
                    IntermediateRepresentation.Block(
                        id: trapID,
                        parameters: [],
                        instructions: [.trap(trapReason(for: failure[1]))]
                    )
                )
                current = IntermediateRepresentation.Block(id: continuationID, parameters: [], instructions: [])
                continue
            }

            if let copy = match(line, pattern: #"^(%[0-9]+) = copy_value (%[0-9]+)$"#) {
                if let reference = functionReferences[copy[1]] {
                    functionReferences[copy[0]] = reference
                    continue
                }
                if let reference = swiftCoreReferences[copy[1]] {
                    swiftCoreReferences[copy[0]] = reference
                    continue
                }
                if let key = localFactoryReferences[copy[1]] {
                    localFactoryReferences[copy[0]] = key
                    continue
                }
                let source = try resolve(copy[1], line: sourceLine)
                let result = try allocate(type: registerTypes[Int(source.rawValue)])
                values[copy[0]] = result
                current!.instructions.append(.copyValue(result: result, source: source))
                continue
            }
            if let move = match(
                line,
                pattern: #"^(%[0-9]+) = move_value(?: \[[^\]]+\])* (%[0-9]+)$"#
            ) {
                if let reference = functionReferences.removeValue(forKey: move[1]) {
                    functionReferences[move[0]] = reference
                    continue
                }
                if let reference = swiftCoreReferences.removeValue(forKey: move[1]) {
                    swiftCoreReferences[move[0]] = reference
                    continue
                }
                if let key = localFactoryReferences.removeValue(forKey: move[1]) {
                    localFactoryReferences[move[0]] = key
                    continue
                }
                let source = try resolve(move[1], line: sourceLine)
                let result = try allocate(type: registerTypes[Int(source.rawValue)])
                values[move[0]] = result
                current!.instructions.append(.moveValue(result: result, source: source))
                continue
            }
            if let destroy = match(line, pattern: #"^destroy_value (%[0-9]+)$"#) {
                if functionReferences.removeValue(forKey: destroy[0]) != nil { continue }
                if swiftCoreReferences.removeValue(forKey: destroy[0]) != nil { continue }
                if localFactoryReferences.removeValue(forKey: destroy[0]) != nil { continue }
                let value = try resolve(destroy[0], line: sourceLine)
                if case .closure = registerTypes[Int(value.rawValue)] { continue }
                current!.instructions.append(.destroyValue(value))
                continue
            }
            if let ownership = match(
                line,
                pattern: #"^(?:retain_value|release_value) (%[0-9]+)$"#
            ) {
                let value = try resolve(ownership[0], line: sourceLine)
                guard !registerTypes[Int(value.rawValue)].requiresLinearOwnership else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                continue
            }
            if let ownership = match(
                line,
                pattern: #"^strong_(retain|release) (%[0-9]+)$"#
            ) {
                let value = try resolve(ownership[1], line: sourceLine)
                let type = registerTypes[Int(value.rawValue)]
                if case .closure = type { continue }
                guard type == .string || type == .error else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                if ownership[0] == "release" {
                    current!.instructions.append(.destroyValue(value))
                }
                continue
            }

            if let branch = match(
                line,
                pattern: #"^switch_enum (%[0-9]+), case #Optional\.(some|none)!enumelt: bb([0-9]+), case #Optional\.(some|none)!enumelt: bb([0-9]+)$"#
            ) {
                guard branch[1] != branch[3] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "switch_enum must contain one some and one none case"
                    )
                }
                let optional = try resolve(branch[0], line: sourceLine)
                guard case .optional = registerTypes[Int(optional.rawValue)] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional switch operand has a non-Optional type"
                    )
                }
                let firstTarget = try parseBlockID(branch[2])
                let secondTarget = try parseBlockID(branch[4])
                let someTarget = branch[1] == "some" ? firstTarget : secondTarget
                let noneTarget = branch[1] == "none" ? firstTarget : secondTarget
                guard optionalSourceBySomeBlock[someTarget] == nil,
                      optionalSourceByNoneBlock[noneTarget] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "multiple Optional switches share a case block"
                    )
                }
                optionalSourceBySomeBlock[someTarget] = branch[0]
                optionalSourceByNoneBlock[noneTarget] = branch[0]
                current!.instructions.append(
                    .switchOptional(
                        optional: optional,
                        someTarget: someTarget,
                        noneTarget: noneTarget
                    )
                )
                continue
            }

            if line.hasPrefix("switch_enum ") {
                let body = String(line.dropFirst("switch_enum ".count))
                let components = splitTopLevel(body)
                if let operandToken = components.first,
                   let enumeration = values[operandToken],
                   case let .local(key) = registerTypes[Int(enumeration.rawValue)] {
                    var caseTargets: [Bytecode.EnumCaseTarget] = []
                    var seenCases = Set<UInt32>()
                    var defaultTarget: Bytecode.BlockID?
                    for component in components.dropFirst() {
                        if let item = match(
                            component,
                            pattern: #"^case #([^!]+)!enumelt: bb([0-9]+)$"#
                        ) {
                            let caseName = item[0].split(separator: ".").last
                                .map(String.init) ?? item[0]
                            let index = try typeEnvironment.enumCaseIndex(
                                type: key,
                                name: caseName
                            )
                            guard let caseIndex = UInt32(exactly: index),
                                  seenCases.insert(caseIndex).inserted
                            else {
                                throw CanonicalSIL.LoweringError.malformedSIL(
                                    "local enum switch contains a duplicate or oversized case"
                                )
                            }
                            caseTargets.append(
                                .init(
                                    caseIndex: caseIndex,
                                    target: try parseBlockID(item[1])
                                )
                            )
                        } else if let item = match(
                            component,
                            pattern: #"^default bb([0-9]+)$"#
                        ), defaultTarget == nil {
                            defaultTarget = try parseBlockID(item[0])
                        } else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "local enum switch contains an unsupported case target"
                            )
                        }
                    }
                    guard !caseTargets.isEmpty else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "local enum switch contains no case targets"
                        )
                    }
                    current!.instructions.append(
                        .switchEnum(
                            enumeration: enumeration,
                            cases: caseTargets,
                            defaultTarget: defaultTarget
                        )
                    )
                    continue
                }
            }

            if let branch = match(line, pattern: #"^br bb([0-9]+)(?:\((.*)\))?$"#) {
                let arguments = try parseBranchArguments(branch.count > 1 ? branch[1] : "", line: sourceLine, resolve: resolve)
                current!.instructions.append(
                    .branch(target: try parseBlockID(branch[0]), arguments: arguments)
                )
                continue
            }
            if let branch = match(
                line,
                pattern: #"^cond_br (%[0-9]+), bb([0-9]+)(?:\(([^)]*)\))?, bb([0-9]+)(?:\(([^)]*)\))?$"#
            ) {
                current!.instructions.append(
                    .conditionalBranch(
                        condition: try resolve(branch[0], line: sourceLine),
                        trueTarget: try parseBlockID(branch[1]),
                        trueArguments: try parseBranchArguments(branch[2], line: sourceLine, resolve: resolve),
                        falseTarget: try parseBlockID(branch[3]),
                        falseArguments: try parseBranchArguments(branch[4], line: sourceLine, resolve: resolve)
                    )
                )
                continue
            }
            if let thrown = match(line, pattern: #"^throw (%[0-9]+)$"#) {
                guard signature.effects.mayThrow else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "non-throwing function contains throw"
                    )
                }
                if let error = values[thrown[0]],
                   [.string, .error].contains(registerTypes[Int(error.rawValue)]) {
                    current!.instructions.append(.throwError(error))
                } else if let message = errorMessageByBox[thrown[0]] {
                    let error = try allocate(type: .string)
                    current!.instructions.append(
                        .constantString(result: error, value: message)
                    )
                    current!.instructions.append(.throwError(error))
                } else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "throw does not contain a supported Error value"
                    )
                }
                continue
            }
            if let returned = match(line, pattern: #"^return (%[0-9]+)$"#) {
                if voidValues.contains(returned[0]) {
                    guard signature.result == .void else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "non-Void function returns an empty tuple"
                        )
                    }
                    current!.instructions.append(.returnValue(nil))
                } else if let allocation = arrayLiteralAllocationByValue[returned[0]],
                          let pending = pendingArrayLiterals[allocation] {
                    let elements = try materializeArrayLiteralElements(pending)
                    let result = try allocate(type: .array(pending.elementType))
                    current!.instructions.append(
                        .makeArray(
                            result: result,
                            elements: elements
                        )
                    )
                    current!.instructions.append(.returnValue(result))
                    pendingArrayLiterals.removeValue(forKey: allocation)
                } else {
                    current!.instructions.append(
                        .returnValue(try resolve(returned[0], line: sourceLine))
                    )
                }
                continue
            }

            throw CanonicalSIL.LoweringError.unsupportedInstruction(line: sourceLine, text: line)
        }
        finishCurrent()
        guard let entryBlock else { throw CanonicalSIL.LoweringError.malformedSIL("function contains no entry block") }
        guard pendingArrayLiterals.isEmpty else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "Array literal allocation is not finalized on every supported path"
            )
        }
        guard pendingArrayIteratorTypes.isEmpty,
              arrayIteratorStates.isEmpty,
              destroyedArrayIterators.isEmpty,
              arrayElementMutations.isEmpty,
              arrayMutationYieldByToken.isEmpty,
              pendingDictionaryIteratorTypes.isEmpty,
              pendingDictionaryIteratorValues.isEmpty,
              dictionaryIteratorStates.isEmpty,
              destroyedDictionaryIterators.isEmpty,
              pendingStringInterpolationAddresses.isEmpty,
              stringInterpolationAddressValues.isEmpty,
              stringInterpolationValues.isEmpty
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "compiler-only iterator or interpolation lifetime is incomplete"
            )
        }

        return IntermediateRepresentation.Function(
            name: displayName,
            kind: kind,
            parameterRegisters: parameterRegisters,
            parameterConventions: signature.parameterConventions,
            resultType: signature.result,
            registerTypes: registerTypes,
            entryBlock: entryBlock,
            blocks: blocks,
            stackSlotTypes: stackSlotTypes,
            effects: effectiveEffects
        )
    }

    func parseFunctionType(
        _ text: String
    ) throws -> (
        parameters: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention],
        result: Bytecode.ValueType,
        effects: Core.Effects
    ) {
        guard let arrow = text.range(of: " -> ", options: .backwards) else {
            throw CanonicalSIL.LoweringError.malformedSIL("function type has no result arrow")
        }
        let resultText = String(text[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        let prefix = String(text[..<arrow.lowerBound])
        guard let close = prefix.lastIndex(of: ")"),
              let open = matchingOpeningParenthesis(for: close, in: prefix),
              open < close
        else {
            throw CanonicalSIL.LoweringError.malformedSIL("function type has no parameter tuple")
        }
        let parametersText = prefix[prefix.index(after: open)..<close]
        let rawParameters = splitTopLevel(String(parametersText)).filter { !$0.isEmpty }
        let parameters = try rawParameters.map(parseType)
        let parameterConventions = rawParameters.map { raw -> Bytecode.ParameterConvention in
            let value = raw.trimmingCharacters(in: .whitespaces)
                .trimmingPrefix("$")
            if value.hasPrefix("@inout ") || value.hasPrefix("*") { return .inout }
            // Shell arguments remain owned by the invocation array for the
            // entire call. SIL's ubiquitous @guaranteed spelling is therefore
            // normalized to owned here; explicit HLBC borrow conventions are
            // reserved for patch-local bindings that opt in deliberately.
            return .owned
        }
        let isAsync = prefix.range(
            of: #"(?:^|\s)@async(?:\s|$)"#,
            options: .regularExpression
        ) != nil
        let resultComponents = splitTopLevelTuple(resultText)
        if resultComponents.count == 2,
           resultComponents[1].trimmingCharacters(in: .whitespaces).hasPrefix("@error ") {
            return (
                parameters,
                parameterConventions,
                try parseType(resultComponents[0]),
                .init(mayThrow: true, isAsync: isAsync)
            )
        }
        return (
            parameters,
            parameterConventions,
            try parseType(resultText),
            .init(isAsync: isAsync)
        )
    }

    private func matchingOpeningParenthesis(
        for close: String.Index,
        in text: String
    ) -> String.Index? {
        var depth = 0
        var index = close
        while true {
            switch text[index] {
            case ")":
                depth += 1
            case "(":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            guard index > text.startIndex else { return nil }
            index = text.index(before: index)
        }
    }

    private func parseType(_ raw: String) throws -> Bytecode.ValueType {
        try typeEnvironment.resolve(raw)
    }

    private func arrayIteratorElementType(
        _ raw: String
    ) throws -> Bytecode.ValueType? {
        let type = raw.trimmingCharacters(in: .whitespaces)
        let prefixes = ["IndexingIterator<", "Swift.IndexingIterator<"]
        guard let prefix = prefixes.first(where: { type.hasPrefix($0) }) else {
            return nil
        }
        guard type.hasSuffix(">") else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "IndexingIterator type is missing its closing angle bracket"
            )
        }
        let start = type.index(type.startIndex, offsetBy: prefix.count)
        let end = type.index(before: type.endIndex)
        let collection = try parseType(String(type[start..<end]))
        guard case let .array(element) = collection else {
            throw CanonicalSIL.LoweringError.unsupportedType(type)
        }
        return element
    }

    private func dictionaryIteratorTypes(
        _ raw: String
    ) throws -> (key: Bytecode.ValueType, value: Bytecode.ValueType)? {
        let type = raw.trimmingCharacters(in: .whitespaces)
        let prefixes = ["Dictionary<", "Swift.Dictionary<"]
        guard let prefix = prefixes.first(where: { type.hasPrefix($0) }),
              type.hasSuffix(">.Iterator")
        else { return nil }
        let start = type.index(type.startIndex, offsetBy: prefix.count)
        let end = type.index(type.endIndex, offsetBy: -">.Iterator".count)
        let types = try parseDictionaryGenericArguments(String(type[start..<end]))
        guard isSupportedDictionaryKey(types.key) else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "Dictionary iterator key \(types.key)"
            )
        }
        return types
    }

    private func parseDictionaryGenericArguments(
        _ raw: String
    ) throws -> (key: Bytecode.ValueType, value: Bytecode.ValueType) {
        let components = splitTopLevel(raw)
        guard components.count == 2 else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "Dictionary generic arguments must contain Key and Value"
            )
        }
        return (try parseType(components[0]), try parseType(components[1]))
    }

    private func isSupportedDictionaryKey(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .bool, .integer, .string:
            true
        default:
            false
        }
    }

    private func removeTupleLabel(_ raw: String) -> String {
        var depth = 0
        for index in raw.indices {
            switch raw[index] {
            case "(", "<", "[": depth += 1
            case ")", ">", "]": depth -= 1
            case ":" where depth == 0:
                return String(raw[raw.index(after: index)...])
                    .trimmingCharacters(in: .whitespaces)
            default: break
            }
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    private func parseBlockHeader(
        _ line: String,
        allocate: (Bytecode.ValueType) throws -> Bytecode.Register
    ) throws -> (block: IntermediateRepresentation.Block, parameters: [(String, Bytecode.Register)])? {
        guard let match = match(line, pattern: #"^bb([0-9]+)(?:\((.*)\))?:$"#) else { return nil }
        let id = try parseBlockID(match[0])
        let parameterText = match.count > 1 ? match[1] : ""
        var parameters: [(String, Bytecode.Register)] = []
        if !parameterText.isEmpty {
            for component in splitTopLevel(parameterText) {
                guard let value = self.match(component, pattern: #"^(%[0-9]+)\s*:\s*(.+)$"#) else {
                    throw CanonicalSIL.LoweringError.malformedSIL("invalid block parameter \(component)")
                }
                parameters.append((value[0], try allocate(parseType(value[1]))))
            }
        }
        return (
            IntermediateRepresentation.Block(id: id, parameters: parameters.map(\.1), instructions: []),
            parameters
        )
    }

    private func parseBranchArguments(
        _ text: String,
        line: Int,
        resolve: (String, Int) throws -> Bytecode.Register
    ) throws -> [Bytecode.Register] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try splitTopLevel(text).map { component in
            let token = component.split(separator: ":", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
            return try resolve(token, line)
        }
    }

    private func parseApplyArguments(
        _ text: String,
        line: Int,
        resolve: (String, Int) throws -> Bytecode.Register
    ) throws -> [Bytecode.Register] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try splitTopLevel(text).map { component in
            guard let value = match(
                component,
                pattern: #"^(?:@(owned|guaranteed|unowned|in_guaranteed)\s+)?(%[0-9]+)(?:\s*:\s*.+)?$"#
            ) else {
                throw CanonicalSIL.LoweringError.unsupportedInstruction(
                    line: line,
                    text: "apply argument \(component)"
                )
            }
            return try resolve(value[1], line)
        }
    }

    private func parseApplyValueTokens(
        _ text: String,
        line: Int
    ) throws -> [String] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try splitTopLevel(text).map { component in
            guard let value = match(
                component,
                pattern: #"^(?:@(owned|guaranteed|unowned|in_guaranteed)\s+)?(%[0-9]+)(?:\s*:\s*.+)?$"#
            ) else {
                throw CanonicalSIL.LoweringError.unsupportedInstruction(
                    line: line,
                    text: "apply argument \(component)"
                )
            }
            return value[1]
        }
    }

    private func parseBlockNumber(_ line: String) -> UInt32? {
        guard let values = match(line.trimmingCharacters(in: .whitespaces), pattern: #"^bb([0-9]+)"#) else { return nil }
        return UInt32(values[0])
    }

    private func unsignedIntegerWidth(of nominalType: String) -> UInt16? {
        switch nominalType {
        case "UInt": 64
        case "UInt8": 8
        case "UInt16": 16
        case "UInt32": 32
        case "UInt64": 64
        default: nil
        }
    }

    private func parseBlockID(_ raw: String) throws -> Bytecode.BlockID {
        guard let value = UInt32(raw) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "block identifier is outside UInt32"
            )
        }
        return .init(rawValue: value)
    }

    private struct IntegerComparison {
        var result: String
        var lhs: String
        var rhs: String
        var predicate: Bytecode.ComparisonPredicate
        var bitWidth: UInt16
        var signedness: Bool?

        func accepts(_ type: Bytecode.ValueType) -> Bool {
            if bitWidth == 1 { return type == .bool && signedness == nil }
            guard case let .integer(width, signed) = type, width == bitWidth else { return false }
            return signedness == nil || signedness == signed
        }
    }

    private func parseIntegerComparison(_ line: String) -> IntegerComparison? {
        guard let parts = match(
            line,
            pattern: #"^(%[0-9]+) = builtin "cmp_(eq|ne|slt|sle|sgt|sge|ult|ule|ugt|uge)_Int(1|8|16|32|64)"\((%[0-9]+), (%[0-9]+)\).*$"#
        ) else { return nil }
        let predicate: Bytecode.ComparisonPredicate = switch parts[1] {
        case "eq": .equal
        case "ne": .notEqual
        case "slt", "ult": .lessThan
        case "sle", "ule": .lessThanOrEqual
        case "sgt", "ugt": .greaterThan
        default: .greaterThanOrEqual
        }
        let signedness: Bool? = switch parts[1].first {
        case "s": true
        case "u": false
        default: nil
        }
        guard let bitWidth = UInt16(parts[2]) else { return nil }
        return IntegerComparison(
            result: parts[0],
            lhs: parts[3],
            rhs: parts[4],
            predicate: predicate,
            bitWidth: bitWidth,
            signedness: signedness
        )
    }

    private struct UncheckedIntegerBinary {
        var result: String
        var lhs: String
        var rhs: String
        var operation: Bytecode.BinaryOperation
        var bitWidth: UInt16
        var signedness: Bool?

        func accepts(_ type: Bytecode.ValueType) -> Bool {
            guard case let .integer(width, signed) = type, width == bitWidth else { return false }
            return signedness == nil || signedness == signed
        }
    }

    private func parseUncheckedIntegerBinary(_ line: String) -> UncheckedIntegerBinary? {
        guard let parts = match(
            line,
            pattern: #"^(%[0-9]+) = builtin "(sdiv|udiv|srem|urem|and|or|xor|shl|ashr|lshr)_Int(8|16|32|64)"\((%[0-9]+), (%[0-9]+)\).*$"#
        ) else { return nil }
        let operation: Bytecode.BinaryOperation = switch parts[1] {
        case "sdiv", "udiv": .divide
        case "srem", "urem": .remainder
        case "and": .bitAnd
        case "or": .bitOr
        case "xor": .bitXor
        case "shl": .shiftLeft
        default: .shiftRight
        }
        let signedness: Bool? = switch parts[1] {
        case "sdiv", "srem", "ashr": true
        case "udiv", "urem", "lshr": false
        default: nil
        }
        guard let bitWidth = UInt16(parts[2]) else { return nil }
        return UncheckedIntegerBinary(
            result: parts[0],
            lhs: parts[3],
            rhs: parts[4],
            operation: operation,
            bitWidth: bitWidth,
            signedness: signedness
        )
    }

    private struct FloatingBinary {
        var result: String
        var lhs: String
        var rhs: String
        var operation: Bytecode.FloatBinaryOperation
        var bitWidth: UInt16
    }

    private func parseFloatingBinary(_ line: String) -> FloatingBinary? {
        guard let parts = match(
            line,
            pattern: #"^(%[0-9]+) = builtin "(fadd|fsub|fmul|fdiv)_FPIEEE(32|64)"\((%[0-9]+), (%[0-9]+)\).*$"#
        ) else { return nil }
        let operation: Bytecode.FloatBinaryOperation = switch parts[1] {
        case "fadd": .add
        case "fsub": .subtract
        case "fmul": .multiply
        default: .divide
        }
        guard let bitWidth = UInt16(parts[2]) else { return nil }
        return FloatingBinary(
            result: parts[0],
            lhs: parts[3],
            rhs: parts[4],
            operation: operation,
            bitWidth: bitWidth
        )
    }

    private struct FloatingComparison {
        var result: String
        var lhs: String
        var rhs: String
        var predicate: Bytecode.ComparisonPredicate
        var bitWidth: UInt16
    }

    private func parseFloatingComparison(_ line: String) -> FloatingComparison? {
        guard let parts = match(
            line,
            pattern: #"^(%[0-9]+) = builtin "fcmp_(oeq|une|olt|ole|ogt|oge)_FPIEEE(32|64)"\((%[0-9]+), (%[0-9]+)\).*$"#
        ) else { return nil }
        let predicate: Bytecode.ComparisonPredicate = switch parts[1] {
        case "oeq": .equal
        case "une": .notEqual
        case "olt": .lessThan
        case "ole": .lessThanOrEqual
        case "ogt": .greaterThan
        default: .greaterThanOrEqual
        }
        guard let bitWidth = UInt16(parts[2]) else { return nil }
        return FloatingComparison(
            result: parts[0],
            lhs: parts[3],
            rhs: parts[4],
            predicate: predicate,
            bitWidth: bitWidth
        )
    }

    private func trapReason(for message: String) -> Bytecode.TrapReason {
        let normalized = message.lowercased()
        if normalized.contains("division by zero") { return .divisionByZero }
        if normalized.contains("overflow")
            || normalized.contains("not enough bits to represent")
            || normalized.contains("cannot be represented") {
            return .integerOverflow
        }
        return .explicit(message)
    }

    private func stripSILComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "/" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "/" {
                    return String(line[..<index])
                }
            }
            index = line.index(after: index)
        }
        return line
    }

    private func decodeSILUTF8Literal(_ encoded: String) throws -> String {
        let input = Array(encoded.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            guard byte == 0x5C else {
                output.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < input.count else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "String literal ends with an incomplete escape"
                )
            }
            let escaped = input[index]
            switch escaped {
            case 0x5C: output.append(0x5C)
            case 0x22: output.append(0x22)
            case 0x6E: output.append(0x0A)
            case 0x72: output.append(0x0D)
            case 0x74: output.append(0x09)
            case 0x30 where index + 1 >= input.count || hexValue(input[index + 1]) == nil:
                output.append(0)
            default:
                guard index + 1 < input.count,
                      let high = hexValue(escaped),
                      let low = hexValue(input[index + 1])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String literal contains an unsupported escape"
                    )
                }
                output.append((high << 4) | low)
                index += 1
            }
            index += 1
        }
        guard let result = String(bytes: output, encoding: .utf8) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "String literal is not valid UTF-8"
            )
        }
        return result
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private func splitTopLevel(_ text: String) -> [String] {
        var result: [String] = []
        var depth = 0
        var start = text.startIndex
        for index in text.indices {
            switch text[index] {
            case "(", "<", "[": depth += 1
            case ")", ">", "]": depth -= 1
            case "," where depth == 0:
                result.append(String(text[start..<index]).trimmingCharacters(in: .whitespaces))
                start = text.index(after: index)
            default: break
            }
        }
        result.append(String(text[start...]).trimmingCharacters(in: .whitespaces))
        return result
    }

    private func splitTopLevelTuple(_ text: String) -> [String] {
        let type = text.trimmingCharacters(in: .whitespaces)
        guard type.hasPrefix("("), type.hasSuffix(")") else { return [type] }
        return splitTopLevel(String(type.dropFirst().dropLast()))
    }

    private func match(_ text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              result.range.location != NSNotFound
        else { return nil }
        return (1..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}
}
