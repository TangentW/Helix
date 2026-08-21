import Foundation
import HelixBytecode
import HelixCore
import HelixInterface
import HelixVerifier
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Release index, transform, Bridge, and archive-driven compilation")
struct ReleasePipeline {
    @Test("Indexer admits only non-suspending async roots and freezes their capability")
    func indexesAsyncLeafProfile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-async-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Patch.swift")
        let sourceText = """
        public func leaf(_ value: Int) async -> Int { value + 1 }
        @inline(never) public func helper(_ value: Int) async -> Int { value + 2 }
        public func suspending(_ value: Int) async -> Int { await helper(value) }
        """
        try Data(sourceText.utf8).write(to: source)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [source],
            moduleName: "Fixture"
        )
        let file = try CanonicalSIL.File(text: sil)
        let leaf = try file.uniqueFunction(mangledNameContaining: "4leaf")
        let suspending = try file.uniqueFunction(mangledNameContaining: "10suspending")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.async-index",
            buildNumber: "1",
            seed: "fixture"
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.async-index",
            buildNumber: "1",
            shellNamespaceID: namespace,
            machOUUIDs: [UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!],
            targetTriple: "arm64-apple-ios15.0",
            minimumOS: .init(15),
            xcodeBuild: "fixture",
            sdkBuild: "fixture",
            frontendInvocation: .init(
                moduleName: "Fixture",
                targetTriple: "arm64-apple-ios15.0",
                sdkName: "iphoneos",
                sdkBuild: "fixture"
            ),
            transformPipelineHash: .sha256("async-index-transform"),
            sourceBaselineHash: .sha256("replaced-by-indexer")
        )
        let effects = Core.Effects(isAsync: true)
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int",
            isAsync: true
        )
        func candidate(
            _ function: CanonicalSIL.Function,
            name: String
        ) -> ReleaseCompiler.DeclarationCandidate {
            .init(
                moduleName: "Fixture",
                sourceFileLogicalID: "Patch.swift",
                canonicalDeclaration: "func \(name)(_: Int) async -> Int",
                mangledName: function.mangledName,
                role: .function,
                loweredSignature: signature,
                parameterTypes: [.int64],
                resultType: .int64,
                interface: .init(
                    declarationKind: "function",
                    baseName: name,
                    argumentLabels: ["_"],
                    accessLevel: "public",
                    canonicalFormalType: "(Swift.Int) async -> Swift.Int",
                    loweredSILType: function.loweredType,
                    effects: effects
                ),
                canonicalSILBody: function.body,
                effects: effects,
                isAsync: true
            )
        }
        let configuration = PatchConfiguration.Document(
            modules: ["Fixture": .init(include: ["Patch.swift"])]
        )
        let request = ReleaseCompiler.IndexRequest(
            metadata: metadata,
            compatibility: .init(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: "swift-async-index"
            ),
            configuration: configuration,
            sources: [.init(logicalPath: "Patch.swift", contentHash: .sha256(sourceText))],
            declarations: [
                candidate(leaf, name: "leaf"),
                candidate(suspending, name: "suspending"),
            ]
        )

        let report = try ReleaseCompiler.Indexer().index(request)
        #expect(report.eligibleCount == 1)
        #expect(report.rejectedCount == 1)
        #expect(report.archive.capabilities.contains(.asyncLeafEntriesV1))
        #expect(report.archive.capabilities.contains(.anyValuesV1))
        #expect(report.archive.functions.first(where: {
            $0.mangledName == leaf.mangledName
        })?.patchability.isEligible == true)
        #expect(report.diagnostics.contains(where: {
            $0.code == "HLXIDX005" && $0.message.contains("non-suspending leaf profile")
        }))
    }

    @Test("HLXI 1.0 derives leaf fingerprints and requires generated dependency fingerprints")
    func rejectsMissingGeneratedImplementationFingerprint() throws {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.missing-implementation-fingerprint",
            buildNumber: "1",
            seed: "fixture"
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.missing-implementation-fingerprint",
            buildNumber: "1",
            shellNamespaceID: namespace,
            machOUUIDs: [UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!],
            targetTriple: "arm64-apple-ios15.0",
            minimumOS: .init(15),
            xcodeBuild: "fixture",
            sdkBuild: "fixture",
            frontendInvocation: .init(
                moduleName: "Fixture",
                targetTriple: "arm64-apple-ios15.0",
                sdkName: "iphoneos",
                sdkBuild: "fixture"
            ),
            transformPipelineHash: .sha256("missing-fingerprint-transform"),
            sourceBaselineHash: .sha256("replaced-by-indexer")
        )
        let interface = ReleaseCompiler.DeclarationInterface(
            declarationKind: "function",
            baseName: "transform",
            argumentLabels: ["_"],
            accessLevel: "public",
            canonicalFormalType: "(Swift.Int) -> Swift.Int",
            loweredSILType: "@convention(thin) (Int) -> Int"
        )
        let configuration = PatchConfiguration.Document(
            modules: ["Fixture": .init(include: ["Patch.swift"])]
        )
        let request = ReleaseCompiler.IndexRequest(
            metadata: metadata,
            compatibility: .init(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: "swift-missing-fingerprint"
            ),
            configuration: configuration,
            sources: [
                .init(logicalPath: "Patch.swift", contentHash: .sha256("source")),
            ],
            declarations: [
                .init(
                    moduleName: "Fixture",
                    sourceFileLogicalID: "Patch.swift",
                    canonicalDeclaration: "func transform(_: Int) -> Int",
                    mangledName: "$s7Fixture9transformyS2iF",
                    role: .function,
                    loweredSignature: .init(
                        parameters: ["Swift.Int"],
                        result: "Swift.Int"
                    ),
                    parameterTypes: [.int64],
                    resultType: .int64,
                    interface: interface,
                    canonicalSILBody: """
                    %1 = function_ref @$s7Fixture9transformyS2iFS2iXEfU_ : $@convention(thin) (Int) -> Int
                    return %0 : $Int
                    """
                ),
            ]
        )

        #expect(throws: ReleaseCompiler.IndexError.invalidInput(
            "compiler-generated dependencies require a transitive implementation fingerprint"
        )) {
            try ReleaseCompiler.Indexer().index(request)
        }

        var leafRequest = request
        leafRequest.declarations[0].canonicalSILBody = "return %0 : $Int"
        let leafReport = try ReleaseCompiler.Indexer().index(leafRequest)
        #expect(
            leafReport.archive.functions.first?.bodyFingerprint
                == ReleaseCompiler.ImplementationFingerprint.compute(
                    symbol: leafRequest.declarations[0].mangledName,
                    loweredType: interface.loweredSILType,
                    body: leafRequest.declarations[0].canonicalSILBody
                )
        )
    }

    @Test("One frozen HLXI contract drives the complete release compilation path")
    func archiveDrivesReleasePipeline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-release-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceText = "public func transform(_ x: Int) -> Int { x + 27 }\n"
        let sourceData = Data(sourceText.utf8)
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try sourceData.write(to: sourceURL)
        let canonicalSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "Fixture"
        )
        let selected = try CanonicalSIL.File(text: canonicalSIL)
            .uniqueFunction(mangledNameContaining: "transform")

        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.release-pipeline",
            buildNumber: "7",
            seed: "fixture"
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.release-pipeline",
            buildNumber: "7",
            shellNamespaceID: namespace,
            machOUUIDs: [UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!],
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
            transformPipelineHash: .sha256("transform-v1"),
            sourceBaselineHash: .sha256("replaced-by-indexer")
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-release-pipeline"
        )
        let interface = ReleaseCompiler.DeclarationInterface(
            declarationKind: "function",
            baseName: "transform",
            argumentLabels: ["_"],
            accessLevel: "public",
            canonicalFormalType: "(Swift.Int) -> Swift.Int",
            loweredSILType: "@convention(thin) (Int) -> Int"
        )
        var genericInterface = interface
        genericInterface.baseName = "generic"
        genericInterface.genericSignature = "<T where T: BinaryInteger>"
        let signature = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let nativeSignature = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let nativeEffects = Core.Effects()
        let nativeContract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 1_000,
            allowsMainThread: true
        )
        let nativeImportKey = try Core.NativeImportKey.derive(
            namespace: namespace,
            canonicalCallee: "Fixture.increment(_:)",
            signature: nativeSignature,
            effects: nativeEffects,
            contract: nativeContract
        )
        let nativeTypeID = Core.TypeID.derive(
            namespace: namespace,
            canonicalType: "Fixture.Point"
        )
        let nativeTypeLayout = Core.Digest.sha256("Fixture.Point.layout.v1")
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          Fixture:
            include:
              - Sources/**/*.swift
            nativeImports:
              candidateIndex: explicit-catalog
              emit: allowlisted
              allow:
                - Fixture.increment(_:)
        """)
        let report = try ReleaseCompiler.Indexer().index(
            .init(
                metadata: metadata,
                compatibility: compatibility,
                configuration: configuration,
                sources: [
                    .init(logicalPath: "Sources/Patch.swift", contentHash: .sha256(sourceData)),
                ],
                declarations: [
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/Patch.swift",
                        canonicalDeclaration: "func transform(_: Int) -> Int",
                        mangledName: selected.mangledName,
                        role: .function,
                        loweredSignature: signature,
                        parameterTypes: [.int64],
                        resultType: .int64,
                        interface: interface,
                        canonicalSILBody: "return %0"
                    ),
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/Patch.swift",
                        canonicalDeclaration: "func generic<T>(_: T) -> T",
                        mangledName: "$s7Fixture7genericyxxlF",
                        role: .function,
                        loweredSignature: .init(parameters: ["T"], result: "T"),
                        parameterTypes: [.int64],
                        resultType: .int64,
                        interface: genericInterface,
                        canonicalSILBody: "return %0",
                        isGeneric: true
                    ),
                ],
                nativeImportCandidates: [
                    .init(
                        id: nil,
                        key: nativeImportKey,
                        canonicalCallee: "Fixture.increment(_:)",
                        silMangledNames: ["$s7Fixture9incrementyS2iF"],
                        parameterTypes: [.int64],
                        resultType: .int64,
                        signature: nativeSignature,
                        effects: nativeEffects,
                        contract: nativeContract,
                        isEmittedToDevice: true
                    ),
                ],
                nativeTypes: [
                    .init(
                        id: nativeTypeID,
                        canonicalName: "Fixture.Point",
                        kind: .value,
                        layoutFingerprint: nativeTypeLayout,
                        isCopyable: true,
                        isEmittedToDevice: true,
                        estimatedSize: 16
                    ),
                ]
            )
        )
        #expect(report.eligibleCount == 1)
        #expect(report.rejectedCount == 1)
        #expect(report.diagnostics.map(\.code) == ["HLXIDX007"])

        let eligible = try #require(
            report.archive.functions.first(where: { $0.patchability.isEligible })
        )
        let entry = try #require(eligible.entryIndex)
        #expect(entry.rawValue == 0)
        let archiveBytes = try InterfaceArchive.Codec.encode(report.archive)
        let decoded = try InterfaceArchive.Codec.decode(archiveBytes).archive
        let shell = try Verification.ShellInterface(archive: decoded)
        let nativeImportID = try #require(
            decoded.nativeImports.first(where: \.isEmittedToDevice)?.id
        )

        let functionOffset = try #require(sourceText.range(of: "func transform"))
        let utf8Offset = sourceText.utf8.distance(
            from: sourceText.utf8.startIndex,
            to: functionOffset.lowerBound.samePosition(in: sourceText.utf8)!
        )
        let transformed = try SourceTransform.Transformer().transform(
            source: sourceData,
            logicalPath: "Sources/Patch.swift",
            expectedSourceHash: .sha256(sourceData),
            edits: [
                .init(
                    utf8Offset: utf8Offset,
                    expectedDeclarationPrefix: "func transform",
                    functionKey: eligible.key
                ),
            ]
        )
        #expect(String(decoding: transformed.contents, as: UTF8.self).contains("public dynamic func transform"))

        let bridgeRoots: [BridgeGeneration.Root] = [
            .init(
                functionKey: eligible.key,
                entryIndex: entry,
                sourceFileLogicalID: eligible.sourceFileLogicalID,
                privateImportSourceFile: "Patch.swift",
                originalReference: "transform(_:)",
                replacementDeclaration: "public func helixBridge_transform(_ x: Int) -> Int",
                parameterExpressions: ["x"],
                parameterSwiftTypes: ["Swift.Int"],
                resultSwiftType: "Swift.Int",
                originalInvocation: "transform(x)",
                bridgeInvocation: "helixBridge_transform(argument0)"
            ),
        ]
        #expect(throws: BridgeGeneration.Error.incompleteNativeImportBindings) {
            try BridgeGeneration.Generator().generate(
                archive: decoded,
                moduleName: "Fixture",
                roots: bridgeRoots
            )
        }
        let importBinding = BridgeGeneration.NativeImportBinding(
            id: nativeImportID,
            key: nativeImportKey,
            invokerExpression: "FixtureIncrementFactory.make("
                + "id: Core.NativeImportID(rawValue: \(nativeImportID.rawValue)), "
                + "key: Core.NativeImportKey(rawValue: try! Core.Digest(hex: "
                + "\(String(reflecting: nativeImportKey.rawValue.hex)))))"
        )
        let typeBinding = BridgeGeneration.NativeTypeBinding(
            id: nativeTypeID,
            canonicalName: "Fixture.Point",
            layoutFingerprint: nativeTypeLayout,
            operationsExpression: "FixturePointFactory.make("
                + "id: Core.TypeID(rawValue: try! Core.Digest(hex: "
                + "\(String(reflecting: nativeTypeID.rawValue.hex)))), "
                + "canonicalName: \"Fixture.Point\", "
                + "layoutFingerprint: try! Core.Digest(hex: "
                + "\(String(reflecting: nativeTypeLayout.hex))), "
                + "requiresMainActor: false)"
        )
        #expect(throws: BridgeGeneration.Error.incompleteNativeTypeBindings) {
            try BridgeGeneration.Generator().generate(
                archive: decoded,
                moduleName: "Fixture",
                roots: bridgeRoots,
                nativeImports: [importBinding]
            )
        }
        #expect(throws: BridgeGeneration.Error.nativeImportBindingMismatch(nativeImportID)) {
            try BridgeGeneration.Generator().generate(
                archive: decoded,
                moduleName: "Fixture",
                roots: bridgeRoots,
                nativeImports: [
                    .init(
                        id: nativeImportID,
                        key: .init(rawValue: .sha256("wrong native import")),
                        invokerExpression: "FixtureIncrementInvoker()"
                    ),
                ],
                nativeTypes: [typeBinding]
            )
        }
        let bridge = try BridgeGeneration.Generator().generate(
            archive: decoded,
            moduleName: "Fixture",
            roots: bridgeRoots,
            nativeImports: [importBinding],
            nativeTypes: [typeBinding]
        )
        #expect(bridge.registrationCount == 1)
        let generatedEntry = try #require(
            bridge.sourceFiles.first(where: { $0.key.contains("HelixBridge.Entry_") })?.value
        )
        #expect(generatedEntry.contains("@_dynamicReplacement"))
        #expect(generatedEntry.contains("Runtime.Bridge.shared.dispatch"))
        #expect(generatedEntry.contains("Runtime.Bridge.shared.withOriginalBypass"))
        #expect(generatedEntry.contains("case .originalRequired:"))
        #expect(generatedEntry.contains("return transform(x)"))
        #expect(generatedEntry.contains("helixBridge_transform(argument0)"))
        let generatedBridge = try #require(bridge.sourceFiles["Generated/FixtureBridge.swift"])
        #expect(generatedBridge.contains(decoded.shellInterfaceHash.hex))
        #expect(generatedBridge.contains("makeShellInterface()"))
        #expect(generatedBridge.contains("Verification.ResolvedEntry("))
        #expect(generatedBridge.contains("Verification.ResolvedNativeImport("))
        #expect(generatedBridge.contains("Verification.ResolvedNativeType("))
        #expect(generatedBridge.contains("makeNativeCatalog()"))
        #expect(generatedBridge.contains("makeNativeTypeCatalog()"))
        #expect(generatedBridge.contains("makeOriginalCatalog("))
        #expect(generatedBridge.contains("makeRuntime("))
        #expect(generatedBridge.contains("FixtureIncrementFactory.make("))
        #expect(generatedBridge.contains("FixturePointFactory.make("))
        #expect(generatedBridge.contains(nativeImportKey.rawValue.hex))
        #expect(generatedBridge.contains(nativeTypeLayout.hex))
        #expect(throws: BridgeGeneration.Error.invalidModuleName) {
            try BridgeGeneration.Generator().generate(
                archive: decoded,
                moduleName: "Invalid-Module",
                roots: bridgeRoots,
                nativeImports: [importBinding],
                nativeTypes: [typeBinding]
            )
        }
        let compiled = try PatchCompiler.Driver().compile(
            canonicalSIL: canonicalSIL,
            functionKey: eligible.key,
            currentInterface: interface,
            archive: decoded
        )
        // The executable probe must consume the same explicitly dynamic source
        // that the Release Shell compiles, not the pre-transform authoring file.
        try transformed.contents.write(to: sourceURL, options: .atomic)
        try typeCheckGeneratedBridge(
            bridge,
            baseSourceURL: sourceURL,
            directory: directory,
            nativeImportID: nativeImportID,
            nativeImportKey: nativeImportKey,
            nativeTypeID: nativeTypeID,
            nativeTypeLayout: nativeTypeLayout,
            patchBytecode: compiled.bytecode
        )

        let image = try Verification.Engine().verify(
            bytes: compiled.bytecode,
            shell: shell,
            policy: .init()
        )
        let input = try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)
        #expect(
            VM.Interpreter().invoke(entry: entry, image: image, arguments: [.integer(input)])
                == .returned(.integer(try VM.Integer(signed: 30, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("Generated bridges preserve effects and recursively encode collection values")
    func typeChecksThrowingAndMainActorBridges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-bridge-effects-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("BridgeFeatures.swift")
        let source = """
        public enum FixtureFailure: Error { case rejected }

        public func risky(_ x: Int) throws -> Int {
            guard x >= 0 else { throw FixtureFailure.rejected }
            return x + 1
        }

        @MainActor public func render(_ x: Int) -> Int { x + 2 }

        public func select(_ values: [Int]) -> [Int] { values }

        public func remap(_ values: [String: Int]) -> [String: Int] { values }

        public func unique(_ values: Set<Int>) -> Set<Int> { values }

        public func echo(_ value: Any) -> Any { value }

        public func echoCharacter(_ value: Character) -> Character { value }

        public func echoSubstring(_ value: Substring) -> Substring { value }
        """
        try Data(source.utf8).write(to: sourceURL, options: .atomic)

        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.bridge-effects",
            buildNumber: "1",
            seed: "fixture"
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.bridge-effects",
            buildNumber: "1",
            shellNamespaceID: namespace,
            machOUUIDs: [UUID(uuidString: "11111111-2222-3333-4444-555555555555")!],
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
            transformPipelineHash: .sha256("bridge-effects-transform"),
            sourceBaselineHash: .sha256("replaced-by-indexer")
        )
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          Fixture:
            include:
              - Sources/**/*.swift
        """)
        let commonInterface = ReleaseCompiler.DeclarationInterface(
            declarationKind: "function",
            baseName: "risky",
            argumentLabels: ["_"],
            accessLevel: "public",
            canonicalFormalType: "(Swift.Int) throws -> Swift.Int",
            loweredSILType: "@convention(thin) (Int) -> @error any Error"
        )
        var actorInterface = commonInterface
        actorInterface.baseName = "render"
        actorInterface.canonicalFormalType = "@MainActor (Swift.Int) -> Swift.Int"
        actorInterface.loweredSILType = "@convention(thin) @MainActor (Int) -> Int"
        var arrayInterface = commonInterface
        arrayInterface.baseName = "select"
        arrayInterface.canonicalFormalType = "(Swift.Array<Swift.Int>) -> Swift.Array<Swift.Int>"
        arrayInterface.loweredSILType = "@convention(thin) (@guaranteed Array<Int>) -> @owned Array<Int>"
        var dictionaryInterface = commonInterface
        dictionaryInterface.baseName = "remap"
        dictionaryInterface.canonicalFormalType = "(Swift.Dictionary<Swift.String, Swift.Int>) -> Swift.Dictionary<Swift.String, Swift.Int>"
        dictionaryInterface.loweredSILType = "@convention(thin) (@guaranteed Dictionary<String, Int>) -> @owned Dictionary<String, Int>"
        var setInterface = commonInterface
        setInterface.baseName = "unique"
        setInterface.canonicalFormalType = "(Swift.Set<Swift.Int>) -> Swift.Set<Swift.Int>"
        setInterface.loweredSILType = "@convention(thin) (@guaranteed Set<Int>) -> @owned Set<Int>"
        var anyInterface = commonInterface
        anyInterface.baseName = "echo"
        anyInterface.canonicalFormalType = "(Swift.Any) -> Swift.Any"
        anyInterface.loweredSILType = "@convention(thin) (@in_guaranteed Any) -> @out Any"
        var characterInterface = commonInterface
        characterInterface.baseName = "echoCharacter"
        characterInterface.canonicalFormalType = "(Swift.Character) -> Swift.Character"
        characterInterface.loweredSILType =
            "@convention(thin) (Character) -> Character"
        var substringInterface = commonInterface
        substringInterface.baseName = "echoSubstring"
        substringInterface.canonicalFormalType = "(Swift.Substring) -> Swift.Substring"
        substringInterface.loweredSILType =
            "@convention(thin) (@guaranteed Substring) -> @owned Substring"
        let report = try ReleaseCompiler.Indexer().index(
            .init(
                metadata: metadata,
                compatibility: .init(
                    runtime: Core.Versions.runtime,
                    bytecode: Core.Versions.bytecode,
                    interfaceArchive: Core.Versions.interfaceArchive,
                    compilerFingerprint: "swift-bridge-effects"
                ),
                configuration: configuration,
                sources: [
                    .init(logicalPath: "Sources/BridgeFeatures.swift", contentHash: .sha256(source)),
                ],
                declarations: [
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/BridgeFeatures.swift",
                        canonicalDeclaration: "func risky(_: Int) throws -> Int",
                        mangledName: "$s7Fixture5riskyyS2iKF",
                        role: .function,
                        loweredSignature: .init(
                            parameters: ["Swift.Int"],
                            result: "Swift.Int",
                            isThrowing: true
                        ),
                        parameterTypes: [.int64],
                        resultType: .int64,
                        interface: commonInterface,
                        canonicalSILBody: "return %0",
                        effects: .init(mayThrow: true)
                    ),
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/BridgeFeatures.swift",
                        canonicalDeclaration: "@MainActor func render(_: Int) -> Int",
                        mangledName: "$s7Fixture6renderyS2iF",
                        role: .function,
                        loweredSignature: .init(
                            parameters: ["Swift.Int"],
                            result: "Swift.Int",
                            isolation: "MainActor"
                        ),
                        parameterTypes: [.int64],
                        resultType: .int64,
                        interface: actorInterface,
                        canonicalSILBody: "return %0",
                        effects: .init(requiresMainActor: true)
                    ),
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/BridgeFeatures.swift",
                        canonicalDeclaration: "func select(_: [Int]) -> [Int]",
                        mangledName: "$s7Fixture6selectySaySiGACF",
                        role: .function,
                        loweredSignature: .init(
                            parameters: ["Swift.Array<Swift.Int>"],
                            result: "Swift.Array<Swift.Int>"
                        ),
                        parameterTypes: [.array(.int64)],
                        resultType: .array(.int64),
                        interface: arrayInterface,
                        canonicalSILBody: "return %0"
                    ),
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/BridgeFeatures.swift",
                        canonicalDeclaration: "func unique(_: Set<Int>) -> Set<Int>",
                        mangledName: "$s7Fixture6uniqueyShySiGACF",
                        role: .function,
                        loweredSignature: .init(
                            parameters: ["Swift.Set<Swift.Int>"],
                            result: "Swift.Set<Swift.Int>"
                        ),
                        parameterTypes: [.set(.int64)],
                        resultType: .set(.int64),
                        interface: setInterface,
                        canonicalSILBody: "return %0"
                    ),
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/BridgeFeatures.swift",
                        canonicalDeclaration: "func remap(_: [String: Int]) -> [String: Int]",
                        mangledName: "$s7Fixture5remapySDySSSiGACF",
                        role: .function,
                        loweredSignature: .init(
                            parameters: ["Swift.Dictionary<Swift.String, Swift.Int>"],
                            result: "Swift.Dictionary<Swift.String, Swift.Int>"
                        ),
                        parameterTypes: [.dictionary(key: .string, value: .int64)],
                        resultType: .dictionary(key: .string, value: .int64),
                        interface: dictionaryInterface,
                        canonicalSILBody: "return %0"
                    ),
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/BridgeFeatures.swift",
                        canonicalDeclaration: "func echo(_: Any) -> Any",
                        mangledName: "$s7Fixture4echoyypypF",
                        role: .function,
                        loweredSignature: .init(
                            parameters: ["Swift.Any"],
                            result: "Swift.Any"
                        ),
                        parameterTypes: [.any],
                        resultType: .any,
                        interface: anyInterface,
                        canonicalSILBody: "return %0"
                    ),
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/BridgeFeatures.swift",
                        canonicalDeclaration:
                            "func echoCharacter(_: Character) -> Character",
                        mangledName: "$s7Fixture13echoCharacteryS2JF",
                        role: .function,
                        loweredSignature: .init(
                            parameters: ["Swift.Character"],
                            result: "Swift.Character"
                        ),
                        parameterTypes: [.string],
                        resultType: .string,
                        interface: characterInterface,
                        canonicalSILBody: "return %0"
                    ),
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/BridgeFeatures.swift",
                        canonicalDeclaration:
                            "func echoSubstring(_: Substring) -> Substring",
                        mangledName: "$s7Fixture13echoSubstringyS2sF",
                        role: .function,
                        loweredSignature: .init(
                            parameters: ["Swift.Substring"],
                            result: "Swift.Substring"
                        ),
                        parameterTypes: [.array(.string)],
                        resultType: .array(.string),
                        interface: substringInterface,
                        canonicalSILBody: "return %0"
                    ),
                ]
            )
        )
        #expect(report.eligibleCount == 8)
        #expect(report.archive.capabilities.contains(.untypedThrowsV1))
        #expect(report.archive.capabilities.contains(.mainActorSyncV1))
        #expect(report.archive.capabilities.contains(.collectionsV1))
        #expect(report.archive.capabilities.contains(.localNominalsV1))
        #expect(report.archive.capabilities.contains(.structuredErrorsV1))
        #expect(report.archive.capabilities.contains(.anyValuesV1))

        let roots = try report.archive.functions.map { record -> BridgeGeneration.Root in
            let entry = try #require(record.entryIndex)
            if record.canonicalDeclaration.contains("echoCharacter") {
                return .init(
                    functionKey: record.key,
                    entryIndex: entry,
                    sourceFileLogicalID: record.sourceFileLogicalID,
                    privateImportSourceFile: "BridgeFeatures.swift",
                    originalReference: "echoCharacter(_:)",
                    replacementDeclaration:
                        "public func helixBridge_echoCharacter(_ value: Character) -> Character",
                    parameterExpressions: ["value"],
                    parameterSwiftTypes: ["Swift.Character"],
                    resultSwiftType: "Swift.Character",
                    originalInvocation: "echoCharacter(value)",
                    bridgeInvocation: "helixBridge_echoCharacter(argument0)"
                )
            }
            if record.canonicalDeclaration.contains("echoSubstring") {
                return .init(
                    functionKey: record.key,
                    entryIndex: entry,
                    sourceFileLogicalID: record.sourceFileLogicalID,
                    privateImportSourceFile: "BridgeFeatures.swift",
                    originalReference: "echoSubstring(_:)",
                    replacementDeclaration:
                        "public func helixBridge_echoSubstring(_ value: Substring) -> Substring",
                    parameterExpressions: ["value"],
                    parameterSwiftTypes: ["Swift.Substring"],
                    resultSwiftType: "Swift.Substring",
                    originalInvocation: "echoSubstring(value)",
                    bridgeInvocation: "helixBridge_echoSubstring(argument0)"
                )
            }
            if record.canonicalDeclaration.contains("echo") {
                return .init(
                    functionKey: record.key,
                    entryIndex: entry,
                    sourceFileLogicalID: record.sourceFileLogicalID,
                    privateImportSourceFile: "BridgeFeatures.swift",
                    originalReference: "echo(_:)",
                    replacementDeclaration: "public func helixBridge_echo(_ value: Any) -> Any",
                    parameterExpressions: ["value"],
                    parameterSwiftTypes: ["Swift.Any"],
                    resultSwiftType: "Swift.Any",
                    originalInvocation: "echo(value)",
                    bridgeInvocation: "helixBridge_echo(argument0)"
                )
            }
            if record.canonicalDeclaration.contains("remap") {
                return .init(
                    functionKey: record.key,
                    entryIndex: entry,
                    sourceFileLogicalID: record.sourceFileLogicalID,
                    privateImportSourceFile: "BridgeFeatures.swift",
                    originalReference: "remap(_:)",
                    replacementDeclaration: "public func helixBridge_remap(_ values: [String: Int]) -> [String: Int]",
                    parameterExpressions: ["values"],
                    parameterSwiftTypes: ["Swift.Dictionary<Swift.String, Swift.Int>"],
                    resultSwiftType: "Swift.Dictionary<Swift.String, Swift.Int>",
                    originalInvocation: "remap(values)",
                    bridgeInvocation: "helixBridge_remap(argument0)"
                )
            }
            if record.canonicalDeclaration.contains("unique") {
                return .init(
                    functionKey: record.key,
                    entryIndex: entry,
                    sourceFileLogicalID: record.sourceFileLogicalID,
                    privateImportSourceFile: "BridgeFeatures.swift",
                    originalReference: "unique(_:)",
                    replacementDeclaration: "public func helixBridge_unique(_ values: Set<Int>) -> Set<Int>",
                    parameterExpressions: ["values"],
                    parameterSwiftTypes: ["Swift.Set<Swift.Int>"],
                    resultSwiftType: "Swift.Set<Swift.Int>",
                    originalInvocation: "unique(values)",
                    bridgeInvocation: "helixBridge_unique(argument0)"
                )
            }
            if record.canonicalDeclaration.contains("select") {
                return .init(
                    functionKey: record.key,
                    entryIndex: entry,
                    sourceFileLogicalID: record.sourceFileLogicalID,
                    privateImportSourceFile: "BridgeFeatures.swift",
                    originalReference: "select(_:)",
                    replacementDeclaration: "public func helixBridge_select(_ values: [Int]) -> [Int]",
                    parameterExpressions: ["values"],
                    parameterSwiftTypes: ["Swift.Array<Swift.Int>"],
                    resultSwiftType: "Swift.Array<Swift.Int>",
                    originalInvocation: "select(values)",
                    bridgeInvocation: "helixBridge_select(argument0)"
                )
            }
            if record.effects.mayThrow {
                return .init(
                    functionKey: record.key,
                    entryIndex: entry,
                    sourceFileLogicalID: record.sourceFileLogicalID,
                    privateImportSourceFile: "BridgeFeatures.swift",
                    originalReference: "risky(_:)",
                    replacementDeclaration: "public func helixBridge_risky(_ x: Int) throws -> Int",
                    parameterExpressions: ["x"],
                    parameterSwiftTypes: ["Swift.Int"],
                    resultSwiftType: "Swift.Int",
                    originalInvocation: "risky(x)",
                    bridgeInvocation: "helixBridge_risky(argument0)"
                )
            }
            return .init(
                functionKey: record.key,
                entryIndex: entry,
                sourceFileLogicalID: record.sourceFileLogicalID,
                privateImportSourceFile: "BridgeFeatures.swift",
                originalReference: "render(_:)",
                replacementDeclaration: "@MainActor public func helixBridge_render(_ x: Int) -> Int",
                parameterExpressions: ["x"],
                parameterSwiftTypes: ["Swift.Int"],
                resultSwiftType: "Swift.Int",
                originalInvocation: "render(x)",
                bridgeInvocation: "helixBridge_render(argument0)"
            )
        }
        let bridge = try BridgeGeneration.Generator().generate(
            archive: report.archive,
            moduleName: "Fixture",
            roots: roots
        )
        let entrySource = bridge.sourceFiles.values.joined(separator: "\n")
        #expect(entrySource.contains("let decision = try Runtime.Bridge.shared.dispatch"))
        #expect(entrySource.contains("arguments: { encoder in"))
        #expect(entrySource.contains("encoder.encodeArguments(count:"))
        #expect(entrySource.contains("encoder.encodeArray"))
        #expect(entrySource.contains("encoder.encodeDictionary"))
        #expect(entrySource.contains("encoder.encodeSet"))
        #expect(entrySource.contains("return try risky(x)"))
        #expect(entrySource.contains("MainActor.assumeIsolated"))
        #expect(entrySource.contains("return .businessError"))
        #expect(entrySource.contains("BridgeValueCodec.encodeArray"))
        #expect(entrySource.contains("BridgeValueCodec.decodeArray"))
        #expect(entrySource.contains("BridgeValueCodec.encodeDictionary"))
        #expect(entrySource.contains("BridgeValueCodec.decodeDictionary"))
        #expect(entrySource.contains("BridgeValueCodec.encodeSet"))
        #expect(entrySource.contains("BridgeValueCodec.decodeSet"))
        #expect(entrySource.contains("encoder.encodeAny"))
        #expect(entrySource.contains("BridgeValueCodec.encodeAny"))
        #expect(entrySource.contains("BridgeValueCodec.decodeAny"))
        #expect(
            entrySource.contains(
                "BridgeValueCodec.decode(value, as: Swift.Character.self)"
            )
        )
        #expect(
            entrySource.contains(
                "BridgeValueCodec.decode(value, as: Swift.Substring.self)"
            )
        )
        try typeCheckGeneratedBridge(
            bridge,
            baseSourceURL: sourceURL,
            directory: directory,
            additionalSource: nil
        )
    }

    @Test("Generated async leaf Bridges preserve async, throws, isolation, and fail-closed catalog routing")
    func typeChecksAsyncLeafBridges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-bridge-async-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("AsyncBridge.swift")
        let source = """
        public enum AsyncFailure: Error { case rejected }

        public func refresh(_ value: Int) async -> Int { value + 1 }

        @MainActor public func renderAsync(_ value: Int) async throws -> Int {
            guard value >= 0 else { throw AsyncFailure.rejected }
            return value + 2
        }
        """
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
        let canonicalSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "Fixture"
        )
        let silFile = try CanonicalSIL.File(text: canonicalSIL)
        let refresh = try silFile.uniqueFunction(mangledNameContaining: "7refresh")
        let render = try silFile.uniqueFunction(mangledNameContaining: "11renderAsync")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.bridge-async",
            buildNumber: "1",
            seed: "fixture"
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.bridge-async",
            buildNumber: "1",
            shellNamespaceID: namespace,
            machOUUIDs: [UUID(uuidString: "11111111-2222-3333-4444-555555555555")!],
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
            transformPipelineHash: .sha256("bridge-async-transform"),
            sourceBaselineHash: .sha256("replaced-by-indexer")
        )
        let asyncEffects = Core.Effects(isAsync: true)
        let throwingActorEffects = Core.Effects(
            mayThrow: true,
            requiresMainActor: true,
            isAsync: true
        )
        let report = try ReleaseCompiler.Indexer().index(
            .init(
                metadata: metadata,
                compatibility: .init(
                    runtime: Core.Versions.runtime,
                    bytecode: Core.Versions.bytecode,
                    interfaceArchive: Core.Versions.interfaceArchive,
                    compilerFingerprint: "swift-bridge-async"
                ),
                configuration: .init(
                    modules: ["Fixture": .init(include: ["Sources/**/*.swift"])]
                ),
                sources: [
                    .init(
                        logicalPath: "Sources/AsyncBridge.swift",
                        contentHash: .sha256(source)
                    ),
                ],
                declarations: [
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/AsyncBridge.swift",
                        canonicalDeclaration: "func refresh(_: Int) async -> Int",
                        mangledName: refresh.mangledName,
                        role: .function,
                        loweredSignature: .init(
                            parameters: ["Swift.Int"],
                            result: "Swift.Int",
                            isAsync: true
                        ),
                        parameterTypes: [.int64],
                        resultType: .int64,
                        interface: .init(
                            declarationKind: "function",
                            baseName: "refresh",
                            argumentLabels: ["_"],
                            accessLevel: "public",
                            canonicalFormalType: "(Swift.Int) async -> Swift.Int",
                            loweredSILType: refresh.loweredType,
                            effects: asyncEffects
                        ),
                        canonicalSILBody: refresh.body,
                        effects: asyncEffects,
                        isAsync: true
                    ),
                    .init(
                        moduleName: "Fixture",
                        sourceFileLogicalID: "Sources/AsyncBridge.swift",
                        canonicalDeclaration:
                            "@MainActor func renderAsync(_: Int) async throws -> Int",
                        mangledName: render.mangledName,
                        role: .function,
                        loweredSignature: .init(
                            parameters: ["Swift.Int"],
                            result: "Swift.Int",
                            isThrowing: true,
                            isAsync: true,
                            isolation: "MainActor"
                        ),
                        parameterTypes: [.int64],
                        resultType: .int64,
                        interface: .init(
                            declarationKind: "function",
                            baseName: "renderAsync",
                            argumentLabels: ["_"],
                            accessLevel: "public",
                            canonicalFormalType:
                                "@MainActor (Swift.Int) async throws -> Swift.Int",
                            loweredSILType: render.loweredType,
                            effects: throwingActorEffects,
                            isolation: "MainActor"
                        ),
                        canonicalSILBody: render.body,
                        effects: throwingActorEffects,
                        isAsync: true
                    ),
                ]
            )
        )
        #expect(report.eligibleCount == 2)
        #expect(report.archive.capabilities.contains(.asyncLeafEntriesV1))

        let roots = try report.archive.functions.map { record -> BridgeGeneration.Root in
            let entry = try #require(record.entryIndex)
            if record.canonicalDeclaration.contains("renderAsync") {
                return .init(
                    functionKey: record.key,
                    entryIndex: entry,
                    sourceFileLogicalID: record.sourceFileLogicalID,
                    privateImportSourceFile: "AsyncBridge.swift",
                    originalReference: "renderAsync(_:)",
                    replacementDeclaration:
                        "@MainActor public func helixBridge_renderAsync(_ value: Int) async throws -> Int",
                    parameterExpressions: ["value"],
                    parameterSwiftTypes: ["Swift.Int"],
                    resultSwiftType: "Swift.Int",
                    originalInvocation: "renderAsync(value)",
                    bridgeInvocation: "helixBridge_renderAsync(argument0)"
                )
            }
            return .init(
                functionKey: record.key,
                entryIndex: entry,
                sourceFileLogicalID: record.sourceFileLogicalID,
                privateImportSourceFile: "AsyncBridge.swift",
                originalReference: "refresh(_:)",
                replacementDeclaration:
                    "public func helixBridge_refresh(_ value: Int) async -> Int",
                parameterExpressions: ["value"],
                parameterSwiftTypes: ["Swift.Int"],
                resultSwiftType: "Swift.Int",
                originalInvocation: "refresh(value)",
                bridgeInvocation: "helixBridge_refresh(argument0)"
            )
        }
        let bridge = try BridgeGeneration.Generator().generate(
            archive: report.archive,
            moduleName: "Fixture",
            roots: roots
        )
        let generated = bridge.sourceFiles.values.joined(separator: "\n")
        #expect(generated.contains("return await refresh(value)"))
        #expect(generated.contains("return try await renderAsync(value)"))
        #expect(generated.contains("async Shell entry requires its generated async Bridge"))
        #expect(!generated.contains("Runtime.Bridge.shared.withOriginalBypass"))
        try typeCheckGeneratedBridge(
            bridge,
            baseSourceURL: sourceURL,
            directory: directory,
            additionalSource: nil
        )
    }

    private func typeCheckGeneratedBridge(
        _ bridge: BridgeGeneration.Output,
        baseSourceURL: URL,
        directory: URL,
        nativeImportID: Core.NativeImportID,
        nativeImportKey: Core.NativeImportKey,
        nativeTypeID: Core.TypeID,
        nativeTypeLayout: Core.Digest,
        patchBytecode: Data
    ) throws {
        let support = """
        import HelixBytecode
        import HelixCore
        import HelixVM

        enum FixtureIncrementFactory: VM.NativeImportFactory {
            static func make(
                id: Core.NativeImportID,
                key: Core.NativeImportKey
            ) -> any VM.NativeInvoker {
                VM.ClosureNativeInvoker(
                    id: id,
                    key: key,
                    parameterTypes: [.int64],
                    resultType: .int64,
                    contract: .bounded(
                        kind: .globalFunction,
                        domain: .application,
                        access: .pure,
                        maximumDurationMicroseconds: 1_000,
                        allowsMainThread: true
                    )
                ) { arguments, _ in
                    .returned(arguments.first)
                }
            }
        }

        enum FixturePointFactory: VM.NativeTypeFactory {
            static func make(
                id: Core.TypeID,
                canonicalName: String,
                layoutFingerprint: Core.Digest,
                requiresMainActor: Bool
            ) -> VM.NativeTypeOperations {
                VM.NativeTypeOperations(
                    id: id,
                    canonicalName: canonicalName,
                    kind: .value,
                    layoutFingerprint: layoutFingerprint,
                    requiresMainActor: requiresMainActor,
                    estimatedSize: 16,
                    equals: { (left: Int, right: Int) in left == right },
                    hash: { (value: Int, hasher: inout Hasher) in hasher.combine(value) }
                )
            }
        }
        """
        try typeCheckGeneratedBridge(
            bridge,
            baseSourceURL: baseSourceURL,
            directory: directory,
            additionalSource: support
        )
        try executeGeneratedBridge(
            bridge,
            directory: directory,
            additionalSource: support,
            patchBytecode: patchBytecode
        )
    }

    private func typeCheckGeneratedBridge(
        _ bridge: BridgeGeneration.Output,
        baseSourceURL: URL,
        directory: URL,
        additionalSource: String?
    ) throws {
        let driver = SwiftFrontend.Driver()
        let fixtureModule = directory.appendingPathComponent("Fixture.swiftmodule")
        let fixtureImage = directory.appendingPathComponent("libFixture.dylib")
        try requireSuccess(
            driver.run(
                arguments: [
                    baseSourceURL.path,
                    "-emit-library", "-emit-module", "-parse-as-library",
                    "-module-name", "Fixture",
                    "-Xfrontend", "-enable-implicit-dynamic",
                    "-Xfrontend", "-enable-private-imports",
                    "-emit-module-path", fixtureModule.path,
                    "-Xlinker", "-install_name", "-Xlinker", "@rpath/libFixture.dylib",
                    "-o", fixtureImage.path,
                ],
                workingDirectory: directory
            )
        )

        var generatedURLs: [URL] = []
        for (path, contents) in bridge.sourceFiles.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try Data(contents.utf8).write(to: url, options: .atomic)
            generatedURLs.append(url)
        }
        if let additionalSource {
            let supportURL = directory.appendingPathComponent("FixtureBridgeSupport.swift")
            try Data(additionalSource.utf8).write(to: supportURL, options: .atomic)
            generatedURLs.append(supportURL)
        }

        let modules = try swiftPMModulesDirectory()
        try requireSuccess(
            driver.run(
                arguments: generatedURLs.map(\.path) + [
                    "-typecheck", "-parse-as-library",
                    "-module-name", "FixtureGeneratedBridge",
                    "-I", directory.path,
                    "-I", modules.path,
                ] + (try runtimeSupportCompilerArguments(modules: modules)) + [
                    "-Xfrontend", "-enable-private-imports",
                    "-Xfrontend", "-enable-dynamic-replacement-chaining",
                    "-warnings-as-errors",
                ],
                workingDirectory: directory
            )
        )
    }

    private func executeGeneratedBridge(
        _ bridge: BridgeGeneration.Output,
        directory: URL,
        additionalSource: String,
        patchBytecode: Data
    ) throws {
        var sourceURLs: [URL] = []
        for (path, contents) in bridge.sourceFiles.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try Data(contents.utf8).write(to: url, options: .atomic)
            sourceURLs.append(url)
        }
        let supportURL = directory.appendingPathComponent("FixtureBridgeSupport.swift")
        try Data(additionalSource.utf8).write(to: supportURL, options: .atomic)
        sourceURLs.append(supportURL)
        let hostURL = directory.appendingPathComponent("FixtureBridgeHost.swift")
        let bytecodeLiteral = patchBytecode.map(String.init).joined(separator: ", ")
        let host = """
        import Foundation
        import Fixture
        import HelixCore
        import HelixRuntime
        import HelixVerifier

        @main
        enum FixtureBridgeHost {
            static func mark(_ value: String) {
                FileHandle.standardError.write(Data((value + "\\n").utf8))
            }

            static func main() throws {
                mark("start")
                let runtime = try FixtureBridge.makeRuntime()
                mark("runtime")
                try FixtureBridge.bootstrap(using: runtime)
                mark("bootstrap")
                let direct = transform(9)
                mark("direct=\\(direct)")
                guard direct == 36 else {
                    fatalError("permanent replacement did not reach its lexical previous implementation")
                }
                guard runtime.originals.indices.count == 1,
                      let entry = runtime.originals.indices.first,
                      let original = runtime.originals[entry]
                else {
                    fatalError("generated OriginalCatalog is incomplete")
                }
                let input = try Runtime.BridgeValueCodec.encode(Int(9))
                mark("catalog")
                guard case let .returned(value) = original.invoke([input]),
                      let value,
                      try Runtime.BridgeValueCodec.decode(value, as: Int.self) == 36
                else {
                    fatalError("OriginalCatalog did not bypass the active replacement")
                }
                let patchBytes = Data([\(bytecodeLiteral)])
                let image = try Verification.Engine().verify(
                    bytes: patchBytes,
                    shell: try FixtureBridge.makeShellInterface(),
                    policy: .init()
                )
                let generation = try Runtime.Generation(
                    id: .init(rawValue: 1),
                    parentID: nil,
                    packageID: "HLX-generated-bridge-probe",
                    packageHash: .sha256(patchBytes),
                    images: [image],
                    estimatedByteCount: patchBytes.count
                )
                try runtime.activate(generation, expectedActiveID: nil)
                guard transform(3) == 30 else {
                    fatalError("permanent replacement did not route through HLVM")
                }
                try runtime.rollback(expectedActiveID: generation.id, to: nil)
                guard transform(9) == 36 else {
                    fatalError("rollback did not restore the lexical previous implementation")
                }
                mark("done")
                print("HELIX_GENERATED_BRIDGE_OK")
            }
        }
        """
        try Data(host.utf8).write(to: hostURL, options: .atomic)
        sourceURLs.append(hostURL)

        let modules = try swiftPMModulesDirectory()
        let executable = directory.appendingPathComponent("FixtureBridgeHost")
        let objects = try runtimeObjectFiles(modules: modules)
        let link = try SwiftFrontend.Driver().run(
            arguments: sourceURLs.map(\.path) + objects.map(\.path) + [
                "-parse-as-library", "-module-name", "FixtureGeneratedBridgeHost",
                "-I", directory.path, "-I", modules.path,
            ] + (try runtimeSupportCompilerArguments(modules: modules)) + [
                "-L", directory.path, "-lFixture",
                "-Xfrontend", "-enable-private-imports",
                "-Xfrontend", "-enable-dynamic-replacement-chaining",
                "-Xlinker", "-rpath", "-Xlinker", directory.path,
                "-warnings-as-errors", "-o", executable.path,
            ],
            workingDirectory: directory
        )
        try requireSuccess(link)
        let execution = try SwiftFrontend.Driver(compilerURL: executable).run(
            arguments: [],
            workingDirectory: directory
        )
        try requireSuccess(execution)
        #expect(execution.standardOutput.contains("HELIX_GENERATED_BRIDGE_OK"))
    }

    @Test("Generated Bridge link input excludes stale SwiftPM object files")
    func generatedBridgeLinkInputUsesCurrentOutputMaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-runtime-objects-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modules = root.appendingPathComponent("Modules", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        let targets = [
            "HelixCore", "HelixBytecode", "HelixInterface",
            "HelixVerifier", "HelixVM", "HelixRuntime", "HelixPatch",
        ]
        var expected: [URL] = []
        for target in targets {
            let targetDirectory = root.appendingPathComponent("\(target).build", isDirectory: true)
            try FileManager.default.createDirectory(
                at: targetDirectory,
                withIntermediateDirectories: true
            )
            let active = targetDirectory.appendingPathComponent("Active.swift.o")
            let stale = targetDirectory.appendingPathComponent("Removed.swift.o")
            try Data().write(to: active)
            try Data().write(to: stale)
            expected.append(active)

            let source = "/Sources/\(target)/Active.swift"
            let outputMap = [source: ["object": active.path]]
            let encoded = try JSONEncoder().encode(outputMap)
            try encoded.write(to: targetDirectory.appendingPathComponent("output-file-map.json"))
        }
        let support = root
            .appendingPathComponent("HelixRuntimeSupport.build", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let supportObject = support.appendingPathComponent("RuntimeAtomic.c.o")
        try Data().write(to: supportObject)
        expected.append(supportObject)

        #expect(try runtimeObjectFiles(modules: modules) == expected)
    }

    private struct SwiftPMOutputFile: Decodable {
        var object: String?
    }

    private func runtimeObjectFiles(modules: URL) throws -> [URL] {
        let buildDirectory = modules.deletingLastPathComponent()
        let targetNames = [
            "HelixCore", "HelixBytecode", "HelixInterface",
            "HelixVerifier", "HelixVM", "HelixRuntime", "HelixPatch",
        ]
        var result: [URL] = []
        for target in targetNames {
            let directory = buildDirectory.appendingPathComponent("\(target).build", isDirectory: true)
            let mapURL = directory.appendingPathComponent("output-file-map.json")
            let outputMap: [String: SwiftPMOutputFile]
            do {
                outputMap = try JSONDecoder().decode(
                    [String: SwiftPMOutputFile].self,
                    from: Data(contentsOf: mapURL)
                )
            } catch {
                throw SwiftFrontend.Error.launchFailed(
                    "invalid SwiftPM output map for \(target)"
                )
            }
            let targetPath = directory.standardizedFileURL.path + "/"
            let sourceRecords = outputMap.filter { !$0.key.isEmpty }
            var objectPaths = Set<String>()
            for record in sourceRecords {
                guard let path = record.value.object else {
                    throw SwiftFrontend.Error.launchFailed(
                        "SwiftPM output map has no object for \(target) source \(record.key)"
                    )
                }
                let object = URL(fileURLWithPath: path).standardizedFileURL
                guard object.path.hasPrefix(targetPath),
                      object.path.hasSuffix(".o"),
                      FileManager.default.fileExists(atPath: object.path)
                else {
                    throw SwiftFrontend.Error.launchFailed(
                        "invalid object file in SwiftPM output map for \(target)"
                    )
                }
                objectPaths.insert(object.path)
            }
            guard !objectPaths.isEmpty else {
                throw SwiftFrontend.Error.launchFailed("missing object files for \(target)")
            }
            result.append(contentsOf: objectPaths.sorted().map(URL.init(fileURLWithPath:)))
        }
        let supportObject = buildDirectory
            .appendingPathComponent("HelixRuntimeSupport.build", isDirectory: true)
            .appendingPathComponent("RuntimeAtomic.c.o")
        guard FileManager.default.fileExists(atPath: supportObject.path) else {
            throw SwiftFrontend.Error.launchFailed("missing HelixRuntimeSupport object file")
        }
        result.append(supportObject)
        return result
    }

    private func runtimeSupportCompilerArguments(modules: URL) throws -> [String] {
        let supportDirectory = modules
            .deletingLastPathComponent()
            .appendingPathComponent("HelixRuntimeSupport.build", isDirectory: true)
        let moduleMap = supportDirectory.appendingPathComponent("module.modulemap")
        guard FileManager.default.fileExists(atPath: moduleMap.path) else {
            throw SwiftFrontend.Error.launchFailed("missing HelixRuntimeSupport module map")
        }
        return ["-Xcc", "-fmodule-map-file=\(moduleMap.path)"]
    }

    private func swiftPMModulesDirectory() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        var candidates: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: keys,
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
        if let fallback = candidates.sorted(by: { $0.path < $1.path }).first {
            return fallback
        }
        throw SwiftFrontend.Error.launchFailed("cannot locate SwiftPM module artifacts")
    }

    private func requireSuccess(_ output: SwiftFrontend.Output) throws {
        guard output.terminationStatus == 0 else {
            throw SwiftFrontend.Error.compilationFailed(
                status: output.terminationStatus,
                diagnostics: output.standardError
            )
        }
    }
}
}
