import Darwin
import Foundation
import HelixBuildTools
import HelixCompiler
import HelixCore
import HelixInterface

extension CLI {
public struct XcodeCatalogPlanReport: Codable, Sendable {
    public var schemaVersion: UInt16 = 1
    public var cachedModules: [String]
    public var pendingModules: [String]
    public var unresolvedModules: [String]
    public var unresolvedReasons: [String: [String]]
    public var jobPath: String?
}

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
        var unresolvedReasons: [String: [String]]
    }

    func resolveXcodeNativeAPICatalogs(
        context: XcodeIntegration.BuildContext,
        metadata: InterfaceArchive.ReleaseMetadata,
        importedModules: [String],
        compilerArguments: [String],
        compilerInputs: BuildCache.CompilerInputs.Snapshot,
        toolchain: ReleaseCompiler.ToolchainIdentity,
        cache: BuildCache.Store,
        performance: BuildPerformance.Recorder,
        cachedOnly: Bool = false
    ) async throws -> XcodeNativeAPICatalogResolution {
        let sdk = SwiftFrontend.Driver.SDKIdentity(
            name: context.environment.sdkName,
            path: context.environment.sdkRootURL.standardizedFileURL.path,
            buildVersion: context.environment.sdkBuild
        )
        let budget = NativeAPICatalog.WorkBudget()
        let builder = NativeAPICatalog.Builder(
            cache: cache,
            invocationObserver: performance.subprocessObserver,
            maximumProbeWorkers: budget.probesPerModule(concurrentModules: min(2, budget.moduleWorkers))
        )
        var snapshots: [NativeAPICatalog.Snapshot] = []
        var prewarmRequests: [NativeAPICatalog.BuildRequest] = []
        var requestedModules = Set(try NativeAPICatalog.Planner.catalogModules(
            importedModules, excluding: metadata.frontendInvocation.moduleName
        ))
        var processedModules = Set<String>()
        var unresolvedModules = Set<String>()
        var unresolvedReasons: [String: [String]] = [:]
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
                // Previously processed modules already have exact identities.
                // Re-scanning their input trees for every newly found dependency
                // makes a large transitive closure quadratic in filesystem work.
                planRequest.importedModules = requestedModules
                    .subtracting(processedModules).subtracting(unresolvedModules).sorted()
                return try NativeAPICatalog.Planner().plan(planRequest)
            }
            unresolvedModules.formUnion(plan.unresolvedModules)
            for (module, reasons) in plan.unresolvedReasons {
                unresolvedReasons[module] = Array(Set((unresolvedReasons[module] ?? []) + reasons)).sorted()
            }
            let pending = plan.requests.filter {
                !processedModules.contains($0.identity.moduleName)
            }.sorted {
                $0.identity.moduleName < $1.identity.moduleName
            }
            guard !pending.isEmpty else { break }
            var discoveredModules = Set<String>()
            let isLiveReload = cachedOnly || context.profile.workflow == .liveReload
            let parallelism = isLiveReload ? 4 : min(2, budget.moduleWorkers)
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
            requestedModules = Set(try NativeAPICatalog.Planner.catalogModules(
                Array(requestedModules.union(discoveredModules)),
                excluding: metadata.frontendInvocation.moduleName
            ))
            if requestedModules.count == previousCount { break }
        }
        let unresolved = unresolvedModules.sorted()
        if !cachedOnly, context.profile.workflow == .hotPatch, !unresolved.isEmpty {
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
            value: UInt64(prewarmRequests.count)
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
            unresolvedModules: unresolved,
            unresolvedReasons: unresolvedReasons
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
        let jobURL = try publishNativeAPICatalogPrewarmJob(requests: requests, cache: cache,
            workingDirectoryURL: workingDirectoryURL, planRequest: planRequest, outputDirectoryURL: outputDirectoryURL)
        let logURL = jobURL.deletingPathExtension().appendingPathExtension("log")
        try catalogPrewarmLauncher(executableURL, jobURL, logURL, workingDirectoryURL)
    }

    func publishNativeAPICatalogPrewarmJob(
        requests: [NativeAPICatalog.BuildRequest], cache: BuildCache.Store,
        workingDirectoryURL: URL, planRequest: NativeAPICatalog.PlanRequest,
        outputDirectoryURL: URL
    ) throws -> URL {
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
        return jobURL
    }

    func prewarmXcodeCatalogs(
        _ arguments: [String]
    ) throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: """
            Usage: helix xcode catalog-prewarm --job <path> [--max-modules <1...256>] [--jobs <1...8>] [--json]
               or: helix xcode catalog-prewarm --plan <path> --profile <id> --capture <path>
                     [--plan-only] [--max-modules <1...256>] [--jobs <1...8>] [--json]

            Capture mode accepts FrontendAttempt.hlxswiftc and needs no successful
            Prepare, AST or SIL. --plan-only publishes a private resumable job and
            reads existing Catalogs without cold generation. JSON also reports worker outcomes.
            All compiler work uses the captured project working directory.
            A module limit pauses
            after that many cold attempts (including failures); rerun the same job to resume. Completed
            modules are reused and do not consume the limit. Changed build inputs
            require a new capture-driven job. The job is retired only after completion.

            """)
        }
        let options = try CLI.Arguments(
            arguments,
            valueOptions: ["job", "max-modules", "jobs"],
            flagOptions: ["json"]
        )
        guard options.positionals.isEmpty else {
            throw CLI.Error.usage(
                "xcode catalog-prewarm accepts no positional arguments"
            )
        }
        let maximumModules: Int
        if let value = try options.value("max-modules") {
            guard let count = Int(value), (1...256).contains(count) else {
                throw CLI.Error.usage("--max-modules must be an integer in 1...256")
            }
            maximumModules = count
        } else {
            maximumModules = 256
        }
        let requestedJobs: Int
        if let value = try options.value("jobs") {
            guard let count = Int(value), (1...8).contains(count) else {
                throw CLI.Error.usage("--jobs must be an integer in 1...8")
            }
            requestedJobs = count
        } else { requestedJobs = 4 }
        let workBudget = NativeAPICatalog.WorkBudget(requestedModules: requestedJobs)
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
        // Every planner, input snapshot and compiler request uses the validated
        // job directory explicitly. Never mutate this process's global cwd.
        let cache = try BuildCache.Store(
            rootURL: URL(fileURLWithPath: job.cacheRootPath)
        )
        let currentToolchain = try ReleaseCompiler.Driver()
            .toolchainIdentity(compilerURL: job.planRequest.compilerURL)
        guard currentToolchain == job.planRequest.toolchain else {
            throw CLI.Error.input(
                "Catalog prewarm compiler changed since job creation"
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
                "Catalog prewarm SDK changed since job creation"
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
                "Catalog prewarm compiler inputs changed since job creation"
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
        let reportDirectory = cache.rootURL.appendingPathComponent("PrewarmReports", isDirectory: true)
        try preparePrivateCatalogDirectory(reportDirectory)
        let jobDigest = Core.Digest.sha256(data)
        let reportURL = reportDirectory.appendingPathComponent(jobDigest.hex + ".json")
        var previouslyFailed = Set<String>()
        if FileManager.default.fileExists(atPath: reportURL.path) {
            let previousBytes = try readPrivateCatalogJob(reportURL, maximumBytes: 64 * 1_024 * 1_024)
            // The report only prioritizes retries; corrupt diagnostic JSON
            // must not invalidate compiler artifacts or prevent a fresh run.
            if let previous = try? JSONDecoder().decode(CLI.CatalogPrewarmReport.self, from: previousBytes),
               previous.schemaVersion == 1, previous.jobDigest == jobDigest {
                previouslyFailed = Set(previous.modules.filter { $0.status == .failed }.map(\.name))
            }
        }
        var records: [String: CLI.CatalogPrewarmReport.Module] = [:]
        var unresolved = initialPlan.unresolvedReasons
        for module in initialPlan.unresolvedModules {
            unresolved[module] = unresolved[module] ?? ["Module fingerprint is unresolved"]
            records[module] = .init(name: module, status: .unresolved,
                failure: (unresolved[module] ?? ["Module fingerprint is unresolved"]).joined(separator: "; "))
        }
        var report = CLI.CatalogPrewarmReport(jobDigest: jobDigest,
            startedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000), workBudget: workBudget, modules: [])
        func saveReport() throws {
            report.modules = records.values.sorted { $0.name < $1.name }
            let bytes = try Core.CanonicalJSON.encode(report)
            guard bytes.count <= 64 * 1_024 * 1_024 else { throw CLI.Error.input("Catalog prewarm report exceeds 64 MiB") }
            try publishPrivateCatalogJob(bytes, to: reportURL, replacing: true)
        }
        func accept(_ request: NativeAPICatalog.BuildRequest, _ output: NativeAPICatalog.BuildOutput,
                    duration: UInt64, referenced: inout Set<String>) {
            records[request.identity.moduleName] = .init(name: request.identity.moduleName, output: output, duration: duration)
            referenced.formUnion(output.snapshot.referencedModules)
        }
        var processedModules = Set<String>()
        var requestedModules = Set(try NativeAPICatalog.Planner.catalogModules(
            job.planRequest.importedModules,
            excluding: job.planRequest.metadata.frontendInvocation.moduleName))
        // Revalidate all current roots: a previously warm artifact may have
        // been evicted after the immutable job was created.
        var pending = initialPlan.requests
        var attemptedMisses = 0
        var generatedCount = 0
        while !pending.isEmpty {
            try Task.checkCancellation()
            pending.sort {
                let left = previouslyFailed.contains($0.identity.moduleName)
                let right = previouslyFailed.contains($1.identity.moduleName)
                return left == right ? $0.identity.moduleName < $1.identity.moduleName : !left
            }
            for request in pending { records[request.identity.moduleName] = .init(name: request.identity.moduleName, status: .pending) }
            try saveReport()
            var referencedModules = Set<String>()
            for start in stride(from: 0, to: pending.count, by: workBudget.moduleWorkers) {
                try Task.checkCancellation()
                let wave = Array(pending[start..<min(start + workBudget.moduleWorkers, pending.count)])
                var cold: [NativeAPICatalog.BuildRequest] = []
                var readDurations: [String: UInt64] = [:]
                // Reserve cold attempts in canonical order so a small module
                // limit cannot select different work depending on thread timing.
                for request in wave {
                    let module = request.identity.moduleName
                    let began = DispatchTime.now().uptimeNanoseconds
                    do {
                        if let cached = try builder.cached(request) {
                            accept(request, cached, duration: (DispatchTime.now().uptimeNanoseconds - began) / 1_000,
                                referenced: &referencedModules)
                            processedModules.insert(module)
                        } else if attemptedMisses < maximumModules {
                            attemptedMisses += 1
                            cold.append(request)
                            readDurations[module] = (DispatchTime.now().uptimeNanoseconds - began) / 1_000
                        } else { report.paused = true }
                    } catch {
                        if error is CancellationError { throw error }
                        records[module] = .init(name: module, status: .failed,
                            duration: (DispatchTime.now().uptimeNanoseconds - began) / 1_000,
                            failure: "Cache read: \(error)")
                        processedModules.insert(module)
                    }
                }
                let waveBuilder = NativeAPICatalog.Builder(cache: cache,
                    maximumProbeWorkers: workBudget.probesPerModule(concurrentModules: max(1, cold.count)))
                let outcomes = CLI.CatalogPrewarmBatch.run(cold, build: waveBuilder.build)
                for (request, outcome) in zip(cold, outcomes) {
                    let module = request.identity.moduleName
                    let duration = outcome.durationMicroseconds + (readDurations[module] ?? 0)
                    if let output = outcome.output {
                        accept(request, output, duration: duration, referenced: &referencedModules)
                        if output.metrics.cacheSource != .hit { generatedCount += 1 }
                    } else {
                        records[module] = .init(name: module, status: .failed, duration: duration,
                            failure: "Catalog build: " + (outcome.failure ?? "worker produced no result"))
                    }
                    processedModules.insert(module)
                }
                try saveReport()
                if outcomes.contains(where: \.cancelled) { throw CancellationError() }
            }
            requestedModules = Set(try NativeAPICatalog.Planner.catalogModules(
                Array(requestedModules.union(referencedModules)),
                excluding: job.planRequest.metadata.frontendInvocation.moduleName))
            var followupRequest = job.planRequest
            followupRequest.importedModules = requestedModules.subtracting(processedModules).subtracting(unresolved.keys).sorted()
            let followup = try NativeAPICatalog.Planner().plan(followupRequest)
            for module in followup.unresolvedModules {
                let reasons = followup.unresolvedReasons[module] ?? ["Module fingerprint is unresolved"]
                unresolved[module] = reasons
                records[module] = .init(name: module, status: .unresolved, failure: reasons.joined(separator: "; "))
            }
            pending = followup.requests.filter { !processedModules.contains($0.identity.moduleName) }
            for request in pending { records[request.identity.moduleName] = .init(name: request.identity.moduleName, status: .pending) }
            if report.paused { break }
        }
        let failures = records.values.filter { $0.status == .failed || $0.status == .unresolved }.sorted { $0.name < $1.name }
        let completedCount = records.values.filter { $0.status == .cached || $0.status == .generated }.count
        report.complete = !report.paused && failures.isEmpty
        try saveReport()
        let details = report.modules.map {
            "\($0.name): \($0.status.rawValue), \($0.durationMicroseconds) us"
                + ($0.failure.map { "; \($0)" } ?? "")
        }.joined(separator: "\n") + "\nReport: \(reportURL.path)\n"
        if !report.complete {
            let summary = report.paused
                ? "Catalog prewarm paused: \(generatedCount) generated, \(completedCount - generatedCount) cached; \(attemptedMisses) cold attempts"
                : "Catalog prewarm incomplete: \(completedCount) completed, \(failures.count) failed or unresolved"
            return .init(exitCode: failures.isEmpty ? 0 : 1,
                standardOutput: options.hasFlag("json")
                    ? String(decoding: try Core.CanonicalJSON.encode(report), as: UTF8.self) + "\n"
                    : summary + "; rerun --job \(jobURL.path) to resume\n" + details)
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
            standardOutput: options.hasFlag("json")
                ? String(decoding: try Core.CanonicalJSON.encode(report), as: UTF8.self) + "\n"
                : "Prewarmed \(completedCount) Native API Catalog module(s)\n" + details
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
        to url: URL,
        replacing: Bool = false
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
        if replacing {
            var existing = Darwin.stat()
            if lstat(url.path, &existing) == 0 {
                _ = try readPrivateCatalogJob(url, maximumBytes: 64 * 1_024 * 1_024)
            } else if errno != ENOENT {
                throw CLI.Error.input("cannot inspect Catalog prewarm report at \(url.path)")
            }
            guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
                throw CLI.Error.input("cannot publish Catalog prewarm report at \(url.path)")
            }
            return
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

    private func readPrivateCatalogJob(_ url: URL, maximumBytes: Int = NativeAPICatalog.PrewarmJobCodec.maximumDocumentBytes) throws -> Data {
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
                <= maximumBytes
        else {
            throw CLI.Error.input(
                "Catalog prewarm job is not an owner-only bounded regular file"
            )
        }
        return try handle.readToEnd() ?? Data()
    }
}
