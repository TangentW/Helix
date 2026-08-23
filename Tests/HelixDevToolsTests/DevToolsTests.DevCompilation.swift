import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixDevTools
import HelixInterface
import HelixLiveReloadAPI
import Testing

extension DevToolsTests {
@Suite("Development HLBC compilation")
struct DevCompilationTests {
    @Test("Swift bodies are extracted without treating literal or comment braces as declarations")
    func extractsLexicallyBalancedBody() throws {
        let source = ##"""
        func render() {
            let ordinary = "literal } and {"
            let interpolated = "value \({ () -> String in "}" }())"
            let raw = #"raw } {"#
            let regex = /item{2,3}/
            let rawRegex = #/other{4}/#
            /* outer } /* nested { */ still ignored */
            if ordinary.isEmpty { print("}") }
        }
        func after() { fatalError() }
        """##
        let body = try NativeGeneration.BodyExtractor().extract(
            from: Data(source.utf8),
            declarationAnchor: "func render() {"
        )
        #expect(body.contains("if ordinary.isEmpty"))
        #expect(!body.contains("func after"))

        #expect(throws: NativeGeneration.BodyExtractionError.ambiguousAnchor) {
            _ = try NativeGeneration.BodyExtractor().extract(
                from: Data("func f() {}\nfunc f() {}".utf8),
                declarationAnchor: "func f() {"
            )
        }
        let repeated = Data("func f() { first() }\nfunc f() { second() }".utf8)
        let second = try NativeGeneration.BodyExtractor().extract(
            from: repeated,
            declarationAnchor: "func f() {",
            declarationOccurrence: 1
        )
        #expect(second.contains("second()"))
        #expect(!second.contains("first()"))
        #expect(throws: NativeGeneration.BodyExtractionError.anchorNotFound) {
            _ = try NativeGeneration.BodyExtractor().extract(
                from: Data(source.utf8),
                declarationAnchor: "func changed() {"
            )
        }
    }

    @Test("A saved Swift body becomes HLBC and restoring the file emits a tombstone")
    func compilesAndRestoresBaseline() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let builder = DevCompilation.BytecodeBuilder(
            archive: fixture.archive,
            manifest: fixture.manifest
        )

        try fixture.write("public func transform(_ x: Int) -> Int { x + 27 }\n")
        let changedRequest = try await fixture.request(revision: 1, generation: 1)
        let changedOutcome = try await builder.build(changedRequest)
        let changedPatch = try #require(changedOutcome.patch)
        #expect(changedPatch.backend == .hlbc)
        #expect(!changedPatch.payload.isEmpty)
        #expect(changedPatch.changedFunctions == [fixture.function.key])
        #expect(changedPatch.restoredFunctions.isEmpty)

        await builder.didActivate(
            fixture.offer(for: changedPatch, revision: 1, generation: 1)
        )
        #expect(await builder.activeFunctionKeys == [fixture.function.key])

        try fixture.write(fixture.baseline)
        let restoreRequest = try await fixture.request(
            revision: 2,
            generation: 2,
            restoredToBaseline: true
        )
        let restoreOutcome = try await builder.build(restoreRequest)
        let restorePatch = try #require(restoreOutcome.patch)
        #expect(restorePatch.payload.isEmpty)
        #expect(restorePatch.mode == .restoreOriginals)
        #expect(restorePatch.changedFunctions == [fixture.function.key])
        #expect(restorePatch.restoredFunctions == [fixture.function.key])

        await builder.didActivate(
            fixture.offer(for: restorePatch, revision: 2, generation: 2)
        )
        #expect(await builder.activeFunctionKeys.isEmpty)
    }

    @Test("A save may add an image-local helper without rebuilding the Dev Shell")
    func compilesNewPatchLocalFunction() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let builder = DevCompilation.BytecodeBuilder(
            archive: fixture.archive,
            manifest: fixture.manifest
        )

        try fixture.write(
            """
            @inline(never)
            private func check(_ value: Int) -> Int { value * 4 }

            @inline(never)
            public func transform(_ x: Int) -> Int { check(x) + 1 }
            """
        )
        let outcome = try await builder.build(
            fixture.request(revision: 1, generation: 1)
        )
        let patch = try #require(outcome.patch)
        let module = try Bytecode.Decoder.decode(patch.payload).module

        #expect(patch.backend == .hlbc)
        #expect(patch.changedFunctions == [fixture.function.key])
        #expect(module.functions.count == 2)
        #expect(module.functions.allSatisfy { $0.kind == .ordinary })
        #expect(Bytecode.Disassembler.disassemble(module).contains("hlbc_apply"))
    }

    @Test("A save may add image-local value types and computed accessors")
    func compilesNewPatchLocalTypes() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let builder = DevCompilation.BytecodeBuilder(
            archive: fixture.archive,
            manifest: fixture.manifest
        )

        try fixture.write(
            """
            private enum Feature {}

            private extension Feature {
                struct Measurement {
                    var raw: Int
                    var doubled: Int {
                        @inline(never) get { raw * 2 }
                    }
                }

                enum Selection {
                    case measurement(Measurement)
                    case none
                }
            }

            @inline(never)
            public func transform(_ x: Int) -> Int {
                let selection = Feature.Selection.measurement(
                    Feature.Measurement(raw: x)
                )
                switch selection {
                case let .measurement(value): return value.doubled
                case .none: return -1
                }
            }
            """
        )
        let outcome = try await builder.build(
            fixture.request(revision: 1, generation: 1)
        )
        let patch = try #require(outcome.patch)
        let module = try Bytecode.Decoder.decode(patch.payload).module
        let disassembly = Bytecode.Disassembler.disassemble(module)

        #expect(patch.backend == .hlbc)
        #expect(module.localTypes.map(\.key.rawValue) == [
            "Feature.Measurement", "Feature.Selection",
        ])
        #expect(disassembly.contains("make_struct"))
        #expect(disassembly.contains("make_enum"))
        #expect(disassembly.contains("hlbc_apply"))
    }

    @Test("A save may add a final class with mutable fields and computed accessors")
    func compilesNewPatchLocalClass() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let builder = DevCompilation.BytecodeBuilder(
            archive: fixture.archive,
            manifest: fixture.manifest
        )

        try fixture.write(
            """
            private final class CounterBox {
                var value: Int

                init(_ value: Int) {
                    self.value = value
                }

                @inline(never)
                func increment() {
                    value += 1
                }

                var doubled: Int {
                    @inline(never) get { value * 2 }
                }
            }

            @inline(never)
            public func transform(_ x: Int) -> Int {
                let box = CounterBox(x)
                let alias = box
                alias.increment()
                return box.doubled
            }
            """
        )
        let outcome = try await builder.build(
            fixture.request(revision: 1, generation: 1)
        )
        let patch = try #require(outcome.patch)
        let module = try Bytecode.Decoder.decode(patch.payload).module
        let disassembly = Bytecode.Disassembler.disassemble(module)

        #expect(patch.backend == .hlbc)
        #expect(module.localTypes.map(\.key.rawValue) == ["CounterBox"])
        #expect(module.capabilities.contains(.localClassesV1))
        #expect(disassembly.contains("allocate_object"))
        #expect(disassembly.contains("project_object_addr"))
        #expect(disassembly.contains("hlbc_apply"))
    }

    @Test("A Swift syntax error remains a compile diagnostic and preserves active code")
    func reportsSwiftDiagnostic() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let builder = DevCompilation.BytecodeBuilder(
            archive: fixture.archive,
            manifest: fixture.manifest
        )
        try fixture.write("public func transform(_ x: Int) -> Int { x + }\n")
        let request = try await fixture.request(revision: 1, generation: 1)

        do {
            _ = try await builder.build(request)
            Issue.record("expected the Swift frontend diagnostic")
        } catch let diagnostic as DevProtocol.Diagnostic {
            #expect(diagnostic.code == "HLXLR202")
            #expect(diagnostic.previousCodeRemainsActive)
            #expect(diagnostic.message.contains("error:"))
            try diagnostic.validate()
        }
    }

    @Test("A changed frozen Swift signature requires a new Dev Shell")
    func rejectsInterfaceChange() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let builder = DevCompilation.BytecodeBuilder(
            archive: fixture.archive,
            manifest: fixture.manifest
        )
        try fixture.write("public func transform(_ x: Int64) -> Int64 { x + 1 }\n")
        let outcome = try await builder.build(
            fixture.request(revision: 1, generation: 1)
        )
        let diagnostic = try #require(outcome.rebuildDiagnostic)
        #expect(diagnostic.code == "HLXLR303")
        try diagnostic.validate()
    }

    @Test("A manifest and HLXI identity mismatch is rejected before compilation")
    func rejectsFrozenIdentityMismatch() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var staleManifest = fixture.manifest
        staleManifest.xcodeBuild = "different-Xcode"
        let builder = DevCompilation.BytecodeBuilder(
            archive: fixture.archive,
            manifest: staleManifest
        )
        try fixture.write("public func transform(_ x: Int) -> Int { x + 3 }\n")
        let outcome = try await builder.build(
            fixture.request(revision: 1, generation: 1)
        )
        let diagnostic = try #require(outcome.rebuildDiagnostic)
        #expect(diagnostic.code == "HLXLR301")
        try diagnostic.validate()
    }

    @Test("A saved Swift body becomes a signed Native image and baseline restore remains a replacement")
    func compilesAndRestoresNativeGeneration() async throws {
        let fixture = try NativeFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let builder = try DevCompilation.NativeBuilder(
            archive: fixture.archive,
            manifest: fixture.manifest,
            reloadIndex: fixture.reloadIndex,
            outputDirectory: fixture.directory.appendingPathComponent("Generations")
        )

        try fixture.write("public dynamic func transform(_ x: Int) -> Int { x + 19 }\n")
        let changed = try #require(
            try await builder.build(fixture.request(revision: 1, generation: 1)).patch
        )
        #expect(changed.backend == .nativeDynamicReplacement)
        #expect(!changed.payload.isEmpty)
        #expect(changed.changedFunctions == [fixture.function.key])
        #expect(changed.restoredFunctions.isEmpty)
        let changedOffer = fixture.offer(for: changed, revision: 1, generation: 1)
        try changedOffer.validate()
        #expect(await builder.didActivate(changedOffer))
        #expect(await builder.activeFunctionKeys == [fixture.function.key])
        let descriptor = try MachO.Inspector().inspect(changed.payload)
        #expect(descriptor.platform == .iOSSimulator)
        #expect(descriptor.isCodeSigned)
        #expect(descriptor.uuid == changed.debugSymbolsUUID)
        let symbols = try #require(changed.debugSymbols)
        #expect(symbols.imageUUID == descriptor.uuid)
        #expect(symbols.sourceMappings.map(\.logicalPath) == ["Feature.swift"])
        #expect(symbols.sourceMappings.map(\.absolutePath) == [fixture.sourceURL.path])
        let dwarfDump = try ProcessExecution.Runner().run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["dwarfdump", "--debug-info", symbols.dwarfURL.path],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: fixture.directory
        )
        #expect(dwarfDump.status == 0)
        #expect(dwarfDump.standardOutput.contains("Feature.swift"))

        try fixture.write(fixture.baseline)
        let restored = try #require(
            try await builder.build(
                fixture.request(revision: 2, generation: 2, restoredToBaseline: true)
            ).patch
        )
        #expect(restored.backend == .nativeDynamicReplacement)
        #expect(!restored.payload.isEmpty)
        #expect(restored.mode == .replacement)
        #expect(restored.restoredFunctions == [fixture.function.key])
        let restoredOffer = fixture.offer(for: restored, revision: 2, generation: 2)
        try restoredOffer.validate()
        #expect(await builder.didActivate(restoredOffer))
        #expect(await builder.activeFunctionKeys.isEmpty)
    }
}
}

private extension DevSession.BuildOutcome {
    var patch: DevSession.BuiltPatch? {
        guard case let .patch(patch) = self else { return nil }
        return patch
    }

    var rebuildDiagnostic: DevProtocol.Diagnostic? {
        guard case let .rebuildRequired(diagnostic) = self else { return nil }
        return diagnostic
    }
}

private struct Fixture {
    let directory: URL
    let sourceURL: URL
    let baseline: String
    let sourceID: LiveReload.SourceFileID
    let archive: InterfaceArchive.Archive
    let manifest: DevBuildManifest.Document
    let function: InterfaceArchive.FunctionRecord

    static func make() throws -> Self {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-dev-compilation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let sourceURL = directory.appendingPathComponent("Patch.swift")
            let baseline = "public func transform(_ x: Int) -> Int { x + 1 }\n"
            try Data(baseline.utf8).write(to: sourceURL)

            let compiler = ReleaseCompiler.Driver()
            let toolchain = try compiler.toolchainIdentity()
            let frontend = SwiftFrontend.Driver()
            let sdk = try frontend.sdkIdentity(name: "iphoneos")
            let target = "arm64-apple-ios15.0"
            let module = "DevCompilationFixture"
            let invocation = InterfaceArchive.FrontendInvocation(
                moduleName: module,
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone"
            )
            let sil = try CanonicalSIL.File(
                text: frontend.emitCanonicalSIL(
                    sourceFiles: [sourceURL],
                    invocation: invocation
                )
            )
            let parsed = try sil.uniqueFunction(mangledNameContaining: "transform")
            let namespace = Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.compilation",
                buildNumber: "1",
                seed: "fixture"
            )
            let executableUUID = UUID()
            let metadata = InterfaceArchive.ReleaseMetadata(
                bundleID: "dev.helix.compilation",
                buildNumber: "1",
                shellNamespaceID: namespace,
                machOUUIDs: [executableUUID],
                targetTriple: target,
                minimumOS: .init(15),
                xcodeBuild: "fixture-Xcode",
                sdkBuild: sdk.buildVersion,
                frontendInvocation: invocation,
                transformPipelineHash: .sha256("dev-compilation-transform"),
                sourceBaselineHash: .sha256("indexed-below")
            )
            let configuration = try PatchConfiguration.Document.parse(yaml: """
            schema: 1
            modules:
              \(module):
                include:
                  - Patch.swift
            """)
            let declaration = ReleaseCompiler.DeclarationCandidate(
                moduleName: module,
                sourceFileLogicalID: "Patch.swift",
                canonicalDeclaration: "func transform(_: Int) -> Int",
                mangledName: parsed.mangledName,
                role: .function,
                loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
                parameterTypes: [.int64],
                resultType: .int64,
                interface: .init(
                    declarationKind: "function",
                    baseName: "transform",
                    argumentLabels: ["_"],
                    accessLevel: "public",
                    canonicalFormalType: "(Swift.Int) -> Swift.Int",
                    loweredSILType: parsed.loweredType
                ),
                canonicalSILBody: parsed.body
            )
            let sourceHash = Core.Digest.sha256(Data(baseline.utf8))
            let archive = try ReleaseCompiler.Indexer().index(
                .init(
                    metadata: metadata,
                    compatibility: .init(
                        runtime: Core.Versions.runtime,
                        bytecode: Core.Versions.bytecode,
                        interfaceArchive: Core.Versions.interfaceArchive,
                        compilerFingerprint: toolchain.fingerprint
                    ),
                    configuration: configuration,
                    sources: [.init(logicalPath: "Patch.swift", contentHash: sourceHash)],
                    declarations: [declaration]
                )
            ).archive
            let function = try #require(archive.functions.first)
            let sourceID = LiveReload.SourceFileID.derive(logicalPath: "Patch.swift")
            let manifest = DevBuildManifest.Document(
                sessionBuildID: UUID(),
                workspacePathHash: .sha256(directory.path),
                scheme: "Fixture",
                configuration: "Debug",
                bundleID: metadata.bundleID,
                executableUUID: executableUUID,
                moduleName: module,
                targetTriple: target,
                architecture: "arm64",
                platform: .iOS,
                minimumOS: .init(15),
                xcodeBuild: metadata.xcodeBuild,
                swiftCompilerFingerprint: toolchain.fingerprint,
                sdkBuild: sdk.buildVersion,
                frontendArguments: [
                    "-module-name", module, "-target", target,
                    "-sdk", sdk.path, "-Onone", "-enable-implicit-dynamic", sourceURL.path,
                ],
                linkArguments: [],
                moduleSearchPaths: [],
                sourceFiles: [
                    .init(
                        id: sourceID,
                        logicalPath: "Patch.swift",
                        absolutePath: sourceURL.path,
                        contentHash: sourceHash
                    ),
                ],
                buildProducts: [],
                liveReloadIndexHash: .sha256("reload-index"),
                dependencyGraphHash: .sha256("dependencies"),
                toolchainCapabilities: .init(
                    implicitDynamic: true,
                    privateImports: true,
                    dynamicReplacementChaining: true,
                    nativeInterposing: false,
                    canonicalSIL: true
                )
            )
            try manifest.validate()
            return .init(
                directory: directory,
                sourceURL: sourceURL,
                baseline: baseline,
                sourceID: sourceID,
                archive: archive,
                manifest: manifest,
                function: function
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func write(_ source: String) throws {
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
    }

    func request(
        revision: UInt64,
        generation: UInt64,
        restoredToBaseline: Bool = false
    ) async throws -> DevSession.BuildRequest {
        let snapshot = try await SourceSnapshot.Snapshotter(
            stabilityDelayNanoseconds: 0,
            maximumAttempts: 2
        ).capture(
            changedPaths: [sourceURL.path],
            manifest: manifest,
            revision: .init(rawValue: revision)
        )
        return .init(
            snapshot: snapshot,
            classification: .init(
                changedFiles: [sourceID],
                restoredToBaseline: restoredToBaseline ? [sourceID] : []
            ),
            generationID: .init(rawValue: generation),
            candidateFunctionKeys: [function.key],
            reason: restoredToBaseline ? .baselineRestored : .sourceSaved
        )
    }

    func offer(
        for patch: DevSession.BuiltPatch,
        revision: UInt64,
        generation: UInt64
    ) -> DevProtocol.PatchOffer {
        .init(
            sessionID: manifest.sessionBuildID,
            sourceRevision: .init(rawValue: revision),
            generationID: .init(rawValue: generation),
            backend: patch.backend,
            payloadByteLength: UInt64(patch.payload.count),
            payloadSHA256: .sha256(patch.payload),
            changedSources: [sourceID],
            changedFunctions: Array(patch.changedFunctions),
            restoredFunctions: Array(patch.restoredFunctions),
            mode: patch.mode
        )
    }
}

private struct NativeFixture {
    let directory: URL
    let sourceURL: URL
    let baseline: String
    let sourceID: LiveReload.SourceFileID
    let archive: InterfaceArchive.Archive
    let manifest: DevBuildManifest.Document
    let reloadIndex: ReloadIndex.Document
    let function: InterfaceArchive.FunctionRecord

    static func make() throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-native-compilation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let sourceURL = directory.appendingPathComponent("Feature.swift")
            let baseline = "public dynamic func transform(_ x: Int) -> Int { x + 1 }\n"
            try Data(baseline.utf8).write(to: sourceURL)
            let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            let compiler = ReleaseCompiler.Driver()
            let toolchain = try compiler.toolchainIdentity(compilerURL: compilerURL)
            let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
            let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
            let target = "arm64-apple-ios15.0-simulator"
            let module = "NativeCompilationFixture"
            let invocation = InterfaceArchive.FrontendInvocation(
                moduleName: module,
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone"
            )
            let parsed = try CanonicalSIL.File(
                text: frontend.emitCanonicalSIL(
                    sourceFiles: [sourceURL],
                    invocation: invocation
                )
            ).uniqueFunction(mangledNameContaining: "transform")
            let namespace = Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.native-compilation",
                buildNumber: "1",
                seed: "fixture"
            )
            let executableUUID = UUID()
            let metadata = InterfaceArchive.ReleaseMetadata(
                bundleID: "dev.helix.native-compilation",
                buildNumber: "1",
                shellNamespaceID: namespace,
                machOUUIDs: [executableUUID],
                targetTriple: target,
                minimumOS: .init(15),
                xcodeBuild: "fixture-Xcode",
                sdkBuild: sdk.buildVersion,
                frontendInvocation: invocation,
                transformPipelineHash: .sha256("native-compilation-transform"),
                sourceBaselineHash: .sha256("indexed-below")
            )
            let configuration = try PatchConfiguration.Document.parse(yaml: """
            schema: 1
            modules:
              \(module):
                include:
                  - Feature.swift
            """)
            let sourceHash = Core.Digest.sha256(Data(baseline.utf8))
            let archive = try ReleaseCompiler.Indexer().index(
                .init(
                    metadata: metadata,
                    compatibility: .init(
                        runtime: Core.Versions.runtime,
                        bytecode: Core.Versions.bytecode,
                        interfaceArchive: Core.Versions.interfaceArchive,
                        compilerFingerprint: toolchain.fingerprint
                    ),
                    configuration: configuration,
                    sources: [.init(logicalPath: "Feature.swift", contentHash: sourceHash)],
                    declarations: [
                        .init(
                            moduleName: module,
                            sourceFileLogicalID: "Feature.swift",
                            canonicalDeclaration: "func transform(_: Int) -> Int",
                            mangledName: parsed.mangledName,
                            role: .function,
                            loweredSignature: .init(
                                parameters: ["Swift.Int"],
                                result: "Swift.Int"
                            ),
                            parameterTypes: [.int64],
                            resultType: .int64,
                            interface: .init(
                                declarationKind: "function",
                                baseName: "transform",
                                argumentLabels: ["_"],
                                accessLevel: "public",
                                canonicalFormalType: "(Swift.Int) -> Swift.Int",
                                loweredSILType: parsed.loweredType
                            ),
                            canonicalSILBody: parsed.body
                        ),
                    ]
                )
            ).archive
            let function = try #require(archive.functions.first)
            let sourceID = LiveReload.SourceFileID.derive(logicalPath: "Feature.swift")
            let reloadIndex = ReloadIndex.Document(
                sourceRoots: [.init(sourceFileID: sourceID, roots: [function.key])],
                roots: [
                    .init(functionKey: function.key, nominalTypeID: nil, role: .modelOrService),
                ],
                nativeReplacements: [
                    .init(
                        functionKey: function.key,
                        sourceFileID: sourceID,
                        sourceDeclaration: .init(
                            identity: try #require(
                                SwiftFrontend.DynamicReplacement.declarationUSR(
                                    mangledName: parsed.mangledName
                                )
                            ),
                            kind: .function,
                            originalReference: "transform(_:)",
                            replacementHeader:
                                "public func replacementTransform(_ x: Int) -> Int",
                            members: [
                                .init(
                                    role: .functionBody,
                                    fallbackBody: "return transform(x)"
                                ),
                            ]
                        ),
                        memberRole: .functionBody,
                        declarationAnchor: "func transform(_ x: Int) -> Int {",
                        loweredType: parsed.loweredType
                    ),
                ]
            )
            let indexHash = try reloadIndex.contentHash()
            let baselineImage = directory.appendingPathComponent("lib\(module).dylib")
            let baselineModule = directory.appendingPathComponent("\(module).swiftmodule")
            let build = try ProcessExecution.Runner().run(
                executable: compilerURL,
                arguments: [
                    sourceURL.path,
                    "-emit-library", "-emit-module", "-module-name", module,
                    "-target", target, "-sdk", sdk.path, "-Onone",
                    "-Xfrontend", "-enable-implicit-dynamic",
                    "-Xfrontend", "-enable-private-imports",
                    "-emit-module-path", baselineModule.path,
                    "-Xlinker", "-install_name", "-Xlinker", "@rpath/lib\(module).dylib",
                    "-o", baselineImage.path,
                ],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: directory
            )
            guard build.status == 0 else {
                throw SwiftFrontend.Error.compilationFailed(
                    status: build.status,
                    diagnostics: build.standardError
                )
            }
            let manifest = DevBuildManifest.Document(
                sessionBuildID: UUID(),
                workspacePathHash: .sha256(directory.path),
                scheme: "Fixture",
                configuration: "Debug",
                bundleID: metadata.bundleID,
                executableUUID: executableUUID,
                moduleName: module,
                targetTriple: target,
                architecture: "arm64",
                platform: .iOSSimulator,
                minimumOS: .init(15),
                xcodeBuild: metadata.xcodeBuild,
                swiftCompilerFingerprint: toolchain.fingerprint,
                sdkBuild: sdk.buildVersion,
                frontendArguments: [
                    "-module-name", module, "-target", target,
                    "-sdk", sdk.path, "-Onone", "-enable-implicit-dynamic",
                    "-enable-private-imports",
                    "-I", directory.path, sourceURL.path,
                ],
                linkArguments: ["-L", directory.path, "-l\(module)"],
                moduleSearchPaths: [directory.path],
                sourceFiles: [
                    .init(
                        id: sourceID,
                        logicalPath: "Feature.swift",
                        absolutePath: sourceURL.path,
                        contentHash: sourceHash
                    ),
                ],
                buildProducts: [
                    .init(
                        kind: "dylib",
                        path: baselineImage.path,
                        contentHash: .sha256(try Data(contentsOf: baselineImage))
                    ),
                ],
                liveReloadIndexHash: indexHash,
                dependencyGraphHash: .sha256("native-dependencies"),
                toolchainCapabilities: .init(
                    implicitDynamic: true,
                    privateImports: true,
                    dynamicReplacementChaining: true,
                    nativeInterposing: false,
                    canonicalSIL: true
                )
            )
            try manifest.validate()
            return .init(
                directory: directory,
                sourceURL: sourceURL,
                baseline: baseline,
                sourceID: sourceID,
                archive: archive,
                manifest: manifest,
                reloadIndex: reloadIndex,
                function: function
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func write(_ source: String) throws {
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
    }

    func request(
        revision: UInt64,
        generation: UInt64,
        restoredToBaseline: Bool = false
    ) async throws -> DevSession.BuildRequest {
        let snapshot = try await SourceSnapshot.Snapshotter(
            stabilityDelayNanoseconds: 0,
            maximumAttempts: 2
        ).capture(
            changedPaths: [sourceURL.path],
            manifest: manifest,
            revision: .init(rawValue: revision)
        )
        return .init(
            snapshot: snapshot,
            classification: .init(
                changedFiles: [sourceID],
                restoredToBaseline: restoredToBaseline ? [sourceID] : []
            ),
            generationID: .init(rawValue: generation),
            candidateFunctionKeys: [function.key],
            reason: restoredToBaseline ? .baselineRestored : .sourceSaved
        )
    }

    func offer(
        for patch: DevSession.BuiltPatch,
        revision: UInt64,
        generation: UInt64
    ) -> DevProtocol.PatchOffer {
        .init(
            sessionID: manifest.sessionBuildID,
            sourceRevision: .init(rawValue: revision),
            generationID: .init(rawValue: generation),
            backend: patch.backend,
            payloadByteLength: UInt64(patch.payload.count),
            payloadSHA256: .sha256(patch.payload),
            changedSources: [sourceID],
            changedFunctions: Array(patch.changedFunctions),
            restoredFunctions: Array(patch.restoredFunctions),
            debugSymbolsUUID: patch.debugSymbolsUUID,
            reason: patch.restoredFunctions.isEmpty ? .sourceSaved : .baselineRestored,
            mode: patch.mode
        )
    }
}
