import Foundation
import HelixInterface

extension SwiftFrontend {
public enum SymbolGraph {}
}

extension SwiftFrontend.SymbolGraph {
public struct Document: Codable, Sendable {
    public var metadata: Metadata
    public var module: Module
    public var symbols: [Symbol]
    public var relationships: [Relationship]
}

public struct Metadata: Codable, Sendable {
    public var formatVersion: Version
    public var generator: String
}

public struct Version: Codable, Hashable, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            major: try values.decode(Int.self, forKey: .major),
            minor: try values.decodeIfPresent(Int.self, forKey: .minor) ?? 0,
            patch: try values.decodeIfPresent(Int.self, forKey: .patch) ?? 0
        )
    }

    private enum CodingKeys: String, CodingKey {
        case major
        case minor
        case patch
    }
}

public struct Module: Codable, Sendable {
    public var name: String
}

public struct Symbol: Codable, Sendable {
    public var kind: Kind
    public var identifier: Identifier
    public var pathComponents: [String]
    public var names: Names
    public var declarationFragments: [Fragment]
    public var functionSignature: FunctionSignature?
    public var accessLevel: String
    public var availability: [Availability]?
}

public struct Kind: Codable, Hashable, Sendable {
    public var identifier: String
    public var displayName: String
}

public struct Identifier: Codable, Hashable, Sendable {
    public var precise: String
    public var interfaceLanguage: String
}

public struct Names: Codable, Sendable {
    public var title: String
}

public struct Fragment: Codable, Hashable, Sendable {
    public var kind: String
    public var spelling: String
    public var preciseIdentifier: String?
}

public struct FunctionSignature: Codable, Sendable {
    public var parameters: [Parameter]?
    public var returns: [Fragment]?
}

public struct Parameter: Codable, Sendable {
    public var name: String
    public var internalName: String?
    public var declarationFragments: [Fragment]
}

public struct Availability: Codable, Sendable {
    public var domain: String
    public var introduced: Version?
    public var deprecated: Version?
    public var obsoleted: Version?
    public var isUnconditionallyDeprecated: Bool?
    public var isUnconditionallyUnavailable: Bool?
}

public struct Relationship: Codable, Hashable, Sendable {
    public var kind: String
    public var source: String
    public var target: String
}
}

extension SwiftFrontend.SymbolGraph.Document {
    public func validate(expectedModuleName: String) throws {
        guard module.name == expectedModuleName,
              !metadata.generator.isEmpty,
              metadata.formatVersion.major >= 0,
              metadata.formatVersion.minor >= 0,
              metadata.formatVersion.patch >= 0,
              !symbols.isEmpty,
              symbols.count <= 1_000_000,
              relationships.count <= 2_000_000
        else {
            throw SwiftFrontend.Error.invalidSymbolGraph(
                "primary graph identity is incomplete"
            )
        }
    }
}

extension SwiftFrontend.Driver {
    /// Extracts one public module API with the symbol-graph tool from the
    /// captured Swift toolchain. Output is bounded before decoding because SDK
    /// graphs are compiler input, not an authority to allocate without limit.
    public func emitSymbolGraph(
        moduleName: String,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> SwiftFrontend.SymbolGraph.Document {
        try invocation.validate()
        guard Self.isModuleIdentifier(moduleName) else {
            throw SwiftFrontend.Error.invalidSymbolGraph(
                "module name is not a Swift identifier"
            )
        }
        let sdk = try sdkIdentity(name: invocation.sdkName)
        guard sdk.buildVersion == invocation.sdkBuild else {
            throw SwiftFrontend.Error.sdkBuildMismatch(
                expected: invocation.sdkBuild,
                actual: sdk.buildVersion
            )
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-symbol-graph-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        } catch {
            throw SwiftFrontend.Error.launchFailed(
                "cannot create symbol graph output directory: \(error)"
            )
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let tool = try symbolGraphTool()
        let arguments = tool.argumentPrefix + [
            "-module-name", moduleName,
            "-target", invocation.targetTriple,
            "-sdk", sdk.path,
            "-output-dir", directory.path,
            "-minimum-access-level", "public",
            "-skip-synthesized-members",
            "-skip-protocol-implementations",
            "-skip-inherited-docs",
        ] + (try symbolGraphImportArguments(invocation.semanticArguments))
        let output = try SwiftFrontend.Driver(
            compilerURL: tool.executable,
            environment: environment,
            defaultWorkingDirectoryURL: defaultWorkingDirectoryURL,
            invocationObserver: invocationObserver
        ).run(arguments: arguments)
        guard output.terminationStatus == 0 else {
            throw SwiftFrontend.Error.symbolGraphFailed(
                module: moduleName,
                diagnostics: output.standardError.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }

        let graphURL = directory.appendingPathComponent(
            "\(moduleName).symbols.json",
            isDirectory: false
        )
        let values: URLResourceValues
        do {
            values = try graphURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw SwiftFrontend.Error.invalidSymbolGraph(
                "missing primary graph for module \(moduleName)"
            )
        }
        let maximumBytes = 64 * 1_024 * 1_024
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= maximumBytes
        else {
            throw SwiftFrontend.Error.invalidSymbolGraph(
                "primary graph for module \(moduleName) is not a bounded regular file"
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: graphURL, options: .mappedIfSafe)
        } catch {
            throw SwiftFrontend.Error.invalidSymbolGraph(
                "cannot read primary graph for module \(moduleName): \(error)"
            )
        }
        guard data.count == byteCount, data.count <= maximumBytes else {
            throw SwiftFrontend.Error.invalidSymbolGraph(
                "primary graph for module \(moduleName) changed while reading"
            )
        }
        do {
            let document = try JSONDecoder().decode(
                SwiftFrontend.SymbolGraph.Document.self,
                from: data
            )
            try document.validate(expectedModuleName: moduleName)
            return document
        } catch let error as SwiftFrontend.Error {
            throw error
        } catch {
            throw SwiftFrontend.Error.invalidSymbolGraph(String(describing: error))
        }
    }

    private func symbolGraphTool() throws -> (
        executable: URL,
        argumentPrefix: [String]
    ) {
        let sibling = compilerURL.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("swift-symbolgraph-extract")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return (sibling, [])
        }
        guard compilerURL.standardizedFileURL.path == "/usr/bin/swiftc" else {
            throw SwiftFrontend.Error.launchFailed(
                "captured Swift toolchain has no swift-symbolgraph-extract sibling"
            )
        }
        return (URL(fileURLWithPath: "/usr/bin/xcrun"), [
            "swift-symbolgraph-extract",
        ])
    }

    /// Projects consumer compilation arguments onto the symbol-graph tool's
    /// narrower module-loading contract. The graph only nominates candidates;
    /// later probes replay every captured source semantic, so dropping
    /// source-only flags is a safe under-approximation while forwarding them
    /// would make the independent extractor reject otherwise valid builds.
    public func symbolGraphImportArguments(
        _ arguments: [String]
    ) throws -> [String] {
        let values = try directFrontendArguments(arguments)
        let pairedOptions: Set<String> = [
            "-F", "-Fsystem", "-I", "-Isystem", "-L", "-Xcc",
            "-language-mode", "-module-cache-path", "-resource-dir",
            "-swift-version",
        ]
        let attachedPrefixes = [
            "-F", "-I", "-L", "-cxx-interoperability-mode=",
        ]
        var result: [String] = []
        var index = 0
        while index < values.count {
            let argument = values[index]
            if pairedOptions.contains(argument) {
                guard index + 1 < values.count else {
                    throw SwiftFrontend.Error.invalidSymbolGraph(
                        "symbol graph option \(argument) is missing its value"
                    )
                }
                result.append(argument)
                result.append(values[index + 1])
                index += 2
                continue
            }
            if attachedPrefixes.contains(where: {
                argument.hasPrefix($0) && argument != $0
            }) {
                result.append(argument)
            }
            index += 1
        }
        return result
    }

    private static func isModuleIdentifier(_ value: String) -> Bool {
        guard value.utf8.count <= 512,
              let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }
}
