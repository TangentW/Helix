import CoreGraphics
import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

#if canImport(UIKit)
import UIKit
#endif

/// APIs shared by Helix's development-time code activation and UI refresh layers.
///
/// Most applications interact with this namespace through ``Reloadable``,
/// ``StateProviding``, or SwiftUI's `View/liveReloadBoundary(for:mode:pulse:)`.
/// Runtime and build-tool integrations also use the stable identity and context
/// values defined here.
public enum LiveReload {}

extension LiveReload {
/// A stable, content-independent identity for a logical Swift source path.
///
/// Derive this value from the path recorded in the Helix source manifest, not
/// from an absolute checkout or DerivedData path.
public struct SourceFileID: Core.DigestIdentity {
    /// The digest used on the Live Reload wire.
    public let rawValue: Core.Digest

    /// Reconstructs an identity from a previously validated digest.
    public init(rawValue: Core.Digest) { self.rawValue = rawValue }

    /// Derives the stable identity for a manifest-relative source path.
    ///
    /// ```swift
    /// let id = LiveReload.SourceFileID.derive(
    ///     logicalPath: "Sources/ProfileViewController.swift"
    /// )
    /// ```
    ///
    /// - Parameter logicalPath: The canonical path relative to the Feature's
    ///   configured source root.
    public static func derive(logicalPath: String) -> Self {
        var hasher = Core.StableHasher(domain: "HLX.SourceFile.v1")
        hasher.append(logicalPath)
        return .init(rawValue: hasher.finalize())
    }
}

/// A stable identity for a Swift nominal type such as a class, struct, or enum.
///
/// UIKit instance discovery and SwiftUI boundaries use this value to match a
/// changed declaration to the corresponding UI target.
public struct NominalTypeID: Core.DigestIdentity {
    /// The digest used by reload hints and boundary registrations.
    public let rawValue: Core.Digest

    /// Reconstructs an identity from a previously validated digest.
    public init(rawValue: Core.Digest) { self.rawValue = rawValue }

    /// Derives an identity from a Swift module and canonical type name.
    ///
    /// ```swift
    /// let screenID = LiveReload.NominalTypeID.derive(
    ///     module: "ProfileFeature",
    ///     canonicalName: "ProfileFeature.ScreenViewController"
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - module: The compiled Swift module name.
    ///   - canonicalName: The declaration name within that module, including
    ///     any namespace or nesting components.
    public static func derive(module: String, canonicalName: String) -> Self {
        var hasher = Core.StableHasher(domain: "HLX.NominalType.v1")
        hasher.append(module)
        hasher.append(canonicalName)
        return .init(rawValue: hasher.finalize())
    }
}

/// The application-defined name of a UIKit recreation factory.
///
/// Factories are an advanced fallback for changes that cannot be reflected by
/// invalidating an existing view hierarchy. Ordinary layout and display edits
/// do not require a factory.
public struct FactoryID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    /// The stable identifier stored in a reload hint.
    public let rawValue: String

    /// Creates an identifier from an application-owned stable string.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The unmodified identifier string.
    public var description: String { rawValue }
}

/// Errors raised when an incoming reload context or hint is malformed.
public enum ValidationError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// The activation context violates a required invariant.
    case invalidContext(String)
    /// An invalidation option contains bits unknown to this Runtime version.
    case unsupportedInvalidationHints(UInt16)

    /// A diagnostic suitable for logs and the Helix debug overlay.
    public var description: String {
        switch self {
        case let .invalidContext(reason): "invalid Live Reload context: \(reason)"
        case let .unsupportedInvalidationHints(bits):
            "unsupported Live Reload invalidation bits: 0x\(String(bits, radix: 16))"
        }
    }
}

/// The code-execution backend that produced an activated generation.
public enum Backend: String, Codable, Hashable, Sendable {
    /// A signed development image using Swift Dynamic Replacement.
    case nativeDynamicReplacement
    /// Verified Helix bytecode executed by HLVM.
    case hlbc
}

/// The UI work requested after a generation becomes active.
///
/// Helix normally infers this policy from the changed declaration. Applications
/// only need to select a policy when providing an explicit reload rule.
public enum Policy: String, Codable, Hashable, Sendable {
    /// Activate code without performing UI work.
    case observeOnly
    /// Invalidate the matching UIKit or SwiftUI target in place.
    case invalidate
    /// Call ``Reloadable/applyLiveReload(_:)`` on the matching instance.
    case invokeHook
    /// Replace a UIKit controller using a registered factory.
    case recreate
}

/// The event that initiated a UI refresh.
public enum Reason: String, Codable, Hashable, Sendable {
    /// A watched Swift source file was saved.
    case sourceSaved
    /// A developer explicitly requested a refresh.
    case manual
    /// Source was restored to its baseline implementation.
    case baselineRestored
}

/// Fine-grained UIKit work that is safe to request after code activation.
///
/// Multiple options can be combined. Data reload options remain disabled by
/// default in `UIKitReload.Coordinator` because `reloadData()` may have business
/// side effects.
public struct InvalidationHints: OptionSet, Codable, Hashable, Sendable {
    /// The encoded option bits.
    public let rawValue: UInt16

    /// Creates a hint set from its encoded representation.
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Calls `setNeedsUpdateConstraints()` on the matched view.
    public static let constraints = Self(rawValue: 1 << 0)
    /// Calls `setNeedsLayout()` on the matched view.
    public static let layout = Self(rawValue: 1 << 1)
    /// Calls `setNeedsDisplay()` on the matched view.
    public static let display = Self(rawValue: 1 << 2)
    /// Requests table data reload when broad data reload is enabled.
    public static let tableData = Self(rawValue: 1 << 3)
    /// Requests collection data reload when broad data reload is enabled.
    public static let collectionData = Self(rawValue: 1 << 4)
    /// Calls `layoutIfNeeded()` when no controller transition is active.
    public static let immediateLayout = Self(rawValue: 1 << 5)

    /// Every option understood by this Runtime version.
    public static let supported: Self = [
        .constraints, .layout, .display, .tableData, .collectionData, .immediateLayout,
    ]

    /// Rejects option bits that this Runtime cannot interpret safely.
    public func validate() throws {
        let unknown = rawValue & ~Self.supported.rawValue
        guard unknown == 0 else {
            throw LiveReload.ValidationError.unsupportedInvalidationHints(unknown)
        }
    }
}

/// Immutable metadata describing one activated code generation.
///
/// A context is delivered to reload hooks and included in UI refresh reports.
/// Automatic contexts must have positive generation and source revision values
/// and identify at least one changed function.
public struct Context: Codable, Hashable, Sendable {
    /// The monotonically increasing Runtime generation identifier.
    public var generationID: UInt64
    /// The source watcher revision that produced the generation.
    public var sourceRevision: UInt64
    /// Logical source files that contributed changed implementations.
    public var changedSources: Set<LiveReload.SourceFileID>
    /// Stable function identities activated in this generation.
    public var changedFunctions: Set<Core.FunctionKey>
    /// The backend used to execute the changed code.
    public var backend: LiveReload.Backend
    /// Why UI refresh was requested.
    public var reason: LiveReload.Reason

    /// Creates a reload context.
    ///
    /// Build tools normally create automatic contexts. Applications may create
    /// a `.manual` context when driving a custom refresh surface.
    ///
    /// - Parameters:
    ///   - generationID: A positive, monotonically increasing identifier.
    ///   - sourceRevision: A positive watcher revision for automatic reloads.
    ///   - changedSources: Logical sources changed by the transaction.
    ///   - changedFunctions: Functions activated by the transaction.
    ///   - backend: The activation backend.
    ///   - reason: The initiating event.
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

    /// Validates invariants required by reload coordinators.
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

/// An explicit, application-owned hook for UI work that cannot be inferred.
///
/// Most UIKit layout and drawing edits are refreshed automatically and do not
/// need this protocol. Use a hook for idempotent business presentation work,
/// never to blindly call `viewDidLoad()` again.
///
/// ```swift
/// extension ProfileViewController: LiveReload.Reloadable {
///     func applyLiveReload(_ context: LiveReload.Context) throws {
///         renderCurrentProfile()
///         view.setNeedsLayout()
///     }
/// }
/// ```
@MainActor
public protocol Reloadable: AnyObject {
    /// The policy emitted when this explicit hook is selected.
    static var liveReloadPolicy: LiveReload.Policy { get }

    /// Reapplies idempotent presentation work to the existing instance.
    ///
    /// - Parameter context: Metadata for the generation that is already active.
    func applyLiveReload(_ context: LiveReload.Context) throws
}
}

public extension LiveReload.Reloadable {
    /// The default policy for explicit reload hooks.
    static var liveReloadPolicy: LiveReload.Policy { .invokeHook }
}

extension LiveReload {
/// A bounded, codable value used to preserve selected UI state during recreation.
public enum Value: Codable, Hashable, Sendable {
    /// A Boolean value.
    case bool(Bool)
    /// A signed 64-bit integer.
    case int(Int64)
    /// A double-precision floating-point value.
    case double(Double)
    /// A Swift string.
    case string(String)
    /// Opaque data owned by the application.
    case data(Data)
    /// A Core Graphics point.
    case point(CGPoint)
    /// A Core Graphics size.
    case size(CGSize)
    /// A Core Graphics rectangle.
    case rect(CGRect)
}

/// Application-selected state captured before recreating a UIKit controller.
public struct State: Codable, Hashable, Sendable {
    /// Named values understood by the old and replacement controller.
    public var values: [String: LiveReload.Value]

    /// Creates a state payload.
    public init(values: [String: LiveReload.Value] = [:]) {
        self.values = values
    }
}

/// Captures and restores selected state across UIKit controller recreation.
///
/// ```swift
/// extension EditorViewController: LiveReload.StateProviding {
///     func captureLiveReloadState() -> LiveReload.State {
///         .init(values: ["draft": .string(textView.text)])
///     }
///
///     func restoreLiveReloadState(_ state: LiveReload.State) {
///         if case let .some(.string(draft)) = state.values["draft"] {
///             textView.text = draft
///         }
///     }
/// }
/// ```
@MainActor
public protocol StateProviding: AnyObject {
    /// Returns the state that should survive instance replacement.
    func captureLiveReloadState() -> LiveReload.State

    /// Applies state captured from the controller being replaced.
    func restoreLiveReloadState(_ state: LiveReload.State)
}

/// Application routing values passed to an explicit recreation factory.
public struct RouteContext: Codable, Hashable, Sendable {
    /// Named route values interpreted by the application factory.
    public var values: [String: LiveReload.Value]

    /// Creates an empty or application-populated route context.
    public init(values: [String: LiveReload.Value] = [:]) {
        self.values = values
    }
}

#if canImport(UIKit)
/// A typed factory for recreating a UIKit controller after an incompatible edit.
///
/// Ordinary Live Reload does not require factories. Register one only when the
/// current instance cannot represent the new presentation safely.
@MainActor
public protocol Factory {
    /// The controller produced by this factory.
    associatedtype Controller: UIViewController

    /// The stable identifier referenced by a `.recreate` reload rule.
    static var id: LiveReload.FactoryID { get }

    /// Builds a replacement controller.
    ///
    /// - Parameters:
    ///   - route: Application routing values for the replacement.
    ///   - retainedModel: An optional model retained from the old controller.
    func makeController(
        route: LiveReload.RouteContext,
        retainedModel: AnyObject?
    ) throws -> Controller
}

/// Adapts an application-specific container that Helix cannot replace itself.
@MainActor
public protocol ContainerAdapter: AnyObject {
    /// Replaces a child controller without animation.
    ///
    /// - Parameters:
    ///   - oldController: The currently installed child.
    ///   - newController: The freshly created replacement.
    func replace(
        oldController: UIViewController,
        with newController: UIViewController
    ) throws
}
#endif

/// Coordinates critical application work with UI refresh.
///
/// Reload coordinators wait while at least one critical section is active. This
/// is useful around navigation transitions or non-reentrant state mutations.
///
/// ```swift
/// let value = try await LiveReload.Guard.shared.withCriticalSection("checkout") {
///     try await submitOrder()
/// }
/// ```
public actor Guard {
    /// The process-wide guard used by default reload coordinators.
    public static let shared = LiveReload.Guard()

    private var criticalSections: [UUID: String] = [:]
    private var continuations: [CheckedContinuation<Void, Never>] = []

    /// Creates an independent guard for custom coordination domains.
    public init() {}

    /// Whether at least one critical section is active.
    public var isBlocked: Bool { !criticalSections.isEmpty }
    /// Human-readable labels for currently active critical sections.
    public var activeLabels: [String] { criticalSections.values.sorted() }

    /// Begins a critical section and returns the token needed to end it.
    @discardableResult
    public func begin(_ label: String) -> UUID {
        let token = UUID()
        criticalSections[token] = label
        return token
    }

    /// Ends the critical section associated with `token`.
    public func end(_ token: UUID) {
        criticalSections.removeValue(forKey: token)
        guard criticalSections.isEmpty else { return }
        let waiting = continuations
        continuations.removeAll(keepingCapacity: true)
        for continuation in waiting { continuation.resume() }
    }

    /// Suspends until all active critical sections have ended.
    public func waitUntilUnblocked() async {
        guard !criticalSections.isEmpty else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    /// Runs an asynchronous operation while reload is blocked.
    ///
    /// The critical section is ended whether the operation returns or throws.
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

    /// Decodes a context while rejecting duplicate source and function identities.
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

    /// Encodes changed source and function sets in deterministic sorted order.
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
