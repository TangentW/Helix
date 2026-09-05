import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt {
/// Private, exact-toolchain compiler intermediates. Each caller reparses them;
/// neither a checkpoint nor a compiler dump is a published Shell authority.
enum CompilerCheckpoints {
    enum Stage: String, Codable, CaseIterable {
        case typedAST = "typed_ast"
        case identitySIL = "identity_sil"
        case semanticSIL = "semantic_sil"
    }

    struct Identity: Codable {
        var compilerCaptureHash: Core.Digest
        var toolchain: ReleaseCompiler.ToolchainIdentity
        var compilerPath: String
        var compilerInputHash: Core.Digest
        var invocation: InterfaceArchive.FrontendInvocation
        var transformPipelineHash: Core.Digest
        var sources: [ShellBuildReceipt.Source]
        var physicalPaths: [String]
    }

    /// Constructed for one synchronous generation; the confirmation closure
    /// and parsed AST objects never cross tasks or survive that call.
    struct Context {
        var cache: BuildCache.Store
        var identity: Core.Digest
        var confirmInputs: () throws -> Void

        func retire() -> UInt64 {
            var count: UInt64 = 0
            for stage in Stage.allCases {
                guard let key = try? CompilerCheckpoints.key(identity: identity, stage: stage) else { continue }
                if cache.discard(namespace: .compilerCheckpoint, key: key) { count += 1 }
            }
            return count
        }
    }

    private struct Key: Codable {
        var identity: Core.Digest
        var stage: Stage
    }

    static let maximumBytes = 256 * 1_024 * 1_024

    static func read<Value>(
        _ stage: Stage,
        context: Context?,
        performance: BuildPerformance.Recorder,
        produce: () throws -> String,
        parse: (String) throws -> Value
    ) throws -> Value {
        guard let context else { return try parse(produce()) }
        let key = try key(identity: context.identity, stage: stage)
        var parsed: Value?
        var confirmedGeneration = false
        let value = try context.cache.value(
            namespace: .compilerCheckpoint, key: key, maximumBytes: maximumBytes,
            validate: { bytes in
                guard !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8) else {
                    throw FrontendReceipt.Error.frontendFailed("invalid \(stage.rawValue) checkpoint encoding")
                }
                parsed = try parse(text)
            },
            produce: {
                let text = try produce()
                try performance.measure("frontend_checkpoint.confirm_inputs") { try context.confirmInputs() }
                confirmedGeneration = true
                return Data(text.utf8)
            }
        )
        // Input drift is not corruption of an earlier valid entry. Confirm
        // hits outside Store validation so drift never quarantines that entry.
        if !confirmedGeneration {
            try performance.measure("frontend_checkpoint.confirm_inputs") { try context.confirmInputs() }
        }
        performance.incrementCounter("frontend_checkpoint.\(stage.rawValue)_\(value.source.rawValue)_count")
        guard let parsed else {
            throw FrontendReceipt.Error.frontendFailed("\(stage.rawValue) checkpoint was not parsed")
        }
        return parsed
    }

    private static func key(identity: Core.Digest, stage: Stage) throws -> Core.Digest {
        try BuildCache.key(domain: "HLX.BuildCache.CompilerCheckpoint.v1", value: Key(identity: identity, stage: stage))
    }
}
}
