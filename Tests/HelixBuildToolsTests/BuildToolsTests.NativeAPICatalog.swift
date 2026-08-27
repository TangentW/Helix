import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Native API Catalog")
struct NativeAPICatalogTests {
    @Test("Catalog codec is canonical and validates stable keys")
    func canonicalCodec() throws {
        let entry = try swiftEntry()
        let document = NativeAPICatalog.Document(
            identity: identity(module: "Fixture"),
            entries: [entry]
        )
        let bytes = try NativeAPICatalog.Codec.encode(document)

        #expect(try NativeAPICatalog.Codec.decode(bytes) == document)

        let object = try JSONSerialization.jsonObject(with: bytes)
        let pretty = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        #expect(throws: NativeAPICatalog.Error.nonCanonical) {
            try NativeAPICatalog.Codec.decode(pretty)
        }

        var forged = entry
        forged.key = .init(rawValue: .sha256("forged"))
        #expect(throws: NativeAPICatalog.Error.self) {
            try NativeAPICatalog.Document(
                identity: identity(module: "Fixture"),
                entries: [forged]
            ).validate()
        }
    }

    @Test("Registry resolves key, Swift spelling, and native entry point")
    func registryIndexes() throws {
        let swift = try swiftEntry()
        let objectiveC = try objectiveCEntry()
        let registry = try NativeAPICatalog.Registry(documents: [
            .init(identity: identity(module: "Fixture"), entries: [swift]),
            .init(identity: identity(module: "UIKit"), entries: [objectiveC]),
        ])

        #expect(registry.count == 2)
        #expect(registry[swift.key] == swift)
        #expect(registry.entries(swiftName: "Fixture.increment(_:)") == [swift])
        #expect(registry.entries(
            compilerSymbol: "$s7Fixture9incrementyS2iF"
        ) == [swift])
        #expect(registry.entries(
            backend: .objectiveCMessage,
            module: "UIKit",
            owner: "UIViewController",
            entryPoint: "presentViewController:animated:completion:"
        ) == [objectiveC])
        #expect(try registry.resolve(descriptor: objectiveC.descriptor) == objectiveC)
    }

    @Test("Registry rejects two catalogs that disagree outside a stable key")
    func rejectsConflictingRecords() throws {
        let original = try swiftEntry()
        var conflicting = original
        conflicting.swiftNames.append("Fixture.alternateName(_:)")
        conflicting.swiftNames.sort()

        #expect(throws: NativeAPICatalog.Error.conflictingEntry(original.key)) {
            try NativeAPICatalog.Registry(documents: [
                .init(
                    identity: identity(module: "Fixture", content: "first"),
                    entries: [original]
                ),
                .init(
                    identity: identity(module: "Fixture", content: "second"),
                    entries: [conflicting]
                ),
            ])
        }
    }

    @Test("Registry loading is idempotent but one identity cannot name two snapshots")
    func registryIdentityConsistency() throws {
        let original = try swiftEntry()
        let document = NativeAPICatalog.Document(
            identity: identity(module: "Fixture"),
            entries: [original]
        )
        let registry = try NativeAPICatalog.Registry(documents: [
            document, document,
        ])
        #expect(registry.count == 1)

        var different = original
        different.compilerSymbols.append("$s7Fixture9alternateyS2iF")
        different.compilerSymbols.sort()
        let conflicting = NativeAPICatalog.Document(
            identity: document.identity,
            entries: [different]
        )
        #expect(throws: NativeAPICatalog.Error.conflictingDocumentIdentity(
            document.identity.cacheKey
        )) {
            try NativeAPICatalog.Registry(documents: [document, conflicting])
        }
    }

    @Test("Unsupported APIs carry a precise reason and no executable binding")
    func unsupportedEntry() throws {
        let base = try swiftEntry()
        let unsupported = try NativeAPICatalog.Entry(
            descriptor: base.descriptor,
            contract: base.contract,
            support: .unsupported(
                code: "NATIVE-GENERIC-ABI",
                explanation: "The unspecialized generic Swift ABI cannot be invoked safely."
            ),
            binding: nil
        )
        let document = NativeAPICatalog.Document(
            identity: identity(module: "Fixture"),
            entries: [unsupported]
        )
        try document.validate()

        var invalid = unsupported
        invalid.binding = .init(
            strategy: .swiftAdapter,
            adapterID: "Fixture.unsupported"
        )
        #expect(throws: NativeAPICatalog.Error.self) {
            try NativeAPICatalog.Document(
                identity: identity(module: "Fixture"),
                entries: [invalid]
            ).validate()
        }
    }

    @Test("Contracts and executable bindings are validated at the catalog boundary")
    func validatesContractAndBindingAuthority() throws {
        let entry = try swiftEntry()

        var mismatchedContract = entry
        mismatchedContract.contract.callbacks = [
            .init(parameterIndex: 0, lifetime: .escaping),
        ]
        #expect(throws: NativeAPICatalog.Error.self) {
            try NativeAPICatalog.Document(
                identity: identity(module: "Fixture"),
                entries: [mismatchedContract]
            ).validate()
        }

        var missingTargetModule = entry
        missingTargetModule.binding?.importedModules = ["Foundation"]
        #expect(throws: NativeAPICatalog.Error.self) {
            try NativeAPICatalog.Document(
                identity: identity(module: "Fixture"),
                entries: [missingTargetModule]
            ).validate()
        }
    }

    @Test("Catalog cache identity includes toolchain, target, and module content")
    func cacheIdentity() {
        let base = identity(module: "Fixture", content: "one")
        var changedContent = base
        changedContent.moduleContentHash = .sha256("two")
        var changedTarget = base
        changedTarget.targetTriple = "arm64-apple-ios18.0-simulator"
        var changedSearchPath = base
        changedSearchPath.moduleSearchPathHash = .sha256("other-search-path")

        #expect(base.cacheKey != changedContent.cacheKey)
        #expect(base.cacheKey != changedTarget.cacheKey)
        #expect(base.cacheKey != changedSearchPath.cacheKey)
    }

    @Test("Catalog cache identity ignores physical module locations only")
    func normalizesModuleLoadingPaths() {
        let first = NativeAPICatalog.Builder.cacheIdentityArguments([
            "-I", "/First/SwiftModules",
            "-F/First/Frameworks",
            "-Xcc", "-I", "-Xcc", "/First/ClangHeaders",
            "-Xcc", "-isystem/First/SystemHeaders",
            "-Xcc", "-fmodule-map-file=/First/Modules/module.modulemap",
            "-Xcc", "-fmodule-file=Dependency=/First/Modules/Dependency.pcm",
            "-module-cache-path", "/First/ModuleCache",
            "-Xcc", "-fmodules-cache-path=/First/ClangModuleCache",
            "-Xcc", "-fmodules-cache-path", "-Xcc",
            "/First/OtherClangModuleCache",
            "-Xcc", "-DHELIX_FEATURE=1",
        ])
        let second = NativeAPICatalog.Builder.cacheIdentityArguments([
            "-I", "/Second/SwiftModules",
            "-F/Second/Frameworks",
            "-Xcc", "-I", "-Xcc", "/Second/ClangHeaders",
            "-Xcc", "-isystem/Second/SystemHeaders",
            "-Xcc", "-fmodule-map-file=/Second/Modules/module.modulemap",
            "-Xcc", "-fmodule-file=Dependency=/Second/Modules/Dependency.pcm",
            "-module-cache-path", "/Second/ModuleCache",
            "-Xcc", "-fmodules-cache-path=/Second/ClangModuleCache",
            "-Xcc", "-fmodules-cache-path", "-Xcc",
            "/Second/OtherClangModuleCache",
            "-Xcc", "-DHELIX_FEATURE=1",
        ])
        let differentMacro = NativeAPICatalog.Builder.cacheIdentityArguments([
            "-I", "/Second/SwiftModules",
            "-F/Second/Frameworks",
            "-Xcc", "-I", "-Xcc", "/Second/ClangHeaders",
            "-Xcc", "-isystem/Second/SystemHeaders",
            "-Xcc", "-fmodule-map-file=/Second/Modules/module.modulemap",
            "-Xcc", "-fmodule-file=Dependency=/Second/Modules/Dependency.pcm",
            "-module-cache-path", "/Second/ModuleCache",
            "-Xcc", "-fmodules-cache-path=/Second/ClangModuleCache",
            "-Xcc", "-fmodules-cache-path", "-Xcc",
            "/Second/OtherClangModuleCache",
            "-Xcc", "-DHELIX_FEATURE=2",
        ])

        #expect(first == second)
        #expect(first != differentMacro)
        #expect(first.contains("-DHELIX_FEATURE=1"))
        #expect(!first.contains { $0.contains("/First/") })
        #expect(
            NativeAPICatalog.Builder.cacheIdentityArguments([
                "-module-cache-path",
            ]) != NativeAPICatalog.Builder.cacheIdentityArguments([])
        )
    }

    @Test("Catalog planning is automatic, portable, and fail-closed")
    func plansImportedModuleCatalogs() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-native-catalog-plan-\(UUID().uuidString)",
            isDirectory: true
        )
        let firstRoot = root.appendingPathComponent("First", isDirectory: true)
        let copiedRoot = root.appendingPathComponent("Copied", isDirectory: true)
        for directory in [firstRoot, copiedRoot] {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        defer { try? manager.removeItem(at: root) }
        let moduleName = "AnalyticsKit"
        let moduleBytes = Data("analytics-interface-v1".utf8)
        try moduleBytes.write(
            to: firstRoot.appendingPathComponent("\(moduleName).swiftmodule")
        )
        try moduleBytes.write(
            to: copiedRoot.appendingPathComponent("\(moduleName).swiftmodule")
        )
        let toolchain = ReleaseCompiler.ToolchainIdentity(
            fingerprint: "swift-test-fingerprint",
            versionOutput: "Swift test",
            targetInfo: "{}",
            compilerBinaryHash: .sha256("swiftc")
        )
        let sdk = SwiftFrontend.Driver.SDKIdentity(
            name: "iphonesimulator",
            path: "/Fixture/SDK",
            buildVersion: "23A340"
        )
        func plan(searchRoot: URL) throws -> NativeAPICatalog.BuildPlan {
            let semanticArguments = [
                "-parse-as-library", "-swift-version", "6",
                "-I", searchRoot.path, "-D", "FEATURE",
            ]
            let invocation = InterfaceArchive.FrontendInvocation(
                moduleName: "Feature",
                targetTriple: "arm64-apple-ios18.0-simulator",
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: semanticArguments
            )
            let metadata = InterfaceArchive.ReleaseMetadata(
                bundleID: "dev.helix.catalog-plan",
                buildNumber: "1",
                shellNamespaceID: .derive(
                    bundleID: "dev.helix.catalog-plan",
                    buildNumber: "1",
                    seed: "fixture"
                ),
                machOUUIDs: [],
                targetTriple: invocation.targetTriple,
                minimumOS: .init(15),
                xcodeBuild: "17A400",
                sdkBuild: sdk.buildVersion,
                frontendInvocation: invocation,
                transformPipelineHash: ShellBuild.transformPipelineHash,
                sourceBaselineHash: .sha256("sources")
            )
            let compilerArguments = ["-I", searchRoot.path]
            let inputs = BuildCache.CompilerInputs.capture(
                arguments: compilerArguments,
                currentModuleName: invocation.moduleName,
                workingDirectory: root,
                importedModules: [moduleName]
            )
            return try NativeAPICatalog.Planner().plan(.init(
                metadata: metadata,
                importedModules: [
                    "Swift", "UIKit", moduleName, "Feature.Helpers",
                ],
                compilerArguments: compilerArguments,
                compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"),
                workingDirectory: root,
                toolchain: toolchain,
                sdk: sdk,
                compilerInputs: inputs
            ))
        }

        let first = try plan(searchRoot: firstRoot)
        let copied = try plan(searchRoot: copiedRoot)
        let firstByModule = Dictionary(uniqueKeysWithValues: first.requests.map {
            ($0.identity.moduleName, $0.identity)
        })
        let copiedByModule = Dictionary(uniqueKeysWithValues: copied.requests.map {
            ($0.identity.moduleName, $0.identity)
        })

        #expect(first.unresolvedModules.isEmpty)
        #expect(Set(firstByModule.keys) == ["AnalyticsKit", "UIKit"])
        #expect(firstByModule == copiedByModule)
        #expect(firstByModule["AnalyticsKit"]?.provenance == .thirdPartyModule)
        #expect(firstByModule["UIKit"]?.provenance == .systemSDK)

        try Data("analytics-interface-v2".utf8).write(
            to: copiedRoot.appendingPathComponent("\(moduleName).swiftmodule")
        )
        let changed = try plan(searchRoot: copiedRoot)
        let changedByModule = Dictionary(uniqueKeysWithValues: changed.requests.map {
            ($0.identity.moduleName, $0.identity)
        })
        #expect(
            changedByModule["AnalyticsKit"]
                != firstByModule["AnalyticsKit"]
        )
        #expect(changedByModule["UIKit"] == firstByModule["UIKit"])

        var incompleteInputs = BuildCache.CompilerInputs.capture(
            arguments: ["-I"],
            currentModuleName: "Feature",
            workingDirectory: root,
            importedModules: [moduleName]
        )
        incompleteInputs.isComplete = false
        var incompleteRequest = try #require(first.requests.first).frontendInvocation
        incompleteRequest.moduleName = "Feature"
        let incompleteMetadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.catalog-plan",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.catalog-plan",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: incompleteRequest.targetTriple,
            minimumOS: .init(15),
            xcodeBuild: "17A400",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: incompleteRequest,
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("sources")
        )
        let unresolved = try NativeAPICatalog.Planner().plan(.init(
            metadata: incompleteMetadata,
            importedModules: ["UIKit", moduleName],
            compilerArguments: ["-I"],
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"),
            workingDirectory: root,
            toolchain: toolchain,
            sdk: sdk,
            compilerInputs: incompleteInputs
        ))
        #expect(unresolved.requests.isEmpty)
        #expect(unresolved.unresolvedModules == ["AnalyticsKit", "UIKit"])
    }

    @Test("Catalog keeps distinct logical APIs that share one Swift implementation")
    func projectsSharedSwiftImplementation() throws {
        let moduleName = "Fixture"
        let sourceID = NativeAPICatalog.Projector.sourceFileLogicalID(
            moduleName: moduleName
        )
        let typeNames = ["Fixture.First", "Fixture.Second"]
        let types = try FrontendReceipt.Adapter().mergeImportedNativeTypes(
            discoveredTypes: [],
            operationTypes: typeNames.map { name in
                .init(
                    canonicalName: name,
                    swiftType: name,
                    kind: .value,
                    aliases: [String(name.split(separator: ".").last!)],
                    representation: .opaqueValue,
                    sourceFileLogicalID: sourceID,
                    importedModules: [moduleName],
                    requiresMainActor: false
                )
            }
        )
        let sharedSymbol = "$ss20_SwiftNewtypeWrapperPsSHRzSH8RawValueSYRpzrlE04hashE0Sivg"
        let operations = try FrontendReceipt.Adapter().mergeImportedOperations(
            typeNames.enumerated().map { index, name in
                .init(
                    silReferences: [sharedSymbol],
                    sourceFileLogicalID: sourceID,
                    importedModules: [moduleName],
                    dispatch: .instanceGetter,
                    ownerType: name,
                    baseName: "hashValue",
                    argumentLabels: [],
                    parameterSwiftTypes: [name],
                    resultSwiftType: "Swift.Int",
                    requiresMainActor: false,
                    declarationUSR: "s:7Fixture6Value\(index)V9hashValueSivp",
                    isolationEvidence: .importedDeclaration,
                    isEmittedToDevice: false
                )
            }
        )
        let projection = NativeAPICatalog.CompilerProjection(
            sourceFileLogicalID: sourceID,
            importedTypes: types,
            operations: operations,
            modulesByDeclarationUSR: Dictionary(uniqueKeysWithValues:
                operations.compactMap { operation in
                    operation.declarationUSR.map { ($0, moduleName) }
                }
            )
        )
        let catalogIdentity = identity(module: moduleName)
        let entries = try NativeAPICatalog.Projector.entries(
            projection: projection,
            identity: catalogIdentity,
            invocation: .init(
                moduleName: "CatalogConsumer",
                targetTriple: catalogIdentity.targetTriple,
                sdkName: "iphoneos",
                sdkBuild: catalogIdentity.sdkProductBuild,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            )
        )

        #expect(entries.count == 2)
        #expect(Set(entries.map(\.descriptor.canonicalCallee)) == [
            "Fixture.First.hashValue.get",
            "Fixture.Second.hashValue.get",
        ])
        #expect(entries.allSatisfy {
            $0.compilerSymbols.contains(sharedSymbol)
                && $0.binding?.strategy == .swiftAdapter
        })
    }

    @Test("Catalog omits protocol defaults declared by another Swift module")
    func omitsForeignProtocolDefaults() throws {
        let moduleName = "Fixture"
        let sourceID = NativeAPICatalog.Projector.sourceFileLogicalID(
            moduleName: moduleName
        )
        let type = FrontendReceipt.Adapter.ImportedNativeType(
            canonicalName: "Fixture.Wrapped",
            swiftType: "Fixture.Wrapped",
            kind: .value,
            aliases: ["Wrapped"],
            representation: .opaqueValue,
            sourceFileLogicalID: sourceID,
            importedModules: [moduleName],
            requiresMainActor: false
        )
        let usr = "s:8OtherKit8HashableP9hashValueSivg"
        let operation = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: [
                "$ss8HashableP9hashValueSivg",
            ],
            sourceFileLogicalID: sourceID,
            importedModules: [moduleName],
            dispatch: .instanceGetter,
            ownerType: type.swiftType,
            baseName: "hashValue",
            argumentLabels: [],
            parameterSwiftTypes: [type.swiftType],
            resultSwiftType: "Swift.Int",
            requiresMainActor: false,
            declarationUSR: usr,
            isolationEvidence: .importedDeclaration,
            isEmittedToDevice: false
        )
        let projection = NativeAPICatalog.CompilerProjection(
            sourceFileLogicalID: sourceID,
            importedTypes: [type],
            operations: [operation],
            modulesByDeclarationUSR: [usr: moduleName]
        )
        let catalogIdentity = identity(module: moduleName)

        let projected = try NativeAPICatalog.Projector.project(
            projection: projection,
            identity: catalogIdentity,
            invocation: .init(
                moduleName: "CatalogConsumer",
                targetTriple: catalogIdentity.targetTriple,
                sdkName: "iphonesimulator",
                sdkBuild: catalogIdentity.sdkProductBuild,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            )
        )
        #expect(projected.entries.isEmpty)
        #expect(projected.importedTypes.isEmpty)
        #expect(projected.operations.isEmpty)
        #expect(projected.referencedModules == ["OtherKit"])
    }

    @Test("Frontend consumes exact Catalog snapshots and production fails closed")
    func consumesCatalogSnapshots() throws {
        let moduleName = "Fixture"
        let sourceID = NativeAPICatalog.Projector.sourceFileLogicalID(
            moduleName: moduleName
        )
        let type = FrontendReceipt.Adapter.ImportedNativeType(
            canonicalName: "Fixture.Counter",
            swiftType: "Fixture.Counter",
            kind: .value,
            aliases: ["Counter"],
            representation: .opaqueValue,
            sourceFileLogicalID: sourceID,
            importedModules: [moduleName],
            requiresMainActor: false
        )
        let usr = "s:7Fixture7CounterV5valueSivg"
        let operation = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: ["$s7Fixture7CounterV5valueSivg"],
            sourceFileLogicalID: sourceID,
            importedModules: [moduleName],
            dispatch: .instanceGetter,
            ownerType: type.swiftType,
            baseName: "value",
            argumentLabels: [],
            parameterSwiftTypes: [type.swiftType],
            resultSwiftType: "Swift.Int",
            requiresMainActor: false,
            declarationUSR: usr,
            isolationEvidence: .importedDeclaration,
            isEmittedToDevice: false
        )
        let projection = NativeAPICatalog.CompilerProjection(
            sourceFileLogicalID: sourceID,
            importedTypes: [type],
            operations: [operation],
            modulesByDeclarationUSR: [usr: moduleName]
        )
        let catalogIdentity = identity(module: moduleName)
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: "CatalogConsumer",
            targetTriple: catalogIdentity.targetTriple,
            sdkName: "iphonesimulator",
            sdkBuild: catalogIdentity.sdkProductBuild,
            optimization: "-Onone",
            semanticArguments: [
                "-parse-as-library", "-swift-version", "6",
            ]
        )
        let document = NativeAPICatalog.Document(
            identity: catalogIdentity,
            entries: try NativeAPICatalog.Projector.entries(
                projection: projection,
                identity: catalogIdentity,
                invocation: invocation
            )
        )
        let snapshot = NativeAPICatalog.Snapshot(
            document: document,
            compilerProjection: projection
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.catalog-consumer",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.catalog-consumer",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: catalogIdentity.targetTriple,
            minimumOS: catalogIdentity.minimumDeployment,
            xcodeBuild: catalogIdentity.xcodeProductBuild,
            sdkBuild: catalogIdentity.sdkProductBuild,
            frontendInvocation: invocation,
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("fixture")
        )
        let toolchain = ReleaseCompiler.ToolchainIdentity(
            fingerprint: catalogIdentity.compilerFingerprint,
            versionOutput: "fixture",
            targetInfo: "fixture",
            compilerBinaryHash: .sha256("fixture")
        )
        let production = FrontendReceipt.Request(
            metadata: metadata,
            configuration: .automaticProjectPolicy(
                moduleName: invocation.moduleName
            ),
            sources: [],
            nativeAPICatalogs: [snapshot],
            callingSurfacePolicy: .managedProductionModule
        )
        let resolution = try FrontendReceipt.CatalogSurface.resolve(
            snapshots: production.nativeAPICatalogs,
            request: production,
            importedModules: [moduleName],
            toolchain: toolchain
        )
        #expect(resolution.hitModules == [moduleName])
        #expect(resolution.missingModules.isEmpty)
        var catalogOperation = operation
        catalogOperation.catalogEntry = document.entries.first
        #expect(resolution.operations == [catalogOperation])
        #expect(resolution.documents == [document])

        var missingProduction = production
        missingProduction.nativeAPICatalogs = []
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.CatalogSurface.resolve(
                snapshots: [],
                request: missingProduction,
                importedModules: [moduleName],
                toolchain: toolchain
            )
        }
        missingProduction.callingSurfacePolicy = .managedDevelopmentModule
        let development = try FrontendReceipt.CatalogSurface.resolve(
            snapshots: [],
            request: missingProduction,
            importedModules: [moduleName],
            toolchain: toolchain
        )
        #expect(development.hitModules.isEmpty)
        #expect(development.missingModules == [moduleName])

        var redundantProjection = projection
        redundantProjection.importedTypes.append(.init(
            canonicalName: "Fixture.Unused",
            swiftType: "Fixture.Unused",
            kind: .value,
            aliases: ["Unused"],
            representation: .opaqueValue,
            sourceFileLogicalID: sourceID,
            importedModules: [moduleName],
            requiresMainActor: false
        ))
        redundantProjection.importedTypes.sort {
            ($0.canonicalName, $0.swiftType)
                < ($1.canonicalName, $1.swiftType)
        }
        let redundantSnapshot = NativeAPICatalog.Snapshot(
            document: document,
            compilerProjection: redundantProjection
        )
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.CatalogSurface.resolve(
                snapshots: [redundantSnapshot],
                request: production,
                importedModules: [moduleName],
                toolchain: toolchain
            )
        }
    }

    @Test("Catalog prewarm jobs are canonical and compiler-bound")
    func validatesPrewarmJobs() throws {
        let catalogIdentity = identity(module: "Fixture")
        let toolchain = ReleaseCompiler.ToolchainIdentity(
            fingerprint: catalogIdentity.compilerFingerprint,
            versionOutput: "fixture",
            targetInfo: "fixture",
            compilerBinaryHash: .sha256("fixture")
        )
        let workingDirectory = URL(fileURLWithPath: "/tmp/helix-work")
        let request = NativeAPICatalog.BuildRequest(
            identity: catalogIdentity,
            frontendInvocation: .init(
                moduleName: "CatalogConsumer",
                targetTriple: catalogIdentity.targetTriple,
                sdkName: "iphoneos",
                sdkBuild: catalogIdentity.sdkProductBuild,
                optimization: "-Onone",
                semanticArguments: [
                    "-parse-as-library", "-swift-version", "6",
                ]
            ),
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"),
            workingDirectoryURL: workingDirectory,
            precomputedToolchain: toolchain,
            precomputedSDK: .init(
                name: "iphoneos",
                path: "/tmp/SDK",
                buildVersion: catalogIdentity.sdkProductBuild
            )
        )
        let job = NativeAPICatalog.PrewarmJob(
            cacheRootURL: URL(fileURLWithPath: "/tmp/helix-cache"),
            workingDirectoryURL: workingDirectory,
            planRequest: .init(
                metadata: .init(
                    bundleID: "dev.helix.prewarm",
                    buildNumber: "1",
                    shellNamespaceID: .derive(
                        bundleID: "dev.helix.prewarm",
                        buildNumber: "1",
                        seed: "fixture"
                    ),
                    machOUUIDs: [],
                    targetTriple: catalogIdentity.targetTriple,
                    minimumOS: catalogIdentity.minimumDeployment,
                    xcodeBuild: catalogIdentity.xcodeProductBuild,
                    sdkBuild: catalogIdentity.sdkProductBuild,
                    frontendInvocation: request.frontendInvocation,
                    transformPipelineHash: ShellBuild.transformPipelineHash,
                    sourceBaselineHash: .sha256("fixture")
                ),
                importedModules: [catalogIdentity.moduleName],
                compilerArguments: [],
                compilerURL: request.compilerURL,
                workingDirectory: workingDirectory,
                toolchain: toolchain,
                sdk: try #require(request.precomputedSDK),
                compilerInputs: .init(
                    importedModules: [catalogIdentity.moduleName],
                    searchRoots: [],
                    explicitPaths: [],
                    fileCount: 0,
                    byteCount: 0,
                    contentHash: .sha256("fixture"),
                    isComplete: true
                )
            ),
            requests: [request]
        )
        let data = try NativeAPICatalog.PrewarmJobCodec.encode(job)
        let decoded = try NativeAPICatalog.PrewarmJobCodec.decode(data)
        #expect(decoded.cacheRootPath == job.cacheRootPath)
        #expect(decoded.requests.map(\.identity) == [catalogIdentity])
        #expect(throws: NativeAPICatalog.Error.self) {
            var invalid = decoded
            invalid.requests[0].precomputedSDK = nil
            _ = try NativeAPICatalog.PrewarmJobCodec.encode(invalid)
        }
        #expect(throws: NativeAPICatalog.Error.self) {
            var invalid = decoded
            invalid.requests[0].compilerURL = URL(
                fileURLWithPath: "/tmp/untrusted-swiftc"
            )
            _ = try NativeAPICatalog.PrewarmJobCodec.encode(invalid)
        }
        #expect(throws: NativeAPICatalog.Error.self) {
            var invalid = decoded
            invalid.planRequest.compilerInputs.isComplete = false
            _ = try NativeAPICatalog.PrewarmJobCodec.encode(invalid)
        }
    }

    @Test("Module Catalog is compiler-proven and reused across projects")
    func buildsAndReusesModuleCatalog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-native-api-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstSearchPath = directory.appendingPathComponent(
            "FirstSearchPath",
            isDirectory: true
        )
        let secondSearchPath = directory.appendingPathComponent(
            "SecondSearchPath",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstSearchPath,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: secondSearchPath,
            withIntermediateDirectories: false
        )
        let moduleName = "CatalogFixture"
        let source = Data(
            """
            public final class Payload {
                public init() {}
            }
            public struct Dormant {}
            public final class Transformer {
                public init() {}
                public func transform(_ value: Payload) -> Payload { value }
            }
            public func increment(_ value: Int) -> Int { value + 1 }
            """.utf8
        )
        let sourceURL = firstSearchPath.appendingPathComponent("Fixture.swift")
        try source.write(to: sourceURL)
        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let target = "arm64-apple-ios15.0-simulator"
        let compilation = try frontend.run(arguments: [
            sourceURL.path,
            "-emit-module", "-parse-as-library",
            "-module-name", moduleName,
            "-target", target,
            "-sdk", sdk.path,
            "-emit-module-path", firstSearchPath.appendingPathComponent(
                "\(moduleName).swiftmodule"
            ).path,
        ])
        guard compilation.terminationStatus == 0 else {
            throw FrontendReceipt.Error.frontendFailed(
                compilation.standardError
            )
        }
        try FileManager.default.copyItem(
            at: firstSearchPath.appendingPathComponent(
                "\(moduleName).swiftmodule"
            ),
            to: secondSearchPath.appendingPathComponent(
                "\(moduleName).swiftmodule"
            )
        )
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
            compilerURL: compilerURL
        )
        let identity = NativeAPICatalog.Identity(
            provenance: .thirdPartyModule,
            xcodeProductBuild: "integration-test",
            sdkProductBuild: sdk.buildVersion,
            compilerFingerprint: toolchain.fingerprint,
            targetTriple: target,
            minimumDeployment: .init(15),
            swiftLanguageMode: "5",
            moduleName: moduleName,
            moduleContentHash: .sha256(source),
            moduleSearchPathHash: .sha256("one equivalent module search slot"),
            dependencyGraphHash: .sha256("none")
        )
        func invocation(
            consumer: String,
            condition: String,
            searchPath: URL
        ) -> InterfaceArchive.FrontendInvocation {
            .init(
                moduleName: consumer,
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: [
                    "-parse-as-library", "-I", searchPath.path,
                    "-D", condition,
                ]
            )
        }
        let builder = NativeAPICatalog.Builder(cache: try .init(
            rootURL: directory.appendingPathComponent("Cache")
        ))
        let firstRequest = NativeAPICatalog.BuildRequest(
            identity: identity,
            frontendInvocation: invocation(
                consumer: "FirstApplication",
                condition: "SHARED_PROJECT",
                searchPath: firstSearchPath
            ),
            compilerURL: compilerURL,
            precomputedToolchain: toolchain,
            precomputedSDK: sdk
        )
        #expect(try builder.cached(firstRequest) == nil)
        let first = try builder.build(firstRequest)
        let secondRequest = NativeAPICatalog.BuildRequest(
            identity: identity,
            frontendInvocation: invocation(
                consumer: "SecondApplication",
                condition: "SHARED_PROJECT",
                searchPath: secondSearchPath
            ),
            compilerURL: compilerURL,
            precomputedToolchain: toolchain,
            precomputedSDK: sdk
        )
        let cachedSecond = try builder.cached(secondRequest)
        let second = try #require(cachedSecond)
        #expect(try builder.cached(.init(
            identity: identity,
            frontendInvocation: invocation(
                consumer: "ThirdApplication",
                condition: "DIFFERENT_PROJECT",
                searchPath: secondSearchPath
            ),
            compilerURL: compilerURL,
            precomputedToolchain: toolchain,
            precomputedSDK: sdk
        )) == nil)

        #expect(first.metrics.cacheSource == .generated)
        #expect(second.metrics.cacheSource == .hit)
        #expect(first.metrics.probeAttemptCount > 0)
        #expect(second.metrics.symbolGraphCacheHitCount == 0)
        #expect(second.metrics.symbolGraphCacheMissCount == 0)
        #expect(second.metrics.probeCacheHitCount == 0)
        #expect(second.metrics.probeCacheMissCount == 0)
        #expect(second.metrics.probeAttemptCount == 0)
        #expect(second.snapshot.document == first.snapshot.document)
        #expect(second.snapshot.compilerProjection
            == first.snapshot.compilerProjection)
        #expect(first.snapshot.document.entries.contains {
            $0.descriptor.canonicalCallee
                == "CatalogFixture.Transformer.transform(_:).call"
                && $0.binding?.strategy == .swiftAdapter
        })
        #expect(first.snapshot.document.entries.contains {
            $0.descriptor.canonicalCallee
                == "CatalogFixture.increment(_:).call"
                && $0.binding?.strategy == .swiftAdapter
        })
        #expect(first.metrics.entryCount > 0)
        #expect(first.metrics.candidateCount >= first.metrics.entryCount)
        #expect(first.snapshot.compilerProjection.importedTypes.contains {
            $0.canonicalName == "CatalogFixture.Payload"
        })
        #expect(!first.snapshot.compilerProjection.importedTypes.contains {
            $0.canonicalName == "CatalogFixture.Dormant"
        })
        try first.snapshot.document.validate()

        var mismatchedIdentity = identity
        mismatchedIdentity.targetTriple = "x86_64-apple-ios15.0-simulator"
        #expect(throws: NativeAPICatalog.Error.self) {
            _ = try builder.build(.init(
                identity: mismatchedIdentity,
                frontendInvocation: invocation(
                    consumer: "MismatchedApplication",
                    condition: "MISMATCHED_PROJECT",
                    searchPath: firstSearchPath
                ),
                compilerURL: compilerURL,
                precomputedToolchain: toolchain
            ))
        }
    }

    @Test("Module Catalog classifies Objective-C messages and C functions")
    func buildsClangModuleCatalog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-native-clang-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let moduleName = "CatalogForeign"
        let header = Data(
            """
            #import <Foundation/Foundation.h>

            NS_ASSUME_NONNULL_BEGIN
            @interface CatalogObject : NSObject
            - (NSInteger)increment:(NSInteger)value;
            - (void)performWithCompletion:(void (^)(BOOL finished))completion;
            @end

            FOUNDATION_EXPORT NSInteger CatalogAdd(NSInteger lhs, NSInteger rhs);
            NS_ASSUME_NONNULL_END
            """.utf8
        )
        let moduleMap = Data(
            """
            module CatalogForeign {
              header "CatalogForeign.h"
              export *
            }
            """.utf8
        )
        let headerURL = directory.appendingPathComponent("CatalogForeign.h")
        let moduleMapURL = directory.appendingPathComponent("module.modulemap")
        try header.write(to: headerURL)
        try moduleMap.write(to: moduleMapURL)
        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
            compilerURL: compilerURL
        )
        let target = "arm64-apple-ios15.0-simulator"
        var content = Data()
        content.append(header)
        content.append(moduleMap)
        let identity = NativeAPICatalog.Identity(
            provenance: .thirdPartyModule,
            xcodeProductBuild: "integration-test",
            sdkProductBuild: sdk.buildVersion,
            compilerFingerprint: toolchain.fingerprint,
            targetTriple: target,
            minimumDeployment: .init(15),
            swiftLanguageMode: "5",
            moduleName: moduleName,
            moduleContentHash: .sha256(content),
            moduleSearchPathHash: .sha256(directory.path),
            dependencyGraphHash: .sha256("Foundation")
        )
        let output = try NativeAPICatalog.Builder(cache: .init(
            rootURL: directory.appendingPathComponent("Cache")
        )).build(.init(
            identity: identity,
            frontendInvocation: .init(
                moduleName: "ForeignConsumer",
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: [
                    "-parse-as-library", "-I", directory.path,
                    "-Xcc", "-fmodule-map-file=\(moduleMapURL.path)",
                ]
            ),
            compilerURL: compilerURL,
            precomputedToolchain: toolchain
        ))

        let objectiveC = try #require(output.snapshot.document.entries.first {
            $0.descriptor.target.backend == .objectiveCMessage
                && $0.descriptor.target.entryPoint == "increment:"
        })
        #expect(objectiveC.binding?.strategy == .objectiveCInvoker)
        #expect(objectiveC.binding?.adapterID == nil)
        let cFunction = try #require(output.snapshot.document.entries.first {
            $0.descriptor.target.backend == .cFunction
                && $0.descriptor.target.entryPoint == "CatalogAdd"
        })
        #expect(cFunction.binding?.strategy == .cInvoker)
        #expect(cFunction.binding?.adapterID == nil)
        #expect(output.snapshot.document.entries.contains {
            $0.descriptor.target.backend == .objectiveCMessage
                && $0.descriptor.target.entryPoint
                    == "performWithCompletion:"
                && $0.descriptor.logicalSignature.parameters.contains {
                    $0.callbackLifetime == .escaping
                }
        })
        try output.snapshot.document.validate()
    }

    @Test("Parallel Catalog probes produce deterministic documents")
    func parallelCatalogProbesAreDeterministic() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-parallel-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let moduleName = "ParallelCatalogFixture"
        let source = Data((0..<260).map { index in
            "public func value\(index)(_ input: Int) -> Int { input + \(index) }"
        }.joined(separator: "\n").utf8)
        let sourceURL = directory.appendingPathComponent("Fixture.swift")
        try source.write(to: sourceURL)
        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let target = "arm64-apple-ios15.0-simulator"
        let compilation = try frontend.run(arguments: [
            sourceURL.path,
            "-emit-module", "-parse-as-library",
            "-module-name", moduleName,
            "-target", target,
            "-sdk", sdk.path,
            "-emit-module-path", directory.appendingPathComponent(
                "\(moduleName).swiftmodule"
            ).path,
        ])
        guard compilation.terminationStatus == 0 else {
            throw FrontendReceipt.Error.frontendFailed(
                compilation.standardError
            )
        }
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
            compilerURL: compilerURL
        )
        let identity = NativeAPICatalog.Identity(
            provenance: .thirdPartyModule,
            xcodeProductBuild: "integration-test",
            sdkProductBuild: sdk.buildVersion,
            compilerFingerprint: toolchain.fingerprint,
            targetTriple: target,
            minimumDeployment: .init(15),
            swiftLanguageMode: "5",
            moduleName: moduleName,
            moduleContentHash: .sha256(source),
            moduleSearchPathHash: .sha256("parallel-fixture-search"),
            dependencyGraphHash: .sha256("none")
        )
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: "ParallelCatalogConsumer",
            targetTriple: target,
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion,
            optimization: "-Onone",
            semanticArguments: ["-parse-as-library", "-I", directory.path]
        )
        func build(cacheName: String) throws -> NativeAPICatalog.BuildOutput {
            try NativeAPICatalog.Builder(cache: .init(
                rootURL: directory.appendingPathComponent(cacheName)
            )).build(.init(
                identity: identity,
                frontendInvocation: invocation,
                compilerURL: compilerURL,
                precomputedToolchain: toolchain
            ))
        }
        let first = try build(cacheName: "FirstCache")
        let second = try build(cacheName: "SecondCache")

        #expect(first.metrics.cacheSource == .generated)
        #expect(second.metrics.cacheSource == .generated)
        #expect(first.metrics.probeAttemptCount == 2)
        #expect(second.metrics.probeAttemptCount == 2)
        #expect(first.snapshot.document.entries.count == 260)
        #expect(second.snapshot.document == first.snapshot.document)
    }

    @Test("System SDK Catalog covers representative UIKit first uses")
    func buildsUIKitCatalogWhenRequested() throws {
        guard ProcessInfo.processInfo.environment[
            "HELIX_RUN_SDK_CATALOG_INTEGRATION"
        ] == "1" else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-uikit-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity(
            compilerURL: compilerURL
        )
        let target = "arm64-apple-ios15.0-simulator"
        let identity = NativeAPICatalog.Identity(
            provenance: .systemSDK,
            xcodeProductBuild: "integration-test",
            sdkProductBuild: sdk.buildVersion,
            compilerFingerprint: toolchain.fingerprint,
            targetTriple: target,
            minimumDeployment: .init(15),
            swiftLanguageMode: "5",
            moduleName: "UIKit",
            moduleContentHash: .sha256("UIKit:\(sdk.buildVersion)"),
            moduleSearchPathHash: .sha256("system-sdk"),
            dependencyGraphHash: .sha256("UIKit-system-dependencies")
        )
        let output = try NativeAPICatalog.Builder(cache: .init(
            rootURL: directory.appendingPathComponent("Cache")
        )).build(.init(
            identity: identity,
            frontendInvocation: .init(
                moduleName: "UIKitCatalogConsumer",
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            compilerURL: compilerURL,
            precomputedToolchain: toolchain
        ))

        #expect(output.metrics.candidateCount > 1_000)
        #expect(output.snapshot.document.entries.contains {
            $0.descriptor.target.backend == .objectiveCMessage
                && $0.descriptor.target.owner == "UIViewController"
                && $0.descriptor.target.entryPoint
                    == "presentViewController:animated:completion:"
        })
        #expect(output.snapshot.document.entries.contains {
            $0.descriptor.target.backend == .objectiveCMessage
                && $0.descriptor.target.owner == "UIView"
                && $0.descriptor.target.entryPoint == "setBackgroundColor:"
        })
        #expect(output.snapshot.document.entries.contains {
            $0.descriptor.target.backend == .objectiveCMessage
                && $0.descriptor.target.owner == "UIView"
                && $0.descriptor.canonicalCallee.contains("animate")
        })
        try output.snapshot.document.validate()
    }

    private func swiftEntry() throws -> NativeAPICatalog.Entry {
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.increment(_:)",
            signature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int"
            ),
            effects: .init(),
            contract: contract
        )
        return try .init(
            descriptor: descriptor,
            contract: contract,
            compilerSymbols: ["$s7Fixture9incrementyS2iF"],
            binding: .init(
                strategy: .swiftAdapter,
                adapterID: "Fixture.increment.Int",
                importedModules: ["Fixture"]
            )
        )
    }

    private func objectiveCEntry() throws -> NativeAPICatalog.Entry {
        let contract = Core.NativeImportContract.bounded(
            kind: .instanceMethod,
            domain: .uiKit,
            access: .write,
            maximumDurationMicroseconds: 1_000,
            allowsMainThread: true,
            callbacks: [
                .init(parameterIndex: 3, lifetime: .escaping),
            ]
        )
        let descriptor = try Core.NativeCall.Descriptor(
            target: .init(
                backend: .objectiveCMessage,
                module: "UIKit",
                owner: "UIViewController",
                member: "present(_:animated:completion:)",
                entryPoint: "presentViewController:animated:completion:",
                dispatch: .instance,
                receiverArgumentIndex: 0
            ),
            logicalSignature: .init(
                parameters: [
                    .init(type: "UIKit.UIViewController"),
                    .init(type: "UIKit.UIViewController"),
                    .init(type: "Swift.Bool"),
                    .init(
                        type: "(() -> Swift.Void)?",
                        callbackLifetime: .escaping
                    ),
                ],
                result: .init(type: "Swift.Void"),
                isolation: "MainActor"
            ),
            physicalSignature: .init(
                callingConvention: .objectiveC,
                parameters: [
                    .init(
                        type: .init(
                            kind: .object,
                            canonicalName: "UIKit.UIViewController",
                            encoding: "@"
                        ),
                        source: .argument(1)
                    ),
                    .init(
                        type: .init(
                            kind: .boolean,
                            canonicalName: "ObjectiveC.BOOL",
                            size: 1,
                            alignment: 1,
                            encoding: "B"
                        ),
                        source: .argument(2)
                    ),
                    .init(
                        type: .init(
                            kind: .block,
                            canonicalName: "ObjectiveC.Block",
                            encoding: "@?",
                            isNullable: true
                        ),
                        source: .argument(3)
                    ),
                ],
                result: .void
            ),
            objectiveC: .init(runtimeClassName: "UIViewController"),
            effects: .init(
                mayAllocate: true,
                hasExternalSideEffects: true,
                requiresMainActor: true
            ),
            availability: [
                .init(platform: "iOS", introduced: .init(5)),
            ]
        )
        return try .init(
            descriptor: descriptor,
            contract: contract,
            compilerSymbols: ["c:objc(cs)UIViewController(im)presentViewController:animated:completion:"],
            binding: .init(
                strategy: .objectiveCInvoker,
                importedModules: ["UIKit"]
            )
        )
    }

    private func identity(
        module: String,
        content: String = "module-content"
    ) -> NativeAPICatalog.Identity {
        .init(
            provenance: module == "UIKit" ? .systemSDK : .applicationModule,
            xcodeProductBuild: "17A400",
            sdkProductBuild: "23A340",
            compilerFingerprint: "swiftlang-6.2.0.1",
            targetTriple: "arm64-apple-ios18.0",
            minimumDeployment: .init(15),
            swiftLanguageMode: "6",
            moduleName: module,
            moduleContentHash: .sha256(content),
            moduleSearchPathHash: .sha256("search-path"),
            dependencyGraphHash: .sha256("dependencies")
        )
    }
}
}
