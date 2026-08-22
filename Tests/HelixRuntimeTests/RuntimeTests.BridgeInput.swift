import Foundation
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

    private struct DescribedError: Error, CustomStringConvertible {
        var description: String { "this description must not cross the boundary" }
    }

    private final class UIReference {}
}
}
