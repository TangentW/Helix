#if os(macOS)
import Foundation
import Testing
@testable import HelixHubCore

enum HubCoreTests {}

extension HubCoreTests {
@Suite("PBX token editing and system validation")
struct PBXEditing {
    @Test("Special characters and OpenStep escapes keep their exact values")
    func strings() throws {
        let values = ["libc++", "@executable_path/Frameworks", "*.xcassets", "<group>",
                      "$(inherited)", "KEY[sdk=iphoneos*]", "中文😀", "quoted\"value", "a\\b", "a\nb\rc\td",
                      "//comment", "/*comment*/", "", "a\0b"]
        for value in values {
            let input = #"{ objects = { PROJECT = { isa = PBXProject; }; VALUE = { isa = XCBuildConfiguration; name = Before; }; }; rootObject = PROJECT; }"#
            var document = try Hub.PBXProjectDocument(data: Data(input.utf8))
            try document.updateObject("VALUE") { $0["name"] = .string(value) }
            let output = try document.serialized()
            let root = try #require(try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any])
            let objects = try #require(root["objects"] as? [String: [String: Any]])
            #expect(objects["VALUE"]?["name"] as? String == value)
        }
        let escaped = #"{ objects = { PROJECT = { isa = PBXProject; name = "\U4F60\U597D\141"; }; }; rootObject = PROJECT; }"#
        var document = try Hub.PBXProjectDocument(data: Data(escaped.utf8))
        #expect(try document.object("PROJECT")["name"]?.string == "你好a")
        try document.updateObject("PROJECT") { $0["other"] = .string("added") }
        #expect(String(decoding: try document.serialized(), as: UTF8.self).contains(#"name = "\U4F60\U597D\141";"#))
    }

    @Test("A large existing source array preserves every untouched source line")
    func largeArray() throws {
        let sourceLines = (0..<2_500).map { "    FILE\($0) /* 文件 \($0).swift */,\r\n" }.joined()
        let input = "{\r\n  objects = {\r\n    PROJECT = { isa = PBXProject; };\r\n    SOURCES = { isa = PBXSourcesBuildPhase; files = (\r\n" + sourceLines + "    ); };\r\n  };\r\n  rootObject = PROJECT;\r\n}"
        var document = try Hub.PBXProjectDocument(data: Data(input.utf8))
        try document.updateObject("SOURCES") {
            $0["files"] = .strings((0..<2_500).map { "FILE\($0)" } + ["HELIX_TRIGGER"])
        }
        let output = String(decoding: try document.serialized(), as: UTF8.self)
        #expect(output.contains(sourceLines))
        #expect(output.replacingOccurrences(of: "\r\n", with: "").contains("\n") == false)
        #expect(output.contains("PROJECT = { isa = PBXProject; };"))
        #expect(output.components(separatedBy: "\n").count <= input.components(separatedBy: "\n").count + 3)
    }

    @Test("Array additions, removals, moves and duplicates remain semantically exact")
    func arrays() throws {
        let variants: [[String]] = [[], ["A"], ["B"], ["A", "B"], ["B", "A"], ["A", "A"],
                                    ["C", "A", "B", "D"], ["B", "D", "A"], ["D", "C"]]
        for old in variants {
            for new in variants {
                for trailingComma in [true, false] {
                    let members = old.enumerated().map { index, member in
                        member + " /* existing \(index) */" + ((trailingComma || index < old.count - 1) ? "," : "")
                    }.joined(separator: "\n")
                    let input = "{ objects = { PROJECT = { isa = PBXProject; list = (\n\(members)\n); }; }; rootObject = PROJECT; }"
                    var document = try Hub.PBXProjectDocument(data: Data(input.utf8))
                    try document.updateObject("PROJECT") { $0["list"] = .strings(new) }
                    let output = try document.serialized()
                    let root = try #require(try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any])
                    let objects = try #require(root["objects"] as? [String: [String: Any]])
                    #expect(objects["PROJECT"]?["list"] as? [String] == new)
                    if old == new { #expect(output == Data(input.utf8)) }
                }
            }
        }
    }

    @Test("No-op, remove/re-add and nested dictionary edits preserve untouched bytes")
    func dictionaryEdits() throws {
        let input = #"{ objects = { PROJECT /* project */ = { isa = PBXProject; values = { "libc++" = "*.xcassets"; remove = 1; }; }; KEEP = { isa = PBXGroup; sourceTree = "<group>"; }; }; rootObject = PROJECT; }"#
        var document = try Hub.PBXProjectDocument(data: Data(input.utf8))
        let original = try document.object("KEEP")
        document.removeObject("KEEP")
        try document.addObject("KEEP", isa: "PBXGroup", fields: original)
        try document.updateObject("PROJECT") { _ in }
        #expect(try document.serialized() == Data(input.utf8))
        try document.updateObject("PROJECT") {
            var values = $0["values"]!.dictionary!
            values.removeValue(forKey: "remove")
            values["added"] = .string("@executable_path/Frameworks")
            $0["values"] = .dictionary(values)
        }
        try document.addObject("NEW", isa: "PBXGroup", fields: ["sourceTree": .string("<group>")])
        let output = String(decoding: try document.serialized(), as: UTF8.self)
        #expect(output.contains(#""libc++" = "*.xcassets";"#))
        #expect(output.contains(#"KEEP = { isa = PBXGroup; sourceTree = "<group>"; };"#))
        #expect(!output.contains("remove = 1;"))
        #expect(output.contains("PROJECT /* project */ ="))
    }

    @Test("Invalid unquoted PBX values and duplicate dictionary keys fail before editing")
    func rejectsInvalidInput() throws {
        for value in ["libc++", "@executable_path/Frameworks", "*.xcassets", "<group>", "中文"] {
            let input = "{ objects = { PROJECT = { isa = PBXProject; name = \(value); }; }; rootObject = PROJECT; }"
            #expect(throws: Hub.Error.self) { _ = try Hub.PBXProjectDocument(data: Data(input.utf8)) }
        }
        let duplicate = "{ objects = { PROJECT = { isa = PBXProject; isa = PBXProject; }; }; rootObject = PROJECT; }"
        #expect(throws: Hub.Error.self) { _ = try Hub.PBXProjectDocument(data: Data(duplicate.utf8)) }
    }

    @Test("Invalid PBX output cannot enter a file transaction")
    func validatesBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let untouched = root.appendingPathComponent("a.txt")
        try Data("original".utf8).write(to: untouched)
        #expect(throws: Hub.Error.self) {
            _ = try Hub.FileTransaction().commit(root: root, mutations: [
                .init(relativePath: "a.txt", data: Data("changed".utf8), permissions: 0o600),
                .init(relativePath: "Example.xcodeproj/project.pbxproj", data: Data("{ name = libc++; }".utf8), permissions: 0o600),
            ])
        }
        #expect(try Data(contentsOf: untouched) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Example.xcodeproj").path))
    }

    @Test("PBX read-back failure rolls back the project and all other mutations")
    func readBackRollback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project.pbxproj")
        let original = Data("{ name = Original; }".utf8)
        try original.write(to: project)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: project.path)
        #expect(throws: Hub.Error.self) {
            _ = try Hub.FileTransaction(fileManager: CorruptingFileManager()).commit(root: root, mutations: [
                .init(relativePath: "a.txt", data: Data("new".utf8), permissions: 0o600),
                .init(relativePath: "project.pbxproj", data: Data("{ name = Updated; }".utf8), permissions: 0o600),
                .init(relativePath: "z.txt", data: Data("also new".utf8), permissions: 0o600),
            ])
        }
        #expect(try Data(contentsOf: project) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: project.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("z.txt").path))
    }

    private final class CorruptingFileManager: FileManager, @unchecked Sendable {
        override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
            try super.setAttributes(attributes, ofItemAtPath: path)
            if path.hasSuffix("project.pbxproj"), attributes[.posixPermissions] as? Int == 0o600 {
                try Data("{ name = libc++; }".utf8).write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
}
#endif
