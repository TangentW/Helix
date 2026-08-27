import Foundation
import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("Compact Shell document")
struct ShellDocument {
    @Test("Canonical data round-trips the exact verified Shell")
    func canonicalRoundTrip() throws {
        let shell = try makeShell()
        let document = try Verification.ShellDocument(shell: shell)
        let data = try document.encoded()
        let decoded = try Verification.ShellDocument.decode(data)
        let restored = try decoded.makeShellInterface()

        #expect(decoded == document)
        #expect(restored.interfaceHash == shell.interfaceHash)
        #expect(restored.compatibility == shell.compatibility)
        #expect(restored.capabilities == shell.capabilities)
        #expect(restored.entries == shell.entries)

        let encoded = try document.encodedBase64()
        let midpoint = encoded.index(
            encoded.startIndex,
            offsetBy: encoded.count / 2
        )
        let chunks = [
            String(encoded[..<midpoint]),
            String(encoded[midpoint...]),
        ]
        #expect(
            try Verification.ShellDocument.decodeBase64(chunks: chunks)
                == document
        )

        let loader = Verification.ShellDocument.Loader(base64Chunks: chunks)
        #expect(try loader.load().entries == shell.entries)
        #expect(try loader.load().entries == shell.entries)
    }

    @Test("Schema, ordering, canonical bytes, and Base64 framing fail closed")
    func rejectsMalformedDocuments() throws {
        let shell = try makeShell()
        let document = try Verification.ShellDocument(shell: shell)

        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        #expect(throws: Verification.Error.self) {
            try Verification.ShellDocument.decode(pretty.encode(document))
        }

        var wrongSchema = document
        wrongSchema.schemaVersion = 2
        let canonicalWrongSchema = try Core.CanonicalJSON.encode(wrongSchema)
        #expect(throws: Verification.Error.self) {
            try Verification.ShellDocument.decode(canonicalWrongSchema)
        }

        var unordered = document
        unordered.entries.reverse()
        let canonicalUnordered = try Core.CanonicalJSON.encode(unordered)
        #expect(throws: Verification.Error.self) {
            try Verification.ShellDocument.decode(canonicalUnordered)
        }

        #expect(throws: Verification.Error.self) {
            try Verification.ShellDocument.decodeBase64(chunks: ["not base64"])
        }
        let failedLoader = Verification.ShellDocument.Loader(
            base64Chunks: ["not base64"]
        )
        #expect(throws: Verification.Error.self) { try failedLoader.load() }
        #expect(throws: Verification.Error.self) { try failedLoader.load() }
        #expect(throws: Verification.Error.self) {
            try Verification.ShellDocument.decodeBase64(
                chunks: Array(repeating: "", count: 16_385)
            )
        }
        #expect(throws: Verification.Error.self) {
            try Verification.ShellDocument.decodeBase64(
                chunks: Array(
                    repeating: String(repeating: "A", count: 64 * 1_024),
                    count: 2_732
                )
            )
        }
    }

    @Test("Concurrent startup paths share one stable Shell result")
    func concurrentLoads() async throws {
        let shell = try makeShell()
        let encoded = try Verification.ShellDocument(shell: shell).encodedBase64()
        let loader = Verification.ShellDocument.Loader(base64Chunks: [encoded])

        let hashes = try await withThrowingTaskGroup(
            of: Core.Digest.self,
            returning: [Core.Digest].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try loader.load().interfaceHash
                }
            }
            var values: [Core.Digest] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        #expect(hashes.count == 8)
        #expect(Set(hashes) == [shell.interfaceHash])
    }

    private func makeShell() throws -> Verification.ShellInterface {
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "shell-document-fixture"
        )
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.shell-document",
            buildNumber: "1",
            seed: "fixture"
        )
        func entry(_ rawValue: UInt32, name: String) throws
            -> Verification.ResolvedEntry {
            Verification.ResolvedEntry(
                index: .init(rawValue: rawValue),
                key: try Core.FunctionKey.derive(
                    namespace: namespace,
                    module: "Fixture",
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    canonicalDeclaration: name,
                    loweredSignature: .init(
                        parameters: [.init("Swift.Int")],
                        result: "Swift.Int"
                    ),
                    role: .function
                ),
                parameterTypes: [.int64],
                parameterConventions: [.owned],
                resultType: .int64
            )
        }
        return try Verification.ShellInterface(
            interfaceHash: .sha256("shell-document-interface"),
            compatibility: compatibility,
            entries: [
                try entry(0, name: "first(_: Swift.Int) -> Swift.Int"),
                try entry(1, name: "second(_: Swift.Int) -> Swift.Int"),
            ]
        )
    }
}
}
