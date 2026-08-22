import Foundation
import HelixBytecode
import HelixCore
import HelixInterface

/// Build-time authority for native operations that an HLBC patch may invoke.
/// The catalog names typed factories; it never grants on-device symbol lookup.
public enum NativeImportCatalog {}

extension NativeImportCatalog {
public struct NativeType: Codable, Hashable, Sendable {
    public var canonicalName: String
    public var kind: InterfaceArchive.TypeKind
    public var layoutFingerprint: Core.Digest
    public var isCopyable: Bool
    public var requiresMainActor: Bool
    public var estimatedSize: UInt64
    public var factoryType: String
    public var importedModules: [String]

    public init(
        canonicalName: String,
        kind: InterfaceArchive.TypeKind,
        layoutFingerprint: Core.Digest,
        isCopyable: Bool,
        requiresMainActor: Bool = false,
        estimatedSize: UInt64,
        factoryType: String,
        importedModules: [String]
    ) {
        self.canonicalName = canonicalName
        self.kind = kind
        self.layoutFingerprint = layoutFingerprint
        self.isCopyable = isCopyable
        self.requiresMainActor = requiresMainActor
        self.estimatedSize = estimatedSize
        self.factoryType = factoryType
        self.importedModules = importedModules.sorted()
    }
}

public struct Candidate: Codable, Hashable, Sendable {
    public var canonicalCallee: String
    public var silMangledNames: [String]
    public var signature: Core.LoweredSignature
    public var effects: Core.Effects
    public var contract: Core.NativeImportContract
    public var capability: Core.Capability
    public var factoryType: String
    public var importedModules: [String]

    public init(
        canonicalCallee: String,
        silMangledNames: [String],
        signature: Core.LoweredSignature,
        effects: Core.Effects = .init(),
        contract: Core.NativeImportContract,
        capability: Core.Capability = .nativeImportsV1,
        factoryType: String,
        importedModules: [String]
    ) {
        self.canonicalCallee = canonicalCallee
        self.silMangledNames = silMangledNames.sorted()
        self.signature = signature
        self.effects = effects
        self.contract = contract
        self.capability = capability
        self.factoryType = factoryType
        self.importedModules = importedModules.sorted()
    }

    fileprivate var orderKey: String {
        "\(silMangledNames.first ?? ""):\(canonicalCallee)"
    }
}

public struct Document: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var nativeTypes: [NativeImportCatalog.NativeType]
    public var candidates: [NativeImportCatalog.Candidate]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        nativeTypes: [NativeImportCatalog.NativeType] = [],
        candidates: [NativeImportCatalog.Candidate]
    ) {
        self.schemaVersion = schemaVersion
        self.nativeTypes = nativeTypes.map { type in
            var value = type
            value.importedModules = Array(Set(value.importedModules)).sorted()
            return value
        }.sorted { $0.canonicalName < $1.canonicalName }
        self.candidates = candidates.map { candidate in
            var value = candidate
            value.silMangledNames = Array(Set(value.silMangledNames)).sorted()
            value.importedModules = Array(Set(value.importedModules)).sorted()
            return value
        }.sorted { $0.orderKey < $1.orderKey }
    }

    public static let empty = Self(candidates: [])

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NativeImportCatalog.Error.unsupportedSchema(schemaVersion)
        }
        guard nativeTypes.count <= 1_024,
              nativeTypes == nativeTypes.sorted(by: { $0.canonicalName < $1.canonicalName }),
              Set(nativeTypes.map(\.canonicalName)).count == nativeTypes.count,
              candidates.count <= 4_096,
              candidates == candidates.sorted(by: { $0.orderKey < $1.orderKey }),
              Set(candidates.map(\.orderKey)).count == candidates.count,
              Set(candidates.flatMap(\.silMangledNames)).count
                  == candidates.reduce(0, { $0 + $1.silMangledNames.count })
        else {
            throw NativeImportCatalog.Error.invalid(
                "types or candidates are oversized, duplicated, or not canonical"
            )
        }
        for type in nativeTypes {
            guard Self.isQualifiedSwiftName(type.canonicalName),
                  !type.canonicalName.hasPrefix("Swift."),
                  type.estimatedSize > 0,
                  type.estimatedSize <= 16 * 1_024 * 1_024,
                  type.kind != .reference || type.isCopyable,
                  !type.canonicalName.hasPrefix("UIKit.") || type.requiresMainActor,
                  Self.isQualifiedSwiftName(type.factoryType),
                  type.importedModules == Array(Set(type.importedModules)).sorted(),
                  !type.importedModules.isEmpty,
                  type.importedModules.allSatisfy(Self.isModulePath),
                  type.importedModules.contains(
                      String(type.factoryType.split(separator: ".")[0])
                  )
            else {
                throw NativeImportCatalog.Error.invalid(
                    "native type \(type.canonicalName) has an invalid layout, factory, or module"
                )
            }
        }
        let nativeTypeIDs = Dictionary(uniqueKeysWithValues: nativeTypes.map { type in
            (
                type.canonicalName,
                Core.TypeID(rawValue: .sha256("HLX.CatalogType.v1:\(type.canonicalName)"))
            )
        })
        let mainActorTypeIDs = Set(nativeTypes.filter(\.requiresMainActor).map {
            nativeTypeIDs[$0.canonicalName]!
        })
        for candidate in candidates {
            let signatureParameters = candidate.signature.parameters.map {
                FrontendReceipt.ValueTypeParser.parse(
                    $0,
                    allowVoid: false,
                    nativeTypes: nativeTypeIDs
                )
            }
            let signatureResult = FrontendReceipt.ValueTypeParser.parse(
                candidate.signature.result,
                allowVoid: true,
                nativeTypes: nativeTypeIDs
            )
            let normalizedIsolation = candidate.signature.isolation.map {
                $0 == "Swift.MainActor" ? "MainActor" : $0
            }
            guard Self.isBoundText(candidate.canonicalCallee, maximumBytes: 4_096),
                  !candidate.silMangledNames.isEmpty,
                  candidate.silMangledNames.count <= 32,
                  candidate.silMangledNames == Array(Set(candidate.silMangledNames)).sorted(),
                  candidate.silMangledNames.allSatisfy(Self.isSILSymbol),
                  !signatureParameters.contains(where: { $0 == nil }),
                  signatureResult != nil,
                  candidate.signature.isThrowing == candidate.effects.mayThrow,
                  (normalizedIsolation == "MainActor")
                      == candidate.effects.requiresMainActor,
                  normalizedIsolation == nil || normalizedIsolation == "MainActor",
                  candidate.capability == .nativeImportsV1,
                  Self.isQualifiedSwiftName(candidate.factoryType),
                  candidate.importedModules == Array(Set(candidate.importedModules)).sorted(),
                  !candidate.importedModules.isEmpty,
                  candidate.importedModules.allSatisfy(Self.isModulePath),
                  candidate.importedModules.contains(
                      String(candidate.factoryType.split(separator: ".")[0])
                  ),
                  FrontendReceipt.NativeBridgeProfile.isResult(
                      signatureResult!
                  ),
                  FrontendReceipt.NativeBridgeProfile.callbacks(
                      parameterSpellings: candidate.signature.parameters,
                      parameterTypes: signatureParameters.compactMap { $0 }
                  ) == candidate.contract.callbacks
            else {
                throw NativeImportCatalog.Error.invalid(
                    "candidate \(candidate.canonicalCallee) has an invalid symbol, signature, factory, or type"
                )
            }
            do {
                try candidate.contract.validate(effects: candidate.effects)
            } catch {
                throw NativeImportCatalog.Error.invalid(
                    "candidate \(candidate.canonicalCallee) has an invalid contract: \(error)"
                )
            }
            let signatureUsesMainActorType = signatureParameters.compactMap({ $0 }).contains {
                Self.containsNativeType($0, ids: mainActorTypeIDs)
            } || Self.containsNativeType(signatureResult!, ids: mainActorTypeIDs)
            guard !signatureUsesMainActorType || candidate.effects.requiresMainActor else {
                throw NativeImportCatalog.Error.invalid(
                    "candidate \(candidate.canonicalCallee) moves a MainActor native type off actor"
                )
            }
            if candidate.contract.kind == .initializer {
                guard candidate.effects.mayAllocate,
                      signatureResult != .void,
                      signatureResult != .never
                else {
                    throw NativeImportCatalog.Error.invalid(
                        "initializer \(candidate.canonicalCallee) must allocate and return a value"
                    )
                }
            }
        }
    }

    private static func containsNativeType(
        _ type: Bytecode.ValueType,
        ids: Set<Core.TypeID>
    ) -> Bool {
        switch type {
        case let .native(id): ids.contains(id)
        case let .array(element), let .optional(element), let .set(element),
             let .address(element), let .mutableCell(element),
             let .nonOwningReference(_, element),
             let .arrayState(_, element):
            containsNativeType(element, ids: ids)
        case let .dictionary(key, value):
            containsNativeType(key, ids: ids) || containsNativeType(value, ids: ids)
        case let .dictionaryState(key, value):
            containsNativeType(key, ids: ids) || containsNativeType(value, ids: ids)
        case let .tuple(elements):
            elements.contains { containsNativeType($0, ids: ids) }
        case let .closure(signature):
            (signature.parameters + [signature.result]).contains {
                containsNativeType($0, ids: ids)
            }
        case .void, .never, .bool, .integer, .float, .string, .any, .local,
             .error:
            false
        }
    }

    private static func isBoundText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains { $0.value < 0x20 }
    }

    private static func isSILSymbol(_ value: String) -> Bool {
        value.utf8.count <= 4_096 && value.utf8.allSatisfy {
            $0 > 0x20 && $0 != 0x3a && $0 != 0x40
        }
    }

    private static func isQualifiedSwiftName(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2 && components.allSatisfy(isSwiftIdentifier)
    }

    private static func isModulePath(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy(isSwiftIdentifier)
    }

    private static func isSwiftIdentifier(_ value: Substring) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt16)
    case documentTooLarge(actual: Int, maximum: Int)
    case nonCanonical
    case invalid(String)

    public var description: String {
        switch self {
        case let .unsupportedSchema(version):
            "unsupported NativeImport Catalog schema \(version)"
        case let .documentTooLarge(actual, maximum):
            "NativeImport Catalog is \(actual) bytes; maximum is \(maximum)"
        case .nonCanonical: "NativeImport Catalog is not canonical JSON"
        case let .invalid(reason): "invalid NativeImport Catalog: \(reason)"
        }
    }
}

public enum Codec {
    public static let maximumDocumentBytes = 8 * 1_024 * 1_024

    public static func encode(_ document: NativeImportCatalog.Document) throws -> Data {
        try document.validate()
        return try Core.CanonicalJSON.encode(document)
    }

    public static func decode(_ data: Data) throws -> NativeImportCatalog.Document {
        guard data.count <= maximumDocumentBytes else {
            throw NativeImportCatalog.Error.documentTooLarge(
                actual: data.count,
                maximum: maximumDocumentBytes
            )
        }
        let document: NativeImportCatalog.Document
        do {
            document = try JSONDecoder().decode(NativeImportCatalog.Document.self, from: data)
        } catch {
            throw NativeImportCatalog.Error.invalid(String(describing: error))
        }
        guard try Core.CanonicalJSON.encode(document) == data else {
            throw NativeImportCatalog.Error.nonCanonical
        }
        try document.validate()
        return document
    }
}
}
