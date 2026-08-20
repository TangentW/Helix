import Foundation
import HelixBytecode
import HelixCore

extension CanonicalSIL {
public struct Lowerer: Sendable {
    private let typeEnvironment: CanonicalSIL.TypeEnvironment

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
        var elements: [Int: Bytecode.Register]
        var elementComponents: [Int: [Int: Bytecode.Register]]

        init(elementType: Bytecode.ValueType, count: Int) {
            self.elementType = elementType
            self.count = count
            elements = [:]
            elementComponents = [:]
        }
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

    /// A `_modify` coroutine lends one element address while retaining the
    /// value-semantic collection snapshot needed for writeback. The yielded
    /// element lives in a VM stack slot so arbitrary nested inout calls,
    /// including throwing calls, use the ordinary address and exclusivity
    /// machinery rather than an API-specific store pattern.
    private struct CollectionElementMutation {
        enum Source {
            case array(array: Bytecode.Register, index: Bytecode.Register)
            case dictionaryDefault(
                dictionary: Bytecode.Register,
                key: Bytecode.Register,
                keyType: Bytecode.ValueType,
                valueType: Bytecode.ValueType
            )
        }

        var collectionAddress: String
        var source: Source
        var elementType: Bytecode.ValueType
    }

    private struct DictionaryIteratorState {
        var keyType: Bytecode.ValueType
        var valueType: Bytecode.ValueType
        var dictionary: Bytecode.Register
        var indexSlot: Bytecode.StackSlot
    }

    private struct SetIteratorState {
        var elementType: Bytecode.ValueType
        var set: Bytecode.Register
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

    private struct TupleComponentStorageKey: Hashable {
        var root: String
        var path: [Int]
    }

    /// Field identity is independent of how compiler-only aggregate values are
    /// cached. Both tuples and patch-local structs use declaration-order paths.
    private struct AggregateComponentAddress {
        var base: String
        var index: Int
    }

    private struct CompilerStorageIdentity: Hashable {
        var root: String
        var path: [Int]
    }

    private struct NativePropertyAddress {
        var receiver: Bytecode.Register
        var valueType: Bytecode.ValueType
        var getter: CanonicalSIL.DirectCallBinding?
        var setter: CanonicalSIL.DirectCallBinding?
        var unavailableGetter: CanonicalSIL.UnavailableDirectCall?
        var unavailableSetter: CanonicalSIL.UnavailableDirectCall?
    }

    private struct NativeReferenceConversion {
        var argument: Bytecode.Register
        var tracksCompilerTemporary: Bool
        var forwardsExplicitOwner: Bool
    }

    enum MetatypeIdentity: Equatable, Sendable {
        case native(Core.TypeID)
        case local(Bytecode.LocalTypeKey)
    }

    struct ErasedMetatype: Equatable, Sendable {
        var physicalIndex: Int
        var identity: MetatypeIdentity
    }

    /// Keeps the physical SIL ABI separate from the frozen device target.
    /// Static metatypes and indirect results never cross the VM boundary.
    private struct ResolvedFunctionReference {
        var binding: CanonicalSIL.DirectCallBinding
        var physicalParameterConventions: [Bytecode.ParameterConvention]
        var hasIndirectResult: Bool
        var indirectErrorType: Bytecode.ValueType?
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
        var components: [Int: Bytecode.Register]

        init(destination: String, concreteType: Bytecode.ValueType) {
            self.destination = destination
            self.concreteType = concreteType
            components = [:]
        }
    }

    private struct ExistentialComponentAddress {
        var projection: String
        var index: Int
    }

    private struct OptionalAddressInitialization {
        var wrappedType: Bytecode.ValueType
        var payload: Bytecode.Register?
    }

    /// A standard-library enum that remains compiler-only while its semantic
    /// payload is lowered to typed HLBC operations.
    private struct CompilerEnumCase: Equatable {
        var typeName: String
        var caseName: String
    }

    /// Lowering represents a destructive enum-payload projection as a value
    /// take followed by writeback. The first reconstructed enum must therefore
    /// initialize the VM storage even when the original SIL expresses an
    /// in-place payload mutation.
    private struct TakenOptionalPayload {
        var address: String
        var requiresInitialization = true
    }

    private struct CollectionHigherOrderPlan {
        var operation: CanonicalSIL.HigherOrderIntrinsic
        var sourceToken: String
        var sourceType: Bytecode.ValueType
        var closureToken: String
        var initialToken: String?
        var resultDestination: String?
        var errorDestination: String?
        var inputType: Bytecode.ValueType
        var closureResultType: Bytecode.ValueType
        var callResultType: Bytecode.ValueType
        var callbackShape: CollectionCallbackShape = .element
        var consumesSource = false
    }

    private enum CollectionCallbackShape: Equatable {
        /// The closure receives the collection's represented `Element`.
        case element
        /// `Dictionary.mapValues` callbacks receive only the value field.
        case dictionaryValue
        /// `Dictionary.filter` has a two-argument key/value callback ABI even
        /// though the represented sequence element is one tuple.
        case dictionaryKeyValue
    }

    private struct ArrayOrderingPlan {
        var operation: CanonicalSIL.OrderingIntrinsic
        var sourceToken: String
        var closureToken: String
        var resultDestination: String?
        var elementType: Bytecode.ValueType
    }

    private struct ArraySplitPlan {
        var sourceToken: String
        var decisionToken: String
        var maximumSplitsToken: String
        var omittingEmptySubsequencesToken: String
        var elementType: Bytecode.ValueType
    }

    private struct ImplicitStackValue {
        var address: String
        var register: Bytecode.Register
        var storeMode: Bytecode.StackStoreMode

        init(
            _ address: String,
            _ register: Bytecode.Register,
            storeMode: Bytecode.StackStoreMode = .initialize
        ) {
            self.address = address
            self.register = register
            self.storeMode = storeMode
        }
    }

    private enum AlgebraicTransformInvocation {
        case direct(resultToken: String)
        case branching(
            normalTarget: Bytecode.BlockID,
            errorTarget: Bytecode.BlockID
        )
    }

    private struct PreparedDirectCallArguments {
        /// A nonthrowing call may temporarily materialize compiler-only value
        /// storage as a VM address. The slot is taken exactly once after every
        /// access closes, then routed through the ordinary aggregate writeback.
        struct CompilerInoutWriteback {
            var token: String
            var slot: Bytecode.StackSlot
            var pointee: Bytecode.ValueType
        }

        var arguments: [Bytecode.Register]
        var accesses: [Bytecode.Register]
        var temporaryOwners: [Bytecode.Register]
        var compilerInoutWritebacks: [CompilerInoutWriteback]
    }

    /// A compiler-only address can expose its SSA owner directly, while a VM
    /// address must materialize an owned copy for a non-consuming read. Keep
    /// that distinction explicit so callers close only the synthetic lifetime.
    private struct BorrowedStoredValue {
        var register: Bytecode.Register
        var temporaryOwner: Bytecode.Register?
    }

    /// Swift places address-only normal and error results before ordinary call
    /// arguments. HLBC keeps value continuations, so lowering removes these
    /// compiler ABI addresses and re-materializes their writes on the matching
    /// control-flow edge.
    private struct IndirectCallDestinations {
        var result: String?
        var error: String?
    }

    /// Keeps semantic preparation out of the instruction-emission stack
    /// frame. Swift Testing runs compiler work on cooperative threads with a
    /// much smaller stack than a pthread; performing whole-function analyses
    /// before entering the broad emission dispatcher avoids compounding their
    /// frames while retaining a single source of truth for normalization.
    private struct PreparedLowering: Sendable {
        var signature: (
            parameters: [Bytecode.ValueType],
            parameterConventions: [Bytecode.ParameterConvention],
            result: Bytecode.ValueType,
            hasIndirectResult: Bool,
            indirectErrorType: Bytecode.ValueType?,
            effects: Core.Effects,
            erasedMetatypes: [ErasedMetatype]
        )
        var hostedMethodContext: CanonicalSIL.TypeEnvironment.HostedMethodContext?
        var effectiveEffects: Core.Effects
        var usesRuntimeAddresses: Bool
        var normalizedBody: String
        var storageInitializationPlan: CanonicalSIL.StorageInitialization.Plan
        var nsErrorBridges: CanonicalSIL.NSErrorBridgePlan
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
        return try CanonicalSIL.LoweringStack.run {
            let preparation = try prepareLowering(
                function,
                kind: kind,
                directCalls: directCalls,
                expectedEffects: expectedEffects
            )
            return try lowerPrepared(
                function,
                displayName: displayName,
                kind: kind,
                directCalls: directCalls,
                preparation: preparation
            )
        }
    }

    private func prepareLowering(
        _ function: CanonicalSIL.Function,
        kind: Bytecode.FunctionKind,
        directCalls: CanonicalSIL.DirectCallTable,
        expectedEffects: Core.Effects?
    ) throws -> PreparedLowering {
        var signature = try parseFunctionType(function.loweredType)
        let mutableCaptures = try CanonicalSIL.MutableCaptures.normalize(
            body: function.body,
            role: kind,
            parameters: signature.parameters,
            parameterConventions: signature.parameterConventions,
            erasedPhysicalIndices: Set(
                signature.erasedMetatypes.map(\.physicalIndex)
            ),
            hasIndirectResult: signature.hasIndirectResult,
            hasIndirectError: signature.indirectErrorType != nil
        )
        signature.parameters = mutableCaptures.parameters
        signature.parameterConventions = mutableCaptures.parameterConventions
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
        let storageInitializationPlan = try CanonicalSIL.StorageInitialization
            .analyze(
                body: normalizedBody,
                directCalls: directCalls,
                typeEnvironment: typeEnvironment
            )
        let nsErrorBridges = try CanonicalSIL.NSErrorBridgePlan.analyze(
            body: normalizedBody,
            directCalls: directCalls
        )
        return .init(
            signature: signature,
            hostedMethodContext: hostedMethodContext,
            effectiveEffects: effectiveEffects,
            usesRuntimeAddresses: usesRuntimeAddresses,
            normalizedBody: normalizedBody,
            storageInitializationPlan: storageInitializationPlan,
            nsErrorBridges: nsErrorBridges
        )
    }

    // The frontend invokes lowering from cooperative workers whose stacks are
    // substantially smaller than pthread defaults. Keep debug spill slots
    // compact in addition to the explicit stack boundary used by `lower`;
    // semantic checks remain in extracted helpers and run in every build mode.
    @_optimize(size)
    private func lowerPrepared(
        _ function: CanonicalSIL.Function,
        displayName: String,
        kind: Bytecode.FunctionKind,
        directCalls: CanonicalSIL.DirectCallTable,
        preparation: PreparedLowering
    ) throws -> IntermediateRepresentation.Function {
        let signature = preparation.signature
        let hostedMethodContext = preparation.hostedMethodContext
        let effectiveEffects = preparation.effectiveEffects
        let usesRuntimeAddresses = preparation.usesRuntimeAddresses
        let normalizedBody = preparation.normalizedBody
        let storageInitializationPlan = preparation.storageInitializationPlan
        let mutableCapturePointees =
            storageInitializationPlan.mutableCapturePointees
        let nsErrorBridges = preparation.nsErrorBridges
        let rawLines = normalizedBody.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var remainingDeallocStackUses: [String: Int] = [:]
        var explicitlyDestroyedAddresses = Set<String>()
        for (index, rawLine) in rawLines.enumerated()
        where !nsErrorBridges.skippedLines.contains(index) {
            let instruction = CanonicalSIL.DebugMetadata.strippingMetadata(
                from: rawLine
            ).trimmingCharacters(in: .whitespaces)
            if let deallocation = match(
                instruction,
                pattern: #"^dealloc_stack (%[0-9]+)$"#
            ) {
                remainingDeallocStackUses[deallocation[0], default: 0] += 1
            }
            if let destruction = match(
                instruction,
                pattern: #"^destroy_addr (%[0-9]+)$"#
            ) {
                explicitlyDestroyedAddresses.insert(destruction[0])
            }
        }
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
        var declaredBlockParameterTypes: [
            Bytecode.BlockID: [Bytecode.ValueType]
        ] = [:]
        var declaredBlockIDs = Set<Bytecode.BlockID>()
        for rawLine in rawLines {
            let instruction = CanonicalSIL.DebugMetadata.strippingMetadata(
                from: rawLine
            ).trimmingCharacters(in: .whitespaces)
            guard let header = match(
                instruction,
                pattern: #"^bb([0-9]+)(?:\((.*)\))?:$"#
            ) else { continue }
            let id = try parseBlockID(header[0])
            guard declaredBlockIDs.insert(id).inserted else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "duplicate basic block \(id)"
                )
            }
            let parameterText = header.count > 1 ? header[1] : ""
            var parameterTypes: [Bytecode.ValueType] = []
            var hasOnlyStorableParameters = true
            for component in splitTopLevel(parameterText)
            where !component.isEmpty {
                guard let parameter = match(
                    component,
                    pattern: #"^%[0-9]+\s*:\s*(.+)$"#
                ), let type = try? parseType(parameter[0])
                else {
                    // Metatypes and other compiler-only block parameters are
                    // interpreted by the authoritative block parser. This
                    // optional prepass exists only to normalize provable
                    // Builtin.IntN forward edges.
                    hasOnlyStorableParameters = false
                    break
                }
                parameterTypes.append(ValueRepresentation.storable(type))
            }
            if hasOnlyStorableParameters {
                declaredBlockParameterTypes[id] = parameterTypes
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
        var localFactoryReferences: [
            String: CanonicalSIL.TypeEnvironment.StructFactory
        ] = [:]
        var stringLiterals: [String: String] = [:]
        var selectorLiterals: [String: String] = [:]
        var selectorOpaquePointers: [String: String] = [:]
        var staticStringPointers: [String: String] = [:]
        var staticStringValues: [String: String] = [:]
        var wordLiterals: [String: UInt64] = [:]
        var integerLiterals: [String: (bitWidth: UInt16, bitPattern: UInt64)] = [:]
        var retypedIntegerOperands: [String: [Bytecode.ValueType: Bytecode.Register]] = [:]
        var boolLiterals: [String: Bool] = [:]
        var metatypeValues = Set<String>()
        var scalarMetatypeValues: [String: Bytecode.ValueType] = [:]
        var compilerEnumMetatypeValues = Set<String>()
        var compilerEnumValues: [String: CompilerEnumCase] = [:]
        var compilerEnumAddressTypes: [String: String] = [:]
        var compilerEnumAddressCases: [String: CompilerEnumCase] = [:]
        var floatingSignValues: [String: Bytecode.Register] = [:]
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
        var setMetatypeValues: [String: Bytecode.ValueType] = [:]
        var stackAddressTypes: [String: Bytecode.ValueType] = [:]
        var stackAddressValues: [String: Bytecode.Register] = [:]
        var stackSlotTypes: [Bytecode.ValueType] = []
        var runtimeStackSlots: [String: Bytecode.StackSlot] = [:]
        var runtimeAddressValues: [String: Bytecode.Register] = [:]
        var runtimeAddressPointees: [String: Bytecode.ValueType] = [:]
        let mutableCaptureState = CanonicalSIL.MutableCaptures.LoweringState()
        var pendingMutableBoxes: [String: Bytecode.ValueType] = [:]
        var mutableBoxProjectionRoots: [String: String] = [:]
        var scopedRuntimeAddresses = Set<String>()
        var initializingRuntimeAccesses = Set<String>()
        var inoutParameterAddressBases = Set<String>()
        var passthroughRuntimeAccesses = Set<String>()
        var deferredAccessMetadataCleanup = Set<String>()
        var borrowedAddressValues: [String: Bytecode.Register] = [:]
        var borrowedValueTokens = Set<String>()
        var borrowedLoadTokens = Set<String>()
        var pendingRetainedValues: [String: [Bytecode.Register]] = [:]
        var retainedValueAliasRoots: [String: String] = [:]
        var borrowedTemporaryValues: [String: Bytecode.Register] = [:]
        var borrowedTemporaryAliasRoots: [String: String] = [:]
        var addressAliases: [String: String] = [:]
        var nativePropertyAddresses: [String: NativePropertyAddress] = [:]
        var pendingArrayIteratorTypes: [String: Bytecode.ValueType] = [:]
        var arrayIteratorStates: [String: ArrayIteratorState] = [:]
        var destroyedArrayIterators: [String: Set<Bytecode.BlockID>] = [:]
        var progressionValues: [String: CanonicalSIL.Progression.Value] = [:]
        var progressionAddresses: [
            String: CanonicalSIL.Progression.SequenceType
        ] = [:]
        var progressionAddressValues: [
            String: CanonicalSIL.Progression.Value
        ] = [:]
        var progressionIteratorAddresses: [
            String: CanonicalSIL.Progression.SequenceType
        ] = [:]
        var progressionIteratorStates: [
            String: CanonicalSIL.Progression.IteratorState
        ] = [:]
        var collectionElementMutations: [String: CollectionElementMutation] = [:]
        var collectionMutationYieldByToken: [String: String] = [:]
        var integerConversionResults = Set<String>()
        var pendingDictionaryIteratorTypes: [String: (Bytecode.ValueType, Bytecode.ValueType)] = [:]
        var pendingDictionaryIteratorValues: [String: DictionaryIteratorState] = [:]
        var dictionaryIteratorStates: [String: DictionaryIteratorState] = [:]
        var destroyedDictionaryIterators: [String: Set<Bytecode.BlockID>] = [:]
        var pendingSetIteratorTypes: [String: Bytecode.ValueType] = [:]
        var pendingSetIteratorValues: [String: SetIteratorState] = [:]
        var setIteratorStates: [String: SetIteratorState] = [:]
        var destroyedSetIterators: [String: Set<Bytecode.BlockID>] = [:]
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
        var tupleComponentValues: [TupleComponentStorageKey: Bytecode.Register] = [:]
        var aggregateComponentAddresses: [String: AggregateComponentAddress] = [:]
        var tupleValues: [String: (Bytecode.Register, Bytecode.Register)] = [:]
        var unpackedTuples: [Bytecode.Register: [Bytecode.Register]] = [:]
        var onStackClosureValues = Set<String>()
        var voidValues = Set<String>()
        var optionalSourceBySomeBlock: [Bytecode.BlockID: String] = [:]
        var optionalSourceByNoneBlock: [Bytecode.BlockID: String] = [:]
        // Root-only facts would let one Optional tuple field prove a sibling.
        // SSA-to-storage provenance is block-local so textual block order
        // cannot impersonate a CFG merge.
        var knownSomeOptionalAddresses: [
            Bytecode.BlockID: Set<CompilerStorageIdentity>
        ] = [:]
        var knownSomeOptionalValues: [Bytecode.BlockID: Set<String>] = [:]
        var optionalValueSourcesByBlock: [
            Bytecode.BlockID: [CompilerStorageIdentity: String]
        ] = [:]
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
        var takenOptionalPayloads: [String: TakenOptionalPayload] = [:]
        var indirectResultAddress: String?
        var indirectResultSlot: Bytecode.StackSlot?
        var indirectErrorAddress: String?
        var typedErrorBoxTypes: [String: Bytecode.LocalTypeKey] = [:]
        var projectedBoxByAddress: [String: String] = [:]
        var errorMessageByBox: [String: String] = [:]
        var catchScratchAddresses = Set<String>()
        var implicitStackValues: [
            Bytecode.BlockID: [ImplicitStackValue]
        ] = [:]
        var implicitOwnerCleanups: [
            Bytecode.BlockID: [Bytecode.Register]
        ] = [:]
        var implicitAccessCleanups: [
            Bytecode.BlockID: [Bytecode.Register]
        ] = [:]
        var compilerAddressWrites: [
            Bytecode.BlockID: [String: Bytecode.Register]
        ] = [:]
        var compilerAddressMergeRegisters: [
            Bytecode.BlockID: [String: Bytecode.Register]
        ] = [:]
        var suppressedVoidTryNormalBlocks = Set<Bytecode.BlockID>()
        var blocks: [IntermediateRepresentation.Block] = []
        var current: IntermediateRepresentation.Block?
        var unreachableTrapReasons: [Bytecode.BlockID: Bytecode.TrapReason] = [:]
        var currentSourceLocation: Core.SourceLocation?
        var currentSILLineIndex = 0
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

        func copyOwnedValue(
            _ source: Bytecode.Register
        ) throws -> Bytecode.Register {
            let type = registerTypes[Int(source.rawValue)]
            guard !type.isTrivial else { return source }
            let copy = try allocate(type: type)
            appendInstruction(.copyValue(result: copy, source: source))
            return copy
        }

        func retainedValueAliasRoot(for token: String) -> String {
            var current = token
            var visited = Set<String>()
            while let next = retainedValueAliasRoots[current],
                  visited.insert(current).inserted {
                current = next
            }
            return current
        }

        func aliasRetainedValue(
            _ resultToken: String,
            to sourceToken: String
        ) {
            let sourceRoot = retainedValueAliasRoot(for: sourceToken)
            let resultRoot = retainedValueAliasRoot(for: resultToken)
            guard resultRoot != sourceRoot else { return }
            if let pending = pendingRetainedValues.removeValue(
                forKey: resultRoot
            ) {
                pendingRetainedValues[sourceRoot, default: []]
                    .append(contentsOf: pending)
            }
            retainedValueAliasRoots[resultRoot] = sourceRoot
            retainedValueAliasRoots[resultToken] = sourceRoot
        }

        func recordPendingRetainedValue(
            _ value: Bytecode.Register,
            for token: String
        ) {
            let root = retainedValueAliasRoot(for: token)
            pendingRetainedValues[root, default: []].append(value)
        }

        func takePendingRetainedValue(
            for token: String
        ) -> Bytecode.Register? {
            let root = retainedValueAliasRoot(for: token)
            guard var pending = pendingRetainedValues[root],
                  let retained = pending.popLast()
            else { return nil }
            if pending.isEmpty {
                pendingRetainedValues.removeValue(forKey: root)
            } else {
                pendingRetainedValues[root] = pending
            }
            return retained
        }

        func borrowedTemporaryAliasRoot(for token: String) -> String {
            var current = token
            var visited = Set<String>()
            while let next = borrowedTemporaryAliasRoots[current],
                  visited.insert(current).inserted {
                current = next
            }
            return current
        }

        func aliasBorrowedTemporary(
            _ resultToken: String,
            to sourceToken: String
        ) {
            let sourceRoot = borrowedTemporaryAliasRoot(for: sourceToken)
            let resultRoot = borrowedTemporaryAliasRoot(for: resultToken)
            guard resultRoot != sourceRoot else { return }
            borrowedTemporaryAliasRoots[resultRoot] = sourceRoot
            borrowedTemporaryAliasRoots[resultToken] = sourceRoot
        }

        func borrowedTemporaryValue(for token: String) -> Bytecode.Register? {
            borrowedTemporaryValues[borrowedTemporaryAliasRoot(for: token)]
        }

        func borrowedTemporaryAliasTokens(for token: String) -> Set<String> {
            let root = borrowedTemporaryAliasRoot(for: token)
            var aliases: Set<String> = [root, token]
            for candidate in borrowedTemporaryAliasRoots.keys
            where borrowedTemporaryAliasRoot(for: candidate) == root {
                aliases.insert(candidate)
            }
            return aliases
        }

        func clearBorrowedTemporaryClassification(for token: String) {
            for alias in borrowedTemporaryAliasTokens(for: token) {
                borrowedValueTokens.remove(alias)
                borrowedLoadTokens.remove(alias)
            }
        }

        func recordBorrowedTemporaryValue(
            _ value: Bytecode.Register,
            for token: String
        ) throws {
            let root = borrowedTemporaryAliasRoot(for: token)
            guard borrowedTemporaryValues[root] == nil else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "borrowed temporary token already owns a VM value"
                )
            }
            borrowedTemporaryValues[root] = value
        }

        @discardableResult
        func removeBorrowedTemporaryValue(
            for token: String
        ) -> Bytecode.Register? {
            borrowedTemporaryValues.removeValue(
                forKey: borrowedTemporaryAliasRoot(for: token)
            )
        }

        func prepareOwnedValue(
            _ token: String,
            expectedType: Bytecode.ValueType? = nil,
            line: Int
        ) throws -> Bytecode.Register {
            let value = try resolveStorableValue(
                token,
                expectedType: expectedType,
                line: line
            )
            let type = registerTypes[Int(value.rawValue)]
            if let retained = takePendingRetainedValue(for: token) {
                guard registerTypes[Int(retained.rawValue)] == type else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "retained owned value has the wrong type"
                    )
                }
                return retained
            }
            guard type.requiresLinearOwnership else { return value }
            if let temporary = borrowedTemporaryValue(for: token) {
                guard temporary == value else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "borrowed temporary ownership does not match its SIL value"
                    )
                }
                let owned = try copyOwnedValue(value)
                if !hasFutureSemanticUse(
                    ofBorrowedTemporaryAliasedTo: token,
                    after: currentSILLineIndex
                ) {
                    removeBorrowedTemporaryValue(for: token)
                    clearBorrowedTemporaryClassification(for: token)
                    appendInstruction(.destroyValue(temporary))
                }
                return owned
            }
            let preservesSource = isBorrowedValue(token: token, register: value)
                || hasFutureSemanticUse(
                    of: token,
                    after: currentSILLineIndex
                )
            guard preservesSource else { return value }
            // Every HLBC aggregate/call/return ownership edge is explicit.
            // Canonical SIL may express that edge as ARC traffic around a
            // borrowed or subsequently reused SSA value, so materialize a VM
            // owner when no explicit retained owner is available.
            return try copyOwnedValue(value)
        }

        func prepareReturnValue(
            _ token: String,
            line: Int
        ) throws -> Bytecode.Register {
            try prepareOwnedValue(token, line: line)
        }

        func prepareStoredValue(
            _ token: String,
            expectedType: Bytecode.ValueType,
            line: Int
        ) throws -> Bytecode.Register {
            try prepareOwnedValue(
                token,
                expectedType: expectedType,
                line: line
            )
        }

        func materializeRetain(
            of token: String,
            value: Bytecode.Register
        ) throws {
            let type = registerTypes[Int(value.rawValue)]
            guard type.requiresLinearOwnership else { return }
            let retained = try copyOwnedValue(value)
            if let temporary = borrowedTemporaryValue(for: token) {
                guard temporary == value else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "borrowed temporary retain does not match its SIL value"
                    )
                }
                removeBorrowedTemporaryValue(for: token)
                for alias in borrowedTemporaryAliasTokens(for: token)
                where values[alias] == temporary {
                    values[alias] = retained
                }
                clearBorrowedTemporaryClassification(for: token)
                appendInstruction(.destroyValue(temporary))
                return
            }
            recordPendingRetainedValue(retained, for: token)
        }

        func isBorrowedParameter(_ register: Bytecode.Register) -> Bool {
            zip(parameterRegisters, signature.parameterConventions).contains {
                $0.0 == register && $0.1 == .borrowed
            }
        }

        func isBorrowedValue(
            token: String,
            register: Bytecode.Register
        ) -> Bool {
            borrowedValueTokens.contains(token)
                || borrowedLoadTokens.contains(token)
                || isBorrowedParameter(register)
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

        func hasFutureSemanticUse(
            ofBorrowedTemporaryAliasedTo token: String,
            after lineIndex: Int
        ) -> Bool {
            borrowedTemporaryAliasTokens(for: token).contains {
                hasFutureSemanticUse(of: $0, after: lineIndex)
            }
        }

        func removeAccessMetadata(_ token: String) {
            passthroughRuntimeAccesses.remove(token)
            initializingRuntimeAccesses.remove(token)
            scopedRuntimeAddresses.remove(token)
            runtimeAddressValues.removeValue(forKey: token)
            runtimeAddressPointees.removeValue(forKey: token)
            mutableCaptureState.addresses.removeValue(forKey: token)
            values.removeValue(forKey: token)
            addressAliases.removeValue(forKey: token)
        }

        func prepareNativeReferenceConversion(
            sourceToken: String,
            source: Bytecode.Register,
            lineIndex: Int
        ) throws -> NativeReferenceConversion {
            if let retained = takePendingRetainedValue(for: sourceToken) {
                guard registerTypes[Int(retained.rawValue)]
                        == registerTypes[Int(source.rawValue)]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "retained native conversion owner has the wrong type"
                    )
                }
                return .init(
                    argument: retained,
                    tracksCompilerTemporary: false,
                    forwardsExplicitOwner: true
                )
            }
            // Native bridge calls consume their argument. Preserve a borrowed
            // or subsequently reused SIL source and own the conversion result
            // as a compiler-generated temporary until its final semantic use.
            let sourceIsBorrowed = isBorrowedValue(
                token: sourceToken,
                register: source
            )
            let preservesSource = sourceIsBorrowed
                || hasFutureSemanticUse(of: sourceToken, after: lineIndex)
            return .init(
                argument: preservesSource
                    ? try copyOwnedValue(source)
                    : source,
                tracksCompilerTemporary: preservesSource,
                forwardsExplicitOwner: false
            )
        }

        func releaseBorrowedTemporariesAfterLastUse(
            _ tokens: some Sequence<String>,
            after lineIndex: Int
        ) {
            for token in Set(tokens) where !hasFutureSemanticUse(
                ofBorrowedTemporaryAliasedTo: token,
                after: lineIndex
            ) {
                guard let value = removeBorrowedTemporaryValue(for: token)
                else { continue }
                clearBorrowedTemporaryClassification(for: token)
                appendInstruction(.destroyValue(value))
            }
        }

        func closeBorrowedTemporaryLifetime(
            for token: String,
            resolved value: Bytecode.Register
        ) throws {
            guard let tracked = removeBorrowedTemporaryValue(for: token)
            else { return }
            guard tracked == value else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "borrowed temporary ownership does not match its SIL value"
                )
            }
            clearBorrowedTemporaryClassification(for: token)
        }

        func transferBorrowedTemporaryLifetime(
            from sourceToken: String,
            resolved source: Bytecode.Register,
            to resultToken: String,
            result: Bytecode.Register
        ) throws {
            guard let tracked = removeBorrowedTemporaryValue(for: sourceToken)
            else { return }
            guard tracked == source else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "borrowed temporary cannot transfer into a different owner"
                )
            }
            clearBorrowedTemporaryClassification(for: sourceToken)
            try recordBorrowedTemporaryValue(result, for: resultToken)
        }

        func addressBase(_ token: String) -> String {
            var current = token
            var visited = Set<String>()
            while let next = addressAliases[current], visited.insert(current).inserted {
                current = next
            }
            return current
        }

        func mutableCell(at token: String) -> Bytecode.Register? {
            (mutableCaptureState.addresses[token]
                ?? mutableCaptureState.addresses[addressBase(token)])?.register
        }

        func mutableCellPointee(at token: String) -> Bytecode.ValueType? {
            (mutableCaptureState.addresses[token]
                ?? mutableCaptureState.addresses[addressBase(token)])?.pointee
        }

        func isKnownSomeOptionalAddress(
            _ token: String,
            in blockID: Bytecode.BlockID?
        ) -> Bool {
            guard let blockID else { return false }
            return knownSomeOptionalAddresses[blockID]?
                .contains(compilerStorageIdentity(for: token)) == true
        }

        func setKnownSomeOptionalAddress(
            _ token: String,
            in blockID: Bytecode.BlockID,
            isKnownSome: Bool
        ) {
            let key = compilerStorageIdentity(for: token)
            if isKnownSome {
                knownSomeOptionalAddresses[blockID, default: []].insert(key)
            } else {
                knownSomeOptionalAddresses[blockID]?.remove(key)
            }
        }

        func isKnownSomeOptionalValue(
            _ token: String,
            in blockID: Bytecode.BlockID?
        ) -> Bool {
            knownOptionalSomePayloads[token] != nil
                || blockID.map {
                    knownSomeOptionalValues[$0]?.contains(token) == true
                } == true
        }

        func setKnownSomeOptionalValue(
            _ token: String,
            in blockID: Bytecode.BlockID,
            isKnownSome: Bool
        ) {
            if isKnownSome {
                knownSomeOptionalValues[blockID, default: []].insert(token)
            } else {
                knownSomeOptionalValues[blockID]?.remove(token)
            }
        }

        func stackType(at token: String) -> Bytecode.ValueType? {
            mutableCellPointee(at: token)
                ?? runtimeAddressPointees[token]
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
            guard runtimeAddress(at: token) == nil,
                  mutableCell(at: token) == nil
            else { return nil }
            if let key = tupleComponentStorageKey(for: token) {
                return tupleComponentValues[key]
            }
            return stackAddressValues[addressBase(token)]
        }

        func recordCompilerAddressValue(_ value: Bytecode.Register, at token: String) {
            if let key = tupleComponentStorageKey(for: token) {
                // A projected write invalidates any cached aggregate snapshot
                // containing that field, as well as nested snapshots replaced
                // by the write. Storage itself is keyed by semantic field path
                // so distinct SIL projections alias one value.
                stackAddressValues.removeValue(forKey: key.root)
                tupleComponentValues = tupleComponentValues.filter { candidate, _ in
                    guard candidate.root == key.root else { return true }
                    return !candidate.path.starts(with: key.path)
                        && !key.path.starts(with: candidate.path)
                }
                tupleComponentValues[key] = value
                return
            }
            let root = addressBase(token)
            stackAddressValues[root] = value
            tupleComponentValues = tupleComponentValues.filter { $0.key.root != root }
        }

        @discardableResult
        func removeCompilerAddressValue(at token: String) -> Bytecode.Register? {
            if let key = tupleComponentStorageKey(for: token) {
                let removed = tupleComponentValues[key]
                stackAddressValues.removeValue(forKey: key.root)
                tupleComponentValues = tupleComponentValues.filter { candidate, _ in
                    guard candidate.root == key.root else { return true }
                    return !candidate.path.starts(with: key.path)
                        && !key.path.starts(with: candidate.path)
                }
                return removed
            }
            return stackAddressValues.removeValue(forKey: addressBase(token))
        }

        func tupleComponentStorageKey(
            for token: String
        ) -> TupleComponentStorageKey? {
            var current = token
            var reversedPath: [Int] = []
            var visited = Set<String>()
            while visited.insert(current).inserted {
                if let component = tupleComponentAddresses[current] {
                    reversedPath.append(component.index)
                    current = component.base
                    continue
                }
                let canonical = addressBase(current)
                guard canonical != current else { break }
                current = canonical
            }
            guard !reversedPath.isEmpty else { return nil }
            return .init(
                root: addressBase(current),
                path: Array(reversedPath.reversed())
            )
        }

        func unpackTupleValue(
            _ tuple: Bytecode.Register,
            retainedOwnerFor token: String? = nil
        ) throws -> [Bytecode.Register] {
            guard case let .tuple(types) = registerTypes[Int(tuple.rawValue)]
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "tuple storage does not contain a tuple VM value"
                )
            }
            if let existing = unpackedTuples[tuple] {
                return existing
            }
            let owner = token.flatMap(takePendingRetainedValue) ?? tuple
            guard registerTypes[Int(owner.rawValue)] == .tuple(types) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "retained tuple projection owner has the wrong type"
                )
            }
            let elements = try types.map { try allocate(type: $0) }
            unpackedTuples[tuple] = elements
            unpackedTuples[owner] = elements
            // Canonical SIL commonly retains an aggregate before projecting
            // fields whose ownership is then released or transferred
            // independently. Destructure that explicit owner so the borrowed
            // aggregate itself remains untouched and ownership is distributed
            // to the projected VM values.
            appendInstruction(.unpackTuple(results: elements, tuple: owner))
            return elements
        }

        /// Compiler-only tuple storage may alternate between one aggregate
        /// register and field registers. Rebuild the requested aggregate only
        /// when every leaf is initialized; making that transition explicit
        /// preserves linear ownership for nested tuples as well as scalars.
        func rebuildTupleStorageValue(
            root: String,
            type: Bytecode.ValueType,
            path: [Int] = []
        ) throws -> Bytecode.Register? {
            if path.isEmpty, let aggregate = stackAddressValues[root] {
                return aggregate
            }
            if !path.isEmpty,
               let aggregate = tupleComponentValues[
                .init(root: root, path: path)
               ] {
                return aggregate
            }
            guard case let .tuple(types) = type else { return nil }

            var elements: [Bytecode.Register] = []
            elements.reserveCapacity(types.count)
            for (index, elementType) in types.enumerated() {
                let childPath = path + [index]
                let childKey = TupleComponentStorageKey(
                    root: root,
                    path: childPath
                )
                let child: Bytecode.Register? = if let value = tupleComponentValues[
                    childKey
                ] {
                    value
                } else if case .tuple = elementType {
                    try rebuildTupleStorageValue(
                        root: root,
                        type: elementType,
                        path: childPath
                    )
                } else {
                    nil
                }
                guard let child,
                      registerTypes[Int(child.rawValue)] == elementType
                else { return nil }
                elements.append(child)
            }

            let result = try allocate(type: type)
            appendInstruction(.makeTuple(result: result, elements: elements))
            tupleComponentValues = tupleComponentValues.filter {
                candidate,
                _ in
                guard candidate.root == root else { return true }
                return !candidate.path.starts(with: path)
                    || candidate.path.count <= path.count
            }
            if path.isEmpty {
                stackAddressValues[root] = result
            } else {
                tupleComponentValues[.init(root: root, path: path)] = result
            }
            return result
        }

        /// Materializes every declared descendant projection from an aggregate
        /// regardless of whether the projection address was formed before or
        /// after the aggregate became initialized.
        func materializeTupleComponents(
            at base: String,
            tuple: Bytecode.Register
        ) throws {
            guard case .tuple = registerTypes[Int(tuple.rawValue)] else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "tuple address does not contain a tuple VM value"
                )
            }
            let baseKey = tupleComponentStorageKey(for: base)
            let root = baseKey?.root ?? addressBase(base)
            let basePath = baseKey?.path ?? []
            let targets = Set(tupleComponentAddresses.keys.compactMap {
                tupleComponentStorageKey(for: $0)
            }.filter {
                $0.root == root
                    && $0.path.count > basePath.count
                    && $0.path.starts(with: basePath)
            }).sorted { lhs, rhs in
                if lhs.path.count != rhs.path.count {
                    return lhs.path.count < rhs.path.count
                }
                for (left, right) in zip(lhs.path, rhs.path)
                where left != right {
                    return left < right
                }
                return false
            }
            guard !targets.isEmpty else { return }

            for target in targets {
                var current = tuple
                var currentPath = basePath
                for index in target.path.dropFirst(basePath.count) {
                    let childPath = currentPath + [index]
                    let childKey = TupleComponentStorageKey(
                        root: root,
                        path: childPath
                    )
                    if let cached = tupleComponentValues[childKey] {
                        current = cached
                    } else {
                        let elements = try unpackTupleValue(current)
                        if currentPath.isEmpty {
                            stackAddressValues.removeValue(forKey: root)
                        } else {
                            tupleComponentValues.removeValue(
                                forKey: .init(
                                    root: root,
                                    path: currentPath
                                )
                            )
                        }
                        guard elements.indices.contains(index) else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "tuple component address is out of bounds"
                            )
                        }
                        for (childIndex, element) in elements.enumerated() {
                            tupleComponentValues[
                                .init(
                                    root: root,
                                    path: currentPath + [childIndex]
                                )
                            ] = element
                        }
                        current = elements[index]
                    }
                    currentPath = childPath
                }
            }
            if let baseKey {
                tupleComponentValues.removeValue(forKey: baseKey)
            } else {
                stackAddressValues.removeValue(forKey: root)
            }
        }

        func compilerStorageIdentity(
            for token: String
        ) -> CompilerStorageIdentity {
            var current = token
            var reversedPath: [Int] = []
            var visited = Set<String>()
            while visited.insert(current).inserted {
                if let component = aggregateComponentAddresses[current] {
                    reversedPath.append(component.index)
                    current = component.base
                    continue
                }
                let canonical = addressBase(current)
                guard canonical != current else { break }
                current = canonical
            }
            return .init(
                root: addressBase(current),
                path: Array(reversedPath.reversed())
            )
        }

        func optionalValueSource(at token: String) -> String? {
            guard let blockID = current?.id else { return nil }
            return optionalValueSourcesByBlock[blockID]?[
                compilerStorageIdentity(for: token)
            ]
        }

        func recordOptionalValueSource(
            _ source: String?,
            at token: String
        ) {
            guard let blockID = current?.id else { return }
            let key = compilerStorageIdentity(for: token)
            if let source {
                optionalValueSourcesByBlock[blockID, default: [:]][key] = source
            } else {
                optionalValueSourcesByBlock[blockID]?.removeValue(forKey: key)
            }
        }

        func invalidateOptionalStorageFacts(at token: String) {
            guard let blockID = current?.id else { return }
            let changed = compilerStorageIdentity(for: token)
            func overlaps(_ candidate: CompilerStorageIdentity) -> Bool {
                guard candidate.root == changed.root else { return false }
                return candidate.path.starts(with: changed.path)
                    || changed.path.starts(with: candidate.path)
            }
            if let known = knownSomeOptionalAddresses[blockID] {
                knownSomeOptionalAddresses[blockID] = Set(
                    known.filter { !overlaps($0) }
                )
            }
            if let sources = optionalValueSourcesByBlock[blockID] {
                optionalValueSourcesByBlock[blockID] = sources.filter {
                    !overlaps($0.key)
                }
            }
        }

        func inheritKnownOptionalValueCase(
            from source: String,
            to result: String
        ) {
            guard let blockID = current?.id,
                  isKnownSomeOptionalValue(source, in: blockID)
            else { return }
            setKnownSomeOptionalValue(result, in: blockID, isKnownSome: true)
        }

        func recordOptionalLoadCase(
            from address: String,
            to result: String,
            type: Bytecode.ValueType
        ) {
            guard case .optional = type,
                  let blockID = current?.id,
                  isKnownSomeOptionalAddress(address, in: blockID)
            else { return }
            setKnownSomeOptionalValue(result, in: blockID, isKnownSome: true)
        }

        @discardableResult
        func removeTupleComponentValues(rootedAt root: String) -> [Bytecode.Register] {
            let canonicalRoot = addressBase(root)
            let matching = tupleComponentValues.filter {
                $0.key.root == canonicalRoot
            }
            for key in matching.keys {
                tupleComponentValues.removeValue(forKey: key)
            }
            return Array(matching.values)
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
            if let value = stackValue(at: token) {
                return value
            }
            guard runtimeAddress(at: token) == nil,
                  mutableCell(at: token) == nil
            else { return nil }
            if let key = tupleComponentStorageKey(for: token) {
                if let rootAggregate = stackAddressValues[key.root] {
                    try materializeTupleComponents(
                        at: key.root,
                        tuple: rootAggregate
                    )
                    return tupleComponentValues[key]
                }
                guard let componentType = stackType(at: token),
                      case .tuple = componentType
                else { return nil }
                return try rebuildTupleStorageValue(
                    root: key.root,
                    type: componentType,
                    path: key.path
                )
            }
            let root = addressBase(token)
            guard let rootType = stackAddressTypes[root],
                  case .tuple = rootType
            else { return nil }
            return try rebuildTupleStorageValue(root: root, type: rootType)
        }

        func copyStoredValue(
            at token: String,
            line: Int
        ) throws -> Bytecode.Register? {
            guard let type = stackType(at: token) else { return nil }
            if storageInitializationPlan.consumesApplicationArgument(
                token,
                at: currentSILLineIndex
            ) {
                guard let taken = try takeStoredValue(at: token, line: line) else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: line,
                        text: "consuming @in argument cannot transfer its storage"
                    )
                }
                return taken
            }
            if let cell = mutableCell(at: token) {
                let result = try allocate(type: type)
                appendInstruction(
                    .loadMutableCell(result: result, cell: cell)
                )
                return result
            }
            if let address = runtimeAddress(at: token) {
                let result = try allocate(type: type)
                if isScopedRuntimeAddress(token) {
                    appendInstruction(
                        .loadAddress(result: result, address: address, mode: .copy)
                    )
                } else {
                    let access = try allocate(type: .address(type))
                    appendInstruction(
                        .beginAccess(result: access, address: address, kind: .read)
                    )
                    appendInstruction(
                        .loadAddress(result: result, address: access, mode: .copy)
                    )
                    appendInstruction(.endAccess(access))
                }
                return result
            }
            guard let stored = try resolvedStackValue(at: token, line: line),
                  registerTypes[Int(stored.rawValue)] == type
            else { return nil }
            guard !type.isTrivial else { return stored }
            let result = try allocate(type: type)
            appendInstruction(.copyValue(result: result, source: stored))
            return result
        }

        func borrowStoredValue(
            at token: String,
            line: Int
        ) throws -> BorrowedStoredValue? {
            guard let type = stackType(at: token) else { return nil }
            if runtimeAddress(at: token) != nil || mutableCell(at: token) != nil {
                guard let copy = try copyStoredValue(at: token, line: line) else {
                    return nil
                }
                return .init(
                    register: copy,
                    temporaryOwner: type.requiresLinearOwnership ? copy : nil
                )
            }
            guard let stored = try resolvedStackValue(at: token, line: line),
                  registerTypes[Int(stored.rawValue)] == type
            else { return nil }
            return .init(register: stored, temporaryOwner: nil)
        }

        /// Produces a value that a consuming operation may transfer. Storage
        /// retains its own lifetime; direct linear values are copied for the
        /// same reason, while non-linear direct values may be reused.
        func materializeOwnedValue(
            at token: String,
            line: Int
        ) throws -> Bytecode.Register {
            if stackType(at: token) != nil {
                guard let copy = try copyStoredValue(at: token, line: line) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "address-backed value is uninitialized"
                    )
                }
                return copy
            }
            return try prepareOwnedValue(token, line: line)
        }

        func takeStoredValue(
            at token: String,
            line: Int
        ) throws -> Bytecode.Register? {
            guard let type = stackType(at: token),
                  mutableCell(at: token) == nil
            else { return nil }
            let root = addressBase(token)
            if let address = runtimeAddress(at: token) {
                guard let slot = runtimeStackSlots[root] else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: line,
                        text: "taking caller-owned address storage requires writeback"
                    )
                }
                let result = try allocate(type: type)
                if token == root, !isScopedRuntimeAddress(token) {
                    appendInstruction(
                        .loadStack(result: result, slot: slot, mode: .take)
                    )
                } else if isScopedRuntimeAddress(token) {
                    appendInstruction(
                        .loadAddress(
                            result: result,
                            address: address,
                            mode: .take
                        )
                    )
                } else {
                    let access = try allocate(type: .address(type))
                    appendInstruction(
                        .beginAccess(
                            result: access,
                            address: address,
                            kind: .modify
                        )
                    )
                    appendInstruction(
                        .loadAddress(
                            result: result,
                            address: access,
                            mode: .take
                        )
                    )
                    appendInstruction(.endAccess(access))
                }
                stackAddressValues.removeValue(forKey: root)
                invalidateOptionalStorageFacts(at: token)
                return result
            }
            guard let stored = try resolvedStackValue(at: token, line: line),
                  !type.requiresLinearOwnership
                    || !isBorrowedValue(token: token, register: stored)
            else { return nil }
            removeCompilerAddressValue(at: token)
            invalidateOptionalStorageFacts(at: token)
            return stored
        }

        func destroyRuntimeStoredValue(
            at token: String,
            line: Int,
            ifInitialized: Bool
        ) throws -> Bool {
            guard let type = stackType(at: token),
                  mutableCell(at: token) == nil,
                  let address = runtimeAddress(at: token)
            else { return false }
            let root = addressBase(token)
            guard runtimeStackSlots[root] != nil else {
                throw CanonicalSIL.LoweringError.unsupportedInstruction(
                    line: line,
                    text: "destroying caller-owned or object address storage requires writeback"
                )
            }
            let destroy: Bytecode.Instruction = if ifInitialized {
                .destroyAddressIfInitialized(address)
            } else {
                .destroyAddress(address)
            }
            if isScopedRuntimeAddress(token) {
                appendInstruction(destroy)
            } else {
                let access = try allocate(type: .address(type))
                appendInstruction(
                    .beginAccess(
                        result: access,
                        address: address,
                        kind: .modify
                    )
                )
                let scopedDestroy: Bytecode.Instruction = if ifInitialized {
                    .destroyAddressIfInitialized(access)
                } else {
                    .destroyAddress(access)
                }
                appendInstruction(scopedDestroy)
                appendInstruction(.endAccess(access))
            }
            removeCompilerAddressValue(at: token)
            invalidateOptionalStorageFacts(at: token)
            return true
        }

        // Materialized values must cross this single sink so compiler-only
        // storage, runtime stack slots, scoped accesses, and projected
        // addresses preserve the same SIL initialization semantics.
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
            invalidateOptionalStorageFacts(at: token)
            if let addressRegister = runtimeAddress(at: token) {
                let root = addressBase(token)
                let inferredMode = storageInitializationPlan.storeMode(
                    at: currentSILLineIndex,
                    address: token
                )
                if isScopedRuntimeAddress(token) {
                    appendInstruction(
                        .storeAddress(
                            address: addressRegister,
                            source: value,
                            mode: requestedMode
                                ?? (initializingRuntimeAccesses.contains(token)
                                    ? .initialize : inferredMode)
                        )
                    )
                } else if let slot = runtimeStackSlots[root], token == root {
                    appendInstruction(
                        .storeStack(
                            slot: slot,
                            source: value,
                            mode: requestedMode ?? inferredMode
                        )
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
                            mode: requestedMode ?? inferredMode
                        )
                    )
                    appendInstruction(.endAccess(access))
                }
                // Runtime storage owns the consumed source. Never retain that
                // register as a compiler-address value: doing so would let a
                // later read bypass load/copy semantics after ownership moved.
                stackAddressValues.removeValue(forKey: root)
                return
            }
            let mode = requestedMode ?? storageInitializationPlan.storeMode(
                at: currentSILLineIndex,
                address: token
            )
            if mode != .initialize,
               let previous = try resolvedStackValue(
                at: token,
                line: currentSILLineIndex + 1
               ),
               previous != value,
               registerTypes[Int(previous.rawValue)].requiresLinearOwnership {
                // Compiler-only addresses elide VM storage instructions, but
                // assignment still ends the previous stored ownership. Keep
                // that release in the shared storage sink so every synthesized
                // mutating operation follows the same rule.
                appendInstruction(.destroyValue(previous))
            }
            recordCompilerAddressValue(value, at: token)
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

        func materializeUnitValue() throws -> Bytecode.Register {
            try materializeZeroSizedValue(type: ValueRepresentation.unit)
        }

        func materializeZeroSizedValue(
            type: Bytecode.ValueType
        ) throws -> Bytecode.Register {
            guard let aggregate = try typeEnvironment.zeroSizedAggregate(
                for: type
            ) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "value type is not statically zero-sized"
                )
            }
            switch aggregate {
            case let .tuple(elementTypes):
                let elements = try elementTypes.map {
                    try materializeZeroSizedValue(type: $0)
                }
                let result = try allocate(type: type)
                appendInstruction(.makeTuple(result: result, elements: elements))
                return result
            case let .structure(key, fields):
                let values = try fields.map {
                    try materializeZeroSizedValue(type: $0.type)
                }
                let result = try allocate(type: .local(key))
                appendInstruction(.makeStruct(result: result, fields: values))
                return result
            }
        }

        func materializeStructFactoryValue(
            plan: CanonicalSIL.TypeEnvironment.StructFieldPlan,
            physicalValues: [Bytecode.Register]
        ) throws -> Bytecode.Register {
            switch plan {
            case let .parameter(index, type):
                guard physicalValues.indices.contains(index),
                      registerTypes[Int(physicalValues[index].rawValue)] == type
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local struct initializer physical parameter does not match its plan"
                    )
                }
                return physicalValues[index]
            case let .tuple(type, elementPlans):
                guard case let .tuple(elementTypes) = type,
                      elementTypes.count == elementPlans.count
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local struct initializer has an invalid tuple reconstruction plan"
                    )
                }
                let elements = try elementPlans.map {
                    try materializeStructFactoryValue(
                        plan: $0,
                        physicalValues: physicalValues
                    )
                }
                guard zip(elements, elementTypes).allSatisfy({ value, expected in
                    registerTypes[Int(value.rawValue)] == expected
                }) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local struct initializer tuple elements do not match their plan"
                    )
                }
                let result = try allocate(type: type)
                appendInstruction(.makeTuple(result: result, elements: elements))
                return result
            }
        }

        func resolveStorableValue(
            _ token: String,
            expectedType: Bytecode.ValueType? = nil,
            line: Int
        ) throws -> Bytecode.Register {
            if voidValues.contains(token) {
                let materializedType = expectedType ?? ValueRepresentation.unit
                guard materializedType == ValueRepresentation.unit else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Void value does not match its materialized storage type"
                    )
                }
                return try materializeUnitValue()
            }
            let value = try resolve(token, line: line)
            if let expectedType,
               registerTypes[Int(value.rawValue)] != expectedType {
                let actualType = registerTypes[Int(value.rawValue)]
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "stored value \(token) at SIL line \(line) has type "
                        + "\(actualType), expected "
                        + "\(expectedType)"
                )
            }
            return value
        }

        func prepareDirectCallArguments(
            _ tokens: [String],
            physicalConventions: [Bytecode.ParameterConvention],
            logicalTypes: [Bytecode.ValueType],
            line: Int,
            allowsCompilerInoutWriteback: Bool
        ) throws -> PreparedDirectCallArguments {
            guard tokens.count == physicalConventions.count,
                  tokens.count == logicalTypes.count
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "direct call physical and logical argument counts disagree"
                )
            }
            let inoutIdentities = zip(tokens, physicalConventions)
                .compactMap { token, convention in
                    convention == .inout
                        ? compilerStorageIdentity(for: token) : nil
                }
            for index in inoutIdentities.indices {
                for other in inoutIdentities.indices where other > index {
                    let lhs = inoutIdentities[index]
                    let rhs = inoutIdentities[other]
                    guard lhs.root == rhs.root,
                          lhs.path.starts(with: rhs.path)
                            || rhs.path.starts(with: lhs.path)
                    else { continue }
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "direct call contains overlapping inout arguments"
                    )
                }
            }
            var arguments: [Bytecode.Register] = []
            var accesses: [Bytecode.Register] = []
            var temporaryOwners: [Bytecode.Register] = []
            var compilerInoutWritebacks: [
                PreparedDirectCallArguments.CompilerInoutWriteback
            ] = []
            arguments.reserveCapacity(tokens.count)
            for ((token, convention), logicalType) in zip(
                zip(tokens, physicalConventions),
                logicalTypes
            ) {
                let value: Bytecode.Register
                if case let .mutableCell(pointee) = logicalType {
                    guard let existing = mutableCell(at: token),
                          mutableCellPointee(at: token) == pointee
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "managed mutable argument is not backed by a matching cell"
                        )
                    }
                    value = existing
                    arguments.append(value)
                    continue
                }
                if convention == .inout,
                   runtimeAddress(at: token) == nil,
                   case let .address(pointee) = logicalType,
                   stackType(at: token) == pointee {
                    guard allowsCompilerInoutWriteback else {
                        throw CanonicalSIL.LoweringError
                            .unsupportedInstruction(
                                line: line,
                                text: "compiler-only inout writeback across try_apply"
                            )
                    }
                    let preservesAggregate = takenOptionalPayloadProjection(
                        at: token
                    )?.path.isEmpty == false
                    let initial = if preservesAggregate {
                        try copyStoredValue(at: token, line: line)
                    } else {
                        try takeStoredValue(at: token, line: line)
                    }
                    guard let initial,
                          registerTypes[Int(initial.rawValue)] == pointee
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "compiler-only inout argument is uninitialized"
                        )
                    }
                    let slot = try allocateStackSlot(type: pointee)
                    appendInstruction(
                        .storeStack(
                            slot: slot,
                            source: initial,
                            mode: .initialize
                        )
                    )
                    let address = try allocate(type: .address(pointee))
                    appendInstruction(.stackAddress(result: address, slot: slot))
                    let access = try allocate(type: .address(pointee))
                    appendInstruction(
                        .beginAccess(
                            result: access,
                            address: address,
                            kind: .modify
                        )
                    )
                    arguments.append(access)
                    accesses.append(access)
                    compilerInoutWritebacks.append(
                        .init(token: token, slot: slot, pointee: pointee)
                    )
                    continue
                }
                if convention == .inout {
                    value = try resolve(token, line: line)
                } else if stackType(at: token) == logicalType {
                    let consumes = storageInitializationPlan
                        .consumesApplicationArgument(
                            token,
                            at: currentSILLineIndex
                        )
                    let stored: Bytecode.Register?
                    if consumes {
                        stored = try takeStoredValue(at: token, line: line)
                    } else if convention == .borrowed,
                              logicalType.requiresLinearOwnership,
                              runtimeAddress(at: token) == nil {
                        stored = try resolvedStackValue(at: token, line: line)
                    } else {
                        stored = try copyStoredValue(at: token, line: line)
                        if convention == .borrowed,
                           logicalType.requiresLinearOwnership,
                           let stored {
                            temporaryOwners.append(stored)
                        }
                    }
                    guard let stored else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "address-backed call argument is uninitialized"
                        )
                    }
                    value = stored
                } else {
                    value = convention == .owned
                        ? try prepareOwnedValue(
                            token,
                            expectedType: logicalType,
                            line: line
                        )
                        : try resolveStorableValue(
                            token,
                            expectedType: logicalType,
                            line: line
                        )
                }
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
                let access = try allocate(type: .address(pointee))
                appendInstruction(
                    .beginAccess(result: access, address: value, kind: .modify)
                )
                arguments.append(access)
                accesses.append(access)
            }
            return .init(
                arguments: arguments,
                accesses: accesses,
                temporaryOwners: temporaryOwners,
                compilerInoutWritebacks: compilerInoutWritebacks
            )
        }

        func appendPreparedOwnerCleanups(
            _ prepared: PreparedDirectCallArguments
        ) {
            for owner in prepared.temporaryOwners {
                appendInstruction(.destroyValue(owner))
            }
        }

        func finishPreparedAccessesAndWritebacks(
            _ prepared: PreparedDirectCallArguments
        ) throws {
            for access in prepared.accesses.reversed() {
                appendInstruction(.endAccess(access))
            }
            for writeback in prepared.compilerInoutWritebacks {
                let value = try allocate(type: writeback.pointee)
                appendInstruction(
                    .loadStack(
                        result: value,
                        slot: writeback.slot,
                        mode: .take
                    )
                )
                try storeConstructedValue(value, at: writeback.token)
            }
        }

        func schedulePreparedContinuationCleanups(
            _ prepared: PreparedDirectCallArguments,
            in targets: [Bytecode.BlockID]
        ) throws {
            guard prepared.compilerInoutWritebacks.isEmpty else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "compiler-only inout writeback cannot cross call continuations"
                )
            }
            for target in targets {
                if !prepared.accesses.isEmpty {
                    guard implicitAccessCleanups[target] == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "one continuation closes multiple synthetic access sets"
                        )
                    }
                    implicitAccessCleanups[target] = Array(
                        prepared.accesses.reversed()
                    )
                }
                for owner in prepared.temporaryOwners {
                    guard !implicitOwnerCleanups[target, default: []]
                        .contains(owner)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "one borrowed call owner is cleaned twice on a successor"
                        )
                    }
                    implicitOwnerCleanups[target, default: []].append(owner)
                }
            }
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
                    return zip(
                        zip(physical, binding.parameterConventions),
                        binding.parameterTypes
                    ).allSatisfy { pair, type in
                        if case .mutableCell = type {
                            return pair.1 == .owned
                                && [.owned, .borrowed, .inout].contains(pair.0)
                        }
                        return pair.0 == pair.1
                    }
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
                indirectErrorType: callee.indirectErrorType,
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
                        ? try copyOwnedValue(argument)
                        : argument
                }
            }
        }

        func transferOwnedCompilerAddressArguments(
            tokens: [String],
            resolvedArguments: [Bytecode.Register],
            conventions: [Bytecode.ParameterConvention],
            forceOwnedTokens: Set<String> = []
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
                guard runtimeAddress(at: token) == nil,
                      mutableCell(at: token) == nil
                else { continue }
                let consumes = storageInitializationPlan
                    .consumesApplicationArgument(
                        token,
                        at: currentSILLineIndex
                    ) || forceOwnedTokens.contains(token)
                guard consumes else { continue }
                guard let stored = stackValue(at: token) else { continue }
                guard stored == argument else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "owned call argument does not match its compiler address storage"
                    )
                }

                // An `@in` SIL argument transfers the value stored at its
                // compiler-only address into the callee. HLBC passes that same
                // value directly, so the later dealloc_stack must not release
                // it a second time.
                removeCompilerAddressValue(at: token)
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
                        .init(address, merge)
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
            let originalType = registerTypes[Int(original.rawValue)]
            if originalType == expected { return original }
            if let cached = retypedIntegerOperands[token]?[expected] { return cached }
            if case let .integer(expectedWidth, _) = expected,
               case let .integer(actualWidth, _) = originalType,
               actualWidth == expectedWidth {
                // Swift's raw overflow builtins encode signedness at the use
                // site. Phi values therefore cannot rely on the declaration's
                // default literal signedness; preserving their bits is the
                // only representation-correct conversion.
                let result = try allocate(type: expected)
                appendInstruction(
                    .integerConvert(
                        result: result,
                        operation: .reinterpret,
                        value: original
                    )
                )
                retypedIntegerOperands[token, default: [:]][expected] = result
                return result
            }
            guard case let .integer(bitWidth, _) = expected,
                  let literal = integerLiterals[token],
                  literal.bitWidth == bitWidth
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "integer literal does not match its builtin signedness"
                )
            }
            let result = try allocate(type: expected)
            appendInstruction(
                .constantInteger(result: result, bitPattern: literal.bitPattern)
            )
            retypedIntegerOperands[token, default: [:]][expected] = result
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

        func normalizeBuiltinIntegerBranchArguments(
            _ arguments: inout [Bytecode.Register],
            target: Bytecode.BlockID
        ) throws {
            let expectedTypes: [Bytecode.ValueType]
            if let targetBlock = if current?.id == target {
                current
            } else {
                blocks.last(where: { $0.id == target })
            } {
                expectedTypes = targetBlock.parameters.map {
                    registerTypes[Int($0.rawValue)]
                }
            } else {
                expectedTypes = (declaredBlockParameterTypes[target] ?? [])
                    + (implicitStackValues[target] ?? []).map {
                        registerTypes[Int($0.register.rawValue)]
                    }
            }
            guard expectedTypes.count == arguments.count else { return }

            for index in arguments.indices {
                let source = arguments[index]
                let sourceType = registerTypes[Int(source.rawValue)]
                let destinationType = expectedTypes[index]
                guard sourceType != destinationType,
                      case let .integer(sourceWidth, _) = sourceType,
                      case let .integer(destinationWidth, _) = destinationType,
                      sourceWidth == destinationWidth
                else { continue }

                // SIL's Builtin.IntN spelling carries no signedness. HLBC
                // does, so phi edges preserve the raw bits while adopting the
                // target block's representation instead of rejecting a legal
                // signed/unsigned use-site interpretation.
                let normalized = try allocate(type: destinationType)
                appendInstruction(
                    .integerConvert(
                        result: normalized,
                        operation: .reinterpret,
                        value: source
                    )
                )
                arguments[index] = normalized
            }
        }

        func appendSyntheticBlock(
            id: Bytecode.BlockID,
            parameters: [Bytecode.Register] = [],
            instructions: [IntermediateRepresentation.Instruction]
        ) {
            blocks.append(
                .init(
                    id: id,
                    parameters: parameters,
                    instructions: instructions
                )
            )
            if let currentSourceLocation {
                for offset in instructions.indices {
                    guard let instructionOffset = UInt32(exactly: offset) else {
                        break
                    }
                    sourceMap.append(
                        .init(
                            blockID: id,
                            instructionOffset: instructionOffset,
                            location: currentSourceLocation
                        )
                    )
                }
            }
        }

        func appendConditionalTrap(
            condition: Bytecode.Register,
            reason: Bytecode.TrapReason
        ) throws {
            guard registerTypes[Int(condition.rawValue)] == .bool else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "conditional trap requires a Bool condition"
                )
            }
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
            appendSyntheticBlock(id: trapID, instructions: [.trap(reason)])
            current = IntermediateRepresentation.Block(
                id: continuationID,
                parameters: [],
                instructions: []
            )
        }

        /// A compiler-only enum case is statically known, but canonical SIL
        /// still contains every switch successor. Preserve those CFG edges so
        /// verifier reachability and phi validation continue to describe the
        /// complete source function while execution takes only the selected
        /// case.
        func appendStaticBranch(
            selected: Bytecode.BlockID,
            preserving targets: [Bytecode.BlockID]
        ) throws {
            var seen = Set<Bytecode.BlockID>()
            let alternatives = targets.filter {
                $0 != selected && seen.insert($0).inserted
            }
            guard !alternatives.isEmpty else {
                appendInstruction(.branch(target: selected, arguments: []))
                return
            }

            let syntheticBlocks = try alternatives.map { _ in
                try allocateSyntheticBlockID()
            }
            let selectKnownCase = try allocate(type: .bool)
            appendInstruction(
                .constantBool(result: selectKnownCase, value: true)
            )
            appendInstruction(
                .conditionalBranch(
                    condition: selectKnownCase,
                    trueTarget: selected,
                    trueArguments: [],
                    falseTarget: syntheticBlocks[0],
                    falseArguments: []
                )
            )
            finishCurrent()

            for index in alternatives.indices {
                let exposeAlternative = try allocate(type: .bool)
                let next = syntheticBlocks.indices.contains(index + 1)
                    ? syntheticBlocks[index + 1]
                    : selected
                appendSyntheticBlock(
                    id: syntheticBlocks[index],
                    instructions: [
                        .constantBool(
                            result: exposeAlternative,
                            value: false
                        ),
                        .conditionalBranch(
                            condition: exposeAlternative,
                            trueTarget: alternatives[index],
                            trueArguments: [],
                            falseTarget: next,
                            falseArguments: []
                        ),
                    ]
                )
            }
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
                if try typeEnvironment.isStaticallyZeroSized(
                    pending.elementType
                ) {
                    guard pending.elementComponents[index] == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "zero-sized Array literal element has component stores"
                        )
                    }
                    result.append(
                        try materializeZeroSizedValue(type: pending.elementType)
                    )
                    continue
                }
                guard case let .tuple(types) = pending.elementType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array literal element is incomplete"
                    )
                }
                let components = pending.elementComponents[index] ?? [:]
                var registers: [Bytecode.Register] = []
                registers.reserveCapacity(types.count)
                for index in types.indices {
                    if let component = components[index] {
                        registers.append(component)
                        continue
                    }
                    guard try typeEnvironment.isStaticallyZeroSized(
                        types[index]
                    ) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array literal tuple component is missing"
                        )
                    }
                    registers.append(
                        try materializeZeroSizedValue(type: types[index])
                    )
                }
                let tuple = try allocate(type: pending.elementType)
                appendInstruction(.makeTuple(result: tuple, elements: registers))
                result.append(tuple)
            }
            return result
        }

        func compilerAddressType(_ token: String) -> Bytecode.ValueType? {
            if token == indirectResultAddress { return signature.result }
            if token == indirectErrorAddress {
                return signature.indirectErrorType
            }
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

        func consumeIndirectCallDestinations(
            from argumentTokens: inout [String],
            resultType: Bytecode.ValueType,
            hasIndirectResult: Bool,
            indirectErrorType: Bytecode.ValueType?,
            physicalArgumentCount: Int
        ) throws -> IndirectCallDestinations {
            let hiddenCount = (hasIndirectResult ? 1 : 0)
                + (indirectErrorType == nil ? 0 : 1)
            let expectedCount = physicalArgumentCount.addingReportingOverflow(
                hiddenCount
            )
            guard !expectedCount.overflow,
                  argumentTokens.count == expectedCount.partialValue
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "call argument count does not match its physical result ABI"
                )
            }

            var resultDestination: String?
            if hasIndirectResult {
                guard resultType == .void || supportsIndirectResult(resultType) else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "indirect call result \(resultType)"
                    )
                }
                let destination = argumentTokens.removeFirst()
                let destinationType = compilerAddressType(destination)
                guard destinationType == resultType
                        || destinationType
                            == ValueRepresentation.storable(resultType)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "indirect call result address does not match its result type"
                    )
                }
                resultDestination = destination
            }

            var errorDestination: String?
            if let indirectErrorType {
                let destination = argumentTokens.removeFirst()
                guard compilerAddressType(destination) == indirectErrorType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "indirect call Error address does not match its error type"
                    )
                }
                errorDestination = destination
            }
            return .init(result: resultDestination, error: errorDestination)
        }

        func bindIndirectTryCallDestinations(
            _ destinations: IndirectCallDestinations,
            resultType: Bytecode.ValueType,
            indirectErrorType: Bytecode.ValueType?,
            normalTarget: Bytecode.BlockID,
            errorTarget: Bytecode.BlockID
        ) throws {
            if destinations.result != nil || resultType == .void {
                guard implicitStackValues[normalTarget] == nil,
                      suppressedVoidTryNormalBlocks.insert(normalTarget).inserted
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Void or indirect call normal continuation is shared"
                    )
                }
                if let destination = destinations.result,
                   resultType != .void {
                    let result = try allocate(type: resultType)
                    implicitStackValues[normalTarget] = [.init(destination, result)]
                }
            }

            if let destination = destinations.error {
                let runtimeErrorType: Bytecode.ValueType = typeEnvironment
                    .preservesTypedErrors ? .error : .string
                guard indirectErrorType == runtimeErrorType,
                      implicitStackValues[errorTarget] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "indirect call Error continuation does not match its image"
                    )
                }
                let error = try allocate(type: runtimeErrorType)
                implicitStackValues[errorTarget] = [.init(destination, error)]
            }
        }

        func materializeMutableCapture(
            at token: String,
            pointee: Bytecode.ValueType,
            line: Int
        ) throws -> Bytecode.Register {
            if let existing = mutableCell(at: token) {
                guard mutableCellPointee(at: token) == pointee else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: line,
                        mangledName: "mutable closure capture"
                    )
                }
                return existing
            }
            let root = addressBase(token)
            guard !inoutParameterAddressBases.contains(root) else {
                throw CanonicalSIL.LoweringError.unsupportedInstruction(
                    line: line,
                    text: "capturing an inout parameter requires caller writeback"
                )
            }
            guard token == root,
                  stackAddressTypes[root] == pointee
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "mutable closure capture must reference matching local storage"
                )
            }

            let initialValue: Bytecode.Register
            if let slot = runtimeStackSlots[root] {
                initialValue = try allocate(type: pointee)
                appendInstruction(
                    .loadStack(result: initialValue, slot: slot, mode: .take)
                )
            } else {
                guard runtimeAddress(at: root) == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "mutable closure capture references unsupported storage"
                    )
                }
                guard let value = try resolvedStackValue(
                    at: root,
                    line: line
                ) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "mutable closure capture references unsupported storage"
                    )
                }
                guard registerTypes[Int(value.rawValue)] == pointee else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "mutable closure capture storage has the wrong type"
                    )
                }
                initialValue = value
            }
            stackAddressValues.removeValue(forKey: root)
            removeTupleComponentValues(rootedAt: root)

            let cell = try allocate(type: .mutableCell(pointee))
            appendInstruction(
                .makeMutableCell(result: cell, initialValue: initialValue)
            )
            mutableCaptureState.addresses[root] = .init(
                register: cell,
                pointee: pointee
            )
            values[root] = cell
            return cell
        }

        func takenOptionalPayloadProjection(
            at token: String
        ) -> (root: String, path: [Int], state: TakenOptionalPayload)? {
            var current = token
            var reversedPath: [Int] = []
            var visited = Set<String>()
            while visited.insert(current).inserted {
                if let state = takenOptionalPayloads[current] {
                    return (
                        root: current,
                        path: Array(reversedPath.reversed()),
                        state: state
                    )
                }
                if let component = aggregateComponentAddresses[current] {
                    reversedPath.append(component.index)
                    current = component.base
                    continue
                }
                let canonical = addressBase(current)
                guard canonical != current else { return nil }
                current = canonical
            }
            return nil
        }

        /// Rebuilds only the aggregate spine containing a projected write.
        /// Sibling values are carried forward in declaration order, so this
        /// supports nested tuples and patch-local structs without a nominal- or
        /// API-specific setter table.
        func replacingAggregateProjection(
            in currentValue: Bytecode.Register,
            type: Bytecode.ValueType,
            path: ArraySlice<Int>,
            prefix: [Int] = [],
            with replacement: Bytecode.Register,
            updatedValues: inout [[Int]: Bytecode.Register]
        ) throws -> Bytecode.Register {
            guard registerTypes[Int(currentValue.rawValue)] == type else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "projected Optional writeback has a mismatched aggregate value"
                )
            }
            guard let fieldIndex = path.first else {
                guard registerTypes[Int(replacement.rawValue)] == type else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "projected Optional writeback has a mismatched replacement"
                    )
                }
                if currentValue != replacement, type.requiresLinearOwnership {
                    appendInstruction(.destroyValue(currentValue))
                }
                updatedValues[prefix] = replacement
                return replacement
            }

            let childTypes: [Bytecode.ValueType]
            let children: [Bytecode.Register]
            let rebuild: ([Bytecode.Register]) throws -> Bytecode.Register
            switch type {
            case let .tuple(types):
                guard types.indices.contains(fieldIndex) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "projected Optional tuple writeback is out of bounds"
                    )
                }
                childTypes = types
                children = try types.map { try allocate(type: $0) }
                appendInstruction(
                    .unpackTuple(results: children, tuple: currentValue)
                )
                rebuild = { fields in
                    let result = try allocate(type: type)
                    appendInstruction(
                        .makeTuple(result: result, elements: fields)
                    )
                    return result
                }
            case let .local(key):
                let fields = try typeEnvironment.structFields(for: key)
                guard fields.indices.contains(fieldIndex) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "projected Optional struct writeback is out of bounds"
                    )
                }
                childTypes = fields.map(\.type)
                children = try fields.indices.map { index in
                    guard let rawIndex = UInt32(exactly: index) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "projected Optional struct field exceeds UInt32"
                        )
                    }
                    let child = try allocate(type: fields[index].type)
                    appendInstruction(
                        .structExtract(
                            result: child,
                            structure: currentValue,
                            fieldIndex: rawIndex
                        )
                    )
                    return child
                }
                rebuild = { fields in
                    let result = try allocate(type: type)
                    appendInstruction(
                        .makeStruct(result: result, fields: fields)
                    )
                    return result
                }
            default:
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "projected Optional writeback requires a represented aggregate"
                )
            }

            var rebuiltChildren = children
            rebuiltChildren[fieldIndex] = try replacingAggregateProjection(
                in: children[fieldIndex],
                type: childTypes[fieldIndex],
                path: path.dropFirst(),
                prefix: prefix + [fieldIndex],
                with: replacement,
                updatedValues: &updatedValues
            )
            for index in rebuiltChildren.indices {
                updatedValues[prefix + [index]] = rebuiltChildren[index]
            }
            let rebuilt = try rebuild(rebuiltChildren)
            updatedValues[prefix] = rebuilt
            return rebuilt
        }

        func storeConstructedValue(
            _ value: Bytecode.Register,
            at token: String,
            mode: Bytecode.StackStoreMode? = nil
        ) throws {
            let type = registerTypes[Int(value.rawValue)]
            guard compilerAddressType(token) == type else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "constructed value does not match its SIL address"
                )
            }
            if let cell = mutableCell(at: token) {
                let storeMode = mode
                    ?? storageInitializationPlan.storeMode(
                        at: currentSILLineIndex,
                        address: token
                    )
                appendInstruction(
                    .storeMutableCell(
                        cell: cell,
                        source: value,
                        mode: storeMode
                    )
                )
                return
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
            if var projection = takenOptionalPayloadProjection(at: token) {
                guard case let .optional(wrapped) = compilerAddressType(
                    projection.state.address
                ),
                      compilerAddressType(projection.root) == wrapped
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "taken Optional payload no longer matches its source storage"
                    )
                }
                var updatedValues: [[Int]: Bytecode.Register] = [:]
                let payload: Bytecode.Register
                if projection.path.isEmpty {
                    if let currentValue = stackValue(at: projection.root) {
                        payload = try replacingAggregateProjection(
                            in: currentValue,
                            type: wrapped,
                            path: projection.path[...],
                            with: value,
                            updatedValues: &updatedValues
                        )
                    } else {
                        payload = value
                        updatedValues[[]] = value
                    }
                } else {
                    guard let currentValue = stackValue(at: projection.root) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "projected Optional writeback lost its payload value"
                        )
                    }
                    payload = try replacingAggregateProjection(
                        in: currentValue,
                        type: wrapped,
                        path: projection.path[...],
                        with: value,
                        updatedValues: &updatedValues
                    )
                }
                recordCompilerAddressValue(payload, at: projection.root)
                for candidate in aggregateComponentAddresses.keys {
                    guard let candidateProjection = takenOptionalPayloadProjection(
                        at: candidate
                    ), candidateProjection.root == projection.root,
                       let updated = updatedValues[candidateProjection.path]
                    else { continue }
                    if let key = tupleComponentStorageKey(for: candidate) {
                        tupleComponentValues[key] = updated
                    } else {
                        stackAddressValues[addressBase(candidate)] = updated
                    }
                }
                let optional = try allocate(type: .optional(wrapped))
                appendInstruction(.makeOptionalSome(result: optional, value: payload))
                try storeVMValue(
                    optional,
                    at: projection.state.address,
                    requestedMode: projection.state.requiresInitialization
                        ? .initialize : mode
                )
                if let blockID = current?.id {
                    setKnownSomeOptionalAddress(
                        projection.state.address,
                        in: blockID,
                        isKnownSome: true
                    )
                }
                projection.state.requiresInitialization = false
                takenOptionalPayloads[projection.root] = projection.state
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
            try storeVMValue(value, at: token, requestedMode: mode)
        }

        func materializeErrorValue(
            from token: String
        ) throws -> Bytecode.Register? {
            if let value = values[token],
               [.string, .error].contains(
                   registerTypes[Int(value.rawValue)]
               ) {
                return value
            }
            guard let message = errorMessageByBox[token] else { return nil }
            let value = try allocate(type: .string)
            appendInstruction(
                .constantString(result: value, value: message)
            )
            return value
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
                physicalConventions: valueConventions,
                logicalTypes: Array(binding.parameterTypes.dropLast()),
                line: line,
                allowsCompilerInoutWriteback: true
            )
            var arguments = try zip(prepared.arguments, valueConventions).map {
                argument, convention in
                convention == .borrowed
                    ? try copyOwnedValue(argument)
                    : argument
            }
            let receiver: Bytecode.Register
            let transfersCompilerStorage: Bool
            let detachedProjection = takenOptionalPayloadProjection(
                at: receiverToken
            )
            if runtimeAddress(at: receiverToken) != nil
                || mutableCell(at: receiverToken) != nil
                || detachedProjection?.path.isEmpty == false {
                guard let copied = try copyStoredValue(
                    at: receiverToken,
                    line: line
                ) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "mutating value receiver references uninitialized storage"
                    )
                }
                receiver = copied
                transfersCompilerStorage = false
            } else if let taken = try takeStoredValue(
                at: receiverToken,
                line: line
            ) {
                receiver = taken
                transfersCompilerStorage = true
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
            // The adapter consumes a value snapshot and returns its mutated
            // replacement. A direct compiler-only value can transfer its
            // owner. Runtime storage and a detached aggregate projection keep
            // the enclosing value until the replacement is assigned or its
            // aggregate spine is rebuilt.
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
            if transfersCompilerStorage {
                try transferOwnedCompilerAddressArguments(
                    tokens: [receiverToken],
                    resolvedArguments: [receiver],
                    conventions: [.owned],
                    forceOwnedTokens: [receiverToken]
                )
            }
            appendPreparedOwnerCleanups(prepared)
            try storeConstructedValue(mutated, at: receiverToken)
            try finishPreparedAccessesAndWritebacks(prepared)
            voidValues.insert(resultToken)
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

        func lowerNaturalArrayOrdering(
            _ operation: CanonicalSIL.OrderingIntrinsic,
            resultToken: String,
            genericArguments: String,
            arguments: [String],
            line: Int
        ) throws {
            guard !operation.usesClosure,
                  arguments.count == 1
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "natural Array ordering has unsupported arguments"
                )
            }
            let genericSpellings = splitTopLevel(genericArguments)
                .filter { !$0.isEmpty }
            let genericTypes = try genericSpellings.map(parseType)
            guard genericTypes.count == 1,
                  case let .array(element) = genericTypes[0],
                  element.isVMComparable
            else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "natural ordering requires an Array with VM-defined Comparable semantics"
                )
            }
            let arrayType = Bytecode.ValueType.array(element)
            if operation.mutatesSource {
                guard compilerAddressType(arguments[0]) == arrayType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "MutableCollection.sort() requires matching inout storage"
                    )
                }
                switch typeEnvironment.collectionIndexModel(
                    for: genericSpellings[0]
                ) {
                case .zeroBasedInteger:
                    break
                case .preservedBaseInteger, .opaque:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "mutating natural ordering requires zero-based Array indices"
                    )
                }
            }

            let borrowedSource = try borrowStoredValue(
                at: arguments[0],
                line: line
            )
            let source = try borrowedSource?.register
                ?? resolve(arguments[0], line: line)
            guard registerTypes[Int(source.rawValue)] == arrayType else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "natural ordering source does not match its specialization"
                )
            }
            let result = try allocate(type: arrayType)
            appendInstruction(.arraySorted(result: result, array: source))
            if let owner = borrowedSource?.temporaryOwner {
                appendInstruction(.destroyValue(owner))
            }

            switch operation {
            case .sorted:
                values[resultToken] = result
            case .sort:
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .assign
                )
                voidValues.insert(resultToken)
            case .sortedBy, .sortBy, .partition:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "closure ordering reached natural ordering lowering"
                )
            }
        }

        func lowerSeparatorArraySplit(
            resultToken: String,
            genericArguments: String,
            argumentText: String,
            line: Int
        ) throws {
            let plan = try parseArraySplitPlan(
                operation: .separator,
                genericArguments: genericArguments,
                argumentText: argumentText,
                line: line
            )
            guard plan.elementType.isVMEquatable else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "split(separator:) requires VM-defined Equatable semantics"
                )
            }
            let arrayType = Bytecode.ValueType.array(plan.elementType)
            let borrowedSource = try borrowStoredValue(
                at: plan.sourceToken,
                line: line
            )
            let source = try borrowedSource?.register
                ?? resolve(plan.sourceToken, line: line)
            let borrowedSeparator = try borrowStoredValue(
                at: plan.decisionToken,
                line: line
            )
            let separator = try borrowedSeparator?.register
                ?? resolve(plan.decisionToken, line: line)
            let maximumSplits = try resolve(
                plan.maximumSplitsToken,
                line: line
            )
            let omittingEmptySubsequences = try resolve(
                plan.omittingEmptySubsequencesToken,
                line: line
            )
            guard registerTypes[Int(source.rawValue)] == arrayType,
                  registerTypes[Int(separator.rawValue)] == plan.elementType,
                  registerTypes[Int(maximumSplits.rawValue)] == .int64,
                  registerTypes[Int(omittingEmptySubsequences.rawValue)] == .bool
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "split(separator:) arguments do not match its specialization"
                )
            }
            let result = try allocate(type: .array(arrayType))
            appendInstruction(
                .arraySplitSeparator(
                    result: result,
                    array: source,
                    separator: separator,
                    maxSplits: maximumSplits,
                    omittingEmptySubsequences: omittingEmptySubsequences
                )
            )
            for owner in [
                borrowedSeparator?.temporaryOwner,
                borrowedSource?.temporaryOwner,
            ].compactMap({ $0 }) {
                appendInstruction(.destroyValue(owner))
            }
            values[resultToken] = result
        }

        func resolveArrayOrderingClosure(
            for plan: ArrayOrderingPlan,
            line: Int
        ) throws -> (Bytecode.Register, Bytecode.ClosureSignature) {
            let closure = try resolve(plan.closureToken, line: line)
            let expectedParameters = Array(
                repeating: plan.elementType,
                count: plan.operation == .partition ? 1 : 2
            )
            guard case let .closure(signature) = registerTypes[
                Int(closure.rawValue)
            ], signature.parameters == expectedParameters,
               signature.parameterConventions.count == expectedParameters.count,
               !signature.parameterConventions.contains(.inout),
               signature.result == .bool,
               signature.effects.mayThrow,
               !signature.effects.isAsync
            else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "<Array ordering closure>"
                )
            }
            return (closure, signature)
        }

        func prepareArrayOrderingContinuations(
            plan: ArrayOrderingPlan,
            normalTarget: Bytecode.BlockID
        ) throws {
            switch plan.operation {
            case .sortedBy:
                break
            case .sortBy:
                let arrayType = Bytecode.ValueType.array(plan.elementType)
                guard compilerAddressType(plan.sourceToken) == arrayType,
                      implicitStackValues[normalTarget] == nil,
                      suppressedVoidTryNormalBlocks.insert(normalTarget).inserted
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "sort(by:) requires one mutable Array continuation"
                    )
                }
                let propagatedArray = try allocate(type: arrayType)
                implicitStackValues[normalTarget] = [
                    .init(
                        plan.sourceToken,
                        propagatedArray,
                        storeMode: .assign
                    ),
                ]
            case .partition:
                let arrayType = Bytecode.ValueType.array(plan.elementType)
                guard let destination = plan.resultDestination,
                      compilerAddressType(destination) == .int64,
                      compilerAddressType(plan.sourceToken) == arrayType,
                      implicitStackValues[normalTarget] == nil,
                      suppressedVoidTryNormalBlocks.insert(normalTarget).inserted
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "partition(by:) requires an out Index and mutable Array"
                    )
                }
                let propagatedIndex = try allocate(type: .int64)
                let propagatedArray = try allocate(type: arrayType)
                implicitStackValues[normalTarget] = [
                    .init(destination, propagatedIndex),
                    .init(
                        plan.sourceToken,
                        propagatedArray,
                        storeMode: .assign
                    ),
                ]
            case .sorted, .sort:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "natural ordering reached try_apply continuation setup"
                )
            }
        }

        /// Comparator evaluation remains ordinary closure control flow while
        /// the VM owns a bounded stable merge-sort state machine. This keeps
        /// captures, throwing callbacks, call depth, and linear values on the
        /// same paths as every other higher-order operation.
        func lowerArrayComparatorSortTryApply(
            plan: ArrayOrderingPlan,
            normalTarget: Bytecode.BlockID,
            errorTarget: Bytecode.BlockID,
            line: Int
        ) throws {
            guard plan.operation == .sortedBy || plan.operation == .sortBy
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "comparator sort received a different ordering operation"
                )
            }
            let arrayType = Bytecode.ValueType.array(plan.elementType)
            let borrowedSource = try borrowStoredValue(
                at: plan.sourceToken,
                line: line
            )
            let source = try borrowedSource?.register
                ?? resolve(plan.sourceToken, line: line)
            guard registerTypes[Int(source.rawValue)] == arrayType else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "sort source does not match its Array specialization"
                )
            }
            let (closure, closureSignature) = try resolveArrayOrderingClosure(
                for: plan,
                line: line
            )
            try prepareArrayOrderingContinuations(
                plan: plan,
                normalTarget: normalTarget
            )

            let errorType: Bytecode.ValueType = typeEnvironment
                .preservesTypedErrors ? .error : .string
            let errorParameter = try allocate(type: errorType)
            let stateType = Bytecode.ValueType.arrayState(
                kind: .stableSort,
                element: plan.elementType
            )
            let state = try allocate(type: stateType)
            let comparisonType = Bytecode.ValueType.tuple([
                plan.elementType,
                plan.elementType,
            ])
            let nextType = Bytecode.ValueType.optional(comparisonType)
            let next = try allocate(type: nextType)
            let comparison = try allocate(type: comparisonType)
            let right = try allocate(type: plan.elementType)
            let left = try allocate(type: plan.elementType)
            let predicate = try allocate(type: .bool)
            let sorted = try allocate(type: arrayType)
            let loop = try allocateSyntheticBlockID()
            let compare = try allocateSyntheticBlockID()
            let accepted = try allocateSyntheticBlockID()
            let complete = try allocateSyntheticBlockID()
            let failed = try allocateSyntheticBlockID()

            appendInstruction(
                .makeArraySortState(result: state, array: source)
            )
            if let owner = borrowedSource?.temporaryOwner {
                appendInstruction(.destroyValue(owner))
            }
            appendInstruction(.branch(target: loop, arguments: []))
            finishCurrent()

            appendSyntheticBlock(
                id: loop,
                instructions: [
                    .arraySortNextComparison(result: next, state: state),
                    .switchOptional(
                        optional: next,
                        someTarget: compare,
                        noneTarget: complete
                    ),
                ]
            )
            appendSyntheticBlock(
                id: compare,
                parameters: [comparison],
                instructions: [
                    .unpackTuple(
                        results: [right, left],
                        tuple: comparison
                    ),
                    .closureTryApply(
                        closure: closure,
                        arguments: [right, left],
                        normalTarget: accepted,
                        errorTarget: failed
                    ),
                ]
            )

            let borrowedComparisonCleanup = zip(
                [right, left],
                closureSignature.parameterConventions
            ).compactMap { register, convention in
                plan.elementType.requiresLinearOwnership
                    && convention == .borrowed
                    ? IntermediateRepresentation.Instruction
                        .destroyValue(register)
                    : nil
            }
            appendSyntheticBlock(
                id: accepted,
                parameters: [predicate],
                instructions: borrowedComparisonCleanup + [
                    .arraySortAcceptComparison(
                        state: state,
                        rightPrecedesLeft: predicate
                    ),
                    .branch(target: loop, arguments: []),
                ]
            )

            appendSyntheticBlock(
                id: complete,
                instructions: [
                    .finishArraySort(result: sorted, state: state),
                    .branch(
                        target: normalTarget,
                        arguments: [sorted]
                    ),
                ]
            )
            appendSyntheticBlock(
                id: failed,
                parameters: [errorParameter],
                instructions: borrowedComparisonCleanup + [
                    .destroyValue(state),
                    .branch(
                        target: errorTarget,
                        arguments: [errorParameter]
                    ),
                ]
            )
        }

        /// A stable two-builder partition gives deterministic output while
        /// preserving Swift's documented false-before-true postcondition. The
        /// original inout value is replaced only after the predicate finishes,
        /// so a thrown callback cannot expose half-written VM storage.
        func lowerArrayPartitionTryApply(
            plan: ArrayOrderingPlan,
            normalTarget: Bytecode.BlockID,
            errorTarget: Bytecode.BlockID,
            line: Int
        ) throws {
            guard plan.operation == .partition else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "partition lowering received a different operation"
                )
            }
            let arrayType = Bytecode.ValueType.array(plan.elementType)
            let borrowedSource = try borrowStoredValue(
                at: plan.sourceToken,
                line: line
            )
            let source = try borrowedSource?.register
                ?? resolve(plan.sourceToken, line: line)
            guard registerTypes[Int(source.rawValue)] == arrayType else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "partition source does not match its Array specialization"
                )
            }
            let (closure, closureSignature) = try resolveArrayOrderingClosure(
                for: plan,
                line: line
            )
            try prepareArrayOrderingContinuations(
                plan: plan,
                normalTarget: normalTarget
            )

            let errorType: Bytecode.ValueType = typeEnvironment
                .preservesTypedErrors ? .error : .string
            let errorParameter = try allocate(type: errorType)
            let builderType = Bytecode.ValueType.arrayState(
                kind: .builder,
                element: plan.elementType
            )
            let falseBuilder = try allocate(type: builderType)
            let trueBuilder = try allocate(type: builderType)
            let indexSlot = try allocateStackSlot(type: .int64)
            let falseCountSlot = try allocateStackSlot(type: .int64)
            let zeroIndex = try allocate(type: .int64)
            let zeroCount = try allocate(type: .int64)
            let loop = try allocateSyntheticBlockID()
            let some = try allocateSyntheticBlockID()
            let closureContinuation = try allocateSyntheticBlockID()
            let appendFalse = try allocateSyntheticBlockID()
            let appendFalseChecked = try allocateSyntheticBlockID()
            let appendTrue = try allocateSyntheticBlockID()
            let complete = try allocateSyntheticBlockID()
            let overflowTrap = try allocateSyntheticBlockID()
            let failed = try allocateSyntheticBlockID()
            let next = try allocate(type: .optional(plan.elementType))
            let element = try allocate(type: plan.elementType)
            let predicate = try allocate(type: .bool)
            let currentCount = try allocate(type: .int64)
            let one = try allocate(type: .int64)
            let advancedCount = try allocate(type: .int64)
            let overflow = try allocate(type: .bool)
            let trueArray = try allocate(type: arrayType)
            let partitioned = try allocate(type: arrayType)
            let partitionIndex = try allocate(type: .int64)

            let inputConvention = closureSignature.parameterConventions[0]
            let closureInput: Bytecode.Register
            var closurePreparation: [IntermediateRepresentation.Instruction] = []
            if plan.elementType.requiresLinearOwnership,
               inputConvention == .owned {
                let copy = try allocate(type: plan.elementType)
                closurePreparation.append(
                    .copyValue(result: copy, source: element)
                )
                closureInput = copy
            } else {
                closureInput = element
            }
            let elementCleanup: [IntermediateRepresentation.Instruction] =
                plan.elementType.requiresLinearOwnership
                    ? [.destroyValue(element)] : []
            let sourceCleanup: [IntermediateRepresentation.Instruction] =
                borrowedSource?.temporaryOwner.map {
                    [.destroyValue($0)]
                } ?? []

            appendInstruction(.makeArrayBuilder(result: falseBuilder))
            appendInstruction(.makeArrayBuilder(result: trueBuilder))
            appendInstruction(
                .constantInteger(result: zeroIndex, bitPattern: 0)
            )
            appendInstruction(
                .storeStack(
                    slot: indexSlot,
                    source: zeroIndex,
                    mode: .initialize
                )
            )
            appendInstruction(
                .constantInteger(result: zeroCount, bitPattern: 0)
            )
            appendInstruction(
                .storeStack(
                    slot: falseCountSlot,
                    source: zeroCount,
                    mode: .initialize
                )
            )
            appendInstruction(.branch(target: loop, arguments: []))
            finishCurrent()

            appendSyntheticBlock(
                id: loop,
                instructions: [
                    .collectionNext(
                        result: next,
                        collection: source,
                        indexSlot: indexSlot,
                        direction: .forward
                    ),
                    .switchOptional(
                        optional: next,
                        someTarget: some,
                        noneTarget: complete
                    ),
                ]
            )
            appendSyntheticBlock(
                id: some,
                parameters: [element],
                instructions: closurePreparation + [
                    .closureTryApply(
                        closure: closure,
                        arguments: [closureInput],
                        normalTarget: closureContinuation,
                        errorTarget: failed
                    ),
                ]
            )
            appendSyntheticBlock(
                id: closureContinuation,
                parameters: [predicate],
                instructions: [
                    .conditionalBranch(
                        condition: predicate,
                        trueTarget: appendTrue,
                        trueArguments: [],
                        falseTarget: appendFalse,
                        falseArguments: []
                    ),
                ]
            )
            appendSyntheticBlock(
                id: appendFalse,
                instructions: [
                    .loadStack(
                        result: currentCount,
                        slot: falseCountSlot,
                        mode: .copy
                    ),
                    .constantInteger(result: one, bitPattern: 1),
                    .checkedBinary(
                        result: advancedCount,
                        overflow: overflow,
                        operation: .add,
                        lhs: currentCount,
                        rhs: one
                    ),
                    .conditionalBranch(
                        condition: overflow,
                        trueTarget: overflowTrap,
                        trueArguments: [],
                        falseTarget: appendFalseChecked,
                        falseArguments: []
                    ),
                ]
            )
            appendSyntheticBlock(
                id: appendFalseChecked,
                instructions: [
                    .storeStack(
                        slot: falseCountSlot,
                        source: advancedCount,
                        mode: .assign
                    ),
                    .arrayBuilderAppend(
                        builder: falseBuilder,
                        value: element
                    ),
                ] + elementCleanup + [
                    .branch(target: loop, arguments: []),
                ]
            )
            appendSyntheticBlock(
                id: appendTrue,
                instructions: [
                    .arrayBuilderAppend(
                        builder: trueBuilder,
                        value: element
                    ),
                ] + elementCleanup + [
                    .branch(target: loop, arguments: []),
                ]
            )

            var completionInstructions: [IntermediateRepresentation.Instruction] = [
                .finishArrayBuilder(
                    result: trueArray,
                    builder: trueBuilder
                ),
                .arrayBuilderAppendContents(
                    builder: falseBuilder,
                    array: trueArray
                ),
            ]
            if arrayType.requiresLinearOwnership {
                completionInstructions.append(.destroyValue(trueArray))
            }
            completionInstructions.append(contentsOf: [
                .finishArrayBuilder(
                    result: partitioned,
                    builder: falseBuilder
                ),
                .loadStack(
                    result: partitionIndex,
                    slot: falseCountSlot,
                    mode: .take
                ),
                .destroyStack(indexSlot),
            ])
            completionInstructions.append(contentsOf: sourceCleanup)
            completionInstructions.append(
                .branch(
                    target: normalTarget,
                    arguments: [partitionIndex, partitioned]
                )
            )
            appendSyntheticBlock(
                id: complete,
                instructions: completionInstructions
            )
            appendSyntheticBlock(
                id: overflowTrap,
                instructions: [.trap(.integerOverflow)]
            )
            appendSyntheticBlock(
                id: failed,
                parameters: [errorParameter],
                instructions: elementCleanup + [
                    .destroyValue(falseBuilder),
                    .destroyValue(trueBuilder),
                    .destroyStack(indexSlot),
                    .destroyStack(falseCountSlot),
                ] + sourceCleanup + [
                    .branch(
                        target: errorTarget,
                        arguments: [errorParameter]
                    ),
                ]
            )
        }

        func lowerArrayOrderingTryApply(
            operation: CanonicalSIL.OrderingIntrinsic,
            genericArguments: String,
            argumentText: String,
            normalTarget: Bytecode.BlockID,
            errorTarget: Bytecode.BlockID,
            line: Int
        ) throws {
            let plan = try parseArrayOrderingPlan(
                operation: operation,
                genericArguments: genericArguments,
                argumentText: argumentText,
                line: line
            )
            switch operation {
            case .sortedBy, .sortBy:
                try lowerArrayComparatorSortTryApply(
                    plan: plan,
                    normalTarget: normalTarget,
                    errorTarget: errorTarget,
                    line: line
                )
            case .partition:
                try lowerArrayPartitionTryApply(
                    plan: plan,
                    normalTarget: normalTarget,
                    errorTarget: errorTarget,
                    line: line
                )
            case .sorted, .sort:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "natural ordering unexpectedly used try_apply"
                )
            }
        }

        func lowerArraySplitTryApply(
            genericArguments: String,
            argumentText: String,
            normalTarget: Bytecode.BlockID,
            errorTarget: Bytecode.BlockID,
            line: Int
        ) throws {
            let plan = try parseArraySplitPlan(
                operation: .predicate,
                genericArguments: genericArguments,
                argumentText: argumentText,
                line: line
            )
            let arrayType = Bytecode.ValueType.array(plan.elementType)
            let borrowedSource = try borrowStoredValue(
                at: plan.sourceToken,
                line: line
            )
            let source = try borrowedSource?.register
                ?? resolve(plan.sourceToken, line: line)
            let maximumSplits = try resolve(
                plan.maximumSplitsToken,
                line: line
            )
            let omittingEmptySubsequences = try resolve(
                plan.omittingEmptySubsequencesToken,
                line: line
            )
            let closure = try resolve(plan.decisionToken, line: line)
            guard registerTypes[Int(source.rawValue)] == arrayType,
                  registerTypes[Int(maximumSplits.rawValue)] == .int64,
                  registerTypes[Int(omittingEmptySubsequences.rawValue)] == .bool,
                  case let .closure(signature) = registerTypes[
                    Int(closure.rawValue)
                  ], signature.parameters == [plan.elementType],
                  signature.parameterConventions.count == 1,
                  signature.parameterConventions[0] != .inout,
                  signature.result == .bool,
                  signature.effects.mayThrow,
                  !signature.effects.isAsync
            else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "<Array split predicate>"
                )
            }

            let errorType: Bytecode.ValueType = typeEnvironment
                .preservesTypedErrors ? .error : .string
            let error = try allocate(type: errorType)
            let state = try allocate(
                type: .arrayState(kind: .split, element: plan.elementType)
            )
            let next = try allocate(type: .optional(plan.elementType))
            let element = try allocate(type: plan.elementType)
            let isSeparator = try allocate(type: .bool)
            let result = try allocate(type: .array(arrayType))
            let loop = try allocateSyntheticBlockID()
            let evaluate = try allocateSyntheticBlockID()
            let accepted = try allocateSyntheticBlockID()
            let complete = try allocateSyntheticBlockID()
            let failed = try allocateSyntheticBlockID()

            appendInstruction(
                .makeArraySplitState(
                    result: state,
                    array: source,
                    maxSplits: maximumSplits,
                    omittingEmptySubsequences: omittingEmptySubsequences
                )
            )
            if let owner = borrowedSource?.temporaryOwner {
                appendInstruction(.destroyValue(owner))
            }
            appendInstruction(.branch(target: loop, arguments: []))
            finishCurrent()

            appendSyntheticBlock(
                id: loop,
                instructions: [
                    .arraySplitNextElement(result: next, state: state),
                    .switchOptional(
                        optional: next,
                        someTarget: evaluate,
                        noneTarget: complete
                    ),
                ]
            )
            appendSyntheticBlock(
                id: evaluate,
                parameters: [element],
                instructions: [
                    .closureTryApply(
                        closure: closure,
                        arguments: [element],
                        normalTarget: accepted,
                        errorTarget: failed
                    ),
                ]
            )
            let borrowedElementCleanup: [IntermediateRepresentation.Instruction]
            if plan.elementType.requiresLinearOwnership,
               signature.parameterConventions[0] == .borrowed {
                borrowedElementCleanup = [.destroyValue(element)]
            } else {
                borrowedElementCleanup = []
            }
            appendSyntheticBlock(
                id: accepted,
                parameters: [isSeparator],
                instructions: borrowedElementCleanup + [
                    .arraySplitAcceptElement(
                        state: state,
                        isSeparator: isSeparator
                    ),
                    .branch(target: loop, arguments: []),
                ]
            )
            appendSyntheticBlock(
                id: complete,
                instructions: [
                    .finishArraySplit(result: result, state: state),
                    .branch(target: normalTarget, arguments: [result]),
                ]
            )
            appendSyntheticBlock(
                id: failed,
                parameters: [error],
                instructions: borrowedElementCleanup + [
                    .destroyValue(state),
                    .branch(target: errorTarget, arguments: [error]),
                ]
            )
        }

        /// `Sequence.reduce(into:_:)` is the standard-library operation whose
        /// callback receives caller-owned mutable storage. Keep that storage
        /// in one frame slot and pass a scoped address into each invocation;
        /// this models Swift's inout exclusivity without copying the
        /// accumulator or teaching the VM about a particular accumulator type.
        func lowerCollectionReduceIntoTryApply(
            plan: CollectionHigherOrderPlan,
            normalTarget: Bytecode.BlockID,
            errorTarget: Bytecode.BlockID,
            line: Int
        ) throws {
            guard plan.operation == .reduceInto,
                  let initialToken = plan.initialToken,
                  let resultDestination = plan.resultDestination
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "reduce(into:_:) has an incomplete lowering plan"
                )
            }

            let borrowedSource = try borrowStoredValue(
                at: plan.sourceToken,
                line: line
            )
            let source = try borrowedSource?.register
                ?? resolve(plan.sourceToken, line: line)
            guard registerTypes[Int(source.rawValue)] == plan.sourceType
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "reduce(into:_:) source does not match its Collection specialization"
                )
            }

            let closure = try resolve(plan.closureToken, line: line)
            let accumulatorAddressType = Bytecode.ValueType.address(
                plan.callResultType
            )
            guard case let .closure(closureSignature) = registerTypes[
                Int(closure.rawValue)
            ], closureSignature.parameters == [
                accumulatorAddressType,
                plan.inputType,
            ], closureSignature.parameterConventions.count == 2,
               closureSignature.parameterConventions[0] == .inout,
               closureSignature.parameterConventions[1] != .inout,
               closureSignature.result == .void,
               closureSignature.effects.mayThrow,
               !closureSignature.effects.isAsync
            else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "<reduce(into:) closure>"
                )
            }
            let elementConvention = closureSignature.parameterConventions[1]
            if plan.inputType.requiresLinearOwnership,
               elementConvention != .borrowed {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "<reduce(into:) borrowed element>"
                )
            }

            guard compilerAddressType(resultDestination)
                    == plan.callResultType,
                  implicitStackValues[normalTarget] == nil,
                  suppressedVoidTryNormalBlocks.insert(normalTarget).inserted
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "reduce(into:_:) indirect result destination is invalid"
                )
            }
            let propagatedResult = try allocate(type: plan.callResultType)
            implicitStackValues[normalTarget] = [
                .init(resultDestination, propagatedResult),
            ]

            let errorValueType: Bytecode.ValueType = typeEnvironment
                .preservesTypedErrors ? .error : .string
            let errorParameter = try allocate(type: errorValueType)
            if let errorDestination = plan.errorDestination {
                guard compilerAddressType(errorDestination) == errorValueType,
                      implicitStackValues[errorTarget] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "reduce(into:_:) indirect Error destination is invalid"
                    )
                }
                let propagatedError = try allocate(type: errorValueType)
                implicitStackValues[errorTarget] = [
                    .init(errorDestination, propagatedError),
                ]
            }

            let initialAccumulator: Bytecode.Register
            if stackType(at: initialToken) != nil {
                guard let taken = try takeStoredValue(
                    at: initialToken,
                    line: line
                ) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "reduce(into:_:) initial accumulator is uninitialized"
                    )
                }
                initialAccumulator = taken
            } else {
                initialAccumulator = try materializeOwnedValue(
                    at: initialToken,
                    line: line
                )
            }
            guard registerTypes[Int(initialAccumulator.rawValue)]
                    == plan.callResultType
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "reduce(into:_:) initial accumulator has the wrong type"
                )
            }

            let accumulatorSlot = try allocateStackSlot(
                type: plan.callResultType
            )
            appendInstruction(
                .storeStack(
                    slot: accumulatorSlot,
                    source: initialAccumulator,
                    mode: .initialize
                )
            )
            let accumulatorAddress = try allocate(
                type: accumulatorAddressType
            )
            appendInstruction(
                .stackAddress(
                    result: accumulatorAddress,
                    slot: accumulatorSlot
                )
            )

            let indexSlot = try allocateStackSlot(type: .int64)
            let initialIndex = try allocate(type: .int64)
            appendInstruction(
                .constantInteger(result: initialIndex, bitPattern: 0)
            )
            appendInstruction(
                .storeStack(
                    slot: indexSlot,
                    source: initialIndex,
                    mode: .initialize
                )
            )

            let loop = try allocateSyntheticBlockID()
            let some = try allocateSyntheticBlockID()
            let empty = try allocateSyntheticBlockID()
            let closureContinuation = try allocateSyntheticBlockID()
            let closureError = try allocateSyntheticBlockID()
            let next = try allocate(type: .optional(plan.inputType))
            let element = try allocate(type: plan.inputType)
            let accumulatorAccess = try allocate(
                type: accumulatorAddressType
            )
            let finalAccumulator = try allocate(type: plan.callResultType)
            let sourceCleanup: [IntermediateRepresentation.Instruction] =
                borrowedSource?.temporaryOwner.map {
                    [.destroyValue($0)]
                } ?? []
            let elementCleanup: [IntermediateRepresentation.Instruction] =
                plan.inputType.requiresLinearOwnership
                    ? [.destroyValue(element)] : []

            appendInstruction(.branch(target: loop, arguments: []))
            finishCurrent()

            appendSyntheticBlock(
                id: loop,
                instructions: [
                    .collectionNext(
                        result: next,
                        collection: source,
                        indexSlot: indexSlot,
                        direction: .forward
                    ),
                    .switchOptional(
                        optional: next,
                        someTarget: some,
                        noneTarget: empty
                    ),
                ]
            )
            appendSyntheticBlock(
                id: some,
                parameters: [element],
                instructions: [
                    .beginAccess(
                        result: accumulatorAccess,
                        address: accumulatorAddress,
                        kind: .modify
                    ),
                    .closureTryApply(
                        closure: closure,
                        arguments: [accumulatorAccess, element],
                        normalTarget: closureContinuation,
                        errorTarget: closureError
                    ),
                ]
            )
            appendSyntheticBlock(
                id: closureContinuation,
                instructions: [
                    .endAccess(accumulatorAccess),
                ] + elementCleanup + [
                    .branch(target: loop, arguments: []),
                ]
            )
            appendSyntheticBlock(
                id: empty,
                instructions: [
                    .loadStack(
                        result: finalAccumulator,
                        slot: accumulatorSlot,
                        mode: .take
                    ),
                    .destroyStack(indexSlot),
                ] + sourceCleanup + [
                    .branch(
                        target: normalTarget,
                        arguments: [finalAccumulator]
                    ),
                ]
            )
            appendSyntheticBlock(
                id: closureError,
                parameters: [errorParameter],
                instructions: [
                    .endAccess(accumulatorAccess),
                ] + elementCleanup + [
                    .destroyStack(accumulatorSlot),
                    .destroyStack(indexSlot),
                ] + sourceCleanup + [
                    .branch(
                        target: errorTarget,
                        arguments: [errorParameter]
                    ),
                ]
            )
        }

        func lowerCollectionHigherOrderTryApply(
            operation: CanonicalSIL.HigherOrderIntrinsic,
            genericArguments: String,
            argumentText: String,
            normalTarget: Bytecode.BlockID,
            errorTarget: Bytecode.BlockID,
            line: Int
        ) throws {
            let plan = try parseCollectionHigherOrderPlan(
                operation: operation,
                genericArguments: genericArguments,
                argumentText: argumentText,
                line: line
            )
            if operation == .reduceInto {
                try lowerCollectionReduceIntoTryApply(
                    plan: plan,
                    normalTarget: normalTarget,
                    errorTarget: errorTarget,
                    line: line
                )
                return
            }
            func requiredRegister(
                _ register: Bytecode.Register?,
                _ role: String
            ) throws -> Bytecode.Register {
                guard let register else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "higher-order lowering omitted its \(role) register"
                    )
                }
                return register
            }
            let borrowedSource: BorrowedStoredValue?
            let source: Bytecode.Register
            if plan.consumesSource {
                borrowedSource = nil
                source = try materializeOwnedValue(
                    at: plan.sourceToken,
                    line: line
                )
            } else {
                borrowedSource = try borrowStoredValue(
                    at: plan.sourceToken,
                    line: line
                )
                source = try borrowedSource?.register
                    ?? resolve(plan.sourceToken, line: line)
            }
            guard registerTypes[Int(source.rawValue)] == plan.sourceType
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "higher-order source does not match its Collection specialization"
                )
            }
            let closure = try resolve(plan.closureToken, line: line)
            guard case let .closure(closureSignature) = registerTypes[
                Int(closure.rawValue)
            ], !closureSignature.effects.isAsync,
               closureSignature.result == plan.closureResultType
            else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "<higher-order closure>"
                )
            }
            let dictionaryTypes: (
                key: Bytecode.ValueType,
                value: Bytecode.ValueType
            )? = if case let .dictionary(key, value) = plan.sourceType {
                (key, value)
            } else {
                nil
            }
            let expectedClosureParameters: [Bytecode.ValueType]
            switch plan.callbackShape {
            case .dictionaryValue:
                guard let dictionaryTypes else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary value callback has a non-Dictionary source"
                    )
                }
                expectedClosureParameters = [dictionaryTypes.value]
            case .dictionaryKeyValue:
                guard let dictionaryTypes else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary key/value callback has a non-Dictionary source"
                    )
                }
                expectedClosureParameters = [
                    dictionaryTypes.key,
                    dictionaryTypes.value,
                ]
            case .element:
                expectedClosureParameters = switch plan.operation {
                case .reduce:
                    [plan.callResultType, plan.inputType]
                case .minimumBy, .maximumBy:
                    [plan.inputType, plan.inputType]
                case .map, .flatMap, .filter, .compactMap, .prefixWhile,
                     .dropWhile, .forEach, .firstWhere, .lastWhere,
                     .firstIndexWhere, .lastIndexWhere, .containsWhere,
                     .allSatisfy, .reduceInto:
                    [plan.inputType]
                case .mapValues, .compactMapValues:
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary value transform lost its callback projection"
                    )
                }
            }
            guard closureSignature.parameters == expectedClosureParameters,
                  closureSignature.parameterConventions.count
                    == expectedClosureParameters.count,
                  !closureSignature.parameterConventions.contains(.inout)
            else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "<higher-order closure>"
                )
            }
            if plan.operation.isComparatorSelection,
               plan.inputType.requiresLinearOwnership,
               closureSignature.parameterConventions != [.borrowed, .borrowed] {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "<comparison closure>"
                )
            }

            let isThrowing = closureSignature.effects.mayThrow
            if plan.operation == .map {
                let genericTypes = try splitTopLevel(genericArguments)
                    .filter { !$0.isEmpty }
                    .map(parseType)
                guard genericTypes.count == 3,
                      (genericTypes[2] == .never) == !isThrowing,
                      plan.errorDestination.map({
                        compilerAddressType($0) == genericTypes[2]
                      }) == true
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Collection.map error specialization does not match its closure"
                    )
                }
            } else {
                guard isThrowing else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "higher-order rethrows ABI lost its Error channel"
                    )
                }
            }

            if let destination = plan.resultDestination {
                guard compilerAddressType(destination) == plan.callResultType,
                      implicitStackValues[normalTarget] == nil,
                      suppressedVoidTryNormalBlocks.insert(normalTarget).inserted
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "higher-order indirect result destination is invalid"
                    )
                }
                let parameter = try allocate(type: plan.callResultType)
                implicitStackValues[normalTarget] = [.init(destination, parameter)]
            } else if plan.callResultType == .void {
                guard suppressedVoidTryNormalBlocks
                    .insert(normalTarget).inserted
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "higher-order Void continuation is shared"
                    )
                }
            }

            let errorValueType: Bytecode.ValueType = typeEnvironment
                .preservesTypedErrors ? .error : .string
            let errorCleanup = try allocateSyntheticBlockID()
            let errorParameter: Bytecode.Register?
            if isThrowing {
                errorParameter = try allocate(type: errorValueType)
                if let destination = plan.errorDestination {
                    guard compilerAddressType(destination) == errorValueType,
                          implicitStackValues[errorTarget] == nil
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "higher-order indirect Error destination is invalid"
                        )
                    }
                    let propagated = try allocate(type: errorValueType)
                    implicitStackValues[errorTarget] = [
                        .init(destination, propagated),
                    ]
                }
            } else {
                errorParameter = nil
            }

            let indexSlot = try allocateStackSlot(type: .int64)
            let initialIndex = try allocate(type: .int64)
            let traversalDirection = plan.operation.traversalDirection
            if traversalDirection == .reverse {
                appendInstruction(
                    .arrayCount(result: initialIndex, array: source)
                )
            } else {
                appendInstruction(
                    .constantInteger(result: initialIndex, bitPattern: 0)
                )
            }
            appendInstruction(
                .storeStack(
                    slot: indexSlot,
                    source: initialIndex,
                    mode: .initialize
                )
            )

            let builder: Bytecode.Register?
            if plan.operation.usesElementBuilder {
                let element: Bytecode.ValueType = switch plan.callResultType {
                case let .array(element), let .set(element):
                    element
                case let .dictionary(key, value):
                    .tuple([key, value])
                default:
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "higher-order builder has an unsupported result container"
                    )
                }
                let register = try allocate(
                    type: .arrayState(kind: .builder, element: element)
                )
                appendInstruction(.makeArrayBuilder(result: register))
                builder = register
            } else {
                builder = nil
            }
            func finishCollectionBuilder(
                _ builder: Bytecode.Register
            ) throws -> (
                result: Bytecode.Register,
                instructions: [IntermediateRepresentation.Instruction]
            ) {
                let result = try allocate(type: plan.callResultType)
                switch plan.callResultType {
                case .array:
                    return (
                        result,
                        [.finishArrayBuilder(result: result, builder: builder)]
                    )
                case let .dictionary(key, value):
                    let bufferedType = Bytecode.ValueType.array(
                        .tuple([key, value])
                    )
                    let buffered = try allocate(type: bufferedType)
                    var instructions: [IntermediateRepresentation.Instruction] = [
                        .finishArrayBuilder(result: buffered, builder: builder),
                        .makeDictionary(result: result, pairs: buffered),
                    ]
                    if bufferedType.requiresLinearOwnership {
                        instructions.append(.destroyValue(buffered))
                    }
                    return (result, instructions)
                case let .set(element):
                    let bufferedType = Bytecode.ValueType.array(element)
                    let buffered = try allocate(type: bufferedType)
                    var instructions: [IntermediateRepresentation.Instruction] = [
                        .finishArrayBuilder(result: buffered, builder: builder),
                        .makeSet(result: result, source: buffered),
                    ]
                    if bufferedType.requiresLinearOwnership {
                        instructions.append(.destroyValue(buffered))
                    }
                    return (result, instructions)
                default:
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "higher-order builder has an unsupported result container"
                    )
                }
            }
            func appendDictionaryPair(
                key: Bytecode.Register,
                value: Bytecode.Register,
                to builder: Bytecode.Register
            ) throws -> [IntermediateRepresentation.Instruction] {
                guard case let .dictionary(keyType, valueType) =
                    plan.callResultType,
                    registerTypes[Int(key.rawValue)] == keyType,
                    registerTypes[Int(value.rawValue)] == valueType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary builder pair does not match its result type"
                    )
                }
                let pairType = Bytecode.ValueType.tuple([keyType, valueType])
                let pair = try allocate(type: pairType)
                var instructions: [IntermediateRepresentation.Instruction] = [
                    .makeTuple(result: pair, elements: [key, value]),
                    .arrayBuilderAppend(builder: builder, value: pair),
                ]
                if pairType.requiresLinearOwnership {
                    instructions.append(.destroyValue(pair))
                }
                return instructions
            }
            let accumulatorType: Bytecode.ValueType? = if plan.operation == .reduce {
                plan.callResultType
            } else if plan.operation.isComparatorSelection {
                plan.inputType
            } else {
                nil
            }
            let initialAccumulator: Bytecode.Register?
            if plan.operation == .reduce {
                guard let initialToken = plan.initialToken
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Sequence.reduce initial value does not match its result"
                    )
                }
                let storedInitial = try materializeOwnedValue(
                    at: initialToken,
                    line: line
                )
                guard registerTypes[Int(storedInitial.rawValue)]
                        == plan.callResultType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Sequence.reduce initial value does not match its result"
                    )
                }
                initialAccumulator = storedInitial
            } else {
                initialAccumulator = nil
            }

            let loop = try allocateSyntheticBlockID()
            let some = try allocateSyntheticBlockID()
            let empty = try allocateSyntheticBlockID()
            let closureContinuation = try allocateSyntheticBlockID()
            let seed = try plan.operation.isComparatorSelection
                ? allocateSyntheticBlockID() : nil
            let seedSome = try plan.operation.isComparatorSelection
                ? allocateSyntheticBlockID() : nil
            let seedEmpty = try plan.operation.isComparatorSelection
                ? allocateSyntheticBlockID() : nil
            let loopAccumulator = try accumulatorType.map(allocate)
            let next = try allocate(type: .optional(plan.inputType))
            let element = try allocate(type: plan.inputType)
            let seedNext = try plan.operation.isComparatorSelection
                ? allocate(type: .optional(plan.inputType)) : nil
            let seedElement = try plan.operation.isComparatorSelection
                ? allocate(type: plan.inputType) : nil
            let directClosureResult = try isThrowing
                || plan.closureResultType == .void
                ? nil
                : allocate(type: plan.closureResultType)

            var closureArgumentPreparation: [
                IntermediateRepresentation.Instruction
            ] = []
            var dictionaryProjectionInstructions: [
                IntermediateRepresentation.Instruction
            ] = []
            var projectedFieldCleanup: [
                IntermediateRepresentation.Instruction
            ] = []
            let closureInput: Bytecode.Register?
            let projectedClosureArguments: [Bytecode.Register]
            let inputNeedsCleanup: Bool
            let dictionaryKey: Bytecode.Register?
            let dictionaryValue: Bytecode.Register?
            if plan.callbackShape == .element {
                dictionaryKey = nil
                dictionaryValue = nil
                projectedClosureArguments = []
                let inputConvention = closureSignature.parameterConventions[
                    plan.operation == .reduce ? 1 : 0
                ]
                if plan.inputType.requiresLinearOwnership,
                   inputConvention == .owned,
                   plan.operation.retainsInputAfterCall {
                    let copy = try allocate(type: plan.inputType)
                    closureArgumentPreparation.append(
                        .copyValue(result: copy, source: element)
                    )
                    closureInput = copy
                } else {
                    closureInput = element
                }
                inputNeedsCleanup = plan.inputType.requiresLinearOwnership
                    && (inputConvention == .borrowed
                        || plan.operation.retainsInputAfterCall)
            } else {
                guard let dictionaryTypes,
                      plan.inputType == .tuple([
                        dictionaryTypes.key,
                        dictionaryTypes.value,
                      ])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary callback projection has a mismatched element"
                    )
                }
                let key = try allocate(type: dictionaryTypes.key)
                let value = try allocate(type: dictionaryTypes.value)
                dictionaryKey = key
                dictionaryValue = value
                dictionaryProjectionInstructions = [
                    .unpackTuple(results: [key, value], tuple: element),
                ]
                if dictionaryTypes.key.requiresLinearOwnership {
                    projectedFieldCleanup.append(.destroyValue(key))
                }
                if dictionaryTypes.value.requiresLinearOwnership {
                    projectedFieldCleanup.append(.destroyValue(value))
                }
                func retainedClosureArgument(
                    _ register: Bytecode.Register,
                    type: Bytecode.ValueType,
                    convention: Bytecode.ParameterConvention
                ) throws -> Bytecode.Register {
                    guard type.requiresLinearOwnership,
                          convention == .owned
                    else { return register }
                    let copy = try allocate(type: type)
                    closureArgumentPreparation.append(
                        .copyValue(result: copy, source: register)
                    )
                    return copy
                }
                switch plan.callbackShape {
                case .dictionaryValue:
                    projectedClosureArguments = [
                        try retainedClosureArgument(
                            value,
                            type: dictionaryTypes.value,
                            convention: closureSignature.parameterConventions[0]
                        ),
                    ]
                case .dictionaryKeyValue:
                    projectedClosureArguments = [
                        try retainedClosureArgument(
                            key,
                            type: dictionaryTypes.key,
                            convention: closureSignature.parameterConventions[0]
                        ),
                        try retainedClosureArgument(
                            value,
                            type: dictionaryTypes.value,
                            convention: closureSignature.parameterConventions[1]
                        ),
                    ]
                case .element:
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "element callback entered Dictionary projection"
                    )
                }
                closureInput = nil
                inputNeedsCleanup = false
            }
            let accumulatorNeedsCleanup = accumulatorType?
                .requiresLinearOwnership == true
                && (plan.operation.isComparatorSelection
                    || closureSignature.parameterConventions[0] == .borrowed)
            let sourceCleanup: [IntermediateRepresentation.Instruction]
            if plan.consumesSource,
               plan.sourceType.requiresLinearOwnership {
                sourceCleanup = [.destroyValue(source)]
            } else {
                sourceCleanup = borrowedSource?.temporaryOwner.map {
                    [.destroyValue($0)]
                } ?? []
            }

            let loopArguments = initialAccumulator.map { [$0] } ?? []
            let initialTarget = seed ?? loop
            if isThrowing {
                appendInstruction(
                    .branch(target: initialTarget, arguments: loopArguments)
                )
            } else {
                let mustSucceed = try allocate(type: .bool)
                appendInstruction(.constantBool(result: mustSucceed, value: true))
                appendInstruction(
                    .conditionalBranch(
                        condition: mustSucceed,
                        trueTarget: initialTarget,
                        trueArguments: loopArguments,
                        falseTarget: errorCleanup,
                        falseArguments: []
                    )
                )
            }
            finishCurrent()

            if let seed, let seedSome, let seedEmpty,
               let seedNext, let seedElement {
                appendSyntheticBlock(
                    id: seed,
                    instructions: [
                        .collectionNext(
                            result: seedNext,
                            collection: source,
                            indexSlot: indexSlot,
                            direction: .forward
                        ),
                        .switchOptional(
                            optional: seedNext,
                            someTarget: seedSome,
                            noneTarget: seedEmpty
                        ),
                    ]
                )
                appendSyntheticBlock(
                    id: seedSome,
                    parameters: [seedElement],
                    instructions: [
                        .branch(target: loop, arguments: [seedElement]),
                    ]
                )
                let result = try allocate(type: plan.callResultType)
                appendSyntheticBlock(
                    id: seedEmpty,
                    instructions: [
                        .makeOptionalNone(result: result),
                        .destroyStack(indexSlot),
                    ] + sourceCleanup + [
                        .branch(target: normalTarget, arguments: [result]),
                    ]
                )
            }

            appendSyntheticBlock(
                id: loop,
                parameters: loopAccumulator.map { [$0] } ?? [],
                instructions: [
                    .collectionNext(
                        result: next,
                        collection: source,
                        indexSlot: indexSlot,
                        direction: traversalDirection
                    ),
                    .switchOptional(
                        optional: next,
                        someTarget: some,
                        noneTarget: empty
                    ),
                ]
            )

            let closureArguments: [Bytecode.Register]
            switch plan.callbackShape {
            case .dictionaryValue, .dictionaryKeyValue:
                closureArguments = projectedClosureArguments
            case .element:
                let closureInput = try requiredRegister(
                    closureInput,
                    "collection element callback input"
                )
                if plan.operation == .reduce {
                    closureArguments = [
                        try requiredRegister(
                            loopAccumulator,
                            "loop accumulator"
                        ),
                        closureInput,
                    ]
                } else if plan.operation == .minimumBy {
                    closureArguments = [
                        closureInput,
                        try requiredRegister(
                            loopAccumulator,
                            "minimum candidate"
                        ),
                    ]
                } else if plan.operation == .maximumBy {
                    closureArguments = [
                        try requiredRegister(
                            loopAccumulator,
                            "maximum candidate"
                        ),
                        closureInput,
                    ]
                } else {
                    closureArguments = [closureInput]
                }
            }
            let closureContinuationArguments = directClosureResult.map {
                [$0]
            } ?? []
            let closureInstructions: [IntermediateRepresentation.Instruction]
            if isThrowing {
                closureInstructions = closureArgumentPreparation + [
                    .closureTryApply(
                        closure: closure,
                        arguments: closureArguments,
                        normalTarget: closureContinuation,
                        errorTarget: errorCleanup
                    ),
                ]
            } else {
                closureInstructions = closureArgumentPreparation + [
                    .closureApply(
                        result: directClosureResult,
                        closure: closure,
                        arguments: closureArguments
                    ),
                    .branch(
                        target: closureContinuation,
                        arguments: closureContinuationArguments
                    ),
                ]
            }
            appendSyntheticBlock(
                id: some,
                parameters: [element],
                instructions: dictionaryProjectionInstructions
                    + closureInstructions
            )

            let continuationResult = try plan.closureResultType == .void
                ? nil
                : allocate(type: plan.closureResultType)
            let continuationParameters = continuationResult.map { [$0] } ?? []
            let materializedContinuationResult: Bytecode.Register?
            let resultMaterialization: [IntermediateRepresentation.Instruction]
            if [.map, .mapValues, .reduce].contains(plan.operation),
               plan.closureResultType == .void {
                let unit = try allocate(type: ValueRepresentation.unit)
                materializedContinuationResult = unit
                resultMaterialization = [
                    .makeTuple(result: unit, elements: []),
                ]
            } else {
                materializedContinuationResult = continuationResult
                resultMaterialization = []
            }
            var closureArgumentCleanup: [
                IntermediateRepresentation.Instruction
            ] = []
            if accumulatorNeedsCleanup {
                closureArgumentCleanup.append(
                    .destroyValue(
                        try requiredRegister(
                            loopAccumulator,
                            "borrowed loop accumulator"
                        )
                    )
                )
            }
            if inputNeedsCleanup {
                closureArgumentCleanup.append(.destroyValue(element))
            }
            switch plan.operation {
            case .map:
                let result = try requiredRegister(
                    materializedContinuationResult,
                    "map result"
                )
                var instructions = resultMaterialization + [
                    .arrayBuilderAppend(
                        builder: try requiredRegister(builder, "element builder"),
                        value: result
                    ),
                ]
                if plan.callResultType.requiresLinearOwnership {
                    instructions.append(.destroyValue(result))
                }
                instructions.append(contentsOf: closureArgumentCleanup)
                instructions.append(.branch(target: loop, arguments: []))
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: instructions
                )
            case .flatMap:
                let result = try requiredRegister(
                    continuationResult,
                    "flatMap sequence result"
                )
                var instructions: [IntermediateRepresentation.Instruction] = [
                    .arrayBuilderAppendContents(
                        builder: try requiredRegister(
                            builder,
                            "element builder"
                        ),
                        array: result
                    ),
                ]
                if plan.closureResultType.requiresLinearOwnership {
                    instructions.append(.destroyValue(result))
                }
                instructions.append(contentsOf: closureArgumentCleanup)
                instructions.append(.branch(target: loop, arguments: []))
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: instructions
                )
            case .filter:
                let predicate = try requiredRegister(
                    continuationResult,
                    "filter predicate"
                )
                let builder = try requiredRegister(builder, "element builder")
                let append = try allocateSyntheticBlockID()
                if plan.callbackShape == .dictionaryKeyValue {
                    let skip = try allocateSyntheticBlockID()
                    let key = try requiredRegister(
                        dictionaryKey,
                        "Dictionary.filter key"
                    )
                    let value = try requiredRegister(
                        dictionaryValue,
                        "Dictionary.filter value"
                    )
                    appendSyntheticBlock(
                        id: closureContinuation,
                        parameters: continuationParameters,
                        instructions: [
                            .conditionalBranch(
                                condition: predicate,
                                trueTarget: append,
                                trueArguments: [],
                                falseTarget: skip,
                                falseArguments: []
                            ),
                        ]
                    )
                    appendSyntheticBlock(
                        id: append,
                        instructions: try appendDictionaryPair(
                            key: key,
                            value: value,
                            to: builder
                        ) + [.branch(target: loop, arguments: [])]
                    )
                    appendSyntheticBlock(
                        id: skip,
                        instructions: projectedFieldCleanup + [
                            .branch(target: loop, arguments: []),
                        ]
                    )
                } else {
                    guard plan.callbackShape == .element else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "filter has an unsupported callback projection"
                        )
                    }
                    let skip = inputNeedsCleanup
                        ? try allocateSyntheticBlockID()
                        : loop
                    appendSyntheticBlock(
                        id: closureContinuation,
                        parameters: continuationParameters,
                        instructions: [
                            .conditionalBranch(
                                condition: predicate,
                                trueTarget: append,
                                trueArguments: [],
                                falseTarget: skip,
                                falseArguments: []
                            ),
                        ]
                    )
                    appendSyntheticBlock(
                        id: append,
                        instructions: [
                            .arrayBuilderAppend(
                                builder: builder,
                                value: element
                            ),
                        ] + (inputNeedsCleanup
                            ? [.destroyValue(element)] : [])
                            + [.branch(target: loop, arguments: [])]
                    )
                    if inputNeedsCleanup {
                        appendSyntheticBlock(
                            id: skip,
                            instructions: [
                                .destroyValue(element),
                                .branch(target: loop, arguments: []),
                            ]
                        )
                    }
                }
            case .compactMap:
                let optional = try requiredRegister(
                    continuationResult,
                    "compactMap result"
                )
                let builder = try requiredRegister(builder, "element builder")
                let append = try allocateSyntheticBlockID()
                let skip = try allocateSyntheticBlockID()
                guard case let .array(mappedType) = plan.callResultType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "compactMap result is not an Array"
                    )
                }
                let mapped = try allocate(type: mappedType)
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: closureArgumentCleanup + [
                        .switchOptional(
                            optional: optional,
                            someTarget: append,
                            noneTarget: skip
                        ),
                    ]
                )
                appendSyntheticBlock(
                    id: append,
                    parameters: [mapped],
                    instructions: [
                        .arrayBuilderAppend(
                            builder: builder,
                            value: mapped
                        ),
                    ] + (mappedType.requiresLinearOwnership
                        ? [.destroyValue(mapped)] : [])
                        + [.branch(target: loop, arguments: [])]
                )
                appendSyntheticBlock(
                    id: skip,
                    instructions: [
                        .branch(target: loop, arguments: []),
                    ]
                )
            case .mapValues:
                guard plan.callbackShape == .dictionaryValue,
                      let dictionaryTypes,
                      case let .dictionary(_, mappedType) = plan.callResultType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "mapValues has an invalid Dictionary lowering plan"
                    )
                }
                let key = try requiredRegister(
                    dictionaryKey,
                    "mapValues key"
                )
                let originalValue = try requiredRegister(
                    dictionaryValue,
                    "mapValues original value"
                )
                let mapped = try requiredRegister(
                    materializedContinuationResult,
                    "mapValues result"
                )
                guard registerTypes[Int(mapped.rawValue)] == mappedType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "mapValues closure result does not match its Dictionary"
                    )
                }
                var instructions = resultMaterialization
                if dictionaryTypes.value.requiresLinearOwnership {
                    instructions.append(.destroyValue(originalValue))
                }
                instructions.append(
                    contentsOf: try appendDictionaryPair(
                        key: key,
                        value: mapped,
                        to: try requiredRegister(builder, "element builder")
                    )
                )
                instructions.append(.branch(target: loop, arguments: []))
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: instructions
                )
            case .compactMapValues:
                guard plan.callbackShape == .dictionaryValue,
                      let dictionaryTypes,
                      case let .dictionary(_, mappedType) = plan.callResultType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "compactMapValues has an invalid Dictionary lowering plan"
                    )
                }
                let optional = try requiredRegister(
                    continuationResult,
                    "compactMapValues result"
                )
                let key = try requiredRegister(
                    dictionaryKey,
                    "compactMapValues key"
                )
                let originalValue = try requiredRegister(
                    dictionaryValue,
                    "compactMapValues original value"
                )
                let builder = try requiredRegister(builder, "element builder")
                let append = try allocateSyntheticBlockID()
                let skip = try allocateSyntheticBlockID()
                let mapped = try allocate(type: mappedType)
                var continuationInstructions: [
                    IntermediateRepresentation.Instruction
                ] = []
                if dictionaryTypes.value.requiresLinearOwnership {
                    continuationInstructions.append(
                        .destroyValue(originalValue)
                    )
                }
                continuationInstructions.append(
                    .switchOptional(
                        optional: optional,
                        someTarget: append,
                        noneTarget: skip
                    )
                )
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: continuationInstructions
                )
                appendSyntheticBlock(
                    id: append,
                    parameters: [mapped],
                    instructions: try appendDictionaryPair(
                        key: key,
                        value: mapped,
                        to: builder
                    ) + [.branch(target: loop, arguments: [])]
                )
                appendSyntheticBlock(
                    id: skip,
                    instructions: (dictionaryTypes.key.requiresLinearOwnership
                        ? [.destroyValue(key)] : []) + [
                        .branch(target: loop, arguments: []),
                    ]
                )
            case .prefixWhile:
                let predicate = try requiredRegister(
                    continuationResult,
                    "prefix(while:) predicate"
                )
                let builder = try requiredRegister(builder, "element builder")
                let append = try allocateSyntheticBlockID()
                let finish = try allocateSyntheticBlockID()
                let finished = try finishCollectionBuilder(builder)
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: [
                        .conditionalBranch(
                            condition: predicate,
                            trueTarget: append,
                            trueArguments: [],
                            falseTarget: finish,
                            falseArguments: []
                        ),
                    ]
                )
                appendSyntheticBlock(
                    id: append,
                    instructions: [
                        .arrayBuilderAppend(builder: builder, value: element),
                    ] + closureArgumentCleanup + [
                        .branch(target: loop, arguments: []),
                    ]
                )
                appendSyntheticBlock(
                    id: finish,
                    instructions: closureArgumentCleanup
                        + finished.instructions + [
                        .destroyStack(indexSlot),
                    ] + sourceCleanup + [
                        .branch(
                            target: normalTarget,
                            arguments: [finished.result]
                        ),
                    ]
                )
            case .dropWhile:
                let predicate = try requiredRegister(
                    continuationResult,
                    "drop(while:) predicate"
                )
                let builder = try requiredRegister(builder, "element builder")
                let keepDropping = try allocateSyntheticBlockID()
                let appendRemainder = try allocateSyntheticBlockID()
                let remainderLoop = try allocateSyntheticBlockID()
                let remainderSome = try allocateSyntheticBlockID()
                let remainderNext = try allocate(
                    type: .optional(plan.inputType)
                )
                let remainderElement = try allocate(type: plan.inputType)
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: [
                        .conditionalBranch(
                            condition: predicate,
                            trueTarget: keepDropping,
                            trueArguments: [],
                            falseTarget: appendRemainder,
                            falseArguments: []
                        ),
                    ]
                )
                appendSyntheticBlock(
                    id: keepDropping,
                    instructions: closureArgumentCleanup + [
                        .branch(target: loop, arguments: []),
                    ]
                )
                appendSyntheticBlock(
                    id: appendRemainder,
                    instructions: [
                        .arrayBuilderAppend(builder: builder, value: element),
                    ] + closureArgumentCleanup + [
                        .branch(target: remainderLoop, arguments: []),
                    ]
                )
                appendSyntheticBlock(
                    id: remainderLoop,
                    instructions: [
                        .collectionNext(
                            result: remainderNext,
                            collection: source,
                            indexSlot: indexSlot,
                            direction: .forward
                        ),
                        .switchOptional(
                            optional: remainderNext,
                            someTarget: remainderSome,
                            noneTarget: empty
                        ),
                    ]
                )
                appendSyntheticBlock(
                    id: remainderSome,
                    parameters: [remainderElement],
                    instructions: [
                        .arrayBuilderAppend(
                            builder: builder,
                            value: remainderElement
                        ),
                    ] + (plan.inputType.requiresLinearOwnership
                        ? [.destroyValue(remainderElement)] : []) + [
                        .branch(target: remainderLoop, arguments: []),
                    ]
                )
            case .reduce:
                let result = try requiredRegister(
                    materializedContinuationResult,
                    "reduce result"
                )
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: resultMaterialization
                        + closureArgumentCleanup + [
                        .branch(
                            target: loop,
                            arguments: [result]
                        ),
                    ]
                )
            case .reduceInto:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "reduce(into:_:) reached value-returning higher-order lowering"
                )
            case .forEach:
                appendSyntheticBlock(
                    id: closureContinuation,
                    instructions: closureArgumentCleanup
                        + [.branch(target: loop, arguments: [])]
                )
            case .firstWhere, .lastWhere:
                let predicate = try requiredRegister(
                    continuationResult,
                    "first/last(where:) predicate"
                )
                let matched = try allocateSyntheticBlockID()
                let skipped = try allocateSyntheticBlockID()
                let result = try allocate(type: plan.callResultType)
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: [
                        .conditionalBranch(
                            condition: predicate,
                            trueTarget: matched,
                            trueArguments: [],
                            falseTarget: skipped,
                            falseArguments: []
                        ),
                    ]
                )
                appendSyntheticBlock(
                    id: matched,
                    instructions: [
                        .makeOptionalSome(result: result, value: element),
                        .destroyStack(indexSlot),
                    ] + sourceCleanup + [
                        .branch(target: normalTarget, arguments: [result]),
                    ]
                )
                appendSyntheticBlock(
                    id: skipped,
                    instructions: (inputNeedsCleanup
                        ? [.destroyValue(element)] : [])
                        + [.branch(target: loop, arguments: [])]
                )
            case .firstIndexWhere, .lastIndexWhere:
                let predicate = try requiredRegister(
                    continuationResult,
                    "first/lastIndex(where:) predicate"
                )
                let matched = try allocateSyntheticBlockID()
                let wrap = try allocateSyntheticBlockID()
                let overflowTrap = try allocateSyntheticBlockID()
                let skipped = try allocateSyntheticBlockID()
                let advancedIndex = try allocate(type: .int64)
                let cursorAdjustment = try allocate(type: .int64)
                let matchedIndex = try allocate(type: .int64)
                let overflow = try allocate(type: .bool)
                let result = try allocate(type: plan.callResultType)
                let cursorAdjustmentBitPattern: UInt64 =
                    traversalDirection == .forward ? 1 : 0
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: [
                        .conditionalBranch(
                            condition: predicate,
                            trueTarget: matched,
                            trueArguments: [],
                            falseTarget: skipped,
                            falseArguments: []
                        ),
                    ]
                )
                appendSyntheticBlock(
                    id: matched,
                    instructions: closureArgumentCleanup + [
                        .loadStack(
                            result: advancedIndex,
                            slot: indexSlot,
                            mode: .copy
                        ),
                        .constantInteger(
                            result: cursorAdjustment,
                            bitPattern: cursorAdjustmentBitPattern
                        ),
                        .checkedBinary(
                            result: matchedIndex,
                            overflow: overflow,
                            operation: .subtract,
                            lhs: advancedIndex,
                            rhs: cursorAdjustment
                        ),
                        .conditionalBranch(
                            condition: overflow,
                            trueTarget: overflowTrap,
                            trueArguments: [],
                            falseTarget: wrap,
                            falseArguments: []
                        ),
                    ]
                )
                appendSyntheticBlock(
                    id: wrap,
                    instructions: [
                        .makeOptionalSome(
                            result: result,
                            value: matchedIndex
                        ),
                        .destroyStack(indexSlot),
                    ] + sourceCleanup + [
                        .branch(target: normalTarget, arguments: [result]),
                    ]
                )
                appendSyntheticBlock(
                    id: overflowTrap,
                    instructions: [.trap(.integerOverflow)]
                )
                appendSyntheticBlock(
                    id: skipped,
                    instructions: closureArgumentCleanup + [
                        .branch(target: loop, arguments: []),
                    ]
                )
            case .containsWhere, .allSatisfy:
                let predicate = try requiredRegister(
                    continuationResult,
                    "predicate result"
                )
                let finished = try allocateSyntheticBlockID()
                let continued = try allocateSyntheticBlockID()
                let finishesWhenTrue = plan.operation == .containsWhere
                let result = try allocate(type: .bool)
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: closureArgumentCleanup + [
                        .conditionalBranch(
                            condition: predicate,
                            trueTarget: finishesWhenTrue ? finished : continued,
                            trueArguments: [],
                            falseTarget: finishesWhenTrue ? continued : finished,
                            falseArguments: []
                        ),
                    ]
                )
                appendSyntheticBlock(
                    id: finished,
                    instructions: [
                        .constantBool(
                            result: result,
                            value: finishesWhenTrue
                        ),
                        .destroyStack(indexSlot),
                    ] + sourceCleanup + [
                        .branch(target: normalTarget, arguments: [result]),
                    ]
                )
                appendSyntheticBlock(
                    id: continued,
                    instructions: [.branch(target: loop, arguments: [])]
                )
            case .minimumBy, .maximumBy:
                let predicate = try requiredRegister(
                    continuationResult,
                    "comparison result"
                )
                let challengerWins = try allocateSyntheticBlockID()
                let candidateWins = try allocateSyntheticBlockID()
                let candidate = try requiredRegister(
                    loopAccumulator,
                    "comparison candidate"
                )
                appendSyntheticBlock(
                    id: closureContinuation,
                    parameters: continuationParameters,
                    instructions: [
                        .conditionalBranch(
                            condition: predicate,
                            trueTarget: challengerWins,
                            trueArguments: [],
                            falseTarget: candidateWins,
                            falseArguments: []
                        ),
                    ]
                )
                appendSyntheticBlock(
                    id: challengerWins,
                    instructions: (plan.inputType.requiresLinearOwnership
                        ? [.destroyValue(candidate)] : []) + [
                        .branch(target: loop, arguments: [element]),
                    ]
                )
                appendSyntheticBlock(
                    id: candidateWins,
                    instructions: (plan.inputType.requiresLinearOwnership
                        ? [.destroyValue(element)] : []) + [
                        .branch(target: loop, arguments: [candidate]),
                    ]
                )
            }

            let emptyInstructions: [IntermediateRepresentation.Instruction]
            switch plan.operation {
            case .map, .flatMap, .filter, .compactMap, .mapValues,
                 .compactMapValues, .prefixWhile, .dropWhile:
                let finished = try finishCollectionBuilder(
                    try requiredRegister(builder, "element builder")
                )
                emptyInstructions = finished.instructions + [
                    .destroyStack(indexSlot),
                ] + sourceCleanup + [
                    .branch(
                        target: normalTarget,
                        arguments: [finished.result]
                    ),
                ]
            case .reduce:
                emptyInstructions = [
                    .destroyStack(indexSlot),
                ] + sourceCleanup + [
                    .branch(
                        target: normalTarget,
                        arguments: [
                            try requiredRegister(
                                loopAccumulator,
                                "final reduce accumulator"
                            ),
                        ]
                    ),
                ]
            case .reduceInto:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "reduce(into:_:) reached value-returning higher-order lowering"
                )
            case .forEach:
                emptyInstructions = [
                    .destroyStack(indexSlot),
                ] + sourceCleanup + [
                    .branch(target: normalTarget, arguments: []),
                ]
            case .firstWhere, .lastWhere, .firstIndexWhere,
                 .lastIndexWhere:
                let result = try allocate(type: plan.callResultType)
                emptyInstructions = [
                    .makeOptionalNone(result: result),
                    .destroyStack(indexSlot),
                ] + sourceCleanup + [
                    .branch(target: normalTarget, arguments: [result]),
                ]
            case .containsWhere, .allSatisfy:
                let result = try allocate(type: .bool)
                emptyInstructions = [
                    .constantBool(
                        result: result,
                        value: plan.operation == .allSatisfy
                    ),
                    .destroyStack(indexSlot),
                ] + sourceCleanup + [
                    .branch(target: normalTarget, arguments: [result]),
                ]
            case .minimumBy, .maximumBy:
                let result = try allocate(type: plan.callResultType)
                emptyInstructions = [
                    .makeOptionalSome(
                        result: result,
                        value: try requiredRegister(
                            loopAccumulator,
                            "final comparison candidate"
                        )
                    ),
                    .destroyStack(indexSlot),
                ] + sourceCleanup + [
                    .branch(target: normalTarget, arguments: [result]),
                ]
            }
            appendSyntheticBlock(id: empty, instructions: emptyInstructions)

            let propagatedArguments = errorParameter.map { [$0] } ?? []
            var cleanupInstructions: [IntermediateRepresentation.Instruction] = []
            if isThrowing {
                cleanupInstructions.append(
                    contentsOf: plan.callbackShape == .element
                        ? closureArgumentCleanup : projectedFieldCleanup
                )
            }
            if let builder {
                cleanupInstructions.append(.destroyValue(builder))
            }
            cleanupInstructions.append(.destroyStack(indexSlot))
            cleanupInstructions.append(contentsOf: sourceCleanup)
            cleanupInstructions.append(
                .branch(
                    target: errorTarget,
                    arguments: propagatedArguments
                )
            )
            appendSyntheticBlock(
                id: errorCleanup,
                parameters: errorParameter.map { [$0] } ?? [],
                instructions: cleanupInstructions
            )
        }

        func resultContainer(
            success: String,
            failure: String
        ) throws -> CanonicalSIL.AlgebraicTransform.Container {
            let type = try parseType("Result<\(success), \(failure)>")
            guard case let .local(key) = type else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "concrete Result container"
                )
            }
            return .enumeration(key: key)
        }

        func isSupportedErrorType(
            _ type: Bytecode.ValueType,
            spelling: String
        ) throws -> Bool {
            switch ValueRepresentation.storable(type) {
            case .never, .error:
                return true
            case .string:
                let normalized = spelling
                    .replacingOccurrences(of: "Swift.", with: "")
                    .filter { !$0.isWhitespace }
                return normalized == "Error" || normalized == "anyError"
            case let .local(key):
                return try typeEnvironment.definition(for: key)
                    .conformsToError
            default:
                return false
            }
        }

        func algebraicEnumerationCase(
            named name: String,
            payloadType: Bytecode.ValueType,
            in container: CanonicalSIL.AlgebraicTransform.Container
        ) throws -> CanonicalSIL.AlgebraicTransform.Case {
            guard case let .enumeration(key) = container else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "algebraic enum case requires an enum container"
                )
            }
            let index = try typeEnvironment.enumCaseIndex(
                type: key,
                name: name
            )
            guard let exact = UInt32(exactly: index) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "algebraic enum case index exceeds UInt32"
                )
            }
            return .init(
                tag: .enumeration(exact),
                payloadType: payloadType
            )
        }

        func parseAlgebraicTransformPlan(
            _ intrinsic: CanonicalSIL.AlgebraicIntrinsic,
            genericArguments: String,
            argumentText: String,
            line: Int
        ) throws -> CanonicalSIL.AlgebraicTransform.Plan {
            let genericSpellings = splitTopLevel(genericArguments)
                .filter { !$0.isEmpty }
            let arguments = try parseApplyValueTokens(
                argumentText,
                line: line
            )

            switch intrinsic {
            case let .optional(transformation):
                guard genericSpellings.count == 3,
                      arguments.count == 4
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional transform has an unsupported specialization"
                    )
                }
                let genericTypes = try genericSpellings.map(parseType)
                guard try isSupportedErrorType(
                    genericTypes[1],
                    spelling: genericSpellings[1]
                ) else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Optional transform Error \(genericTypes[1])"
                    )
                }
                let inputPayload = ValueRepresentation.storable(
                    genericTypes[0]
                )
                let outputPayload = ValueRepresentation.storable(
                    genericTypes[2]
                )
                let input = CanonicalSIL.AlgebraicTransform.Container
                    .optional(wrapped: inputPayload)
                let output = CanonicalSIL.AlgebraicTransform.Container
                    .optional(wrapped: outputPayload)
                let inputSome = CanonicalSIL.AlgebraicTransform.Case(
                    tag: .optionalSome,
                    payloadType: inputPayload
                )
                let outputSome = CanonicalSIL.AlgebraicTransform.Case(
                    tag: .optionalSome,
                    payloadType: outputPayload
                )
                let none = CanonicalSIL.AlgebraicTransform.Case(
                    tag: .optionalNone,
                    payloadType: nil
                )
                let closureOutput: CanonicalSIL.AlgebraicTransform
                    .ClosureOutput = switch transformation {
                case .map:
                    .payload(
                        logicalType: genericTypes[2],
                        storedType: outputPayload,
                        outputCase: outputSome
                    )
                case .flatMap:
                    .container(output.type)
                }
                return .init(
                    sourceToken: arguments[3],
                    closureToken: arguments[2],
                    resultDestination: arguments[0],
                    errorDestination: arguments[1],
                    errorType: genericTypes[1],
                    input: input,
                    output: output,
                    transformedInputCase: inputSome,
                    passthroughInputCase: none,
                    passthroughOutputCase: none,
                    closureOutput: closureOutput
                )

            case let .result(selectedCase, transformation):
                guard genericSpellings.count == 3,
                      arguments.count == 3
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Result transform has an unsupported specialization"
                    )
                }
                let genericTypes = try genericSpellings.map(parseType)
                let outputFailureIsSupported: Bool
                if selectedCase == .success {
                    outputFailureIsSupported = true
                } else {
                    outputFailureIsSupported = try isSupportedErrorType(
                        genericTypes[2],
                        spelling: genericSpellings[2]
                    )
                }
                guard try isSupportedErrorType(
                    genericTypes[1],
                    spelling: genericSpellings[1]
                ),
                      outputFailureIsSupported
                else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Result transform Failure specialization"
                    )
                }
                let success = ValueRepresentation.storable(genericTypes[0])
                let failure = ValueRepresentation.storable(genericTypes[1])
                let transformedOutput = ValueRepresentation.storable(
                    genericTypes[2]
                )
                let input = try resultContainer(
                    success: genericSpellings[0],
                    failure: genericSpellings[1]
                )
                let output: CanonicalSIL.AlgebraicTransform.Container
                let transformedInputPayload: Bytecode.ValueType
                let passthroughPayload: Bytecode.ValueType
                let outputSuccess: Bytecode.ValueType
                let outputFailure: Bytecode.ValueType
                switch selectedCase {
                case .success:
                    output = try resultContainer(
                        success: genericSpellings[2],
                        failure: genericSpellings[1]
                    )
                    transformedInputPayload = success
                    passthroughPayload = failure
                    outputSuccess = transformedOutput
                    outputFailure = failure
                case .failure:
                    output = try resultContainer(
                        success: genericSpellings[0],
                        failure: genericSpellings[2]
                    )
                    transformedInputPayload = failure
                    passthroughPayload = success
                    outputSuccess = success
                    outputFailure = transformedOutput
                }
                let transformedInputCase = try algebraicEnumerationCase(
                    named: selectedCase.rawValue,
                    payloadType: transformedInputPayload,
                    in: input
                )
                let passthroughInputCase = try algebraicEnumerationCase(
                    named: selectedCase.opposite.rawValue,
                    payloadType: passthroughPayload,
                    in: input
                )
                let transformedOutputCase = try algebraicEnumerationCase(
                    named: selectedCase.rawValue,
                    payloadType: selectedCase == .success
                        ? outputSuccess : outputFailure,
                    in: output
                )
                let passthroughOutputCase = try algebraicEnumerationCase(
                    named: selectedCase.opposite.rawValue,
                    payloadType: passthroughPayload,
                    in: output
                )
                let closureOutput: CanonicalSIL.AlgebraicTransform
                    .ClosureOutput = switch transformation {
                case .map:
                    .payload(
                        logicalType: genericTypes[2],
                        storedType: transformedOutput,
                        outputCase: transformedOutputCase
                    )
                case .flatMap:
                    .container(output.type)
                }
                return .init(
                    sourceToken: arguments[2],
                    closureToken: arguments[1],
                    resultDestination: arguments[0],
                    errorDestination: nil,
                    errorType: nil,
                    input: input,
                    output: output,
                    transformedInputCase: transformedInputCase,
                    passthroughInputCase: passthroughInputCase,
                    passthroughOutputCase: passthroughOutputCase,
                    closureOutput: closureOutput
                )

            case .resultGet:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Result.get entered closure-transform planning"
                )
            }
        }

        func appendAlgebraicSwitch(
            source: Bytecode.Register,
            container: CanonicalSIL.AlgebraicTransform.Container,
            transformedCase: CanonicalSIL.AlgebraicTransform.Case,
            transformedTarget: Bytecode.BlockID,
            passthroughCase: CanonicalSIL.AlgebraicTransform.Case,
            passthroughTarget: Bytecode.BlockID
        ) throws {
            switch container {
            case .optional:
                let someTarget: Bytecode.BlockID
                let noneTarget: Bytecode.BlockID
                switch (transformedCase.tag, passthroughCase.tag) {
                case (.optionalSome, .optionalNone):
                    someTarget = transformedTarget
                    noneTarget = passthroughTarget
                case (.optionalNone, .optionalSome):
                    someTarget = passthroughTarget
                    noneTarget = transformedTarget
                default:
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional transform must cover .some and .none exactly once"
                    )
                }
                appendInstruction(
                    .switchOptional(
                        optional: source,
                        someTarget: someTarget,
                        noneTarget: noneTarget
                    )
                )

            case .enumeration:
                guard case let .enumeration(transformedIndex) =
                        transformedCase.tag,
                      case let .enumeration(passthroughIndex) =
                        passthroughCase.tag,
                      transformedIndex != passthroughIndex
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "enum transform must cover two distinct cases"
                    )
                }
                appendInstruction(
                    .switchEnum(
                        enumeration: source,
                        cases: [
                            .init(
                                caseIndex: transformedIndex,
                                target: transformedTarget
                            ),
                            .init(
                                caseIndex: passthroughIndex,
                                target: passthroughTarget
                            ),
                        ],
                        defaultTarget: nil
                    )
                )
            }
        }

        func algebraicCaseIsValid(
            _ shape: CanonicalSIL.AlgebraicTransform.Case,
            in container: CanonicalSIL.AlgebraicTransform.Container
        ) throws -> Bool {
            switch (container, shape.tag) {
            case let (.optional(wrapped), .optionalSome):
                return shape.payloadType == wrapped
            case (.optional, .optionalNone):
                return shape.payloadType == nil
            case let (.enumeration(key), .enumeration(rawIndex)):
                guard case let .enumeration(cases) = try typeEnvironment
                        .definition(for: key).kind,
                      let index = Int(exactly: rawIndex),
                      cases.indices.contains(index)
                else { return false }
                return cases[index].payloadType == shape.payloadType
            default:
                return false
            }
        }

        func makeAlgebraicCase(
            _ shape: CanonicalSIL.AlgebraicTransform.Case,
            in container: CanonicalSIL.AlgebraicTransform.Container,
            payload: Bytecode.Register?
        ) throws -> (
            value: Bytecode.Register,
            instructions: [IntermediateRepresentation.Instruction]
        ) {
            let payloadType = payload.map {
                registerTypes[Int($0.rawValue)]
            }
            guard payloadType == shape.payloadType else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "algebraic case payload does not match its plan"
                )
            }
            let value = try allocate(type: container.type)
            switch (container, shape.tag) {
            case let (.optional(wrapped), .optionalSome):
                guard shape.payloadType == wrapped, let payload else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional.some transform has an invalid payload"
                    )
                }
                return (
                    value,
                    [.makeOptionalSome(result: value, value: payload)]
                )
            case (.optional, .optionalNone):
                guard payload == nil, shape.payloadType == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional.none transform unexpectedly has a payload"
                    )
                }
                return (value, [.makeOptionalNone(result: value)])
            case let (.enumeration, .enumeration(index)):
                return (
                    value,
                    [
                        .makeEnum(
                            result: value,
                            caseIndex: index,
                            payload: payload
                        ),
                    ]
                )
            default:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "algebraic case does not belong to its output container"
                )
            }
        }

        func lowerAlgebraicTransform(
            _ plan: CanonicalSIL.AlgebraicTransform.Plan,
            invocation: AlgebraicTransformInvocation,
            line: Int
        ) throws {
            let errorABIIsValid: Bool = switch (
                plan.errorDestination,
                plan.errorType
            ) {
            case (nil, nil):
                true
            case let (.some(destination), .some(type)):
                compilerAddressType(destination) == type
            default:
                false
            }
            let outputCaseIsValid: Bool
            switch plan.closureOutput {
            case let .payload(_, _, outputCase):
                outputCaseIsValid = try algebraicCaseIsValid(
                    outputCase,
                    in: plan.output
                )
            case .container:
                outputCaseIsValid = true
            }
            guard let closureParameterType =
                    plan.transformedInputCase.payloadType,
                  try algebraicCaseIsValid(
                    plan.transformedInputCase,
                    in: plan.input
                  ),
                  try algebraicCaseIsValid(
                    plan.passthroughInputCase,
                    in: plan.input
                  ),
                  try algebraicCaseIsValid(
                    plan.passthroughOutputCase,
                    in: plan.output
                  ),
                  outputCaseIsValid,
                  plan.passthroughInputCase.payloadType
                    == plan.passthroughOutputCase.payloadType,
                  compilerAddressType(plan.resultDestination)
                    == plan.output.type,
                  errorABIIsValid
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "algebraic transform plan does not match its physical ABI"
                )
            }
            switch plan.closureOutput {
            case let .payload(logicalType, storedType, outputCase):
                guard outputCase.payloadType == storedType,
                      logicalType == .void
                        || ValueRepresentation.storable(logicalType)
                            == storedType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "algebraic map result does not match its output case"
                    )
                }
            case let .container(type):
                guard type == plan.output.type else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "algebraic flatMap result is not its output container"
                    )
                }
            }

            let source = try materializeOwnedValue(
                at: plan.sourceToken,
                line: line
            )
            let closure = try resolve(plan.closureToken, line: line)
            guard registerTypes[Int(source.rawValue)] == plan.input.type,
                  case let .closure(signature) = registerTypes[
                    Int(closure.rawValue)
                  ],
                  signature.parameters == [closureParameterType],
                  signature.parameterConventions.count == 1,
                  signature.parameterConventions[0] != .inout,
                  signature.result == plan.closureOutput.logicalType,
                  !signature.effects.isAsync
            else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "algebraic transform"
                )
            }

            let completionTarget: Bytecode.BlockID
            let directResultToken: String?
            let errorTarget: Bytecode.BlockID?
            switch invocation {
            case let .direct(resultToken):
                guard !signature.effects.mayThrow,
                      plan.errorDestination == nil,
                      plan.errorType == nil
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: line,
                        mangledName: "nonthrowing algebraic transform"
                    )
                }
                completionTarget = try allocateSyntheticBlockID()
                directResultToken = resultToken
                errorTarget = nil

            case let .branching(normalTarget, branchErrorTarget):
                guard let errorType = plan.errorType,
                      plan.errorDestination != nil,
                      signature.effects.mayThrow == (errorType != .never),
                      implicitStackValues[normalTarget] == nil,
                      suppressedVoidTryNormalBlocks.insert(normalTarget).inserted
                else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: line,
                        mangledName: "rethrowing algebraic transform"
                    )
                }
                let propagatedResult = try allocate(type: plan.output.type)
                implicitStackValues[normalTarget] = [
                    .init(plan.resultDestination, propagatedResult),
                ]
                completionTarget = normalTarget
                directResultToken = nil
                errorTarget = branchErrorTarget
            }

            let isThrowing = signature.effects.mayThrow
            let errorCleanup: Bytecode.BlockID?
            let errorParameter: Bytecode.Register?
            if let errorTarget {
                let cleanup = try allocateSyntheticBlockID()
                errorCleanup = cleanup
                if isThrowing {
                    let expectedErrorType: Bytecode.ValueType = typeEnvironment
                        .preservesTypedErrors ? .error : .string
                    guard plan.errorType == expectedErrorType,
                          let errorDestination = plan.errorDestination,
                          implicitStackValues[errorTarget] == nil
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "algebraic rethrows Error does not match its image"
                        )
                    }
                    let parameter = try allocate(type: expectedErrorType)
                    let propagated = try allocate(type: expectedErrorType)
                    implicitStackValues[errorTarget] = [
                        .init(errorDestination, propagated),
                    ]
                    errorParameter = parameter
                } else {
                    errorParameter = nil
                }
            } else {
                errorCleanup = nil
                errorParameter = nil
            }

            let dispatch = try allocateSyntheticBlockID()
            let transformed = try allocateSyntheticBlockID()
            let passthrough = try allocateSyntheticBlockID()
            let closureContinuation = try allocateSyntheticBlockID()
            if let errorCleanup, !isThrowing {
                // A Never-specialized `try_apply` still has an error edge in
                // SIL. Preserve it as verified but statically impossible CFG.
                let mustSucceed = try allocate(type: .bool)
                appendInstruction(.constantBool(result: mustSucceed, value: true))
                appendInstruction(
                    .conditionalBranch(
                        condition: mustSucceed,
                        trueTarget: dispatch,
                        trueArguments: [],
                        falseTarget: errorCleanup,
                        falseArguments: []
                    )
                )
            } else {
                appendInstruction(.branch(target: dispatch, arguments: []))
            }
            finishCurrent()

            current = .init(id: dispatch, parameters: [], instructions: [])
            try appendAlgebraicSwitch(
                source: source,
                container: plan.input,
                transformedCase: plan.transformedInputCase,
                transformedTarget: transformed,
                passthroughCase: plan.passthroughInputCase,
                passthroughTarget: passthrough
            )
            finishCurrent()

            let payload = try allocate(type: closureParameterType)
            let closureResultType: Bytecode.ValueType? = switch plan.closureOutput {
            case let .payload(logicalType, storedType, _):
                logicalType == .void ? nil : storedType
            case let .container(type):
                type
            }
            let closureResult = try closureResultType.map(allocate)
            let transformedInstructions: [IntermediateRepresentation.Instruction]
            if isThrowing {
                guard let errorCleanup else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "throwing algebraic transform has no error cleanup"
                    )
                }
                transformedInstructions = [
                    .closureTryApply(
                        closure: closure,
                        arguments: [payload],
                        normalTarget: closureContinuation,
                        errorTarget: errorCleanup
                    ),
                ]
            } else {
                transformedInstructions = [
                    .closureApply(
                        result: closureResult,
                        closure: closure,
                        arguments: [payload]
                    ),
                    .branch(
                        target: closureContinuation,
                        arguments: closureResult.map { [$0] } ?? []
                    ),
                ]
            }
            appendSyntheticBlock(
                id: transformed,
                parameters: [payload],
                instructions: transformedInstructions
            )

            let continuationResult = try closureResultType.map(allocate)
            let transformedValue: Bytecode.Register
            var continuationInstructions: [IntermediateRepresentation.Instruction]
            switch plan.closureOutput {
            case let .payload(_, _, outputCase):
                let storedPayload: Bytecode.Register
                let payloadMaterialization: [IntermediateRepresentation.Instruction]
                if let continuationResult {
                    storedPayload = continuationResult
                    payloadMaterialization = []
                } else {
                    storedPayload = try allocate(type: ValueRepresentation.unit)
                    payloadMaterialization = [
                        .makeTuple(result: storedPayload, elements: []),
                    ]
                }
                let constructed = try makeAlgebraicCase(
                    outputCase,
                    in: plan.output,
                    payload: storedPayload
                )
                transformedValue = constructed.value
                continuationInstructions = payloadMaterialization
                    + constructed.instructions
            case .container:
                guard let continuationResult else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "flatMap closure did not produce its container"
                    )
                }
                transformedValue = continuationResult
                continuationInstructions = []
            }
            let payloadNeedsCleanup = closureParameterType
                .requiresLinearOwnership
                && signature.parameterConventions[0] == .borrowed
            if payloadNeedsCleanup {
                continuationInstructions.append(.destroyValue(payload))
            }
            continuationInstructions.append(
                .branch(
                    target: completionTarget,
                    arguments: [transformedValue]
                )
            )
            appendSyntheticBlock(
                id: closureContinuation,
                parameters: continuationResult.map { [$0] } ?? [],
                instructions: continuationInstructions
            )

            let passthroughPayload = try plan.passthroughInputCase
                .payloadType.map(allocate)
            let forwarded = try makeAlgebraicCase(
                plan.passthroughOutputCase,
                in: plan.output,
                payload: passthroughPayload
            )
            appendSyntheticBlock(
                id: passthrough,
                parameters: passthroughPayload.map { [$0] } ?? [],
                instructions: forwarded.instructions + [
                    .branch(
                        target: completionTarget,
                        arguments: [forwarded.value]
                    ),
                ]
            )

            if let errorCleanup, let errorTarget {
                var instructions: [IntermediateRepresentation.Instruction] = []
                if isThrowing && payloadNeedsCleanup {
                    instructions.append(.destroyValue(payload))
                } else if !isThrowing,
                          plan.input.type.requiresLinearOwnership {
                    // The impossible edge precedes the consuming Optional
                    // switch, so it still owns the materialized source.
                    instructions.append(.destroyValue(source))
                }
                instructions.append(
                    .branch(
                        target: errorTarget,
                        arguments: errorParameter.map { [$0] } ?? []
                    )
                )
                appendSyntheticBlock(
                    id: errorCleanup,
                    parameters: errorParameter.map { [$0] } ?? [],
                    instructions: instructions
                )
            }

            if let directResultToken {
                let mergedResult = try allocate(type: plan.output.type)
                current = .init(
                    id: completionTarget,
                    parameters: [mergedResult],
                    instructions: []
                )
                try storeConstructedValue(
                    mergedResult,
                    at: plan.resultDestination,
                    mode: .initialize
                )
                voidValues.insert(directResultToken)
            }
        }

        func parseResultProjectionPlan(
            genericArguments: String,
            argumentText: String,
            line: Int
        ) throws -> CanonicalSIL.AlgebraicTransform.ProjectionPlan {
            let genericSpellings = splitTopLevel(genericArguments)
                .filter { !$0.isEmpty }
            let arguments = try parseApplyValueTokens(
                argumentText,
                line: line
            )
            guard genericSpellings.count == 2, arguments.count == 3 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Result.get has an unsupported specialization"
                )
            }
            let genericTypes = try genericSpellings.map(parseType)
            guard try isSupportedErrorType(
                genericTypes[1],
                spelling: genericSpellings[1]
            ) else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "Result.get Failure \(genericTypes[1])"
                )
            }
            let success = ValueRepresentation.storable(genericTypes[0])
            let failure = ValueRepresentation.storable(genericTypes[1])
            let input = try resultContainer(
                success: genericSpellings[0],
                failure: genericSpellings[1]
            )
            return .init(
                sourceToken: arguments[2],
                resultDestination: arguments[0],
                errorDestination: arguments[1],
                input: input,
                successCase: try algebraicEnumerationCase(
                    named: CanonicalSIL.AlgebraicIntrinsic.ResultCase
                        .success.rawValue,
                    payloadType: success,
                    in: input
                ),
                failureCase: try algebraicEnumerationCase(
                    named: CanonicalSIL.AlgebraicIntrinsic.ResultCase
                        .failure.rawValue,
                    payloadType: failure,
                    in: input
                )
            )
        }

        func lowerResultProjection(
            _ plan: CanonicalSIL.AlgebraicTransform.ProjectionPlan,
            normalTarget: Bytecode.BlockID,
            errorTarget: Bytecode.BlockID,
            line: Int
        ) throws {
            guard let successType = plan.successCase.payloadType,
                  let failureType = plan.failureCase.payloadType,
                  try algebraicCaseIsValid(
                    plan.successCase,
                    in: plan.input
                  ),
                  try algebraicCaseIsValid(
                    plan.failureCase,
                    in: plan.input
                  ),
                  compilerAddressType(plan.resultDestination) == successType,
                  compilerAddressType(plan.errorDestination) == failureType,
                  implicitStackValues[normalTarget] == nil,
                  implicitStackValues[errorTarget] == nil,
                  suppressedVoidTryNormalBlocks.insert(normalTarget).inserted
            else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "Result.get"
                )
            }
            let source = try materializeOwnedValue(
                at: plan.sourceToken,
                line: line
            )
            guard registerTypes[Int(source.rawValue)] == plan.input.type else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "Result.get"
                )
            }

            let propagatedSuccess = try allocate(type: successType)
            let propagatedFailure = try allocate(type: failureType)
            implicitStackValues[normalTarget] = [
                .init(plan.resultDestination, propagatedSuccess),
            ]
            implicitStackValues[errorTarget] = [
                .init(plan.errorDestination, propagatedFailure),
            ]

            let success = try allocateSyntheticBlockID()
            let failure = try allocateSyntheticBlockID()
            try appendAlgebraicSwitch(
                source: source,
                container: plan.input,
                transformedCase: plan.successCase,
                transformedTarget: success,
                passthroughCase: plan.failureCase,
                passthroughTarget: failure
            )
            finishCurrent()

            let successPayload = try allocate(type: successType)
            appendSyntheticBlock(
                id: success,
                parameters: [successPayload],
                instructions: [
                    .branch(
                        target: normalTarget,
                        arguments: [successPayload]
                    ),
                ]
            )
            let failurePayload = try allocate(type: failureType)
            appendSyntheticBlock(
                id: failure,
                parameters: [failurePayload],
                instructions: [
                    .branch(
                        target: errorTarget,
                        arguments: [failurePayload]
                    ),
                ]
            )
        }

        func progressionSequenceType(
            _ raw: String
        ) throws -> CanonicalSIL.Progression.SequenceType? {
            try CanonicalSIL.Progression.sequenceType(raw) {
                try parseStoredType($0)
            }
        }

        func progressionIteratorType(
            _ raw: String
        ) throws -> CanonicalSIL.Progression.SequenceType? {
            try CanonicalSIL.Progression.iteratorType(raw) {
                try parseStoredType($0)
            }
        }

        func normalizedIteratorCollectionType(
            _ shape: CanonicalSIL.CollectionIntrinsic.IteratorShape,
            genericArguments: String
        ) throws -> Bytecode.ValueType {
            let spelling: String = switch shape {
            case .collection:
                genericArguments
            case .reversed:
                "ReversedCollection<\(genericArguments)>"
            case .enumerated:
                "EnumeratedSequence<\(genericArguments)>"
            case .zipped:
                "Zip2Sequence<\(genericArguments)>"
            case .flattened:
                "FlattenSequence<\(genericArguments)>"
            case .joined:
                "JoinedSequence<\(genericArguments)>"
            }
            let type = try parseType(spelling)
            guard case .array = type else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "collection iterator \(spelling)"
                )
            }
            return type
        }

        func progressionValue(
            at address: String,
            line: Int
        ) throws -> CanonicalSIL.Progression.Value {
            let base = addressBase(address)
            guard let value = progressionAddressValues[base],
                  progressionAddresses[base] == value.type
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "progression operation references uninitialized or mismatched storage at line \(line)"
                )
            }
            return value
        }

        func initializeProgressionIterator(
            type: CanonicalSIL.Progression.SequenceType,
            outputAddress: String,
            inputAddress: String,
            resultToken: String,
            line: Int
        ) throws {
            let output = addressBase(outputAddress)
            let value = try progressionValue(at: inputAddress, line: line)
            guard type.supportsIteration,
                  value.type == type,
                  progressionIteratorAddresses[output] == type,
                  progressionIteratorStates[output] == nil
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "progression makeIterator types or storage do not match"
                )
            }
            let stride: Bytecode.Register
            if type.family.usesExplicitStride {
                guard let explicit = value.stride,
                      registerTypes[Int(explicit.rawValue)] == type.stride
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Stride progression has no matching stride value"
                    )
                }
                stride = explicit
            } else {
                guard type.stride == .int64 else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "progression iterator element \(type.element)"
                    )
                }
                stride = try allocate(type: .int64)
                appendInstruction(.constantInteger(result: stride, bitPattern: 1))
            }
            let initial = try allocate(type: .optional(type.element))
            appendInstruction(
                .makeOptionalSome(result: initial, value: value.start)
            )
            let cursorSlot = try allocateStackSlot(
                type: .optional(type.element)
            )
            appendInstruction(
                .storeStack(
                    slot: cursorSlot,
                    source: initial,
                    mode: .initialize
                )
            )
            progressionIteratorStates[output] = .init(
                type: type,
                end: value.end,
                stride: stride,
                cursorSlot: cursorSlot
            )
            voidValues.insert(resultToken)
        }

        func lowerProgressionIteratorNext(
            type: CanonicalSIL.Progression.SequenceType,
            resultAddress: String,
            iteratorAddress: String,
            resultToken: String,
            line: Int
        ) throws {
            let iterator = addressBase(iteratorAddress)
            guard type.supportsIteration,
                  stackType(at: resultAddress) == .optional(type.element),
                  progressionIteratorAddresses[iterator] == type,
                  let state = progressionIteratorStates[iterator],
                  state.type == type
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "progression iterator next types or storage do not match"
                )
            }
            let result = try allocate(type: .optional(type.element))
            appendInstruction(
                .progressionNext(
                    result: result,
                    cursorSlot: state.cursorSlot,
                    end: state.end,
                    stride: state.stride,
                    boundary: type.family.boundary
                )
            )
            try storeConstructedValue(
                result,
                at: resultAddress,
                mode: .initialize
            )
            voidValues.insert(resultToken)
        }

        func roundingOperation(
            for rule: CompilerEnumCase
        ) throws -> Bytecode.FloatUnaryOperation {
            guard rule.typeName == "FloatingPointRoundingRule" else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "rounding operation references an unrelated compiler enum"
                )
            }
            return switch rule.caseName {
            case "down": .roundDown
            case "up": .roundUp
            case "towardZero": .roundTowardZero
            case "awayFromZero": .roundAwayFromZero
            case "toNearestOrAwayFromZero": .roundToNearestOrAwayFromZero
            case "toNearestOrEven": .roundToNearestOrEven
            default:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "unknown FloatingPointRoundingRule case \(rule.caseName)"
                )
            }
        }

        func emitScalarLiteral(
            _ literal: CanonicalSIL.ScalarIntrinsic.StaticValue.Literal
        ) throws -> Bytecode.Register {
            switch literal {
            case let .integer(type, bitPattern):
                let result = try allocate(type: type)
                appendInstruction(
                    .constantInteger(result: result, bitPattern: bitPattern)
                )
                return result
            case let .floating(type, bitPattern):
                let result = try allocate(type: type)
                appendInstruction(
                    .constantFloat(result: result, bitPattern: bitPattern)
                )
                return result
            case let .boolean(value):
                let result = try allocate(type: .bool)
                appendInstruction(.constantBool(result: result, value: value))
                return result
            }
        }

        func emitFloatingUnary(
            _ operation: Bytecode.FloatUnaryOperation,
            operand: Bytecode.Register
        ) throws -> Bytecode.Register {
            let type = registerTypes[Int(operand.rawValue)]
            guard case .float = type else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "floating scalar operation has a non-floating operand"
                )
            }
            let result = try allocate(type: type)
            appendInstruction(
                .floatingUnary(
                    result: result,
                    operation: operation,
                    operand: operand
                )
            )
            return result
        }

        func emitFloatingBinary(
            _ operation: Bytecode.FloatBinaryOperation,
            lhs: Bytecode.Register,
            rhs: Bytecode.Register
        ) throws -> Bytecode.Register {
            let type = registerTypes[Int(lhs.rawValue)]
            guard case .float = type,
                  registerTypes[Int(rhs.rawValue)] == type
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "floating binary operation does not use one float type"
                )
            }
            let result = try allocate(type: type)
            appendInstruction(
                .floatingBinary(
                    result: result,
                    operation: operation,
                    lhs: lhs,
                    rhs: rhs
                )
            )
            return result
        }

        func emitFloatingIntegerProperty(
            _ operation: Bytecode.FloatIntegerPropertyOperation,
            operand: Bytecode.Register
        ) throws -> Bytecode.Register {
            guard case let .float(width)
                = registerTypes[Int(operand.rawValue)]
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "floating integer property has a non-floating operand"
                )
            }
            let type: Bytecode.ValueType = switch operation {
            case .exponent, .significandWidth: .int64
            case .exponentBitPattern:
                .integer(bitWidth: 64, signed: false)
            case .significandBitPattern:
                .integer(bitWidth: width, signed: false)
            }
            let result = try allocate(type: type)
            appendInstruction(
                .floatingIntegerProperty(
                    result: result,
                    operation: operation,
                    operand: operand
                )
            )
            return result
        }

        func emitScalarBitCast(
            _ operand: Bytecode.Register,
            to type: Bytecode.ValueType
        ) throws -> Bytecode.Register {
            let source = registerTypes[Int(operand.rawValue)]
            switch (source, type) {
            case let (.integer(sourceWidth, _), .float(targetWidth))
            where sourceWidth == targetWidth:
                break
            case let (.float(sourceWidth), .integer(targetWidth, _))
            where sourceWidth == targetWidth:
                break
            default:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "scalar bit-pattern conversion does not preserve width"
                )
            }
            let result = try allocate(type: type)
            appendInstruction(.scalarBitCast(result: result, operand: operand))
            return result
        }

        func emitIntegerUnary(
            _ operation: Bytecode.IntegerUnaryOperation,
            operand: Bytecode.Register
        ) throws -> Bytecode.Register {
            let type = registerTypes[Int(operand.rawValue)]
            guard case let .integer(width, signed) = type else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "integer scalar operation has a non-integer operand"
                )
            }
            let primitiveType: Bytecode.ValueType = operation == .magnitude
                ? .integer(bitWidth: width, signed: false)
                : type
            if operation == .signum, !signed {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "unsigned integer signum"
                )
            }
            let primitive = try allocate(type: primitiveType)
            appendInstruction(
                .integerUnary(
                    result: primitive,
                    operation: operation,
                    operand: operand
                )
            )
            guard operation == .nonzeroBitCount
                    || operation == .leadingZeroBitCount
                    || operation == .trailingZeroBitCount
            else { return primitive }
            if primitiveType == .int64 { return primitive }
            let result = try allocate(type: .int64)
            let conversion: Bytecode.IntegerConversionOperation
            if width == 64 {
                conversion = .reinterpret
            } else {
                conversion = signed ? .signExtend : .zeroExtend
            }
            appendInstruction(
                .integerConvert(
                    result: result,
                    operation: conversion,
                    value: primitive
                )
            )
            return result
        }

        func lowerScalarIntrinsic(
            _ intrinsic: CanonicalSIL.ScalarIntrinsic,
            resultToken: String,
            genericArguments: String,
            arguments: [String],
            line: Int
        ) throws {
            switch intrinsic {
            case let .staticValue(property):
                guard let metatype = arguments.last,
                      let receiver = scalarMetatypeValues[metatype],
                      arguments.count == 1 || arguments.count == 2
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "scalar static property has unsupported arguments"
                    )
                }
                if !genericArguments.isEmpty,
                   try parseStoredType(genericArguments) != receiver {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "scalar static property specialization disagrees with its metatype"
                    )
                }
                guard let literal = property.literal(for: receiver) else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "scalar static property \(property) on \(receiver)"
                    )
                }
                let value = try emitScalarLiteral(literal)
                if arguments.count == 2 {
                    guard compilerAddressType(arguments[0])
                            == registerTypes[Int(value.rawValue)]
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect scalar static result has the wrong storage type"
                        )
                    }
                    try storeConstructedValue(
                        value,
                        at: arguments[0],
                        mode: .initialize
                    )
                    voidValues.insert(resultToken)
                } else {
                    values[resultToken] = value
                }

            case let .floatingUnary(operation):
                let operand: Bytecode.Register
                let destination: String?
                if arguments.count == 1, genericArguments.isEmpty {
                    operand = try resolve(arguments[0], line: line)
                    destination = nil
                } else if arguments.count == 2, !genericArguments.isEmpty {
                    let type = try parseStoredType(genericArguments)
                    guard compilerAddressType(arguments[0]) == type,
                          stackType(at: arguments[1]) == type,
                          let stored = try copyStoredValue(
                              at: arguments[1],
                              line: line
                          ),
                          registerTypes[Int(stored.rawValue)] == type
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect floating operation does not match its specialization"
                        )
                    }
                    operand = stored
                    destination = arguments[0]
                } else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating scalar operation has unsupported arguments"
                    )
                }
                let result = try emitFloatingUnary(operation, operand: operand)
                if let destination {
                    try storeConstructedValue(
                        result,
                        at: destination,
                        mode: .initialize
                    )
                    voidValues.insert(resultToken)
                } else {
                    values[resultToken] = result
                }

            case let .floatingBinary(operation, form):
                switch form {
                case .instance:
                    guard arguments.count == 3,
                          !genericArguments.isEmpty
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "FloatingPoint binary operation has unsupported arguments"
                        )
                    }
                    let type = try parseStoredType(genericArguments)
                    guard case .float = type,
                          compilerAddressType(arguments[0]) == type,
                          stackType(at: arguments[1]) == type,
                          stackType(at: arguments[2]) == type,
                          let rhs = try copyStoredValue(
                              at: arguments[1],
                              line: line
                          ),
                          let lhs = try copyStoredValue(
                              at: arguments[2],
                              line: line
                          )
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "FloatingPoint binary specialization does not match its storage"
                        )
                    }
                    try storeConstructedValue(
                        try emitFloatingBinary(operation, lhs: lhs, rhs: rhs),
                        at: arguments[0],
                        mode: .initialize
                    )
                    voidValues.insert(resultToken)

                case .mutating:
                    guard genericArguments.isEmpty,
                          arguments.count == 2,
                          let lhs = try copyStoredValue(
                              at: arguments[1],
                              line: line
                          )
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "mutating floating binary operation has unsupported arguments"
                        )
                    }
                    let rhs = try resolve(arguments[0], line: line)
                    try storeConstructedValue(
                        try emitFloatingBinary(operation, lhs: lhs, rhs: rhs),
                        at: arguments[1]
                    )
                    voidValues.insert(resultToken)

                case .staticMember:
                    guard arguments.count == 4,
                          !genericArguments.isEmpty
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "static FloatingPoint binary operation has unsupported arguments"
                        )
                    }
                    let type = try parseStoredType(genericArguments)
                    guard case .float = type,
                          compilerAddressType(arguments[0]) == type,
                          stackType(at: arguments[1]) == type,
                          stackType(at: arguments[2]) == type,
                          scalarMetatypeValues[arguments[3]] == type,
                          let lhs = try copyStoredValue(
                              at: arguments[1],
                              line: line
                          ),
                          let rhs = try copyStoredValue(
                              at: arguments[2],
                              line: line
                          )
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "static FloatingPoint specialization does not match its storage"
                        )
                    }
                    try storeConstructedValue(
                        try emitFloatingBinary(operation, lhs: lhs, rhs: rhs),
                        at: arguments[0],
                        mode: .initialize
                    )
                    voidValues.insert(resultToken)
                }

            case let .floatingPredicate(operation):
                guard genericArguments.isEmpty, arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating predicate has unsupported arguments"
                    )
                }
                let operand = try resolve(arguments[0], line: line)
                guard case .float = registerTypes[Int(operand.rawValue)] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating predicate has a non-floating operand"
                    )
                }
                let result = try allocate(type: .bool)
                values[resultToken] = result
                appendInstruction(
                    .floatingPredicate(
                        result: result,
                        operation: operation,
                        operand: operand
                    )
                )

            case let .floatingBinaryPredicate(operation):
                guard arguments.count == 2,
                      !genericArguments.isEmpty
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating binary predicate has unsupported arguments"
                    )
                }
                let type = try parseStoredType(genericArguments)
                guard case .float = type,
                      stackType(at: arguments[0]) == type,
                      stackType(at: arguments[1]) == type,
                      let rhs = try copyStoredValue(
                          at: arguments[0],
                          line: line
                      ),
                      let lhs = try copyStoredValue(
                          at: arguments[1],
                          line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating binary predicate specialization does not match its storage"
                    )
                }
                let result = try allocate(type: .bool)
                values[resultToken] = result
                appendInstruction(
                    .floatingBinaryPredicate(
                        result: result,
                        operation: operation,
                        lhs: lhs,
                        rhs: rhs
                    )
                )

            case let .floatingIntegerProperty(operation):
                guard genericArguments.isEmpty,
                      arguments.count == 1
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating integer property has unsupported arguments"
                    )
                }
                values[resultToken] = try emitFloatingIntegerProperty(
                    operation,
                    operand: resolve(arguments[0], line: line)
                )

            case let .floatingBitPattern(direction):
                guard genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating bit-pattern operation cannot be generic"
                    )
                }
                switch direction {
                case .extract:
                    guard arguments.count == 1 else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "floating bit-pattern getter has unsupported arguments"
                        )
                    }
                    let operand = try resolve(arguments[0], line: line)
                    guard case let .float(width)
                        = registerTypes[Int(operand.rawValue)]
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "floating bit-pattern getter has a non-floating receiver"
                        )
                    }
                    values[resultToken] = try emitScalarBitCast(
                        operand,
                        to: .integer(bitWidth: width, signed: false)
                    )
                case .initialize:
                    guard arguments.count == 2,
                          let type = scalarMetatypeValues[arguments[1]],
                          case let .float(width) = type
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "floating bit-pattern initializer has unsupported arguments"
                        )
                    }
                    let operand = try resolve(arguments[0], line: line)
                    guard registerTypes[Int(operand.rawValue)]
                            == .integer(bitWidth: width, signed: false)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "floating bit-pattern initializer has a mismatched integer"
                        )
                    }
                    values[resultToken] = try emitScalarBitCast(
                        operand,
                        to: type
                    )
                }

            case .floatingSign:
                guard genericArguments.isEmpty, arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating sign getter has unsupported arguments"
                    )
                }
                let operand = try resolve(arguments[0], line: line)
                guard case .float = registerTypes[Int(operand.rawValue)] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating sign getter has a non-floating operand"
                    )
                }
                let isMinus = try allocate(type: .bool)
                appendInstruction(
                    .floatingPredicate(
                        result: isMinus,
                        operation: .isSignMinus,
                        operand: operand
                    )
                )
                floatingSignValues[resultToken] = isMinus

            case .floatingRoundDefault:
                guard arguments.count == 2, !genericArguments.isEmpty,
                      let operand = try copyStoredValue(
                          at: arguments[1],
                          line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "FloatingPoint.rounded() has unsupported arguments"
                    )
                }
                let type = try parseStoredType(genericArguments)
                guard compilerAddressType(arguments[0]) == type,
                      stackType(at: arguments[1]) == type,
                      registerTypes[Int(operand.rawValue)] == type
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "FloatingPoint.rounded() specialization does not match its storage"
                    )
                }
                let result = try emitFloatingUnary(
                    .roundToNearestOrAwayFromZero,
                    operand: operand
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case .floatingRoundRule:
                guard arguments.count == 3, !genericArguments.isEmpty,
                      let rule = compilerEnumAddressCases[
                          addressBase(arguments[1])
                      ],
                      let operand = try copyStoredValue(
                          at: arguments[2],
                          line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "FloatingPoint.rounded(_:) has unsupported arguments"
                    )
                }
                let type = try parseStoredType(genericArguments)
                guard compilerAddressType(arguments[0]) == type,
                      stackType(at: arguments[2]) == type,
                      registerTypes[Int(operand.rawValue)] == type
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "FloatingPoint.rounded(_:) specialization does not match its storage"
                    )
                }
                let result = try emitFloatingUnary(
                    try roundingOperation(for: rule),
                    operand: operand
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case .floatingRoundSlowPath:
                guard genericArguments.isEmpty, arguments.count == 2,
                      let rule = compilerEnumAddressCases[
                          addressBase(arguments[0])
                      ],
                      let operand = try copyStoredValue(
                          at: arguments[1],
                          line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating round slow path has unsupported arguments"
                    )
                }
                let result = try emitFloatingUnary(
                    try roundingOperation(for: rule),
                    operand: operand
                )
                try storeConstructedValue(result, at: arguments[1])
                voidValues.insert(resultToken)

            case let .integerUnary(operation):
                if genericArguments.isEmpty, arguments.count == 1 {
                    let operand = try resolve(arguments[0], line: line)
                    values[resultToken] = try emitIntegerUnary(
                        operation,
                        operand: operand
                    )
                } else if !genericArguments.isEmpty,
                          arguments.count == 2 {
                    let type = try parseStoredType(genericArguments)
                    guard case .integer = type,
                          compilerAddressType(arguments[0]) == type,
                          stackType(at: arguments[1]) == type,
                          let operand = try copyStoredValue(
                              at: arguments[1],
                              line: line
                          )
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "generic integer unary specialization does not match its storage"
                        )
                    }
                    try storeConstructedValue(
                        try emitIntegerUnary(operation, operand: operand),
                        at: arguments[0],
                        mode: .initialize
                    )
                    voidValues.insert(resultToken)
                } else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer unary operation has unsupported arguments"
                    )
                }

            case .integerIsMultiple:
                guard arguments.count == 2, !genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "BinaryInteger.isMultiple(of:) has unsupported arguments"
                    )
                }
                let type = try parseStoredType(genericArguments)
                guard case .integer = type,
                      stackType(at: arguments[0]) == type,
                      stackType(at: arguments[1]) == type,
                      let divisor = try copyStoredValue(
                          at: arguments[0],
                          line: line
                      ),
                      let value = try copyStoredValue(
                          at: arguments[1],
                          line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "BinaryInteger.isMultiple(of:) specialization does not match its storage"
                    )
                }
                let remainder = try allocate(type: type)
                let overflow = try allocate(type: .bool)
                appendInstruction(
                    .checkedBinary(
                        result: remainder,
                        overflow: overflow,
                        operation: .remainder,
                        lhs: value,
                        rhs: divisor
                    )
                )
                let zero = try allocate(type: type)
                appendInstruction(
                    .constantInteger(result: zero, bitPattern: 0)
                )
                let result = try allocate(type: .bool)
                values[resultToken] = result
                appendInstruction(
                    .compare(
                        result: result,
                        predicate: .equal,
                        lhs: remainder,
                        rhs: zero
                    )
                )

            case .integerQuotientAndRemainder:
                guard arguments.count == 4, !genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "BinaryInteger.quotientAndRemainder(dividingBy:) has unsupported arguments"
                    )
                }
                let type = try parseStoredType(genericArguments)
                guard case .integer = type,
                      compilerAddressType(arguments[0]) == type,
                      compilerAddressType(arguments[1]) == type,
                      stackType(at: arguments[2]) == type,
                      stackType(at: arguments[3]) == type,
                      let divisor = try copyStoredValue(
                          at: arguments[2],
                          line: line
                      ),
                      let value = try copyStoredValue(
                          at: arguments[3],
                          line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "BinaryInteger quotient/remainder specialization does not match its storage"
                    )
                }
                let zero = try allocate(type: type)
                appendInstruction(
                    .constantInteger(result: zero, bitPattern: 0)
                )
                let dividesByZero = try allocate(type: .bool)
                appendInstruction(
                    .compare(
                        result: dividesByZero,
                        predicate: .equal,
                        lhs: divisor,
                        rhs: zero
                    )
                )
                try appendConditionalTrap(
                    condition: dividesByZero,
                    reason: .divisionByZero
                )
                let quotient = try allocate(type: type)
                let quotientOverflow = try allocate(type: .bool)
                appendInstruction(
                    .checkedBinary(
                        result: quotient,
                        overflow: quotientOverflow,
                        operation: .divide,
                        lhs: value,
                        rhs: divisor
                    )
                )
                try appendConditionalTrap(
                    condition: quotientOverflow,
                    reason: .integerOverflow
                )
                let remainder = try allocate(type: type)
                let remainderOverflow = try allocate(type: .bool)
                appendInstruction(
                    .checkedBinary(
                        result: remainder,
                        overflow: remainderOverflow,
                        operation: .remainder,
                        lhs: value,
                        rhs: divisor
                    )
                )
                try appendConditionalTrap(
                    condition: remainderOverflow,
                    reason: .integerOverflow
                )
                try storeConstructedValue(
                    quotient,
                    at: arguments[0],
                    mode: .initialize
                )
                try storeConstructedValue(
                    remainder,
                    at: arguments[1],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case let .integerReportingOverflow(operation):
                guard genericArguments.isEmpty, arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer reporting-overflow operation has unsupported arguments"
                    )
                }
                let rhs = try resolve(arguments[0], line: line)
                let lhs = try resolve(arguments[1], line: line)
                let type = registerTypes[Int(lhs.rawValue)]
                guard case .integer = type,
                      registerTypes[Int(rhs.rawValue)] == type
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer reporting-overflow operands do not match"
                    )
                }
                let partial = try allocate(type: type)
                let overflow = try allocate(type: .bool)
                appendInstruction(
                    .checkedBinary(
                        result: partial,
                        overflow: overflow,
                        operation: operation,
                        lhs: lhs,
                        rhs: rhs
                    )
                )
                let result = try allocate(type: .tuple([type, .bool]))
                values[resultToken] = result
                appendInstruction(
                    .makeTuple(
                        result: result,
                        elements: [partial, overflow]
                    )
                )

            case .integerClampingConversion:
                let specializations = try splitTopLevel(genericArguments)
                    .filter { !$0.isEmpty }
                    .map(parseStoredType)
                guard specializations.count == 2,
                      arguments.count == 3,
                      case .integer = specializations[0],
                      case .integer = specializations[1],
                      compilerAddressType(arguments[0])
                        == specializations[0],
                      stackType(at: arguments[1]) == specializations[1],
                      scalarMetatypeValues[arguments[2]]
                        == specializations[0],
                      let source = try copyStoredValue(
                          at: arguments[1],
                          line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "clamping integer conversion does not match its specialization"
                    )
                }
                let result = try allocate(type: specializations[0])
                appendInstruction(
                    .integerConvert(
                        result: result,
                        operation: .clamp,
                        value: source
                    )
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case .integerFullWidthMultiply:
                guard genericArguments.isEmpty,
                      arguments.count == 2
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "full-width integer multiply has unsupported arguments"
                    )
                }
                let rhs = try resolve(arguments[0], line: line)
                let lhs = try resolve(arguments[1], line: line)
                let type = registerTypes[Int(lhs.rawValue)]
                guard case let .integer(width, _) = type,
                      registerTypes[Int(rhs.rawValue)] == type
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "full-width integer multiply operands do not match"
                    )
                }
                let lowType = Bytecode.ValueType.integer(
                    bitWidth: width,
                    signed: false
                )
                let high = try allocate(type: type)
                let low = try allocate(type: lowType)
                appendInstruction(
                    .integerFullWidthMultiply(
                        high: high,
                        low: low,
                        lhs: lhs,
                        rhs: rhs
                    )
                )
                let result = try allocate(type: .tuple([type, lowType]))
                values[resultToken] = result
                appendInstruction(
                    .makeTuple(result: result, elements: [high, low])
                )

            case .integerFullWidthDivide:
                guard genericArguments.isEmpty,
                      arguments.count == 3
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "full-width integer divide has unsupported arguments"
                    )
                }
                let dividendHigh = try resolve(arguments[0], line: line)
                let dividendLow = try resolve(arguments[1], line: line)
                let divisor = try resolve(arguments[2], line: line)
                let type = registerTypes[Int(divisor.rawValue)]
                guard case let .integer(width, _) = type,
                      registerTypes[Int(dividendHigh.rawValue)] == type,
                      registerTypes[Int(dividendLow.rawValue)]
                        == .integer(bitWidth: width, signed: false)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "full-width integer divide operands do not match"
                    )
                }
                let quotient = try allocate(type: type)
                let remainder = try allocate(type: type)
                appendInstruction(
                    .integerFullWidthDivide(
                        quotient: quotient,
                        remainder: remainder,
                        dividendHigh: dividendHigh,
                        dividendLow: dividendLow,
                        divisor: divisor
                    )
                )
                let result = try allocate(type: .tuple([type, type]))
                values[resultToken] = result
                appendInstruction(
                    .makeTuple(
                        result: result,
                        elements: [quotient, remainder]
                    )
                )
            }
        }

        func lowerCapacityHint(
            capacityToken: String,
            storageToken: String,
            expectedType: Bytecode.ValueType,
            displayName: String,
            resultToken: String,
            line: Int
        ) throws {
            guard compilerAddressType(storageToken) == expectedType else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "\(displayName) storage does not match its specialization"
                )
            }
            let capacity: Bytecode.Register
            if let stored = try copyStoredValue(
                at: capacityToken,
                line: line
            ) {
                capacity = stored
            } else {
                capacity = try resolve(capacityToken, line: line)
            }
            guard registerTypes[Int(capacity.rawValue)] == .int64 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "\(displayName) has unsupported arguments"
                )
            }
            try appendNonnegativePrecondition(
                capacity,
                reason: "\(displayName) must not be negative"
            )
            guard let collection = try borrowStoredValue(
                at: storageToken,
                line: line
            ), registerTypes[Int(collection.register.rawValue)] == expectedType
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "\(displayName) has unsupported arguments"
                )
            }
            if let owner = collection.temporaryOwner {
                appendInstruction(.destroyValue(owner))
            }
            // Capacity is not observable through the supported collection
            // APIs. Validate Swift's precondition while retaining immutable
            // VM value storage.
            voidValues.insert(resultToken)
        }

        func appendNonnegativePrecondition(
            _ value: Bytecode.Register,
            reason: String
        ) throws {
            guard registerTypes[Int(value.rawValue)] == .int64 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "nonnegative precondition requires Int"
                )
            }
            let zero = try allocate(type: .int64)
            appendInstruction(.constantInteger(result: zero, bitPattern: 0))
            let isNegative = try allocate(type: .bool)
            appendInstruction(
                .compare(
                    result: isNegative,
                    predicate: .lessThan,
                    lhs: value,
                    rhs: zero
                )
            )
            try appendConditionalTrap(
                condition: isNegative,
                reason: .explicit(reason)
            )
        }

        func lowerCollectionIntrinsic(
            _ intrinsic: CanonicalSIL.CollectionIntrinsic,
            resultToken: String,
            genericArguments: String,
            arguments: [String],
            line: Int
        ) throws {
            func materialize(
                _ token: String,
                as expected: Bytecode.ValueType
            ) throws -> Bytecode.Register {
                let value = if let stored = try copyStoredValue(
                    at: token,
                    line: line
                ) {
                    stored
                } else {
                    try resolve(token, line: line)
                }
                guard registerTypes[Int(value.rawValue)] == expected else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "collection operand does not match its specialization"
                    )
                }
                return value
            }

            func emitArrayCount(
                _ array: Bytecode.Register
            ) throws -> Bytecode.Register {
                guard case .array = registerTypes[Int(array.rawValue)] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array index operation has a non-Array operand"
                    )
                }
                let count = try allocate(type: .int64)
                appendInstruction(.arrayCount(result: count, array: array))
                return count
            }

            func emitCheckedIndexArithmetic(
                _ operation: Bytecode.BinaryOperation,
                _ lhs: Bytecode.Register,
                _ rhs: Bytecode.Register
            ) throws -> Bytecode.Register {
                let result = try allocate(type: .int64)
                let overflow = try allocate(type: .bool)
                appendInstruction(
                    .checkedBinary(
                        result: result,
                        overflow: overflow,
                        operation: operation,
                        lhs: lhs,
                        rhs: rhs
                    )
                )
                try appendConditionalTrap(
                    condition: overflow,
                    reason: .integerOverflow
                )
                return result
            }

            switch intrinsic {
            case let .equality(container):
                guard arguments.count == 3 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "collection equality has unsupported arguments"
                    )
                }
                let type: Bytecode.ValueType
                switch container {
                case .array:
                    let element = try parseStoredType(genericArguments)
                    guard element.isVMEquatable,
                          arrayMetatypeValues[arguments[2]] == element
                    else {
                        throw CanonicalSIL.LoweringError.unsupportedType(
                            "Array equality element \(element)"
                        )
                    }
                    type = .array(element)
                case .dictionary:
                    let types = try parseDictionaryGenericArguments(
                        genericArguments
                    )
                    guard types.key.isVMHashable,
                          types.value.isVMEquatable,
                          dictionaryMetatypeValues[arguments[2]]?.0
                            == types.key,
                          dictionaryMetatypeValues[arguments[2]]?.1
                            == types.value
                    else {
                        throw CanonicalSIL.LoweringError.unsupportedType(
                            "Dictionary equality specialization"
                        )
                    }
                    type = .dictionary(
                        key: types.key,
                        value: types.value
                    )
                }
                let lhs = try materialize(arguments[0], as: type)
                let rhs = try materialize(arguments[1], as: type)
                let result = try allocate(type: .bool)
                values[resultToken] = result
                appendInstruction(
                    .compare(
                        result: result,
                        predicate: .equal,
                        lhs: lhs,
                        rhs: rhs
                    )
                )

            case let .search(operation):
                guard arguments.count == 3 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Collection index search has unsupported arguments"
                    )
                }
                let collection = try parseType(genericArguments)
                guard case let .array(element) = collection,
                      element.isVMEquatable,
                      compilerAddressType(arguments[0]) == .optional(.int64),
                      stackType(at: arguments[1]) == element,
                      stackType(at: arguments[2]) == collection
                else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Collection index search specialization \(collection)"
                    )
                }
                let needle = try materialize(arguments[1], as: element)
                let array = try materialize(arguments[2], as: collection)
                let result = try allocate(type: .optional(.int64))
                appendInstruction(
                    .arraySearch(
                        result: result,
                        operation: operation,
                        array: array,
                        value: needle
                    )
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case let .extremum(operation):
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Sequence extremum has unsupported arguments"
                    )
                }
                let sequence = try parseType(genericArguments)
                guard case let .array(element) = sequence,
                      element.isVMComparable,
                      compilerAddressType(arguments[0]) == .optional(element),
                      stackType(at: arguments[1]) == sequence
                else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Sequence extremum specialization \(sequence)"
                    )
                }
                let array = try materialize(arguments[1], as: sequence)
                let result = try allocate(type: .optional(element))
                appendInstruction(
                    .arrayExtremum(
                        result: result,
                        operation: operation,
                        array: array
                    )
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case let .relation(operation):
                let specializations = try splitTopLevel(genericArguments)
                    .filter { !$0.isEmpty }
                    .map(parseType)
                guard specializations.count == 2,
                      arguments.count == 2,
                      specializations[0] == specializations[1],
                      case let .array(element) = specializations[0]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Sequence relation has unsupported specializations"
                    )
                }
                let supportsElementOperation = switch operation {
                case .elementsEqual, .startsWith: element.isVMEquatable
                case .lexicographicallyPrecedes: element.isVMComparable
                }
                guard supportsElementOperation,
                      stackType(at: arguments[0]) == specializations[0],
                      stackType(at: arguments[1]) == specializations[0]
                else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Sequence relation element \(element)"
                    )
                }
                let rhs = try materialize(
                    arguments[0],
                    as: specializations[0]
                )
                let lhs = try materialize(
                    arguments[1],
                    as: specializations[0]
                )
                let result = try allocate(type: .bool)
                values[resultToken] = result
                appendInstruction(
                    .arrayRelation(
                        result: result,
                        operation: operation,
                        lhs: lhs,
                        rhs: rhs
                    )
                )

            case let .adapter(.transform(operation)):
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "collection adapter has unsupported arguments"
                    )
                }
                let sourceType = try parseType(genericArguments)
                guard case let .array(element) = sourceType else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "collection adapter source \(sourceType)"
                    )
                }
                let resultType: Bytecode.ValueType = switch operation {
                case .reversed:
                    sourceType
                case .enumerated:
                    .array(.tuple([.int64, element]))
                }
                guard compilerAddressType(arguments[0]) == resultType,
                      stackType(at: arguments[1]) == sourceType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "collection adapter storage does not match its specialization"
                    )
                }
                let source = try materialize(arguments[1], as: sourceType)
                let result = try allocate(type: resultType)
                appendInstruction(
                    .arrayAdapter(
                        result: result,
                        operation: operation,
                        array: source
                    )
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case .adapter(.arrayFromSequence):
                let specializations = try splitTopLevel(genericArguments)
                    .filter { !$0.isEmpty }
                    .map(parseType)
                guard specializations.count == 2,
                      arguments.count == 2,
                      case let .array(sourceElement) = specializations[1],
                      ValueRepresentation.storable(specializations[0])
                        == sourceElement,
                      arrayMetatypeValues[arguments[1]] == sourceElement,
                      stackType(at: arguments[0]) == specializations[1]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array sequence initializer specialization does not match"
                    )
                }
                values[resultToken] = try materialize(
                    arguments[0],
                    as: specializations[1]
                )

            case let .adapter(.arrayRepeat(hasMetatype)):
                guard arguments.count == 3 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "repeated collection has unsupported arguments"
                    )
                }
                let element = try parseStoredType(genericArguments)
                let valueIndex = hasMetatype ? 0 : 1
                let countIndex = hasMetatype ? 1 : 2
                if hasMetatype,
                   arrayMetatypeValues[arguments[2]] != element {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array(repeating:) metatype does not match Element"
                    )
                }
                let value = try materialize(arguments[valueIndex], as: element)
                let count = try materialize(arguments[countIndex], as: .int64)
                let result = try allocate(type: .array(element))
                appendInstruction(
                    .arrayRepeat(result: result, value: value, count: count)
                )
                if hasMetatype {
                    values[resultToken] = result
                } else {
                    guard compilerAddressType(arguments[0]) == .array(element)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "repeatElement output does not match Element"
                        )
                    }
                    try storeConstructedValue(
                        result,
                        at: arguments[0],
                        mode: .initialize
                    )
                    voidValues.insert(resultToken)
                }

            case let .adapter(.subsequence(operation)):
                guard arguments.count == 3 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "collection subsequence has unsupported arguments"
                    )
                }
                let collection = try parseType(genericArguments)
                let normalizedSpelling = genericArguments
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingPrefix("$")
                let isConcreteArray = ["Array<", "Swift.Array<"]
                    .contains(where: normalizedSpelling.hasPrefix)
                let usesConcreteIndex = switch operation {
                case .prefixUpTo, .prefixThrough, .suffixFrom: true
                case .dropFirst, .dropLast, .prefix, .suffix: false
                }
                guard case .array = collection,
                      !usesConcreteIndex || isConcreteArray,
                      compilerAddressType(arguments[0]) == collection,
                      stackType(at: arguments[2]) == collection
                else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "collection subsequence specialization \(genericArguments)"
                    )
                }
                let bound = try materialize(arguments[1], as: .int64)
                let source = try materialize(arguments[2], as: collection)
                let result = try allocate(type: collection)
                appendInstruction(
                    .arraySubsequence(
                        result: result,
                        operation: operation,
                        array: source,
                        bound: bound
                    )
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case .adapter(.rangeSlice):
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array range subscript has unsupported arguments"
                    )
                }
                let element = try parseStoredType(genericArguments)
                guard let range = progressionValues[arguments[0]],
                      range.type == .init(family: .range, element: .int64),
                      range.stride == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array range subscript requires Range<Int>"
                    )
                }
                let source = try materialize(
                    arguments[1],
                    as: .array(element)
                )
                let result = try allocate(type: .array(element))
                appendInstruction(
                    .arrayRangeSlice(
                        result: result,
                        array: source,
                        lowerBound: range.start,
                        upperBound: range.end
                    )
                )
                if !hasFutureSemanticUse(
                    of: arguments[0],
                    after: currentSILLineIndex
                ) {
                    progressionValues.removeValue(forKey: arguments[0])
                }
                values[resultToken] = result

            case .adapter(.zip):
                let sequences = try splitTopLevel(genericArguments)
                    .filter { !$0.isEmpty }
                    .map(parseType)
                guard sequences.count == 2,
                      arguments.count == 3,
                      case let .array(lhsElement) = sequences[0],
                      case let .array(rhsElement) = sequences[1]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "zip requires two supported sequence specializations"
                    )
                }
                let resultType: Bytecode.ValueType = .array(
                    .tuple([lhsElement, rhsElement])
                )
                guard compilerAddressType(arguments[0]) == resultType,
                      stackType(at: arguments[1]) == sequences[0],
                      stackType(at: arguments[2]) == sequences[1]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "zip storage does not match its sequence elements"
                    )
                }
                let lhs = try materialize(arguments[1], as: sequences[0])
                let rhs = try materialize(arguments[2], as: sequences[1])
                let result = try allocate(type: resultType)
                appendInstruction(
                    .arrayZip(result: result, lhs: lhs, rhs: rhs)
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case let .adapter(.joined(hasSeparator)):
                let sequences = try splitTopLevel(genericArguments)
                    .filter { !$0.isEmpty }
                    .map(parseType)
                let expectedSpecializations = hasSeparator ? 2 : 1
                let expectedArguments = hasSeparator ? 3 : 2
                guard sequences.count == expectedSpecializations,
                      arguments.count == expectedArguments,
                      case let .array(.array(element)) = sequences[0]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "joined requires an Array-backed nested sequence"
                    )
                }
                let resultType: Bytecode.ValueType = .array(element)
                let sourceIndex = hasSeparator ? 2 : 1
                guard compilerAddressType(arguments[0]) == resultType,
                      stackType(at: arguments[sourceIndex]) == sequences[0]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "joined storage does not match its nested sequence"
                    )
                }
                let separator: Bytecode.Register?
                if hasSeparator {
                    guard sequences[1] == resultType,
                          stackType(at: arguments[1]) == resultType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "joined separator does not match nested Element"
                        )
                    }
                    separator = try materialize(arguments[1], as: resultType)
                } else {
                    separator = nil
                }
                let source = try materialize(
                    arguments[sourceIndex],
                    as: sequences[0]
                )
                let result = try allocate(type: resultType)
                appendInstruction(
                    .arrayJoined(
                        result: result,
                        arrays: source,
                        separator: separator
                    )
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case let .arrayIndex(operation):
                switch operation {
                case .start, .end:
                    guard arguments.count == 1 else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array boundary index has unsupported arguments"
                        )
                    }
                    let element = try parseStoredType(genericArguments)
                    let array = try materialize(
                        arguments[0],
                        as: .array(element)
                    )
                    let result: Bytecode.Register
                    switch operation {
                    case .start:
                        result = try allocate(type: .int64)
                        appendInstruction(
                            .constantInteger(result: result, bitPattern: 0)
                        )
                    case .end:
                        result = try emitArrayCount(array)
                    case .distance, .indices, .after, .before, .offsetBy,
                         .offsetByLimited:
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array index dispatch is inconsistent"
                        )
                    }
                    values[resultToken] = result

                case .distance:
                    guard arguments.count == 3 else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array distance has unsupported arguments"
                        )
                    }
                    let element = try parseStoredType(genericArguments)
                    let from = try materialize(arguments[0], as: .int64)
                    let to = try materialize(arguments[1], as: .int64)
                    _ = try materialize(
                        arguments[2],
                        as: .array(element)
                    )
                    let result = try emitCheckedIndexArithmetic(
                        .subtract,
                        to,
                        from
                    )
                    values[resultToken] = result

                case .indices:
                    guard arguments.count == 2 else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.indices has unsupported arguments"
                        )
                    }
                    let collection = try parseType(genericArguments)
                    guard case .array = collection else {
                        throw CanonicalSIL.LoweringError.unsupportedType(
                            "Array.indices specialization \(collection)"
                        )
                    }
                    let output = addressBase(arguments[0])
                    let range = CanonicalSIL.Progression.SequenceType(
                        family: .range,
                        element: .int64
                    )
                    guard progressionAddresses[output] == range,
                          stackType(at: arguments[1]) == collection
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.indices storage does not match Range<Int>"
                        )
                    }
                    let array = try materialize(arguments[1], as: collection)
                    let start = try allocate(type: .int64)
                    appendInstruction(
                        .constantInteger(result: start, bitPattern: 0)
                    )
                    progressionAddressValues[output] = .init(
                        type: range,
                        start: start,
                        end: try emitArrayCount(array),
                        stride: nil
                    )
                    voidValues.insert(resultToken)

                case .after, .before:
                    guard arguments.count == 2 else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array index movement has unsupported arguments"
                        )
                    }
                    let element = try parseStoredType(genericArguments)
                    let index = try materialize(arguments[0], as: .int64)
                    _ = try materialize(
                        arguments[1],
                        as: .array(element)
                    )
                    let one = try allocate(type: .int64)
                    appendInstruction(
                        .constantInteger(result: one, bitPattern: 1)
                    )
                    let arithmetic: Bytecode.BinaryOperation = operation == .after
                        ? .add
                        : .subtract
                    values[resultToken] = try emitCheckedIndexArithmetic(
                        arithmetic,
                        index,
                        one
                    )

                case .offsetBy, .offsetByLimited:
                    let expectedCount = operation == .offsetBy ? 3 : 4
                    guard arguments.count == expectedCount else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array offset index has unsupported arguments"
                        )
                    }
                    let element = try parseStoredType(genericArguments)
                    let index = try materialize(arguments[0], as: .int64)
                    let distance = try materialize(arguments[1], as: .int64)
                    let arrayArgument = operation == .offsetBy ? 2 : 3
                    _ = try materialize(
                        arguments[arrayArgument],
                        as: .array(element)
                    )
                    guard operation == .offsetByLimited else {
                        values[resultToken] = try emitCheckedIndexArithmetic(
                            .add,
                            index,
                            distance
                        )
                        break
                    }

                    let limit = try materialize(arguments[2], as: .int64)
                    let destination = try allocate(type: .int64)
                    let overflow = try allocate(type: .bool)
                    appendInstruction(
                        .checkedBinary(
                            result: destination,
                            overflow: overflow,
                            operation: .add,
                            lhs: index,
                            rhs: distance
                        )
                    )
                    let zero = try allocate(type: .int64)
                    appendInstruction(
                        .constantInteger(result: zero, bitPattern: 0)
                    )

                    func predicate(
                        _ comparison: Bytecode.ComparisonPredicate,
                        _ lhs: Bytecode.Register,
                        _ rhs: Bytecode.Register
                    ) throws -> Bytecode.Register {
                        let result = try allocate(type: .bool)
                        appendInstruction(
                            .compare(
                                result: result,
                                predicate: comparison,
                                lhs: lhs,
                                rhs: rhs
                            )
                        )
                        return result
                    }

                    func conjunction(
                        _ lhs: Bytecode.Register,
                        _ rhs: Bytecode.Register
                    ) throws -> Bytecode.Register {
                        let result = try allocate(type: .bool)
                        appendInstruction(
                            .booleanBinary(
                                result: result,
                                operation: .and,
                                lhs: lhs,
                                rhs: rhs
                            )
                        )
                        return result
                    }

                    func disjunction(
                        _ lhs: Bytecode.Register,
                        _ rhs: Bytecode.Register
                    ) throws -> Bytecode.Register {
                        let result = try allocate(type: .bool)
                        appendInstruction(
                            .booleanBinary(
                                result: result,
                                operation: .or,
                                lhs: lhs,
                                rhs: rhs
                            )
                        )
                        return result
                    }

                    // A limit constrains movement only when it lies in the
                    // requested direction from the starting index.
                    let movingForward = try predicate(
                        .greaterThan,
                        distance,
                        zero
                    )
                    let forwardLimitApplies = try conjunction(
                        movingForward,
                        predicate(.greaterThanOrEqual, limit, index)
                    )
                    let pastForwardLimit = try predicate(
                        .greaterThan,
                        destination,
                        limit
                    )
                    let positiveExceeded = try conjunction(
                        forwardLimitApplies,
                        disjunction(overflow, pastForwardLimit)
                    )
                    let movingBackward = try predicate(
                        .lessThan,
                        distance,
                        zero
                    )
                    let backwardLimitApplies = try conjunction(
                        movingBackward,
                        predicate(.lessThanOrEqual, limit, index)
                    )
                    let pastBackwardLimit = try predicate(
                        .lessThan,
                        destination,
                        limit
                    )
                    let negativeExceeded = try conjunction(
                        backwardLimitApplies,
                        disjunction(overflow, pastBackwardLimit)
                    )
                    let limitApplies = try disjunction(
                        forwardLimitApplies,
                        backwardLimitApplies
                    )
                    let trueValue = try allocate(type: .bool)
                    appendInstruction(
                        .constantBool(result: trueValue, value: true)
                    )
                    let limitDoesNotApply = try allocate(type: .bool)
                    appendInstruction(
                        .booleanBinary(
                            result: limitDoesNotApply,
                            operation: .xor,
                            lhs: limitApplies,
                            rhs: trueValue
                        )
                    )
                    let unboundedOverflow = try conjunction(
                        overflow,
                        limitDoesNotApply
                    )
                    try appendConditionalTrap(
                        condition: unboundedOverflow,
                        reason: .integerOverflow
                    )
                    let exceeded = try disjunction(
                        positiveExceeded,
                        negativeExceeded
                    )
                    let some = try allocate(type: .optional(.int64))
                    appendInstruction(
                        .makeOptionalSome(result: some, value: destination)
                    )
                    let none = try allocate(type: .optional(.int64))
                    appendInstruction(.makeOptionalNone(result: none))
                    let result = try allocate(type: .optional(.int64))
                    appendInstruction(
                        .select(
                            result: result,
                            condition: exceeded,
                            trueValue: none,
                            falseValue: some
                        )
                    )
                    values[resultToken] = result
                }

            case let .arrayEdit(operation):
                let specializations = try splitTopLevel(genericArguments)
                    .filter { !$0.isEmpty }
                    .map(parseType)
                let specialization = try operation.resolveSpecialization(
                    specializations
                )
                let arrayType = specialization.array
                let element = specialization.element

                func borrowArray(
                    at token: String
                ) throws -> BorrowedStoredValue {
                    let borrowed: BorrowedStoredValue
                    if let stored = try borrowStoredValue(
                        at: token,
                        line: line
                    ) {
                        borrowed = stored
                    } else {
                        borrowed = .init(
                            register: try resolve(token, line: line),
                            temporaryOwner: nil
                        )
                    }
                    guard registerTypes[Int(borrowed.register.rawValue)]
                            == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array edit operand does not match its specialization"
                        )
                    }
                    return borrowed
                }

                func destroyTemporaryOwners(
                    _ values: [BorrowedStoredValue]
                ) {
                    var destroyed = Set<Bytecode.Register>()
                    for owner in values.compactMap(\.temporaryOwner)
                    where destroyed.insert(owner).inserted {
                        appendInstruction(.destroyValue(owner))
                    }
                }

                func integerConstant(
                    _ bitPattern: UInt64
                ) throws -> Bytecode.Register {
                    let result = try allocate(type: .int64)
                    appendInstruction(
                        .constantInteger(
                            result: result,
                            bitPattern: bitPattern
                        )
                    )
                    return result
                }

                func emptyArray() throws -> Bytecode.Register {
                    let result = try allocate(type: arrayType)
                    appendInstruction(.makeArray(result: result, elements: []))
                    return result
                }

                func replace(
                    _ array: Bytecode.Register,
                    from lowerBound: Bytecode.Register,
                    to upperBound: Bytecode.Register,
                    with replacement: Bytecode.Register
                ) throws -> Bytecode.Register {
                    let result = try allocate(type: arrayType)
                    appendInstruction(
                        .arrayReplaceSubrange(
                            result: result,
                            array: array,
                            lowerBound: lowerBound,
                            upperBound: upperBound,
                            replacement: replacement
                        )
                    )
                    return result
                }

                func destroyLinearTemporary(_ value: Bytecode.Register) {
                    if registerTypes[Int(value.rawValue)]
                        .requiresLinearOwnership {
                        appendInstruction(.destroyValue(value))
                    }
                }

                func rangeValue(
                    at token: String
                ) throws -> CanonicalSIL.Progression.Value {
                    let isDirect = progressionValues[token] != nil
                    let value = if let direct = progressionValues[token] {
                        direct
                    } else {
                        try progressionValue(at: token, line: line)
                    }
                    guard value.type == .init(
                        family: .range,
                        element: .int64
                    ), value.stride == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array range edit requires Range<Int>"
                        )
                    }
                    if isDirect, !hasFutureSemanticUse(
                        of: token,
                        after: currentSILLineIndex
                    ) {
                        progressionValues.removeValue(forKey: token)
                    }
                    return value
                }

                switch operation {
                case .concatenating:
                    guard arguments.count == 3,
                          arrayMetatypeValues[arguments[2]] == element
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array concatenation has unsupported arguments"
                        )
                    }
                    let lhs = try borrowArray(at: arguments[0])
                    let rhs = try borrowArray(at: arguments[1])
                    let end = try emitArrayCount(lhs.register)
                    let result = try replace(
                        lhs.register,
                        from: end,
                        to: end,
                        with: rhs.register
                    )
                    destroyTemporaryOwners([lhs, rhs])
                    values[resultToken] = result

                case .concatenateInPlace, .appendContents:
                    guard arguments.count == (operation == .concatenateInPlace
                        ? 3 : 2)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array append-contents edit has unsupported arguments"
                        )
                    }
                    let destinationToken = operation == .concatenateInPlace
                        ? arguments[0] : arguments[1]
                    let sourceToken = operation == .concatenateInPlace
                        ? arguments[1] : arguments[0]
                    if operation == .concatenateInPlace,
                       arrayMetatypeValues[arguments[2]] != element {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array += metatype does not match Element"
                        )
                    }
                    guard compilerAddressType(destinationToken) == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array append-contents destination has the wrong type"
                        )
                    }
                    let destination = try borrowArray(at: destinationToken)
                    let source = try borrowArray(at: sourceToken)
                    let end = try emitArrayCount(destination.register)
                    let result = try replace(
                        destination.register,
                        from: end,
                        to: end,
                        with: source.register
                    )
                    destroyTemporaryOwners([destination, source])
                    try storeConstructedValue(
                        result,
                        at: destinationToken,
                        mode: .assign
                    )
                    voidValues.insert(resultToken)

                case .insertElement:
                    guard arguments.count == 3,
                          compilerAddressType(arguments[2]) == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.insert has unsupported arguments"
                        )
                    }
                    let value = try materializeOwnedValue(
                        at: arguments[0],
                        line: line
                    )
                    guard registerTypes[Int(value.rawValue)] == element else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.insert value does not match Element"
                        )
                    }
                    let singleton = try allocate(type: arrayType)
                    appendInstruction(
                        .makeArray(result: singleton, elements: [value])
                    )
                    let index = try materialize(arguments[1], as: .int64)
                    let destination = try borrowArray(at: arguments[2])
                    let result = try replace(
                        destination.register,
                        from: index,
                        to: index,
                        with: singleton
                    )
                    destroyLinearTemporary(singleton)
                    destroyTemporaryOwners([destination])
                    try storeConstructedValue(
                        result,
                        at: arguments[2],
                        mode: .assign
                    )
                    voidValues.insert(resultToken)

                case .insertContents:
                    guard arguments.count == 3,
                          compilerAddressType(arguments[2]) == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "insert(contentsOf:at:) has unsupported arguments"
                        )
                    }
                    let contents = try borrowArray(at: arguments[0])
                    let index = try materialize(arguments[1], as: .int64)
                    let destination = try borrowArray(at: arguments[2])
                    let result = try replace(
                        destination.register,
                        from: index,
                        to: index,
                        with: contents.register
                    )
                    destroyTemporaryOwners([contents, destination])
                    try storeConstructedValue(
                        result,
                        at: arguments[2],
                        mode: .assign
                    )
                    voidValues.insert(resultToken)

                case .replaceSubrange:
                    guard arguments.count == 3,
                          compilerAddressType(arguments[2]) == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.replaceSubrange has unsupported arguments"
                        )
                    }
                    let bounds = try rangeValue(at: arguments[0])
                    let replacement = try borrowArray(at: arguments[1])
                    let destination = try borrowArray(at: arguments[2])
                    let result = try replace(
                        destination.register,
                        from: bounds.start,
                        to: bounds.end,
                        with: replacement.register
                    )
                    destroyTemporaryOwners([replacement, destination])
                    try storeConstructedValue(
                        result,
                        at: arguments[2],
                        mode: .assign
                    )
                    voidValues.insert(resultToken)

                case .removeAt, .removeFirst, .removeLast:
                    let expectedCount = operation == .removeAt ? 3 : 2
                    guard arguments.count == expectedCount else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array element removal has unsupported arguments"
                        )
                    }
                    let outputToken = arguments[0]
                    let destinationToken = arguments[expectedCount - 1]
                    guard compilerAddressType(outputToken) == element,
                          compilerAddressType(destinationToken) == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array element removal storage has the wrong type"
                        )
                    }
                    let destination = try borrowArray(at: destinationToken)
                    let index: Bytecode.Register
                    switch operation {
                    case .removeAt:
                        index = try materialize(arguments[1], as: .int64)
                    case .removeFirst:
                        index = try integerConstant(0)
                    case .removeLast:
                        let end = try emitArrayCount(destination.register)
                        index = try emitCheckedIndexArithmetic(
                            .subtract,
                            end,
                            integerConstant(1)
                        )
                    default:
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array removal dispatch is inconsistent"
                        )
                    }
                    let removed = try allocate(type: element)
                    appendInstruction(
                        .arrayGet(
                            result: removed,
                            array: destination.register,
                            index: index
                        )
                    )
                    let one = try integerConstant(1)
                    let upperBound = try emitCheckedIndexArithmetic(
                        .add,
                        index,
                        one
                    )
                    let empty = try emptyArray()
                    let result = try replace(
                        destination.register,
                        from: index,
                        to: upperBound,
                        with: empty
                    )
                    destroyLinearTemporary(empty)
                    destroyTemporaryOwners([destination])
                    try storeConstructedValue(
                        removed,
                        at: outputToken,
                        mode: .initialize
                    )
                    try storeConstructedValue(
                        result,
                        at: destinationToken,
                        mode: .assign
                    )
                    voidValues.insert(resultToken)

                case .removeSubrange:
                    guard arguments.count == 2,
                          compilerAddressType(arguments[1]) == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.removeSubrange has unsupported arguments"
                        )
                    }
                    let bounds = try rangeValue(at: arguments[0])
                    let destination = try borrowArray(at: arguments[1])
                    let empty = try emptyArray()
                    let result = try replace(
                        destination.register,
                        from: bounds.start,
                        to: bounds.end,
                        with: empty
                    )
                    destroyLinearTemporary(empty)
                    destroyTemporaryOwners([destination])
                    try storeConstructedValue(
                        result,
                        at: arguments[1],
                        mode: .assign
                    )
                    voidValues.insert(resultToken)

                case .removeFirstCount, .removeLastCount:
                    guard arguments.count == 2,
                          compilerAddressType(arguments[1]) == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array counted removal has unsupported arguments"
                        )
                    }
                    let count = try materialize(arguments[0], as: .int64)
                    try appendNonnegativePrecondition(
                        count,
                        reason: "Array removal count must not be negative"
                    )
                    let destination = try borrowArray(at: arguments[1])
                    let zero = try integerConstant(0)
                    let end = try emitArrayCount(destination.register)
                    let lowerBound: Bytecode.Register
                    let upperBound: Bytecode.Register
                    if operation == .removeFirstCount {
                        lowerBound = zero
                        upperBound = count
                    } else {
                        lowerBound = try emitCheckedIndexArithmetic(
                            .subtract,
                            end,
                            count
                        )
                        upperBound = end
                    }
                    let empty = try emptyArray()
                    let result = try replace(
                        destination.register,
                        from: lowerBound,
                        to: upperBound,
                        with: empty
                    )
                    destroyLinearTemporary(empty)
                    destroyTemporaryOwners([destination])
                    try storeConstructedValue(
                        result,
                        at: arguments[1],
                        mode: .assign
                    )
                    voidValues.insert(resultToken)

                case .removeAll:
                    guard arguments.count == 2,
                          compilerAddressType(arguments[1]) == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.removeAll has unsupported arguments"
                        )
                    }
                    _ = try materialize(arguments[0], as: .bool)
                    let destination = try borrowArray(at: arguments[1])
                    let result = try emptyArray()
                    destroyTemporaryOwners([destination])
                    try storeConstructedValue(
                        result,
                        at: arguments[1],
                        mode: .assign
                    )
                    voidValues.insert(resultToken)

                case .swapAt:
                    guard arguments.count == 3,
                          compilerAddressType(arguments[2]) == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.swapAt has unsupported arguments"
                        )
                    }
                    let lhsIndex = try materialize(arguments[0], as: .int64)
                    let rhsIndex = try materialize(arguments[1], as: .int64)
                    let destination = try borrowArray(at: arguments[2])
                    let result = try allocate(type: arrayType)
                    appendInstruction(
                        .arraySwap(
                            result: result,
                            array: destination.register,
                            lhsIndex: lhsIndex,
                            rhsIndex: rhsIndex
                        )
                    )
                    destroyTemporaryOwners([destination])
                    try storeConstructedValue(
                        result,
                        at: arguments[2],
                        mode: .assign
                    )
                    voidValues.insert(resultToken)

                case .reserveCapacity:
                    guard arguments.count == 2,
                          compilerAddressType(arguments[1]) == arrayType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.reserveCapacity has unsupported arguments"
                        )
                    }
                    try lowerCapacityHint(
                        capacityToken: arguments[0],
                        storageToken: arguments[1],
                        expectedType: arrayType,
                        displayName: "Array capacity",
                        resultToken: resultToken,
                        line: line
                    )
                }
            }
        }

        /// Selects an existing Dictionary value or evaluates the default
        /// closure lazily. Both the getter and `_modify` coroutine share this
        /// CFG, which keeps autoclosure behavior in ordinary verified closure
        /// control flow and needs no API-specific VM instruction.
        func lowerDictionaryValueOrDefault(
            dictionary: Bytecode.Register,
            key: Bytecode.Register,
            closureToken: String,
            keyType: Bytecode.ValueType,
            valueType: Bytecode.ValueType,
            line: Int
        ) throws -> Bytecode.Register {
            let dictionaryType = Bytecode.ValueType.dictionary(
                key: keyType,
                value: valueType
            )
            let closure = try resolve(closureToken, line: line)
            guard keyType.isVMHashable,
                  registerTypes[Int(dictionary.rawValue)] == dictionaryType,
                  registerTypes[Int(key.rawValue)] == keyType,
                  case let .closure(signature) = registerTypes[
                    Int(closure.rawValue)
                  ], signature.parameters.isEmpty,
                  signature.parameterConventions.isEmpty,
                  signature.result == valueType,
                  !signature.effects.mayThrow,
                  !signature.effects.isAsync
            else {
                throw CanonicalSIL.LoweringError.callSignatureMismatch(
                    line: line,
                    mangledName: "Dictionary.subscript(default:)"
                )
            }

            let lookup = try allocate(type: .optional(valueType))
            let existingTarget = try allocateSyntheticBlockID()
            let defaultTarget = try allocateSyntheticBlockID()
            let mergeTarget = try allocateSyntheticBlockID()
            appendInstruction(
                .dictionaryGet(
                    result: lookup,
                    dictionary: dictionary,
                    key: key
                )
            )
            appendInstruction(
                .switchOptional(
                    optional: lookup,
                    someTarget: existingTarget,
                    noneTarget: defaultTarget
                )
            )
            finishCurrent()

            let existing = try allocate(type: valueType)
            appendSyntheticBlock(
                id: existingTarget,
                parameters: [existing],
                instructions: [
                    .branch(target: mergeTarget, arguments: [existing]),
                ]
            )
            let defaultValue = try allocate(type: valueType)
            appendSyntheticBlock(
                id: defaultTarget,
                instructions: [
                    .closureApply(
                        result: defaultValue,
                        closure: closure,
                        arguments: []
                    ),
                    .branch(target: mergeTarget, arguments: [defaultValue]),
                ]
            )

            let selected = try allocate(type: valueType)
            current = .init(
                id: mergeTarget,
                parameters: [selected],
                instructions: []
            )
            return selected
        }

        /// Completes either the normal or unwind edge of a collection
        /// `_modify` coroutine. The stack slot is path-local at runtime even
        /// though several textual exits share one lowering record.
        func finalizeCollectionElementMutation(
            yieldToken: String,
            line: Int
        ) throws {
            guard let mutation = collectionElementMutations[yieldToken],
                  let access = runtimeAddress(at: yieldToken),
                  isScopedRuntimeAddress(yieldToken),
                  let element = try takeStoredValue(
                    at: yieldToken,
                    line: line
                  ),
                  registerTypes[Int(element.rawValue)] == mutation.elementType
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "collection _modify ended with uninitialized or mismatched element storage"
                )
            }
            appendInstruction(.endAccess(access))

            switch mutation.source {
            case let .array(array, index):
                let updated = try allocate(type: .array(mutation.elementType))
                appendInstruction(
                    .arrayUpdate(
                        result: updated,
                        array: array,
                        index: index,
                        value: element
                    )
                )
                for temporary in [array, element]
                where registerTypes[Int(temporary.rawValue)]
                    .requiresLinearOwnership {
                    appendInstruction(.destroyValue(temporary))
                }
                try storeConstructedValue(
                    updated,
                    at: mutation.collectionAddress,
                    mode: .assign
                )

            case let .dictionaryDefault(
                dictionary,
                key,
                keyType,
                valueType
            ):
                let update = try allocate(type: .optional(valueType))
                appendInstruction(
                    .makeOptionalSome(result: update, value: element)
                )
                let previous = try allocate(type: .optional(valueType))
                let updated = try allocate(
                    type: .dictionary(key: keyType, value: valueType)
                )
                appendInstruction(
                    .dictionarySet(
                        previousValueResult: previous,
                        dictionaryResult: updated,
                        dictionary: dictionary,
                        key: key,
                        value: update
                    )
                )
                for temporary in [dictionary, key, update, previous]
                where registerTypes[Int(temporary.rawValue)]
                    .requiresLinearOwnership {
                    appendInstruction(.destroyValue(temporary))
                }
                try storeConstructedValue(
                    updated,
                    at: mutation.collectionAddress,
                    mode: .assign
                )
            }
        }

        func removeCollectionMutationMetadata(yieldToken: String) {
            collectionElementMutations.removeValue(forKey: yieldToken)
            runtimeStackSlots.removeValue(forKey: yieldToken)
            runtimeAddressValues.removeValue(forKey: yieldToken)
            runtimeAddressPointees.removeValue(forKey: yieldToken)
            scopedRuntimeAddresses.remove(yieldToken)
            stackAddressTypes.removeValue(forKey: yieldToken)
            stackAddressValues.removeValue(forKey: yieldToken)
            values.removeValue(forKey: yieldToken)
        }

        func beginCollectionElementMutation(
            yieldToken: String,
            continuationToken: String,
            initialElement: Bytecode.Register,
            mutation: CollectionElementMutation
        ) throws {
            guard registerTypes[Int(initialElement.rawValue)]
                    == mutation.elementType,
                  collectionElementMutations[yieldToken] == nil,
                  collectionMutationYieldByToken[continuationToken] == nil,
                  stackType(at: yieldToken) == nil
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "collection _modify has mismatched or overlapping access state"
                )
            }
            let slot = try allocateStackSlot(type: mutation.elementType)
            appendInstruction(
                .storeStack(
                    slot: slot,
                    source: initialElement,
                    mode: .initialize
                )
            )
            let address = try allocate(type: .address(mutation.elementType))
            appendInstruction(.stackAddress(result: address, slot: slot))
            let access = try allocate(type: .address(mutation.elementType))
            appendInstruction(
                .beginAccess(
                    result: access,
                    address: address,
                    kind: .modify
                )
            )

            stackAddressTypes[yieldToken] = mutation.elementType
            runtimeStackSlots[yieldToken] = slot
            runtimeAddressValues[yieldToken] = access
            runtimeAddressPointees[yieldToken] = mutation.elementType
            scopedRuntimeAddresses.insert(yieldToken)
            values[yieldToken] = access
            collectionElementMutations[yieldToken] = mutation
            collectionMutationYieldByToken[continuationToken] = yieldToken
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

            func materializeSetOperand(
                _ token: String,
                element expectedElement: Bytecode.ValueType,
                expectedSequence: Bytecode.ValueType? = nil
            ) throws -> Bytecode.Register {
                let source = try materializeOwnedValue(at: token, line: line)
                let sourceType = registerTypes[Int(source.rawValue)]
                if let expectedSequence, sourceType != expectedSequence {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set Sequence specialization does not match its operand"
                    )
                }
                switch sourceType {
                case .set(let element) where element == expectedElement:
                    return source
                case .array(let element) where element == expectedElement:
                    let result = try allocate(type: .set(expectedElement))
                    appendInstruction(.makeSet(result: result, source: source))
                    return result
                default:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Set operations support Array<Element> and Set<Element> sequences"
                    )
                }
            }

            func makeEmptyDictionary(
                key: Bytecode.ValueType,
                value: Bytecode.ValueType
            ) throws -> Bytecode.Register {
                let pairType = Bytecode.ValueType.tuple([key, value])
                let pairs = try allocate(type: .array(pairType))
                appendInstruction(.makeArray(result: pairs, elements: []))
                let result = try allocate(type: .dictionary(key: key, value: value))
                appendInstruction(.makeDictionary(result: result, pairs: pairs))
                if registerTypes[Int(pairs.rawValue)].requiresLinearOwnership {
                    appendInstruction(.destroyValue(pairs))
                }
                return result
            }

            func emitDictionarySet(
                dictionary: Bytecode.Register,
                key: Bytecode.Register,
                update: Bytecode.Register,
                keyType: Bytecode.ValueType,
                valueType: Bytecode.ValueType
            ) throws -> (
                previous: Bytecode.Register,
                updated: Bytecode.Register
            ) {
                let dictionaryType = Bytecode.ValueType.dictionary(
                    key: keyType,
                    value: valueType
                )
                guard registerTypes[Int(dictionary.rawValue)] == dictionaryType,
                      registerTypes[Int(key.rawValue)] == keyType,
                      registerTypes[Int(update.rawValue)] == .optional(valueType)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary update operands do not match its specialization"
                    )
                }
                let previous = try allocate(type: .optional(valueType))
                let updated = try allocate(type: dictionaryType)
                appendInstruction(
                    .dictionarySet(
                        previousValueResult: previous,
                        dictionaryResult: updated,
                        dictionary: dictionary,
                        key: key,
                        value: update
                    )
                )
                return (previous, updated)
            }

            func destroyLinearTemporary(_ register: Bytecode.Register) {
                if registerTypes[Int(register.rawValue)].requiresLinearOwnership {
                    appendInstruction(.destroyValue(register))
                }
            }

            switch intrinsic {
            case let .scalar(scalar):
                try lowerScalarIntrinsic(
                    scalar,
                    resultToken: resultToken,
                    genericArguments: genericArguments,
                    arguments: arguments,
                    line: line
                )
            case let .collection(collection):
                try lowerCollectionIntrinsic(
                    collection,
                    resultToken: resultToken,
                    genericArguments: genericArguments,
                    arguments: arguments,
                    line: line
                )
            case let .ordering(operation) where !operation.usesClosure:
                try lowerNaturalArrayOrdering(
                    operation,
                    resultToken: resultToken,
                    genericArguments: genericArguments,
                    arguments: arguments,
                    line: line
                )
            case let .split(operation) where !operation.usesClosure:
                try lowerSeparatorArraySplit(
                    resultToken: resultToken,
                    genericArguments: genericArguments,
                    argumentText: argumentText,
                    line: line
                )
            case .higherOrder, .ordering, .split, .algebraic:
                throw CanonicalSIL.LoweringError.unsupportedInstruction(
                    line: line,
                    text: "Swift intrinsic requires control-flow lowering"
                )
            case let .progressionConstructor(family):
                guard arguments.count == 4,
                      !genericArguments.isEmpty,
                      family.usesExplicitStride
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "stride constructor has unsupported arguments"
                    )
                }
                let type = CanonicalSIL.Progression.SequenceType(
                    family: family,
                    element: try parseStoredType(genericArguments)
                )
                guard type.supportsIteration,
                      let strideType = type.stride,
                      progressionAddresses[addressBase(arguments[0])] == type,
                      stackType(at: arguments[1]) == type.element,
                      stackType(at: arguments[2]) == type.element,
                      stackType(at: arguments[3]) == strideType,
                      let start = try copyStoredValue(
                          at: arguments[1],
                          line: line
                      ),
                      let end = try copyStoredValue(
                          at: arguments[2],
                          line: line
                      ),
                      let stride = try copyStoredValue(
                          at: arguments[3],
                          line: line
                      ),
                      registerTypes[Int(start.rawValue)] == type.element,
                      registerTypes[Int(end.rawValue)] == type.element,
                      registerTypes[Int(stride.rawValue)] == strideType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "stride constructor specialization does not match its storage"
                    )
                }
                let zero = try allocate(type: strideType)
                switch strideType {
                case .integer:
                    appendInstruction(
                        .constantInteger(result: zero, bitPattern: 0)
                    )
                case .float:
                    appendInstruction(
                        .constantFloat(result: zero, bitPattern: 0)
                    )
                default:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "stride distance \(strideType)"
                    )
                }
                let isZero = try allocate(type: .bool)
                appendInstruction(
                    .compare(
                        result: isZero,
                        predicate: .equal,
                        lhs: stride,
                        rhs: zero
                    )
                )
                try appendConditionalTrap(
                    condition: isZero,
                    reason: .explicit("Stride size must not be zero")
                )
                progressionAddressValues[addressBase(arguments[0])] = .init(
                    type: type,
                    start: start,
                    end: end,
                    stride: stride
                )
                voidValues.insert(resultToken)

            case let .progressionMakeIterator(family):
                guard arguments.count == 2, !genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Stride.makeIterator has unsupported arguments"
                    )
                }
                let type = CanonicalSIL.Progression.SequenceType(
                    family: family,
                    element: try parseStoredType(genericArguments)
                )
                try initializeProgressionIterator(
                    type: type,
                    outputAddress: arguments[0],
                    inputAddress: arguments[1],
                    resultToken: resultToken,
                    line: line
                )

            case let .progressionIteratorNext(family):
                guard arguments.count == 2, !genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Stride iterator next has unsupported arguments"
                    )
                }
                let type = CanonicalSIL.Progression.SequenceType(
                    family: family,
                    element: try parseStoredType(genericArguments)
                )
                try lowerProgressionIteratorNext(
                    type: type,
                    resultAddress: arguments[0],
                    iteratorAddress: arguments[1],
                    resultToken: resultToken,
                    line: line
                )

            case let .rangeContains(family):
                guard arguments.count == 2,
                      !genericArguments.isEmpty,
                      family == .range || family == .closedRange
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Range.contains has unsupported arguments"
                    )
                }
                let element = try parseStoredType(genericArguments)
                let value = try progressionValue(
                    at: arguments[1],
                    line: line
                )
                guard value.type == .init(family: family, element: element),
                      let needle = try copyStoredValue(
                          at: arguments[0],
                          line: line
                      ),
                      registerTypes[Int(needle.rawValue)] == element,
                      registerTypes[Int(value.start.rawValue)] == element,
                      registerTypes[Int(value.end.rawValue)] == element
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Range.contains specialization does not match its operands"
                    )
                }
                let meetsLower = try allocate(type: .bool)
                appendInstruction(
                    .compare(
                        result: meetsLower,
                        predicate: .lessThanOrEqual,
                        lhs: value.start,
                        rhs: needle
                    )
                )
                let meetsUpper = try allocate(type: .bool)
                appendInstruction(
                    .compare(
                        result: meetsUpper,
                        predicate: family == .closedRange
                            ? .lessThanOrEqual
                            : .lessThan,
                        lhs: needle,
                        rhs: value.end
                    )
                )
                let result = try allocate(type: .bool)
                values[resultToken] = result
                appendInstruction(
                    .booleanBinary(
                        result: result,
                        operation: .and,
                        lhs: meetsLower,
                        rhs: meetsUpper
                    )
                )

            case .minimum, .maximum:
                guard arguments.count == 3, !genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Swift min/max has unsupported arguments"
                    )
                }
                let type = try parseType(genericArguments)
                switch type {
                case .integer, .float, .string:
                    break
                default:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "min/max operand \(type)"
                    )
                }
                guard compilerAddressType(arguments[0]) == type,
                      stackType(at: arguments[1]) == type,
                      stackType(at: arguments[2]) == type,
                      let lhs = try copyStoredValue(at: arguments[1], line: line),
                      let rhs = try copyStoredValue(at: arguments[2], line: line),
                      registerTypes[Int(lhs.rawValue)] == type,
                      registerTypes[Int(rhs.rawValue)] == type
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Swift min/max operands do not match their specialization"
                    )
                }
                let condition = try allocate(type: .bool)
                let predicate: Bytecode.ComparisonPredicate = intrinsic == .minimum
                    ? .lessThan
                    : .lessThanOrEqual
                appendInstruction(
                    .compare(
                        result: condition,
                        predicate: predicate,
                        lhs: intrinsic == .minimum ? rhs : lhs,
                        rhs: intrinsic == .minimum ? lhs : rhs
                    )
                )
                let result = try allocate(type: type)
                appendInstruction(
                    .select(
                        result: result,
                        condition: condition,
                        trueValue: rhs,
                        falseValue: lhs
                    )
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case .absoluteValue:
                guard arguments.count == 2, !genericArguments.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Swift abs has unsupported arguments"
                    )
                }
                let type = try parseType(genericArguments)
                guard compilerAddressType(arguments[0]) == type,
                      stackType(at: arguments[1]) == type,
                      let operand = try copyStoredValue(
                        at: arguments[1],
                        line: line
                      ),
                      registerTypes[Int(operand.rawValue)] == type
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Swift abs operand does not match its specialization"
                    )
                }
                let result: Bytecode.Register
                switch type {
                case .integer(_, signed: true):
                    let zero = try allocate(type: type)
                    appendInstruction(.constantInteger(result: zero, bitPattern: 0))
                    let isNegative = try allocate(type: .bool)
                    appendInstruction(
                        .compare(
                            result: isNegative,
                            predicate: .lessThan,
                            lhs: operand,
                            rhs: zero
                        )
                    )
                    let negated = try allocate(type: type)
                    let overflow = try allocate(type: .bool)
                    appendInstruction(
                        .checkedBinary(
                            result: negated,
                            overflow: overflow,
                            operation: .subtract,
                            lhs: zero,
                            rhs: operand
                        )
                    )
                    try appendConditionalTrap(
                        condition: overflow,
                        reason: .integerOverflow
                    )
                    result = try allocate(type: type)
                    appendInstruction(
                        .select(
                            result: result,
                            condition: isNegative,
                            trueValue: negated,
                            falseValue: operand
                        )
                    )
                case .float:
                    result = try allocate(type: type)
                    appendInstruction(
                        .floatingUnary(
                            result: result,
                            operation: .absolute,
                            operand: operand
                        )
                    )
                default:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "abs operand \(type)"
                    )
                }
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case .assertionFailure:
                guard genericArguments.isEmpty,
                      arguments.count == 5,
                      let prefix = staticStringValues[arguments[0]],
                      let message = staticStringValues[arguments[1]],
                      staticStringValues[arguments[2]] != nil,
                      values[arguments[3]] != nil,
                      values[arguments[4]] != nil,
                      !prefix.isEmpty,
                      !message.isEmpty,
                      let blockID = current?.id,
                      unreachableTrapReasons[blockID] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Swift assertion failure has unsupported metadata"
                    )
                }
                // Assertion metadata stays compiler-only, but retain its
                // diagnostic in the trap emitted by the following canonical
                // `unreachable` terminator.
                unreachableTrapReasons[blockID] = trapReason(for: message)
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

            case .stringAppend:
                guard genericArguments.isEmpty,
                      arguments.count == 3,
                      metatypeValues.contains(arguments[2]),
                      compilerAddressType(arguments[0]) == .string,
                      let lhs = try copyStoredValue(
                          at: arguments[0],
                          line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String mutation has unsupported arguments"
                    )
                }
                let rhs = try resolve(arguments[1], line: line)
                guard registerTypes[Int(lhs.rawValue)] == .string,
                      registerTypes[Int(rhs.rawValue)] == .string
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String mutation operands must both be String"
                    )
                }
                let result = try allocate(type: .string)
                appendInstruction(
                    .stringConcat(result: result, lhs: lhs, rhs: rhs)
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .assign
                )
                voidValues.insert(resultToken)

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

            case let .stringTransform(operation):
                guard genericArguments.isEmpty, arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String transform has unsupported arguments"
                    )
                }
                let operand = try resolve(arguments[0], line: line)
                guard registerTypes[Int(operand.rawValue)] == .string else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "String transform operand must be String"
                    )
                }
                let result = try allocate(type: .string)
                values[resultToken] = result
                appendInstruction(
                    .stringTransform(
                        result: result,
                        operation: operation,
                        string: operand
                    )
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
                guard let string = try copyStoredValue(
                    at: arguments[1],
                    line: line
                ) ?? values[arguments[1]],
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
                guard let value = try copyStoredValue(
                    at: arguments[0],
                    line: line
                ) ?? values[arguments[0]] else {
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
                let genericType = try intrinsic == .arrayCount
                    ? parseStoredType(genericArguments)
                    : parseType(genericArguments)
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

            case .arrayEmpty:
                guard arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.init() has unsupported arguments"
                    )
                }
                let element = ValueRepresentation.storable(
                    try parseType(genericArguments)
                )
                guard arrayMetatypeValues[arguments[0]] == element else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.init() metatype does not match Element"
                    )
                }
                let result = try allocate(type: .array(element))
                appendInstruction(.makeArray(result: result, elements: []))
                values[resultToken] = result

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
                let element = try parseStoredType(genericArguments)
                guard registerTypes[Int(index.rawValue)] == .int64,
                      registerTypes[Int(array.rawValue)] == .array(element),
                      outputType == element
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array subscript types do not match"
                    )
                }
                let result = try allocate(type: element)
                appendInstruction(.arrayGet(result: result, array: array, index: index))
                try storeConstructedValue(result, at: arguments[0], mode: .initialize)
                voidValues.insert(resultToken)

            case .arraySubscriptModify:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Array.subscript.modify must be consumed by begin_apply"
                )

            case let .collectionBoundary(operation):
                guard arguments.count == 2, !genericArguments.isEmpty,
                      let outputType = stackType(at: arguments[0])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Collection boundary getter has unsupported arguments"
                    )
                }
                let collectionType = try parseType(genericArguments)
                let result: Bytecode.Register
                switch collectionType {
                case let .array(element):
                    let array = try resolve(arguments[1], line: line)
                    guard registerTypes[Int(array.rawValue)] == collectionType,
                          outputType == .optional(element)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Collection boundary types do not match Array.Element"
                        )
                    }
                    result = try allocate(type: outputType)
                    appendInstruction(
                        .arrayBoundary(
                            result: result,
                            operation: operation,
                            array: array
                        )
                    )
                case let .set(element) where operation == .first:
                    let set = try materializeSetOperand(
                        arguments[1],
                        element: element
                    )
                    guard outputType == .optional(element) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Collection.first types do not match Set.Element"
                        )
                    }
                    let zero = try allocate(type: .int64)
                    appendInstruction(.constantInteger(result: zero, bitPattern: 0))
                    let slot = try allocateStackSlot(type: .int64)
                    appendInstruction(
                        .storeStack(slot: slot, source: zero, mode: .initialize)
                    )
                    result = try allocate(type: outputType)
                    appendInstruction(
                        .collectionNext(
                            result: result,
                            collection: set,
                            indexSlot: slot,
                            direction: .forward
                        )
                    )
                    appendInstruction(.destroyStack(slot))
                default:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Collection boundary operation for \(collectionType)"
                    )
                }
                try storeConstructedValue(result, at: arguments[0], mode: .initialize)
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
                      let arrayType = stackType(at: arguments[1])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.append has unsupported inout arguments"
                    )
                }
                guard let borrowedValue = try borrowStoredValue(
                    at: arguments[0],
                    line: line
                ), let borrowedArray = try borrowStoredValue(
                    at: arguments[1],
                    line: line
                ) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.append references uninitialized storage"
                    )
                }
                let element = try parseStoredType(genericArguments)
                guard valueType == element,
                      registerTypes[
                        Int(borrowedValue.register.rawValue)
                      ] == element,
                      arrayType == .array(element),
                      registerTypes[
                        Int(borrowedArray.register.rawValue)
                      ] == arrayType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.append types do not match Array.Element"
                    )
                }
                let result = try allocate(type: arrayType)
                appendInstruction(
                    .arrayAppend(
                        result: result,
                        array: borrowedArray.register,
                        value: borrowedValue.register
                    )
                )
                for owner in [
                    borrowedValue.temporaryOwner,
                    borrowedArray.temporaryOwner,
                ].compactMap({ $0 }) {
                    appendInstruction(.destroyValue(owner))
                }
                try storeConstructedValue(result, at: arguments[1], mode: .assign)
                voidValues.insert(resultToken)

            case .arrayPopLast:
                guard arguments.count == 2,
                      !genericArguments.isEmpty,
                      let outputType = compilerAddressType(arguments[0]),
                      let arrayType = compilerAddressType(arguments[1])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.popLast has unsupported inout arguments"
                    )
                }
                guard let array = try copyStoredValue(
                    at: arguments[1],
                    line: line
                ) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.popLast references uninitialized storage"
                    )
                }
                let collectionType = try parseType(genericArguments)
                guard case let .array(element) = collectionType,
                      arrayType == collectionType,
                      outputType == .optional(element),
                      registerTypes[Int(array.rawValue)] == collectionType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array.popLast types do not match Array.Element"
                    )
                }
                let removed = try allocate(type: outputType)
                let updated = try allocate(type: collectionType)
                appendInstruction(
                    .arrayPopLast(
                        elementResult: removed,
                        arrayResult: updated,
                        array: array
                    )
                )
                try storeConstructedValue(
                    removed,
                    at: arguments[0],
                    mode: .initialize
                )
                try storeConstructedValue(
                    updated,
                    at: arguments[1],
                    mode: .assign
                )
                voidValues.insert(resultToken)

            case let .collectionMakeIterator(shape):
                if shape == .collection,
                   let type = try progressionSequenceType(genericArguments) {
                    guard arguments.count == 2 else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Range.makeIterator has unsupported arguments"
                        )
                    }
                    try initializeProgressionIterator(
                        type: type,
                        outputAddress: arguments[0],
                        inputAddress: arguments[1],
                        resultToken: resultToken,
                        line: line
                    )
                    return
                }
                guard arguments.count == 2,
                      !genericArguments.isEmpty,
                      let collectionType = try? normalizedIteratorCollectionType(
                          shape,
                          genericArguments: genericArguments
                      ),
                      case let .array(element) = collectionType,
                      pendingArrayIteratorTypes[addressBase(arguments[0])] == element,
                      stackType(at: arguments[1]) == collectionType,
                      let array = try takeStoredValue(
                        at: arguments[1],
                        line: line
                      ),
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
                appendInstruction(.constantInteger(result: zero, bitPattern: 0))
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

            case let .indexingIteratorNext(shape):
                if shape == .collection,
                   let type = try progressionSequenceType(genericArguments) {
                    guard arguments.count == 2 else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Range iterator next has unsupported arguments"
                        )
                    }
                    try lowerProgressionIteratorNext(
                        type: type,
                        resultAddress: arguments[0],
                        iteratorAddress: arguments[1],
                        resultToken: resultToken,
                        line: line
                    )
                    return
                }
                guard arguments.count == 2,
                      !genericArguments.isEmpty,
                      let collectionType = try? normalizedIteratorCollectionType(
                          shape,
                          genericArguments: genericArguments
                      ),
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
                    .collectionNext(
                        result: result,
                        collection: state.array,
                        indexSlot: state.indexSlot,
                        direction: .forward
                    )
                )
                try storeConstructedValue(result, at: arguments[0], mode: .initialize)
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

            case .dictionaryEmpty:
                guard arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.init() has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(
                    genericArguments
                )
                guard let metatype = dictionaryMetatypeValues[arguments[0]],
                      metatype.0 == types.key,
                      metatype.1 == types.value
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.init() metatype does not match Key and Value"
                    )
                }
                let result = try makeEmptyDictionary(
                    key: types.key,
                    value: types.value
                )
                values[resultToken] = result

            case .dictionarySubscriptGet:
                guard arguments.count == 3,
                      let outputType = stackType(at: arguments[0]),
                      let key = try copyStoredValue(
                        at: arguments[1],
                        line: line
                      )
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
                try storeConstructedValue(result, at: arguments[0], mode: .initialize)
                voidValues.insert(resultToken)

            case .dictionarySubscriptSet:
                guard arguments.count == 3,
                      let updateType = stackType(at: arguments[0]),
                      let keyType = stackType(at: arguments[1]),
                      let dictionaryType = stackType(at: arguments[2])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary subscript setter has unsupported arguments"
                    )
                }
                guard let update = try copyStoredValue(
                    at: arguments[0],
                    line: line
                ), let key = try copyStoredValue(
                    at: arguments[1],
                    line: line
                ), let dictionary = try copyStoredValue(
                    at: arguments[2],
                    line: line
                ) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary subscript setter references uninitialized storage"
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
                let mutation = try emitDictionarySet(
                    dictionary: dictionary,
                    key: key,
                    update: update,
                    keyType: types.key,
                    valueType: types.value
                )
                destroyLinearTemporary(update)
                destroyLinearTemporary(dictionary)
                destroyLinearTemporary(mutation.previous)
                try storeConstructedValue(
                    mutation.updated,
                    at: arguments[2],
                    mode: .assign
                )
                voidValues.insert(resultToken)

            case .dictionaryDefaultSubscriptGet:
                guard arguments.count == 4,
                      let outputType = compilerAddressType(arguments[0]),
                      let keyType = compilerAddressType(arguments[1]),
                      let borrowedKey = try borrowStoredValue(
                        at: arguments[1],
                        line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary default subscript getter has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(genericArguments)
                let dictionaryType = Bytecode.ValueType.dictionary(
                    key: types.key,
                    value: types.value
                )
                let borrowedDictionary = try borrowStoredValue(
                    at: arguments[3],
                    line: line
                )
                let dictionary = try borrowedDictionary?.register
                    ?? resolve(arguments[3], line: line)
                guard outputType == types.value,
                      keyType == types.key,
                      registerTypes[Int(borrowedKey.register.rawValue)]
                        == types.key,
                      registerTypes[Int(dictionary.rawValue)] == dictionaryType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary default subscript getter types do not match"
                    )
                }
                let result = try lowerDictionaryValueOrDefault(
                    dictionary: dictionary,
                    key: borrowedKey.register,
                    closureToken: arguments[2],
                    keyType: types.key,
                    valueType: types.value,
                    line: line
                )
                for owner in [
                    borrowedKey.temporaryOwner,
                    borrowedDictionary?.temporaryOwner,
                ].compactMap({ $0 }) {
                    appendInstruction(.destroyValue(owner))
                }
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case .dictionaryDefaultSubscriptModify:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Dictionary.subscript(default:)._modify must be consumed by begin_apply"
                )

            case .dictionaryUpdateValue:
                guard arguments.count == 4,
                      let outputType = compilerAddressType(arguments[0]),
                      let valueType = compilerAddressType(arguments[1]),
                      let keyType = compilerAddressType(arguments[2]),
                      let dictionaryType = compilerAddressType(arguments[3]),
                      let value = try copyStoredValue(
                        at: arguments[1],
                        line: line
                      ),
                      let key = try copyStoredValue(
                        at: arguments[2],
                        line: line
                      ),
                      let dictionary = try copyStoredValue(
                        at: arguments[3],
                        line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.updateValue has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(genericArguments)
                let expectedDictionary = Bytecode.ValueType.dictionary(
                    key: types.key,
                    value: types.value
                )
                guard outputType == .optional(types.value),
                      valueType == types.value,
                      registerTypes[Int(value.rawValue)] == valueType,
                      keyType == types.key,
                      registerTypes[Int(key.rawValue)] == keyType,
                      dictionaryType == expectedDictionary,
                      registerTypes[Int(dictionary.rawValue)] == dictionaryType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.updateValue types do not match Dictionary"
                    )
                }
                let update = try allocate(type: .optional(types.value))
                appendInstruction(.makeOptionalSome(result: update, value: value))
                let mutation = try emitDictionarySet(
                    dictionary: dictionary,
                    key: key,
                    update: update,
                    keyType: types.key,
                    valueType: types.value
                )
                destroyLinearTemporary(update)
                destroyLinearTemporary(dictionary)
                try storeConstructedValue(
                    mutation.previous,
                    at: arguments[0],
                    mode: .initialize
                )
                try storeConstructedValue(
                    mutation.updated,
                    at: arguments[3],
                    mode: .assign
                )
                voidValues.insert(resultToken)

            case .dictionaryRemoveValue:
                guard arguments.count == 3,
                      let outputType = compilerAddressType(arguments[0]),
                      let keyType = compilerAddressType(arguments[1]),
                      let dictionaryType = compilerAddressType(arguments[2])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.removeValue has unsupported arguments"
                    )
                }
                guard let key = try copyStoredValue(
                    at: arguments[1],
                    line: line
                ), let dictionary = try copyStoredValue(
                    at: arguments[2],
                    line: line
                ) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.removeValue references uninitialized storage"
                    )
                }
                let types = try parseDictionaryGenericArguments(genericArguments)
                let expectedDictionary = Bytecode.ValueType.dictionary(
                    key: types.key,
                    value: types.value
                )
                guard outputType == .optional(types.value),
                      keyType == types.key,
                      registerTypes[Int(key.rawValue)] == keyType,
                      dictionaryType == expectedDictionary,
                      registerTypes[Int(dictionary.rawValue)] == dictionaryType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.removeValue types do not match Dictionary"
                    )
                }
                let update = try allocate(type: .optional(types.value))
                appendInstruction(.makeOptionalNone(result: update))
                let mutation = try emitDictionarySet(
                    dictionary: dictionary,
                    key: key,
                    update: update,
                    keyType: types.key,
                    valueType: types.value
                )
                destroyLinearTemporary(update)
                destroyLinearTemporary(dictionary)
                try storeConstructedValue(
                    mutation.previous,
                    at: arguments[0],
                    mode: .initialize
                )
                try storeConstructedValue(
                    mutation.updated,
                    at: arguments[2],
                    mode: .assign
                )
                voidValues.insert(resultToken)

            case .dictionaryRemoveAll:
                guard arguments.count == 2,
                      let dictionaryType = compilerAddressType(arguments[1])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.removeAll has unsupported arguments"
                    )
                }
                let keepingCapacity = try resolve(arguments[0], line: line)
                let types = try parseDictionaryGenericArguments(genericArguments)
                let expectedDictionary = Bytecode.ValueType.dictionary(
                    key: types.key,
                    value: types.value
                )
                guard registerTypes[Int(keepingCapacity.rawValue)] == .bool,
                      dictionaryType == expectedDictionary
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.removeAll types do not match Dictionary"
                    )
                }
                let empty = try makeEmptyDictionary(
                    key: types.key,
                    value: types.value
                )
                try storeConstructedValue(
                    empty,
                    at: arguments[1],
                    mode: .assign
                )
                voidValues.insert(resultToken)

            case let .dictionaryProjection(projection):
                guard arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary projection getter has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(genericArguments)
                let dictionary = try resolve(arguments[0], line: line)
                let dictionaryType = Bytecode.ValueType.dictionary(
                    key: types.key,
                    value: types.value
                )
                guard registerTypes[Int(dictionary.rawValue)] == dictionaryType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary projection generic types do not match its operand"
                    )
                }
                let element = projection == .keys ? types.key : types.value
                let result = try allocate(type: .array(element))
                appendInstruction(
                    .dictionaryProject(
                        result: result,
                        dictionary: dictionary,
                        projection: projection
                    )
                )
                values[resultToken] = result

            case .dictionaryReserveCapacity:
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.reserveCapacity has unsupported arguments"
                    )
                }
                let types = try parseDictionaryGenericArguments(
                    genericArguments
                )
                try lowerCapacityHint(
                    capacityToken: arguments[0],
                    storageToken: arguments[1],
                    expectedType: .dictionary(
                        key: types.key,
                        value: types.value
                    ),
                    displayName: "Dictionary capacity",
                    resultToken: resultToken,
                    line: line
                )

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
                destroyLinearTemporary(pairs)

            case .dictionaryUniqueKeysWithValues:
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.init(uniqueKeysWithValues:) has unsupported arguments"
                    )
                }
                let types = try parseDictionarySequenceGenericArguments(
                    genericArguments
                )
                let pairSequence = Bytecode.ValueType.array(
                    .tuple([types.key, types.value])
                )
                guard types.sequence == pairSequence,
                      stackType(at: arguments[0]) == pairSequence,
                      let metatype = dictionaryMetatypeValues[arguments[1]],
                      metatype.0 == types.key,
                      metatype.1 == types.value,
                      let pairs = try copyStoredValue(
                        at: arguments[0],
                        line: line
                      ),
                      registerTypes[Int(pairs.rawValue)] == pairSequence
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Dictionary.init(uniqueKeysWithValues:) types do not match"
                    )
                }
                let result = try allocate(
                    type: .dictionary(key: types.key, value: types.value)
                )
                appendInstruction(.makeDictionary(result: result, pairs: pairs))
                destroyLinearTemporary(pairs)
                values[resultToken] = result

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
                appendInstruction(.constantInteger(result: zero, bitPattern: 0))
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
                    .collectionNext(
                        result: result,
                        collection: state.dictionary,
                        indexSlot: state.indexSlot,
                        direction: .forward
                    )
                )
                try storeConstructedValue(result, at: arguments[0], mode: .initialize)
                voidValues.insert(resultToken)

            case .setEmpty:
                guard arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.init() has unsupported arguments"
                    )
                }
                let types = try parseSetGenericArguments(genericArguments)
                guard setMetatypeValues[arguments[0]] == types.element else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.init() metatype does not match Element"
                    )
                }
                let emptyArray = try allocate(type: .array(types.element))
                appendInstruction(.makeArray(result: emptyArray, elements: []))
                let result = try allocate(type: .set(types.element))
                appendInstruction(.makeSet(result: result, source: emptyArray))
                values[resultToken] = result

            case .setCount, .setIsEmpty:
                guard arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set property getter has unsupported arguments"
                    )
                }
                let types = try parseSetGenericArguments(genericArguments)
                let set = try materializeSetOperand(
                    arguments[0],
                    element: types.element
                )
                let resultType: Bytecode.ValueType = intrinsic == .setCount
                    ? .int64
                    : .bool
                let result = try allocate(type: resultType)
                values[resultToken] = result
                appendInstruction(
                    intrinsic == .setCount
                        ? .setCount(result: result, set: set)
                        : .setIsEmpty(result: result, set: set)
                )

            case .setContains:
                guard arguments.count == 2,
                      let element = try copyStoredValue(
                        at: arguments[0],
                        line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.contains has unsupported arguments"
                    )
                }
                let types = try parseSetGenericArguments(genericArguments)
                let set = try materializeSetOperand(
                    arguments[1],
                    element: types.element
                )
                guard registerTypes[Int(element.rawValue)] == types.element else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.contains element type does not match"
                    )
                }
                let result = try allocate(type: .bool)
                values[resultToken] = result
                appendInstruction(
                    .setContains(result: result, set: set, element: element)
                )

            case .setInsert:
                guard arguments.count == 3,
                      let memberType = compilerAddressType(arguments[0]),
                      let elementType = compilerAddressType(arguments[1]),
                      let setType = compilerAddressType(arguments[2]),
                      let element = try copyStoredValue(
                        at: arguments[1],
                        line: line
                      ),
                      let set = try copyStoredValue(
                        at: arguments[2],
                        line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.insert has unsupported or uninitialized arguments"
                    )
                }
                let types = try parseSetGenericArguments(genericArguments)
                let expectedSet = Bytecode.ValueType.set(types.element)
                guard memberType == types.element,
                      elementType == types.element,
                      setType == expectedSet,
                      registerTypes[Int(element.rawValue)] == types.element,
                      registerTypes[Int(set.rawValue)] == expectedSet
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.insert types do not match Set.Element"
                    )
                }
                let inserted = try allocate(type: .bool)
                let member = try allocate(type: types.element)
                let updated = try allocate(type: expectedSet)
                appendInstruction(
                    .setInsert(
                        insertedResult: inserted,
                        memberResult: member,
                        setResult: updated,
                        set: set,
                        element: element
                    )
                )
                values[resultToken] = inserted
                try storeConstructedValue(
                    member,
                    at: arguments[0],
                    mode: .initialize
                )
                try storeConstructedValue(
                    updated,
                    at: arguments[2],
                    mode: .assign
                )

            case .setUpdate, .setRemove:
                guard arguments.count == 3,
                      let outputType = compilerAddressType(arguments[0]),
                      let elementType = compilerAddressType(arguments[1]),
                      let setType = compilerAddressType(arguments[2]),
                      let element = try copyStoredValue(
                        at: arguments[1],
                        line: line
                      ),
                      let set = try copyStoredValue(
                        at: arguments[2],
                        line: line
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set mutation has unsupported or uninitialized arguments"
                    )
                }
                let types = try parseSetGenericArguments(genericArguments)
                let expectedSet = Bytecode.ValueType.set(types.element)
                guard outputType == .optional(types.element),
                      elementType == types.element,
                      setType == expectedSet,
                      registerTypes[Int(element.rawValue)] == types.element,
                      registerTypes[Int(set.rawValue)] == expectedSet
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set mutation types do not match Set.Element"
                    )
                }
                let oldMember = try allocate(type: outputType)
                let updated = try allocate(type: expectedSet)
                if intrinsic == .setUpdate {
                    appendInstruction(
                        .setUpdate(
                            oldMemberResult: oldMember,
                            setResult: updated,
                            set: set,
                            element: element
                        )
                    )
                } else {
                    appendInstruction(
                        .setRemove(
                            removedResult: oldMember,
                            setResult: updated,
                            set: set,
                            element: element
                        )
                    )
                }
                try storeConstructedValue(
                    oldMember,
                    at: arguments[0],
                    mode: .initialize
                )
                try storeConstructedValue(
                    updated,
                    at: arguments[2],
                    mode: .assign
                )
                voidValues.insert(resultToken)

            case .setPopFirst, .setRemoveFirst:
                let types = try parseSetGenericArguments(genericArguments)
                let expectedOutput: Bytecode.ValueType = intrinsic == .setPopFirst
                    ? .optional(types.element)
                    : types.element
                let expectedSet = Bytecode.ValueType.set(types.element)
                guard arguments.count == 2,
                      compilerAddressType(arguments[0]) == expectedOutput,
                      compilerAddressType(arguments[1]) == expectedSet,
                      let source = try copyStoredValue(
                        at: arguments[1],
                        line: line
                      ),
                      registerTypes[Int(source.rawValue)] == expectedSet
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set first-element removal types do not match Set.Element"
                    )
                }
                let optional = try allocate(type: .optional(types.element))
                let updated = try allocate(type: expectedSet)
                appendInstruction(
                    .setPopFirst(
                        elementResult: optional,
                        setResult: updated,
                        set: source
                    )
                )
                let output: Bytecode.Register
                if intrinsic == .setPopFirst {
                    output = optional
                } else {
                    output = try allocate(type: types.element)
                    appendInstruction(
                        .unwrapOptional(result: output, optional: optional)
                    )
                }
                try storeConstructedValue(
                    output,
                    at: arguments[0],
                    mode: .initialize
                )
                try storeConstructedValue(
                    updated,
                    at: arguments[1],
                    mode: .assign
                )
                voidValues.insert(resultToken)

            case .setReserveCapacity:
                let types = try parseSetGenericArguments(genericArguments)
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.reserveCapacity has unsupported arguments"
                    )
                }
                try lowerCapacityHint(
                    capacityToken: arguments[0],
                    storageToken: arguments[1],
                    expectedType: .set(types.element),
                    displayName: "Set capacity",
                    resultToken: resultToken,
                    line: line
                )

            case .setLiteral, .setSequenceInit:
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set initializer has unsupported arguments"
                    )
                }
                let types = try parseSetGenericArguments(genericArguments)
                guard setMetatypeValues[arguments[1]] == types.element else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set initializer metatype does not match Element"
                    )
                }
                let expectedSequence = intrinsic == .setSequenceInit
                    ? types.sequence
                    : nil
                let result = try materializeSetOperand(
                    arguments[0],
                    element: types.element,
                    expectedSequence: expectedSequence
                )
                values[resultToken] = result

            case .setMakeIterator:
                guard arguments.count == 1 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.makeIterator has unsupported arguments"
                    )
                }
                let types = try parseSetGenericArguments(genericArguments)
                let set = try materializeSetOperand(
                    arguments[0],
                    element: types.element
                )
                guard pendingSetIteratorValues[resultToken] == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set iterator value is initialized more than once"
                    )
                }
                let zero = try allocate(type: .int64)
                appendInstruction(.constantInteger(result: zero, bitPattern: 0))
                let slot = try allocateStackSlot(type: .int64)
                appendInstruction(
                    .storeStack(slot: slot, source: zero, mode: .initialize)
                )
                pendingSetIteratorValues[resultToken] = .init(
                    elementType: types.element,
                    set: set,
                    indexSlot: slot
                )

            case .setIteratorNext:
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.Iterator.next has unsupported arguments"
                    )
                }
                let types = try parseSetGenericArguments(genericArguments)
                let resultType = Bytecode.ValueType.optional(types.element)
                guard compilerAddressType(arguments[0]) == resultType,
                      let state = setIteratorStates[addressBase(arguments[1])],
                      state.elementType == types.element
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.Iterator.next types do not match"
                    )
                }
                let result = try allocate(type: resultType)
                appendInstruction(
                    .collectionNext(
                        result: result,
                        collection: state.set,
                        indexSlot: state.indexSlot,
                        direction: .forward
                    )
                )
                try storeConstructedValue(
                    result,
                    at: arguments[0],
                    mode: .initialize
                )
                voidValues.insert(resultToken)

            case let .setAlgebra(operation):
                guard arguments.count == 2 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set algebra has unsupported arguments"
                    )
                }
                let types = try parseSetGenericArguments(genericArguments)
                let rhs = try materializeSetOperand(
                    arguments[0],
                    element: types.element,
                    expectedSequence: types.sequence
                )
                let lhs = try materializeSetOperand(
                    arguments[1],
                    element: types.element
                )
                let result = try allocate(type: .set(types.element))
                values[resultToken] = result
                appendInstruction(
                    .setAlgebra(
                        result: result,
                        operation: operation,
                        lhs: lhs,
                        rhs: rhs
                    )
                )

            case let .setFormAlgebra(operation):
                let types = try parseSetGenericArguments(genericArguments)
                guard arguments.count == 2,
                      compilerAddressType(arguments[1]) == .set(types.element)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "mutating Set algebra has unsupported arguments"
                    )
                }
                let rhs = try materializeSetOperand(
                    arguments[0],
                    element: types.element,
                    expectedSequence: types.sequence
                )
                guard let lhs = try copyStoredValue(
                    at: arguments[1],
                    line: line
                ) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "mutating Set algebra references uninitialized storage"
                    )
                }
                let result = try allocate(type: .set(types.element))
                appendInstruction(
                    .setAlgebra(
                        result: result,
                        operation: operation,
                        lhs: lhs,
                        rhs: rhs
                    )
                )
                try storeConstructedValue(
                    result,
                    at: arguments[1],
                    mode: .assign
                )
                voidValues.insert(resultToken)

            case let .setRelation(operation):
                let types = try parseSetGenericArguments(genericArguments)
                let lhs: Bytecode.Register
                let rhs: Bytecode.Register
                if operation == .equal {
                    guard arguments.count == 3,
                          setMetatypeValues[arguments[2]] == types.element
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Set equality has unsupported arguments"
                        )
                    }
                    lhs = try materializeSetOperand(
                        arguments[0],
                        element: types.element
                    )
                    rhs = try materializeSetOperand(
                        arguments[1],
                        element: types.element
                    )
                } else {
                    guard arguments.count == 2 else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Set relation has unsupported arguments"
                        )
                    }
                    rhs = try materializeSetOperand(
                        arguments[0],
                        element: types.element
                    )
                    lhs = try materializeSetOperand(
                        arguments[1],
                        element: types.element
                    )
                }
                let result = try allocate(type: .bool)
                values[resultToken] = result
                appendInstruction(
                    .setRelation(
                        result: result,
                        operation: operation,
                        lhs: lhs,
                        rhs: rhs
                    )
                )

            case .setRemoveAll:
                let types = try parseSetGenericArguments(genericArguments)
                guard arguments.count == 2,
                      let element = compilerAddressType(arguments[1]),
                      case let .set(elementType) = element,
                      elementType == types.element,
                      let keepCapacity = try? resolve(arguments[0], line: line),
                      registerTypes[Int(keepCapacity.rawValue)] == .bool
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set.removeAll has unsupported arguments"
                    )
                }
                let emptyArray = try allocate(type: .array(elementType))
                appendInstruction(.makeArray(result: emptyArray, elements: []))
                let emptySet = try allocate(type: .set(elementType))
                appendInstruction(.makeSet(result: emptySet, source: emptyArray))
                try storeConstructedValue(
                    emptySet,
                    at: arguments[1],
                    mode: .assign
                )
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
                let element = try parseStoredType(genericArguments)
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
                let element = try parseStoredType(genericArguments)
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
            currentSILLineIndex = lineIndex
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
                if let value = mutableCaptureState.temporaryBorrowOwners.removeValue(
                    forKey: borrowEnd[0]
                ), registerTypes[Int(value.rawValue)].requiresLinearOwnership {
                    appendInstruction(.destroyValue(value))
                }
                if let value = removeBorrowedTemporaryValue(for: borrowEnd[0]) {
                    clearBorrowedTemporaryClassification(for: borrowEnd[0])
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
                indirectErrorType: entryBlock == nil
                    ? signature.indirectErrorType
                    : nil,
                suppressVoidParameter: parseBlockNumber(line).map {
                    suppressedVoidTryNormalBlocks.contains(.init(rawValue: $0))
                } ?? false,
                allocate: allocate
            ) {
                finishCurrent()
                var loweredBlock = block.block
                let explicitParameters = block.parameters
                if suppressedVoidTryNormalBlocks.remove(block.block.id) != nil {
                    guard explicitParameters.isEmpty else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "try_apply normal block carries a non-Void SIL parameter"
                        )
                    }
                    if let parameter = block.suppressedVoidParameter {
                        voidValues.insert(parameter)
                    }
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
                if let accesses = implicitAccessCleanups.removeValue(
                    forKey: loweredBlock.id
                ) {
                    for access in accesses {
                        appendInstruction(.endAccess(access))
                    }
                }
                if let owners = implicitOwnerCleanups.removeValue(
                    forKey: loweredBlock.id
                ) {
                    for owner in owners {
                        appendInstruction(.destroyValue(owner))
                    }
                }
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
                if let implicit = implicitStackValues[block.block.id] {
                    for item in implicit {
                        if runtimeAddress(at: item.address) != nil
                            || item.address == indirectResultAddress {
                            // Continuation-carried values may initialize an
                            // indirect result or assign a transactional inout
                            // update. Preserve the recorded mode for runtime
                            // storage and the current function's `@out` slot.
                            try storeConstructedValue(
                                item.register,
                                at: item.address,
                                mode: item.storeMode
                            )
                            continue
                        }
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
                for (token, pointee) in block.mutableCellParameters {
                    guard let register = values[token],
                          registerTypes[Int(register.rawValue)]
                            == .mutableCell(pointee)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "mutable capture parameter has no matching VM cell"
                        )
                    }
                    mutableCaptureState.addresses[token] = .init(
                        register: register,
                        pointee: pointee
                    )
                }
                if entryBlock == nil {
                    entryBlock = loweredBlock.id
                    if signature.hasIndirectResult {
                        guard let address = block.indirectResultAddress else {
                            throw CanonicalSIL.LoweringError.unsupportedType(
                                "indirect result \(signature.result)"
                            )
                        }
                        if signature.result == .void {
                            // A fully specialized generic closure may retain
                            // an `@out ()` parameter even though `()` is its
                            // logical no-result ABI. The pointer is zero-sized
                            // compiler metadata and never enters HLBC.
                            _ = address
                        } else {
                            guard supportsIndirectResult(signature.result) else {
                                throw CanonicalSIL.LoweringError.unsupportedType(
                                    "indirect result \(signature.result)"
                                )
                            }
                            indirectResultAddress = address
                            indirectResultSlot = try allocateStackSlot(
                                type: signature.result
                            )
                        }
                    } else if block.indirectResultAddress != nil {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "entry block contains an unexpected indirect result"
                        )
                    }
                    if let errorType = signature.indirectErrorType {
                        guard let address = block.indirectErrorAddress else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "entry block omits its indirect error result"
                            )
                        }
                        indirectErrorAddress = address
                        stackAddressTypes[address] = errorType
                    } else if block.indirectErrorAddress != nil {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "entry block contains an unexpected indirect error result"
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
                        && isBorrowedValue(token: token, register: value)
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
                    physicalConventions: physicalConventions,
                    logicalTypes: binding.parameterTypes,
                    line: sourceLine,
                    allowsCompilerInoutWriteback: false
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
                try schedulePreparedContinuationCleanups(
                    prepared,
                    in: [bridge.normalTarget, bridge.errorTarget]
                )
                for token in bridge.argumentTokens {
                    if removeBorrowedTemporaryValue(for: token) != nil {
                        clearBorrowedTemporaryClassification(for: token)
                    }
                }
                continue
            }

            if line == "unreachable" {
                let reason = current.flatMap {
                    unreachableTrapReasons.removeValue(forKey: $0.id)
                } ?? .explicit("Swift unreachable")
                appendInstruction(.trap(reason))
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
               [0, 2].contains(flag.bitPattern),
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
                pattern: #"^(%[0-9]+) = metatype \$@(thin|thick) (.+)\.Type$"#
            ) {
                let normalized = metatype[2]
                    .replacingOccurrences(of: "Swift.", with: "")
                if normalized == "FloatingPointRoundingRule" {
                    compilerEnumMetatypeValues.insert(metatype[0])
                    continue
                }
                if let type = try? parseStoredType(metatype[2]) {
                    switch type {
                    case .integer, .float:
                        scalarMetatypeValues[metatype[0]] = type
                        continue
                    default:
                        break
                    }
                }
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
                pattern: #"^(%[0-9]+) = metatype \$@thin (?:Swift\.)?Set<(.+)>\.Type$"#
            ) {
                let element = try parseStoredType(metatype[1])
                guard element.isVMHashable else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "Set element \(element) lacks VM-defined Hashable semantics"
                    )
                }
                setMetatypeValues[metatype[0]] = element
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
                let compilerEnumType = stack[1]
                    .replacingOccurrences(of: "Swift.", with: "")
                if compilerEnumType == "FloatingPointRoundingRule" {
                    compilerEnumAddressTypes[stack[0]] = compilerEnumType
                    continue
                }
                if stack[1] == "DefaultStringInterpolation"
                    || stack[1] == "Swift.DefaultStringInterpolation" {
                    pendingStringInterpolationAddresses.insert(stack[0])
                    continue
                }
                if let type = try progressionIteratorType(stack[1]) {
                    progressionIteratorAddresses[stack[0]] = type
                    continue
                }
                if let type = try progressionSequenceType(stack[1]) {
                    progressionAddresses[stack[0]] = type
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
                if let element = try setIteratorElementType(stack[1]) {
                    pendingSetIteratorTypes[stack[0]] = element
                    continue
                }
                let type = try parseStoredType(stack[1])
                stackAddressTypes[stack[0]] = type
                if let capturedType = mutableCapturePointees[stack[0]] {
                    guard capturedType == type else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "planned mutable capture does not match its allocation"
                        )
                    }
                    let cell = try allocate(type: .mutableCell(type))
                    appendInstruction(
                        .makeMutableCell(result: cell, initialValue: nil)
                    )
                    mutableCaptureState.addresses[stack[0]] = .init(
                        register: cell,
                        pointee: type
                    )
                    values[stack[0]] = cell
                } else if usesRuntimeAddresses
                            || storageInitializationPlan.runtimeStorageRoots.contains(
                                stack[0]
                            ) {
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

            if let box = match(
                line,
                pattern: #"^(%[0-9]+) = alloc_box \$\{ var (.+) \}(?:, .*)?$"#
            ) {
                let pointee = try parseType(box[1])
                guard pendingMutableBoxes.updateValue(
                    pointee,
                    forKey: box[0]
                ) == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "mutable box is allocated more than once"
                    )
                }
                continue
            }

            if let projection = match(
                line,
                pattern: #"^(%[0-9]+) = project_box (%[0-9]+), ([0-9]+)$"#
            ) {
                guard projection[2] == "0" else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: "multi-field mutable box projection"
                    )
                }
                if let pointee = pendingMutableBoxes[projection[1]] {
                    guard mutableBoxProjectionRoots.updateValue(
                        projection[1],
                        forKey: projection[0]
                    ) == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "mutable box projection is defined more than once"
                        )
                    }
                    stackAddressTypes[projection[0]] = pointee
                    continue
                }
                guard let cell = values[projection[1]],
                      case let .mutableCell(pointee) = registerTypes[
                        Int(cell.rawValue)
                      ]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "project_box references an unknown mutable capture"
                    )
                }
                mutableCaptureState.addresses[projection[1]] = .init(
                    register: cell,
                    pointee: pointee
                )
                mutableCaptureState.addresses[projection[0]] = .init(
                    register: cell,
                    pointee: pointee
                )
                addressAliases[projection[0]] = projection[1]
                values[projection[0]] = cell
                continue
            }

            if let copy = match(
                line,
                pattern: #"^copy_addr(?: \[(take)\])? (%[0-9]+) to (?:\[(init|assign)\] )?(%[0-9]+)$"#
            ) {
                let source = addressBase(copy[1])
                let destination = addressBase(copy[3])
                if let sourceType = compilerEnumAddressTypes[source] {
                    guard compilerEnumAddressTypes[destination] == sourceType,
                          let value = compilerEnumAddressCases[source]
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "compiler enum copy_addr requires initialized matching storage"
                        )
                    }
                    if copy[2] != "init",
                       compilerEnumAddressCases[destination] == nil {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "compiler enum assignment requires initialized destination storage"
                        )
                    }
                    compilerEnumAddressCases[destination] = value
                    if copy[0] == "take" {
                        compilerEnumAddressCases.removeValue(forKey: source)
                    }
                    continue
                }
                if let progression = progressionAddressValues[source] {
                    guard progressionAddresses[source] == progression.type,
                          progressionAddresses[destination] == progression.type
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "progression copy_addr requires matching storage"
                        )
                    }
                    progressionAddressValues[destination] = progression
                    if copy[0] == "take" {
                        progressionAddressValues.removeValue(forKey: source)
                    }
                    continue
                }
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
                let sourceOptionalValue = optionalValueSource(at: copy[1])
                let sourceType = stackType(at: copy[1])
                let destinationType = compilerAddressType(copy[3])
                guard let sourceType, sourceType == destinationType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "copy_addr at line \(sourceLine) requires initialized matching storage; "
                            + "source \(copy[1]) is \(String(describing: sourceType)), "
                            + "destination \(copy[3]) is \(String(describing: destinationType))"
                    )
                }
                let value: Bytecode.Register?
                if copy[0] == "take" {
                    guard mutableCell(at: copy[1]) == nil else {
                        throw CanonicalSIL.LoweringError.unsupportedInstruction(
                            line: sourceLine,
                            text: "taking copy_addr through a mutable closure capture"
                        )
                    }
                    value = try takeStoredValue(
                        at: copy[1],
                        line: sourceLine
                    )
                } else {
                    value = try copyStoredValue(
                        at: copy[1],
                        line: sourceLine
                    )
                }
                guard let value else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "copy_addr references uninitialized source storage"
                    )
                }
                let type = registerTypes[Int(value.rawValue)]
                guard type == sourceType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "copy_addr materialized a value with the wrong type"
                    )
                }
                if type == .any {
                    try storeExistential(value, at: copy[3])
                } else {
                    try storeConstructedValue(value, at: copy[3])
                }
                if let blockID, case .optional = type {
                    recordOptionalValueSource(sourceOptionalValue, at: copy[3])
                    setKnownSomeOptionalAddress(
                        copy[3],
                        in: blockID,
                        isKnownSome: sourceIsKnownSome
                    )
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
                if let cell = mutableCell(at: borrow[1]),
                   let pointee = mutableCellPointee(at: borrow[1]) {
                    let value = try allocate(type: pointee)
                    appendInstruction(
                        .loadMutableCell(result: value, cell: cell)
                    )
                    values[borrow[0]] = value
                    borrowedValueTokens.insert(borrow[0])
                    mutableCaptureState.temporaryBorrowOwners[borrow[0]] = value
                    continue
                }
                if runtimeAddress(at: borrow[1]) != nil {
                    guard let pointee = stackType(at: borrow[1]),
                          let value = try copyStoredValue(
                            at: borrow[1],
                            line: sourceLine
                          ),
                          registerTypes[Int(value.rawValue)] == pointee
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "load_borrow references uninitialized runtime storage"
                        )
                    }
                    values[borrow[0]] = value
                    borrowedValueTokens.insert(borrow[0])
                    if pointee.requiresLinearOwnership {
                        mutableCaptureState.temporaryBorrowOwners[borrow[0]] = value
                    }
                    continue
                }
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
                pattern: #"^(%[0-9]+) = begin_access \[(read|modify|init)\] \[(static|dynamic)\] (%[0-9]+)$"#
            ) {
                let source = access[3]
                let base = addressBase(source)
                if let cell = mutableCell(at: source),
                   let pointee = mutableCellPointee(at: source) {
                    addressAliases[access[0]] = base
                    mutableCaptureState.addresses[access[0]] = .init(
                        register: cell,
                        pointee: pointee
                    )
                    values[access[0]] = cell
                    continue
                }
                if let sourceAddress = runtimeAddress(at: source),
                   let pointee = stackType(at: source) {
                    if access[2] == "static",
                       runtimeStackSlots[base] != nil {
                        // Swift has already proven a static frame-local access.
                        // Preserve its address provenance without opening a VM
                        // scope at the aggregate root: the eventual projected
                        // load, store, or inout call opens the narrowest scope.
                        // This keeps sibling fields independently accessible.
                        addressAliases[access[0]] = base
                        runtimeAddressValues[access[0]] = sourceAddress
                        runtimeAddressPointees[access[0]] = pointee
                        passthroughRuntimeAccesses.insert(access[0])
                        if access[1] == "init" {
                            initializingRuntimeAccesses.insert(access[0])
                        }
                        values[access[0]] = sourceAddress
                        continue
                    }
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
                        || progressionAddresses[base] != nil
                        || progressionIteratorAddresses[base] != nil
                        || pendingDictionaryIteratorTypes[base] != nil
                        || pendingSetIteratorTypes[base] != nil
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
                let token = access[0]
                // SIL block layout is not execution order: a merge block may
                // print its end_access before late textual predecessor blocks.
                // Emit the dynamic close here but retain compile-time address
                // metadata until every printed predecessor has been lowered.
                let hasLaterTextualUse = hasFutureSemanticUse(
                    of: token,
                    after: currentSILLineIndex
                )
                if passthroughRuntimeAccesses.contains(token) {
                    if hasLaterTextualUse {
                        deferredAccessMetadataCleanup.insert(token)
                    } else {
                        removeAccessMetadata(token)
                    }
                    continue
                }
                if scopedRuntimeAddresses.contains(token),
                   let register = runtimeAddressValues[token] {
                    appendInstruction(.endAccess(register))
                    if hasLaterTextualUse {
                        deferredAccessMetadataCleanup.insert(token)
                    } else {
                        removeAccessMetadata(token)
                    }
                    continue
                }
                guard addressAliases[token] != nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "end_access references an unsupported access"
                    )
                }
                if hasLaterTextualUse {
                    deferredAccessMetadataCleanup.insert(token)
                } else {
                    removeAccessMetadata(token)
                }
                continue
            }

            if let deallocation = match(line, pattern: #"^dealloc_stack (%[0-9]+)$"#) {
                let token = deallocation[0]
                let address = addressBase(token)
                guard let remainingUses = remainingDeallocStackUses[token],
                      remainingUses > 0
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "dealloc_stack is absent from the lexical cleanup inventory"
                    )
                }
                let isFinalLexicalUse = remainingUses == 1
                if isFinalLexicalUse {
                    remainingDeallocStackUses.removeValue(forKey: token)
                } else {
                    remainingDeallocStackUses[token] = remainingUses - 1
                }
                if compilerEnumAddressTypes[address] != nil {
                    if isFinalLexicalUse {
                        compilerEnumAddressTypes.removeValue(forKey: address)
                        compilerEnumAddressCases.removeValue(forKey: address)
                    }
                    continue
                }
                if onStackClosureValues.contains(address) {
                    // SIL models an on-stack partial_apply as storage. The VM owns the
                    // corresponding closure value for the lifetime of its frame.
                    if isFinalLexicalUse { onStackClosureValues.remove(address) }
                    continue
                }
                if catchScratchAddresses.contains(address),
                   runtimeStackSlots[address] == nil {
                    continue
                }
                if progressionAddresses[address] != nil {
                    guard progressionAddressValues[address] != nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "progression storage is deallocated before initialization"
                        )
                    }
                    if isFinalLexicalUse {
                        progressionAddresses.removeValue(forKey: address)
                        progressionAddressValues.removeValue(forKey: address)
                    }
                    continue
                }
                if progressionIteratorAddresses[address] != nil {
                    guard let state = progressionIteratorStates[address]
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "progression iterator storage is deallocated before initialization"
                        )
                    }
                    appendInstruction(.destroyStack(state.cursorSlot))
                    if isFinalLexicalUse {
                        progressionIteratorAddresses.removeValue(forKey: address)
                        progressionIteratorStates.removeValue(forKey: address)
                    }
                    continue
                }
                if pendingStringInterpolationAddresses.contains(address) {
                    guard stringInterpolationAddressValues[address] == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "String interpolation storage is deallocated before take"
                        )
                    }
                    if isFinalLexicalUse {
                        pendingStringInterpolationAddresses.remove(address)
                    }
                    continue
                }
                if pendingArrayIteratorTypes[address] != nil {
                    guard let block = current?.id,
                          let iterator = arrayIteratorStates[address]
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array iterator is deallocated before initialization"
                        )
                    }
                    let hasExplicitDestroy = explicitlyDestroyedAddresses
                        .contains(token)
                    if hasExplicitDestroy {
                        guard destroyedArrayIterators[address]?
                            .contains(block) == true
                        else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "Array iterator is deallocated before destroy_addr"
                            )
                        }
                    } else {
                        guard destroyedArrayIterators[address, default: []]
                            .insert(block).inserted
                        else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "trivial Array iterator is deallocated twice"
                            )
                        }
                        appendInstruction(.destroyStack(iterator.indexSlot))
                    }
                    if isFinalLexicalUse {
                        pendingArrayIteratorTypes.removeValue(forKey: address)
                        arrayIteratorStates.removeValue(forKey: address)
                        destroyedArrayIterators.removeValue(forKey: address)
                    }
                    continue
                }
                if pendingDictionaryIteratorTypes[address] != nil {
                    guard let block = current?.id,
                          dictionaryIteratorStates[address] != nil,
                          destroyedDictionaryIterators[address]?.contains(block) == true
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Dictionary iterator is deallocated before destroy_addr"
                        )
                    }
                    if isFinalLexicalUse {
                        pendingDictionaryIteratorTypes.removeValue(forKey: address)
                        dictionaryIteratorStates.removeValue(forKey: address)
                        destroyedDictionaryIterators.removeValue(forKey: address)
                    }
                    continue
                }
                if pendingSetIteratorTypes[address] != nil {
                    guard let block = current?.id,
                          setIteratorStates[address] != nil,
                          destroyedSetIterators[address]?.contains(block) == true
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Set iterator is deallocated before destroy_addr"
                        )
                    }
                    if isFinalLexicalUse {
                        pendingSetIteratorTypes.removeValue(forKey: address)
                        setIteratorStates.removeValue(forKey: address)
                        destroyedSetIterators.removeValue(forKey: address)
                    }
                    continue
                }
                if let slot = runtimeStackSlots[address] {
                    switch storageInitializationPlan.deallocationMode(
                        at: currentSILLineIndex
                    ) {
                    case .none:
                        break
                    case .destroy:
                        appendInstruction(.destroyStack(slot))
                    case .destroyIfInitialized:
                        appendInstruction(
                            .destroyStackIfInitialized(slot)
                        )
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
                takenOptionalPayloads = takenOptionalPayloads.filter {
                    addressBase($0.value.address) != address
                }
                // Swift treats some imported C values as trivial even though
                // HLBC represents them with an owned native box. Release any
                // compiler-only storage that SIL legitimately deallocates
                // without a preceding destroy_addr.
                var storedValues = removeTupleComponentValues(rootedAt: address)
                if let aggregate = stackAddressValues.removeValue(forKey: address) {
                    storedValues.append(aggregate)
                }
                for value in Set(storedValues)
                where registerTypes[Int(value.rawValue)].requiresLinearOwnership {
                    appendInstruction(.destroyValue(value))
                }
                continue
            }

            if let literal = match(line, pattern: #"^(%[0-9]+) = integer_literal \$Builtin\.Int(1|8|16|32|64), (-?[0-9]+)$"#) {
                guard let width = UInt16(literal[1]),
                      let bitPattern = Self.integerLiteralBitPattern(
                          literal[2],
                          bitWidth: width
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer literal is outside its supported representation"
                    )
                }
                integerLiterals[literal[0]] = (width, bitPattern)
                if width == 1 {
                    let register = try allocate(type: .bool)
                    values[literal[0]] = register
                    let bool = bitPattern != 0
                    boolLiterals[literal[0]] = bool
                    appendInstruction(.constantBool(result: register, value: bool))
                } else {
                    let register = try allocate(type: .integer(bitWidth: width, signed: true))
                    values[literal[0]] = register
                    appendInstruction(
                        .constantInteger(
                            result: register,
                            bitPattern: bitPattern
                        )
                    )
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
                let maximumDigits = width == 32 ? 8 : 16
                guard !literal[2].isEmpty,
                      literal[2].count <= maximumDigits
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Float\(width) literal exceeds its hexadecimal bit width"
                    )
                }
                guard let bitPattern = UInt64(literal[2], radix: 16),
                      width == 64 || bitPattern <= UInt32.max
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating-point literal has an invalid bit pattern"
                    )
                }
                let result = try allocate(type: .float(bitWidth: width))
                values[literal[0]] = result
                appendInstruction(
                    .constantFloat(result: result, bitPattern: bitPattern)
                )
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

            if let ternary = parseFloatingTernary(line) {
                let multiplicand = try resolve(
                    ternary.multiplicand,
                    line: sourceLine
                )
                let multiplier = try resolve(
                    ternary.multiplier,
                    line: sourceLine
                )
                let addend = try resolve(ternary.addend, line: sourceLine)
                let expected = Bytecode.ValueType.float(
                    bitWidth: ternary.bitWidth
                )
                guard registerTypes[Int(multiplicand.rawValue)] == expected,
                      registerTypes[Int(multiplier.rawValue)] == expected,
                      registerTypes[Int(addend.rawValue)] == expected
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating ternary operands do not match its builtin"
                    )
                }
                let result = try allocate(type: expected)
                values[ternary.result] = result
                appendInstruction(
                    .floatingTernary(
                        result: result,
                        operation: ternary.operation,
                        multiplicand: multiplicand,
                        multiplier: multiplier,
                        addend: addend
                    )
                )
                continue
            }

            if let unary = parseFloatingUnary(line) {
                let operand = try resolve(unary.operand, line: sourceLine)
                let type = Bytecode.ValueType.float(bitWidth: unary.bitWidth)
                guard registerTypes[Int(operand.rawValue)] == type else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "floating unary operand does not match its builtin"
                    )
                }
                let result = try allocate(type: type)
                values[unary.result] = result
                appendInstruction(
                    .floatingUnary(
                        result: result,
                        operation: unary.operation,
                        operand: operand
                    )
                )
                continue
            }

            if let unary = parseIntegerUnary(line) {
                let operand = try resolve(unary.operand, line: sourceLine)
                guard case let .integer(width, _) = registerTypes[
                    Int(operand.rawValue)
                ], width == unary.bitWidth else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "integer unary operand does not match its builtin"
                    )
                }
                if let flag = unary.zeroIsUndefinedFlag,
                   boolLiterals[flag] != false {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: "integer count builtin with undefined zero semantics"
                    )
                }
                let type = registerTypes[Int(operand.rawValue)]
                let result = try allocate(type: type)
                values[unary.result] = result
                appendInstruction(
                    .integerUnary(
                        result: result,
                        operation: unary.operation,
                        operand: operand
                    )
                )
                continue
            }

            if let bitcast = match(
                line,
                pattern: #"^(%[0-9]+) = builtin "bitcast_(FPIEEE|Int)(32|64)_(FPIEEE|Int)(32|64)"\((%[0-9]+)\).*$"#
            ) {
                guard bitcast[1] != bitcast[3],
                      bitcast[2] == bitcast[4],
                      let width = UInt16(bitcast[2])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "scalar bitcast must preserve width across integer and float"
                    )
                }
                let operand = try resolve(bitcast[5], line: sourceLine)
                let operandType = registerTypes[Int(operand.rawValue)]
                let resultType: Bytecode.ValueType
                if bitcast[1] == "FPIEEE" {
                    guard operandType == .float(bitWidth: width) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "floating scalar bitcast operand has the wrong width"
                        )
                    }
                    // Builtin.IntN has no signedness. Begin with its raw-bit
                    // interpretation and retype it at the first signed use.
                    resultType = .integer(bitWidth: width, signed: false)
                } else {
                    guard case let .integer(actualWidth, _) = operandType,
                          actualWidth == width
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "integer scalar bitcast operand has the wrong width"
                        )
                    }
                    resultType = .float(bitWidth: width)
                }
                let result = try allocate(type: resultType)
                values[bitcast[0]] = result
                appendInstruction(
                    .scalarBitCast(result: result, operand: operand)
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
                if let cell = mutableCell(at: projection[1]),
                   let basePointee = mutableCellPointee(at: projection[1]) {
                    if scalarWrappers.contains(projection[2]),
                       projection[3] == "_value" {
                        mutableCaptureState.addresses[projection[0]] = .init(
                            register: cell,
                            pointee: basePointee
                        )
                        addressAliases[projection[0]] = addressBase(projection[1])
                        values[projection[0]] = cell
                        continue
                    }
                    guard case let .local(key) = basePointee,
                          typeEnvironment.localKey(for: projection[2]) == key
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "struct_element_addr mutable cell is not its declared local struct"
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
                    let result = try allocate(type: .mutableCell(pointee))
                    appendInstruction(
                        .projectMutableCell(
                            result: result,
                            cell: cell,
                            fieldIndex: fieldIndex
                        )
                    )
                    mutableCaptureState.addresses[projection[0]] = .init(
                        register: result,
                        pointee: pointee
                    )
                    aggregateComponentAddresses[projection[0]] = .init(
                        base: projection[1],
                        index: index
                    )
                    addressAliases[projection[0]] = addressBase(projection[1])
                    values[projection[0]] = result
                    continue
                }
                if scalarWrappers.contains(projection[2]),
                   projection[3] == "_value",
                   let property = nativePropertyAddresses[addressBase(projection[1])] {
                    nativePropertyAddresses[projection[0]] = property
                    addressAliases[projection[0]] = addressBase(projection[1])
                    continue
                }
                if scalarWrappers.contains(projection[2]),
                   projection[3] == "_value",
                   runtimeAddress(at: projection[1]) == nil,
                   let stored = stackValue(at: projection[1]),
                   let pointee = stackType(at: projection[1]),
                   registerTypes[Int(stored.rawValue)] == pointee {
                    stackAddressTypes[projection[0]] = pointee
                    stackAddressValues[projection[0]] = stored
                    addressAliases[projection[0]] = addressBase(projection[1])
                    continue
                }
                if runtimeAddress(at: projection[1]) == nil,
                   let structure = stackValue(at: projection[1]),
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
                    aggregateComponentAddresses[projection[0]] = .init(
                        base: projection[1],
                        index: index
                    )
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
                    .projectAggregateAddress(
                        result: result,
                        base: base,
                        fieldIndex: fieldIndex
                    )
                )
                runtimeAddressValues[projection[0]] = result
                runtimeAddressPointees[projection[0]] = pointee
                aggregateComponentAddresses[projection[0]] = .init(
                    base: projection[1],
                    index: index
                )
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
                pattern: #"^(%[0-9]+) = struct_extract (%[0-9]+), #(.+)\.([^.]+)$"#
            ), let wrapper = try CanonicalSIL.TransparentScalarWrapper.descriptor(
                for: alias[2],
                resolve: parseStoredType
            ) {
                guard wrapper.fieldNames.contains(alias[3]) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "transparent scalar wrapper has an unknown stored field"
                    )
                }
                let operand = try resolve(alias[1], line: sourceLine)
                guard registerTypes[Int(operand.rawValue)] == wrapper.valueType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "transparent scalar extraction has the wrong representation"
                    )
                }
                values[alias[0]] = operand
                continue
            }
            if let alias = match(
                line,
                pattern: #"^(%[0-9]+) = struct \$(.+) \((%[0-9]+)\)$"#
            ), let wrapper = try CanonicalSIL.TransparentScalarWrapper.descriptor(
                for: alias[1],
                resolve: parseStoredType
            ) {
                switch wrapper.valueType {
                case .integer:
                    values[alias[0]] = try materializeIntegerOperand(
                        alias[2],
                        expected: wrapper.valueType,
                        line: sourceLine
                    )
                case .bool, .float:
                    let operand = try resolve(alias[2], line: sourceLine)
                    guard registerTypes[Int(operand.rawValue)] == wrapper.valueType else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "transparent scalar construction has the wrong representation"
                        )
                    }
                    values[alias[0]] = operand
                default:
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "transparent scalar construction is not scalar"
                    )
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
                        arguments: [try copyOwnedValue(operand)]
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
                aliasRetainedValue(cast[0], to: cast[1])
                if conversion.forwardsExplicitOwner {
                    recordPendingRetainedValue(result, for: cast[0])
                }
                if conversion.tracksCompilerTemporary {
                    try recordBorrowedTemporaryValue(result, for: cast[0])
                }
                appendInstruction(
                    .nativeApply(
                        result: result,
                        importID: requirement.id,
                        arguments: [conversion.argument]
                    )
                )
                releaseBorrowedTemporariesAfterLastUse(
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
                aliasRetainedValue(cast[0], to: cast[1])
                if conversion.forwardsExplicitOwner {
                    recordPendingRetainedValue(result, for: cast[0])
                }
                if conversion.tracksCompilerTemporary {
                    try recordBorrowedTemporaryValue(result, for: cast[0])
                }
                appendInstruction(
                    .nativeApply(
                        result: result,
                        importID: requirement.id,
                        arguments: [conversion.argument]
                    )
                )
                releaseBorrowedTemporariesAfterLastUse(
                    [cast[1]],
                    after: lineIndex
                )
                continue
            }

            if let construction = match(
                line,
                pattern: #"^(%[0-9]+) = struct \$((?:Swift\.)?(?:Range|ClosedRange)<.+>) \((.*)\)$"#
            ), let type = try progressionSequenceType(construction[1]) {
                let operands = try parseApplyValueTokens(
                    construction[2],
                    line: sourceLine
                )
                guard type.family == .range || type.family == .closedRange,
                      operands.count == 2
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Range construction requires lower and upper bounds"
                    )
                }
                let lower = try resolve(operands[0], line: sourceLine)
                let upper = try resolve(operands[1], line: sourceLine)
                guard registerTypes[Int(lower.rawValue)] == type.element,
                      registerTypes[Int(upper.rawValue)] == type.element
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Range bounds do not match the concrete Bound type"
                    )
                }
                progressionValues[construction[0]] = .init(
                    type: type,
                    start: lower,
                    end: upper,
                    stride: nil
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
                let registers = try zip(operands, fields).map {
                    operand, field in
                    try resolveStorableValue(
                        operand,
                        expectedType: field.type,
                        line: sourceLine
                    )
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
                    indirectErrorType: callee.indirectErrorType,
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
                if let factory = typeEnvironment.structFactory(reference[1]) {
                    localFactoryReferences[reference[0]] = factory
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
                    indirectErrorType: callee.indirectErrorType,
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
                      !binding.effects.isAsync,
                      case let .closure(signature) = try parseType(conversion[2]),
                      signature.parameters == binding.parameterTypes,
                      signature.parameterConventions
                        == binding.parameterConventions,
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
                      !binding.effects.isAsync
                else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let physicalType = try parseFunctionType(
                    closure[3],
                    bridgingTo: (
                        binding.parameterTypes,
                        binding.resultType
                    ),
                    abiAdapter: binding.abiAdapter
                )
                guard physicalType.parameters == binding.parameterTypes,
                      physicalType.parameterConventions
                        == reference.physicalParameterConventions,
                      physicalType.result == binding.resultType,
                      physicalType.hasIndirectResult == reference.hasIndirectResult,
                      physicalType.indirectErrorType
                        == reference.indirectErrorType,
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
                guard captureTokens.count <= binding.parameterTypes.count else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "partial_apply captures more values than its callee accepts"
                    )
                }
                let invocationCount = binding.parameterTypes.count
                    - captureTokens.count
                let invocationTypes = Array(binding.parameterTypes.prefix(invocationCount))
                let expectedCaptureTypes = Array(
                    binding.parameterTypes.suffix(captureTokens.count)
                )
                var captureTemporaryOwners: [Bytecode.Register] = []
                let captures = try zip(captureTokens, expectedCaptureTypes).map {
                    token, type in
                    if case let .mutableCell(pointee) = type {
                        return try materializeMutableCapture(
                            at: token,
                            pointee: pointee,
                            line: sourceLine
                        )
                    }
                    if let retained = takePendingRetainedValue(for: token) {
                        guard registerTypes[Int(retained.rawValue)] == type else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "retained closure capture has the wrong type"
                            )
                        }
                        captureTemporaryOwners.append(retained)
                        return retained
                    }
                    return try resolveStorableValue(
                        token,
                        expectedType: type,
                        line: sourceLine
                    )
                }
                let captureTypes = captures.map { registerTypes[Int($0.rawValue)] }
                guard captureTypes == expectedCaptureTypes else {
                    throw CanonicalSIL.LoweringError.callSignatureMismatch(
                        line: sourceLine,
                        mangledName: binding.mangledName
                    )
                }
                let signature = Bytecode.ClosureSignature(
                    parameters: invocationTypes,
                    parameterConventions: Array(
                        binding.parameterConventions.prefix(invocationCount)
                    ),
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
                for owner in captureTemporaryOwners
                where registerTypes[Int(owner.rawValue)]
                    .requiresLinearOwnership {
                    // make_closure copies captures into its managed context;
                    // this owner represents Swift's explicit context retain.
                    appendInstruction(.destroyValue(owner))
                }
                continue
            }

            if let dependence = match(
                line,
                pattern: #"^(%[0-9]+) = mark_dependence(?: \[[^\]]+\])* (%[0-9]+) on (%[0-9]+)$"#
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
                pattern: #"^(%[0-9]+) = convert_function (%[0-9]+) to \$(.+)$"#
            ) {
                let source = try resolve(conversion[1], line: sourceLine)
                guard case let .closure(actual) = registerTypes[
                    Int(source.rawValue)
                ], case let .closure(expected) = try parseType(conversion[2]),
                   actual == expected
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "convert_function changes the represented closure ABI"
                    )
                }
                // Direct and indirect SIL results share one value result in
                // HLBC. A fully concrete conversion that preserves the VM
                // signature is therefore an ownership-neutral closure alias.
                values[conversion[0]] = source
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
                    inheritKnownOptionalValueCase(
                        from: borrowed[1],
                        to: borrowed[0]
                    )
                }
                continue
            }

            if let call = match(
                line,
                pattern: #"^\((%[0-9]+), (%[0-9]+)\) = begin_apply (%[0-9]+)(?:<(.+)>)?\((.*)\) : \$(.+)$"#
            ) {
                guard let intrinsic = swiftCoreReferences[call[2]] else {
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                let arguments = splitTopLevel(call[4]).map { argument in
                    String(argument.split(separator: ":", maxSplits: 1)[0])
                        .trimmingCharacters(in: .whitespaces)
                }
                switch intrinsic {
                case .arraySubscriptModify:
                    guard arguments.count == 2 else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.subscript.modify has unsupported arguments"
                        )
                    }
                    let element = try parseStoredType(call[3])
                    let index = try resolve(arguments[0], line: sourceLine)
                    guard registerTypes[Int(index.rawValue)] == .int64,
                          compilerAddressType(arguments[1]) == .array(element),
                          let array = try copyStoredValue(
                            at: arguments[1],
                            line: sourceLine
                          ),
                          registerTypes[Int(array.rawValue)] == .array(element)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array.subscript.modify types do not match"
                        )
                    }
                    let currentElement = try allocate(type: element)
                    appendInstruction(
                        .arrayGet(
                            result: currentElement,
                            array: array,
                            index: index
                        )
                    )
                    try beginCollectionElementMutation(
                        yieldToken: call[0],
                        continuationToken: call[1],
                        initialElement: currentElement,
                        mutation: .init(
                            collectionAddress: arguments[1],
                            source: .array(array: array, index: index),
                            elementType: element
                        )
                    )

                case .dictionaryDefaultSubscriptModify:
                    guard arguments.count == 3,
                          let keyType = compilerAddressType(arguments[0]),
                          let key = try copyStoredValue(
                            at: arguments[0],
                            line: sourceLine
                          ),
                          let dictionary = try copyStoredValue(
                            at: arguments[2],
                            line: sourceLine
                          )
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Dictionary default subscript modify has unsupported arguments"
                        )
                    }
                    let types = try parseDictionaryGenericArguments(call[3])
                    let dictionaryType = Bytecode.ValueType.dictionary(
                        key: types.key,
                        value: types.value
                    )
                    guard keyType == types.key,
                          registerTypes[Int(key.rawValue)] == types.key,
                          compilerAddressType(arguments[2]) == dictionaryType,
                          registerTypes[Int(dictionary.rawValue)] == dictionaryType
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Dictionary default subscript modify types do not match"
                        )
                    }
                    let selected = try lowerDictionaryValueOrDefault(
                        dictionary: dictionary,
                        key: key,
                        closureToken: arguments[1],
                        keyType: types.key,
                        valueType: types.value,
                        line: sourceLine
                    )
                    try beginCollectionElementMutation(
                        yieldToken: call[0],
                        continuationToken: call[1],
                        initialElement: selected,
                        mutation: .init(
                            collectionAddress: arguments[2],
                            source: .dictionaryDefault(
                                dictionary: dictionary,
                                key: key,
                                keyType: types.key,
                                valueType: types.value
                            ),
                            elementType: types.value
                        )
                    )

                default:
                    throw CanonicalSIL.LoweringError.unsupportedInstruction(
                        line: sourceLine,
                        text: line
                    )
                }
                continue
            }

            if let apply = match(
                line,
                pattern: #"^(?:(%[0-9]+) = )?end_apply (%[0-9]+) as \$\(\)$"#
            ) {
                guard let yield = collectionMutationYieldByToken[apply[1]] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "collection _modify end_apply has no matching begin_apply"
                    )
                }
                try finalizeCollectionElementMutation(
                    yieldToken: yield,
                    line: sourceLine
                )
                if !hasFutureSemanticUse(
                    of: apply[1],
                    after: currentSILLineIndex
                ) {
                    collectionMutationYieldByToken.removeValue(forKey: apply[1])
                    removeCollectionMutationMetadata(yieldToken: yield)
                }
                if !apply[0].isEmpty { voidValues.insert(apply[0]) }
                continue
            }

            if let apply = match(
                line,
                pattern: #"^abort_apply (%[0-9]+)$"#
            ) {
                guard let yield = collectionMutationYieldByToken[apply[0]] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "collection _modify abort_apply has no matching begin_apply"
                    )
                }
                try finalizeCollectionElementMutation(
                    yieldToken: yield,
                    line: sourceLine
                )
                if !hasFutureSemanticUse(
                    of: apply[0],
                    after: currentSILLineIndex
                ) {
                    collectionMutationYieldByToken.removeValue(forKey: apply[0])
                    removeCollectionMutationMetadata(yieldToken: yield)
                }
                continue
            }

            if let call = match(
                line,
                pattern: #"^try_apply (%[0-9]+)(?:<(.+)>)?\((.*)\) : \$(.+), normal bb([0-9]+), error bb([0-9]+)$"#
            ) {
                if let closure = values[call[0]],
                   case let .closure(signature) = registerTypes[
                    Int(closure.rawValue)
                   ] {
                    let appliedType = try parseFunctionType(call[3])
                    guard call[1].isEmpty,
                          signature.effects.mayThrow,
                          !signature.effects.isAsync,
                          appliedType.parameters == signature.parameters,
                          appliedType.parameterConventions
                            == signature.parameterConventions,
                          appliedType.result == signature.result,
                          appliedType.effects.mayThrow,
                          !appliedType.effects.isAsync
                    else {
                        throw CanonicalSIL.LoweringError.callSignatureMismatch(
                            line: sourceLine,
                            mangledName: "<closure>"
                        )
                    }
                    let normalTarget = try parseBlockID(call[4])
                    let errorTarget = try parseBlockID(call[5])
                    var argumentTokens = try parseApplyValueTokens(
                        call[2],
                        line: sourceLine
                    )
                    let destinations = try consumeIndirectCallDestinations(
                        from: &argumentTokens,
                        resultType: signature.result,
                        hasIndirectResult: appliedType.hasIndirectResult,
                        indirectErrorType: appliedType.indirectErrorType,
                        physicalArgumentCount: signature.parameters.count
                    )
                    try bindIndirectTryCallDestinations(
                        destinations,
                        resultType: signature.result,
                        indirectErrorType: appliedType.indirectErrorType,
                        normalTarget: normalTarget,
                        errorTarget: errorTarget
                    )
                    let prepared = try prepareDirectCallArguments(
                        argumentTokens,
                        physicalConventions: appliedType.parameterConventions,
                        logicalTypes: signature.parameters,
                        line: sourceLine,
                        allowsCompilerInoutWriteback: false
                    )
                    let arguments = prepared.arguments
                    guard arguments.map({
                        registerTypes[Int($0.rawValue)]
                    }) == signature.parameters else {
                        throw CanonicalSIL.LoweringError.callSignatureMismatch(
                            line: sourceLine,
                            mangledName: "<closure>"
                        )
                    }
                    appendInstruction(
                        .closureTryApply(
                            closure: closure,
                            arguments: arguments,
                            normalTarget: normalTarget,
                            errorTarget: errorTarget
                        )
                    )
                    try transferOwnedCompilerAddressArguments(
                        tokens: argumentTokens,
                        resolvedArguments: prepared.arguments,
                        conventions: appliedType.parameterConventions
                    )
                    try schedulePreparedContinuationCleanups(
                        prepared,
                        in: [normalTarget, errorTarget]
                    )
                    continue
                }
                if case let .higherOrder(operation)? = swiftCoreReferences[
                    call[0]
                ] {
                    let normalTarget = try parseBlockID(call[4])
                    let errorTarget = try parseBlockID(call[5])
                    try lowerCollectionHigherOrderTryApply(
                        operation: operation,
                        genericArguments: call[1],
                        argumentText: call[2],
                        normalTarget: normalTarget,
                        errorTarget: errorTarget,
                        line: sourceLine
                    )
                    continue
                }
                if case let .ordering(operation)? = swiftCoreReferences[
                    call[0]
                ], operation.usesClosure {
                    let normalTarget = try parseBlockID(call[4])
                    let errorTarget = try parseBlockID(call[5])
                    try lowerArrayOrderingTryApply(
                        operation: operation,
                        genericArguments: call[1],
                        argumentText: call[2],
                        normalTarget: normalTarget,
                        errorTarget: errorTarget,
                        line: sourceLine
                    )
                    continue
                }
                if case .split(.predicate)? = swiftCoreReferences[call[0]] {
                    let normalTarget = try parseBlockID(call[4])
                    let errorTarget = try parseBlockID(call[5])
                    try lowerArraySplitTryApply(
                        genericArguments: call[1],
                        argumentText: call[2],
                        normalTarget: normalTarget,
                        errorTarget: errorTarget,
                        line: sourceLine
                    )
                    continue
                }
                if case let .algebraic(intrinsic)? = swiftCoreReferences[
                    call[0]
                ] {
                    let normalTarget = try parseBlockID(call[4])
                    let errorTarget = try parseBlockID(call[5])
                    switch intrinsic {
                    case .optional, .result:
                        let plan = try parseAlgebraicTransformPlan(
                            intrinsic,
                            genericArguments: call[1],
                            argumentText: call[2],
                            line: sourceLine
                        )
                        try lowerAlgebraicTransform(
                            plan,
                            invocation: .branching(
                                normalTarget: normalTarget,
                                errorTarget: errorTarget
                            ),
                            line: sourceLine
                        )
                    case .resultGet:
                        let plan = try parseResultProjectionPlan(
                            genericArguments: call[1],
                            argumentText: call[2],
                            line: sourceLine
                        )
                        try lowerResultProjection(
                            plan,
                            normalTarget: normalTarget,
                            errorTarget: errorTarget,
                            line: sourceLine
                        )
                    }
                    continue
                }
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
                      appliedType.indirectErrorType
                        == reference.indirectErrorType,
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
                let destinations = try consumeIndirectCallDestinations(
                    from: &argumentTokens,
                    resultType: binding.resultType,
                    hasIndirectResult: reference.hasIndirectResult,
                    indirectErrorType: reference.indirectErrorType,
                    physicalArgumentCount: reference.physicalParameterConventions.count
                        + reference.erasedMetatypes.count
                )
                try bindIndirectTryCallDestinations(
                    destinations,
                    resultType: binding.resultType,
                    indirectErrorType: reference.indirectErrorType,
                    normalTarget: normalTarget,
                    errorTarget: errorTarget
                )
                argumentTokens = try eraseMetatypeArguments(
                    argumentTokens,
                    for: reference,
                    line: sourceLine
                )
                let prepared = try prepareDirectCallArguments(
                    argumentTokens,
                    physicalConventions: reference.physicalParameterConventions,
                    logicalTypes: binding.parameterTypes,
                    line: sourceLine,
                    allowsCompilerInoutWriteback: false
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
                try schedulePreparedContinuationCleanups(
                    prepared,
                    in: [normalTarget, errorTarget]
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
                          appliedType.parameterConventions
                            == signature.parameterConventions,
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
                    let destinations = try consumeIndirectCallDestinations(
                        from: &argumentTokens,
                        resultType: signature.result,
                        hasIndirectResult: appliedType.hasIndirectResult,
                        indirectErrorType: appliedType.indirectErrorType,
                        physicalArgumentCount: signature.parameters.count
                    )
                    guard destinations.error == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "ordinary closure apply carries an indirect Error result"
                        )
                    }
                    let indirectResultDestination = destinations.result
                    let prepared = try prepareDirectCallArguments(
                        argumentTokens,
                        physicalConventions: appliedType.parameterConventions,
                        logicalTypes: signature.parameters,
                        line: sourceLine,
                        allowsCompilerInoutWriteback: true
                    )
                    let arguments = prepared.arguments
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
                    try transferOwnedCompilerAddressArguments(
                        tokens: argumentTokens,
                        resolvedArguments: prepared.arguments,
                        conventions: appliedType.parameterConventions
                    )
                    appendPreparedOwnerCleanups(prepared)
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
                    try finishPreparedAccessesAndWritebacks(prepared)
                    continue
                }
                if let factory = localFactoryReferences[call[1]] {
                    let key = factory.key
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
                    if argumentTokens.count
                        == factory.physicalParameterTypes.count + 2 {
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
                    guard argumentTokens.count
                            == factory.physicalParameterTypes.count + 1,
                          let metatypeToken = argumentTokens.last,
                          localMetatypeValues[metatypeToken] == key
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "local struct initializer arguments do not match \(key)"
                        )
                    }
                    let physicalTokens = Array(argumentTokens.dropLast())
                    let physicalValues = try zip(
                        physicalTokens,
                        factory.physicalParameterTypes
                    ).map { token, expectedType in
                        try resolveStorableValue(
                            token,
                            expectedType: expectedType,
                            line: sourceLine
                        )
                    }
                    guard factory.fieldPlans.count == fields.count else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "local struct initializer plan does not match \(key)"
                        )
                    }
                    let fieldRegisters = try factory.fieldPlans.map {
                        try materializeStructFactoryValue(
                            plan: $0,
                            physicalValues: physicalValues
                        )
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
                if case let .algebraic(intrinsic)? = swiftCoreReferences[
                    call[1]
                ] {
                    switch intrinsic {
                    case .optional, .result:
                        let plan = try parseAlgebraicTransformPlan(
                            intrinsic,
                            genericArguments: call[2],
                            argumentText: call[3],
                            line: sourceLine
                        )
                        try lowerAlgebraicTransform(
                            plan,
                            invocation: .direct(resultToken: call[0]),
                            line: sourceLine
                        )
                    case .resultGet:
                        throw CanonicalSIL.LoweringError.unsupportedInstruction(
                            line: sourceLine,
                            text: "Result.get requires try_apply"
                        )
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
                        indirectErrorType: callee.indirectErrorType,
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
                      appliedType.indirectErrorType
                        == reference.indirectErrorType,
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
                let destinations = try consumeIndirectCallDestinations(
                    from: &argumentTokens,
                    resultType: binding.resultType,
                    hasIndirectResult: reference.hasIndirectResult,
                    indirectErrorType: reference.indirectErrorType,
                    physicalArgumentCount: reference.physicalParameterConventions.count
                        + reference.erasedMetatypes.count
                )
                guard destinations.error == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "ordinary apply carries an indirect Error result"
                    )
                }
                let indirectResultDestination = destinations.result
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
                    physicalConventions: reference.physicalParameterConventions,
                    logicalTypes: binding.parameterTypes,
                    line: sourceLine,
                    allowsCompilerInoutWriteback: true
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
                appendPreparedOwnerCleanups(prepared)
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
                try finishPreparedAccessesAndWritebacks(prepared)
                releaseBorrowedTemporariesAfterLastUse(
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
                    aliasRetainedValue(cast[0], to: cast[1])
                    aliasBorrowedTemporary(cast[0], to: cast[1])
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
                let payload = try prepareOwnedValue(
                    cast[1],
                    expectedType: sourceType,
                    line: sourceLine
                )
                let result = try allocate(type: .optional(sourceType))
                values[cast[0]] = result
                knownOptionalSomePayloads[cast[0]] = payload
                appendInstruction(.makeOptionalSome(result: result, value: payload))
                if payload == source {
                    try transferBorrowedTemporaryLifetime(
                        from: cast[1],
                        resolved: source,
                        to: cast[0],
                        result: result
                    )
                } else {
                    releaseBorrowedTemporariesAfterLastUse(
                        [cast[1]],
                        after: lineIndex
                    )
                }
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
                guard try parseStoredType(address[2]) == pending.elementType else {
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
            ), let cell = mutableCell(at: component[1]),
               case let .tuple(types) = mutableCellPointee(at: component[1]),
               let index = Int(component[2]),
               types.indices.contains(index),
               let fieldIndex = UInt32(exactly: index) {
                let pointee = types[index]
                let result = try allocate(type: .mutableCell(pointee))
                appendInstruction(
                    .projectMutableCell(
                        result: result,
                        cell: cell,
                        fieldIndex: fieldIndex
                    )
                )
                mutableCaptureState.addresses[component[0]] = .init(
                    register: result,
                    pointee: pointee
                )
                tupleComponentAddresses[component[0]] = .init(
                    base: component[1],
                    index: index
                )
                aggregateComponentAddresses[component[0]] = .init(
                    base: component[1],
                    index: index
                )
                addressAliases[component[0]] = addressBase(component[1])
                values[component[0]] = result
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
            ), let base = runtimeAddress(at: component[1]),
               case let .tuple(types) = stackType(at: component[1]),
               let index = Int(component[2]),
               types.indices.contains(index),
               let fieldIndex = UInt32(exactly: index) {
                let pointee = types[index]
                let result = try allocate(type: .address(pointee))
                appendInstruction(
                    .projectAggregateAddress(
                        result: result,
                        base: base,
                        fieldIndex: fieldIndex
                    )
                )
                runtimeAddressValues[component[0]] = result
                runtimeAddressPointees[component[0]] = pointee
                tupleComponentAddresses[component[0]] = .init(
                    base: component[1],
                    index: index
                )
                aggregateComponentAddresses[component[0]] = .init(
                    base: component[1],
                    index: index
                )
                addressAliases[component[0]] = addressBase(component[1])
                if isScopedRuntimeAddress(component[1]) {
                    scopedRuntimeAddresses.insert(component[0])
                }
                values[component[0]] = result
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
                aggregateComponentAddresses[component[0]] = .init(
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
                      isKnownSomeOptionalAddress(extraction[1], in: blockID)
                else {
                    let block = current?.id.description ?? "<none>"
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "unchecked Optional address payload \(extraction[1]) in "
                            + "\(block) is not dominated by its some edge"
                    )
                }
                guard case let .optional(wrapped) = compilerAddressType(
                    extraction[1]
                ) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "unchecked Optional payload projection has a non-Optional address"
                    )
                }
                let payloadUse = storageInitializationPlan.detachedPayloadUses[
                    extraction[0]
                ] ?? .read
                let optional: Bytecode.Register?
                switch payloadUse {
                case .read:
                    optional = try copyStoredValue(
                        at: extraction[1],
                        line: sourceLine
                    )
                case .take, .modify:
                    optional = try takeStoredValue(
                        at: extraction[1],
                        line: sourceLine
                    )
                }
                guard let optional else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "unchecked Optional payload projection references uninitialized storage"
                    )
                }
                guard registerTypes[Int(optional.rawValue)]
                        == .optional(wrapped)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "unchecked Optional payload projection has mismatched storage"
                    )
                }
                let payload = try allocate(type: wrapped)
                appendInstruction(
                    .unwrapOptional(result: payload, optional: optional)
                )
                if payloadUse != .read {
                    let root = addressBase(extraction[1])
                    for token in [root, extraction[1]]
                    where values[token] == optional {
                        values.removeValue(forKey: token)
                    }
                    setKnownSomeOptionalAddress(
                        extraction[1],
                        in: blockID,
                        isKnownSome: false
                    )
                }
                stackAddressTypes[extraction[0]] = wrapped
                stackAddressValues[extraction[0]] = payload
                if payloadUse == .modify {
                    takenOptionalPayloads[extraction[0]] = .init(
                        address: extraction[1]
                    )
                }
                continue
            }

            if let optional = match(
                line,
                pattern: #"^(%[0-9]+) = enum \$Optional<(.+)>, #Optional\.some!enumelt, (%[0-9]+)$"#
            ) {
                let payload: Bytecode.Register
                let source: Bytecode.Register
                let wrapped: Bytecode.ValueType
                if voidValues.contains(optional[2]) {
                    wrapped = try parseStoredType(optional[1])
                    payload = try resolveStorableValue(
                        optional[2],
                        expectedType: wrapped,
                        line: sourceLine
                    )
                    source = payload
                } else {
                    source = try resolve(optional[2], line: sourceLine)
                    let payloadType = registerTypes[Int(source.rawValue)]
                    wrapped = ValueRepresentation.storable(
                        try parsePhysicalType(
                            optional[1],
                            bridgedTo: payloadType
                        )
                    )
                    payload = try prepareOwnedValue(
                        optional[2],
                        expectedType: wrapped,
                        line: sourceLine
                    )
                }
                guard registerTypes[Int(payload.rawValue)] == wrapped else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Optional.some payload does not match its SIL type"
                    )
                }
                let result = try allocate(type: .optional(wrapped))
                values[optional[0]] = result
                knownOptionalSomePayloads[optional[0]] = payload
                appendInstruction(.makeOptionalSome(result: result, value: payload))
                if payload == source {
                    try transferBorrowedTemporaryLifetime(
                        from: optional[2],
                        resolved: source,
                        to: optional[0],
                        result: result
                    )
                } else {
                    releaseBorrowedTemporariesAfterLastUse(
                        [optional[2]],
                        after: lineIndex
                    )
                }
                continue
            }

            if let optional = match(
                line,
                pattern: #"^(%[0-9]+) = enum \$Optional<(.+)>, #Optional\.none!enumelt$"#
            ) {
                let resolvedWrapped: Bytecode.ValueType
                if let resolved = try? parseType(optional[1]) {
                    resolvedWrapped = resolved
                } else if isSupportedObjectiveCBridgeSpelling(
                    optional[1],
                    to: .string
                ) {
                    resolvedWrapped = .string
                } else {
                    throw CanonicalSIL.LoweringError.unsupportedType(optional[1])
                }
                let wrapped = ValueRepresentation.storable(resolvedWrapped)
                let result = try allocate(type: .optional(wrapped))
                values[optional[0]] = result
                appendInstruction(.makeOptionalNone(result: result))
                continue
            }

            if let enumeration = match(
                line,
                pattern: #"^(%[0-9]+) = enum \$(?:Swift\.)?(FloatingPointSign|FloatingPointRoundingRule), #(?:Swift\.)?[^.]+\.([^!]+)!enumelt$"#
            ) {
                let value = CompilerEnumCase(
                    typeName: enumeration[1],
                    caseName: enumeration[2]
                )
                switch value.typeName {
                case "FloatingPointSign":
                    guard value.caseName == "plus" || value.caseName == "minus" else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "unknown FloatingPointSign case \(value.caseName)"
                        )
                    }
                case "FloatingPointRoundingRule":
                    _ = try roundingOperation(for: value)
                default:
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "unknown compiler-only enum \(value.typeName)"
                    )
                }
                compilerEnumValues[enumeration[0]] = value
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
                let expectedPayload = cases[index].payloadType
                let payload: Bytecode.Register?
                if enumeration[3].isEmpty {
                    payload = nil
                } else if let expectedPayload {
                    payload = try resolveStorableValue(
                        enumeration[3],
                        expectedType: expectedPayload,
                        line: sourceLine
                    )
                } else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "payload-free local enum case carries a SIL value"
                    )
                }
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
                pattern: #"^inject_enum_addr (%[0-9]+), #(?:Swift\.)?FloatingPointRoundingRule\.([^!]+)!enumelt$"#
            ) {
                let address = addressBase(injection[0])
                guard compilerEnumAddressTypes[address]
                        == "FloatingPointRoundingRule",
                      compilerEnumAddressCases[address] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "compiler enum injection has invalid or initialized storage"
                    )
                }
                let enumeration = CompilerEnumCase(
                    typeName: "FloatingPointRoundingRule",
                    caseName: injection[1]
                )
                _ = try roundingOperation(for: enumeration)
                compilerEnumAddressCases[address] = enumeration
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
                // The projected payload remains compiler-side until the enum
                // tag is injected. This is therefore the first complete
                // value stored in a runtime slot even when field-sensitive
                // SIL analysis has already observed the successful edge.
                try storeConstructedValue(
                    optional,
                    at: injection[0],
                    mode: .initialize
                )
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
            ), let box = mutableBoxProjectionRoots.removeValue(
                forKey: store[1]
            ), let pointee = pendingMutableBoxes.removeValue(forKey: box) {
                let initialValue = try resolve(store[0], line: sourceLine)
                guard registerTypes[Int(initialValue.rawValue)] == pointee,
                      values[box] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "mutable box initializer does not match its pointee"
                    )
                }
                let cell = try allocate(type: .mutableCell(pointee))
                appendInstruction(
                    .makeMutableCell(
                        result: cell,
                        initialValue: initialValue
                    )
                )
                for token in [box, store[1]] {
                    mutableCaptureState.addresses[token] = .init(
                        register: cell,
                        pointee: pointee
                    )
                    values[token] = cell
                }
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
                let ownedValue = try copyOwnedValue(value)
                let receiver = try copyOwnedValue(property.receiver)
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
            ), let progression = progressionValues[store[0]] {
                let address = addressBase(store[1])
                guard progressionAddresses[address] == progression.type
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "progression value does not match its destination storage"
                    )
                }
                progressionAddressValues[address] = progression
                if !hasFutureSemanticUse(
                    of: store[0],
                    after: currentSILLineIndex
                ) {
                    progressionValues.removeValue(forKey: store[0])
                }
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
            ), let state = pendingSetIteratorValues.removeValue(forKey: store[0]) {
                let address = addressBase(store[1])
                guard pendingSetIteratorTypes[address] == state.elementType,
                      setIteratorStates[address] == nil
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Set iterator store does not match its stack address"
                    )
                }
                setIteratorStates[address] = state
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
                guard address.index >= 0,
                      address.index < pending.count,
                      types.indices.contains(address.component)
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Array tuple component store is out of bounds"
                    )
                }
                let value = try prepareStoredValue(
                    store[0],
                    expectedType: types[address.component],
                    line: sourceLine
                )
                guard
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
                let value = try prepareStoredValue(
                    store[0],
                    expectedType: pending.elementType,
                    line: sourceLine
                )
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
            ), existentialBoxes.contains(store[0]),
               let destinationType = compilerAddressType(store[1]),
               [.string, .error].contains(destinationType) {
                guard let value = try materializeErrorValue(from: store[0]),
                      registerTypes[Int(value.rawValue)] == destinationType
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "Error existential box does not match its destination"
                    )
                }
                try storeConstructedValue(value, at: store[1])
                continue
            }

            if let store = match(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init|assign)\] )?(%[0-9]+)$"#
            ), let addressType = compilerAddressType(store[1]) {
                let value = try prepareStoredValue(
                    store[0],
                    expectedType: addressType,
                    line: sourceLine
                )
                guard registerTypes[Int(value.rawValue)] == addressType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "store value does not match its stack address"
                    )
                }
                try storeConstructedValue(value, at: store[1])
                if case .optional = addressType {
                    recordOptionalValueSource(store[0], at: store[1])
                    if let blockID = current?.id {
                        setKnownSomeOptionalAddress(
                            store[1],
                            in: blockID,
                            isKnownSome: isKnownSomeOptionalValue(
                                store[0],
                                in: blockID
                            )
                        )
                    }
                }
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
                if load[1].isEmpty,
                   binding.resultType.requiresLinearOwnership {
                    borrowedLoadTokens.insert(load[0])
                    try recordBorrowedTemporaryValue(result, for: load[0])
                }
                continue
            }

            if let load = match(
                line,
                pattern: #"^(%[0-9]+) = load(?: \[(trivial|copy|take)\])? (%[0-9]+)$"#
            ) {
                let mode = load[1]
                let isTakingLoad = mode == "take"
                    || storageInitializationPlan.forwardingLoadLines
                        .contains(currentSILLineIndex)
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
                    let receiver = try copyOwnedValue(property.receiver)
                    appendInstruction(
                        .nativeApply(
                            result: result,
                            importID: requirement.id,
                            arguments: [receiver]
                        )
                    )
                    if mode.isEmpty,
                       property.valueType.requiresLinearOwnership {
                        borrowedLoadTokens.insert(load[0])
                        try recordBorrowedTemporaryValue(result, for: load[0])
                    }
                    continue
                }
                if pendingStringInterpolationAddresses.contains(address) {
                    guard let accumulator = stringInterpolationAddressValues[address] else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "String interpolation load references uninitialized storage"
                        )
                    }
                    switch (mode, isTakingLoad) {
                    case (_, true):
                        stringInterpolationAddressValues.removeValue(forKey: address)
                    case ("", false), ("copy", false):
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
                if let progression = progressionAddressValues[address] {
                    guard progressionAddresses[address] == progression.type,
                          progressionValues[load[0]] == nil
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "progression load references mismatched storage"
                        )
                    }
                    if isTakingLoad {
                        progressionAddressValues.removeValue(forKey: address)
                    }
                    progressionValues[load[0]] = progression
                    continue
                }
                if let cell = mutableCell(at: load[2]),
                   let pointee = mutableCellPointee(at: load[2]) {
                    guard mode != "take" else {
                        throw CanonicalSIL.LoweringError.unsupportedInstruction(
                            line: sourceLine,
                            text: "taking load through a mutable closure capture"
                        )
                    }
                    let result = try allocate(type: pointee)
                    appendInstruction(
                        .loadMutableCell(result: result, cell: cell)
                    )
                    values[load[0]] = result
                    recordOptionalLoadCase(
                        from: load[2],
                        to: load[0],
                        type: pointee
                    )
                    continue
                }
                if let addressRegister = runtimeAddress(at: load[2]),
                   let addressType = stackType(at: load[2]) {
                    if isTakingLoad {
                        let blockID = current?.id
                        let wasKnownSome = isKnownSomeOptionalAddress(
                            load[2],
                            in: blockID
                        )
                        guard let result = try takeStoredValue(
                            at: load[2],
                            line: sourceLine
                        ) else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "taking load references unavailable address storage"
                            )
                        }
                        values[load[0]] = result
                        if let blockID, wasKnownSome {
                            setKnownSomeOptionalValue(
                                load[0],
                                in: blockID,
                                isKnownSome: true
                            )
                        }
                        continue
                    }
                    let result = try allocate(type: addressType)
                    if isScopedRuntimeAddress(load[2]) {
                        appendInstruction(
                            .loadAddress(result: result, address: addressRegister, mode: .copy)
                        )
                    } else if let slot = runtimeStackSlots[address], load[2] == address {
                        let loadMode: Bytecode.StackLoadMode = isTakingLoad
                            ? .take : .copy
                        appendInstruction(
                            .loadStack(result: result, slot: slot, mode: loadMode)
                        )
                        if loadMode == .take { stackAddressValues.removeValue(forKey: address) }
                    } else {
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
                    if mode.isEmpty,
                       addressType.requiresLinearOwnership {
                        // An unqualified canonical-SIL load is a +0 view even
                        // when the address has been promoted to runtime storage.
                        // `loadAddress.copy` supplies the temporary VM owner;
                        // track it until the matching retain or final use so it
                        // cannot leak beside the owner materialized for Swift.
                        borrowedLoadTokens.insert(load[0])
                        try recordBorrowedTemporaryValue(result, for: load[0])
                    }
                    recordOptionalLoadCase(
                        from: load[2],
                        to: load[0],
                        type: addressType
                    )
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
                let blockID = current?.id
                let wasKnownSome = isKnownSomeOptionalAddress(
                    load[2],
                    in: blockID
                )
                if isTakingLoad {
                    guard !addressType.requiresLinearOwnership
                            || !isBorrowedValue(
                                token: load[2],
                                register: value
                            )
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "taking load cannot consume borrowed storage"
                        )
                    }
                    removeCompilerAddressValue(at: load[2])
                    invalidateOptionalStorageFacts(at: load[2])
                    values[load[0]] = value
                    if let blockID, wasKnownSome,
                       case .optional = addressType {
                        setKnownSomeOptionalValue(
                            load[0],
                            in: blockID,
                            isKnownSome: true
                        )
                    }
                } else if mode == "copy" {
                    let copy = try allocate(type: addressType)
                    appendInstruction(.copyValue(result: copy, source: value))
                    values[load[0]] = copy
                } else {
                    values[load[0]] = value
                    if addressType.requiresLinearOwnership {
                        // An unqualified canonical-SIL load is a +0 view. Its
                        // retain, return, store, or owned-call use materializes
                        // a distinct VM owner at the actual ownership edge.
                        borrowedLoadTokens.insert(load[0])
                    }
                }
                if !isTakingLoad {
                    recordOptionalLoadCase(
                        from: load[2],
                        to: load[0],
                        type: addressType
                    )
                }
                continue
            }

            if let destroy = match(line, pattern: #"^destroy_addr (%[0-9]+)$"#) {
                let address = addressBase(destroy[0])
                invalidateOptionalStorageFacts(at: destroy[0])
                if compilerEnumAddressTypes[address] != nil {
                    guard compilerEnumAddressCases.removeValue(forKey: address) != nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "destroy_addr references uninitialized compiler enum storage"
                        )
                    }
                    continue
                }
                if mutableCell(at: destroy[0]) != nil {
                    // The cell owns its payload until every closure/context
                    // reference is released; SIL's stack destroy must not
                    // invalidate an independently escaping capture.
                    continue
                }
                if pendingStringInterpolationAddresses.contains(address) {
                    guard stringInterpolationAddressValues.removeValue(forKey: address) != nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "destroy_addr references uninitialized String interpolation storage"
                        )
                    }
                    continue
                }
                if catchScratchAddresses.contains(address),
                   runtimeStackSlots[address] == nil {
                    continue
                }
                if runtimeAddress(at: destroy[0]) != nil,
                   destroy[0] != address {
                    guard try destroyRuntimeStoredValue(
                        at: destroy[0],
                        line: sourceLine,
                        ifInitialized: storageInitializationPlan
                            .conditionalDestroyLines
                            .contains(currentSILLineIndex)
                    ) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "projected address destroy references uninitialized storage"
                        )
                    }
                    continue
                }
                if let iterator = arrayIteratorStates[address] {
                    guard let block = current?.id,
                          destroyedArrayIterators[address, default: []]
                            .insert(block).inserted
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Array iterator is destroyed twice in one block"
                        )
                    }
                    appendInstruction(.destroyStack(iterator.indexSlot))
                    continue
                }
                if let iterator = dictionaryIteratorStates[address] {
                    guard let block = current?.id,
                          destroyedDictionaryIterators[address, default: []]
                            .insert(block).inserted
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Dictionary iterator is destroyed twice in one block"
                        )
                    }
                    appendInstruction(.destroyStack(iterator.indexSlot))
                    continue
                }
                if let iterator = setIteratorStates[address] {
                    guard let block = current?.id,
                          destroyedSetIterators[address, default: []]
                            .insert(block).inserted
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Set iterator is destroyed twice in one block"
                        )
                    }
                    appendInstruction(.destroyStack(iterator.indexSlot))
                    continue
                }
                if let slot = runtimeStackSlots[address] {
                    let isConditional = storageInitializationPlan
                        .conditionalDestroyLines.contains(currentSILLineIndex)
                    stackAddressValues.removeValue(forKey: address)
                    appendInstruction(
                        isConditional
                            ? .destroyStackIfInitialized(slot)
                            : .destroyStack(slot)
                    )
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
                if let value = try resolvedStackValue(
                    at: destroy[0],
                    line: sourceLine
                ) {
                    removeCompilerAddressValue(at: destroy[0])
                    if registerTypes[Int(value.rawValue)].requiresLinearOwnership {
                        appendInstruction(.destroyValue(value))
                    }
                } else if stackType(at: destroy[0])?.requiresLinearOwnership == true {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "destroy_addr references uninitialized compiler storage"
                    )
                }
                continue
            }

            if let cast = match(
                line,
                pattern: #"^checked_cast_addr_br (?:take_always|copy_on_success) Any in (%[0-9]+) to (.+) in (%[0-9]+), bb([0-9]+), bb([0-9]+)$"#
            ) {
                let targetType = try parseType(cast[1])
                guard stackType(at: cast[0]) == .any,
                      let source = try copyStoredValue(
                        at: cast[0],
                        line: sourceLine
                      ),
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
                implicitStackValues[successTarget] = [.init(cast[2], projected)]
                continue
            }

            if let cast = match(
                line,
                pattern: #"^unconditional_checked_cast_addr Any in (%[0-9]+) to (.+) in (%[0-9]+)$"#
            ) {
                let targetType = try parseType(cast[1])
                guard stackType(at: cast[0]) == .any,
                      let source = try copyStoredValue(
                        at: cast[0],
                        line: sourceLine
                      ),
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
                      let error = try copyStoredValue(
                        at: cast[0],
                        line: sourceLine
                      ),
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
                implicitStackValues[successTarget] = [.init(cast[2], projected)]
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
                if !hasFutureSemanticUse(
                    of: tuple[0],
                    after: currentSILLineIndex
                ) {
                    // Canonical SIL may assemble an aggregate solely for
                    // `debug_value`. Lowering it would invent an owned VM
                    // lifetime after debug metadata has been erased.
                    continue
                }
                let components = splitTopLevel(tuple[1])
                if components.count == 1, components[0].isEmpty {
                    voidValues.insert(tuple[0])
                    continue
                }
                let elements = try components.map { component in
                    let token = component.split(separator: ":", maxSplits: 1)[0]
                        .trimmingCharacters(in: .whitespaces)
                    return try prepareOwnedValue(
                        token,
                        line: sourceLine
                    )
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
                let elements = try unpackTupleValue(
                    tuple,
                    retainedOwnerFor: extract[1]
                )
                values[extract[0]] = elements[index]
                continue
            }

            if let failure = match(line, pattern: #"^cond_fail (%[0-9]+), \"([^\"]*)\"$"#) {
                let condition = try resolve(failure[0], line: sourceLine)
                try appendConditionalTrap(
                    condition: condition,
                    reason: trapReason(for: failure[1])
                )
                continue
            }

            if let copy = match(line, pattern: #"^(%[0-9]+) = copy_value (%[0-9]+)$"#) {
                if let progression = progressionValues[copy[1]] {
                    progressionValues[copy[0]] = progression
                    continue
                }
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
                inheritKnownOptionalValueCase(
                    from: copy[1],
                    to: copy[0]
                )
                if let selection = optionalAddressSelectionConditions[copy[1]] {
                    optionalAddressSelectionConditions[copy[0]] = selection
                }
                appendInstruction(.copyValue(result: result, source: source))
                releaseBorrowedTemporariesAfterLastUse(
                    [copy[1]],
                    after: lineIndex
                )
                continue
            }
            if let move = match(
                line,
                pattern: #"^(%[0-9]+) = move_value(?: \[[^\]]+\])* (%[0-9]+)$"#
            ) {
                if let progression = progressionValues[move[1]] {
                    progressionValues[move[0]] = progression
                    if !hasFutureSemanticUse(
                        of: move[1],
                        after: currentSILLineIndex
                    ) {
                        progressionValues.removeValue(forKey: move[1])
                    }
                    continue
                }
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
                inheritKnownOptionalValueCase(
                    from: move[1],
                    to: move[0]
                )
                if let selection = optionalAddressSelectionConditions.removeValue(
                    forKey: move[1]
                ) {
                    optionalAddressSelectionConditions[move[0]] = selection
                }
                appendInstruction(.moveValue(result: result, source: source))
                continue
            }
            if let destroy = match(line, pattern: #"^destroy_value (%[0-9]+)$"#) {
                if progressionValues[destroy[0]] != nil {
                    if !hasFutureSemanticUse(
                        of: destroy[0],
                        after: currentSILLineIndex
                    ) {
                        progressionValues.removeValue(forKey: destroy[0])
                    }
                    continue
                }
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
                let value = try resolve(destroy[0], line: sourceLine)
                try closeBorrowedTemporaryLifetime(
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
                if progressionValues[ownership[1]] != nil {
                    if ownership[0] == "release_value",
                       !hasFutureSemanticUse(
                            of: ownership[1],
                            after: currentSILLineIndex
                       ) {
                        progressionValues.removeValue(forKey: ownership[1])
                    }
                    continue
                }
                if ownership[0] == "release_value",
                   let retained = takePendingRetainedValue(
                    for: ownership[1]
                   ) {
                    appendInstruction(.destroyValue(retained))
                    continue
                }
                let value = try resolve(ownership[1], line: sourceLine)
                if registerTypes[Int(value.rawValue)].requiresLinearOwnership {
                    if ownership[0] == "retain_value" {
                        try materializeRetain(of: ownership[1], value: value)
                    } else if borrowedTemporaryValue(for: ownership[1]) != nil
                        || !isBorrowedValue(
                            token: ownership[1],
                            register: value
                        ) {
                        try closeBorrowedTemporaryLifetime(
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
                if ownership[0] == "release",
                   let retained = takePendingRetainedValue(
                    for: ownership[1]
                   ) {
                    appendInstruction(.destroyValue(retained))
                    continue
                }
                let value = try resolve(ownership[1], line: sourceLine)
                let type = registerTypes[Int(value.rawValue)]
                if case .closure = type { continue }
                if case .mutableCell = type { continue }
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
                if ownership[0] == "retain" {
                    try materializeRetain(of: ownership[1], value: value)
                } else if borrowedTemporaryValue(for: ownership[1]) != nil
                    || !isBorrowedValue(
                        token: ownership[1],
                        register: value
                    ) {
                    try closeBorrowedTemporaryLifetime(
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
                pattern: #"^(%[0-9]+) = select_enum (%[0-9]+), case #(?:Swift\.)?FloatingPointSign\.(plus|minus)!enumelt: (%[0-9]+), case #(?:Swift\.)?FloatingPointSign\.(plus|minus)!enumelt: (%[0-9]+) : \$Builtin\.Int(8|16|32|64)$"#
            ) {
                guard selection[2] != selection[4],
                      let first = values[selection[3]],
                      let second = values[selection[5]],
                      registerTypes[Int(first.rawValue)]
                        == registerTypes[Int(second.rawValue)],
                      case let .integer(width, _) = registerTypes[Int(first.rawValue)],
                      String(width) == selection[6]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "FloatingPointSign selection has invalid cases or values"
                    )
                }
                if let isMinus = floatingSignValues[selection[1]] {
                    let minus = selection[2] == "minus" ? first : second
                    let plus = selection[2] == "plus" ? first : second
                    let result = try allocate(
                        type: registerTypes[Int(first.rawValue)]
                    )
                    values[selection[0]] = result
                    appendInstruction(
                        .select(
                            result: result,
                            condition: isMinus,
                            trueValue: minus,
                            falseValue: plus
                        )
                    )
                    continue
                }
                if let concrete = compilerEnumValues[selection[1]],
                   concrete.typeName == "FloatingPointSign" {
                    values[selection[0]] = concrete.caseName == selection[2]
                        ? first
                        : second
                    continue
                }
            }

            if line.hasPrefix("switch_enum_addr "),
               let separator = line.firstIndex(of: ",") {
                let operand = String(
                    line[line.index(line.startIndex, offsetBy: "switch_enum_addr ".count)..<separator]
                ).trimmingCharacters(in: .whitespaces)
                let address = addressBase(operand)
                if let selected = compilerEnumAddressCases[address] {
                    let clauses = splitTopLevel(
                        String(line[line.index(after: separator)...])
                    )
                    var targets: [String: Bytecode.BlockID] = [:]
                    var defaultTarget: Bytecode.BlockID?
                    var allTargets: [Bytecode.BlockID] = []
                    for clause in clauses {
                        if let item = match(
                            clause,
                            pattern: #"^case #(?:Swift\.)?FloatingPointRoundingRule\.([^!]+)!enumelt: bb([0-9]+)$"#
                        ) {
                            guard targets[item[0]] == nil else {
                                throw CanonicalSIL.LoweringError.malformedSIL(
                                    "compiler enum switch repeats a case"
                                )
                            }
                            let target = try parseBlockID(item[1])
                            targets[item[0]] = target
                            allTargets.append(target)
                        } else if let item = match(
                            clause,
                            pattern: #"^default bb([0-9]+)$"#
                        ), defaultTarget == nil {
                            let target = try parseBlockID(item[0])
                            defaultTarget = target
                            allTargets.append(target)
                        } else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "compiler enum switch contains an unsupported clause"
                            )
                        }
                    }
                    guard selected.typeName == compilerEnumAddressTypes[address],
                          let target = targets[selected.caseName] ?? defaultTarget
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "compiler enum switch does not cover its stored case"
                        )
                    }
                    try appendStaticBranch(
                        selected: target,
                        preserving: allTargets
                    )
                    continue
                }
            }

            if let selection = match(
                line,
                pattern: #"^(%[0-9]+) = select_enum_addr (%[0-9]+), case #Optional\.(some|none)!enumelt: (%[0-9]+), default (%[0-9]+) : \$Builtin\.Int1$"#
            ) {
                guard let borrowed = try borrowStoredValue(
                    at: selection[1],
                    line: sourceLine
                ) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "select_enum_addr requires initialized Optional storage"
                    )
                }
                let optional = borrowed.register
                guard
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
                if let temporaryOwner = borrowed.temporaryOwner {
                    appendInstruction(.destroyValue(temporaryOwner))
                }
                continue
            }

            if let branch = match(
                line,
                pattern: #"^switch_enum_addr (%[0-9]+), case #Optional\.(some|none)!enumelt: bb([0-9]+), case #Optional\.(some|none)!enumelt: bb([0-9]+)$"#
            ) {
                guard branch[1] != branch[3],
                      let borrowed = try borrowStoredValue(
                        at: branch[0],
                        line: sourceLine
                      ),
                      case .optional = registerTypes[
                        Int(borrowed.register.rawValue)
                      ]
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "switch_enum_addr requires initialized Optional storage and distinct cases"
                    )
                }
                let optional = borrowed.register
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
                if let source = optionalValueSource(at: branch[0]) {
                    setKnownSomeOptionalValue(
                        source,
                        in: someTarget,
                        isKnownSome: true
                    )
                }
                if runtimeAddress(at: branch[0]) == nil,
                   mutableCell(at: branch[0]) == nil {
                    try inheritCompilerAddressValue(
                        optional,
                        at: branch[0],
                        into: [someTarget, noneTarget]
                    )
                }
                let isSome = try allocate(type: .bool)
                appendInstruction(
                    .optionalIsSome(result: isSome, optional: optional)
                )
                if let temporaryOwner = borrowed.temporaryOwner {
                    appendInstruction(.destroyValue(temporaryOwner))
                }
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
                let optional = try prepareOwnedValue(
                    branch[0],
                    line: sourceLine
                )
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

            if let branch = match(
                line,
                pattern: #"^switch_enum (%[0-9]+), case #(?:Swift\.)?FloatingPointSign\.(plus|minus)!enumelt: bb([0-9]+), case #(?:Swift\.)?FloatingPointSign\.(plus|minus)!enumelt: bb([0-9]+)$"#
            ) {
                guard branch[1] != branch[3] else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "FloatingPointSign switch must cover plus and minus"
                    )
                }
                let firstTarget = try parseBlockID(branch[2])
                let secondTarget = try parseBlockID(branch[4])
                let plusTarget = branch[1] == "plus"
                    ? firstTarget
                    : secondTarget
                let minusTarget = branch[1] == "minus"
                    ? firstTarget
                    : secondTarget
                if let isMinus = floatingSignValues[branch[0]] {
                    appendInstruction(
                        .conditionalBranch(
                            condition: isMinus,
                            trueTarget: minusTarget,
                            trueArguments: [],
                            falseTarget: plusTarget,
                            falseArguments: []
                        )
                    )
                    continue
                }
                if let concrete = compilerEnumValues[branch[0]],
                   concrete.typeName == "FloatingPointSign" {
                    try appendStaticBranch(
                        selected: concrete.caseName == "minus"
                            ? minusTarget
                            : plusTarget,
                        preserving: [plusTarget, minusTarget]
                    )
                    continue
                }
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
                    resolve: { token, line in
                        try resolveStorableValue(token, line: line)
                    }
                )
                try appendCompilerAddressMergeArguments(
                    target: target,
                    arguments: &arguments
                )
                try normalizeBuiltinIntegerBranchArguments(
                    &arguments,
                    target: target
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
                guard case .optional = stackType(at: selection.address),
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
                if let source = optionalValueSource(at: selection.address) {
                    setKnownSomeOptionalValue(
                        source,
                        in: someTarget,
                        isKnownSome: true
                    )
                }
                if runtimeAddress(at: selection.address) == nil,
                   mutableCell(at: selection.address) == nil {
                    guard let optional = stackValue(at: selection.address) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "Optional address condition lost its stored value"
                        )
                    }
                    try inheritCompilerAddressValue(
                        optional,
                        at: selection.address,
                        into: [someTarget, noneTarget]
                    )
                }
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
                    resolve: { token, line in
                        try resolveStorableValue(token, line: line)
                    }
                )
                var falseArguments = try parseBranchArguments(
                    branch[4],
                    line: sourceLine,
                    resolve: { token, line in
                        try resolveStorableValue(token, line: line)
                    }
                )
                try appendCompilerAddressMergeArguments(
                    target: trueTarget,
                    arguments: &trueArguments
                )
                try appendCompilerAddressMergeArguments(
                    target: falseTarget,
                    arguments: &falseArguments
                )
                try normalizeBuiltinIntegerBranchArguments(
                    &trueArguments,
                    target: trueTarget
                )
                try normalizeBuiltinIntegerBranchArguments(
                    &falseArguments,
                    target: falseTarget
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
                if let error = try materializeErrorValue(from: thrown[0]) {
                    appendInstruction(.throwError(error))
                } else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "throw does not contain a supported Error value"
                    )
                }
                continue
            }
            if line == "throw_addr" {
                guard signature.effects.mayThrow,
                      let address = indirectErrorAddress,
                      let error = try copyStoredValue(
                        at: address,
                        line: sourceLine
                      ),
                      [.string, .error].contains(
                        registerTypes[Int(error.rawValue)]
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "throw_addr has no initialized indirect Error value"
                    )
                }
                appendInstruction(.throwError(error))
                continue
            }
            if let returned = match(line, pattern: #"^return (%[0-9]+)$"#) {
                if voidValues.contains(returned[0]) {
                    if signature.hasIndirectResult {
                        if signature.result == .void {
                            appendInstruction(.returnValue(nil))
                            continue
                        }
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
        for token in deferredAccessMetadataCleanup {
            removeAccessMetadata(token)
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
            "progression",
            count: progressionValues.count
                + progressionAddresses.count
                + progressionAddressValues.count
                + progressionIteratorAddresses.count
                + progressionIteratorStates.count
        )
        recordIncompleteLifetime(
            "assertion-trap",
            count: unreachableTrapReasons.count
        )
        recordIncompleteLifetime(
            "collection-element-mutation",
            count: collectionElementMutations.count
                + collectionMutationYieldByToken.count
        )
        recordIncompleteLifetime(
            "mutable-box",
            count: pendingMutableBoxes.count + mutableBoxProjectionRoots.count
        )
        recordIncompleteLifetime(
            "dictionary-iterator",
            count: pendingDictionaryIteratorTypes.count
                + pendingDictionaryIteratorValues.count
                + dictionaryIteratorStates.count
                + destroyedDictionaryIterators.count
        )
        recordIncompleteLifetime(
            "set-iterator",
            count: pendingSetIteratorTypes.count
                + pendingSetIteratorValues.count
                + setIteratorStates.count
                + destroyedSetIterators.count
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
        let retainedValueTokens = pendingRetainedValues.flatMap { token, values in
            Array(repeating: token, count: values.count)
        }.sorted()
        recordIncompleteLifetime(
            "retained-value[\(retainedValueTokens.joined(separator: "|"))]",
            count: retainedValueTokens.count
        )
        recordIncompleteLifetime(
            "lexical-dealloc",
            count: remainingDeallocStackUses.values.reduce(0, +)
        )
        recordIncompleteLifetime(
            "compiler-enum",
            count: compilerEnumAddressTypes.count
                + compilerEnumAddressCases.count
        )
        recordIncompleteLifetime(
            "borrowed-call-cleanup",
            count: implicitOwnerCleanups.values.reduce(0) {
                $0 + $1.count
            }
        )
        recordIncompleteLifetime(
            "inout-call-cleanup",
            count: implicitAccessCleanups.values.reduce(0) {
                $0 + $1.count
            }
        )
        let borrowedTemporaryTokens = borrowedTemporaryValues.keys.sorted()
        recordIncompleteLifetime(
            "borrowed-temporary[\(borrowedTemporaryTokens.joined(separator: "|"))]",
            count: borrowedTemporaryTokens.count
        )
        guard incompleteCompilerLifetimes.isEmpty else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "compiler-only lifetime is incomplete in \(displayName): "
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
        let text = try CanonicalSIL.SubstitutedFunctionType.specialize(text)
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
        indirectErrorType: Bytecode.ValueType?,
        effects: Core.Effects,
        erasedMetatypes: [ErasedMetatype]
    ) {
        let text = try CanonicalSIL.SubstitutedFunctionType.specialize(text)
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
            parameters = try valueSpellings.map(parseStoredType)
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
        let indirectErrorType: Bytecode.ValueType?
        if resultComponents.count == 1,
           let error = try supportedErrorResult(resultComponents[0]) {
            // SIL omits the normal empty-tuple result for `throws -> Void`.
            guard physicalResultExpectation == nil
                    || physicalResultExpectation == .void
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "throwing Void SIL cannot satisfy a non-Void logical result"
                )
            }
            parsedResult = (.void, false)
            mayThrow = error.isPossible
            indirectErrorType = error.isIndirect ? error.type : nil
        } else if resultComponents.count == 2,
                  let error = try supportedErrorResult(resultComponents[1]) {
            parsedResult = try parseFunctionResult(
                resultComponents[0],
                bridgedTo: physicalResultExpectation
            )
            mayThrow = error.isPossible
            indirectErrorType = error.isIndirect ? error.type : nil
        } else {
            parsedResult = try parseFunctionResult(
                resultText,
                bridgedTo: physicalResultExpectation
            )
            mayThrow = false
            indirectErrorType = nil
        }
        return (
            parameters,
            parameterConventions,
            expected?.result ?? parsedResult.type,
            parsedResult.isIndirect,
            indirectErrorType,
            .init(mayThrow: mayThrow, isAsync: isAsync),
            erasedMetatypes
        )
    }

    private struct SupportedErrorResult {
        var type: Bytecode.ValueType
        var isIndirect: Bool

        var isPossible: Bool { type != .never }
    }

    private func supportedErrorResult(
        _ raw: String
    ) throws -> SupportedErrorResult? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let prefixes = [
            (spelling: "@error_indirect ", isIndirect: true),
            (spelling: "@error ", isIndirect: false),
        ]
        guard let prefix = prefixes.first(where: {
            value.hasPrefix($0.spelling)
        }) else {
            return nil
        }
        let type = try parseType(
            String(value.dropFirst(prefix.spelling.count))
        )
        if type == .never {
            return .init(type: type, isIndirect: prefix.isIndirect)
        }
        guard [.string, .error].contains(type) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "throwing function has a non-Error error result"
            )
        }
        return .init(type: type, isIndirect: prefix.isIndirect)
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
        case .void, .never, .address, .mutableCell, .arrayState:
            false
        case .bool, .integer, .float, .string, .any, .array, .dictionary, .set,
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
            let parsed = try parseType(raw)
            let actual = expected == .void
                ? parsed
                : ValueRepresentation.storable(parsed)
            if case let .mutableCell(pointee) = expected,
               actual == .address(pointee) {
                return expected
            }
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
            if value.hasPrefix("@inout ")
                || value.hasPrefix("@inout_aliasable ")
                || value.hasPrefix("*") {
                return .inout
            }
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

    private func parseStoredType(
        _ raw: String
    ) throws -> Bytecode.ValueType {
        ValueRepresentation.storable(try parseType(raw))
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
        let collection: Bytecode.ValueType
        if let prefix = prefixes.first(where: { type.hasPrefix($0) }) {
            guard type.hasSuffix(">") else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "IndexingIterator type is missing its closing angle bracket"
                )
            }
            let start = type.index(type.startIndex, offsetBy: prefix.count)
            let end = type.index(before: type.endIndex)
            collection = try parseType(String(type[start..<end]))
        } else if type.hasSuffix(".Iterator") {
            let base = String(type.dropLast(".Iterator".count))
            let adapterPrefixes = [
                "ReversedCollection<", "Swift.ReversedCollection<",
                "EnumeratedSequence<", "Swift.EnumeratedSequence<",
                "Zip2Sequence<", "Swift.Zip2Sequence<",
                "FlattenSequence<", "Swift.FlattenSequence<",
                "JoinedSequence<", "Swift.JoinedSequence<",
            ]
            guard adapterPrefixes.contains(where: base.hasPrefix) else {
                return nil
            }
            collection = try parseType(base)
        } else {
            return nil
        }
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
        guard types.key.isVMHashable else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "Dictionary iterator key \(types.key)"
            )
        }
        return types
    }

    private func setIteratorElementType(
        _ raw: String
    ) throws -> Bytecode.ValueType? {
        let type = raw.trimmingCharacters(in: .whitespaces)
        let prefixes = ["Set<", "Swift.Set<"]
        guard let prefix = prefixes.first(where: { type.hasPrefix($0) }),
              type.hasSuffix(">.Iterator")
        else { return nil }
        let start = type.index(type.startIndex, offsetBy: prefix.count)
        let end = type.index(type.endIndex, offsetBy: -">.Iterator".count)
        let element = try parseStoredType(String(type[start..<end]))
        guard element.isVMHashable else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "Set iterator element \(element) lacks VM-defined Hashable semantics"
            )
        }
        return element
    }

    private func parseSetGenericArguments(
        _ raw: String
    ) throws -> (element: Bytecode.ValueType, sequence: Bytecode.ValueType?) {
        let components = splitTopLevel(raw)
        guard (1...2).contains(components.count) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "Set generic arguments must contain Element and an optional Sequence"
            )
        }
        let element = try parseStoredType(components[0])
        guard element.isVMHashable else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "Set element \(element) lacks VM-defined Hashable semantics"
            )
        }
        let sequence: Bytecode.ValueType?
        if components.count == 2 {
            sequence = try parseStoredType(components[1])
        } else {
            sequence = nil
        }
        return (element, sequence)
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
        let key = try parseStoredType(components[0])
        guard key.isVMHashable else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "Dictionary key \(key) lacks VM-defined Hashable semantics"
            )
        }
        return (key, try parseStoredType(components[1]))
    }

    private func parseDictionarySequenceGenericArguments(
        _ raw: String
    ) throws -> (
        key: Bytecode.ValueType,
        value: Bytecode.ValueType,
        sequence: Bytecode.ValueType
    ) {
        let components = splitTopLevel(raw)
        guard components.count == 3 else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "Dictionary Sequence initializer requires Key, Value, and Sequence"
            )
        }
        let key = try parseStoredType(components[0])
        guard key.isVMHashable else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "Dictionary key \(key) lacks VM-defined Hashable semantics"
            )
        }
        return (
            key,
            try parseStoredType(components[1]),
            try parseStoredType(components[2])
        )
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
        indirectErrorType: Bytecode.ValueType?,
        suppressVoidParameter: Bool,
        allocate: (Bytecode.ValueType) throws -> Bytecode.Register
    ) throws -> (
        block: IntermediateRepresentation.Block,
        parameters: [(String, Bytecode.Register)],
        indirectResultAddress: String?,
        indirectErrorAddress: String?,
        indirectValueParameters: [String: Bytecode.ValueType],
        mutableCellParameters: [String: Bytecode.ValueType],
        suppressedVoidParameter: String?,
        erasedMetatypeParameters: [(String, MetatypeIdentity)]
    )? {
        guard let match = match(line, pattern: #"^bb([0-9]+)(?:\((.*)\))?:$"#) else { return nil }
        let id = try parseBlockID(match[0])
        let parameterText = match.count > 1 ? match[1] : ""
        var parameters: [(String, Bytecode.Register)] = []
        var indirectResultAddress: String?
        var indirectErrorAddress: String?
        var indirectValueParameters: [String: Bytecode.ValueType] = [:]
        var mutableCellParameters: [String: Bytecode.ValueType] = [:]
        var suppressedVoidParameter: String?
        var erasedMetatypeParameters: [(String, MetatypeIdentity)] = []
        let erasedByIndex = Dictionary(
            uniqueKeysWithValues: erasedMetatypes.map {
                ($0.physicalIndex, $0.identity)
            }
        )
        if !parameterText.isEmpty {
            let components = splitTopLevel(parameterText)
            let leadingAddressCount = (indirectResultType == nil ? 0 : 1)
                + (indirectErrorType == nil ? 0 : 1)
            if let entryParameterTypes,
               components.count != entryParameterTypes.count
                    + erasedMetatypes.count + leadingAddressCount {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "entry block parameter count differs from its function ABI"
                )
            }
            if let bridgedParameterTypes,
               bridgedParameterTypes.count != components.count {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "bridged block parameter count differs from its Optional payload"
                )
            }
            if suppressVoidParameter, components.count != 1 {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "try_apply normal block has unexpected SIL parameters"
                )
            }
            for (physicalIndex, component) in components.enumerated() {
                guard let value = self.match(component, pattern: #"^(%[0-9]+)\s*:\s*(.+)$"#) else {
                    throw CanonicalSIL.LoweringError.malformedSIL("invalid block parameter \(component)")
                }
                if physicalIndex == 0, let indirectResultType {
                    guard try parseType(value[1])
                            == .address(
                                ValueRepresentation.storable(
                                    indirectResultType
                                )
                            )
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect result address does not match the function result"
                        )
                    }
                    indirectResultAddress = value[0]
                    continue
                }
                let indirectErrorIndex = indirectResultType == nil ? 0 : 1
                if let indirectErrorType,
                   physicalIndex == indirectErrorIndex {
                    guard try parseType(value[1])
                            == .address(indirectErrorType)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indirect error address does not match the function error result"
                        )
                    }
                    indirectErrorAddress = value[0]
                    continue
                }
                let logicalPhysicalIndex = physicalIndex - leadingAddressCount
                guard logicalPhysicalIndex >= 0 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "entry block contains an unrecognized ABI address parameter"
                    )
                }
                if let identity = erasedByIndex[logicalPhysicalIndex] {
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
                        bridgedTo: bridgedParameterTypes[logicalPhysicalIndex]
                    )
                } else {
                    let parsed = try parseType(value[1])
                    physicalType = suppressVoidParameter
                        ? parsed
                        : ValueRepresentation.storable(parsed)
                }
                if suppressVoidParameter {
                    guard physicalIndex == 0, physicalType == .void else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "try_apply normal block parameter is not Void"
                        )
                    }
                    suppressedVoidParameter = value[0]
                    continue
                }
                let logicalIndex = parameters.count
                let loweredType: Bytecode.ValueType
                if let entryParameterTypes,
                   entryParameterTypes.indices.contains(logicalIndex),
                   case let .mutableCell(pointee) = entryParameterTypes[logicalIndex],
                   physicalType == .address(pointee),
                   component.contains("@closureCapture") {
                    loweredType = .mutableCell(pointee)
                    mutableCellParameters[value[0]] = pointee
                } else if let entryParameterTypes,
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
            indirectErrorAddress,
            indirectValueParameters,
            mutableCellParameters,
            suppressedVoidParameter,
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

    private func parseArrayOrderingPlan(
        operation: CanonicalSIL.OrderingIntrinsic,
        genericArguments: String,
        argumentText: String,
        line: Int
    ) throws -> ArrayOrderingPlan {
        guard operation.usesClosure else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "natural ordering does not use try_apply lowering"
            )
        }
        let genericSpellings = splitTopLevel(genericArguments)
            .filter { !$0.isEmpty }
        let genericTypes = try genericSpellings.map(parseType)
        let arguments = try parseApplyValueTokens(argumentText, line: line)
        guard genericTypes.count == 1,
              case let .array(element) = genericTypes[0]
        else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "ordering requires a represented Array specialization"
            )
        }

        switch operation {
        case .sortedBy:
            guard arguments.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Sequence.sorted(by:) has unsupported arguments"
                )
            }
            return .init(
                operation: operation,
                sourceToken: arguments[1],
                closureToken: arguments[0],
                resultDestination: nil,
                elementType: element
            )
        case .sortBy:
            guard arguments.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "MutableCollection.sort(by:) has unsupported arguments"
                )
            }
            switch typeEnvironment.collectionIndexModel(
                for: genericSpellings[0]
            ) {
            case .zeroBasedInteger:
                break
            case .preservedBaseInteger, .opaque:
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "mutating comparator ordering requires zero-based Array indices"
                )
            }
            return .init(
                operation: operation,
                sourceToken: arguments[1],
                closureToken: arguments[0],
                resultDestination: nil,
                elementType: element
            )
        case .partition:
            guard arguments.count == 3 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "MutableCollection.partition(by:) has unsupported arguments"
                )
            }
            switch typeEnvironment.collectionIndexModel(
                for: genericSpellings[0]
            ) {
            case .zeroBasedInteger:
                break
            case .preservedBaseInteger:
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "partition requires preserved indices for \(genericSpellings[0])"
                )
            case .opaque:
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "partition requires a represented index for \(genericSpellings[0])"
                )
            }
            return .init(
                operation: operation,
                sourceToken: arguments[2],
                closureToken: arguments[1],
                resultDestination: arguments[0],
                elementType: element
            )
        case .sorted, .sort:
            throw CanonicalSIL.LoweringError.malformedSIL(
                "natural ordering reached comparator plan parsing"
            )
        }
    }

    private func parseArraySplitPlan(
        operation: CanonicalSIL.SplitIntrinsic,
        genericArguments: String,
        argumentText: String,
        line: Int
    ) throws -> ArraySplitPlan {
        let genericTypes = try splitTopLevel(genericArguments)
            .filter { !$0.isEmpty }
            .map(parseType)
        let arguments = try parseApplyValueTokens(argumentText, line: line)
        guard genericTypes.count == 1,
              case let .array(element) = genericTypes[0],
              arguments.count == 4
        else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "split requires a represented Array-backed Collection"
            )
        }
        switch operation {
        case .separator:
            return .init(
                sourceToken: arguments[3],
                decisionToken: arguments[0],
                maximumSplitsToken: arguments[1],
                omittingEmptySubsequencesToken: arguments[2],
                elementType: element
            )
        case .predicate:
            return .init(
                sourceToken: arguments[3],
                decisionToken: arguments[2],
                maximumSplitsToken: arguments[0],
                omittingEmptySubsequencesToken: arguments[1],
                elementType: element
            )
        }
    }

    private func parseCollectionHigherOrderPlan(
        operation: CanonicalSIL.HigherOrderIntrinsic,
        genericArguments: String,
        argumentText: String,
        line: Int
    ) throws -> CollectionHigherOrderPlan {
        let genericSpellings = splitTopLevel(genericArguments)
            .filter { !$0.isEmpty }
        let genericTypes = try genericSpellings.map(parseType)
        let arguments = try parseApplyValueTokens(argumentText, line: line)

        func managedCollectionElement(
            _ type: Bytecode.ValueType
        ) throws -> Bytecode.ValueType {
            switch type {
            case let .array(element), let .set(element):
                return element
            case let .dictionary(key, value):
                return .tuple([key, value])
            default:
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "higher-order collection \(type)"
                )
            }
        }

        func arrayElement(
            _ type: Bytecode.ValueType
        ) throws -> Bytecode.ValueType {
            guard case let .array(element) = type else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "Array-backed higher-order result \(type)"
                )
            }
            return element
        }

        switch operation {
        case .map:
            guard genericTypes.count == 3, arguments.count == 3 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Collection.map has an unsupported specialization"
                )
            }
            let input = try managedCollectionElement(genericTypes[0])
            let mapped = ValueRepresentation.storable(genericTypes[1])
            return .init(
                operation: operation,
                sourceToken: arguments[2],
                sourceType: genericTypes[0],
                closureToken: arguments[1],
                initialToken: nil,
                resultDestination: nil,
                errorDestination: arguments[0],
                inputType: input,
                closureResultType: genericTypes[1],
                callResultType: .array(mapped)
            )
        case .flatMap:
            guard genericTypes.count == 2, arguments.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Sequence.flatMap has an unsupported specialization"
                )
            }
            let input = try managedCollectionElement(genericTypes[0])
            let mapped = try arrayElement(genericTypes[1])
            return .init(
                operation: operation,
                sourceToken: arguments[1],
                sourceType: genericTypes[0],
                closureToken: arguments[0],
                initialToken: nil,
                resultDestination: nil,
                errorDestination: nil,
                inputType: input,
                closureResultType: genericTypes[1],
                callResultType: .array(mapped)
            )
        case .filter:
            guard arguments.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Collection.filter has an unsupported specialization"
                )
            }
            if genericTypes.count == 1 {
                let input: Bytecode.ValueType
                let sourceType: Bytecode.ValueType
                let consumesSource: Bool
                switch genericTypes[0] {
                case let .array(element):
                    input = element
                    sourceType = genericTypes[0]
                    consumesSource = false
                default:
                    // Unlike the generic `_ArrayProtocol` overload, the Set
                    // specialization carries only `Element` as a generic
                    // argument; reconstruct its concrete source container.
                    input = ValueRepresentation.storable(genericTypes[0])
                    sourceType = .set(input)
                    consumesSource = true
                }
                return .init(
                    operation: operation,
                    sourceToken: arguments[1],
                    sourceType: sourceType,
                    closureToken: arguments[0],
                    initialToken: nil,
                    resultDestination: nil,
                    errorDestination: nil,
                    inputType: input,
                    closureResultType: .bool,
                    callResultType: sourceType,
                    consumesSource: consumesSource
                )
            }
            if genericTypes.count == 2 {
                let key = ValueRepresentation.storable(genericTypes[0])
                let value = ValueRepresentation.storable(genericTypes[1])
                let sourceType = Bytecode.ValueType.dictionary(
                    key: key,
                    value: value
                )
                return .init(
                    operation: operation,
                    sourceToken: arguments[1],
                    sourceType: sourceType,
                    closureToken: arguments[0],
                    initialToken: nil,
                    resultDestination: nil,
                    errorDestination: nil,
                    inputType: .tuple([key, value]),
                    closureResultType: .bool,
                    callResultType: sourceType,
                    callbackShape: .dictionaryKeyValue,
                    consumesSource: true
                )
            }
            throw CanonicalSIL.LoweringError.malformedSIL(
                "Collection.filter has an unsupported specialization"
            )
        case .compactMap:
            guard genericTypes.count == 2, arguments.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Sequence.compactMap has an unsupported specialization"
                )
            }
            let input = try managedCollectionElement(genericTypes[0])
            let mapped = ValueRepresentation.storable(genericTypes[1])
            return .init(
                operation: operation,
                sourceToken: arguments[1],
                sourceType: genericTypes[0],
                closureToken: arguments[0],
                initialToken: nil,
                resultDestination: nil,
                errorDestination: nil,
                inputType: input,
                closureResultType: .optional(mapped),
                callResultType: .array(mapped)
            )
        case .mapValues, .compactMapValues:
            guard genericTypes.count == 3, arguments.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Dictionary value transform has an unsupported specialization"
                )
            }
            let key = ValueRepresentation.storable(genericTypes[0])
            let value = ValueRepresentation.storable(genericTypes[1])
            let mapped = ValueRepresentation.storable(genericTypes[2])
            return .init(
                operation: operation,
                sourceToken: arguments[1],
                sourceType: .dictionary(key: key, value: value),
                closureToken: arguments[0],
                initialToken: nil,
                resultDestination: nil,
                errorDestination: nil,
                inputType: .tuple([key, value]),
                closureResultType: operation == .mapValues
                    ? mapped : .optional(mapped),
                callResultType: .dictionary(key: key, value: mapped),
                callbackShape: .dictionaryValue
            )
        case .prefixWhile, .dropWhile:
            let supportsDirectResult = operation == .prefixWhile
            guard genericTypes.count == 1,
                  arguments.count == 3
                    || supportsDirectResult && arguments.count == 2
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "prefix/drop(while:) has an unsupported specialization"
                )
            }
            let input = try arrayElement(genericTypes[0])
            let hasIndirectResult = arguments.count == 3
            return .init(
                operation: operation,
                sourceToken: arguments[arguments.count - 1],
                sourceType: genericTypes[0],
                closureToken: arguments[arguments.count - 2],
                initialToken: nil,
                resultDestination: hasIndirectResult ? arguments[0] : nil,
                errorDestination: nil,
                inputType: input,
                closureResultType: .bool,
                callResultType: .array(input)
            )
        case .reduce:
            guard genericTypes.count == 2, arguments.count == 4 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Sequence.reduce has an unsupported specialization"
                )
            }
            let input = try managedCollectionElement(genericTypes[0])
            let accumulator = ValueRepresentation.storable(genericTypes[1])
            return .init(
                operation: operation,
                sourceToken: arguments[3],
                sourceType: genericTypes[0],
                closureToken: arguments[2],
                initialToken: arguments[1],
                resultDestination: arguments[0],
                errorDestination: nil,
                inputType: input,
                closureResultType: genericTypes[1],
                callResultType: accumulator
            )
        case .reduceInto:
            guard genericTypes.count == 2, arguments.count == 4 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Sequence.reduce(into:_:) has an unsupported specialization"
                )
            }
            let input = try managedCollectionElement(genericTypes[0])
            let accumulator = ValueRepresentation.storable(genericTypes[1])
            return .init(
                operation: operation,
                sourceToken: arguments[3],
                sourceType: genericTypes[0],
                closureToken: arguments[2],
                initialToken: arguments[1],
                resultDestination: arguments[0],
                errorDestination: nil,
                inputType: input,
                closureResultType: .void,
                callResultType: accumulator
            )
        case .forEach, .firstWhere, .lastWhere, .firstIndexWhere,
             .lastIndexWhere, .containsWhere, .allSatisfy,
             .minimumBy, .maximumBy:
            let hasIndirectResult = operation == .firstWhere
                || operation == .lastWhere
                || operation == .firstIndexWhere
                || operation == .lastIndexWhere
                || operation.isComparatorSelection
            let expectedArgumentCount = hasIndirectResult ? 3 : 2
            guard genericTypes.count == 1,
                  arguments.count == expectedArgumentCount
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Sequence predicate operation has an unsupported specialization"
                )
            }
            let input = try managedCollectionElement(genericTypes[0])
            if operation.traversalDirection == .reverse {
                guard case .array = genericTypes[0] else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "reverse higher-order traversal requires a represented Array"
                    )
                }
            }
            if operation == .firstIndexWhere
                || operation == .lastIndexWhere {
                switch typeEnvironment.collectionIndexModel(
                    for: genericSpellings[0]
                ) {
                case .zeroBasedInteger:
                    break
                case .preservedBaseInteger:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "predicate index search requires preserved indices for "
                            + genericSpellings[0]
                    )
                case .opaque:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "predicate index search requires a represented index for "
                            + genericSpellings[0]
                    )
                }
            }
            let closureResult: Bytecode.ValueType = operation == .forEach
                ? .void : .bool
            let callResult: Bytecode.ValueType = switch operation {
            case .forEach: .void
            case .firstWhere, .lastWhere: .optional(input)
            case .firstIndexWhere, .lastIndexWhere: .optional(.int64)
            case .containsWhere, .allSatisfy: .bool
            case .minimumBy, .maximumBy: .optional(input)
            case .map, .flatMap, .filter, .compactMap, .mapValues,
                 .compactMapValues, .prefixWhile, .dropWhile, .reduce,
                 .reduceInto:
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "predicate operation dispatch is inconsistent"
                )
            }
            return .init(
                operation: operation,
                sourceToken: arguments[expectedArgumentCount - 1],
                sourceType: genericTypes[0],
                closureToken: arguments[expectedArgumentCount - 2],
                initialToken: nil,
                resultDestination: hasIndirectResult ? arguments[0] : nil,
                errorDestination: nil,
                inputType: input,
                closureResultType: closureResult,
                callResultType: callResult
            )
        }
    }

    private func parseBlockNumber(_ line: String) -> UInt32? {
        guard let values = match(line.trimmingCharacters(in: .whitespaces), pattern: #"^bb([0-9]+)"#) else { return nil }
        return UInt32(values[0])
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

    private struct FloatingUnary {
        var result: String
        var operand: String
        var operation: Bytecode.FloatUnaryOperation
        var bitWidth: UInt16
    }

    private struct FloatingTernary {
        var result: String
        var multiplicand: String
        var multiplier: String
        var addend: String
        var operation: Bytecode.FloatTernaryOperation
        var bitWidth: UInt16
    }

    private func parseFloatingTernary(_ line: String) -> FloatingTernary? {
        guard let parts = match(
            line,
            pattern: #"^(%[0-9]+) = builtin "int_fma_FPIEEE(32|64)"\((%[0-9]+), (%[0-9]+), (%[0-9]+)\).*$"#
        ), let bitWidth = UInt16(parts[1]) else { return nil }
        return FloatingTernary(
            result: parts[0],
            multiplicand: parts[2],
            multiplier: parts[3],
            addend: parts[4],
            operation: .fusedMultiplyAdd,
            bitWidth: bitWidth
        )
    }

    private func parseFloatingUnary(_ line: String) -> FloatingUnary? {
        guard let parts = match(
            line,
            pattern: #"^(%[0-9]+) = builtin "(fneg|int_fabs|int_round|int_rint|int_trunc|int_ceil|int_floor)_FPIEEE(32|64)"\((%[0-9]+)\).*$"#
        ), let bitWidth = UInt16(parts[2]) else { return nil }
        let operation: Bytecode.FloatUnaryOperation = switch parts[1] {
        case "fneg": .negate
        case "int_fabs": .absolute
        case "int_round": .roundToNearestOrAwayFromZero
        case "int_rint": .roundToNearestOrEven
        case "int_trunc": .roundTowardZero
        case "int_ceil": .roundUp
        default: .roundDown
        }
        return FloatingUnary(
            result: parts[0],
            operand: parts[3],
            operation: operation,
            bitWidth: bitWidth
        )
    }

    private struct IntegerUnary {
        var result: String
        var operand: String
        var zeroIsUndefinedFlag: String?
        var operation: Bytecode.IntegerUnaryOperation
        var bitWidth: UInt16
    }

    private func parseIntegerUnary(_ line: String) -> IntegerUnary? {
        if let parts = match(
            line,
            pattern: #"^(%[0-9]+) = builtin "int_(ctpop|bswap)_Int(8|16|32|64)"\((%[0-9]+)\).*$"#
        ), let bitWidth = UInt16(parts[2]) {
            return IntegerUnary(
                result: parts[0],
                operand: parts[3],
                zeroIsUndefinedFlag: nil,
                operation: parts[1] == "ctpop"
                    ? .nonzeroBitCount
                    : .byteSwapped,
                bitWidth: bitWidth
            )
        }
        guard let parts = match(
            line,
            pattern: #"^(%[0-9]+) = builtin "int_(ctlz|cttz)_Int(8|16|32|64)"\((%[0-9]+), (%[0-9]+)\).*$"#
        ), let bitWidth = UInt16(parts[2]) else { return nil }
        return IntegerUnary(
            result: parts[0],
            operand: parts[3],
            zeroIsUndefinedFlag: parts[4],
            operation: parts[1] == "ctlz"
                ? .leadingZeroBitCount
                : .trailingZeroBitCount,
            bitWidth: bitWidth
        )
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

    /// SIL integer literals are fixed-width APInt payloads. Negative decimal
    /// spellings are sign-extended text for those same bits; they are not proof
    /// that the eventual Swift value is signed.
    private static func integerLiteralBitPattern(
        _ spelling: String,
        bitWidth: UInt16
    ) -> UInt64? {
        guard [1, 8, 16, 32, 64].contains(bitWidth) else { return nil }
        let mask = bitWidth == 64
            ? UInt64.max
            : (UInt64(1) << bitWidth) - 1
        if spelling.hasPrefix("-") {
            guard let value = Int64(spelling) else { return nil }
            let minimum = bitWidth == 64
                ? Int64.min
                : -(Int64(1) << (bitWidth - 1))
            guard value >= minimum else { return nil }
            return UInt64(bitPattern: value) & mask
        }
        guard let value = UInt64(spelling), value <= mask else { return nil }
        return value
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
