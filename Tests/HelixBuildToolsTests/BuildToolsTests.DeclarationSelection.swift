import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Declaration-scoped frontend exclusions", .serialized)
struct DeclarationSelectionTests {
    @Test("An unresolved closure excludes its owner, and an unresolved getter excludes the property group")
    func groupsUnresolvedMembers() throws {
        let data = Data("{}\n{}\n{}\n".utf8)
        let source = FrontendReceipt.Adapter.SourceState(logicalPath: "Sources/Feature.swift",
            url: URL(fileURLWithPath: "/tmp/HelixDeclarationGroups.swift"), contents: data, contentHash: .sha256(data))
        let closure: FrontendReceipt.TypedAST.Object = ["_kind": "closure_expr", "discriminator": "0", "range": ["start": 0, "end": 1]]
        let function: FrontendReceipt.TypedAST.Object = ["_kind": "func_decl", "usr": "s:7Fixture3fooyyF",
            "range": ["start": 0, "end": 1], "body": ["elements": [closure]]]
        let property: FrontendReceipt.TypedAST.Object = ["_kind": "var_decl", "usr": "s:7Fixture1pSiv",
            "range": ["start": 3, "end": 4], "accessors": [
                ["_kind": "accessor_decl", "usr": "s:7Fixture1pSivg", "get": true, "range": ["start": 3, "end": 4]],
                ["_kind": "accessor_decl", "usr": "s:7Fixture1pSivs", "set": true, "range": ["start": 3, "end": 4]],
            ]]
        let good: FrontendReceipt.TypedAST.Object = ["_kind": "func_decl", "usr": "s:7Fixture4goodyyF",
            "range": ["start": 6, "end": 7], "body": [:]]
        let symbols = ["$s7Fixture3fooyyF", "$s7Fixture3fooyyFSiyXEfU_", "$s7Fixture3baryyFSiyXEfU_",
                       "$s7Fixture1xSivg", "$s7Fixture1ySivg", "$s7Fixture1pSivs", "$s7Fixture4goodyyF"]
        let functions = symbols.enumerated().map { index, symbol in
            var function = CanonicalSIL.Function(mangledName: symbol, loweredType: "$@convention(thin) () -> Int", body: "")
            function.declarationLocation = .init(file: source.url.path, line: index < 3 ? 1 : (index < 6 ? 2 : 3), column: 1)
            return function
        }
        let documents: [FrontendReceipt.TypedAST.Object] = [["filename": source.url.path, "items": [function, property, good]]]
        let byPath = [source.url.path: source]
        var selection = try FrontendReceipt.DeclarationSelection(documents: documents, sourcesByPhysicalPath: byPath,
            options: .init(failurePolicy: .excludeUnresolved))
        _ = try FrontendReceipt.Adapter().analyzeSILSourceMappings(selection: &selection, sourcesByPhysicalPath: byPath,
            functions: functions, compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"), performance: .init(), stage: "fixture SIL")
        #expect(Set(selection.exclusions.keys.map(\.usr)) == ["s:7Fixture3fooyyF", "s:7Fixture1pSiv"])
        let available = try #require(try selection.availableDocuments(sourcesByPhysicalPath: byPath).first)
        #expect((try FrontendReceipt.TypedAST.items(in: available)).compactMap { ($0 as? FrontendReceipt.TypedAST.Object)?["usr"] as? String } == ["s:7Fixture4goodyyF"])
        #expect(selection.diagnostics.allSatisfy { $0.code == "HLXIDX024" && $0.location != nil && !$0.notes.isEmpty })
        var implicitFunction = function
        implicitFunction["implicit"] = true
        var bodyFile = try CanonicalSIL.File(text: "")
        bodyFile.functions = functions
        bodyFile.functions[0].body = "%0 = function_ref @\(CanonicalSIL.AnyObjectBridge.silMangledName) : $@convention(thin) (@in_guaranteed Any) -> @owned AnyObject"
        let moduleImport: FrontendReceipt.TypedAST.Object = ["_kind": "import_decl", "module_path": ["Foundation"]]
        var observed: [FrontendReceipt.DeclarationSelection.Exclusion] = []
        let rolledBack = try FrontendReceipt.Adapter().discoverImportedOperationSurface(
            documents: [["filename": source.url.path, "items": [moduleImport, implicitFunction, good]]],
            sourcesByPhysicalPath: byPath, moduleName: "Fixture", demangled: [:], silFile: bodyFile,
            failurePolicy: .excludeUnresolved, onExclusions: { observed = $0 })
        #expect(rolledBack.operations.isEmpty && rolledBack.types.isEmpty)
        #expect(rolledBack.exclusions.count == 1 && observed.count == 1)
        implicitFunction["body"] = ["_kind": "brace_stmt"]
        let completeBody = try FrontendReceipt.Adapter().discoverImportedOperationSurface(
            documents: [["filename": source.url.path, "items": [moduleImport, implicitFunction]]],
            sourcesByPhysicalPath: byPath, moduleName: "Fixture", demangled: [:], silFile: bodyFile)
        #expect(completeBody.operations.contains { $0.compilerOperation == .anyObjectBridge })
        var strict = try FrontendReceipt.DeclarationSelection(documents: documents, sourcesByPhysicalPath: byPath, options: nil)
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.Adapter().analyzeSILSourceMappings(selection: &strict, sourcesByPhysicalPath: byPath,
                functions: functions, compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"), performance: .init(), stage: "strict SIL")
        }
        // A closure without a compiler-backed source owner cannot be quarantined.
        var unowned = try FrontendReceipt.DeclarationSelection(documents: [["filename": source.url.path, "items": [closure]]],
            sourcesByPhysicalPath: byPath, options: .init(failurePolicy: .excludeUnresolved))
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.Adapter().analyzeSILSourceMappings(selection: &unowned, sourcesByPhysicalPath: byPath,
                functions: functions, compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"), performance: .init(), stage: "unowned SIL")
        }
    }

    @Test("Partial receipts preserve good entries, evidence, cache isolation and complete compiler inputs")
    func publishesPartialReceipt() throws {
        let fixture = try makeInjectedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var request = fixture.request
        #expect(throws: FrontendReceipt.Error.self) { try FrontendReceipt.Adapter().generate(request) }
        request.indexing = .init(failurePolicy: .excludeUnresolved)
        let cache = FrontendReceipt.CachedAdapter(cache: try .init(rootURL: fixture.root.appendingPathComponent("Cache")))
        let capture = Data("measured-fixture-capture".utf8)
        let output = try cache.generate(request, compilerCapture: capture, workingDirectory: fixture.root)
        try output.receipt.validate()
        #expect(output.receipt.roots.count == 1)
        #expect(output.receipt.roots[0].declarationMangledName.contains("4good"))
        #expect(!output.receipt.declarations.contains { $0.mangledName.contains("6broken") || $0.mangledName.contains("6alias") })
        #expect(!output.receipt.nativeImportCandidates.flatMap(\.silMangledNames).contains { $0.contains("6broken") || $0.contains("6alias") })
        #expect(output.receipt.sources.count == 2)
        #expect(output.excludedDeclarationCount == 1)
        let warning = try #require(output.diagnostics.first { $0.code == "HLXIDX024" })
        #expect(warning.message.contains("Sources/Legacy/Bad.swift"))
        #expect(warning.notes.count == 2)
        for note in warning.notes {
            #expect(note.contains("6aliasA") && note.contains("6aliasB") && note.contains("@convention(thin)"))
            #expect(note.contains("Bad.swift:1:13"))
        }
        let hit = try cache.generate(request, compilerCapture: capture, workingDirectory: fixture.root)
        #expect(hit.diagnostics == output.diagnostics)
        #expect(hit.performance.counters.contains { $0.name == "frontend_cache.module_hit_count" && $0.value == 1 })
        let diagnosed = try FrontendReceipt.Adapter().diagnose(request, stages: [.sourceMappings])
        #expect(diagnosed.passed, "\(diagnosed.checks)")
        #expect(diagnosed.diagnostics.contains { $0 == warning })

        request.indexing = .init()
        #expect(throws: FrontendReceipt.Error.self) { try cache.generate(request, compilerCapture: capture, workingDirectory: fixture.root) }
        request.indexing = .init(include: ["Sources/Feature/**"])
        let scoped = try cache.generate(request, compilerCapture: capture, workingDirectory: fixture.root)
        #expect(scoped.excludedDeclarationCount == 0)
        #expect(scoped.receipt.roots.count == 1 && scoped.receipt.sources.count == 2)
        #expect(scoped.receipt.configuration.modules["DeclarationSelectionFixture"]?.include == ["Sources/Feature/Good.swift"])
        #expect(scoped.performance.counters.contains { $0.name == "frontend_cache.module_miss_count" && $0.value == 1 })
        // A change outside Helix's scope remains a whole-module compiler input.
        try Data("public func broken(_ value: Int) -> Int { value + 2 }\n".utf8).write(to: fixture.request.sources[0].url)
        let edited = try cache.generate(request, compilerCapture: capture, workingDirectory: fixture.root)
        #expect(edited.receipt.sources != scoped.receipt.sources)
        #expect(edited.performance.counters.contains { $0.name == "frontend_cache.module_miss_count" && $0.value == 1 })

        request.indexing = .init(failurePolicy: .excludeUnresolved)
        try Data().write(to: fixture.root.appendingPathComponent("corrupt"))
        let corrupt = try FrontendReceipt.Adapter().diagnose(request)
        #expect(!corrupt.passed)
        #expect(corrupt.checks.contains { $0.stage == "frontend.identity_sil.function_definitions" && $0.status == .failed })
        #expect(corrupt.checks.contains { $0.stage == "frontend.receipt" && $0.status == .blocked })
        request.indexing = .init(include: ["Missing/**"])
        let unmatched = try FrontendReceipt.Adapter().diagnose(request)
        #expect(!unmatched.passed && unmatched.performance?.subprocesses.isEmpty == true)
        #expect(unmatched.checks.contains { $0.detail.contains("matches no captured source") })
    }

    @Test("Host Plan v2 scopes are explicit, and v1 cannot silently carry new policy")
    func validatesOptionsAndMigration() throws {
        let defaults = try JSONDecoder().decode(FrontendReceipt.IndexingOptions.self, from: Data("{}".utf8))
        #expect(defaults.failurePolicy == .strict)
        #expect(defaults.includes(logicalPath: "Sources/Feature.swift"))
        for options in [FrontendReceipt.IndexingOptions(include: []), .init(include: ["/tmp/**"]),
                        .init(exclude: ["Sources/../Feature.swift"]), .init(include: ["Sources\\Feature.swift"])] {
            #expect(throws: FrontendReceipt.Error.self) { try options.validate() }
        }
        var plan = XcodeIntegration.HostPlan(schemaVersion: 1, projectPath: "Example.xcodeproj",
            features: [.init(id: "app", targetName: "Example", moduleName: "Example")],
            profiles: [.init(id: "live", workflow: .liveReload, schemeName: "Example", applicationTargetName: "Example",
                configurationName: "Debug", bundleIdentifier: "dev.helix.example", namespaceSeed: "fixture", featureID: "app")])
        let legacy = try XcodeIntegration.HostPlanCodec.encode(plan)
        #expect(try XcodeIntegration.HostPlanCodec.encode(XcodeIntegration.HostPlanCodec.decode(legacy)) == legacy)
        plan.features[0].indexing = .init(include: ["Sources/Feature/**"], failurePolicy: .excludeUnresolved)
        #expect(throws: XcodeIntegration.Error.self) { try plan.validate() }
        plan.schemaVersion = 2
        let encoded = try XcodeIntegration.HostPlanCodec.encode(plan)
        #expect(try XcodeIntegration.HostPlanCodec.decode(encoded) == plan)
        var state = XcodeIntegration.PrepareState(inputHash: .sha256("fixture"),
            artifacts: [.init(path: "FrontendDiagnostics.json", contentHash: .sha256("[]"), byteCount: 2, permissions: 0o644)],
            eligibleFunctionCount: 1, rejectedFunctionCount: 0)
        let legacyState = try XcodeIntegration.PrepareStateCodec.encode(state)
        #expect(try XcodeIntegration.PrepareStateCodec.encode(XcodeIntegration.PrepareStateCodec.decode(legacyState)) == legacyState)
        state.excludedDeclarationCount = 3
        #expect(try XcodeIntegration.PrepareStateCodec.decode(XcodeIntegration.PrepareStateCodec.encode(state)).excludedDeclarationCount == 3)
    }

    private func makeInjectedFixture() throws -> (root: URL, request: FrontendReceipt.Request) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helix-declaration-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let bad = root.appendingPathComponent("Bad.swift")
        let good = root.appendingPathComponent("Good.swift")
        try Data("public func broken(_ value: Int) -> Int { value }\n".utf8).write(to: bad)
        try Data("public func good(_ value: Int) -> Int { value + 1 }\n".utf8).write(to: good)
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let target = "arm64-apple-ios15.0-simulator"
        let metadata = InterfaceArchive.ReleaseMetadata(bundleID: "dev.helix.declarations", buildNumber: "1",
            shellNamespaceID: .derive(bundleID: "dev.helix.declarations", buildNumber: "1", seed: "fixture"), machOUUIDs: [],
            targetTriple: target, minimumOS: .init(15), xcodeBuild: "fixture", sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(moduleName: "DeclarationSelectionFixture", targetTriple: target, sdkName: sdk.name,
                sdkBuild: sdk.buildVersion, optimization: "-Onone", semanticArguments: ["-parse-as-library", "-g"]),
            transformPipelineHash: ShellBuild.transformPipelineHash, sourceBaselineHash: .sha256("computed"))
        let file = try CanonicalSIL.File(text: frontend.emitCanonicalSIL(sourceFiles: [bad, good], invocation: metadata.frontendInvocation))
        let function = try #require(file.functions.first { $0.mangledName.contains("6broken") })
        let location = try #require(function.declarationLocation)
        try Core.CanonicalJSON.encode(["symbol": function.mangledName, "file": location.file,
            "line": String(location.line), "column": String(location.column)]).write(to: root.appendingPathComponent("Injection.json"))
        // Change only the SIL identity facts after a real emission. Both alias
        // spellings are valid compiler symbols; no display-name demangler is mocked.
        let injection = #"""
        import json, pathlib, re, sys
        root = pathlib.Path(__file__).parent
        config = json.loads((root / 'Injection.json').read_text())
        output = pathlib.Path(sys.argv[1])
        text = output.read_text()
        first = config['symbol'].replace('6broken', '6aliasA')
        second = config['symbol'].replace('6broken', '6aliasB')
        text = text.replace(config['symbol'], first)
        scope = max([int(x) for x in re.findall(r'^sil_scope (\d+)', text, re.M)] + [0]) + 1
        location = json.dumps(config['file']) + ':' + config['line'] + ':' + config['column']
        signature = '$@convention(thin) (Int) -> Int'
        text += f'\nsil_scope {scope} {{ loc {location} parent @{second} : {signature} }}\n'
        definition = f"sil hidden @{second} : {signature} {{\nbb0(%0 : $Int):\n  return %0 : $Int, scope {scope}\n}} // end sil function '{second}'\n"
        text += definition
        if (root / 'corrupt').exists(): text += definition
        output.write_text(text)
        """#
        try Data((injection + "\n").utf8).write(to: root.appendingPathComponent("Inject.py"))
        let script = #"""
        #!/bin/sh
        emit_sil=no
        previous=''
        sil_output=''
        for argument in "$@"; do
          if [ "$argument" = '-emit-sil' ]; then emit_sil=yes; fi
          if [ "$previous" = '-o' ]; then sil_output="$argument"; fi
          previous="$argument"
        done
        /usr/bin/swiftc "$@" || exit $?
        if [ "$emit_sil" = yes ]; then /usr/bin/python3 "${0%/*}/Inject.py" "$sil_output"; fi
        """#
        let compiler = root.appendingPathComponent("swiftc")
        try Data((script + "\n").utf8).write(to: compiler)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compiler.path)
        return (root, .init(metadata: metadata, configuration: .automaticProjectPolicy(moduleName: "DeclarationSelectionFixture"),
            sources: [.init(logicalPath: "Sources/Legacy/Bad.swift", url: bad), .init(logicalPath: "Sources/Feature/Good.swift", url: good)],
            compilerURL: compiler))
    }
}
}
