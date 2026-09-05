import Foundation
import HelixCompiler
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Mixed-language compiler capture replay")
struct CompilerReplay {
    @Test("Oversized source diagnostics include observed size and limit before loading bytes")
    func oversizedSource() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("helix-oversized-\(UUID().uuidString).swift")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 64 * 1_024 * 1_024 + 1)
        try handle.close()
        let sources = [FrontendReceipt.Source(logicalPath: "Sources/Large.swift", url: file)]
        let reads: [() throws -> Void] = [
            { _ = try FrontendReceipt.Adapter().loadSources(sources) },
            { _ = try FrontendReceipt.SourceImports.scan(sources: sources) },
        ]
        for read in reads {
            do {
                try read()
                Issue.record("oversized source was accepted")
            } catch {
                let message = String(describing: error)
                #expect(message.contains("Sources/Large.swift"))
                #expect(message.contains("67108865 bytes"))
                #expect(message.contains("67108864 bytes (64 MiB)"))
            }
        }
    }

    private let required = [
        "-Xfrontend", "-enable-private-imports",
        "-Xfrontend", "-enable-implicit-dynamic",
        "-Xfrontend", "-enable-dynamic-replacement-chaining",
    ]

    @Test("Captured bridging header and C++ mode produce typed AST and canonical SIL together")
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
        let sil = try frontend.emitCanonicalSIL(sourceFiles: [source], invocation: invocation)
        #expect(sil.hasPrefix("sil_stage canonical\n"))
        #expect(sil.contains("BridgedValue"))
        let semanticSIL = try frontend.emitCanonicalSIL(sourceFiles: [source],
            moduleName: invocation.moduleName, optimization: "-Onone",
            additionalArguments: ["-target", invocation.targetTriple, "-sdk", sdk.path] + semantic,
            purpose: .semanticLowering)
        #expect(semanticSIL.contains("ImportedCounter"))
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
