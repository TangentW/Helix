import Foundation
import HelixBytecode
import HelixCLIKit
import HelixCompiler
import HelixCore
import HelixInterface
import HelixVerifier
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Scoped NativeImport discovery")
struct NativeImportDiscoveryTests {
    @Test("Real module indexing generates exact invokers for a selected source range")
    func indexesAndMaterializesGeneratedInvokers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-native-import-discovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let patchDirectory = directory.appendingPathComponent("Patch", isDirectory: true)
        let nativeDirectory = directory.appendingPathComponent("Native", isDirectory: true)
        try FileManager.default.createDirectory(
            at: patchDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nativeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let patchURL = patchDirectory.appendingPathComponent("Feature.swift")
        let nativeURL = nativeDirectory.appendingPathComponent("Operations.swift")
        try Data(
            "public func transform(_ value: Int) -> Int { adjust(value, by: 1) }\n".utf8
        ).write(to: patchURL)
        try Data(
            """
            public enum SampleError: Error { case negative }
            public func adjust(_ value: Int, by amount: Int) -> Int { value + amount }
            public func checked(_ value: Int) throws -> Int {
                if value < 0 { throw SampleError.negative }
                return value
            }
            @MainActor public func mainValue(_ value: Int) -> Int { value + 10 }
            public func copy(_ values: [String: Int]?) -> [String: Int]? { values }
            public func keyword(_ value: Int, `repeat` count: Int) -> Int { value + count }
            public enum Math {
                public static func doubled(_ value: Int) -> Int { value * 2 }
            }
            """.utf8
        ).write(to: nativeURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "GeneratedImportFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configurationYAML = """
        schema: 2
        modules:
          \(moduleName):
            include:
              - Patch/**
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Native/**
                declarations:
                  - \(moduleName).*
                visibility: public
                profile: bounded-pure
                maximumDurationMicroseconds: 500
                allowsMainThread: true
        """
        let configuration = try PatchConfiguration.Document.parse(yaml: configurationYAML)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.generated-import",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.generated-import",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "integration-test",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(
                moduleName: moduleName,
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by indexer")
        )
        let request = FrontendReceipt.Request(
            metadata: metadata,
            configuration: configuration,
            sources: [
                .init(logicalPath: "Native/Operations.swift", url: nativeURL),
                .init(logicalPath: "Patch/Feature.swift", url: patchURL),
            ],
            compilerURL: compilerURL
        )

        let output = try FrontendReceipt.Adapter().generate(request)
        #expect(output.receipt.nativeImportCandidates.map(\.canonicalCallee).sorted() == [
            "\(moduleName).Math.doubled(_:)",
            "\(moduleName).adjust(_:by:)",
            "\(moduleName).checked(_:)",
            "\(moduleName).copy(_:)",
            "\(moduleName).keyword(_:repeat:)",
            "\(moduleName).mainValue(_:)",
        ])
        #expect(output.receipt.nativeImportCandidates.map(\.id) == [
            .init(rawValue: 0), .init(rawValue: 1), .init(rawValue: 2),
            .init(rawValue: 3), .init(rawValue: 4), .init(rawValue: 5),
        ])
        #expect(output.receipt.nativeImportBindings.count == 6)
        #expect(output.receipt.nativeImportBindings.allSatisfy {
            $0.generated != nil && $0.importedModules.isEmpty
        })
        var forgedLegacyReceipt = output.receipt
        forgedLegacyReceipt.schemaVersion = 5
        #expect(throws: ShellBuildReceipt.Error.self) {
            try forgedLegacyReceipt.validate()
        }
        #expect(output.receipt.configuration.modules[moduleName]?.nativeImports.allow.sorted() == [
            "\(moduleName).Math.doubled(_:)",
            "\(moduleName).adjust(_:by:)",
            "\(moduleName).checked(_:)",
            "\(moduleName).copy(_:)",
            "\(moduleName).keyword(_:repeat:)",
            "\(moduleName).mainValue(_:)",
        ])

        let adjustDeclaration = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "adjust"
        })
        var overrideRequest = request
        overrideRequest.nativeImportCatalog = NativeImportCatalog.Document(
            candidates: [
                .init(
                    canonicalCallee: "\(moduleName).overrideAdjust(_:by:)",
                    silMangledNames: [adjustDeclaration.mangledName],
                    signature: adjustDeclaration.loweredSignature,
                    effects: .init(mayAllocate: true),
                    contract: .bounded(
                        kind: .globalFunction,
                        domain: .application,
                        access: .pure,
                        maximumDurationMicroseconds: 500,
                        allowsMainThread: true
                    ),
                    factoryType: "OverrideSupport.AdjustFactory",
                    importedModules: ["OverrideSupport"]
                ),
            ]
        )
        let overridden = try FrontendReceipt.Adapter().generate(overrideRequest)
        let overriddenRecord = try #require(
            overridden.receipt.nativeImportCandidates.first {
                $0.canonicalCallee == "\(moduleName).overrideAdjust(_:by:)"
            }
        )
        #expect(overriddenRecord.isEmittedToDevice)
        let overriddenBinding = try #require(
            overridden.receipt.nativeImportBindings.first {
                $0.key == overriddenRecord.key
            }
        )
        #expect(overriddenBinding.generated == nil)
        #expect(overriddenBinding.importedModules == ["OverrideSupport"])
        #expect(overridden.diagnostics.contains { $0.code == "HLXNID008" })

        var tampered = output.receipt
        let tamperedID = try #require(tampered.nativeImportCandidates.first?.id)
        tampered.nativeImportBindings[0].invokerExpression += ".tampered"
        #expect(throws: BridgeGeneration.Error.nativeImportBindingMismatch(tamperedID)) {
            try ShellBuild.Materializer().materialize(
                receipt: tampered,
                sourceRoot: directory
            )
        }

        let shell = try ShellBuild.Materializer().materialize(
            receipt: output.receipt,
            sourceRoot: directory
        )
        let transform = try #require(shell.archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        #expect(transform.effects.mayAllocate)
        let generatedSources = shell.bridge.sourceFiles.filter {
            $0.key.contains("HelixBridge.NativeImport_")
        }
        #expect(generatedSources.count == 2)
        #expect(generatedSources.values.contains {
            $0.contains("No NativeImport adapters were required")
        })
        let generated = try #require(generatedSources.values.first {
            $0.contains("@_private(sourceFile: \"Native/Operations.swift\")")
        })
        #expect(generated.contains("@_private(sourceFile: \"Native/Operations.swift\")"))
        #expect(generated.contains("adjust(argument0, by: argument1)"))
        #expect(generated.contains("Math.doubled(argument0)"))
        #expect(generated.contains("keyword(argument0, repeat: argument1)"))
        #expect(generated.contains("VM.ClosureNativeInvoker("))
        #expect(generated.contains("catch let trap as VM.RuntimeTrap"))
        #expect(generated.contains("try context.withMainActor"))
        #expect(generated.contains("BridgeValueCodec.decodeDictionary"))
        let bridge = try #require(
            shell.bridge.sourceFiles["Generated/\(moduleName)Bridge.swift"]
        )
        #expect(bridge.contains("HelixNativeImports_"))
        try typeCheckGeneratedBridge(
            shell: shell,
            directory: directory,
            moduleName: moduleName
        )

        try Data(
            "public func transform(_ value: Int) -> Int { adjust(value, by: 1) + 3 }\n".utf8
        ).write(to: patchURL)
        let patch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [nativeURL, patchURL],
                compilerURL: compilerURL
            )
        )
        #expect(patch.disassembly.contains("native_apply"))
        _ = try Verification.Engine().verify(
            bytes: patch.bytecode,
            shell: Verification.ShellInterface(archive: shell.archive),
            policy: .init(
                acceptedCapabilities: Set(shell.archive.capabilities),
                allowedNativeImports: Set(
                    shell.archive.nativeImports.compactMap(\.id)
                )
            )
        )

        // Restore the indexed baseline before comparing the independent CLI receipt.
        try Data(
            "public func transform(_ value: Int) -> Int { adjust(value, by: 1) }\n".utf8
        ).write(to: patchURL)

        let metadataURL = directory.appendingPathComponent("ReleaseMetadata.json")
        let configurationURL = directory.appendingPathComponent("Helix.yml")
        let receiptURL = directory.appendingPathComponent("CLIReceipt.json")
        try Core.CanonicalJSON.encode(metadata).write(to: metadataURL)
        try Data(configurationYAML.utf8).write(to: configurationURL)
        let cli = CLI.Application(currentDirectoryURL: directory).run([
            "shell", "index",
            "--metadata", metadataURL.path,
            "--configuration", configurationURL.path,
            "--source-map", "Native/Operations.swift=\(nativeURL.path)",
            "--source-map", "Patch/Feature.swift=\(patchURL.path)",
            "--compiler", compilerURL.path,
            "--output", receiptURL.path,
        ])
        #expect(cli.exitCode == 0)
        #expect(cli.standardError.isEmpty)
        #expect(
            try ShellBuildReceipt.Codec.decode(Data(contentsOf: receiptURL)) == output.receipt
        )
    }

    private func typeCheckGeneratedBridge(
        shell: ShellBuild.Output,
        directory: URL,
        moduleName: String
    ) throws {
        let output = directory.appendingPathComponent("GeneratedTypecheck", isDirectory: true)
        let nativeDirectory = output.appendingPathComponent("Native", isDirectory: true)
        let patchDirectory = output.appendingPathComponent("Patch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nativeDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: patchDirectory,
            withIntermediateDirectories: true
        )
        for (path, contents) in shell.transformedSources {
            let url = output.appendingPathComponent(path)
            try contents.write(to: url)
        }
        let frontend = SwiftFrontend.Driver()
        try requireFrontendSuccess(
            frontend.run(
                arguments: [
                    "Native/Operations.swift", "Patch/Feature.swift",
                    "-emit-library", "-emit-module", "-parse-as-library",
                    "-module-name", moduleName,
                    "-Xfrontend", "-enable-private-imports",
                    "-emit-module-path", "\(moduleName).swiftmodule",
                    "-o", "lib\(moduleName).dylib",
                ],
                workingDirectory: output
            )
        )
        let generatedURLs = try shell.bridge.sourceFiles.sorted(by: { $0.key < $1.key }).map {
            let url = output.appendingPathComponent(URL(fileURLWithPath: $0.key).lastPathComponent)
            try Data($0.value.utf8).write(to: url)
            return url
        }
        let modules = try swiftPMModulesDirectory()
        try requireFrontendSuccess(
            frontend.run(
                arguments: generatedURLs.map(\.path) + [
                    "-typecheck", "-parse-as-library",
                    "-module-name", "GeneratedImportBridgeProbe",
                    "-I", output.path,
                    "-I", modules.path,
                ] + (try runtimeSupportCompilerArguments(modules: modules)) + [
                    "-Xfrontend", "-enable-private-imports",
                    "-Xfrontend", "-enable-dynamic-replacement-chaining",
                    "-warnings-as-errors",
                ],
                workingDirectory: output
            )
        )
    }

    private func swiftPMModulesDirectory() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
        var candidates: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in enumerator
            where file.lastPathComponent == "HelixRuntime.swiftmodule" {
                candidates.append(file.deletingLastPathComponent())
            }
        }
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        if let matching = candidates.first(where: {
            $0.deletingLastPathComponent().lastPathComponent == configuration
        }) {
            return matching
        }
        guard let fallback = candidates.sorted(by: { $0.path < $1.path }).first else {
            throw FrontendReceipt.Error.invalidRequest("cannot locate SwiftPM module artifacts")
        }
        return fallback
    }

    private func runtimeSupportCompilerArguments(modules: URL) throws -> [String] {
        let supportDirectory = modules.deletingLastPathComponent()
            .appendingPathComponent("HelixRuntimeSupport.build", isDirectory: true)
        let moduleMap = supportDirectory.appendingPathComponent("module.modulemap")
        guard FileManager.default.fileExists(atPath: moduleMap.path) else {
            throw FrontendReceipt.Error.invalidRequest("missing HelixRuntimeSupport module map")
        }
        return ["-Xcc", "-fmodule-map-file=\(moduleMap.path)"]
    }

    private func requireFrontendSuccess(_ output: SwiftFrontend.Output) throws {
        guard output.terminationStatus == 0 else {
            throw FrontendReceipt.Error.frontendFailed(output.standardError)
        }
    }

    @Test("A source range expands deterministically into exact value-only operations")
    func discoversEligibleOperationsAndDiagnosesBoundaries() throws {
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 2
        modules:
          ScopeFixture:
            include:
              - Patchable/**
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Native/**
                declarations:
                  - ScopeFixture.*
                visibility: public
                profile: bounded-read
                maximumDurationMicroseconds: 750
                allowsMainThread: false
        """)
        let metadata = makeMetadata(moduleName: "ScopeFixture")
        let scalar = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let declarations = [
            declaration(
                canonicalCallee: "ScopeFixture.compute(_:)",
                mangledName: "$s12ScopeFixture7computeyS2iF",
                signature: scalar
            ),
            declaration(
                canonicalCallee: "ScopeFixture.Math.double(_:)",
                mangledName: "$s12ScopeFixture4MathO6doubleyS2iFZ",
                dispatch: .staticMethod,
                ownerType: "Math",
                signature: scalar
            ),
            declaration(
                canonicalCallee: "ScopeFixture.hidden(_:)",
                mangledName: "$s12ScopeFixture6hiddenyS2iF",
                accessLevel: "internal",
                signature: scalar
            ),
            declaration(
                canonicalCallee: "ScopeFixture.Counter.increment(_:)",
                mangledName: "$s12ScopeFixture7CounterC9incrementyS2iF",
                dispatch: .instanceMethod,
                ownerType: "Counter",
                signature: scalar
            ),
            declaration(
                canonicalCallee: "ScopeFixture.suspend(_:)",
                mangledName: "$s12ScopeFixture7suspendyS2iYaF",
                signature: .init(
                    parameters: ["Swift.Int"],
                    result: "Swift.Int",
                    isAsync: true
                ),
                effects: .init(isAsync: true)
            ),
        ]

        let output = try NativeImportDiscovery.Engine().discover(
            declarations: Array(declarations.reversed()),
            metadata: metadata,
            configuration: configuration
        )

        #expect(output.candidates.map(\.record.canonicalCallee).sorted() == [
            "ScopeFixture.Math.double(_:)",
            "ScopeFixture.compute(_:)",
        ])
        #expect(output.candidates.allSatisfy {
            $0.record.contract.domain == .application
                && $0.record.contract.access == .read
                && $0.record.contract.execution.maximumDurationMicroseconds == 750
                && !$0.record.contract.execution.allowsMainThread
                && $0.record.effects.mayAllocate
                && !$0.record.effects.hasExternalSideEffects
                && $0.record.id == nil
        })
        #expect(Set(output.candidates.map(\.record.contract.kind)) == [
            .globalFunction, .staticMethod,
        ])
        #expect(output.diagnostics.map(\.code) == ["HLXNID001", "HLXNID002"])
        #expect(!output.candidates.contains {
            $0.record.canonicalCallee == "ScopeFixture.hidden(_:)"
        })

        let repeated = try NativeImportDiscovery.Engine().discover(
            declarations: declarations,
            metadata: metadata,
            configuration: configuration
        )
        #expect(repeated.candidates == output.candidates)
        #expect(repeated.diagnostics == output.diagnostics)

        var foreign = declarations[0]
        foreign.moduleName = "AnotherModule"
        #expect(throws: FrontendReceipt.Error.self) {
            try NativeImportDiscovery.Engine().discover(
                declarations: [foreign],
                metadata: metadata,
                configuration: configuration
            )
        }
    }

    @Test("Automatic discovery rejects native, address, and closure boundaries")
    func rejectsUnsupportedBoundaryTypes() throws {
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 2
        modules:
          ScopeFixture:
            include:
              - Sources/**
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Sources/**
                profile: bounded-pure
        """)
        let metadata = makeMetadata(moduleName: "ScopeFixture")
        let typeID = Core.TypeID.derive(
            namespace: metadata.shellNamespaceID,
            canonicalType: "ScopeFixture.Token"
        )
        var native = declaration(
            canonicalCallee: "ScopeFixture.consume(_:)",
            mangledName: "$s12ScopeFixture7consumeyAA5TokenCF",
            signature: .init(
                parameters: ["ScopeFixture.Token"],
                result: "Swift.Void"
            )
        )
        native.parameterSwiftTypes = ["ScopeFixture.Token"]
        native.parameterTypes = [.native(typeID)]
        native.resultSwiftType = "Swift.Void"
        native.resultType = .void
        native.sourceFileLogicalID = "Sources/Operations.swift"

        let output = try NativeImportDiscovery.Engine().discover(
            declarations: [native],
            metadata: metadata,
            configuration: configuration
        )
        #expect(output.candidates.isEmpty)
        #expect(output.diagnostics.map(\.code) == ["HLXNID005"])
    }

    private func declaration(
        canonicalCallee: String,
        mangledName: String,
        accessLevel: String = "public",
        dispatch: NativeImportDiscovery.Dispatch = .globalFunction,
        ownerType: String? = nil,
        signature: Core.LoweredSignature,
        effects: Core.Effects = .init()
    ) -> NativeImportDiscovery.Declaration {
        .init(
            moduleName: "ScopeFixture",
            sourceFileLogicalID: "Native/Operations.swift",
            mangledName: mangledName,
            canonicalCallee: canonicalCallee,
            accessLevel: accessLevel,
            dispatch: dispatch,
            ownerType: ownerType,
            baseName: canonicalCallee.contains("double") ? "double" :
                canonicalCallee.split(separator: ".").last.map {
                    String($0.split(separator: "(").first ?? $0)
                } ?? "operation",
            argumentLabels: ["_"],
            parameterSwiftTypes: ["Swift.Int"],
            resultSwiftType: "Swift.Int",
            parameterTypes: [.int64],
            resultType: .int64,
            signature: signature,
            inferredEffects: effects,
            isGeneric: false,
            hasInOut: false,
            hasTypedThrows: false,
            hasUnsupportedAttributes: false
        )
    }

    private func makeMetadata(moduleName: String) -> InterfaceArchive.ReleaseMetadata {
        let target = "arm64-apple-ios15.0-simulator"
        return .init(
            bundleID: "dev.helix.native-import-scope",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.native-import-scope",
                buildNumber: "1",
                seed: "scope-fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "test",
            sdkBuild: "test",
            frontendInvocation: .init(
                moduleName: moduleName,
                targetTriple: target,
                sdkName: "iphonesimulator",
                sdkBuild: "test",
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("test")
        )
    }
}
}
