import Foundation
import HelixCompiler
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Mixed-language compiler capture replay")
struct CompilerReplay {
    private let required = [
        "-Xfrontend", "-enable-private-imports",
        "-Xfrontend", "-enable-implicit-dynamic",
        "-Xfrontend", "-enable-dynamic-replacement-chaining",
    ]

    @Test("Captured bridging header and C++ mode typecheck together")
    func mixedLanguageReplay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-mixed-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let header = directory.appendingPathComponent("Bridging Header.h")
        try Data("""
        #import <Foundation/Foundation.h>
        @interface BridgedValue : NSObject
        @end
        struct ImportedCounter { int value; };
        """.utf8).write(to: header)
        let source = directory.appendingPathComponent("Mixed.swift")
        try Data("""
        func bridged(_ value: BridgedValue) -> BridgedValue { value }
        func counter(_ value: ImportedCounter) -> Int32 { value.value }
        """.utf8).write(to: source)
        let captured = required + [
            "-cxx-interoperability-mode=default", "-Xcc", "-std=gnu++20",
            "-import-objc-header", header.path, "-pch-output-dir", directory.path,
        ]
        let semantic = try XcodeIntegration.CompilerArguments.semanticArguments(from: captured)
        #expect(semantic == ["-parse-as-library"] + captured)
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: "MixedReplayFixture",
            targetTriple: "arm64-apple-ios15.0-simulator",
            sdkName: sdk.name, sdkBuild: sdk.buildVersion,
            optimization: "-Onone", semanticArguments: semantic
        )
        let ast = try frontend.emitTypedAST(sourceFiles: [source], invocation: invocation)
        #expect(ast.contains("BridgedValue"))
        #expect(ast.contains("ImportedCounter"))
    }

    @Test("Interop capture rejects missing and NUL values")
    func malformedArguments() throws {
        for option in ["-import-objc-header", "-pch-output-dir", "-cxx-interoperability-mode"] {
            #expect(throws: XcodeIntegration.CompilerArgumentError.self) {
                try XcodeIntegration.CompilerArguments.semanticArguments(from: required + [option])
            }
            #expect(throws: XcodeIntegration.CompilerArgumentError.self) {
                try XcodeIntegration.CompilerArguments.semanticArguments(from: required + [option, "\0"])
            }
        }
        #expect(try XcodeIntegration.CompilerArguments.semanticArguments(
            from: required + ["-cxx-interoperability-mode", "default"]
        ).suffix(2) == ["-cxx-interoperability-mode", "default"])
    }
}
}
