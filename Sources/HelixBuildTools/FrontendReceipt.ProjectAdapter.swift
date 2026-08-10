import Foundation
import HelixCore
import HelixInterface

extension FrontendReceipt {
public struct ProjectRequest: Sendable {
    public var modules: [FrontendReceipt.Request]

    public init(modules: [FrontendReceipt.Request]) {
        self.modules = modules
    }
}

public struct ProjectModuleReport: Codable, Hashable, Sendable {
    public var moduleName: String
    public var receiptPath: String
    public var diagnosticsPath: String
    public var receiptHash: Core.Digest
    public var sourceCount: UInt32
    public var declarationCount: UInt32
    public var eligibleEntryCount: UInt32
    public var emittedNativeImportCount: UInt32
    public var generatedNativeImportCount: UInt32
    public var diagnosticCount: UInt32
}

public struct ProjectReport: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var bundleID: String
    public var buildNumber: String
    public var shellNamespaceID: Core.ShellNamespaceID
    public var toolchainFingerprint: String
    public var modules: [FrontendReceipt.ProjectModuleReport]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        bundleID: String,
        buildNumber: String,
        shellNamespaceID: Core.ShellNamespaceID,
        toolchainFingerprint: String,
        modules: [FrontendReceipt.ProjectModuleReport]
    ) {
        self.schemaVersion = schemaVersion
        self.bundleID = bundleID
        self.buildNumber = buildNumber
        self.shellNamespaceID = shellNamespaceID
        self.toolchainFingerprint = toolchainFingerprint
        self.modules = modules.sorted { $0.moduleName < $1.moduleName }
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              !bundleID.isEmpty,
              !buildNumber.isEmpty,
              !toolchainFingerprint.isEmpty,
              (1...256).contains(modules.count),
              modules == modules.sorted(by: { $0.moduleName < $1.moduleName }),
              Set(modules.map(\.moduleName)).count == modules.count,
              modules.allSatisfy({
                  Self.isSwiftIdentifier($0.moduleName)
                      && $0.receiptPath == "Receipts/\($0.moduleName).ShellBuildReceipt.json"
                      && $0.diagnosticsPath == "Diagnostics/\($0.moduleName).json"
                      && $0.sourceCount > 0
                      && $0.declarationCount > 0
                      && $0.eligibleEntryCount <= $0.declarationCount
                      && $0.generatedNativeImportCount <= $0.emittedNativeImportCount
              })
        else {
            throw FrontendReceipt.Error.invalidRequest(
                "project report is unsupported, unordered, duplicated, or incomplete"
            )
        }
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
    }
}

public struct ProjectOutput: Sendable {
    public var modules: [String: FrontendReceipt.Output]
    public var report: FrontendReceipt.ProjectReport
}

public struct ProjectAdapter: Sendable {
    private struct ProjectIdentity: Hashable {
        var bundleID: String
        var buildNumber: String
        var namespace: Core.ShellNamespaceID
        var targetTriple: String
        var minimumOS: Core.SemanticVersion
        var xcodeBuild: String
        var sdkBuild: String

        init(_ metadata: InterfaceArchive.ReleaseMetadata) {
            bundleID = metadata.bundleID
            buildNumber = metadata.buildNumber
            namespace = metadata.shellNamespaceID
            targetTriple = metadata.targetTriple
            minimumOS = metadata.minimumOS
            xcodeBuild = metadata.xcodeBuild
            sdkBuild = metadata.sdkBuild
        }
    }

    public init() {}

    public func generate(
        _ request: FrontendReceipt.ProjectRequest
    ) throws -> FrontendReceipt.ProjectOutput {
        guard (1...256).contains(request.modules.count) else {
            throw FrontendReceipt.Error.invalidRequest(
                "project indexing requires 1...256 Swift modules"
            )
        }
        let sorted = request.modules.sorted {
            $0.metadata.frontendInvocation.moduleName
                < $1.metadata.frontendInvocation.moduleName
        }
        let names = sorted.map(\.metadata.frontendInvocation.moduleName)
        guard Set(names).count == names.count, let first = sorted.first else {
            throw FrontendReceipt.Error.invalidRequest(
                "project indexing contains duplicate Swift modules"
            )
        }
        let configuredNames = Set(first.configuration.modules.keys)
        guard Set(names) == configuredNames,
              sorted.allSatisfy({ $0.configuration == first.configuration })
        else {
            throw FrontendReceipt.Error.invalidRequest(
                "project indexing must cover one shared configuration's complete module set"
            )
        }
        let identity = ProjectIdentity(first.metadata)
        let compilerPath = first.compilerURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard sorted.allSatisfy({
            ProjectIdentity($0.metadata) == identity
                && $0.compilerURL.resolvingSymlinksInPath().standardizedFileURL.path
                    == compilerPath
        }) else {
            throw FrontendReceipt.Error.invalidRequest(
                "project modules disagree on App, target, SDK, namespace, or Swift compiler identity"
            )
        }

        var outputs: [String: FrontendReceipt.Output] = [:]
        var reports: [FrontendReceipt.ProjectModuleReport] = []
        var toolchainFingerprint: String?
        for module in sorted {
            let name = module.metadata.frontendInvocation.moduleName
            let output = try FrontendReceipt.Adapter().generate(module)
            if let toolchainFingerprint {
                guard toolchainFingerprint == output.toolchain.fingerprint else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "project modules were indexed by different Swift toolchains"
                    )
                }
            } else {
                toolchainFingerprint = output.toolchain.fingerprint
            }
            let receiptBytes = try ShellBuildReceipt.Codec.encode(output.receipt)
            reports.append(
                .init(
                    moduleName: name,
                    receiptPath: "Receipts/\(name).ShellBuildReceipt.json",
                    diagnosticsPath: "Diagnostics/\(name).json",
                    receiptHash: .sha256(receiptBytes),
                    sourceCount: try boundedCount(output.receipt.sources.count),
                    declarationCount: try boundedCount(output.receipt.declarations.count),
                    eligibleEntryCount: try boundedCount(
                        output.receipt.roots.filter { $0.bridge != nil }.count
                    ),
                    emittedNativeImportCount: try boundedCount(
                        output.receipt.nativeImportCandidates.filter(\.isEmittedToDevice).count
                    ),
                    generatedNativeImportCount: try boundedCount(
                        output.receipt.nativeImportBindings.filter { $0.generated != nil }.count
                    ),
                    diagnosticCount: try boundedCount(output.diagnostics.count)
                )
            )
            outputs[name] = output
        }
        guard let fingerprint = toolchainFingerprint else {
            throw FrontendReceipt.Error.invalidRequest("project indexing produced no modules")
        }
        let report = FrontendReceipt.ProjectReport(
            bundleID: first.metadata.bundleID,
            buildNumber: first.metadata.buildNumber,
            shellNamespaceID: first.metadata.shellNamespaceID,
            toolchainFingerprint: fingerprint,
            modules: reports
        )
        try report.validate()
        return .init(modules: outputs, report: report)
    }

    private func boundedCount(_ value: Int) throws -> UInt32 {
        guard let result = UInt32(exactly: value) else {
            throw FrontendReceipt.Error.invalidRequest("project index count exceeds UInt32")
        }
        return result
    }
}
}
