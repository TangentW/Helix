import Foundation
import HelixCore

/// Deterministic build settings and source lists consumed by the two Xcode
/// targets that make up a Helix Shell feature and its permanent Bridge.
public enum XcodeIntegration {}

extension XcodeIntegration {
public struct Plan: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var featureModuleName: String
    public var bridgeModuleName: String
    public var releaseRuntimePackageProduct: String
    public var developmentRuntimePackageProduct: String
    public var outputDirectoryBuildSetting: String
    public var featureSourceList: String
    public var bridgeSourceList: String
    public var provisionalArchive: String
    public var reloadIndex: String
    public var featureSwiftFlags: [String]
    public var bridgeSwiftFlags: [String]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        featureModuleName: String,
        bridgeModuleName: String,
        releaseRuntimePackageProduct: String = "HelixAppRuntime",
        developmentRuntimePackageProduct: String = "HelixDevAppRuntime",
        outputDirectoryBuildSetting: String = "HELIX_SHELL_OUTPUT_DIR",
        featureSourceList: String = "Xcode/FeatureSources.xcfilelist",
        bridgeSourceList: String = "Xcode/BridgeSources.xcfilelist",
        provisionalArchive: String = "Shell.provisional.hlxi",
        reloadIndex: String = "ReloadIndex.json",
        featureSwiftFlags: [String] = [
            "-Xfrontend", "-enable-private-imports",
        ],
        bridgeSwiftFlags: [String] = [
            "-Xfrontend", "-enable-private-imports",
            "-Xfrontend", "-enable-dynamic-replacement-chaining",
        ]
    ) {
        self.schemaVersion = schemaVersion
        self.featureModuleName = featureModuleName
        self.bridgeModuleName = bridgeModuleName
        self.releaseRuntimePackageProduct = releaseRuntimePackageProduct
        self.developmentRuntimePackageProduct = developmentRuntimePackageProduct
        self.outputDirectoryBuildSetting = outputDirectoryBuildSetting
        self.featureSourceList = featureSourceList
        self.bridgeSourceList = bridgeSourceList
        self.provisionalArchive = provisionalArchive
        self.reloadIndex = reloadIndex
        self.featureSwiftFlags = featureSwiftFlags
        self.bridgeSwiftFlags = bridgeSwiftFlags
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.isSwiftIdentifier(featureModuleName),
              Self.isSwiftIdentifier(bridgeModuleName),
              releaseRuntimePackageProduct == "HelixAppRuntime",
              developmentRuntimePackageProduct == "HelixDevAppRuntime",
              Self.isBuildSetting(outputDirectoryBuildSetting),
              Self.isSafeRelativePath(featureSourceList),
              Self.isSafeRelativePath(bridgeSourceList),
              Self.isSafeRelativePath(provisionalArchive),
              Self.isSafeRelativePath(reloadIndex),
              featureSwiftFlags == ["-Xfrontend", "-enable-private-imports"],
              bridgeSwiftFlags == [
                  "-Xfrontend", "-enable-private-imports",
                  "-Xfrontend", "-enable-dynamic-replacement-chaining",
              ]
        else {
            throw XcodeIntegration.Error.invalidPlan
        }
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func isBuildSetting(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isASCII && first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber)
        }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), value.utf8.count <= 16 * 1_024 else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains("..")
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

public struct Output: Sendable {
    public var plan: XcodeIntegration.Plan
    public var artifacts: [String: Data]
}

public struct Generator: Sendable {
    public init() {}

    public func generate(
        moduleName: String,
        transformedSourcePaths: [String],
        bridgeSourcePaths: [String]
    ) throws -> XcodeIntegration.Output {
        let featurePaths = transformedSourcePaths.sorted()
        let bridgePaths = bridgeSourcePaths.sorted()
        guard !featurePaths.isEmpty, !bridgePaths.isEmpty,
              Set(featurePaths).count == featurePaths.count,
              Set(bridgePaths).count == bridgePaths.count,
              featurePaths.allSatisfy(Self.isSafeSourcePath),
              bridgePaths.allSatisfy(Self.isSafeSourcePath)
        else {
            throw XcodeIntegration.Error.invalidSources
        }
        let plan = XcodeIntegration.Plan(
            featureModuleName: moduleName,
            bridgeModuleName: "\(moduleName)HelixBridge"
        )
        try plan.validate()
        let setting = "$(\(plan.outputDirectoryBuildSetting))"
        let featureList = featurePaths.map { "\(setting)/DerivedSources/\($0)" }
            .joined(separator: "\n") + "\n"
        let bridgeList = bridgePaths.map { "\(setting)/\($0)" }
            .joined(separator: "\n") + "\n"
        let featureFlags = plan.featureSwiftFlags.joined(separator: " ")
        let bridgeFlags = plan.bridgeSwiftFlags.joined(separator: " ")
        let configuration = """
        // Generated by Helix. Include this file from target-specific xcconfig files.
        HELIX_FEATURE_MODULE_NAME = \(plan.featureModuleName)
        HELIX_BRIDGE_MODULE_NAME = \(plan.bridgeModuleName)
        HELIX_RELEASE_RUNTIME_PRODUCT = \(plan.releaseRuntimePackageProduct)
        HELIX_DEV_RUNTIME_PRODUCT = \(plan.developmentRuntimePackageProduct)
        HELIX_FEATURE_SOURCE_FILE_LIST = $(\(plan.outputDirectoryBuildSetting))/\(plan.featureSourceList)
        HELIX_BRIDGE_SOURCE_FILE_LIST = $(\(plan.outputDirectoryBuildSetting))/\(plan.bridgeSourceList)
        HELIX_PROVISIONAL_ARCHIVE = $(\(plan.outputDirectoryBuildSetting))/\(plan.provisionalArchive)
        HELIX_RELOAD_INDEX = $(\(plan.outputDirectoryBuildSetting))/\(plan.reloadIndex)
        HELIX_FEATURE_SWIFT_FLAGS = \(featureFlags)
        HELIX_BRIDGE_SWIFT_FLAGS = \(bridgeFlags)

        """
        return .init(
            plan: plan,
            artifacts: [
                "Xcode/IntegrationPlan.json": try Core.CanonicalJSON.encode(plan),
                plan.featureSourceList: Data(featureList.utf8),
                plan.bridgeSourceList: Data(bridgeList.utf8),
                "Xcode/HelixShell.xcconfig": Data(configuration.utf8),
            ]
        )
    }

    private static func isSafeSourcePath(_ value: String) -> Bool {
        guard value.hasSuffix(".swift"), !value.hasPrefix("/"),
              !value.contains("$"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains("..")
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPlan
    case invalidSources
    case hostPlanTooLarge(actual: Int, maximum: Int)
    case hostPlanNonCanonical
    case invalidHostPlan(String)
    case outputCollision(String)

    public var description: String {
        switch self {
        case .invalidPlan: "invalid Xcode integration plan"
        case .invalidSources: "Xcode integration source lists are empty, unsafe, or duplicated"
        case let .hostPlanTooLarge(actual, maximum):
            "Xcode host plan is \(actual) bytes; maximum is \(maximum)"
        case .hostPlanNonCanonical:
            "Xcode host plan is not canonical JSON"
        case let .invalidHostPlan(reason):
            "invalid Xcode host plan: \(reason)"
        case let .outputCollision(path):
            "Xcode integration generated the same output twice: \(path)"
        }
    }
}
}
