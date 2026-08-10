import Foundation
import Testing

enum NamingTests {}

extension NamingTests {
@Suite("Repository Swift naming conventions")
struct Conventions {
    @Test("Handwritten Swift types and files use namespace names")
    func sourceAndTestFilesUseNamespaces() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let prefixedDeclaration = try NSRegularExpression(
            pattern: #"(?m)^[ \t]*(?:(?:public|package|internal|fileprivate|private)[ \t]+)?(?:final[ \t]+)?(?:indirect[ \t]+)?(?:struct|enum|class|actor|protocol|typealias)[ \t]+(?:HLX|HLBC|HLXI)[A-Z][A-Za-z0-9_]*"#
        )
        let prefixedFile = try NSRegularExpression(pattern: #"^(?:HLX|HLBC|HLXI)[A-Z]"#)
        var violations: [String] = []

        for directoryName in ["Sources", "Tests"] {
            let directory = packageRoot.appendingPathComponent(directoryName, isDirectory: true)
            guard let files = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                Issue.record("Cannot enumerate \(directory.path)")
                continue
            }

            for case let file as URL in files where file.pathExtension == "swift" {
                let relativePath = String(file.path.dropFirst(packageRoot.path.count + 1))
                guard !relativePath.hasPrefix("Tests/Fixtures/"), file.lastPathComponent != "main.swift" else {
                    continue
                }

                let stem = file.deletingPathExtension().lastPathComponent
                let stemRange = NSRange(stem.startIndex..<stem.endIndex, in: stem)
                if !stem.contains(".") {
                    violations.append("\(relativePath): expected Namespace.Type.swift")
                }
                if prefixedFile.firstMatch(in: stem, range: stemRange) != nil {
                    violations.append("\(relativePath): legacy prefix in Swift file name")
                }

                let source = try String(contentsOf: file, encoding: .utf8)
                let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
                if let match = prefixedDeclaration.firstMatch(in: source, range: sourceRange),
                   let range = Range(match.range, in: source) {
                    violations.append("\(relativePath): legacy Swift declaration '\(source[range])'")
                }
            }
        }

        let report = violations.sorted().joined(separator: "\n")
        #expect(violations.isEmpty, "\(report)")
    }
}
}
