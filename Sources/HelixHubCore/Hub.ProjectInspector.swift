import Foundation
import HelixDevTools

extension Hub {
/// Resolved Xcode settings needed to prefill a profile without guessing build
/// variables that may come from xcconfig files.
public struct TargetSettings: Hashable, Sendable {
    public var targetName: String
    public var configurationName: String
    public var moduleName: String
    public var bundleIdentifier: String?
    public var productName: String
    public var swiftVersion: String?
    public var sourceRootURL: URL

    public init(
        targetName: String,
        configurationName: String,
        moduleName: String,
        bundleIdentifier: String?,
        productName: String,
        swiftVersion: String?,
        sourceRootURL: URL
    ) {
        self.targetName = targetName
        self.configurationName = configurationName
        self.moduleName = moduleName
        self.bundleIdentifier = bundleIdentifier
        self.productName = productName
        self.swiftVersion = swiftVersion
        self.sourceRootURL = sourceRootURL
    }
}

/// Invokes only Xcode's read-only `-showBuildSettings` query. Project graph and
/// source discovery remain independent of Xcode and are handled by
/// `ProjectFileParser`.
public struct ProjectInspector: Sendable {
    public var runner: any ProcessExecution.Running

    public init(runner: any ProcessExecution.Running = ProcessExecution.Runner()) {
        self.runner = runner
    }

    public func settings(
        project: Hub.XcodeProject,
        targetName: String,
        configurationName: String
    ) throws -> Hub.TargetSettings {
        guard let target = project.target(named: targetName),
              target.configurationNames.contains(configurationName)
        else {
            throw Hub.Error.projectInspectionFailed(
                "target \(targetName) has no \(configurationName) configuration"
            )
        }
        let result: ProcessExecution.Result
        do {
            result = try runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "xcodebuild",
                    "-project", project.projectURL.path,
                    "-target", targetName,
                    "-configuration", configurationName,
                    "-showBuildSettings", "-json",
                ],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: project.sourceRootURL
            )
        } catch {
            throw Hub.Error.projectInspectionFailed(String(describing: error))
        }
        guard result.status == 0 else {
            throw Hub.Error.projectInspectionFailed(
                bounded(result.standardError.isEmpty ? result.standardOutput : result.standardError)
            )
        }
        let data = Data(result.standardOutput.utf8)
        guard !data.isEmpty, data.count <= 16 * 1_024 * 1_024 else {
            throw Hub.Error.projectInspectionFailed("Xcode returned oversized build settings")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Hub.Error.projectInspectionFailed("Xcode returned malformed build settings")
        }
        guard let entries = object as? [[String: Any]],
              let entry = entries.first(where: { ($0["target"] as? String) == targetName })
                ?? entries.first,
              let settings = entry["buildSettings"] as? [String: Any]
        else {
            throw Hub.Error.projectInspectionFailed("Xcode returned no target build settings")
        }
        func value(_ key: String) -> String? {
            guard let value = settings[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
        }
        let module = value("PRODUCT_MODULE_NAME")
            ?? value("SWIFT_MODULE_NAME")
            ?? Self.swiftIdentifier(value("PRODUCT_NAME") ?? target.productName)
        guard Self.isSwiftIdentifier(module) else {
            throw Hub.Error.projectInspectionFailed(
                "target \(targetName) does not resolve a valid Swift module name"
            )
        }
        let sourceRoot = value("SRCROOT").map(URL.init(fileURLWithPath:))
            ?? project.sourceRootURL
        return .init(
            targetName: targetName,
            configurationName: configurationName,
            moduleName: module,
            bundleIdentifier: value("PRODUCT_BUNDLE_IDENTIFIER"),
            productName: value("PRODUCT_NAME") ?? target.productName,
            swiftVersion: value("SWIFT_VERSION"),
            sourceRootURL: sourceRoot.standardizedFileURL
        )
    }

    private func bounded(_ value: String) -> String {
        String(value.prefix(8_192))
    }

    private static func swiftIdentifier(_ value: String) -> String {
        let scalars = value.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" ? Character($0) : "_"
        }
        var result = String(scalars)
        if result.first?.isNumber == true { result = "_" + result }
        return result
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
    }
}
}
