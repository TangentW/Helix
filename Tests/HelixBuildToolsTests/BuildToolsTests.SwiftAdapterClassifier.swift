import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Swift Adapter classification")
struct SwiftAdapterClassifierTests {
    private let classifier = NativeImportDiscovery.SwiftAdapterClassifier()

    @Test("External pure Swift APIs enter module Packs")
    func externalModulePack() {
        #expect(classifier.classify(
            declarationUSR: "s:10Foundation4DateV18addingTimeIntervalyACSdF",
            hasCompilerOperation: false,
            adapterTypeSpellings: ["Foundation.Date", "Swift.Double"],
            applicationTypeNames: ["Demo.Event"],
            applicationModuleName: "Demo"
        ) == .modulePack("Foundation"))
    }

    @Test("Swift overlays on imported types retain extension module ownership")
    func importedTypeOverlayModulePack() {
        let usr = "s:So13NSFileManagerC10FoundationE10enumerator2at"
        #expect(NativeImportDiscovery.SwiftAdapterClassifier
            .declarationModule(in: usr) == "Foundation")
        #expect(classifier.classify(
            declarationUSR: usr,
            hasCompilerOperation: false,
            adapterTypeSpellings: [
                "FileManager",
                "FileManager.DirectoryEnumerationOptions",
            ],
            applicationTypeNames: [],
            applicationModuleName: "Demo"
        ) == .modulePack("Foundation"))
        #expect(NativeImportDiscovery.SwiftAdapterClassifier
            .declarationModule(
                in: "s:SS10FoundationE18localizedCapitalizedSSvg"
            ) == "Foundation")
        #expect(NativeImportDiscovery.SwiftAdapterClassifier
            .declarationModule(
                in: "s:So4TypeC10FoundationE5value8OtherKitE"
            ) == nil)
    }

    @Test("Standard-library generic witnesses do not manufacture modules")
    func standardLibraryGenericWitness() {
        let usr =
            "s:s20_SwiftNewtypeWrapperPsSHRzSH8RawValueSYRpzrlE04hashE0Sivp"
        #expect(NativeImportDiscovery.SwiftAdapterClassifier
            .declarationModule(in: usr) == "Swift")
        #expect(classifier.classify(
            declarationUSR: usr,
            hasCompilerOperation: false,
            adapterTypeSpellings: ["UIKit.UIFont.Weight", "Swift.Int"],
            applicationTypeNames: [],
            applicationModuleName: "Demo"
        ) == .modulePack("Swift"))
    }

    @Test("Validated Catalog ownership can classify declarations without a USR")
    func catalogModulePack() {
        #expect(classifier.classify(
            authoritativeModuleName: "Foundation",
            declarationUSR: nil,
            hasCompilerOperation: false,
            adapterTypeSpellings: ["Foundation.ListFormatter"],
            applicationTypeNames: [],
            applicationModuleName: "Demo"
        ) == .modulePack("Foundation"))
        #expect(classifier.classify(
            authoritativeModuleName: "Foundation",
            declarationUSR: "s:5UIKit6UIViewC",
            hasCompilerOperation: false,
            adapterTypeSpellings: ["Foundation.ListFormatter"],
            applicationTypeNames: [],
            applicationModuleName: "Demo"
        ) == .application(.noExternalSwiftDeclaration))
    }

    @Test("Application dependencies and synthesized calls stay project-local")
    func applicationAdapters() {
        #expect(classifier.classify(
            declarationUSR: "s:10Foundation4DateV18addingTimeIntervalyACSdF",
            hasCompilerOperation: false,
            adapterTypeSpellings: ["(Demo.Event) -> Foundation.Date"],
            applicationTypeNames: ["Demo.Event"],
            applicationModuleName: "Demo"
        ) == .application(.referencesApplicationType))
        #expect(classifier.classify(
            declarationUSR: "s:10Foundation4DateV18addingTimeIntervalyACSdF",
            hasCompilerOperation: true,
            adapterTypeSpellings: ["Foundation.Date"],
            applicationTypeNames: [],
            applicationModuleName: "Demo"
        ) == .application(.compilerGeneratedOperation))
        #expect(classifier.classify(
            declarationUSR: "c:@F@NSMaxRange",
            hasCompilerOperation: false,
            adapterTypeSpellings: ["Foundation.NSRange"],
            applicationTypeNames: [],
            applicationModuleName: "Demo"
        ) == .application(.noExternalSwiftDeclaration))
        #expect(classifier.classify(
            declarationUSR: "s:4Demo6helperyS2iF",
            hasCompilerOperation: false,
            adapterTypeSpellings: ["Swift.Int"],
            applicationTypeNames: [],
            applicationModuleName: "Demo"
        ) == .application(.applicationModuleDeclaration))
    }

    @Test("Malformed Swift USRs fail closed")
    func malformedUSR() {
        for usr in [
            "s:", "s:0", "s:5Exact", "s:10Short", "s:9Bad-Thing",
        ] {
            #expect(classifier.classify(
                declarationUSR: usr,
                hasCompilerOperation: false,
                adapterTypeSpellings: [],
                applicationTypeNames: [],
                applicationModuleName: "Demo"
            ) == .application(.noExternalSwiftDeclaration))
        }
    }

    @Test("Swift USR module lengths are UTF-8 byte counts")
    func unicodeModuleUSR() {
        #expect(NativeImportDiscovery.SwiftAdapterClassifier
            .declarationModule(in: "s:6模块4TypeV") == "模块")
        #expect(NativeImportDiscovery.SwiftAdapterClassifier
            .declarationModule(in: "s:2模块4TypeV") == nil)
    }

    @Test("Pack imports retain referenced dependency modules only")
    func requiredImports() {
        #expect(classifier.requiredImports(
            primaryModule: "NetworkKit",
            typeSpellings: [
                "NetworkKit.Request<GeometryKit.Point>",
                "(Swift.Int) -> Foundation.Date",
            ],
            candidateModules: [
                "DemoSupport", "Foundation", "GeometryKit", "NetworkKit",
                "UnrelatedKit",
            ]
        ) == ["Foundation", "GeometryKit", "NetworkKit"])
    }
}
}
