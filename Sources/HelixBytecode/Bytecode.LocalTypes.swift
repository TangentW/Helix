import Foundation

extension Bytecode {
public struct LocalTypeKey: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }
}

public struct LocalStructField: Codable, Hashable, Sendable {
    public var name: String
    public var type: Bytecode.ValueType

    public init(name: String, type: Bytecode.ValueType) {
        self.name = name
        self.type = type
    }
}

public struct LocalEnumCase: Codable, Hashable, Sendable {
    public var name: String
    /// Swift SIL represents all associated values as at most one payload. A
    /// source case with multiple values therefore carries one tuple payload.
    public var payloadType: Bytecode.ValueType?

    public init(name: String, payloadType: Bytecode.ValueType? = nil) {
        self.name = name
        self.payloadType = payloadType
    }
}

public enum LocalTypeKind: Codable, Hashable, Sendable {
    case structure(fields: [Bytecode.LocalStructField])
    case enumeration(cases: [Bytecode.LocalEnumCase])
}

public struct LocalTypeDefinition: Codable, Hashable, Sendable {
    public var key: Bytecode.LocalTypeKey
    public var kind: Bytecode.LocalTypeKind
    public var conformsToError: Bool

    public init(
        key: Bytecode.LocalTypeKey,
        kind: Bytecode.LocalTypeKind,
        conformsToError: Bool = false
    ) {
        self.key = key
        self.kind = kind
        self.conformsToError = conformsToError
    }
}

public struct EnumCaseTarget: Codable, Hashable, Sendable {
    public var caseIndex: UInt32
    public var target: Bytecode.BlockID

    public init(caseIndex: UInt32, target: Bytecode.BlockID) {
        self.caseIndex = caseIndex
        self.target = target
    }
}
}
