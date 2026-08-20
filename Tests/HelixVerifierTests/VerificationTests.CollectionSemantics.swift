import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("HLBC collection value verification")
struct CollectionSemantics {
    @Test("Equatable and Comparable classification is recursive and fail-closed")
    func classifiesValueSemantics() {
        let recursive = Bytecode.ValueType.optional(
            .array(.dictionary(key: .string, value: .set(.int64)))
        )
        #expect(recursive.isVMEquatable)
        #expect(recursive.isVMHashable)
        #expect(!recursive.isVMComparable)
        #expect(Bytecode.ValueType.string.isVMComparable)
        #expect(!Bytecode.ValueType.bool.isVMComparable)
        #expect(!Bytecode.ValueType.any.isVMEquatable)
        #expect(
            Bytecode.ValueType.dictionary(key: .string, value: .int64)
                .managedCollectionElement == .tuple([.string, .int64])
        )
        #expect(Bytecode.ValueType.bool.managedCollectionElement == nil)

        var tooDeep = Bytecode.ValueType.int64
        for _ in 0..<33 { tooDeep = .optional(tooDeep) }
        #expect(!tooDeep.isVMEquatable)
    }

    @Test("Managed Collection materialization verifies one generic element shape")
    func verifiesManagedCollectionMaterialization() throws {
        let set = Bytecode.ValueType.set(.int64)
        let integers = Bytecode.ValueType.array(.int64)
        _ = try verify(
            fixture(
                parameterTypes: [set],
                resultType: integers,
                registerTypes: [set, integers],
                instruction: .collectionMaterialize(
                    result: register(1),
                    collection: register(0)
                )
            )
        )

        let dictionary = Bytecode.ValueType.dictionary(
            key: .string,
            value: .int64
        )
        let pairs = Bytecode.ValueType.array(.tuple([.string, .int64]))
        _ = try verify(
            fixture(
                parameterTypes: [dictionary],
                resultType: pairs,
                registerTypes: [dictionary, pairs],
                instruction: .collectionMaterialize(
                    result: register(1),
                    collection: register(0)
                )
            )
        )

        try expectInvalid(
            fixture(
                parameterTypes: [set],
                resultType: .array(.string),
                registerTypes: [set, .array(.string)],
                instruction: .collectionMaterialize(
                    result: register(1),
                    collection: register(0)
                )
            ),
            reason: "collection_materialize requires an Array, Dictionary, or Set and its matching element Array"
        )
        try expectInvalid(
            fixture(
                parameterTypes: [.int64],
                resultType: integers,
                registerTypes: [.int64, integers],
                instruction: .collectionMaterialize(
                    result: register(1),
                    collection: register(0)
                )
            ),
            reason: "collection_materialize requires an Array, Dictionary, or Set and its matching element Array"
        )
    }

    @Test("Recursive Array relations and equality are accepted")
    func acceptsRecursiveEquality() throws {
        let dictionary = Bytecode.ValueType.dictionary(
            key: .string,
            value: .int64
        )
        let array = Bytecode.ValueType.array(dictionary)
        _ = try verify(
            fixture(
                parameterTypes: [array, array],
                resultType: .bool,
                registerTypes: [array, array, .bool],
                instruction: .arrayRelation(
                    result: register(2),
                    operation: .startsWith,
                    lhs: register(0),
                    rhs: register(1)
                )
            )
        )
        _ = try verify(
            fixture(
                parameterTypes: [array, array],
                resultType: .bool,
                registerTypes: [array, array, .bool],
                instruction: .compare(
                    result: register(2),
                    predicate: .equal,
                    lhs: register(0),
                    rhs: register(1)
                )
            )
        )
    }

    @Test("Collection instructions reject forged result and constraint types")
    func rejectsInvalidCollectionShapes() throws {
        let intArray = Bytecode.ValueType.array(.int64)
        try expectInvalid(
            fixture(
                parameterTypes: [intArray, .int64],
                resultType: .bool,
                registerTypes: [intArray, .int64, .bool],
                instruction: .arraySearch(
                    result: register(2),
                    operation: .firstIndex,
                    array: register(0),
                    value: register(1)
                )
            ),
            reason: "array_search requires a matching VM-Equatable element and Optional<Int> result"
        )

        let boolArray = Bytecode.ValueType.array(.bool)
        try expectInvalid(
            fixture(
                parameterTypes: [boolArray],
                resultType: .optional(.bool),
                registerTypes: [boolArray, .optional(.bool)],
                instruction: .arrayExtremum(
                    result: register(1),
                    operation: .minimum,
                    array: register(0)
                )
            ),
            reason: "array_extremum requires a VM-Comparable Array and Optional<Element> result"
        )
        try expectInvalid(
            fixture(
                parameterTypes: [boolArray, boolArray],
                resultType: .bool,
                registerTypes: [boolArray, boolArray, .bool],
                instruction: .arrayRelation(
                    result: register(2),
                    operation: .lexicographicallyPrecedes,
                    lhs: register(0),
                    rhs: register(1)
                )
            ),
            reason: "array_relation element lacks the required VM value semantics"
        )
    }

    @Test("Ordering predicates cannot manufacture Comparable for Bool")
    func rejectsSyntheticOrdering() throws {
        try expectInvalid(
            fixture(
                parameterTypes: [.bool, .bool],
                resultType: .bool,
                registerTypes: [.bool, .bool, .bool],
                instruction: .compare(
                    result: register(2),
                    predicate: .lessThan,
                    lhs: register(0),
                    rhs: register(1)
                )
            ),
            reason: "comparison predicate is unavailable for Bool"
        )
    }

    @Test("Array adapters verify operation-specific generic result shapes")
    func acceptsGenericArrayAdapters() throws {
        let strings = Bytecode.ValueType.array(.string)
        let enumerated = Bytecode.ValueType.array(
            .tuple([.int64, .string])
        )
        _ = try verify(
            fixture(
                parameterTypes: [strings],
                resultType: enumerated,
                registerTypes: [strings, enumerated],
                instruction: .arrayAdapter(
                    result: register(1),
                    operation: .enumerated,
                    array: register(0)
                )
            )
        )

        let integers = Bytecode.ValueType.array(.int64)
        let zipped = Bytecode.ValueType.array(
            .tuple([.string, .int64])
        )
        _ = try verify(
            fixture(
                parameterTypes: [strings, integers],
                resultType: zipped,
                registerTypes: [strings, integers, zipped],
                instruction: .arrayZip(
                    result: register(2),
                    lhs: register(0),
                    rhs: register(1)
                )
            )
        )

        let nested = Bytecode.ValueType.array(integers)
        _ = try verify(
            fixture(
                parameterTypes: [nested, integers],
                resultType: integers,
                registerTypes: [nested, integers, integers],
                instruction: .arrayJoined(
                    result: register(2),
                    arrays: register(0),
                    separator: register(1)
                )
            )
        )
    }

    @Test("Array adapters reject forged bounds and element shapes")
    func rejectsInvalidArrayAdapters() throws {
        let integers = Bytecode.ValueType.array(.int64)
        try expectInvalid(
            fixture(
                parameterTypes: [integers],
                resultType: integers,
                registerTypes: [integers, integers],
                instruction: .arrayAdapter(
                    result: register(1),
                    operation: .enumerated,
                    array: register(0)
                )
            ),
            reason: "array_adapter result does not match its operation"
        )

        try expectInvalid(
            fixture(
                parameterTypes: [integers, .bool],
                resultType: integers,
                registerTypes: [integers, .bool, integers],
                instruction: .arraySubsequence(
                    result: register(2),
                    operation: .prefix,
                    array: register(0),
                    bound: register(1)
                )
            ),
            reason: "array_subsequence requires matching Arrays and an Int bound"
        )

        let strings = Bytecode.ValueType.array(.string)
        let wrongZip = Bytecode.ValueType.array(
            .tuple([.int64, .int64])
        )
        try expectInvalid(
            fixture(
                parameterTypes: [integers, strings],
                resultType: wrongZip,
                registerTypes: [integers, strings, wrongZip],
                instruction: .arrayZip(
                    result: register(2),
                    lhs: register(0),
                    rhs: register(1)
                )
            ),
            reason: "array_zip result must contain both Array elements"
        )
    }

    @Test("Collection adapters track recursively owned native results")
    func tracksNativeCollectionResults() throws {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.verifier.collection",
            buildNumber: "1",
            seed: "adapter-native"
        )
        let typeID = Core.TypeID.derive(
            namespace: namespace,
            canonicalType: "Fixture.Reference"
        )
        let native = Bytecode.ValueType.native(typeID)
        let array = Bytecode.ValueType.array(native)
        var adapterFixture = try fixture(
            parameterTypes: [array],
            resultType: array,
            registerTypes: [array, array],
            instruction: .arrayAdapter(
                result: register(1),
                operation: .reversed,
                array: register(0)
            ),
            cleanup: [.destroyValue(register(0))]
        )
        adapterFixture.module.capabilities.insert(.nativeTypesV1)
        adapterFixture.shell.capabilities.insert(.nativeTypesV1)
        adapterFixture.policy.acceptedCapabilities.insert(.nativeTypesV1)
        adapterFixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.Reference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.Reference.layout.v1"),
            isCopyable: true,
            estimatedSize: 8
        )

        _ = try verify(adapterFixture)

        var materializationFixture = try fixture(
            parameterTypes: [array],
            resultType: array,
            registerTypes: [array, array],
            instruction: .collectionMaterialize(
                result: register(1),
                collection: register(0)
            ),
            cleanup: [.destroyValue(register(0))]
        )
        materializationFixture.module.capabilities.insert(.nativeTypesV1)
        materializationFixture.shell.capabilities.insert(.nativeTypesV1)
        materializationFixture.policy.acceptedCapabilities.insert(.nativeTypesV1)
        materializationFixture.shell.types = adapterFixture.shell.types

        _ = try verify(materializationFixture)

        var noncopyableFixture = materializationFixture
        noncopyableFixture.shell.types[typeID] = .init(
            id: typeID,
            canonicalName: "Fixture.Reference",
            kind: .reference,
            layoutFingerprint: .sha256("Fixture.Reference.layout.v1"),
            isCopyable: false,
            estimatedSize: 8
        )
        try expectInvalid(
            noncopyableFixture,
            reason: "collection_materialize requires a copyable element type"
        )
    }

    private struct Fixture {
        var module: Bytecode.Module
        var shell: Verification.ShellInterface
        var policy: Core.RuntimePolicy
    }

    private func fixture(
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        registerTypes: [Bytecode.ValueType],
        instruction: Bytecode.Instruction,
        cleanup: [Bytecode.Instruction] = []
    ) throws -> Fixture {
        let result = register(registerTypes.count - 1)
        let parameters = parameterTypes.indices.map(register)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "collectionSemantics",
            parameterRegisters: parameters,
            resultType: resultType,
            registerTypes: registerTypes,
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: parameters,
                    instructions: [instruction] + cleanup + [
                        .returnValue(result),
                    ]
                ),
            ]
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "collection-verifier-fixture"
        )
        let hash = Core.Digest.sha256("collection-verifier-shell")
        let capabilities: Set<Core.Capability> = [
            .baselineV1,
            .collectionsV1,
            .stringsV1,
        ]
        let key = try functionKey()
        let module = Bytecode.Module(
            name: "CollectionVerifierFixture",
            shellInterfaceHash: hash,
            compatibility: compatibility,
            capabilities: capabilities,
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
            interfaceHash: hash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: key,
                    parameterTypes: parameterTypes,
                    resultType: resultType
                ),
            ]
        )
        return .init(
            module: module,
            shell: shell,
            policy: .init(acceptedCapabilities: capabilities)
        )
    }

    private func expectInvalid(
        _ fixture: Fixture,
        reason: String
    ) throws {
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: reason
            )
        ) {
            try verify(fixture)
        }
    }

    private func verify(_ fixture: Fixture) throws -> Verification.Image {
        try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(fixture.module),
            shell: fixture.shell,
            policy: fixture.policy
        )
    }

    private func functionKey() throws -> Core.FunctionKey {
        try .derive(
            namespace: .derive(
                bundleID: "dev.helix.verifier.collection",
                buildNumber: "1",
                seed: "fixture"
            ),
            module: "Fixture",
            sourceFileLogicalID: "Collection.swift",
            canonicalDeclaration: "func collectionSemantics()",
            loweredSignature: .init(parameters: [], result: "Swift.Void"),
            role: .function
        )
    }

    private func register(_ index: Int) -> Bytecode.Register {
        .init(rawValue: UInt32(index))
    }
}
}
