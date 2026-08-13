import Foundation
import HelixCore

extension XcodeIntegration {
public enum Workflow: String, Codable, CaseIterable, Hashable, Sendable {
    case hotPatch
    case liveReload

    public var runtimePackageProduct: String {
        switch self {
        case .hotPatch: "HelixAppRuntime"
        case .liveReload: "HelixDevAppRuntime"
        }
    }
}

public struct Feature: Codable, Hashable, Sendable {
    public var id: String
    public var moduleName: String
    public var sourceRoot: String
    public var patchConfigurationPath: String
    public var nativeImportCatalogPath: String?
    public var sourceFiles: [String]

    public init(
        id: String,
        moduleName: String,
        sourceRoot: String,
        patchConfigurationPath: String,
        nativeImportCatalogPath: String? = nil,
        sourceFiles: [String]
    ) {
        self.id = id
        self.moduleName = moduleName
        self.sourceRoot = sourceRoot
        self.patchConfigurationPath = patchConfigurationPath
        self.nativeImportCatalogPath = nativeImportCatalogPath
        self.sourceFiles = sourceFiles.sorted()
    }

    public var bridgeTypeName: String { "\(moduleName)Bridge" }
}

/// Public, non-secret inputs for the Xcode quick-patch workflow. The private
/// key path is checked in as a location only; the key itself must remain in a
/// local ignored directory with owner-only permissions.
public struct PatchSettings: Codable, Hashable, Sendable {
    public var actionTargetName: String
    public var actionSchemeName: String
    public var recipePath: String
    public var signingCertificatePath: String
    public var trustedRootPath: String
    public var privateKeyPath: String
    public var outputRoot: String
    public var simulatorInboxPath: String?

    public init(
        actionTargetName: String,
        actionSchemeName: String,
        recipePath: String,
        signingCertificatePath: String,
        trustedRootPath: String,
        privateKeyPath: String = ".helix/private/PatchSigningKey.json",
        outputRoot: String = ".helix/patches",
        simulatorInboxPath: String? = nil
    ) {
        self.actionTargetName = actionTargetName
        self.actionSchemeName = actionSchemeName
        self.recipePath = recipePath
        self.signingCertificatePath = signingCertificatePath
        self.trustedRootPath = trustedRootPath
        self.privateKeyPath = privateKeyPath
        self.outputRoot = outputRoot
        self.simulatorInboxPath = simulatorInboxPath
    }
}

public struct Profile: Codable, Hashable, Sendable {
    public var id: String
    public var workflow: XcodeIntegration.Workflow
    public var schemeName: String
    public var applicationTargetName: String
    public var configurationName: String
    public var bundleIdentifier: String
    public var namespaceSeed: String
    public var featureID: String
    public var patch: XcodeIntegration.PatchSettings?

    public init(
        id: String,
        workflow: XcodeIntegration.Workflow,
        schemeName: String,
        applicationTargetName: String,
        configurationName: String,
        bundleIdentifier: String,
        namespaceSeed: String,
        featureID: String,
        patch: XcodeIntegration.PatchSettings? = nil
    ) {
        self.id = id
        self.workflow = workflow
        self.schemeName = schemeName
        self.applicationTargetName = applicationTargetName
        self.configurationName = configurationName
        self.bundleIdentifier = bundleIdentifier
        self.namespaceSeed = namespaceSeed
        self.featureID = featureID
        self.patch = patch
    }

    public var runtimePackageProduct: String { workflow.runtimePackageProduct }
}

/// The checked-in contract for one Xcode host. It intentionally records only
/// stable project facts; volatile DerivedData paths and compiler identities are
/// measured from the active Xcode build environment.
public struct HostPlan: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 3
    public static let defaultFileName = "HostPlan.json"

    public var schemaVersion: UInt16
    public var projectPath: String
    public var integrationRoot: String
    public var features: [XcodeIntegration.Feature]
    public var profiles: [XcodeIntegration.Profile]

    private struct BuildSlot: Hashable {
        var target: String
        var configuration: String

        init(target: String, configuration: String) {
            self.target = target
            self.configuration = configuration
        }
    }

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        projectPath: String,
        integrationRoot: String = ".helix/xcode",
        features: [XcodeIntegration.Feature],
        profiles: [XcodeIntegration.Profile]
    ) {
        self.schemaVersion = schemaVersion
        self.projectPath = projectPath
        self.integrationRoot = integrationRoot
        self.features = features.sorted { $0.id < $1.id }
        self.profiles = profiles.sorted { $0.id < $1.id }
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "unsupported schema version \(schemaVersion)"
            )
        }
        guard Self.isSafeRelativePath(projectPath),
              ["xcodeproj", "xcworkspace"].contains(
                  URL(fileURLWithPath: projectPath).pathExtension.lowercased()
              )
        else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "projectPath must name a relative .xcodeproj or .xcworkspace"
            )
        }
        guard Self.isSafeRelativePath(integrationRoot),
              !integrationRoot.hasSuffix(".xcodeproj"),
              !integrationRoot.hasSuffix(".xcworkspace")
        else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "integrationRoot must be a safe relative directory"
            )
        }
        guard (1...128).contains(features.count),
              features == features.sorted(by: { $0.id < $1.id }),
              Set(features.map(\.id)).count == features.count,
              Set(features.map(\.moduleName)).count == features.count
        else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "features must be nonempty, sorted, and uniquely named"
            )
        }
        for feature in features { try Self.validate(feature) }

        guard (1...256).contains(profiles.count),
              profiles == profiles.sorted(by: { $0.id < $1.id }),
              Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map(\.schemeName)).count == profiles.count
        else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "profiles must be nonempty, sorted, and use unique schemes"
            )
        }
        let applicationSlots = profiles.map {
            BuildSlot(
                target: $0.applicationTargetName,
                configuration: $0.configurationName
            )
        }
        let featureSlots = profiles.map {
            BuildSlot(
                target: $0.featureID,
                configuration: $0.configurationName
            )
        }
        guard Set(applicationSlots).count == applicationSlots.count,
              Set(featureSlots).count == featureSlots.count
        else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "each App and Feature target configuration may belong to only one profile"
            )
        }
        let featureIDs = Set(features.map(\.id))
        var allSchemeNames = Set(profiles.map(\.schemeName))
        let occupiedTargetNames = Set(
            features.map(\.moduleName) + profiles.map(\.applicationTargetName)
        )
        var patchActionTargetNames = Set<String>()
        for profile in profiles {
            try Self.validate(profile)
            guard featureIDs.contains(profile.featureID) else {
                throw XcodeIntegration.Error.invalidHostPlan(
                    "profile \(profile.id) references unknown feature \(profile.featureID)"
                )
            }
            if let patch = profile.patch {
                guard allSchemeNames.insert(patch.actionSchemeName).inserted,
                      patchActionTargetNames.insert(patch.actionTargetName).inserted,
                      !occupiedTargetNames.contains(patch.actionTargetName)
                else {
                    throw XcodeIntegration.Error.invalidHostPlan(
                        "profile \(profile.id) patch action must use a unique target and scheme"
                    )
                }
                let publicInputs = [
                    patch.recipePath,
                    patch.signingCertificatePath,
                    patch.trustedRootPath,
                    patch.privateKeyPath,
                ]
                guard publicInputs.allSatisfy({
                    !Self.containsPath($0, in: integrationRoot)
                        && !Self.containsPath($0, in: patch.outputRoot)
                }),
                    !Self.containsPath(patch.outputRoot, in: integrationRoot),
                    !Self.containsPath(integrationRoot, in: patch.outputRoot)
                else {
                    throw XcodeIntegration.Error.invalidHostPlan(
                        "profile \(profile.id) patch inputs, outputs, and generated kit overlap"
                    )
                }
            }
        }
    }

    public func feature(id: String) throws -> XcodeIntegration.Feature {
        guard let feature = features.first(where: { $0.id == id }) else {
            throw XcodeIntegration.Error.invalidHostPlan("unknown feature \(id)")
        }
        return feature
    }

    public func profile(id: String) throws -> XcodeIntegration.Profile {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw XcodeIntegration.Error.invalidHostPlan("unknown profile \(id)")
        }
        return profile
    }

    private static func validate(_ feature: XcodeIntegration.Feature) throws {
        guard isFileComponent(feature.id),
              isSwiftIdentifier(feature.moduleName),
              feature.sourceRoot == "." || isSafeRelativePath(feature.sourceRoot),
              isSafeRelativePath(feature.patchConfigurationPath),
              ["yml", "yaml"].contains(
                  URL(fileURLWithPath: feature.patchConfigurationPath)
                      .pathExtension.lowercased()
              ),
              feature.nativeImportCatalogPath.map(isSafeRelativePath) ?? true,
              !feature.sourceFiles.isEmpty,
              feature.sourceFiles == feature.sourceFiles.sorted(),
              Set(feature.sourceFiles).count == feature.sourceFiles.count,
              feature.sourceFiles.allSatisfy({
                  isSafeRelativePath($0) && $0.hasSuffix(".swift")
              })
        else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "feature \(feature.id) has invalid modules, paths, or source files"
            )
        }
        if let catalog = feature.nativeImportCatalogPath,
           URL(fileURLWithPath: catalog).pathExtension.lowercased() != "json" {
            throw XcodeIntegration.Error.invalidHostPlan(
                "feature \(feature.id) NativeImport catalog must be JSON"
            )
        }
    }

    private static func validate(_ profile: XcodeIntegration.Profile) throws {
        guard isFileComponent(profile.id),
              isDisplayName(profile.schemeName),
              isDisplayName(profile.applicationTargetName),
              isDisplayName(profile.configurationName),
              isBundleIdentifier(profile.bundleIdentifier),
              isBoundString(profile.namespaceSeed, maximumBytes: 1_024),
              isFileComponent(profile.featureID)
        else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "profile \(profile.id) has an invalid name, bundle ID, seed, or feature"
            )
        }
        guard profile.workflow == .hotPatch || profile.patch == nil else {
            throw XcodeIntegration.Error.invalidHostPlan(
                "Live Reload profile \(profile.id) cannot declare patch signing inputs"
            )
        }
        if let patch = profile.patch {
            guard isDisplayName(patch.actionTargetName),
                isDisplayName(patch.actionSchemeName),
                [
                    patch.recipePath,
                    patch.signingCertificatePath,
                    patch.trustedRootPath,
                    patch.privateKeyPath,
                    patch.outputRoot,
                ].allSatisfy(isSafeRelativePath),
                patch.simulatorInboxPath.map(isSafeRelativePath) ?? true,
                URL(fileURLWithPath: patch.recipePath).pathExtension.lowercased() == "json",
                URL(fileURLWithPath: patch.signingCertificatePath)
                    .pathExtension.lowercased() == "json",
                URL(fileURLWithPath: patch.trustedRootPath).pathExtension.lowercased() == "json",
                URL(fileURLWithPath: patch.privateKeyPath).pathExtension.lowercased() == "json"
            else {
                throw XcodeIntegration.Error.invalidHostPlan(
                    "profile \(profile.id) has invalid patch paths"
                )
            }
            if let inbox = patch.simulatorInboxPath,
               !inbox.hasPrefix("Documents/") || !inbox.hasSuffix(".hlxp") {
                throw XcodeIntegration.Error.invalidHostPlan(
                    "profile \(profile.id) simulator inbox must be a Documents/*.hlxp path"
                )
            }
        }
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
    }

    private static func isFileComponent(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isASCII && first.isLetter,
              value.utf8.count <= 128
        else { return false }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0 == "-" || $0.isASCII && ($0.isLetter || $0.isNumber)
        }
    }

    private static func isDisplayName(_ value: String) -> Bool {
        isBoundString(value, maximumBytes: 256)
            && !value.contains("$")
            && !value.contains("\\")
            && !value.contains("/")
    }

    private static func isBundleIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            guard let first = component.first,
                  first.isASCII && (first.isLetter || first.isNumber)
            else { return false }
            return component.allSatisfy {
                $0 == "-" || $0.isASCII && ($0.isLetter || $0.isNumber)
            }
        }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard isBoundString(value, maximumBytes: 16 * 1_024),
              !value.hasPrefix("/"),
              !value.contains("$"),
              !value.contains("\\"),
              !value.contains("#"),
              !value.contains("\""),
              !value.contains(";"),
              !value.contains("=")
        else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains(".")
            && !components.contains("..")
    }

    private static func isBoundString(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func containsPath(_ candidate: String, in root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }
}

public enum HostPlanCodec {
    public static let maximumDocumentBytes = 1 * 1_024 * 1_024

    public static func encode(_ plan: XcodeIntegration.HostPlan) throws -> Data {
        try plan.validate()
        return try Core.CanonicalJSON.encode(plan)
    }

    public static func decode(_ data: Data) throws -> XcodeIntegration.HostPlan {
        guard data.count <= maximumDocumentBytes else {
            throw XcodeIntegration.Error.hostPlanTooLarge(
                actual: data.count,
                maximum: maximumDocumentBytes
            )
        }
        let plan: XcodeIntegration.HostPlan
        do {
            plan = try JSONDecoder().decode(XcodeIntegration.HostPlan.self, from: data)
        } catch {
            throw XcodeIntegration.Error.invalidHostPlan(
                "JSON decoding failed: \(error)"
            )
        }
        guard try Core.CanonicalJSON.encode(plan) == data else {
            throw XcodeIntegration.Error.hostPlanNonCanonical
        }
        try plan.validate()
        return plan
    }
}
}
