import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Compiler-proven managed native aliases")
struct ManagedNativeAliasTests {
    @Test("Initializer evidence unifies renamed owners and nested types")
    func unifiesRenamedNominalIdentities() throws {
        let legacyRoot = type(
            "NSDecimal.FormatStyle",
            aliases: ["Foundation.NSDecimal.FormatStyle"]
        )
        let canonicalRoot = type(
            "Foundation.Decimal.FormatStyle",
            aliases: ["Decimal.FormatStyle"]
        )
        let legacyNested = type(
            "NSDecimal.FormatStyle.Attributed",
            aliases: ["Foundation.NSDecimal.FormatStyle.Attributed"]
        )
        let canonicalNested = type(
            "Foundation.Decimal.FormatStyle.Attributed",
            aliases: ["Decimal.FormatStyle.Attributed"]
        )
        let initializer = operation(
            owner: legacyRoot.swiftType,
            result: canonicalRoot.swiftType,
            dispatch: .initializer,
            declarationUSR: "s:Foundation.NSDecimal.FormatStyle.init"
        )
        let getter = operation(
            owner: legacyRoot.swiftType,
            parameters: [legacyRoot.swiftType],
            result: legacyNested.swiftType,
            dispatch: .instanceGetter,
            declarationUSR: "s:Foundation.NSDecimal.FormatStyle.attributed"
        )

        let surface = try FrontendReceipt.ManagedNativeSurface
            .canonicalizingCompilerNominalAliases(
                importedTypes: [
                    legacyRoot, canonicalRoot, legacyNested, canonicalNested,
                ],
                operations: [initializer, getter]
            )

        #expect(surface.importedTypes.map(\.canonicalName) == [
            "Foundation.Decimal.FormatStyle",
            "Foundation.Decimal.FormatStyle.Attributed",
        ])
        let root = try #require(surface.importedTypes.first)
        #expect(root.swiftType == "Foundation.Decimal.FormatStyle")
        #expect(root.aliases.contains("NSDecimal.FormatStyle"))
        #expect(root.aliases.contains("Foundation.NSDecimal.FormatStyle"))
        #expect(surface.operations[0].ownerType
            == "Foundation.Decimal.FormatStyle")
        #expect(surface.operations[0].resultSwiftType
            == "Foundation.Decimal.FormatStyle")
        #expect(surface.operations[1].parameterSwiftTypes
            == ["Foundation.Decimal.FormatStyle"])
        #expect(surface.operations[1].resultSwiftType
            == "Foundation.Decimal.FormatStyle.Attributed")
    }

    @Test("Conflicting or cyclic compiler alias evidence fails closed")
    func rejectsInvalidAliasGraphs() {
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.ManagedNativeSurface
                .canonicalizingCompilerNominalAliases(
                    importedTypes: [],
                    operations: [
                        operation(
                            owner: "Legacy.Value",
                            result: "Modern.First",
                            dispatch: .initializer,
                            declarationUSR: "s:Legacy.Value.first"
                        ),
                        operation(
                            owner: "Legacy.Value",
                            result: "Modern.Second",
                            dispatch: .initializer,
                            declarationUSR: "s:Legacy.Value.second"
                        ),
                    ]
                )
        }
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.ManagedNativeSurface
                .canonicalizingCompilerNominalAliases(
                    importedTypes: [],
                    operations: [
                        operation(
                            owner: "First.Value",
                            result: "Second.Value",
                            dispatch: .initializer,
                            declarationUSR: "s:First.Value.init"
                        ),
                        operation(
                            owner: "Second.Value",
                            result: "First.Value",
                            dispatch: .initializer,
                            declarationUSR: "s:Second.Value.init"
                        ),
                    ]
                )
        }
    }

    @Test("Swift spelling normalization preserves Objective-C runtime identity")
    func preservesObjectiveCRuntimeIdentity() throws {
        var reference = type("LegacyView", representation: .reference)
        reference.objectiveCRuntimeName = "LegacyView"
        let surface = try FrontendReceipt.ManagedNativeSurface
            .canonicalizingCompilerNominalAliases(
                importedTypes: [reference],
                operations: [operation(
                    owner: "LegacyView",
                    result: "Foundation.ModernView",
                    dispatch: .initializer,
                    declarationUSR: "s:Foundation.LegacyView.init"
                )]
            )

        let normalized = try #require(surface.importedTypes.first)
        #expect(normalized.canonicalName == "LegacyView")
        #expect(normalized.swiftType == "Foundation.ModernView")
        #expect(normalized.objectiveCRuntimeName == "LegacyView")
    }

    @Test("Pure Swift reference aliases share one canonical native identity")
    func canonicalizesPureSwiftReferenceIdentity() throws {
        let legacy = type(
            "Legacy.Reference",
            representation: .reference,
            module: "Library"
        )
        let canonical = type(
            "Library.Modern.Reference",
            representation: .reference,
            module: "Library"
        )
        let surface = try FrontendReceipt.ManagedNativeSurface
            .canonicalizingCompilerNominalAliases(
                importedTypes: [legacy, canonical],
                operations: [operation(
                    owner: legacy.swiftType,
                    result: canonical.swiftType,
                    dispatch: .initializer,
                    declarationUSR: "s:7Library6LegacyO9ReferenceC",
                    importedModules: ["Library"]
                )]
            )

        #expect(surface.importedTypes.count == 1)
        let normalized = try #require(surface.importedTypes.first)
        #expect(normalized.canonicalName == "Library.Modern.Reference")
        #expect(normalized.swiftType == "Library.Modern.Reference")
        #expect(normalized.aliases.contains("Legacy.Reference"))
        #expect(surface.operations[0].ownerType == "Library.Modern.Reference")
    }

    private func type(
        _ name: String,
        aliases: [String] = [],
        representation: FrontendReceipt.Adapter.ImportedNativeType
            .Representation = .opaqueValue,
        module: String = "Foundation"
    ) -> FrontendReceipt.Adapter.ImportedNativeType {
        .init(
            canonicalName: name,
            swiftType: name,
            kind: representation == .reference ? .reference : .value,
            aliases: aliases,
            representation: representation,
            sourceFileLogicalID: "NativeAPICatalog/\(module).swift",
            importedModules: [module],
            nativeModuleName: module,
            requiresMainActor: false,
            isolationEvidence: .importedDeclaration
        )
    }

    private func operation(
        owner: String,
        parameters: [String] = [],
        result: String,
        dispatch: NativeImportDiscovery.Dispatch,
        declarationUSR: String,
        importedModules: [String] = ["Foundation"]
    ) -> FrontendReceipt.Adapter.ImportedOperation {
        .init(
            silReferences: ["$s_helix_compiler_alias_fixture"],
            sourceFileLogicalID: "NativeAPICatalog/Foundation.swift",
            importedModules: importedModules,
            dispatch: dispatch,
            ownerType: owner,
            baseName: dispatch == .initializer ? "init" : "attributed",
            argumentLabels: [],
            parameterSwiftTypes: parameters,
            resultSwiftType: result,
            requiresMainActor: false,
            declarationUSR: declarationUSR,
            isolationEvidence: .importedDeclaration,
            isEmittedToDevice: false
        )
    }
}
}
