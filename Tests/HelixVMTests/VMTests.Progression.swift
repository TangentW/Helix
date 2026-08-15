import HelixBytecode
import HelixCore
import HelixVerifier
import Testing
@testable import HelixVM

extension VMTests {
@Suite("HLVM numeric progression semantics")
struct Progression {
    @Test("Integer progressions preserve direction, boundaries, and overflow termination")
    func integerProgressions() throws {
        let int8 = Bytecode.ValueType.integer(bitWidth: 8, signed: true)
        #expect(
            try collect(
                start: integer(126, type: int8),
                end: integer(127, type: int8),
                stride: integer(1, type: .int64),
                boundary: .inclusive
            ) == [
                integer(126, type: int8),
                integer(127, type: int8),
            ]
        )

        let uint8 = Bytecode.ValueType.integer(bitWidth: 8, signed: false)
        #expect(
            try collect(
                start: unsignedInteger(5, type: uint8),
                end: unsignedInteger(0, type: uint8),
                stride: integer(-2, type: .int64),
                boundary: .inclusive
            ) == [
                unsignedInteger(5, type: uint8),
                unsignedInteger(3, type: uint8),
                unsignedInteger(1, type: uint8),
            ]
        )

        #expect(
            try collect(
                start: integer(.max - 1, type: .int64),
                end: integer(.max, type: .int64),
                stride: integer(2, type: .int64),
                boundary: .inclusive
            ) == [integer(.max - 1, type: .int64)]
        )
        #expect(
            try collect(
                start: integer(5, type: .int64),
                end: integer(0, type: .int64),
                stride: integer(-2, type: .int64),
                boundary: .exclusive
            ) == [
                integer(5, type: .int64),
                integer(3, type: .int64),
                integer(1, type: .int64),
            ]
        )
        let uint64 = Bytecode.ValueType.integer(bitWidth: 64, signed: false)
        #expect(
            try collect(
                start: unsignedInteger(.max, type: uint64),
                end: unsignedInteger(0, type: uint64),
                stride: integer(.min, type: .int64),
                boundary: .inclusive
            ) == [
                unsignedInteger(.max, type: uint64),
                unsignedInteger(UInt64(Int64.max), type: uint64),
            ]
        )
    }

    @Test("Floating progressions preserve Float and Double comparison semantics")
    func floatingProgressions() throws {
        #expect(
            try collect(
                start: .float64(0),
                end: .float64(1),
                stride: .float64(0.25),
                boundary: .exclusive
            ) == [0.0, 0.25, 0.5, 0.75].map {
                .float64($0)
            }
        )
        #expect(
            try collect(
                start: .float32(1),
                end: .float32(0),
                stride: .float32(-0.5),
                boundary: .inclusive
            ) == [1.0, 0.5, 0.0].map {
                .float32($0)
            }
        )
        #expect(
            try collect(
                start: .float64(0),
                end: .float64(1),
                stride: .float64(.nan),
                boundary: .exclusive
            ).isEmpty
        )

        var reverseNaNCursor = VM.Value.optional(
            .float64(1)
        )
        let first = try VM.Progression.next(
            cursor: reverseNaNCursor,
            end: .float64(0),
            stride: .float64(.nan),
            boundary: .exclusive
        )
        reverseNaNCursor = first.cursor
        #expect(first.result == .optional(.float64(1)))
        let second = try VM.Progression.next(
            cursor: reverseNaNCursor,
            end: .float64(0),
            stride: .float64(.nan),
            boundary: .exclusive
        )
        guard case let .optional(.some(.float(value))) = second.result,
              value.bitWidth == 64
        else {
            Issue.record("descending NaN stride did not preserve Swift's live cursor")
            return
        }
        #expect(value.doubleValue.isNaN)
    }

    @Test("A zero stride fails closed")
    func rejectsZeroStride() throws {
        #expect(throws: VM.RuntimeTrap.explicit("Stride size must not be zero")) {
            _ = try VM.Progression.next(
                cursor: .optional(integer(0, type: .int64)),
                end: integer(1, type: .int64),
                stride: integer(0, type: .int64),
                boundary: .exclusive
            )
        }
    }

    @Test("Verified bytecode mutates an Optional cursor without a sentinel")
    func executesVerifiedInstruction() throws {
        let optional = Bytecode.ValueType.optional(.int64)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "progression",
            parameterRegisters: [],
            resultType: .tuple([optional, optional, optional]),
            registerTypes: [
                .int64, .int64, .int64, optional,
                optional, optional, optional,
                .tuple([optional, optional, optional]),
            ],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .constantInteger(
                            result: .init(rawValue: 0),
                            bitPattern: UInt64(Int64.max - 1)
                        ),
                        .constantInteger(
                            result: .init(rawValue: 1),
                            bitPattern: UInt64(Int64.max)
                        ),
                        .constantInteger(result: .init(rawValue: 2), bitPattern: 2),
                        .makeOptionalSome(
                            result: .init(rawValue: 3),
                            value: .init(rawValue: 0)
                        ),
                        .storeStack(
                            slot: .init(rawValue: 0),
                            source: .init(rawValue: 3),
                            mode: .initialize
                        ),
                        .progressionNext(
                            result: .init(rawValue: 4),
                            cursorSlot: .init(rawValue: 0),
                            end: .init(rawValue: 1),
                            stride: .init(rawValue: 2),
                            boundary: .inclusive
                        ),
                        .progressionNext(
                            result: .init(rawValue: 5),
                            cursorSlot: .init(rawValue: 0),
                            end: .init(rawValue: 1),
                            stride: .init(rawValue: 2),
                            boundary: .inclusive
                        ),
                        .progressionNext(
                            result: .init(rawValue: 6),
                            cursorSlot: .init(rawValue: 0),
                            end: .init(rawValue: 1),
                            stride: .init(rawValue: 2),
                            boundary: .inclusive
                        ),
                        .destroyStack(.init(rawValue: 0)),
                        .makeTuple(
                            result: .init(rawValue: 7),
                            elements: [
                                .init(rawValue: 4),
                                .init(rawValue: 5),
                                .init(rawValue: 6),
                            ]
                        ),
                        .returnValue(.init(rawValue: 7)),
                    ]
                ),
            ],
            stackSlotTypes: [optional]
        )
        let image = try verify(function: function)
        let expected = VM.Value.tuple([
            .optional(try integer(.max - 1, type: .int64)),
            .optional(nil),
            .optional(nil),
        ])
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: []
            ) == .returned(expected)
        )
    }

    private func collect(
        start: VM.Value,
        end: VM.Value,
        stride: VM.Value,
        boundary: Bytecode.ProgressionBoundary
    ) throws -> [VM.Value] {
        var cursor = VM.Value.optional(start)
        var values: [VM.Value] = []
        for _ in 0..<64 {
            let step = try VM.Progression.next(
                cursor: cursor,
                end: end,
                stride: stride,
                boundary: boundary
            )
            cursor = step.cursor
            guard case let .optional(value) = step.result else {
                Issue.record("progression returned a non-Optional value")
                return values
            }
            guard let value else { return values }
            values.append(value)
        }
        Issue.record("progression did not terminate within the test bound")
        return values
    }

    private func integer(
        _ value: Int64,
        type: Bytecode.ValueType
    ) throws -> VM.Value {
        guard case let .integer(width, signed) = type else {
            throw VM.RuntimeTrap.typeMismatch(expected: .int64, actual: type)
        }
        return .integer(
            try .init(signed: value, bitWidth: width, isSigned: signed)
        )
    }

    private func unsignedInteger(
        _ value: UInt64,
        type: Bytecode.ValueType
    ) throws -> VM.Value {
        guard case let .integer(width, signed: false) = type else {
            throw VM.RuntimeTrap.typeMismatch(expected: .int64, actual: type)
        }
        return .integer(
            try .init(rawBits: value, bitWidth: width, isSigned: false)
        )
    }

    private func verify(function: Bytecode.Function) throws -> Verification.Image {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.vm.progression",
            buildNumber: "1",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(
            parameters: [],
            result: "(Swift.Int?, Swift.Int?, Swift.Int?)"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Progression.swift",
            canonicalDeclaration: "func progression()",
            loweredSignature: signature,
            role: .function
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "vm-progression-fixture"
        )
        let shellHash = Core.Digest.sha256("vm-progression-shell")
        let capabilities: Set<Core.Capability> = [.baselineV1, .collectionsV1]
        let resultType = function.resultType
        let module = Bytecode.Module(
            name: "VMProgressionFixture",
            shellInterfaceHash: shellHash,
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
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: key,
                    parameterTypes: [],
                    resultType: resultType
                ),
            ]
        )
        return try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(acceptedCapabilities: capabilities)
        )
    }
}
}
