import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

extension NativeAPICatalog {
public struct PlanRequest: Codable, Sendable {
    public var metadata: InterfaceArchive.ReleaseMetadata
    public var importedModules: [String]
    public var compilerArguments: [String]
    public var compilerURL: URL
    public var workingDirectory: URL
    public var toolchain: ReleaseCompiler.ToolchainIdentity
    public var sdk: SwiftFrontend.Driver.SDKIdentity
    public var compilerInputs: BuildCache.CompilerInputs.Snapshot

    public init(
        metadata: InterfaceArchive.ReleaseMetadata,
        importedModules: [String],
        compilerArguments: [String],
        compilerURL: URL,
        workingDirectory: URL,
        toolchain: ReleaseCompiler.ToolchainIdentity,
        sdk: SwiftFrontend.Driver.SDKIdentity,
        compilerInputs: BuildCache.CompilerInputs.Snapshot
    ) {
        self.metadata = metadata
        self.importedModules = importedModules
        self.compilerArguments = compilerArguments
        self.compilerURL = compilerURL
        self.workingDirectory = workingDirectory
        self.toolchain = toolchain
        self.sdk = sdk
        self.compilerInputs = compilerInputs
    }
}

public struct BuildPlan: Sendable {
    public var requests: [NativeAPICatalog.BuildRequest]
    public var unresolvedModules: [String]

    public init(
        requests: [NativeAPICatalog.BuildRequest],
        unresolvedModules: [String]
    ) {
        self.requests = requests
        self.unresolvedModules = unresolvedModules
    }
}

/// Derives Catalog identities entirely from the captured compiler and module
/// inputs. Project configuration never lists individual APIs or descriptors.
public struct Planner: Sendable {
    public init() {}

    /// Validates an accumulated closure before planning only its new members.
    public static func catalogModules(_ importedModules: [String], excluding currentModule: String) throws -> [String] {
        let modules = try ModuleSelection.catalogModules(importedModules, excluding: currentModule)
        guard modules.count <= 256 else {
            throw NativeAPICatalog.Error.invalid("Catalog planning exceeds the 256-module build bound")
        }
        return modules
    }

    public func plan(
        _ request: NativeAPICatalog.PlanRequest
    ) throws -> NativeAPICatalog.BuildPlan {
        try request.metadata.frontendInvocation.validate()
        guard request.metadata.machOUUIDs.isEmpty,
              !request.toolchain.fingerprint.isEmpty,
              request.sdk.name == request.metadata.frontendInvocation.sdkName,
              request.sdk.buildVersion == request.metadata.sdkBuild,
              URL(fileURLWithPath: request.sdk.path).standardizedFileURL.path
                == request.sdk.path,
              request.sdk.path.hasPrefix("/"),
              !request.compilerURL.path.isEmpty,
              request.compilerURL.standardizedFileURL.path
                == request.compilerURL.path,
              request.compilerURL.path.hasPrefix("/"),
              request.workingDirectory.standardizedFileURL.path
                == request.workingDirectory.path,
              request.workingDirectory.path.hasPrefix("/")
        else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog planning identity is incomplete or disagrees with the build"
            )
        }
        let modules = try Self.catalogModules(
            request.importedModules,
            excluding: request.metadata.frontendInvocation.moduleName
        )
        guard request.compilerInputs.isComplete else {
            return .init(requests: [], unresolvedModules: modules)
        }
        let languageMode = try Self.swiftLanguageMode(
            in: request.metadata.frontendInvocation.semanticArguments
        )
        let normalizedSearchArguments = NativeAPICatalog.Builder
            .cacheIdentityArguments(
                request.metadata.frontendInvocation.semanticArguments
            )
        let searchIdentity = try BuildCache.key(
            domain: "HLX.APICatalog.ModuleSearch.v1",
            value: normalizedSearchArguments
        )
        var requests: [NativeAPICatalog.BuildRequest] = []
        var unresolved: [String] = []
        let directoryCache = BuildCache.CompilerInputs.DirectoryInventoryCache()
        for module in modules {
            let inputs = BuildCache.CompilerInputs.capture(
                arguments: request.compilerArguments,
                currentModuleName:
                    request.metadata.frontendInvocation.moduleName,
                workingDirectory: request.workingDirectory,
                importedModules: [module],
                directoryCache: directoryCache
            )
            guard inputs.isComplete else {
                unresolved.append(module)
                continue
            }
            let isSystemModule = inputs.fileCount == 0
            let contentHash: Core.Digest
            let dependencyHash: Core.Digest
            if isSystemModule {
                contentHash = .sha256(
                    "HLX.APICatalog.SystemModule.v1:"
                        + "\(request.sdk.buildVersion):\(module)"
                )
                dependencyHash = .sha256(
                    "HLX.APICatalog.SystemDependencies.v1:"
                        + "\(request.sdk.buildVersion):\(module)"
                )
            } else {
                contentHash = inputs.contentHash
                // The aggregate capture conservatively binds a third-party
                // module to every imported dependency visible to this exact
                // build. It may invalidate more often than a transitive graph,
                // but it can never reuse across changed dependency bytes.
                dependencyHash = request.compilerInputs.contentHash
            }
            let identity = NativeAPICatalog.Identity(
                provenance: isSystemModule
                    ? .systemSDK : .thirdPartyModule,
                xcodeProductBuild: request.metadata.xcodeBuild,
                sdkProductBuild: request.metadata.sdkBuild,
                compilerFingerprint: request.toolchain.fingerprint,
                targetTriple: request.metadata.targetTriple,
                minimumDeployment: request.metadata.minimumOS,
                swiftLanguageMode: languageMode,
                moduleName: module,
                moduleContentHash: contentHash,
                moduleSearchPathHash: searchIdentity,
                dependencyGraphHash: dependencyHash
            )
            requests.append(.init(
                identity: identity,
                frontendInvocation: request.metadata.frontendInvocation,
                compilerURL: request.compilerURL,
                workingDirectoryURL: request.workingDirectory,
                precomputedToolchain: request.toolchain,
                precomputedSDK: request.sdk
            ))
        }
        return .init(
            requests: requests.sorted {
                $0.identity.moduleName < $1.identity.moduleName
            },
            unresolvedModules: unresolved.sorted()
        )
    }

    static func swiftLanguageMode(in arguments: [String]) throws -> String {
        let options = Set(["-swift-version", "-language-mode"])
        var result: String?
        var index = 0
        while index < arguments.count {
            guard options.contains(arguments[index]) else {
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog language-mode option is incomplete"
                )
            }
            let value = arguments[index + 1]
            guard !value.isEmpty, value.utf8.count <= 32,
                  !value.unicodeScalars.contains(where: { $0.value == 0 })
            else {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog language mode is invalid"
                )
            }
            if let result, result != value {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog invocation has conflicting language modes"
                )
            }
            result = value
            index += 2
        }
        return result ?? "default"
    }
}
}

extension NativeAPICatalog {
enum ModuleSelection {}
}

extension NativeAPICatalog.ModuleSelection {
    private static let compilerOwnedModules: Set<String> = [
        "Builtin", "Cxx", "CxxStdlib", "ObjectiveC", "Swift",
        "SwiftOnoneSupport", "_Concurrency", "_StringProcessing",
    ]

    static func catalogModules(
        _ importedModules: [String],
        excluding currentModule: String
    ) throws -> [String] {
        var modules = Set<String>()
        for path in importedModules {
            guard let module = path.split(separator: ".").first.map(String.init),
                  isModuleIdentifier(module)
            else {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog import module is invalid: \(path)"
                )
            }
            if module != currentModule,
               !compilerOwnedModules.contains(module) {
                modules.insert(module)
            }
        }
        return modules.sorted()
    }

    private static func isModuleIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first),
              value.utf8.count <= 1_024
        else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }
}
