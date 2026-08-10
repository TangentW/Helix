import Foundation
import HelixCore

/// Canonical, filesystem-facing input for one atomic multi-module index run.
public enum ProjectIndex {}

extension ProjectIndex {
public struct Source: Codable, Hashable, Sendable {
    public var logicalPath: String
    public var physicalPath: String

    public init(logicalPath: String, physicalPath: String) {
        self.logicalPath = logicalPath
        self.physicalPath = physicalPath
    }
}

public struct Module: Codable, Hashable, Sendable {
    public var moduleName: String
    public var metadataPath: String
    public var nativeImportCatalogPath: String?
    public var sources: [ProjectIndex.Source]

    public init(
        moduleName: String,
        metadataPath: String,
        nativeImportCatalogPath: String? = nil,
        sources: [ProjectIndex.Source]
    ) {
        self.moduleName = moduleName
        self.metadataPath = metadataPath
        self.nativeImportCatalogPath = nativeImportCatalogPath
        self.sources = sources.sorted { $0.logicalPath < $1.logicalPath }
    }
}

public struct Plan: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var configurationPath: String
    public var compilerPath: String?
    public var modules: [ProjectIndex.Module]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        configurationPath: String,
        compilerPath: String? = nil,
        modules: [ProjectIndex.Module]
    ) {
        self.schemaVersion = schemaVersion
        self.configurationPath = configurationPath
        self.compilerPath = compilerPath
        self.modules = modules.sorted { $0.moduleName < $1.moduleName }
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.isBoundPath(configurationPath),
              compilerPath.map(Self.isBoundPath) ?? true,
              (1...256).contains(modules.count),
              modules == modules.sorted(by: { $0.moduleName < $1.moduleName }),
              Set(modules.map(\.moduleName)).count == modules.count,
              Set(modules.map(\.metadataPath)).count == modules.count
        else {
            throw ProjectIndex.Error.invalid(
                "plan is unsupported, unordered, duplicated, or incomplete"
            )
        }
        for module in modules {
            guard Self.isSwiftIdentifier(module.moduleName),
                  Self.isBoundPath(module.metadataPath),
                  module.nativeImportCatalogPath.map(Self.isBoundPath) ?? true,
                  !module.sources.isEmpty,
                  module.sources == module.sources.sorted(by: {
                      $0.logicalPath < $1.logicalPath
                  }),
                  Set(module.sources.map(\.logicalPath)).count == module.sources.count,
                  Set(module.sources.map(\.physicalPath)).count == module.sources.count,
                  module.sources.allSatisfy({
                      Self.isSafeLogicalPath($0.logicalPath)
                          && Self.isBoundPath($0.physicalPath)
                  })
            else {
                throw ProjectIndex.Error.invalid(
                    "module \(module.moduleName) has invalid metadata, catalog, or source mappings"
                )
            }
        }
    }

    private static func isBoundPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 16 * 1_024
            && !path.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func isSafeLogicalPath(_ path: String) -> Bool {
        guard isBoundPath(path), !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains("..")
            && path.hasSuffix(".swift")
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case tooLarge(actual: Int, maximum: Int)
    case nonCanonical
    case invalid(String)

    public var description: String {
        switch self {
        case let .tooLarge(actual, maximum):
            "project index plan is \(actual) bytes; maximum is \(maximum)"
        case .nonCanonical: "project index plan is not canonical JSON"
        case let .invalid(reason): "invalid project index plan: \(reason)"
        }
    }
}

public enum Codec {
    public static let maximumDocumentBytes = 8 * 1_024 * 1_024

    public static func encode(_ plan: ProjectIndex.Plan) throws -> Data {
        try plan.validate()
        return try Core.CanonicalJSON.encode(plan)
    }

    public static func decode(_ data: Data) throws -> ProjectIndex.Plan {
        guard data.count <= maximumDocumentBytes else {
            throw ProjectIndex.Error.tooLarge(
                actual: data.count,
                maximum: maximumDocumentBytes
            )
        }
        let plan: ProjectIndex.Plan
        do {
            plan = try JSONDecoder().decode(ProjectIndex.Plan.self, from: data)
        } catch {
            throw ProjectIndex.Error.invalid("JSON decoding failed: \(error)")
        }
        guard try Core.CanonicalJSON.encode(plan) == data else {
            throw ProjectIndex.Error.nonCanonical
        }
        try plan.validate()
        return plan
    }
}
}
