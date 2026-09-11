import Foundation
import HelixBuildTools
import HelixCore

extension CLI {
public struct CatalogPrewarmReport: Codable, Sendable {
    public struct Module: Codable, Sendable {
        public enum Status: String, Codable, Sendable { case pending, cached, generated, failed, unresolved }
        public var name: String
        public var status: Status
        public var durationMicroseconds: UInt64 = 0
        public var candidateCount: UInt64? = nil
        public var entryCount: UInt64? = nil
        public var probeAttempts: UInt64? = nil
        public var probeCacheHits: UInt64? = nil
        public var probeCacheMisses: UInt64? = nil
        public var rejectionReasons: [String] = []
        public var failure: String? = nil

        init(name: String, output: NativeAPICatalog.BuildOutput, duration: UInt64) {
            self.name = name
            status = output.metrics.cacheSource == .hit ? .cached : .generated
            durationMicroseconds = duration
            candidateCount = output.metrics.candidateCount
            entryCount = output.metrics.entryCount
            probeAttempts = output.metrics.probeAttemptCount
            probeCacheHits = output.metrics.probeCacheHitCount
            probeCacheMisses = output.metrics.probeCacheMissCount
            rejectionReasons = output.metrics.rejectionReasons
        }

        init(name: String, status: Status, duration: UInt64 = 0, failure: String? = nil) {
            self.name = name
            self.status = status
            durationMicroseconds = duration
            self.failure = failure
        }
    }

    public var schemaVersion: UInt16 = 1
    public var jobDigest: Core.Digest
    public var startedAtMilliseconds: Int64
    public var workBudget: NativeAPICatalog.WorkBudget
    public var complete: Bool = false
    public var paused: Bool = false
    public var modules: [Module]
}

/// Each wave has at most the module budget. The locked result slots keep
/// completion order out of diagnostics and never share mutable compiler state.
enum CatalogPrewarmBatch {
    struct Outcome: Sendable {
        var output: NativeAPICatalog.BuildOutput?
        var failure: String?
        var cancelled: Bool
        var durationMicroseconds: UInt64
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Outcome?]
        init(count: Int) { values = Array(repeating: nil, count: count) }
        func put(_ value: Outcome, at index: Int) { lock.withLock { values[index] = value } }
        func joined() -> [Outcome] { lock.withLock { values.map { $0! } } }
    }

    static func run(_ requests: [NativeAPICatalog.BuildRequest],
                    build: @Sendable (NativeAPICatalog.BuildRequest) throws -> NativeAPICatalog.BuildOutput) -> [Outcome] {
        precondition(requests.count <= 8)
        let results = Results(count: requests.count)
        DispatchQueue.concurrentPerform(iterations: requests.count) { index in
            autoreleasepool {
                let started = DispatchTime.now().uptimeNanoseconds
                let outcome: Outcome
                do {
                    let output = try build(requests[index])
                    outcome = .init(output: output, failure: nil, cancelled: false,
                        durationMicroseconds: (DispatchTime.now().uptimeNanoseconds - started) / 1_000)
                } catch {
                    outcome = .init(output: nil, failure: String(describing: error), cancelled: error is CancellationError,
                        durationMicroseconds: (DispatchTime.now().uptimeNanoseconds - started) / 1_000)
                }
                results.put(outcome, at: index)
            }
        }
        return results.joined()
    }
}
}
