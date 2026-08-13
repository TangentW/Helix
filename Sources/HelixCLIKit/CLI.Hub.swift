import Foundation
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

#if os(macOS) && canImport(Network) && canImport(Security)
extension CLI.Application {
    /// Headless frontend for the same persistent service owned by Helix Hub.
    func runHubService(
        _ arguments: [String],
        outputHandler: @escaping @Sendable (CLI.Output) -> Void
    ) async throws -> CLI.Result {
        if arguments == ["--help"] {
            return .init(exitCode: 0, standardOutput: Self.hubRunHelp)
        }
        guard arguments.isEmpty else {
            throw CLI.Error.usage("hub run accepts no arguments")
        }

        let toolExecutableURL = Bundle.main.executableURL ?? URL(
            fileURLWithPath: CommandLine.arguments[0],
            relativeTo: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        ).absoluteURL
        let service = try DevSession.Service.persistent(
            toolExecutableURL: toolExecutableURL
        ) { event in
            if let output = Self.describe(event) {
                outputHandler(output)
            }
        }
        do {
            let endpoint = try await service.start()
            outputHandler(
                .standardOutput(
                    "Helix is running on port \(endpoint.port) and advertising "
                        + "_helix._tcp.\n"
                )
            )
            await withTaskCancellationHandler {
                await service.waitUntilStopped()
            } onCancel: {
                Task { await service.stop() }
            }
            return .init(exitCode: 0)
        } catch {
            await service.stop()
            throw error
        }
    }

    private static func describe(_ event: DevSession.ServiceEvent) -> CLI.Output? {
        switch event {
        case .listening, .localControlRequest:
            nil
        case .pairingStarted:
            .standardOutput("Authenticating a Helix App connection...\n")
        case let .paired(shellID, peerID):
            .standardOutput(
                "Paired Shell \(shellID.rawValue.uuidString) with App "
                    + "\(peerID.rawValue.uuidString).\n"
            )
        case let .pairingRejected(rejection):
            .standardError("Rejected App pairing: \(rejection.detail)\n")
        case let .contextRegistered(context):
            .standardOutput(
                "Registered \(context.scheme) Shell "
                    + "\(context.shellIdentity.shellID.rawValue.uuidString).\n"
            )
        case let .contextRemoved(shellID):
            .standardOutput(
                "Removed Shell \(shellID.rawValue.uuidString).\n"
            )
        case let .session(event):
            describe(event)
        case .stopped:
            .standardOutput("Helix stopped.\n")
        }
    }

    private static func describe(_ event: DevSession.HostEvent) -> CLI.Output? {
        switch event {
        case .authenticating:
            .standardOutput("Authenticating the paired App session...\n")
        case let .connected(_, identity):
            .standardOutput(
                "Connected process \(identity.processID) on "
                    + "\(identity.platform.rawValue)/\(identity.architecture).\n"
            )
        case let .pipeline(_, event):
            describe(event)
        case let .result(_, result):
            describe(result)
        case .disconnected:
            .standardError("App disconnected; its Build Context remains available.\n")
        case let .connectionRejected(_, reason):
            .standardError("Rejected App session: \(reason)\n")
        }
    }

    private static func describe(_ event: DevSession.PipelineEvent) -> CLI.Output? {
        switch event {
        case let .snapshotting(revision, paths):
            .standardOutput(
                "\(revision): captured \(paths.count) changed source file(s).\n"
            )
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
            nil
        }
    }

    static func describe(_ result: DevSession.PipelineResult) -> CLI.Output {
        switch result {
        case let .activation(activation):
            let summary = "\(activation.sourceRevision)/\(activation.generationID): "
                + "\(activation.codeStatus.rawValue), UI "
                + "\(activation.reloadStatus.rawValue).\n"
            guard let diagnostic = activation.diagnostic else {
                return .standardOutput(summary)
            }
            return .standardError(summary + diagnostic.description + "\n")
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
