import Foundation
import HelixBytecode
import HelixCLIKit
import HelixCompiler
import HelixCore
import HelixDevTools
import HelixInterface
import HelixVerifier
import HelixVM
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Real Swift frontend receipt adapter")
struct FrontendReceiptPipeline {
    @Test("An unchanged module reuses its receipt and ignores unrelated modules")
    func reusesCachedModuleReceipt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-cached-frontend-receipt-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources")
        let cacheDirectory = directory.appendingPathComponent("Cache")
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = sourceDirectory.appendingPathComponent("Feature.swift")
        try Data("public func increment(_ value: Int) -> Int { value + 1 }\n".utf8)
            .write(to: sourceURL)
        let unrelatedModule = sourceDirectory.appendingPathComponent(
            "UnrelatedFixture.swiftmodule"
        )
        try Data("unrelated-interface-v1".utf8).write(to: unrelatedModule)
        let compilerArguments = ["-I", sourceDirectory.path]

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
            compilerURL: compilerURL
        )
        let moduleName = "CachedFrontendFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**
        """)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.cached-frontend",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.cached-frontend",
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
        let request = FrontendReceipt.Request(
            metadata: metadata,
            configuration: configuration,
            sources: [
                .init(logicalPath: "Sources/Feature.swift", url: sourceURL),
            ],
            compilerURL: compilerURL
        )
        let cached = FrontendReceipt.CachedAdapter(
            cache: try BuildCache.Store(rootURL: cacheDirectory)
        )

        let first = try cached.generate(
            request,
            compilerCapture: Data("capture".utf8),
            compilerArguments: compilerArguments,
            precomputedToolchain: toolchain
        )
        let second = try cached.generate(
            request,
            compilerCapture: Data("capture".utf8),
            compilerArguments: compilerArguments,
            precomputedToolchain: toolchain
        )
        let changedCapture = try cached.generate(
            request,
            compilerCapture: Data("changed-capture".utf8),
            compilerArguments: compilerArguments,
            precomputedToolchain: toolchain
        )
        try Data("unrelated-interface-v2".utf8).write(to: unrelatedModule)
        let changedUnrelatedModule = try cached.generate(
            request,
            compilerCapture: Data("changed-capture".utf8),
            compilerArguments: compilerArguments,
            precomputedToolchain: toolchain
        )

        #expect(second.receipt == first.receipt)
        #expect(second.diagnostics == first.diagnostics)
        #expect(second.toolchain == first.toolchain)
        #expect(first.performance.counters.first {
            $0.name == "frontend_cache.module_miss_count"
        }?.value == 1)
        #expect(second.performance.counters.first {
            $0.name == "frontend_cache.module_hit_count"
        }?.value == 1)
        #expect(second.performance.subprocesses.isEmpty)
        #expect(changedCapture.receipt == first.receipt)
        #expect(changedCapture.performance.counters.first {
            $0.name == "frontend_cache.module_miss_count"
        }?.value == 1)
        #expect(!changedCapture.performance.subprocesses.isEmpty)
        #expect(changedUnrelatedModule.receipt == first.receipt)
        #expect(changedUnrelatedModule.performance.counters.first {
            $0.name == "frontend_cache.module_hit_count"
        }?.value == 1)
        #expect(changedUnrelatedModule.performance.subprocesses.isEmpty)

        let initialSources = [ShellBuildReceipt.Source(
            logicalPath: "Sources/Feature.swift",
            contentHash: .sha256(
                "public func increment(_ value: Int) -> Int { value + 1 }\n"
            )
        )]
        try Data("""
        import Foundation
        public func increment(_ value: Int) -> Int { value + 2 }

        """.utf8).write(to: sourceURL)
        #expect(throws: FrontendReceipt.SourceImports.ValidationError.sourceChanged) {
            _ = try FrontendReceipt.Adapter().generate(
                request,
                cache: nil,
                toolchain: toolchain,
                compilerInputHash: nil,
                expectedSources: initialSources
            )
        }
        #expect(
            throws: FrontendReceipt.SourceImports.ValidationError
                .compilerImportMismatch
        ) {
            _ = try FrontendReceipt.Adapter().generate(
                request,
                cache: nil,
                toolchain: toolchain,
                compilerInputHash: nil,
                expectedImports: .init(modules: [], isComplete: true)
            )
        }
    }

    @Test("Typed AST accepts empty source documents but rejects malformed items")
    func acceptsEmptyTypedASTDocuments() throws {
        #expect(try FrontendReceipt.TypedAST.items(in: ["filename": "/tmp/Empty.swift"])
            .isEmpty)
        #expect(throws: FrontendReceipt.Error.self) {
            _ = try FrontendReceipt.TypedAST.items(in: [
                "filename": "/tmp/Malformed.swift",
                "items": ["not": "an array"],
            ])
        }
    }

    @Test("Source locations use UTF-8 columns and all Swift line endings")
    func mapsExactUTF8SourceLocations() throws {
        let source = Data("é{\r\n  #column\rnext".utf8)
        let locations = SourceTransform.LocationMap(source)
        let brace = try #require(source.range(of: Data("{".utf8)))
        let column = try #require(source.range(of: Data("#column".utf8)))
        let next = try #require(source.range(of: Data("next".utf8)))

        #expect(locations.location(atUTF8Offset: brace.lowerBound)?.line == 1)
        #expect(locations.location(atUTF8Offset: brace.lowerBound)?.column == 3)
        #expect(locations.location(atUTF8Offset: column.lowerBound)?.line == 2)
        #expect(locations.location(atUTF8Offset: column.lowerBound)?.column == 3)
        #expect(locations.location(atUTF8Offset: next.lowerBound)?.line == 3)
        #expect(locations.location(atUTF8Offset: next.lowerBound)?.column == 1)
        #expect(locations.location(atUTF8Offset: source.count + 1) == nil)
        #expect(locations.utf8Offset(line: 1, column: 3) == brace.lowerBound)
        #expect(locations.utf8Offset(line: 2, column: 3) == column.lowerBound)
        #expect(locations.utf8Offset(line: 3, column: 1) == next.lowerBound)
        #expect(locations.utf8Offset(line: 0, column: 1) == nil)
        #expect(locations.utf8Offset(line: 2, column: 100) == nil)

        let prefixed = Data("xxé{\rnext".utf8)
        let slice = prefixed[prefixed.index(prefixed.startIndex, offsetBy: 2)...]
        let slicedLocations = SourceTransform.LocationMap(slice)
        #expect(slicedLocations.location(atUTF8Offset: 0)?.line == 1)
        #expect(slicedLocations.location(atUTF8Offset: 2)?.column == 3)
        #expect(slicedLocations.location(atUTF8Offset: 4)?.line == 2)
        #expect(slicedLocations.location(atUTF8Offset: 4)?.column == 1)
    }

    @Test("SIL resolver falls back to an exact source declaration location")
    func resolvesOverlayMangledFunctionByLocation() throws {
        let physical = "$s7Fixture5probeyyF"
        let fixture = try silResolverFixture(symbols: [physical])

        let resolved = try fixture.resolver.function(
            for: fixture.item,
            source: fixture.source,
            baseName: "probe"
        )
        #expect(resolved?.mangledName == physical)
        #expect(resolved?.declarationLocation?.line == 1)
        #expect(resolved?.declarationLocation?.column == 13)
    }

    @Test("SIL resolver rejects ambiguous source declaration locations")
    func rejectsAmbiguousOverlayMangledFunctionLocation() throws {
        let fixture = try silResolverFixture(symbols: [
            "$s7Fixture5probeAyyF",
            "$s7Fixture5probeByyF",
        ])

        #expect(throws: FrontendReceipt.Error.self) {
            _ = try fixture.resolver.function(
                for: fixture.item,
                source: fixture.source,
                baseName: "probe"
            )
        }
    }

    @Test("SIL resolver rejects a same-line declaration at another column")
    func rejectsInexactOverlayMangledFunctionLocation() throws {
        let fixture = try silResolverFixture(
            symbols: ["$s7Fixture5probeyyF"],
            declarationColumn: 14
        )

        let resolved = try fixture.resolver.function(
            for: fixture.item,
            source: fixture.source,
            baseName: "probe"
        )
        #expect(resolved == nil)
    }

    @Test("Frontend value parsing accepts synchronous escaping closure syntax")
    func parsesClosureTypes() {
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        #expect(
            FrontendReceipt.ValueTypeParser.parse(
                "(Swift.Int, String) -> Swift.Int",
                allowVoid: false
            ) == Bytecode.ValueType.closure(
                    Bytecode.ClosureSignature(
                        parameters: [.int64, .string],
                        parameterConventions: [.owned, .owned],
                        result: .int64
                    )
                )
        )
        #expect(
            FrontendReceipt.ValueTypeParser.parse("() -> Void", allowVoid: false)
                == Bytecode.ValueType.closure(
                    Bytecode.ClosureSignature(
                        parameters: [],
                        parameterConventions: [],
                        result: .void
                    )
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
            ) == .closure(signature)
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
        #expect(
            FrontendReceipt.ValueTypeParser.parse(
                "Swift.Set<Swift.Optional<Swift.Int>>",
                allowVoid: false
            ) == .set(.optional(.int64))
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

        public dynamic func remap(_ values: [String: Int]) -> [String: Int] { values }

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
            parameterConventions: [.owned],
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
        #expect(methodRoot.sourceDeclaration.enclosingPrefix == "extension Screen {")
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
        #expect(transformed.contains("public dynamic func remap"))
        #expect(!transformed.contains("dynamic dynamic func remap"))
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
            public var samples: [Int] = []

            public mutating func incrementOrReject(
                by amount: Int,
                reject: Bool
            ) throws {
                samples.append(amount)
                value += samples.count
                if reject { throw CounterError.rejected }
            }
            public mutating func incrementThenDivide(
                by amount: Int,
                divisor: Int
            ) -> Int {
                value += amount
                return value / divisor
            }
            public borrowing func snapshot() -> Int { value }
            public consuming func consumed() -> Int { value }
            public static func doubled(_ value: Int) -> Int { value * 2 }
        }

        public enum CounterError: Error { case rejected }

        public enum Phase {
            case idle
            case count(Int)

            public mutating func advance(by amount: Int) {
                self = .count(amount)
            }
        }

        extension Counter {
            public func adding(_ amount: Int) -> Int { value + amount }
            public mutating func increment(by amount: Int) { value += amount }
        }

        public class Factory {
            public class func doubled(_ value: Int) -> Int { value * 2 }
        }

        public actor Worker {
            public nonisolated func identifier(_ value: Int) -> Int { value }
            public func isolated(_ value: Int) async -> Int { value }
            public static func staticValue(_ value: Int) async -> Int { value }
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
        public func adjust(_ value: inout Int, by amount: Int) {
            value += amount
        }
        public func exchange(_ lhs: inout Int, _ rhs: inout Int) {
            let temporary = lhs
            lhs = rhs
            rhs = temporary
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
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Sources/**/*.swift
                declarations:
                  - \(moduleName).Worker.*
                visibility: public
                profile: pure
                maximumBoundedDurationMicroseconds: 500
                maximumSuspendingDurationMicroseconds: 5000000
                allowsMainThread: true
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
        #expect(output.receipt.declarations.count == 21)
        #expect(output.receipt.roots.count == 17)
        #expect(output.receipt.roots.filter { $0.bridge != nil }.count == 12)
        #expect(output.receipt.roots.filter {
            $0.nativeReplacement != nil
        }.count == 16)
        #expect(output.diagnostics.contains { $0.code == "HLXIDX012" })
        #expect(output.diagnostics.contains { $0.code == "HLXIDX007" })
        #expect(output.diagnostics.filter { $0.code == "HLXIDX020" }.count == 5)
        #expect(output.diagnostics.filter { $0.code == "HLXIDX006" }.count == 1)
        let snapshot = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "snapshot"
        })
        let consumed = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "consumed"
        })
        #expect(snapshot.parameterTypes.last == .local(.init(rawValue: "Counter")))
        #expect(snapshot.parameterConventions.last == .owned)
        #expect(consumed.parameterConventions.last == .owned)
        let snapshotRoot = output.receipt.roots.first {
            $0.declarationMangledName == snapshot.mangledName
        }
        #expect(snapshotRoot?.bridge != nil)
        #expect(snapshotRoot?.sourceDeclaration.replacementHeader.contains(
            "borrowing func"
        ) == true)
        #expect(output.receipt.roots.first {
            $0.declarationMangledName == consumed.mangledName
        }?.sourceDeclaration.replacementHeader.contains("consuming func") == true)
        let increment = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "increment"
        })
        #expect(output.receipt.roots.first {
            $0.declarationMangledName == increment.mangledName
        }?.bridge != nil)
        #expect(increment.parameterConventions == [.owned, .inout])
        let adjust = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "adjust"
        })
        #expect(adjust.parameterConventions == [.inout, .owned])
        let adjustBridge = try #require(output.receipt.roots.first {
            $0.declarationMangledName == adjust.mangledName
        }?.bridge)
        #expect(adjustBridge.originalInvocation == "adjust(&value, by: amount)")
        #expect(try #require(adjustBridge.bridgeInvocation).hasSuffix(
            "_adjust(&argument0, by: argument1)"
        ))
        let exchange = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "exchange"
        })
        #expect(exchange.parameterConventions == [.inout, .inout])
        #expect(output.receipt.roots.first {
            $0.declarationMangledName == exchange.mangledName
        }?.bridge == nil)
        let asynchronous = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "asynchronous"
        })
        #expect(asynchronous.effects.isAsync)
        #expect(asynchronous.forcedPatchability == nil)
        #expect(output.receipt.roots.first {
            $0.declarationMangledName == asynchronous.mangledName
        }?.sourceDeclaration.replacementHeader.contains(" async ") == true)
        let asynchronousRoot = try #require(output.receipt.roots.first {
            $0.declarationMangledName == asynchronous.mangledName
        })
        #expect(
            asynchronousRoot.sourceBodyTransform?.kind
                == .asynchronousFunction
        )
        #expect(asynchronousRoot.nativeReplacement == nil)
        #expect(asynchronousRoot.declarationInsertion == nil)
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
        let staticActorMethod = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "staticValue"
        })
        #expect(staticActorMethod.effects.isAsync)
        #expect(staticActorMethod.forcedPatchability?.reasonCode == "HLXIDX020")
        #expect(!staticActorMethod.hasCompleteDynamicCoverage)
        #expect(!output.receipt.roots.contains {
            $0.declarationMangledName == staticActorMethod.mangledName
        })
        #expect(!output.receipt.nativeImportCandidates.contains {
            $0.canonicalCallee.contains(".Worker.")
        })
        #expect(output.diagnostics.contains {
            $0.message.contains("custom calling or isolation attributes")
        })
        let customActorFunction = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "actorBound"
        })
        #expect(customActorFunction.effects.isAsync)
        #expect(customActorFunction.forcedPatchability?.reasonCode == "HLXIDX012")
        #expect(!output.receipt.roots.contains {
            $0.declarationMangledName == customActorFunction.mangledName
        })
        let classMethod = try #require(output.receipt.roots.first {
            $0.declarationMangledName.contains("FactoryC7doubled")
        })
        #expect(classMethod.sourceDeclaration.replacementHeader.hasPrefix("class func "))
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
        try typeCheckGeneratedBridge(
            shell: shell,
            directory: directory,
            moduleName: moduleName
        )

        let patchedSource = source
            .replacingOccurrences(
                of: "value += amount }",
                with: "value += amount + 10 }"
            )
            .replacingOccurrences(
                of: "value += samples.count",
                with: "value += samples.count + 10"
            )
            .replacingOccurrences(
                of: "return value / divisor",
                with: "return (value + 10) / divisor"
            )
            .replacingOccurrences(
                of: "self = .count(amount)",
                with: "self = .count(amount + 10)"
            )
            .replacingOccurrences(
                of: "value += amount\n}\npublic func exchange",
                with: "value += amount + 10\n}\npublic func exchange"
            )
        #expect(patchedSource != source)
        try Data(patchedSource.utf8).write(to: sourceURL)
        let selectedNames: Set<String> = [
            "increment", "incrementOrReject", "incrementThenDivide", "advance",
            "adjust",
        ]
        let selectedKeys = Set(shell.archive.functions.compactMap { record in
            selectedNames.contains(
                output.receipt.declarations.first {
                    $0.mangledName == record.mangledName
                }?.interface.baseName ?? ""
            ) ? record.key : nil
        })
        #expect(selectedKeys.count == 5)
        let patch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [sourceURL],
                selectedFunctionKeys: selectedKeys,
                compilerURL: compilerURL,
                enforceToolchainFingerprint: false
            )
        )
        let image = try Verification.Engine().verify(
            bytes: patch.bytecode,
            shell: Verification.ShellInterface(archive: shell.archive),
            policy: .init(
                acceptedCapabilities: Set(shell.archive.capabilities)
            )
        )
        func integer(_ value: Int64) throws -> VM.Value {
            .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
        }
        func entry(named name: String) throws -> Core.EntryIndex {
            let declaration = try #require(output.receipt.declarations.first {
                $0.interface.baseName == name
            })
            return try #require(shell.archive.functions.first {
                $0.mangledName == declaration.mangledName
            }?.entryIndex)
        }

        let counter = VM.Value.structure(
            type: .init(rawValue: "Counter"),
            fields: [
                try integer(3),
                .array(.init(elements: [try integer(5)], elementType: .int64)),
            ]
        )
        let incremented = VM.Interpreter().invokeEntry(
            entry: try entry(named: "increment"),
            image: image,
            arguments: [try integer(2), counter]
        )
        #expect(incremented.outcome == .returned(nil))
        #expect(incremented.writebacks == [
            .init(
                parameterIndex: 1,
                value: .structure(
                    type: .init(rawValue: "Counter"),
                    fields: [
                        try integer(15),
                        .array(.init(
                            elements: [try integer(5)],
                            elementType: .int64
                        )),
                    ]
                )
            ),
        ])

        let rejected = VM.Interpreter().invokeEntry(
            entry: try entry(named: "incrementOrReject"),
            image: image,
            arguments: [try integer(7), .bool(true), counter]
        )
        guard case .businessError = rejected.outcome else {
            Issue.record("throwing mutating root did not preserve its business error")
            return
        }
        #expect(rejected.writebacks == [
            .init(
                parameterIndex: 2,
                value: .structure(
                    type: .init(rawValue: "Counter"),
                    fields: [
                        try integer(15),
                        .array(.init(
                            elements: [try integer(5), try integer(7)],
                            elementType: .int64
                        )),
                    ]
                )
            ),
        ])

        let completed = VM.Interpreter().invokeEntry(
            entry: try entry(named: "incrementThenDivide"),
            image: image,
            arguments: [try integer(7), try integer(2), counter]
        )
        #expect(completed.outcome == .returned(try integer(10)))
        #expect(completed.writebacks == [
            .init(
                parameterIndex: 2,
                value: .structure(
                    type: .init(rawValue: "Counter"),
                    fields: [
                        try integer(10),
                        .array(.init(
                            elements: [try integer(5)],
                            elementType: .int64
                        )),
                    ]
                )
            ),
        ])

        let trapped = VM.Interpreter().invokeEntry(
            entry: try entry(named: "incrementThenDivide"),
            image: image,
            arguments: [try integer(7), try integer(0), counter]
        )
        #expect(trapped.outcome == .trapped(.divisionByZero))
        #expect(trapped.writebacks.isEmpty)

        let advanced = VM.Interpreter().invokeEntry(
            entry: try entry(named: "advance"),
            image: image,
            arguments: [
                try integer(2),
                .enumeration(
                    type: .init(rawValue: "Phase"),
                    caseIndex: 0,
                    payload: nil
                ),
            ]
        )
        #expect(advanced.outcome == .returned(nil))
        #expect(advanced.writebacks == [
            .init(
                parameterIndex: 1,
                value: .enumeration(
                    type: .init(rawValue: "Phase"),
                    caseIndex: 1,
                    payload: try integer(12)
                )
            ),
        ])

        let adjusted = VM.Interpreter().invokeEntry(
            entry: try entry(named: "adjust"),
            image: image,
            arguments: [try integer(3), try integer(2)]
        )
        #expect(adjusted.outcome == .returned(nil))
        #expect(adjusted.writebacks == [
            .init(parameterIndex: 0, value: try integer(15)),
        ])
    }

    @Test("Async source-body bridges preserve lexical class context")
    func asyncSourceBodyBridgesPreserveLexicalClassContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-frontend-async-lexical-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = sourceDirectory.appendingPathComponent("Lexical.swift")
        let source = #"""
        open class Parent {
            open func describe(_ value: Int) async -> String { defer { _ = #function }; let closure = { #function }; func local() -> String { #function }; return "parent:\(value):\(#function):\(closure()):\(local()):\(#line):\(#column):\(#fileID):\(#filePath)" }
        }

        public final class Child: Parent {
            private let suffix = "child"

            public override func describe(_ value: Int) async -> String {
                let inherited = await super.describe(value)
                return "\(inherited):\(suffix):\(#function)"
            }
        }

        @MainActor
        public final class MainActorModel {
            public func calculate(_ value: Int) async -> Int {
                value + 3
            }

            nonisolated public func calculateAnywhere(_ value: Int) async -> Int {
                value + 4
            }
        }

        public enum PrivateContainer {
            private final class Hidden {
                func hiddenDescription(_ value: Int) async -> String {
                    "hidden:\(value)"
                }
            }
        }

        @available(iOS 99, *)
        public func futureDescription(_ value: Int) async -> String {
            "future:\(value)"
        }

        @available(iOS 99, *)
        extension Parent {
            public func futureExtensionDescription(_ value: Int) async -> String {
                "future-extension:\(value)"
            }
        }
        """# + """

        public func oversizedDescription(_ value: Int) async -> Int {
            /*\(String(repeating: "x", count: 66 * 1_024))*/
            return value
        }
        """
        try Data(source.utf8).write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let sdk = try SwiftFrontend.Driver(compilerURL: compilerURL).sdkIdentity(
            name: "iphonesimulator"
        )
        let moduleName = "FrontendAsyncLexicalFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**/*.swift
            entrypoints: all
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Sources/**/*.swift
                declarations:
                  - "*future*"
                visibility: public
                profile: pure
        """)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.frontend-async-lexical",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.frontend-async-lexical",
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
        let adapterOutput = try FrontendReceipt.Adapter().generate(
            .init(
                metadata: metadata,
                configuration: configuration,
                sources: [
                    .init(logicalPath: "Sources/Lexical.swift", url: sourceURL),
                ],
                compilerURL: compilerURL
            )
        )
        let receipt = adapterOutput.receipt
        let asyncRoots = receipt.roots.filter {
            $0.sourceBodyTransform?.kind == .asynchronousFunction
        }
        #expect(asyncRoots.count == 3)
        let inheritedMainActor = try #require(receipt.declarations.first {
            $0.interface.baseName == "calculate"
        })
        #expect(inheritedMainActor.effects.isAsync)
        #expect(inheritedMainActor.effects.requiresMainActor)
        #expect(inheritedMainActor.loweredSignature.isolation == "MainActor")
        #expect(receipt.roots.contains {
            $0.declarationMangledName == inheritedMainActor.mangledName
        })
        let inheritedNonisolated = try #require(receipt.declarations.first {
            $0.interface.baseName == "calculateAnywhere"
        })
        #expect(inheritedNonisolated.effects.isAsync)
        #expect(!inheritedNonisolated.effects.requiresMainActor)
        #expect(inheritedNonisolated.loweredSignature.isolation == nil)
        #expect(!receipt.roots.contains {
            $0.declarationMangledName == inheritedNonisolated.mangledName
        })
        #expect(adapterOutput.diagnostics.contains {
            $0.code == "HLXIDX021"
                && $0.message.contains("calculateAnywhere")
        })
        let future = try #require(receipt.declarations.first {
            $0.interface.baseName == "futureDescription"
        })
        #expect(!future.hasCompleteDynamicCoverage)
        #expect(!receipt.roots.contains {
            $0.declarationMangledName == future.mangledName
        })
        let futureExtension = try #require(receipt.declarations.first {
            $0.interface.baseName == "futureExtensionDescription"
        })
        #expect(!futureExtension.hasCompleteDynamicCoverage)
        #expect(!receipt.roots.contains {
            $0.declarationMangledName == futureExtension.mangledName
        })
        let oversized = try #require(receipt.declarations.first {
            $0.interface.baseName == "oversizedDescription"
        })
        #expect(!oversized.hasCompleteDynamicCoverage)
        #expect(!receipt.roots.contains {
            $0.declarationMangledName == oversized.mangledName
        })
        let hidden = try #require(receipt.declarations.first {
            $0.interface.baseName == "hiddenDescription"
        })
        #expect(hidden.forcedPatchability?.reasonCode == "HLXIDX020")
        #expect(!receipt.roots.contains {
            $0.declarationMangledName == hidden.mangledName
        })
        #expect(adapterOutput.diagnostics.contains {
            $0.code == "HLXIDX020"
                && $0.message.contains("private nested receiver")
        })
        #expect(adapterOutput.diagnostics.contains {
            $0.code == "HLXIDX010"
                && $0.message.contains("oversizedDescription")
                && $0.message.contains("metadata limits")
        })
        #expect(!receipt.nativeImportCandidates.contains {
            $0.canonicalCallee.lowercased().contains("future")
        })
        #expect(adapterOutput.diagnostics.filter {
            $0.code == "HLXNID004"
                && $0.message.lowercased().contains("future")
        }.count == 2)
        #expect(asyncRoots.allSatisfy {
            $0.declarationInsertion == nil && $0.nativeReplacement == nil
        })

        let shell = try ShellBuild.Materializer().materialize(
            receipt: receipt,
            sourceRoot: directory
        )
        let transformed = String(
            decoding: try #require(shell.transformedSources["Sources/Lexical.swift"]),
            as: UTF8.self
        )
        #expect(
            transformed.components(
                separatedBy: "Runtime.Bridge.shared.prepareAsyncDispatch"
            ).count == 4
        )
        #expect(transformed.contains("await super.describe(value)"))
        #expect(transformed.contains(#"\(inherited):\(suffix):\(#function)"#))
        try typeCheckGeneratedBridge(
            shell: shell,
            directory: directory,
            moduleName: moduleName
        )

        let parentRoot = try #require(asyncRoots.first {
            $0.nominalType?.canonicalName == "Parent"
        })
        let childRoot = try #require(asyncRoots.first {
            $0.nominalType?.canonicalName == "Child"
        })
        let parentInvocation = try #require(parentRoot.bridge?.bridgeInvocation)
        let childInvocation = try #require(childRoot.bridge?.bridgeInvocation)
        let thunks = try asyncRoots.map {
            try #require($0.bridge?.sourceSupplementalDeclaration)
        }.joined(separator: "\n\n")
        #expect(parentInvocation.contains("helixReload_"))
        #expect(!parentInvocation.contains(".describe("))
        #expect(thunks.contains(#""describe(_:)""#))
        #expect(thunks.contains(#"defer { _ = "describe(_:)" }"#))
        #expect(thunks.components(separatedBy:
            #"#sourceLocation(file: "Sources/Lexical.swift", line: 1)"#
        ).count == 4)
        #expect(shell.bridge.sourceFiles.values.contains {
            $0.contains("invokeMainActorAsync: { arguments in")
        })

        let executableSourceURL = directory.appendingPathComponent("AsyncThunkProbe.swift")
        let executableURL = directory.appendingPathComponent("AsyncThunkProbe")
        let executableSource = """
        #sourceLocation(file: "Sources/Lexical.swift", line: 1)
        """ + "\n" + source + "\n\n" + thunks + """

        #sourceLocation()

        @main
        enum AsyncThunkProbe {
            static func main() async {
                let child = Child()
                let parent: Parent = child
                let baseline = await Parent().describe(7)
                let virtual = await parent.describe(7)
                guard virtual == baseline + ":child:describe(_:)",
                      await {
                          let argument0 = 7
                          let argument1: Parent = child
                          return await \(parentInvocation)
                      }() == baseline,
                      await {
                          let argument0 = 7
                          let argument1: Child = child
                          return await \(childInvocation)
                      }() == virtual
                else {
                    fatalError("async exact-original thunk dispatched virtually")
                }
                print("HELIX_ASYNC_EXACT_ORIGINAL_OK")
            }
        }
        """
        try Data(executableSource.utf8).write(to: executableSourceURL)
        try requireFrontendSuccess(
            SwiftFrontend.Driver().run(
                arguments: [
                    executableSourceURL.path,
                    "-parse-as-library", "-warnings-as-errors",
                    "-o", executableURL.path,
                ],
                workingDirectory: directory
            )
        )
        let execution = try SwiftFrontend.Driver(compilerURL: executableURL).run(
            arguments: [],
            workingDirectory: directory
        )
        try requireFrontendSuccess(execution)
        #expect(execution.standardOutput.contains("HELIX_ASYNC_EXACT_ORIGINAL_OK"))
    }

    @Test("Frozen Shell struct and enum receivers use generated structural codecs")
    func bridgesFrozenValueReceivers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-frozen-value-receivers-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let modelsURL = sourceDirectory.appendingPathComponent("Models.swift")
        let extensionsURL = sourceDirectory.appendingPathComponent("Extensions.swift")
        let models = """
        public enum Values {
        public protocol Flag {}

        public enum CheckError: Error {
            case rejected

            public func errorCode() -> Int { 7 }
        }

        public enum FutureMode {
            @available(iOS 99, *)
            case future
            case current

            public func stableCode() -> Int { 1 }
        }

        @available(iOS 99, *)
        public struct FutureRecord {
            public func stableCode() -> Int { 1 }
        }

        public struct Marker {
            public init() {}
            public func echoed() -> Marker { self }
        }

        public struct Pinned {
            private let token: Int = 7

            public func value() -> Int { token }
        }

        public struct ExistentialBox {
            private let value: any Flag

            public func hasValue() -> Bool {
                _ = value
                return true
            }
        }

        public final class Owner {
            public init() {}
        }

        public struct WeakBox {
            private weak var owner: Owner?

            public init(owner: Owner?) {
                self.owner = owner
            }

            public func hasOwner() -> Bool { owner != nil }
        }

        public struct PrivateStorage {
            private struct Secret {
                let value: Int
            }

            private let secret: Secret

            public init(value: Int) {
                secret = Secret(value: value)
            }

            public func value() -> Int { secret.value }
        }

        public struct Metadata {
            private let enabled: Bool

            public init(enabled: Bool) { self.enabled = enabled }
            public func isEnabled() -> Bool { enabled }
        }

        public typealias StoredMode = Mode

        public struct Snapshot {
            private let metadata: Metadata
            private let samples: [Int]
            private let title: String?
            private let enabled: Bool
            private let origin: (x: Int, y: String)
            private let lookup: [String: Int]
            private let flags: Set<String>
            private var retries: Int = 0

            public init(
                metadata: Metadata,
                samples: [Int],
                title: String?,
                enabled: Bool,
                origin: (x: Int, y: String),
                lookup: [String: Int],
                flags: Set<String>
            ) {
                self.metadata = metadata
                self.samples = samples
                self.title = title
                self.enabled = enabled
                self.origin = origin
                self.lookup = lookup
                self.flags = flags
            }

            public func score(_ delta: Int) -> Int {
                samples.count + retries + delta + (enabled ? 1 : 0)
            }

            public func echoed() -> Self { self }

            public borrowing func replacing(with other: Self) -> Self { other }

            public func preservingAlias(_ mode: StoredMode) -> StoredMode {
                mode
            }

            public func checked(_ accepted: Bool) throws -> Self {
                guard accepted else { throw CheckError.rejected }
                return self
            }
        }

        public enum Mode {
            case idle
            case count(Int)
            case named(label: String)
            case pair(Int, name: String)
            case snapshot(Snapshot)

            public func code() -> Int {
                switch self {
                case .idle: return 0
                case .count: return 1
                case .named: return 2
                case .pair: return 3
                case .snapshot: return 4
                }
            }

            public consuming func echoed() -> Self { self }
        }

        public enum RawMode: Int {
            case idle = 3
            case active = 9

            public func rawCode() -> Int { rawValue }
        }
        }

        public func chooseSnapshot(
            _ value: Values.Snapshot?
        ) -> Values.Snapshot? {
            value
        }
        """
        let extensions = """
        extension Values.Snapshot {
            public func fromExtension() -> Values.Snapshot { self }
        }

        extension Values.Mode {
            public func fromExtension() -> Values.Mode { self }
        }
        """
        try Data(models.utf8).write(to: modelsURL)
        try Data(extensions.utf8).write(to: extensionsURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "FrontendFrozenValueFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**/*.swift
        """)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.frontend-frozen-value",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.frontend-frozen-value",
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
                    .init(logicalPath: "Sources/Models.swift", url: modelsURL),
                    .init(logicalPath: "Sources/Extensions.swift", url: extensionsURL),
                ],
                compilerURL: compilerURL
            )
        )
        let receipt = output.receipt
        #expect(receipt.roots.count == 19)
        #expect(receipt.roots.compactMap(\.bridge).count == 14)
        #expect(output.diagnostics.contains {
            $0.code == "HLXIDX011" && $0.message.contains("Pinned")
        })
        #expect(output.diagnostics.contains {
            $0.code == "HLXIDX011" && $0.message.contains("ExistentialBox")
        })
        #expect(output.diagnostics.contains {
            $0.code == "HLXIDX011" && $0.message.contains("PrivateStorage")
        })
        #expect(output.diagnostics.contains {
            $0.code == "HLXIDX011" && $0.message.contains("WeakBox")
        })
        #expect(output.diagnostics.contains {
            $0.code == "HLXIDX011" && $0.message.contains("FutureMode")
        })
        #expect(output.diagnostics.contains {
            $0.code == "HLXIDX010"
                && $0.message.contains("FutureRecord")
                && $0.message.contains("availability-constrained")
        })
        let pinned = try #require(receipt.declarations.first {
            $0.interface.baseName == "value"
        })
        #expect(receipt.roots.first {
            $0.declarationMangledName == pinned.mangledName
        }?.bridge == nil)
        #expect(receipt.frozenValueTypes.map(\.key.rawValue).sorted() == [
            "Values.CheckError", "Values.Marker", "Values.Metadata",
            "Values.Mode", "Values.RawMode", "Values.Snapshot",
        ])
        #expect(receipt.frozenValueTypes.first {
            $0.key.rawValue == "Values.CheckError"
        }?.conformsToError == true)
        #expect(receipt.roots.contains {
            $0.bridge != nil
                && $0.sourceDeclaration.replacementHeader.contains("Values.StoredMode")
        })

        let shell = try ShellBuild.Materializer().materialize(
            receipt: receipt,
            sourceRoot: directory
        )
        #expect(shell.archive.frozenValueTypes == receipt.frozenValueTypes)
        #expect(shell.archive.schemaVersion == 1)
        #expect(shell.archive.compatibility.interfaceArchive == .init(1))
        let transformedModels = String(
            decoding: try #require(shell.transformedSources["Sources/Models.swift"]),
            as: UTF8.self
        )
        #expect(transformedModels.contains("__helix_frozenValue_"))
        #expect(transformedModels.contains("private init("))
        #expect(transformedModels.contains("self.metadata = field0"))
        #expect(transformedModels.contains("self.retries = field7"))
        #expect(shell.bridge.sourceFiles.values.contains {
            $0.contains("encodeInput_frozenValue_")
                && $0.contains("decodeEnumeration")
        })
        try typeCheckGeneratedBridge(
            shell: shell,
            directory: directory,
            moduleName: moduleName
        )

        let patchedModels = models
            .replacingOccurrences(
                of: "samples.count + retries + delta + (enabled ? 1 : 0)",
                with: "samples.count + retries + delta + (enabled ? 11 : 10)"
            )
            .replacingOccurrences(
                of: "case .snapshot: return 4",
                with: "case .snapshot: return 14"
            )
        #expect(patchedModels != models)
        try Data(patchedModels.utf8).write(to: modelsURL)
        let changedMangledNames = Set(receipt.declarations.filter {
            ["score", "code"].contains($0.interface.baseName)
        }.map(\.mangledName))
        let selected = Set(shell.archive.functions.compactMap { record -> Core.FunctionKey? in
            changedMangledNames.contains(record.mangledName) ? record.key : nil
        })
        #expect(selected.count == 2)
        let patch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [modelsURL, extensionsURL],
                selectedFunctionKeys: selected,
                compilerURL: compilerURL,
                enforceToolchainFingerprint: false
            )
        )
        #expect(patch.changedFunctions.count == 2)
        let patchLocalKeys = Set(patch.module.localTypes.map(\.key))
        #expect(patchLocalKeys.isSuperset(of: Set([
            Bytecode.LocalTypeKey(rawValue: "Values.Metadata"),
            .init(rawValue: "Values.Mode"),
            .init(rawValue: "Values.Snapshot"),
        ])))
        #expect(!patchLocalKeys.contains(.init(rawValue: "Values.Marker")))
        _ = try Verification.Engine().verify(
            bytes: patch.bytecode,
            shell: Verification.ShellInterface(archive: shell.archive),
            policy: .init(acceptedCapabilities: Set(shell.archive.capabilities))
        )

        let reorderedFields = patchedModels.replacingOccurrences(
            of: """
                private let metadata: Metadata
                private let samples: [Int]
                private let title: String?
                private let enabled: Bool
                private let origin: (x: Int, y: String)
                private let lookup: [String: Int]
                private let flags: Set<String>
            """,
            with: """
                private let metadata: Metadata
                private let enabled: Bool
                private let samples: [Int]
                private let title: String?
                private let origin: (x: Int, y: String)
                private let lookup: [String: Int]
                private let flags: Set<String>
            """
        )
        #expect(reorderedFields != patchedModels)
        try Data(reorderedFields.utf8).write(to: modelsURL)
        #expect(throws: ReleaseCompiler.DriverError.self) {
            try ReleaseCompiler.Driver().build(
                .init(
                    archive: shell.archive,
                    sourceFiles: [modelsURL, extensionsURL],
                    selectedFunctionKeys: selected,
                    compilerURL: compilerURL,
                    enforceToolchainFingerprint: false
                )
            )
        }

        let reorderedCases = patchedModels.replacingOccurrences(
            of: """
                case idle
                case count(Int)
            """,
            with: """
                case count(Int)
                case idle
            """
        )
        #expect(reorderedCases != patchedModels)
        try Data(reorderedCases.utf8).write(to: modelsURL)
        #expect(throws: ReleaseCompiler.DriverError.self) {
            try ReleaseCompiler.Driver().build(
                .init(
                    archive: shell.archive,
                    sourceFiles: [modelsURL, extensionsURL],
                    selectedFunctionKeys: selected,
                    compilerURL: compilerURL,
                    enforceToolchainFingerprint: false
                )
            )
        }
    }

    func typeCheckGeneratedBridge(
        shell: ShellBuild.Output,
        directory: URL,
        moduleName: String,
        emitEntryObjects: Bool = false
    ) throws {
        let output = directory.appendingPathComponent(
            "GeneratedBridgeTypecheck",
            isDirectory: true
        )
        for (path, contents) in shell.transformedSources {
            let url = output.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url)
        }
        let frontend = SwiftFrontend.Driver()
        let modules = try swiftPMModulesDirectory()
        try requireFrontendSuccess(
            frontend.run(
                arguments: shell.transformedSources.keys.sorted() + [
                    "-emit-module", "-parse-as-library",
                    "-module-name", moduleName,
                    "-Xfrontend", "-enable-private-imports",
                    "-emit-module-path", "\(moduleName).swiftmodule",
                    "-I", modules.path,
                ] + (try runtimeSupportCompilerArguments(modules: modules)),
                workingDirectory: output
            )
        )
        let generatedURLs = try shell.bridge.sourceFiles.sorted(by: {
            $0.key < $1.key
        }).map { item in
            let url = output.appendingPathComponent(
                URL(fileURLWithPath: item.key).lastPathComponent
            )
            try Data(item.value.utf8).write(to: url)
            return url
        }
        try requireFrontendSuccess(
            frontend.run(
                arguments: generatedURLs.map(\.path) + [
                    "-typecheck", "-parse-as-library",
                    "-module-name", "FrontendReceiptGeneratedBridge",
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
        if emitEntryObjects {
            try requireFrontendSuccess(
                frontend.run(
                    arguments: shell.transformedSources.keys.sorted() + [
                        "-emit-object", "-parse-as-library",
                        "-whole-module-optimization",
                        "-module-name", moduleName,
                        "-Xfrontend", "-enable-private-imports",
                        "-I", modules.path,
                    ] + (try runtimeSupportCompilerArguments(modules: modules)) + [
                        "-o", output.appendingPathComponent(
                            "TransformedModule.o"
                        ).path,
                    ],
                    workingDirectory: output
                )
            )
            for (index, url) in generatedURLs.filter({
                $0.lastPathComponent.hasPrefix("HelixBridge.Entry_")
            }).enumerated() {
                try requireFrontendSuccess(
                    frontend.run(
                        arguments: [
                            url.path,
                            "-emit-object", "-parse-as-library",
                            "-module-name", "FrontendReceiptGeneratedEntry\(index)",
                            "-I", output.path,
                            "-I", modules.path,
                        ] + (try runtimeSupportCompilerArguments(modules: modules)) + [
                            "-Xfrontend", "-enable-private-imports",
                            "-Xfrontend", "-enable-dynamic-replacement-chaining",
                            "-warnings-as-errors",
                            "-o", output.appendingPathComponent(
                                "GeneratedEntry\(index).o"
                            ).path,
                        ],
                        workingDirectory: output
                    )
                )
            }
        }
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
            throw FrontendReceipt.Error.invalidRequest(
                "cannot locate SwiftPM module artifacts"
            )
        }
        return fallback
    }

    private func runtimeSupportCompilerArguments(modules: URL) throws -> [String] {
        let buildRoot = modules.deletingLastPathComponent()
        let supportModules = [
            "HelixRuntimeSupport",
            "HelixObjectiveCRuntimeSupport",
            "HelixCRuntimeSupport",
        ]
        var arguments: [String] = []
        for module in supportModules {
            let moduleMap = buildRoot
                .appendingPathComponent("\(module).build", isDirectory: true)
                .appendingPathComponent("module.modulemap")
            guard FileManager.default.fileExists(atPath: moduleMap.path) else {
                throw FrontendReceipt.Error.invalidRequest(
                    "missing \(module) module map"
                )
            }
            arguments.append(contentsOf: [
                "-Xcc", "-fmodule-map-file=\(moduleMap.path)",
            ])
        }
        return arguments
    }

    func typeCheckNativeReplacements(
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
        let privateImportSourceFile = URL(fileURLWithPath: logicalPath).lastPathComponent
        let transformedURL = output.appendingPathComponent(privateImportSourceFile)
        let sourceRecord = try #require(receipt.sources.first {
            $0.logicalPath == logicalPath
        })
        let functionByMangledName = Dictionary(
            uniqueKeysWithValues: shell.archive.functions.map { ($0.mangledName, $0) }
        )
        let declarationGroups = Dictionary(
            grouping: receipt.roots.filter { root in
                receipt.declarations.contains {
                    $0.mangledName == root.declarationMangledName
                        && $0.sourceFileLogicalID == logicalPath
                }
            },
            by: { $0.sourceDeclaration.identity }
        ).values
        let edits = try declarationGroups.compactMap {
            roots -> SourceTransform.Edit? in
            let root = try #require(roots.first)
            guard let insertion = root.declarationInsertion else { return nil }
            let keys = try roots.map {
                try #require(functionByMangledName[$0.declarationMangledName]).key
            }
            return .init(
                utf8Offset: root.declarationUTF8Offset,
                expectedDeclarationPrefix: root.expectedDeclarationPrefix,
                insertion: insertion,
                functionKeys: keys
            )
        }
        // Native replacements only require declaration-level `dynamic`
        // insertion. Permanent body dispatch is compiled separately by
        // `typeCheckGeneratedBridge`, with its Runtime dependencies present.
        let insertionOnlySource = try SourceTransform.Transformer().transform(
            source: originalSource,
            logicalPath: logicalPath,
            expectedSourceHash: sourceRecord.contentHash,
            edits: edits,
            replacements: [],
            supplementalDeclarations: ""
        ).contents
        try insertionOnlySource.write(to: transformedURL)
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
                sourceDeclaration: descriptor.sourceDeclaration,
                memberRole: descriptor.memberRole,
                body: try NativeGeneration.BodyExtractor().extract(
                    from: originalSource,
                    declarationAnchor: descriptor.declarationAnchor,
                    declarationOccurrence: descriptor.declarationOccurrence
                )
            )
        }
        let generated = try NativeGeneration.SourceGenerator().generateFiles(
            moduleName: moduleName,
            units: [
                .init(
                    sourceFileLogicalPath: logicalPath,
                    privateImportSourceFile: privateImportSourceFile,
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

    private func silResolverFixture(
        symbols: [String],
        declarationColumn: Int = 13
    ) throws -> (
        resolver: FrontendReceipt.SILFunctionResolver,
        source: FrontendReceipt.Adapter.SourceState,
        item: FrontendReceipt.TypedAST.Object
    ) {
        let sourceURL = URL(fileURLWithPath: "/tmp/HelixResolverFixture.swift")
        let contents = Data("public func probe() {}\n".utf8)
        let bodyOffset = try #require(contents.firstIndex(of: UInt8(ascii: "{")))
        let functionType = "@convention(thin) () -> ()"
        let scopes = symbols.enumerated().map { index, symbol in
            "sil_scope \(index + 1) { loc \"\(sourceURL.path)\":1:\(declarationColumn) "
                + "parent @\(symbol) : $\(functionType) }"
        }
        let functions = symbols.map { symbol in
            """
            sil @\(symbol) : $\(functionType) {
            bb0:
              %0 = tuple ()
              return %0
            } // end sil function '\(symbol)'
            """
        }
        let file = try CanonicalSIL.File(
            text: (scopes + functions).joined(separator: "\n")
        )
        let state = FrontendReceipt.Adapter.SourceState(
            logicalPath: "Sources/Fixture.swift",
            url: sourceURL,
            contents: contents,
            contentHash: .sha256(contents)
        )
        let item: FrontendReceipt.TypedAST.Object = [
            "usr": "s:7Fixture5probeyyFQO",
            "range": [
                "start": NSNumber(value: 0),
                "end": NSNumber(value: contents.count),
            ],
            "body": [
                "range": [
                    "start": NSNumber(value: bodyOffset),
                    "end": NSNumber(value: contents.count),
                ],
            ],
        ]
        return (.init(file: file), state, item)
    }
}
}
