import Foundation
import HelixCore

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

/// A frozen native superclass used only as the Objective-C host of a local
/// class. The logical class remains an HLVM type and never fabricates Swift
/// metadata on-device.
public struct HostedSuperclass: Codable, Hashable, Sendable {
    public var typeID: Core.TypeID

    public init(typeID: Core.TypeID) {
        self.typeID = typeID
    }
}

/// Physical Objective-C callback shapes implemented by precompiled Runtime
/// trampolines. This closed set prevents downloaded metadata from inventing an
/// arbitrary native calling convention.
public enum HostedMethodABI: String, Codable, Hashable, Sendable {
    case voidNoArguments
    case voidBool
}

public struct HostedMethod: Codable, Hashable, Sendable {
    public var selector: String
    public var functionID: Bytecode.FunctionID
    public var abi: Bytecode.HostedMethodABI

    public init(
        selector: String,
        functionID: Bytecode.FunctionID,
        abi: Bytecode.HostedMethodABI
    ) {
        self.selector = selector
        self.functionID = functionID
        self.abi = abi
    }
}

public enum LocalTypeKind: Codable, Hashable, Sendable {
    case structure(fields: [Bytecode.LocalStructField])
    case enumeration(cases: [Bytecode.LocalEnumCase])
    case `class`(
        fields: [Bytecode.LocalStructField],
        hostedSuperclass: Bytecode.HostedSuperclass?,
        hostedMethods: [Bytecode.HostedMethod]
    )
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
