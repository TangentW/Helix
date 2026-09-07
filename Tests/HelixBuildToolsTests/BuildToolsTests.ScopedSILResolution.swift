import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Compiler-backed SIL location disambiguation")
struct ScopedSILResolutionTests {
    @Test("Compiler closure discriminators distinguish equal roles at one coordinate")
    func matchesDiscriminators() throws {
        let symbols = ["$s7Fixture3fooyyFSiyXEfU_", "$s7Fixture3fooyyFSiyXEfU0_"]
        let source = FrontendReceipt.Adapter.SourceState(logicalPath: "Source.swift",
            url: URL(fileURLWithPath: "/tmp/Discriminators.swift"), contents: Data("{}".utf8), contentHash: .sha256("{}"))
        var file = try CanonicalSIL.File(text: "")
        file.functions = symbols.map {
            var function = CanonicalSIL.Function(mangledName: $0, loweredType: "$@convention(thin) () -> Int", body: "")
            function.declarationLocation = .init(file: source.url.path, line: 1, column: 1)
            return function
        }
        let resolver = try FrontendReceipt.SILFunctionResolver(file: file).resolvingCollisions(using: .init(compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")))
        for index in symbols.indices {
            let closure: FrontendReceipt.TypedAST.Object = ["_kind": "closure_expr", "discriminator": String(index), "range": ["start": 0, "end": 1]]
            #expect(try resolver.function(forClosure: closure, source: source)?.mangledName == symbols[index])
        }
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.SILSymbolIdentity.parse("Demangling for unexpected\nkind=Global\n  kind=Function\n", symbols: symbols)
        }
    }

    @Test("Real autoclosures and explicit closures sharing a coordinate resolve separately")
    func resolvesRealClosures() throws {
        try withFixture("""
        import Foundation
        public func fallback(_ value: Int?) -> Int { value ?? { 7 }() }
        public func siblings(_ value: Int?) -> Int { (value ?? { 3 }()) + (value ?? { 4 }()) }
        """) { request, documents, file, source in
            let resolver = try FrontendReceipt.SILFunctionResolver(file: file)
                .resolvingCollisions(using: .init(compilerURL: request.compilerURL))
            let closures = objects(in: documents).filter { $0["_kind"] as? String == "closure_expr" }
            #expect(closures.count == 3)
            var symbols = Set<String>()
            for closure in closures {
                let function = try #require(try resolver.function(forClosure: closure, source: source))
                let identity = try FrontendReceipt.Demangler(compilerURL: request.compilerURL)
                    .symbolIdentities([function.mangledName])[function.mangledName]
                #expect(identity?.kind == "ExplicitClosure")
                symbols.insert(function.mangledName)
            }
            #expect(symbols.count == 3)
            let receipt = try FrontendReceipt.Adapter().generate(request)
            #expect(receipt.receipt.roots.count == 2)
        }
    }

    @Test("Role evidence excludes witness thunks without choosing between two source declarations")
    func resolvesDeclarationRoles() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/HelixRoleFixture.swift")
        let contents = Data("public func number() -> Int { 1 }\n".utf8)
        let source = FrontendReceipt.Adapter.SourceState(logicalPath: "Sources/Feature.swift", url: sourceURL,
            contents: contents, contentHash: .sha256(contents))
        let first = "$s15IdentityFixture6SharedV6numberSiyF"
        let witness = "$s15IdentityFixture6SharedVAA8NumberedA2aDP6numberSiyFTW"
        let second = "$s15IdentityFixture9ContainerO6SharedV6numberSiyF"
        let item: FrontendReceipt.TypedAST.Object = ["_kind": "func_decl", "usr": "s:7Fixture6numberSiyF",
            "range": ["start": 0, "end": contents.count - 1], "body": ["range": ["start": 28, "end": contents.count - 1]]]
        func resolver(_ symbols: [String]) throws -> FrontendReceipt.SILFunctionResolver {
            var file = try CanonicalSIL.File(text: "")
            file.functions = symbols.map {
                var f = CanonicalSIL.Function(mangledName: $0, loweredType: "$@convention(thin) () -> Int", body: "")
                f.declarationLocation = .init(file: sourceURL.path, line: 1, column: 13)
                return f
            }
            return try FrontendReceipt.SILFunctionResolver(file: file)
                .resolvingCollisions(using: .init(compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")))
        }
        #expect(try resolver([witness, first]).function(for: item, source: source, baseName: "number")?.mangledName == first)
        for candidates in [[first, second, witness], [first, "future_unknown_symbol", witness], ["future_unknown_symbol", witness]] {
            do {
                _ = try resolver(candidates).function(for: item, source: source, baseName: "number")
                Issue.record("Unproven source identity was selected")
            } catch {
                let message = String(describing: error)
                for symbol in candidates { #expect(message.contains(symbol)) }
                #expect(message.contains("compiler symbol-tree"))
                #expect(message.contains("() -> Int"))
            }
        }
    }

    @Test("Diagnosis aggregates every independent AST to SIL mapping conflict")
    func aggregatesMappingConflicts() throws {
        let url = URL(fileURLWithPath: "/tmp/HelixMappingConflicts.swift")
        let line = "public func value() -> Int { 1 }\n"
        let contents = Data((line + line).utf8)
        let source = FrontendReceipt.Adapter.SourceState(logicalPath: "Sources/Feature.swift", url: url,
            contents: contents, contentHash: .sha256(contents))
        let symbols = ["$s7Fixture3oneSiyF", "$s7Fixture3twoSiyF", "$s7Fixture5threeSiyF", "$s7Fixture4fourSiyF"]
        let functions = symbols.enumerated().map { index, symbol in
            var value = CanonicalSIL.Function(mangledName: symbol, loweredType: "$@convention(thin) () -> Int", body: "")
            value.declarationLocation = .init(file: url.path, line: index / 2 + 1, column: 13)
            return value
        }
        let items: [FrontendReceipt.TypedAST.Object] = (0..<2).map { index in
            ["_kind": "func_decl", "usr": "s:unmatched\(index)", "name": ["base_name": ["name": "value"]],
             "range": ["start": index * line.utf8.count, "end": (index + 1) * line.utf8.count - 1],
             "body": ["range": ["start": index * line.utf8.count + 26, "end": (index + 1) * line.utf8.count - 1]]]
        }
        do {
            try FrontendReceipt.Adapter().validateSILSourceMappings(documents: [["filename": url.path, "items": items]],
                sourcesByPhysicalPath: [url.path: source], functions: functions,
                compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"), performance: .init())
            Issue.record("Expected both unresolved declaration identities")
        } catch {
            let detail = String(describing: error)
            for symbol in symbols { #expect(detail.contains(symbol)) }
            #expect(detail.contains("\(url.path):1:13"))
            #expect(detail.contains("\(url.path):2:13"))
        }
    }

    @Test("UIKit NS_SWIFT_NAME nested references preserve one measured Objective-C runtime identity")
    func resolvesRealNestedObjectiveCType() throws {
        try withFixture("""
        import UIKit
        @MainActor public func mapped(_ value: UIPencilInteraction.Tap) -> UIPencilInteraction.Tap { value }
        @MainActor public func qualified(_ value: UIKit.UIPencilInteraction.Tap?) -> UIPencilInteraction.Tap? { value ?? { nil }() }
        """) { request, documents, _, source in
            let adapter = FrontendReceipt.Adapter()
            let demangled = try FrontendReceipt.Demangler(compilerURL: request.compilerURL)
                .demangle(FrontendReceipt.TypedAST.mangledTypes(in: documents))
            let types = try adapter.discoverImportedNativeTypes(documents: documents,
                sourcesByPhysicalPath: [source.url.path: source], moduleName: "ScopedIdentityFixture", demangled: demangled)
            let type = try #require(types.first { $0.objectiveCRuntimeName == "UIPencilInteractionTap" })
            #expect(type.swiftType.contains("UIPencilInteraction.Tap"))
            // Preserve the compiler's actual flat Clang spelling as another
            // observation; it cannot compete with the proven Swift overlay.
            let raw = try #require(demangled["$sSo22UIPencilInteractionTapCD"])
            var clang = type
            clang.swiftType = raw
            clang.canonicalName = "UIPencilInteractionTap"
            clang.aliases = []
            let merged = try adapter.mergeImportedNativeTypes(discoveredTypes: types, operationTypes: [clang])
            #expect(merged.filter { $0.objectiveCRuntimeName == "UIPencilInteractionTap" }.count == 1)
            let receipt = try adapter.generate(request)
            #expect(receipt.receipt.roots.count == 2)
        }
    }

    private func objects(in value: Any) -> [FrontendReceipt.TypedAST.Object] {
        if let array = value as? [Any] { return array.flatMap { objects(in: $0) } }
        guard let object = value as? FrontendReceipt.TypedAST.Object else { return [] }
        return [object] + object.values.flatMap { objects(in: $0) }
    }

    private func withFixture(_ sourceText: String,
        body: (FrontendReceipt.Request, [FrontendReceipt.TypedAST.Object], CanonicalSIL.File, FrontendReceipt.Adapter.SourceState) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helix-scoped-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Feature.swift")
        let data = Data((sourceText + "\n").utf8)
        try data.write(to: url)
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let target = "arm64-apple-ios17.5-simulator"
        let metadata = InterfaceArchive.ReleaseMetadata(bundleID: "dev.helix.scoped-identity", buildNumber: "1",
            shellNamespaceID: .derive(bundleID: "dev.helix.scoped-identity", buildNumber: "1", seed: "fixture"), machOUUIDs: [],
            targetTriple: target, minimumOS: .init(17, 5), xcodeBuild: "fixture", sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(moduleName: "ScopedIdentityFixture", targetTriple: target, sdkName: sdk.name,
                sdkBuild: sdk.buildVersion, optimization: "-Onone", semanticArguments: ["-parse-as-library", "-g"]),
            transformPipelineHash: ShellBuild.transformPipelineHash, sourceBaselineHash: .sha256("computed"))
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          ScopedIdentityFixture:
            include:
              - Sources/**
        """)
        let request = FrontendReceipt.Request(metadata: metadata, configuration: configuration,
            sources: [.init(logicalPath: "Sources/Feature.swift", url: url)])
        let documents = try FrontendReceipt.TypedAST.parseDocuments(frontend.emitTypedAST(sourceFiles: [url], invocation: metadata.frontendInvocation))
        let file = try CanonicalSIL.File(text: frontend.emitCanonicalSIL(sourceFiles: [url], invocation: metadata.frontendInvocation, purpose: .semanticLowering))
        let source = FrontendReceipt.Adapter.SourceState(logicalPath: "Sources/Feature.swift", url: url, contents: data, contentHash: .sha256(data))
        try body(request, documents, file, source)
    }
}
}
