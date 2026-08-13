import Foundation
import Testing

extension CLITests {
@Suite("CocoaPods distribution")
struct CocoaPodsDistribution {
    private static let productionSourceModules = [
        "HelixCore", "HelixBytecode", "HelixInterface", "HelixVerifier",
        "HelixVM", "HelixRuntime", "HelixPatch",
    ]
    private static let developmentSourceModules = productionSourceModules + [
        "HelixLiveReloadAPI", "HelixDevProtocol", "HelixDevRuntime",
    ]
    private static let internalModules = Set(developmentSourceModules + [
        "HelixRuntimeSupport",
    ])

    @Test("App-facing specs compile the checked-in Runtime source boundary")
    func podspecContracts() throws {
        let root = repositoryRoot()
        let app = try text(at: root.appendingPathComponent("HelixAppRuntime.podspec"))
        let development = try text(
            at: root.appendingPathComponent("HelixDevAppRuntime.podspec")
        )
        let repositorySourceModules = try sourceModuleNames(
            in: root.appendingPathComponent("Sources")
        )

        expectSpec(
            app,
            product: "HelixAppRuntime",
            sourceModules: Self.productionSourceModules,
            repositorySourceModules: repositorySourceModules
        )
        expectSpec(
            development,
            product: "HelixDevAppRuntime",
            sourceModules: Self.developmentSourceModules,
            repositorySourceModules: repositorySourceModules
        )
    }

    @Test("Every internal Runtime import is leaf-module-only")
    func internalImportsAreConditional() throws {
        let root = repositoryRoot()
        for module in Self.developmentSourceModules {
            let directory = root.appendingPathComponent("Sources/\(module)")
            let sources = try swiftFiles(in: directory)
            #expect(!sources.isEmpty, "Runtime source module is empty: \(module)")
            for source in sources {
                try expectInternalImportsAreLeafModuleOnly(in: source)
            }
        }
    }

    private func expectSpec(
        _ source: String,
        product: String,
        sourceModules: [String],
        repositorySourceModules: [String]
    ) {
        #expect(source.contains("spec.name = '\(product)'"))
        #expect(source.contains("spec.version = '1.0.0'"))
        #expect(source.contains(":git => 'https://github.com/TangentW/Helix.git'"))
        #expect(source.contains(":tag => \"v#{spec.version}\""))
        #expect(source.contains("spec.static_framework = true"))
        #expect(source.contains("-package-name Helix"))
        #expect(source.contains("Sources/HelixRuntimeSupport/RuntimeAtomic.c"))
        #expect(source.contains("Sources/HelixRuntimeSupport/include/RuntimeAtomic.h"))
        #expect(!source.contains("prepare_command"))
        #expect(!source.contains("CocoaPods/Generated"))
        let expectedModules = Set(sourceModules)
        for module in repositorySourceModules where module != "HelixRuntimeSupport" {
            let isIncluded = source.contains("'Sources/\(module)/**/*.swift'")
            #expect(
                isIncluded == expectedModules.contains(module),
                "Unexpected \(product) source boundary for \(module)"
            )
        }
    }

    private func expectInternalImportsAreLeafModuleOnly(in source: URL) throws {
        let lines = try text(at: source).split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var conditions: [String] = []
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("#if ") {
                conditions.append(value)
            } else if value.hasPrefix("#elseif ") {
                if !conditions.isEmpty { conditions[conditions.count - 1] = value }
            } else if value == "#else" {
                if !conditions.isEmpty { conditions[conditions.count - 1] = value }
            } else if value == "#endif" {
                if !conditions.isEmpty { conditions.removeLast() }
            } else if value.hasPrefix("import ") {
                let module = String(value.dropFirst("import ".count))
                if Self.internalModules.contains(module) {
                    #expect(
                        conditions.contains("#if canImport(HelixCore)"),
                        "Internal import is not leaf-module-only: \(source.path): \(value)"
                    )
                }
            }
        }
        #expect(conditions.isEmpty, "Unbalanced conditional compilation in \(source.path)")
    }

    private func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceModuleNames(in directory: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard try url.resourceValues(forKeys: Set(keys)).isDirectory == true else {
                return nil
            }
            return url.lastPathComponent
        }.sorted()
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
        }.sorted { $0.path < $1.path }
    }
}
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
