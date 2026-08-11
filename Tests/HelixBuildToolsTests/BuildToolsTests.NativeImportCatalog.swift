import Foundation
import HelixBytecode
import HelixCLIKit
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Explicit Native Import Catalog")
struct NativeImportCatalogPipeline {
    @Test("Catalog JSON is canonical and rejects ambiguous or dishonest descriptors")
    func validatesCatalogDocuments() throws {
        let candidate = makeCandidate(
            canonicalCallee: "Fixture.increment(_:)",
            symbol: "$s7Fixture9incrementyS2iF",
            factoryType: "FixtureSupport.IncrementFactory",
            module: "FixtureSupport"
        )
        let document = NativeImportCatalog.Document(candidates: [candidate])
        let bytes = try NativeImportCatalog.Codec.encode(document)
        #expect(try NativeImportCatalog.Codec.decode(bytes) == document)

        var nonCanonical = bytes
        nonCanonical.append(UInt8(ascii: "\n"))
        #expect(throws: NativeImportCatalog.Error.nonCanonical) {
            try NativeImportCatalog.Codec.decode(nonCanonical)
        }

        let duplicateSymbol = makeCandidate(
            canonicalCallee: "Fixture.other(_:)",
            symbol: candidate.silMangledNames[0],
            factoryType: "FixtureSupport.OtherFactory",
            module: "FixtureSupport"
        )
        #expect(throws: NativeImportCatalog.Error.invalid(
            "types or candidates are oversized, duplicated, or not canonical"
        )) {
            try NativeImportCatalog.Document(
                candidates: [candidate, duplicateSymbol]
            ).validate()
        }

        var dishonest = candidate
        dishonest.signature.parameters = ["Swift.UnsafeRawPointer"]
        #expect(throws: NativeImportCatalog.Error.invalid(
            "candidate Fixture.increment(_:) has an invalid symbol, signature, factory, or type"
        )) {
            try NativeImportCatalog.Document(candidates: [dishonest]).validate()
        }

        var invalidFactory = candidate
        invalidFactory.factoryType = "MissingQualification"
        #expect(throws: NativeImportCatalog.Error.invalid(
            "candidate Fixture.increment(_:) has an invalid symbol, signature, factory, or type"
        )) {
            try NativeImportCatalog.Document(candidates: [invalidFactory]).validate()
        }
    }

    @Test("Catalog models UIKit types, getters, setters, and execution effects explicitly")
    func validatesFrameworkContractsAndNativeTypes() throws {
        let viewType = NativeImportCatalog.NativeType(
            canonicalName: "UIKit.UIView",
            kind: .reference,
            layoutFingerprint: .sha256("UIKit.UIView.reference.v1"),
            isCopyable: true,
            requiresMainActor: true,
            estimatedSize: 8,
            factoryType: "UIKitSupport.UIViewTypeFactory",
            importedModules: ["UIKitSupport", "UIKit"]
        )
        let getter = NativeImportCatalog.Candidate(
            canonicalCallee: "UIKit.UIView.isHidden.getter",
            silMangledNames: ["$s5UIKit6UIViewC8isHiddenSbvg"],
            signature: .init(
                parameters: ["UIKit.UIView"],
                result: "Swift.Bool",
                isolation: "MainActor"
            ),
            effects: .init(requiresMainActor: true),
            contract: .bounded(
                kind: .instanceGetter,
                domain: .uiKit,
                access: .read,
                maximumDurationMicroseconds: 500,
                allowsMainThread: true
            ),
            factoryType: "UIKitSupport.IsHiddenGetterFactory",
            importedModules: ["UIKitSupport", "UIKit"]
        )
        let setter = NativeImportCatalog.Candidate(
            canonicalCallee: "UIKit.UIView.isHidden.setter",
            silMangledNames: ["$s5UIKit6UIViewC8isHiddenSbvs"],
            signature: .init(
                parameters: ["UIKit.UIView", "Swift.Bool"],
                result: "Swift.Void",
                isolation: "MainActor"
            ),
            effects: .init(
                hasExternalSideEffects: true,
                requiresMainActor: true
            ),
            contract: .bounded(
                kind: .instanceSetter,
                domain: .uiKit,
                access: .write,
                maximumDurationMicroseconds: 500,
                allowsMainThread: true
            ),
            factoryType: "UIKitSupport.IsHiddenSetterFactory",
            importedModules: ["UIKitSupport", "UIKit"]
        )
        let document = NativeImportCatalog.Document(
            nativeTypes: [viewType],
            candidates: [setter, getter]
        )
        try document.validate()
        #expect(
            try NativeImportCatalog.Codec.decode(
                NativeImportCatalog.Codec.encode(document)
            ) == document
        )

        var unsafeIO = getter
        unsafeIO.canonicalCallee = "UIKit.UIView.loadRemoteState()"
        unsafeIO.silMangledNames = ["$s5UIKit6UIViewC15loadRemoteStateyyF"]
        unsafeIO.effects.hasExternalSideEffects = true
        unsafeIO.contract = .cooperative(
            kind: .instanceMethod,
            domain: .uiKit,
            access: .io,
            maximumDurationMicroseconds: 10_000,
            allowsMainThread: true
        )
        #expect(throws: NativeImportCatalog.Error.self) {
            try NativeImportCatalog.Document(
                nativeTypes: [viewType],
                candidates: [unsafeIO]
            ).validate()
        }
    }

    @Test("Real Swift indexing freezes allowlisted factories and CLI emits the same receipt")
    func indexesAndMaterializesAllowlistedFactories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-native-import-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = sourceDirectory.appendingPathComponent("Patch.swift")
        let source = """
        func increment(_ value: Int) -> Int { value + 1 }
        func dormant(_ value: Int) -> Int { value - 1 }
        public func transform(_ value: Int) -> Int {
            increment(value) + dormant(value)
        }
        """
        try Data(source.utf8).write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "NativeImportFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: moduleName,
            targetTriple: target,
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion,
            optimization: "-Onone",
            semanticArguments: ["-parse-as-library"]
        )
        let sil = try CanonicalSIL.File(
            text: frontend.emitCanonicalSIL(
                sourceFiles: [sourceURL],
                invocation: invocation
            )
        )
        let increment = try sil.uniqueFunction(mangledNameContaining: "increment")
        let dormant = try sil.uniqueFunction(mangledNameContaining: "dormant")
        let incrementCallee = "\(moduleName).increment(_:)"
        let dormantCallee = "\(moduleName).dormant(_:)"
        let catalog = NativeImportCatalog.Document(
            candidates: [
                makeCandidate(
                    canonicalCallee: incrementCallee,
                    symbol: increment.mangledName,
                    factoryType: "NativeSupport.IncrementFactory",
                    module: "NativeSupport"
                ),
                makeCandidate(
                    canonicalCallee: dormantCallee,
                    symbol: dormant.mangledName,
                    factoryType: "DormantSupport.DormantFactory",
                    module: "DormantSupport"
                ),
            ]
        )
        let configurationYAML = """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**/*.swift
            entrypoints: public
            nativeImports:
              candidateIndex: explicit-catalog
              emit: allowlisted
              allow:
                - \(incrementCallee)
        """
        let configuration = try PatchConfiguration.Document.parse(yaml: configurationYAML)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.native-import-catalog",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.native-import-catalog",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "integration-test",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: invocation,
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by the indexer")
        )

        let output = try FrontendReceipt.Adapter().generate(
            .init(
                metadata: metadata,
                configuration: configuration,
                sources: [
                    .init(logicalPath: "Sources/Patch.swift", url: sourceURL),
                ],
                compilerURL: compilerURL,
                nativeImportCatalog: catalog
            )
        )
        let receipt = output.receipt
        #expect(receipt.nativeImportCandidates.count == 2)
        #expect(receipt.nativeImportCandidates.filter(\.isEmittedToDevice).count == 1)
        #expect(receipt.nativeImportCandidates.first {
            $0.canonicalCallee == incrementCallee
        }?.id == .init(rawValue: 0))
        #expect(receipt.nativeImportCandidates.first {
            $0.canonicalCallee == dormantCallee
        }?.id == nil)
        #expect(receipt.nativeImportBindings.count == 1)
        #expect(receipt.nativeImportBindings[0].importedModules == ["NativeSupport"])
        #expect(receipt.capabilities.contains(.nativeImportsV2))

        let shell = try ShellBuild.Materializer().materialize(
            receipt: receipt,
            sourceRoot: directory
        )
        #expect(shell.archive.nativeImports.count == 2)
        #expect(shell.report.emittedNativeImportCount == 1)
        let bridge = try #require(shell.bridge.sourceFiles[
            "Generated/\(moduleName)Bridge.swift"
        ])
        #expect(bridge.contains("import NativeSupport"))
        #expect(!bridge.contains("import DormantSupport"))
        #expect(bridge.contains("NativeSupport.IncrementFactory.make("))
        #expect(!bridge.contains("DormantSupport.DormantFactory.make("))

        let metadataURL = directory.appendingPathComponent("ReleaseMetadata.json")
        let configurationURL = directory.appendingPathComponent("Helix.yml")
        let catalogURL = directory.appendingPathComponent("NativeImports.json")
        let cliReceiptURL = directory.appendingPathComponent("CLIReceipt.json")
        try Core.CanonicalJSON.encode(metadata).write(to: metadataURL)
        try Data(configurationYAML.utf8).write(to: configurationURL)
        try NativeImportCatalog.Codec.encode(catalog).write(to: catalogURL)
        let cli = CLI.Application(currentDirectoryURL: directory).run([
            "shell", "index",
            "--metadata", metadataURL.path,
            "--configuration", configurationURL.path,
            "--source-map", "Sources/Patch.swift=\(sourceURL.path)",
            "--compiler", compilerURL.path,
            "--native-import-catalog", catalogURL.path,
            "--output", cliReceiptURL.path,
        ])
        #expect(cli.exitCode == 0)
        #expect(cli.standardError.isEmpty)
        #expect(
            try ShellBuildReceipt.Codec.decode(Data(contentsOf: cliReceiptURL)) == receipt
        )
    }

    @Test("Frontend resolves cataloged App reference types into Bridge and TypeOps bindings")
    func resolvesNativeTypesThroughFrontend() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-native-type-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = sourceDirectory.appendingPathComponent("Patch.swift")
        try Data(
            """
            public final class Token {}
            @MainActor public func identity(_ value: Token) -> Token { value }
            public func unsafeIdentity(_ value: Token) -> Token { value }
            """.utf8
        ).write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "NativeTypeFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: moduleName,
            targetTriple: target,
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion,
            optimization: "-Onone",
            semanticArguments: ["-parse-as-library"]
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.native-type-catalog",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.native-type-catalog",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "integration-test",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: invocation,
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by indexer")
        )
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**/*.swift
            nativeImports:
              candidateIndex: explicit-catalog
              emit: allowlisted
        """)
        let typeName = "\(moduleName).Token"
        let layout = Core.Digest.sha256("\(typeName).reference.v1")
        let catalog = NativeImportCatalog.Document(
            nativeTypes: [
                .init(
                    canonicalName: typeName,
                    kind: .reference,
                    layoutFingerprint: layout,
                    isCopyable: true,
                    requiresMainActor: true,
                    estimatedSize: 8,
                    factoryType: "NativeSupport.TokenTypeFactory",
                    importedModules: ["NativeSupport"]
                ),
            ],
            candidates: []
        )

        let output = try FrontendReceipt.Adapter().generate(
            .init(
                metadata: metadata,
                configuration: configuration,
                sources: [.init(logicalPath: "Sources/Patch.swift", url: sourceURL)],
                compilerURL: compilerURL,
                nativeImportCatalog: catalog
            )
        )
        let receipt = output.receipt
        let type = try #require(receipt.nativeTypes.first)
        #expect(type.canonicalName == typeName)
        #expect(type.id == Core.TypeID.derive(
            namespace: metadata.shellNamespaceID,
            canonicalType: typeName
        ))
        #expect(receipt.capabilities.contains(.nativeTypesV1))
        #expect(receipt.capabilities.contains(.mainActorSyncV1))
        #expect(receipt.nativeTypeBindings.first?.importedModules == ["NativeSupport"])
        let identity = try #require(receipt.declarations.first {
            $0.canonicalDeclaration.contains("func identity(")
        })
        #expect(identity.parameterTypes == [.native(type.id)])
        #expect(identity.resultType == .native(type.id))
        #expect(identity.effects.requiresMainActor)
        let unsafeIdentity = try #require(receipt.declarations.first {
            $0.canonicalDeclaration.contains("unsafeIdentity")
        })
        #expect(unsafeIdentity.forcedPatchability == nil)
        #expect(output.diagnostics.contains { $0.code == "HLXIDX021" })

        let shell = try ShellBuild.Materializer().materialize(
            receipt: receipt,
            sourceRoot: directory
        )
        #expect(shell.archive.functions.first {
            $0.canonicalDeclaration.contains("unsafeIdentity")
        }?.patchability.reasonCode == "HLXIDX021")
        let bridge = try #require(shell.bridge.sourceFiles[
            "Generated/\(moduleName)Bridge.swift"
        ])
        #expect(bridge.contains("import NativeSupport"))
        #expect(bridge.contains("NativeSupport.TokenTypeFactory.make("))
        #expect(bridge.contains("requiresMainActor: true"))
    }

    private func makeCandidate(
        canonicalCallee: String,
        symbol: String,
        factoryType: String,
        module: String
    ) -> NativeImportCatalog.Candidate {
        .init(
            canonicalCallee: canonicalCallee,
            silMangledNames: [symbol],
            signature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int"
            ),
            contract: .bounded(
                kind: .globalFunction,
                domain: .application,
                access: .pure,
                maximumDurationMicroseconds: 1_000,
                allowsMainThread: true
            ),
            factoryType: factoryType,
            importedModules: [module]
        )
    }
}
}
