import Foundation
import HelixBytecode
import HelixCore
import HelixVM
import Testing
@testable import HelixRuntime

extension RuntimeTests {
@Suite("Swift Any bridge")
struct AnyBridge {
    private struct NativeSnapshot: Hashable, Sendable {
        var count: Int
    }

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
            erased.dynamicType == .dictionary(key: .string, value: .any)
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

        let floatPayload = Float(bitPattern: 0x7FA1_2345)
        let decodedFloat = try #require(
            Runtime.BridgeValueCodec.decodeAny(
                Runtime.BridgeValueCodec.encodeAny(floatPayload)
            ) as? Float
        )
        #expect(decodedFloat.bitPattern == floatPayload.bitPattern)

        let doublePayload = Double(bitPattern: 0x7FF0_0000_0000_1234)
        let decodedDouble = try #require(
            Runtime.BridgeValueCodec.decodeAny(
                Runtime.BridgeValueCodec.encodeAny(doublePayload)
            ) as? Double
        )
        #expect(decodedDouble.bitPattern == doublePayload.bitPattern)

        let exactInt64 = try Runtime.BridgeValueCodec.decodeAny(
            Runtime.BridgeValueCodec.encodeAny(Int64(64))
        )
        #expect(exactInt64 as? Int64 == 64)
        #expect(exactInt64 is Int == false)
        let exactUInt64 = try Runtime.BridgeValueCodec.decodeAny(
            Runtime.BridgeValueCodec.encodeAny(UInt64(64))
        )
        #expect(exactUInt64 as? UInt64 == 64)
        #expect(exactUInt64 is UInt == false)
    }

    @Test("Recursive codecs preserve text and collection identities")
    func preservesRecursiveConcreteShapes() throws {
        let first: Set<Character> = ["e\u{301}", "👨‍👩‍👧‍👦"]
        let second: Set<Character> = ["🇨🇳"]
        let input: [String: [Set<Character>?]] = [
            "values": [first, nil, second],
        ]

        let encoded = try Runtime.BridgeValueCodec.encodeAny(input)
        guard case let .any(erased) = encoded else {
            Issue.record("expected an Any VM value")
            return
        }
        #expect(
            erased.dynamicType == .dictionary(
                key: .string,
                value: .array(.optional(.set(.character)))
            )
        )
        let decoded = try #require(
            Runtime.BridgeValueCodec.decodeAny(encoded)
                as? [String: [Set<Character>?]]
        )
        #expect(decoded == input)

        let substrings: Set<Substring> = ["alpha", "beta"]
        let decodedSubstrings = try #require(
            Runtime.BridgeValueCodec.decodeAny(
                Runtime.BridgeValueCodec.encodeAny(substrings)
            ) as? Set<Substring>
        )
        #expect(decodedSubstrings == substrings)

        let compositeKeys: [[Int?]: Set<Substring>] = [
            [1, nil]: ["first", "second"],
            [2]: ["third"],
        ]
        let decodedCompositeKeys = try #require(
            Runtime.BridgeValueCodec.decodeAny(
                Runtime.BridgeValueCodec.encodeAny(compositeKeys)
            ) as? [[Int?]: Set<Substring>]
        )
        #expect(decodedCompositeKeys == compositeKeys)

        let cgFloat = CGFloat(12.5)
        let decodedCGFloat = try Runtime.BridgeValueCodec.decodeAny(
            Runtime.BridgeValueCodec.encodeAny(cgFloat)
        )
        #expect(decodedCGFloat as? CGFloat == cgFloat)
        #expect(decodedCGFloat is Double == false)
    }

    @Test("Authenticated native references materialize through recursive Any")
    func materializesNativeReferencesWithCatalog() throws {
        let typeID = Core.TypeID(rawValue: .sha256("AnyBridge.NativeReference"))
        let catalog = try VM.NativeTypeCatalog([
            .objectiveCReference(
                id: typeID,
                canonicalName: "Foundation.NSObject",
                layoutFingerprint: .sha256("AnyBridge.NativeReference.Layout"),
                referenceClass: NSObject.self,
                accepts: { _ in true }
            ),
        ])
        let object = NSObject()
        let encoded = try Runtime.BridgeValueCodec.encodeAny(
            object,
            nativeTypeCatalog: catalog
        )
        guard case let .any(erased) = encoded else {
            Issue.record("expected a native Any payload")
            return
        }
        #expect(erased.dynamicType == .native(typeID))

        let decoded = try Runtime.BridgeValueCodec.decodeAny(
            encoded,
            nativeTypeCatalog: catalog
        ) as AnyObject
        #expect(ObjectIdentifier(decoded) == ObjectIdentifier(object))
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try Runtime.BridgeValueCodec.decodeAny(encoded)
        }
        #expect(throws: Runtime.BridgeInputError.self) {
            _ = try Runtime.BridgeValueCodec.encodeAny(object)
        }

        let array = try Runtime.BridgeValueCodec.encodeAny(
            [object],
            nativeTypeCatalog: catalog
        )
        let decodedArray = try Runtime.BridgeValueCodec.decodeAny(
            array,
            nativeTypeCatalog: catalog
        )
        guard let first = Mirror(reflecting: decodedArray).children.first?.value else {
            Issue.record("expected an array containing the native reference")
            return
        }
        #expect(Mirror(reflecting: decodedArray).children.count == 1)
        #expect(
            ObjectIdentifier(first as AnyObject) == ObjectIdentifier(object)
        )
    }

    @Test("Authenticated native values materialize through recursive Any")
    func materializesNativeValuesWithCatalog() throws {
        let typeID = Core.TypeID(rawValue: .sha256("AnyBridge.NativeSnapshot"))
        let typeName = String(reflecting: NativeSnapshot.self)
        let catalog = try VM.NativeTypeCatalog([
            .opaqueValue(
                id: typeID,
                canonicalName: typeName,
                layoutFingerprint: .sha256("AnyBridge.NativeSnapshot.Layout"),
                clone: { (value: NativeSnapshot) in value }
            ),
        ])
        let snapshot = NativeSnapshot(count: 7)

        let encoded = try Runtime.BridgeValueCodec.encodeAny(
            snapshot,
            nativeTypeCatalog: catalog
        )
        guard let decoded = try Runtime.BridgeValueCodec.decodeAny(
            encoded,
            nativeTypeCatalog: catalog
        ) as? NativeSnapshot else {
            Issue.record("expected the authenticated native value")
            return
        }
        #expect(decoded == snapshot)

        let encodedArray = try Runtime.BridgeValueCodec.encodeAny(
            [snapshot],
            nativeTypeCatalog: catalog
        )
        guard let decodedArray = try Runtime.BridgeValueCodec.decodeAny(
            encodedArray,
            nativeTypeCatalog: catalog
        ) as? [NativeSnapshot] else {
            Issue.record("expected an array of authenticated native values")
            return
        }
        #expect(decodedArray == [snapshot])
    }

    @Test("Any rejects native values whose frozen ownership is noncopyable")
    func rejectsNoncopyableNativeValues() throws {
        let typeID = Core.TypeID(rawValue: .sha256("AnyBridge.Noncopyable"))
        let typeName = String(reflecting: NativeSnapshot.self)
        let catalog = try VM.NativeTypeCatalog([
            .init(
                id: typeID,
                canonicalName: typeName,
                kind: .value,
                layoutFingerprint: .sha256("AnyBridge.Noncopyable.Layout"),
                isCopyable: false,
                estimatedSize: 8,
                clone: { (value: NativeSnapshot) in value }
            ),
        ])
        let snapshot = NativeSnapshot(count: 7)
        #expect(throws: Runtime.BridgeInputError.self) {
            _ = try Runtime.BridgeValueCodec.encodeAny(
                snapshot,
                nativeTypeCatalog: catalog
            )
        }

        let boxed = try catalog.box(snapshot, as: typeID)
        let erased = VM.Value.any(
            .init(dynamicType: .native(typeID), payload: .native(boxed))
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try Runtime.BridgeValueCodec.decodeAny(
                erased,
                nativeTypeCatalog: catalog
            )
        }
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

        do {
            _ = try Runtime.BridgeValueCodec.encodeAny([1, 2, 3][1...])
            Issue.record("expected ArraySlice to be rejected at the Shell boundary")
        } catch let error as Runtime.BridgeInputError {
            guard case let .unsupportedAnyType(type) = error else {
                Issue.record("unexpected bridge error: \(error)")
                return
            }
            #expect(type.contains("ArraySlice<Swift.Int>"))
        }

        let unsupported = VM.Value.any(
            .init(
                dynamicType: .tuple([
                    .init(type: .bool),
                    .init(type: .bool),
                ]),
                payload: .tuple([.bool(true), .bool(false)])
            )
        )
        #expect(
            throws: VM.RuntimeTrap.nativeFailure(
                "Swift Any boundary cannot materialize (Bool, Bool)"
            )
        ) {
            _ = try Runtime.BridgeValueCodec.decodeAny(unsupported)
        }

        let malformedNested = VM.Value.any(
            .init(
                dynamicType: .array(.any),
                payload: .array(
                    [
                        .any(
                            .init(
                                dynamicType: .character,
                                payload: .string("multiple characters")
                            )
                        ),
                    ],
                    elementType: .any
                )
            )
        )
        #expect(
            throws: VM.RuntimeTrap.typeMismatch(expected: .any, actual: .any)
        ) {
            _ = try Runtime.BridgeValueCodec.decodeAny(malformedNested)
        }
    }
}
}
