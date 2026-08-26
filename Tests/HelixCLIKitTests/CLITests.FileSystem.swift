import Darwin
import Foundation
import Testing
@testable import HelixCLIKit

extension CLITests {
@Suite("Atomic generated-directory publication")
struct FileSystemPublication {
    @Test("Identical trees are no-ops and partial updates preserve unchanged files")
    func preservesUnchangedArtifacts() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-publication-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let target = root.appendingPathComponent("Generated", isDirectory: true)
        let files = CLI.FileSystem(currentDirectoryURL: root)
        let initial = [
            "Nested/Stable.swift": Data("stable".utf8),
            "Changing.swift": Data("first".utf8),
            "Secret.json": Data("secret".utf8),
        ]

        let created = try files.writeDirectory(
            initial,
            to: target,
            force: true,
            privatePaths: ["Secret.json"]
        )
        let stableURL = target.appendingPathComponent("Nested/Stable.swift")
        let changingURL = target.appendingPathComponent("Changing.swift")
        let stableIdentity = try identity(of: stableURL)
        let changingIdentity = try identity(of: changingURL)
        #expect(created.reusedFileCount == 0)
        #expect(created.writtenFileCount == 3)
        #expect(!created.wasNoOp)

        let noOp = try files.writeDirectory(
            initial,
            to: target,
            force: true,
            privatePaths: ["Secret.json"]
        )
        #expect(noOp.wasNoOp)
        #expect(noOp.reusedFileCount == 3)
        #expect(try identity(of: stableURL) == stableIdentity)
        #expect(try identity(of: changingURL) == changingIdentity)

        var changed = initial
        changed["Changing.swift"] = Data("second".utf8)
        let partial = try files.writeDirectory(
            changed,
            to: target,
            force: true,
            privatePaths: ["Secret.json"]
        )
        #expect(!partial.wasNoOp)
        #expect(partial.reusedFileCount == 2)
        #expect(partial.writtenFileCount == 1)
        #expect(try identity(of: stableURL) == stableIdentity)
        #expect(try identity(of: changingURL) != changingIdentity)
        #expect(try permissions(of: target.appendingPathComponent("Secret.json")) == 0o600)
    }

    @Test("Unexpected and symbolic entries are removed without being followed")
    func rejectsNonArtifactEntries() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-publication-shape-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let outside = root.appendingPathComponent("Outside")
        try Data("outside".utf8).write(to: outside)
        let target = root.appendingPathComponent("Generated", isDirectory: true)
        let files = CLI.FileSystem(currentDirectoryURL: root)
        let artifacts = ["Value.swift": Data("value".utf8)]
        _ = try files.writeDirectory(artifacts, to: target, force: true)
        try Data("extra".utf8).write(
            to: target.appendingPathComponent("Unexpected.txt")
        )
        let value = target.appendingPathComponent("Value.swift")
        try manager.removeItem(at: value)
        try manager.createSymbolicLink(at: value, withDestinationURL: outside)

        let publication = try files.writeDirectory(
            artifacts,
            to: target,
            force: true
        )

        #expect(!publication.wasNoOp)
        #expect(publication.reusedFileCount == 0)
        #expect(publication.writtenFileCount == 1)
        #expect(!manager.fileExists(
            atPath: target.appendingPathComponent("Unexpected.txt").path
        ))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(try Data(contentsOf: value) == Data("value".utf8))
        #expect(try value.resourceValues(forKeys: [.isSymbolicLinkKey])
            .isSymbolicLink == false)
    }

    private func identity(of url: URL) throws -> (UInt64, UInt64) {
        var information = Darwin.stat()
        guard lstat(url.path, &information) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return (UInt64(information.st_dev), UInt64(information.st_ino))
    }

    private func permissions(of url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return UInt16(truncating: try #require(
            attributes[.posixPermissions] as? NSNumber
        ))
    }
}
}
