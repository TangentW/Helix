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
                  case let .array(values, elementType) = arguments[0],
                  elementType == .any,
                  values.count == 2,
                  case let .any(label) = values[0],
                  label.concreteType == .string,
                  label.payload == .string("value: 4"),
                  case let .any(number) = values[1],
                  number.concreteType == .int64,
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
}
}
