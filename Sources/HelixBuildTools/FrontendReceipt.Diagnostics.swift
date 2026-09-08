import Foundation
import HelixCompiler
import HelixCore

extension FrontendReceipt {
public struct DiagnosticCheck: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case passed, failed, blocked, notRun = "not_run" }
    public var stage: String
    public var status: Status
    public var detail: String

    public init(stage: String, status: Status, detail: String = "") {
        self.stage = stage
        self.status = status
        self.detail = detail
    }
}

public struct DiagnosticReport: Codable, Sendable {
    // Schema 3 explicitly lists unexecuted checks with the not_run status.
    // Schema 2 distinguishes selected checks from full receipt validation.
    // Schema 1 decodes with a nil selection, preserving its full-scope meaning.
    public var schemaVersion: UInt16 = 3
    public var passed: Bool
    public var checks: [DiagnosticCheck]
    public var diagnostics: [Core.Diagnostic]
    public var performance: BuildPerformance.Trace?
    public var requestedStages: [DiagnosticStage]? = nil

    public static func failure(stage: String, reason: String) -> Self {
        failure(stage: stage, reason: reason, stages: nil)
    }

    public static func failure(stage: String, reason: String, stages: [DiagnosticStage]?) -> Self {
        let selection = stages.map { Array(Set($0)).sorted { $0.rawValue < $1.rawValue } }
        let roots = Set(selection?.flatMap(\.roots) ?? ["frontend.receipt"]).subtracting([stage]).sorted()
        return .init(passed: false, checks: [.init(stage: stage, status: .failed, detail: reason)]
            + roots.map { .init(stage: $0, status: .blocked, detail: "Requires valid \(stage) inputs") },
            diagnostics: [], performance: nil, requestedStages: selection)
    }
}

struct DiagnosticFailure: Swift.Error {
    var checks: [DiagnosticCheck]
}

/// One synchronous analysis owns this session. Failed outputs never enter the
/// dependency map, compiler checkpoints, or a published receipt.
final class DiagnosticSession {
    let collectFailures: Bool
    let catalogFailure: String?
    let performance: BuildPerformance.Recorder
    private(set) var checks: [DiagnosticCheck] = []
    private var statuses: [String: DiagnosticCheck.Status] = [:]
    var indexingDiagnostics: [Core.Diagnostic] = []
    let requestedStages: [DiagnosticStage]?
    private let requiredStages: Set<String>?

    init(collectFailures: Bool, catalogFailure: String? = nil, performance: BuildPerformance.Recorder = .init(),
         stages: [DiagnosticStage]? = nil) {
        self.collectFailures = collectFailures
        self.catalogFailure = catalogFailure
        self.performance = performance
        requestedStages = stages.map { Array(Set($0)).sorted { $0.rawValue < $1.rawValue } }
        requiredStages = stages.map(DiagnosticPlan.requiredStages)
    }

    func includes(_ stage: String) -> Bool { requiredStages?.contains(stage) ?? true }

    func run<T>(_ stage: String, dependencies: [String]? = nil, _ operation: () throws -> T) throws -> T? {
        guard includes(stage) else { return nil }
        guard statuses[stage] == nil else {
            throw FrontendReceipt.Error.invalidRequest("diagnostic stage repeats: \(stage)")
        }
        let blocked = (dependencies ?? DiagnosticPlan.dependencies[stage, default: []]).filter { statuses[$0] != .passed }
        guard blocked.isEmpty else {
            record(stage, status: .blocked, detail: "Requires successful checks: " + blocked.joined(separator: ", "))
            return nil
        }
        do {
            try Task.checkCancellation()
            let result = try performance.measure(stage, operation)
            record(stage, status: .passed)
            return result
        } catch {
            if error is CancellationError { throw error }
            guard collectFailures else { throw error }
            record(stage, status: .failed, detail: String(describing: error))
            return nil
        }
    }

    func record(_ stage: String, status: DiagnosticCheck.Status, detail: String = "") {
        statuses[stage] = status
        checks.append(.init(stage: stage, status: status, detail: detail))
    }

    func requireSuccess() throws {
        guard checks.allSatisfy({ $0.status == .passed }) else {
            throw DiagnosticFailure(checks: checks)
        }
    }

    func report(output: FrontendReceipt.Output?, error: Swift.Error? = nil) -> DiagnosticReport {
        let selectedComplete = error is DiagnosticSelectionComplete
        if let error, !selectedComplete {
            if error is DiagnosticFailure {
                if includes("frontend.receipt") {
                    record("frontend.receipt", status: .blocked, detail: "Independent analysis checks failed; no receipt was published")
                }
            } else {
                record(includes("frontend.receipt") ? "frontend.receipt" : "frontend.analysis", status: .failed, detail: String(describing: error))
            }
        } else if output != nil {
            record("frontend.receipt", status: .passed)
        }
        let passed = (output != nil || selectedComplete) && !checks.isEmpty && checks.allSatisfy { $0.status == .passed }
        if collectFailures {
            var known = Set(DiagnosticPlan.dependencies.keys)
            for prefix in ["frontend.identity_sil", "frontend.semantic_sil"] {
                known.formUnion(CanonicalSIL.Inspection.Component.allCases.map { prefix + "." + $0.rawValue })
            }
            for stage in known.sorted() where statuses[stage] == nil {
                let selected = includes(stage) || ["frontend.identity_sil", "frontend.semantic_sil"].contains {
                    includes($0) && stage.hasPrefix($0 + ".") && !stage.hasSuffix(".ast_mapping")
                }
                record(stage, status: .notRun, detail: selected
                    ? "Analysis stopped before this check; no result is available"
                    : "Not requested by the selected diagnostic stages")
            }
        }
        return .init(passed: passed,
                     checks: checks, diagnostics: output?.diagnostics ?? indexingDiagnostics, performance: performance.trace(), requestedStages: requestedStages)
    }
}
}

extension FrontendReceipt.Adapter {
    /// Evaluates independent branches and the complete receipt pipeline without
    /// publishing a receipt. A failed dependency explicitly blocks its consumers.
    public func diagnose(_ request: FrontendReceipt.Request) throws -> FrontendReceipt.DiagnosticReport {
        try diagnose(request, stages: nil)
    }

    public func diagnose(_ request: FrontendReceipt.Request, stages: [FrontendReceipt.DiagnosticStage]?) throws -> FrontendReceipt.DiagnosticReport {
        guard stages?.isEmpty != true else { throw FrontendReceipt.Error.invalidRequest("diagnostic stage selection is empty") }
        let session = FrontendReceipt.DiagnosticSession(collectFailures: true, stages: stages)
        do {
            let output = try generate(request, cache: nil, toolchain: nil, compilerInputHash: nil, diagnostics: session)
            return session.report(output: output)
        } catch {
            if error is CancellationError { throw error }
            return session.report(output: nil, error: error)
        }
    }
}
