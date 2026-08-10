import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier

extension Runtime {
public struct GenerationID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "g\(rawValue)" }
}

public struct Route: Sendable {
    public let entryIndex: Core.EntryIndex
    public let functionID: Bytecode.FunctionID
    public let image: Verification.Image

    public init(entryIndex: Core.EntryIndex, functionID: Bytecode.FunctionID, image: Verification.Image) {
        self.entryIndex = entryIndex
        self.functionID = functionID
        self.image = image
    }
}

public final class Generation: @unchecked Sendable {
    public let id: Runtime.GenerationID
    public let parentID: Runtime.GenerationID?
    public let packageID: String
    public let packageHash: Core.Digest
    public let createdAt: Date
    public let routes: [Core.EntryIndex: Runtime.Route]
    public let removedEntries: Set<Core.EntryIndex>
    public let images: [Verification.Image]
    public let resourceLimits: Core.ResourceLimits
    public let estimatedByteCount: Int

    public init(
        id: Runtime.GenerationID,
        parentID: Runtime.GenerationID?,
        packageID: String,
        packageHash: Core.Digest,
        images: [Verification.Image],
        removedEntries: Set<Core.EntryIndex> = [],
        estimatedByteCount: Int,
        createdAt: Date = Date()
    ) throws {
        guard id.rawValue > 0 else { throw Runtime.ActivationError.invalidGeneration("generation ID must be positive") }
        guard !packageID.isEmpty else { throw Runtime.ActivationError.invalidGeneration("package ID must not be empty") }
        guard estimatedByteCount >= 0 else { throw Runtime.ActivationError.invalidGeneration("negative byte estimate") }
        guard !images.isEmpty || !removedEntries.isEmpty else {
            throw Runtime.ActivationError.invalidGeneration(
                "generation has neither verified routes nor original-route tombstones"
            )
        }
        var routes: [Core.EntryIndex: Runtime.Route] = [:]
        var shellHash: Core.Digest?
        for image in images {
            if let shellHash, shellHash != image.shell.interfaceHash {
                throw Runtime.ActivationError.invalidGeneration("images target different Shell interfaces")
            }
            shellHash = image.shell.interfaceHash
            for entry in image.module.entries {
                let route = Runtime.Route(entryIndex: entry.entryIndex, functionID: entry.functionID, image: image)
                guard routes.updateValue(route, forKey: entry.entryIndex) == nil else {
                    throw Runtime.ActivationError.duplicateRoute(entry.entryIndex)
                }
            }
        }
        guard Set(routes.keys).isDisjoint(with: removedEntries) else {
            throw Runtime.ActivationError.invalidGeneration(
                "generation both replaces and removes the same entry"
            )
        }
        self.id = id
        self.parentID = parentID
        self.packageID = packageID
        self.packageHash = packageHash
        self.createdAt = createdAt
        self.routes = routes
        self.removedEntries = removedEntries
        self.images = images
        self.estimatedByteCount = estimatedByteCount
        self.resourceLimits = images.dropFirst().reduce(images.first?.effectiveResourceLimits ?? .init()) {
            $0.constrained(by: $1.effectiveResourceLimits)
        }
    }
}

public final class GenerationLease: @unchecked Sendable {
    public let generation: Runtime.Generation
    init(generation: Runtime.Generation) { self.generation = generation }
}

public enum ActivationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidGeneration(String)
    case duplicateRoute(Core.EntryIndex)
    case staleActiveGeneration(expected: Runtime.GenerationID?, actual: Runtime.GenerationID?)
    case parentMismatch(expected: Runtime.GenerationID?, actual: Runtime.GenerationID?)
    case generationAlreadyExists(Runtime.GenerationID)
    case unknownGeneration(Runtime.GenerationID)
    case rollbackTargetIsNotAncestor(target: Runtime.GenerationID, active: Runtime.GenerationID)
    case generationLimitReached(maximum: Int)
    case memoryLimitReached(maximumBytes: Int)
    case quarantined(Runtime.GenerationID)

    public var description: String {
        switch self {
        case let .invalidGeneration(reason): "invalid generation: \(reason)"
        case let .duplicateRoute(entry): "generation defines duplicate route \(entry)"
        case let .staleActiveGeneration(expected, actual): "active generation changed: expected \(String(describing: expected)), got \(String(describing: actual))"
        case let .parentMismatch(expected, actual): "generation parent mismatch: expected \(String(describing: expected)), got \(String(describing: actual))"
        case let .generationAlreadyExists(id): "generation \(id) already exists"
        case let .unknownGeneration(id): "unknown generation \(id)"
        case let .rollbackTargetIsNotAncestor(target, active):
            "generation \(target) is not an ancestor of active generation \(active)"
        case let .generationLimitReached(maximum): "generation limit reached (\(maximum))"
        case let .memoryLimitReached(maximum): "generation memory limit reached (\(maximum) bytes)"
        case let .quarantined(id): "generation \(id) is quarantined"
        }
    }
}
}
