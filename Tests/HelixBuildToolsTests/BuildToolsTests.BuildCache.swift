import Darwin
import Foundation
import HelixCore
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Owner-local content-addressed build cache")
struct BuildCacheStore {
    private enum ValidationError: Swift.Error {
        case invalid
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var productionCount = 0
        private var values: [BuildCache.Value] = []

        func produced() {
            lock.withLock { productionCount += 1 }
        }

        func append(_ value: BuildCache.Value) {
            lock.withLock { values.append(value) }
        }

        func snapshot() -> (Int, [BuildCache.Value]) {
            lock.withLock { (productionCount, values) }
        }
    }

    @Test("A generated entry is canonical, private, and reused")
    func generatesAndReusesEntry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: fixture.root.path
        )
        try BuildCache.Store.validateAncestorChain(fixture.root)
        let key = Core.Digest.sha256("module")
        let data = Data("receipt".utf8)
        var productionCount = 0

        let generated = try fixture.store.value(
            namespace: .moduleFrontend,
            key: key,
            maximumBytes: 1_024
        ) {
            productionCount += 1
            return data
        }
        let hit = try fixture.store.value(
            namespace: .moduleFrontend,
            key: key,
            maximumBytes: 1_024
        ) {
            productionCount += 1
            return Data("unexpected".utf8)
        }

        #expect(generated == .init(data: data, source: .generated))
        #expect(hit == .init(data: data, source: .hit))
        #expect(productionCount == 1)
        let entry = fixture.root
            .appendingPathComponent("v1/module_frontend")
            .appendingPathComponent(key.hex)
        #expect(try permissions(of: fixture.root) == 0o700)
        #expect(try permissions(of: entry) == 0o700)
        #expect(try permissions(of: entry.appendingPathComponent("Manifest.json")) == 0o600)
        #expect(try permissions(of: entry.appendingPathComponent("Payload.bin")) == 0o600)
    }

    @Test("Corrupt entries are repaired instead of trusted")
    func repairsCorruptEntry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let key = Core.Digest.sha256("probe")
        _ = try fixture.store.value(
            namespace: .managedProbe,
            key: key,
            maximumBytes: 1_024
        ) { Data("first".utf8) }
        let payload = fixture.root
            .appendingPathComponent("v1/managed_probe")
            .appendingPathComponent(key.hex)
            .appendingPathComponent("Payload.bin")
        try Data("tampered".utf8).write(to: payload)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: payload.path
        )

        let repaired = try fixture.store.value(
            namespace: .managedProbe,
            key: key,
            maximumBytes: 1_024
        ) { Data("second".utf8) }
        #expect(repaired == .init(data: Data("second".utf8), source: .repaired))
        let hit = try fixture.store.value(
            namespace: .managedProbe,
            key: key,
            maximumBytes: 1_024
        ) { Data("unexpected".utf8) }
        #expect(hit == .init(data: Data("second".utf8), source: .hit))
    }

    @Test("A consumer-rejected payload is quarantined and regenerated")
    func repairsSemanticallyInvalidEntry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let key = Core.Digest.sha256("semantic")
        _ = try fixture.store.value(
            namespace: .moduleFrontend,
            key: key,
            maximumBytes: 1_024
        ) { Data("structurally-valid-but-stale".utf8) }

        let repaired = try fixture.store.value(
            namespace: .moduleFrontend,
            key: key,
            maximumBytes: 1_024,
            validate: {
                guard $0 == Data("current".utf8) else {
                    throw ValidationError.invalid
                }
            }
        ) { Data("current".utf8) }

        #expect(repaired.source == .repaired)
        #expect(repaired.data == Data("current".utf8))
    }

    @Test("Concurrent requests coalesce behind one producer")
    func coalescesConcurrentProduction() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let key = Core.Digest.sha256("shared")
        let state = State()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "dev.helix.tests.build-cache",
            attributes: .concurrent
        )

        for _ in 0..<16 {
            group.enter()
            queue.async {
                defer { group.leave() }
                let value = try! fixture.store.value(
                    namespace: .symbolGraph,
                    key: key,
                    maximumBytes: 1_024
                ) {
                    state.produced()
                    Thread.sleep(forTimeInterval: 0.05)
                    return Data("shared-value".utf8)
                }
                state.append(value)
            }
        }
        group.wait()

        let snapshot = state.snapshot()
        #expect(snapshot.0 == 1)
        #expect(snapshot.1.count == 16)
        #expect(snapshot.1.allSatisfy { $0.data == Data("shared-value".utf8) })
        #expect(snapshot.1.filter { $0.source == .generated }.count == 1)
        #expect(snapshot.1.filter { $0.source == .hit }.count == 15)
    }

    @Test("Unsafe roots bypass the cache without changing build semantics")
    func bypassesUnsafeRoots() throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appendingPathComponent(
            "helix-cache-unsafe-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: parent) }
        let writable = parent.appendingPathComponent("writable", isDirectory: true)
        try manager.createDirectory(at: writable, withIntermediateDirectories: false)
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: writable.path
        )
        let writableStore = try BuildCache.Store(rootURL: writable)
        let writableValue = try writableStore.value(
            namespace: .moduleFrontend,
            key: .sha256("unsafe"),
            maximumBytes: 1_024
        ) { Data("uncached".utf8) }
        #expect(writableValue.source == .bypassed)
        #expect(try permissions(of: writable) == 0o777)

        let writableParent = parent.appendingPathComponent(
            "writable-parent",
            isDirectory: true
        )
        try manager.createDirectory(
            at: writableParent,
            withIntermediateDirectories: false
        )
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: writableParent.path
        )
        let nestedRoot = writableParent.appendingPathComponent(
            "private-child",
            isDirectory: true
        )
        let nestedStore = try BuildCache.Store(rootURL: nestedRoot)
        let nestedValue = try nestedStore.value(
            namespace: .moduleFrontend,
            key: .sha256("unsafe-parent"),
            maximumBytes: 1_024
        ) { Data("uncached".utf8) }
        #expect(nestedValue.source == .bypassed)
        #expect(!manager.fileExists(
            atPath: nestedRoot.appendingPathComponent("v1").path
        ))

        let target = parent.appendingPathComponent("target", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        let linkedStore = try BuildCache.Store(rootURL: link)
        let linkedValue = try linkedStore.value(
            namespace: .moduleFrontend,
            key: .sha256("linked"),
            maximumBytes: 1_024
        ) { Data("uncached".utf8) }
        #expect(linkedValue.source == .bypassed)
        #expect(!manager.fileExists(atPath: target.appendingPathComponent("v1").path))
    }

    @Test("Compiler input identity tracks interfaces but ignores implementation outputs")
    func fingerprintsCompilerInterfaces() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-compiler-inputs-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let external = root.appendingPathComponent("External.swiftmodule")
        let current = root.appendingPathComponent("Current.swiftmodule")
        let object = root.appendingPathComponent("External.o")
        try Data("interface-v1".utf8).write(to: external)
        try Data("current-v1".utf8).write(to: current)
        try Data("implementation-v1".utf8).write(to: object)
        let arguments = ["-I", root.path]

        let first = BuildCache.CompilerInputs.capture(
            arguments: arguments,
            currentModuleName: "Current",
            workingDirectory: root
        )
        let clangForwarded = BuildCache.CompilerInputs.capture(
            arguments: ["-Xcc", "-I", "-Xcc", root.path],
            currentModuleName: "Current",
            workingDirectory: root
        )
        try Data("implementation-v2".utf8).write(to: object)
        let implementationChanged = BuildCache.CompilerInputs.capture(
            arguments: arguments,
            currentModuleName: "Current",
            workingDirectory: root
        )
        try Data("current-v2".utf8).write(to: current)
        let currentModuleChanged = BuildCache.CompilerInputs.capture(
            arguments: arguments,
            currentModuleName: "Current",
            workingDirectory: root
        )
        try Data("interface-v2".utf8).write(to: external)
        let interfaceChanged = BuildCache.CompilerInputs.capture(
            arguments: arguments,
            currentModuleName: "Current",
            workingDirectory: root
        )

        #expect(first.isComplete)
        #expect(first.fileCount == 1)
        #expect(clangForwarded == first)
        #expect(implementationChanged == first)
        #expect(currentModuleChanged == first)
        #expect(interfaceChanged.contentHash != first.contentHash)
    }

    @Test("Compiler input identity distinguishes missing and newly created roots")
    func fingerprintsMissingCompilerSearchRoots() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-missing-compiler-inputs-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? manager.removeItem(at: root) }
        let missing = BuildCache.CompilerInputs.capture(
            arguments: ["-I", root.path],
            currentModuleName: "Current",
            workingDirectory: manager.temporaryDirectory
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        let created = BuildCache.CompilerInputs.capture(
            arguments: ["-I", root.path],
            currentModuleName: "Current",
            workingDirectory: manager.temporaryDirectory
        )

        #expect(missing.isComplete)
        #expect(created.isComplete)
        #expect(missing.contentHash != created.contentHash)
    }

    @Test("Compiler input directory traversal stops at its configured bound")
    func boundsCompilerInputTraversal() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-bounded-compiler-inputs-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appendingPathComponent("A.h"))
        try Data("b".utf8).write(to: root.appendingPathComponent("B.h"))

        #expect(try BuildCache.CompilerInputs.boundedSubpaths(
            of: root,
            maximumCount: 2
        ) == ["A.h", "B.h"])
        #expect(throws: BuildCache.Error.self) {
            _ = try BuildCache.CompilerInputs.boundedSubpaths(
                of: root,
                maximumCount: 1
            )
        }
    }

    @Test("Compiler input identity ignores modules outside the imported surface")
    func fingerprintsOnlyImportedModules() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-selected-compiler-inputs-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected.swiftmodule")
        let unrelated = root.appendingPathComponent("Unrelated.swiftmodule")
        try Data("selected-v1".utf8).write(to: selected)
        try Data("unrelated-v1".utf8).write(to: unrelated)

        func snapshot() -> BuildCache.CompilerInputs.Snapshot {
            BuildCache.CompilerInputs.capture(
                arguments: ["-I", root.path],
                currentModuleName: "Current",
                workingDirectory: root,
                importedModules: ["Selected"]
            )
        }

        let first = snapshot()
        try Data("unrelated-v2".utf8).write(to: unrelated)
        let unrelatedChanged = snapshot()
        try Data("selected-v2".utf8).write(to: selected)
        let selectedChanged = snapshot()

        #expect(first.isComplete)
        #expect(first.importedModules == ["Selected"])
        #expect(first.fileCount == 1)
        #expect(unrelatedChanged == first)
        #expect(selectedChanged.contentHash != first.contentHash)
    }

    @Test("A selected Clang module fingerprints its local module-map surface")
    func fingerprintsSelectedClangModule() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-clang-compiler-inputs-\(UUID().uuidString)",
            isDirectory: true
        )
        let selectedRoot = root.appendingPathComponent("Selected", isDirectory: true)
        try manager.createDirectory(
            at: selectedRoot,
            withIntermediateDirectories: true
        )
        defer { try? manager.removeItem(at: root) }
        let moduleMap = selectedRoot.appendingPathComponent("module.modulemap")
        let header = selectedRoot.appendingPathComponent("Selected.h")
        let unrelated = root.appendingPathComponent("Unrelated.h")
        try Data("module Selected { header \"Selected.h\" }".utf8)
            .write(to: moduleMap)
        try Data("typedef int SelectedValue;".utf8).write(to: header)
        try Data("typedef int UnrelatedValue;".utf8).write(to: unrelated)

        func snapshot() -> BuildCache.CompilerInputs.Snapshot {
            BuildCache.CompilerInputs.capture(
                arguments: ["-I", root.path],
                currentModuleName: "Current",
                workingDirectory: root,
                importedModules: ["Selected"]
            )
        }

        let first = snapshot()
        try Data("typedef long UnrelatedValue;".utf8).write(to: unrelated)
        let unrelatedChanged = snapshot()
        try Data("typedef long SelectedValue;".utf8).write(to: header)
        let selectedChanged = snapshot()

        #expect(first.isComplete)
        #expect(first.fileCount == 2)
        #expect(unrelatedChanged == first)
        #expect(selectedChanged.contentHash != first.contentHash)
    }

    @Test("Compiler-visible aliases enter identity even when bytes are shared")
    func fingerprintsLogicalModuleAliases() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-aliased-compiler-inputs-\(UUID().uuidString)",
            isDirectory: true
        )
        let module = root.appendingPathComponent(
            "Selected.swiftmodule",
            isDirectory: true
        )
        try manager.createDirectory(at: module, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let generic = module.appendingPathComponent("arm64.swiftmodule")
        try Data("selected-interface".utf8).write(to: generic)

        func snapshot() -> BuildCache.CompilerInputs.Snapshot {
            BuildCache.CompilerInputs.capture(
                arguments: ["-I", root.path],
                currentModuleName: "Current",
                workingDirectory: root,
                importedModules: ["Selected"]
            )
        }

        let first = snapshot()
        try manager.createSymbolicLink(
            at: module.appendingPathComponent("arm64-apple-ios.swiftmodule"),
            withDestinationURL: generic
        )
        let aliased = snapshot()

        #expect(first.isComplete)
        #expect(aliased.isComplete)
        #expect(first.fileCount == 1)
        #expect(aliased.fileCount == 1)
        #expect(aliased.contentHash != first.contentHash)
    }

    @Test("VFS overlays fingerprint their external file contents")
    func fingerprintsVFSOverlayContents() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-overlay-compiler-inputs-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let header = root.appendingPathComponent("Mapped.h")
        let overlay = root.appendingPathComponent("overlay.json")
        try Data("typedef int MappedValue;".utf8).write(to: header)
        let document: [String: Any] = [
            "version": 0,
            "roots": [[
                "type": "file",
                "name": "/virtual/Mapped.h",
                "external-contents": header.path,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: overlay)

        func snapshot() -> BuildCache.CompilerInputs.Snapshot {
            BuildCache.CompilerInputs.capture(
                arguments: ["-Xcc", "-ivfsoverlay", "-Xcc", overlay.path],
                currentModuleName: "Current",
                workingDirectory: root,
                importedModules: []
            )
        }

        let first = snapshot()
        try Data("typedef long MappedValue;".utf8).write(to: header)
        let changed = snapshot()

        #expect(first.isComplete)
        #expect(first.fileCount == 2)
        #expect(first.explicitPaths.contains(header.path))
        #expect(changed.contentHash != first.contentHash)
    }

    @Test("Bridging-header maps fingerprint their mapped headers")
    func fingerprintsBridgingHeaderMapContents() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-hmap-compiler-inputs-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let bridge = root.appendingPathComponent("Bridge.h")
        let mapped = root.appendingPathComponent("Mapped.h")
        let sibling = root.appendingPathComponent("Sibling.h")
        let map = root.appendingPathComponent("Headers.hmap")
        try Data("#include <Mapped.h>\n#include \"Sibling.h\"".utf8)
            .write(to: bridge)
        try Data("typedef int MappedValue;".utf8).write(to: mapped)
        try Data("typedef int SiblingValue;".utf8).write(to: sibling)
        try headerMap(
            key: "Mapped.h",
            prefix: root.path + "/",
            suffix: "Mapped.h"
        ).write(to: map)

        func snapshot() -> BuildCache.CompilerInputs.Snapshot {
            BuildCache.CompilerInputs.capture(
                arguments: [
                    "-import-objc-header", bridge.path,
                    "-Xcc", "-I", "-Xcc", map.path,
                ],
                currentModuleName: "Current",
                workingDirectory: root,
                importedModules: []
            )
        }

        let first = snapshot()
        try Data("typedef long SiblingValue;".utf8).write(to: sibling)
        let siblingChanged = snapshot()
        try Data("typedef long MappedValue;".utf8).write(to: mapped)
        let changed = snapshot()

        #expect(first.isComplete)
        #expect(first.fileCount == 4)
        #expect(first.explicitPaths.contains(mapped.path))
        #expect(siblingChanged.contentHash != first.contentHash)
        #expect(changed.contentHash != first.contentHash)
    }

    @Test("Common Clang search and explicit-input forms retain content identity")
    func fingerprintsCommonClangPathForms() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "helix-clang-path-forms-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let mapped = root.appendingPathComponent("Mapped.h")
        let map = root.appendingPathComponent("Headers.hmap")
        let moduleMap = root.appendingPathComponent("module.modulemap")
        try Data("typedef int MappedValue;".utf8).write(to: mapped)
        try headerMap(
            key: "Mapped.h",
            prefix: root.path + "/",
            suffix: "Mapped.h"
        ).write(to: map)
        try Data("module Selected { header \"Mapped.h\" }".utf8)
            .write(to: moduleMap)

        func quoteSnapshot() -> BuildCache.CompilerInputs.Snapshot {
            BuildCache.CompilerInputs.capture(
                arguments: ["-Xcc", "-iquote", "-Xcc", map.path],
                currentModuleName: "Current",
                workingDirectory: root,
                importedModules: []
            )
        }
        func moduleMapSnapshot() -> BuildCache.CompilerInputs.Snapshot {
            BuildCache.CompilerInputs.capture(
                arguments: [
                    "-Xfrontend", "-fmodule-map-file",
                    "-Xfrontend", moduleMap.path,
                ],
                currentModuleName: "Current",
                workingDirectory: root,
                importedModules: ["Selected"]
            )
        }

        let quoteFirst = quoteSnapshot()
        let moduleMapFirst = moduleMapSnapshot()
        try Data("typedef long MappedValue;".utf8).write(to: mapped)
        let quoteChanged = quoteSnapshot()
        let moduleMapHeaderChanged = moduleMapSnapshot()
        try Data("module Selected { header \"Mapped.h\" export * }".utf8)
            .write(to: moduleMap)
        let moduleMapChanged = moduleMapSnapshot()

        #expect(quoteFirst.isComplete)
        #expect(quoteFirst.fileCount == 2)
        #expect(quoteChanged.contentHash != quoteFirst.contentHash)
        #expect(moduleMapFirst.isComplete)
        #expect(moduleMapFirst.explicitPaths == [moduleMap.path])
        #expect(moduleMapHeaderChanged.contentHash != moduleMapFirst.contentHash)
        #expect(moduleMapChanged.contentHash != moduleMapHeaderChanged.contentHash)
    }

    private func makeFixture() throws -> (root: URL, store: BuildCache.Store) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-build-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        return (root, try BuildCache.Store(rootURL: root))
    }

    private func permissions(of url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return UInt16(truncating: try #require(
            attributes[.posixPermissions] as? NSNumber
        ))
    }

    private func headerMap(
        key: String,
        prefix: String,
        suffix: String
    ) -> Data {
        var strings = Data([0])
        func addString(_ value: String) -> UInt32 {
            let offset = UInt32(strings.count)
            strings.append(Data(value.utf8))
            strings.append(0)
            return offset
        }
        let keyOffset = addString(key)
        let prefixOffset = addString(prefix)
        let suffixOffset = addString(suffix)
        var data = Data()
        func append(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        append(0x686D_6170)
        data.append(1)
        data.append(0)
        data.append(0)
        data.append(0)
        append(48)
        append(1)
        append(2)
        append(UInt32(prefix.utf8.count + suffix.utf8.count))
        append(keyOffset)
        append(prefixOffset)
        append(suffixOffset)
        append(0)
        append(0)
        append(0)
        data.append(strings)
        return data
    }
}
}

extension BuildToolsTests {
@Suite("Swift source import discovery")
struct SourceImports {
    @Test("Common import forms are found outside comments and literals")
    func scansCommonForms() {
        let source = [
            "@testable import XCTest",
            "@_implementationOnly import struct InternalKit.Widget",
            "#if canImport(UIKit)",
            "public import UIKit; import class Foundation.NSObject",
            "#endif",
            "// import CommentedOut",
            "/* nested /* import AlsoCommented */ comment */",
            "let text = \"value \\(render(\"import InInterpolationString\"))\"",
            "let multiline = \"\"\"import InMultilineString\"\"\"",
            "let raw = #\"import InRawString\"#",
            "let escaped = `import`",
        ].joined(separator: "\n")

        let result = FrontendReceipt.SourceImports.scan(
            contents: [Data(source.utf8)]
        )

        #expect(result.isComplete)
        #expect(result.modules == ["Foundation", "InternalKit", "UIKit", "XCTest"])
        #expect(result.covers(compilerModules: ["UIKit", "Foundation.NSObject"]))
        #expect(!result.covers(compilerModules: ["MissingKit"]))
    }

    @Test("An unterminated lexical construct disables caching")
    func rejectsIncompleteSource() {
        let result = FrontendReceipt.SourceImports.scan(
            contents: [Data("import Foundation\n/* unfinished".utf8)]
        )

        #expect(!result.isComplete)
        #expect(result.modules == ["Foundation"])
    }
}
}
