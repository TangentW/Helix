#if os(macOS)
import Darwin
import Foundation
import HelixCore

extension Hub {
public struct ProjectRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var projectURL: URL
    public var hostPlanURL: URL
    public var capabilities: [Hub.Capability]
    public var requirements: [Hub.Requirement]
    public var configuredAt: Date

    public init(
        name: String,
        projectURL: URL,
        hostPlanURL: URL,
        capabilities: [Hub.Capability],
        requirements: [Hub.Requirement],
        configuredAt: Date = Date()
    ) throws {
        self.name = name
        self.projectURL = projectURL.standardizedFileURL
        self.hostPlanURL = hostPlanURL.standardizedFileURL
        self.capabilities = Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue }
        self.requirements = requirements.sorted { $0.code < $1.code }
        self.configuredAt = configuredAt
        id = Self.identifier(for: self.projectURL)
        try validate()
    }

    public func validate() throws {
        let projectPath = projectURL.standardizedFileURL.path
        let sourceRoot = projectURL.deletingLastPathComponent().standardizedFileURL.path
        let planPath = hostPlanURL.standardizedFileURL.path
        guard id == Self.identifier(for: projectURL),
              projectURL.isFileURL, hostPlanURL.isFileURL,
              projectURL == projectURL.standardizedFileURL,
              hostPlanURL == hostPlanURL.standardizedFileURL,
              projectPath.hasPrefix("/"), planPath.hasPrefix(sourceRoot + "/"),
              projectURL.pathExtension.lowercased() == "xcodeproj",
              !name.isEmpty, name.utf8.count <= 1_024,
              !capabilities.isEmpty,
              capabilities == Array(Set(capabilities)).sorted(by: { $0.rawValue < $1.rawValue }),
              requirements.count <= 1_024,
              requirements == requirements.sorted(by: { $0.code < $1.code }),
              configuredAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw Hub.Error.storageFailure("project record is malformed")
        }
        for requirement in requirements {
            guard !requirement.code.isEmpty, requirement.code.utf8.count <= 256,
                  !requirement.summary.isEmpty, requirement.summary.utf8.count <= 4_096,
                  !requirement.detail.isEmpty, requirement.detail.utf8.count <= 16_384,
                  ![requirement.code, requirement.summary, requirement.detail]
                    .contains(where: { $0.contains("\0") })
            else {
                throw Hub.Error.storageFailure("project requirement is malformed")
            }
        }
    }

    static func identifier(for projectURL: URL) -> String {
        Core.Digest.sha256(projectURL.standardizedFileURL.path).hex
    }
}

/// Owner-only recent-project registry shared by the menu app and future
/// headless frontends. It stores no signing secrets or pairing credentials.
public actor ProjectStore {
    public static let maximumDocumentBytes = 2 * 1_024 * 1_024

    public let url: URL
    private var recordsByID: [String: Hub.ProjectRecord]

    public init(url: URL) throws {
        self.url = url.standardizedFileURL
        let records = try Self.load(url: self.url)
        recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    public static func applicationSupport() throws -> Hub.ProjectStore {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw Hub.Error.storageFailure("Application Support is unavailable")
        }
        return try .init(
            url: root
                .appendingPathComponent("Helix", isDirectory: true)
                .appendingPathComponent("HubProjects.json")
        )
    }

    public func records() -> [Hub.ProjectRecord] {
        recordsByID.values.sorted(by: Self.newestFirst)
    }

    @discardableResult
    public func register(
        installation: Hub.InstallationResult,
        configuredAt: Date = Date()
    ) throws -> Hub.ProjectRecord {
        let name = installation.projectURL.deletingPathExtension().lastPathComponent
        let record = try Hub.ProjectRecord(
            name: name,
            projectURL: installation.projectURL,
            hostPlanURL: installation.hostPlanURL,
            capabilities: installation.capabilities,
            requirements: installation.requirements,
            configuredAt: configuredAt
        )
        var candidate = recordsByID
        candidate[record.id] = record
        try save(candidate)
        recordsByID = candidate
        return record
    }

    public func remove(id: String) throws {
        guard recordsByID[id] != nil else { return }
        var candidate = recordsByID
        candidate[id] = nil
        try save(candidate)
        recordsByID = candidate
    }

    private func save(_ records: [String: Hub.ProjectRecord]) throws {
        let document = Document(records: records.values.sorted(by: Self.newestFirst))
        try document.validate()
        let data = try Core.CanonicalJSON.encode(document)
        guard data.count <= Self.maximumDocumentBytes else {
            throw Hub.Error.storageFailure("project registry is oversized")
        }
        try OwnerFile.write(
            data,
            to: url,
            maximumBytes: Self.maximumDocumentBytes
        )
    }

    private static func load(url: URL) throws -> [Hub.ProjectRecord] {
        let data: Data
        do {
            data = try OwnerFile.read(from: url, maximumBytes: maximumDocumentBytes)
        } catch OwnerFile.StorageError.unavailable {
            return []
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
            try document.validate()
            guard try Core.CanonicalJSON.encode(document) == data else {
                throw Hub.Error.storageFailure("project registry is noncanonical")
            }
        } catch let error as Hub.Error {
            throw error
        } catch {
            throw Hub.Error.storageFailure("project registry cannot be decoded")
        }
        return document.records
    }

    private static func newestFirst(
        _ lhs: Hub.ProjectRecord,
        _ rhs: Hub.ProjectRecord
    ) -> Bool {
        if lhs.configuredAt != rhs.configuredAt { return lhs.configuredAt > rhs.configuredAt }
        return lhs.id < rhs.id
    }

    private struct Document: Codable {
        static let currentSchemaVersion: UInt16 = 1
        var schemaVersion: UInt16 = Self.currentSchemaVersion
        var records: [Hub.ProjectRecord]

        func validate() throws {
            guard schemaVersion == Self.currentSchemaVersion,
                  records.count <= 1_024,
                  records == records.sorted(by: Hub.ProjectStore.newestFirst),
                  Set(records.map(\.id)).count == records.count
            else {
                throw Hub.Error.storageFailure("project registry schema or ordering is invalid")
            }
            try records.forEach { try $0.validate() }
        }
    }
}
}

private enum OwnerFile {
    enum StorageError: Swift.Error { case unavailable }

    static func read(from url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw StorageError.unavailable }
            throw Hub.Error.storageFailure("project registry cannot be opened safely")
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(), status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o077 == 0,
              status.st_size > 0, status.st_size <= maximumBytes
        else {
            throw Hub.Error.storageFailure(
                "project registry must be a bounded owner-only regular file"
            )
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            .readToEnd() ?? Data()
        guard data.count == Int(status.st_size) else {
            throw Hub.Error.storageFailure("project registry changed while reading")
        }
        return data
    }

    static func write(_ data: Data, to url: URL, maximumBytes: Int) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw Hub.Error.storageFailure("project registry is empty or oversized")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var directoryStatus = stat()
        guard directory.path.withCString({ lstat($0, &directoryStatus) }) == 0,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_mode & 0o077 == 0
        else {
            throw Hub.Error.storageFailure("project registry directory is insecure")
        }
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw Hub.Error.storageFailure("project registry staging file cannot be created")
        }
        var removeTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if removeTemporary { _ = temporary.path.withCString(Darwin.unlink) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw Hub.Error.storageFailure("project registry is empty")
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw Hub.Error.storageFailure("project registry staging write failed")
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              temporary.path.withCString({ source in
                url.path.withCString { destination in Darwin.rename(source, destination) }
              }) == 0
        else {
            throw Hub.Error.storageFailure("project registry cannot be published atomically")
        }
        removeTemporary = false
    }
}
#endif
