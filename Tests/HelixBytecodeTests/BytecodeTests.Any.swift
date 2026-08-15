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
        #expect(Bytecode.ValueType.int64.isAnyPayloadV1)
        #expect(Bytecode.ValueType.optional(.any).isAnyPayloadV1)
        #expect(Bytecode.ValueType.array(.any).isAnyPayloadV1)
        #expect(
            Bytecode.ValueType.dictionary(key: .string, value: .any)
                .isAnyPayloadV1
        )
        #expect(!Bytecode.ValueType.any.isAnyPayloadV1)
        #expect(!Bytecode.ValueType.tuple([]).isAnyPayloadV1)
        #expect(
            !Bytecode.ValueType.dictionary(key: .any, value: .string)
                .isAnyPayloadV1
        )
        #expect(
            !Bytecode.ValueType.native(
                .init(rawValue: .sha256("Any.Native.fixture"))
            ).isAnyPayloadV1
        )
        #expect(!Bytecode.ValueType.error.isAnyPayloadV1)
        #expect(!Bytecode.ValueType.address(.int64).isAnyPayloadV1)
        #expect(
            !Bytecode.ValueType.closure(
                .init(
                    parameters: [],
                    parameterConventions: [],
                    result: .void
                )
            ).isAnyPayloadV1
        )
    }

    private func makeModule() throws -> Bytecode.Module {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.any-wire",
            buildNumber: "1",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func identity(_ value: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "identity",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .any, .optional(.int64), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .eraseToAny(
                            result: .init(rawValue: 1),
                            value: .init(rawValue: 0)
                        ),
                        .checkedCastAny(
                            result: .init(rawValue: 2),
                            value: .init(rawValue: 1)
                        ),
                        .forceCastAny(
                            result: .init(rawValue: 3),
                            value: .init(rawValue: 1)
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
