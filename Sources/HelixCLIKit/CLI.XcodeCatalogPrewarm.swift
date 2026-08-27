import Darwin
import Foundation
import HelixBuildTools
import HelixCompiler
import HelixCore
import HelixInterface

extension CLI {
enum CatalogPrewarmProcess {
    static func launch(
        executableURL: URL,
        jobURL: URL,
        logURL: URL,
        workingDirectoryURL: URL
    ) throws {
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path
        ) else {
            throw CLI.Error.input(
                "Helix executable is unavailable for Catalog prewarming"
            )
        }
        let descriptor = Darwin.open(
            logURL.path,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CLI.Error.input(
                "cannot open Catalog prewarm log at \(logURL.path)"
            )
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o177 == 0
        else {
            try? handle.close()
            throw CLI.Error.input(
                "Catalog prewarm log is not an owner-only regular file"
            )
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "xcode", "catalog-prewarm", "--job", jobURL.path,
        ]
        process.currentDirectoryURL = workingDirectoryURL
        process.qualityOfService = .utility
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            try? handle.close()
            throw CLI.Error.input(
                "cannot launch Catalog prewarm worker: \(error.localizedDescription)"
            )
        }
        try? handle.close()
    }
}
}

extension CLI.Application {
    struct XcodeNativeAPICatalogResolution: Sendable {
        var snapshots: [NativeAPICatalog.Snapshot]
        var prewarmRequests: [NativeAPICatalog.BuildRequest]
        var prewarmPlanRequest: NativeAPICatalog.PlanRequest
        var unresolvedModules: [String]
    }

    func resolveXcodeNativeAPICatalogs(
        context: XcodeIntegration.BuildContext,
        metadata: InterfaceArchive.ReleaseMetadata,
        importedModules: [String],
        compilerArguments: [String],
        compilerInputs: BuildCache.CompilerInputs.Snapshot,
        toolchain: ReleaseCompiler.ToolchainIdentity,
        cache: BuildCache.Store,
        performance: BuildPerformance.Recorder
    ) async throws -> XcodeNativeAPICatalogResolution {
        let sdk = SwiftFrontend.Driver.SDKIdentity(
            name: context.environment.sdkName,
            path: context.environment.sdkRootURL.standardizedFileURL.path,
            buildVersion: context.environment.sdkBuild
        )
        let builder = NativeAPICatalog.Builder(
            cache: cache,
            invocationObserver: performance.subprocessObserver
        )
        var snapshots: [NativeAPICatalog.Snapshot] = []
        var prewarmRequests: [NativeAPICatalog.BuildRequest] = []
        var requestedModules = Set(importedModules)
        var processedModules = Set<String>()
        var unresolvedModules = Set<String>()
        var cacheHits: UInt64 = 0
        var generated: UInt64 = 0
        var entryCount: UInt64 = 0
        var planRequest = NativeAPICatalog.PlanRequest(
            metadata: metadata,
            importedModules: importedModules,
            compilerArguments: compilerArguments,
            compilerURL: context.environment.compilerURL,
            workingDirectory: context.environment.sourceRootURL,
            toolchain: toolchain,
            sdk: sdk,
            compilerInputs: compilerInputs
        )
        while true {
            let plan = try performance.measure("prepare.catalog_plan") {
                planRequest.importedModules = Array(requestedModules).sorted()
                return try NativeAPICatalog.Planner().plan(planRequest)
            }
            unresolvedModules.formUnion(plan.unresolvedModules)
            let pending = plan.requests.filter {
                !processedModules.contains($0.identity.moduleName)
            }.sorted {
                $0.identity.moduleName < $1.identity.moduleName
            }
            guard !pending.isEmpty else { break }
            var discoveredModules = Set<String>()
            let isLiveReload = context.profile.workflow == .liveReload
            let parallelism = isLiveReload ? 4 : 2
            var resolved: [(NativeAPICatalog.BuildRequest,
                            NativeAPICatalog.BuildOutput?)] = []
            for start in stride(from: 0, to: pending.count, by: parallelism) {
                let end = min(start + parallelism, pending.count)
                let batch = Array(pending[start..<end])
                let outputs = try await performance.measure(
                    isLiveReload ? "prepare.catalog_read" : "prepare.catalog_build"
                ) {
                    try await withThrowingTaskGroup(
                        of: (Int, NativeAPICatalog.BuildOutput?).self
                    ) { group in
                        for (offset, request) in batch.enumerated() {
                            group.addTask {
                                let output = if isLiveReload {
                                    try builder.cached(request)
                                } else {
                                    try builder.build(request)
                                }
                                return (offset, output)
                            }
                        }
                        var values: [(Int, NativeAPICatalog.BuildOutput?)] = []
                        for try await value in group {
                            values.append(value)
                        }
                        return values.sorted { $0.0 < $1.0 }.map(\.1)
                    }
                }
                resolved.append(contentsOf: zip(batch, outputs))
            }
            for (request, output) in resolved {
                processedModules.insert(request.identity.moduleName)
                if isLiveReload, output == nil { prewarmRequests.append(request) }
                guard let output else { continue }
                performance.merge(output.performance)
                snapshots.append(output.snapshot)
                discoveredModules.formUnion(
                    output.snapshot.referencedModules
                )
                entryCount += output.metrics.entryCount
                if output.metrics.cacheSource == .hit {
                    cacheHits += 1
                } else {
                    generated += 1
                }
            }
            let previousCount = requestedModules.count
            requestedModules.formUnion(discoveredModules)
            if requestedModules.count == previousCount { break }
        }
        let unresolved = unresolvedModules.sorted()
        if context.profile.workflow == .hotPatch, !unresolved.isEmpty {
            throw CLI.Error.input(
                "Hot Patch Native API Catalog planning is incomplete for modules: "
                    + unresolved.joined(separator: ", ")
                    + ". Check the captured module search paths and rebuild the Feature target."
            )
        }
        snapshots.sort {
            ($0.document.identity.moduleName, $0.document.identity.cacheKey)
                < ($1.document.identity.moduleName, $1.document.identity.cacheKey)
        }
        performance.setCounter(
            "prepare.catalog_planned_module_count",
            value: UInt64(processedModules.count)
        )
        performance.setCounter(
            "prepare.catalog_unresolved_module_count",
            value: UInt64(unresolved.count)
        )
        performance.setCounter(
            "prepare.catalog_hit_module_count",
            value: cacheHits
        )
        performance.setCounter(
            "prepare.catalog_generated_module_count",
            value: generated
        )
        performance.setCounter(
            "prepare.catalog_miss_module_count",
            value: UInt64(prewarmRequests.count + unresolved.count)
        )
        performance.setCounter(
            "prepare.catalog_entry_count",
            value: entryCount
        )
        planRequest.importedModules = Array(requestedModules).sorted()
        return .init(
            snapshots: snapshots,
            prewarmRequests: prewarmRequests,
            prewarmPlanRequest: planRequest,
            unresolvedModules: unresolved
        )
    }

    func scheduleNativeAPICatalogPrewarm(
        requests: [NativeAPICatalog.BuildRequest],
        cache: BuildCache.Store,
        workingDirectoryURL: URL,
        planRequest: NativeAPICatalog.PlanRequest,
        outputDirectoryURL: URL
    ) throws {
        guard !requests.isEmpty else { return }
        let job = NativeAPICatalog.PrewarmJob(
            cacheRootURL: cache.rootURL,
            workingDirectoryURL: workingDirectoryURL,
            planRequest: planRequest,
            requests: requests
        )
        let data = try NativeAPICatalog.PrewarmJobCodec.encode(job)
        let identifier = try BuildCache.key(
            domain: "HLX.NativeAPICatalog.PrewarmJob.v1",
            value: job
        ).hex
        let directory = outputDirectoryURL.appendingPathComponent(
            ".NativeAPICatalogPrewarm",
            isDirectory: true
        )
        try preparePrivateCatalogDirectory(directory)
        let jobURL = directory.appendingPathComponent("\(identifier).json")
        try publishPrivateCatalogJob(data, to: jobURL)
        let logURL = directory.appendingPathComponent("\(identifier).log")
        try catalogPrewarmLauncher(
            executableURL,
            jobURL,
            logURL,
            workingDirectoryURL
        )
    }

    func prewarmXcodeCatalogs(
        _ arguments: [String]
    ) throws -> CLI.Result {
        let options = try CLI.Arguments(
            arguments,
            valueOptions: ["job"],
            flagOptions: []
        )
        guard options.positionals.isEmpty else {
            throw CLI.Error.usage(
                "xcode catalog-prewarm accepts no positional arguments"
            )
        }
        let jobURL = files.resolve(try options.require("job"))
        let descriptor = Darwin.open(
            jobURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw CLI.Error.input(
                "cannot open Catalog prewarm job at \(jobURL.path)"
            )
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o177 == 0,
              information.st_size > 0,
              information.st_size
                <= NativeAPICatalog.PrewarmJobCodec.maximumDocumentBytes
        else {
            throw CLI.Error.input(
                "Catalog prewarm job is not an owner-only bounded regular file"
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                return .init(
                    exitCode: 0,
                    standardOutput: "Catalog prewarm is already running\n"
                )
            }
            throw CLI.Error.input("cannot lock Catalog prewarm job")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        let data = try handle.readToEnd() ?? Data()
        let job = try NativeAPICatalog.PrewarmJobCodec.decode(data)
        guard job.workingDirectoryPath
                == URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .standardizedFileURL.path
        else {
            throw CLI.Error.input(
                "Catalog prewarm worker started in the wrong working directory"
            )
        }
        let cache = try BuildCache.Store(
            rootURL: URL(fileURLWithPath: job.cacheRootPath)
        )
        let currentToolchain = try ReleaseCompiler.Driver()
            .toolchainIdentity(compilerURL: job.planRequest.compilerURL)
        guard currentToolchain == job.planRequest.toolchain else {
            throw CLI.Error.input(
                "Catalog prewarm compiler changed after Prepare"
            )
        }
        let frontend = SwiftFrontend.Driver(
            compilerURL: job.planRequest.compilerURL,
            defaultWorkingDirectoryURL: URL(
                fileURLWithPath: job.workingDirectoryPath
            )
        )
        let currentSDK = try frontend.sdkIdentity(
            name: job.planRequest.sdk.name
        )
        guard currentSDK == job.planRequest.sdk else {
            throw CLI.Error.input(
                "Catalog prewarm SDK changed after Prepare"
            )
        }
        let currentCompilerInputs = BuildCache.CompilerInputs.capture(
            arguments: job.planRequest.compilerArguments,
            currentModuleName: job.planRequest.metadata.frontendInvocation
                .moduleName,
            workingDirectory: job.planRequest.workingDirectory,
            importedModules: Set(
                job.planRequest.compilerInputs.importedModules
            )
        )
        guard currentCompilerInputs == job.planRequest.compilerInputs else {
            throw CLI.Error.input(
                "Catalog prewarm compiler inputs changed after Prepare"
            )
        }
        let builder = NativeAPICatalog.Builder(cache: cache)
        let initialPlan = try NativeAPICatalog.Planner().plan(
            job.planRequest
        )
        let plannedByModule = Dictionary(uniqueKeysWithValues:
            initialPlan.requests.map { ($0.identity.moduleName, $0) }
        )
        guard job.requests.allSatisfy({ request in
            plannedByModule[request.identity.moduleName] == request
        }) else {
            throw CLI.Error.input(
                "Catalog prewarm requests no longer match their compiler inputs"
            )
        }
        let initialRequestModules = Set(
            job.requests.map { $0.identity.moduleName }
        )
        var processedModules = Set(
            initialPlan.requests.map { $0.identity.moduleName }
        ).subtracting(initialRequestModules)
        var requestedModules = Set(job.planRequest.importedModules)
        var pending = job.requests
        var completedCount = 0
        while !pending.isEmpty {
            var referencedModules = Set<String>()
            for request in pending {
                processedModules.insert(request.identity.moduleName)
                let output = try builder.build(request)
                completedCount += 1
                referencedModules.formUnion(
                    output.snapshot.referencedModules
                )
            }
            let previousCount = requestedModules.count
            requestedModules.formUnion(referencedModules)
            guard requestedModules.count != previousCount else { break }
            var followupRequest = job.planRequest
            followupRequest.importedModules = Array(requestedModules).sorted()
            let followup = try NativeAPICatalog.Planner().plan(
                followupRequest
            )
            guard followup.unresolvedModules.isEmpty else {
                throw CLI.Error.input(
                    "Catalog prewarm cannot resolve referenced modules: "
                        + followup.unresolvedModules.joined(separator: ", ")
                )
            }
            pending = followup.requests.filter {
                !processedModules.contains($0.identity.moduleName)
            }
        }
        do {
            try FileManager.default.removeItem(at: jobURL)
        } catch CocoaError.fileNoSuchFile {
            // Another completed worker may have unlinked the same immutable
            // job after this process opened it.
        } catch {
            throw CLI.Error.input(
                "cannot retire Catalog prewarm job: \(error.localizedDescription)"
            )
        }
        return .init(
            exitCode: 0,
            standardOutput: "Prewarmed \(completedCount) Native API Catalog module(s)\n"
        )
    }

    private func preparePrivateCatalogDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw CLI.Error.input(
                "cannot create Catalog prewarm directory: \(error.localizedDescription)"
            )
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw CLI.Error.input(
                "cannot open Catalog prewarm directory"
            )
        }
        defer { Darwin.close(descriptor) }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid()
        else {
            throw CLI.Error.input(
                "Catalog prewarm directory is not an owner-private directory"
            )
        }
        guard fchmod(descriptor, S_IRWXU) == 0,
              fstat(descriptor, &information) == 0,
              information.st_mode & 0o077 == 0
        else {
            throw CLI.Error.input(
                "cannot protect Catalog prewarm directory"
            )
        }
    }

    private func publishPrivateCatalogJob(
        _ data: Data,
        to url: URL
    ) throws {
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CLI.Error.input(
                "cannot create Catalog prewarm job at \(temporaryURL.path)"
            )
        }
        defer {
            Darwin.close(descriptor)
            _ = Darwin.unlink(temporaryURL.path)
        }
        var written = 0
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw CLI.Error.input(
                        "cannot write Catalog prewarm job at \(url.path)"
                    )
                }
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CLI.Error.input(
                "cannot sync Catalog prewarm job at \(temporaryURL.path)"
            )
        }
        guard Darwin.link(temporaryURL.path, url.path) == 0 else {
            if errno == EEXIST {
                let existing = try readPrivateCatalogJob(url)
                guard existing == data else {
                    throw CLI.Error.input(
                        "Catalog prewarm job identity collides with different bytes"
                    )
                }
                return
            }
            throw CLI.Error.input(
                "cannot publish Catalog prewarm job at \(url.path)"
            )
        }
    }

    private func readPrivateCatalogJob(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw CLI.Error.input(
                "cannot read Catalog prewarm job at \(url.path)"
            )
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o177 == 0,
              information.st_size > 0,
              information.st_size
                <= NativeAPICatalog.PrewarmJobCodec.maximumDocumentBytes
        else {
            throw CLI.Error.input(
                "Catalog prewarm job is not an owner-only bounded regular file"
            )
        }
        return try handle.readToEnd() ?? Data()
    }
}
