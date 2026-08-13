import Foundation
import HelixCore
import HelixDevProtocol
import HelixInterface
import HelixLiveReloadAPI

extension DevSession {
public struct ProductInput: Hashable, Sendable {
    public var kind: String
    public var url: URL

    public init(kind: String, url: URL) {
        self.kind = kind
        self.url = url
    }
}

public struct PrepareRequest: Sendable {
    public var activityLogURL: URL?
    public var capturedFrontendJobs: [BuildCapture.CapturedFrontendJob]?
    public var workingDirectory: URL
    public var workspaceURL: URL
    public var scheme: String
    public var configuration: String
    public var bundleID: String
    public var moduleName: String
    public var executableURL: URL
    public var reloadIndexURL: URL
    public var interfaceArchiveURL: URL
    public var compilerURL: URL?
    /// Logical source to the file developers edit and the watcher observes.
    public var sourceMappings: [String: URL]
    /// Logical source to the materialized file Xcode actually compiled. Leave
    /// empty when Xcode compiled the editable source directly.
    public var compiledSourceMappings: [String: URL]
    public var linkArguments: [String]
    public var buildProducts: [DevSession.ProductInput]
    public var expandedCodeSignIdentity: String?
    public var teamIdentifier: String?
    public var entitlementsURL: URL?
    public var sessionBuildID: UUID

    public init(
        activityLogURL: URL? = nil,
        capturedFrontendJobs: [BuildCapture.CapturedFrontendJob]? = nil,
        workingDirectory: URL,
        workspaceURL: URL,
        scheme: String,
        configuration: String,
        bundleID: String,
        moduleName: String,
        executableURL: URL,
        reloadIndexURL: URL,
        interfaceArchiveURL: URL,
        compilerURL: URL? = nil,
        sourceMappings: [String: URL] = [:],
        compiledSourceMappings: [String: URL] = [:],
        linkArguments: [String] = [],
        buildProducts: [DevSession.ProductInput] = [],
        expandedCodeSignIdentity: String? = nil,
        teamIdentifier: String? = nil,
        entitlementsURL: URL? = nil,
        sessionBuildID: UUID = UUID()
    ) {
        self.activityLogURL = activityLogURL
        self.capturedFrontendJobs = capturedFrontendJobs
        self.workingDirectory = workingDirectory
        self.workspaceURL = workspaceURL
        self.scheme = scheme
        self.configuration = configuration
        self.bundleID = bundleID
        self.moduleName = moduleName
        self.executableURL = executableURL
        self.reloadIndexURL = reloadIndexURL
        self.interfaceArchiveURL = interfaceArchiveURL
        self.compilerURL = compilerURL
        self.sourceMappings = sourceMappings
        self.compiledSourceMappings = compiledSourceMappings
        self.linkArguments = linkArguments
        self.buildProducts = buildProducts
        self.expandedCodeSignIdentity = expandedCodeSignIdentity
        self.teamIdentifier = teamIdentifier
        self.entitlementsURL = entitlementsURL
        self.sessionBuildID = sessionBuildID
    }
}

public struct PrepareResult: Sendable {
    public var manifest: DevBuildManifest.Document
    public var reloadIndex: ReloadIndex.Document
    public var archive: InterfaceArchive.Archive
    public var compilerURL: URL
    public var selectedJob: BuildCapture.NormalizedFrontendJob
    public var probe: BuildCapture.ProbeResult
}

public struct Preparer<Probe: BuildCapture.Probing>: Sendable {
    public var probe: Probe

    public init(probe: Probe) {
        self.probe = probe
    }

    public func prepare(_ request: DevSession.PrepareRequest) throws -> DevSession.PrepareResult {
        try validateRequest(request)
        let archive = try InterfaceArchive.Codec.decode(
            readRegularFile(request.interfaceArchiveURL, maximumBytes: 64 * 1_024 * 1_024)
        ).archive
        let index: ReloadIndex.Document = try decodeJSON(
            request.reloadIndexURL,
            maximumBytes: 32 * 1_024 * 1_024
        )
        try archive.validate()
        try index.validate()

        let jobs = try captureJobs(request)
        let compiledSourceURLs = try resolveSourceURLs(
            archive: archive,
            jobs: jobs,
            explicitMappings: request.compiledSourceMappings.isEmpty
                ? request.sourceMappings : request.compiledSourceMappings,
            workspaceURL: request.workspaceURL
        )
        let sourceURLs = try resolveEditableSourceURLs(
            request: request,
            archive: archive,
            compiledSourceURLs: compiledSourceURLs
        )
        let selectedJob = try selectJob(jobs, sourceURLs: compiledSourceURLs)
        let target = try TargetIdentity.parse(selectedJob.targetTriple)
        let compilerURL = try resolveCompiler(
            requested: request.compilerURL,
            capturedExecutable: selectedJob.executable
        )
        let executable = try inspectExecutable(
            request.executableURL,
            expectedTarget: target
        )
        let probeResult = try probe.probe(
            .init(
                job: selectedJob,
                compilerURL: compilerURL,
                workingDirectory: request.workingDirectory,
                platform: target.platform
            )
        )
        guard probeResult.replayArtifactCount > 0 else {
            throw DevSession.PrepareError.identityMismatch(
                "frontend replay produced no identity-bearing artifact"
            )
        }
        try validateFrozenIdentity(
            request: request,
            archive: archive,
            index: index,
            job: selectedJob,
            target: target,
            executableUUID: executable.uuid,
            probe: probeResult
        )

        let sources = try makeSources(
            archive: archive,
            sourceURLs: sourceURLs,
            compiledSourceURLs: compiledSourceURLs
        )
        try validateReloadIndex(index, archive: archive, sources: sources)
        let products = try makeProducts(request)
        let entitlementsHash = try request.entitlementsURL.map {
            Core.Digest.sha256(try readRegularFile($0, maximumBytes: 4 * 1_024 * 1_024))
        }
        let dependencyGraphHash = dependencyHash(
            job: selectedJob,
            linkArguments: request.linkArguments,
            products: products,
            entitlementsHash: entitlementsHash
        )
        let manifest = DevBuildManifest.Document(
            sessionBuildID: request.sessionBuildID,
            workspacePathHash: .sha256(request.workspaceURL.standardizedFileURL.path),
            scheme: request.scheme,
            configuration: request.configuration,
            bundleID: request.bundleID,
            executableUUID: executable.uuid,
            moduleName: request.moduleName,
            targetTriple: selectedJob.targetTriple,
            architecture: target.architecture,
            platform: target.platform,
            minimumOS: target.minimumOS,
            xcodeBuild: probeResult.xcodeBuild,
            swiftCompilerFingerprint: probeResult.swiftCompilerFingerprint,
            sdkBuild: probeResult.sdkBuild,
            frontendArguments: selectedJob.arguments,
            linkArguments: request.linkArguments,
            moduleSearchPaths: selectedJob.moduleSearchPaths,
            sourceFiles: sources,
            buildProducts: products,
            expandedCodeSignIdentity: normalizedOptional(request.expandedCodeSignIdentity),
            teamIdentifier: normalizedOptional(request.teamIdentifier),
            entitlementsHash: entitlementsHash,
            liveReloadIndexHash: try index.contentHash(),
            dependencyGraphHash: dependencyGraphHash,
            toolchainCapabilities: probeResult.toolchainCapabilities
        )
        try manifest.validate()
        return .init(
            manifest: manifest,
            reloadIndex: index,
            archive: archive,
            compilerURL: compilerURL,
            selectedJob: selectedJob,
            probe: probeResult
        )
    }

    private func validateRequest(_ request: DevSession.PrepareRequest) throws {
        let values = [
            request.scheme, request.configuration, request.bundleID, request.moduleName,
        ]
        guard values.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.count <= 1_024
                && !$0.unicodeScalars.contains(where: { $0.value == 0 })
        }), (request.activityLogURL?.isFileURL == true
            || !(request.capturedFrontendJobs?.isEmpty ?? true)),
            request.workingDirectory.isFileURL,
            request.workspaceURL.isFileURL,
            request.executableURL.isFileURL,
            request.reloadIndexURL.isFileURL,
            request.interfaceArchiveURL.isFileURL,
            request.linkArguments.count <= 65_536,
            request.linkArguments.reduce(0, { $0 + $1.utf8.count }) <= 8 * 1_024 * 1_024,
            !request.linkArguments.contains(where: containsNull),
            request.sessionBuildID.uuidString != "00000000-0000-0000-0000-000000000000"
        else {
            throw DevSession.PrepareError.invalidRequest
        }
    }

    private func captureJobs(
        _ request: DevSession.PrepareRequest
    ) throws -> [BuildCapture.NormalizedFrontendJob] {
        let captured: [BuildCapture.CapturedFrontendJob]
        if let direct = request.capturedFrontendJobs {
            guard !direct.isEmpty,
                  direct.count <= 1_024,
                  direct.reduce(0, { partial, job in
                      partial + job.executable.utf8.count
                          + job.arguments.reduce(0, { $0 + $1.utf8.count })
                  }) <= 16 * 1_024 * 1_024
            else {
                throw DevSession.PrepareError.invalidRequest
            }
            captured = direct
        } else {
            guard let activityLogURL = request.activityLogURL else {
                throw DevSession.PrepareError.invalidRequest
            }
            captured = try BuildCapture.XcodeActivityReader()
                .readFrontendJobs(fromActivityLog: activityLogURL)
        }
        var matches: [BuildCapture.NormalizedFrontendJob] = []
        var firstFailure: Swift.Error?
        for job in captured {
            do {
                let normalized = try BuildCapture.FrontendJobNormalizer().normalize(
                    job,
                    workingDirectory: request.workingDirectory
                )
                if normalized.moduleName == request.moduleName {
                    matches.append(try absoluteExecutable(normalized, request: request))
                }
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        guard !matches.isEmpty else {
            if let firstFailure { throw firstFailure }
            throw DevSession.PrepareError.noMatchingFrontendJob(request.moduleName)
        }
        return matches
    }

    private func absoluteExecutable(
        _ job: BuildCapture.NormalizedFrontendJob,
        request: DevSession.PrepareRequest
    ) throws -> BuildCapture.NormalizedFrontendJob {
        var job = job
        if job.executable.hasPrefix("/") {
            job.executable = URL(fileURLWithPath: job.executable).standardizedFileURL.path
            return job
        }
        if URL(fileURLWithPath: job.executable).lastPathComponent == "swiftc",
           let compiler = request.compilerURL {
            job.executable = compiler.standardizedFileURL.path
            return job
        }
        throw DevSession.PrepareError.identityMismatch(
            "activity log contains a relative compiler path that cannot be resolved exactly"
        )
    }

    private func resolveSourceURLs(
        archive: InterfaceArchive.Archive,
        jobs: [BuildCapture.NormalizedFrontendJob],
        explicitMappings: [String: URL],
        workspaceURL: URL
    ) throws -> [String: URL] {
        let logicalPaths = Set(archive.sources.map(\.logicalPath))
        guard explicitMappings.isEmpty || Set(explicitMappings.keys) == logicalPaths else {
            throw DevSession.PrepareError.sourceSetMismatch(
                "explicit source mappings must exactly cover HLXI sources"
            )
        }
        let capturedPaths = Set(jobs.flatMap(\.sourcePaths)).map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let workspaceRoot = sourceRoot(for: workspaceURL)
        var result: [String: URL] = [:]
        for logicalPath in logicalPaths.sorted() {
            if let explicit = explicitMappings[logicalPath] {
                let normalized = explicit.standardizedFileURL
                guard capturedPaths.contains(normalized) else {
                    throw DevSession.PrepareError.sourceSetMismatch(
                        "mapped source is absent from the captured job: \(logicalPath)"
                    )
                }
                result[logicalPath] = normalized
                continue
            }
            let workspaceCandidate = workspaceRoot.appendingPathComponent(logicalPath).standardizedFileURL
            let exactWorkspaceMatch = capturedPaths.filter { $0 == workspaceCandidate }
            let suffixMatches = capturedPaths.filter {
                $0.path.hasSuffix("/\(logicalPath)")
            }
            let candidates = Set(exactWorkspaceMatch + suffixMatches)
            guard candidates.count == 1, let source = candidates.first else {
                throw DevSession.PrepareError.ambiguousSource(logicalPath)
            }
            result[logicalPath] = source
        }
        guard Set(result.values).count == result.count else {
            throw DevSession.PrepareError.sourceSetMismatch(
                "two HLXI logical sources map to one physical file"
            )
        }
        return result
    }

    private func sourceRoot(for workspaceURL: URL) -> URL {
        switch workspaceURL.pathExtension.lowercased() {
        case "xcworkspace", "xcodeproj":
            // Xcode containers are bundles beside the repository sources, not
            // the directory against which logical source paths are resolved.
            return workspaceURL.deletingLastPathComponent().standardizedFileURL
        default:
            return workspaceURL.standardizedFileURL
        }
    }

    private func resolveEditableSourceURLs(
        request: DevSession.PrepareRequest,
        archive: InterfaceArchive.Archive,
        compiledSourceURLs: [String: URL]
    ) throws -> [String: URL] {
        guard !request.compiledSourceMappings.isEmpty else {
            return compiledSourceURLs
        }
        let logicalPaths = Set(archive.sources.map(\.logicalPath))
        guard Set(request.compiledSourceMappings.keys) == logicalPaths,
              Set(request.sourceMappings.keys) == logicalPaths
        else {
            throw DevSession.PrepareError.sourceSetMismatch(
                "compiled and editable mappings must exactly cover HLXI sources"
            )
        }
        let editable = request.sourceMappings.mapValues(\.standardizedFileURL)
        guard Set(editable.values).count == editable.count else {
            throw DevSession.PrepareError.sourceSetMismatch(
                "two HLXI logical sources map to one editable file"
            )
        }
        for (logicalPath, url) in editable {
            guard url.isFileURL,
                  url.path.hasPrefix("/"),
                  url.pathExtension == "swift",
                  let attributes = try? FileManager.default.attributesOfItem(
                      atPath: url.path
                  ),
                  (attributes[.type] as? FileAttributeType) == .typeRegular
            else {
                throw DevSession.PrepareError.invalidFilesystemEntry(url.path)
            }
            guard compiledSourceURLs[logicalPath] != nil else {
                throw DevSession.PrepareError.sourceSetMismatch(logicalPath)
            }
        }
        return editable
    }

    private func selectJob(
        _ jobs: [BuildCapture.NormalizedFrontendJob],
        sourceURLs: [String: URL]
    ) throws -> BuildCapture.NormalizedFrontendJob {
        let expectedSources = Set(sourceURLs.values.map(\.path))
        let matchingSources = jobs.filter { Set($0.sourcePaths) == expectedSources }
        guard !matchingSources.isEmpty else {
            throw DevSession.PrepareError.sourceSetMismatch(
                "no captured frontend job exactly covers the HLXI source set"
            )
        }

        // EMIT_FRONTEND_COMMAND_LINES prints both the Swift Driver invocation and
        // the frontend jobs it expands into. They are different phases of the
        // same build, so comparing their complete flag sets reports a false
        // configuration conflict. Prefer the whole-module Driver command because
        // it preserves Xcode's source membership and file-list context; fall back
        // to per-primary frontend compilation when a log contains no Driver line.
        let preferredPhase = matchingSources.map(replayPhase).min() ?? 3
        let candidates = matchingSources.filter { replayPhase($0) == preferredPhase }
        let environmentIdentities = Set(candidates.map {
            [$0.executable, $0.moduleName, $0.targetTriple, $0.sdkPath]
        })
        let semanticIdentities = Set(candidates.map { semanticArguments($0.arguments) })
        guard environmentIdentities.count == 1, semanticIdentities.count == 1 else {
            throw DevSession.PrepareError.inconsistentFrontendJobs
        }
        return candidates.sorted {
            let lhs = $0.primaryFilePaths.joined(separator: "\u{0}")
            let rhs = $1.primaryFilePaths.joined(separator: "\u{0}")
            if lhs != rhs { return lhs < rhs }
            return $0.arguments.lexicographicallyPrecedes($1.arguments)
        }[0]
    }

    private func replayPhase(_ job: BuildCapture.NormalizedFrontendJob) -> Int {
        let arguments = job.arguments
        let performsCompilation = arguments.contains("-c")
            || arguments.contains("-emit-object")
        if performsCompilation {
            let executable = URL(fileURLWithPath: job.executable).lastPathComponent
            let isExpandedFrontend = executable == "swift-frontend"
                || arguments.contains("-frontend")
            return isExpandedFrontend ? 1 : 0
        }
        if arguments.contains("-emit-module") { return 2 }
        return 3
    }

    private func semanticArguments(_ arguments: [String]) -> [String] {
        let replaceablePairs: Set<String> = [
            "-primary-file", "-o", "-emit-module-path", "-emit-module-doc-path",
            "-emit-module-source-info-path", "-emit-dependencies-path",
            "-emit-reference-dependencies-path", "-serialize-diagnostics-path",
            "-emit-objc-header-path", "-emit-tbd-path", "-emit-api-descriptor-path",
            "-emit-const-values-path", "-emit-abi-descriptor-path",
            "-emit-loaded-module-trace-path", "-index-unit-output-path",
            "-save-optimization-record-path", "-emit-pcm-path", "-index-store-path",
            "-pch-output-dir", "-output-file-map", "-supplementary-output-file-map",
        ]
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if replaceablePairs.contains(argument), index + 1 < arguments.count {
                index += 2
            } else if argument.hasSuffix(".swift"), !argument.hasPrefix("-") {
                index += 1
            } else {
                result.append(argument)
                index += 1
            }
        }
        return result
    }

    private func resolveCompiler(
        requested: URL?,
        capturedExecutable: String
    ) throws -> URL {
        let captured = URL(fileURLWithPath: capturedExecutable).standardizedFileURL
        let derived: URL
        switch captured.lastPathComponent {
        case "swift-frontend":
            derived = captured.deletingLastPathComponent().appendingPathComponent("swiftc")
        case "swiftc", "swift-driver":
            derived = captured
        default:
            throw DevSession.PrepareError.identityMismatch(
                "captured Swift executable has an unsupported name"
            )
        }
        let selected = (requested ?? derived).standardizedFileURL
        if requested != nil {
            guard selected.deletingLastPathComponent() == derived.deletingLastPathComponent() else {
                throw DevSession.PrepareError.identityMismatch(
                    "requested swiftc is outside the captured frontend toolchain"
                )
            }
        }
        guard FileManager.default.isExecutableFile(atPath: selected.path) else {
            throw DevSession.PrepareError.identityMismatch(
                "captured toolchain has no executable swiftc at \(selected.path)"
            )
        }
        return selected
    }

    private func inspectExecutable(
        _ url: URL,
        expectedTarget: TargetIdentity
    ) throws -> (uuid: UUID, descriptor: MachO.Descriptor) {
        let data = try readRegularFile(url, maximumBytes: 1_024 * 1_024 * 1_024)
        let descriptor = try MachO.Inspector().inspect(data)
        let architectureMatches = descriptor.architecture.rawValue == expectedTarget.machOArchitecture
        let platformMatches: Bool
        switch (expectedTarget.platform, descriptor.platform) {
        case (.iOS, .iOS), (.iOSSimulator, .iOSSimulator), (.macOS, .macOS):
            platformMatches = true
        default:
            platformMatches = false
        }
        guard architectureMatches, platformMatches, let uuid = descriptor.uuid else {
            throw DevSession.PrepareError.identityMismatch(
                "App executable UUID, architecture, or platform is missing or incompatible"
            )
        }
        return (uuid, descriptor)
    }

    private func validateFrozenIdentity(
        request: DevSession.PrepareRequest,
        archive: InterfaceArchive.Archive,
        index: ReloadIndex.Document,
        job: BuildCapture.NormalizedFrontendJob,
        target: TargetIdentity,
        executableUUID: UUID,
        probe: BuildCapture.ProbeResult
    ) throws {
        let functionModules = Set(archive.functions.map(\.moduleName))
        var mismatches: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ field: String) {
            if !condition() { mismatches.append(field) }
        }
        check(archive.metadata.bundleID == request.bundleID, "bundleID")
        check(archive.metadata.machOUUIDs.contains(executableUUID), "executableUUID")
        check(archive.metadata.targetTriple == job.targetTriple, "targetTriple")
        check(archive.metadata.minimumOS == target.minimumOS, "minimumOS")
        check(archive.metadata.xcodeBuild == probe.xcodeBuild, "xcodeBuild")
        check(archive.metadata.sdkBuild == probe.sdkBuild, "sdkBuild")
        check(
            archive.metadata.frontendInvocation.moduleName == request.moduleName,
            "frontendInvocation.moduleName"
        )
        check(
            archive.metadata.frontendInvocation.targetTriple == job.targetTriple,
            "frontendInvocation.targetTriple"
        )
        check(
            archive.metadata.frontendInvocation.sdkBuild == probe.sdkBuild,
            "frontendInvocation.sdkBuild"
        )
        check(
            archive.metadata.frontendInvocation.optimization == "-Onone",
            "frontendInvocation.optimization"
        )
        check(
            archive.compatibility.compilerFingerprint == probe.swiftCompilerFingerprint,
            "swiftCompilerFingerprint"
        )
        check(functionModules == [request.moduleName], "functionModules")
        check(
            Set(index.roots.map(\.functionKey))
                .isSubset(of: Set(archive.functions.map(\.key))),
            "reloadIndex.functionKeys"
        )
        guard mismatches.isEmpty else {
            throw DevSession.PrepareError.identityMismatch(
                "frozen fields differ: \(mismatches.joined(separator: ", "))"
            )
        }
    }

    private func makeSources(
        archive: InterfaceArchive.Archive,
        sourceURLs: [String: URL],
        compiledSourceURLs: [String: URL]
    ) throws -> [DevBuildManifest.SourceFile] {
        try archive.sources.sorted(by: { $0.logicalPath < $1.logicalPath }).map { source in
            guard let url = sourceURLs[source.logicalPath],
                  let compiledURL = compiledSourceURLs[source.logicalPath]
            else {
                throw DevSession.PrepareError.sourceSetMismatch(source.logicalPath)
            }
            let data = try readRegularFile(url, maximumBytes: 64 * 1_024 * 1_024)
            let digest = Core.Digest.sha256(data)
            guard digest == source.contentHash else {
                throw DevSession.PrepareError.sourceBaselineMismatch(source.logicalPath)
            }
            return .init(
                id: LiveReload.SourceFileID.derive(logicalPath: source.logicalPath),
                logicalPath: source.logicalPath,
                absolutePath: url.path,
                contentHash: digest,
                privateImportSourceFile: compiledURL.lastPathComponent
            )
        }
    }

    private func validateReloadIndex(
        _ index: ReloadIndex.Document,
        archive: InterfaceArchive.Archive,
        sources: [DevBuildManifest.SourceFile]
    ) throws {
        let sourceIDs = Set(sources.map(\.id))
        let functionKeys = Set(archive.functions.map(\.key))
        guard Set(index.sourceRoots.map(\.sourceFileID)).isSubset(of: sourceIDs),
              Set(index.roots.map(\.functionKey)).isSubset(of: functionKeys),
              index.nativeReplacements.allSatisfy({
                  sourceIDs.contains($0.sourceFileID) && functionKeys.contains($0.functionKey)
              })
        else {
            throw DevSession.PrepareError.identityMismatch(
                "Reload Index contains a source or function outside the frozen HLXI"
            )
        }
    }

    private func makeProducts(
        _ request: DevSession.PrepareRequest
    ) throws -> [DevBuildManifest.Product] {
        let inputs = [DevSession.ProductInput(kind: "executable", url: request.executableURL)]
            + request.buildProducts
        guard inputs.allSatisfy({
            !$0.kind.isEmpty && $0.kind.utf8.count <= 256 && !$0.kind.contains("\u{0}")
        }), Set(inputs.map { $0.url.standardizedFileURL.path }).count == inputs.count else {
            throw DevSession.PrepareError.invalidRequest
        }
        return try inputs.map { input in
            let url = input.url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw DevSession.PrepareError.invalidFilesystemEntry(url.path)
            }
            let hash = isDirectory.boolValue
                ? nil
                : Core.Digest.sha256(
                    try readRegularFile(url, maximumBytes: 1_024 * 1_024 * 1_024)
                )
            return .init(kind: input.kind, path: url.path, contentHash: hash)
        }.sorted {
            ($0.kind, $0.path) < ($1.kind, $1.path)
        }
    }

    private func dependencyHash(
        job: BuildCapture.NormalizedFrontendJob,
        linkArguments: [String],
        products: [DevBuildManifest.Product],
        entitlementsHash: Core.Digest?
    ) -> Core.Digest {
        var hasher = Core.StableHasher(domain: "HLX.DevDependencyGraph.v1")
        for argument in semanticArguments(job.arguments) { hasher.append(argument) }
        for path in job.moduleSearchPaths.sorted() { hasher.append(path) }
        for argument in linkArguments { hasher.append(argument) }
        for product in products {
            hasher.append(product.kind)
            hasher.append(product.path)
            if let hash = product.contentHash { hasher.append(hash) }
        }
        if let entitlementsHash { hasher.append(entitlementsHash) }
        return hasher.finalize()
    }

    private func decodeJSON<Value: Decodable>(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(
                Value.self,
                from: readRegularFile(url, maximumBytes: maximumBytes)
            )
        } catch let error as DevSession.PrepareError {
            throw error
        } catch {
            throw DevSession.PrepareError.invalidDocument(String(describing: error))
        }
    }

    private func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size <= UInt64(maximumBytes)
        else {
            throw DevSession.PrepareError.invalidFilesystemEntry(url.path)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty
        else { return nil }
        return result
    }

    private func containsNull(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0 }
    }
}

private struct TargetIdentity: Sendable {
    var architecture: String
    var machOArchitecture: String
    var platform: DevProtocol.ApplePlatform
    var minimumOS: Core.SemanticVersion

    static func parse(_ triple: String) throws -> Self {
        let architecture = String(triple.split(separator: "-", maxSplits: 1).first ?? "")
        let machOArchitecture: String
        switch architecture {
        case "arm64", "arm64e": machOArchitecture = "arm64"
        case "x86_64": machOArchitecture = "x86_64"
        default:
            throw DevSession.PrepareError.identityMismatch(
                "unsupported target architecture \(architecture)"
            )
        }
        let lowercased = triple.lowercased()
        let platform: DevProtocol.ApplePlatform
        let marker: String
        if lowercased.contains("-apple-ios") {
            platform = lowercased.contains("simulator") ? .iOSSimulator : .iOS
            marker = "-apple-ios"
        } else if lowercased.contains("-apple-macosx") {
            platform = .macOS
            marker = "-apple-macosx"
        } else if lowercased.contains("-apple-macos") {
            platform = .macOS
            marker = "-apple-macos"
        } else {
            throw DevSession.PrepareError.identityMismatch(
                "target triple is not an Apple iOS, Simulator, or macOS target"
            )
        }
        guard let markerRange = lowercased.range(of: marker) else {
            throw DevSession.PrepareError.identityMismatch("target triple has no OS version")
        }
        let suffix = lowercased[markerRange.upperBound...]
        let versionText = String(suffix.prefix { $0.isNumber || $0 == "." })
        let parts = versionText.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              let major = UInt16(parts[0]),
              let minor = parts.count > 1 ? UInt16(parts[1]) : 0,
              let patch = parts.count > 2 ? UInt16(parts[2]) : 0
        else {
            throw DevSession.PrepareError.identityMismatch(
                "target triple contains an invalid minimum OS version"
            )
        }
        return .init(
            architecture: architecture,
            machOArchitecture: machOArchitecture,
            platform: platform,
            minimumOS: .init(major, minor, patch)
        )
    }
}

public enum PrepareError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidRequest
    case noMatchingFrontendJob(String)
    case ambiguousSource(String)
    case sourceSetMismatch(String)
    case sourceBaselineMismatch(String)
    case inconsistentFrontendJobs
    case invalidFilesystemEntry(String)
    case invalidDocument(String)
    case identityMismatch(String)

    public var description: String {
        switch self {
        case .invalidRequest:
            "Dev prepare request is empty, oversized, unsafe, or internally inconsistent"
        case let .noMatchingFrontendJob(module):
            "Xcode activity contains no expanded Swift frontend job for module \(module)"
        case let .ambiguousSource(path):
            "HLXI source \(path) cannot be mapped uniquely to the captured frontend job"
        case let .sourceSetMismatch(reason):
            "captured frontend source set does not match HLXI: \(reason)"
        case let .sourceBaselineMismatch(path):
            "source \(path) differs from the HLXI build baseline"
        case .inconsistentFrontendJobs:
            "matching primary-file jobs disagree on a semantic frontend argument"
        case let .invalidFilesystemEntry(path):
            "Dev prepare input is missing, not a regular file, or too large: \(path)"
        case let .invalidDocument(reason):
            "Dev prepare input document is invalid: \(reason)"
        case let .identityMismatch(reason):
            "Dev prepare identity check failed: \(reason)"
        }
    }
}

public typealias DefaultPreparer = DevSession.Preparer<BuildCapture.DefaultFrontendReplayProbe>
}
