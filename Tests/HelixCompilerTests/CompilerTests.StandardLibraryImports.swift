import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift standard-library NativeImports")
struct StandardLibraryImports {
    private enum NativeTextOperation: Sendable {
        case describing(expected: Int64?)
        case reflecting
        case debugPrint(expected: Int64)
    }

    private struct NativeTextProbe: VM.NativeInvoker {
        let id: Core.NativeImportID
        let key: Core.NativeImportKey
        let parameterTypes: [Bytecode.ValueType]
        let resultType: Bytecode.ValueType
        let effects: Core.Effects
        let contract: Core.NativeImportContract
        let operation: NativeTextOperation

        init(
            requirement: Bytecode.ImportRequirement,
            descriptor: Bytecode.StandardLibraryImports.Descriptor,
            operation: NativeTextOperation
        ) {
            id = requirement.id
            key = requirement.key
            parameterTypes = descriptor.parameterTypes
            resultType = descriptor.resultType
            effects = descriptor.effects
            contract = descriptor.contract
            self.operation = operation
        }

        func invoke(
            arguments: [VM.Value],
            context: VM.NativeInvocationContext
        ) throws -> VM.NativeInvocationResult {
            try context.checkpoint()
            switch operation {
            case let .describing(expected):
                guard arguments.count == 1,
                      case let .any(erased) = arguments[0],
                      erased.dynamicType == .optional(.integer(.int)),
                      case let .optional(payload) = erased.payload
                else {
                    return .businessError(
                        "describing adapter lost Optional<Int> identity"
                    )
                }
                if let expected {
                    guard case let .integer(value)? = payload,
                          value.signedValue == expected
                    else {
                        return .businessError(
                            "describing adapter lost Optional.some payload"
                        )
                    }
                } else if payload != nil {
                    return .businessError(
                        "describing adapter lost Optional.none identity"
                    )
                }
                return .returned(.string("described"))

            case .reflecting:
                guard arguments.count == 1,
                      case let .any(erased) = arguments[0],
                      erased.dynamicType == .array(.string),
                      case let .array(storage) = erased.payload,
                      storage.elementType == .string,
                      storage.elements == [.string("x"), .string("y")]
                else {
                    return .businessError(
                        "reflecting adapter lost Array<String> identity"
                    )
                }
                return .returned(.string("reflected"))

            case let .debugPrint(expected):
                guard arguments.count == 3,
                      case let .array(storage) = arguments[0],
                      storage.elementType == .any,
                      storage.elements.count == 2,
                      case let .any(label) = storage.elements[0],
                      label.dynamicType == .string,
                      label.payload == .string("value"),
                      case let .any(value) = storage.elements[1],
                      value.dynamicType == .integer(.int),
                      case let .integer(number) = value.payload,
                      number.signedValue == expected,
                      arguments[1] == .string(":"),
                      arguments[2] == .string("!")
                else {
                    return .businessError(
                        "debugPrint arguments lost their represented values"
                    )
                }
                return .returned(nil)
            }
        }
    }

    private struct PrintProbe: VM.NativeInvoker {
        let id: Core.NativeImportID
        let key: Core.NativeImportKey
        let parameterTypes: [Bytecode.ValueType]
        let resultType: Bytecode.ValueType
        let effects: Core.Effects
        let contract: Core.NativeImportContract

        init(id: Core.NativeImportID, key: Core.NativeImportKey) {
            let descriptor = Bytecode.StandardLibraryImports.swiftPrint
            self.id = id
            self.key = key
            parameterTypes = descriptor.parameterTypes
            resultType = descriptor.resultType
            effects = descriptor.effects
            contract = descriptor.contract
        }

        func invoke(
            arguments: [VM.Value],
            context: VM.NativeInvocationContext
        ) throws -> VM.NativeInvocationResult {
            try context.checkpoint()
            guard arguments.count == 3,
                  case let .array(storage) = arguments[0],
                  storage.elementType == .any,
                  storage.elements.count == 2,
                  case let .any(label) = storage.elements[0],
                  label.dynamicType == .string,
                  label.payload == .string("value: 4"),
                  case let .any(number) = storage.elements[1],
                  number.dynamicType == .integer(.int),
                  case let .integer(integer) = number.payload,
                  integer.signedValue == 4,
                  arguments[1] == .string(" "),
                  arguments[2] == .string("\n")
            else {
                return .businessError("print arguments did not preserve Swift semantics")
            }
            return .returned(nil)
        }
    }

    @Test("Ordinary print compiles through Any, default thunks, and synchronous NativeImport")
    func compilesAndExecutesPrint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-print-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            public func transform(_ value: Int) -> Int {
                print("value: \\(value)", value)
                return value + 1
            }
            """.utf8
        ).write(to: sourceURL)
        let canonicalSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "PrintFixture",
            optimization: "-Onone",
            additionalArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
        )
        let root = try CanonicalSIL.File(text: canonicalSIL)
            .uniqueFunction(mangledNameContaining: "transform")
        let descriptor = Bytecode.StandardLibraryImports.swiftPrint
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.print",
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
        let requirement = Bytecode.ImportRequirement(
            id: importID,
            key: importKey,
            signature: descriptor.signature,
            effects: descriptor.effects,
            contract: descriptor.contract,
            requiredCapability: descriptor.capability
        )
        let directCalls = try CanonicalSIL.DirectCallTable(
            descriptor.silMangledNames.map { symbol in
                .init(
                    mangledName: symbol,
                    parameterTypes: descriptor.parameterTypes,
                    resultType: descriptor.resultType,
                    effects: descriptor.effects,
                    target: .nativeImport(requirement)
                )
            }
        )
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "PrintFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func transform(_: Int) -> Int",
            loweredSignature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int"
            ),
            role: .function
        )
        let entry = Core.EntryIndex(rawValue: 0)
        let shellHash = Core.Digest.sha256("helix-print-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-print-fixture"
        )
        let compiled = try PatchCompiler.Driver().compile(
            .init(
                canonicalSIL: canonicalSIL,
                mangledName: root.mangledName,
                displayName: "transform",
                functionKey: functionKey,
                entryIndex: entry,
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                directCalls: directCalls,
                effects: descriptor.effects,
                sourceFileLogicalID: "Patch.swift"
            )
        )

        #expect(compiled.module.imports == [requirement])
        #expect(compiled.module.functions.filter {
            $0.kind == .concreteSpecialization && $0.name.contains("fA")
        }.count == 2)
        #expect(compiled.disassembly.contains("native_apply #\(importID.rawValue)"))
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: compiled.module.capabilities,
            entries: [
                .init(
                    index: entry,
                    key: functionKey,
                    parameterTypes: [.int64],
                    resultType: .int64,
                    effects: descriptor.effects
                ),
            ],
            imports: [
                .init(
                    id: importID,
                    key: importKey,
                    parameterTypes: descriptor.parameterTypes,
                    resultType: descriptor.resultType,
                    signature: descriptor.signature,
                    effects: descriptor.effects,
                    contract: descriptor.contract,
                    capability: descriptor.capability
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: compiled.bytecode,
            shell: shell,
            policy: .init(
                acceptedCapabilities: compiled.module.capabilities,
                allowedNativeImports: [importID]
            )
        )
        let catalog = try VM.NativeCatalog([
            PrintProbe(id: importID, key: importKey),
        ])
        #expect(
            VM.Interpreter(nativeCatalog: catalog).invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 5, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Generic text rendering adapts represented values to fixed NativeImports")
    func compilesNativeTextRenderingAdapters() throws {
        let descriptors = [
            Bytecode.StandardLibraryImports.swiftStringDescribing,
            Bytecode.StandardLibraryImports.swiftStringReflecting,
            Bytecode.StandardLibraryImports.swiftDebugPrint,
        ]
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func nativeTextRendering(_ value: Int?) -> String {
                debugPrint(
                    "value",
                    value ?? -1,
                    separator: ":",
                    terminator: "!"
                )
                return String(describing: value)
                    + "|" + String(reflecting: ["x", "y"])
            }
            """,
            functionName: "nativeTextRendering",
            moduleName: "HelixNativeTextRendering",
            standardLibraryImports: descriptors
        )
        #expect(fixture.image.module.imports.count == descriptors.count)
        let requirements = Dictionary<
            Core.NativeImportID,
            Bytecode.ImportRequirement
        >(
            uniqueKeysWithValues: fixture.image.module.imports.map {
                ($0.id, $0)
            }
        )
        func invoke(
            argument: VM.Value,
            expectedDescription: Int64?,
            expectedDebugValue: Int64
        ) throws -> VM.ExecutionResult {
            let probes: [any VM.NativeInvoker] = [
                NativeTextProbe(
                    requirement: try #require(
                        requirements[Core.NativeImportID(rawValue: 0)]
                    ),
                    descriptor: descriptors[0],
                    operation: .describing(expected: expectedDescription)
                ),
                NativeTextProbe(
                    requirement: try #require(
                        requirements[Core.NativeImportID(rawValue: 1)]
                    ),
                    descriptor: descriptors[1],
                    operation: .reflecting
                ),
                NativeTextProbe(
                    requirement: try #require(
                        requirements[Core.NativeImportID(rawValue: 2)]
                    ),
                    descriptor: descriptors[2],
                    operation: .debugPrint(expected: expectedDebugValue)
                ),
            ]
            return VM.Interpreter(
                nativeCatalog: try VM.NativeCatalog(probes)
            ).invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [argument]
            )
        }
        let expected = VM.ExecutionResult.returned(
            VM.Value.string("described|reflected")
        )
        #expect(
            try invoke(
                argument: .optional(try integer(7)),
                expectedDescription: 7,
                expectedDebugValue: 7
            ) == expected
        )
        #expect(
            try invoke(
                argument: .optional(nil),
                expectedDescription: nil,
                expectedDebugValue: -1
            ) == expected
        )
    }

    @Test("Native text rendering rejects image-local values before dispatch")
    func rejectsUnbridgeableNativeTextPayload() {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                private struct LocalPayload { var value: Int }
                public func unsupportedDescription(_ value: Int) -> String {
                    String(describing: LocalPayload(value: value))
                }
                """,
                functionName: "unsupportedDescription",
                moduleName: "HelixUnsupportedNativeTextRendering",
                standardLibraryImports: [
                    Bytecode.StandardLibraryImports.swiftStringDescribing,
                ]
            )
            Issue.record("image-local payload unexpectedly crossed NativeImport")
        } catch {
            #expect(
                String(describing: error).contains(
                    "Swift native text rendering payload LocalPayload"
                )
            )
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
