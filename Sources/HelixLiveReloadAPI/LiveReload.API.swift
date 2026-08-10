import CoreGraphics
import Foundation
import HelixCore
import HelixRuntime

#if canImport(UIKit)
import UIKit
#endif

public enum LiveReload {}

extension LiveReload {
public struct SourceFileID: Core.DigestIdentity {
    public let rawValue: Core.Digest
    public init(rawValue: Core.Digest) { self.rawValue = rawValue }

    public static func derive(logicalPath: String) -> Self {
        var hasher = Core.StableHasher(domain: "HLX.SourceFile.v1")
        hasher.append(logicalPath)
        return .init(rawValue: hasher.finalize())
    }
}

public struct NominalTypeID: Core.DigestIdentity {
    public let rawValue: Core.Digest
    public init(rawValue: Core.Digest) { self.rawValue = rawValue }

    public static func derive(module: String, canonicalName: String) -> Self {
        var hasher = Core.StableHasher(domain: "HLX.NominalType.v1")
        hasher.append(module)
        hasher.append(canonicalName)
        return .init(rawValue: hasher.finalize())
    }
}

public struct FactoryID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum ValidationError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidContext(String)
    case unsupportedInvalidationHints(UInt16)

    public var description: String {
        switch self {
        case let .invalidContext(reason): "invalid Live Reload context: \(reason)"
        case let .unsupportedInvalidationHints(bits):
            "unsupported Live Reload invalidation bits: 0x\(String(bits, radix: 16))"
        }
    }
}

public enum Backend: String, Codable, Hashable, Sendable {
    case nativeDynamicReplacement
    case hlbc
}

public enum Policy: String, Codable, Hashable, Sendable {
    case observeOnly
    case invalidate
    case invokeHook
    case recreate
}

public enum Reason: String, Codable, Hashable, Sendable {
    case sourceSaved
    case manual
    case baselineRestored
}

public struct InvalidationHints: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let constraints = Self(rawValue: 1 << 0)
    public static let layout = Self(rawValue: 1 << 1)
    public static let display = Self(rawValue: 1 << 2)
    public static let tableData = Self(rawValue: 1 << 3)
    public static let collectionData = Self(rawValue: 1 << 4)
    public static let immediateLayout = Self(rawValue: 1 << 5)

    public static let supported: Self = [
        .constraints, .layout, .display, .tableData, .collectionData, .immediateLayout,
    ]

    public func validate() throws {
        let unknown = rawValue & ~Self.supported.rawValue
        guard unknown == 0 else {
            throw LiveReload.ValidationError.unsupportedInvalidationHints(unknown)
        }
    }
}

public struct Context: Codable, Hashable, Sendable {
    public var generationID: UInt64
    public var sourceRevision: UInt64
    public var changedSources: Set<LiveReload.SourceFileID>
    public var changedFunctions: Set<Core.FunctionKey>
    public var backend: LiveReload.Backend
    public var reason: LiveReload.Reason

    public init(
        generationID: UInt64,
        sourceRevision: UInt64 = 0,
        changedSources: Set<LiveReload.SourceFileID> = [],
        changedFunctions: Set<Core.FunctionKey>,
        backend: LiveReload.Backend = .hlbc,
        reason: LiveReload.Reason = .sourceSaved
    ) {
        self.generationID = generationID
        self.sourceRevision = sourceRevision
        self.changedSources = changedSources
        self.changedFunctions = changedFunctions
        self.backend = backend
        self.reason = reason
    }

    public func validate() throws {
        guard generationID > 0 else {
            throw LiveReload.ValidationError.invalidContext("generationID must be positive")
        }
        if reason != .manual, sourceRevision == 0 {
            throw LiveReload.ValidationError.invalidContext(
                "sourceRevision must be positive for an automatic reload"
            )
        }
        guard !changedFunctions.isEmpty || reason == .manual else {
            throw LiveReload.ValidationError.invalidContext(
                "an automatic reload must identify at least one changed function"
            )
        }
    }
}

@MainActor
public protocol Reloadable: AnyObject {
    static var liveReloadPolicy: LiveReload.Policy { get }
    func applyLiveReload(_ context: LiveReload.Context) throws
}
}

public extension LiveReload.Reloadable {
    static var liveReloadPolicy: LiveReload.Policy { .invokeHook }
}

extension LiveReload {
public enum Value: Codable, Hashable, Sendable {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case data(Data)
    case point(CGPoint)
    case size(CGSize)
    case rect(CGRect)
}

public struct State: Codable, Hashable, Sendable {
    public var values: [String: LiveReload.Value]

    public init(values: [String: LiveReload.Value] = [:]) {
        self.values = values
    }
}

@MainActor
public protocol StateProviding: AnyObject {
    func captureLiveReloadState() -> LiveReload.State
    func restoreLiveReloadState(_ state: LiveReload.State)
}

public struct RouteContext: Codable, Hashable, Sendable {
    public var values: [String: LiveReload.Value]

    public init(values: [String: LiveReload.Value] = [:]) {
        self.values = values
    }
}

#if canImport(UIKit)
@MainActor
public protocol Factory {
    associatedtype Controller: UIViewController

    static var id: LiveReload.FactoryID { get }
    func makeController(
        route: LiveReload.RouteContext,
        retainedModel: AnyObject?
    ) throws -> Controller
}

@MainActor
public protocol ContainerAdapter: AnyObject {
    func replace(
        oldController: UIViewController,
        with newController: UIViewController
    ) throws
}
#endif

public actor Guard {
    public static let shared = LiveReload.Guard()

    private var criticalSections: [UUID: String] = [:]
    private var continuations: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isBlocked: Bool { !criticalSections.isEmpty }
    public var activeLabels: [String] { criticalSections.values.sorted() }

    @discardableResult
    public func begin(_ label: String) -> UUID {
        let token = UUID()
        criticalSections[token] = label
        return token
    }

    public func end(_ token: UUID) {
        criticalSections.removeValue(forKey: token)
        guard criticalSections.isEmpty else { return }
        let waiting = continuations
        continuations.removeAll(keepingCapacity: true)
        for continuation in waiting { continuation.resume() }
    }

    public func waitUntilUnblocked() async {
        guard !criticalSections.isEmpty else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    public func withCriticalSection<T: Sendable>(
        _ label: String,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let token = begin(label)
        do {
            let value = try await operation()
            end(token)
            return value
        } catch {
            end(token)
            throw error
        }
    }
}
}

extension LiveReload.Context {
    private enum CodingKeys: String, CodingKey {
        case generationID, sourceRevision, changedSources, changedFunctions, backend, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generationID = try container.decode(UInt64.self, forKey: .generationID)
        sourceRevision = try container.decode(UInt64.self, forKey: .sourceRevision)
        let sources = try container.decode([LiveReload.SourceFileID].self, forKey: .changedSources)
        let functions = try container.decode([Core.FunctionKey].self, forKey: .changedFunctions)
        guard Set(sources).count == sources.count, Set(functions).count == functions.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .changedFunctions,
                in: container,
                debugDescription: "duplicate Live Reload identity"
            )
        }
        changedSources = Set(sources)
        changedFunctions = Set(functions)
        backend = try container.decode(LiveReload.Backend.self, forKey: .backend)
        reason = try container.decode(LiveReload.Reason.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generationID, forKey: .generationID)
        try container.encode(sourceRevision, forKey: .sourceRevision)
        try container.encode(
            changedSources.sorted { $0.description < $1.description },
            forKey: .changedSources
        )
        try container.encode(
            changedFunctions.sorted { $0.description < $1.description },
            forKey: .changedFunctions
        )
        try container.encode(backend, forKey: .backend)
        try container.encode(reason, forKey: .reason)
    }
}
