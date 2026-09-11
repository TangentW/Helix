import Foundation

extension NativeAPICatalog {
/// A conservative execution budget, independent of Catalog content identity.
/// The memory estimate is a scheduling heuristic, not an RSS limit.
public struct WorkBudget: Codable, Hashable, Sendable {
    public let compilerWorkers: Int
    public let moduleWorkers: Int

    public init(processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
                physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                requestedModules: Int = 4) {
        let gibibytes = physicalMemory / (1_024 * 1_024 * 1_024)
        let memoryWorkers = max(1, Int(gibibytes > 4 ? (gibibytes - 4) / 2 : 1))
        compilerWorkers = max(1, min(8, processorCount, memoryWorkers))
        moduleWorkers = max(1, min(requestedModules, compilerWorkers))
    }

    public func probesPerModule(concurrentModules: Int) -> Int {
        max(1, compilerWorkers / max(1, concurrentModules))
    }
}
}
