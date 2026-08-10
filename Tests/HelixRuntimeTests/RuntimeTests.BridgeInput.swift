import HelixBytecode
import HelixCore
import HelixVM
import Testing
@testable import HelixRuntime

extension RuntimeTests {
@Suite("Bridge input encoding limits")
struct BridgeInput {
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

    private func makeEncoder(
        _ limits: Runtime.BridgeInputLimits = .init()
    ) -> Runtime.BridgeValueCodec.Encoder {
        .init(limits: limits)
    }

    private enum SyntheticDeadline: Error, Equatable {
        case expired
    }

    private final class UIReference {}
}
}
