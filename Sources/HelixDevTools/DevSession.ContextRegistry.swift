import Foundation
import HelixCore
import HelixDevProtocol

extension DevSession {
/// Actor-isolated exact-build index shared by CLI and Helix Hub frontends.
public actor ContextRegistry {
    public struct Limits: Hashable, Sendable {
        /// Default retention suitable for several active Xcode workspaces.
        public static let standard = Self(
            validatedMaximumContexts: 512,
            maximumContextsPerWorkspace: 64
        )

        /// Maximum retained contexts across every workspace.
        public var maximumContexts: Int
        /// Maximum retained contexts for any one workspace.
        public var maximumContextsPerWorkspace: Int

        /// Creates validated retention limits.
        public init(
            maximumContexts: Int = 512,
            maximumContextsPerWorkspace: Int = 64
        ) throws {
            guard (1...4_096).contains(maximumContexts),
                  (1...maximumContexts).contains(maximumContextsPerWorkspace)
            else {
                throw DevSession.ContextError.invalidValue
            }
            self.maximumContexts = maximumContexts
            self.maximumContextsPerWorkspace = maximumContextsPerWorkspace
        }

        private init(
            validatedMaximumContexts: Int,
            maximumContextsPerWorkspace: Int
        ) {
            maximumContexts = validatedMaximumContexts
            self.maximumContextsPerWorkspace = maximumContextsPerWorkspace
        }
    }

    private let limits: Limits
    private var contextsByShell: [DevProtocol.ShellID: DevSession.BuildContext] = [:]
    private var shellByBuild: [DevProtocol.PeerBuildIdentity: DevProtocol.ShellID] = [:]

    /// Reconstructs a registry from a validated persisted snapshot.
    public init(
        contexts: [DevSession.BuildContext] = [],
        limits: Limits = .standard
    ) throws {
        self.limits = limits
        for context in contexts.sorted(by: Self.oldestFirst) {
            try Self.insert(
                context,
                contextsByShell: &contextsByShell,
                shellByBuild: &shellByBuild
            )
        }
        Self.enforceLimits(
            contextsByShell: &contextsByShell,
            shellByBuild: &shellByBuild,
            limits: limits
        )
    }

    /// Inserts or refreshes one exact Shell. Returns `false` for stale/no-op input.
    @discardableResult
    public func register(_ context: DevSession.BuildContext) throws -> Bool {
        try context.validate()
        let shellID = context.shellIdentity.shellID
        if let existing = contextsByShell[shellID] {
            guard existing.shellIdentity == context.shellIdentity else {
                throw DevSession.ContextError.shellIdentityCollision
            }
            guard existing.workspacePathHash == context.workspacePathHash,
                  existing.workspacePath == context.workspacePath,
                  existing.scheme == context.scheme,
                  existing.buildConfiguration == context.buildConfiguration,
                  existing.moduleName == context.moduleName
            else {
                throw DevSession.ContextError.shellIdentityCollision
            }
            guard context.registeredAt >= existing.registeredAt else { return false }
            if existing == context { return false }
        }
        if let existingShell = shellByBuild[context.shellIdentity.build],
           existingShell != shellID {
            guard let existing = contextsByShell[existingShell],
                  existing.workspacePathHash == context.workspacePathHash,
                  existing.workspacePath == context.workspacePath,
                  existing.scheme == context.scheme,
                  existing.buildConfiguration == context.buildConfiguration,
                  existing.moduleName == context.moduleName,
                  context.registeredAt >= existing.registeredAt
            else {
                throw DevSession.ContextError.buildIdentityCollision
            }
            // A tool upgrade may revise the deterministic Shell-ID domain.
            // Rotating an otherwise identical exact-build context is safe and
            // keeps the peer-build lookup single-valued.
            contextsByShell[existingShell] = nil
        }
        contextsByShell[shellID] = context
        shellByBuild[context.shellIdentity.build] = shellID
        enforceLimits()
        return contextsByShell[shellID] == context
    }

    /// Registers and persists one context as a single actor-isolated transaction.
    ///
    /// If the atomic file write fails, the complete in-memory index—including
    /// entries removed by retention limits—is restored before the error escapes.
    @discardableResult
    public func register(
        _ context: DevSession.BuildContext,
        persistingTo store: DevSession.ContextStore
    ) throws -> Bool {
        let previousContexts = contextsByShell
        let previousBuilds = shellByBuild
        do {
            let changed = try register(context)
            guard changed else { return false }
            try store.save(contexts())
            return true
        } catch {
            contextsByShell = previousContexts
            shellByBuild = previousBuilds
            throw error
        }
    }

    /// Finds the only context matching the exact App build facts.
    public func resolve(
        _ build: DevProtocol.PeerBuildIdentity
    ) -> DevSession.BuildContext? {
        guard let shellID = shellByBuild[build] else { return nil }
        return contextsByShell[shellID]
    }

    /// Finds one context by its build-scoped Shell identifier.
    public func context(
        shellID: DevProtocol.ShellID
    ) -> DevSession.BuildContext? {
        contextsByShell[shellID]
    }

    /// Returns newest-first contexts, optionally restricted to one workspace.
    public func contexts(
        workspacePathHash: Core.Digest? = nil
    ) -> [DevSession.BuildContext] {
        contextsByShell.values
            .filter { workspacePathHash == nil || $0.workspacePathHash == workspacePathHash }
            .sorted(by: Self.newestFirst)
    }

    /// Removes one Shell from both exact-match indexes.
    @discardableResult
    public func remove(shellID: DevProtocol.ShellID) -> DevSession.BuildContext? {
        guard let removed = contextsByShell.removeValue(forKey: shellID) else {
            return nil
        }
        shellByBuild[removed.shellIdentity.build] = nil
        return removed
    }

    /// Removes and persists one context, rolling the index back on write failure.
    @discardableResult
    public func remove(
        shellID: DevProtocol.ShellID,
        persistingTo store: DevSession.ContextStore
    ) throws -> DevSession.BuildContext? {
        let previousContexts = contextsByShell
        let previousBuilds = shellByBuild
        guard let removed = remove(shellID: shellID) else { return nil }
        do {
            try store.save(contexts())
            return removed
        } catch {
            contextsByShell = previousContexts
            shellByBuild = previousBuilds
            throw error
        }
    }

    /// Removes contexts older than the supplied cutoff.
    public func prune(registeredBefore cutoff: Date) -> Int {
        let doomed = contextsByShell.values
            .filter { $0.registeredAt < cutoff }
            .map(\.shellIdentity.shellID)
        doomed.forEach { _ = remove(shellID: $0) }
        return doomed.count
    }

    /// Restores a previously validated snapshot after a larger transaction
    /// fails. The complete index is replaced so retention evictions are also
    /// rolled back, not only the newly inserted Shell.
    func restoreTransactionSnapshot(
        _ contexts: [DevSession.BuildContext],
        persistingTo store: DevSession.ContextStore?
    ) throws {
        var restoredByShell: [DevProtocol.ShellID: DevSession.BuildContext] = [:]
        var restoredByBuild: [DevProtocol.PeerBuildIdentity: DevProtocol.ShellID] = [:]
        for context in contexts.sorted(by: Self.oldestFirst) {
            try Self.insert(
                context,
                contextsByShell: &restoredByShell,
                shellByBuild: &restoredByBuild
            )
        }
        Self.enforceLimits(
            contextsByShell: &restoredByShell,
            shellByBuild: &restoredByBuild,
            limits: limits
        )
        if let store {
            try store.save(restoredByShell.values.sorted(by: Self.newestFirst))
        }
        contextsByShell = restoredByShell
        shellByBuild = restoredByBuild
    }

    private static func insert(
        _ context: DevSession.BuildContext,
        contextsByShell: inout [DevProtocol.ShellID: DevSession.BuildContext],
        shellByBuild: inout [DevProtocol.PeerBuildIdentity: DevProtocol.ShellID]
    ) throws {
        try context.validate()
        let shellID = context.shellIdentity.shellID
        guard contextsByShell[shellID] == nil else {
            throw DevSession.ContextError.shellIdentityCollision
        }
        guard shellByBuild[context.shellIdentity.build] == nil else {
            throw DevSession.ContextError.buildIdentityCollision
        }
        contextsByShell[shellID] = context
        shellByBuild[context.shellIdentity.build] = shellID
    }

    private func enforceLimits() {
        Self.enforceLimits(
            contextsByShell: &contextsByShell,
            shellByBuild: &shellByBuild,
            limits: limits
        )
    }

    private static func enforceLimits(
        contextsByShell: inout [DevProtocol.ShellID: DevSession.BuildContext],
        shellByBuild: inout [DevProtocol.PeerBuildIdentity: DevProtocol.ShellID],
        limits: Limits
    ) {
        func remove(_ context: DevSession.BuildContext) {
            contextsByShell[context.shellIdentity.shellID] = nil
            shellByBuild[context.shellIdentity.build] = nil
        }
        let workspaces = Dictionary(grouping: contextsByShell.values, by: \.workspacePathHash)
        for contexts in workspaces.values where contexts.count > limits.maximumContextsPerWorkspace {
            for context in contexts.sorted(by: Self.oldestFirst)
                .dropLast(limits.maximumContextsPerWorkspace) {
                remove(context)
            }
        }
        if contextsByShell.count > limits.maximumContexts {
            for context in contextsByShell.values.sorted(by: Self.oldestFirst)
                .dropLast(limits.maximumContexts) {
                remove(context)
            }
        }
    }

    private static func newestFirst(
        _ lhs: DevSession.BuildContext,
        _ rhs: DevSession.BuildContext
    ) -> Bool {
        if lhs.registeredAt != rhs.registeredAt { return lhs.registeredAt > rhs.registeredAt }
        return lhs.shellIdentity.shellID.rawValue.uuidString
            < rhs.shellIdentity.shellID.rawValue.uuidString
    }

    private static func oldestFirst(
        _ lhs: DevSession.BuildContext,
        _ rhs: DevSession.BuildContext
    ) -> Bool {
        newestFirst(rhs, lhs)
    }
}
}
