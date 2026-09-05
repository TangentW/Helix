import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("File-scoped source nominal identity")
struct SourceNominalIdentity {
    @Test("USR identity distinguishes private names and rejects contradictory declarations")
    func nominalIndex() throws {
        let first = nominal("s:first", file: "A.swift")
        let second = nominal("s:second", file: "B.swift")
        let resolved = try FrontendReceipt.Adapter.resolveSourceNominalNames([second, first])
        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { $0.hasAmbiguousName })
        let index = FrontendReceipt.Adapter.SourceNominalIndex(resolved)
        #expect(index.resolve("Fixture.Owner.Key", in: "A.swift")?.declarationIdentity == "s:first")
        #expect(index.resolve("Fixture.Owner.Key", in: "B.swift")?.declarationIdentity == "s:second")
        #expect(index.resolve("Fixture.Owner.Key", in: "C.swift") == nil)
        var publicNominal = second
        publicNominal.isFileScoped = false
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.Adapter.resolveSourceNominalNames([first, publicNominal])
        }
        var conflicting = second
        conflicting.declarationIdentity = first.declarationIdentity
        var declarations = [first.declarationIdentity: first]
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.Adapter.insertSourceNominal(conflicting, into: &declarations)
        }
        conflicting.declarationIdentity = ""
        #expect(throws: FrontendReceipt.Error.self) {
            try FrontendReceipt.Adapter.insertSourceNominal(conflicting, into: &declarations)
        }
    }

    @Test("Legacy nominal encoding and IDs remain stable; scoped IDs bind logical paths")
    func identityCompatibility() throws {
        let legacyData = Data(#"{"canonicalName":"Owner.Key","moduleName":"Fixture"}"#.utf8)
        let legacy = try JSONDecoder().decode(ShellBuildReceipt.NominalType.self, from: legacyData)
        #expect(try Core.CanonicalJSON.encode(legacy) == legacyData)
        #expect(legacy == .init(moduleName: "Fixture", canonicalName: "Owner.Key"))
        let first = ShellBuildReceipt.NominalType(
            moduleName: "Fixture", canonicalName: "Owner.Key", sourceFileLogicalID: "Sources/A.swift"
        )
        let second = ShellBuildReceipt.NominalType(
            moduleName: "Fixture", canonicalName: "Owner.Key", sourceFileLogicalID: "Sources/B.swift"
        )
        #expect(first.id != second.id)
        #expect(first.id != legacy.id)
        let decoded = try JSONDecoder().decode(
            ShellBuildReceipt.NominalType.self, from: Core.CanonicalJSON.encode(first)
        )
        #expect(decoded.id == first.id)
    }

    @Test("Six extension files with private Key types complete indexing deterministically")
    func realPrivateNominals() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-private-nominals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let target = "arm64-apple-ios15.0-simulator"
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.private-nominals", buildNumber: "1",
            shellNamespaceID: .derive(bundleID: "dev.helix.private-nominals", buildNumber: "1", seed: "test"),
            machOUUIDs: [], targetTriple: target, minimumOS: .init(15),
            xcodeBuild: "test", sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(
                moduleName: "ScopedFixture", targetTriple: target,
                sdkName: sdk.name, sdkBuild: sdk.buildVersion, optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed")
        )
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          ScopedFixture:
            include:
              - Sources/**
        """)
        let owner = directory.appendingPathComponent("Owner.swift")
        try Data("public class Owner { public init() {} }\n".utf8).write(to: owner)
        var sources: [FrontendReceipt.Source] = [.init(logicalPath: "Sources/Owner.swift", url: owner)]
        for index in 0..<6 {
            let url = directory.appendingPathComponent("Extension\(index).swift")
            try Data("""
            extension Owner {
                private struct Key {
                    static var value = \(index)
                    struct Child { let value: Int }
                    typealias Alias = Int
                }
                public func value\(index)() -> Int { Key.value }
            }
            fileprivate struct Local {
                func code() -> Int { \(index) }
            }
            private typealias LocalAlias = Int
            """.utf8).write(to: url)
            sources.append(.init(logicalPath: "Sources/Extension\(index).swift", url: url))
        }
        var request = FrontendReceipt.Request(metadata: metadata, configuration: configuration, sources: sources)
        let first = try FrontendReceipt.Adapter().generate(request).receipt
        try first.validate()
        #expect(first.declarations.filter { $0.canonicalDeclaration.hasPrefix("Owner.func value") }.count == 6)
        let localRoots = first.roots.compactMap(\.nominalType).filter { $0.canonicalName == "Local" }
        #expect(localRoots.count == 6)
        #expect(Set(localRoots.map(\.id)).count == 6)
        var tampered = first
        let scopedRootIndex = try #require(tampered.roots.firstIndex { $0.nominalType?.sourceFileLogicalID != nil })
        tampered.roots[scopedRootIndex].nominalType?.sourceFileLogicalID = "Sources/Wrong.swift"
        #expect(throws: ShellBuildReceipt.Error.self) { try tampered.validate() }
        #expect(!first.frozenValueTypes.contains { $0.canonicalName.contains("Key") || $0.canonicalName.hasSuffix(".Local") })
        request.sources.reverse()
        let second = try FrontendReceipt.Adapter().generate(request).receipt
        #expect(try ShellBuildReceipt.Codec.encode(first) == ShellBuildReceipt.Codec.encode(second))
        let relocated = directory.appendingPathComponent("Relocated")
        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: false)
        request.sources = try request.sources.map { source in
            let url = relocated.appendingPathComponent(source.url.lastPathComponent)
            try FileManager.default.copyItem(at: source.url, to: url)
            return .init(logicalPath: source.logicalPath, url: url)
        }
        let third = try FrontendReceipt.Adapter().generate(request).receipt
        #expect(Set(third.roots.compactMap(\.nominalType).map(\.id)) == Set(first.roots.compactMap(\.nominalType).map(\.id)))
        let edited = relocated.appendingPathComponent("Extension0.swift")
        let text = try String(contentsOf: edited, encoding: .utf8)
        try text.replacingOccurrences(of: "Key.value", with: "Key.value + 1")
            .write(to: edited, atomically: true, encoding: .utf8)
        let fourth = try FrontendReceipt.Adapter().generate(request).receipt
        #expect(Set(fourth.roots.compactMap(\.nominalType).map(\.id)) == Set(first.roots.compactMap(\.nominalType).map(\.id)))
    }

    private func nominal(_ usr: String, file: String) -> FrontendReceipt.Adapter.SourceNominal {
        .init(
            declarationIdentity: usr, declarationOffset: 0,
            canonicalName: "Fixture.Owner.Key", sourceFileLogicalID: file,
            kind: .structure, isFileScoped: true,
            isFileScopeNameable: false, isAvailabilityConstrained: false
        )
    }
}
}
