import Foundation
import HelixCompiler

/// Local build telemetry. It is never part of HLBC, HLXI, a signed patch, or
/// the release identity, so measured durations cannot make those artifacts
/// nondeterministic.
public enum BuildPerformance {}

extension BuildPerformance {
public enum Operation: String, Codable, Hashable, Sendable {
    case prepare
    case bridge
    case finalize
    case patch
}

public enum Workflow: String, Codable, Hashable, Sendable {
    case liveReload
    case hotPatch
}

public enum Outcome: String, Codable, Hashable, Sendable {
    case success
    case failure
}

public struct Stage: Codable, Hashable, Sendable {
    public var name: String
    public var invocationCount: UInt64
    public var durationMicroseconds: UInt64

    public init(
        name: String,
        invocationCount: UInt64,
        durationMicroseconds: UInt64
    ) {
        self.name = name
        self.invocationCount = invocationCount
        self.durationMicroseconds = durationMicroseconds
    }
}

public struct Subprocess: Codable, Hashable, Sendable {
    public var kind: SwiftFrontend.InvocationKind
    public var executableName: String
    public var invocationCount: UInt64
    public var failureCount: UInt64
    public var durationMicroseconds: UInt64
    public var standardOutputBytes: UInt64
    public var standardErrorBytes: UInt64

    public init(
        kind: SwiftFrontend.InvocationKind,
        executableName: String,
        invocationCount: UInt64,
        failureCount: UInt64,
        durationMicroseconds: UInt64,
        standardOutputBytes: UInt64,
        standardErrorBytes: UInt64
    ) {
        self.kind = kind
        self.executableName = executableName
        self.invocationCount = invocationCount
        self.failureCount = failureCount
        self.durationMicroseconds = durationMicroseconds
        self.standardOutputBytes = standardOutputBytes
        self.standardErrorBytes = standardErrorBytes
    }
}

public struct Counter: Codable, Hashable, Sendable {
    public var name: String
    public var value: UInt64

    public init(name: String, value: UInt64) {
        self.name = name
        self.value = value
    }
}

public struct Artifact: Codable, Hashable, Sendable {
    public var relativePath: String
    public var byteCount: UInt64

    public init(relativePath: String, byteCount: UInt64) {
        self.relativePath = relativePath
        self.byteCount = byteCount
    }
}

public struct Trace: Codable, Hashable, Sendable {
    public var stages: [BuildPerformance.Stage]
    public var subprocesses: [BuildPerformance.Subprocess]
    public var counters: [BuildPerformance.Counter]
    public var artifacts: [BuildPerformance.Artifact]

    public init(
        stages: [BuildPerformance.Stage] = [],
        subprocesses: [BuildPerformance.Subprocess] = [],
        counters: [BuildPerformance.Counter] = [],
        artifacts: [BuildPerformance.Artifact] = []
    ) {
        self.stages = stages
        self.subprocesses = subprocesses
        self.counters = counters
        self.artifacts = artifacts
    }

    public func validate() throws {
        guard stages.count <= 256,
              subprocesses.count <= 64,
              counters.count <= 256,
              artifacts.count <= 4_096
        else {
            throw BuildPerformance.Error.invalid("report exceeds structural limits")
        }
        try Self.validateUnique(stages.map(\.name), label: "stage")
        try Self.validateUnique(
            subprocesses.map { "\($0.kind.rawValue)\u{0}\($0.executableName)" },
            label: "subprocess"
        )
        try Self.validateUnique(counters.map(\.name), label: "counter")
        try Self.validateUnique(artifacts.map(\.relativePath), label: "artifact")
        guard stages.allSatisfy({
            Self.isName($0.name) && $0.invocationCount > 0
        }), subprocesses.allSatisfy({
            Self.isExecutableName($0.executableName)
                && $0.invocationCount > 0
                && $0.failureCount <= $0.invocationCount
        }), counters.allSatisfy({ Self.isName($0.name) }), artifacts.allSatisfy({
            Self.isSafeRelativePath($0.relativePath)
        }) else {
            throw BuildPerformance.Error.invalid("report contains an invalid name or count")
        }
    }

    private static func validateUnique(_ values: [String], label: String) throws {
        guard values == values.sorted(), Set(values).count == values.count else {
            throw BuildPerformance.Error.invalid("\(label) records are not unique and sorted")
        }
    }

    private static func isName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }

    private static func isExecutableName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.utf8.count <= 255
            && value.unicodeScalars.allSatisfy {
                $0.value >= 0x20 && $0.value != 0x7f
                    && $0 != "/" && $0 != "\\"
            }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 4_096, !value.hasPrefix("/") else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains(".")
            && !components.contains("..")
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

public struct Report: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var operation: BuildPerformance.Operation
    public var workflow: BuildPerformance.Workflow
    public var outcome: BuildPerformance.Outcome
    public var totalDurationMicroseconds: UInt64
    public var trace: BuildPerformance.Trace

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        operation: BuildPerformance.Operation,
        workflow: BuildPerformance.Workflow,
        outcome: BuildPerformance.Outcome,
        totalDurationMicroseconds: UInt64,
        trace: BuildPerformance.Trace
    ) throws {
        self.schemaVersion = schemaVersion
        self.operation = operation
        self.workflow = workflow
        self.outcome = outcome
        self.totalDurationMicroseconds = totalDurationMicroseconds
        self.trace = trace
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BuildPerformance.Error.invalid("unsupported schema version")
        }
        try trace.validate()
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case let .invalid(reason): "invalid build performance report: \(reason)"
        }
    }
}
}
