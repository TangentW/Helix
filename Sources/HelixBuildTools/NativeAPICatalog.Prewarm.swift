import Foundation
import HelixCore

extension NativeAPICatalog {
public struct PrewarmJob: Codable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var cacheRootPath: String
    public var workingDirectoryPath: String
    public var planRequest: NativeAPICatalog.PlanRequest
    public var requests: [NativeAPICatalog.BuildRequest]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        cacheRootURL: URL,
        workingDirectoryURL: URL,
        planRequest: NativeAPICatalog.PlanRequest,
        requests: [NativeAPICatalog.BuildRequest]
    ) {
        self.schemaVersion = schemaVersion
        cacheRootPath = cacheRootURL.standardizedFileURL.path
        workingDirectoryPath = workingDirectoryURL.standardizedFileURL.path
        self.planRequest = planRequest
        self.requests = requests.sorted {
            ($0.identity.moduleName, $0.identity.cacheKey)
                < ($1.identity.moduleName, $1.identity.cacheKey)
        }
    }

    public func validate() throws {
        let root = URL(fileURLWithPath: cacheRootPath).standardizedFileURL
        let workingDirectory = URL(
            fileURLWithPath: workingDirectoryPath
        ).standardizedFileURL
        let order = requests.map {
            $0.identity.moduleName + "\u{0}" + $0.identity.cacheKey.hex
        }
        guard schemaVersion == Self.currentSchemaVersion,
              cacheRootPath == root.path,
              cacheRootPath.hasPrefix("/"),
              cacheRootPath != "/",
              !cacheRootPath.contains("\n"),
              !cacheRootPath.contains("\r"),
              workingDirectoryPath == workingDirectory.path,
              workingDirectoryPath.hasPrefix("/"),
              workingDirectoryPath != "/",
              !workingDirectoryPath.contains("\n"),
              !workingDirectoryPath.contains("\r"),
              !requests.isEmpty,
              requests.count <= 256,
              order == order.sorted(),
              Set(requests.map { $0.identity.moduleName }).count
                == requests.count
        else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog prewarm job is empty, oversized, duplicated, or noncanonical"
            )
        }
        guard planRequest.workingDirectory.standardizedFileURL.path
                == workingDirectoryPath,
              planRequest.compilerURL.standardizedFileURL
                == planRequest.compilerURL,
              planRequest.compilerURL.path.hasPrefix("/"),
              planRequest.importedModules
                == Array(Set(planRequest.importedModules)).sorted(),
              planRequest.compilerInputs.isComplete,
              Set(try NativeAPICatalog.ModuleSelection.catalogModules(
                  planRequest.compilerInputs.importedModules,
                  excluding: planRequest.metadata.frontendInvocation.moduleName
              )).isSubset(of: Set(try NativeAPICatalog.ModuleSelection
                  .catalogModules(
                      planRequest.importedModules,
                      excluding: planRequest.metadata.frontendInvocation
                          .moduleName
                  ))),
              planRequest.toolchain.fingerprint
                == requests[0].identity.compilerFingerprint,
              planRequest.sdk.name
                == requests[0].frontendInvocation.sdkName,
              planRequest.sdk.buildVersion
                == requests[0].identity.sdkProductBuild,
              Set(requests.map { $0.identity.moduleName }).isSubset(
                  of: Set(try NativeAPICatalog.ModuleSelection.catalogModules(
                      planRequest.importedModules,
                      excluding: planRequest.metadata.frontendInvocation
                          .moduleName
                  ))
              )
        else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog prewarm plan disagrees with its initial requests"
            )
        }
        for request in requests {
            try request.frontendInvocation.validate()
            try NativeAPICatalog.Document(
                identity: request.identity,
                entries: []
            ).validate()
            guard request.compilerURL.standardizedFileURL.path
                    == request.compilerURL.path,
                  request.compilerURL.path.hasPrefix("/"),
                  request.compilerURL == planRequest.compilerURL,
                  request.frontendInvocation
                    == planRequest.metadata.frontendInvocation,
                  request.workingDirectoryURL?.standardizedFileURL.path
                    == workingDirectoryPath,
                  request.precomputedToolchain == planRequest.toolchain,
                  request.precomputedSDK == planRequest.sdk,
                  request.identity.compilerFingerprint
                    == planRequest.toolchain.fingerprint,
                  request.identity.targetTriple
                    == planRequest.metadata.targetTriple,
                  request.identity.minimumDeployment
                    == planRequest.metadata.minimumOS,
                  request.identity.xcodeProductBuild
                    == planRequest.metadata.xcodeBuild,
                  request.identity.sdkProductBuild
                    == planRequest.sdk.buildVersion
            else {
                throw NativeAPICatalog.Error.invalid(
                    "Catalog prewarm request is not bound to its compiler and SDK identity"
                )
            }
        }
    }
}

public enum PrewarmJobCodec {
    public static let maximumDocumentBytes = 16 * 1_024 * 1_024

    public static func encode(
        _ job: NativeAPICatalog.PrewarmJob
    ) throws -> Data {
        try job.validate()
        let data = try Core.CanonicalJSON.encode(job)
        guard data.count <= maximumDocumentBytes else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog prewarm job exceeds 16 MiB"
            )
        }
        return data
    }

    public static func decode(
        _ data: Data
    ) throws -> NativeAPICatalog.PrewarmJob {
        guard !data.isEmpty, data.count <= maximumDocumentBytes else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog prewarm job is empty or oversized"
            )
        }
        let job: NativeAPICatalog.PrewarmJob
        do {
            job = try JSONDecoder().decode(
                NativeAPICatalog.PrewarmJob.self,
                from: data
            )
        } catch {
            throw NativeAPICatalog.Error.invalid(
                "Catalog prewarm job cannot be decoded: \(error)"
            )
        }
        try job.validate()
        guard try Core.CanonicalJSON.encode(job) == data else {
            throw NativeAPICatalog.Error.invalid(
                "Catalog prewarm job is noncanonical"
            )
        }
        return job
    }
}
}
