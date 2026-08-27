import Foundation
import HelixBytecode
import HelixCLIKit
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixInterface
import HelixLiveReloadAPI
import Testing
@testable import HelixBuildTools

enum BuildToolsTests {}

extension BuildToolsTests {
@Suite("Typed Shell build materialization")
struct ShellBuildPipeline {
    @Test("One receipt derives transformed sources, Bridge, HLXI, and Reload Index")
    func materializesCompleteShellContract() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let encodedReceipt = try ShellBuildReceipt.Codec.encode(fixture.receipt)
        let decodedReceipt = try ShellBuildReceipt.Codec.decode(encodedReceipt)
        let output = try ShellBuild.Materializer().materialize(
            receipt: decodedReceipt,
            sourceRoot: fixture.directory
        )

        #expect(output.archive.metadata.machOUUIDs.isEmpty)
        #expect(output.archive.metadata.transformPipelineHash == ShellBuild.transformPipelineHash)
        #expect(output.archive.sources.count == 1)
        #expect(output.archive.sources[0].transformHash != nil)
        #expect(output.archive.bridgeRegistrationCount == 1)
        #expect(output.bridge.registrationCount == 1)
        #expect(output.reloadIndex.roots.count == 1)
        #expect(output.reloadIndex.nativeReplacements.count == 1)
        #expect(output.reloadIndex.explicitReloadRules.count == 1)
        #expect(output.reloadIndex.factories.count == 1)

        let transformed = try #require(
            output.transformedSources["Sources/Patch.swift"]
        )
        #expect(String(decoding: transformed, as: UTF8.self).contains("public dynamic func transform"))
        let artifacts = try output.artifacts()
        #expect(artifacts["Shell.provisional.hlxi"] == output.archiveBytes)
        #expect(
            artifacts["NativeCapabilities.json"]
                == output.nativeCapabilityManifestBytes
        )
        #expect(
            output.report.nativeCapabilityManifestHash
                == .sha256(output.nativeCapabilityManifestBytes)
        )
        #expect(
            output.report.nativeCapabilityCount
                == UInt32(output.nativeCapabilityManifest.entries.count)
        )
        #expect(artifacts["ReloadIndex.json"] == output.reloadIndexBytes)
        #expect(
            artifacts["DerivedSources/Sources/HelixGenerated.Patch.swift"] == transformed
        )
        #expect(artifacts.keys.contains("ShellBuildReport.json"))
        #expect(artifacts.keys.contains { $0.hasPrefix("Generated/HelixBridge.Entry_") })
        #expect(artifacts.keys.contains("Generated/FixtureBridge.swift"))
        let bridge = String(
            decoding: try #require(artifacts["Generated/FixtureBridge.swift"]),
            as: UTF8.self
        )
        #expect(bridge.contains("makeNativeCapabilityManifest()"))
        #expect(bridge.contains("from shell: Verification.ShellInterface"))
        #expect(bridge.contains("public static func makePatchBuildContract()"))
        #expect(bridge.contains("runtimeImageIdentity: .current"))
        #expect(bridge.contains("#elseif canImport(HelixAppIntegration)"))
        #expect(artifacts["Generated/FixtureBridge.HubContract.swift"] == nil)
        let provider = String(
            decoding: try #require(
                artifacts["Generated/FixtureBridge.Provider.swift"]
            ),
            as: UTF8.self
        )
        #expect(provider.contains("@_cdecl(\"hlx_bridge_provider_v1\")"))
        #expect(provider.contains("Runtime.BridgeProvider"))
        #expect(provider.contains("nativeCapabilityManifest:"))
        #expect(provider.contains("makeNativeCapabilityManifest(from: shell)"))
        #expect(provider.contains(output.report.reloadIndexHash.hex))
        #expect(provider.contains("makeShellInterface: {"))
        #expect(provider.contains("try FixtureBridge.makeShellInterface()"))
        #expect(provider.contains("makeShellInterface: {\n                    shell\n"))
        #expect(provider.contains("install: { runtime in"))
        #expect(provider.contains("try FixtureBridge.bootstrap(using: runtime)"))
        #expect(provider.contains("#elseif canImport(HelixAppIntegration)"))
        let planBytes = try #require(artifacts["Xcode/IntegrationPlan.json"])
        let plan = try JSONDecoder().decode(XcodeIntegration.Plan.self, from: planBytes)
        try plan.validate()
        #expect(plan.featureModuleName == "Fixture")
        #expect(plan.bridgeModuleName == "FixtureHelixBridge")
        #expect(plan.releaseRuntimePackageProduct == "HelixAppIntegration")
        #expect(plan.developmentRuntimePackageProduct == "HelixDevSupport")
        #expect(try Core.CanonicalJSON.encode(plan) == planBytes)
        let featureList = String(
            decoding: try #require(artifacts[plan.featureSourceList]),
            as: UTF8.self
        )
        #expect(
            featureList
                == "$(HELIX_SHELL_OUTPUT_DIR)/DerivedSources/Sources/"
                    + "HelixGenerated.Patch.swift\n"
        )
        let bridgeList = String(
            decoding: try #require(artifacts[plan.bridgeSourceList]),
            as: UTF8.self
        )
        #expect(bridgeList.contains("$(HELIX_SHELL_OUTPUT_DIR)/Generated/"))
        #expect(artifacts.keys.contains("Xcode/HelixShell.xcconfig"))
        let xcconfig = String(
            decoding: try #require(artifacts["Xcode/HelixShell.xcconfig"]),
            as: UTF8.self
        )
        #expect(xcconfig.contains("HELIX_RELEASE_RUNTIME_PRODUCT = HelixAppIntegration"))
        #expect(xcconfig.contains("HELIX_DEV_RUNTIME_PRODUCT = HelixDevSupport"))
        #expect(
            output.report.generatedSources.map(\.path)
                == output.report.generatedSources.map(\.path).sorted()
        )

        let uuid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let finalized = try ShellBuild.Finalizer().finalize(
            provisionalArchive: output.archive,
            machOUUIDs: [uuid]
        )
        #expect(finalized.metadata.machOUUIDs == [uuid])
        #expect(finalized.shellInterfaceHash == output.archive.shellInterfaceHash)
        #expect(try finalized.archiveDigest() != output.archive.archiveDigest())
        let roundTripped = try InterfaceArchive.Codec.decode(
            InterfaceArchive.Codec.encode(finalized)
        ).archive
        #expect(roundTripped == finalized)
    }

    @Test("Exact source mappings support files outside the project root")
    func materializesExactSourceMappings() throws {
        let fixture = try makeFixture()
        let generatedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-shell-generated-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
            try? FileManager.default.removeItem(at: generatedRoot)
        }
        try FileManager.default.createDirectory(
            at: generatedRoot,
            withIntermediateDirectories: true
        )
        let generated = generatedRoot.appendingPathComponent("Unexpected Name.swift")
        try Data(contentsOf: fixture.directory.appendingPathComponent(
            "Sources/Patch.swift"
        )).write(to: generated)

        let output = try ShellBuild.Materializer().materialize(
            receipt: fixture.receipt,
            sourceMappings: ["Sources/Patch.swift": generated]
        )
        #expect(output.archive.sources.map(\.logicalPath) == ["Sources/Patch.swift"])

        #expect(throws: ShellBuild.Error.self) {
            try ShellBuild.Materializer().materialize(
                receipt: fixture.receipt,
                sourceMappings: ["Wrong.swift": generated]
            )
        }
    }

    @Test("A Dev Shell embeds only its pinned Hub invitation contract")
    func embedsHubContract() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let reservation = Pairing.Reservation(
            invitationID: .init(rawValue: UUID()),
            code: try Pairing.Code("AB23"),
            kind: .automaticXcode,
            reservedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        let binding = try ShellBuild.HubBinding(
            reservation: reservation,
            spkiSHA256: .sha256("host identity")
        )
        let output = try ShellBuild.Materializer().materialize(
            receipt: fixture.receipt,
            sourceRoot: fixture.directory,
            hubBinding: binding
        )
        let source = String(
            decoding: try #require(
                output.xcodeIntegration.artifacts[
                    "Generated/FixtureBridge.HubContract.swift"
                ] ?? output.bridge.sourceFiles[
                    "Generated/FixtureBridge.HubContract.swift"
                ].map { Data($0.utf8) }
            ),
            as: UTF8.self
        )
        #expect(source.contains("@_cdecl(\"hlx_dev_hub_contract_v1\")"))
        #expect(source.contains(binding.spkiSHA256.hex))
        #expect(source.contains("\"AB23\""))
        #expect(!source.contains(reservation.invitationID.rawValue.uuidString))
    }

    @Test("Receipt bytes are canonical and unknown fields cannot survive decoding")
    func rejectsNonCanonicalReceipt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var bytes = try ShellBuildReceipt.Codec.encode(fixture.receipt)
        bytes.append(UInt8(ascii: "\n"))

        #expect(throws: ShellBuildReceipt.Error.nonCanonical) {
            try ShellBuildReceipt.Codec.decode(bytes)
        }
    }

    @Test("Only the current Shell Build Receipt schema is accepted")
    func rejectsNonCurrentSchema() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var unsupported = fixture.receipt
        unsupported.schemaVersion = 2
        #expect(throws: ShellBuildReceipt.Error.unsupportedSchema(2)) {
            try ShellBuildReceipt.Codec.encode(unsupported)
        }
    }

    @Test("Only property observers may omit a source-callable OriginalEntry")
    func rejectsMissingOrdinaryBridgeInvocation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var forged = fixture.receipt
        var root = try #require(forged.roots.first)
        var bridge = try #require(root.bridge)
        bridge.bridgeInvocation = nil
        root.bridge = bridge
        forged.roots[0] = root

        #expect(throws: ShellBuildReceipt.Error.self) {
            try forged.validate()
        }
    }

    @Test("The current receipt rejects an Entry and NativeImport identity overlap")
    func rejectsEntryNativeImportOverlap() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var forged = fixture.receipt
        let entry = try #require(forged.roots.first?.declarationMangledName)
        let declaration = try #require(forged.declarations.first)
        let effects = Core.Effects()
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.forged(_:)",
            signature: declaration.loweredSignature,
            effects: effects,
            contract: contract
        )
        let key = try Core.NativeCall.Key.derive(descriptor: descriptor)
        forged.nativeImportCandidates = [
            .init(
                id: nil,
                key: key,
                descriptor: descriptor,
                silMangledNames: [entry],
                parameterTypes: declaration.parameterTypes,
                resultType: declaration.resultType,
                contract: contract,
                capability: .nativeImportsV1,
                isEmittedToDevice: false
            ),
        ]

        #expect(throws: ShellBuildReceipt.Error.self) {
            try forged.validate()
        }
    }

    @Test("A source mutation after typed indexing fails closed")
    func rejectsChangedSource() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("public func transform(_ x: Int) -> Int { x + 99 }\n".utf8)
            .write(to: fixture.sourceURL, options: .atomic)

        #expect(throws: ShellBuild.Error.sourceHashMismatch("Sources/Patch.swift")) {
            try ShellBuild.Materializer().materialize(
                receipt: fixture.receipt,
                sourceRoot: fixture.directory
            )
        }
    }

    @Test("Source limits include generated transform expansion")
    func rejectsExpandedSourceBeyondLimit() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let materializer = ShellBuild.Materializer(
            limits: .init(
                maximumSourceBytes: fixture.sourceData.count,
                maximumTotalSourceBytes: fixture.sourceData.count
            )
        )

        #expect(throws: ShellBuild.Error.sourceSetTooLarge) {
            try materializer.materialize(
                receipt: fixture.receipt,
                sourceRoot: fixture.directory
            )
        }
    }

    @Test("Xcode integration rejects paths that can expand build settings")
    func rejectsUnsafeXcodeSourcePath() {
        #expect(throws: XcodeIntegration.Error.invalidSources) {
            try XcodeIntegration.Generator().generate(
                moduleName: "Fixture",
                transformedSourcePaths: ["Sources/$(INJECT).swift"],
                bridgeSourcePaths: ["Generated/Bridge.swift"]
            )
        }
    }

    @Test("Metadata factory freezes deterministic pre-link identity")
    func metadataFactory() throws {
        let request = ShellBuild.MetadataRequest(
            bundleID: "dev.helix.fixture",
            buildNumber: "42",
            namespaceSeed: "team-owned-stable-seed",
            minimumOS: .init(15),
            xcodeBuild: "18A1",
            frontendInvocation: .init(
                moduleName: "Fixture",
                targetTriple: "arm64-apple-ios15.0-simulator",
                sdkName: "iphonesimulator",
                sdkBuild: "24A1",
                optimization: "-Onone",
                semanticArguments: ["-enable-library-evolution"]
            )
        )
        let first = try ShellBuild.MetadataFactory().make(request)
        let second = try ShellBuild.MetadataFactory().make(request)
        #expect(first == second)
        #expect(first.machOUUIDs.isEmpty)
        #expect(first.transformPipelineHash == ShellBuild.transformPipelineHash)
        #expect(first.targetTriple == first.frontendInvocation.targetTriple)
        #expect(first.sdkBuild == first.frontendInvocation.sdkBuild)
        let zero = try Core.Digest(
            bytes: repeatElement(UInt8(0), count: Core.Digest.byteCount)
        )
        #expect(first.sourceBaselineHash == zero)

        var mismatched = request
        mismatched.minimumOS = .init(16)
        #expect(throws: ShellBuild.Error.self) {
            try ShellBuild.MetadataFactory().make(mismatched)
        }
        var unsafe = request
        unsafe.frontendInvocation.semanticArguments = ["-emit-ir"]
        #expect(throws: InterfaceArchive.Error.self) {
            try ShellBuild.MetadataFactory().make(unsafe)
        }
    }

    @Test("A source symlink cannot escape the declared source root")
    func rejectsEscapingSourceSymlink() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let outside = fixture.directory.deletingLastPathComponent()
            .appendingPathComponent("helix-outside-\(UUID().uuidString).swift")
        try fixture.sourceData.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: fixture.sourceURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.sourceURL,
            withDestinationURL: outside
        )

        #expect(throws: ShellBuild.Error.sourceEscapesRoot("Sources/Patch.swift")) {
            try ShellBuild.Materializer().materialize(
                receipt: fixture.receipt,
                sourceRoot: fixture.directory
            )
        }
    }

    @Test("Every eligible function must have exactly one typed Bridge root")
    func rejectsIncompleteRootSet() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var receipt = fixture.receipt
        receipt.roots = []

        #expect(throws: ShellBuild.Error.rootSetMismatch) {
            try ShellBuild.Materializer().materialize(
                receipt: receipt,
                sourceRoot: fixture.directory
            )
        }
    }

    @Test("A Native declaration occurrence must match its typed source offset")
    func rejectsMismatchedNativeOccurrence() throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let duplicate = "// func transform(_ x: Int) -> Int {\n"
        let source = Data(duplicate.utf8) + fixture.sourceData
        try source.write(to: fixture.sourceURL)
        fixture.receipt.sources[0].contentHash = .sha256(source)
        fixture.receipt.roots[0].declarationUTF8Offset += duplicate.utf8.count
        fixture.receipt.roots[0].nativeReplacement?
            .declarationAnchorUTF8Offset += duplicate.utf8.count

        #expect(throws: ShellBuild.Error.self) {
            try ShellBuild.Materializer().materialize(
                receipt: fixture.receipt,
                sourceRoot: fixture.directory
            )
        }
    }

    @Test("Finalization accepts only a provisional archive and unique UUIDs")
    func enforcesTwoPhaseIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provisional = try ShellBuild.Materializer().materialize(
            receipt: fixture.receipt,
            sourceRoot: fixture.directory
        ).archive
        let uuid = UUID()
        let final = try ShellBuild.Finalizer().finalize(
            provisionalArchive: provisional,
            machOUUIDs: [uuid]
        )

        #expect(throws: ShellBuild.Error.prelinkArchiveRequired) {
            try ShellBuild.Finalizer().finalize(
                provisionalArchive: final,
                machOUUIDs: [UUID()]
            )
        }
        #expect(throws: ShellBuild.Error.missingMachOUUID) {
            try ShellBuild.Finalizer().finalize(
                provisionalArchive: provisional,
                machOUUIDs: [uuid, uuid]
            )
        }
    }

    @Test("CLI commits a complete Shell directory and replaces it only with force")
    func cliMaterializesAtomically() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let receiptURL = fixture.directory.appendingPathComponent("ShellBuildReceipt.json")
        try ShellBuildReceipt.Codec.encode(fixture.receipt).write(to: receiptURL)
        let outputURL = fixture.directory.appendingPathComponent(
            "ShellDerived",
            isDirectory: true
        )
        let application = CLI.Application(currentDirectoryURL: fixture.directory)
        let arguments = [
            "shell", "build",
            "--receipt", receiptURL.path,
            "--source-root", fixture.directory.path,
            "--output", outputURL.path,
        ]

        let first = application.run(arguments)
        #expect(first.exitCode == 0)
        #expect(
            FileManager.default.fileExists(
                atPath: outputURL.appendingPathComponent("Shell.provisional.hlxi").path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: outputURL.appendingPathComponent("Generated/FixtureBridge.swift").path
            )
        )
        #expect(!FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent(
                "Generated/FixtureBridge.HubContract.swift"
            ).path
        ))
        #expect(
            FileManager.default.fileExists(
                atPath: outputURL.appendingPathComponent(
                    "Generated/FixtureBridge.Provider.swift"
                ).path
            )
        )
        let marker = outputURL.appendingPathComponent("stale")
        try Data("stale".utf8).write(to: marker)

        let refused = application.run(arguments)
        #expect(refused.exitCode == 1)
        #expect(refused.standardError.contains("output already exists"))
        let replaced = application.run(arguments + ["--force"])
        #expect(replaced.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("CLI emits canonical pre-link metadata and honors output collision policy")
    func cliCreatesMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-shell-metadata-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("ReleaseMetadata.json")
        let arguments = [
            "shell", "metadata",
            "--bundle-id", "dev.helix.fixture",
            "--build-number", "42",
            "--namespace-seed", "stable-seed",
            "--module", "Fixture",
            "--target", "arm64-apple-ios15.0-simulator",
            "--minimum-os", "15.0",
            "--xcode-build", "18A1",
            "--sdk-name", "iphonesimulator",
            "--sdk-build", "24A1",
            "--optimization=-Onone",
            "--semantic-argument=-enable-library-evolution",
            "--output", output.path,
        ]
        let application = CLI.Application(currentDirectoryURL: directory)

        let created = application.run(arguments)
        #expect(created.exitCode == 0)
        let bytes = try Data(contentsOf: output)
        let metadata = try JSONDecoder().decode(
            InterfaceArchive.ReleaseMetadata.self,
            from: bytes
        )
        #expect(metadata.minimumOS == .init(15))
        #expect(metadata.frontendInvocation.semanticArguments == ["-enable-library-evolution"])
        #expect(try Core.CanonicalJSON.encode(metadata) == bytes)

        let refused = application.run(arguments)
        #expect(refused.exitCode == 1)
        #expect(refused.standardError.contains("output already exists"))
        #expect(application.run(arguments + ["--force"]).exitCode == 0)
    }

    private struct Fixture {
        var directory: URL
        var sourceURL: URL
        var sourceData: Data
        var receipt: ShellBuildReceipt.Document
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-shell-build-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let sourceText = "public func transform(_ x: Int) -> Int { x + 27 }\n"
        let sourceData = Data(sourceText.utf8)
        let sourceURL = sourceDirectory.appendingPathComponent("Patch.swift")
        try sourceData.write(to: sourceURL)
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.shell-build",
            buildNumber: "1",
            seed: "fixture"
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.shell-build",
            buildNumber: "1",
            shellNamespaceID: namespace,
            machOUUIDs: [],
            targetTriple: "arm64-apple-ios15.0",
            minimumOS: .init(15),
            xcodeBuild: "18A1",
            sdkBuild: "24A1",
            frontendInvocation: .init(
                moduleName: "Fixture",
                targetTriple: "arm64-apple-ios15.0",
                sdkName: "iphoneos",
                sdkBuild: "24A1"
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("filled by materializer")
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-shell-build-fixture"
        )
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          Fixture:
            include:
              - Sources/**/*.swift
        """)
        let interface = ReleaseCompiler.DeclarationInterface(
            declarationKind: "function",
            baseName: "transform",
            argumentLabels: ["_"],
            accessLevel: "public",
            canonicalFormalType: "(Swift.Int) -> Swift.Int",
            loweredSILType: "@convention(thin) (Int) -> Int"
        )
        let mangledName = "$s7Fixture9transformyS2iF"
        let declaration = ReleaseCompiler.DeclarationCandidate(
            moduleName: "Fixture",
            sourceFileLogicalID: "Sources/Patch.swift",
            canonicalDeclaration: "func transform(_: Int) -> Int",
            mangledName: mangledName,
            role: .function,
            loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64],
            resultType: .int64,
            interface: interface,
            canonicalSILBody: "return %0"
        )
        let controller = ShellBuildReceipt.NominalType(
            moduleName: "Fixture",
            canonicalName: "PatchViewController"
        )
        let root = ShellBuildReceipt.Root(
            declarationMangledName: mangledName,
            declarationUTF8Offset: Data("public ".utf8).count,
            expectedDeclarationPrefix: "func transform",
            sourceDeclaration: .init(
                identity: "s:7Fixture9transformyS2iF",
                kind: .function,
                originalReference: "transform(_:)",
                replacementHeader:
                    "public func helixBridge_transform(_ x: Int) -> Int",
                members: [
                    .init(
                        role: .functionBody,
                        fallbackBody: "return transform(x)"
                    ),
                ]
            ),
            memberRole: .functionBody,
            reloadRole: .viewLoadOrInitialization,
            nominalType: controller,
            bridge: .init(
                privateImportSourceFile: "Sources/Patch.swift",
                parameterExpressions: ["x"],
                parameterSwiftTypes: ["Swift.Int"],
                resultSwiftType: "Swift.Int",
                originalInvocation: "transform(x)",
                bridgeInvocation: "helixBridge_transform(argument0)"
            ),
            nativeReplacement: .init(
                declarationAnchorUTF8Offset: Data("public ".utf8).count,
                declarationAnchor: "func transform(_ x: Int) -> Int {",
                loweredType: "@convention(thin) (Int) -> Int"
            )
        )
        let factoryID = LiveReload.FactoryID(rawValue: "fixture.patch-controller")
        let receipt = ShellBuildReceipt.Document(
            metadata: metadata,
            compatibility: compatibility,
            configuration: configuration,
            sources: [
                .init(logicalPath: "Sources/Patch.swift", contentHash: .sha256(sourceData)),
            ],
            declarations: [declaration],
            roots: [root],
            superclassEdges: [
                .init(
                    subtype: controller,
                    superclass: .init(moduleName: "UIKit", canonicalName: "UIViewController")
                ),
            ],
            reloadRules: [
                .init(
                    sourceLogicalPaths: ["Sources/Patch.swift"],
                    controllerType: controller,
                    policy: .recreate,
                    factoryID: factoryID
                ),
            ],
            factories: [
                .init(id: factoryID, controllerType: controller),
            ]
        )
        return .init(
            directory: directory,
            sourceURL: sourceURL,
            sourceData: sourceData,
            receipt: receipt
        )
    }
}
}
