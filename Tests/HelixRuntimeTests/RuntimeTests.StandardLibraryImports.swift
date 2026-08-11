import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
import Testing
@testable import HelixRuntime

extension RuntimeTests {
@Suite("Swift standard-library imports")
struct StandardLibraryImports {
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test("Print preserves heterogeneous Any values, separator, and terminator")
    func formatsSwiftPrintArguments() throws {
        let values = try [
            Runtime.BridgeValueCodec.encodeAny("Helix"),
            Runtime.BridgeValueCodec.encodeAny(3),
            Runtime.BridgeValueCodec.encodeAny(true),
        ]
        let output = try Runtime.StandardLibraryImports.formatPrint(
            arguments: [
                .array(values, elementType: .any),
                .string(" | "),
                .string("!"),
            ]
        )
        #expect(output == "Helix | 3 | true!")
    }

    @Test("The print NativeImport emits one bounded synchronous write")
    func invokesPrintThroughVerifiedNativeImport() throws {
        let descriptor = Bytecode.StandardLibraryImports.swiftPrint
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.runtime-print",
            buildNumber: "1",
            seed: "fixture"
        )
        let importID = Core.NativeImportID(rawValue: 0)
        let importKey = try Core.NativeImportKey.derive(
            namespace: namespace,
            canonicalCallee: descriptor.canonicalCallee,
            signature: descriptor.signature,
            effects: descriptor.effects,
            contract: descriptor.contract
        )
        let output = OutputBox()
        let invoker = Runtime.StandardLibraryImports.makePrint(
            id: importID,
            key: importKey,
            emit: { output.append($0) }
        )
        let fixture = try makeFixture(
            namespace: namespace,
            importID: importID,
            importKey: importKey
        )
        let catalog = try VM.NativeCatalog([invoker])
        let values = try [
            Runtime.BridgeValueCodec.encodeAny("count"),
            Runtime.BridgeValueCodec.encodeAny(4),
        ]

        #expect(
            VM.Interpreter(nativeCatalog: catalog).invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [
                    .array(values, elementType: .any),
                    .string(":"),
                    .string("\n"),
                ]
            ) == .returned(nil)
        )
        #expect(output.values == ["count:4\n"])
    }

    @Test("Print rejects output beyond its frozen bound before performing I/O")
    func rejectsOversizedOutput() throws {
        let oversized = String(
            repeating: "x",
            count: Runtime.StandardLibraryImports.maximumPrintUTF8Bytes + 1
        )
        let value = try Runtime.BridgeValueCodec.encodeAny(oversized)
        #expect(
            throws: VM.RuntimeTrap.nativeFailure(
                "Swift.print output exceeds "
                    + "\(Runtime.StandardLibraryImports.maximumPrintUTF8Bytes) UTF-8 bytes"
            )
        ) {
            _ = try Runtime.StandardLibraryImports.formatPrint(
                arguments: [
                    .array([value], elementType: .any),
                    .string(" "),
                    .string("\n"),
                ]
            )
        }
    }

    private struct Fixture {
        var entry: Core.EntryIndex
        var image: Verification.Image
    }

    private func makeFixture(
        namespace: Core.ShellNamespaceID,
        importID: Core.NativeImportID,
        importKey: Core.NativeImportKey
    ) throws -> Fixture {
        let descriptor = Bytecode.StandardLibraryImports.swiftPrint
        let functionID = Bytecode.FunctionID(rawValue: 0)
        let entry = Core.EntryIndex(rawValue: 0)
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "RuntimePrintFixture",
            sourceFileLogicalID: "Fixture.swift",
            canonicalDeclaration: "func printFixture(_: [Any], _: String, _: String)",
            loweredSignature: .init(
                parameters: descriptor.signature.parameters,
                result: descriptor.signature.result
            ),
            role: .function
        )
        let function = Bytecode.Function(
            id: functionID,
            name: "printFixture",
            parameterRegisters: [
                .init(rawValue: 0),
                .init(rawValue: 1),
                .init(rawValue: 2),
            ],
            resultType: .void,
            registerTypes: descriptor.parameterTypes,
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [
                        .init(rawValue: 0),
                        .init(rawValue: 1),
                        .init(rawValue: 2),
                    ],
                    instructions: [
                        .nativeApply(
                            result: nil,
                            importID: importID,
                            arguments: [
                                .init(rawValue: 0),
                                .init(rawValue: 1),
                                .init(rawValue: 2),
                            ]
                        ),
                        .returnValue(nil),
                    ]
                ),
            ],
            effects: descriptor.effects
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "runtime-print-fixture"
        )
        let shellHash = Core.Digest.sha256("runtime-print-shell")
        let capabilities: Set<Core.Capability> = [
            .baselineV1,
            .nativeImportsV2,
            .anyValuesV1,
            .collectionsV1,
            .stringsV1,
        ]
        let requirement = Bytecode.ImportRequirement(
            id: importID,
            key: importKey,
            signature: descriptor.signature,
            effects: descriptor.effects,
            contract: descriptor.contract,
            requiredCapability: descriptor.capability
        )
        let module = Bytecode.Module(
            name: "RuntimePrintFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            functions: [function],
            entries: [
                .init(
                    entryIndex: entry,
                    functionKey: functionKey,
                    functionID: functionID
                ),
            ],
            imports: [requirement]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: entry,
                    key: functionKey,
                    parameterTypes: descriptor.parameterTypes,
                    resultType: .void,
                    effects: descriptor.effects
                ),
            ],
            imports: [
                .init(
                    id: importID,
                    key: importKey,
                    parameterTypes: descriptor.parameterTypes,
                    resultType: .void,
                    signature: descriptor.signature,
                    effects: descriptor.effects,
                    contract: descriptor.contract,
                    capability: descriptor.capability
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(
                acceptedCapabilities: capabilities,
                allowedNativeImports: [importID]
            )
        )
        return .init(entry: entry, image: image)
    }
}
}
