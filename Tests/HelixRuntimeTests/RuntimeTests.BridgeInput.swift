import Foundation
import HelixBytecode
import HelixCore
import Testing
@testable import HelixRuntime
@testable import HelixVM

extension RuntimeTests {
@Suite("Bridge input encoding limits")
struct BridgeInput {
    private final class InvocationResult: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: VM.RuntimeTrap?

        var trap: VM.RuntimeTrap? {
            lock.withLock { storage }
        }

        func record(_ trap: VM.RuntimeTrap?) {
            lock.withLock { storage = trap }
        }
    }

    @Test("Scoped encoding preserves nested aggregate shapes")
    func aggregateRoundTrip() throws {
        let encoder = makeEncoder()
        let value = try encoder.encodeDictionary(
            ["numbers": [Int32(3), Int32(5)]],
            keyType: .string,
            valueType: .array(.integer(bitWidth: 32, signed: true)),
            encodeKey: { try encoder.encode($0) },
            encodeValue: { values in
                try encoder.encodeArray(
                    values,
                    elementType: .integer(bitWidth: 32, signed: true)
                ) { try encoder.encode($0) }
            }
        )
        try encoder.finalize(arguments: [value])

        guard case let .dictionary(entries, .string, valueType) = value else {
            Issue.record("expected a Dictionary VM value")
            return
        }
        #expect(valueType == .array(.integer(bitWidth: 32, signed: true)))
        #expect(entries.count == 1)
        #expect(entries[0].key == .string("numbers"))
    }

    @Test("Frozen struct and enum codecs validate their complete logical shapes")
    func frozenValueCodecsRoundTrip() throws {
        let structKey = Bytecode.LocalTypeKey(rawValue: "Fixture.Snapshot")
        let enumKey = Bytecode.LocalTypeKey(rawValue: "Fixture.Mode")
        let fieldTypes: [Bytecode.ValueType] = [
            .int64,
            .optional(.string),
        ]
        let encoder = makeEncoder()
        let structure = try encoder.encodeStructure(
            type: structKey,
            fieldTypes: fieldTypes
        ) {
            [
                try encoder.encode(Int64(7)),
                try encoder.encodeOptional("Helix") {
                    try encoder.encode($0)
                },
            ]
        }
        let enumeration = try encoder.encodeEnumeration(
            type: enumKey,
            caseIndex: 2,
            payloadType: .tuple([.string])
        ) {
            try encoder.encodeTuple(count: 1) {
                [try encoder.encode("named")]
            }
        }
        try encoder.finalize(arguments: [structure, enumeration])

        #expect(
            try Runtime.BridgeValueCodec.decodeStructure(
                structure,
                type: structKey,
                fieldTypes: fieldTypes
            ) == [
                .integer(try VM.Integer(signed: 7, bitWidth: 64, isSigned: true)),
                .optional(.string("Helix")),
            ]
        )
        let decoded = try Runtime.BridgeValueCodec.decodeEnumeration(
            enumeration,
            type: enumKey,
            payloadTypes: [nil, .int64, .tuple([.string])]
        )
        #expect(decoded.caseIndex == 2)
        #expect(decoded.payload == .tuple([.string("named")]))

        #expect(throws: Runtime.BridgeInputError.invalidContainerCount) {
            _ = try Runtime.BridgeValueCodec.encodeStructure(
                type: structKey,
                fieldTypes: [.int64],
                fields: []
            )
        }
        #expect(
            throws: Runtime.BridgeInputError.encodedTypeMismatch(
                expected: Bytecode.ValueType.int64.description,
                actual: Bytecode.ValueType.bool.description
            )
        ) {
            _ = try Runtime.BridgeValueCodec.encodeStructure(
                type: structKey,
                fieldTypes: [.int64],
                fields: [.bool(true)]
            )
        }
        #expect(throws: Runtime.BridgeInputError.invalidContainerCount) {
            _ = try Runtime.BridgeValueCodec.encodeEnumeration(
                type: enumKey,
                caseIndex: 0,
                payloadType: nil,
                payload: .bool(true)
            )
        }
        #expect(
            throws: VM.RuntimeTrap.typeMismatch(
                expected: .local(structKey),
                actual: .local(enumKey)
            )
        ) {
            _ = try Runtime.BridgeValueCodec.decodeStructure(
                enumeration,
                type: structKey,
                fieldTypes: fieldTypes
            )
        }
        #expect(
            throws: VM.RuntimeTrap.nativeFailure(
                "indexed Shell struct field count does not match its verified definition"
            )
        ) {
            _ = try Runtime.BridgeValueCodec.decodeStructure(
                .structure(type: structKey, fields: []),
                type: structKey,
                fieldTypes: fieldTypes
            )
        }
        #expect(
            throws: VM.RuntimeTrap.nativeFailure(
                "indexed Shell enum case index is outside its verified definition"
            )
        ) {
            _ = try Runtime.BridgeValueCodec.decodeEnumeration(
                .enumeration(type: enumKey, caseIndex: 3, payload: nil),
                type: enumKey,
                payloadTypes: [nil]
            )
        }
        #expect(
            throws: VM.RuntimeTrap.nativeFailure(
                "indexed Shell enum payload presence does not match its verified case"
            )
        ) {
            _ = try Runtime.BridgeValueCodec.decodeEnumeration(
                .enumeration(type: enumKey, caseIndex: 0, payload: .bool(true)),
                type: enumKey,
                payloadTypes: [nil]
            )
        }
    }

    @Test("Frozen aggregate encoding reserves shape, bytes, nodes, and depth first")
    func frozenValueEncodingIsResourceBounded() throws {
        let key = Bytecode.LocalTypeKey(rawValue: "Fixture.Value")
        var callbacks = 0
        let nodeLimited = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 1_024,
                maximumValueNodes: 2,
                maximumNestingDepth: 8,
                maximumContainerElements: 8
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.valueNodeLimitExceeded(maximum: 2)
        ) {
            _ = try nodeLimited.encodeStructure(
                type: key,
                fieldTypes: [.bool, .bool]
            ) {
                callbacks += 1
                return [try nodeLimited.encode(true), try nodeLimited.encode(false)]
            }
        }
        #expect(callbacks == 0)

        let byteLimited = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 47,
                maximumValueNodes: 8,
                maximumNestingDepth: 8,
                maximumContainerElements: 8
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.estimatedVMByteLimitExceeded(
                maximum: 47
            )
        ) {
            _ = try byteLimited.encodeStructure(
                type: key,
                fieldTypes: [.bool, .bool]
            ) {
                [try byteLimited.encode(true), try byteLimited.encode(false)]
            }
        }

        let depthLimited = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 1_024,
                maximumValueNodes: 8,
                maximumNestingDepth: 1,
                maximumContainerElements: 8
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.nestingDepthLimitExceeded(maximum: 1)
        ) {
            _ = try depthLimited.encodeEnumeration(
                type: key,
                caseIndex: 0,
                payloadType: .tuple([.bool])
            ) {
                try depthLimited.encodeTuple(count: 1) {
                    [try depthLimited.encode(true)]
                }
            }
        }
    }

    @Test("Container shape is rejected before element encoding begins")
    func preflightsContainerShape() throws {
        let encoder = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 1_024,
                maximumValueNodes: 3,
                maximumNestingDepth: 8,
                maximumContainerElements: 16
            )
        )
        var callbackCount = 0

        #expect(throws: Runtime.BridgeInputError.valueNodeLimitExceeded(maximum: 3)) {
            _ = try encoder.encodeArray(
                [1, 2, 3],
                elementType: .int64
            ) { value in
                callbackCount += 1
                return try encoder.encode(Int64(value))
            }
        }
        #expect(callbackCount == 0)
    }

    @Test("Root arguments are preflighted and constrained by patch fuel")
    func preflightsRootArgumentsAndFuel() throws {
        let limits = Runtime.BridgeInputLimits(
            maximumEstimatedVMBytes: 1_024,
            maximumValueNodes: 100,
            maximumNestingDepth: 8,
            maximumContainerElements: 100
        )
        let effective = limits.constrained(
            by: .init(instructionFuelPerEntry: 3)
        )
        #expect(effective.maximumValueNodes == 3)
        #expect(effective.maximumContainerElements == 3)

        let encoder = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 1_024,
                maximumValueNodes: 16,
                maximumNestingDepth: 8,
                maximumContainerElements: 1
            )
        )
        var didBuild = false
        #expect(
            throws: Runtime.BridgeInputError.containerElementLimitExceeded(
                actual: 2,
                maximum: 1
            )
        ) {
            _ = try encoder.encodeArguments(count: 2) {
                didBuild = true
                return [try encoder.encode(true), try encoder.encode(false)]
            }
        }
        #expect(!didBuild)
    }

    @Test("Aggregate bytes are reserved before collection allocation")
    func preflightsAggregateBytes() throws {
        let encoder = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 31,
                maximumValueNodes: 16,
                maximumNestingDepth: 8,
                maximumContainerElements: 16
            )
        )
        var callbackCount = 0

        #expect(
            throws: Runtime.BridgeInputError.estimatedVMByteLimitExceeded(maximum: 31)
        ) {
            _ = try encoder.encodeArray([true], elementType: .bool) { value in
                callbackCount += 1
                return try encoder.encode(value)
            }
        }
        #expect(callbackCount == 0)
    }

    @Test("UTF-8 bytes and recursive depth have independent limits")
    func stringAndDepthLimits() throws {
        let stringEncoder = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 3,
                maximumValueNodes: 16,
                maximumNestingDepth: 8,
                maximumContainerElements: 16
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.estimatedVMByteLimitExceeded(maximum: 3)
        ) {
            _ = try stringEncoder.encode("Helix")
        }

        let depthEncoder = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 1_024,
                maximumValueNodes: 16,
                maximumNestingDepth: 2,
                maximumContainerElements: 16
            )
        )
        let nested: Int64?? = .some(.some(7))
        #expect(
            throws: Runtime.BridgeInputError.nestingDepthLimitExceeded(maximum: 2)
        ) {
            _ = try depthEncoder.encodeOptional(nested) { wrapped in
                try depthEncoder.encodeOptional(wrapped) {
                    try depthEncoder.encode($0)
                }
            }
        }
    }

    @Test("Element type mismatches and untracked values fail closed")
    func rejectsInvalidEncoderUse() throws {
        let mismatched = makeEncoder()
        #expect(
            throws: Runtime.BridgeInputError.encodedTypeMismatch(
                expected: Bytecode.ValueType.int64.description,
                actual: Bytecode.ValueType.bool.description
            )
        ) {
            _ = try mismatched.encodeArray([true], elementType: .int64) {
                try mismatched.encode($0)
            }
        }

        let collidingSet = makeEncoder()
        #expect(throws: Runtime.BridgeInputError.duplicateEncodedSetElement) {
            _ = try collidingSet.encodeSet(
                Set([1, 2]),
                elementType: .int64
            ) { _ in
                try collidingSet.encode(Int64(0))
            }
        }

        let unsupportedSet = makeEncoder()
        #expect(
            throws: Runtime.BridgeInputError.encodedTypeMismatch(
                expected: "a VM-defined Hashable Set element",
                actual: Bytecode.ValueType.tuple([.int64]).description
            )
        ) {
            _ = try unsupportedSet.encodeSet(
                Set([1]),
                elementType: .tuple([.int64])
            ) { value in
                try unsupportedSet.encode(Int64(value))
            }
        }

        let collidingDictionary = makeEncoder()
        #expect(throws: Runtime.BridgeInputError.duplicateEncodedDictionaryKey) {
            _ = try collidingDictionary.encodeDictionary(
                [1: "one", 2: "two"],
                keyType: .int64,
                valueType: .string,
                encodeKey: { _ in try collidingDictionary.encode(Int64(0)) },
                encodeValue: { try collidingDictionary.encode($0) }
            )
        }

        let untracked = makeEncoder()
        #expect(throws: Runtime.BridgeInputError.untrackedEncodedValue) {
            try untracked.finalize(arguments: [.string("not encoded")])
        }
        #expect(throws: Runtime.BridgeInputError.encoderAlreadyFinished) {
            _ = try untracked.encode(true)
        }
    }

    @Test("Native values use a separate owned-byte budget")
    func nativeByteLimit() throws {
        let typeID = Core.TypeID(rawValue: .sha256("BridgeInput.Native"))
        let catalog = try VM.NativeTypeCatalog([
            .init(
                id: typeID,
                canonicalName: "Fixture.Native",
                kind: .value,
                layoutFingerprint: .sha256("BridgeInput.Native.Layout"),
                estimatedSize: 1,
                estimatedByteCount: { (_: Int64) in 128 }
            ),
        ])
        let encoder = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 1_024,
                maximumEstimatedNativeBytes: 127,
                maximumValueNodes: 16,
                maximumNestingDepth: 8,
                maximumContainerElements: 16
            )
        )

        #expect(
            throws: Runtime.BridgeInputError.estimatedNativeByteLimitExceeded(maximum: 127)
        ) {
            _ = try encoder.encodeNative(Int64(9), as: typeID, catalog: catalog)
        }
    }

    @Test("Native callables are identity-bearing leaves with bounded results")
    func nativeClosureRoundTrip() throws {
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .bool
        )
        let encoder = makeEncoder()
        let encoded = try encoder.encodeNativeClosure(
            signature: signature
        ) { arguments, resultEncoder in
            guard case let .integer(value) = arguments.first else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .int64,
                    actual: arguments.first?.type
                )
            }
            return try resultEncoder.encode(value.signedValue == 42)
        }
        try encoder.finalize(arguments: [encoded])

        guard case let .closure(closure) = encoded,
              let nativeClosure = closure.nativeTarget
        else {
            Issue.record("expected a native-origin VM closure")
            return
        }
        let result = try nativeClosure.invoke(
            arguments: [
                .integer(
                    try .init(signed: 42, bitWidth: 64, isSigned: true)
                ),
            ],
            budget: .init(limits: .init())
        )
        #expect(result == .bool(true))

        let mismatchedEncoder = makeEncoder()
        let mismatched = try mismatchedEncoder.encodeNativeClosure(
            signature: signature
        ) { _, resultEncoder in
            try resultEncoder.encode(Int64(1))
        }
        try mismatchedEncoder.finalize(arguments: [mismatched])
        guard case let .closure(mismatchedValue) = mismatched,
              let mismatchedClosure = mismatchedValue.nativeTarget
        else {
            Issue.record("expected a mismatched native-origin VM closure")
            return
        }
        #expect(throws: VM.RuntimeTrap.typeMismatch(
            expected: .bool,
            actual: .int64
        )) {
            _ = try mismatchedClosure.invoke(
                arguments: [
                    .integer(
                        try .init(signed: 42, bitWidth: 64, isSigned: true)
                    ),
                ],
                budget: .init(limits: .init())
            )
        }

        let substituted = makeEncoder()
        _ = try substituted.encodeNativeClosure(
            signature: signature
        ) { _, resultEncoder in
            try resultEncoder.encode(false)
        }
        let imageClosure = VM.Value.closure(
            .init(
                functionID: .init(rawValue: 7),
                signature: signature,
                captures: []
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.encodedTypeMismatch(
                expected: "a bridge-created native closure",
                actual: imageClosure.type.description
            )
        ) {
            try substituted.finalize(arguments: [imageClosure])
        }
    }

    @Test("NativeImport results use one bounded encoder for returned callables")
    func nativeImportCallableResultEncoding() throws {
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 1_000,
            allowsMainThread: true
        )
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000)
        )
        let context = try budget.beginNativeInvocation(
            id: .init(rawValue: 0),
            effects: .init(),
            contract: contract
        )
        let encoded = try Runtime.BridgeValueCodec.encodeNativeImportResult(
            expectedType: .closure(signature),
            context: context
        ) { encoder in
            try encoder.encodeNativeClosure(signature: signature) {
                arguments,
                resultEncoder in
                guard case let .integer(value) = arguments.first else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: .int64,
                        actual: arguments.first?.type
                    )
                }
                return try resultEncoder.encode(value.signedValue + 1)
            }
        }
        try context.finish(requireCooperation: false)
        guard case let .closure(closure) = encoded,
              let nativeClosure = closure.nativeTarget
        else {
            Issue.record("expected a returned native-origin callable")
            return
        }
        let result = try nativeClosure.invoke(
            arguments: [
                .integer(
                    try .init(signed: 41, bitWidth: 64, isSigned: true)
                ),
            ],
            budget: .init(limits: .init())
        )
        #expect(
            result == .integer(
                try .init(signed: 42, bitWidth: 64, isSigned: true)
            )
        )

        let rejectedBudget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000)
        )
        let rejectedContext = try rejectedBudget.beginNativeInvocation(
            id: .init(rawValue: 1),
            effects: .init(),
            contract: contract
        )
        defer { try? rejectedContext.finish(requireCooperation: false) }
        let imageClosure = VM.Value.closure(
            .init(
                functionID: .init(rawValue: 7),
                signature: signature,
                captures: []
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.encodedTypeMismatch(
                expected: "a bridge-created native closure",
                actual: imageClosure.type.description
            )
        ) {
            _ = try Runtime.BridgeValueCodec.encodeNativeImportResult(
                expectedType: .closure(signature),
                context: rejectedContext
            ) { _ in imageClosure }
        }

        let constrainedBudget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: VM.NativeClosure.estimatedVMByteCount - 1,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        let constrainedContext = try constrainedBudget.beginNativeInvocation(
            id: .init(rawValue: 2),
            effects: .init(),
            contract: contract
        )
        defer { try? constrainedContext.finish(requireCooperation: false) }
        #expect(
            throws: Runtime.BridgeInputError.estimatedVMByteLimitExceeded(
                maximum: VM.NativeClosure.estimatedVMByteCount - 1
            )
        ) {
            _ = try Runtime.BridgeValueCodec.encodeNativeImportResult(
                expectedType: .closure(signature),
                context: constrainedContext
            ) { encoder in
                try encoder.encodeNativeClosure(
                    signature: signature
                ) { _, resultEncoder in
                    try resultEncoder.encode(Int64(0))
                }
            }
        }
    }

    @Test("NativeImport result encoding enforces the exact import deadline")
    func nativeImportResultEncodingDeadline() throws {
        let clock = ControlledClock()
        let importID = Core.NativeImportID(rawValue: 3)
        let budget = VM.InvocationBudget(
            limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            isMainThread: true,
            nowNanoseconds: { clock.now() }
        )
        let context = try budget.beginNativeInvocation(
            id: importID,
            effects: .init(),
            contract: .bounded(
                kind: .globalFunction,
                domain: .application,
                access: .pure,
                maximumDurationMicroseconds: 1_000,
                allowsMainThread: true
            )
        )
        defer { try? context.finish(requireCooperation: false) }
        clock.set(2_000_000)

        #expect(throws: VM.RuntimeTrap.nativeImportDeadlineExceeded(importID)) {
            _ = try Runtime.BridgeValueCodec.encodeNativeImportResult(
                expectedType: .int64,
                context: context
            ) { encoder in
                try encoder.encode(Int64(1))
            }
        }
    }

    @Test("Native callables enforce actor isolation")
    func nativeClosureEnforcesActorIsolation() async throws {
        let mainActorSignature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void,
            effects: .init(requiresMainActor: true)
        )
        let actorEncoder = makeEncoder()
        let actorValue = try actorEncoder.encodeNativeClosure(
            signature: mainActorSignature
        ) { _, _ in nil }
        try actorEncoder.finalize(arguments: [actorValue])
        guard case let .closure(actorVMClosure) = actorValue,
              let actorClosure = actorVMClosure.nativeTarget
        else {
            Issue.record("expected a MainActor native-origin VM closure")
            return
        }
        let actorTrap = await Task.detached { () -> VM.RuntimeTrap? in
            do {
                _ = try actorClosure.invoke(
                    arguments: [],
                    budget: .init(limits: .init(), isMainThread: false)
                )
                return nil
            } catch let trap as VM.RuntimeTrap {
                return trap
            } catch {
                return .nativeFailure(String(describing: error))
            }
        }.value
        #expect(actorTrap == .mainActorViolation)
    }

    @Test("Native callables reject overlapping non-Sendable invocation")
    func nativeClosureRejectsOverlap() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let firstResult = InvocationResult()
        let overlapEncoder = makeEncoder()
        let overlapValue = try overlapEncoder.encodeNativeClosure(
            signature: .init(
                parameters: [],
                parameterConventions: [],
                result: .void
            )
        ) { _, _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
            return nil
        }
        try overlapEncoder.finalize(arguments: [overlapValue])
        guard case let .closure(overlapVMClosure) = overlapValue,
              let overlapClosure = overlapVMClosure.nativeTarget
        else {
            Issue.record("expected an overlap-guarded native-origin VM closure")
            return
        }
        let worker = Thread {
            defer { finished.signal() }
            do {
                _ = try overlapClosure.invoke(
                    arguments: [],
                    budget: .init(limits: .init(), isMainThread: false)
                )
                firstResult.record(nil)
            } catch let trap as VM.RuntimeTrap {
                firstResult.record(trap)
            } catch {
                firstResult.record(.nativeFailure(String(describing: error)))
            }
        }
        worker.start()
        guard entered.wait(timeout: .now() + 10) == .success else {
            release.signal()
            Issue.record("first native callable invocation did not enter")
            _ = finished.wait(timeout: .now() + 10)
            return
        }
        #expect(throws: VM.RuntimeTrap.nativeFailure(
            "concurrent invocation of a non-Sendable native closure is unsupported"
        )) {
            _ = try overlapClosure.invoke(
                arguments: [],
                budget: .init(limits: .init())
            )
        }
        release.signal()
        try #require(finished.wait(timeout: .now() + 10) == .success)
        #expect(firstResult.trap == nil)
    }

    @Test("Bridge can box explicitly cataloged non-Sendable UI references")
    func boxesNonSendableReference() throws {
        let typeID = Core.TypeID(rawValue: .sha256("BridgeInput.UIReference"))
        let operations = VM.NativeTypeOperations.reference(
            id: typeID,
            canonicalName: "Fixture.UIReference",
            layoutFingerprint: .sha256("BridgeInput.UIReference.Layout"),
            describe: { (_: UIReference) in "ui-reference" }
        )
        let catalog = try VM.NativeTypeCatalog([operations])
        let object = UIReference()
        let encoder = makeEncoder()
        let encoded = try encoder.encodeNative(object, as: typeID, catalog: catalog)
        try encoder.finalize(arguments: [encoded])
        let decoded = try Runtime.BridgeValueCodec.decodeNative(
            encoded,
            as: UIReference.self,
            typeID: typeID
        )
        #expect(decoded === object)
    }

    @Test("Streaming and final validation share the invocation deadline")
    func deadlineCoversEncodingAndValidation() throws {
        var checks = 0
        var callbacks = 0
        let streaming = Runtime.BridgeValueCodec.Encoder(
            limits: .init(),
            checkDeadline: {
                checks += 1
                if checks == 2 { throw SyntheticDeadline.expired }
            }
        )
        #expect(throws: SyntheticDeadline.expired) {
            _ = try streaming.encodeArray(
                Array(repeating: true, count: 128),
                elementType: .bool
            ) { value in
                callbacks += 1
                return try streaming.encode(value)
            }
        }
        #expect(callbacks < 128)

        var expired = false
        let validation = Runtime.BridgeValueCodec.Encoder(
            limits: .init(),
            checkDeadline: {
                if expired { throw SyntheticDeadline.expired }
            }
        )
        let value = try validation.encode(true)
        expired = true
        #expect(throws: SyntheticDeadline.expired) {
            try validation.finalize(arguments: [value])
        }
    }

    @Test("Character and Substring use validated normalized text representations")
    func textRepresentationsRoundTrip() throws {
        for character: Character in ["e\u{301}", "👨‍👩‍👧‍👦", "🇨🇳"] {
            let encoded = try Runtime.BridgeValueCodec.encode(character)
            #expect(
                try Runtime.BridgeValueCodec.decode(
                    encoded,
                    as: Character.self
                ) == character
            )
        }

        for malformed in ["", "ab"] {
            #expect(
                throws: VM.RuntimeTrap.explicit(
                    "represented Character must contain exactly one extended grapheme cluster"
                )
            ) {
                _ = try Runtime.BridgeValueCodec.decode(
                    .string(malformed),
                    as: Character.self
                )
            }
        }
        #expect(
            throws: VM.RuntimeTrap.typeMismatch(
                expected: .string,
                actual: .bool
            )
        ) {
            _ = try Runtime.BridgeValueCodec.decode(
                .bool(false),
                as: Character.self
            )
        }

        let source = "A👩🏽‍💻e\u{301}Z"
        let substring = source.dropFirst().dropLast()
        let encoded = try Runtime.BridgeValueCodec.encode(substring)
        #expect(
            encoded == .array(
                [.string("👩🏽‍💻"), .string("e\u{301}")],
                elementType: .string
            )
        )
        #expect(
            try Runtime.BridgeValueCodec.decode(
                encoded,
                as: Substring.self
            ) == substring
        )

        let encoder = makeEncoder()
        let streamed = try encoder.encode(substring)
        try encoder.finalize(arguments: [streamed])
        #expect(
            try Runtime.BridgeValueCodec.decode(
                streamed,
                as: Substring.self
            ) == substring
        )
        #expect(
            throws: VM.RuntimeTrap.explicit(
                "represented Character must contain exactly one extended grapheme cluster"
            )
        ) {
            _ = try Runtime.BridgeValueCodec.decode(
                .array([.string("ab")], elementType: .string),
                as: Substring.self
            )
        }

        let boundedEncoder = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 1_024,
                maximumValueNodes: 16,
                maximumNestingDepth: 8,
                maximumContainerElements: 1
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.containerElementLimitExceeded(
                actual: 2,
                maximum: 1
            )
        ) {
            _ = try boundedEncoder.encode(Substring("ab"))
        }

        let byteBoundedEncoder = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 49,
                maximumValueNodes: 16,
                maximumNestingDepth: 8,
                maximumContainerElements: 16
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.estimatedVMByteLimitExceeded(
                maximum: 49
            )
        ) {
            _ = try byteBoundedEncoder.encode(Substring("ab"))
        }
    }

    @Test("Error existentials cross as bounded opaque proxies")
    func errorBoundaryRoundTrip() throws {
        let encoder = makeEncoder()
        let encoded = try encoder.encodeError(DescribedError())
        try encoder.finalize(arguments: [encoded])

        let expectedIdentity = String(reflecting: DescribedError.self)
        #expect(encoded == .error(.init(message: expectedIdentity)))
        let decoded = try Runtime.BridgeValueCodec.decodeError(encoded)
        #expect(String(describing: decoded) == expectedIdentity)
        #expect((decoded as? LocalizedError)?.errorDescription == expectedIdentity)

        let preserved = VM.Value.error(.init(message: "PatchError.failed"))
        let proxy = try Runtime.BridgeValueCodec.decodeError(preserved)
        #expect(
            try Runtime.BridgeValueCodec.encodeError(proxy)
                == .error(.init(message: "PatchError.failed"))
        )

        let limited = makeEncoder(
            .init(
                maximumEstimatedVMBytes: 1,
                maximumValueNodes: 4,
                maximumNestingDepth: 4,
                maximumContainerElements: 4
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.estimatedVMByteLimitExceeded(
                maximum: 1
            )
        ) {
            _ = try limited.encodeError(DescribedError())
        }
    }

    private func makeEncoder(
        _ limits: Runtime.BridgeInputLimits = .init()
    ) -> Runtime.BridgeValueCodec.Encoder {
        .init(limits: limits)
    }

    private enum SyntheticDeadline: Error, Equatable {
        case expired
    }

    private final class ControlledClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func now() -> UInt64 {
            lock.withLock { value }
        }

        func set(_ value: UInt64) {
            lock.withLock { self.value = value }
        }
    }

    private struct DescribedError: Error, CustomStringConvertible {
        var description: String { "this description must not cross the boundary" }
    }

    private final class UIReference {}
}
}
