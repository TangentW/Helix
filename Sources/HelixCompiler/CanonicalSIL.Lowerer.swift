import Foundation
import HelixBytecode
import HelixCore

extension CanonicalSIL {
public struct Lowerer: Sendable {
    private let typeEnvironment: CanonicalSIL.TypeEnvironment

    private enum SwiftCoreIntrinsic: Equatable {
        case stringLiteral
        case characterLiteral
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
        case assertionFailure

        init?(mangledName: String) {
            switch mangledName {
            case "$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC":
                self = .stringLiteral
            case "$sSJ38_builtinExtendedGraphemeClusterLiteral17utf8CodeUnitCount7isASCIISJBp_BwBi1_tcfC":
                self = .characterLiteral
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
            case "$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_A2HSus6UInt32VtF":
                self = .assertionFailure
            default: return nil
            }
        }
    }

    /// Swift emits these Foundation bridges around imported Objective-C APIs.
    /// HLBC calls a generated, Swift-typed NativeImport instead, so lowering
    /// preserves the Swift value while validating the exact compiler bridge.
    private enum ObjectiveCBridgeIntrinsic: Equatable {
        case stringToObjectiveC
        case stringFromObjectiveC
        case arrayToObjectiveC
        case arrayFromObjectiveC

        init?(mangledName: String, loweredType: String) {
            switch mangledName {
            case "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF":
                self = .stringToObjectiveC
            case "$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ":
                self = .stringFromObjectiveC
            case "$sSa10FoundationE19_bridgeToObjectiveCSo7NSArrayCyF":
                self = .arrayToObjectiveC
            case "$sSa10FoundationE36_unconditionallyBridgeFromObjectiveCySayxGSo7NSArrayCSgFZ":
                self = .arrayFromObjectiveC
            default:
                return nil
            }
            guard accepts(loweredType: loweredType) else { return nil }
        }

        func accepts(loweredType: String) -> Bool {
            let normalized = loweredType
                .replacingOccurrences(of: "Swift.", with: "")
                .filter { !$0.isWhitespace }
            return switch self {
            case .stringToObjectiveC:
                normalized
                    == "@convention(method)(@guaranteedString)->@ownedNSString"
            case .stringFromObjectiveC:
                normalized
                    == "@convention(method)(@guaranteedOptional<NSString>,@thinString.Type)->@ownedString"
            case .arrayToObjectiveC:
                normalized.hasPrefix("@convention(method)<τ_0_0>")
                    && normalized.hasSuffix("(@guaranteedArray<τ_0_0>)->@ownedNSArray")
            case .arrayFromObjectiveC:
                normalized.hasPrefix("@convention(method)<τ_0_0>")
                    && normalized.hasSuffix(
                        "(@guaranteedOptional<NSArray>,@thinArray<τ_0_0>.Type)->@ownedArray<τ_0_0>"
                    )
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

    /// Range is a compiler-only value. HLBC represents the loop with an Int
    /// stack cursor and ordinary typed control flow rather than a Swift ABI
    /// object whose layout could change with the standard library.
    private struct IntegerRangeValue {
        var lowerBound: Bytecode.Register
        var upperBound: Bytecode.Register
    }

    private struct IntegerRangeIteratorState {
        var upperBound: Bytecode.Register
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

    private struct TupleComponentAddress {
        var base: String
        var index: Int
    }

    private struct NativePropertyAddress {
        var receiver: Bytecode.Register
        var valueType: Bytecode.ValueType
        var getter: CanonicalSIL.DirectCallBinding?
        var setter: CanonicalSIL.DirectCallBinding?
        var unavailableGetter: CanonicalSIL.UnavailableDirectCall?
        var unavailableSetter: CanonicalSIL.UnavailableDirectCall?
    }

    enum MetatypeIdentity: Equatable {
        case native(Core.TypeID)
        case local(Bytecode.LocalTypeKey)
    }

    struct ErasedMetatype: Equatable {
        var physicalIndex: Int
        var identity: MetatypeIdentity
    }

    /// Keeps the physical SIL ABI separate from the frozen device target.
    /// Static metatypes and indirect results never cross the VM boundary.
    private struct ResolvedFunctionReference {
        var binding: CanonicalSIL.DirectCallBinding
        var physicalParameterConventions: [Bytecode.ParameterConvention]
        var hasIndirectResult: Bool
        var erasedMetatypes: [ErasedMetatype]
        var usesObjectiveCBridge: Bool
    }

    private struct HostedSuperReference {
        var context: CanonicalSIL.TypeEnvironment.HostedMethodContext
        var objectToken: String
    }

    private struct ExistentialProjection {
        var destination: String
        var concreteType: Bytecode.ValueType
        var components: [Int: Bytecode.Register] = [:]
    }

    private struct ExistentialComponentAddress {
        var projection: String
        var index: Int
    }

    private struct OptionalAddressInitialization {
        var wrappedType: Bytecode.ValueType
        var payload: Bytecode.Register?
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
        let hostedMethodContext = try typeEnvironment.hostedMethodContext(
            for: function
        )
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
        let nsErrorBridges = try CanonicalSIL.NSErrorBridgePlan.analyze(
            body: normalizedBody,
            directCalls: directCalls
        )
        let rawLines = normalizedBody.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        // Reject a forbidden existential payload before incidental SIL such
        // as a closure reabstraction thunk obscures the actionable cause.
        for rawLine in rawLines {
            let instruction = CanonicalSIL.DebugMetadata.strippingComment(
                from: rawLine
            ).trimmingCharacters(in: .whitespaces)
            guard let projection = match(
                instruction,
                pattern: #"^%[0-9]+ = init_existential_addr %[0-9]+, \$(.+)$"#
            ) else { continue }
            let concreteType = try parseType(projection[0])
            guard concreteType.isAnyPayloadOrExistentialV1 else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "Any payload \(concreteType)"
                )
            }
        }
        let maximumOriginalBlock = rawLines.compactMap(parseBlockNumber).max() ?? 0
        var nextSyntheticBlock: UInt32? = maximumOriginalBlock == UInt32.max
            ? nil
            : maximumOriginalBlock + 1
        var registerTypes: [Bytecode.ValueType] = []
        var values: [String: Bytecode.Register] = [:]
        var functionReferences: [String: ResolvedFunctionReference] = [:]
        var hostedAllocatorReferences: [String: Core.TypeID] = [:]
        var hostedSuperReferences: [String: HostedSuperReference] = [:]
        var deferredForeignReferences: [String: (reference: String, loweredType: String)] = [:]
        var swiftCoreReferences: [String: SwiftCoreIntrinsic] = [:]
        var objectiveCBridgeReferences: [String: ObjectiveCBridgeIntrinsic] = [:]
        var optionSetArrayLiteralReferences: [String: String] = [:]
        var localFactoryReferences: [String: Bytecode.LocalTypeKey] = [:]
        var stringLiterals: [String: String] = [:]
        var selectorLiterals: [String: String] = [:]
        var selectorOpaquePointers: [String: String] = [:]
        var staticStringPointers: [String: String] = [:]
        var staticStringValues: [String: String] = [:]
        var wordLiterals: [String: UInt64] = [:]
        var integerLiterals: [String: (bitWidth: UInt16, value: Int64)] = [:]
        var retypedIntegerLiterals: [String: [Bytecode.ValueType: Bytecode.Register]] = [:]
        var boolLiterals: [String: Bool] = [:]
        var metatypeValues = Set<String>()
        var arrayMetatypeValues: [String: Bytecode.ValueType] = [:]
        var nativeMetatypeValues: [String: Core.TypeID] = [:]
        var hostedMetatypeValues: [String: (
            key: Bytecode.LocalTypeKey,
            superclass: Core.TypeID
        )] = [:]
        var hostedAllocationObjects: [String: (
            key: Bytecode.LocalTypeKey,
            object: Bytecode.Register
        )] = [:]
        var nativeGlobalAddresses: [String: CanonicalSIL.DirectCallBinding] = [:]
        var characterMetatypeValues = Set<String>()
        var localMetatypeValues: [String: Bytecode.LocalTypeKey] = [:]
        var dictionaryMetatypeValues: [String: (Bytecode.ValueType, Bytecode.ValueType)] = [:]
        var stackAddressTypes: [String: Bytecode.ValueType] = [:]
        var stackAddressValues: [String: Bytecode.Register] = [:]
        var stackSlotTypes: [Bytecode.ValueType] = []
        var runtimeStackSlots: [String: Bytecode.StackSlot] = [:]
        var runtimeAddressValues: [String: Bytecode.Register] = [:]
        var runtimeAddressPointees: [String: Bytecode.ValueType] = [:]
        var scopedRuntimeAddresses = Set<String>()
        var initializingRuntimeAccesses = Set<String>()
        var inoutParameterAddressBases = Set<String>()
        var passthroughRuntimeAccesses = Set<String>()
        var borrowedAddressValues: [String: Bytecode.Register] = [:]
        var borrowedValueTokens = Set<String>()
        var preservedNativeConversionValues: [String: Bytecode.Register] = [:]
        var addressAliases: [String: String] = [:]
        var nativePropertyAddresses: [String: NativePropertyAddress] = [:]
        var pendingArrayIteratorTypes: [String: Bytecode.ValueType] = [:]
        var arrayIteratorStates: [String: ArrayIteratorState] = [:]
        var destroyedArrayIterators = Set<String>()
        var integerRangeValues: [String: IntegerRangeValue] = [:]
        var integerRangeAddresses = Set<String>()
        var integerRangeAddressValues: [String: IntegerRangeValue] = [:]
        var integerRangeIteratorAddresses = Set<String>()
        var integerRangeIteratorStates: [String: IntegerRangeIteratorState] = [:]
        var pendingIntegerRangeNextAddresses: [String: IntegerRangeIteratorState] = [:]
        var pendingIntegerRangeNextValues: [String: IntegerRangeIteratorState] = [:]
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
        var tupleComponentAddresses: [String: TupleComponentAddress] = [:]
        var tupleValues: [String: (Bytecode.Register, Bytecode.Register)] = [:]
        var unpackedTuples: [String: [Bytecode.Register]] = [:]
        var onStackClosureValues = Set<String>()
        var voidValues = Set<String>()
        var compilerOptionalVoidValues = Set<String>()
        var optionalSourceBySomeBlock: [Bytecode.BlockID: String] = [:]
        var optionalSourceByNoneBlock: [Bytecode.BlockID: String] = [:]
        var knownSomeOptionalAddresses: [Bytecode.BlockID: Set<String>] = [:]
        var optionalAddressSelectionConditions: [
            String: (address: String, someWhenTrue: Bool)
        ] = [:]
        var inheritedCompilerAddressValues: [
            Bytecode.BlockID: [String: Bytecode.Register]
        ] = [:]
        var reconstructedNoneValues: [Bytecode.BlockID: [String: Bytecode.Register]] = [:]
        var knownOptionalSomePayloads: [String: Bytecode.Register] = [:]
        var errorEnumMessages: [String: String] = [:]
        var existentialBoxes = Set<String>()
        var existentialProjections: [String: ExistentialProjection] = [:]
        var existentialComponentAddresses: [String: ExistentialComponentAddress] = [:]
        var optionalAddressInitializations: [String: OptionalAddressInitialization] = [:]
        var optionalPayloadAddressRoots: [String: String] = [:]
        var takenOptionalPayloadRoots: [String: String] = [:]
        var indirectResultAddress: String?
        var indirectResultSlot: Bytecode.StackSlot?
        var typedErrorBoxTypes: [String: Bytecode.LocalTypeKey] = [:]
        var projectedBoxByAddress: [String: String] = [:]
        var errorMessageByBox: [String: String] = [:]
        var catchScratchAddresses = Set<String>()
        var implicitStackValues: [
            Bytecode.BlockID: [(address: String, register: Bytecode.Register)]
        ] = [:]
        var compilerAddressWrites: [
            Bytecode.BlockID: [String: Bytecode.Register]
        ] = [:]
        var compilerAddressMergeRegisters: [
            Bytecode.BlockID: [String: Bytecode.Register]
        ] = [:]
        var indirectTryNormalBlocks = Set<Bytecode.BlockID>()
        var blocks: [IntermediateRepresentation.Block] = []
        var current: IntermediateRepresentation.Block?
        var currentSourceLocation: Core.SourceLocation?
        var sourceMap: [IntermediateRepresentation.SourceMapEntry] = []
        var entryBlock: Bytecode.BlockID?
        var parameterRegisters: [Bytecode.Register] = []
        let debugLineLocations = Dictionary(
            uniqueKeysWithValues: function.debugLineLocations.map { ($0.line, $0.location) }
        )

        func appendInstruction(_ instruction: IntermediateRepresentation.Instruction) {
            guard var block = current else {
                preconditionFailure("HLBC instruction emitted outside a basic block")
            }
            let offset = UInt32(exactly: block.instructions.count)
            block.instructions.append(instruction)
            current = block
            if let offset, let currentSourceLocation {
                sourceMap.append(
                    .init(
                        blockID: block.id,
                        instructionOffset: offset,
                        location: currentSourceLocation
                    )
                )
            }
        }

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

        func copyOwnedCallArgument(
            _ source: Bytecode.Register
        ) throws -> Bytecode.Register {
            let type = registerTypes[Int(source.rawValue)]
            guard !type.isTrivial else { return source }
            let copy = try allocate(type: type)
            appendInstruction(.copyValue(result: copy, source: source))
            return copy
        }

        func prepareReturnValue(
            _ token: String,
            line: Int
        ) throws -> Bytecode.Register {
            let value = try resolve(token, line: line)
            let type = registerTypes[Int(value.rawValue)]
            guard type.requiresLinearOwnership,
                  borrowedValueTokens.contains(token) || isBorrowedParameter(value)
            else { return value }
            // HLBC return transfers ownership. SIL may return a guaranteed
            // reference directly because ARC retains are implicit at that ABI
            // boundary, so materialize the corresponding VM ownership edge.
            return try copyOwnedCallArgument(value)
        }

        func isBorrowedParameter(_ register: Bytecode.Register) -> Bool {
            zip(parameterRegisters, signature.parameterConventions).contains {
                $0.0 == register && $0.1 == .borrowed
            }
        }

        func lineContainsSILValue(_ token: String, line: String) -> Bool {
            line.range(
                of: "(?<![0-9])" + NSRegularExpression.escapedPattern(for: token)
                    + "(?![0-9])",
                options: .regularExpression
            ) != nil
        }

        func hasFutureSemanticUse(of token: String, after lineIndex: Int) -> Bool {
            guard lineIndex + 1 < rawLines.count else { return false }
            return rawLines[(lineIndex + 1)...].contains { rawLine in
                let instruction = CanonicalSIL.DebugMetadata.strippingComment(
                    from: rawLine
                ).trimmingCharacters(in: .whitespaces)
                guard !instruction.isEmpty,
                      !instruction.hasPrefix("debug_value"),
                      !instruction.hasPrefix("debug_step"),
                      !instruction.hasPrefix("end_borrow"),
                      !instruction.hasPrefix("fix_lifetime")
                else { return false }
                return lineContainsSILValue(token, line: instruction)
            }
        }

        func prepareNativeReferenceConversion(
            sourceToken: String,
            source: Bytecode.Register,
            lineIndex: Int
        ) throws -> (argument: Bytecode.Register, tracksResultLifetime: Bool) {
            // Native bridge calls consume their argument. Preserve a borrowed
            // or subsequently reused SIL source and own the conversion result
            // as a compiler-generated temporary until its final semantic use.
            let sourceIsBorrowed = borrowedValueTokens.contains(sourceToken)
                || isBorrowedParameter(source)
            let preservesSource = sourceIsBorrowed
                || hasFutureSemanticUse(of: sourceToken, after: lineIndex)
            return (
                preservesSource ? try copyOwnedCallArgument(source) : source,
                preservesSource
            )
        }

        func releasePreservedNativeConversionsAfterLastUse(
            _ tokens: some Sequence<String>,
            after lineIndex: Int
        ) {
            for token in Set(tokens) where !hasFutureSemanticUse(
                of: token,
                after: lineIndex
            ) {
                guard let value = preservedNativeConversionValues.removeValue(
                    forKey: token
                ) else { continue }
                appendInstruction(.destroyValue(value))
            }
        }

        func closePreservedNativeConversionLifetime(
            for token: String,
            resolved value: Bytecode.Register
        ) throws {
            guard let tracked = preservedNativeConversionValues.removeValue(
                forKey: token
            ) else { return }
            guard tracked == value else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "preserved native conversion ownership does not match its SIL value"
                )
            }
        }

        func transferPreservedNativeConversionLifetime(
            from sourceToken: String,
            resolved source: Bytecode.Register,
            to resultToken: String,
            result: Bytecode.Register
        ) throws {
            guard let tracked = preservedNativeConversionValues.removeValue(
                forKey: sourceToken
            ) else { return }
            guard tracked == source,
                  preservedNativeConversionValues[resultToken] == nil
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "preserved native conversion cannot transfer into its owner"
                )
            }
            preservedNativeConversionValues[resultToken] = result
        }

        func addressBase(_ token: String) -> String {
            var current = token
            var visited = Set<String>()
            while let next = addressAliases[current], visited.insert(current).inserted {
                current = next
            }
            return current
        }

        func isKnownSomeOptionalAddress(
            _ token: String,
            in blockID: Bytecode.BlockID?
        ) -> Bool {
            guard let blockID else { return false }
            return knownSomeOptionalAddresses[blockID]?.contains(addressBase(token)) == true
        }

        func setKnownSomeOptionalAddress(
            _ token: String,
            in blockID: Bytecode.BlockID,
            isKnownSome: Bool
        ) {
            let root = addressBase(token)
            if isKnownSome {
                knownSomeOptionalAddresses[blockID, default: []].insert(root)
            } else {
                knownSomeOptionalAddresses[blockID]?.remove(root)
            }
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

        func reconstructedOptionalNone(
            for token: String,
            line: Int
        ) throws -> Bytecode.Register? {
            guard let blockID = current?.id,
                  let source = optionalSourceByNoneBlock[blockID],
                  addressBase(source) == addressBase(token)
            else { return nil }
            let root = addressBase(source)
            if let replacement = reconstructedNoneValues[blockID]?[root] {
                return replacement
            }
            guard runtimeAddress(at: source) == nil else { return nil }
            guard let original = stackAddressValues[root] ?? values[source] else {
                throw CanonicalSIL.LoweringError.undefinedValue(
                    line: line,
                    value: token
                )
            }
            let type = registerTypes[Int(original.rawValue)]
            guard case .optional = type else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "switch_enum none edge does not reference an Optional"
                )
            }
            let replacement = try allocate(type: type)
            appendInstruction(.makeOptionalNone(result: replacement))
            reconstructedNoneValues[blockID, default: [:]][root] = replacement
            if stackAddressTypes[root] != nil {
                stackAddressValues[root] = replacement
                values[root] = replacement
                values[source] = replacement
            }
            return replacement
        }

        func resolvedStackValue(
            at token: String,
            line: Int
        ) throws -> Bytecode.Register? {
            if let replacement = try reconstructedOptionalNone(
                for: token,
                line: line
            ) {
                return replacement
            }
            return stackValue(at: token)
        }

        func storeVMValue(
            _ value: Bytecode.Register,
            at token: String,
            requestedMode: Bytecode.StackStoreMode? = nil
        ) throws {
            guard let addressType = stackType(at: token),
                  registerTypes[Int(value.rawValue)] == addressType
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "store value does not match its stack address"
                )
            }
            if let addressRegister = runtimeAddress(at: token) {
                let root = addressBase(token)
                if isScopedRuntimeAddress(token) {
                    appendInstruction(
                        .storeAddress(
                            address: addressRegister,
                            source: value,
                            mode: requestedMode
                                ?? (initializingRuntimeAccesses.contains(token)
                                    ? .initialize : .assign)
                        )
                    )
                } else if let slot = runtimeStackSlots[root], token == root {
                    let mode: Bytecode.StackStoreMode = stackAddressValues[root] == nil
                        ? .initialize
                        : .assign
                    appendInstruction(
                        .storeStack(slot: slot, source: value, mode: mode)
                    )
                } else {
                    let access = try allocate(type: .address(addressType))
                    appendInstruction(
                        .beginAccess(
                            result: access,
                            address: addressRegister,
                            kind: .modify
                        )
                    )
                    appendInstruction(
                        .storeAddress(
                            address: access,
                            source: value,
                            mode: requestedMode ?? .assign
                        )
                    )
                    appendInstruction(.endAccess(access))
                }
                stackAddressValues[root] = value
                return
            }
            assignStackValue(value, at: token)
            values[token] = value
            values[addressBase(token)] = value
        }

        func resolve(_ token: String, line: Int) throws -> Bytecode.Register {
            if let replacement = try reconstructedOptionalNone(
                for: token,
                line: line
            ) {
                return replacement
            }
            guard let register = values[token] else {
                throw CanonicalSIL.LoweringError.undefinedValue(line: line, value: token)
            }
            return register
        }

        func prepareDirectCallArguments(
            _ tokens: [String],
            conventions: [Bytecode.ParameterConvention],
            line: Int,
            allowsSynthesizedAccess: Bool
        ) throws -> (arguments: [Bytecode.Register], accesses: [Bytecode.Register]) {
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
                appendInstruction(
                    .beginAccess(result: access, address: value, kind: .modify)
                )
                arguments.append(access)
                accesses.append(access)
            }
            return (arguments, accesses)
        }

        func acceptsPhysicalConventions(
            _ physical: [Bytecode.ParameterConvention],
            for binding: CanonicalSIL.DirectCallBinding
        ) -> Bool {
            guard physical.count == binding.parameterConventions.count else {
                return false
            }
            switch binding.abiAdapter {
            case .direct:
                switch binding.target {
                case .function:
                    return physical == binding.parameterConventions
                case .entry, .nativeImport:
                    // Device boundaries own values. A guaranteed physical
                    // parameter is adapted with an explicit VM copy.
                    return !physical.contains(.inout)
                        && binding.parameterConventions.allSatisfy { $0 == .owned }
                }
            case .mutatingValueReceiver:
                guard case .nativeImport = binding.target,
                      physical.last == .inout,
                      !physical.dropLast().contains(.inout)
                else { return false }
                return binding.parameterConventions.allSatisfy { $0 == .owned }
            }
        }

        func resolveDeferredForeignReference(
            _ deferred: (reference: String, loweredType: String),
            genericArguments rawArguments: String,
            line: Int
        ) throws -> ResolvedFunctionReference {
            let genericArguments = splitTopLevel(rawArguments).filter { !$0.isEmpty }
            guard !genericArguments.isEmpty else {
                throw CanonicalSIL.LoweringError.unsupportedInstruction(
                    line: line,
                    text: "pseudogeneric Objective-C call has no concrete specialization"
                )
            }
            let symbol = CanonicalSIL.NativeBridgeSymbols.foreignCall(
                reference: deferred.reference,
                loweredType: deferred.loweredType,
                genericArguments: genericArguments
            )
            guard let binding = directCalls.binding(for: symbol) else {
                if let unavailable = directCalls.unavailableCall(for: symbol) {
                    throw CanonicalSIL.LoweringError.unavailableNativeImport(
                        line: line,
                        mangledName: symbol,
                        canonicalCallee: unavailable.canonicalCallee,
                        reason: unavailable.reason
                    )
                }
                throw CanonicalSIL.LoweringError.unboundCallee(
                    line: line,
                    mangledName: symbol
                )
            }
            let callee = try parseFunctionType(
                deferred.loweredType,
                bridgingTo: (binding.parameterTypes, binding.resultType),
                abiAdapter: binding.abiAdapter
            )
            guard callee.parameters == binding.parameterTypes,
                  acceptsPhysicalConventions(
                      callee.parameterConventions,
                      for: binding
                  ),
                  callee.result == binding.resultType,
                  callee.effects.mayThrow == binding.effects.mayThrow,
                  callee.effects.isAsync == binding.effects.isAsync
            else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: symbol,
                    detail: "specialized foreign reference has \(callee.parameters) "
                        + "\(callee.parameterConventions) -> \(callee.result) "
                        + "\(callee.effects); expected \(binding.parameterTypes) "
                        + "\(binding.parameterConventions) -> \(binding.resultType) "
                        + "\(binding.effects)"
                )
            }
            return .init(
                binding: binding,
                physicalParameterConventions: callee.parameterConventions,
                hasIndirectResult: callee.hasIndirectResult,
                erasedMetatypes: callee.erasedMetatypes,
                usesObjectiveCBridge: true
            )
        }

        func eraseMetatypeArguments(
            _ tokens: [String],
            for reference: ResolvedFunctionReference,
            line: Int
        ) throws -> [String] {
            guard !reference.erasedMetatypes.isEmpty else { return tokens }
            let erasedByIndex = Dictionary(
                uniqueKeysWithValues: reference.erasedMetatypes.map {
                    ($0.physicalIndex, $0.identity)
                }
            )
            guard tokens.count
                    == reference.physicalParameterConventions.count + erasedByIndex.count
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "direct call physical argument count does not match its frozen ABI"
                )
            }
            var logical: [String] = []
            logical.reserveCapacity(reference.physicalParameterConventions.count)
            for (index, token) in tokens.enumerated() {
                if let identity = erasedByIndex[index] {
                    let matches: Bool = switch identity {
                    case let .native(typeID):
                        nativeMetatypeValues[token] == typeID
                    case let .local(key):
                        localMetatypeValues[token] == key
                    }
                    guard matches else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "direct call metatype argument does not match its concrete type"
                        )
                    }
                } else {
                    logical.append(token)
                }
            }
            return logical
        }

        func adaptBoundaryArguments(
            _ arguments: [Bytecode.Register],
            physicalConventions: [Bytecode.ParameterConvention],
            binding: CanonicalSIL.DirectCallBinding
        ) throws -> [Bytecode.Register] {
            switch binding.target {
            case .function:
                return arguments
            case .entry, .nativeImport:
                return try zip(arguments, physicalConventions).map {
                    argument, convention in
                    convention == .borrowed
                        ? try copyOwnedCallArgument(argument)
                        : argument
                }
            }
        }

        func transferOwnedCompilerAddressArguments(
            tokens: [String],
            resolvedArguments: [Bytecode.Register],
            conventions: [Bytecode.ParameterConvention]
        ) throws {
            guard tokens.count == resolvedArguments.count,
                  tokens.count == conventions.count
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "owned call argument transfer has inconsistent arity"
                )
            }
            for ((token, argument), convention) in zip(
                zip(tokens, resolvedArguments),
                conventions
            ) where convention == .owned {
                let root = addressBase(token)
                guard let stored = stackAddressValues[root] else { continue }
                guard stored == argument else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "owned call argument does not match its compiler address storage"
                    )
                }

                // An `@in` SIL argument transfers the value stored at its
                // compiler-only address into the callee. HLBC passes that same
                // value directly, so the later dealloc_stack must not release
                // it a second time.
                stackAddressValues.removeValue(forKey: root)
                for key in [root, token] where values[key] == argument {
                    values.removeValue(forKey: key)
                }
            }
        }

        func appendCompilerAddressMergeArguments(
            target: Bytecode.BlockID,
            arguments: inout [Bytecode.Register]
        ) throws {
            guard let sourceBlock = current?.id,
                  let writes = compilerAddressWrites[sourceBlock]
            else { return }
            for (address, value) in writes.sorted(by: { $0.key < $1.key }) {
                let type = registerTypes[Int(value.rawValue)]
                let merge: Bytecode.Register
                if let existing = compilerAddressMergeRegisters[target]?[address] {
                    guard registerTypes[Int(existing.rawValue)] == type else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "compiler address merge has inconsistent value types"
                        )
                    }
                    merge = existing
                } else {
                    merge = try allocate(type: type)
                    compilerAddressMergeRegisters[target, default: [:]][address] = merge
                    implicitStackValues[target, default: []].append(
                        (address, merge)
                    )
                }
                arguments.append(value)
            }
        }

        func inheritCompilerAddressValue(
            _ value: Bytecode.Register,
            at address: String,
            into targets: [Bytecode.BlockID]
        ) throws {
            let root = addressBase(address)
            guard stackType(at: root) == registerTypes[Int(value.rawValue)] else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "inherited compiler address value has the wrong VM type"
                )
            }
            for target in targets {
                if let existing = inheritedCompilerAddressValues[target]?[root],
                   existing != value {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "compiler address reaches one block with multiple unmerged values"
                    )
                }
                inheritedCompilerAddressValues[target, default: [:]][root] = value
            }
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
            appendInstruction(
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
                appendInstruction(.makeTuple(result: tuple, elements: registers))
                result.append(tuple)
            }
            return result
        }

        func compilerAddressType(_ token: String) -> Bytecode.ValueType? {
            if token == indirectResultAddress { return signature.result }
            if let component = tupleComponentAddresses[token],
               case let .tuple(types) = stackType(at: component.base),
               types.indices.contains(component.index) {
                return types[component.index]
            }
            if let root = optionalPayloadAddressRoots[token],
               let initialization = optionalAddressInitializations[root] {
                return initialization.wrappedType
            }
            if let projection = existentialProjections[token] {
                return projection.concreteType
            }
            if let component = existentialComponentAddresses[token],
               let projection = existentialProjections[component.projection],
               case let .tuple(types) = projection.concreteType,
               types.indices.contains(component.index) {
                return types[component.index]
            }
            if let address = arrayLiteralAddresses[token],
               let pending = pendingArrayLiterals[address.allocation] {
                return pending.elementType
            }
            if let address = arrayLiteralComponentAddresses[token],
               let pending = pendingArrayLiterals[address.allocation],
               case let .tuple(types) = pending.elementType,
               types.indices.contains(address.component) {
                return types[address.component]
            }
            return stackType(at: token)
        }

        func storeConstructedValue(
            _ value: Bytecode.Register,
            at token: String
        ) throws {
            let type = registerTypes[Int(value.rawValue)]
            guard compilerAddressType(token) == type else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "constructed value does not match its SIL address"
                )
            }
            if token == indirectResultAddress {
                guard let slot = indirectResultSlot else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "indirect result has no VM result slot"
                    )
                }
                appendInstruction(
                    .storeStack(slot: slot, source: value, mode: .initialize)
                )
                return
            }
            if let root = takenOptionalPayloadRoots[token] {
                guard case let .optional(wrapped) = compilerAddressType(root),
                      wrapped == type
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "taken Optional payload no longer matches its source storage"
                    )
                }
                assignStackValue(value, at: token)
                let optional = try allocate(type: .optional(wrapped))
                appendInstruction(.makeOptionalSome(result: optional, value: value))
                try storeVMValue(optional, at: root)
                return
            }
            if let root = optionalPayloadAddressRoots[token],
               var initialization = optionalAddressInitializations[root] {
                guard initialization.wrappedType == type,
                      initialization.payload == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional payload address is invalid or initialized twice"
                    )
                }
                initialization.payload = value
                optionalAddressInitializations[root] = initialization
                return
            }
            try storeVMValue(value, at: token)
        }

        func lowerMutatingValueReceiverApply(
            resultToken: String,
            argumentTokens: [String],
            reference: ResolvedFunctionReference,
            line: Int
        ) throws {
            let binding = reference.binding
            guard binding.abiAdapter == .mutatingValueReceiver,
                  case let .nativeImport(requirement) = binding.target,
                  !binding.effects.mayThrow,
                  !binding.effects.isAsync,
                  !resultToken.isEmpty,
                  argumentTokens.count == binding.parameterTypes.count,
                  let receiverType = binding.parameterTypes.last,
                  binding.resultType == receiverType,
                  reference.physicalParameterConventions.last == .inout
            else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "mutating value-receiver call has an invalid frozen ABI"
                )
            }
            let receiverToken = argumentTokens[argumentTokens.count - 1]
            guard compilerAddressType(receiverToken) == receiverType else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "mutating value receiver is not stored at its expected SIL address"
                )
            }
            let valueTokens = Array(argumentTokens.dropLast())
            let valueConventions = Array(
                reference.physicalParameterConventions.dropLast()
            )
            let prepared = try prepareDirectCallArguments(
                valueTokens,
                conventions: valueConventions,
                line: line,
                allowsSynthesizedAccess: true
            )
            var arguments = try zip(prepared.arguments, valueConventions).map {
                argument, convention in
                convention == .borrowed
                    ? try copyOwnedCallArgument(argument)
                    : argument
            }
            let receiver: Bytecode.Register
            if let stored = stackValue(at: receiverToken) {
                receiver = stored
            } else if let address = runtimeAddress(at: receiverToken) {
                let loaded = try allocate(type: receiverType)
                if isScopedRuntimeAddress(receiverToken) {
                    appendInstruction(
                        .loadAddress(result: loaded, address: address, mode: .copy)
                    )
                } else {
                    let access = try allocate(type: .address(receiverType))
                    appendInstruction(
                        .beginAccess(result: access, address: address, kind: .read)
                    )
                    appendInstruction(
                        .loadAddress(result: loaded, address: access, mode: .copy)
                    )
                    appendInstruction(.endAccess(access))
                }
                receiver = loaded
            } else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "mutating value receiver references uninitialized storage"
                )
            }
            guard registerTypes[Int(receiver.rawValue)] == receiverType else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "mutating value receiver storage has the wrong VM type"
                )
            }
            // The adapter consumes the current value and returns its mutated
            // replacement. Passing the original register keeps the HLBC
            // lifetime aligned with Swift's inout writeback instead of
            // leaving the pre-mutation value live beside the replacement.
            arguments.append(receiver)
            guard arguments.map({ registerTypes[Int($0.rawValue)] })
                    == binding.parameterTypes
            else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: binding.mangledName
                )
            }
            let mutated = try allocate(type: receiverType)
            appendInstruction(
                .nativeApply(
                    result: mutated,
                    importID: requirement.id,
                    arguments: arguments
                )
            )
            try transferOwnedCompilerAddressArguments(
                tokens: valueTokens,
                resolvedArguments: prepared.arguments,
                conventions: valueConventions
            )
            try transferOwnedCompilerAddressArguments(
                tokens: [receiverToken],
                resolvedArguments: [receiver],
                conventions: [.owned]
            )
            try storeConstructedValue(mutated, at: receiverToken)
            for access in prepared.accesses.reversed() {
                appendInstruction(.endAccess(access))
            }
            voidValues.insert(resultToken)
        }

        func materializeTupleComponents(
            at base: String,
            tuple: Bytecode.Register
        ) throws {
            guard case let .tuple(types) = registerTypes[Int(tuple.rawValue)] else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "tuple address does not contain a tuple VM value"
                )
            }
            let elements: [Bytecode.Register]
            if let existing = unpackedTuples[base] {
                elements = existing
            } else {
                elements = try types.map { try allocate(type: $0) }
                unpackedTuples[base] = elements
                appendInstruction(.unpackTuple(results: elements, tuple: tuple))
            }
            for (token, component) in tupleComponentAddresses
            where addressBase(component.base) == addressBase(base) {
                guard types.indices.contains(component.index) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "tuple component address is out of bounds"
                    )
                }
                stackAddressTypes[token] = types[component.index]
                stackAddressValues[token] = elements[component.index]
            }
        }

        func storeExistential(
            _ value: Bytecode.Register,
            at token: String
        ) throws {
            guard registerTypes[Int(value.rawValue)] == .any else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "existential projection did not produce Any"
                )
            }
            if let address = arrayLiteralAddresses[token],
               var pending = pendingArrayLiterals[address.allocation] {
                guard pending.elementType == .any,
                      address.index >= 0,
                      address.index < pending.count,
                      pending.elements[address.index] == nil,
                      pending.elementComponents[address.index] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Any array literal store is invalid or duplicated"
                    )
                }
                pending.elements[address.index] = value
                pendingArrayLiterals[address.allocation] = pending
                return
            }
            if let address = arrayLiteralComponentAddresses[token],
               var pending = pendingArrayLiterals[address.allocation],
               case let .tuple(types) = pending.elementType {
                guard address.index >= 0,
                      address.index < pending.count,
                      types.indices.contains(address.component),
                      types[address.component] == .any,
                      pending.elements[address.index] == nil,
                      pending.elementComponents[address.index]?[address.component] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Any tuple component store is invalid or duplicated"
                    )
                }
                pending.elementComponents[address.index, default: [:]][address.component] = value
                pendingArrayLiterals[address.allocation] = pending
                return
            }
            try storeConstructedValue(value, at: token)
        }

        func finishExistentialProjection(
            _ token: String,
            payload: Bytecode.Register
        ) throws {
            guard let projection = existentialProjections.removeValue(forKey: token),
                  registerTypes[Int(payload.rawValue)] == projection.concreteType
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Any payload does not match its concrete SIL type"
                )
            }
            existentialComponentAddresses = existentialComponentAddresses.filter {
                $0.value.projection != token
            }
            let erased = try allocate(type: .any)
            appendInstruction(.eraseToAny(result: erased, value: payload))
            try storeExistential(erased, at: projection.destination)
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
            case .assertionFailure:
                guard genericArguments.isEmpty,
                      arguments.count == 5,
                      let prefix = staticStringValues[arguments[0]],
                      let message = staticStringValues[arguments[1]],
                      staticStringValues[arguments[2]] != nil,
                      values[arguments[3]] != nil,
                      values[arguments[4]] != nil,
                      !prefix.isEmpty,
                      !message.isEmpty
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Swift assertion failure has unsupported metadata"
                    )
                }
                // The following `unreachable` becomes the VM trap terminator.
                // StaticString pointer layout remains compiler-only.
                voidValues.insert(resultToken)

            case .stringLiteral, .characterLiteral:
                guard genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String or Character literal initializer unexpectedly has generic arguments"
                    )
                }
                let expectedMetatypes = intrinsic == .stringLiteral
                    ? metatypeValues
                    : characterMetatypeValues
                guard arguments.count == 4,
                      let literal = stringLiterals[arguments[0]],
                      let expectedByteCount = wordLiterals[arguments[1]],
                      let expectedASCII = boolLiterals[arguments[2]],
                      expectedMetatypes.contains(arguments[3])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String or Character literal initializer has unsupported arguments"
                    )
                }
                let actualByteCount = UInt64(literal.utf8.count)
                let actualASCII = literal.utf8.allSatisfy { $0 < 0x80 }
                guard actualByteCount == expectedByteCount,
                      actualASCII == expectedASCII,
                      intrinsic != .characterLiteral || literal.count == 1
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String or Character literal metadata does not match its payload"
                    )
                }
                let result = try allocate(type: .string)
                values[resultToken] = result
                appendInstruction(.constantString(result: result, value: literal))

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
                appendInstruction(
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
                appendInstruction(.stringConcat(result: result, lhs: lhs, rhs: rhs))

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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                    appendInstruction(
                        .stringify(result: rendered, value: value)
                    )
                default:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "String interpolation payload \(valueType)"
                    )
                }
                let result = try allocate(type: .string)
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(.arrayGet(result: result, array: array, index: index))
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
                appendInstruction(.arrayFirst(result: result, array: array))
                voidValues.insert(resultToken)

            case .sequenceContains:
                guard arguments.count == 2, !genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Sequence.contains has unsupported arguments"
                    )
                }
                let needle = try resolve(arguments[0], line: line)
                let sequence = try resolve(arguments[1], line: line)
                let sequenceType = try parseType(genericArguments)
                if sequenceType == .string,
                   registerTypes[Int(sequence.rawValue)] == .string,
                   registerTypes[Int(needle.rawValue)] == .string {
                    let result = try allocate(type: .bool)
                    values[resultToken] = result
                    appendInstruction(
                        .stringPredicate(
                            result: result,
                            operation: .contains,
                            string: sequence,
                            pattern: needle
                        )
                    )
                    return
                }
                guard case let .array(element) = sequenceType,
                      registerTypes[Int(sequence.rawValue)] == sequenceType,
                      registerTypes[Int(needle.rawValue)] == element
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Sequence.contains types do not match Array.Element"
                    )
                }
                let result = try allocate(type: .bool)
                values[resultToken] = result
                appendInstruction(
                    .arrayContains(result: result, array: sequence, value: needle)
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
                appendInstruction(
                    .arrayAppend(result: result, array: array, value: value)
                )
                assignStackValue(result, at: arguments[1])
                voidValues.insert(resultToken)

            case .collectionMakeIterator:
                if isIntegerRangeType(genericArguments), arguments.count == 2 {
                    let iteratorAddress = addressBase(arguments[0])
                    let rangeAddress = addressBase(arguments[1])
                    guard integerRangeIteratorAddresses.contains(iteratorAddress),
                          integerRangeIteratorStates[iteratorAddress] == nil,
                          integerRangeAddresses.contains(rangeAddress),
                          let range = integerRangeAddressValues[rangeAddress]
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Range<Int>.makeIterator has unsupported arguments"
                        )
                    }
                    let slot = try allocateStackSlot(type: .int64)
                    appendInstruction(
                        .storeStack(
                            slot: slot,
                            source: range.lowerBound,
                            mode: .initialize
                        )
                    )
                    integerRangeIteratorStates[iteratorAddress] = .init(
                        upperBound: range.upperBound,
                        indexSlot: slot
                    )
                    voidValues.insert(resultToken)
                    return
                }
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
                appendInstruction(.constantInteger(result: zero, value: 0))
                let slot = try allocateStackSlot(type: .int64)
                appendInstruction(
                    .storeStack(slot: slot, source: zero, mode: .initialize)
                )
                arrayIteratorStates[iteratorAddress] = .init(
                    elementType: element,
                    array: array,
                    indexSlot: slot
                )
                voidValues.insert(resultToken)

            case .indexingIteratorNext:
                if isIntegerRangeType(genericArguments), arguments.count == 2 {
                    let resultAddress = addressBase(arguments[0])
                    let iteratorAddress = addressBase(arguments[1])
                    guard stackType(at: resultAddress) == .optional(.int64),
                          let state = integerRangeIteratorStates[iteratorAddress],
                          pendingIntegerRangeNextAddresses[resultAddress] == nil
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "IndexingIterator<Range<Int>>.next has unsupported arguments"
                        )
                    }
                    pendingIntegerRangeNextAddresses[resultAddress] = state
                    voidValues.insert(resultToken)
                    return
                }
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(.constantInteger(result: zero, value: 0))
                let slot = try allocateStackSlot(type: .int64)
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
                    .makeArray(
                        result: result,
                        elements: elements
                    )
                )
                pendingArrayLiterals.removeValue(forKey: allocation)
            }
        }

        func lowerObjectiveCBridgeIntrinsic(
            _ intrinsic: ObjectiveCBridgeIntrinsic,
            resultToken: String,
            genericArguments: String,
            argumentText: String,
            loweredType: String,
            line: Int
        ) throws {
            let arguments = try parseApplyValueTokens(argumentText, line: line)
            guard !resultToken.isEmpty,
                  intrinsic.accepts(loweredType: loweredType)
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Objective-C bridge has an unexpected specialization or signature"
                )
            }

            if intrinsic == .arrayToObjectiveC || intrinsic == .arrayFromObjectiveC {
                guard !genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Objective-C Array bridge has no concrete element type"
                    )
                }
                let element = try parseType(genericArguments)
                let source: Bytecode.Register
                switch intrinsic {
                case .arrayToObjectiveC:
                    guard arguments.count == 1,
                          let value = values[arguments[0]]
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array-to-Objective-C bridge has unsupported arguments"
                        )
                    }
                    source = value
                case .arrayFromObjectiveC:
                    guard arguments.count == 2,
                          arrayMetatypeValues[arguments[1]] == element,
                          let value = values[arguments[0]]
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Objective-C-to-Array bridge has unsupported arguments"
                        )
                    }
                    source = value
                case .stringToObjectiveC, .stringFromObjectiveC:
                    preconditionFailure("not an Array bridge")
                }
                guard registerTypes[Int(source.rawValue)] == .array(element) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Objective-C Array bridge payload has the wrong Swift element type"
                    )
                }
                let result = try allocate(type: .array(element))
                values[resultToken] = result
                appendInstruction(.copyValue(result: result, source: source))
                return
            }
            guard genericArguments.isEmpty else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Objective-C String bridge has an unexpected specialization"
                )
            }

            let source: Bytecode.Register
            switch intrinsic {
            case .stringToObjectiveC:
                guard arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String-to-Objective-C bridge has unsupported arguments"
                    )
                }
                source = try resolve(arguments[0], line: line)
            case .stringFromObjectiveC:
                guard arguments.count == 2,
                      metatypeValues.contains(arguments[1]),
                      let optional = values[arguments[0]],
                      registerTypes[Int(optional.rawValue)] == .optional(.string),
                      let payload = knownOptionalSomePayloads[arguments[0]]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Objective-C-to-String bridge is not fed by a proven Optional.some"
                    )
                }
                source = payload
            case .arrayToObjectiveC, .arrayFromObjectiveC:
                preconditionFailure("handled before String bridge lowering")
            }
            guard registerTypes[Int(source.rawValue)] == .string else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Objective-C String bridge payload is not a Swift String"
                )
            }
            let result = try allocate(type: .string)
            values[resultToken] = result
            appendInstruction(.copyValue(result: result, source: source))
        }

        for (lineIndex, originalRawLine) in rawLines.enumerated() {
            let rawLine = nsErrorBridges.replacementLines[lineIndex]
                ?? originalRawLine
            let sourceLine = lineIndex + 1
            let parsedLine = if function.hasStrippedDebugMetadata {
                CanonicalSIL.DebugMetadata.ParsedLine(
                    instruction: CanonicalSIL.DebugMetadata.strippingComment(from: rawLine)
                        .trimmingCharacters(in: .whitespaces),
                    location: nil
                )
            } else {
                try CanonicalSIL.DebugMetadata.parse(rawLine, scopes: [:])
            }
            currentSourceLocation = parsedLine.location
                ?? debugLineLocations[sourceLine]
            let line = parsedLine.instruction
            if nsErrorBridges.skippedLines.contains(lineIndex) { continue }
            if let borrowEnd = match(
                line,
                pattern: #"^end_borrow (%[0-9]+)$"#
            ) {
                borrowedValueTokens.remove(borrowEnd[0])
                if let value = preservedNativeConversionValues.removeValue(
                    forKey: borrowEnd[0]
                ) {
                    appendInstruction(.destroyValue(value))
                }
                continue
            }
            guard !line.isEmpty,
                  !line.hasPrefix("["),
                  !line.hasPrefix("debug_value"),
                  !line.hasPrefix("debug_step"),
                  !line.hasPrefix("fix_lifetime")
            else { continue }

            let bridgedBlockParameterTypes: [Bytecode.ValueType]? = {
                guard let number = parseBlockNumber(line),
                      let sourceToken = optionalSourceBySomeBlock[
                        .init(rawValue: number)
                      ],
                      let source = values[sourceToken],
                      case let .optional(wrapped) = registerTypes[Int(source.rawValue)]
                else { return nil }
                return [wrapped]
            }()
            if let block = try parseBlockHeader(
                line,
                entryParameterTypes: entryBlock == nil
                    ? signature.parameters
                    : nil,
                erasedMetatypes: entryBlock == nil
                    ? signature.erasedMetatypes
                    : [],
                bridgedParameterTypes: bridgedBlockParameterTypes,
                indirectResultType: entryBlock == nil && signature.hasIndirectResult
                    ? signature.result
                    : nil,
                suppressVoidParameter: parseBlockNumber(line).map {
                    indirectTryNormalBlocks.contains(.init(rawValue: $0))
                } ?? false,
                allocate: allocate
            ) {
                finishCurrent()
                var loweredBlock = block.block
                let explicitParameters = block.parameters
                if indirectTryNormalBlocks.remove(block.block.id) != nil {
                    guard explicitParameters.isEmpty,
                          let parameter = block.suppressedVoidParameter
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect try_apply normal block does not carry its Void SIL token"
                        )
                    }
                    voidValues.insert(parameter)
                } else if block.suppressedVoidParameter != nil {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "block unexpectedly suppresses a Void SIL parameter"
                    )
                }
                if let inherited = inheritedCompilerAddressValues[block.block.id] {
                    for (address, value) in inherited {
                        stackAddressValues[address] = value
                        values[address] = value
                    }
                }
                if let implicit = implicitStackValues[block.block.id] {
                    loweredBlock.parameters.append(contentsOf: implicit.map(\.register))
                    for item in implicit {
                        stackAddressValues[addressBase(item.address)] = item.register
                        values[item.address] = item.register
                    }
                }
                current = loweredBlock
                for (token, identity) in block.erasedMetatypeParameters {
                    switch identity {
                    case let .native(typeID):
                        nativeMetatypeValues[token] = typeID
                    case let .local(key):
                        localMetatypeValues[token] = key
                    }
                }
                for (silValue, register) in explicitParameters {
                    values[silValue] = register
                }
                compilerOptionalVoidValues.formUnion(
                    block.compilerOptionalVoidParameters
                )
                if let implicit = implicitStackValues[block.block.id] {
                    for item in implicit {
                        if optionalPayloadAddressRoots[item.address] != nil {
                            try storeConstructedValue(
                                item.register,
                                at: item.address
                            )
                        }
                        guard case .tuple = registerTypes[Int(item.register.rawValue)] else {
                            continue
                        }
                        try materializeTupleComponents(
                            at: item.address,
                            tuple: item.register
                        )
                    }
                }
                for (token, type) in block.indirectValueParameters {
                    guard let register = values[token] else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect value parameter has no VM register"
                        )
                    }
                    stackAddressTypes[token] = type
                    stackAddressValues[token] = register
                }
                if entryBlock == nil {
                    entryBlock = loweredBlock.id
                    if signature.hasIndirectResult {
                        guard supportsIndirectResult(signature.result),
                              let address = block.indirectResultAddress
                        else {
                            throw CanonicalSIL.LoweringError.unsupportedType(
                                "indirect result \(signature.result)"
                            )
                        }
                        indirectResultAddress = address
                        indirectResultSlot = try allocateStackSlot(
                            type: signature.result
                        )
                    } else if block.indirectResultAddress != nil {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "entry block contains an unexpected indirect result"
                        )
                    }
                    parameterRegisters = loweredBlock.parameters
                    guard parameterRegisters.count == signature.parameters.count else {
                        throw CanonicalSIL.LoweringError.malformedSIL("entry parameter count does not match function type")
                    }
                    for (register, expected) in zip(parameterRegisters, signature.parameters)
                    where registerTypes[Int(register.rawValue)] != expected {
                        throw CanonicalSIL.LoweringError.malformedSIL("entry parameter type does not match function type")
                    }
                    for ((parameter, convention), type) in zip(
                        zip(explicitParameters, signature.parameterConventions),
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

            if let bridge = nsErrorBridges.callsByLine[lineIndex] {
                let binding = bridge.binding
                let resolved = try bridge.argumentTokens.map {
                    try resolve($0, line: sourceLine)
                }
                let physicalConventions = zip(
                    bridge.argumentTokens,
                    resolved
                ).map { token, value -> Bytecode.ParameterConvention in
                    let type = registerTypes[Int(value.rawValue)]
                    return type.requiresLinearOwnership
                        && (borrowedValueTokens.contains(token)
                            || isBorrowedParameter(value))
                        ? .borrowed : .owned
                }
                guard acceptsPhysicalConventions(
                    physicalConventions,
                    for: binding
                ) else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName,
                        detail: "NSError bridge ownership does not match its logical ABI"
                    )
                }
                let prepared = try prepareDirectCallArguments(
                    bridge.argumentTokens,
                    conventions: physicalConventions,
                    line: sourceLine,
                    allowsSynthesizedAccess: false
                )
                let arguments = try adaptBoundaryArguments(
                    prepared.arguments,
                    physicalConventions: physicalConventions,
                    binding: binding
                )
                guard arguments.map({ registerTypes[Int($0.rawValue)] })
                        == binding.parameterTypes,
                      case let .nativeImport(requirement) = binding.target
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                appendInstruction(
                    .nativeTryApply(
                        importID: requirement.id,
                        arguments: arguments,
                        normalTarget: bridge.normalTarget,
                        errorTarget: bridge.errorTarget
                    )
                )
                for token in bridge.argumentTokens {
                    preservedNativeConversionValues.removeValue(forKey: token)
                }
                continue
            }

            if line == "unreachable" {
                appendInstruction(.trap(.explicit("Swift unreachable")))
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
                pattern: #"^(%[0-9]+) = string_literal objc_selector \"(.*)\"$"#
            ) {
                selectorLiterals[literal[0]] = try decodeSILUTF8Literal(literal[1])
                continue
            }

            if let conversion = match(
                line,
                pattern: #"^(%[0-9]+) = builtin \"ptrtoint_Word\"\((%[0-9]+)\) : \$Builtin\.Word$"#
            ), let literal = stringLiterals[conversion[1]] {
                staticStringPointers[conversion[0]] = literal
                continue
            }

            if let construction = match(
                line,
                pattern: #"^(%[0-9]+) = struct \$StaticString \((%[0-9]+), (%[0-9]+), (%[0-9]+)\)$"#
            ), let literal = staticStringPointers[construction[1]],
               let expectedCount = wordLiterals[construction[2]],
               let flag = integerLiterals[construction[3]],
               flag.bitWidth == 8,
               [0, 2].contains(flag.value),
               UInt64(literal.utf8.count) == expectedCount {
                staticStringValues[construction[0]] = literal
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
                pattern: #"^(%[0-9]+) = metatype \$@thin (?:Swift\.)?Array<(.+)>\.Type$"#
            ) {
                arrayMetatypeValues[metatype[0]] = try parseType(metatype[1])
                continue
            }

            if let metatype = match(
                line,
                pattern: #"^(%[0-9]+) = metatype \$@thin (?:Swift\.)?Character\.Type$"#
            ) {
                characterMetatypeValues.insert(metatype[0])
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
                pattern: #"^(%[0-9]+) = metatype \$@(?:thin|thick|objc_metatype) (.+)\.Type$"#
            ), let key = typeEnvironment.localKey(for: metatype[1]) {
                localMetatypeValues[metatype[0]] = key
                if let superclass = try typeEnvironment.hostedSuperclass(for: key) {
                    hostedMetatypeValues[metatype[0]] = (key, superclass.typeID)
                }
                continue
            }

            if let metatype = match(
                line,
                pattern: #"^(%[0-9]+) = metatype \$@(?:thin|thick|objc_metatype) (.+)\.Type$"#
            ), let type = try? parseType(metatype[1]),
               case let .native(typeID) = type {
                nativeMetatypeValues[metatype[0]] = typeID
                continue
            }

            if let cast = match(
                line,
                pattern: #"^(%[0-9]+) = upcast (%[0-9]+) to \$@(?:thick|objc_metatype) (.+)\.Type$"#
            ), let key = localMetatypeValues[cast[1]],
               case let .native(targetType) = try parseType(cast[2]),
               try typeEnvironment.hostedSuperclass(for: key)?.typeID == targetType {
                hostedMetatypeValues[cast[0]] = (key, targetType)
                continue
            }

            if let allocation = match(
                line,
                pattern: #"^(%[0-9]+) = alloc_ref \$(.+)$"#
            ), let key = typeEnvironment.localKey(for: allocation[1]),
               typeEnvironment.isClass(key) {
                let result = try allocate(type: .local(key))
                values[allocation[0]] = result
                appendInstruction(.allocateObject(result: result))
                continue
            }

            if let allocation = match(
                line,
                pattern: #"^(%[0-9]+) = alloc_ref_dynamic(?: \[objc\])? (%[0-9]+), \$(.+)$"#
            ), let key = typeEnvironment.localKey(for: allocation[2]),
               typeEnvironment.isClass(key) {
                guard localMetatypeValues[allocation[1]] == key else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "dynamic local class allocation uses the wrong metatype"
                    )
                }
                let result = try allocate(type: .local(key))
                values[allocation[0]] = result
                appendInstruction(.allocateObject(result: result))
                continue
            }

            if let global = match(
                line,
                pattern: #"^(%[0-9]+) = global_addr @([^\s:]+) : \$(?:\*)(.+)$"#
            ) {
                let symbol = CanonicalSIL.NativeBridgeSymbols.importedGlobal(
                    symbol: global[1],
                    loweredType: global[2]
                )
                guard let binding = directCalls.binding(for: symbol),
                      binding.parameterTypes.isEmpty,
                      binding.resultType != .void,
                      !binding.effects.mayThrow,
                      !binding.effects.isAsync,
                      case .nativeImport = binding.target
                else {
                    throw CanonicalSIL.LoweringError.unboundCallee(
                        line: sourceLine,
                        mangledName: symbol
                    )
                }
                let physicalType = try parsePhysicalType(
                    global[2],
                    bridgedTo: binding.resultType
                )
                guard physicalType == binding.resultType else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: symbol
                    )
                }
                stackAddressTypes[global[0]] = binding.resultType
                nativeGlobalAddresses[global[0]] = binding
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
                if isIntegerRangeIteratorType(stack[1]) {
                    integerRangeIteratorAddresses.insert(stack[0])
                    continue
                }
                if isIntegerRangeType(stack[1]) {
                    integerRangeAddresses.insert(stack[0])
                    continue
                }
                if isCharacterType(stack[1]) {
                    // Character literals are represented as one-grapheme VM
                    // strings. This avoids importing Swift.Character layout.
                    stackAddressTypes[stack[0]] = .string
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
                    appendInstruction(.stackAddress(result: address, slot: slot))
                }
                continue
            }

            if let copy = match(
                line,
                pattern: #"^copy_addr(?: \[(take)\])? (%[0-9]+) to (?:\[(init|assign)\] )?(%[0-9]+)$"#
            ) {
                let blockID = current?.id
                let sourceIsKnownSome = isKnownSomeOptionalAddress(
                    copy[1],
                    in: blockID
                )
                let sourceType = stackType(at: copy[1])
                let destinationType = compilerAddressType(copy[3])
                guard let source = try resolvedStackValue(
                    at: copy[1],
                    line: sourceLine
                ),
                      sourceType == destinationType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "copy_addr at line \(sourceLine) requires initialized matching storage; "
                            + "source \(copy[1]) is \(String(describing: sourceType)), "
                            + "destination \(copy[3]) is \(String(describing: destinationType))"
                    )
                }
                let value: Bytecode.Register
                let type = registerTypes[Int(source.rawValue)]
                if type.isTrivial || copy[0] == "take" {
                    value = source
                } else {
                    value = try allocate(type: type)
                    appendInstruction(.copyValue(result: value, source: source))
                }
                if type == .any {
                    try storeExistential(value, at: copy[3])
                } else {
                    try storeConstructedValue(value, at: copy[3])
                }
                if let blockID, case .optional = type {
                    setKnownSomeOptionalAddress(
                        copy[3],
                        in: blockID,
                        isKnownSome: sourceIsKnownSome
                    )
                    if copy[0] == "take" {
                        setKnownSomeOptionalAddress(
                            copy[1],
                            in: blockID,
                            isKnownSome: false
                        )
                    }
                }
                if copy[0] == "take" {
                    stackAddressValues.removeValue(forKey: addressBase(copy[1]))
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
                borrowedValueTokens.insert(borrow[0])
                continue
            }

            if let access = match(
                line,
                pattern: #"^(%[0-9]+) = begin_access \[(read|modify|init)\] \[(?:static|dynamic)\] (%[0-9]+)$"#
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
                    let kind: Bytecode.AccessKind = access[1] == "read" ? .read : .modify
                    appendInstruction(
                        .beginAccess(result: result, address: sourceAddress, kind: kind)
                    )
                    addressAliases[access[0]] = base
                    runtimeAddressValues[access[0]] = result
                    runtimeAddressPointees[access[0]] = pointee
                    scopedRuntimeAddresses.insert(access[0])
                    if access[1] == "init" {
                        initializingRuntimeAccesses.insert(access[0])
                    }
                    values[access[0]] = result
                    continue
                }
                guard stackAddressTypes[base] != nil
                        || pendingArrayIteratorTypes[base] != nil
                        || integerRangeIteratorAddresses.contains(base)
                        || pendingDictionaryIteratorTypes[base] != nil
                        || pendingStringInterpolationAddresses.contains(base)
                        || nativePropertyAddresses[base] != nil
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
                    initializingRuntimeAccesses.remove(access[0])
                    scopedRuntimeAddresses.remove(access[0])
                    runtimeAddressValues.removeValue(forKey: access[0])
                    runtimeAddressPointees.removeValue(forKey: access[0])
                    values.removeValue(forKey: access[0])
                    addressAliases.removeValue(forKey: access[0])
                    continue
                }
                if scopedRuntimeAddresses.remove(access[0]) != nil,
                   let register = runtimeAddressValues.removeValue(forKey: access[0]) {
                    initializingRuntimeAccesses.remove(access[0])
                    appendInstruction(.endAccess(register))
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
                if integerRangeAddresses.remove(address) != nil {
                    guard integerRangeAddressValues.removeValue(forKey: address) != nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Range<Int> storage is deallocated before initialization"
                        )
                    }
                    continue
                }
                if integerRangeIteratorAddresses.remove(address) != nil {
                    guard let state = integerRangeIteratorStates.removeValue(forKey: address)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Range<Int> iterator storage is deallocated before initialization"
                        )
                    }
                    appendInstruction(.destroyStack(state.indexSlot))
                    continue
                }
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
                if let slot = runtimeStackSlots[address] {
                    if stackAddressValues[address] != nil {
                        appendInstruction(.destroyStack(slot))
                    }
                    guard stackAddressTypes[address] != nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "runtime stack address lost its declared type"
                        )
                    }
                    // SIL prints mutually exclusive successor blocks in one
                    // linear stream. Keep the compile-time slot declaration
                    // and initialization evidence so each successor can emit
                    // its own destroy_stack; HLBC verification then proves
                    // exactly one destroy occurs on every runtime path.
                    continue
                }
                guard stackAddressTypes[address] != nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "dealloc_stack references an unsupported address"
                    )
                }
                takenOptionalPayloadRoots = takenOptionalPayloadRoots.filter {
                    addressBase($0.value) != address
                }
                // Swift treats some imported C values as trivial even though
                // HLBC represents them with an owned native box. Release any
                // compiler-only storage that SIL legitimately deallocates
                // without a preceding destroy_addr.
                if let value = stackAddressValues.removeValue(forKey: address),
                   registerTypes[Int(value.rawValue)].requiresLinearOwnership {
                    appendInstruction(.destroyValue(value))
                }
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
                    appendInstruction(.constantBool(result: register, value: bool))
                } else {
                    let register = try allocate(type: .integer(bitWidth: width, signed: true))
                    values[literal[0]] = register
                    appendInstruction(.constantInteger(result: register, value: value))
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
                appendInstruction(.constantFloat(result: result, value: value))
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                appendInstruction(
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
                pattern: #"^(%[0-9]+) = ref_element_addr(?: \[immutable\])? (%[0-9]+), #(.+)\.([^.]+)$"#
            ) {
                let ownerType = projection[2]
                let property = projection[3]
                if let key = typeEnvironment.localKey(for: ownerType),
                   typeEnvironment.isClass(key) {
                    let object = try resolve(projection[1], line: sourceLine)
                    guard registerTypes[Int(object.rawValue)] == .local(key) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "class field receiver does not match \(key)"
                        )
                    }
                    let fields = try typeEnvironment.classFields(for: key)
                    let index = try typeEnvironment.storedFieldIndex(
                        type: key,
                        name: property
                    )
                    guard let fieldIndex = UInt32(exactly: index) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "local class field index exceeds UInt32"
                        )
                    }
                    let pointee = fields[index].type
                    let result = try allocate(type: .address(pointee))
                    appendInstruction(
                        .projectObjectAddress(
                            result: result,
                            object: object,
                            fieldIndex: fieldIndex
                        )
                    )
                    runtimeAddressValues[projection[0]] = result
                    runtimeAddressPointees[projection[0]] = pointee
                    addressAliases[projection[0]] = projection[0]
                    values[projection[0]] = result
                    continue
                }
                let getterSymbol = CanonicalSIL.NativePropertySymbol.getter(
                    ownerType: ownerType,
                    property: property
                )
                let setterSymbol = CanonicalSIL.NativePropertySymbol.setter(
                    ownerType: ownerType,
                    property: property
                )
                let getter = directCalls.binding(for: getterSymbol)
                let setter = directCalls.binding(for: setterSymbol)
                let unavailableGetter = directCalls.unavailableCall(for: getterSymbol)
                let unavailableSetter = directCalls.unavailableCall(for: setterSymbol)
                guard getter != nil || setter != nil
                        || unavailableGetter != nil || unavailableSetter != nil
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let receiver = try resolve(projection[1], line: sourceLine)
                let receiverType = registerTypes[Int(receiver.rawValue)]
                guard case .native = receiverType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "native property receiver is not a frozen native reference"
                    )
                }
                let getterType = getter?.resultType
                let setterType = setter?.parameterTypes.first
                guard let valueType = getterType ?? setterType,
                      getterType == nil || getterType != .void,
                      setterType == nil || setterType != .void,
                      getterType == nil || setterType == nil || getterType == setterType,
                      getter.map({ binding in
                        binding.parameterTypes == [receiverType]
                            && binding.parameterConventions == [.owned]
                            && !binding.effects.mayThrow
                            && !binding.effects.isAsync
                            && { if case .nativeImport = binding.target { true } else { false } }()
                      }) ?? true,
                      setter.map({ binding in
                        binding.parameterTypes == [valueType, receiverType]
                            && binding.parameterConventions == [.owned, .owned]
                            && binding.resultType == .void
                            && !binding.effects.mayThrow
                            && !binding.effects.isAsync
                            && { if case .nativeImport = binding.target { true } else { false } }()
                      }) ?? true
                else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "stored property \(ownerType).\(property) has an invalid exact binding"
                    )
                }
                nativePropertyAddresses[projection[0]] = .init(
                    receiver: receiver,
                    valueType: valueType,
                    getter: getter,
                    setter: setter,
                    unavailableGetter: unavailableGetter,
                    unavailableSetter: unavailableSetter
                )
                continue
            }

            if let projection = match(
                line,
                pattern: #"^(%[0-9]+) = struct_element_addr (%[0-9]+), #(.+)\.([^.]+)$"#
            ) {
                let scalarWrappers: Set<String> = [
                    "Int", "Int8", "Int16", "Int32", "Int64",
                    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
                    "Bool", "Float", "Double", "CGFloat",
                ]
                if scalarWrappers.contains(projection[2]),
                   projection[3] == "_value",
                   let property = nativePropertyAddresses[addressBase(projection[1])] {
                    nativePropertyAddresses[projection[0]] = property
                    addressAliases[projection[0]] = addressBase(projection[1])
                    continue
                }
                if let structure = stackValue(at: projection[1]),
                   case let .local(key) = stackType(at: projection[1]),
                   typeEnvironment.localKey(for: projection[2]) == key {
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
                    let result = try allocate(type: fields[index].type)
                    appendInstruction(
                        .structExtract(
                            result: result,
                            structure: structure,
                            fieldIndex: fieldIndex
                        )
                    )
                    stackAddressTypes[projection[0]] = fields[index].type
                    stackAddressValues[projection[0]] = result
                    continue
                }
                guard let base = runtimeAddress(at: projection[1]),
                      let basePointee = stackType(at: projection[1])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "struct_element_addr references an unsupported address"
                    )
                }
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
                appendInstruction(
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

            if let pointer = match(
                line,
                pattern: #"^(%[0-9]+) = struct \$OpaquePointer \((%[0-9]+)\)$"#
            ), let selector = selectorLiterals[pointer[1]] {
                selectorOpaquePointers[pointer[0]] = selector
                continue
            }

            if let construction = match(
                line,
                pattern: #"^(%[0-9]+) = struct \$(?:ObjectiveC\.)?Selector \((%[0-9]+)\)$"#
            ), let selector = selectorOpaquePointers[construction[1]],
               case let .native(typeID) = try parseType("ObjectiveC.Selector") {
                let symbol = CanonicalSIL.NativeBridgeSymbols.selectorInitializer(for: typeID)
                guard let binding = directCalls.binding(for: symbol),
                      binding.parameterTypes == [.string],
                      binding.parameterConventions == [.owned],
                      binding.resultType == .native(typeID),
                      !binding.effects.mayThrow,
                      !binding.effects.isAsync,
                      case let .nativeImport(requirement) = binding.target
                else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "Selector construction has no exact frozen initializer"
                    )
                }
                let string = try allocate(type: .string)
                appendInstruction(.constantString(result: string, value: selector))
                let result = try allocate(type: .native(typeID))
                values[construction[0]] = result
                appendInstruction(
                    .nativeApply(
                        result: result,
                        importID: requirement.id,
                        arguments: [string]
                    )
                )
                continue
            }

            if let alias = match(
                line,
                pattern: #"^(%[0-9]+) = struct_extract (%[0-9]+), #(?:Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Bool|Float|Double|CGFloat)\._value$"#
            ) {
                values[alias[0]] = try resolve(alias[1], line: sourceLine)
                continue
            }
            if let alias = match(
                line,
                pattern: #"^(%[0-9]+) = struct \$(Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Bool|Float|Double|CGFloat) \((%[0-9]+)\)$"#
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
                        appendInstruction(
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

            if hostedMethodContext?.abi == .voidBool,
               let bridge = match(
                   line,
                   pattern: #"^(%[0-9]+) = struct \$(?:ObjectiveC\.)?ObjCBool \((%[0-9]+)\)$"#
               ) {
                let value = try resolve(bridge[1], line: sourceLine)
                guard registerTypes[Int(value.rawValue)] == .bool else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "hosted Objective-C Bool bridge does not wrap Swift.Bool"
                    )
                }
                // ObjCBool is only the physical foreign-call wrapper. The
                // bounded Runtime trampoline consumes the logical Bool.
                values[bridge[0]] = value
                continue
            }

            if let construction = match(
                line,
                pattern: #"^(%[0-9]+) = struct \$(.+) \((%[0-9]+)\)$"#
            ), case let .native(typeID) = try parseType(construction[1]) {
                let operand = try resolve(construction[2], line: sourceLine)
                let operandType = registerTypes[Int(operand.rawValue)]
                let symbol = CanonicalSIL.NativeBridgeSymbols.rawValueInitializer(
                    for: typeID
                )
                guard let binding = directCalls.binding(for: symbol),
                      binding.parameterTypes == [operandType],
                      binding.parameterConventions == [.owned],
                      binding.resultType == .native(typeID),
                      !binding.effects.mayThrow,
                      !binding.effects.isAsync,
                      case let .nativeImport(requirement) = binding.target
                else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "native raw-value construction has no exact frozen initializer"
                    )
                }
                let result = try allocate(type: .native(typeID))
                values[construction[0]] = result
                appendInstruction(
                    .nativeApply(
                        result: result,
                        importID: requirement.id,
                        arguments: [try copyOwnedCallArgument(operand)]
                    )
                )
                continue
            }

            if let cast = match(
                line,
                pattern: #"^(%[0-9]+) = init_existential_ref (%[0-9]+) : \$(.+) : \$.+, \$(?:Swift\.)?AnyObject$"#
            ) {
                let source = try resolve(cast[1], line: sourceLine)
                guard case let .native(sourceType) = registerTypes[Int(source.rawValue)],
                      case let .native(targetType) = try parseType("Swift.AnyObject"),
                      sourceType != targetType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "AnyObject erasure source is not an exact frozen reference"
                    )
                }
                let symbol = CanonicalSIL.NativeBridgeSymbols.upcast(
                    from: sourceType,
                    to: targetType
                )
                guard let binding = directCalls.binding(for: symbol),
                      binding.parameterTypes == [.native(sourceType)],
                      binding.parameterConventions == [.owned],
                      binding.resultType == .native(targetType),
                      !binding.effects.mayThrow,
                      !binding.effects.isAsync,
                      case let .nativeImport(requirement) = binding.target
                else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "AnyObject erasure has no exact frozen bridge"
                    )
                }
                let conversion = try prepareNativeReferenceConversion(
                    sourceToken: cast[1],
                    source: source,
                    lineIndex: lineIndex
                )
                let result = try allocate(type: .native(targetType))
                values[cast[0]] = result
                if conversion.tracksResultLifetime {
                    preservedNativeConversionValues[cast[0]] = result
                }
                appendInstruction(
                    .nativeApply(
                        result: result,
                        importID: requirement.id,
                        arguments: [conversion.argument]
                    )
                )
                releasePreservedNativeConversionsAfterLastUse(
                    [cast[1]],
                    after: lineIndex
                )
                continue
            }

            if let cast = match(
                line,
                pattern: #"^(%[0-9]+) = upcast (%[0-9]+) to \$(.+)$"#
            ) {
                if let allocation = hostedAllocationObjects[cast[1]] {
                    guard case let .native(targetType) = try parseType(cast[2]),
                          try typeEnvironment.hostedSuperclass(
                            for: allocation.key
                          )?.typeID == targetType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "hosted class allocation is upcast to a different superclass"
                        )
                    }
                    values[cast[1]] = allocation.object
                    hostedAllocationObjects.removeValue(forKey: cast[1])
                }
                let source = try resolve(cast[1], line: sourceLine)
                if case let .local(key) = registerTypes[Int(source.rawValue)],
                   case let .native(targetType) = try parseType(cast[2]),
                   try typeEnvironment.hostedSuperclass(for: key)?.typeID
                    == targetType {
                    let result = try allocate(type: .native(targetType))
                    values[cast[0]] = result
                    appendInstruction(
                        .projectHostedObject(result: result, object: source)
                    )
                    continue
                }
                guard case let .native(sourceType) = registerTypes[Int(source.rawValue)],
                      case let .native(targetType) = try parseType(cast[2]),
                      sourceType != targetType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "native upcast source or destination is not an exact frozen reference"
                    )
                }
                let symbol = CanonicalSIL.NativeBridgeSymbols.upcast(
                    from: sourceType,
                    to: targetType
                )
                guard let binding = directCalls.binding(for: symbol),
                      binding.parameterTypes == [.native(sourceType)],
                      binding.parameterConventions == [.owned],
                      binding.resultType == .native(targetType),
                      !binding.effects.mayThrow,
                      !binding.effects.isAsync,
                      case let .nativeImport(requirement) = binding.target
                else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "native upcast has no exact frozen bridge"
                    )
                }
                let conversion = try prepareNativeReferenceConversion(
                    sourceToken: cast[1],
                    source: source,
                    lineIndex: lineIndex
                )
                let result = try allocate(type: .native(targetType))
                values[cast[0]] = result
                if conversion.tracksResultLifetime {
                    preservedNativeConversionValues[cast[0]] = result
                }
                appendInstruction(
                    .nativeApply(
                        result: result,
                        importID: requirement.id,
                        arguments: [conversion.argument]
                    )
                )
                releasePreservedNativeConversionsAfterLastUse(
                    [cast[1]],
                    after: lineIndex
                )
                continue
            }

            if let construction = match(
                line,
                pattern: #"^(%[0-9]+) = struct \$((?:Swift\.)?Range<(?:Swift\.)?Int>) \((.*)\)$"#
            ) {
                let operands = try parseApplyValueTokens(
                    construction[2],
                    line: sourceLine
                )
                guard operands.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Range<Int> construction requires lower and upper bounds"
                    )
                }
                let lower = try resolve(operands[0], line: sourceLine)
                let upper = try resolve(operands[1], line: sourceLine)
                guard registerTypes[Int(lower.rawValue)] == .int64,
                      registerTypes[Int(upper.rawValue)] == .int64
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Range<Int> bounds must both be Int"
                    )
                }
                integerRangeValues[construction[0]] = .init(
                    lowerBound: lower,
                    upperBound: upper
                )
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
                appendInstruction(
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
                appendInstruction(
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
                    appendInstruction(
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
                pattern: #"^(%[0-9]+) = (?:objc_)?super_method (%[0-9]+), #([^.\s:]+)\.([^!\s:]+)(?:!foreign)? : .*, \$(.+)$"#
            ), let context = hostedMethodContext {
                let selectorBase = context.selector.hasSuffix(":")
                    ? String(context.selector.dropLast())
                    : context.selector
                guard reference[3] == selectorBase else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "hosted method \(context.selector) calls a different superclass selector \(reference[3])"
                    )
                }
                hostedSuperReferences[reference[0]] = .init(
                    context: context,
                    objectToken: reference[1]
                )
                continue
            }

            if let reference = match(
                line,
                pattern: #"^(%[0-9]+) = (?:objc|objc_super|class)_method .*, (#[^\s:]+) : .*, \$(.+)$"#
            ) {
                let usesObjectiveCBridge = reference[1].hasSuffix("foreign")
                if usesObjectiveCBridge,
                   reference[2].contains("@pseudogeneric")
                    || reference[2].contains("τ_") {
                    deferredForeignReferences[reference[0]] = (
                        reference: reference[1],
                        loweredType: reference[2]
                    )
                    continue
                }
                let exactForeignSymbol = CanonicalSIL.NativeBridgeSymbols.foreignCall(
                    reference: reference[1],
                    loweredType: reference[2]
                )
                let resolvedSymbol = directCalls.binding(for: reference[1]) == nil
                    ? exactForeignSymbol : reference[1]
                guard let binding = directCalls.binding(for: resolvedSymbol) else {
                    if let unavailable = directCalls.unavailableCall(for: resolvedSymbol)
                        ?? directCalls.unavailableCall(for: reference[1]) {
                        throw CanonicalSIL.LoweringError.unavailableNativeImport(
                            line: sourceLine,
                            mangledName: resolvedSymbol,
                            canonicalCallee: unavailable.canonicalCallee,
                            reason: unavailable.reason
                        )
                    }
                    throw CanonicalSIL.LoweringError.unboundCallee(
                        line: sourceLine,
                        mangledName: exactForeignSymbol
                    )
                }
                let physicalBridge: (
                    parameters: [Bytecode.ValueType], result: Bytecode.ValueType
                )? = usesObjectiveCBridge
                    ? (binding.parameterTypes, binding.resultType)
                    : nil
                let callee = try parseFunctionType(
                    reference[2],
                    bridgingTo: physicalBridge,
                    abiAdapter: binding.abiAdapter
                )
                guard callee.parameters == binding.parameterTypes,
                      acceptsPhysicalConventions(
                          callee.parameterConventions,
                          for: binding
                      ),
                      callee.result == binding.resultType,
                      callee.effects.mayThrow == binding.effects.mayThrow,
                      callee.effects.isAsync == binding.effects.isAsync
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: reference[1],
                        detail: "actual \(callee.parameters) \(callee.parameterConventions) "
                            + "-> \(callee.result) \(callee.effects); expected "
                            + "\(binding.parameterTypes) \(binding.parameterConventions) "
                            + "-> \(binding.resultType) \(binding.effects)"
                    )
                }
                functionReferences[reference[0]] = .init(
                    binding: binding,
                    physicalParameterConventions: callee.parameterConventions,
                    hasIndirectResult: callee.hasIndirectResult,
                    erasedMetatypes: callee.erasedMetatypes,
                    usesObjectiveCBridge: usesObjectiveCBridge
                )
                continue
            }

            if let reference = match(
                line,
                pattern: #"^(%[0-9]+) = (?:dynamic_)?function_ref @([^\s:]+) : \$(.+)$"#
            ) {
                if let intrinsic = SwiftCoreIntrinsic(mangledName: reference[1]) {
                    swiftCoreReferences[reference[0]] = intrinsic
                    continue
                }
                if let intrinsic = ObjectiveCBridgeIntrinsic(
                    mangledName: reference[1],
                    loweredType: reference[2]
                ) {
                    objectiveCBridgeReferences[reference[0]] = intrinsic
                    continue
                }
                if reference[1]
                    == CanonicalSIL.NativeBridgeSymbols.optionSetArrayLiteralSILSymbol {
                    optionSetArrayLiteralReferences[reference[0]] = reference[2]
                    continue
                }
                if let key = typeEnvironment.structFactory(reference[1]) {
                    localFactoryReferences[reference[0]] = key
                    continue
                }
                if let key = typeEnvironment.classAllocator(reference[1]),
                   let superclass = try typeEnvironment.hostedSuperclass(for: key) {
                    hostedAllocatorReferences[reference[0]] = superclass.typeID
                    continue
                }
                if let allocatorType = try hostedAllocatorType(
                    loweredType: reference[2]
                ) {
                    hostedAllocatorReferences[reference[0]] = allocatorType
                    if directCalls.binding(for: reference[1]) == nil {
                        continue
                    }
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
                let callee = try parseFunctionType(
                    reference[2],
                    bridgingTo: (binding.parameterTypes, binding.resultType),
                    abiAdapter: binding.abiAdapter
                )
                guard callee.parameters == binding.parameterTypes,
                      acceptsPhysicalConventions(
                          callee.parameterConventions,
                          for: binding
                      ),
                      callee.result == binding.resultType,
                      callee.effects.mayThrow == binding.effects.mayThrow,
                      callee.effects.isAsync == binding.effects.isAsync
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: reference[1],
                        detail: "actual \(callee.parameters) \(callee.parameterConventions) "
                            + "-> \(callee.result) \(callee.effects); expected "
                            + "\(binding.parameterTypes) \(binding.parameterConventions) "
                            + "-> \(binding.resultType) \(binding.effects)"
                    )
                }
                functionReferences[reference[0]] = .init(
                    binding: binding,
                    physicalParameterConventions: callee.parameterConventions,
                    hasIndirectResult: callee.hasIndirectResult,
                    erasedMetatypes: callee.erasedMetatypes,
                    usesObjectiveCBridge: false
                )
                continue
            }

            if let conversion = match(
                line,
                pattern: #"^(%[0-9]+) = thin_to_thick_function (%[0-9]+) to \$(.+)$"#
            ) {
                guard let reference = functionReferences[conversion[1]],
                      case let .function(functionID) = reference.binding.target
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let binding = reference.binding
                guard
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
                appendInstruction(
                    .makeClosure(result: result, function: functionID, captures: [])
                )
                continue
            }

            if let closure = match(
                line,
                pattern: #"^(%[0-9]+) = partial_apply(?: \[[^\]]+\])* (%[0-9]+)\((.*)\) : \$(.+)$"#
            ) {
                guard let reference = functionReferences[closure[1]],
                      case let .function(functionID) = reference.binding.target
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let binding = reference.binding
                guard
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
                      physicalType.parameterConventions
                        == reference.physicalParameterConventions,
                      physicalType.result == binding.resultType,
                      physicalType.hasIndirectResult == reference.hasIndirectResult,
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
                appendInstruction(
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
                } else if let reference = deferredForeignReferences[borrowed[1]] {
                    deferredForeignReferences[borrowed[0]] = reference
                } else if let reference = hostedSuperReferences[borrowed[1]] {
                    hostedSuperReferences[borrowed[0]] = reference
                } else if let typeID = hostedAllocatorReferences[borrowed[1]] {
                    hostedAllocatorReferences[borrowed[0]] = typeID
                } else if let reference = swiftCoreReferences[borrowed[1]] {
                    swiftCoreReferences[borrowed[0]] = reference
                } else if let reference = objectiveCBridgeReferences[borrowed[1]] {
                    objectiveCBridgeReferences[borrowed[0]] = reference
                } else if let key = localFactoryReferences[borrowed[1]] {
                    localFactoryReferences[borrowed[0]] = key
                } else {
                    values[borrowed[0]] = try resolve(borrowed[1], line: sourceLine)
                    borrowedValueTokens.insert(borrowed[0])
                    if let payload = knownOptionalSomePayloads[borrowed[1]] {
                        knownOptionalSomePayloads[borrowed[0]] = payload
                    }
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
                guard swiftCoreReferences[call[0]] == nil else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let reference: ResolvedFunctionReference
                if let resolved = functionReferences[call[0]] {
                    reference = resolved
                } else if let deferred = deferredForeignReferences[call[0]] {
                    reference = try resolveDeferredForeignReference(
                        deferred,
                        genericArguments: call[1],
                        line: sourceLine
                    )
                } else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let binding = reference.binding
                guard
                      binding.effects.mayThrow,
                      !binding.effects.isAsync
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let appliedType = try parseFunctionType(
                    call[3],
                    bridgingTo: (binding.parameterTypes, binding.resultType),
                    abiAdapter: binding.abiAdapter
                )
                guard appliedType.parameters == binding.parameterTypes,
                      appliedType.parameterConventions
                        == reference.physicalParameterConventions,
                      appliedType.result == binding.resultType,
                      appliedType.hasIndirectResult == reference.hasIndirectResult,
                      appliedType.erasedMetatypes == reference.erasedMetatypes,
                      appliedType.effects.mayThrow,
                      !appliedType.effects.isAsync,
                      call[1].isEmpty
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                let normalTarget = try parseBlockID(call[4])
                let errorTarget = try parseBlockID(call[5])
                var argumentTokens = try parseApplyValueTokens(
                    call[2],
                    line: sourceLine
                )
                if reference.hasIndirectResult {
                    guard supportsIndirectResult(binding.resultType),
                          argumentTokens.count
                            == reference.physicalParameterConventions.count
                                + reference.erasedMetatypes.count + 1
                    else {
                        throw CanonicalSIL.LoweringError.unsupportedType(
                            "indirect throwing call result \(binding.resultType)"
                        )
                    }
                    let destination = argumentTokens.removeFirst()
                    guard compilerAddressType(destination) == binding.resultType,
                          runtimeAddress(at: destination) == nil,
                          implicitStackValues[normalTarget] == nil,
                          indirectTryNormalBlocks.insert(normalTarget).inserted
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect try_apply result or normal block is invalid"
                        )
                    }
                    let result = try allocate(type: binding.resultType)
                    implicitStackValues[normalTarget] = [
                        (destination, result),
                    ]
                }
                argumentTokens = try eraseMetatypeArguments(
                    argumentTokens,
                    for: reference,
                    line: sourceLine
                )
                let prepared = try prepareDirectCallArguments(
                    argumentTokens,
                    conventions: reference.physicalParameterConventions,
                    line: sourceLine,
                    allowsSynthesizedAccess: false
                )
                let arguments = try adaptBoundaryArguments(
                    prepared.arguments,
                    physicalConventions: reference.physicalParameterConventions,
                    binding: binding
                )
                guard arguments.map({ registerTypes[Int($0.rawValue)] }) == binding.parameterTypes else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
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
                appendInstruction(instruction)
                try transferOwnedCompilerAddressArguments(
                    tokens: argumentTokens,
                    resolvedArguments: prepared.arguments,
                    conventions: reference.physicalParameterConventions
                )
                continue
            }

            if let call = match(
                line,
                pattern: #"^(?:(%[0-9]+) = )?apply (%[0-9]+)(?:<(.+)>)?\((.*)\) : \$(.+)$"#
            ) {
                if let reference = hostedSuperReferences[call[1]] {
                    guard call[2].isEmpty else {
                        throw CanonicalSIL.LoweringError.unsupportedInstruction(
                            line: sourceLine,
                            text: "generic hosted superclass call"
                        )
                    }
                    let tokens = try parseApplyValueTokens(
                        call[3],
                        line: sourceLine
                    )
                    let expectedArgumentCount: Int = switch reference.context.abi {
                    case .voidNoArguments: 0
                    case .voidBool: 1
                    }
                    guard tokens.count == expectedArgumentCount + 1 else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "hosted superclass call has an incompatible physical arity"
                        )
                    }
                    let object = try resolve(
                        reference.objectToken,
                        line: sourceLine
                    )
                    guard registerTypes[Int(object.rawValue)]
                            == .local(reference.context.typeKey)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "hosted superclass call uses a different local object"
                        )
                    }
                    let arguments = try tokens.dropLast().map {
                        try resolve($0, line: sourceLine)
                    }
                    let expectedTypes: [Bytecode.ValueType] = switch reference.context.abi {
                    case .voidNoArguments: []
                    case .voidBool: [.bool]
                    }
                    guard arguments.map({ registerTypes[Int($0.rawValue)] })
                            == expectedTypes
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "hosted superclass call arguments do not match its ABI"
                        )
                    }
                    appendInstruction(
                        .hostedSuperApply(
                            object: object,
                            methodIndex: reference.context.methodIndex,
                            arguments: arguments
                        )
                    )
                    if !call[0].isEmpty { voidValues.insert(call[0]) }
                    continue
                }
                if let superclass = hostedAllocatorReferences[call[1]] {
                    guard call[2].isEmpty, !call[0].isEmpty else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "hosted class allocator has generic arguments or no result"
                        )
                    }
                    let tokens = try parseApplyValueTokens(
                        call[3],
                        line: sourceLine
                    )
                    if tokens.count == 1,
                       let metatype = hostedMetatypeValues[tokens[0]],
                       metatype.superclass == superclass {
                        let fields = try typeEnvironment.classFields(for: metatype.key)
                        guard fields.isEmpty else {
                            throw CanonicalSIL.LoweringError.unsupportedType(
                                "hosted class \(metatype.key) stored properties require an explicit hosted initializer profile"
                            )
                        }
                        let object = try allocate(type: .local(metatype.key))
                        appendInstruction(.allocateObject(result: object))
                        let appliedType = try parseFunctionType(call[4])
                        if appliedType.result == .local(metatype.key) {
                            values[call[0]] = object
                        } else {
                            hostedAllocationObjects[call[0]] = (
                                metatype.key,
                                object
                            )
                        }
                        continue
                    }
                    // A normal native allocation may share this function
                    // reference; its frozen NativeImport handles that path.
                    guard functionReferences[call[1]] != nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "unfrozen native allocator is not applied to a hosted metatype"
                        )
                    }
                }
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
                    var argumentTokens = try parseApplyValueTokens(
                        call[3],
                        line: sourceLine
                    )
                    let indirectResultDestination: String?
                    if appliedType.hasIndirectResult {
                        guard supportsIndirectResult(signature.result),
                              argumentTokens.count == signature.parameters.count + 1
                        else {
                            throw CanonicalSIL.LoweringError.unsupportedType(
                                "indirect closure result \(signature.result)"
                            )
                        }
                        let destination = argumentTokens.removeFirst()
                        guard compilerAddressType(destination) == signature.result else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "indirect closure result address does not match its result type"
                            )
                        }
                        indirectResultDestination = destination
                    } else {
                        indirectResultDestination = nil
                    }
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
                    if indirectResultDestination != nil {
                        guard !call[0].isEmpty else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "indirect closure apply does not define its Void SIL result"
                            )
                        }
                        result = try allocate(type: signature.result)
                        voidValues.insert(call[0])
                    } else if signature.result == .void {
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
                    appendInstruction(
                        .closureApply(
                            result: result,
                            closure: closure,
                            arguments: arguments
                        )
                    )
                    if let indirectResultDestination, let result {
                        if signature.result == .any {
                            try storeExistential(result, at: indirectResultDestination)
                        } else {
                            try storeConstructedValue(
                                result,
                                at: indirectResultDestination
                            )
                        }
                    }
                    continue
                }
                if let key = localFactoryReferences[call[1]] {
                    guard call[2].isEmpty, !call[0].isEmpty else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "local struct initializer has unsupported generic arguments or result"
                        )
                    }
                    let fields = try typeEnvironment.structFields(for: key)
                    var argumentTokens = try parseApplyValueTokens(
                        call[3],
                        line: sourceLine
                    )
                    let indirectDestination: String?
                    if argumentTokens.count == fields.count + 2 {
                        let destination = argumentTokens.removeFirst()
                        guard compilerAddressType(destination) == .local(key) else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "local struct initializer result address does not match \(key)"
                            )
                        }
                        indirectDestination = destination
                    } else {
                        indirectDestination = nil
                    }
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
                    appendInstruction(
                        .makeStruct(result: result, fields: Array(fieldRegisters))
                    )
                    if let indirectDestination {
                        voidValues.insert(call[0])
                        if existentialProjections[indirectDestination] != nil {
                            try finishExistentialProjection(
                                indirectDestination,
                                payload: result
                            )
                        } else {
                            try storeConstructedValue(
                                result,
                                at: indirectDestination
                            )
                        }
                    } else {
                        values[call[0]] = result
                    }
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
                if let intrinsic = objectiveCBridgeReferences[call[1]] {
                    try lowerObjectiveCBridgeIntrinsic(
                        intrinsic,
                        resultToken: call[0],
                        genericArguments: call[2],
                        argumentText: call[3],
                        loweredType: call[4],
                        line: sourceLine
                    )
                    continue
                }
                let reference: ResolvedFunctionReference
                let appliedLoweredType: String
                if let resolved = functionReferences[call[1]] {
                    reference = resolved
                    appliedLoweredType = call[4]
                } else if let deferred = deferredForeignReferences[call[1]] {
                    reference = try resolveDeferredForeignReference(
                        deferred,
                        genericArguments: call[2],
                        line: sourceLine
                    )
                    appliedLoweredType = call[4]
                } else if let deferredType = optionSetArrayLiteralReferences[call[1]] {
                    let substitutions = splitTopLevel(call[2]).filter { !$0.isEmpty }
                    guard substitutions.count == 1,
                          case let .native(typeID) = try parseType(substitutions[0])
                    else {
                        throw CanonicalSIL.LoweringError.unsupportedInstruction(
                            line: sourceLine,
                            text: "OptionSet array literal without one frozen concrete type"
                        )
                    }
                    let symbol = CanonicalSIL.NativeBridgeSymbols
                        .optionSetArrayLiteralInitializer(for: typeID)
                    guard let binding = directCalls.binding(for: symbol),
                          binding.parameterTypes == [.array(.native(typeID))],
                          binding.resultType == .native(typeID),
                          binding.abiAdapter == .direct,
                          !binding.effects.mayThrow,
                          !binding.effects.isAsync,
                          case .nativeImport = binding.target
                    else {
                        if let unavailable = directCalls.unavailableCall(for: symbol) {
                            throw CanonicalSIL.LoweringError.unavailableNativeImport(
                                line: sourceLine,
                                mangledName: symbol,
                                canonicalCallee: unavailable.canonicalCallee,
                                reason: unavailable.reason
                            )
                        }
                        throw CanonicalSIL.LoweringError.unboundCallee(
                            line: sourceLine,
                            mangledName: symbol
                        )
                    }
                    func specialize(_ raw: String) -> String {
                        raw.replacingOccurrences(
                            of: "τ_0_0.ArrayLiteralElement",
                            with: substitutions[0]
                        ).replacingOccurrences(
                            of: "τ_0_0.Element",
                            with: substitutions[0]
                        ).replacingOccurrences(
                            of: "τ_0_0",
                            with: substitutions[0]
                        )
                    }
                    let specializedReferenceType = specialize(deferredType)
                    appliedLoweredType = specialize(call[4])
                    let callee = try parseFunctionType(
                        specializedReferenceType,
                        bridgingTo: (binding.parameterTypes, binding.resultType)
                    )
                    guard callee.parameters == binding.parameterTypes,
                          acceptsPhysicalConventions(
                              callee.parameterConventions,
                              for: binding
                          ),
                          callee.result == binding.resultType,
                          callee.effects.mayThrow == binding.effects.mayThrow,
                          callee.effects.isAsync == binding.effects.isAsync
                    else {
                        throw CanonicalSIL.LoweringError.callSignatureMismatch(
                            line: sourceLine,
                            mangledName: symbol,
                            detail: "specialized reference has \(callee.parameters) "
                                + "\(callee.parameterConventions) -> \(callee.result) "
                                + "\(callee.effects); expected \(binding.parameterTypes) "
                                + "\(binding.parameterConventions) -> \(binding.resultType) "
                                + "\(binding.effects)"
                        )
                    }
                    reference = .init(
                        binding: binding,
                        physicalParameterConventions: callee.parameterConventions,
                        hasIndirectResult: callee.hasIndirectResult,
                        erasedMetatypes: callee.erasedMetatypes,
                        usesObjectiveCBridge: false
                    )
                } else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let binding = reference.binding
                let appliedType = try parseFunctionType(
                    appliedLoweredType,
                    bridgingTo: (binding.parameterTypes, binding.resultType),
                    abiAdapter: binding.abiAdapter
                )
                guard appliedType.parameters == binding.parameterTypes,
                      appliedType.parameterConventions
                        == reference.physicalParameterConventions,
                      appliedType.result == binding.resultType,
                      appliedType.hasIndirectResult == reference.hasIndirectResult,
                      appliedType.erasedMetatypes == reference.erasedMetatypes,
                      appliedType.effects.mayThrow == binding.effects.mayThrow,
                      appliedType.effects.isAsync == binding.effects.isAsync,
                      !binding.effects.isAsync
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                var argumentTokens = try parseApplyValueTokens(
                    call[3],
                    line: sourceLine
                )
                let indirectResultDestination: String?
                if reference.hasIndirectResult {
                    guard supportsIndirectResult(binding.resultType),
                          argumentTokens.count
                            == reference.physicalParameterConventions.count
                                + reference.erasedMetatypes.count + 1
                    else {
                        throw CanonicalSIL.LoweringError.unsupportedType(
                            "indirect call result \(binding.resultType)"
                        )
                    }
                    let destination = argumentTokens.removeFirst()
                    guard compilerAddressType(destination) == binding.resultType else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect call result address does not match its result type"
                        )
                    }
                    indirectResultDestination = destination
                } else {
                    indirectResultDestination = nil
                }
                argumentTokens = try eraseMetatypeArguments(
                    argumentTokens,
                    for: reference,
                    line: sourceLine
                )
                if binding.abiAdapter == .mutatingValueReceiver {
                    guard indirectResultDestination == nil else {
                        throw CanonicalSIL.LoweringError.invalidCallTable(
                            "mutating value-receiver call unexpectedly has an indirect result"
                        )
                    }
                    try lowerMutatingValueReceiverApply(
                        resultToken: call[0],
                        argumentTokens: argumentTokens,
                        reference: reference,
                        line: sourceLine
                    )
                    continue
                }
                let prepared = try prepareDirectCallArguments(
                    argumentTokens,
                    conventions: reference.physicalParameterConventions,
                    line: sourceLine,
                    allowsSynthesizedAccess: true
                )
                let arguments = try adaptBoundaryArguments(
                    prepared.arguments,
                    physicalConventions: reference.physicalParameterConventions,
                    binding: binding
                )
                guard arguments.map({ registerTypes[Int($0.rawValue)] }) == binding.parameterTypes else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                let result: Bytecode.Register?
                if indirectResultDestination != nil {
                    guard !call[0].isEmpty else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect apply does not define its Void SIL result"
                        )
                    }
                    let register = try allocate(type: binding.resultType)
                    result = register
                    voidValues.insert(call[0])
                    // The VM call is value-based. Re-materialize Swift's
                    // address-only existential convention after the call.
                } else if binding.resultType == .void {
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
                appendInstruction(instruction)
                try transferOwnedCompilerAddressArguments(
                    tokens: argumentTokens,
                    resolvedArguments: prepared.arguments,
                    conventions: reference.physicalParameterConventions
                )
                if let indirectResultDestination, let result {
                    if binding.resultType == .any {
                        try storeExistential(result, at: indirectResultDestination)
                    } else {
                        try storeConstructedValue(
                            result,
                            at: indirectResultDestination
                        )
                    }
                }
                for access in prepared.accesses.reversed() {
                    appendInstruction(.endAccess(access))
                }
                releasePreservedNativeConversionsAfterLastUse(
                    zip(
                        argumentTokens,
                        reference.physicalParameterConventions
                    ).compactMap { token, convention in
                        convention == .borrowed ? token : nil
                    },
                    after: lineIndex
                )
                continue
            }

            if let tuple = match(
                line,
                pattern: #"^\((%[0-9]+), (%[0-9]+)\) = destructure_tuple (%[0-9]+)$"#
            ), let pending = pendingArrayLiterals[tuple[2]] {
                if pending.count == 0 {
                    let result = try allocate(type: .array(pending.elementType))
                    values[tuple[0]] = result
                    appendInstruction(.makeArray(result: result, elements: []))
                    pendingArrayLiterals.removeValue(forKey: tuple[2])
                } else {
                    arrayLiteralAllocationByValue[tuple[0]] = tuple[2]
                    arrayLiteralStorageTokens[tuple[1]] = tuple[2]
                }
                continue
            }

            if let tuple = match(
                line,
                pattern: #"^(%[0-9]+) = tuple_extract (%[0-9]+), ([0-9]+)$"#
            ), let pending = pendingArrayLiterals[tuple[1]] {
                switch tuple[2] {
                case "0":
                    if pending.count == 0 {
                        let result = try allocate(type: .array(pending.elementType))
                        values[tuple[0]] = result
                        appendInstruction(.makeArray(result: result, elements: []))
                        pendingArrayLiterals.removeValue(forKey: tuple[1])
                    } else {
                        arrayLiteralAllocationByValue[tuple[0]] = tuple[1]
                    }
                case "1":
                    arrayLiteralStorageTokens[tuple[0]] = tuple[1]
                default:
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array literal allocation tuple has only two elements"
                    )
                }
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
                appendInstruction(.unpackTuple(results: results, tuple: source))
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
                pattern: #"^(%[0-9]+) = unchecked_ref_cast (%[0-9]+) to \$(.+)$"#
            ), let allocation = hostedAllocationObjects.removeValue(
                forKey: cast[1]
            ), let target = typeEnvironment.localKey(for: cast[2]),
               target == allocation.key {
                values[cast[0]] = allocation.object
                continue
            }

            if let cast = match(
                line,
                pattern: #"^(%[0-9]+) = unchecked_ref_cast (%[0-9]+) to \$(.+)$"#
            ), let targetType = try? parseType(cast[2]) {
                let source = try resolve(cast[1], line: sourceLine)
                let sourceType = registerTypes[Int(source.rawValue)]
                // Swift may spell an Objective-C superclass lookup with a
                // same-type cast of the concrete receiver. This is an alias,
                // not authority to reinterpret one frozen reference as another.
                if sourceType == targetType,
                   typeEnvironment.containsReferenceNativeValue(sourceType) {
                    values[cast[0]] = source
                    continue
                }
            }

            if let cast = match(
                line,
                pattern: #"^(%[0-9]+) = unchecked_ref_cast (%[0-9]+) to \$Optional<(.+)>$"#
            ) {
                let source = try resolve(cast[1], line: sourceLine)
                let sourceType = registerTypes[Int(source.rawValue)]
                guard sourceType.requiresLinearOwnership,
                      try parsePhysicalType(cast[2], bridgedTo: sourceType) == sourceType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "unchecked reference-to-Optional cast changes its frozen VM type"
                    )
                }
                let result = try allocate(type: .optional(sourceType))
                values[cast[0]] = result
                knownOptionalSomePayloads[cast[0]] = source
                appendInstruction(.makeOptionalSome(result: result, value: source))
                try transferPreservedNativeConversionLifetime(
                    from: cast[1],
                    resolved: source,
                    to: cast[0],
                    result: result
                )
                continue
            }

            if let initialization = match(
                line,
                pattern: #"^(%[0-9]+) = end_init_let_ref (%[0-9]+)$"#
            ) {
                let object = try resolve(initialization[1], line: sourceLine)
                guard case let .local(key) = registerTypes[Int(object.rawValue)],
                      typeEnvironment.isClass(key)
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                values[initialization[0]] = object
                continue
            }

            if let cast = match(
                line,
                pattern: #"^(%[0-9]+) = unchecked_ref_cast (%[0-9]+) to \$(.+)$"#
            ), let target = typeEnvironment.localKey(for: cast[2]),
               typeEnvironment.isClass(target) {
                let object = try resolve(cast[1], line: sourceLine)
                guard registerTypes[Int(object.rawValue)] == .local(target) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local class reference cast changes its logical type"
                    )
                }
                values[cast[0]] = object
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
            ), let projection = existentialProjections[component[1]],
               case let .tuple(types) = projection.concreteType,
               let index = Int(component[2]),
               types.indices.contains(index) {
                existentialComponentAddresses[component[0]] = .init(
                    projection: component[1],
                    index: index
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

            if let component = match(
                line,
                pattern: #"^(%[0-9]+) = tuple_element_addr (%[0-9]+), ([0-9]+)$"#
            ), case let .tuple(types) = stackType(at: component[1]),
               let index = Int(component[2]),
               types.indices.contains(index) {
                tupleComponentAddresses[component[0]] = .init(
                    base: component[1],
                    index: index
                )
                stackAddressTypes[component[0]] = types[index]
                if let tuple = stackValue(at: component[1]) {
                    try materializeTupleComponents(
                        at: component[1],
                        tuple: tuple
                    )
                }
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

            if let extraction = match(
                line,
                pattern: #"^(%[0-9]+) = unchecked_take_enum_data_addr (%[0-9]+), #Optional\.some!enumelt$"#
            ) {
                guard let blockID = current?.id,
                      isKnownSomeOptionalAddress(extraction[1], in: blockID),
                      let optional = stackValue(at: extraction[1]),
                      case let .optional(wrapped) = registerTypes[Int(optional.rawValue)],
                      compilerAddressType(extraction[1]) == .optional(wrapped)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "unchecked Optional address payload is not dominated by its some edge"
                    )
                }
                let payload = try allocate(type: wrapped)
                appendInstruction(
                    .unwrapOptional(result: payload, optional: optional)
                )
                let root = addressBase(extraction[1])
                stackAddressValues.removeValue(forKey: root)
                for token in [root, extraction[1]] where values[token] == optional {
                    values.removeValue(forKey: token)
                }
                setKnownSomeOptionalAddress(
                    extraction[1],
                    in: blockID,
                    isKnownSome: false
                )
                stackAddressTypes[extraction[0]] = wrapped
                stackAddressValues[extraction[0]] = payload
                takenOptionalPayloadRoots[extraction[0]] = root
                continue
            }

            if let optional = match(
                line,
                pattern: #"^(%[0-9]+) = enum \$Optional<(.+)>, #Optional\.some!enumelt, (%[0-9]+)$"#
            ) {
                if voidValues.contains(optional[2]),
                   (try? parseType(optional[1])) == .void {
                    let result = try allocate(type: .bool)
                    values[optional[0]] = result
                    compilerOptionalVoidValues.insert(optional[0])
                    appendInstruction(.constantBool(result: result, value: true))
                    continue
                }
                let payload = try resolve(optional[2], line: sourceLine)
                let payloadType = registerTypes[Int(payload.rawValue)]
                let wrapped = try parsePhysicalType(
                    optional[1],
                    bridgedTo: payloadType
                )
                guard registerTypes[Int(payload.rawValue)] == wrapped else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional.some payload does not match its SIL type"
                    )
                }
                let result = try allocate(type: .optional(wrapped))
                values[optional[0]] = result
                knownOptionalSomePayloads[optional[0]] = payload
                appendInstruction(.makeOptionalSome(result: result, value: payload))
                try transferPreservedNativeConversionLifetime(
                    from: optional[2],
                    resolved: payload,
                    to: optional[0],
                    result: result
                )
                continue
            }

            if let optional = match(
                line,
                pattern: #"^(%[0-9]+) = enum \$Optional<(.+)>, #Optional\.none!enumelt$"#
            ) {
                let wrapped: Bytecode.ValueType
                if let resolved = try? parseType(optional[1]) {
                    wrapped = resolved
                } else if isSupportedObjectiveCBridgeSpelling(
                    optional[1],
                    to: .string
                ) {
                    wrapped = .string
                } else {
                    throw CanonicalSIL.LoweringError.unsupportedType(optional[1])
                }
                if wrapped == .void {
                    let result = try allocate(type: .bool)
                    values[optional[0]] = result
                    compilerOptionalVoidValues.insert(optional[0])
                    appendInstruction(.constantBool(result: result, value: false))
                    continue
                }
                let result = try allocate(type: .optional(wrapped))
                values[optional[0]] = result
                appendInstruction(.makeOptionalNone(result: result))
                continue
            }

            if let enumeration = match(
                line,
                pattern: #"^(%[0-9]+) = enum \$(.+), #([^!]+)!enumelt$"#
            ), case let .native(typeID) = try parseType(enumeration[1]) {
                let reference = "#\(enumeration[2])!enumelt"
                guard let binding = directCalls.binding(for: reference),
                      binding.parameterTypes.isEmpty,
                      binding.resultType == .native(typeID),
                      !binding.effects.mayThrow,
                      !binding.effects.isAsync,
                      case let .nativeImport(requirement) = binding.target
                else {
                    if let unavailable = directCalls.unavailableCall(for: reference) {
                        throw CanonicalSIL.LoweringError.unavailableNativeImport(
                            line: sourceLine,
                            mangledName: reference,
                            canonicalCallee: unavailable.canonicalCallee,
                            reason: unavailable.reason
                        )
                    }
                    throw CanonicalSIL.LoweringError.unboundCallee(
                        line: sourceLine,
                        mangledName: reference
                    )
                }
                let result = try allocate(type: .native(typeID))
                values[enumeration[0]] = result
                appendInstruction(
                    .nativeApply(
                        result: result,
                        importID: requirement.id,
                        arguments: []
                    )
                )
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
                appendInstruction(
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

            if let initialization = match(
                line,
                pattern: #"^(%[0-9]+) = init_enum_data_addr (%[0-9]+), #Optional\.some!enumelt$"#
            ) {
                guard case let .optional(wrapped) = compilerAddressType(
                    initialization[1]
                ),
                optionalAddressInitializations[initialization[1]] == nil,
                optionalPayloadAddressRoots[initialization[0]] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional address initialization is invalid or duplicated"
                    )
                }
                optionalAddressInitializations[initialization[1]] = .init(
                    wrappedType: wrapped
                )
                optionalPayloadAddressRoots[initialization[0]] = initialization[1]
                continue
            }

            if let injection = match(
                line,
                pattern: #"^inject_enum_addr (%[0-9]+), #Optional\.(some|none)!enumelt$"#
            ) {
                guard case let .optional(wrapped) = compilerAddressType(injection[0]) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "inject_enum_addr destination is not Optional"
                    )
                }
                let optional = try allocate(type: .optional(wrapped))
                if injection[1] == "some" {
                    guard let initialization = optionalAddressInitializations.removeValue(
                        forKey: injection[0]
                    ), initialization.wrappedType == wrapped,
                       let payload = initialization.payload
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Optional.some address is missing its payload"
                        )
                    }
                    appendInstruction(
                        .makeOptionalSome(result: optional, value: payload)
                    )
                } else {
                    guard optionalAddressInitializations.removeValue(
                        forKey: injection[0]
                    ) == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Optional.none address contains pending payload storage"
                        )
                    }
                    appendInstruction(.makeOptionalNone(result: optional))
                }
                optionalPayloadAddressRoots = optionalPayloadAddressRoots.filter {
                    $0.value != injection[0]
                }
                try storeConstructedValue(optional, at: injection[0])
                let root = addressBase(injection[0])
                if injection[0] != indirectResultAddress,
                   stackAddressTypes[root] != nil,
                   runtimeAddress(at: injection[0]) == nil,
                   let blockID = current?.id {
                    compilerAddressWrites[blockID, default: [:]][root] = optional
                }
                continue
            }

            if let projection = match(
                line,
                pattern: #"^(%[0-9]+) = init_existential_addr (%[0-9]+), \$(.+)$"#
            ) {
                let concreteType = try parseType(projection[2])
                guard compilerAddressType(projection[1]) == .any,
                      concreteType.isAnyPayloadOrExistentialV1,
                      existentialProjections[projection[0]] == nil
                else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Any payload \(concreteType)"
                    )
                }
                existentialProjections[projection[0]] = .init(
                    destination: projection[1],
                    concreteType: concreteType
                )
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
            ), let component = existentialComponentAddresses[store[1]],
               var projection = existentialProjections[component.projection],
               case let .tuple(types) = projection.concreteType {
                let payload = try resolve(store[0], line: sourceLine)
                guard types.indices.contains(component.index),
                      registerTypes[Int(payload.rawValue)] == types[component.index],
                      projection.components.updateValue(
                          payload,
                          forKey: component.index
                      ) == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Any tuple payload component is invalid or duplicated"
                    )
                }
                existentialProjections[component.projection] = projection
                if projection.components.count == types.count {
                    let elements = try types.indices.map { index in
                        guard let element = projection.components[index] else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "Any tuple payload is incomplete"
                            )
                        }
                        return element
                    }
                    let tuple = try allocate(type: projection.concreteType)
                    appendInstruction(.makeTuple(result: tuple, elements: elements))
                    try finishExistentialProjection(
                        component.projection,
                        payload: tuple
                    )
                }
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
            ), let projection = existentialProjections[store[1]] {
                let payload = try resolve(store[0], line: sourceLine)
                guard projection.components.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Any payload mixes direct and component stores"
                    )
                }
                try finishExistentialProjection(store[1], payload: payload)
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
            ), let property = nativePropertyAddresses[addressBase(store[1])] {
                guard let binding = property.setter else {
                    if let unavailable = property.unavailableSetter {
                        throw CanonicalSIL.LoweringError.unavailableNativeImport(
                            line: sourceLine,
                            mangledName: unavailable.mangledName,
                            canonicalCallee: unavailable.canonicalCallee,
                            reason: unavailable.reason
                        )
                    }
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: "stored property is read-only in the frozen Shell"
                    )
                }
                guard case let .nativeImport(requirement) = binding.target else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "stored property setter is not a NativeImport"
                    )
                }
                let value = try resolve(store[0], line: sourceLine)
                guard registerTypes[Int(value.rawValue)] == property.valueType else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                let ownedValue = try copyOwnedCallArgument(value)
                let receiver = try copyOwnedCallArgument(property.receiver)
                appendInstruction(
                    .nativeApply(
                        result: nil,
                        importID: requirement.id,
                        arguments: [ownedValue, receiver]
                    )
                )
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
                appendInstruction(
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
            ), let range = integerRangeValues.removeValue(forKey: store[0]) {
                let address = addressBase(store[1])
                guard integerRangeAddresses.contains(address),
                      integerRangeAddressValues[address] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Range<Int> storage is unsupported or initialized more than once"
                    )
                }
                integerRangeAddressValues[address] = range
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
                appendInstruction(
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
                try storeVMValue(value, at: store[1])
                continue
            }

            if let load = match(
                line,
                pattern: #"^(%[0-9]+) = load(?: \[(trivial|copy|take)\])? (%[0-9]+)$"#
            ), let binding = nativeGlobalAddresses[load[2]],
               case let .nativeImport(requirement) = binding.target {
                guard load[1] != "take" else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "an imported global value cannot be taken"
                    )
                }
                let result = try allocate(type: binding.resultType)
                values[load[0]] = result
                appendInstruction(
                    .nativeApply(
                        result: result,
                        importID: requirement.id,
                        arguments: []
                    )
                )
                continue
            }

            if let load = match(
                line,
                pattern: #"^(%[0-9]+) = load(?: \[(trivial|copy|take)\])? (%[0-9]+)$"#
            ) {
                let mode = load[1]
                let address = addressBase(load[2])
                if let property = nativePropertyAddresses[address] {
                    guard mode != "take" else {
                        throw CanonicalSIL.LoweringError.unsupportedInstruction(
                            line: sourceLine,
                            text: "taking load from native application storage"
                        )
                    }
                    guard let binding = property.getter else {
                        if let unavailable = property.unavailableGetter {
                            throw CanonicalSIL.LoweringError.unavailableNativeImport(
                                line: sourceLine,
                                mangledName: unavailable.mangledName,
                                canonicalCallee: unavailable.canonicalCallee,
                                reason: unavailable.reason
                            )
                        }
                        throw CanonicalSIL.LoweringError.unsupportedInstruction(
                            line: sourceLine,
                            text: "stored property getter is absent from the frozen Shell"
                        )
                    }
                    guard case let .nativeImport(requirement) = binding.target else {
                        throw CanonicalSIL.LoweringError.invalidCallTable(
                            "stored property getter is not a NativeImport"
                        )
                    }
                    let result = try allocate(type: property.valueType)
                    values[load[0]] = result
                    let receiver = try copyOwnedCallArgument(property.receiver)
                    appendInstruction(
                        .nativeApply(
                            result: result,
                            importID: requirement.id,
                            arguments: [receiver]
                        )
                    )
                    continue
                }
                if pendingStringInterpolationAddresses.contains(address) {
                    guard let accumulator = stringInterpolationAddressValues[address] else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "String interpolation load references uninitialized storage"
                        )
                    }
                    switch mode {
                    case "take":
                        stringInterpolationAddressValues.removeValue(forKey: address)
                    case "", "copy":
                        // Unoptimized SIL spells the same ownership transfer as
                        // load + retain_value + destroy_addr instead of load [take].
                        break
                    default:
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "String interpolation storage has an invalid load convention"
                        )
                    }
                    values[load[0]] = accumulator
                    stringInterpolationValues[load[0]] = accumulator
                    continue
                }
                if let state = pendingIntegerRangeNextAddresses.removeValue(
                    forKey: address
                ) {
                    guard stackType(at: load[2]) == .optional(.int64) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Range iterator result storage is not Optional<Int>"
                        )
                    }
                    pendingIntegerRangeNextValues[load[0]] = state
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
                        appendInstruction(
                            .loadAddress(result: result, address: addressRegister, mode: .copy)
                        )
                    } else if let slot = runtimeStackSlots[address], load[2] == address {
                        guard stackAddressValues[address] != nil else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "load references an uninitialized runtime stack address"
                            )
                        }
                        let loadMode: Bytecode.StackLoadMode = mode == "take" ? .take : .copy
                        appendInstruction(
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
                        appendInstruction(
                            .beginAccess(result: access, address: addressRegister, kind: .read)
                        )
                        appendInstruction(
                            .loadAddress(result: result, address: access, mode: .copy)
                        )
                        appendInstruction(.endAccess(access))
                    }
                    values[load[0]] = result
                    continue
                }
                guard let value = try resolvedStackValue(
                    at: load[2],
                    line: sourceLine
                ),
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
                    appendInstruction(.copyValue(result: copy, source: value))
                    values[load[0]] = copy
                } else {
                    values[load[0]] = value
                }
                continue
            }

            if let destroy = match(line, pattern: #"^destroy_addr (%[0-9]+)$"#) {
                let address = addressBase(destroy[0])
                if pendingStringInterpolationAddresses.contains(address) {
                    guard stringInterpolationAddressValues.removeValue(forKey: address) != nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "destroy_addr references uninitialized String interpolation storage"
                        )
                    }
                    continue
                }
                if catchScratchAddresses.contains(address) { continue }
                if let iterator = arrayIteratorStates.removeValue(forKey: address) {
                    appendInstruction(.destroyStack(iterator.indexSlot))
                    destroyedArrayIterators.insert(address)
                    continue
                }
                if let iterator = dictionaryIteratorStates.removeValue(forKey: address) {
                    appendInstruction(.destroyStack(iterator.indexSlot))
                    destroyedDictionaryIterators.insert(address)
                    continue
                }
                if let slot = runtimeStackSlots[address] {
                    guard stackAddressValues.removeValue(forKey: address) != nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "destroy_addr references uninitialized runtime storage"
                        )
                    }
                    appendInstruction(.destroyStack(slot))
                    continue
                }
                guard stackAddressTypes[address] != nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "destroy_addr references an unsupported address"
                    )
                }
                // Compiler-only storage owns the SSA value transferred into
                // it. Native boxes need an explicit HLBC destroy even when the
                // physical Swift value has trivial SIL ownership.
                if let value = stackAddressValues.removeValue(forKey: address),
                   registerTypes[Int(value.rawValue)].requiresLinearOwnership {
                    appendInstruction(.destroyValue(value))
                }
                continue
            }

            if let cast = match(
                line,
                pattern: #"^checked_cast_addr_br (?:take_always|copy_on_success) Any in (%[0-9]+) to (.+) in (%[0-9]+), bb([0-9]+), bb([0-9]+)$"#
            ) {
                let targetType = try parseType(cast[1])
                guard stackType(at: cast[0]) == .any,
                      let source = stackValue(at: cast[0]),
                      registerTypes[Int(source.rawValue)] == .any,
                      compilerAddressType(cast[2]) == targetType,
                      targetType.isAnyCastTargetV1,
                      runtimeAddress(at: cast[2]) == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "checked Any cast source or destination type does not match"
                    )
                }
                let successTarget = try parseBlockID(cast[3])
                let failureTarget = try parseBlockID(cast[4])
                guard implicitStackValues[successTarget] == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "multiple checked Any casts share a success block"
                    )
                }
                let optional = try allocate(type: .optional(targetType))
                let projected = try allocate(type: targetType)
                appendInstruction(
                    .checkedCastAny(result: optional, value: source)
                )
                appendInstruction(
                    .switchOptional(
                        optional: optional,
                        someTarget: successTarget,
                        noneTarget: failureTarget
                    )
                )
                implicitStackValues[successTarget] = [(cast[2], projected)]
                continue
            }

            if let cast = match(
                line,
                pattern: #"^unconditional_checked_cast_addr Any in (%[0-9]+) to (.+) in (%[0-9]+)$"#
            ) {
                let targetType = try parseType(cast[1])
                guard stackType(at: cast[0]) == .any,
                      let source = stackValue(at: cast[0]),
                      registerTypes[Int(source.rawValue)] == .any,
                      compilerAddressType(cast[2]) == targetType,
                      targetType.isAnyCastTargetV1
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "forced Any cast source or destination type does not match"
                    )
                }
                let result = try allocate(type: targetType)
                appendInstruction(.forceCastAny(result: result, value: source))
                try storeVMValue(result, at: cast[2])
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
                appendInstruction(
                    .castError(result: optional, error: error, expectedType: key)
                )
                appendInstruction(
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
                appendInstruction(.makeTuple(result: result, elements: elements))
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
                appendInstruction(
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
                    appendInstruction(.unpackTuple(results: elements, tuple: tuple))
                }
                values[extract[0]] = elements[index]
                continue
            }

            if let failure = match(line, pattern: #"^cond_fail (%[0-9]+), \"([^\"]*)\"$"#) {
                let condition = try resolve(failure[0], line: sourceLine)
                let trapID = try allocateSyntheticBlockID()
                let continuationID = try allocateSyntheticBlockID()
                appendInstruction(
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
                if let currentSourceLocation {
                    sourceMap.append(
                        .init(
                            blockID: trapID,
                            instructionOffset: 0,
                            location: currentSourceLocation
                        )
                    )
                }
                current = IntermediateRepresentation.Block(id: continuationID, parameters: [], instructions: [])
                continue
            }

            if let copy = match(line, pattern: #"^(%[0-9]+) = copy_value (%[0-9]+)$"#) {
                if let reference = functionReferences[copy[1]] {
                    functionReferences[copy[0]] = reference
                    continue
                }
                if let reference = deferredForeignReferences[copy[1]] {
                    deferredForeignReferences[copy[0]] = reference
                    continue
                }
                if let reference = hostedSuperReferences[copy[1]] {
                    hostedSuperReferences[copy[0]] = reference
                    continue
                }
                if let typeID = hostedAllocatorReferences[copy[1]] {
                    hostedAllocatorReferences[copy[0]] = typeID
                    continue
                }
                if let reference = swiftCoreReferences[copy[1]] {
                    swiftCoreReferences[copy[0]] = reference
                    continue
                }
                if let reference = objectiveCBridgeReferences[copy[1]] {
                    objectiveCBridgeReferences[copy[0]] = reference
                    continue
                }
                if let reference = optionSetArrayLiteralReferences[copy[1]] {
                    optionSetArrayLiteralReferences[copy[0]] = reference
                    continue
                }
                if let key = localFactoryReferences[copy[1]] {
                    localFactoryReferences[copy[0]] = key
                    continue
                }
                let source = try resolve(copy[1], line: sourceLine)
                let result = try allocate(type: registerTypes[Int(source.rawValue)])
                values[copy[0]] = result
                if let payload = knownOptionalSomePayloads[copy[1]] {
                    knownOptionalSomePayloads[copy[0]] = payload
                }
                if let selection = optionalAddressSelectionConditions[copy[1]] {
                    optionalAddressSelectionConditions[copy[0]] = selection
                }
                if compilerOptionalVoidValues.contains(copy[1]) {
                    compilerOptionalVoidValues.insert(copy[0])
                }
                appendInstruction(.copyValue(result: result, source: source))
                releasePreservedNativeConversionsAfterLastUse(
                    [copy[1]],
                    after: lineIndex
                )
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
                if let reference = deferredForeignReferences.removeValue(forKey: move[1]) {
                    deferredForeignReferences[move[0]] = reference
                    continue
                }
                if let reference = hostedSuperReferences.removeValue(forKey: move[1]) {
                    hostedSuperReferences[move[0]] = reference
                    continue
                }
                if let typeID = hostedAllocatorReferences.removeValue(forKey: move[1]) {
                    hostedAllocatorReferences[move[0]] = typeID
                    continue
                }
                if let reference = swiftCoreReferences.removeValue(forKey: move[1]) {
                    swiftCoreReferences[move[0]] = reference
                    continue
                }
                if let reference = objectiveCBridgeReferences.removeValue(forKey: move[1]) {
                    objectiveCBridgeReferences[move[0]] = reference
                    continue
                }
                if let reference = optionSetArrayLiteralReferences.removeValue(
                    forKey: move[1]
                ) {
                    optionSetArrayLiteralReferences[move[0]] = reference
                    continue
                }
                if let key = localFactoryReferences.removeValue(forKey: move[1]) {
                    localFactoryReferences[move[0]] = key
                    continue
                }
                let source = try resolve(move[1], line: sourceLine)
                let result = try allocate(type: registerTypes[Int(source.rawValue)])
                values[move[0]] = result
                if let payload = knownOptionalSomePayloads.removeValue(forKey: move[1]) {
                    knownOptionalSomePayloads[move[0]] = payload
                }
                if let selection = optionalAddressSelectionConditions.removeValue(
                    forKey: move[1]
                ) {
                    optionalAddressSelectionConditions[move[0]] = selection
                }
                if compilerOptionalVoidValues.remove(move[1]) != nil {
                    compilerOptionalVoidValues.insert(move[0])
                }
                appendInstruction(.moveValue(result: result, source: source))
                continue
            }
            if let destroy = match(line, pattern: #"^destroy_value (%[0-9]+)$"#) {
                if functionReferences.removeValue(forKey: destroy[0]) != nil { continue }
                if deferredForeignReferences.removeValue(forKey: destroy[0]) != nil {
                    continue
                }
                if hostedSuperReferences.removeValue(forKey: destroy[0]) != nil {
                    continue
                }
                if hostedAllocatorReferences.removeValue(forKey: destroy[0]) != nil {
                    continue
                }
                if swiftCoreReferences.removeValue(forKey: destroy[0]) != nil { continue }
                if objectiveCBridgeReferences.removeValue(forKey: destroy[0]) != nil { continue }
                if optionSetArrayLiteralReferences.removeValue(forKey: destroy[0]) != nil {
                    continue
                }
                if localFactoryReferences.removeValue(forKey: destroy[0]) != nil { continue }
                knownOptionalSomePayloads.removeValue(forKey: destroy[0])
                optionalAddressSelectionConditions.removeValue(forKey: destroy[0])
                compilerOptionalVoidValues.remove(destroy[0])
                let value = try resolve(destroy[0], line: sourceLine)
                try closePreservedNativeConversionLifetime(
                    for: destroy[0],
                    resolved: value
                )
                if case .closure = registerTypes[Int(value.rawValue)] { continue }
                appendInstruction(.destroyValue(value))
                continue
            }
            if let ownership = match(
                line,
                pattern: #"^(retain_value|release_value) (%[0-9]+)$"#
            ) {
                let value = try resolve(ownership[1], line: sourceLine)
                if registerTypes[Int(value.rawValue)].requiresLinearOwnership {
                    // A NativeImport result is already an owned VM handle. The
                    // retain paired with a Swift +0 load is therefore implicit;
                    // its release remains an explicit linear consume.
                    if ownership[0] == "release_value",
                       !isBorrowedParameter(value) {
                        try closePreservedNativeConversionLifetime(
                            for: ownership[1],
                            resolved: value
                        )
                        appendInstruction(.destroyValue(value))
                    }
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
                if case let .local(key) = type, typeEnvironment.isClass(key) {
                    // VM.Value retains one shared object identity; Swift ARC
                    // traffic does not become explicit HLBC instructions.
                    continue
                }
                guard type == .string || type == .error
                        || type.requiresLinearOwnership
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                if ownership[0] == "release", !isBorrowedParameter(value) {
                    try closePreservedNativeConversionLifetime(
                        for: ownership[1],
                        resolved: value
                    )
                    appendInstruction(.destroyValue(value))
                }
                continue
            }

            if let deallocation = match(
                line,
                pattern: #"^dealloc_ref (%[0-9]+)$"#
            ) {
                let value = try resolve(deallocation[0], line: sourceLine)
                guard case let .local(key) = registerTypes[Int(value.rawValue)],
                      typeEnvironment.isClass(key)
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                continue
            }

            if let selection = match(
                line,
                pattern: #"^(%[0-9]+) = select_enum_addr (%[0-9]+), case #Optional\.(some|none)!enumelt: (%[0-9]+), default (%[0-9]+) : \$Builtin\.Int1$"#
            ) {
                guard let optional = stackValue(at: selection[1]),
                      case .optional = registerTypes[Int(optional.rawValue)],
                      let caseValue = boolLiterals[selection[3]],
                      let defaultValue = boolLiterals[selection[4]],
                      caseValue != defaultValue
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "select_enum_addr requires initialized Optional storage and complementary Bool values"
                    )
                }
                let someValue = selection[2] == "some" ? caseValue : defaultValue
                let result = try allocate(type: .bool)
                values[selection[0]] = result
                optionalAddressSelectionConditions[selection[0]] = (
                    address: selection[1],
                    someWhenTrue: someValue
                )
                if someValue {
                    appendInstruction(.optionalIsSome(result: result, optional: optional))
                } else {
                    let isSome = try allocate(type: .bool)
                    let trueToken = caseValue ? selection[3] : selection[4]
                    guard let trueValue = values[trueToken] else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "select_enum_addr lost its true Bool operand"
                        )
                    }
                    appendInstruction(.optionalIsSome(result: isSome, optional: optional))
                    appendInstruction(
                        .booleanBinary(
                            result: result,
                            operation: .xor,
                            lhs: isSome,
                            rhs: trueValue
                        )
                    )
                }
                continue
            }

            if let branch = match(
                line,
                pattern: #"^switch_enum_addr (%[0-9]+), case #Optional\.(some|none)!enumelt: bb([0-9]+), case #Optional\.(some|none)!enumelt: bb([0-9]+)$"#
            ) {
                guard branch[1] != branch[3],
                      let optional = stackValue(at: branch[0]),
                      case .optional = registerTypes[Int(optional.rawValue)]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "switch_enum_addr requires initialized Optional storage and distinct cases"
                    )
                }
                let firstTarget = try parseBlockID(branch[2])
                let secondTarget = try parseBlockID(branch[4])
                let someTarget = branch[1] == "some" ? firstTarget : secondTarget
                let noneTarget = branch[1] == "none" ? firstTarget : secondTarget
                guard knownSomeOptionalAddresses[someTarget] == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "multiple Optional address switches share a case block"
                    )
                }
                // An enum-address branch only inspects storage. Ownership moves
                // when a proven `.some` address is explicitly taken below.
                setKnownSomeOptionalAddress(
                    branch[0],
                    in: someTarget,
                    isKnownSome: true
                )
                try inheritCompilerAddressValue(
                    optional,
                    at: branch[0],
                    into: [someTarget, noneTarget]
                )
                let isSome = try allocate(type: .bool)
                appendInstruction(
                    .optionalIsSome(result: isSome, optional: optional)
                )
                appendInstruction(
                    .conditionalBranch(
                        condition: isSome,
                        trueTarget: someTarget,
                        trueArguments: [],
                        falseTarget: noneTarget,
                        falseArguments: []
                    )
                )
                continue
            }

            if let branch = match(
                line,
                pattern: #"^switch_enum (%[0-9]+), case #Optional\.(some|none)!enumelt: bb([0-9]+), case #Optional\.(some|none)!enumelt: bb([0-9]+)$"#
            ), compilerOptionalVoidValues.contains(branch[0]) {
                guard branch[1] != branch[3] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional<Void> switch must contain distinct cases"
                    )
                }
                let firstTarget = try parseBlockID(branch[2])
                let secondTarget = try parseBlockID(branch[4])
                let someTarget = branch[1] == "some" ? firstTarget : secondTarget
                let noneTarget = branch[1] == "none" ? firstTarget : secondTarget
                appendInstruction(
                    .conditionalBranch(
                        condition: try resolve(branch[0], line: sourceLine),
                        trueTarget: someTarget,
                        trueArguments: [],
                        falseTarget: noneTarget,
                        falseArguments: []
                    )
                )
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
                let firstTarget = try parseBlockID(branch[2])
                let secondTarget = try parseBlockID(branch[4])
                let someTarget = branch[1] == "some" ? firstTarget : secondTarget
                let noneTarget = branch[1] == "none" ? firstTarget : secondTarget
                if let state = pendingIntegerRangeNextValues.removeValue(
                    forKey: branch[0]
                ) {
                    let cursor = try allocate(type: .int64)
                    appendInstruction(
                        .loadStack(
                            result: cursor,
                            slot: state.indexSlot,
                            mode: .copy
                        )
                    )
                    let hasNext = try allocate(type: .bool)
                    appendInstruction(
                        .compare(
                            result: hasNext,
                            predicate: .lessThan,
                            lhs: cursor,
                            rhs: state.upperBound
                        )
                    )
                    let somePreparation = try allocateSyntheticBlockID()
                    appendInstruction(
                        .conditionalBranch(
                            condition: hasNext,
                            trueTarget: somePreparation,
                            trueArguments: [],
                            falseTarget: noneTarget,
                            falseArguments: []
                        )
                    )
                    finishCurrent()

                    let one = try allocate(type: .int64)
                    let next = try allocate(type: .int64)
                    let overflow = try allocate(type: .bool)
                    let preparationInstructions: [IntermediateRepresentation.Instruction] = [
                        .constantInteger(result: one, value: 1),
                        .checkedBinary(
                            result: next,
                            overflow: overflow,
                            operation: .add,
                            lhs: cursor,
                            rhs: one
                        ),
                        .storeStack(
                            slot: state.indexSlot,
                            source: next,
                            mode: .assign
                        ),
                        .branch(target: someTarget, arguments: [cursor]),
                    ]
                    blocks.append(
                        .init(
                            id: somePreparation,
                            parameters: [],
                            instructions: preparationInstructions
                        )
                    )
                    if let currentSourceLocation {
                        for offset in preparationInstructions.indices {
                            guard let instructionOffset = UInt32(exactly: offset) else { break }
                            sourceMap.append(
                                .init(
                                    blockID: somePreparation,
                                    instructionOffset: instructionOffset,
                                    location: currentSourceLocation
                                )
                            )
                        }
                    }
                    continue
                }
                let optional = try resolve(branch[0], line: sourceLine)
                guard case .optional = registerTypes[Int(optional.rawValue)] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional switch operand has a non-Optional type"
                    )
                }
                guard optionalSourceBySomeBlock[someTarget] == nil,
                      optionalSourceByNoneBlock[noneTarget] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "multiple Optional switches share a case block"
                    )
                }
                optionalSourceBySomeBlock[someTarget] = branch[0]
                optionalSourceByNoneBlock[noneTarget] = branch[0]
                appendInstruction(
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
                    appendInstruction(
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
                let target = try parseBlockID(branch[0])
                var arguments = try parseBranchArguments(
                    branch.count > 1 ? branch[1] : "",
                    line: sourceLine,
                    resolve: resolve
                )
                try appendCompilerAddressMergeArguments(
                    target: target,
                    arguments: &arguments
                )
                appendInstruction(
                    .branch(target: target, arguments: arguments)
                )
                continue
            }
            if let branch = match(
                line,
                pattern: #"^cond_br (%[0-9]+), bb([0-9]+), bb([0-9]+)$"#
            ), let selection = optionalAddressSelectionConditions.removeValue(
                forKey: branch[0]
            ) {
                let trueTarget = try parseBlockID(branch[1])
                let falseTarget = try parseBlockID(branch[2])
                let someTarget = selection.someWhenTrue ? trueTarget : falseTarget
                let noneTarget = selection.someWhenTrue ? falseTarget : trueTarget
                guard let optional = stackValue(at: selection.address),
                      case .optional = registerTypes[Int(optional.rawValue)],
                      knownSomeOptionalAddresses[someTarget] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional address condition does not dominate distinct case blocks"
                    )
                }
                setKnownSomeOptionalAddress(
                    selection.address,
                    in: someTarget,
                    isKnownSome: true
                )
                try inheritCompilerAddressValue(
                    optional,
                    at: selection.address,
                    into: [someTarget, noneTarget]
                )
                appendInstruction(
                    .conditionalBranch(
                        condition: try resolve(branch[0], line: sourceLine),
                        trueTarget: trueTarget,
                        trueArguments: [],
                        falseTarget: falseTarget,
                        falseArguments: []
                    )
                )
                continue
            }

            if let branch = match(
                line,
                pattern: #"^cond_br (%[0-9]+), bb([0-9]+)(?:\(([^)]*)\))?, bb([0-9]+)(?:\(([^)]*)\))?$"#
            ) {
                let trueTarget = try parseBlockID(branch[1])
                let falseTarget = try parseBlockID(branch[3])
                var trueArguments = try parseBranchArguments(
                    branch[2],
                    line: sourceLine,
                    resolve: resolve
                )
                var falseArguments = try parseBranchArguments(
                    branch[4],
                    line: sourceLine,
                    resolve: resolve
                )
                try appendCompilerAddressMergeArguments(
                    target: trueTarget,
                    arguments: &trueArguments
                )
                try appendCompilerAddressMergeArguments(
                    target: falseTarget,
                    arguments: &falseArguments
                )
                appendInstruction(
                    .conditionalBranch(
                        condition: try resolve(branch[0], line: sourceLine),
                        trueTarget: trueTarget,
                        trueArguments: trueArguments,
                        falseTarget: falseTarget,
                        falseArguments: falseArguments
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
                    appendInstruction(.throwError(error))
                } else if let message = errorMessageByBox[thrown[0]] {
                    let error = try allocate(type: .string)
                    appendInstruction(
                        .constantString(result: error, value: message)
                    )
                    appendInstruction(.throwError(error))
                } else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "throw does not contain a supported Error value"
                    )
                }
                continue
            }
            if let returned = match(line, pattern: #"^return (%[0-9]+)$"#) {
                if voidValues.contains(returned[0]) {
                    if signature.hasIndirectResult {
                        guard let slot = indirectResultSlot else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "indirect result returns before initialization"
                            )
                        }
                        let result = try allocate(type: signature.result)
                        appendInstruction(
                            .loadStack(result: result, slot: slot, mode: .take)
                        )
                        appendInstruction(.returnValue(result))
                        continue
                    }
                    guard signature.result == .void else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "non-Void function returns an empty tuple"
                        )
                    }
                    appendInstruction(.returnValue(nil))
                } else if let allocation = arrayLiteralAllocationByValue[returned[0]],
                          let pending = pendingArrayLiterals[allocation] {
                    let elements = try materializeArrayLiteralElements(pending)
                    let result = try allocate(type: .array(pending.elementType))
                    appendInstruction(
                        .makeArray(
                            result: result,
                            elements: elements
                        )
                    )
                    appendInstruction(.returnValue(result))
                    pendingArrayLiterals.removeValue(forKey: allocation)
                } else {
                    appendInstruction(
                        .returnValue(
                            try prepareReturnValue(
                                returned[0],
                                line: sourceLine
                            )
                        )
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
        guard existentialProjections.isEmpty,
              existentialComponentAddresses.isEmpty
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "Any existential projection is not initialized"
            )
        }
        guard optionalAddressInitializations.isEmpty,
              optionalPayloadAddressRoots.isEmpty,
              optionalAddressSelectionConditions.isEmpty
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "Optional address initialization is incomplete"
            )
        }
        guard hostedAllocationObjects.isEmpty else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "hosted class allocation is not completed by its canonical subclass cast"
            )
        }
        var incompleteCompilerLifetimes: [String] = []
        func recordIncompleteLifetime(_ name: String, count: Int) {
            guard count > 0 else { return }
            incompleteCompilerLifetimes.append("\(name)=\(count)")
        }
        recordIncompleteLifetime(
            "array-iterator",
            count: pendingArrayIteratorTypes.count
                + arrayIteratorStates.count
                + destroyedArrayIterators.count
        )
        recordIncompleteLifetime(
            "integer-range",
            count: integerRangeValues.count
                + integerRangeAddresses.count
                + integerRangeAddressValues.count
                + integerRangeIteratorAddresses.count
                + integerRangeIteratorStates.count
                + pendingIntegerRangeNextAddresses.count
                + pendingIntegerRangeNextValues.count
        )
        recordIncompleteLifetime(
            "array-mutation",
            count: arrayElementMutations.count + arrayMutationYieldByToken.count
        )
        recordIncompleteLifetime(
            "dictionary-iterator",
            count: pendingDictionaryIteratorTypes.count
                + pendingDictionaryIteratorValues.count
                + dictionaryIteratorStates.count
                + destroyedDictionaryIterators.count
        )
        recordIncompleteLifetime(
            "string-interpolation",
            count: pendingStringInterpolationAddresses.count
                + stringInterpolationAddressValues.count
                + stringInterpolationValues.count
        )
        recordIncompleteLifetime(
            "borrow",
            count: borrowedValueTokens.count
        )
        let nativeConversionTokens = preservedNativeConversionValues.keys.sorted()
        recordIncompleteLifetime(
            "native-conversion[\(nativeConversionTokens.joined(separator: "|"))]",
            count: nativeConversionTokens.count
        )
        guard incompleteCompilerLifetimes.isEmpty else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "compiler-only lifetime is incomplete: "
                    + incompleteCompilerLifetimes.joined(separator: ", ")
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
            effects: effectiveEffects,
            sourceLocation: sourceMap.first?.location
                ?? function.debugLineLocations.first?.location,
            sourceMap: sourceMap
        )
    }

    /// Resolves the SIL ownership spellings for an already typed parameter list.
    /// Build-time indexers use this to freeze the same ABI that lowering enforces.
    public func parseParameterConventions(
        _ text: String,
        parameterTypes: [Bytecode.ValueType]
    ) throws -> [Bytecode.ParameterConvention] {
        guard let arrow = outerFunctionArrow(in: text) else {
            throw CanonicalSIL.LoweringError.malformedSIL("function type has no result arrow")
        }
        let prefix = String(text[..<arrow.lowerBound])
        guard let close = prefix.lastIndex(of: ")"),
              let open = matchingOpeningParenthesis(for: close, in: prefix),
              open < close
        else {
            throw CanonicalSIL.LoweringError.malformedSIL("function type has no parameter tuple")
        }
        let parametersText = prefix[prefix.index(after: open)..<close]
        let rawParameters = splitTopLevel(String(parametersText)).filter { !$0.isEmpty }
        guard rawParameters.count == parameterTypes.count else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "function type parameter count does not match resolved types"
            )
        }
        return parameterConventions(
            rawParameters: rawParameters,
            parameterTypes: parameterTypes,
            implicitlyBorrowsLinearValues: isObjectiveCMethodConvention(prefix)
        )
    }

    func parseFunctionType(
        _ text: String,
        bridgingTo expected: (
            parameters: [Bytecode.ValueType], result: Bytecode.ValueType
        )? = nil,
        abiAdapter: CanonicalSIL.DirectCallBinding.ABIAdapter = .direct
    ) throws -> (
        parameters: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention],
        result: Bytecode.ValueType,
        hasIndirectResult: Bool,
        effects: Core.Effects,
        erasedMetatypes: [ErasedMetatype]
    ) {
        guard let arrow = outerFunctionArrow(in: text) else {
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
        let parameters: [Bytecode.ValueType]
        let parameterConventions: [Bytecode.ParameterConvention]
        var erasedMetatypes: [ErasedMetatype] = []
        var valueSpellings: [String] = []
        valueSpellings.reserveCapacity(rawParameters.count)
        for (index, spelling) in rawParameters.enumerated() {
            if let identity = metatypeIdentity(spelling) {
                erasedMetatypes.append(
                    .init(physicalIndex: index, identity: identity)
                )
            } else {
                valueSpellings.append(spelling)
            }
        }
        let physicalResultExpectation: Bytecode.ValueType?
        if let expected {
            let physicalExpectations: [Bytecode.ValueType]
            switch abiAdapter {
            case .direct:
                physicalExpectations = expected.parameters
                physicalResultExpectation = expected.result
            case .mutatingValueReceiver:
                guard let receiver = expected.parameters.last,
                      expected.result == receiver
                else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "mutating value-receiver binding has an invalid logical signature"
                    )
                }
                physicalExpectations = Array(expected.parameters.dropLast())
                    + [.address(receiver)]
                physicalResultExpectation = .void
            }
            guard valueSpellings.count == physicalExpectations.count else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "physical function parameters differ from its Swift NativeImport"
                )
            }
            let physicalParameters = try zip(valueSpellings, physicalExpectations).map {
                try parsePhysicalType($0.0, bridgedTo: $0.1)
            }
            parameters = expected.parameters
            parameterConventions = self.parameterConventions(
                rawParameters: valueSpellings,
                parameterTypes: physicalParameters,
                implicitlyBorrowsLinearValues: isObjectiveCMethodConvention(prefix)
            )
        } else {
            parameters = try valueSpellings.map(parseType)
            parameterConventions = self.parameterConventions(
                rawParameters: valueSpellings,
                parameterTypes: parameters,
                implicitlyBorrowsLinearValues: isObjectiveCMethodConvention(prefix)
            )
            physicalResultExpectation = nil
        }
        let isAsync = prefix.range(
            of: #"(?:^|\s)@async(?:\s|$)"#,
            options: .regularExpression
        ) != nil
        let resultComponents = splitTopLevelTuple(resultText)
        let parsedResult: (type: Bytecode.ValueType, isIndirect: Bool)
        let mayThrow: Bool
        if resultComponents.count == 1,
           try isSupportedErrorResult(resultComponents[0]) {
            // SIL omits the normal empty-tuple result for `throws -> Void`.
            guard physicalResultExpectation == nil
                    || physicalResultExpectation == .void
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "throwing Void SIL cannot satisfy a non-Void logical result"
                )
            }
            parsedResult = (.void, false)
            mayThrow = true
        } else if resultComponents.count == 2,
                  try isSupportedErrorResult(resultComponents[1]) {
            parsedResult = try parseFunctionResult(
                resultComponents[0],
                bridgedTo: physicalResultExpectation
            )
            mayThrow = true
        } else {
            parsedResult = try parseFunctionResult(
                resultText,
                bridgedTo: physicalResultExpectation
            )
            mayThrow = false
        }
        return (
            parameters,
            parameterConventions,
            expected?.result ?? parsedResult.type,
            parsedResult.isIndirect,
            .init(mayThrow: mayThrow, isAsync: isAsync),
            erasedMetatypes
        )
    }

    private func isSupportedErrorResult(_ raw: String) throws -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("@error ") else { return false }
        let spelling = String(value.dropFirst("@error ".count))
        guard [.string, .error].contains(try parseType(spelling)) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "throwing function has a non-Error error result"
            )
        }
        return true
    }

    private func metatypeIdentity(_ raw: String) -> MetatypeIdentity? {
        var spelling = raw.trimmingCharacters(in: .whitespaces)
        if spelling.hasPrefix("$") { spelling.removeFirst() }
        let prefixes = ["@thin ", "@thick ", "@objc_metatype "]
        guard let prefix = prefixes.first(where: spelling.hasPrefix),
              spelling.hasSuffix(".Type")
        else { return nil }
        let start = spelling.index(spelling.startIndex, offsetBy: prefix.count)
        let end = spelling.index(spelling.endIndex, offsetBy: -".Type".count)
        guard start < end,
              let type = try? parseType(String(spelling[start..<end]))
        else { return nil }
        return switch type {
        case let .native(typeID): .native(typeID)
        case let .local(key): .local(key)
        default: nil
        }
    }

    private func hostedAllocatorType(
        loweredType: String
    ) throws -> Core.TypeID? {
        guard loweredType.contains("@convention(method)") else { return nil }
        let signature = try parseFunctionType(loweredType)
        guard signature.parameters.isEmpty,
              signature.result != .void,
              !signature.effects.mayThrow,
              !signature.effects.isAsync,
              signature.erasedMetatypes.count == 1,
              signature.erasedMetatypes[0].physicalIndex == 0,
              case let .native(resultType) = signature.result,
              signature.erasedMetatypes[0].identity == .native(resultType)
        else { return nil }
        return resultType
    }

    private func supportsIndirectResult(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .void, .never, .address:
            false
        case .bool, .integer, .float, .string, .any, .array, .dictionary,
             .tuple, .native, .local, .error, .closure, .optional:
            true
        }
    }

    private func parseFunctionResult(
        _ raw: String,
        bridgedTo expected: Bytecode.ValueType? = nil
    ) throws -> (type: Bytecode.ValueType, isIndirect: Bool) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("@out ") {
            let spelling = String(value.dropFirst("@out ".count))
            return (
                try expected.map { try parsePhysicalType(spelling, bridgedTo: $0) }
                    ?? parseType(spelling),
                true
            )
        }
        return (
            try expected.map { try parsePhysicalType(value, bridgedTo: $0) }
                ?? parseType(value),
            false
        )
    }

    private func parsePhysicalType(
        _ raw: String,
        bridgedTo expected: Bytecode.ValueType
    ) throws -> Bytecode.ValueType {
        do {
            let actual = try parseType(raw)
            guard actual == expected else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "foreign physical type \(actual) differs from Swift NativeImport type \(expected)"
                )
            }
            return actual
        } catch {
            guard isSupportedObjectiveCBridgeSpelling(raw, to: expected) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "foreign physical type \(raw) cannot bridge to frozen logical type \(expected)"
                )
            }
            return expected
        }
    }

    private func isSupportedObjectiveCBridgeSpelling(
        _ raw: String,
        to expected: Bytecode.ValueType
    ) -> Bool {
        var spelling = raw.trimmingCharacters(in: .whitespaces)
        var removed = true
        while removed {
            removed = false
            for prefix in [
                "$", "@owned ", "@guaranteed ", "@unowned ",
                "@autoreleased ", "@in_guaranteed ",
            ] where spelling.hasPrefix(prefix) {
                spelling.removeFirst(prefix.count)
                spelling = spelling.trimmingCharacters(in: .whitespaces)
                removed = true
                break
            }
        }
        switch expected {
        case .string:
            return ["NSString", "Foundation.NSString", "__C.NSString"]
                .contains(spelling)
        case .array:
            if ["NSArray", "Foundation.NSArray", "__C.NSArray"]
                .contains(spelling) {
                return true
            }
            for prefix in ["Optional<", "Swift.Optional<"]
            where spelling.hasPrefix(prefix) && spelling.hasSuffix(">") {
                let body = String(spelling.dropFirst(prefix.count).dropLast())
                return ["NSArray", "Foundation.NSArray", "__C.NSArray"]
                    .contains(body)
            }
            return false
        case let .native(typeID):
            return typeEnvironment.matchesPseudogenericNativeType(
                spelling,
                expected: typeID
            )
        case let .optional(wrapped):
            for prefix in ["Optional<", "Swift.Optional<"]
            where spelling.hasPrefix(prefix) && spelling.hasSuffix(">") {
                let body = String(spelling.dropFirst(prefix.count).dropLast())
                return isSupportedObjectiveCBridgeSpelling(body, to: wrapped)
            }
            return false
        default:
            return false
        }
    }

    private func parameterConventions(
        rawParameters: [String],
        parameterTypes: [Bytecode.ValueType],
        implicitlyBorrowsLinearValues: Bool
    ) -> [Bytecode.ParameterConvention] {
        zip(rawParameters, parameterTypes).map {
            raw, type -> Bytecode.ParameterConvention in
            let value = raw.trimmingCharacters(in: .whitespaces)
                .trimmingPrefix("$")
            if value.hasPrefix("@inout ") || value.hasPrefix("*") { return .inout }
            // Copyable VM values do not need SIL's borrow distinction. Linear
            // native handles do. Objective-C method parameters are +0 unless
            // SIL explicitly marks them @owned, even when the printed type has
            // no ownership spelling. The NativeImport boundary is consuming,
            // so lowering copies these borrowed physical values before it.
            let explicitlyBorrowed = value.hasPrefix("@guaranteed ")
                || value.hasPrefix("@unowned ")
                || value.hasPrefix("@in_guaranteed ")
            let explicitlyOwned = value.hasPrefix("@owned ")
            if type.requiresLinearOwnership,
               explicitlyBorrowed
                || (implicitlyBorrowsLinearValues
                    && !explicitlyOwned
                    && typeEnvironment.containsReferenceNativeValue(type)) {
                return .borrowed
            }
            return .owned
        }
    }

    private func isObjectiveCMethodConvention(_ prefix: String) -> Bool {
        prefix.range(
            of: #"@convention\s*\(\s*objc_method\s*\)"#,
            options: .regularExpression
        ) != nil
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

    private func outerFunctionArrow(in text: String) -> Range<String.Index>? {
        var parenthesisDepth = 0
        var angleDepth = 0
        var bracketDepth = 0
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "<": angleDepth += 1
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" { angleDepth -= 1 }
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            case "-" where parenthesisDepth == 0
                    && angleDepth == 0
                    && bracketDepth == 0:
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == ">" {
                    return index..<text.index(after: next)
                }
            default:
                break
            }
            guard parenthesisDepth >= 0, angleDepth >= 0, bracketDepth >= 0 else {
                return nil
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func parseType(_ raw: String) throws -> Bytecode.ValueType {
        try typeEnvironment.resolve(raw)
    }

    private func isIntegerRangeType(_ raw: String) -> Bool {
        let type = raw.replacingOccurrences(of: " ", with: "")
        return [
            "Range<Int>",
            "Range<Swift.Int>",
            "Swift.Range<Int>",
            "Swift.Range<Swift.Int>",
        ].contains(type)
    }

    private func isIntegerRangeIteratorType(_ raw: String) -> Bool {
        let type = raw.replacingOccurrences(of: " ", with: "")
        let prefixes = ["IndexingIterator<", "Swift.IndexingIterator<"]
        guard let prefix = prefixes.first(where: { type.hasPrefix($0) }),
              type.hasSuffix(">")
        else { return false }
        let start = type.index(type.startIndex, offsetBy: prefix.count)
        let end = type.index(before: type.endIndex)
        return isIntegerRangeType(String(type[start..<end]))
    }

    private func isCharacterType(_ raw: String) -> Bool {
        let type = raw.trimmingCharacters(in: .whitespaces)
        return type == "Character" || type == "Swift.Character"
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
            case ")", "]": depth -= 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)]
                    : nil
                if previous != "-" { depth -= 1 }
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
        entryParameterTypes: [Bytecode.ValueType]?,
        erasedMetatypes: [ErasedMetatype],
        bridgedParameterTypes: [Bytecode.ValueType]?,
        indirectResultType: Bytecode.ValueType?,
        suppressVoidParameter: Bool,
        allocate: (Bytecode.ValueType) throws -> Bytecode.Register
    ) throws -> (
        block: IntermediateRepresentation.Block,
        parameters: [(String, Bytecode.Register)],
        indirectResultAddress: String?,
        indirectValueParameters: [String: Bytecode.ValueType],
        suppressedVoidParameter: String?,
        compilerOptionalVoidParameters: Set<String>,
        erasedMetatypeParameters: [(String, MetatypeIdentity)]
    )? {
        guard let match = match(line, pattern: #"^bb([0-9]+)(?:\((.*)\))?:$"#) else { return nil }
        let id = try parseBlockID(match[0])
        let parameterText = match.count > 1 ? match[1] : ""
        var parameters: [(String, Bytecode.Register)] = []
        var indirectResultAddress: String?
        var indirectValueParameters: [String: Bytecode.ValueType] = [:]
        var suppressedVoidParameter: String?
        var compilerOptionalVoidParameters = Set<String>()
        var erasedMetatypeParameters: [(String, MetatypeIdentity)] = []
        let erasedByIndex = Dictionary(
            uniqueKeysWithValues: erasedMetatypes.map {
                ($0.physicalIndex, $0.identity)
            }
        )
        if !parameterText.isEmpty {
            let components = splitTopLevel(parameterText)
            if let bridgedParameterTypes,
               bridgedParameterTypes.count != components.count {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "bridged block parameter count differs from its Optional payload"
                )
            }
            if suppressVoidParameter, components.count != 1 {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "indirect try_apply normal block has unexpected SIL parameters"
                )
            }
            for (physicalIndex, component) in components.enumerated() {
                guard let value = self.match(component, pattern: #"^(%[0-9]+)\s*:\s*(.+)$"#) else {
                    throw CanonicalSIL.LoweringError.malformedSIL("invalid block parameter \(component)")
                }
                if let identity = erasedByIndex[physicalIndex] {
                    guard metatypeIdentity(value[1]) == identity else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "entry metatype parameter does not match its concrete type"
                        )
                    }
                    erasedMetatypeParameters.append((value[0], identity))
                    continue
                }
                let physicalType: Bytecode.ValueType
                if let bridgedParameterTypes {
                    physicalType = try parsePhysicalType(
                        value[1],
                        bridgedTo: bridgedParameterTypes[physicalIndex]
                    )
                } else {
                    let parsed = try parseType(value[1])
                    if entryParameterTypes == nil, parsed == .optional(.void) {
                        physicalType = .bool
                        compilerOptionalVoidParameters.insert(value[0])
                    } else {
                        physicalType = parsed
                    }
                }
                if suppressVoidParameter {
                    guard physicalIndex == 0, physicalType == .void else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect try_apply normal block parameter is not Void"
                        )
                    }
                    suppressedVoidParameter = value[0]
                    continue
                }
                if physicalIndex == 0, let indirectResultType {
                    guard physicalType == .address(indirectResultType) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect result address does not match the function result"
                        )
                    }
                    indirectResultAddress = value[0]
                    continue
                }
                let logicalIndex = parameters.count
                let loweredType: Bytecode.ValueType
                if let entryParameterTypes,
                   entryParameterTypes.indices.contains(logicalIndex),
                   physicalType == .address(entryParameterTypes[logicalIndex]) {
                    loweredType = entryParameterTypes[logicalIndex]
                    indirectValueParameters[value[0]] = loweredType
                } else {
                    loweredType = physicalType
                }
                parameters.append((value[0], try allocate(loweredType)))
            }
        }
        return (
            IntermediateRepresentation.Block(id: id, parameters: parameters.map(\.1), instructions: []),
            parameters,
            indirectResultAddress,
            indirectValueParameters,
            suppressedVoidParameter,
            compilerOptionalVoidParameters,
            erasedMetatypeParameters
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
            case ")", "]": depth -= 1
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" { depth -= 1 }
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
