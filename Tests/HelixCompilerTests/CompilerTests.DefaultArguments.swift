import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Default argument lowering")
struct DefaultArguments {
    @Test("PatchCompiler links a reachable default argument generator into HLBC")
    func linksDefaultArgumentGenerator() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-default-argument-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            @inline(never) public func supplied(_ value: Int = 7) -> Int { value }
            @inline(never) public func transform(_ value: Int) -> Int { value + supplied() }
            """.utf8
        ).write(to: sourceURL)

        let canonicalSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "DefaultArgumentFixture",
            purpose: .implementationIdentity
        )
        let file = try CanonicalSIL.File(text: canonicalSIL)
        let transform = try #require(file.functions.first {
            $0.mangledName.contains("transform")
                && !ReleaseCompiler.ImplementationFingerprint
                    .isCompilerGeneratedSymbol($0.mangledName)
        })
        let supplied = try #require(file.functions.first {
            $0.mangledName.contains("supplied")
                && !ReleaseCompiler.ImplementationFingerprint
                    .isCompilerGeneratedSymbol($0.mangledName)
        })
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.default-argument",
            buildNumber: "1",
            seed: "fixture"
        )
        let rootEntry = Core.EntryIndex(rawValue: 0)
        let suppliedEntry = Core.EntryIndex(rawValue: 1)
        let rootKey = try functionKey(
            namespace: namespace,
            declaration: "func transform(_: Int) -> Int"
        )
        let suppliedKey = try functionKey(
            namespace: namespace,
            declaration: "func supplied(_: Int) -> Int"
        )
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: supplied.mangledName,
                parameterTypes: [.int64],
                resultType: .int64,
                target: .entry(suppliedEntry)
            ),
        ])
        let shellHash = Core.Digest.sha256("helix-default-argument-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-default-argument-fixture"
        )
        let compiled = try PatchCompiler.Driver().compile(
            .init(
                canonicalSIL: canonicalSIL,
                mangledName: transform.mangledName,
                displayName: "transform",
                functionKey: rootKey,
                entryIndex: rootEntry,
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                directCalls: directCalls,
                sourceFileLogicalID: "Patch.swift"
            )
        )

        let generated = try #require(compiled.module.functions.first {
            $0.kind == .concreteSpecialization && $0.name.contains("fA")
        })
        #expect(compiled.module.functions.count == 2)
        #expect(generated.parameterRegisters.isEmpty)
        #expect(generated.resultType == .int64)
        #expect(compiled.disassembly.contains("entry_apply #\(suppliedEntry.rawValue)"))

        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: compiled.module.capabilities,
            entries: [
                .init(
                    index: rootEntry,
                    key: rootKey,
                    parameterTypes: [.int64],
                    resultType: .int64
                ),
                .init(
                    index: suppliedEntry,
                    key: suppliedKey,
                    parameterTypes: [.int64],
                    resultType: .int64
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: compiled.bytecode,
            shell: shell,
            policy: .init(acceptedCapabilities: compiled.module.capabilities)
        )
        let interpreter = VM.Interpreter(entryInvocation: { entry, arguments, _ in
            guard entry == suppliedEntry, arguments.count == 1 else {
                return .trapped(.unknownEntry(entry))
            }
            return .returned(arguments[0])
        })
        #expect(
            interpreter.invoke(
                entry: rootEntry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 10, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Swift generator classification covers functions, methods, and initializers")
    func classifiesCommonDefaultArgumentOwners() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-default-owner-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Defaults.swift")
        try Data(
            """
            public struct Counter {
                public var value: Int

                public init(seed: Int, step: Int = 1) {
                    value = seed + step
                }

                public func adding(_ input: Int, offset: Int = 2) -> Int {
                    value + input + offset
                }

                public static func scaled(_ input: Int, factor: Int = 3) -> Int {
                    input * factor
                }
            }

            public func adjusted(_ input: Int, delta: Int = 4) -> Int {
                input + delta
            }
            """.utf8
        ).write(to: sourceURL)

        let canonicalSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "DefaultOwnerFixture",
            purpose: .implementationIdentity
        )
        let generators = try CanonicalSIL.File(text: canonicalSIL).functions.filter {
            ReleaseCompiler.ImplementationFingerprint
                .isDefaultArgumentGenerator($0.mangledName)
        }

        #expect(generators.count == 4)
        #expect(generators.allSatisfy { $0.mangledName.last == "_" })
        #expect(generators.allSatisfy { !$0.body.isEmpty })
    }

    private func functionKey(
        namespace: Core.ShellNamespaceID,
        declaration: String
    ) throws -> Core.FunctionKey {
        try Core.FunctionKey.derive(
            namespace: namespace,
            module: "DefaultArgumentFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: declaration,
            loweredSignature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int"
            ),
            role: .function
        )
    }
}
}
