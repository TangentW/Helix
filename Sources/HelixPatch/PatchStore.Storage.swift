import Foundation
import HelixCore
import HelixRuntime

public enum PatchStore {}

extension PatchStore {
public struct PendingActivation: Codable, Hashable, Sendable {
    public var targetGenerationID: Runtime.GenerationID
    public var parentGenerationID: Runtime.GenerationID?
    public var packageID: String
    public var packageHash: Core.Digest
    public var signerKeyID: String
    public var nonce: UUID
    public var createdAtUnixSeconds: Int64

    public init(
        targetGenerationID: Runtime.GenerationID,
        parentGenerationID: Runtime.GenerationID?,
        packageID: String,
        packageHash: Core.Digest,
        signerKeyID: String,
        nonce: UUID = UUID(),
        createdAtUnixSeconds: Int64
    ) {
        self.targetGenerationID = targetGenerationID
        self.parentGenerationID = parentGenerationID
        self.packageID = packageID
        self.packageHash = packageHash
        self.signerKeyID = signerKeyID
        self.nonce = nonce
        self.createdAtUnixSeconds = createdAtUnixSeconds
    }
}

public struct ActiveState: Codable, Hashable, Sendable {
    public var generationID: Runtime.GenerationID
    public var parentGenerationID: Runtime.GenerationID?
    public var packageID: String
    public var packageHash: Core.Digest
    public var signerKeyID: String
    public var activationNonce: UUID
    public var committedAtUnixSeconds: Int64

    public init(
        generationID: Runtime.GenerationID,
        parentGenerationID: Runtime.GenerationID?,
        packageID: String,
        packageHash: Core.Digest,
        signerKeyID: String,
        activationNonce: UUID,
        committedAtUnixSeconds: Int64
    ) {
        self.generationID = generationID
        self.parentGenerationID = parentGenerationID
        self.packageID = packageID
        self.packageHash = packageHash
        self.signerKeyID = signerKeyID
        self.activationNonce = activationNonce
        self.committedAtUnixSeconds = committedAtUnixSeconds
    }
}

public struct ActiveHealth: Codable, Hashable, Sendable {
    public var generationID: Runtime.GenerationID
    public var packageHash: Core.Digest
    public var markedAtUnixSeconds: Int64

    public init(
        generationID: Runtime.GenerationID,
        packageHash: Core.Digest,
        markedAtUnixSeconds: Int64
    ) {
        self.generationID = generationID
        self.packageHash = packageHash
        self.markedAtUnixSeconds = markedAtUnixSeconds
    }
}

public struct Recovery: Hashable, Sendable {
    public var interruptedTarget: Runtime.GenerationID
    public var conservativeRollbackTarget: Runtime.GenerationID?
    public var packageID: String
    public var packageHash: Core.Digest

    public init(
        interruptedTarget: Runtime.GenerationID,
        conservativeRollbackTarget: Runtime.GenerationID?,
        packageID: String,
        packageHash: Core.Digest
    ) {
        self.interruptedTarget = interruptedTarget
        self.conservativeRollbackTarget = conservativeRollbackTarget
        self.packageID = packageID
        self.packageHash = packageHash
    }
}

public struct LocalBlock: Codable, Hashable, Sendable {
    public var packageHash: Core.Digest
    public var reasonCode: String
    public var detail: String
    public var blockedAtUnixSeconds: Int64

    public init(
        packageHash: Core.Digest,
        reasonCode: String,
        detail: String,
        blockedAtUnixSeconds: Int64
    ) {
        self.packageHash = packageHash
        self.reasonCode = reasonCode
        self.detail = detail
        self.blockedAtUnixSeconds = blockedAtUnixSeconds
    }
}

public struct RevocationState: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var highestSeenEpoch: UInt64
    public var revokedKeyIDs: Set<String>
    public var revokedPackageHashes: Set<Core.Digest>
    public var latestSnapshotHash: Core.Digest?

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        highestSeenEpoch: UInt64 = 0,
        revokedKeyIDs: Set<String> = [],
        revokedPackageHashes: Set<Core.Digest> = [],
        latestSnapshotHash: Core.Digest? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.highestSeenEpoch = highestSeenEpoch
        self.revokedKeyIDs = revokedKeyIDs
        self.revokedPackageHashes = revokedPackageHashes
        self.latestSnapshotHash = latestSnapshotHash
    }
}

public struct Quarantine: Codable, Hashable, Sendable {
    public var packageHash: Core.Digest
    public var reasonCode: String
    public var detail: String
    public var quarantinedAtUnixSeconds: Int64

    public init(
        packageHash: Core.Digest,
        reasonCode: String,
        detail: String,
        quarantinedAtUnixSeconds: Int64
    ) {
        self.packageHash = packageHash
        self.reasonCode = reasonCode
        self.detail = detail
        self.quarantinedAtUnixSeconds = quarantinedAtUnixSeconds
    }
}

public final class Storage: @unchecked Sendable {
    private struct Ledger: Codable {
        var records: [String: PatchPackage.AntiRollbackState] = [:]
    }

    private struct LocalBlockLedger: Codable {
        var records: [String: PatchStore.LocalBlock] = [:]
    }

    private struct RecoveryEvidence: Codable {
        var schemaVersion: UInt16 = 1
        var reasonCode: String
        var detail: String
        var recordedAtUnixSeconds: Int64
    }

    public let rootURL: URL
    public let incomingURL: URL
    public let verifiedURL: URL
    public let activeURL: URL
    public let quarantineURL: URL
    public let lastKnownGoodURL: URL

    private let fileManager: FileManager
    private let lock: NSLock

    private var pendingActivationURL: URL {
        activeURL.appendingPathComponent("pending-activation.json")
    }

    private var activeStateURL: URL {
        activeURL.appendingPathComponent("active-state.json")
    }

    private var ledgerURL: URL {
        activeURL.appendingPathComponent("anti-rollback.json")
    }

    private var localBlocksURL: URL {
        activeURL.appendingPathComponent("local-blocks.json")
    }

    private var revocationStateURL: URL {
        activeURL.appendingPathComponent("revocations.json")
    }

    private var activeHealthURL: URL {
        activeURL.appendingPathComponent("active-health.json")
    }

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        self.fileManager = fileManager
        lock = StorageLockPool.shared.lock(for: standardizedRoot.path)
        incomingURL = standardizedRoot.appendingPathComponent("incoming", isDirectory: true)
        verifiedURL = standardizedRoot.appendingPathComponent("verified", isDirectory: true)
        activeURL = standardizedRoot.appendingPathComponent("active", isDirectory: true)
        quarantineURL = standardizedRoot.appendingPathComponent("quarantine", isDirectory: true)
        lastKnownGoodURL = standardizedRoot.appendingPathComponent("last-known-good", isDirectory: true)

        for directory in [
            standardizedRoot, incomingURL, verifiedURL, activeURL, quarantineURL, lastKnownGoodURL,
        ] {
            try Self.ensureDirectory(directory, fileManager: fileManager)
            try Self.excludeFromBackup(directory)
        }
    }

    @discardableResult
    public func persistVerifiedPackage(
        _ bytes: Data,
        packageHash: Core.Digest
    ) throws -> URL {
        try lock.withLock {
            guard packageHash.constantTimeEquals(.sha256(bytes)) else {
                throw PatchPackage.Error.payloadHashMismatch("package")
            }
            let directory = verifiedURL.appendingPathComponent(
                packageHash.hex,
                isDirectory: true
            )
            try Self.ensureDirectory(directory, fileManager: fileManager)
            try Self.excludeFromBackup(directory)
            let destination = directory.appendingPathComponent("package.hlxp")
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try readRegularFile(destination, mapped: true)
                guard existing == bytes else {
                    throw PatchPackage.Error.activationPersistence(
                        "immutable verified package directory contains different bytes"
                    )
                }
                return destination
            }
            try atomicWrite(bytes, to: destination)
            return destination
        }
    }

    public func verifiedPackageBytes(packageHash: Core.Digest) throws -> Data {
        try lock.withLock {
            let url = verifiedURL
                .appendingPathComponent(packageHash.hex, isDirectory: true)
                .appendingPathComponent("package.hlxp")
            let bytes = try readRegularFile(url, mapped: true)
            guard packageHash.constantTimeEquals(.sha256(bytes)) else {
                throw PatchPackage.Error.payloadHashMismatch("stored package")
            }
            return bytes
        }
    }

    public func makeIncomingURL(downloadID: UUID) -> URL {
        incomingURL.appendingPathComponent("\(downloadID.uuidString.lowercased()).partial")
    }

    func openIncomingFile(downloadID: UUID) throws -> (URL, FileHandle) {
        try lock.withLock {
            let url = makeIncomingURL(downloadID: downloadID)
            guard !fileManager.fileExists(atPath: url.path) else {
                throw PatchPackage.Error.activationPersistence(
                    "incoming download ID already exists"
                )
            }
            guard fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            ) else {
                throw PatchPackage.Error.activationPersistence("cannot create incoming file")
            }
            do {
                try Self.excludeFromBackup(url)
                #if os(iOS)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
                #endif
                try synchronizeDirectory(incomingURL)
                return (url, try FileHandle(forWritingTo: url))
            } catch {
                try? fileManager.removeItem(at: url)
                throw error
            }
        }
    }

    func readIncomingFile(downloadID: UUID, maximumBytes: Int) throws -> Data {
        try lock.withLock {
            guard maximumBytes >= 0 else {
                throw PatchPackage.Error.limitExceeded("incoming package bytes")
            }
            let url = makeIncomingURL(downloadID: downloadID)
            try ensureRegularFile(url)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value >= 0,
                  size.uint64Value <= UInt64(maximumBytes)
            else {
                throw PatchPackage.Error.limitExceeded("incoming package bytes")
            }
            return try readRegularFile(url, mapped: true)
        }
    }

    public func removeIncoming(downloadID: UUID) throws {
        try lock.withLock {
            let url = makeIncomingURL(downloadID: downloadID)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                try synchronizeDirectory(incomingURL)
            }
        }
    }

    public func antiRollbackState(
        campaignID: String,
        shellInterfaceHash: Core.Digest
    ) throws -> PatchPackage.AntiRollbackState? {
        try lock.withLock {
            let ledger = try loadLedger()
            let state = ledger.records[Self.ledgerKey(
                campaignID: campaignID,
                shellInterfaceHash: shellInterfaceHash
            )]
            if let state {
                guard state.campaignID == campaignID,
                      state.shellInterfaceHash == shellInterfaceHash
                else {
                    throw PatchPackage.Error.activationPersistence(
                        "anti-rollback ledger identity mismatch"
                    )
                }
            }
            return state
        }
    }

    public func recordSeen(
        manifest: PatchPackage.Manifest,
        packageHash: Core.Digest,
        shellInterfaceHash: Core.Digest
    ) throws {
        try lock.withLock {
            var ledger = try loadLedger()
            let key = Self.ledgerKey(
                campaignID: manifest.campaignID,
                shellInterfaceHash: shellInterfaceHash
            )
            var state = ledger.records[key] ?? .init(
                campaignID: manifest.campaignID,
                shellInterfaceHash: shellInterfaceHash
            )
            guard state.campaignID == manifest.campaignID,
                  state.shellInterfaceHash == shellInterfaceHash
            else {
                throw PatchPackage.Error.activationPersistence(
                    "anti-rollback ledger identity mismatch"
                )
            }
            if manifest.revision < state.highestSeenRevision
                || (manifest.revision == state.highestSeenRevision
                    && state.highestSeenPackageHash != nil
                    && state.highestSeenPackageHash != packageHash)
            {
                throw PatchPackage.Error.rollbackRevision(
                    highestSeen: state.highestSeenRevision,
                    received: manifest.revision
                )
            }
            guard manifest.security.antiRollbackCounter >= state.highestSeenCounter else {
                throw PatchPackage.Error.rollbackRevision(
                    highestSeen: state.highestSeenCounter,
                    received: manifest.security.antiRollbackCounter
                )
            }
            guard manifest.security.emergencyPolicyEpoch >= state.emergencyPolicyEpoch else {
                throw PatchPackage.Error.emergencyPolicyRollback(
                    highestSeen: state.emergencyPolicyEpoch,
                    received: manifest.security.emergencyPolicyEpoch
                )
            }
            if manifest.revision > state.highestSeenRevision
                || state.highestSeenPackageHash == nil
            {
                state.highestSeenRevision = manifest.revision
                state.highestSeenPackageHash = packageHash
            }
            state.highestSeenCounter = max(
                state.highestSeenCounter,
                manifest.security.antiRollbackCounter
            )
            state.emergencyPolicyEpoch = max(
                state.emergencyPolicyEpoch,
                manifest.security.emergencyPolicyEpoch
            )
            ledger.records[key] = state
            try atomicWrite(try Core.CanonicalJSON.encode(ledger), to: ledgerURL)
        }
    }

    public func revoke(
        packageHash: Core.Digest,
        campaignID: String,
        shellInterfaceHash: Core.Digest
    ) throws {
        try lock.withLock {
            var ledger = try loadLedger()
            let key = Self.ledgerKey(
                campaignID: campaignID,
                shellInterfaceHash: shellInterfaceHash
            )
            var state = ledger.records[key] ?? .init(
                campaignID: campaignID,
                shellInterfaceHash: shellInterfaceHash
            )
            guard state.campaignID == campaignID,
                  state.shellInterfaceHash == shellInterfaceHash
            else {
                throw PatchPackage.Error.activationPersistence(
                    "anti-rollback ledger identity mismatch"
                )
            }
            state.revokedPackageHashes.insert(packageHash)
            ledger.records[key] = state
            try atomicWrite(try Core.CanonicalJSON.encode(ledger), to: ledgerURL)
        }
    }

    public func beginActivation(_ record: PatchStore.PendingActivation) throws {
        try lock.withLock {
            try validate(record)
            if fileManager.fileExists(atPath: pendingActivationURL.path) {
                let existing: PatchStore.PendingActivation = try decode(pendingActivationURL)
                try validate(existing)
                guard existing == record else {
                    throw PatchPackage.Error.activationPersistence(
                        "another activation transaction is pending"
                    )
                }
                return
            }
            let active: PatchStore.ActiveState? = fileManager.fileExists(atPath: activeStateURL.path)
                ? try decode(activeStateURL)
                : nil
            if let active { try validate(active) }
            guard active?.generationID == record.parentGenerationID else {
                throw PatchPackage.Error.activationPersistence(
                    "persistent active generation does not match activation parent"
                )
            }
            if let active {
                guard fileManager.fileExists(atPath: activeHealthURL.path) else {
                    throw PatchPackage.Error.activationPersistence(
                        "active parent has not been marked healthy"
                    )
                }
                let health: PatchStore.ActiveHealth = try decode(activeHealthURL)
                guard health.generationID == active.generationID,
                      health.packageHash == active.packageHash
                else {
                    throw PatchPackage.Error.activationPersistence(
                        "active health proof does not match the parent"
                    )
                }
            }
            try atomicWrite(try Core.CanonicalJSON.encode(record), to: pendingActivationURL)
        }
    }

    public func commitActivation(_ state: PatchStore.ActiveState) throws {
        try lock.withLock {
            try validate(state)
            if !fileManager.fileExists(atPath: pendingActivationURL.path) {
                let active: PatchStore.ActiveState? = fileManager.fileExists(atPath: activeStateURL.path)
                    ? try decode(activeStateURL)
                    : nil
                guard active == state else {
                    throw PatchPackage.Error.activationPersistence(
                        "activation commit has no matching pending transaction"
                    )
                }
                return
            }
            let pending: PatchStore.PendingActivation = try decode(pendingActivationURL)
            guard pending.nonce == state.activationNonce,
                  pending.targetGenerationID == state.generationID,
                  pending.parentGenerationID == state.parentGenerationID,
                  pending.packageID == state.packageID,
                  pending.packageHash == state.packageHash,
                  pending.signerKeyID == state.signerKeyID
            else {
                throw PatchPackage.Error.activationPersistence(
                    "commit does not match pending activation"
                )
            }
            let previous: PatchStore.ActiveState? = fileManager.fileExists(atPath: activeStateURL.path)
                ? try decode(activeStateURL)
                : nil
            if let previous { try validate(previous) }
            guard previous?.generationID == state.parentGenerationID else {
                throw PatchPackage.Error.activationPersistence(
                    "activation parent changed before commit"
                )
            }
            let lastKnownGoodStateURL = lastKnownGoodURL.appendingPathComponent("active-state.json")
            if let previous {
                try atomicWrite(
                    try Core.CanonicalJSON.encode(previous),
                    to: lastKnownGoodStateURL
                )
            } else if fileManager.fileExists(atPath: lastKnownGoodStateURL.path) {
                try fileManager.removeItem(at: lastKnownGoodStateURL)
                try synchronizeDirectory(lastKnownGoodURL)
            }
            try atomicWrite(try Core.CanonicalJSON.encode(state), to: activeStateURL)
            if fileManager.fileExists(atPath: activeHealthURL.path) {
                try? fileManager.removeItem(at: activeHealthURL)
            }
            // Once active-state is durable, a stale matching pending record is
            // harmless: launch recovery recognizes the nonce as committed.
            try? fileManager.removeItem(at: pendingActivationURL)
            try synchronizeDirectory(activeURL)
        }
    }

    func isActivationCommitted(_ state: PatchStore.ActiveState) throws -> Bool {
        try lock.withLock {
            guard fileManager.fileExists(atPath: activeStateURL.path) else { return false }
            let active: PatchStore.ActiveState = try decode(activeStateURL)
            try validate(active)
            return active == state
        }
    }

    public func activeState() throws -> PatchStore.ActiveState? {
        try lock.withLock {
            guard fileManager.fileExists(atPath: activeStateURL.path) else { return nil }
            let state: PatchStore.ActiveState = try decode(activeStateURL)
            try validate(state)
            return state
        }
    }

    public func markActiveHealthy(
        expectedActiveID: Runtime.GenerationID,
        nowUnixSeconds: Int64
    ) throws {
        try lock.withLock {
            guard !fileManager.fileExists(atPath: pendingActivationURL.path) else {
                throw PatchPackage.Error.activationPersistence(
                    "cannot mark health during an activation transaction"
                )
            }
            guard fileManager.fileExists(atPath: activeStateURL.path) else {
                throw PatchPackage.Error.activationPersistence("active state is missing")
            }
            let active: PatchStore.ActiveState = try decode(activeStateURL)
            try validate(active)
            guard active.generationID == expectedActiveID else {
                throw PatchPackage.Error.activationPersistence(
                    "active generation changed before health marking"
                )
            }
            try atomicWrite(
                try Core.CanonicalJSON.encode(
                    PatchStore.ActiveHealth(
                        generationID: active.generationID,
                        packageHash: active.packageHash,
                        markedAtUnixSeconds: nowUnixSeconds
                    )
                ),
                to: activeHealthURL
            )
        }
    }

    func markLaunchHealthy(
        journalName: String,
        sessionNonce: UUID,
        nowUnixSeconds: Int64
    ) throws {
        try lock.withLock {
            guard !fileManager.fileExists(atPath: pendingActivationURL.path) else {
                throw PatchPackage.Error.activationPersistence(
                    "cannot mark health during an activation transaction"
                )
            }
            let journalURL = try internalStateURL(name: journalName)
            guard fileManager.fileExists(atPath: journalURL.path) else {
                throw PatchPackage.Error.activationPersistence("Crash Guard journal is missing")
            }
            var journal: CrashProtection.Journal = try decode(journalURL)
            guard journal.sessionNonce == sessionNonce, journal.health == .launching else {
                throw PatchPackage.Error.activationPersistence("stale Crash Guard session nonce")
            }
            if let generationID = journal.activeGenerationID {
                guard fileManager.fileExists(atPath: activeStateURL.path) else {
                    throw PatchPackage.Error.activationPersistence("active state is missing")
                }
                let active: PatchStore.ActiveState = try decode(activeStateURL)
                try validate(active)
                guard active.generationID == generationID,
                      journal.activePackageHash == active.packageHash
                else {
                    throw PatchPackage.Error.activationPersistence(
                        "Crash Guard journal does not match active state"
                    )
                }
                // Write the proof first. A crash between these writes may cause
                // one conservative extra rollback, never an unproven parent.
                try atomicWrite(
                    try Core.CanonicalJSON.encode(
                        PatchStore.ActiveHealth(
                            generationID: active.generationID,
                            packageHash: active.packageHash,
                            markedAtUnixSeconds: nowUnixSeconds
                        )
                    ),
                    to: activeHealthURL
                )
            }
            journal.health = .healthy
            journal.consecutiveUncleanLaunches = 0
            journal.updatedAtUnixSeconds = nowUnixSeconds
            try atomicWrite(try Core.CanonicalJSON.encode(journal), to: journalURL)
        }
    }

    public func rollbackToLastKnownGood(
        expectedActiveID: Runtime.GenerationID
    ) throws -> PatchStore.ActiveState? {
        try lock.withLock {
            guard fileManager.fileExists(atPath: activeStateURL.path) else {
                throw PatchPackage.Error.activationPersistence("active state is missing during rollback")
            }
            let active: PatchStore.ActiveState = try decode(activeStateURL)
            try validate(active)
            guard active.generationID == expectedActiveID else {
                throw PatchPackage.Error.activationPersistence(
                    "persistent active generation changed before rollback"
                )
            }
            let lastKnownGoodStateURL = lastKnownGoodURL.appendingPathComponent("active-state.json")
            let target: PatchStore.ActiveState?
            if fileManager.fileExists(atPath: lastKnownGoodStateURL.path) {
                let candidate: PatchStore.ActiveState = try decode(lastKnownGoodStateURL)
                try validate(candidate)
                if candidate == active {
                    // A previous rollback published the parent but crashed
                    // before deleting its LKG pointer. Finish that transaction
                    // instead of attempting to roll the parent back again.
                    try writeHealthProof(for: candidate)
                    try fileManager.removeItem(at: lastKnownGoodStateURL)
                    try synchronizeDirectory(lastKnownGoodURL)
                    return candidate
                }
                guard candidate.generationID == active.parentGenerationID else {
                    throw PatchPackage.Error.activationPersistence(
                        "last-known-good state does not match active parent"
                    )
                }
                try atomicWrite(try Core.CanonicalJSON.encode(candidate), to: activeStateURL)
                try writeHealthProof(for: candidate)
                target = candidate
            } else {
                if fileManager.fileExists(atPath: activeStateURL.path) {
                    try fileManager.removeItem(at: activeStateURL)
                }
                try synchronizeDirectory(activeURL)
                if fileManager.fileExists(atPath: activeHealthURL.path) {
                    try fileManager.removeItem(at: activeHealthURL)
                    try synchronizeDirectory(activeURL)
                }
                target = nil
            }
            if fileManager.fileExists(atPath: lastKnownGoodStateURL.path) {
                try fileManager.removeItem(at: lastKnownGoodStateURL)
                try synchronizeDirectory(lastKnownGoodURL)
            }
            return target
        }
    }

    func resetActivationStatePreservingEvidence(
        reasonCode: String,
        detail: String,
        nowUnixSeconds: Int64
    ) throws {
        try lock.withLock {
            let evidenceURL = try makeRecoveryEvidenceDirectory(
                reasonCode: reasonCode,
                detail: detail,
                nowUnixSeconds: nowUnixSeconds
            )
            let lastKnownGoodStateURL = lastKnownGoodURL.appendingPathComponent("active-state.json")
            // Move the active pointer first. If the process dies during this
            // recovery, the next launch cannot mistake a partly reset state
            // for an executable generation.
            for (source, evidenceName) in [
                (activeStateURL, "active-state.json"),
                (pendingActivationURL, "pending-activation.json"),
                (activeHealthURL, "active-health.json"),
                (lastKnownGoodStateURL, "last-known-good-state.json"),
            ] where pathEntryExists(source) {
                try fileManager.moveItem(
                    at: source,
                    to: evidenceURL.appendingPathComponent(evidenceName)
                )
            }
            try synchronizeDirectory(activeURL)
            try synchronizeDirectory(lastKnownGoodURL)
            try synchronizeDirectory(evidenceURL)
            try synchronizeDirectory(quarantineURL)
        }
    }

    func discardInternalStatePreservingEvidence(
        name: String,
        reasonCode: String,
        detail: String,
        nowUnixSeconds: Int64
    ) throws {
        try lock.withLock {
            let source = try internalStateURL(name: name)
            guard pathEntryExists(source) else { return }
            let evidenceURL = try makeRecoveryEvidenceDirectory(
                reasonCode: reasonCode,
                detail: detail,
                nowUnixSeconds: nowUnixSeconds
            )
            try fileManager.moveItem(
                at: source,
                to: evidenceURL.appendingPathComponent(name)
            )
            try synchronizeDirectory(activeURL)
            try synchronizeDirectory(evidenceURL)
            try synchronizeDirectory(quarantineURL)
        }
    }

    public func recoverInterruptedActivation() throws -> PatchStore.Recovery? {
        try lock.withLock {
            guard fileManager.fileExists(atPath: pendingActivationURL.path) else { return nil }
            let pending: PatchStore.PendingActivation = try decode(pendingActivationURL)
            try validate(pending)
            let active: PatchStore.ActiveState? = fileManager.fileExists(atPath: activeStateURL.path)
                ? try decode(activeStateURL)
                : nil
            if let active { try validate(active) }
            try fileManager.removeItem(at: pendingActivationURL)
            try synchronizeDirectory(activeURL)
            guard active?.activationNonce != pending.nonce
                    || active?.generationID != pending.targetGenerationID
                    || active?.packageHash != pending.packageHash
            else {
                return nil
            }
            return .init(
                interruptedTarget: pending.targetGenerationID,
                conservativeRollbackTarget: pending.parentGenerationID,
                packageID: pending.packageID,
                packageHash: pending.packageHash
            )
        }
    }

    public func localBlock(for packageHash: Core.Digest) throws -> PatchStore.LocalBlock? {
        try lock.withLock {
            try loadLocalBlocks().records[packageHash.hex]
        }
    }

    public func blockLocally(_ record: PatchStore.LocalBlock) throws {
        try lock.withLock {
            guard !record.reasonCode.isEmpty else {
                throw PatchPackage.Error.activationPersistence("local block reason is empty")
            }
            var ledger = try loadLocalBlocks()
            if let existing = ledger.records[record.packageHash.hex] {
                guard existing.packageHash == record.packageHash else {
                    throw PatchPackage.Error.activationPersistence("local block hash key mismatch")
                }
                return
            }
            ledger.records[record.packageHash.hex] = record
            try atomicWrite(try Core.CanonicalJSON.encode(ledger), to: localBlocksURL)
        }
    }

    public func revocationState() throws -> PatchStore.RevocationState {
        try lock.withLock {
            guard fileManager.fileExists(atPath: revocationStateURL.path) else { return .init() }
            let state: PatchStore.RevocationState = try decode(revocationStateURL)
            try validate(state)
            return state
        }
    }

    func recordVerifiedRevocation(
        snapshot: PatchPackage.RevocationSnapshot,
        effectiveTrustStore: PatchPackage.TrustStore
    ) throws {
        try lock.withLock {
            let existing: PatchStore.RevocationState
            if fileManager.fileExists(atPath: revocationStateURL.path) {
                existing = try decode(revocationStateURL)
                try validate(existing)
            } else {
                existing = .init()
            }
            guard snapshot.epoch >= existing.highestSeenEpoch else {
                throw PatchPackage.Error.revocationEpochRollback(
                    highestSeen: existing.highestSeenEpoch,
                    received: snapshot.epoch
                )
            }
            if snapshot.epoch == existing.highestSeenEpoch {
                guard effectiveTrustStore.revokedKeyIDs.isSubset(of: existing.revokedKeyIDs),
                      effectiveTrustStore.revokedPackageHashes.isSubset(of: existing.revokedPackageHashes)
                else {
                    throw PatchPackage.Error.invalidRevocationSnapshot(
                        "persisted revocation epoch has conflicting contents"
                    )
                }
                return
            }
            let state = PatchStore.RevocationState(
                highestSeenEpoch: snapshot.epoch,
                revokedKeyIDs: effectiveTrustStore.revokedKeyIDs,
                revokedPackageHashes: effectiveTrustStore.revokedPackageHashes,
                latestSnapshotHash: .sha256(try Core.CanonicalJSON.encode(snapshot))
            )
            try atomicWrite(try Core.CanonicalJSON.encode(state), to: revocationStateURL)
        }
    }

    public func quarantine(_ record: PatchStore.Quarantine) throws {
        try lock.withLock {
            let directory = quarantineURL.appendingPathComponent(
                record.packageHash.hex,
                isDirectory: true
            )
            try Self.ensureDirectory(directory, fileManager: fileManager)
            try Self.excludeFromBackup(directory)
            try atomicWrite(
                try Core.CanonicalJSON.encode(record),
                to: directory.appendingPathComponent("reason.json")
            )
        }
    }

    func readInternalState<T: Codable>(_ type: T.Type, name: String) throws -> T? {
        try lock.withLock {
            let url = try internalStateURL(name: name)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try decode(url)
        }
    }

    func writeInternalState<T: Codable>(_ value: T, name: String) throws {
        try lock.withLock {
            try atomicWrite(
                try Core.CanonicalJSON.encode(value),
                to: try internalStateURL(name: name)
            )
        }
    }

    func updateInternalState<T: Codable, Result>(
        _ type: T.Type,
        name: String,
        _ update: (inout T?) throws -> Result
    ) throws -> Result {
        try lock.withLock {
            let url = try internalStateURL(name: name)
            var value: T? = fileManager.fileExists(atPath: url.path) ? try decode(url) : nil
            let result = try update(&value)
            if let value {
                try atomicWrite(try Core.CanonicalJSON.encode(value), to: url)
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                try synchronizeDirectory(activeURL)
            }
            return result
        }
    }

    private func loadLedger() throws -> Ledger {
        guard fileManager.fileExists(atPath: ledgerURL.path) else { return Ledger() }
        return try decode(ledgerURL)
    }

    private func loadLocalBlocks() throws -> LocalBlockLedger {
        guard fileManager.fileExists(atPath: localBlocksURL.path) else { return .init() }
        return try decode(localBlocksURL)
    }

    private func internalStateURL(name: String) throws -> URL {
        guard !name.isEmpty,
              name.utf8.count <= 128,
              !name.contains("/"),
              name != ".",
              name != ".."
        else {
            throw PatchPackage.Error.activationPersistence("invalid internal state name")
        }
        return activeURL.appendingPathComponent(name)
    }

    private func writeHealthProof(for state: PatchStore.ActiveState) throws {
        try atomicWrite(
            try Core.CanonicalJSON.encode(
                PatchStore.ActiveHealth(
                    generationID: state.generationID,
                    packageHash: state.packageHash,
                    markedAtUnixSeconds: state.committedAtUnixSeconds
                )
            ),
            to: activeHealthURL
        )
    }

    private func makeRecoveryEvidenceDirectory(
        reasonCode: String,
        detail: String,
        nowUnixSeconds: Int64
    ) throws -> URL {
        let directory = quarantineURL.appendingPathComponent(
            "state-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try Self.ensureDirectory(directory, fileManager: fileManager)
        try Self.excludeFromBackup(directory)
        try atomicWrite(
            try Core.CanonicalJSON.encode(
                RecoveryEvidence(
                    reasonCode: String(reasonCode.prefix(128)),
                    detail: String(detail.prefix(4_096)),
                    recordedAtUnixSeconds: nowUnixSeconds
                )
            ),
            to: directory.appendingPathComponent("reason.json")
        )
        return directory
    }

    private func pathEntryExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func validate(_ record: PatchStore.PendingActivation) throws {
        guard record.targetGenerationID.rawValue > 0,
              record.targetGenerationID != record.parentGenerationID,
              !record.packageID.isEmpty,
              !record.signerKeyID.isEmpty
        else {
            throw PatchPackage.Error.activationPersistence("invalid pending activation record")
        }
    }

    private func validate(_ state: PatchStore.ActiveState) throws {
        guard state.generationID.rawValue > 0,
              state.generationID != state.parentGenerationID,
              !state.packageID.isEmpty,
              !state.signerKeyID.isEmpty
        else {
            throw PatchPackage.Error.activationPersistence("invalid active state")
        }
    }

    private func validate(_ state: PatchStore.RevocationState) throws {
        guard state.schemaVersion == PatchStore.RevocationState.currentSchemaVersion,
              !state.revokedKeyIDs.contains("")
        else {
            throw PatchPackage.Error.activationPersistence("invalid persisted revocation state")
        }
    }

    private func decode<T: Codable>(_ url: URL) throws -> T {
        do {
            let bytes = try readRegularFile(url)
            let value = try JSONDecoder().decode(T.self, from: bytes)
            guard try Core.CanonicalJSON.encode(value) == bytes else {
                throw PatchPackage.Error.activationPersistence(
                    "non-canonical or unknown fields in \(url.lastPathComponent)"
                )
            }
            return value
        } catch let error as PatchPackage.Error {
            throw error
        } catch {
            throw PatchPackage.Error.activationPersistence(
                "cannot decode \(url.lastPathComponent): \(error)"
            )
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        do {
            try Self.ensureDirectory(
                destination.deletingLastPathComponent(),
                fileManager: fileManager
            )
            if fileManager.fileExists(atPath: destination.path) {
                try ensureRegularFile(destination)
            }
            try data.write(to: destination, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: destination.path
            )
            let handle = try FileHandle(forWritingTo: destination)
            try handle.synchronize()
            try handle.close()
            try Self.excludeFromBackup(destination)
            #if os(iOS)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            #endif
            try synchronizeDirectory(destination.deletingLastPathComponent())
        } catch let error as PatchPackage.Error {
            throw error
        } catch {
            throw PatchPackage.Error.activationPersistence(
                "cannot write \(destination.lastPathComponent): \(error)"
            )
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        // Foundation does not guarantee directory synchronization on Darwin.
        // It can report Cocoa error 512 with no POSIX error on both Simulator
        // and device filesystems. The file itself was already fsynced above;
        // directory sync is therefore a best-effort durability strengthening.
        guard let handle = try? FileHandle(forReadingFrom: directory) else { return }
        try? handle.synchronize()
        try? handle.close()
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        #if os(iOS)
        try mutableURL.setResourceValues(values)
        #else
        try? mutableURL.setResourceValues(values)
        #endif
    }

    private func readRegularFile(_ url: URL, mapped: Bool = false) throws -> Data {
        try ensureRegularFile(url)
        do {
            return try Data(contentsOf: url, options: mapped ? [.mappedIfSafe] : [])
        } catch {
            throw PatchPackage.Error.activationPersistence(
                "cannot read \(url.lastPathComponent): \(error)"
            )
        }
    }

    private func ensureRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard values.isSymbolicLink != true,
              attributes[.type] as? FileAttributeType == .typeRegular
        else {
            throw PatchPackage.Error.activationPersistence(
                "\(url.lastPathComponent) is not a regular file"
            )
        }
    }

    private static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard values.isSymbolicLink != true,
                  attributes[.type] as? FileAttributeType == .typeDirectory
            else {
                throw PatchPackage.Error.activationPersistence(
                    "\(url.lastPathComponent) is not a directory"
                )
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private static func ledgerKey(
        campaignID: String,
        shellInterfaceHash: Core.Digest
    ) -> String {
        "\(campaignID)\u{0}\(shellInterfaceHash.hex)"
    }
}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private final class StorageLockPool: @unchecked Sendable {
    static let shared = StorageLockPool()

    private let lock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for path: String) -> NSLock {
        lock.withLock {
            if let existing = locks[path] { return existing }
            let created = NSLock()
            locks[path] = created
            return created
        }
    }
}

extension PatchStore.RevocationState {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, highestSeenEpoch, revokedKeyIDs
        case revokedPackageHashes, latestSnapshotHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        highestSeenEpoch = try container.decode(UInt64.self, forKey: .highestSeenEpoch)
        let keyIDs = try container.decode([String].self, forKey: .revokedKeyIDs)
        let hashes = try container.decode([Core.Digest].self, forKey: .revokedPackageHashes)
        guard Set(keyIDs).count == keyIDs.count, Set(hashes).count == hashes.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .revokedKeyIDs,
                in: container,
                debugDescription: "duplicate persisted revocation"
            )
        }
        revokedKeyIDs = Set(keyIDs)
        revokedPackageHashes = Set(hashes)
        latestSnapshotHash = try container.decodeIfPresent(
            Core.Digest.self,
            forKey: .latestSnapshotHash
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(highestSeenEpoch, forKey: .highestSeenEpoch)
        try container.encode(revokedKeyIDs.sorted(), forKey: .revokedKeyIDs)
        try container.encode(revokedPackageHashes.sorted(), forKey: .revokedPackageHashes)
        try container.encodeIfPresent(latestSnapshotHash, forKey: .latestSnapshotHash)
    }
}
