import Foundation
import HelixBytecode
import HelixCLIKit
import HelixCompiler
import HelixCore
import HelixDevTools
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Real Swift frontend receipt adapter")
struct FrontendReceiptPipeline {
    @Test("Frontend value parsing accepts synchronous escaping closure syntax")
    func parsesClosureTypes() {
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            result: .int64
        )
        #expect(
            FrontendReceipt.ValueTypeParser.parse(
                "(Swift.Int, String) -> Swift.Int",
                allowVoid: false
            ) == Bytecode.ValueType.closure(
                    Bytecode.ClosureSignature(
                        parameters: [.int64, .string],
                        result: .int64
                    )
                )
        )
        #expect(
            FrontendReceipt.ValueTypeParser.parse("() -> Void", allowVoid: false)
                == Bytecode.ValueType.closure(
                    Bytecode.ClosureSignature(parameters: [], result: .void)
                )
        )
        #expect(
            FrontendReceipt.ValueTypeParser.parse(
                "@escaping (Int) -> Int",
                allowVoid: false
            ) == .closure(signature)
        )
        #expect(
            FrontendReceipt.ValueTypeParser.parse(
                "@escaping (Int) async -> Int",
                allowVoid: false
            ) == nil
        )
        #expect(
            FrontendReceipt.ValueTypeParser.parse(
                "@escaping @Sendable (Int) -> Int",
                allowVoid: false
            ) == nil
        )
        #expect(
            FrontendReceipt.ValueTypeParser.parse(
                "(Int) async -> Int",
                allowVoid: false
            ) == nil
        )
        #expect(
            FrontendReceipt.ValueTypeParser.parse(
                "(Int) throws -> Int",
                allowVoid: false
            ) == nil
        )
    }

    @Test("Typed AST and SIL derive both HLBC and Native roots without text discovery")
    func derivesReceiptFromInstalledXcodeToolchain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-frontend-receipt-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent(
            "Sources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = sourceDirectory.appendingPathComponent("Patch.swift")
        let source = """
        // UTF-8 offsets must be measured in bytes, not String characters. 🧪
        func forward(_ transform: @escaping (Int) -> Int) -> (Int) -> Int {
            transform
        }

        public func transform(_ value: Int) -> Int {
            let adjust = { (input: Int) in input + 27 }
            return forward(adjust)(value)
        }

        public func remap(_ values: [String: Int]) -> [String: Int] { values }

        public final class Screen {
            @MainActor public func viewDidLoad(_ value: Int) -> Int { value + 1 }
        }
        """
        try Data(source.utf8).write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "FrontendReceiptFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configurationYAML = """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**/*.swift
        """
        let configuration = try PatchConfiguration.Document.parse(yaml: configurationYAML)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.frontend-receipt",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.frontend-receipt",
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
            sourceBaselineHash: .sha256("computed by the indexer")
        )

        let output = try FrontendReceipt.Adapter().generate(
            .init(
                metadata: metadata,
                configuration: configuration,
                sources: [
                    .init(logicalPath: "Sources/Patch.swift", url: sourceURL),
                ],
                compilerURL: compilerURL
            )
        )
        let receipt = output.receipt
        let forwardingSignature = Bytecode.ClosureSignature(
            parameters: [.int64],
            result: .int64
        )
        #expect(receipt.declarations.count == 4)
        #expect(receipt.roots.count == 4)
        #expect(receipt.roots.compactMap(\.bridge).count == 3)
        #expect(receipt.roots.compactMap(\.nativeReplacement).count == 4)
        #expect(!output.diagnostics.contains { $0.code == "HLXIDX020" })

        let function = try #require(receipt.declarations.first {
            $0.interface.baseName == "transform"
        })
        let forwarding = try #require(receipt.declarations.first {
            $0.interface.baseName == "forward"
        })
        let method = try #require(receipt.declarations.first {
            $0.interface.baseName == "viewDidLoad"
        })
        let dictionary = try #require(receipt.declarations.first {
            $0.interface.baseName == "remap"
        })
        #expect(function.forcedPatchability == nil)
        #expect(function.implementationFingerprint != nil)
        #expect(forwarding.parameterTypes == [.closure(forwardingSignature)])
        #expect(forwarding.resultType == .closure(forwardingSignature))
        #expect(
            dictionary.parameterTypes
                == [.dictionary(key: .string, value: .int64)]
        )
        #expect(dictionary.resultType == .dictionary(key: .string, value: .int64))
        #expect(method.forcedPatchability == nil)
        let screenType = try #require(receipt.nativeTypes.first {
            $0.canonicalName == "\(moduleName).Screen"
        })
        #expect(method.parameterTypes == [.int64, .native(screenType.id)])
        let screenTypeBinding = try #require(receipt.nativeTypeBindings.first {
            $0.canonicalName == screenType.canonicalName
        })
        #expect(screenTypeBinding.generated?.sourceFileLogicalID == "Sources/Patch.swift")
        #expect(screenTypeBinding.generated?.swiftType == "Screen")
        var legacySchema = receipt
        legacySchema.schemaVersion = 6
        #expect(throws: ShellBuildReceipt.Error.self) {
            try legacySchema.validate()
        }
        var forgedTypeSpelling = receipt
        let bindingIndex = try #require(forgedTypeSpelling.nativeTypeBindings.firstIndex {
            $0.canonicalName == screenType.canonicalName
        })
        forgedTypeSpelling.nativeTypeBindings[bindingIndex].generated?.swiftType =
            "\(moduleName).Screen"
        #expect(throws: ShellBuildReceipt.Error.self) {
            try forgedTypeSpelling.validate()
        }
        let methodRoot = try #require(receipt.roots.first {
            $0.declarationMangledName == method.mangledName
        })
        #expect(methodRoot.bridge?.parameterExpressions == ["value", "self"])
        #expect(
            methodRoot.bridge?.parameterSwiftTypes
                == ["Swift.Int", "Screen"]
        )
        #expect(methodRoot.bridge?.enclosingPrefix == "extension Screen {")
        #expect(methodRoot.nominalType?.canonicalName == "Screen")
        #expect(methodRoot.reloadRole == .viewLoadOrInitialization)

        let receiptBytes = try ShellBuildReceipt.Codec.encode(receipt)
        #expect(try ShellBuildReceipt.Codec.decode(receiptBytes) == receipt)
        let shell = try ShellBuild.Materializer().materialize(
            receipt: receipt,
            sourceRoot: directory
        )
        #expect(shell.archive.functions.count == 4)
        #expect(
            shell.archive.functions.first {
                $0.mangledName == forwarding.mangledName
            }?.patchability.reasonCode == "HLXIDX022"
        )
        #expect(shell.archive.capabilities.contains(.escapingClosureValuesV1))
        #expect(
            shell.archive.functions.first { $0.mangledName == function.mangledName }?
                .bodyFingerprint == function.implementationFingerprint
        )
        #expect(shell.archive.bridgeRegistrationCount == 3)
        #expect(shell.reloadIndex.roots.count == 4)
        #expect(shell.reloadIndex.nativeReplacements.count == 4)
        let transformed = String(
            decoding: try #require(shell.transformedSources["Sources/Patch.swift"]),
            as: UTF8.self
        )
        #expect(transformed.contains("public dynamic func transform"))
        #expect(transformed.contains("@MainActor public dynamic func viewDidLoad"))
        try typeCheckNativeReplacements(
            receipt: receipt,
            shell: shell,
            originalSource: Data(source.utf8),
            directory: directory,
            compilerURL: compilerURL,
            sdkPath: sdk.path,
            target: target,
            moduleName: moduleName
        )

        let metadataURL = directory.appendingPathComponent("ReleaseMetadata.json")
        let configurationURL = directory.appendingPathComponent("Helix.yml")
        let cliReceiptURL = directory.appendingPathComponent("CLIReceipt.json")
        try Core.CanonicalJSON.encode(metadata).write(to: metadataURL)
        try Data(configurationYAML.utf8).write(to: configurationURL)
        let cli = CLI.Application(currentDirectoryURL: directory).run([
            "shell", "index",
            "--metadata", metadataURL.path,
            "--configuration", configurationURL.path,
            "--source-map", "Sources/Patch.swift=\(sourceURL.path)",
            "--compiler", compilerURL.path,
            "--output", cliReceiptURL.path,
        ])
        #expect(cli.exitCode == 0)
        #expect(cli.standardError.isEmpty)
        #expect(
            try ShellBuildReceipt.Codec.decode(Data(contentsOf: cliReceiptURL)) == receipt
        )
    }

    @Test("Native indexing preserves advanced Swift declaration semantics")
    func indexesAdvancedDeclarations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-frontend-advanced-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = sourceDirectory.appendingPathComponent("Advanced.swift")
        let source = """
        public enum SampleError: Error { case failed }

        public struct Counter {
            public var value: Int

            public mutating func increment(by amount: Int) { value += amount }
            public borrowing func snapshot() -> Int { value }
            public consuming func consumed() -> Int { value }
            public static func doubled(_ value: Int) -> Int { value * 2 }
        }

        extension Counter {
            public func adding(_ amount: Int) -> Int { value + amount }
        }

        public class Factory {
            public class func doubled(_ value: Int) -> Int { value * 2 }
        }

        public actor Worker {
            public nonisolated func identifier(_ value: Int) -> Int { value }
            public func isolated(_ value: Int) async -> Int { value }
        }

        @globalActor
        public actor FeatureActor {
            public static let shared = FeatureActor()
        }

        @FeatureActor public func actorBound(_ value: Int) async -> Int { value + 2 }
        public func passthrough<T>(_ value: T) -> T { value }
        public func asynchronous(_ value: Int) async -> Int { value + 1 }
        public func escapedAsyncLabel(_ `async`: Int) -> Int { `async` }
        public func defaulted(_ value: Int = 3) -> Int { value }
        public func throwing(_ value: Int) throws -> Int {
            if value < 0 { throw SampleError.failed }
            return value
        }
        public func rethrowing(_ body: () throws -> Int) rethrows -> Int { try body() }
        """
        let sourceData = Data(source.utf8)
        try sourceData.write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "FrontendAdvancedFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**/*.swift
        """)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.frontend-advanced",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.frontend-advanced",
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
            sourceBaselineHash: .sha256("computed by the indexer")
        )
        let output = try FrontendReceipt.Adapter().generate(
            .init(
                metadata: metadata,
                configuration: configuration,
                sources: [
                    .init(logicalPath: "Sources/Advanced.swift", url: sourceURL),
                ],
                compilerURL: compilerURL
            )
        )
        #expect(output.receipt.declarations.count == 15)
        #expect(output.receipt.roots.count == 15)
        #expect(output.receipt.roots.filter { $0.bridge != nil }.count == 4)
        #expect(output.receipt.roots.allSatisfy { $0.nativeReplacement != nil })
        #expect(output.diagnostics.contains { $0.code == "HLXIDX012" })
        #expect(output.diagnostics.contains { $0.code == "HLXIDX007" })
        #expect(output.diagnostics.filter { $0.code == "HLXIDX020" }.count == 8)
        let asynchronous = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "asynchronous"
        })
        #expect(asynchronous.effects.isAsync)
        #expect(asynchronous.forcedPatchability == nil)
        #expect(output.receipt.roots.first {
            $0.declarationMangledName == asynchronous.mangledName
        }?.bridge?.replacementDeclaration.contains(" async ") == true)
        let escapedAsyncLabel = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "escapedAsyncLabel"
        })
        #expect(!escapedAsyncLabel.effects.isAsync)
        #expect(escapedAsyncLabel.forcedPatchability == nil)
        let isolatedActorMethod = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "isolated"
        })
        #expect(isolatedActorMethod.effects.isAsync)
        #expect(isolatedActorMethod.forcedPatchability?.reasonCode == "HLXIDX020")
        let customActorFunction = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "actorBound"
        })
        #expect(customActorFunction.effects.isAsync)
        #expect(customActorFunction.forcedPatchability?.reasonCode == "HLXIDX012")
        #expect(output.receipt.roots.contains {
            $0.nativeReplacement?.replacementDeclaration.contains(
                "@\(moduleName).FeatureActor"
            ) == true
        })
        let classMethod = try #require(output.receipt.roots.first {
            $0.declarationMangledName.contains("FactoryC7doubled")
        })
        #expect(classMethod.nativeReplacement?.replacementDeclaration.hasPrefix("class func ") == true)
        #expect(
            try ShellBuildReceipt.Codec.decode(
                ShellBuildReceipt.Codec.encode(output.receipt)
            ) == output.receipt
        )

        let shell = try ShellBuild.Materializer().materialize(
            receipt: output.receipt,
            sourceRoot: directory
        )
        try typeCheckNativeReplacements(
            receipt: output.receipt,
            shell: shell,
            originalSource: sourceData,
            directory: directory,
            compilerURL: compilerURL,
            sdkPath: sdk.path,
            target: target,
            moduleName: moduleName,
            logicalPath: "Sources/Advanced.swift"
        )
    }

    private func typeCheckNativeReplacements(
        receipt: ShellBuildReceipt.Document,
        shell: ShellBuild.Output,
        originalSource: Data,
        directory: URL,
        compilerURL: URL,
        sdkPath: String,
        target: String,
        moduleName: String,
        logicalPath: String = "Sources/Patch.swift"
    ) throws {
        let output = directory.appendingPathComponent("NativeTypecheck", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let transformedURL = output.appendingPathComponent("Patch.swift")
        try #require(shell.transformedSources[logicalPath]).write(
            to: transformedURL
        )
        let moduleURL = output.appendingPathComponent("\(moduleName).swiftmodule")
        let imageURL = output.appendingPathComponent("lib\(moduleName).dylib")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        try requireFrontendSuccess(
            frontend.run(
                arguments: [
                    transformedURL.path,
                    "-emit-library", "-emit-module", "-parse-as-library",
                    "-module-name", moduleName,
                    "-target", target, "-sdk", sdkPath, "-Onone",
                    "-Xfrontend", "-enable-private-imports",
                    "-emit-module-path", moduleURL.path,
                    "-o", imageURL.path,
                ],
                workingDirectory: output
            )
        )

        let nativeByKey = Dictionary(
            uniqueKeysWithValues: shell.reloadIndex.nativeReplacements.map {
                ($0.functionKey, $0)
            }
        )
        let functionByKey = Dictionary(
            uniqueKeysWithValues: shell.archive.functions.map { ($0.key, $0) }
        )
        let roots = try receipt.roots.compactMap { root -> NativeGeneration.ReplacementRoot? in
            guard let function = shell.archive.functions.first(where: {
                $0.mangledName == root.declarationMangledName
            }), let descriptor = nativeByKey[function.key], functionByKey[function.key] != nil
            else { return nil }
            return .init(
                originalReference: descriptor.originalReference,
                replacementDeclaration: descriptor.replacementDeclaration,
                body: try NativeGeneration.BodyExtractor().extract(
                    from: originalSource,
                    declarationAnchor: descriptor.declarationAnchor,
                    declarationOccurrence: descriptor.declarationOccurrence
                ),
                enclosingPrefix: descriptor.enclosingPrefix,
                enclosingSuffix: descriptor.enclosingSuffix
            )
        }
        let generated = try NativeGeneration.SourceGenerator().generateFiles(
            moduleName: moduleName,
            units: [
                .init(
                    sourceFileLogicalPath: logicalPath,
                    roots: roots
                ),
            ]
        )
        let generatedURLs = try generated.sorted(by: { $0.key < $1.key }).map {
            let url = output.appendingPathComponent($0.key)
            try Data($0.value.utf8).write(to: url)
            return url
        }
        try requireFrontendSuccess(
            frontend.run(
                arguments: generatedURLs.map(\.path) + [
                    "-typecheck", "-parse-as-library",
                    "-module-name", "FrontendReceiptNativeGeneration",
                    "-target", target, "-sdk", sdkPath, "-Onone",
                    "-I", output.path,
                    "-Xfrontend", "-enable-private-imports",
                    "-Xfrontend", "-enable-dynamic-replacement-chaining",
                    "-warnings-as-errors",
                ],
                workingDirectory: output
            )
        )
    }

    private func requireFrontendSuccess(_ result: SwiftFrontend.Output) throws {
        guard result.terminationStatus == 0 else {
            throw FrontendReceipt.Error.frontendFailed(result.standardError)
        }
    }
}
}
