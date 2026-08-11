import HelixBytecode
import HelixVM
import Testing
@testable import HelixRuntime

extension RuntimeTests {
@Suite("Swift Any bridge")
struct AnyBridge {
    @Test("Heterogeneous standard-library graphs round-trip without native objects")
    func heterogeneousGraphRoundTrip() throws {
        let input: [String: Any] = [
            "count": 3,
            "name": "Helix",
            "flags": [true, false] as [Any],
            "metadata": ["build": 12, "channel": "debug"] as [String: Any],
        ]

        let encoded = try Runtime.BridgeValueCodec.encodeAny(input)
        guard case let .any(erased) = encoded else {
            Issue.record("expected an Any VM value")
            return
        }
        #expect(
            erased.concreteType == .dictionary(key: .string, value: .any)
        )

        let decoded = try #require(
            Runtime.BridgeValueCodec.decodeAny(encoded) as? [String: Any]
        )
        #expect(decoded["count"] as? Int == 3)
        #expect(decoded["name"] as? String == "Helix")
        #expect(decoded["flags"] as? [Any] != nil)
        let metadata = try #require(decoded["metadata"] as? [String: Any])
        #expect(metadata["build"] as? Int == 12)
        #expect(metadata["channel"] as? String == "debug")
    }

    @Test("Scalar optionals and homogeneous scalar arrays preserve their Swift shape")
    func preservesCommonConcreteShapes() throws {
        let integers = try Runtime.BridgeValueCodec.decodeAny(
            Runtime.BridgeValueCodec.encodeAny([1, 2, 3])
        )
        #expect(integers as? [Int] == [1, 2, 3])

        let dictionary = try Runtime.BridgeValueCodec.decodeAny(
            Runtime.BridgeValueCodec.encodeAny(["answer": 42])
        )
        #expect(dictionary as? [String: Int] == ["answer": 42])

        let optional: Int? = nil
        let decodedOptional = try Runtime.BridgeValueCodec.decodeAny(
            Runtime.BridgeValueCodec.encodeAny(optional as Any)
        )
        #expect(
            String(reflecting: Swift.type(of: decodedOptional))
                == "Swift.Optional<Swift.Int>"
        )

        let scalarSamples: [Any] = [
            true, Int8(-8), Int16(-16), Int32(-32), Int(-64),
            UInt8(8), UInt16(16), UInt32(32), UInt(64),
            Float(1.25), Double(2.5), "value",
        ]
        for sample in scalarSamples {
            let decoded = try Runtime.BridgeValueCodec.decodeAny(
                Runtime.BridgeValueCodec.encodeAny(sample)
            )
            #expect(
                String(reflecting: Swift.type(of: decoded))
                    == String(reflecting: Swift.type(of: sample))
            )
        }

        // HLBC deliberately gives Int and Int64 one 64-bit signed identity.
        let canonicalInt = try Runtime.BridgeValueCodec.decodeAny(
            Runtime.BridgeValueCodec.encodeAny(Int64(64))
        )
        #expect(canonicalInt as? Int == 64)
        let canonicalUInt = try Runtime.BridgeValueCodec.decodeAny(
            Runtime.BridgeValueCodec.encodeAny(UInt64(64))
        )
        #expect(canonicalUInt as? UInt == 64)
    }

    @Test("The Any wrapper participates in node and depth accounting")
    func accountsForExistentialContainer() throws {
        let nodeLimited = Runtime.BridgeValueCodec.Encoder(
            limits: .init(
                maximumEstimatedVMBytes: 1_024,
                maximumValueNodes: 1,
                maximumNestingDepth: 8,
                maximumContainerElements: 8
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.valueNodeLimitExceeded(maximum: 1)
        ) {
            _ = try nodeLimited.encodeAny(true)
        }

        let depthLimited = Runtime.BridgeValueCodec.Encoder(
            limits: .init(
                maximumEstimatedVMBytes: 1_024,
                maximumValueNodes: 8,
                maximumNestingDepth: 1,
                maximumContainerElements: 8
            )
        )
        #expect(
            throws: Runtime.BridgeInputError.nestingDepthLimitExceeded(maximum: 1)
        ) {
            _ = try depthLimited.encodeAny(true)
        }

        let exact = Runtime.BridgeValueCodec.Encoder(
            limits: .init(
                maximumEstimatedVMBytes: 1_024,
                maximumValueNodes: 2,
                maximumNestingDepth: 2,
                maximumContainerElements: 8
            )
        )
        let encoded = try exact.encodeAny(true)
        try exact.finalize(arguments: [encoded])
    }

    @Test("Unsupported Swift and VM payloads fail at the boundary")
    func rejectsUnsupportedPayloads() throws {
        struct LocalValue { var count: Int }

        do {
            _ = try Runtime.BridgeValueCodec.encodeAny(LocalValue(count: 1))
            Issue.record("expected a local nominal value to be rejected")
        } catch let error as Runtime.BridgeInputError {
            guard case let .unsupportedAnyType(type) = error else {
                Issue.record("unexpected bridge error: \(error)")
                return
            }
            #expect(type.contains("LocalValue"))
        }

        let unsupported = VM.Value.any(
            .init(
                concreteType: .tuple([.bool]),
                payload: .tuple([.bool(true)])
            )
        )
        #expect(
            throws: VM.RuntimeTrap.nativeFailure(
                "Swift Any boundary cannot materialize (Bool)"
            )
        ) {
            _ = try Runtime.BridgeValueCodec.decodeAny(unsupported)
        }
    }
}
}
