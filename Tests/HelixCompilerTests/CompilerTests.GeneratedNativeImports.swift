import HelixBytecode
import HelixCore
import HelixInterface
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Generated NativeImport validation")
struct GeneratedNativeImports {
    @Test("App-owned call targets accept only the reserved identity namespace")
    func rejectsArbitraryApplicationNamespaces() {
        let generated = BridgeGeneration.GeneratedNativeImport(
            declarationMangledName: "$s7Fixture6WidgetC4makeyACSiFZ",
            sourceFileLogicalID: "Sources/Widget.swift",
            dispatch: .staticMethod,
            ownerType: "Widget",
            baseName: "make",
            argumentLabels: ["_"],
            parameterSwiftTypes: ["Swift.Int"],
            resultSwiftType: "Fixture.Widget"
        )
        func target(_ entryPoint: String) -> Core.NativeCall.Target {
            .init(
                backend: .swiftAdapter,
                module: "Fixture",
                owner: "Widget",
                member: "make(_:)",
                entryPoint: entryPoint,
                dispatch: .static
            )
        }
        let generator = BridgeGeneration.Generator()

        #expect(generator.generatedSwiftCallMatchesDescriptor(
            generated,
            target: target("Fixture.Widget.make(_:)")
        ))
        #expect(generator.generatedSwiftCallMatchesDescriptor(
            generated,
            target: target("Fixture.HelixExternal.Widget.make(_:).call")
        ))
        #expect(!generator.generatedSwiftCallMatchesDescriptor(
            generated,
            target: target("Fixture.Untrusted.Widget.make(_:).call")
        ))
    }

    @Test("App-owned owners preserve a namespace equal to their module")
    func preservesModuleNamedApplicationNamespace() {
        let generator = BridgeGeneration.Generator()

        func generated(
            dispatch: BridgeGeneration.GeneratedNativeImport.Dispatch,
            baseName: String,
            labels: [String] = []
        ) -> BridgeGeneration.GeneratedNativeImport {
            .init(
                declarationMangledName: "$s17LiveReloadFeature"
                    + "06ScreenC10ControllerC",
                sourceFileLogicalID: "Sources/LiveReloadFeature.Screen.swift",
                dispatch: dispatch,
                ownerType: "LiveReloadFeature.ScreenViewController",
                baseName: baseName,
                argumentLabels: labels,
                parameterSwiftTypes: [],
                resultSwiftType: "Swift.Void"
            )
        }

        func target(
            _ member: String,
            dispatch: Core.NativeCall.Dispatch
        ) -> Core.NativeCall.Target {
            .init(
                backend: .swiftAdapter,
                module: "LiveReloadFeature",
                owner: "LiveReloadFeature.ScreenViewController",
                member: member,
                entryPoint: "LiveReloadFeature.LiveReloadFeature."
                    + "ScreenViewController.\(member)",
                dispatch: dispatch,
                receiverArgumentIndex: dispatch == .instance ? 0 : nil
            )
        }

        #expect(generator.generatedSwiftCallMatchesDescriptor(
            generated(dispatch: .initializer, baseName: "init"),
            target: target("init()", dispatch: .initializer)
        ))
        #expect(generator.generatedSwiftCallMatchesDescriptor(
            generated(dispatch: .staticMethod, baseName: "make"),
            target: target("make()", dispatch: .static)
        ))
        #expect(generator.generatedSwiftCallMatchesDescriptor(
            generated(dispatch: .instanceMethod, baseName: "refresh"),
            target: target("refresh()", dispatch: .instance)
        ))
        #expect(generator.generatedSwiftCallMatchesDescriptor(
            generated(dispatch: .instanceGetter, baseName: "detailLabel"),
            target: target("detailLabel.get", dispatch: .instance)
        ))
        #expect(!generator.generatedSwiftCallMatchesDescriptor(
            generated(dispatch: .instanceGetter, baseName: "detailLabel"),
            target: .init(
                backend: .swiftAdapter,
                module: "LiveReloadFeature",
                owner: "ScreenViewController",
                member: "detailLabel.get",
                entryPoint: "LiveReloadFeature.ScreenViewController."
                    + "detailLabel.get",
                dispatch: .instance,
                receiverArgumentIndex: 0
            )
        ))
    }

    @Test("App-local imported globals preserve their compiler namespace")
    func acceptsNamespacedImportedGlobalIdentity() {
        let generated = BridgeGeneration.GeneratedNativeImport(
            declarationMangledName: "$sSo18CACurrentMediaTimeSdyF",
            sourceFileLogicalID: "Sources/Animation.swift",
            dispatch: .globalFunction,
            baseName: "CACurrentMediaTime",
            argumentLabels: [],
            parameterSwiftTypes: [],
            resultSwiftType: "Swift.Double"
        )
        func target(_ entryPoint: String) -> Core.NativeCall.Target {
            .init(
                backend: .swiftAdapter,
                module: "Fixture",
                member: String(entryPoint.dropFirst("Fixture.".count)),
                entryPoint: entryPoint,
                dispatch: .global
            )
        }
        let generator = BridgeGeneration.Generator()

        #expect(generator.generatedSwiftCallMatchesDescriptor(
            generated,
            target: target(
                "Fixture.HelixExternal.__C.CACurrentMediaTime().call"
            )
        ))
        #expect(!generator.generatedSwiftCallMatchesDescriptor(
            generated,
            target: target("Fixture.__C.CACurrentMediaTime().call")
        ))
        #expect(!generator.generatedSwiftCallMatchesDescriptor(
            generated,
            target: target("Fixture.HelixExternal.__C.CAFrameTime().call")
        ))
        #expect(!generator.generatedSwiftCallMatchesDescriptor(
            generated,
            target: target(
                "Fixture.HelixExternal.__C?.CACurrentMediaTime().call"
            )
        ))
    }

    @Test("Swift aliases may spell an initializer owner and result differently")
    func acceptsCompilerProvenInitializerAliases() throws {
        let fixture = try makeAliasInitializerFixture()
        let output = try BridgeGeneration.Generator().generate(
            archive: fixture.archive,
            moduleName: "Fixture",
            roots: [],
            nativeImports: [fixture.binding],
            nativeTypes: fixture.typeBindings
        )

        let pack = try #require(output.adapterPacks.first)
        let source = try #require(output.sourceFiles[pack.sourcePath])
        #expect(source.contains(
            "let result: Foundation.Decimal.FormatStyle = "
                + "NSDecimal.FormatStyle(locale: argument0)"
        ))

        var forged = fixture.binding
        forged.generated?.ownerType = "Unrelated.FormatStyle"
        #expect(throws: BridgeGeneration.Error.generatedNativeImportBindingMismatch(
            .init(rawValue: 0),
            "Swift call target for Foundation.NSDecimal.FormatStyle.init(locale:) "
                + "[NativeCallKey \(fixture.record.key.rawValue.hex)]"
        )) {
            try BridgeGeneration.Generator().generate(
                archive: fixture.archive,
                moduleName: "Fixture",
                roots: [],
                nativeImports: [forged],
                nativeTypes: fixture.typeBindings
            )
        }
    }

    private struct Fixture {
        var archive: InterfaceArchive.Archive
        var record: InterfaceArchive.NativeImportRecord
        var binding: BridgeGeneration.NativeImportBinding
        var typeBindings: [BridgeGeneration.NativeTypeBinding]
    }

    private func makeAliasInitializerFixture() throws -> Fixture {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.generated-native-imports",
            buildNumber: "1",
            seed: "fixture"
        )
        let sourcePath = "Sources/Fixture.swift"
        let signature = Core.LoweredSignature(parameters: [], result: "Swift.Void")
        let declaration = "func anchor()"
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: sourcePath,
            canonicalDeclaration: declaration,
            loweredSignature: signature,
            role: .function
        )
        let function = InterfaceArchive.FunctionRecord(
            key: functionKey,
            entryIndex: nil,
            moduleName: "Fixture",
            sourceFileLogicalID: sourcePath,
            canonicalDeclaration: declaration,
            mangledName: "$s7Fixture6anchoryyF",
            role: .function,
            loweredSignature: signature,
            parameterTypes: [],
            resultType: .void,
            effects: .init(),
            interfaceFingerprint: .sha256("anchor interface"),
            bodyFingerprint: .sha256("anchor body"),
            patchability: .rejected("fixture", explanation: "fixture")
        )
        let localeID = Core.TypeID.derive(
            namespace: namespace,
            canonicalType: "Foundation.Locale"
        )
        let formatID = Core.TypeID.derive(
            namespace: namespace,
            canonicalType: "Foundation.Decimal.FormatStyle"
        )
        let localeLayout = Core.Digest.sha256("Foundation.Locale layout")
        let formatLayout = Core.Digest.sha256(
            "Foundation.Decimal.FormatStyle layout"
        )
        let nativeTypes = [
            InterfaceArchive.TypeRecord(
                id: localeID,
                canonicalName: "Foundation.Locale",
                swiftTypeAliases: ["Locale"],
                kind: .value,
                layoutFingerprint: localeLayout,
                isCopyable: true,
                isEmittedToDevice: true,
                estimatedSize: 8
            ),
            InterfaceArchive.TypeRecord(
                id: formatID,
                canonicalName: "Foundation.Decimal.FormatStyle",
                swiftTypeAliases: ["Decimal.FormatStyle"],
                kind: .value,
                layoutFingerprint: formatLayout,
                isCopyable: true,
                isEmittedToDevice: true,
                estimatedSize: 8
            ),
        ]
        let contract = Core.NativeImportContract.bounded(
            kind: .initializer,
            domain: .foundation,
            access: .readWrite,
            maximumDurationMicroseconds: 2_000,
            allowsMainThread: true
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee:
                "Foundation.NSDecimal.FormatStyle.init(locale:)",
            signature: .init(
                parameters: ["Foundation.Locale"],
                result: "Foundation.Decimal.FormatStyle"
            ),
            effects: .init(mayAllocate: true, hasExternalSideEffects: true),
            contract: contract,
            argumentLabels: ["locale"]
        )
        let record = InterfaceArchive.NativeImportRecord(
            id: .init(rawValue: 0),
            key: try Core.NativeCall.Key.derive(descriptor: descriptor),
            descriptor: descriptor,
            silMangledNames: [
                "$sSo9NSDecimala10FoundationE11FormatStyleV6localeAeC6LocaleV_tcfC",
            ],
            parameterTypes: [.native(localeID)],
            resultType: .native(formatID),
            contract: contract,
            isEmittedToDevice: true
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.generated-native-imports",
            buildNumber: "1",
            shellNamespaceID: namespace,
            machOUUIDs: [],
            targetTriple: "arm64-apple-ios15.0-simulator",
            minimumOS: .init(15),
            xcodeBuild: "fixture",
            sdkBuild: "fixture",
            frontendInvocation: .init(
                moduleName: "Fixture",
                targetTriple: "arm64-apple-ios15.0-simulator",
                sdkName: "iphonesimulator",
                sdkBuild: "fixture"
            ),
            transformPipelineHash: .sha256("fixture transform"),
            sourceBaselineHash: .sha256("fixture baseline")
        )
        let archive = try InterfaceArchive.Archive.make(
            metadata: metadata,
            compatibility: .init(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: "fixture"
            ),
            capabilities: [.baselineV1, .nativeImportsV1, .nativeTypesV1],
            sources: [
                .init(
                    logicalPath: sourcePath,
                    contentHash: .sha256("fixture source")
                ),
            ],
            functions: [function],
            nativeImports: [record],
            nativeTypes: nativeTypes,
            bridgeRegistrationCount: 0
        )
        let generated = BridgeGeneration.GeneratedNativeImport(
            declarationMangledName: record.silMangledNames[0],
            sourceFileLogicalID: "NativeAPICatalog/Foundation.swift",
            dispatch: .initializer,
            ownerType: "NSDecimal.FormatStyle",
            baseName: "init",
            argumentLabels: ["locale"],
            parameterSwiftTypes: ["Foundation.Locale"],
            resultSwiftType: "Foundation.Decimal.FormatStyle",
            nativeModuleName: "Foundation"
        )
        let binding = BridgeGeneration.NativeImportBinding(
            id: .init(rawValue: 0),
            key: record.key,
            strategy: .generatedSwiftAdapter,
            importedModules: ["Foundation"],
            generated: generated
        )
        let typeBindings = [
            BridgeGeneration.NativeTypeBinding(
                id: localeID,
                canonicalName: "Foundation.Locale",
                layoutFingerprint: localeLayout,
                operationsExpression: "FixtureNativeTypes.locale",
                importedModules: ["Foundation"]
            ),
            BridgeGeneration.NativeTypeBinding(
                id: formatID,
                canonicalName: "Foundation.Decimal.FormatStyle",
                layoutFingerprint: formatLayout,
                operationsExpression: "FixtureNativeTypes.decimalFormat",
                importedModules: ["Foundation"]
            ),
        ]
        return .init(
            archive: archive,
            record: record,
            binding: binding,
            typeBindings: typeBindings
        )
    }
}
}
