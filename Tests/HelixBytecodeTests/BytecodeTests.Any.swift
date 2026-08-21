import HelixCore
import Testing
@testable import HelixBytecode

extension BytecodeTests {
@Suite("HLBC Any wire contract")
struct AnyWireContract {
    @Test("Any types and instructions round-trip in HLBC 1.0")
    func roundTrip() throws {
        let module = try makeModule()
        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)

        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(decoded.module.capabilities.contains(.anyValuesV1))
    }

    @Test("Any v1 exposes a closed, VM-managed payload set")
    func payloadPolicy() {
        #expect(Bytecode.DynamicType.integer(.int).isAnyPayloadV1)
        #expect(Bytecode.DynamicType.optional(.any).isAnyPayloadV1)
        #expect(Bytecode.DynamicType.array(.any).isAnyPayloadV1)
        #expect(
            Bytecode.DynamicType.dictionary(key: .string, value: .any)
                .isAnyPayloadV1
        )
        #expect(
            Bytecode.DynamicType.dictionary(
                key: .array(.optional(.integer(.int))),
                value: .set(.substring)
            ).isAnyPayloadV1
        )
        #expect(Bytecode.DynamicType.set(.character).isAnyPayloadV1)
        #expect(Bytecode.DynamicType.substring.isAnyPayloadV1)
        #expect(Bytecode.DynamicType.arraySlice(.integer(.int)).isAnyPayloadV1)
        #expect(!Bytecode.DynamicType.any.isAnyPayloadV1)
        #expect(!Bytecode.DynamicType.tuple([]).isAnyPayloadV1)
        #expect(
            !Bytecode.DynamicType.tuple([.init(type: .bool)]).isAnyPayloadV1
        )
        #expect(
            !Bytecode.DynamicType.dictionary(key: .any, value: .string)
                .isAnyPayloadV1
        )
        #expect(
            Bytecode.DynamicType.integer(.int).storageType == .int64
        )
        #expect(
            Bytecode.DynamicType.integer(.int64).storageType == .int64
        )
        #expect(
            Bytecode.DynamicType.floatingPoint(.cgFloat).storageType
                == .float(bitWidth: 64)
        )
        #expect(Bytecode.DynamicType.any.isSwiftBridgeMaterializableV1)
        #expect(
            Bytecode.DynamicType.optional(
                .dictionary(
                    key: .string,
                    value: .array(.integer(.int))
                )
            ).isSwiftBridgeMaterializableV1
        )
        #expect(
            !Bytecode.DynamicType.arraySlice(.integer(.int))
                .isSwiftBridgeMaterializableV1
        )
        #expect(
            !Bytecode.DynamicType.tuple([
                .init(type: .integer(.int)),
                .init(type: .string),
            ]).isSwiftBridgeMaterializableV1
        )
        #expect(
            !Bytecode.DynamicType.array(.local(.init(rawValue: "Payload")))
                .isSwiftBridgeMaterializableV1
        )

        var deepest = Bytecode.DynamicType.integer(.int)
        for _ in 0..<Bytecode.DynamicType.maximumNestingDepthV1 {
            deepest = .optional(deepest)
        }
        #expect(deepest.isAnyPayloadV1)
        let overdeep = Bytecode.DynamicType.optional(deepest)
        #expect(!overdeep.isAnyPayloadV1)

        let maximumTuple = Bytecode.DynamicType.tuple(
            Array(
                repeating: .init(type: .bool),
                count: Bytecode.DynamicType.maximumTupleElementCountV1
            )
        )
        #expect(maximumTuple.isAnyPayloadV1)
        #expect(
            !Bytecode.DynamicType.tuple(
                Array(
                    repeating: .init(type: .bool),
                    count: Bytecode.DynamicType.maximumTupleElementCountV1 + 1
                )
            ).isAnyPayloadV1
        )

        let maximumLabel = String(
            repeating: "a",
            count: Bytecode.DynamicType.maximumTupleLabelUTF8LengthV1
        )
        #expect(
            Bytecode.DynamicType.tuple([
                .init(label: maximumLabel, type: .bool),
                .init(type: .string),
            ]).isAnyPayloadV1
        )
        #expect(
            !Bytecode.DynamicType.tuple([
                .init(label: maximumLabel + "a", type: .bool),
                .init(type: .string),
            ]).isAnyPayloadV1
        )
        #expect(
            !Bytecode.DynamicType.tuple([
                .init(label: "invalid\nlabel", type: .bool),
                .init(label: "valid", type: .string),
            ]).isAnyPayloadV1
        )
        #expect(
            !Bytecode.DynamicType.tuple([
                .init(label: "value", type: .bool),
                .init(label: "value", type: .string),
            ]).isAnyPayloadV1
        )
    }

    private func makeModule() throws -> Bytecode.Module {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.any-wire",
            buildNumber: "1",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Array<Swift.Optional<Swift.Character>>"],
            result: "Swift.Array<Swift.Optional<Swift.Character>>"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func identity(_ value: [Character?]) -> [Character?]",
            loweredSignature: signature,
            role: .function
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "identity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .array(.optional(.string)),
            registerTypes: [
                .array(.optional(.string)),
                .any,
                .optional(.array(.optional(.string))),
                .array(.optional(.string)),
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
                            dynamicType: .array(.optional(.character))
                        ),
                        .checkedCastAny(
                            result: .init(rawValue: 2),
                            value: .init(rawValue: 1),
                            targetType: .array(.optional(.character))
                        ),
                        .forceCastAny(
                            result: .init(rawValue: 3),
                            value: .init(rawValue: 1),
                            targetType: .array(.optional(.character))
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        return .init(
            name: "AnyFixture",
            shellInterfaceHash: .sha256("any-wire-shell"),
            compatibility: .init(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: "swift-any-wire"
            ),
            capabilities: [.baselineV1, .anyValuesV1],
            functions: [function],
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: key,
                    functionID: function.id
                ),
            ]
        )
    }
}
}
