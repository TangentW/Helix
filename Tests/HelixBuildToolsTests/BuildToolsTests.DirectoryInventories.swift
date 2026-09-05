import Foundation
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Compiler input directory inventories")
struct DirectoryInventories {
    @Test("Reused listings still reread bytes and invalidate nested membership changes")
    func tracksFilesAndMembership() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let first = nested.appendingPathComponent("A.swiftmodule")
        let second = nested.appendingPathComponent("B.swiftmodule")
        try Data("first".utf8).write(to: first)
        let cache = BuildCache.CompilerInputs.DirectoryInventoryCache()
        func snapshot(_ cache: BuildCache.CompilerInputs.DirectoryInventoryCache?) -> BuildCache.CompilerInputs.Snapshot {
            BuildCache.CompilerInputs.capture(
                arguments: ["-I", root.path], currentModuleName: "App", workingDirectory: root,
                importedModules: ["A", "B"], directoryCache: cache
            )
        }
        let original = snapshot(cache)
        #expect(original.isComplete)
        #expect(snapshot(cache) == snapshot(nil))
        #expect(cache.enumerationCount == 1)
        try Data("later".utf8).write(to: first)
        let edited = snapshot(cache)
        #expect(edited == snapshot(nil))
        #expect(edited.contentHash != original.contentHash)
        try Data("second".utf8).write(to: second)
        let added = snapshot(cache)
        #expect(added == snapshot(nil))
        #expect(added.fileCount == 2)
        #expect(added.contentHash != edited.contentHash)
        #expect(cache.enumerationCount == 2)
        try FileManager.default.removeItem(at: second)
        #expect(snapshot(cache) == edited)
        #expect(cache.enumerationCount == 3)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: nested.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path) }
        #expect(!snapshot(cache).isComplete)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
        #expect(snapshot(cache) == snapshot(nil))
        #expect(snapshot(cache).isComplete)
    }

    @Test("Directory links retain cycle policy and retargeting invalidates membership")
    func avoidsDirectoryLinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let search = root.appendingPathComponent("Search")
        let target = root.appendingPathComponent("Target")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("header".utf8).write(to: target.appendingPathComponent("Hidden.h"))
        let link = search.appendingPathComponent("Link.framework")
        let cache = BuildCache.CompilerInputs.DirectoryInventoryCache()
        #expect(try cache.subpaths(of: search, maximumCount: 10).isEmpty)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try cache.subpaths(of: search, maximumCount: 10) == ["Link.framework"])
        #expect(cache.enumerationCount == 2)
        let inputs = BuildCache.CompilerInputs.capture(
            arguments: ["-F", search.path], currentModuleName: "App", workingDirectory: root,
            importedModules: ["Link"], directoryCache: cache
        )
        #expect(!inputs.isComplete)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        try Data("header".utf8).write(to: link.appendingPathComponent("Visible.h"))
        #expect(try cache.subpaths(of: search, maximumCount: 10) == ["Link.framework", "Link.framework/Visible.h"])
    }

    @Test("Shared inventories preserve per-root bounds and bound total retention")
    func boundsRetention() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = [root.appendingPathComponent("First"), root.appendingPathComponent("Second")]
        for directory in roots {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for name in ["A.h", "B.h"] { try Data().write(to: directory.appendingPathComponent(name)) }
        }
        let cache = BuildCache.CompilerInputs.DirectoryInventoryCache(maximumCachedEntries: 3)
        for directory in roots + [roots[0]] {
            #expect(try cache.subpaths(of: directory, maximumCount: 2) == ["A.h", "B.h"])
            #expect(cache.cachedEntryCount == 3)
        }
        #expect(cache.enumerationCount == 3)
        for bound in [0, 1] {
            #expect(throws: BuildCache.Error.self) { try cache.subpaths(of: roots[0], maximumCount: bound) }
        }
    }

    @Test("A root module map fingerprints helper headers without module-name prefixes")
    func tracksRootModuleMapHeaders() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let header = root.appendingPathComponent("Common.h")
        try Data("module Selected { header \"Common.h\" export * }".utf8)
            .write(to: root.appendingPathComponent("module.modulemap"))
        try Data("int original(void);".utf8).write(to: header)
        func snapshot() -> BuildCache.CompilerInputs.Snapshot {
            BuildCache.CompilerInputs.capture(arguments: ["-I", root.path], currentModuleName: "App",
                workingDirectory: root, importedModules: ["Selected"])
        }
        let before = snapshot()
        #expect(before.isComplete)
        #expect(before.fileCount == 2)
        try Data("double revised(void);".utf8).write(to: header)
        #expect(snapshot().contentHash != before.contentHash)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helix-directory-inventory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
}
