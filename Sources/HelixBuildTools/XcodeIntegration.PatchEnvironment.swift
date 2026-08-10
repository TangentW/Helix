import Darwin
import Foundation
import HelixCore

extension XcodeIntegration {
public struct PatchEnvironment: Sendable {
    public var recipeURL: URL
    public var signingCertificateURL: URL
    public var trustedRootURL: URL
    public var privateKeyURL: URL
    public var outputRootURL: URL
    public var marketingVersion: String
    public var simulatorInboxPath: String?
}
}

extension XcodeIntegration.EnvironmentResolver {
    public func resolvePatch(
        context: XcodeIntegration.BuildContext,
        variables: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> XcodeIntegration.PatchEnvironment {
        guard context.profile.workflow == .hotPatch,
              let settings = context.profile.patch
        else {
            throw XcodeIntegration.EnvironmentError.missing(
                "Hot Patch profile patch settings"
            )
        }
        let root = context.environment.sourceRootURL.resolvingSymlinksInPath()
        func input(_ path: String, setting: String) throws -> URL {
            let expected = root.appendingPathComponent(path).standardizedFileURL
            let actual = try required(setting, variables: variables)
            let actualURL = URL(fileURLWithPath: actual).standardizedFileURL
            guard actualURL.path == expected.path else {
                throw XcodeIntegration.EnvironmentError.mismatch(
                    name: setting,
                    expected: expected.path,
                    actual: actualURL.path
                )
            }
            guard Self.containsPatchPath(
                expected.resolvingSymlinksInPath(),
                in: root
            ) else {
                throw XcodeIntegration.EnvironmentError.unsafePath(expected.path)
            }
            return expected
        }
        let recipe = try input(settings.recipePath, setting: "HELIX_PATCH_RECIPE")
        let certificate = try input(
            settings.signingCertificatePath,
            setting: "HELIX_PATCH_CERTIFICATE"
        )
        let trustedRoot = try input(
            settings.trustedRootPath,
            setting: "HELIX_PATCH_TRUSTED_ROOT"
        )
        let privateKey = try input(
            settings.privateKeyPath,
            setting: "HELIX_PATCH_PRIVATE_KEY"
        )
        let expectedOutput = root.appendingPathComponent(
            settings.outputRoot,
            isDirectory: true
        ).standardizedFileURL
        let actualOutput = URL(
            fileURLWithPath: try required("HELIX_PATCH_OUTPUT_ROOT", variables: variables),
            isDirectory: true
        ).standardizedFileURL
        let resolvedOutput = expectedOutput.resolvingSymlinksInPath()
        guard actualOutput.path == expectedOutput.path,
              Self.containsPatchPath(
                  expectedOutput.deletingLastPathComponent().resolvingSymlinksInPath(),
                  in: root
              ),
              Self.containsPatchPath(resolvedOutput, in: root)
        else {
            throw XcodeIntegration.EnvironmentError.mismatch(
                name: "HELIX_PATCH_OUTPUT_ROOT",
                expected: expectedOutput.path,
                actual: actualOutput.path
            )
        }
        var outputInformation = Darwin.stat()
        if lstat(expectedOutput.path, &outputInformation) == 0,
           outputInformation.st_mode & S_IFMT != S_IFDIR {
            throw XcodeIntegration.EnvironmentError.unsafePath(expectedOutput.path)
        }
        guard let marketingVersion = variables["MARKETING_VERSION"],
              !marketingVersion.isEmpty,
              marketingVersion.utf8.count <= 256,
              !marketingVersion.unicodeScalars.contains(where: { $0.value == 0 }),
              (try? Core.SemanticVersion(parsing: marketingVersion)) != nil
        else {
            throw XcodeIntegration.EnvironmentError.invalid(
                name: "MARKETING_VERSION",
                value: variables["MARKETING_VERSION"] ?? ""
            )
        }
        if let inbox = settings.simulatorInboxPath {
            guard variables["HELIX_PATCH_SIMULATOR_INBOX"] == inbox else {
                throw XcodeIntegration.EnvironmentError.mismatch(
                    name: "HELIX_PATCH_SIMULATOR_INBOX",
                    expected: inbox,
                    actual: variables["HELIX_PATCH_SIMULATOR_INBOX"] ?? ""
                )
            }
        }
        return .init(
            recipeURL: recipe,
            signingCertificateURL: certificate,
            trustedRootURL: trustedRoot,
            privateKeyURL: privateKey,
            outputRootURL: expectedOutput,
            marketingVersion: marketingVersion,
            simulatorInboxPath: settings.simulatorInboxPath
        )
    }

    private func required(
        _ name: String,
        variables: [String: String]
    ) throws -> String {
        guard let value = variables[name], !value.isEmpty else {
            throw XcodeIntegration.EnvironmentError.missing(name)
        }
        guard value.hasPrefix("/"), value.utf8.count <= 16 * 1_024,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw XcodeIntegration.EnvironmentError.invalid(name: name, value: value)
        }
        return value
    }

    private static func containsPatchPath(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
