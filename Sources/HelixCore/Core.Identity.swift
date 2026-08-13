import Foundation

extension Core {
public protocol DigestIdentity: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible
where RawValue == Core.Digest {}
}

extension Core.DigestIdentity {
    public var description: String { rawValue.hex }
}

extension Core {
public struct ShellNamespaceID: Core.DigestIdentity {
    public let rawValue: Core.Digest
    public init(rawValue: Core.Digest) { self.rawValue = rawValue }

    public static func derive(bundleID: String, buildNumber: String, seed: String) -> Self {
        var hasher = Core.StableHasher(domain: "HLX.ShellNamespace.v1")
        hasher.append(bundleID)
        hasher.append(buildNumber)
        hasher.append(seed)
        return Self(rawValue: hasher.finalize())
    }
}

public struct FunctionKey: Core.DigestIdentity {
    public let rawValue: Core.Digest
    public init(rawValue: Core.Digest) { self.rawValue = rawValue }

    public static func derive(
        namespace: Core.ShellNamespaceID,
        module: String,
        sourceFileLogicalID: String,
        canonicalDeclaration: String,
        loweredSignature: Core.LoweredSignature,
        role: Core.FunctionRole
    ) throws -> Self {
        var hasher = Core.StableHasher(domain: "HLX.Function.v1")
        hasher.append(namespace.rawValue)
        hasher.append(module)
        hasher.append(sourceFileLogicalID)
        hasher.append(canonicalDeclaration)
        hasher.append(try Core.CanonicalJSON.encode(loweredSignature))
        hasher.append(role.rawValue)
        return Self(rawValue: hasher.finalize())
    }
}

public struct TypeID: Core.DigestIdentity {
    public let rawValue: Core.Digest
    public init(rawValue: Core.Digest) { self.rawValue = rawValue }

    public static func derive(namespace: Core.ShellNamespaceID, canonicalType: String) -> Self {
        var hasher = Core.StableHasher(domain: "HLX.Type.v1")
        hasher.append(namespace.rawValue)
        hasher.append(canonicalType)
        return Self(rawValue: hasher.finalize())
    }
}

public struct NativeImportKey: Core.DigestIdentity {
    public let rawValue: Core.Digest
    public init(rawValue: Core.Digest) { self.rawValue = rawValue }

    public static func derive(
        namespace: Core.ShellNamespaceID,
        canonicalCallee: String,
        signature: Core.LoweredSignature,
        effects: Core.Effects,
        contract: Core.NativeImportContract
    ) throws -> Self {
        try contract.validate(effects: effects)
        var hasher = Core.StableHasher(domain: "HLX.Import.v1")
        hasher.append(namespace.rawValue)
        hasher.append(canonicalCallee)
        hasher.append(try Core.CanonicalJSON.encode(signature))
        hasher.append(try Core.CanonicalJSON.encode(effects))
        hasher.append(try Core.CanonicalJSON.encode(contract))
        return Self(rawValue: hasher.finalize())
    }
}

public struct EntryIndex: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { String(rawValue) }
}

public struct NativeImportID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { String(rawValue) }
}

public enum FunctionRole: String, Codable, Hashable, Sendable {
    case function
    case method
    case getter
    case setter
    case initializer
    case deinitializer
}

public struct LoweredSignature: Codable, Hashable, Sendable {
    public var parameters: [String]
    public var result: String
    public var isThrowing: Bool
    /// Describes the Swift ABI. HLBC may still restrict the accepted body to a
    /// non-suspending async leaf profile.
    public var isAsync: Bool
    public var isolation: String?

    public init(
        parameters: [String],
        result: String,
        isThrowing: Bool = false,
        isAsync: Bool = false,
        isolation: String? = nil
    ) {
        self.parameters = parameters
        self.result = result
        self.isThrowing = isThrowing
        self.isAsync = isAsync
        self.isolation = isolation
    }
}

public struct Effects: Codable, Hashable, Sendable {
    public var mayThrow: Bool
    public var mayAllocate: Bool
    public var hasExternalSideEffects: Bool
    public var requiresMainActor: Bool
    /// Marks the Swift entry ABI as async. The first capability only permits
    /// bodies proven not to contain a suspension or async call.
    public var isAsync: Bool

    public init(
        mayThrow: Bool = false,
        mayAllocate: Bool = false,
        hasExternalSideEffects: Bool = false,
        requiresMainActor: Bool = false,
        isAsync: Bool = false
    ) {
        self.mayThrow = mayThrow
        self.mayAllocate = mayAllocate
        self.hasExternalSideEffects = hasExternalSideEffects
        self.requiresMainActor = requiresMainActor
        self.isAsync = isAsync
    }
}

public struct FunctionInterface: Codable, Hashable, Sendable {
    public var key: Core.FunctionKey
    public var entryIndex: Core.EntryIndex
    public var mangledName: String
    public var sourceFileLogicalID: String
    public var loweredSignature: Core.LoweredSignature
    public var effects: Core.Effects

    public init(
        key: Core.FunctionKey,
        entryIndex: Core.EntryIndex,
        mangledName: String,
        sourceFileLogicalID: String,
        loweredSignature: Core.LoweredSignature,
        effects: Core.Effects
    ) {
        self.key = key
        self.entryIndex = entryIndex
        self.mangledName = mangledName
        self.sourceFileLogicalID = sourceFileLogicalID
        self.loweredSignature = loweredSignature
        self.effects = effects
    }
}
}
