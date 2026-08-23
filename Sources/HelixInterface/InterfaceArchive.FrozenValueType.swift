import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

extension InterfaceArchive {
public struct FrozenStoredProperty: Codable, Hashable, Sendable {
    public var name: String
    public var swiftType: String
    public var type: Bytecode.ValueType

    public init(name: String, swiftType: String, type: Bytecode.ValueType) {
        self.name = name
        self.swiftType = swiftType
        self.type = type
    }
}

public struct FrozenEnumAssociatedValue: Codable, Hashable, Sendable {
    /// `nil` represents an unlabeled (`_`) associated value.
    public var label: String?
    public var swiftType: String
    public var type: Bytecode.ValueType

    public init(
        label: String? = nil,
        swiftType: String,
        type: Bytecode.ValueType
    ) {
        self.label = label
        self.swiftType = swiftType
        self.type = type
    }
}

public struct FrozenEnumCase: Codable, Hashable, Sendable {
    public var name: String
    public var associatedValues: [InterfaceArchive.FrozenEnumAssociatedValue]

    public init(
        name: String,
        associatedValues: [InterfaceArchive.FrozenEnumAssociatedValue] = []
    ) {
        self.name = name
        self.associatedValues = associatedValues
    }

    public var payloadType: Bytecode.ValueType? {
        switch associatedValues.count {
        case 0:
            nil
        case 1 where associatedValues[0].label == nil:
            associatedValues[0].type
        default:
            .tuple(associatedValues.map(\.type))
        }
    }
}

public enum FrozenValueTypeKind: Codable, Hashable, Sendable {
    case structure(fields: [InterfaceArchive.FrozenStoredProperty])
    case enumeration(cases: [InterfaceArchive.FrozenEnumCase])
}

/// A source-defined Shell value whose logical aggregate shape is permitted to
/// cross an HLBC entry. This is a structural codec contract, never permission
/// to inspect Swift's native memory layout or synthesize runtime metadata.
public struct FrozenValueTypeRecord: Codable, Hashable, Sendable {
    public var key: Bytecode.LocalTypeKey
    public var canonicalName: String
    public var sourceFileLogicalID: String
    public var kind: InterfaceArchive.FrozenValueTypeKind
    public var conformsToError: Bool
    public var isCopyable: Bool
    public var layoutFingerprint: Core.Digest

    public init(
        key: Bytecode.LocalTypeKey,
        canonicalName: String,
        sourceFileLogicalID: String,
        kind: InterfaceArchive.FrozenValueTypeKind,
        conformsToError: Bool = false,
        isCopyable: Bool = true
    ) throws {
        self.key = key
        self.canonicalName = canonicalName
        self.sourceFileLogicalID = sourceFileLogicalID
        self.kind = kind
        self.conformsToError = conformsToError
        self.isCopyable = isCopyable
        layoutFingerprint = try Self.layoutFingerprint(
            key: key,
            canonicalName: canonicalName,
            kind: kind,
            conformsToError: conformsToError,
            isCopyable: isCopyable
        )
    }

    public var definition: Bytecode.LocalTypeDefinition {
        let definitionKind: Bytecode.LocalTypeKind = switch kind {
        case let .structure(fields):
            .structure(
                fields: fields.map {
                    .init(name: $0.name, type: $0.type)
                }
            )
        case let .enumeration(cases):
            .enumeration(
                cases: cases.map {
                    .init(name: $0.name, payloadType: $0.payloadType)
                }
            )
        }
        return .init(
            key: key,
            kind: definitionKind,
            conformsToError: conformsToError
        )
    }

    public func expectedLayoutFingerprint() throws -> Core.Digest {
        try Self.layoutFingerprint(
            key: key,
            canonicalName: canonicalName,
            kind: kind,
            conformsToError: conformsToError,
            isCopyable: isCopyable
        )
    }

    public func swiftType(moduleName: String) -> String {
        let prefix = moduleName + "."
        return canonicalName.hasPrefix(prefix)
            ? String(canonicalName.dropFirst(prefix.count))
            : canonicalName
    }

    /// A deterministic private source hook and generated codec suffix.
    public var codecIdentifier: String {
        "frozenValue_" + layoutFingerprint.hex
    }

    /// Whether every source spelling can be emitted as generated Swift without
    /// escaping a declaration or creating ambiguous member identities.
    public var hasSafeSourceCodecShape: Bool {
        guard Self.isSafeTypePath(key.rawValue) else { return false }
        switch kind {
        case let .structure(fields):
            return Set(fields.map(\.name)).count == fields.count
                && fields.allSatisfy {
                    Self.isSafeDeclarationIdentifier($0.name)
                        && Self.isSafeSwiftTypeSpelling($0.swiftType)
                }
        case let .enumeration(cases):
            return !cases.isEmpty
                && Set(cases.map(\.name)).count == cases.count
                && cases.allSatisfy { item in
                    Self.isSafeDeclarationIdentifier(item.name)
                        && item.associatedValues.count <= 64
                        && item.associatedValues.allSatisfy { associated in
                            (associated.label.map(
                                Self.isSafeDeclarationIdentifier
                            ) ?? true)
                                && Self.isSafeSwiftTypeSpelling(
                                    associated.swiftType
                                )
                        }
                }
        }
    }

    private struct LayoutProjection: Codable {
        var key: Bytecode.LocalTypeKey
        var canonicalName: String
        var kind: InterfaceArchive.FrozenValueTypeKind
        var conformsToError: Bool
        var isCopyable: Bool
    }

    private static func layoutFingerprint(
        key: Bytecode.LocalTypeKey,
        canonicalName: String,
        kind: InterfaceArchive.FrozenValueTypeKind,
        conformsToError: Bool,
        isCopyable: Bool
    ) throws -> Core.Digest {
        var hasher = Core.StableHasher(domain: "HLXI.FrozenValueLayout.v1")
        hasher.append(
            try Core.CanonicalJSON.encode(
                LayoutProjection(
                    key: key,
                    canonicalName: canonicalName,
                    kind: kind,
                    conformsToError: conformsToError,
                    isCopyable: isCopyable
                )
            )
        )
        return hasher.finalize()
    }

    private static func isSafeTypePath(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".").allSatisfy {
            Core.SwiftName.normalizedIdentifier(String($0)) != nil
        }
    }

    private static func isSafeDeclarationIdentifier(_ value: String) -> Bool {
        Core.SwiftName.normalizedIdentifier(value) != nil
    }

    private static func isSafeSwiftTypeSpelling(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 * 1_024 else {
            return false
        }
        let punctuation = CharacterSet(charactersIn: "._<>()[],:?&@- ")
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || punctuation.contains($0)
        }
    }
}
}

extension InterfaceArchive.Archive {
    func validateFrozenValueTypes() throws {
        let moduleName = metadata.frontendInvocation.moduleName
        let sourcePaths = Set(sources.map(\.logicalPath))
        guard frozenValueTypes == frozenValueTypes.sorted(by: { $0.key < $1.key }),
              Set(frozenValueTypes.map(\.key)).count == frozenValueTypes.count,
              Set(frozenValueTypes.map(\.canonicalName)).count == frozenValueTypes.count
        else {
            throw InterfaceArchive.Error.invalidArchive(
                "frozen Shell value types are duplicated or unordered"
            )
        }
        if !frozenValueTypes.isEmpty,
           !capabilities.contains(.localNominalsV1) {
            throw InterfaceArchive.Error.invalidArchive(
                "frozen Shell value types require the local-nominals capability"
            )
        }

        let byKey = Dictionary(
            uniqueKeysWithValues: frozenValueTypes.map { ($0.key, $0) }
        )
        var totalMembers = 0
        for record in frozenValueTypes {
            guard record.canonicalName == "\(moduleName).\(record.key.rawValue)",
                  sourcePaths.contains(record.sourceFileLogicalID),
                  record.isCopyable,
                  !record.conformsToError
                    || capabilities.contains(.structuredErrorsV1),
                  record.layoutFingerprint == (try record.expectedLayoutFingerprint()),
                  record.hasSafeSourceCodecShape
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "frozen Shell value type \(record.key) has invalid identity, source, conformance, copyability, or layout"
                )
            }
            let memberCount: Int
            switch record.kind {
            case let .structure(fields):
                memberCount = fields.count
                guard Set(fields.map(\.name)).count == fields.count else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell struct \(record.key) has duplicate fields"
                    )
                }
                for field in fields {
                    guard Self.isSafeDeclarationIdentifier(field.name),
                          Self.isSafeSwiftTypeSpelling(field.swiftType)
                    else {
                        throw InterfaceArchive.Error.invalidArchive(
                            "frozen Shell struct \(record.key) has an unsafe field spelling"
                        )
                    }
                }
            case let .enumeration(cases):
                guard !cases.isEmpty,
                      Set(cases.map(\.name)).count == cases.count
                else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell enum \(record.key) has empty or duplicate cases"
                    )
                }
                var enumMemberCount = 0
                for item in cases {
                    guard Self.isSafeDeclarationIdentifier(item.name),
                          item.associatedValues.count <= 64
                    else {
                        throw InterfaceArchive.Error.invalidArchive(
                            "frozen Shell enum \(record.key) has an invalid case"
                        )
                    }
                    for associated in item.associatedValues {
                        guard associated.label.map(
                            Self.isSafeDeclarationIdentifier
                        ) ?? true,
                        Self.isSafeSwiftTypeSpelling(associated.swiftType)
                        else {
                            throw InterfaceArchive.Error.invalidArchive(
                                "frozen Shell enum \(record.key) has an unsafe associated-value spelling"
                            )
                        }
                    }
                    let addition = enumMemberCount.addingReportingOverflow(
                        max(1, item.associatedValues.count)
                    )
                    guard !addition.overflow,
                          addition.partialValue <= 65_536 else {
                        throw InterfaceArchive.Error.invalidArchive(
                            "frozen Shell enum \(record.key) contains too many associated values"
                        )
                    }
                    enumMemberCount = addition.partialValue
                }
                memberCount = enumMemberCount
            }
            let addition = totalMembers.addingReportingOverflow(memberCount)
            guard !addition.overflow, addition.partialValue <= 65_536 else {
                throw InterfaceArchive.Error.invalidArchive(
                    "frozen Shell value types contain too many members"
                )
            }
            totalMembers = addition.partialValue
        }

        func validateMemberType(
            _ type: Bytecode.ValueType,
            depth: Int
        ) throws {
            guard depth <= 32 else {
                throw InterfaceArchive.Error.invalidArchive(
                    "frozen Shell value type nesting exceeds 32 levels"
                )
            }
            switch type {
            case .void, .never, .native, .error, .address, .mutableCell,
                 .nonOwningReference, .arrayState, .dictionaryState, .closure:
                throw InterfaceArchive.Error.invalidArchive(
                    "frozen Shell value type contains unsupported storage \(type)"
                )
            case let .integer(width, _):
                guard [8, 16, 32, 64].contains(width) else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell value type contains unsupported integer width"
                    )
                }
            case let .float(width):
                guard width == 32 || width == 64 else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell value type contains unsupported float width"
                    )
                }
            case let .local(key):
                guard byKey[key] != nil else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell value type references unknown \(key)"
                    )
                }
            case let .array(element):
                guard capabilities.contains(.collectionsV1) else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell Array storage requires the collection capability"
                    )
                }
                try validateMemberType(element, depth: depth + 1)
            case let .optional(element):
                try validateMemberType(element, depth: depth + 1)
            case let .set(element):
                guard capabilities.contains(.collectionsV1),
                      element.isVMHashable else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell Set requires collection and VM-defined Hashable semantics"
                    )
                }
                try validateMemberType(element, depth: depth + 1)
            case let .dictionary(key, value):
                guard capabilities.contains(.collectionsV1),
                      key.isVMHashable else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell Dictionary requires collection and VM-defined Hashable semantics"
                    )
                }
                try validateMemberType(key, depth: depth + 1)
                try validateMemberType(value, depth: depth + 1)
            case let .tuple(elements):
                guard elements.count <= 64 else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell tuple contains too many elements"
                    )
                }
                for element in elements {
                    try validateMemberType(element, depth: depth + 1)
                }
            case .string:
                guard capabilities.contains(.stringsV1) else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell String storage requires the string capability"
                    )
                }
            case .any:
                guard capabilities.contains(.anyValuesV1) else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "frozen Shell Any storage requires the Any capability"
                    )
                }
            case .bool:
                break
            }
        }
        for record in frozenValueTypes {
            switch record.kind {
            case let .structure(fields):
                for field in fields {
                    try validateMemberType(field.type, depth: 0)
                }
            case let .enumeration(cases):
                for item in cases {
                    if let payload = item.payloadType {
                        try validateMemberType(payload, depth: 0)
                    }
                }
            }
        }

        // The expanded logical value depth includes both container wrappers and
        // referenced frozen nominals. Checking those axes independently would
        // admit a type whose every runtime value necessarily exceeds the bridge
        // nesting contract.
        var visiting = Set<Bytecode.LocalTypeKey>()
        var depthByKey: [Bytecode.LocalTypeKey: Int] = [:]

        func checkedDepth(_ value: Int, owner: Bytecode.LocalTypeKey) throws -> Int {
            guard value <= 32 else {
                throw InterfaceArchive.Error.invalidArchive(
                    "frozen Shell value type graph exceeds 32 levels at \(owner)"
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
            guard visiting.insert(key).inserted, let record = byKey[key] else {
                throw InterfaceArchive.Error.invalidArchive(
                    "frozen Shell value type graph is recursive or incomplete at \(key)"
                )
            }
            defer { visiting.remove(key) }
            let members: [Bytecode.ValueType] = switch record.kind {
            case let .structure(fields): fields.map(\.type)
            case let .enumeration(cases): cases.compactMap(\.payloadType)
            }
            let memberDepth = try members.map {
                try depth(of: $0, owner: key)
            }.max() ?? 0
            let result = try checkedDepth(1 + memberDepth, owner: key)
            depthByKey[key] = result
            return result
        }

        for key in byKey.keys.sorted() {
            _ = try depth(of: key)
        }
    }

    private static func isSafeTypePath(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".").allSatisfy {
            Core.SwiftName.normalizedIdentifier(String($0)) != nil
        }
    }

    private static func isSafeDeclarationIdentifier(_ value: String) -> Bool {
        Core.SwiftName.normalizedIdentifier(value) != nil
    }

    private static func isSafeSwiftTypeSpelling(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 * 1_024 else {
            return false
        }
        let punctuation = CharacterSet(charactersIn: "._<>()[],:?&@- ")
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || punctuation.contains($0)
        }
    }
}
