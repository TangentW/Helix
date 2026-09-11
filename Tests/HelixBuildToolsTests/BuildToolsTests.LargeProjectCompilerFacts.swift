import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Large-project compiler fact regressions")
struct LargeProjectCompilerFacts {
    @Test("Import scan excludes only proven inactive OS branches and retains unknown conditions")
    func scopesConditionalImports() {
        let source = Data("""
        #if os(macOS)
        import AppKit
        #elseif os(iOS)
        import UIKit
        #if FEATURE_FLAG
        import OptionalFeature
        #else
        import FallbackFeature
        #endif
        #else
        import OtherPlatform
        #endif
        #if !os(iOS)
        import NonIOS
        #endif
        #if os(macOS) || FEATURE_FLAG
        import PossibleFeature
        #endif
        #if os(macOS)
          || FEATURE_FLAG
        import MultilinePossible
        #endif
        """.utf8)
        let result = FrontendReceipt.SourceImports.scan(contents: [source], targetTriple: "arm64-apple-ios17.0-simulator")
        #expect(result.isComplete)
        #expect(result.modules == ["FallbackFeature", "MultilinePossible", "OptionalFeature", "PossibleFeature", "UIKit"])
        #expect(result.covers(compilerModules: ["UIKit", "OptionalFeature"]))
        #expect(FrontendReceipt.SourceImports.scan(contents: [source]).modules.contains("AppKit"))
        #expect(!FrontendReceipt.SourceImports.scan(contents: [Data("#if os(iOS)\nimport UIKit".utf8)]).isComplete)
    }

    @Test("Actor and selector diagnostics are semantic rejections; unknown compiler failures are not")
    func classifiesProbeFailures() {
        let known = [
            "actor-isolated property 'value' can not be mutated from a nonisolated context",
            "call to global actor 'WorkerActor'-isolated initializer 'init()' in a synchronous nonisolated context",
            "argument of '#selector' does not refer to an '@objc' method, property, or initializer",
        ]
        for diagnostic in known {
            #expect(FrontendReceipt.ManagedNativeSurface.isDeterministicProbeRejection(status: 1, diagnostics: "fixture.swift:2:1: error: " + diagnostic))
            #expect(!FrontendReceipt.ManagedNativeSurface.isDeterministicProbeRejection(status: 1,
                diagnostics: "error: " + diagnostic + "\nerror: compiler crashed"))
        }
        for diagnostic in ["no such module 'AppKit'", "unable to load standard library", "an unknown compiler failure"] {
            #expect(!FrontendReceipt.ManagedNativeSurface.isDeterministicProbeRejection(status: 1, diagnostics: "error: " + diagnostic))
        }
    }

    @Test("Module and probe budgets share CPU and conservative memory limits")
    func boundsCompilerWork() {
        for processors in [0, 1, 4, 12, 128] {
            for gibibytes: UInt64 in [0, 4, 8, 16, 64, 1024] {
                let budget = NativeAPICatalog.WorkBudget(processorCount: processors,
                    physicalMemory: gibibytes * 1_024 * 1_024 * 1_024, requestedModules: 8)
                #expect((1...8).contains(budget.compilerWorkers))
                for modules in 1...budget.moduleWorkers {
                    #expect(modules * budget.probesPerModule(concurrentModules: modules) <= budget.compilerWorkers)
                }
            }
        }
    }

    @Test("CoreGraphics C method parameters keep their own nominal identity")
    func preservesCoreGraphicsParameterIdentity() throws {
        let surface = try measure("""
        import CoreGraphics
        import CoreFoundation
        public func bounds(_ page: CGPDFPage, _ box: CGPDFBox) -> CGRect { page.getBoxRect(box) }
        public func document(_ context: CGContext, _ info: CFDictionary, _ data: CFData) {
            context.beginPDFPage(info)
            context.addDocumentMetadata(data)
        }
        """)
        for name in ["CGPDFBox", "CFData", "CFDictionary"] {
            let types = surface.types.filter { [$0.canonicalName, $0.swiftType].contains { $0.contains(name) } }
            #expect(!types.isEmpty, "Missing \(name)")
            #expect(types.allSatisfy { !$0.swiftType.contains("CGContext") && !$0.swiftType.contains("CGPDFPage") })
        }
        let box = try #require(surface.operations.first { $0.baseName == "getBoxRect" })
        #expect(box.parameterSwiftTypes.first?.contains("CGPDFBox") == true)
        #expect(box.ownerType == "CGPDFPage")
        #expect(box.parameterProjection?.logicalParameterIndices == [1, 0])
        #expect(box.parameterProjection?.argumentOrderVersion == 2)
    }

    @Test("C import-as-member self in the middle is mapped from compiler context")
    func mapsClangMiddleReceiver() throws {
        let surface = try measure("""
        import MemberFixture
        public func use(_ pair: Pair) -> Int32 { pair.combine(1, 2) }
        """, header: """
        typedef struct Pair { int value; } Pair;
        int combine(int first, Pair receiver, int second) __attribute__((swift_name("Pair.combine(_:self:_:)")));
        """)
        let call = try #require(surface.operations.first { $0.baseName == "combine" })
        #expect(call.parameterProjection?.logicalParameterIndices == [0, 2, 1])
        #expect(call.parameterSwiftTypes == ["Swift.Int32", "Swift.Int32", "Pair"])
    }

    @Test("Repeated C owner slots cannot be guessed from type spelling")
    func rejectsAmbiguousClangReceiver() throws {
        #expect(throws: FrontendReceipt.Error.self) {
            try measure("""
            import MemberFixture
            public func use(_ pair: Pair, _ other: Pair) -> Int32 { pair.compare(other) }
            """, header: """
            typedef struct Pair { int value; } Pair;
            int compare(Pair other, Pair receiver) __attribute__((swift_name("Pair.compare(_:self:)")));
            """)
        }
    }

    @Test("Clang typedef identity requires one exact length-prefixed nominal")
    func exactClangTypedefIdentity() {
        let adapter = FrontendReceipt.Adapter()
        #expect(adapter.isImportedClangTypealias("$sSo9CFDataRefaD"))
        #expect(adapter.isImportedClangTypealias("$sSo9CFDataRefaSgD"))
        for mangled in ["$sSo9CFDataRefaSo12CGContextRefaD", "$sSo9223372036854775807XaD", "$sSo99CFDataRefaD", "$sSo9CFDataRefaMD"] {
            #expect(!adapter.isImportedClangTypealias(mangled))
            #expect(FrontendReceipt.Adapter.objectiveCNominalIdentity(inMangledType: mangled) == nil)
        }
    }

    @Test("Raw-representable enum evidence refines value kind without erasing reference conflicts")
    func refinesEnumKindWithMatchingRepresentation() throws {
        let value = FrontendReceipt.Adapter.ImportedNativeType(canonicalName: "Fixture.Choice", swiftType: "Fixture.Choice",
            kind: .value, aliases: [], representation: .rawRepresentable, sourceFileLogicalID: "Value.swift",
            importedModules: ["Fixture"], requiresMainActor: false, isolationEvidence: .importedDeclaration)
        var enumeration = value
        enumeration.kind = .enumeration
        enumeration.sourceFileLogicalID = "Enum.swift"
        for uses in [[value, enumeration], [enumeration, value]] {
            let merged = try FrontendReceipt.Adapter().mergeImportedNativeTypes(discoveredTypes: [], operationTypes: uses)
            #expect(merged.count == 1 && merged[0].kind == .enumeration)
        }
        var reference = value
        reference.kind = .reference
        reference.representation = .reference
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.Adapter().mergeImportedNativeTypes(discoveredTypes: [enumeration], operationTypes: [reference])
        }
    }

    @Test("Parameter permutation has an explicit v2 contract and rejects malformed maps")
    func versionedParameterPermutation() throws {
        let original = InterfaceArchive.NativeImportParameterProjection(physicalParameterCount: 3, logicalParameterIndices: [0, 2, 1])
        #expect(original.isValid(logicalParameterCount: 3))
        let data = try JSONEncoder().encode(original)
        let roundTrip = try JSONDecoder().decode(InterfaceArchive.NativeImportParameterProjection.self, from: data)
        #expect(roundTrip == original)
        var legacy = original
        legacy.argumentOrderVersion = nil
        #expect(!legacy.isValid(logicalParameterCount: 3))
        legacy.argumentOrderVersion = 3
        #expect(!legacy.isValid(logicalParameterCount: 3))
        let old = try JSONDecoder().decode(InterfaceArchive.NativeImportParameterProjection.self,
            from: Data(#"{"physicalParameterCount":2,"logicalParameterIndices":[0,1],"defaultArguments":[]}"#.utf8))
        #expect(old.argumentOrderVersion == nil && old.isValid(logicalParameterCount: 2))
        for indices: [UInt16] in [[1, 1, 0], [2, 0], [0, 3, 1]] {
            #expect(!InterfaceArchive.NativeImportParameterProjection(physicalParameterCount: 3,
                logicalParameterIndices: indices).isValid(logicalParameterCount: 3))
        }
    }

    private func measure(_ text: String, header: String? = nil) throws -> FrontendReceipt.Adapter.ImportedOperationSurface {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helix-compiler-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        if let header {
            try Data(header.utf8).write(to: root.appendingPathComponent("Member.h"))
            try Data("module MemberFixture { header \"Member.h\" export * }".utf8).write(to: root.appendingPathComponent("module.modulemap"))
        }
        let source = Data(text.utf8)
        let url = root.appendingPathComponent("Fixture.swift")
        try source.write(to: url)
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let invocation = InterfaceArchive.FrontendInvocation(moduleName: "CompilerFacts", targetTriple: "arm64-apple-ios17.0-simulator",
            sdkName: sdk.name, sdkBuild: sdk.buildVersion, optimization: "-Onone", semanticArguments: ["-parse-as-library", "-I", root.path])
        let ast = try frontend.emitTypedAST(sourceFiles: [url], invocation: invocation)
        let documents = try FrontendReceipt.TypedAST.parseDocuments(ast)
        let demangled = try FrontendReceipt.Demangler(compilerURL: frontend.compilerURL)
            .demangle(FrontendReceipt.TypedAST.mangledTypes(in: documents))
        let sil = try frontend.emitCanonicalSIL(sourceFiles: [url], invocation: invocation)
        if header == nil, let path = ProcessInfo.processInfo.environment["HELIX_COMPILER_FACT_REPORT"], path.hasPrefix("/") {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(ast.utf8).write(to: directory.appendingPathComponent("coregraphics.ast.json"))
            try Data(sil.utf8).write(to: directory.appendingPathComponent("coregraphics.sil"))
            try Core.CanonicalJSON.encode(demangled).write(to: directory.appendingPathComponent("coregraphics.demangled.json"))
        }
        let state = FrontendReceipt.Adapter.SourceState(logicalPath: "Fixture.swift", url: url, contents: source, contentHash: .sha256(source))
        return try FrontendReceipt.Adapter().discoverImportedOperationSurface(documents: documents,
            sourcesByPhysicalPath: [url.resolvingSymlinksInPath().path: state], moduleName: invocation.moduleName,
            demangled: demangled, silFile: CanonicalSIL.File(text: sil))
    }
}
}
