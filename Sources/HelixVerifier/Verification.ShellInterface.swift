import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

extension Verification {
public struct ResolvedEntry: Hashable, Sendable {
    public var index: Core.EntryIndex
    public var key: Core.FunctionKey
    public var parameterTypes: [Bytecode.ValueType]
    public var resultType: Bytecode.ValueType
    public var effects: Core.Effects
    public var fallbackAllowed: Bool

    public init(
        index: Core.EntryIndex,
        key: Core.FunctionKey,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        effects: Core.Effects = .init(),
        fallbackAllowed: Bool = false
    ) {
        self.index = index
        self.key = key
        self.parameterTypes = parameterTypes
        self.resultType = resultType
        self.effects = effects
        self.fallbackAllowed = fallbackAllowed
    }
}

public struct ResolvedNativeImport: Hashable, Sendable {
    public var id: Core.NativeImportID
    public var key: Core.NativeImportKey
    public var parameterTypes: [Bytecode.ValueType]
    public var resultType: Bytecode.ValueType
    public var signature: Core.LoweredSignature
    public var effects: Core.Effects
    public var contract: Core.NativeImportContract
    public var capability: Core.Capability

    public init(
        id: Core.NativeImportID,
        key: Core.NativeImportKey,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        signature: Core.LoweredSignature,
        effects: Core.Effects,
        contract: Core.NativeImportContract,
        capability: Core.Capability = .nativeImportsV1
    ) {
        self.id = id
        self.key = key
        self.parameterTypes = parameterTypes
        self.resultType = resultType
        self.signature = signature
        self.effects = effects
        self.contract = contract
        self.capability = capability
    }

    public var parameterConventions: [Bytecode.ParameterConvention] {
        let nonescaping = Set(contract.callbacks.compactMap { callback in
            callback.lifetime == .nonescaping
                ? Int(callback.parameterIndex) : nil
        })
        return parameterTypes.indices.map {
            nonescaping.contains($0) ? .borrowed : .owned
        }
    }
}

public enum NativeTypeKind: String, Hashable, Sendable {
    case value
    case reference
    case enumeration
}

public struct ResolvedNativeType: Hashable, Sendable {
    public var id: Core.TypeID
    public var canonicalName: String
    public var kind: Verification.NativeTypeKind
    public var layoutFingerprint: Core.Digest
    public var isCopyable: Bool
    public var requiresMainActor: Bool
    public var estimatedSize: UInt64

    public init(
        id: Core.TypeID,
        canonicalName: String,
        kind: Verification.NativeTypeKind,
        layoutFingerprint: Core.Digest,
        isCopyable: Bool,
        requiresMainActor: Bool = false,
        estimatedSize: UInt64
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.kind = kind
        self.layoutFingerprint = layoutFingerprint
        self.isCopyable = isCopyable
        self.requiresMainActor = requiresMainActor
        self.estimatedSize = estimatedSize
    }
}

public struct ShellInterface: Sendable {
    public var interfaceHash: Core.Digest
    public var compatibility: Core.Compatibility
    public var capabilities: Set<Core.Capability>
    public var entries: [Core.EntryIndex: Verification.ResolvedEntry]
    public var imports: [Core.NativeImportID: Verification.ResolvedNativeImport]
    public var types: [Core.TypeID: Verification.ResolvedNativeType]

    public init(
        interfaceHash: Core.Digest,
        compatibility: Core.Compatibility,
        capabilities: Set<Core.Capability> = [.baselineV1],
        entries: [Verification.ResolvedEntry] = [],
        imports: [Verification.ResolvedNativeImport] = [],
        types: [Verification.ResolvedNativeType] = []
    ) throws {
        self.interfaceHash = interfaceHash
        self.compatibility = compatibility
        self.capabilities = capabilities
        self.entries = try Self.uniqueDictionary(entries, key: \.index, label: "entry")
        self.imports = try Self.uniqueDictionary(imports, key: \.id, label: "native import")
        self.types = try Self.uniqueDictionary(types, key: \.id, label: "native type")
        try validateBoundarySignatures()
    }

    func validateBoundarySignatures() throws {
        for index in entries.keys.sorted() {
            guard let entry = entries[index] else { continue }
            for type in entry.parameterTypes + [entry.resultType] {
                try Self.validateBoundaryType(
                    type,
                    owner: "entry \(entry.index)",
                    capabilities: capabilities
                )
            }
        }
        for id in imports.keys.sorted() {
            guard let descriptor = imports[id] else { continue }
            let callbacks = descriptor.contract.callbacks
            let normalizedIsolation = descriptor.signature.isolation.map {
                $0 == "Swift.MainActor" ? "MainActor" : $0
            }
            guard descriptor.capability == .nativeImportsV1,
                  capabilities.contains(descriptor.capability),
                  descriptor.signature.parameters.count
                    == descriptor.parameterTypes.count,
                  !descriptor.signature.result.isEmpty,
                  descriptor.signature.isThrowing == descriptor.effects.mayThrow,
                  descriptor.signature.isAsync == descriptor.effects.isAsync,
                  normalizedIsolation == nil || normalizedIsolation == "MainActor",
                  (normalizedIsolation == "MainActor")
                    == descriptor.effects.requiresMainActor
            else {
                throw Verification.Error.invalidShellInterface(
                    "native import \(descriptor.id) has inconsistent signature, effects, isolation, or capability"
                )
            }
            do {
                try descriptor.contract.validate(effects: descriptor.effects)
            } catch {
                throw Verification.Error.invalidShellInterface(
                    "native import \(descriptor.id) has an invalid contract: \(error)"
                )
            }
            guard callbacks == callbacks.sorted(),
                  Set(callbacks.map(\.parameterIndex)).count == callbacks.count,
                  callbacks.allSatisfy({
                Int($0.parameterIndex) < descriptor.parameterTypes.count
            }) else {
                throw Verification.Error.invalidShellInterface(
                    "native import \(descriptor.id) has an out-of-range callback parameter"
                )
            }
            let callbackByIndex = Dictionary(
                uniqueKeysWithValues: callbacks.map { (Int($0.parameterIndex), $0) }
            )
            for (parameterIndex, type) in descriptor.parameterTypes.enumerated() {
                if let callback = callbackByIndex[parameterIndex] {
                    try Self.validateNativeCallbackType(
                        type,
                        callback: callback,
                        owner: "native import \(descriptor.id) parameter \(parameterIndex)",
                        capabilities: capabilities
                    )
                } else {
                    guard type.isOrdinaryNativeImportBridgeValue else {
                        throw Verification.Error.invalidShellInterface(
                            "native import \(descriptor.id) has an unsupported ordinary parameter"
                        )
                    }
                    try Self.validateBoundaryType(
                        type,
                        owner: "native import \(descriptor.id)",
                        capabilities: capabilities
                    )
                }
            }
            guard !descriptor.resultType.containsClosureValue else {
                throw Verification.Error.invalidShellInterface(
                    "native import \(descriptor.id) cannot return a callback"
                )
            }
            guard descriptor.resultType.isNativeImportBridgeResult else {
                throw Verification.Error.invalidShellInterface(
                    "native import \(descriptor.id) has an unsupported result"
                )
            }
            try Self.validateBoundaryType(
                descriptor.resultType,
                owner: "native import \(descriptor.id)",
                capabilities: capabilities
            )
        }
    }

    private static func validateNativeCallbackType(
        _ type: Bytecode.ValueType,
        callback: Core.NativeImportCallback,
        owner: String,
        capabilities: Set<Core.Capability>
    ) throws {
        guard capabilities.contains(.closureValuesV1),
              callback.lifetime != .escaping
                || capabilities.contains(.escapingClosureValuesV1),
              let shape = type.directClosureShape,
              shape.signature.isNativeBridgeCallback,
              !shape.signature.parameters.contains(where: \.containsClosureValue)
                || capabilities.contains(.escapingClosureValuesV1),
              !(callback.lifetime == .nonescaping && shape.isOptional)
        else {
            throw Verification.Error.invalidShellInterface(
                "\(owner) must be a synchronous, nonthrowing callback with a bridgeable result and valid lifetime"
            )
        }
        for parameter in shape.signature.parameters {
            if let callable = parameter.directClosureShape {
                try validateNativeCallableArgument(
                    callable.signature,
                    owner: owner,
                    capabilities: capabilities
                )
            } else {
                guard parameter.isNativeBridgeValue else {
                    throw Verification.Error.invalidShellInterface(
                        "\(owner) has an unbridgeable callback argument"
                    )
                }
                try validateBoundaryType(
                    parameter,
                    owner: owner,
                    capabilities: capabilities,
                    allowingError: true
                )
            }
        }
        try validateBoundaryType(
            shape.signature.result,
            owner: owner,
            capabilities: capabilities
        )
    }

    private static func validateNativeCallableArgument(
        _ signature: Bytecode.ClosureSignature,
        owner: String,
        capabilities: Set<Core.Capability>
    ) throws {
        guard capabilities.contains(.escapingClosureValuesV1),
              signature.isNativeBridgeCallableArgument
        else {
            throw Verification.Error.invalidShellInterface(
                "\(owner) has an unsupported native callable argument"
            )
        }
        for parameter in signature.parameters {
            try validateBoundaryType(
                parameter,
                owner: owner,
                capabilities: capabilities,
                allowingError: true
            )
        }
        try validateBoundaryType(
            signature.result,
            owner: owner,
            capabilities: capabilities,
            allowingError: true
        )
    }

    private static func validateBoundaryType(
        _ type: Bytecode.ValueType,
        owner: String,
        capabilities: Set<Core.Capability>,
        allowingError: Bool = false,
        depth: Int = 0
    ) throws {
        guard depth <= 32 else {
            throw Verification.Error.invalidShellInterface(
                "type nesting in \(owner) exceeds 32 levels"
            )
        }
        switch type {
        case .any:
            guard capabilities.contains(.anyValuesV1) else {
                throw Verification.Error.invalidShellInterface(
                    "Any in \(owner) signature requires \(Core.Capability.anyValuesV1)"
                )
            }
        case .error:
            guard allowingError,
                  capabilities.contains(.structuredErrorsV1)
            else {
                throw Verification.Error.invalidShellInterface(
                    "Error in \(owner) is supported only in a NativeImport callback parameter with \(Core.Capability.structuredErrorsV1)"
                )
            }
        case .local, .address, .mutableCell, .nonOwningReference,
             .arrayState,
             .dictionaryState, .closure:
            // Local nominal identities exist only inside one verified image and
            // therefore cannot be frozen into a Shell ABI or NativeImport catalog.
            throw Verification.Error.invalidShellInterface(
                "patch-local nominal, internal storage, and closure values cannot appear in \(owner) signature"
            )
        case let .optional(element):
            try validateBoundaryType(
                element,
                owner: owner,
                capabilities: capabilities,
                allowingError: allowingError,
                depth: depth + 1
            )
        case let .array(element):
            try validateBoundaryType(
                element,
                owner: owner,
                capabilities: capabilities,
                allowingError: allowingError,
                depth: depth + 1
            )
            guard capabilities.contains(.collectionsV1) else {
                throw Verification.Error.invalidShellInterface(
                    "Array in \(owner) signature requires \(Core.Capability.collectionsV1)"
                )
            }
        case let .dictionary(key, value):
            try validateBoundaryType(
                key,
                owner: owner,
                capabilities: capabilities,
                allowingError: allowingError,
                depth: depth + 1
            )
            try validateBoundaryType(
                value,
                owner: owner,
                capabilities: capabilities,
                allowingError: allowingError,
                depth: depth + 1
            )
            guard capabilities.contains(.collectionsV1), key.isVMHashable else {
                throw Verification.Error.invalidShellInterface(
                    "Dictionary in \(owner) signature requires collection capability and a VM-defined Hashable key"
                )
            }
        case let .set(element):
            try validateBoundaryType(
                element,
                owner: owner,
                capabilities: capabilities,
                allowingError: allowingError,
                depth: depth + 1
            )
            guard capabilities.contains(.collectionsV1), element.isVMHashable else {
                throw Verification.Error.invalidShellInterface(
                    "Set in \(owner) signature requires collection capability and a VM-defined Hashable element"
                )
            }
        case let .tuple(elements):
            for element in elements {
                try validateBoundaryType(
                    element,
                    owner: owner,
                    capabilities: capabilities,
                    allowingError: allowingError,
                    depth: depth + 1
                )
            }
        case .void, .never, .bool, .integer, .float, .string, .native:
            break
        }
    }

    private static func uniqueDictionary<Element, Key: Hashable>(
        _ elements: [Element],
        key: KeyPath<Element, Key>,
        label: String
    ) throws -> [Key: Element] {
        var result: [Key: Element] = [:]
        for element in elements {
            let value = element[keyPath: key]
            guard result.updateValue(element, forKey: value) == nil else {
                throw Verification.Error.invalidShellInterface("duplicate \(label) \(value)")
            }
        }
        return result
    }
}
}
