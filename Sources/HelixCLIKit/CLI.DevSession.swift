import Foundation
import HelixCore
import HelixDevTools

extension CLI {
struct DevValidationReport: Codable, Hashable, Sendable {
    var schemaVersion: UInt16 = 1
    var sessionID: UUID
    var bundleID: String
    var platform: String
    var architecture: String
    var sourceCount: Int
    var reloadRootCount: Int
    var interfaceFunctionCount: Int
    var backendPreference: DevBackendSelection.Preference

    init(prepared: DevSession.PreparedConfiguration) {
        sessionID = prepared.manifest.sessionBuildID
        bundleID = prepared.manifest.bundleID
        platform = prepared.manifest.platform.rawValue
        architecture = prepared.manifest.architecture
        sourceCount = prepared.manifest.sourceFiles.count
        reloadRootCount = prepared.reloadIndex.roots.count
        interfaceFunctionCount = prepared.archive.functions.count
        backendPreference = prepared.resolved.document.backendPreference
    }
}
}

#if os(macOS)
extension CLI.Application {
    func runDevDaemon(
        _ arguments: [String],
        outputHandler: @escaping @Sendable (CLI.Output) -> Void
    ) async throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.devRunHelp)
        }
        let options = try CLI.Arguments(
            arguments,
            valueOptions: ["config", "bootstrap", "target", "lifecycle-lock"],
            flagOptions: []
        )
        guard options.positionals.isEmpty else {
            throw CLI.Error.usage("dev run accepts no positional arguments")
        }
        let bootstrapPath = try options.value("bootstrap")
        let targetValue = try options.value("target")
        let lifecycleLockPath = try options.value("lifecycle-lock")
        let machineValues = [bootstrapPath, targetValue, lifecycleLockPath]
        guard machineValues.allSatisfy({ $0 == nil })
                || machineValues.allSatisfy({ $0 != nil })
        else {
            throw CLI.Error.usage(
                "--bootstrap, --target, and --lifecycle-lock must be supplied together"
            )
        }
        let launchTarget: DevSession.LaunchTarget?
        if let targetValue {
            guard let target = DevSession.LaunchTarget(rawValue: targetValue) else {
                throw CLI.Error.usage("--target must be simulator or device")
            }
            launchTarget = target
        } else {
            launchTarget = nil
        }
        let configurationURL = files.resolve(try options.require("config"))
        let bootstrapURL = bootstrapPath.map(files.resolve)
        let lifecycleLockURL = lifecycleLockPath.map(files.resolve)
        let supervisedArtifacts: DevProcess.SupervisedArtifacts?
        if let bootstrapURL, let lifecycleLockURL {
            supervisedArtifacts = try DevProcess.SupervisedArtifacts(
                bootstrapURL: bootstrapURL,
                lifecycleLockURL: lifecycleLockURL
            )
        } else {
            supervisedArtifacts = nil
        }
        let lifetimeLock = try lifecycleLockURL.map {
            try DevProcess.LifetimeLock(url: $0)
        }
        defer { lifetimeLock?.unlock() }
        defer {
            if let supervisedArtifacts {
                do {
                    try supervisedArtifacts.cleanupPrivateHandoff()
                } catch {
                    outputHandler(
                        .standardError(
                            "error: cannot clean supervised Dev Session handoff: \(error)\n"
                        )
                    )
                }
            }
        }
        let daemon = try DevSession.Daemon(
            configurationURL: configurationURL,
            disconnectPolicy: supervisedArtifacts == nil
                ? .waitForReplacement
                : .stopAfterGracePeriod(nanoseconds: 5_000_000_000)
        ) { event in
            if let output = Self.describe(event) {
                outputHandler(output)
            }
        }
        let bootstrap = try await daemon.start()
        if let bootstrapURL, let launchTarget {
            guard let launchEnvironment = bootstrap.environment(for: launchTarget) else {
                await daemon.stop()
                throw CLI.Error.input(
                    "device launch requires a Bonjour-enabled Dev configuration"
                )
            }
            let document = DevProcess.BootstrapDocument(
                target: launchTarget,
                environment: launchEnvironment
            )
            let configuration = try Data(
                contentsOf: configurationURL,
                options: .mappedIfSafe
            )
            try lifetimeLock?.publish(
                owner: .init(
                    processID: ProcessInfo.processInfo.processIdentifier,
                    sessionID: bootstrap.sessionID,
                    configurationSHA256: .sha256(configuration),
                    executablePath: executableURL.resolvingSymlinksInPath().path
                )
            )
            try DevProcess.BootstrapCodec.write(document, to: bootstrapURL)
            outputHandler(
                .standardOutput(
                    "Helix Dev Session \(bootstrap.sessionID.uuidString) is listening "
                        + "on port \(bootstrap.port).\n"
                )
            )
        } else {
            outputHandler(.standardOutput(Self.describe(bootstrap)))
        }
        await withTaskCancellationHandler {
            await daemon.waitUntilStopped()
        } onCancel: {
            Task { await daemon.stop() }
        }
        return .init(exitCode: 0)
    }

    private static func describe(_ bootstrap: DevSession.Bootstrap) -> String {
        func lines(_ values: [String: String]) -> String {
            values.sorted { $0.key < $1.key }.map { "  \($0.key)=\($0.value)" }
                .joined(separator: "\n")
        }
        let simulator = bootstrap.environment(for: .simulator) ?? [:]
        let device: String
        if let environment = bootstrap.environment(for: .device) {
            device = "Device launch environment (Bonjour):\n" + lines(environment)
        } else {
            device = "Device launch environment: disabled because advertiseBonjour is false."
        }
        return """
        Helix Dev Session is listening on port \(bootstrap.port).
        Session: \(bootstrap.sessionID.uuidString)

        Simulator launch environment:
        \(lines(simulator))

        \(device)

        Treat HLX_DEV_SESSION_SECRET as an ephemeral credential; do not write it to source control.
        """ + "\n"
    }

    private static func describe(_ event: DevSession.DaemonEvent) -> CLI.Output? {
        switch event {
        case .listening:
            nil
        case .authenticating:
            .standardOutput("Authenticating an App connection...\n")
        case let .connected(identity):
            .standardOutput(
                "Connected process \(identity.processID) on "
                    + "\(identity.platform.rawValue)/\(identity.architecture).\n"
            )
        case let .pipeline(event):
            describe(event)
        case let .result(result):
            describe(result)
        case .disconnected:
            .standardError("App disconnected; waiting for a matching process.\n")
        case let .connectionRejected(reason):
            .standardError("Rejected App connection: \(reason)\n")
        case .stopped:
            .standardOutput("Helix Dev Session stopped.\n")
        }
    }

    private static func describe(_ event: DevSession.PipelineEvent) -> CLI.Output {
        switch event {
        case let .snapshotting(revision, paths):
            .standardOutput("\(revision): captured \(paths.count) changed source file(s).\n")
        case let .compiling(revision, generation):
            .standardOutput("\(revision)/\(generation): compiling Swift changes...\n")
        case let .transferring(offer):
            .standardOutput(
                "\(offer.sourceRevision)/\(offer.generationID): transferring "
                    + "\(offer.backend.rawValue) (\(offer.payloadByteLength) bytes).\n"
            )
        case let .debugSymbols(symbols):
            .standardOutput(
                "Native patch symbols match \(symbols.imageUUID.uuidString). "
                    + "Paste these commands into the Xcode LLDB console:\n"
                    + symbols.lldbCommands().map { "  \($0)" }.joined(separator: "\n")
                    + "\n"
            )
        case .completed:
            .standardOutput("")
        }
    }

    private static func describe(_ result: DevSession.PipelineResult) -> CLI.Output {
        switch result {
        case let .activation(activation):
            return .standardOutput(
                "\(activation.sourceRevision)/\(activation.generationID): "
                    + "\(activation.codeStatus.rawValue), UI \(activation.reloadStatus.rawValue).\n"
            )
        case let .noSemanticChange(revision):
            return .standardOutput("\(revision): no semantic function-body change.\n")
        case let .rebuildRequired(diagnostic):
            return .standardError("\(diagnostic.description)\n")
        case let .failed(diagnostic):
            return .standardError("\(diagnostic.description)\n")
        case let .superseded(revision):
            return .standardOutput("\(revision): superseded by a newer save.\n")
        }
    }
}
#endif
