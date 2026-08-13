import Foundation
import Testing

extension CLITests {
@Suite("CocoaPods distribution")
struct CocoaPodsDistribution {
    @Test("App-facing specs remain self-contained and manager-safe")
    func podspecContracts() throws {
        let root = repositoryRoot()
        let app = try String(
            contentsOf: root.appendingPathComponent("HelixAppRuntime.podspec"),
            encoding: .utf8
        )
        let development = try String(
            contentsOf: root.appendingPathComponent("HelixDevAppRuntime.podspec"),
            encoding: .utf8
        )
        let ignore = try String(
            contentsOf: root.appendingPathComponent(".gitignore"),
            encoding: .utf8
        )

        try expectSpec(
            app,
            product: "HelixAppRuntime",
            generatedPath: "CocoaPods/Generated/HelixAppRuntime"
        )
        try expectSpec(
            development,
            product: "HelixDevAppRuntime",
            generatedPath: "CocoaPods/Generated/HelixDevAppRuntime"
        )
        #expect(!app.contains("HelixDevRuntime"))
        #expect(!app.contains("HelixLiveReloadAPI"))
        #expect(ignore.split(separator: "\n").contains("/CocoaPods/Generated/"))
    }

    @Test("Runtime source preparation is deterministic and product-isolated")
    func preparesRuntimeSources() throws {
        let root = repositoryRoot()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-cocoapods-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: output) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let appFirst = try prepare("HelixAppRuntime", root: root, output: output)
        let development = try prepare("HelixDevAppRuntime", root: root, output: output)
        let appSecond = try prepare("HelixAppRuntime", root: root, output: output)

        #expect(appFirst == appSecond)
        #expect(appFirst.product == "HelixAppRuntime")
        #expect(appFirst.modules == [
            "HelixCore", "HelixBytecode", "HelixInterface", "HelixVerifier",
            "HelixVM", "HelixRuntime", "HelixPatch",
        ])
        #expect(development.product == "HelixDevAppRuntime")
        #expect(development.modules.suffix(3) == [
            "HelixLiveReloadAPI", "HelixDevProtocol", "HelixDevRuntime",
        ])
        #expect(Set(appFirst.files.keys).isSubset(of: Set(development.files.keys)))
        #expect(
            appFirst.files.keys.allSatisfy {
                !$0.contains("HelixDev") && !$0.contains("HelixLiveReload")
            }
        )

        for product in ["HelixAppRuntime", "HelixDevAppRuntime"] {
            let productURL = output.appendingPathComponent(product, isDirectory: true)
            for source in try swiftFiles(in: productURL) {
                let text = try String(contentsOf: source, encoding: .utf8)
                #expect(!text.split(separator: "\n").contains { line in
                    line.trimmingCharacters(in: .whitespaces).hasPrefix("import Helix")
                })
            }
        }
    }

    @Test("Unknown products fail without creating an output")
    func rejectsUnknownProduct() throws {
        let root = repositoryRoot()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-cocoapods-rejection-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try runPreparation(
            product: "HelixCompiler",
            root: root,
            output: output
        )
        #expect(result.status != 0)
        #expect(result.standardError.contains("unknown CocoaPods product"))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private func expectSpec(
        _ source: String,
        product: String,
        generatedPath: String
    ) throws {
        #expect(source.contains("spec.name = '\(product)'"))
        #expect(source.contains(":git => 'https://github.com/TangentW/Helix.git'"))
        #expect(source.contains(":tag => \"v#{spec.version}\""))
        #expect(source.contains("spec.static_framework = true"))
        #expect(source.contains("prepare_runtime_sources.rb \(product)"))
        #expect(source.contains("spec.source_files = '\(generatedPath)/**/*.{swift,c,h}'"))
        #expect(source.contains("-package-name Helix"))
        #expect(!source.contains("Sources/HelixCompiler"))
        #expect(!source.contains("Sources/HelixHub"))
    }

    private func prepare(
        _ product: String,
        root: URL,
        output: URL
    ) throws -> SourceManifest {
        let result = try runPreparation(product: product, root: root, output: output)
        #expect(result.status == 0)
        let data = try Data(contentsOf: output
            .appendingPathComponent(product)
            .appendingPathComponent("CocoaPodsSourceManifest.json"))
        return try JSONDecoder().decode(SourceManifest.self, from: data)
    }

    private func runPreparation(
        product: String,
        root: URL,
        output: URL
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ruby",
            root.appendingPathComponent("CocoaPods/Scripts/prepare_runtime_sources.rb").path,
            product,
            "--output-root", output.path,
        ]
        process.currentDirectoryURL = root
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .init(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return try enumerator.compactMap { value in
            guard let url = value as? URL,
                  url.pathExtension == "swift",
                  try url.resourceValues(forKeys: Set(keys)).isRegularFile == true
            else { return nil }
            return url
        }
    }

    private struct ProcessResult {
        var status: Int32
        var standardOutput: String
        var standardError: String
    }

    private struct SourceManifest: Codable, Equatable {
        struct FileEntry: Codable, Equatable {
            var sourceSHA256: String
            var generatedSHA256: String
        }

        var schemaVersion: Int
        var product: String
        var modules: [String]
        var files: [String: FileEntry]
    }
}
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
