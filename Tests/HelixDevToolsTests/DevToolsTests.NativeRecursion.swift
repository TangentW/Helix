import Foundation
import HelixCompiler
import HelixCore
import HelixDevTools
import Testing

extension DevToolsTests {
@Suite("Native self-reference rebinding")
struct NativeRecursion {
    #if os(macOS)
    @Test("Typed AST identity rebinds recursive forms and SIL preserves explicit previous")
    func typedASTAndSIL() throws {
        #expect(SwiftFrontend.DynamicReplacement.isPreviousMarkerUSR(
            "s:18HelixLiveReloadAPI0bC0O8previousyxxyYaKXElFZ"
        ))
        #expect(!SwiftFrontend.DynamicReplacement.isPreviousMarkerUSR(
            "s:18HelixLiveReloadAPI5OtherO8previousyxxyYaKXElFZ"
        ))

        let directory = try makeTemporaryDirectory("helix-native-recursion")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Feature.swift")
        let source = """
        import HelixLiveReloadAPI

        public dynamic func globalFactorial(_ n: Int) -> Int {
            n < 2 ? 1 : n * globalFactorial(n - 1)
        }

        public dynamic func globalFactorial(_ value: String) -> String {
            value
        }

        public dynamic func previousFactorial(_ n: Int) -> Int {
            n < 2 ? 1 : n * LiveReload.previous { previousFactorial(n - 1) }
        }

        public dynamic func previousAsyncFactorial(_ n: Int) async throws -> Int {
            n < 2 ? 1 : n * LiveReload.previous {
                try await previousAsyncFactorial(n - 1)
            }
        }

        public dynamic func shadowed(_ n: Int) -> Int {
            func shadowed(_ value: String) -> Int { value.count }
            return shadowed("local") + n
        }

        public dynamic func nestedFactorial(_ n: Int) -> Int {
            let recurse: (Int) -> Int = { value in
                value < 2 ? 1 : value * nestedFactorial(value - 1)
            }
            return recurse(n)
        }

        public dynamic func invalidNestedPrevious(_ n: Int) -> Int {
            let operation = {
                LiveReload.previous { invalidNestedPrevious(n - 1) }
            }
            return operation()
        }

        public dynamic func invalidMultiStatementPrevious(_ n: Int) -> Int {
            LiveReload.previous {
                let next = n - 1
                return invalidMultiStatementPrevious(next)
            }
        }

        public dynamic func invalidForeignPrevious(_ n: Int) -> Int {
            LiveReload.previous { globalFactorial(n) }
        }

        public class Recursor {
            public init() {}

            public dynamic func instanceFactorial(_ n: Int) -> Int {
                n < 2 ? 1 : n * self.instanceFactorial(n - 1)
            }

            public dynamic static func staticFactorial(_ n: Int) -> Int {
                n < 2 ? 1 : n * Self.staticFactorial(n - 1)
            }

            public dynamic class func classFactorial(_ n: Int) -> Int {
                n < 2 ? 1 : n * Self.classFactorial(n - 1)
            }

            public dynamic func genericFactorial<T: BinaryInteger>(_ n: T) -> T {
                n < 2 ? 1 : n * genericFactorial(n - 1)
            }

            public dynamic func asyncFactorial(_ n: Int) async throws -> Int {
                n < 2 ? 1 : n * (try await asyncFactorial(n - 1))
            }

            public dynamic var stableValue: Int { 1 }

            public dynamic var recursiveValue: Int { recursiveValue + 1 }

            public dynamic subscript(index: Int) -> Int { self[index] + 1 }
        }
        """
        let sourceData = Data(source.utf8)
        try sourceData.write(to: sourceURL, options: .atomic)

        let modules = try swiftPMModulesDirectory()
        let buildRoot = modules.deletingLastPathComponent()
        let moduleMaps = [
            "HelixRuntimeSupport",
            "HelixObjectiveCRuntimeSupport",
        ].map {
            buildRoot.appendingPathComponent("\($0).build/module.modulemap")
        }
        let moduleCache = directory.appendingPathComponent("ModuleCache", isDirectory: true)
        let compiler = SwiftFrontend.Driver(compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc"))
        let platformArguments = try macOSPlatformArguments()
        let importArguments = ["-I", modules.path]
            + moduleMaps.flatMap {
                ["-Xcc", "-fmodule-map-file=\($0.path)"]
            }
            + ["-module-cache-path", moduleCache.path]
        let ast = try compiler.run(
            arguments: [
                "-frontend", "-dump-ast", "-dump-ast-format", "json",
                "-module-name", "NativeRecursionFixture",
            ] + platformArguments + importArguments + [sourceURL.path],
            workingDirectory: directory
        )
        try requireSuccess(ast)
        let document = try #require(
            SwiftFrontend.TypedAST.parseDocuments(ast.standardOutput).first
        )
        let declarations = typedObjects(in: document).filter {
            $0["_kind"] as? String == "func_decl" && $0["usr"] as? String != nil
        }
        let selected = try [
            selectFunction("globalFactorial", parameterType: "$sSiD", from: declarations),
            selectFunction("previousFactorial", from: declarations),
            selectFunction("previousAsyncFactorial", from: declarations),
            selectFunction("shadowed", from: declarations),
            selectFunction("nestedFactorial", from: declarations),
            selectFunction("instanceFactorial", from: declarations),
            selectFunction("staticFactorial", from: declarations),
            selectFunction("classFactorial", from: declarations),
            selectFunction("genericFactorial", from: declarations),
            selectFunction("asyncFactorial", from: declarations),
        ]
        func target(
            _ declaration: [String: Any]
        ) throws -> NativeGeneration.SelfReferenceTarget {
            let usr = try #require(declaration["usr"] as? String)
            let baseName = try functionBaseName(declaration)
            let replacementName = SwiftFrontend.DynamicReplacement.replacementBaseName(
                usr: usr,
                baseName: baseName
            )
            return .init(
                mangledName: "$s" + usr.dropFirst(2),
                sourceFilePath: sourceURL.path,
                sourceDeclaration: .init(
                    identity: usr,
                    kind: .function,
                    originalReference: "\(baseName)(_:)",
                    replacementHeader: "func \(replacementName)(_ value: Int) -> Int",
                    members: [
                        .init(
                            role: .functionBody,
                            fallbackBody: "return \(baseName)(value)"
                        ),
                    ]
                ),
                memberRole: .functionBody
            )
        }
        let targets = try selected.map(target)
        let rebinder = NativeGeneration.SelfReferenceRebinder()
        let plans = try rebinder.analyze(
            astOutput: ast.standardOutput,
            sources: [sourceURL.path: sourceData],
            targets: targets
        )
        let planByBaseName = try Dictionary(uniqueKeysWithValues: selected.map { declaration in
            let baseName = try functionBaseName(declaration)
            let usr = try #require(declaration["usr"] as? String)
            return (baseName, try #require(plans["$s" + usr.dropFirst(2)]))
        })

        for name in [
            "globalFactorial", "nestedFactorial", "instanceFactorial",
            "staticFactorial", "classFactorial", "genericFactorial", "asyncFactorial",
        ] {
            #expect(planByBaseName[name]?.currentReferenceCount == 1)
            #expect(planByBaseName[name]?.explicitPreviousCount == 0)
        }
        #expect(planByBaseName["previousFactorial"]?.currentReferenceCount == 0)
        #expect(planByBaseName["previousFactorial"]?.explicitPreviousCount == 1)
        #expect(planByBaseName["previousAsyncFactorial"]?.currentReferenceCount == 0)
        #expect(planByBaseName["previousAsyncFactorial"]?.explicitPreviousCount == 1)
        #expect(planByBaseName["shadowed"]?.currentReferenceCount == 0)

        for (name, expected) in [
            ("invalidNestedPrevious", "cannot be nested in another closure"),
            ("invalidMultiStatementPrevious", "single-expression closure"),
            ("invalidForeignPrevious", "does not reference the function being replaced"),
        ] {
            let declaration = try selectFunction(name, from: declarations)
            do {
                _ = try rebinder.analyze(
                    astOutput: ast.standardOutput,
                    sources: [sourceURL.path: sourceData],
                    targets: [try target(declaration)]
                )
                Issue.record("expected invalid previous marker for \(name)")
            } catch let error as NativeGeneration.SelfReferenceError {
                #expect(error.description.contains(expected))
            }
        }

        func accessorTarget(
            name: String,
            kind: Core.DynamicReplacement.DeclarationKind,
            originalReference: String,
            replacementHeader: (String) -> String
        ) throws -> NativeGeneration.SelfReferenceTarget {
            let parent = try #require(typedObjects(in: document).first {
                let expectedKind =
                    kind == .property ? "var_decl" : "subscript_decl"
                guard $0["_kind"] as? String == expectedKind,
                      $0["usr"] as? String != nil,
                      let declarationName = $0["name"] as? [String: Any],
                      let base = declarationName["base_name"] as? [String: Any]
                else { return false }
                return base["name"] as? String == name
                    || base["special"] as? String == name
            })
            let parentUSR = try #require(parent["usr"] as? String)
            let accessors = try #require(parent["accessors"] as? [[String: Any]])
            let getter = try #require(accessors.first { $0["get"] as? Bool == true })
            let getterUSR = try #require(getter["usr"] as? String)
            let replacementName = SwiftFrontend.DynamicReplacement.replacementBaseName(
                usr: parentUSR,
                baseName: name
            )
            return .init(
                mangledName: "$s" + getterUSR.dropFirst(2),
                sourceFilePath: sourceURL.path,
                sourceDeclaration: .init(
                    identity: parentUSR,
                    kind: kind,
                    originalReference: originalReference,
                    replacementHeader: replacementHeader(replacementName),
                    members: [
                        .init(role: .getter, header: "get", fallbackBody: "return 0"),
                    ],
                    enclosingPrefix: "extension Recursor {",
                    enclosingSuffix: "}"
                ),
                memberRole: .getter
            )
        }
        let stableAccessor = try accessorTarget(
            name: "stableValue",
            kind: .property,
            originalReference: "stableValue",
            replacementHeader: { "var \($0): Int" }
        )
        let stablePlan = try #require(rebinder.analyze(
            astOutput: ast.standardOutput,
            sources: [sourceURL.path: sourceData],
            targets: [stableAccessor]
        )[stableAccessor.mangledName])
        #expect(stablePlan.edits.isEmpty)

        for recursiveAccessor in [
            try accessorTarget(
                name: "recursiveValue",
                kind: .property,
                originalReference: "recursiveValue",
                replacementHeader: { "var \($0): Int" }
            ),
            try accessorTarget(
                name: "subscript",
                kind: .subscriptDeclaration,
                originalReference: "subscript(index:)",
                replacementHeader: { "subscript(\($0) index: Int) -> Int" }
            ),
        ] {
            #expect(throws: NativeGeneration.SelfReferenceError.self) {
                _ = try rebinder.analyze(
                    astOutput: ast.standardOutput,
                    sources: [sourceURL.path: sourceData],
                    targets: [recursiveAccessor]
                )
            }
        }

        let roots = try selected.map { declaration -> NativeGeneration.ReplacementRoot in
            let baseName = try functionBaseName(declaration)
            let usr = try #require(declaration["usr"] as? String)
            let plan = try #require(plans["$s" + usr.dropFirst(2)])
            let bodyObject = try #require(declaration["body"] as? [String: Any])
            let bodyRange = try typedRange(bodyObject)
            let extracted = NativeGeneration.ExtractedBody(
                sourceRange: (bodyRange.lowerBound + 1)..<(bodyRange.upperBound - 1),
                contents: String(
                    decoding: sourceData[(bodyRange.lowerBound + 1)..<(bodyRange.upperBound - 1)],
                    as: UTF8.self
                )
            )
            let rewritten = try rebinder.rewrite(extracted, using: plan)
            let declarationText: String
            let enclosure: (String, String)
            switch baseName {
            case "instanceFactorial":
                declarationText = "public func \(plan.replacementBaseName)(_ n: Int) -> Int"
                enclosure = ("extension Recursor {", "}")
            case "staticFactorial":
                declarationText = "public static func \(plan.replacementBaseName)(_ n: Int) -> Int"
                enclosure = ("extension Recursor {", "}")
            case "classFactorial":
                declarationText = "public class func \(plan.replacementBaseName)(_ n: Int) -> Int"
                enclosure = ("extension Recursor {", "}")
            case "genericFactorial":
                declarationText = "public func \(plan.replacementBaseName)<T: BinaryInteger>(_ n: T) -> T"
                enclosure = ("extension Recursor {", "}")
            case "asyncFactorial":
                declarationText = "public func \(plan.replacementBaseName)(_ n: Int) async throws -> Int"
                enclosure = ("extension Recursor {", "}")
            case "previousAsyncFactorial":
                declarationText = "public func \(plan.replacementBaseName)(_ n: Int) async throws -> Int"
                enclosure = ("", "")
            default:
                declarationText = "public func \(plan.replacementBaseName)(_ n: Int) -> Int"
                enclosure = ("", "")
            }
            return .init(
                sourceDeclaration: .init(
                    identity: usr,
                    kind: .function,
                    originalReference: "\(baseName)(_:)",
                    replacementHeader: declarationText,
                    members: [
                        .init(
                            role: .functionBody,
                            fallbackBody: "return \(baseName)(n)"
                        ),
                    ],
                    enclosingPrefix: enclosure.0,
                    enclosingSuffix: enclosure.1
                ),
                memberRole: .functionBody,
                body: rewritten,
            )
        }

        let featureModule = directory.appendingPathComponent("NativeRecursionFixture.swiftmodule")
        let feature = try compiler.run(
            arguments: [sourceURL.path, "-emit-module", "-parse-as-library",
                "-module-name", "NativeRecursionFixture",
                "-emit-module-path", featureModule.path,
                "-Xfrontend", "-enable-implicit-dynamic",
                "-Xfrontend", "-enable-private-imports",
            ] + platformArguments + importArguments,
            workingDirectory: directory
        )
        try requireSuccess(feature)
        let generatedSource = try NativeGeneration.SourceGenerator().generate(
            moduleName: "NativeRecursionFixture",
            sourceFileLogicalPath: "Feature.swift",
            imports: ["HelixLiveReloadAPI"],
            roots: roots
        )
        #expect(!generatedSource.contains("LiveReload.previous"))
        let generatedURL = directory.appendingPathComponent("Generated.swift")
        try Data(generatedSource.utf8).write(to: generatedURL, options: .atomic)
        let sil = try compiler.run(
            arguments: [generatedURL.path, "-emit-silgen", "-parse-as-library",
                "-module-name", "NativeRecursionPatch",
                "-I", directory.path,
                "-Xfrontend", "-enable-private-imports",
                "-Xfrontend", "-enable-dynamic-replacement-chaining",
                "-o", "-",
            ] + platformArguments + importArguments,
            workingDirectory: directory
        )
        try requireSuccess(sil)

        for name in [
            "globalFactorial", "nestedFactorial", "instanceFactorial",
            "staticFactorial", "classFactorial", "genericFactorial", "asyncFactorial",
        ] {
            let replacementName = try #require(planByBaseName[name]?.replacementBaseName)
            let section = try silFunction(named: replacementName, in: sil.standardOutput)
            #expect(section.contains("dynamic_replacement_for"))
            #expect(sil.standardOutput.split(separator: "\n").contains {
                $0.contains("function_ref") && $0.contains(replacementName)
            })
        }
        for name in ["previousFactorial", "previousAsyncFactorial"] {
            let previousName = try #require(planByBaseName[name]?.replacementBaseName)
            let previousSection = try silFunction(named: previousName, in: sil.standardOutput)
            #expect(previousSection.contains("prev_dynamic_function_ref"))
        }
        #expect(sil.standardOutput.split(separator: "\n").count {
            $0.contains(" = prev_dynamic_function_ref")
        } == 2)
    }
    #endif
}
}

#if os(macOS)
private func typedObjects(in value: Any) -> [[String: Any]] {
    var result: [[String: Any]] = []
    func visit(_ value: Any) {
        if let object = value as? [String: Any] {
            result.append(object)
            object.values.forEach(visit)
        } else if let array = value as? [Any] {
            array.forEach(visit)
        }
    }
    visit(value)
    return result
}

private func selectFunction(
    _ baseName: String,
    parameterType: String? = nil,
    from declarations: [[String: Any]]
) throws -> [String: Any] {
    let matches = try declarations.filter { declaration in
        guard try functionBaseName(declaration) == baseName else { return false }
        guard let parameterType else { return true }
        let parameters = declaration["params"] as? [String: Any]
        let items = parameters?["params"] as? [[String: Any]]
        return items?.first?["interface_type"] as? String == parameterType
    }
    return try #require(matches.count == 1 ? matches[0] : nil)
}

private func functionBaseName(_ declaration: [String: Any]) throws -> String {
    let name = try #require(declaration["name"] as? [String: Any])
    let base = try #require(name["base_name"] as? [String: Any])
    return try #require(base["name"] as? String)
}

private func typedRange(_ object: [String: Any]) throws -> Range<Int> {
    let range = try #require(object["range"] as? [String: Any])
    let start = try #require(range["start"] as? Int)
    let end = try #require(range["end"] as? Int)
    return start..<(end + 1)
}

private func silFunction(named name: String, in sil: String) throws -> String {
    let pattern = #"(?m)^// [^\n]*"# + NSRegularExpression.escapedPattern(for: name)
    let start = try #require(sil.range(of: pattern, options: .regularExpression))
    let end = try #require(
        sil.range(of: "\n} // end sil function", range: start.lowerBound..<sil.endIndex)
    )
    return String(sil[start.lowerBound..<end.upperBound])
}

private func requireSuccess(_ output: SwiftFrontend.Output) throws {
    guard output.terminationStatus == 0 else {
        throw SwiftFrontend.Error.compilationFailed(
            status: output.terminationStatus,
            diagnostics: output.standardError
        )
    }
}

private func makeTemporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func swiftPMModulesDirectory() throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
    var candidates: [URL] = []
    if let enumerator = FileManager.default.enumerator(
        at: buildRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) {
        for case let file as URL in enumerator
        where file.lastPathComponent == "HelixLiveReloadAPI.swiftmodule" {
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
    return try #require(candidates.sorted(by: { $0.path < $1.path }).first)
}

private func macOSPlatformArguments() throws -> [String] {
    let output = try SwiftFrontend.Driver(
        compilerURL: URL(fileURLWithPath: "/usr/bin/xcrun")
    ).run(arguments: ["--sdk", "macosx", "--show-sdk-path"])
    try requireSuccess(output)
    let sdk = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    #if arch(x86_64)
    let target = "x86_64-apple-macosx14.0"
    #else
    let target = "arm64-apple-macosx14.0"
    #endif
    return ["-target", target, "-sdk", sdk]
}
#endif
