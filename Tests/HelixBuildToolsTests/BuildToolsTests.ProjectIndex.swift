import Foundation
import HelixCLIKit
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Project-wide NativeImport indexing")
struct ProjectIndexTests {
    @Test("One canonical plan indexes every configured module atomically")
    func indexesCompleteProject() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-project-index-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let moduleNames = ["AccountFeature", "CheckoutFeature"]
        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let target = "arm64-apple-ios15.0-simulator"
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.project-index",
            buildNumber: "1",
            seed: "fixture"
        )
        let configurationText = """
        schema: 1
        modules:
          AccountFeature:
            include:
              - Account/Patch/**
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Account/Native/**
                profile: bounded-read-write
                maximumDurationMicroseconds: 400
          CheckoutFeature:
            include:
              - Checkout/Patch/**
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Checkout/Native/**
                profile: bounded-pure
                maximumDurationMicroseconds: 300
        """
        let configuration = try PatchConfiguration.Document.parse(yaml: configurationText)
        let configurationURL = directory.appendingPathComponent("Helix.yml")
        try Data(configurationText.utf8).write(to: configurationURL)

        var requests: [FrontendReceipt.Request] = []
        var planModules: [ProjectIndex.Module] = []
        for (offset, moduleName) in moduleNames.enumerated() {
            let prefix = offset == 0 ? "Account" : "Checkout"
            let patchDirectory = directory.appendingPathComponent("\(prefix)/Patch", isDirectory: true)
            let nativeDirectory = directory.appendingPathComponent("\(prefix)/Native", isDirectory: true)
            try FileManager.default.createDirectory(
                at: patchDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: nativeDirectory,
                withIntermediateDirectories: true
            )
            let patchURL = patchDirectory.appendingPathComponent("Feature.swift")
            let nativeURL = nativeDirectory.appendingPathComponent("Operations.swift")
            try Data(
                "public func transform(_ value: Int) -> Int { adjust(value) }\n".utf8
            ).write(to: patchURL)
            try Data(
                "public func adjust(_ value: Int) -> Int { value + \(offset + 1) }\n".utf8
            ).write(to: nativeURL)
            let metadata = makeMetadata(
                moduleName: moduleName,
                namespace: namespace,
                target: target,
                sdkBuild: sdk.buildVersion
            )
            let metadataName = "\(moduleName).ReleaseMetadata.json"
            try Core.CanonicalJSON.encode(metadata).write(
                to: directory.appendingPathComponent(metadataName)
            )
            let sources: [FrontendReceipt.Source] = [
                .init(
                    logicalPath: "\(prefix)/Native/Operations.swift",
                    url: nativeURL
                ),
                .init(
                    logicalPath: "\(prefix)/Patch/Feature.swift",
                    url: patchURL
                ),
            ]
            requests.append(
                .init(
                    metadata: metadata,
                    configuration: configuration,
                    sources: sources,
                    compilerURL: compilerURL
                )
            )
            planModules.append(
                .init(
                    moduleName: moduleName,
                    metadataPath: metadataName,
                    sources: sources.map {
                        .init(
                            logicalPath: $0.logicalPath,
                            physicalPath: $0.url.path
                        )
                    }
                )
            )
        }

        let output = try FrontendReceipt.ProjectAdapter().generate(
            .init(modules: Array(requests.reversed()))
        )
        #expect(output.report.modules.map(\.moduleName) == moduleNames)
        #expect(output.report.modules.allSatisfy {
            $0.generatedNativeImportCount == 1 && $0.emittedNativeImportCount == 2
        })
        #expect(output.modules.count == 2)
        let accountTransform = try #require(
            output.modules["AccountFeature"]?.receipt.declarations.first {
                $0.interface.baseName == "transform"
            }
        )
        let checkoutTransform = try #require(
            output.modules["CheckoutFeature"]?.receipt.declarations.first {
                $0.interface.baseName == "transform"
            }
        )
        #expect(accountTransform.effects.hasExternalSideEffects)
        #expect(checkoutTransform.effects.hasExternalSideEffects)
        for module in output.report.modules {
            let receipt = try #require(output.modules[module.moduleName]?.receipt)
            #expect(receipt.nativeImportBindings.count == 2)
            #expect(receipt.nativeImportBindings.filter { $0.generated != nil }.count == 1)
            #expect(receipt.nativeImportBindings.contains {
                $0.generated == nil && $0.importedModules == ["HelixRuntime"]
            })
            #expect(
                Core.Digest.sha256(try ShellBuildReceipt.Codec.encode(receipt))
                    == module.receiptHash
            )
        }

        let plan = ProjectIndex.Plan(
            configurationPath: configurationURL.lastPathComponent,
            compilerPath: compilerURL.path,
            modules: planModules
        )
        let planBytes = try ProjectIndex.Codec.encode(plan)
        #expect(try ProjectIndex.Codec.decode(planBytes) == plan)
        var nonCanonical = planBytes
        nonCanonical.append(UInt8(ascii: "\n"))
        #expect(throws: ProjectIndex.Error.nonCanonical) {
            try ProjectIndex.Codec.decode(nonCanonical)
        }
        let planURL = directory.appendingPathComponent("ProjectIndexPlan.json")
        try planBytes.write(to: planURL)
        let outputURL = directory.appendingPathComponent("ProjectIndex", isDirectory: true)
        let cli = CLI.Application(currentDirectoryURL: directory).run([
            "shell", "index-project",
            "--plan", planURL.lastPathComponent,
            "--output", outputURL.lastPathComponent,
        ])
        #expect(cli.exitCode == 0)
        #expect(cli.standardError.isEmpty)
        let reportBytes = try Data(
            contentsOf: outputURL.appendingPathComponent("ProjectIndexReport.json")
        )
        let report = try JSONDecoder().decode(
            FrontendReceipt.ProjectReport.self,
            from: reportBytes
        )
        try report.validate()
        #expect(try Core.CanonicalJSON.encode(report) == reportBytes)
        #expect(report == output.report)
        for module in report.modules {
            let receiptBytes = try Data(
                contentsOf: outputURL.appendingPathComponent(module.receiptPath)
            )
            #expect(Core.Digest.sha256(receiptBytes) == module.receiptHash)
            #expect(
                FileManager.default.fileExists(
                    atPath: outputURL.appendingPathComponent(module.diagnosticsPath).path
                )
            )
        }

        var traversingReport = report
        traversingReport.modules[0].moduleName = "../Escape"
        traversingReport.modules[0].receiptPath =
            "Receipts/../Escape.ShellBuildReceipt.json"
        traversingReport.modules[0].diagnosticsPath = "Diagnostics/../Escape.json"
        #expect(throws: FrontendReceipt.Error.self) {
            try traversingReport.validate()
        }

        var impossibleCounts = report
        impossibleCounts.modules[0].generatedNativeImportCount = 2
        impossibleCounts.modules[0].emittedNativeImportCount = 1
        #expect(throws: FrontendReceipt.Error.self) {
            try impossibleCounts.validate()
        }

        let unsafeOutputURL = directory.appendingPathComponent(
            "UnsafeProjectIndex",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unsafeOutputURL,
            withIntermediateDirectories: false
        )
        let unsafePlan = ProjectIndex.Plan(
            configurationPath: "../\(configurationURL.lastPathComponent)",
            compilerPath: compilerURL.path,
            modules: planModules.map { module in
                .init(
                    moduleName: module.moduleName,
                    metadataPath: "../\(module.metadataPath)",
                    sources: module.sources
                )
            }
        )
        let unsafePlanURL = unsafeOutputURL.appendingPathComponent("ProjectIndexPlan.json")
        try ProjectIndex.Codec.encode(unsafePlan).write(to: unsafePlanURL)
        let unsafeCLI = CLI.Application(currentDirectoryURL: directory).run([
            "shell", "index-project",
            "--plan", unsafePlanURL.path,
            "--output", unsafeOutputURL.path,
            "--force",
        ])
        #expect(unsafeCLI.exitCode != 0)
        #expect(
            unsafeCLI.standardError.contains(
                "project output directory must not contain or replace any plan input"
            )
        )
        #expect(FileManager.default.fileExists(atPath: unsafePlanURL.path))
    }

    @Test("Project adapter rejects partial and cross-build module sets")
    func rejectsInconsistentProjects() throws {
        let configuration = PatchConfiguration.Document(
            schema: 1,
            modules: [
                "First": .init(include: ["First/**"]),
                "Second": .init(include: ["Second/**"]),
            ]
        )
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.project-negative",
            buildNumber: "1",
            seed: "fixture"
        )
        let metadata = makeMetadata(
            moduleName: "First",
            namespace: namespace,
            target: "arm64-apple-ios15.0-simulator",
            sdkBuild: "test"
        )
        let request = FrontendReceipt.Request(
            metadata: metadata,
            configuration: configuration,
            sources: [
                .init(
                    logicalPath: "First/Feature.swift",
                    url: URL(fileURLWithPath: "/tmp/First.swift")
                ),
            ]
        )

        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.ProjectAdapter().generate(.init(modules: [request]))
        }
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.ProjectAdapter().generate(
                .init(modules: [request, request])
            )
        }

        var secondMetadata = makeMetadata(
            moduleName: "Second",
            namespace: namespace,
            target: "arm64-apple-ios15.0-simulator",
            sdkBuild: "test"
        )
        secondMetadata.buildNumber = "2"
        let secondRequest = FrontendReceipt.Request(
            metadata: secondMetadata,
            configuration: configuration,
            sources: [
                .init(
                    logicalPath: "Second/Feature.swift",
                    url: URL(fileURLWithPath: "/tmp/Second.swift")
                ),
            ]
        )
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.ProjectAdapter().generate(
                .init(modules: [request, secondRequest])
            )
        }
    }

    private func makeMetadata(
        moduleName: String,
        namespace: Core.ShellNamespaceID,
        target: String,
        sdkBuild: String
    ) -> InterfaceArchive.ReleaseMetadata {
        .init(
            bundleID: "dev.helix.project-index",
            buildNumber: "1",
            shellNamespaceID: namespace,
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "integration-test",
            sdkBuild: sdkBuild,
            frontendInvocation: .init(
                moduleName: moduleName,
                targetTriple: target,
                sdkName: "iphonesimulator",
                sdkBuild: sdkBuild,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by indexer")
        )
    }
}
}
