import Foundation
import HelixCore

extension FrontendReceipt {
public struct DiagnosticCheck: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case passed, failed, blocked }
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
    public var schemaVersion: UInt16 = 1
    public var passed: Bool
    public var checks: [DiagnosticCheck]
    public var diagnostics: [Core.Diagnostic]
    public var performance: BuildPerformance.Trace?

    public static func failure(stage: String, reason: String) -> Self {
        .init(passed: false, checks: [
            .init(stage: stage, status: .failed, detail: reason),
            .init(stage: "frontend.receipt", status: .blocked, detail: "Requires valid \(stage) inputs"),
        ], diagnostics: [], performance: nil)
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

    init(collectFailures: Bool, catalogFailure: String? = nil, performance: BuildPerformance.Recorder = .init()) {
        self.collectFailures = collectFailures
        self.catalogFailure = catalogFailure
        self.performance = performance
    }

    func run<T>(_ stage: String, dependencies: [String] = [], _ operation: () throws -> T) throws -> T? {
        guard statuses[stage] == nil else {
            throw FrontendReceipt.Error.invalidRequest("diagnostic stage repeats: \(stage)")
        }
        let blocked = dependencies.filter { statuses[$0] != .passed }
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
        if let error {
            if error is DiagnosticFailure {
                record("frontend.receipt", status: .blocked, detail: "Independent analysis checks failed; no receipt was published")
            } else {
                record("frontend.receipt", status: .failed, detail: String(describing: error))
            }
        } else if output != nil {
            record("frontend.receipt", status: .passed)
        }
        return .init(passed: output != nil && checks.allSatisfy { $0.status == .passed },
                     checks: checks, diagnostics: output?.diagnostics ?? [], performance: performance.trace())
    }
}
}

extension FrontendReceipt.Adapter {
    /// Evaluates independent branches and the complete receipt pipeline without
    /// publishing a receipt. A failed dependency explicitly blocks its consumers.
    public func diagnose(_ request: FrontendReceipt.Request) throws -> FrontendReceipt.DiagnosticReport {
        let session = FrontendReceipt.DiagnosticSession(collectFailures: true)
        do {
            let output = try generate(request, cache: nil, toolchain: nil, compilerInputHash: nil, diagnostics: session)
            return session.report(output: output)
        } catch {
            if error is CancellationError { throw error }
            return session.report(output: nil, error: error)
        }
    }
}
