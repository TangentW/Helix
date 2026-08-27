import Foundation
import HelixCore

/// Cached compiler and SDK facts used to resolve native calls. Projects never
/// maintain this database by hand; Hub and the build tools publish it.
public enum NativeAPICatalog {}

extension NativeAPICatalog {
public enum Provenance: String, Codable, Hashable, Sendable, CaseIterable {
    case systemSDK
    case thirdPartyModule
    case applicationModule
    case helixBuiltin
}

public struct Identity: Codable, Hashable, Sendable {
    public static let currentRulesVersion: UInt16 = 1

    public var provenance: NativeAPICatalog.Provenance
    public var xcodeProductBuild: String
    public var sdkProductBuild: String
    public var compilerFingerprint: String
    public var targetTriple: String
    public var minimumDeployment: Core.SemanticVersion
    public var swiftLanguageMode: String
    public var moduleName: String
    /// Aggregate of `.swiftinterface`, `.swiftmodule`, Clang declarations, and
    /// binary content that can change the imported API or ABI.
    public var moduleContentHash: Core.Digest
    public var moduleSearchPathHash: Core.Digest
    public var dependencyGraphHash: Core.Digest
    public var rulesVersion: UInt16

    public init(
        provenance: NativeAPICatalog.Provenance,
        xcodeProductBuild: String,
        sdkProductBuild: String,
        compilerFingerprint: String,
        targetTriple: String,
        minimumDeployment: Core.SemanticVersion,
        swiftLanguageMode: String,
        moduleName: String,
        moduleContentHash: Core.Digest,
        moduleSearchPathHash: Core.Digest,
        dependencyGraphHash: Core.Digest,
        rulesVersion: UInt16 = Self.currentRulesVersion
    ) {
        self.provenance = provenance
        self.xcodeProductBuild = xcodeProductBuild
        self.sdkProductBuild = sdkProductBuild
        self.compilerFingerprint = compilerFingerprint
        self.targetTriple = targetTriple
        self.minimumDeployment = minimumDeployment
        self.swiftLanguageMode = swiftLanguageMode
        self.moduleName = moduleName
        self.moduleContentHash = moduleContentHash
        self.moduleSearchPathHash = moduleSearchPathHash
        self.dependencyGraphHash = dependencyGraphHash
        self.rulesVersion = rulesVersion
    }

    public var cacheKey: Core.Digest {
        var hasher = Core.StableHasher(domain: "HLX.APICatalog.v1")
        hasher.append(provenance.rawValue)
        hasher.append(xcodeProductBuild)
        hasher.append(sdkProductBuild)
        hasher.append(compilerFingerprint)
        hasher.append(targetTriple)
        hasher.append(minimumDeployment.description)
        hasher.append(swiftLanguageMode)
        hasher.append(moduleName)
        hasher.append(moduleContentHash)
        hasher.append(moduleSearchPathHash)
        hasher.append(dependencyGraphHash)
        hasher.append(rulesVersion)
        return hasher.finalize()
    }
}

public enum SupportState: String, Codable, Hashable, Sendable, CaseIterable {
    case supported
    case unsupported
}

public struct Support: Codable, Hashable, Sendable {
    public var state: NativeAPICatalog.SupportState
    public var reasonCode: String?
    public var explanation: String?

    public init(
        state: NativeAPICatalog.SupportState,
        reasonCode: String? = nil,
        explanation: String? = nil
    ) {
        self.state = state
        self.reasonCode = reasonCode
        self.explanation = explanation
    }

    public static let supported = Self(state: .supported)

    public static func unsupported(
        code: String,
        explanation: String
    ) -> Self {
        .init(
            state: .unsupported,
            reasonCode: code,
            explanation: explanation
        )
    }
}

public enum BindingStrategy: String, Codable, Hashable, Sendable, CaseIterable {
    case objectiveCInvoker
    case cInvoker
    case swiftAdapter
    case builtin
}

public struct Binding: Codable, Hashable, Sendable {
    public var strategy: NativeAPICatalog.BindingStrategy
    /// Stable Adapter Pack entry. Generic Objective-C and C invokers do not
    /// need one because their call plan comes entirely from the descriptor.
    public var adapterID: String?
    public var importedModules: [String]

    public init(
        strategy: NativeAPICatalog.BindingStrategy,
        adapterID: String? = nil,
        importedModules: [String] = []
    ) {
        self.strategy = strategy
        self.adapterID = adapterID
        self.importedModules = Array(Set(importedModules)).sorted()
    }
}

public struct Entry: Codable, Hashable, Sendable {
    public var key: Core.NativeCall.Key
    public var descriptor: Core.NativeCall.Descriptor
    /// Scheduling and policy authority is cataloged with the API but remains
    /// outside `key`; changing a deadline never creates a different API.
    public var contract: Core.NativeImportContract
    /// Source-facing names accepted by the compiler. They are lookup aliases,
    /// not part of `Key`, because import spelling can change independently.
    public var swiftNames: [String]
    /// USRs and canonical compiler symbols used only while matching frontend
    /// output. Runtime code never resolves or invokes these strings.
    public var compilerSymbols: [String]
    public var support: NativeAPICatalog.Support
    public var binding: NativeAPICatalog.Binding?

    public init(
        descriptor: Core.NativeCall.Descriptor,
        contract: Core.NativeImportContract,
        swiftNames: [String] = [],
        compilerSymbols: [String] = [],
        support: NativeAPICatalog.Support = .supported,
        binding: NativeAPICatalog.Binding?
    ) throws {
        let validated = try descriptor.validatedIdentity(contract: contract)
        self.key = validated.key
        self.descriptor = validated.descriptor
        self.contract = contract
        self.swiftNames = Array(
            Set(swiftNames + [validated.descriptor.canonicalCallee])
        ).sorted()
        self.compilerSymbols = Array(Set(compilerSymbols)).sorted()
        self.support = support
        self.binding = binding
    }
}

public struct Document: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var identity: NativeAPICatalog.Identity
    public var entries: [NativeAPICatalog.Entry]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        identity: NativeAPICatalog.Identity,
        entries: [NativeAPICatalog.Entry]
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.entries = entries.map { item in
            var value = item
            value.swiftNames = Array(Set(value.swiftNames)).sorted()
            value.compilerSymbols = Array(Set(value.compilerSymbols)).sorted()
            if var binding = value.binding {
                binding.importedModules = Array(Set(binding.importedModules)).sorted()
                value.binding = binding
            }
            return value
        }.sorted { $0.key < $1.key }
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NativeAPICatalog.Error.unsupportedSchema(schemaVersion)
        }
        try Self.validate(identity)
        guard entries.count <= 250_000,
              entries == entries.sorted(by: { $0.key < $1.key }),
              Set(entries.map(\.key)).count == entries.count
        else {
            throw NativeAPICatalog.Error.invalid(
                "entries are oversized, duplicated, or not key-sorted"
            )
        }
        for entry in entries {
            do {
                let validated = try entry.descriptor.validatedIdentity(
                    contract: entry.contract
                )
                guard validated.descriptor == entry.descriptor,
                      validated.key == entry.key
                else {
                    throw NativeAPICatalog.Error.invalid(
                        "entry \(entry.key) has a noncanonical descriptor or mismatched key"
                    )
                }
            } catch let error as NativeAPICatalog.Error {
                throw error
            } catch {
                throw NativeAPICatalog.Error.invalid(
                    "entry \(entry.key) has an invalid descriptor: \(error)"
                )
            }
            guard entry.descriptor.target.module == identity.moduleName,
                  entry.swiftNames.count <= 64,
                  entry.swiftNames == Array(Set(entry.swiftNames)).sorted(),
                  entry.swiftNames.contains(entry.descriptor.canonicalCallee),
                  entry.swiftNames.allSatisfy(Self.isBoundText),
                  entry.compilerSymbols.count <= 64,
                  entry.compilerSymbols == Array(Set(entry.compilerSymbols)).sorted(),
                  entry.compilerSymbols.allSatisfy(Self.isCompilerSymbol)
            else {
                throw NativeAPICatalog.Error.invalid(
                    "entry \(entry.key) has invalid module or lookup aliases"
                )
            }
            try Self.validateSupport(entry.support, binding: entry.binding)
            if let binding = entry.binding {
                try Self.validate(
                    binding,
                    backend: entry.descriptor.target.backend,
                    module: entry.descriptor.target.module
                )
            }
        }
    }

    private static func validate(_ identity: NativeAPICatalog.Identity) throws {
        guard identity.rulesVersion
                == NativeAPICatalog.Identity.currentRulesVersion,
              isToken(identity.xcodeProductBuild, maximumBytes: 128),
              isToken(identity.sdkProductBuild, maximumBytes: 128),
              isBoundText(identity.compilerFingerprint),
              isToken(identity.targetTriple, maximumBytes: 256),
              isToken(identity.swiftLanguageMode, maximumBytes: 32),
              isModulePath(identity.moduleName)
        else {
            throw NativeAPICatalog.Error.invalid(
                "catalog identity is incomplete or noncanonical"
            )
        }
    }

    private static func validateSupport(
        _ support: NativeAPICatalog.Support,
        binding: NativeAPICatalog.Binding?
    ) throws {
        switch support.state {
        case .supported:
            guard support.reasonCode == nil,
                  support.explanation == nil,
                  binding != nil
            else {
                throw NativeAPICatalog.Error.invalid(
                    "supported API must have one binding and no rejection reason"
                )
            }
        case .unsupported:
            guard let code = support.reasonCode,
                  isDiagnosticCode(code),
                  let explanation = support.explanation,
                  isBoundText(explanation),
                  binding == nil
            else {
                throw NativeAPICatalog.Error.invalid(
                    "unsupported API must have a bounded reason and no binding"
                )
            }
        }
    }

    private static func validate(
        _ binding: NativeAPICatalog.Binding,
        backend: Core.NativeCall.Backend,
        module: String
    ) throws {
        let expected: NativeAPICatalog.BindingStrategy = switch backend {
        case .objectiveCMessage: .objectiveCInvoker
        case .cFunction: .cInvoker
        case .swiftAdapter: .swiftAdapter
        case .builtin: .builtin
        }
        guard binding.strategy == expected,
              binding.importedModules.count <= 64,
              binding.importedModules
                == Array(Set(binding.importedModules)).sorted(),
              binding.importedModules.allSatisfy(isModulePath),
              binding.importedModules.contains(module)
        else {
            throw NativeAPICatalog.Error.invalid(
                "API binding strategy or imported modules disagree with its backend or target"
            )
        }
        switch binding.strategy {
        case .objectiveCInvoker, .cInvoker:
            guard binding.adapterID == nil else {
                throw NativeAPICatalog.Error.invalid(
                    "generic native invokers cannot name a per-API adapter"
                )
            }
        case .swiftAdapter, .builtin:
            guard let adapterID = binding.adapterID,
                  isToken(adapterID, maximumBytes: 512)
            else {
                throw NativeAPICatalog.Error.invalid(
                    "Swift and builtin bindings require a stable adapter ID"
                )
            }
        }
    }

    private static func isDiagnosticCode(_ value: String) -> Bool {
        isToken(value, maximumBytes: 64)
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || $0 == 45
            }
    }

    private static func isCompilerSymbol(_ value: String) -> Bool {
        isToken(value, maximumBytes: 4_096)
    }

    private static func isModulePath(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            guard let first = component.first,
                  first == "_" || first.isLetter
            else { return false }
            return component.dropFirst().allSatisfy {
                $0 == "_" || $0.isLetter || $0.isNumber
            }
        }
    }

    private static func isBoundText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7f
            }
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isToken(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7f }
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt16)
    case documentTooLarge(actual: Int, maximum: Int)
    case nonCanonical
    case conflictingDocumentIdentity(Core.Digest)
    case conflictingEntry(Core.NativeCall.Key)
    case invalid(String)

    public var description: String {
        switch self {
        case let .unsupportedSchema(version):
            "unsupported Native API Catalog schema \(version)"
        case let .documentTooLarge(actual, maximum):
            "Native API Catalog is \(actual) bytes; maximum is \(maximum)"
        case .nonCanonical:
            "Native API Catalog is not canonical JSON"
        case let .conflictingDocumentIdentity(identity):
            "Native API Catalog identity \(identity) names different documents"
        case let .conflictingEntry(key):
            "Native API Catalogs disagree for call \(key)"
        case let .invalid(reason):
            "invalid Native API Catalog: \(reason)"
        }
    }
}

public enum Codec {
    public static let maximumDocumentBytes = 128 * 1_024 * 1_024

    public static func encode(
        _ document: NativeAPICatalog.Document
    ) throws -> Data {
        try document.validate()
        let data = try Core.CanonicalJSON.encode(document)
        guard data.count <= maximumDocumentBytes else {
            throw NativeAPICatalog.Error.documentTooLarge(
                actual: data.count,
                maximum: maximumDocumentBytes
            )
        }
        return data
    }

    public static func decode(_ data: Data) throws -> NativeAPICatalog.Document {
        guard data.count <= maximumDocumentBytes else {
            throw NativeAPICatalog.Error.documentTooLarge(
                actual: data.count,
                maximum: maximumDocumentBytes
            )
        }
        let document: NativeAPICatalog.Document
        do {
            document = try JSONDecoder().decode(
                NativeAPICatalog.Document.self,
                from: data
            )
        } catch {
            throw NativeAPICatalog.Error.invalid(String(describing: error))
        }
        guard try Core.CanonicalJSON.encode(document) == data else {
            throw NativeAPICatalog.Error.nonCanonical
        }
        try document.validate()
        return document
    }
}
}
