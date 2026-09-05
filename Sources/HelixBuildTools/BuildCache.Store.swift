import Darwin
import Foundation
import HelixCore

/// Content-addressed, owner-local build facts. Cached bytes are never product
/// authority: every consumer must decode and validate them before use.
public enum BuildCache {}

extension BuildCache {
public enum Namespace: String, Codable, Hashable, Sendable {
    case moduleFrontend = "module_frontend"
    case compilerCheckpoint = "compiler_checkpoint"
    case nativeAPICatalog = "native_api_catalog"
    case symbolGraph = "symbol_graph"
    case managedProbe = "managed_probe"
    case managedProbeBatch = "managed_probe_batch"
    case adapterPack = "adapter_pack"
    case adapterObject = "adapter_object"
    case developmentAdapter = "development_adapter"
    case applicationObject = "application_object"
}

public enum Source: String, Codable, Hashable, Sendable {
    case hit
    case generated
    case repaired
    case bypassed
}

public struct Value: Hashable, Sendable {
    public var data: Data
    public var source: BuildCache.Source

    public init(data: Data, source: BuildCache.Source) {
        self.data = data
        self.source = source
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidRoot
    case unsafePath(String)
    case io(String)

    public var description: String {
        switch self {
        case .invalidRoot: "build cache root is unsafe"
        case let .unsafePath(path): "build cache path is unsafe: \(path)"
        case let .io(reason): "build cache I/O failed: \(reason)"
        }
    }
}

public struct Store: Sendable {
    private struct Manifest: Codable, Hashable, Sendable {
        static let currentSchemaVersion: UInt16 = 1

        var schemaVersion: UInt16
        var namespace: BuildCache.Namespace
        var key: Core.Digest
        var payloadByteCount: UInt64
        var payloadSHA256: Core.Digest

        init(
            namespace: BuildCache.Namespace,
            key: Core.Digest,
            payload: Data
        ) {
            schemaVersion = Self.currentSchemaVersion
            self.namespace = namespace
            self.key = key
            payloadByteCount = UInt64(payload.count)
            payloadSHA256 = .sha256(payload)
        }

        func validate(
            namespace: BuildCache.Namespace,
            key: Core.Digest,
            maximumBytes: Int
        ) throws {
            guard schemaVersion == Self.currentSchemaVersion,
                  self.namespace == namespace,
                  self.key == key,
                  payloadByteCount > 0,
                  payloadByteCount <= UInt64(maximumBytes)
            else {
                throw BuildCache.Error.io("cache manifest identity is invalid")
            }
        }
    }

    private enum ExistingEntry {
        case missing
        case valid(Data)
        case corrupt

        var isCorrupt: Bool {
            if case .corrupt = self { return true }
            return false
        }
    }

    public var rootURL: URL

    public init(rootURL: URL) throws {
        let root = rootURL.standardizedFileURL
        guard root.path.hasPrefix("/"), root.path != "/",
              !root.lastPathComponent.isEmpty
        else { throw BuildCache.Error.invalidRoot }
        self.rootURL = root
    }

    public func value(
        namespace: BuildCache.Namespace,
        key: Core.Digest,
        maximumBytes: Int,
        validate: (Data) throws -> Void = { _ in },
        produce: () throws -> Data
    ) throws -> BuildCache.Value {
        guard maximumBytes > 0, maximumBytes <= 512 * 1_024 * 1_024 else {
            throw BuildCache.Error.io("cache payload limit is invalid")
        }
        func bypass() throws -> BuildCache.Value {
            let data = try produce()
            try validate(data)
            return .init(data: data, source: .bypassed)
        }
        let manager = FileManager.default
        let namespaceURL: URL
        do {
            try Self.preparePrivateDirectory(rootURL, manager: manager)
            try Self.validateAncestorChain(rootURL)
            let versionURL = rootURL.appendingPathComponent("v1", isDirectory: true)
            try Self.preparePrivateDirectory(versionURL, manager: manager)
            namespaceURL = versionURL.appendingPathComponent(
                namespace.rawValue,
                isDirectory: true
            )
            try Self.preparePrivateDirectory(namespaceURL, manager: manager)
        } catch {
            return try bypass()
        }

        let lockURL = namespaceURL.appendingPathComponent(".\(key.hex).lock")
        let lockDescriptor: Int32
        do {
            lockDescriptor = try Self.openLock(lockURL)
        } catch {
            return try bypass()
        }
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        while flock(lockDescriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                return try bypass()
            }
        }

        let entryURL = namespaceURL.appendingPathComponent(
            key.hex,
            isDirectory: true
        )
        var existing = Self.load(
            entryURL,
            namespace: namespace,
            key: key,
            maximumBytes: maximumBytes
        )
        switch existing {
        case let .valid(data):
            do {
                try validate(data)
                return .init(data: data, source: .hit)
            } catch {
                existing = .corrupt
                guard Self.quarantine(entryURL, manager: manager) else {
                    return try bypass()
                }
            }
        case .missing:
            break
        case .corrupt:
            guard Self.quarantine(entryURL, manager: manager) else {
                return try bypass()
            }
        }

        let data = try produce()
        try validate(data)
        guard !data.isEmpty, data.count <= maximumBytes else {
            return .init(data: data, source: .bypassed)
        }
        do {
            try Self.publish(
                data,
                namespace: namespace,
                key: key,
                at: entryURL,
                manager: manager
            )
            return .init(
                data: data,
                source: existing.isCorrupt ? .repaired : .generated
            )
        } catch {
            return .init(data: data, source: .bypassed)
        }
    }

    /// Returns one already-published value without creating directories,
    /// waiting for a producer, repairing corruption, or running new work.
    /// This is the read boundary used by latency-sensitive build phases while
    /// a separate process may be publishing the same content-addressed fact.
    public func cachedValue(
        namespace: BuildCache.Namespace,
        key: Core.Digest,
        maximumBytes: Int,
        validate: (Data) throws -> Void = { _ in }
    ) throws -> BuildCache.Value? {
        guard maximumBytes > 0, maximumBytes <= 512 * 1_024 * 1_024 else {
            throw BuildCache.Error.io("cache payload limit is invalid")
        }
        let versionURL = rootURL.appendingPathComponent("v1", isDirectory: true)
        let namespaceURL = versionURL.appendingPathComponent(
            namespace.rawValue,
            isDirectory: true
        )
        for directory in [rootURL, versionURL, namespaceURL] {
            var information = Darwin.stat()
            guard lstat(directory.path, &information) == 0 else {
                if errno == ENOENT { return nil }
                throw BuildCache.Error.io("cannot inspect cache directory")
            }
            guard Self.isPrivateDirectory(information) else {
                throw BuildCache.Error.unsafePath(directory.path)
            }
        }
        try Self.validateAncestorChain(rootURL)

        let lockURL = namespaceURL.appendingPathComponent(".\(key.hex).lock")
        let lockDescriptor = Darwin.open(
            lockURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard lockDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw BuildCache.Error.io("cannot open cache lock")
        }
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        var lockInformation = Darwin.stat()
        guard fstat(lockDescriptor, &lockInformation) == 0,
              lockInformation.st_mode & S_IFMT == S_IFREG,
              lockInformation.st_uid == geteuid(),
              lockInformation.st_mode & 0o177 == 0
        else {
            throw BuildCache.Error.unsafePath(lockURL.path)
        }
        guard flock(lockDescriptor, LOCK_SH | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
            throw BuildCache.Error.io("cannot acquire cache read lock")
        }

        let entryURL = namespaceURL.appendingPathComponent(
            key.hex,
            isDirectory: true
        )
        guard case let .valid(data) = Self.load(
            entryURL,
            namespace: namespace,
            key: key,
            maximumBytes: maximumBytes
        ) else { return nil }
        do {
            try validate(data)
        } catch {
            return nil
        }
        return .init(data: data, source: .hit)
    }

    /// Best-effort retirement of a superseded private intermediate. Keep the
    /// lock inode so another process cannot lock a different file for this key.
    func discard(namespace: BuildCache.Namespace, key: Core.Digest) -> Bool {
        let version = rootURL.appendingPathComponent("v1", isDirectory: true)
        let directory = version.appendingPathComponent(namespace.rawValue, isDirectory: true)
        do {
            try Self.validateAncestorChain(rootURL)
            for url in [rootURL, version, directory] {
                var information = Darwin.stat()
                guard lstat(url.path, &information) == 0, Self.isPrivateDirectory(information) else { return false }
            }
            let descriptor = try Self.openLock(directory.appendingPathComponent(".\(key.hex).lock"))
            defer {
                _ = flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
            // A successful foreground build must not wait for another
            // process that is still producing this intermediate.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
            let entry = directory.appendingPathComponent(key.hex, isDirectory: true)
            var information = Darwin.stat()
            guard lstat(entry.path, &information) == 0, Self.isPrivateDirectory(information) else { return false }
            return Self.quarantine(entry, manager: .default)
        } catch {
            return false
        }
    }

    private static func load(
        _ entryURL: URL,
        namespace: BuildCache.Namespace,
        key: Core.Digest,
        maximumBytes: Int
    ) -> ExistingEntry {
        var entryInformation = Darwin.stat()
        guard lstat(entryURL.path, &entryInformation) == 0 else {
            return errno == ENOENT ? .missing : .corrupt
        }
        guard Self.isPrivateDirectory(entryInformation) else { return .corrupt }
        let manifestURL = entryURL.appendingPathComponent("Manifest.json")
        let payloadURL = entryURL.appendingPathComponent("Payload.bin")
        do {
            let manifestBytes = try readPrivateRegularFile(
                manifestURL,
                maximumBytes: 64 * 1_024
            )
            let manifest = try JSONDecoder().decode(
                Manifest.self,
                from: manifestBytes
            )
            guard try Core.CanonicalJSON.encode(manifest) == manifestBytes else {
                return .corrupt
            }
            try manifest.validate(
                namespace: namespace,
                key: key,
                maximumBytes: maximumBytes
            )
            let payload = try readPrivateRegularFile(
                payloadURL,
                maximumBytes: maximumBytes
            )
            guard UInt64(payload.count) == manifest.payloadByteCount,
                  Core.Digest.sha256(payload) == manifest.payloadSHA256
            else { return .corrupt }
            return .valid(payload)
        } catch {
            return .corrupt
        }
    }

    private static func publish(
        _ data: Data,
        namespace: BuildCache.Namespace,
        key: Core.Digest,
        at entryURL: URL,
        manager: FileManager
    ) throws {
        let parent = entryURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".staging-\(key.hex)-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var stagingExists = true
        defer { if stagingExists { try? manager.removeItem(at: staging) } }
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: staging.path
        )
        let payloadURL = staging.appendingPathComponent("Payload.bin")
        let manifestURL = staging.appendingPathComponent("Manifest.json")
        try data.write(to: payloadURL, options: .atomic)
        let manifest = Manifest(namespace: namespace, key: key, payload: data)
        try Core.CanonicalJSON.encode(manifest).write(to: manifestURL, options: .atomic)
        for url in [payloadURL, manifestURL] {
            try manager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        }
        guard Darwin.rename(staging.path, entryURL.path) == 0 else {
            throw BuildCache.Error.io(
                "cannot publish cache entry: \(String(cString: strerror(errno)))"
            )
        }
        stagingExists = false
    }

    private static func quarantine(_ url: URL, manager: FileManager) -> Bool {
        let quarantine = url.deletingLastPathComponent().appendingPathComponent(
            ".corrupt-\(url.lastPathComponent)-\(UUID().uuidString)",
            isDirectory: true
        )
        guard Darwin.rename(url.path, quarantine.path) == 0 else { return false }
        try? manager.removeItem(at: quarantine)
        return true
    }

    private static func preparePrivateDirectory(
        _ url: URL,
        manager: FileManager
    ) throws {
        var information = Darwin.stat()
        if lstat(url.path, &information) != 0 {
            guard errno == ENOENT else {
                throw BuildCache.Error.io("cannot inspect \(url.path)")
            }
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            guard lstat(url.path, &information) == 0 else {
                throw BuildCache.Error.io("cannot inspect created cache directory")
            }
        }
        guard Self.isOwnedDirectory(information),
              information.st_mode & 0o022 == 0
        else {
            throw BuildCache.Error.unsafePath(url.path)
        }
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
        guard lstat(url.path, &information) == 0,
              Self.isPrivateDirectory(information)
        else {
            throw BuildCache.Error.unsafePath(url.path)
        }
    }

    private static func isOwnedDirectory(_ information: Darwin.stat) -> Bool {
        information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == geteuid()
    }

    private static func isPrivateDirectory(_ information: Darwin.stat) -> Bool {
        isOwnedDirectory(information)
            && information.st_mode & 0o077 == 0
    }

    static func validateAncestorChain(_ root: URL) throws {
        var current = root.standardizedFileURL
        var visited = Set<String>()
        while true {
            guard visited.insert(current.path).inserted else {
                throw BuildCache.Error.unsafePath(current.path)
            }
            var information = Darwin.stat()
            guard lstat(current.path, &information) == 0 else {
                throw BuildCache.Error.unsafePath(current.path)
            }
            if information.st_mode & S_IFMT == S_IFLNK {
                // Only an administrator-controlled system alias such as
                // `/var -> private/var` may appear above the private root.
                // User-owned ancestor links are too easy to retarget.
                guard information.st_uid == 0,
                      fstatat(AT_FDCWD, current.path, &information, 0) == 0
                else {
                    throw BuildCache.Error.unsafePath(current.path)
                }
            }
            guard information.st_mode & S_IFMT == S_IFDIR else {
                throw BuildCache.Error.unsafePath(current.path)
            }
            let writableByOthers = information.st_mode & 0o022 != 0
            let protectedSharedDirectory = information.st_mode & S_ISVTX != 0
                && (information.st_uid == 0 || information.st_uid == geteuid())
            guard !writableByOthers || protectedSharedDirectory else {
                throw BuildCache.Error.unsafePath(current.path)
            }
            if current.path == "/" { return }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                throw BuildCache.Error.unsafePath(current.path)
            }
            current = parent
        }
    }

    private static func openLock(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw BuildCache.Error.io("cannot open cache lock")
        }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o177 == 0
        else {
            Darwin.close(descriptor)
            throw BuildCache.Error.unsafePath(url.path)
        }
        return descriptor
    }

    private static func readPrivateRegularFile(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw BuildCache.Error.io("cannot open cache file")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = Darwin.stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o177 == 0,
              information.st_size > 0,
              information.st_size <= maximumBytes
        else {
            throw BuildCache.Error.unsafePath(url.path)
        }
        let expected = Int(information.st_size)
        var data = Data()
        data.reserveCapacity(expected)
        while data.count < expected {
            let chunk = try handle.read(
                upToCount: min(64 * 1_024, expected - data.count)
            ) ?? Data()
            guard !chunk.isEmpty else {
                throw BuildCache.Error.io("cache file changed while reading")
            }
            data.append(chunk)
        }
        guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else {
            throw BuildCache.Error.io("cache file changed while reading")
        }
        return data
    }
}

/// Resolves the owner-local shared cache used by Xcode integration and
/// development-time Adapter compilation. An invalid override is ignored in
/// favor of the validated user-cache location.
public static func defaultStore(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
) -> BuildCache.Store? {
    let root: URL
    if let configured = environment["HELIX_BUILD_CACHE_DIR"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !configured.isEmpty,
       configured.hasPrefix("/"),
       !configured.contains("\n"),
       !configured.contains("\r") {
        root = URL(fileURLWithPath: configured, isDirectory: true)
    } else {
        guard let caches = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }
        root = caches
            .appendingPathComponent("Helix", isDirectory: true)
            .appendingPathComponent("BuildFacts", isDirectory: true)
    }
    return try? .init(rootURL: root)
}
}
