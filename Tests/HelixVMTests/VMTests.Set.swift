import HelixBytecode
import Testing
@testable import HelixVM

extension VMTests {
@Suite("HLVM Set value semantics")
struct SetSemantics {
    @Test("Set storage preserves order while equality and hashing ignore it")
    func deterministicStorageAndUnorderedEquality() throws {
        let one = try integer(1)
        let two = try integer(2)
        let lhs = VM.SetValue(
            elements: [one, two, one],
            elementType: .int64
        )
        let rhs = VM.SetValue(
            elements: [two, one],
            elementType: .int64
        )

        #expect(lhs.elements == [one, two])
        #expect(lhs == rhs)

        var lhsHasher = Hasher()
        lhs.hash(into: &lhsHasher)
        var rhsHasher = Hasher()
        rhs.hash(into: &rhsHasher)
        #expect(lhsHasher.finalize() == rhsHasher.finalize())
    }

    @Test("Copied NaN Sets remain reflexive without equating independent storage")
    func preservesSwiftCopyIdentityForNaN() {
        let nan = VM.Value.float64(.nan)
        let original = VM.SetValue(
            elements: [nan],
            elementType: .float(bitWidth: 64)
        )
        let copy = original
        let independent = VM.SetValue(
            elements: [nan],
            elementType: .float(bitWidth: 64)
        )
        let duplicates = VM.SetValue(
            elements: [nan, nan],
            elementType: .float(bitWidth: 64)
        )

        #expect(original == original)
        #expect(original == copy)
        #expect(original != independent)
        #expect(duplicates.elements.count == 2)

        let array = VM.Value.array([nan], elementType: .float(bitWidth: 64))
        let arrayCopy = array
        let independentArray = VM.Value.array(
            [nan],
            elementType: .float(bitWidth: 64)
        )
        #expect(VM.HashableValue.equal(array, arrayCopy))
        #expect(!VM.HashableValue.equal(array, independentArray))

        let dictionary = VM.Value.dictionary(
            [.init(key: .string("nan"), value: nan)],
            keyType: .string,
            valueType: .float(bitWidth: 64)
        )
        let dictionaryCopy = dictionary
        let independentDictionary = VM.Value.dictionary(
            [.init(key: .string("nan"), value: nan)],
            keyType: .string,
            valueType: .float(bitWidth: 64)
        )
        #expect(VM.HashableValue.equal(dictionary, dictionaryCopy))
        #expect(!VM.HashableValue.equal(dictionary, independentDictionary))
    }

    @Test("VM Hashable semantics recurse through unordered collections")
    func recursivelyComparesCollectionValues() throws {
        let one = try integer(1)
        let two = try integer(2)
        let keyType = Bytecode.ValueType.string
        let valueType = Bytecode.ValueType.int64
        let lhs = VM.Value.dictionary(
            [
                .init(key: .string("one"), value: one),
                .init(key: .string("two"), value: two),
            ],
            keyType: keyType,
            valueType: valueType
        )
        let rhs = VM.Value.dictionary(
            [
                .init(key: .string("two"), value: two),
                .init(key: .string("one"), value: one),
            ],
            keyType: keyType,
            valueType: valueType
        )

        #expect(VM.HashableValue.equal(lhs, rhs))
        let set = VM.SetValue(
            elements: [lhs, rhs],
            elementType: .dictionary(key: keyType, value: valueType)
        )
        #expect(set.elements.count == 1)

        let ordered = VM.Value.array([one, two], elementType: .int64)
        let reversed = VM.Value.array([two, one], elementType: .int64)
        #expect(!VM.HashableValue.equal(ordered, reversed))
    }

    @Test("Deterministic fingerprints agree for every exercised equal shape")
    func deterministicFingerprintsRespectEquality() throws {
        let composed = VM.Value.string("é")
        let decomposed = VM.Value.string("e\u{301}")
        #expect(VM.HashableValue.equal(composed, decomposed))
        #expect(
            VM.HashableValue.deterministicFingerprint(composed)
                == VM.HashableValue.deterministicFingerprint(decomposed)
        )

        let positiveZero = VM.Value.float64(0.0)
        let negativeZero = VM.Value.float64(-0.0)
        #expect(VM.HashableValue.equal(positiveZero, negativeZero))
        #expect(
            VM.HashableValue.deterministicFingerprint(positiveZero)
                == VM.HashableValue.deterministicFingerprint(negativeZero)
        )

        let one = try integer(1)
        let two = try integer(2)
        let lhs = VM.Value.dictionary(
            [
                .init(key: .string("one"), value: one),
                .init(key: .string("two"), value: two),
            ],
            keyType: .string,
            valueType: .int64
        )
        let rhs = VM.Value.dictionary(
            [
                .init(key: .string("two"), value: two),
                .init(key: .string("one"), value: one),
            ],
            keyType: .string,
            valueType: .int64
        )
        #expect(VM.HashableValue.equal(lhs, rhs))
        #expect(
            VM.HashableValue.deterministicFingerprint(lhs)
                == VM.HashableValue.deterministicFingerprint(rhs)
        )
    }

    @Test("Nested unordered equality reports its temporary VM storage")
    func accountsForEqualityScratchStorage() throws {
        let one = try integer(1)
        let nested = VM.Value.set(
            .init(elements: [one], elementType: .int64)
        )
        let dictionary = VM.Value.dictionary(
            [.init(key: .string("one"), value: nested)],
            keyType: .string,
            valueType: .set(.int64)
        )

        // Dictionary indexing charges two logical slots per entry plus its
        // header; the nested Set charges one slot plus its header.
        #expect(
            try VM.HashableValue.equalityScratchBytes(for: dictionary)
                == UInt64((2 + 1 + 1 + 1) * 16)
        )
        #expect(try VM.HashableValue.equalityScratchBytes(for: one) == 0)
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try VM.Integer(
                signed: value,
                bitWidth: 64,
                isSigned: true
            )
        )
    }
}
}
