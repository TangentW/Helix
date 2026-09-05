import Foundation
import HelixInterface
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Large-module frontend replay")
struct FrontendReplay {
    @Test("Response files bound argv count and bytes independently")
    func responseFileLimits() throws {
        #expect(!SwiftFrontend.ResponseFile.isRequired(for: Array(repeating: "x", count: 3_000)))
        #expect(SwiftFrontend.ResponseFile.isRequired(for: Array(repeating: "x", count: 3_001)))
        #expect(SwiftFrontend.ResponseFile.isRequired(for: [String(repeating: "界", count: 50_000)]))
        #expect(throws: SwiftFrontend.Error.self) {
            try SwiftFrontend.ResponseFile.render(["invalid\0argument"])
        }
        #expect(throws: SwiftFrontend.Error.self) {
            try SwiftFrontend.Driver(compilerURL: URL(fileURLWithPath: "/bin/echo"))
                .run(arguments: Array(repeating: "x", count: 4_096))
        }
    }

    @Test("Typed AST handles 2,101 primary files including quoted and Unicode paths")
    func largeTypedAST() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frontend = SwiftFrontend.Driver()
        let invocation = try invocation(frontend)
        let sources = try (0..<2_101).map { index in
            let name = index == 0 ? "界 'quote\" back\\ tab\t line\n.swift" : "File\(index).swift"
            let url = directory.appendingPathComponent(name)
            try Data("struct Value\(index) {}\n".utf8).write(to: url)
            return url
        }
        let output = try frontend.emitTypedAST(sourceFiles: sources, invocation: invocation)
        let documents = try SwiftFrontend.TypedAST.parseDocuments(output)
        #expect(documents.count == sources.count)
        #expect(Set(documents.compactMap { $0["filename"] as? String }) == Set(sources.map(\.path)))
    }

    @Test("Nested relative response files survive large direct frontend launches")
    func nestedResponseFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Nested File.swift")
        try Data("struct NestedValue {}\n".utf8).write(to: source)
        try SwiftFrontend.ResponseFile.render([source.lastPathComponent])
            .write(to: directory.appendingPathComponent("nested.resp"), atomically: true, encoding: .utf8)
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let output = try frontend.run(
            arguments: ["-frontend", "-typecheck", "-parse-as-library",
                        "-sdk", sdk.path, "-target", "arm64-apple-ios15.0-simulator"]
                + Array(repeating: "-DRESPONSE_TEST", count: 3_100)
                + ["@nested.resp"],
            workingDirectory: directory
        )
        #expect(output.terminationStatus == 0, "\(output.standardError)")
    }

    @Test("Direct frontend replay resolves the toolchain TaskLocal macro")
    func standardLibraryMacro() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Context.swift")
        try Data("""
        enum Context {
            @TaskLocal static var value: Int = 0
            static func read() -> Int { $value.wrappedValue }
        }
        """.utf8).write(to: source)
        let frontend = SwiftFrontend.Driver()
        let invocation = try invocation(frontend)
        let ast = try frontend.emitTypedAST(sourceFiles: [source], invocation: invocation)
        #expect(ast.contains("TaskLocal"))
        _ = try frontend.typecheckDiagnostics(sourceFiles: [source], invocation: invocation)
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity()
        let info = try #require(JSONSerialization.jsonObject(with: Data(toolchain.targetInfo.utf8)) as? [String: Any])
        let paths = try #require(info["paths"] as? [String: Any])
        let resource = try #require(paths["runtimeResourcePath"] as? String)
        let direct = SwiftFrontend.Driver(compilerURL: URL(fileURLWithPath: resource)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("bin/swift-frontend"))
        _ = try direct.emitCanonicalSIL(sourceFiles: [source], invocation: invocation)
    }

    @Test("Default plugin paths preserve explicit server choice and avoid duplicates")
    func pluginPaths() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = directory.appendingPathComponent("usr/lib/swift")
        let plugins = resource.appendingPathComponent("host/plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try Data().write(to: resource.appendingPathComponent("host/libSwiftInProcPluginServer.dylib"))
        let existing = ["-plugin-path", plugins.path, "-in-process-plugin-server-path", "/explicit/server"]
        #expect(SwiftFrontend.Driver.pluginArguments(resourceDirectory: resource, existing: existing).isEmpty)
        #expect(SwiftFrontend.Driver.pluginArguments(resourceDirectory: directory, existing: []).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func invocation(_ frontend: SwiftFrontend.Driver) throws -> InterfaceArchive.FrontendInvocation {
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        return .init(
            moduleName: "LargeReplayFixture",
            targetTriple: "arm64-apple-ios15.0-simulator",
            sdkName: sdk.name, sdkBuild: sdk.buildVersion,
            optimization: "-Onone", semanticArguments: ["-parse-as-library"]
        )
    }
}
}
