import Foundation
import HelixCore
import Testing
@testable import HelixBytecode

@Test("HLBC magic is exactly eight bytes")
func magicWidth() {
    #expect(Bytecode.Format.magic.count == 8)
    #expect(String(decoding: Bytecode.Format.magic.prefix(4), as: UTF8.self) == "HLBC")
}

enum BytecodeTests {}

extension BytecodeTests {
@Suite("HLBC container")
struct Container {
    @Test("A typed CFG survives an encode/decode round trip")
    func roundTrip() throws {
        let module = try makeAddModule()
        let encoded = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(encoded)

        #expect(Array(encoded.prefix(8)) == Bytecode.Format.magic)
        #expect(decoded.module == module)
        #expect(decoded.header.shellInterfaceHash == module.shellInterfaceHash)
        #expect(decoded.sections[.functions] != nil)
        #expect(decoded.sections[.code] != nil)
    }

    @Test("Function stack layout and effects survive the wire format")
    func stackAndEffectsRoundTrip() throws {
        var module = try makeAddModule()
        module.functions[0].stackSlotTypes = [.optional(.string)]
        module.functions[0].effects = .init(mayThrow: true)

        let decoded = try Bytecode.Decoder.decode(Bytecode.Encoder.encode(module)).module

        #expect(decoded.functions[0].stackSlotTypes == [.optional(.string)])
        #expect(decoded.functions[0].effects == .init(mayThrow: true))
        #expect(decoded == module)
    }

    @Test("Encoding is deterministic")
    func deterministicEncoding() throws {
        let module = try makeAddModule()
        #expect(try Bytecode.Encoder.encode(module) == Bytecode.Encoder.encode(module))
    }

    @Test("Only the current HLBC format is accepted")
    func formatVersionIsExact() throws {
        var bytes = try Bytecode.Encoder.encode(makeAddModule())
        bytes[10] = 1

        #expect(
            throws: Bytecode.CodecError.unsupportedFormat(major: 1, minor: 1)
        ) {
            try Bytecode.Decoder.decode(bytes)
        }

        var incompatible = try makeAddModule()
        incompatible.compatibility.bytecode = .init(1, 1, 0)
        #expect(
            throws: Bytecode.CodecError.invalidHeader(
                "HLBC format 1.0 requires bytecode compatibility 1.0.0, not 1.1.0"
            )
        ) {
            try Bytecode.Encoder.encode(incompatible)
        }
    }

    @Test("HLBC 1.0 canonically carries module-local nominal definitions")
    func localNominalWireFormat() throws {
        let key = Bytecode.LocalTypeKey(rawValue: "Fixture.Mode")
        let auxiliaryKey = Bytecode.LocalTypeKey(rawValue: "Fixture.Auxiliary")
        var module = try makeAddModule()
        module.capabilities.insert(.localNominalsV1)
        module.localTypes = [
            .init(
                key: key,
                kind: .enumeration(
                    cases: [
                        .init(name: "value", payloadType: .int64),
                        .init(name: "none"),
                    ]
                )
            ),
            .init(
                key: auxiliaryKey,
                kind: .structure(fields: [.init(name: "flag", type: .bool)])
            ),
        ]
        module.functions[0].registerTypes.append(.local(key))
        module.functions[0].blocks[0].instructions.insert(
            .makeEnum(
                result: .init(rawValue: 5),
                caseIndex: 0,
                payload: .init(rawValue: 0)
            ),
            at: 0
        )

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)
        var canonicalModule = module
        canonicalModule.localTypes.sort { $0.key < $1.key }
        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == canonicalModule)
        #expect(try Bytecode.Encoder.encode(module) == Bytecode.Encoder.encode(canonicalModule))
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
    }

    @Test("HLBC 1.0 canonically carries local classes and bounded host descriptors")
    func localClassWireFormat() throws {
        let key = Bytecode.LocalTypeKey(rawValue: "Fixture.Controller")
        let superclass = Core.TypeID.derive(
            namespace: .derive(
                bundleID: "dev.helix.fixture",
                buildNumber: "1",
                seed: "fixture"
            ),
            canonicalType: "UIKit.UIViewController"
        )
        var module = try makeAddModule()
        module.capabilities.formUnion([
            .localNominalsV1,
            .addressValuesV1,
            .localClassesV1,
            .hostedObjectiveCClassesV1,
        ])
        module.localTypes = [
            .init(
                key: key,
                kind: .class(
                    fields: [
                        .init(name: "count", type: .int64),
                        .init(name: "next", type: .optional(.local(key))),
                    ],
                    hostedSuperclass: .init(typeID: superclass),
                    hostedMethods: [
                        .init(
                            selector: "viewDidLoad",
                            functionID: .init(rawValue: 0),
                            abi: .voidNoArguments
                        ),
                    ]
                )
            ),
        ]
        module.functions[0].registerTypes.append(contentsOf: [
            .local(key),
            .address(.int64),
            .native(superclass),
        ])
        module.functions[0].blocks[0].instructions.insert(contentsOf: [
            .allocateObject(result: .init(rawValue: 5)),
            .projectObjectAddress(
                result: .init(rawValue: 6),
                object: .init(rawValue: 5),
                fieldIndex: 0
            ),
            .projectHostedObject(
                result: .init(rawValue: 7),
                object: .init(rawValue: 5)
            ),
            .hostedSuperApply(
                object: .init(rawValue: 5),
                methodIndex: 0,
                arguments: []
            ),
        ], at: 0)

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)

        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
    }

    @Test("HLBC 1.0 canonically carries address operations and call conventions")
    func addressWireFormat() throws {
        var module = try makeAddModule()
        module.capabilities.formUnion([.addressValuesV1, .borrowCallsV1])
        module.functions[0] = .init(
            id: .init(rawValue: 0),
            name: "mutateLocal",
            parameterRegisters: [.init(rawValue: 0)],
            parameterConventions: [.borrowed],
            resultType: .int64,
            registerTypes: [
                .int64,
                .address(.int64),
                .address(.int64),
                .int64,
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 0),
                            mode: .initialize
                        ),
                        .stackAddress(
                            result: .init(rawValue: 1),
                            slot: .init(rawValue: 0)
                        ),
                        .beginAccess(
                            result: .init(rawValue: 2),
                            address: .init(rawValue: 1),
                            kind: .modify
                        ),
                        .loadAddress(
                            result: .init(rawValue: 3),
                            address: .init(rawValue: 2),
                            mode: .copy
                        ),
                        .storeAddress(
                            address: .init(rawValue: 2),
                            source: .init(rawValue: 3),
                            mode: .assign
                        ),
                        .endAccess(.init(rawValue: 2)),
                        .destroyStack(.init(rawValue: 0)),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ],
            stackSlotTypes: [.int64]
        )

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)

        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
    }

    @Test("HLBC 1.0 canonically carries closure values and function kinds")
    func closureWireFormat() throws {
        var module = try makeAddModule()
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        module.capabilities.formUnion([
            .closureValuesV1,
            .compilerSpecializationsV1,
        ])
        module.functions[0].registerTypes.append(.closure(signature))
        module.functions[0].registerTypes.append(.int64)
        module.functions[0].blocks[0].instructions.insert(
            .makeClosure(
                result: .init(rawValue: 5),
                function: .init(rawValue: 1),
                captures: [.init(rawValue: 0)]
            ),
            at: 0
        )
        module.functions[0].blocks[0].instructions.insert(
            .closureApply(
                result: .init(rawValue: 6),
                closure: .init(rawValue: 5),
                arguments: [.init(rawValue: 1)]
            ),
            at: 1
        )
        module.functions.append(
            .init(
                id: .init(rawValue: 1),
                name: "closure body",
                kind: .closureBody,
                parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
                resultType: .int64,
                registerTypes: [.int64, .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                        instructions: [.returnValue(.init(rawValue: 0))]
                    ),
                ]
            )
        )
        module.functions.append(
            .init(
                id: .init(rawValue: 2),
                name: "genericIdentity<Int>",
                kind: .concreteSpecialization,
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .int64,
                registerTypes: [.int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [.returnValue(.init(rawValue: 0))]
                    ),
                ]
            )
        )

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)

        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
    }

    @Test("Closure descriptions preserve ownership and expose malformed ABI")
    func closureSignatureDescription() {
        var signature = Bytecode.ClosureSignature(
            parameters: [.int64, .string, .bool],
            parameterConventions: [.owned, .borrowed, .inout],
            result: .void
        )
        #expect(
            signature.description
                == "(Int64, @borrowed String, @inout Bool) -> Void"
        )

        signature.parameterConventions.removeLast()
        #expect(
            signature.description
                == "<invalid closure signature: 3 parameters, 2 conventions>"
        )
    }

    @Test("HLBC 1.0 canonically carries the non-suspending async entry ABI")
    func asyncLeafWireFormat() throws {
        var module = try makeAddModule()
        module.capabilities.insert(.asyncLeafEntriesV1)
        module.functions[0].effects.isAsync = true

        let bytes = try Bytecode.Encoder.encode(module)
        let decoded = try Bytecode.Decoder.decode(bytes)
        #expect(decoded.header.formatMinor == Bytecode.Format.minorVersion)
        #expect(decoded.module == module)
        #expect(try Bytecode.Encoder.encode(decoded.module) == bytes)
    }

    @Test("Any post-encode mutation invalidates the image hash")
    func corruptionIsRejected() throws {
        var encoded = try Bytecode.Encoder.encode(makeAddModule())
        encoded[encoded.count - 1] ^= 0x01

        #expect(throws: Bytecode.CodecError.imageHashMismatch) {
            try Bytecode.Decoder.decode(encoded)
        }
    }

    @Test("The decoder deterministically rejects a seeded malformed corpus")
    func malformedCorpusIsRejected() throws {
        let canonical = try Bytecode.Encoder.encode(makeAddModule())
        var generator = Generator(seed: 0x484c_4243_4655_5a5a)

        for caseID in 0..<1_000 {
            let candidate = mutate(canonical, caseID: caseID, generator: &generator)
            let first = decodeOutcome(candidate)
            let second = decodeOutcome(candidate)
            #expect(first == second, Comment(rawValue: "non-deterministic case \(caseID)"))
            #expect(!first.wasAccepted, Comment(rawValue: "accepted malformed case \(caseID)"))
        }
    }

    @Test("A hash-consistent but non-canonical JSON section is rejected")
    func nonCanonicalSectionIsRejected() throws {
        let encoded = try Bytecode.Encoder.encode(makeAddModule())
        let rebuilt = try rebuild(encoded) { sections in
            sections[.metadata]?.append(0x20)
        }

        #expect(throws: Bytecode.CodecError.invalidHeader("v1 image is not canonically encoded")) {
            try Bytecode.Decoder.decode(rebuilt)
        }
    }

    @Test("Recognized but undeclared v1 sections are rejected")
    func extraV1SectionIsRejected() throws {
        let encoded = try Bytecode.Encoder.encode(makeAddModule())
        let rebuilt = try rebuild(encoded) { sections in
            sections[.strings] = Data("[]".utf8)
        }

        #expect(throws: Bytecode.CodecError.self) {
            try Bytecode.Decoder.decode(rebuilt)
        }
    }

    @Test("Non-finite floating-point constants cannot enter canonical HLBC")
    func nonFiniteFloatIsRejected() throws {
        var module = try makeAddModule()
        module.functions[0].registerTypes.append(.float(bitWidth: 64))
        module.functions[0].blocks[2].instructions.insert(
            .constantFloat(result: .init(rawValue: 5), value: .infinity),
            at: 0
        )

        #expect(throws: Bytecode.CodecError.self) {
            try Bytecode.Encoder.encode(module)
        }
    }

    @Test("Canonical floating literals preserve signed zero")
    func signedZeroRoundTrip() throws {
        var module = try makeAddModule()
        module.functions[0].registerTypes.append(.float(bitWidth: 64))
        module.functions[0].blocks[0].instructions.insert(
            .constantFloat(result: .init(rawValue: 5), value: -0.0),
            at: 0
        )

        let decoded = try Bytecode.Decoder.decode(Bytecode.Encoder.encode(module)).module
        let constants = decoded.functions
            .flatMap(\.blocks)
            .flatMap(\.instructions)
            .compactMap { instruction -> Double? in
                guard case let .constantFloat(_, value) = instruction else { return nil }
                return value
            }
        let value = try #require(constants.first)
        #expect(value == 0)
        #expect(value.sign == .minus)
    }

    @Test("Disassembly retains blocks and checked operations")
    func disassembly() throws {
        var module = try makeAddModule()
        module.name = "Fixture\"\nPatch"
        module.functions[0].stackSlotTypes = [.int64]
        module.functions[0].effects = .init(mayThrow: true)
        let text = Bytecode.Disassembler.disassemble(module)
        #expect(text.contains("checked_add"))
        #expect(text.contains("cond_br"))
        #expect(text.contains("func @0"))
        #expect(text.contains("throws"))
        #expect(text.contains("stack $0: Int64"))
        #expect(text.contains(#"hlbc_module "Fixture\"\nPatch""#))
    }

    private func makeAddModule() throws -> Bytecode.Module {
        let shellHash = Core.Digest.sha256("fixture-shell")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.fixture",
            buildNumber: "1",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func transform(_: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "transform",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64, .int64, .bool, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(result: .init(rawValue: 1), value: 27),
                        .checkedBinary(
                            result: .init(rawValue: 2),
                            overflow: .init(rawValue: 3),
                            operation: .add,
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .conditionalBranch(
                            condition: .init(rawValue: 3),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: [.init(rawValue: 2)]
                        ),
                    ]
                ),
                .init(id: .init(rawValue: 1), instructions: [.trap(.integerOverflow)]),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 4)],
                    instructions: [.returnValue(.init(rawValue: 4))]
                ),
            ]
        )
        return Bytecode.Module(
            name: "FixturePatch",
            shellInterfaceHash: shellHash,
            compatibility: .init(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: "swift-fixture"
            ),
            functions: [function],
            entries: [.init(entryIndex: .init(rawValue: 0), functionKey: key, functionID: function.id)]
        )
    }

    private enum DecodeOutcome: Equatable {
        case accepted(Core.Digest)
        case rejected(String)

        var wasAccepted: Bool {
            if case .accepted = self { return true }
            return false
        }
    }

    private struct Generator {
        private var state: UInt64

        init(seed: UInt64) {
            precondition(seed != 0)
            state = seed
        }

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        mutating func index(upperBound: Int) -> Int {
            precondition(upperBound > 0)
            return Int(next() % UInt64(upperBound))
        }

        mutating func byte() -> UInt8 {
            UInt8(truncatingIfNeeded: next())
        }
    }

    private func decodeOutcome(_ bytes: Data) -> DecodeOutcome {
        do {
            let decoded = try Bytecode.Decoder.decode(
                bytes,
                limits: .init(
                    maximumFileBytes: 1 * 1_024 * 1_024,
                    maximumSectionCount: 16,
                    maximumSectionBytes: 512 * 1_024
                )
            )
            return .accepted(decoded.header.imageHash)
        } catch {
            return .rejected(
                "\(String(reflecting: type(of: error))):\(String(describing: error))"
            )
        }
    }

    private func mutate(
        _ canonical: Data,
        caseID: Int,
        generator: inout Generator
    ) -> Data {
        switch caseID % 5 {
        case 0:
            var result = canonical
            let index = generator.index(upperBound: result.count)
            result[index] ^= UInt8(1 << generator.index(upperBound: 8))
            return result
        case 1:
            return Data(canonical.prefix(generator.index(upperBound: canonical.count)))
        case 2:
            var result = canonical
            for _ in 0..<(1 + generator.index(upperBound: 16)) {
                result.append(generator.byte())
            }
            return result
        case 3:
            var result = canonical
            let start = generator.index(upperBound: result.count)
            let count = min(1 + generator.index(upperBound: 16), result.count - start)
            for index in start..<(start + count) {
                result[index] ^= generator.byte() | 1
            }
            return result
        default:
            let count = generator.index(upperBound: 2_048)
            return Data((0..<count).map { _ in generator.byte() })
        }
    }

    private func rebuild(
        _ encoded: Data,
        mutate: (inout [Bytecode.SectionKind: Data]) -> Void
    ) throws -> Data {
        let decoded = try Bytecode.Decoder.decode(encoded)
        var sections = decoded.sections
        mutate(&sections)
        let sorted = sections.sorted { $0.key < $1.key }
        let payloadStart = Bytecode.Header.byteCount + sorted.count * Bytecode.SectionEntry.byteCount
        let zeroHash = try Core.Digest(bytes: repeatElement(UInt8(0), count: Core.Digest.byteCount))

        var offset = payloadStart
        var entries: [Bytecode.SectionEntry] = []
        for (kind, payload) in sorted {
            entries.append(
                .init(
                    kind: kind,
                    flags: 0,
                    offset: UInt64(offset),
                    compressedSize: UInt64(payload.count),
                    uncompressedSize: UInt64(payload.count),
                    sha256: .sha256(payload)
                )
            )
            offset += payload.count
        }

        var writer = Bytecode.BinaryWriter()
        writer.append(bytes: Bytecode.Format.magic)
        writer.append(decoded.header.formatMajor)
        writer.append(decoded.header.formatMinor)
        writer.append(decoded.header.minimumRuntimeMajor)
        writer.append(decoded.header.flags)
        writer.append(decoded.header.shellInterfaceHash.data)
        writer.append(zeroHash.data)
        writer.append(UInt32(entries.count))
        writer.append(UInt64(Bytecode.Header.byteCount))
        for entry in entries {
            writer.append(entry.kind.rawValue)
            writer.append(entry.flags)
            writer.append(entry.offset)
            writer.append(entry.compressedSize)
            writer.append(entry.uncompressedSize)
            writer.append(entry.sha256.data)
        }
        for (_, payload) in sorted { writer.append(payload) }
        let imageHash = Core.Digest.sha256(writer.data)
        writer.data.replaceSubrange(Bytecode.Header.imageHashRange, with: imageHash.data)
        return writer.data
    }
}
}
