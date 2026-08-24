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
    public var parameterConventions: [Bytecode.ParameterConvention]
    public var resultType: Bytecode.ValueType
    public var effects: Core.Effects
    public var fallbackAllowed: Bool

    public init(
        index: Core.EntryIndex,
        key: Core.FunctionKey,
        parameterTypes: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention],
        resultType: Bytecode.ValueType,
        effects: Core.Effects = .init(),
        fallbackAllowed: Bool = false
    ) {
        self.index = index
        self.key = key
        self.parameterTypes = parameterTypes
        self.parameterConventions = parameterConventions
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

public struct ResolvedFrozenValueType: Hashable, Sendable {
    public var definition: Bytecode.LocalTypeDefinition
    public var layoutFingerprint: Core.Digest
    public var isCopyable: Bool

    public init(
        definition: Bytecode.LocalTypeDefinition,
        layoutFingerprint: Core.Digest,
        isCopyable: Bool = true
    ) {
        self.definition = definition
        self.layoutFingerprint = layoutFingerprint
        self.isCopyable = isCopyable
    }

    public var key: Bytecode.LocalTypeKey { definition.key }
}

public struct ShellInterface: Sendable {
    public var interfaceHash: Core.Digest
    public var compatibility: Core.Compatibility
    public var capabilities: Set<Core.Capability>
    public var entries: [Core.EntryIndex: Verification.ResolvedEntry]
    public var imports: [Core.NativeImportID: Verification.ResolvedNativeImport]
    public var types: [Core.TypeID: Verification.ResolvedNativeType]
    public var frozenValueTypes: [
        Bytecode.LocalTypeKey: Verification.ResolvedFrozenValueType
    ]

    public init(
        interfaceHash: Core.Digest,
        compatibility: Core.Compatibility,
        capabilities: Set<Core.Capability> = [.baselineV1],
        entries: [Verification.ResolvedEntry] = [],
        imports: [Verification.ResolvedNativeImport] = [],
        types: [Verification.ResolvedNativeType] = [],
        frozenValueTypes: [Verification.ResolvedFrozenValueType] = []
    ) throws {
        self.interfaceHash = interfaceHash
        self.compatibility = compatibility
        self.capabilities = capabilities
        self.entries = try Self.uniqueDictionary(entries, key: \.index, label: "entry")
        self.imports = try Self.uniqueDictionary(imports, key: \.id, label: "native import")
        self.types = try Self.uniqueDictionary(types, key: \.id, label: "native type")
        self.frozenValueTypes = try Self.uniqueDictionary(
            frozenValueTypes,
            key: \.key,
            label: "frozen Shell value type"
        )
        try validateBoundarySignatures()
    }

    func validateBoundarySignatures() throws {
        try validateFrozenValueTypes()
        for index in entries.keys.sorted() {
            guard let entry = entries[index] else { continue }
            guard entry.parameterConventions.count
                    == entry.parameterTypes.count,
                  entry.parameterConventions.filter({ $0 == .inout }).count <= 1,
                  !(entry.effects.isAsync
                    && entry.parameterConventions.contains(.inout))
            else {
                throw Verification.Error.invalidShellInterface(
                    "entry \(entry.index) has invalid parameter ownership"
                )
            }
            if entry.parameterConventions.contains(.inout),
               !capabilities.contains(.addressValuesV1) {
                throw Verification.Error.invalidShellInterface(
                    "entry \(entry.index) uses writeback without "
                        + "\(Core.Capability.addressValuesV1)"
                )
            }
            if entry.parameterConventions.contains(.borrowed),
               !capabilities.contains(.borrowCallsV1) {
                throw Verification.Error.invalidShellInterface(
                    "entry \(entry.index) uses borrowed ownership without "
                        + "\(Core.Capability.borrowCallsV1)"
                )
            }
            for type in entry.parameterTypes + [entry.resultType] {
                try Self.validateBoundaryType(
                    type,
                    owner: "entry \(entry.index)",
                    capabilities: capabilities,
                    frozenValueTypes: frozenValueTypes,
                    allowingFrozenValue: true
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
                        capabilities: capabilities,
                        frozenValueTypes: frozenValueTypes
                    )
                }
            }
            guard descriptor.resultType.isNativeImportBridgeResult else {
                throw Verification.Error.invalidShellInterface(
                    "native import \(descriptor.id) has an unsupported result"
                )
            }
            if let callable = descriptor.resultType.directClosureShape {
                try Self.validateNativeCallable(
                    callable.signature,
                    owner: "native import \(descriptor.id) result",
                    capabilities: capabilities
                )
            } else {
                try Self.validateBoundaryType(
                    descriptor.resultType,
                    owner: "native import \(descriptor.id)",
                    capabilities: capabilities,
                    frozenValueTypes: frozenValueTypes
                )
            }
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
              !shape.signature.effects.requiresMainActor
                || capabilities.contains(.mainActorIsolationV1),
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
                try validateNativeCallable(
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
                        frozenValueTypes: [:],
                        allowingError: true
                )
            }
        }
        try validateBoundaryType(
            shape.signature.result,
            owner: owner,
            capabilities: capabilities,
            frozenValueTypes: [:]
        )
    }

    private static func validateNativeCallable(
        _ signature: Bytecode.ClosureSignature,
        owner: String,
        capabilities: Set<Core.Capability>
    ) throws {
        guard capabilities.contains(.closureValuesV1),
              capabilities.contains(.escapingClosureValuesV1),
              signature.isNativeBridgeCallable,
              !signature.effects.requiresMainActor
                || capabilities.contains(.mainActorIsolationV1)
        else {
            throw Verification.Error.invalidShellInterface(
                "\(owner) has an unsupported native callable"
            )
        }
        for parameter in signature.parameters {
            try validateBoundaryType(
                parameter,
                owner: owner,
                capabilities: capabilities,
                frozenValueTypes: [:],
                allowingError: true
            )
        }
        try validateBoundaryType(
            signature.result,
            owner: owner,
            capabilities: capabilities,
            frozenValueTypes: [:],
            allowingError: true
        )
    }

    private static func validateBoundaryType(
        _ type: Bytecode.ValueType,
        owner: String,
        capabilities: Set<Core.Capability>,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: Verification.ResolvedFrozenValueType
        ],
        allowingError: Bool = false,
        allowingFrozenValue: Bool = false,
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
        case let .local(key):
            guard allowingFrozenValue,
                  capabilities.contains(.localNominalsV1),
                  frozenValueTypes[key] != nil
            else {
                throw Verification.Error.invalidShellInterface(
                    "unfrozen local nominal \(key) cannot appear in \(owner) signature"
                )
            }
        case .address, .mutableCell, .nonOwningReference,
             .arrayState,
             .dictionaryState, .closure:
            throw Verification.Error.invalidShellInterface(
                "internal storage and closure values cannot appear in \(owner) signature"
            )
        case let .optional(element):
            try validateBoundaryType(
                element,
                owner: owner,
                capabilities: capabilities,
                frozenValueTypes: frozenValueTypes,
                allowingError: allowingError,
                allowingFrozenValue: allowingFrozenValue,
                depth: depth + 1
            )
        case let .array(element):
            try validateBoundaryType(
                element,
                owner: owner,
                capabilities: capabilities,
                frozenValueTypes: frozenValueTypes,
                allowingError: allowingError,
                allowingFrozenValue: allowingFrozenValue,
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
                frozenValueTypes: frozenValueTypes,
                allowingError: allowingError,
                allowingFrozenValue: allowingFrozenValue,
                depth: depth + 1
            )
            try validateBoundaryType(
                value,
                owner: owner,
                capabilities: capabilities,
                frozenValueTypes: frozenValueTypes,
                allowingError: allowingError,
                allowingFrozenValue: allowingFrozenValue,
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
                frozenValueTypes: frozenValueTypes,
                allowingError: allowingError,
                allowingFrozenValue: allowingFrozenValue,
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
                    frozenValueTypes: frozenValueTypes,
                    allowingError: allowingError,
                    allowingFrozenValue: allowingFrozenValue,
                    depth: depth + 1
                )
            }
        case .void, .never, .bool, .integer, .float, .string, .native:
            break
        }
    }

    private func validateFrozenValueTypes() throws {
        if !frozenValueTypes.isEmpty,
           !capabilities.contains(.localNominalsV1) {
            throw Verification.Error.invalidShellInterface(
                "frozen Shell values require \(Core.Capability.localNominalsV1)"
            )
        }
        var totalMembers = 0
        func validateStorage(_ type: Bytecode.ValueType, depth: Int) throws {
            guard depth <= 32 else {
                throw Verification.Error.invalidShellInterface(
                    "frozen Shell value storage exceeds 32 levels"
                )
            }
            switch type {
            case let .local(key):
                guard frozenValueTypes[key] != nil else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell value references unknown \(key)"
                    )
                }
            case let .integer(width, _):
                guard [8, 16, 32, 64].contains(width) else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell value contains unsupported integer width"
                    )
                }
            case let .float(width):
                guard width == 32 || width == 64 else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell value contains unsupported float width"
                    )
                }
            case let .array(element):
                guard capabilities.contains(.collectionsV1) else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell Array storage requires the collection capability"
                    )
                }
                try validateStorage(element, depth: depth + 1)
            case let .optional(element):
                try validateStorage(element, depth: depth + 1)
            case let .set(element):
                guard capabilities.contains(.collectionsV1),
                      element.isVMHashable else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell Set requires collection and VM-defined Hashable semantics"
                    )
                }
                try validateStorage(element, depth: depth + 1)
            case let .dictionary(key, value):
                guard capabilities.contains(.collectionsV1),
                      key.isVMHashable else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell Dictionary requires collection and VM-defined Hashable semantics"
                    )
                }
                try validateStorage(key, depth: depth + 1)
                try validateStorage(value, depth: depth + 1)
            case let .tuple(elements):
                guard elements.count <= 64 else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell tuple contains too many elements"
                    )
                }
                for element in elements {
                    try validateStorage(element, depth: depth + 1)
                }
            case .void, .never, .native, .error, .address, .mutableCell,
                 .nonOwningReference, .arrayState, .dictionaryState, .closure:
                throw Verification.Error.invalidShellInterface(
                    "frozen Shell value contains unsupported storage \(type)"
                )
            case .string:
                guard capabilities.contains(.stringsV1) else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell String storage requires the string capability"
                    )
                }
            case .any:
                guard capabilities.contains(.anyValuesV1) else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell Any storage requires the Any capability"
                    )
                }
            case .bool:
                break
            }
        }
        for key in frozenValueTypes.keys.sorted() {
            guard let record = frozenValueTypes[key], record.isCopyable,
                  record.definition.key == key,
                  !record.definition.conformsToError
                    || capabilities.contains(.structuredErrorsV1),
                  key.rawValue.split(separator: ".").allSatisfy({
                      Core.SwiftName.normalizedIdentifier(String($0)) != nil
                  })
            else {
                throw Verification.Error.invalidShellInterface(
                    "frozen Shell value \(key) has an unsupported conformance or identity"
                )
            }
            let memberCount: Int
            switch record.definition.kind {
            case let .structure(fields):
                memberCount = fields.count
                guard Set(fields.map(\.name)).count == fields.count,
                      fields.allSatisfy({
                          Core.SwiftName.normalizedIdentifier($0.name) != nil
                      })
                else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell struct \(key) has duplicate or invalid fields"
                    )
                }
                for field in fields {
                    try validateStorage(field.type, depth: 0)
                }
            case let .enumeration(cases):
                guard !cases.isEmpty,
                      Set(cases.map(\.name)).count == cases.count,
                      cases.allSatisfy({
                          Core.SwiftName.normalizedIdentifier($0.name) != nil
                      })
                else {
                    throw Verification.Error.invalidShellInterface(
                        "frozen Shell enum \(key) has empty, duplicate, or invalid cases"
                    )
                }
                var enumMemberCount = 0
                for item in cases {
                    if let payload = item.payloadType {
                        try validateStorage(payload, depth: 0)
                    }
                    let caseMemberCount: Int = switch item.payloadType {
                    case nil: 1
                    case let .tuple(elements): max(1, elements.count)
                    default: 1
                    }
                    let addition = enumMemberCount.addingReportingOverflow(
                        caseMemberCount
                    )
                    guard !addition.overflow,
                          addition.partialValue <= 65_536 else {
                        throw Verification.Error.invalidShellInterface(
                            "frozen Shell enum \(key) contains too many associated values"
                        )
                    }
                    enumMemberCount = addition.partialValue
                }
                memberCount = enumMemberCount
            case .class:
                throw Verification.Error.invalidShellInterface(
                    "frozen Shell value \(key) cannot be a class"
                )
            }
            let addition = totalMembers.addingReportingOverflow(memberCount)
            guard !addition.overflow, addition.partialValue <= 65_536 else {
                throw Verification.Error.invalidShellInterface(
                    "frozen Shell values contain too many members"
                )
            }
            totalMembers = addition.partialValue
        }

        // Count the expanded value graph, not nominal and wrapper nesting as
        // independent dimensions. This keeps every accepted frozen shape
        // constructible under the same bounded bridge contract.
        var visiting = Set<Bytecode.LocalTypeKey>()
        var depthByKey: [Bytecode.LocalTypeKey: Int] = [:]

        func checkedDepth(_ value: Int, owner: Bytecode.LocalTypeKey) throws -> Int {
            guard value <= 32 else {
                throw Verification.Error.invalidShellInterface(
                    "frozen Shell value graph exceeds 32 levels at \(owner)"
                )
            }
            return value
        }

        func depth(
            of type: Bytecode.ValueType,
            owner: Bytecode.LocalTypeKey
        ) throws -> Int {
            switch type {
            case let .local(dependency):
                return try depth(of: dependency)
            case let .array(element), let .optional(element), let .set(element):
                return try checkedDepth(
                    1 + depth(of: element, owner: owner),
                    owner: owner
                )
            case let .dictionary(key, value):
                return try checkedDepth(
                    1 + max(
                        depth(of: key, owner: owner),
                        depth(of: value, owner: owner)
                    ),
                    owner: owner
                )
            case let .tuple(elements):
                let childDepth = try elements.map {
                    try depth(of: $0, owner: owner)
                }.max() ?? 0
                return try checkedDepth(1 + childDepth, owner: owner)
            default:
                return 1
            }
        }

        func depth(of key: Bytecode.LocalTypeKey) throws -> Int {
            if let depth = depthByKey[key] { return depth }
            guard visiting.insert(key).inserted,
                  let record = frozenValueTypes[key]
            else {
                throw Verification.Error.invalidShellInterface(
                    "frozen Shell value graph is recursive or incomplete at \(key)"
                )
            }
            defer { visiting.remove(key) }
            let members: [Bytecode.ValueType]
            switch record.definition.kind {
            case let .structure(fields):
                members = fields.map(\.type)
            case let .enumeration(cases):
                members = cases.compactMap(\.payloadType)
            case .class:
                throw Verification.Error.invalidShellInterface(
                    "frozen Shell value \(key) cannot be a class"
                )
            }
            let memberDepth = try members.map {
                try depth(of: $0, owner: key)
            }.max() ?? 0
            let result = try checkedDepth(1 + memberDepth, owner: key)
            depthByKey[key] = result
            return result
        }

        for key in frozenValueTypes.keys.sorted() {
            _ = try depth(of: key)
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
