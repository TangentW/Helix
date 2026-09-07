import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Compiler-backed SIL location disambiguation")
struct ScopedSILResolutionTests {
    @Test("Symbol trees distinguish static declarations, adapter attributes and unknown wrappers")
    func parsesStructuredRoles() throws {
        func parse(_ tree: String) throws -> FrontendReceipt.SILSymbolIdentity {
            try #require(try FrontendReceipt.SILSymbolIdentity.parse("Demangling for fixture\n" + tree,
                symbols: ["fixture"])["fixture"])
        }
        let getter = try parse("kind=Global\n  kind=Static\n    kind=Getter\n      kind=Variable\n")
        #expect(getter.kind == "Getter")
        #expect(getter.isStatic && !getter.isAdapter)
        #expect(getter.roots == ["Static"])
        let closure = "  kind=ExplicitClosure\n    kind=Function\n      kind=Number, index=77\n    kind=Number, index=2\n"
        #expect(try parse("kind=Global\n" + closure).discriminator == 2)
        for attribute in ["ObjCAttribute", "NonObjCAttribute", "MergedFunction"] {
            let value = try parse("kind=Global\n  kind=\(attribute)\n" + closure)
            #expect(value.kind == "ExplicitClosure" && value.isAdapter && value.discriminator == 2)
        }
        for tree in [
            "kind=Global\n  kind=FutureAttribute\n" + closure,
            "kind=Global\n  kind=Static\n    kind=Getter\n    kind=Setter\n",
            "kind=Global\n    kind=Getter\n",
            "kind=Global\n  kind=ObjCAttribute\n    kind=UnexpectedChild\n" + closure,
        ] {
            let value = try parse(tree)
            #expect(value.kind == nil && !value.isAdapter)
            #expect(value.evidence.contains("unresolved"))
        }
        let duplicateIndex = try parse("kind=Global\n" + closure + "    kind=Number, index=3\n")
        #expect(duplicateIndex.discriminator == nil)
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.SILSymbolIdentity.parse("Demangling for fixture\nkind=Global\nDemangling for fixture\nkind=Global\n",
                symbols: ["fixture", "fixture"])
        }
    }

    @Test("Private static CGFloat accessors map across the measured SDK overlay spelling")
    func resolvesRealStaticOverlayAccessors() throws {
        try withFixture("""
        import Foundation
        import CoreGraphics
        enum Fixture {}
        fileprivate extension Fixture {
            enum Metrics {
                static let first: CGFloat = 8
                static let second: CGFloat = 9
                static var computed: CGFloat { first + second }
            }
        }
        extension Fixture { static func value() -> CGFloat { Metrics.computed } }
        public func independent() -> Int { 4 }
        """) { request, documents, semanticFile, source in
            let accessors = objects(in: documents).filter {
                $0["_kind"] as? String == "accessor_decl" && $0["get"] as? Bool == true
            }
            #expect(accessors.count == 3)
            let identityFile = try CanonicalSIL.File(text: SwiftFrontend.Driver().emitCanonicalSIL(
                sourceFiles: [source.url], invocation: request.metadata.frontendInvocation, purpose: .implementationIdentity))
            for file in [identityFile, semanticFile] {
                let resolver = try FrontendReceipt.SILFunctionResolver(file: file).resolvingSourceMappings(
                    in: documents, sourcesByPhysicalPath: [source.url.path: source], using: .init(compilerURL: request.compilerURL))
                for accessor in accessors {
                    let function = try #require(try resolver.function(for: accessor, source: source))
                    let identity = try #require(try FrontendReceipt.Demangler(compilerURL: request.compilerURL)
                        .symbolIdentities([function.mangledName])[function.mangledName])
                    #expect(identity.kind == "Getter" && identity.isStatic && !identity.isAdapter)
                    #expect((accessor["usr"] as? String)?.contains("CoreFoundation") == true)
                    #expect(function.mangledName.contains("CoreGraphics"))
                }
                let identities = try FrontendReceipt.Demangler(compilerURL: request.compilerURL)
                    .symbolIdentities(Set(file.functions.map(\.mangledName)))
                let addressors = file.functions.filter { identities[$0.mangledName]?.kind == "UnsafeMutableAddressor" }
                #expect(!addressors.isEmpty)
                let addressorOnly = try FrontendReceipt.SILFunctionResolver(functions: addressors).resolvingSourceMappings(
                    in: documents, sourcesByPhysicalPath: [source.url.path: source], using: .init(compilerURL: request.compilerURL))
                for accessor in accessors {
                    #expect(try addressorOnly.function(for: accessor, source: source) == nil)
                }
            }
            let receipt = try FrontendReceipt.Adapter().generate(request)
            #expect(receipt.receipt.roots.contains { $0.declarationMangledName.contains("independent") })
        }
    }

    @Test("Real C callbacks and reabstraction helpers cannot replace the Swift closure identity")
    func resolvesRealCallbackThunks() throws {
        try withFixture("""
        import Foundation
        enum Fixture {
            static func callC(_ callback: @convention(c) (Int32) -> Int32) -> Int32 { callback(1) }
            static func callback() -> Int32 { callC { $0 + 1 } }
            static func generic<T>(_ callback: @escaping (T) -> T, _ value: T) -> T { callback(value) }
            static func adapted() -> Int { generic({ (value: Int) in value + 1 }, 1) }
            static func erased(_ callback: @escaping () -> Int) -> () -> Any { callback }
        }
        public func independent() -> Int { 4 }
        """) { request, documents, semanticFile, source in
            let closures = objects(in: documents).filter { $0["_kind"] as? String == "closure_expr" }
            #expect(closures.count == 2)
            let identityFile = try CanonicalSIL.File(text: SwiftFrontend.Driver().emitCanonicalSIL(
                sourceFiles: [source.url], invocation: request.metadata.frontendInvocation, purpose: .implementationIdentity))
            for original in [identityFile, semanticFile] {
                let demangler = FrontendReceipt.Demangler(compilerURL: request.compilerURL)
                let identities = try demangler.symbolIdentities(Set(original.functions.map(\.mangledName)))
                #expect(identities.values.contains { $0.wrappers.contains("ObjCAttribute") && $0.isAdapter })
                let helper = try #require(original.functions.first { identities[$0.mangledName]?.kind == "ReabstractionThunkHelper" })
                var file = original
                let resolver = try FrontendReceipt.SILFunctionResolver(file: file).resolvingSourceMappings(
                    in: documents, sourcesByPhysicalPath: [source.url.path: source], using: demangler)
                for closure in closures {
                    let selected = try #require(try resolver.function(forClosure: closure, source: source))
                    #expect(identities[selected.mangledName]?.kind == "ExplicitClosure")
                    #expect(identities[selected.mangledName]?.isAdapter == false)
                    // Use real compiler symbols with an injected shared debug
                    // coordinate; helper coordinates differ across optimizers.
                    var collidingHelper = helper
                    collidingHelper.declarationLocation = selected.declarationLocation
                    file.functions = [selected, collidingHelper]
                    let collision = try FrontendReceipt.SILFunctionResolver(file: file).resolvingCollisions(using: demangler)
                    #expect(try collision.function(forClosure: closure, source: source)?.mangledName == selected.mangledName)
                }
            }
            #expect(try FrontendReceipt.Adapter().generate(request).receipt.roots.contains { $0.declarationMangledName.contains("independent") })
        }
    }

    @Test("Unique closure fallbacks are batched across a demangler batch boundary")
    func batchesUniqueFallbacks() throws {
        let count = 257
        let data = Data(String(repeating: "{}\n", count: count).utf8)
        let source = FrontendReceipt.Adapter.SourceState(logicalPath: "Sources/Closures.swift",
            url: URL(fileURLWithPath: "/tmp/HelixBatchedClosures.swift"), contents: data, contentHash: .sha256(data))
        let symbols = (0..<count).map { "$s7Fixture3fooyyFSiyXEfU" + ($0 == 0 ? "_" : "\($0 - 1)_") }
        let functions = symbols.enumerated().map { index, symbol in
            var function = CanonicalSIL.Function(mangledName: symbol, loweredType: "$@convention(thin) () -> Int", body: "")
            function.declarationLocation = .init(file: source.url.path, line: index + 1, column: 1)
            return function
        }
        let items: [FrontendReceipt.TypedAST.Object] = (0..<count).map {
            ["_kind": "closure_expr", "discriminator": String($0), "range": ["start": $0 * 3, "end": $0 * 3 + 1]]
        }
        let performance = BuildPerformance.Recorder()
        let resolver = try FrontendReceipt.SILFunctionResolver(functions: functions).resolvingSourceMappings(
            in: [["filename": source.url.path, "items": items]], sourcesByPhysicalPath: [source.url.path: source],
            using: .init(compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"), invocationObserver: performance.subprocessObserver))
        for index in items.indices {
            #expect(try resolver.function(forClosure: items[index], source: source)?.mangledName == symbols[index])
        }
        #expect(performance.trace().subprocesses.reduce(0) { $0 + $1.invocationCount } == 2)
    }

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
        #expect(try resolver([witness]).function(for: item, source: source, baseName: "number") == nil)
        for candidates in [[first, second, witness], [first, "future_unknown_symbol", witness], ["future_unknown_symbol", witness], ["future_unknown_symbol"]] {
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
