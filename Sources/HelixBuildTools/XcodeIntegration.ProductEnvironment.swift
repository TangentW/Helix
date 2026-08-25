import Foundation
import HelixCore

extension XcodeIntegration {
public struct ProductEnvironment: Sendable {
    public var applicationBundleURL: URL
    public var executableURL: URL
    public var projectURL: URL
    public var marketingVersion: String
    public var expandedCodeSignIdentity: String?
    public var teamIdentifier: String?
    public var entitlementsURL: URL?
}
}

extension XcodeIntegration.EnvironmentResolver {
    public func resolveProduct(
        context: XcodeIntegration.BuildContext,
        variables: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> XcodeIntegration.ProductEnvironment {
        try match(
            "TARGET_NAME",
            expected: context.profile.applicationTargetName,
            variables: variables
        )
        try match(
            "PRODUCT_BUNDLE_IDENTIFIER",
            expected: context.profile.bundleIdentifier,
            variables: variables
        )
        let targetBuildDirectory = try absolutePath("TARGET_BUILD_DIR", variables: variables)
        let wrapper = try requiredProductValue("WRAPPER_NAME", variables: variables)
        guard Self.isSafeRelativeProductPath(wrapper), wrapper.hasSuffix(".app") else {
            throw XcodeIntegration.EnvironmentError.invalid(
                name: "WRAPPER_NAME",
                value: wrapper
            )
        }
        let application = targetBuildDirectory.appendingPathComponent(
            wrapper,
            isDirectory: true
        ).standardizedFileURL
        let executablePath = try requiredProductValue(
            "EXECUTABLE_PATH",
            variables: variables
        )
        guard Self.isSafeRelativeProductPath(executablePath) else {
            throw XcodeIntegration.EnvironmentError.invalid(
                name: "EXECUTABLE_PATH",
                value: executablePath
            )
        }
        let executable = targetBuildDirectory.appendingPathComponent(
            executablePath
        ).standardizedFileURL
        guard Self.containsProduct(application, in: targetBuildDirectory),
              Self.containsProduct(executable, in: application)
        else {
            throw XcodeIntegration.EnvironmentError.unsafePath(executable.path)
        }

        let project = context.environment.sourceRootURL.appendingPathComponent(
            context.plan.projectPath
        ).standardizedFileURL
        let entitlementsURL: URL?
        if let value = variables["CODE_SIGN_ENTITLEMENTS"], !value.isEmpty {
            guard Self.isSafeRelativeProductPath(value) else {
                throw XcodeIntegration.EnvironmentError.invalid(
                    name: "CODE_SIGN_ENTITLEMENTS",
                    value: value
                )
            }
            let resolved = context.environment.sourceRootURL
                .appendingPathComponent(value).standardizedFileURL
            guard Self.containsProduct(resolved, in: context.environment.sourceRootURL) else {
                throw XcodeIntegration.EnvironmentError.unsafePath(resolved.path)
            }
            entitlementsURL = resolved
        } else {
            entitlementsURL = nil
        }
        let marketingVersion = try requiredProductValue(
            "MARKETING_VERSION",
            variables: variables
        )
        guard (try? Core.SemanticVersion(parsing: marketingVersion)) != nil else {
            throw XcodeIntegration.EnvironmentError.invalid(
                name: "MARKETING_VERSION",
                value: marketingVersion
            )
        }
        return .init(
            applicationBundleURL: application,
            executableURL: executable,
            projectURL: project,
            marketingVersion: marketingVersion,
            expandedCodeSignIdentity: Self.normalized(
                variables["EXPANDED_CODE_SIGN_IDENTITY"]
            ),
            teamIdentifier: Self.normalized(variables["DEVELOPMENT_TEAM"]),
            entitlementsURL: entitlementsURL
        )
    }

    private func match(
        _ name: String,
        expected: String,
        variables: [String: String]
    ) throws {
        let actual = try requiredProductValue(name, variables: variables)
        guard actual == expected else {
            throw XcodeIntegration.EnvironmentError.mismatch(
                name: name,
                expected: expected,
                actual: actual
            )
        }
    }

    private func absolutePath(
        _ name: String,
        variables: [String: String]
    ) throws -> URL {
        let value = try requiredProductValue(name, variables: variables)
        guard value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw XcodeIntegration.EnvironmentError.invalid(name: name, value: value)
        }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    private func requiredProductValue(
        _ name: String,
        variables: [String: String]
    ) throws -> String {
        guard let value = variables[name], !value.isEmpty else {
            throw XcodeIntegration.EnvironmentError.missing(name)
        }
        guard value.utf8.count <= 16 * 1_024,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw XcodeIntegration.EnvironmentError.invalid(name: name, value: value)
        }
        return value
    }

    private static func isSafeRelativeProductPath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains(".")
            && !components.contains("..")
    }

    private static func containsProduct(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func normalized(_ value: String?) -> String? {
        value.flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
