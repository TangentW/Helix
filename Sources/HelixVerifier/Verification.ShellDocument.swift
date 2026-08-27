import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

extension Verification {
/// Deterministic, data-only representation embedded in a generated Release
/// Bridge. Keeping the Shell as data avoids compiling one Swift constructor
/// expression for every cataloged native call.
public struct ShellDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let maximumEncodedByteCount = 128 * 1_024 * 1_024

    public var schemaVersion: UInt16
    public var interfaceHash: Core.Digest
    public var compatibility: Core.Compatibility
    public var capabilities: [Core.Capability]
    public var entries: [Verification.ResolvedEntry]
    public var imports: [Verification.ResolvedNativeImport]
    public var types: [Verification.ResolvedNativeType]
    public var frozenValueTypes: [Verification.ResolvedFrozenValueType]

    public init(shell: Verification.ShellInterface) throws {
        schemaVersion = Self.currentSchemaVersion
        interfaceHash = shell.interfaceHash
        compatibility = shell.compatibility
        capabilities = shell.capabilities.sorted()
        entries = shell.entries.values.sorted { $0.index < $1.index }
        imports = shell.imports.values.sorted { $0.id < $1.id }
        types = shell.types.values.sorted { $0.id.rawValue < $1.id.rawValue }
        frozenValueTypes = shell.frozenValueTypes.values.sorted { $0.key < $1.key }
        try validate()
    }

    public func makeShellInterface() throws -> Verification.ShellInterface {
        try validate()
        return try Verification.ShellInterface(
            interfaceHash: interfaceHash,
            compatibility: compatibility,
            capabilities: Set(capabilities),
            entries: entries,
            imports: imports,
            types: types,
            frozenValueTypes: frozenValueTypes
        )
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try Core.CanonicalJSON.encode(self)
        guard data.count <= Self.maximumEncodedByteCount else {
            throw Verification.Error.invalidShellInterface(
                "encoded Shell document exceeds \(Self.maximumEncodedByteCount) bytes"
            )
        }
        return data
    }

    public func encodedBase64() throws -> String {
        try encoded().base64EncodedString()
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedByteCount else {
            throw Verification.Error.invalidShellInterface(
                "encoded Shell document exceeds \(maximumEncodedByteCount) bytes"
            )
        }
        let document: Self
        do {
            document = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw Verification.Error.invalidShellInterface(
                "Shell document cannot be decoded: \(error)"
            )
        }
        try document.validate()
        guard try Core.CanonicalJSON.encode(document) == data else {
            throw Verification.Error.invalidShellInterface(
                "Shell document is not canonical"
            )
        }
        return document
    }

    public static func decodeBase64(chunks: [String]) throws -> Self {
        guard chunks.count <= 16_384,
              chunks.allSatisfy({ $0.utf8.count <= 64 * 1_024 })
        else {
            throw Verification.Error.invalidShellInterface(
                "Shell document has too many or oversized Base64 chunks"
            )
        }
        let encodedCount = chunks.reduce(into: 0) { total, chunk in
            let addition = total.addingReportingOverflow(chunk.utf8.count)
            total = addition.overflow ? Int.max : addition.partialValue
        }
        let maximumBase64ByteCount = maximumEncodedByteCount / 3 * 4 + 4
        guard encodedCount <= maximumBase64ByteCount else {
            throw Verification.Error.invalidShellInterface(
                "Shell document has invalid or oversized Base64 data"
            )
        }
        let encoded = chunks.joined()
        guard let data = Data(base64Encoded: encoded),
              data.base64EncodedString() == encoded
        else {
            throw Verification.Error.invalidShellInterface(
                "Shell document has invalid or oversized Base64 data"
            )
        }
        return try decode(data)
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw Verification.Error.invalidShellInterface(
                "unsupported Shell document schema \(schemaVersion)"
            )
        }
        guard capabilities == Array(Set(capabilities)).sorted(),
              entries == entries.sorted(by: { $0.index < $1.index }),
              imports == imports.sorted(by: { $0.id < $1.id }),
              types == types.sorted(by: { $0.id.rawValue < $1.id.rawValue }),
              frozenValueTypes == frozenValueTypes.sorted(by: { $0.key < $1.key })
        else {
            throw Verification.Error.invalidShellInterface(
                "Shell document collections are not uniquely ordered"
            )
        }
        _ = try Verification.ShellInterface(
            interfaceHash: interfaceHash,
            compatibility: compatibility,
            capabilities: Set(capabilities),
            entries: entries,
            imports: imports,
            types: types,
            frozenValueTypes: frozenValueTypes
        )
    }
}
}

extension Verification.ShellDocument {
/// Decodes a generated Shell at most once, including under concurrent startup
/// paths. A corrupt embedded document remains a deterministic failure instead
/// of being reparsed by every Runtime factory call.
public final class Loader: @unchecked Sendable {
    private enum State {
        case unloaded
        case loaded(Verification.ShellInterface)
        case failed(Verification.Error)
    }

    private let base64Chunks: [String]
    private let lock = NSLock()
    private var state = State.unloaded

    public init(base64Chunks: [String]) {
        self.base64Chunks = base64Chunks
    }

    public func load() throws -> Verification.ShellInterface {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case let .loaded(shell): return shell
        case let .failed(error): throw error
        case .unloaded: break
        }
        do {
            let shell = try Verification.ShellDocument.decodeBase64(
                chunks: base64Chunks
            ).makeShellInterface()
            state = .loaded(shell)
            return shell
        } catch let error as Verification.Error {
            state = .failed(error)
            throw error
        } catch {
            let failure = Verification.Error.invalidShellInterface(
                "Shell document loading failed: \(error)"
            )
            state = .failed(failure)
            throw failure
        }
    }
}
}
