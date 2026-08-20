import Foundation
import HelixCore
import HelixVerifier
import Testing
@testable import HelixCompiler

extension CompilerTests {
struct FrontendExecutionHarness {
    struct Fixture: Sendable {
        var image: Verification.Image
        var entry: Core.EntryIndex
    }

    static func compile(
        source: String,
        functionName: String,
        moduleName: String = "HelixFrontendExecutionFixture"
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-frontend-execution-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data((source + "\n").utf8).write(to: sourceURL)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: moduleName,
            optimization: "-Onone",
            additionalArguments: ["-Xfrontend", "-disable-sil-perf-optzns"],
            purpose: .semanticLowering
        )
        let file = try CanonicalSIL.File(text: sil)
        let nameMatches = file.functions.filter {
            $0.mangledName.contains(functionName)
        }
        let declarationPattern = try NSRegularExpression(
            pattern: #"\bfunc\s+"#
                + NSRegularExpression.escapedPattern(for: functionName)
                + #"\b"#
        )
        let declarationLines = Set(
            source.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated().compactMap { offset, line -> Int? in
                    let text = String(line)
                    let range = NSRange(text.startIndex..., in: text)
                    return declarationPattern.firstMatch(
                        in: text,
                        range: range
                    ).map { _ in offset + 1 }
                }
        )
        let locatedMatches = file.functions.filter {
            $0.declarationLocation.map {
                declarationLines.contains($0.line)
            } == true
        }
        let candidates = locatedMatches.isEmpty ? nameMatches : locatedMatches
        let functions = candidates.sorted {
            ($0.mangledName.utf8.count, $0.mangledName)
                < ($1.mangledName.utf8.count, $1.mangledName)
        }
        let function = try #require(functions.first)
        let signature = try CanonicalSIL.Lowerer(
            typeEnvironment: file.typeEnvironment
        ).parseFunctionType(function.loweredType)
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.frontend-execution",
            buildNumber: "1",
            seed: "fixture"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: moduleName,
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func \(functionName)",
            loweredSignature: .init(parameters: [], result: "Swift.Void"),
            role: .function
        )
        let shellHash = Core.Digest.sha256(
            "helix-frontend-execution-\(functionName)"
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "frontend-execution-fixture"
        )
        let entry = Core.EntryIndex(rawValue: 0)
        let compiled = try PatchCompiler.Driver().compile(
            .init(
                canonicalSIL: sil,
                mangledName: function.mangledName,
                displayName: functionName,
                functionKey: key,
                entryIndex: entry,
                shellInterfaceHash: shellHash,
                compatibility: compatibility
            )
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: compiled.module.capabilities,
            entries: [
                .init(
                    index: entry,
                    key: key,
                    parameterTypes: signature.parameters,
                    resultType: signature.result,
                    effects: signature.effects
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: compiled.bytecode,
            shell: shell,
            policy: .init(acceptedCapabilities: compiled.module.capabilities)
        )
        return .init(image: image, entry: entry)
    }
}
}
