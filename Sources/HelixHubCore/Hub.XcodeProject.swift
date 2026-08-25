import Foundation

extension Hub {
/// Read-only semantic snapshot of one `.xcodeproj` selected in Helix Hub.
public struct XcodeProject: Hashable, Sendable {
    public var projectURL: URL
    public var sourceRootURL: URL
    public var name: String
    public var objectVersion: String
    public var configurations: [String]
    public var targets: [Hub.XcodeTarget]
    public var sharedSchemes: [Hub.XcodeScheme]

    public init(
        projectURL: URL,
        sourceRootURL: URL,
        name: String,
        objectVersion: String,
        configurations: [String],
        targets: [Hub.XcodeTarget],
        sharedSchemes: [Hub.XcodeScheme]
    ) {
        self.projectURL = projectURL
        self.sourceRootURL = sourceRootURL
        self.name = name
        self.objectVersion = objectVersion
        self.configurations = configurations
        self.targets = targets
        self.sharedSchemes = sharedSchemes
    }

    public func target(named name: String) -> Hub.XcodeTarget? {
        targets.first { $0.name == name }
    }
}

public struct XcodeScheme: Hashable, Sendable, Identifiable {
    public var name: String
    public var url: URL
    public var id: String { name }

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

public struct XcodeTarget: Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case application
        case framework
        case library
        case appExtension
        case testBundle
        case aggregate
        case other
    }

    public var id: String
    public var name: String
    public var productName: String
    public var buildableName: String?
    public var productType: String?
    public var kind: Kind
    public var configurationNames: [String]
    /// Whether Xcode can schedule a source compilation for this target.
    ///
    /// This is deliberately capability-level metadata. Source membership is
    /// learned from Xcode's successful Swift frontend invocation instead of
    /// being guessed from the project file or a synchronized directory.
    public var supportsSourceCompilation: Bool
    public var packageProducts: [String]
    public var baseConfigurationPaths: [String: String]

    /// Swift package products linked to this target.
    public var linkedRuntimeProducts: [String] { packageProducts }

    public init(
        id: String,
        name: String,
        productName: String,
        buildableName: String?,
        productType: String?,
        kind: Kind,
        configurationNames: [String],
        supportsSourceCompilation: Bool,
        packageProducts: [String],
        baseConfigurationPaths: [String: String]
    ) {
        self.id = id
        self.name = name
        self.productName = productName
        self.buildableName = buildableName
        self.productType = productType
        self.kind = kind
        self.configurationNames = configurationNames
        self.supportsSourceCompilation = supportsSourceCompilation
        self.packageProducts = packageProducts
        self.baseConfigurationPaths = baseConfigurationPaths
    }

    public func linksRuntimeProduct(_ product: String) -> Bool {
        packageProducts.contains(product)
    }
}
}
