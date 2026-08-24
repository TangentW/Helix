import Foundation

extension Core {
/// Describes how Swift spells and dispatches an explicitly exported native operation.
public enum NativeImportKind: String, Codable, Hashable, Sendable, CaseIterable {
    case globalFunction
    case initializer
    case instanceMethod
    case staticMethod
    case instanceGetter
    case instanceSetter
    case staticGetter
    case staticSetter
    case instanceSubscriptGetter
    case instanceSubscriptSetter
    case serviceMethod
}

/// A policy domain, not a dynamic module lookup key.
public struct NativeImportDomain: RawRepresentable, Codable, Hashable, Sendable,
    Comparable, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }

    public static let swift = Self(rawValue: "swift")
    public static let foundation = Self(rawValue: "apple.foundation")
    public static let uiKit = Self(rawValue: "apple.uikit")
    public static let application = Self(rawValue: "application")
}

/// Classifies observable state access independently from allocation and throwing effects.
public enum NativeImportAccess: String, Codable, Hashable, Sendable, CaseIterable {
    case pure
    case read
    case write
    case readWrite
    case io

    public var hasExternalSideEffects: Bool {
        switch self {
        case .pure, .read: false
        case .write, .readWrite, .io: true
        }
    }
}

public enum NativeImportDeadlineMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Trusted constant-time work. The runtime can only check its deadline after return.
    case bounded
    /// Work that must periodically call `NativeInvocationContext.checkpoint`.
    case cooperative
    /// An async operation may suspend without consuming the root's active-time
    /// budget, but its own wall-clock deadline remains continuous.
    case suspending
}

public struct NativeImportExecutionPolicy: Codable, Hashable, Sendable {
    public static let maximumBoundedDurationMicroseconds: UInt32 = 2_000
    public static let maximumCooperativeDurationMicroseconds: UInt32 = 1_000_000
    public static let maximumSuspendingDurationMicroseconds: UInt32 = 60_000_000
    public static let maximumMainThreadDurationMicroseconds: UInt32 = 16_000

    public var deadlineMode: Core.NativeImportDeadlineMode
    public var maximumDurationMicroseconds: UInt32
    public var allowsMainThread: Bool

    public init(
        deadlineMode: Core.NativeImportDeadlineMode,
        maximumDurationMicroseconds: UInt32,
        allowsMainThread: Bool
    ) {
        self.deadlineMode = deadlineMode
        self.maximumDurationMicroseconds = maximumDurationMicroseconds
        self.allowsMainThread = allowsMainThread
    }
}

/// Security- and scheduling-relevant metadata frozen into every native import identity.
public struct NativeImportContract: Codable, Hashable, Sendable {
    public var kind: Core.NativeImportKind
    public var domain: Core.NativeImportDomain
    public var access: Core.NativeImportAccess
    public var execution: Core.NativeImportExecutionPolicy
    /// Sparse, index-aligned callback lifetime authority for this import.
    public var callbacks: [Core.NativeImportCallback]

    public init(
        kind: Core.NativeImportKind,
        domain: Core.NativeImportDomain,
        access: Core.NativeImportAccess,
        execution: Core.NativeImportExecutionPolicy,
        callbacks: [Core.NativeImportCallback] = []
    ) {
        self.kind = kind
        self.domain = domain
        self.access = access
        self.execution = execution
        self.callbacks = callbacks.sorted()
    }

    public static func bounded(
        kind: Core.NativeImportKind,
        domain: Core.NativeImportDomain,
        access: Core.NativeImportAccess,
        maximumDurationMicroseconds: UInt32,
        allowsMainThread: Bool,
        callbacks: [Core.NativeImportCallback] = []
    ) -> Self {
        Self(
            kind: kind,
            domain: domain,
            access: access,
            execution: .init(
                deadlineMode: .bounded,
                maximumDurationMicroseconds: maximumDurationMicroseconds,
                allowsMainThread: allowsMainThread
            ),
            callbacks: callbacks
        )
    }

    public static func cooperative(
        kind: Core.NativeImportKind,
        domain: Core.NativeImportDomain,
        access: Core.NativeImportAccess,
        maximumDurationMicroseconds: UInt32,
        allowsMainThread: Bool,
        callbacks: [Core.NativeImportCallback] = []
    ) -> Self {
        Self(
            kind: kind,
            domain: domain,
            access: access,
            execution: .init(
                deadlineMode: .cooperative,
                maximumDurationMicroseconds: maximumDurationMicroseconds,
                allowsMainThread: allowsMainThread
            ),
            callbacks: callbacks
        )
    }

    public static func suspending(
        kind: Core.NativeImportKind,
        domain: Core.NativeImportDomain,
        access: Core.NativeImportAccess,
        maximumDurationMicroseconds: UInt32,
        allowsMainThread: Bool
    ) -> Self {
        Self(
            kind: kind,
            domain: domain,
            access: access,
            execution: .init(
                deadlineMode: .suspending,
                maximumDurationMicroseconds: maximumDurationMicroseconds,
                allowsMainThread: allowsMainThread
            )
        )
    }

    public func validate(effects: Core.Effects) throws {
        guard effects.isAsync == (execution.deadlineMode == .suspending) else {
            throw Core.NativeImportContractError.invalid(
                "async effects require the suspending invocation contract"
            )
        }
        guard callbacks.count <= 64,
              callbacks == callbacks.sorted(),
              Set(callbacks.map(\.parameterIndex)).count == callbacks.count
        else {
            throw Core.NativeImportContractError.invalid(
                "callback parameters must be unique, sorted, and bounded"
            )
        }
        guard Self.isValidDomain(domain.rawValue) else {
            throw Core.NativeImportContractError.invalid("domain is not canonical")
        }
        guard access.hasExternalSideEffects == effects.hasExternalSideEffects else {
            throw Core.NativeImportContractError.invalid(
                "state access disagrees with external side-effect metadata"
            )
        }
        guard execution.maximumDurationMicroseconds > 0 else {
            throw Core.NativeImportContractError.invalid("maximum duration must be positive")
        }
        if effects.isAsync, !callbacks.isEmpty {
            throw Core.NativeImportContractError.invalid(
                "suspending native imports cannot carry callback parameters"
            )
        }
        if access == .io,
           execution.deadlineMode != (effects.isAsync ? .suspending : .cooperative) {
            throw Core.NativeImportContractError.invalid(
                effects.isAsync
                    ? "async I/O native imports must use suspending deadlines"
                    : "synchronous I/O native imports must use cooperative deadlines"
            )
        }
        switch execution.deadlineMode {
        case .bounded:
            guard execution.maximumDurationMicroseconds
                    <= Core.NativeImportExecutionPolicy.maximumBoundedDurationMicroseconds
            else {
                throw Core.NativeImportContractError.invalid(
                    "bounded native imports exceed the 2 ms qualification limit"
                )
            }
        case .cooperative:
            guard execution.maximumDurationMicroseconds
                    <= Core.NativeImportExecutionPolicy.maximumCooperativeDurationMicroseconds
            else {
                throw Core.NativeImportContractError.invalid(
                    "cooperative native imports exceed the 1 s qualification limit"
                )
            }
        case .suspending:
            guard execution.maximumDurationMicroseconds
                    <= Core.NativeImportExecutionPolicy.maximumSuspendingDurationMicroseconds
            else {
                throw Core.NativeImportContractError.invalid(
                    "suspending native imports exceed the 60 s qualification limit"
                )
            }
        }
        if execution.allowsMainThread, !effects.isAsync {
            guard execution.maximumDurationMicroseconds
                    <= Core.NativeImportExecutionPolicy.maximumMainThreadDurationMicroseconds
            else {
                throw Core.NativeImportContractError.invalid(
                    "main-thread native imports exceed the 16 ms qualification limit"
                )
            }
        }
        guard !effects.requiresMainActor || execution.allowsMainThread else {
            throw Core.NativeImportContractError.invalid(
                "MainActor native imports must allow main-thread execution"
            )
        }
        if domain == .uiKit {
            guard effects.requiresMainActor, execution.allowsMainThread else {
                throw Core.NativeImportContractError.invalid(
                    "UIKit native imports must be MainActor-bound"
                )
            }
        }
        switch kind {
        case .instanceGetter, .staticGetter, .instanceSubscriptGetter:
            guard access == .pure || access == .read else {
                throw Core.NativeImportContractError.invalid(
                    "getter native imports cannot declare state mutation"
                )
            }
        case .instanceSetter, .staticSetter, .instanceSubscriptSetter:
            guard access == .write || access == .readWrite else {
                throw Core.NativeImportContractError.invalid(
                    "setter native imports must declare state mutation"
                )
            }
        case .globalFunction, .initializer, .instanceMethod, .staticMethod, .serviceMethod:
            break
        }
    }

    private static func isValidDomain(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy { segment in
            guard let first = segment.utf8.first, (97...122).contains(first) else {
                return false
            }
            return segment.utf8.dropFirst().allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }
        }
    }
}

public enum NativeImportContractError: Swift.Error, Equatable, Sendable,
    CustomStringConvertible
{
    case invalid(String)

    public var description: String {
        switch self {
        case let .invalid(reason): "invalid native import contract: \(reason)"
        }
    }
}
}
