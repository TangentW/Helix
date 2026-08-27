import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import Testing
@testable import HelixVM

extension VMTests {
@Suite("HLVM Any execution")
struct AnyExecution {
    private struct NativeSnapshot: Hashable, Sendable {
        let value: Int
    }

    private enum NativeStatus: Equatable, Sendable {
        case ready
    }

    private final class CloneProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var count: Int { lock.withLock { storage } }

        func clone(_ value: NativeSnapshot) -> NativeSnapshot {
            lock.withLock { storage += 1 }
            return value
        }
    }

    @Test("Erasure records the static concrete type and preserves its value")
    func erasesScalarValue() throws {
        let int = try integer(42)
        let function = erasureFunction(sourceType: .integer(.int))
        let image = try makeVerified(
            function: function,
            parameterTypes: [.int64],
            resultType: .any
        )

        #expect(
            VM.Interpreter().invoke(
                function: function.id,
                image: image,
                arguments: [int]
            ) == .returned(
                .any(.init(dynamicType: .integer(.int), payload: int))
            )
        )
    }

    @Test("Copyable native values preserve their identity through Any")
    func nativeValueRoundTrip() throws {
        let typeID = Core.TypeID(rawValue: .sha256("VMAny.NativeSnapshot"))
        let layout = Core.Digest.sha256("VMAny.NativeSnapshot.Layout")
        let operations = VM.NativeTypeOperations.opaqueValue(
            id: typeID,
            canonicalName: "Fixture.NativeSnapshot",
            layoutFingerprint: layout,
            estimatedSize: 8,
            clone: { (value: NativeSnapshot) in value }
        )
        let catalog = try VM.NativeTypeCatalog([operations])
        let boxed = try catalog.box(NativeSnapshot(value: 42), as: typeID)
        let resolvedType = Verification.ResolvedNativeType(
            id: typeID,
            canonicalName: "Fixture.NativeSnapshot",
            kind: .value,
            layoutFingerprint: layout,
            isCopyable: true,
            estimatedSize: 8
        )

        let erase = erasureFunction(sourceType: .native(typeID))
        let eraseImage = try makeVerified(
            function: erase,
            parameterTypes: [.native(typeID)],
            resultType: .any,
            nativeTypes: [resolvedType]
        )
        let erased = VM.Value.any(
            .init(dynamicType: .native(typeID), payload: .native(boxed))
        )
        #expect(
            VM.Interpreter(nativeTypeCatalog: catalog).invoke(
                function: erase.id,
                image: eraseImage,
                arguments: [.native(boxed)]
            ) == .returned(erased)
        )

        let roundTrip = nativeAnyRoundTripFunction(typeID: typeID)
        let roundTripImage = try makeVerified(
            function: roundTrip,
            parameterTypes: [.native(typeID)],
            resultType: .native(typeID),
            nativeTypes: [resolvedType]
        )
        #expect(
            VM.Interpreter(nativeTypeCatalog: catalog).invoke(
                function: roundTrip.id,
                image: roundTripImage,
                arguments: [.native(boxed)]
            ) == .returned(.native(boxed))
        )
    }

    @Test("Opaque native enums preserve their enumeration descriptor")
    func opaqueNativeEnumeration() throws {
        let typeID = Core.TypeID(rawValue: .sha256("VMAny.NativeStatus"))
        let layout = Core.Digest.sha256("VMAny.NativeStatus.Layout")
        let operations = VM.NativeTypeOperations.opaqueEnumeration(
            id: typeID,
            canonicalName: "Fixture.NativeStatus",
            layoutFingerprint: layout,
            clone: { (value: NativeStatus) in value }
        )
        let catalog = try VM.NativeTypeCatalog([operations])
        let boxed = try catalog.box(NativeStatus.ready, as: typeID)

        #expect(operations.kind == .enumeration)
        #expect(try catalog.copy(boxed) == boxed)
        #expect(boxed.value(as: NativeStatus.self) == .ready)
    }

    @Test("Development native type catalogs append exact descriptors only")
    func appendsNativeTypeCatalogTransactionally() throws {
        let firstID = Core.TypeID(rawValue: .sha256("VMAny.First"))
        let secondID = Core.TypeID(rawValue: .sha256("VMAny.Second"))
        let firstLayout = Core.Digest.sha256("VMAny.First.Layout")
        let first = VM.NativeTypeOperations.opaqueValue(
            id: firstID,
            canonicalName: "Fixture.First",
            layoutFingerprint: firstLayout,
            estimatedSize: 8,
            clone: { (value: NativeSnapshot) in value }
        )
        let replay = VM.NativeTypeOperations.opaqueValue(
            id: firstID,
            canonicalName: "Fixture.First",
            layoutFingerprint: firstLayout,
            estimatedSize: 8,
            clone: { (value: NativeSnapshot) in value }
        )
        let second = VM.NativeTypeOperations.opaqueValue(
            id: secondID,
            canonicalName: "Fixture.Second",
            layoutFingerprint: .sha256("VMAny.Second.Layout"),
            estimatedSize: 8,
            clone: { (value: NativeSnapshot) in value }
        )
        let catalog = try VM.NativeTypeCatalog([first])
        let extended = try catalog.appending([replay, second])

        #expect(extended[firstID] != nil)
        #expect(extended[secondID] != nil)
        let mismatched = VM.NativeTypeOperations.opaqueValue(
            id: firstID,
            canonicalName: "Fixture.First",
            layoutFingerprint: .sha256("VMAny.First.ChangedLayout"),
            estimatedSize: 8,
            clone: { (value: NativeSnapshot) in value }
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try catalog.appending([mismatched])
        }
        #expect(catalog[secondID] == nil)
    }

    @Test("Casting reusable Any storage materializes a native TypeOps copy")
    func nativeCastCopiesExistentialPayload() throws {
        let typeID = Core.TypeID(rawValue: .sha256("VMAny.CloneSnapshot"))
        let layout = Core.Digest.sha256("VMAny.CloneSnapshot.Layout")
        let probe = CloneProbe()
        let operations = VM.NativeTypeOperations.opaqueValue(
            id: typeID,
            canonicalName: "Fixture.CloneSnapshot",
            layoutFingerprint: layout,
            estimatedSize: 8,
            clone: probe.clone
        )
        let catalog = try VM.NativeTypeCatalog([operations])
        let boxed = try catalog.box(NativeSnapshot(value: 42), as: typeID)
        let resolvedType = Verification.ResolvedNativeType(
            id: typeID,
            canonicalName: "Fixture.CloneSnapshot",
            kind: .value,
            layoutFingerprint: layout,
            isCopyable: true,
            estimatedSize: 8
        )
        let function = castFunction(target: .native(typeID), checked: false)
        let image = try makeVerified(
            function: function,
            parameterTypes: [.any],
            resultType: .native(typeID),
            nativeTypes: [resolvedType]
        )
        let erased = VM.Value.any(
            .init(dynamicType: .native(typeID), payload: .native(boxed))
        )

        #expect(
            VM.Interpreter(nativeTypeCatalog: catalog).invoke(
                function: function.id,
                image: image,
                arguments: [erased]
            ) == .returned(.native(boxed))
        )
        #expect(probe.count == 1)
    }

    @Test("Checked casts and force casts preserve scalar values")
    func scalarCasts() throws {
        let int = try integer(42)
        let checked = castFunction(target: .integer(.int), checked: true)
        let checkedImage = try makeVerified(
            function: checked,
            parameterTypes: [.any],
            resultType: .optional(.int64)
        )
        let interpreter = VM.Interpreter()

        #expect(
            interpreter.invoke(
                function: checked.id,
                image: checkedImage,
                arguments: [.any(.init(dynamicType: .integer(.int), payload: int))]
            ) == .returned(.optional(int))
        )
        #expect(
            interpreter.invoke(
                function: checked.id,
                image: checkedImage,
                arguments: [
                    .any(.init(dynamicType: .string, payload: .string("42"))),
                ]
            ) == .returned(.optional(nil))
        )

        let forced = castFunction(target: .integer(.int), checked: false)
        let forcedImage = try makeVerified(
            function: forced,
            parameterTypes: [.any],
            resultType: .int64
        )
        #expect(
            interpreter.invoke(
                function: forced.id,
                image: forcedImage,
                arguments: [.any(.init(dynamicType: .integer(.int), payload: int))]
            ) == .returned(int)
        )
        #expect(
            interpreter.invoke(
                function: forced.id,
                image: forcedImage,
                arguments: [
                    .any(.init(dynamicType: .string, payload: .string("42"))),
                ]
            ) == .trapped(
                .dynamicCastFailure(
                    actual: .string,
                    expected: .integer(.int)
                )
            )
        )
    }

    @Test("Dynamic Optional casts distinguish failure from a successful nil")
    func optionalNilCasts() throws {
        let target = Bytecode.DynamicType.optional(.string)
        let function = castFunction(target: target, checked: true)
        let image = try makeVerified(
            function: function,
            parameterTypes: [.any],
            resultType: .optional(target.storageType)
        )
        let boxedNil = VM.Value.any(
            .init(
                dynamicType: .optional(.integer(.int)),
                payload: .optional(nil)
            )
        )

        #expect(
            VM.Interpreter().invoke(
                function: function.id,
                image: image,
                arguments: [boxedNil]
            ) == .returned(.optional(.optional(nil)))
        )

        let int = try integer(7)
        let injectedTarget = Bytecode.DynamicType.optional(.integer(.int))
        let injectedFunction = castFunction(
            target: injectedTarget,
            checked: true
        )
        let injectedImage = try makeVerified(
            function: injectedFunction,
            parameterTypes: [.any],
            resultType: .optional(injectedTarget.storageType)
        )
        #expect(
            VM.Interpreter().invoke(
                function: injectedFunction.id,
                image: injectedImage,
                arguments: [
                    .any(.init(dynamicType: .integer(.int), payload: int)),
                ]
            ) == .returned(.optional(.optional(int)))
        )

        let doublyOptional = Bytecode.DynamicType.optional(
            .optional(.integer(.int))
        )
        let nestedFunction = castFunction(
            target: doublyOptional,
            checked: true
        )
        let nestedImage = try makeVerified(
            function: nestedFunction,
            parameterTypes: [.any],
            resultType: .optional(doublyOptional.storageType)
        )
        #expect(
            VM.Interpreter().invoke(
                function: nestedFunction.id,
                image: nestedImage,
                arguments: [
                    .any(
                        .init(
                            dynamicType: .optional(.integer(.int)),
                            payload: .optional(int)
                        )
                    ),
                ]
            ) == .returned(
                .optional(.optional(.optional(int)))
            )
        )
    }

    @Test("Array and Dictionary casts recursively open nested Any values")
    func collectionCasts() throws {
        let one = try integer(1)
        let two = try integer(2)
        let boxedOne = VM.Value.any(
            .init(dynamicType: .integer(.int), payload: one)
        )
        let boxedTwo = VM.Value.any(
            .init(dynamicType: .integer(.int), payload: two)
        )
        let arraySource = VM.Value.any(
            .init(
                dynamicType: .array(.any),
                payload: .array([boxedOne, boxedTwo], elementType: .any)
            )
        )
        let arrayTarget = Bytecode.DynamicType.array(.integer(.int))
        let arrayFunction = castFunction(target: arrayTarget, checked: true)
        let arrayImage = try makeVerified(
            function: arrayFunction,
            parameterTypes: [.any],
            resultType: .optional(arrayTarget.storageType)
        )
        #expect(
            VM.Interpreter().invoke(
                function: arrayFunction.id,
                image: arrayImage,
                arguments: [arraySource]
            ) == .returned(
                .optional(.array([one, two], elementType: .int64))
            )
        )

        let reverseSource = VM.Value.any(
            .init(
                dynamicType: .array(.integer(.int)),
                payload: .array([one, two], elementType: .int64)
            )
        )
        let reverseTarget = Bytecode.DynamicType.array(.any)
        let reverseFunction = castFunction(
            target: reverseTarget,
            checked: true
        )
        let reverseImage = try makeVerified(
            function: reverseFunction,
            parameterTypes: [.any],
            resultType: .optional(reverseTarget.storageType)
        )
        #expect(
            VM.Interpreter().invoke(
                function: reverseFunction.id,
                image: reverseImage,
                arguments: [reverseSource]
            ) == .returned(
                .optional(
                    .array([boxedOne, boxedTwo], elementType: .any)
                )
            )
        )

        let dictionarySource = VM.Value.any(
            .init(
                dynamicType: .dictionary(key: .string, value: .any),
                payload: .dictionary(
                    [
                        .init(key: .string("one"), value: boxedOne),
                        .init(key: .string("two"), value: boxedTwo),
                    ],
                    keyType: .string,
                    valueType: .any
                )
            )
        )
        let dictionaryTarget = Bytecode.DynamicType.dictionary(
            key: .string,
            value: .integer(.int)
        )
        let dictionaryFunction = castFunction(
            target: dictionaryTarget,
            checked: true
        )
        let dictionaryImage = try makeVerified(
            function: dictionaryFunction,
            parameterTypes: [.any],
            resultType: .optional(dictionaryTarget.storageType)
        )
        #expect(
            VM.Interpreter().invoke(
                function: dictionaryFunction.id,
                image: dictionaryImage,
                arguments: [dictionarySource]
            ) == .returned(
                .optional(
                    .dictionary(
                        [
                            .init(key: .string("one"), value: one),
                            .init(key: .string("two"), value: two),
                        ],
                        keyType: .string,
                        valueType: .int64
                    )
                )
            )
        )
    }

    @Test("Dictionary casts trap when keys collide after recursive conversion")
    func dictionaryCastTrapsOnConvertedKeyCollisions() throws {
        let sourceElement = Bytecode.ValueType.optional(.optional(.int64))
        let sourceKey = Bytecode.ValueType.array(sourceElement)
        let sourceDynamicType = Bytecode.DynamicType.dictionary(
            key: .array(.optional(.optional(.integer(.int)))),
            value: .integer(.int)
        )
        let targetDynamicType = Bytecode.DynamicType.dictionary(
            key: .array(.optional(.integer(.int))),
            value: .integer(.int)
        )
        let source = VM.Value.dictionary(
            [
                .init(
                    key: .array(
                        [.optional(nil)],
                        elementType: sourceElement
                    ),
                    value: try integer(1)
                ),
                .init(
                    key: .array(
                        [.optional(.optional(nil))],
                        elementType: sourceElement
                    ),
                    value: try integer(2)
                ),
            ],
            keyType: sourceKey,
            valueType: .int64
        )
        let caster = VM.DynamicCaster(
            budget: .init(
                limits: .init(maxWallTimeMainThreadMilliseconds: 1_000)
            )
        )

        #expect(
            throws: VM.RuntimeTrap.dynamicCastProducedDuplicateDictionaryKey
        ) {
            _ = try caster.cast(
                source,
                from: sourceDynamicType,
                to: targetDynamicType
            )
        }
    }

    @Test("Set casts trap when elements collide after recursive conversion")
    func setCastTrapsOnConvertedElementCollisions() throws {
        let sourceElement = Bytecode.DynamicType.optional(
            .optional(.integer(.int))
        )
        let targetElement = Bytecode.DynamicType.optional(.integer(.int))
        let source = VM.Value.set(
            .init(
                elements: [
                    .optional(nil),
                    .optional(.optional(nil)),
                ],
                elementType: sourceElement.storageType
            )
        )
        let caster = VM.DynamicCaster(
            budget: .init(
                limits: .init(maxWallTimeMainThreadMilliseconds: 1_000)
            )
        )

        #expect(
            throws: VM.RuntimeTrap.dynamicCastProducedDuplicateSetElement
        ) {
            _ = try caster.cast(
                source,
                from: .set(sourceElement),
                to: .set(targetElement)
            )
        }
    }

    @Test("Dynamic collection casts refund transient uniqueness storage")
    func collectionCastRefundsUniquenessStorage() throws {
        let budget = VM.InvocationBudget(
            limits: .init(
                maxVMHeapBytes: 96,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        )
        let caster = VM.DynamicCaster(budget: budget)
        let source = VM.Value.set(
            .init(
                elements: [try integer(1)],
                elementType: .int64
            )
        )

        #expect(
            try caster.cast(
                source,
                from: .set(.integer(.int)),
                to: .set(.optional(.integer(.int)))
            ) == .set(
                .init(
                    elements: [.optional(try integer(1))],
                    elementType: .optional(.int64)
                )
            )
        )
        try budget.consumeVMHeap(bytes: 32)
        #expect(throws: VM.RuntimeTrap.vmHeapLimitExceeded) {
            try budget.consumeVMHeap(bytes: 1)
        }
    }

    @Test("A failed element cast rejects the complete collection")
    func collectionCastIsAtomic() throws {
        let boxedInt = VM.Value.any(
            .init(dynamicType: .integer(.int), payload: try integer(1))
        )
        let boxedString = VM.Value.any(
            .init(dynamicType: .string, payload: .string("two"))
        )
        let source = VM.Value.any(
            .init(
                dynamicType: .array(.any),
                payload: .array([boxedInt, boxedString], elementType: .any)
            )
        )
        let target = Bytecode.DynamicType.array(.integer(.int))
        let function = castFunction(target: target, checked: true)
        let image = try makeVerified(
            function: function,
            parameterTypes: [.any],
            resultType: .optional(target.storageType)
        )

        #expect(
            VM.Interpreter().invoke(
                function: function.id,
                image: image,
                arguments: [source]
            ) == .returned(.optional(nil))
        )
    }

    @Test("Forged existential metadata is rejected before a cast executes")
    func rejectsMalformedExistentials() throws {
        let function = castFunction(target: .integer(.int), checked: true)
        let image = try makeVerified(
            function: function,
            parameterTypes: [.any],
            resultType: .optional(.int64)
        )
        let malformed = VM.Value.any(
            .init(
                dynamicType: .string,
                payload: try integer(1)
            )
        )

        #expect(
            VM.Interpreter().invoke(
                function: function.id,
                image: image,
                arguments: [malformed]
            ) == .trapped(
                .typeMismatch(expected: .string, actual: .int64)
            )
        )

        let unsupported = VM.Value.any(
            .init(dynamicType: .character, payload: .string("not one character"))
        )
        #expect(
            VM.Interpreter().invoke(
                function: function.id,
                image: image,
                arguments: [unsupported]
            ) == .trapped(.typeMismatch(expected: .string, actual: .string))
        )
    }

    @Test("Existential traversal consumes proportional invocation fuel")
    func castTraversalConsumesFuel() throws {
        let elements = try (0..<32).map { try integer(Int64($0)) }
        let boxedElements = elements.map {
            VM.Value.any(.init(dynamicType: .integer(.int), payload: $0))
        }
        let source = VM.Value.any(
            .init(
                dynamicType: .array(.any),
                payload: .array(boxedElements, elementType: .any)
            )
        )
        let target = Bytecode.DynamicType.array(.integer(.int))
        let function = castFunction(target: target, checked: true)
        let limits = Core.ResourceLimits(
            // Boundary ownership consumes 66 units; recursive conversion
            // consumes another 65 and must be the operation that exhausts.
            instructionFuelPerEntry: 100,
            maxWallTimeMainThreadMilliseconds: 1_000
        )
        let passthrough = identityFunction(type: .any)
        let passthroughImage = try makeVerified(
            function: passthrough,
            parameterTypes: [.any],
            resultType: .any,
            limits: limits
        )
        #expect(
            VM.Interpreter().invoke(
                function: passthrough.id,
                image: passthroughImage,
                arguments: [source]
            ) == .returned(source)
        )
        let image = try makeVerified(
            function: function,
            parameterTypes: [.any],
            resultType: .optional(target.storageType),
            limits: limits
        )

        #expect(
            VM.Interpreter().invoke(
                function: function.id,
                image: image,
                arguments: [source]
            ) == .trapped(.instructionFuelExhausted)
        )
    }

    @Test("Existential erasure charges recursive logical validation")
    func erasureValidationConsumesFuel() throws {
        let source = VM.Value.array(
            Array(repeating: .string("a"), count: 32),
            elementType: .string
        )
        let dynamicType = Bytecode.DynamicType.array(.character)
        let function = erasureFunction(sourceType: dynamicType)
        let limits = Core.ResourceLimits(
            // Boundary ownership consumes 65 units; logical Character-array
            // validation consumes another 65 before the Any box is created.
            instructionFuelPerEntry: 100,
            maxWallTimeMainThreadMilliseconds: 1_000
        )
        let passthrough = identityFunction(type: dynamicType.storageType)
        let passthroughImage = try makeVerified(
            function: passthrough,
            parameterTypes: [dynamicType.storageType],
            resultType: dynamicType.storageType,
            limits: limits
        )
        #expect(
            VM.Interpreter().invoke(
                function: passthrough.id,
                image: passthroughImage,
                arguments: [source]
            ) == .returned(source)
        )
        let image = try makeVerified(
            function: function,
            parameterTypes: [dynamicType.storageType],
            resultType: .any,
            limits: limits
        )

        #expect(
            VM.Interpreter().invoke(
                function: function.id,
                image: image,
                arguments: [source]
            ) == .trapped(.instructionFuelExhausted)
        )
    }

    @Test("Boundary validation rejects existential nesting beyond the VM limit")
    func nestingLimit() throws {
        var value = VM.Value.any(
            .init(dynamicType: .integer(.int), payload: try integer(1))
        )
        for _ in 0..<VM.ValueLimits.maximumNestingDepth {
            value = .any(
                .init(
                    dynamicType: .optional(.any),
                    payload: .optional(value)
                )
            )
        }
        let function = castFunction(target: .any, checked: false)
        let image = try makeVerified(
            function: function,
            parameterTypes: [.any],
            resultType: .any
        )

        #expect(
            VM.Interpreter().invoke(
                function: function.id,
                image: image,
                arguments: [value]
            ) == .trapped(
                .valueNestingDepthExceeded(
                    maximum: VM.ValueLimits.maximumNestingDepth
                )
            )
        )
        #expect(!value.matches(Bytecode.ValueType.any))
    }

    private func castFunction(
        target: Bytecode.DynamicType,
        checked: Bool
    ) -> Bytecode.Function {
        let resultType: Bytecode.ValueType = checked
            ? .optional(target.storageType)
            : target.storageType
        let instruction: Bytecode.Instruction = checked
            ? .checkedCastAny(
                result: .init(rawValue: 1),
                value: .init(rawValue: 0),
                targetType: target
            )
            : .forceCastAny(
                result: .init(rawValue: 1),
                value: .init(rawValue: 0),
                targetType: target
            )
        return .init(
            id: .init(rawValue: 0),
            name: checked ? "checkedCast" : "forceCast",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: resultType,
            registerTypes: [.any, resultType],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        instruction,
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
    }

    private func identityFunction(
        type: Bytecode.ValueType
    ) -> Bytecode.Function {
        .init(
            id: .init(rawValue: 0),
            name: "identity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: type,
            registerTypes: [type],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
    }

    private func erasureFunction(
        sourceType: Bytecode.DynamicType
    ) -> Bytecode.Function {
        .init(
            id: .init(rawValue: 0),
            name: "erase",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .any,
            registerTypes: [sourceType.storageType, .any],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .eraseToAny(
                            result: .init(rawValue: 1),
                            value: .init(rawValue: 0),
                            dynamicType: sourceType
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
    }

    private func nativeAnyRoundTripFunction(
        typeID: Core.TypeID
    ) -> Bytecode.Function {
        .init(
            id: .init(rawValue: 0),
            name: "nativeAnyRoundTrip",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .native(typeID),
            registerTypes: [
                .native(typeID),
                .any,
                .any,
                .native(typeID),
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .eraseToAny(
                            result: .init(rawValue: 1),
                            value: .init(rawValue: 0),
                            dynamicType: .native(typeID)
                        ),
                        .copyValue(
                            result: .init(rawValue: 2),
                            source: .init(rawValue: 1)
                        ),
                        .forceCastAny(
                            result: .init(rawValue: 3),
                            value: .init(rawValue: 2),
                            targetType: .native(typeID)
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }

    private func makeVerified(
        function: Bytecode.Function,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        limits: Core.ResourceLimits = .init(
            maxWallTimeMainThreadMilliseconds: 1_000
        ),
        nativeTypes: [Verification.ResolvedNativeType] = []
    ) throws -> Verification.Image {
        let shellHash = Core.Digest.sha256("vm-any-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-vm-any"
        )
        let signature = Core.LoweredSignature(
            parameters: parameterTypes.map(\.description),
            result: resultType.description
        )
        let key = try Core.FunctionKey.derive(
            namespace: .derive(
                bundleID: "dev.helix.vm-any",
                buildNumber: "1",
                seed: "fixture"
            ),
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func cast(_ value: Any) -> Any",
            loweredSignature: signature,
            role: .function
        )
        var capabilities: Set<Core.Capability> = [
            .baselineV1, .stringsV1, .collectionsV1, .anyValuesV1,
        ]
        if !nativeTypes.isEmpty {
            capabilities.insert(.nativeTypesV1)
        }
        let module = Bytecode.Module(
            name: "VMAnyFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            requestedResources: limits,
            functions: [function],
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: key,
                    functionID: function.id
                ),
            ]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: key,
                    parameterTypes: parameterTypes,
                    parameterConventions: function.parameterConventions,
                    resultType: resultType,
                    effects: function.effects
                ),
            ],
            types: nativeTypes
        )
        return try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(
                acceptedCapabilities: capabilities,
                resourceCeiling: limits
            )
        )
    }
}
}
