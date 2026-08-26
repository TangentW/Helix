import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVerifier
#endif

extension Runtime {
/// Monotonic identity of one activated Runtime generation.
public struct GenerationID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// Unsigned wire and persistence representation.
    public let rawValue: UInt64
    /// Creates a generation identity. Activatable generations must be positive.
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    /// Orders generation identities by their raw monotonic value.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    /// Compact diagnostic form such as `g42`.
    public var description: String { "g\(rawValue)" }
}

/// Verified mapping from an instrumented entry index to an HLBC function.
public struct Route: Sendable {
    /// Stable Shell entry being replaced.
    public let entryIndex: Core.EntryIndex
    /// Function executed inside the verified bytecode image.
    public let functionID: Bytecode.FunctionID
    /// Immutable verified image that owns ``functionID``.
    public let image: Verification.Image

    /// Creates a verified dispatch route.
    public init(entryIndex: Core.EntryIndex, functionID: Bytecode.FunctionID, image: Verification.Image) {
        self.entryIndex = entryIndex
        self.functionID = functionID
        self.image = image
    }
}

/// Immutable set of replacement routes activated as one transaction.
///
/// A generation references its parent and resolves unchanged entries through
/// that ancestry. `removedEntries` are tombstones that explicitly restore an
/// original route instead of inheriting an older patch.
public final class Generation: @unchecked Sendable {
    /// Positive, unique generation identity.
    public let id: Runtime.GenerationID
    /// Generation that was active when this generation was built.
    public let parentID: Runtime.GenerationID?
    /// Stable package identifier used for diagnostics and persistence.
    public let packageID: String
    /// SHA-256 identity of the source package.
    public let packageHash: Core.Digest
    /// Local construction time.
    public let createdAt: Date
    /// Replacement routes keyed by stable Shell entry index.
    public let routes: [Core.EntryIndex: Runtime.Route]
    /// Entry indices that stop inheriting older replacement routes.
    public let removedEntries: Set<Core.EntryIndex>
    /// Verified bytecode images retained by this generation.
    public let images: [Verification.Image]
    /// Most restrictive signed resource limits across all images.
    public let resourceLimits: Core.ResourceLimits
    /// Full native capability snapshot for this generation. Nil selects the
    /// linked baseline, or inherits the parent's development snapshot.
    public let nativeCapabilities: Runtime.NativeCapabilities?
    /// Conservative memory estimate charged to the generation registry.
    public let estimatedByteCount: Int

    /// Creates and validates an immutable generation.
    ///
    /// Images must target one Shell interface, routes must be unique, and one
    /// entry cannot be both replaced and removed in the same transaction.
    public init(
        id: Runtime.GenerationID,
        parentID: Runtime.GenerationID?,
        packageID: String,
        packageHash: Core.Digest,
        images: [Verification.Image],
        removedEntries: Set<Core.EntryIndex> = [],
        nativeCapabilities: Runtime.NativeCapabilities? = nil,
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
        self.nativeCapabilities = nativeCapabilities
        self.estimatedByteCount = estimatedByteCount
        self.resourceLimits = images.dropFirst().reduce(images.first?.effectiveResourceLimits ?? .init()) {
            $0.constrained(by: $1.effectiveResourceLimits)
        }
    }
}

/// Strong reference that pins one immutable routing snapshot for an invocation.
///
/// A lease remains self-contained after its generation is superseded. The
/// registry may therefore compact the corresponding historical record without
/// changing route resolution halfway through a running call tree.
public final class GenerationLease: @unchecked Sendable {
    /// Immutable generation retained by the lease.
    public var generation: Runtime.Generation { snapshot.generation }

    let snapshot: Runtime.GenerationSnapshot

    init(snapshot: Runtime.GenerationSnapshot) {
        self.snapshot = snapshot
        snapshot.acquireLease()
    }

    deinit {
        snapshot.releaseLease()
    }

    func route(for entry: Core.EntryIndex) -> Runtime.Route? {
        snapshot.routes[entry]?.route
    }

    func entryEffects(for entry: Core.EntryIndex) -> Core.Effects? {
        snapshot.entryEffects[entry]
    }

    var resourceLimits: Core.ResourceLimits {
        snapshot.resourceLimits
    }

    var nativeCapabilities: Runtime.NativeCapabilities? {
        snapshot.nativeCapabilities
    }
}

/// Materialized routing state owned by the registry and active leases.
///
/// Route inheritance is flattened when a generation activates. Inherited
/// routes retain their verified images directly, so neither route lookup nor an
/// in-flight invocation depends on historical registry entries remaining live.
final class GenerationSnapshot: @unchecked Sendable {
    struct OwnedRoute: Sendable {
        let route: Runtime.Route
        let ownerID: Runtime.GenerationID
    }

    let generation: Runtime.Generation
    let routes: [Core.EntryIndex: OwnedRoute]
    let entryEffects: [Core.EntryIndex: Core.Effects]
    let resourceLimits: Core.ResourceLimits
    let nativeCapabilities: Runtime.NativeCapabilities?
    let artifactByteCounts: [Runtime.GenerationID: Int]

    private let leaseLock = NSLock()
    private var leaseCountStorage = 0

    init(generation: Runtime.Generation, parent: Runtime.GenerationSnapshot?) {
        var routes = parent?.routes ?? [:]
        for entry in generation.removedEntries {
            routes.removeValue(forKey: entry)
        }
        for (entry, route) in generation.routes {
            routes[entry] = .init(route: route, ownerID: generation.id)
        }

        var effects = parent?.entryEffects ?? [:]
        for image in generation.images {
            for (entry, descriptor) in image.shell.entries {
                effects[entry] = descriptor.effects
            }
        }

        var artifactByteCounts = parent?.artifactByteCounts ?? [:]
        let referencedOwners = Set(routes.values.map(\.ownerID))
        artifactByteCounts = artifactByteCounts.filter {
            referencedOwners.contains($0.key)
        }
        if !generation.images.isEmpty || generation.estimatedByteCount > 0 {
            artifactByteCounts[generation.id] = generation.estimatedByteCount
        }

        var imageLimits: [Core.Digest: Core.ResourceLimits] = [:]
        for ownedRoute in routes.values {
            imageLimits[ownedRoute.route.image.imageHash]
                = ownedRoute.route.image.effectiveResourceLimits
        }
        let limits = imageLimits.values.dropFirst().reduce(
            imageLimits.values.first ?? .init()
        ) { partial, next in
            partial.constrained(by: next)
        }

        self.generation = generation
        self.routes = routes
        self.entryEffects = effects
        self.resourceLimits = limits
        nativeCapabilities = generation.nativeCapabilities
            ?? parent?.nativeCapabilities
        self.artifactByteCounts = artifactByteCounts
    }

    var leaseCount: Int {
        leaseLock.lock()
        defer { leaseLock.unlock() }
        return leaseCountStorage
    }

    func acquireLease() {
        leaseLock.lock()
        leaseCountStorage += 1
        leaseLock.unlock()
    }

    func releaseLease() {
        leaseLock.lock()
        precondition(leaseCountStorage > 0, "unbalanced generation lease release")
        leaseCountStorage -= 1
        leaseLock.unlock()
    }
}

/// Generation construction, activation, rollback, and capacity failures.
public enum ActivationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A generation violates a structural invariant.
    case invalidGeneration(String)
    /// Multiple images replace the same Shell entry in one generation.
    case duplicateRoute(Core.EntryIndex)
    /// Compare-and-swap activation or rollback observed a different active ID.
    case staleActiveGeneration(expected: Runtime.GenerationID?, actual: Runtime.GenerationID?)
    /// A generation's declared parent differs from the expected active ID.
    case parentMismatch(expected: Runtime.GenerationID?, actual: Runtime.GenerationID?)
    /// The registry already contains the supplied generation ID.
    case generationAlreadyExists(Runtime.GenerationID)
    /// A successful activation has already used this or a newer identity.
    case generationIDNotMonotonic(
        previous: Runtime.GenerationID,
        attempted: Runtime.GenerationID
    )
    /// A requested lease or rollback target does not exist.
    case unknownGeneration(Runtime.GenerationID)
    /// Rollback attempted to jump outside the active generation's ancestry.
    case rollbackTargetIsNotAncestor(target: Runtime.GenerationID, active: Runtime.GenerationID)
    /// The registry reached its configured retained-generation count.
    case generationLimitReached(maximum: Int)
    /// Activating the generation would exceed the registry byte budget.
    case memoryLimitReached(maximumBytes: Int)
    /// A known-bad generation cannot be activated or selected for rollback.
    case quarantined(Runtime.GenerationID)

    /// Human-readable activation failure detail.
    public var description: String {
        switch self {
        case let .invalidGeneration(reason): "invalid generation: \(reason)"
        case let .duplicateRoute(entry): "generation defines duplicate route \(entry)"
        case let .staleActiveGeneration(expected, actual): "active generation changed: expected \(String(describing: expected)), got \(String(describing: actual))"
        case let .parentMismatch(expected, actual): "generation parent mismatch: expected \(String(describing: expected)), got \(String(describing: actual))"
        case let .generationAlreadyExists(id): "generation \(id) already exists"
        case let .generationIDNotMonotonic(previous, attempted):
            "generation ID is not monotonic: \(attempted) follows \(previous)"
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
