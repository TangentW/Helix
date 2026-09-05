import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixInterface
import HelixLiveReloadAPI

/// A typed compiler-to-build-tools boundary. The Swift compiler adapter emits
/// this document; downstream tools consume it without rediscovering declarations
/// from source text.
public enum ShellBuildReceipt {}

extension ShellBuildReceipt {
public struct Source: Codable, Hashable, Sendable {
    public var logicalPath: String
    public var contentHash: Core.Digest

    public init(logicalPath: String, contentHash: Core.Digest) {
        self.logicalPath = logicalPath
        self.contentHash = contentHash
    }
}

public struct NominalType: Codable, Hashable, Sendable {
    public var moduleName: String
    public var canonicalName: String
    /// An additive scope for private/fileprivate names. Absence preserves v1 IDs.
    public var sourceFileLogicalID: String?

    public init(moduleName: String, canonicalName: String) {
        self.init(moduleName: moduleName, canonicalName: canonicalName, sourceFileLogicalID: nil)
    }

    public init(moduleName: String, canonicalName: String, sourceFileLogicalID: String?) {
        self.moduleName = moduleName
        self.canonicalName = canonicalName
        self.sourceFileLogicalID = sourceFileLogicalID
    }

    public var id: LiveReload.NominalTypeID {
        if let sourceFileLogicalID {
            .derive(module: moduleName, canonicalName: canonicalName,
                    sourceFileLogicalID: sourceFileLogicalID)
        } else {
            .derive(module: moduleName, canonicalName: canonicalName)
        }
    }

    fileprivate var orderKey: String {
        "\(moduleName).\(canonicalName)" + (sourceFileLogicalID.map { "\u{0}\($0)" } ?? "")
    }
}

public struct NativeReplacement: Codable, Hashable, Sendable {
    public var declarationAnchorUTF8Offset: Int
    public var declarationAnchor: String
    public var declarationOccurrence: UInt32
    public var loweredType: String
    public var importedModules: [String]

    public init(
        declarationAnchorUTF8Offset: Int,
        declarationAnchor: String,
        declarationOccurrence: UInt32 = 0,
        loweredType: String,
        importedModules: [String] = []
    ) {
        self.declarationAnchorUTF8Offset = declarationAnchorUTF8Offset
        self.declarationAnchor = declarationAnchor
        self.declarationOccurrence = declarationOccurrence
        self.loweredType = loweredType
        self.importedModules = importedModules.sorted()
    }
}

public struct Bridge: Codable, Hashable, Sendable {
    public var privateImportSourceFile: String
    public var parameterExpressions: [String]
    public var parameterSwiftTypes: [String]
    public var resultSwiftType: String
    public var originalInvocation: String
    /// Source-callable expression used by the OriginalEntry catalog. Swift
    /// property observers have no source-level callable spelling, so their
    /// exact Bridge fallback is carried by `originalInvocation` while this is
    /// nil and the unreachable nested-original path fails closed.
    public var bridgeInvocation: String?
    /// Declaration emitted back into the defining source file. Async entries
    /// use this for a uniquely named exact-original thunk whose call cannot
    /// redispatch through an override.
    public var sourceSupplementalDeclaration: String?

    public init(
        privateImportSourceFile: String,
        parameterExpressions: [String],
        parameterSwiftTypes: [String],
        resultSwiftType: String,
        originalInvocation: String,
        bridgeInvocation: String?,
        sourceSupplementalDeclaration: String? = nil
    ) {
        self.privateImportSourceFile = privateImportSourceFile
        self.parameterExpressions = parameterExpressions
        self.parameterSwiftTypes = parameterSwiftTypes
        self.resultSwiftType = resultSwiftType
        self.originalInvocation = originalInvocation
        self.bridgeInvocation = bridgeInvocation
        self.sourceSupplementalDeclaration = sourceSupplementalDeclaration
    }
}

public struct Root: Codable, Hashable, Sendable {
    public var declarationMangledName: String
    public var declarationUTF8Offset: Int
    public var expectedDeclarationPrefix: String
    public var declarationInsertion: String?
    public var sourceDeclaration: Core.DynamicReplacement.Declaration
    public var memberRole: Core.DynamicReplacement.MemberRole
    public var reloadRole: ReloadIndex.FunctionRole
    public var nominalType: ShellBuildReceipt.NominalType?
    /// Present when a permanent Bridge must be installed by replacing the
    /// exact declaration body in the derived Shell source.
    public var sourceBodyTransform: ShellBuildReceipt.SourceBodyTransform?
    public var bridge: ShellBuildReceipt.Bridge?
    public var nativeReplacement: ShellBuildReceipt.NativeReplacement?

    public init(
        declarationMangledName: String,
        declarationUTF8Offset: Int,
        expectedDeclarationPrefix: String,
        declarationInsertion: String? = "dynamic ",
        sourceDeclaration: Core.DynamicReplacement.Declaration,
        memberRole: Core.DynamicReplacement.MemberRole,
        reloadRole: ReloadIndex.FunctionRole = .unknown,
        nominalType: ShellBuildReceipt.NominalType? = nil,
        sourceBodyTransform: ShellBuildReceipt.SourceBodyTransform? = nil,
        bridge: ShellBuildReceipt.Bridge? = nil,
        nativeReplacement: ShellBuildReceipt.NativeReplacement? = nil
    ) {
        self.declarationMangledName = declarationMangledName
        self.declarationUTF8Offset = declarationUTF8Offset
        self.expectedDeclarationPrefix = expectedDeclarationPrefix
        self.declarationInsertion = declarationInsertion
        self.sourceDeclaration = sourceDeclaration
        self.memberRole = memberRole
        self.reloadRole = reloadRole
        self.nominalType = nominalType
        self.sourceBodyTransform = sourceBodyTransform
        self.bridge = bridge
        self.nativeReplacement = nativeReplacement
    }
}

public struct NativeImportBinding: Codable, Hashable, Sendable {
    public enum Strategy: String, Codable, Hashable, Sendable {
        case factory
        case generatedSwiftAdapter
        case objectiveCInvoker
        case cInvoker
    }

    public var key: Core.NativeCall.Key
    public var strategy: Strategy
    /// Trusted dotted callable reference from the explicit Catalog. The Bridge
    /// supplies the release-specific compact ID and stable Key when rendering
    /// the invocation; arbitrary Swift expressions are never persisted here.
    public var factoryReference: String?
    public var importedModules: [String]
    public var generated: ShellBuildReceipt.GeneratedNativeImport?
    public var cFunction: ShellBuildReceipt.CFunctionBinding?

    public init(
        key: Core.NativeCall.Key,
        strategy: Strategy,
        factoryReference: String? = nil,
        importedModules: [String] = [],
        generated: ShellBuildReceipt.GeneratedNativeImport? = nil,
        cFunction: ShellBuildReceipt.CFunctionBinding? = nil
    ) {
        self.key = key
        self.strategy = strategy
        self.factoryReference = factoryReference
        self.importedModules = importedModules.sorted()
        self.generated = generated
        self.cFunction = cFunction
    }
}

/// Exact compiler-bound C function reference used by the generic C invoker.
/// Only identifier components and compiler-observed physical types are stored;
/// arbitrary Swift expressions are never accepted from project input.
public struct CFunctionBinding: Codable, Hashable, Sendable {
    public var moduleName: String
    public var swiftName: String
    public var parameterSwiftTypes: [String]
    public var resultSwiftType: String

    public init(
        moduleName: String,
        swiftName: String,
        parameterSwiftTypes: [String],
        resultSwiftType: String
    ) {
        self.moduleName = moduleName
        self.swiftName = swiftName
        self.parameterSwiftTypes = parameterSwiftTypes
        self.resultSwiftType = resultSwiftType
    }
}

/// Structured call metadata for a source-discovered invoker. Keeping this
/// data structured lets the Bridge generator render Swift without persisting
/// arbitrary source snippets in the receipt.
public struct GeneratedNativeImport: Codable, Hashable, Sendable {
    public enum Dispatch: String, Codable, Hashable, Sendable {
        case globalFunction
        case initializer
        case staticMethod
        case nativeUpcast
        case anyObjectBridge
        case staticGetter
        case staticSetter
        case instanceMethod
        case instanceGetter
        case instanceSetter
        case instanceValueSetter
    }

    public var declarationMangledName: String
    public var sourceFileLogicalID: String
    public var dispatch: Dispatch
    public var ownerType: String?
    public var baseName: String
    public var argumentLabels: [String]
    public var parameterSwiftTypes: [String]
    public var invocationParameterSwiftTypes: [String]?
    public var resultSwiftType: String
    /// External module whose adapter can be emitted into a reusable Pack.
    /// Nil keeps the adapter in its application source group.
    public var nativeModuleName: String?

    public init(
        declarationMangledName: String,
        sourceFileLogicalID: String,
        dispatch: Dispatch,
        ownerType: String? = nil,
        baseName: String,
        argumentLabels: [String],
        parameterSwiftTypes: [String],
        invocationParameterSwiftTypes: [String]? = nil,
        resultSwiftType: String,
        nativeModuleName: String? = nil
    ) {
        self.declarationMangledName = declarationMangledName
        self.sourceFileLogicalID = sourceFileLogicalID
        self.dispatch = dispatch
        self.ownerType = ownerType
        self.baseName = baseName
        self.argumentLabels = argumentLabels
        self.parameterSwiftTypes = parameterSwiftTypes
        self.invocationParameterSwiftTypes = invocationParameterSwiftTypes
        self.resultSwiftType = resultSwiftType
        self.nativeModuleName = nativeModuleName
    }
}

public struct NativeTypeBinding: Codable, Hashable, Sendable {
    public enum Strategy: String, Codable, Hashable, Sendable {
        case factory
        case objectiveCReference
    }

    public var canonicalName: String
    public var layoutFingerprint: Core.Digest
    public var requiresMainActor: Bool
    public var strategy: Strategy
    public var operationsExpression: String?
    public var importedModules: [String]
    public var generated: ShellBuildReceipt.GeneratedNativeType?

    public init(
        canonicalName: String,
        layoutFingerprint: Core.Digest,
        requiresMainActor: Bool = false,
        strategy: Strategy = .factory,
        operationsExpression: String? = nil,
        importedModules: [String] = [],
        generated: ShellBuildReceipt.GeneratedNativeType? = nil
    ) {
        self.canonicalName = canonicalName
        self.layoutFingerprint = layoutFingerprint
        self.requiresMainActor = requiresMainActor
        self.strategy = strategy
        self.operationsExpression = operationsExpression
        self.importedModules = importedModules.sorted()
        self.generated = generated
    }
}

/// Structured metadata for TypeOps generated beside one privately imported
/// source file. No arbitrary Swift expression is accepted from project input.
public struct GeneratedNativeType: Codable, Hashable, Sendable {
    public enum Representation: String, Codable, Hashable, Sendable {
        case reference
        case rawRepresentable
        case opaqueValue
        case objectiveCStructure
    }

    public var sourceFileLogicalID: String
    public var swiftType: String
    public var representation: Representation
    public var nativeABIEncoding: String?
    public var nativeModuleName: String?

    public init(
        sourceFileLogicalID: String,
        swiftType: String,
        representation: Representation = .reference,
        nativeABIEncoding: String? = nil,
        nativeModuleName: String? = nil
    ) {
        self.sourceFileLogicalID = sourceFileLogicalID
        self.swiftType = swiftType
        self.representation = representation
        self.nativeABIEncoding = nativeABIEncoding
        self.nativeModuleName = nativeModuleName
    }
}

public struct SuperclassEdge: Codable, Hashable, Sendable {
    public var subtype: ShellBuildReceipt.NominalType
    public var superclass: ShellBuildReceipt.NominalType

    public init(
        subtype: ShellBuildReceipt.NominalType,
        superclass: ShellBuildReceipt.NominalType
    ) {
        self.subtype = subtype
        self.superclass = superclass
    }

    fileprivate var orderKey: String { "\(subtype.orderKey):\(superclass.orderKey)" }
}

public struct ReloadRule: Codable, Hashable, Sendable {
    public var sourceLogicalPaths: [String]
    public var controllerType: ShellBuildReceipt.NominalType
    public var policy: LiveReload.Policy
    public var invalidationHints: LiveReload.InvalidationHints
    public var factoryID: LiveReload.FactoryID?

    public init(
        sourceLogicalPaths: [String],
        controllerType: ShellBuildReceipt.NominalType,
        policy: LiveReload.Policy,
        invalidationHints: LiveReload.InvalidationHints = [],
        factoryID: LiveReload.FactoryID? = nil
    ) {
        self.sourceLogicalPaths = sourceLogicalPaths.sorted()
        self.controllerType = controllerType
        self.policy = policy
        self.invalidationHints = invalidationHints
        self.factoryID = factoryID
    }

    fileprivate var orderKey: String {
        "\(controllerType.orderKey):\(policy.rawValue):\(invalidationHints.rawValue):"
            + "\(factoryID?.rawValue ?? ""):\(sourceLogicalPaths.joined(separator: ","))"
    }
}

public struct Factory: Codable, Hashable, Sendable {
    public var id: LiveReload.FactoryID
    public var controllerType: ShellBuildReceipt.NominalType

    public init(id: LiveReload.FactoryID, controllerType: ShellBuildReceipt.NominalType) {
        self.id = id
        self.controllerType = controllerType
    }
}

private struct NativeTypeIdentity: Hashable, Comparable,
    CustomStringConvertible {
    var canonicalName: String
    var layoutFingerprint: Core.Digest
    var requiresMainActor: Bool

    init(_ record: InterfaceArchive.TypeRecord) {
        canonicalName = record.canonicalName
        layoutFingerprint = record.layoutFingerprint
        requiresMainActor = record.requiresMainActor
    }

    init(_ binding: ShellBuildReceipt.NativeTypeBinding) {
        canonicalName = binding.canonicalName
        layoutFingerprint = binding.layoutFingerprint
        requiresMainActor = binding.requiresMainActor
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.canonicalName != rhs.canonicalName {
            return lhs.canonicalName < rhs.canonicalName
        }
        if lhs.layoutFingerprint != rhs.layoutFingerprint {
            return lhs.layoutFingerprint < rhs.layoutFingerprint
        }
        return !lhs.requiresMainActor && rhs.requiresMainActor
    }

    var description: String {
        "\(canonicalName):\(layoutFingerprint.hex):\(requiresMainActor)"
    }
}

public struct Document: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var metadata: InterfaceArchive.ReleaseMetadata
    public var compatibility: Core.Compatibility
    public var configuration: PatchConfiguration.Document
    public var capabilities: [Core.Capability]
    public var sources: [ShellBuildReceipt.Source]
    public var declarations: [ReleaseCompiler.DeclarationCandidate]
    public var roots: [ShellBuildReceipt.Root]
    public var nativeImportCandidates: [InterfaceArchive.NativeImportRecord]
    public var nativeImportBindings: [ShellBuildReceipt.NativeImportBinding]
    public var nativeTypes: [InterfaceArchive.TypeRecord]
    public var frozenValueTypes: [InterfaceArchive.FrozenValueTypeRecord]
    public var nativeTypeBindings: [ShellBuildReceipt.NativeTypeBinding]
    public var superclassEdges: [ShellBuildReceipt.SuperclassEdge]
    public var reloadRules: [ShellBuildReceipt.ReloadRule]
    public var factories: [ShellBuildReceipt.Factory]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        metadata: InterfaceArchive.ReleaseMetadata,
        compatibility: Core.Compatibility,
        configuration: PatchConfiguration.Document,
        capabilities: Set<Core.Capability> = [.baselineV1],
        sources: [ShellBuildReceipt.Source],
        declarations: [ReleaseCompiler.DeclarationCandidate],
        roots: [ShellBuildReceipt.Root],
        nativeImportCandidates: [InterfaceArchive.NativeImportRecord] = [],
        nativeImportBindings: [ShellBuildReceipt.NativeImportBinding] = [],
        nativeTypes: [InterfaceArchive.TypeRecord] = [],
        frozenValueTypes: [InterfaceArchive.FrozenValueTypeRecord] = [],
        nativeTypeBindings: [ShellBuildReceipt.NativeTypeBinding] = [],
        superclassEdges: [ShellBuildReceipt.SuperclassEdge] = [],
        reloadRules: [ShellBuildReceipt.ReloadRule] = [],
        factories: [ShellBuildReceipt.Factory] = []
    ) {
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.compatibility = compatibility
        self.configuration = configuration
        self.capabilities = capabilities.sorted()
        self.sources = sources.sorted { $0.logicalPath < $1.logicalPath }
        self.declarations = declarations.sorted { $0.mangledName < $1.mangledName }
        self.roots = roots.sorted { $0.declarationMangledName < $1.declarationMangledName }
        self.nativeImportCandidates = nativeImportCandidates.sorted {
            $0.key.rawValue < $1.key.rawValue
        }
        self.nativeImportBindings = nativeImportBindings.sorted {
            $0.key.rawValue < $1.key.rawValue
        }
        self.nativeTypes = nativeTypes.sorted { $0.id.rawValue < $1.id.rawValue }
        self.frozenValueTypes = frozenValueTypes.sorted { $0.key < $1.key }
        self.nativeTypeBindings = nativeTypeBindings.sorted {
            let lhs = NativeTypeIdentity($0)
            let rhs = NativeTypeIdentity($1)
            return lhs < rhs
        }
        self.superclassEdges = superclassEdges.sorted { $0.orderKey < $1.orderKey }
        self.reloadRules = reloadRules.sorted { $0.orderKey < $1.orderKey }
        self.factories = factories.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func contentHash() throws -> Core.Digest {
        try validate()
        return .sha256(try Core.CanonicalJSON.encode(self))
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ShellBuildReceipt.Error.unsupportedSchema(schemaVersion)
        }
        guard metadata.machOUUIDs.isEmpty else {
            throw ShellBuildReceipt.Error.invalid(
                "a pre-link receipt must not claim a Mach-O UUID"
            )
        }
        guard metadata.transformPipelineHash == ShellBuild.transformPipelineHash else {
            throw ShellBuildReceipt.Error.invalid("transform pipeline identity is stale")
        }
        try metadata.frontendInvocation.validate()
        do {
            try configuration.validate()
        } catch {
            throw ShellBuildReceipt.Error.invalid(
                "patchability configuration is incomplete: \(error)"
            )
        }
        guard capabilities == Array(Set(capabilities)).sorted(),
              capabilities.contains(.baselineV1)
        else {
            throw ShellBuildReceipt.Error.invalid(
                "capabilities are duplicated, unordered, or omit the baseline"
            )
        }
        guard sources == sources.sorted(by: { $0.logicalPath < $1.logicalPath }),
              Set(sources.map(\.logicalPath)).count == sources.count,
              !sources.isEmpty,
              sources.allSatisfy({ Self.isSafeLogicalPath($0.logicalPath) })
        else {
            throw ShellBuildReceipt.Error.invalid(
                "source paths are empty, duplicated, unordered, absolute, or traversing"
            )
        }
        let sourcePaths = Set(sources.map(\.logicalPath))
        guard frozenValueTypes == frozenValueTypes.sorted(by: { $0.key < $1.key }),
              Set(frozenValueTypes.map(\.key)).count == frozenValueTypes.count,
              frozenValueTypes.allSatisfy({
                  sourcePaths.contains($0.sourceFileLogicalID)
              })
        else {
            throw ShellBuildReceipt.Error.invalid(
                "indexed Shell value types are duplicated, unordered, or reference unknown sources"
            )
        }
        guard declarations == declarations.sorted(by: { $0.mangledName < $1.mangledName }),
              Set(declarations.map(\.mangledName)).count == declarations.count,
              !declarations.isEmpty,
              declarations.allSatisfy({
                  sourcePaths.contains($0.sourceFileLogicalID)
                      && !$0.mangledName.isEmpty
                      && !$0.canonicalDeclaration.isEmpty
              })
        else {
            throw ShellBuildReceipt.Error.invalid(
                "declarations are empty, duplicated, unordered, or reference unknown sources"
            )
        }
        let declarationNames = Set(declarations.map(\.mangledName))
        guard roots == roots.sorted(by: {
            $0.declarationMangledName < $1.declarationMangledName
        }), Set(roots.map(\.declarationMangledName)).count == roots.count,
            roots.allSatisfy({ declarationNames.contains($0.declarationMangledName) })
        else {
            throw ShellBuildReceipt.Error.invalid(
                "bridge roots are duplicated, unordered, or reference unknown declarations"
            )
        }
        let declarationByName = Dictionary(
            uniqueKeysWithValues: declarations.map { ($0.mangledName, $0) }
        )
        for root in roots {
            guard let declaration = declarationByName[root.declarationMangledName] else {
                throw ShellBuildReceipt.Error.invalid(
                    "bridge root references an unknown declaration"
                )
            }
            try Self.validateRoot(root, declaration: declaration)
        }
        for values in Dictionary(grouping: roots, by: { $0.sourceDeclaration.identity }).values {
            guard let first = values.first,
                  values.allSatisfy({
                      $0.sourceDeclaration == first.sourceDeclaration
                          && $0.declarationUTF8Offset == first.declarationUTF8Offset
                          && $0.expectedDeclarationPrefix == first.expectedDeclarationPrefix
                          && $0.declarationInsertion == first.declarationInsertion
                          && $0.nominalType == first.nominalType
                          && $0.reloadRole == first.reloadRole
                  }),
                  Set(values.map(\.memberRole)).count == values.count,
                  Set(values.compactMap {
                      declarationByName[$0.declarationMangledName]?.sourceFileLogicalID
                  }).count == 1
            else {
                throw ShellBuildReceipt.Error.invalid(
                    "a grouped Swift declaration has inconsistent source or member metadata"
                )
            }
        }
        guard nativeImportCandidates == nativeImportCandidates.sorted(by: {
            $0.key.rawValue < $1.key.rawValue
        }) else {
            throw ShellBuildReceipt.Error.invalid(
                "native import candidates are not ordered by NativeCallKey"
            )
        }
        guard Set(nativeImportCandidates.map(\.key)).count
                == nativeImportCandidates.count
        else {
            throw ShellBuildReceipt.Error.invalid(
                "native import candidates contain duplicate NativeCallKeys"
            )
        }
        guard nativeImportBindings == nativeImportBindings.sorted(by: {
            $0.key.rawValue < $1.key.rawValue
        }) else {
            throw ShellBuildReceipt.Error.invalid(
                "native import bindings are not ordered by NativeCallKey"
            )
        }
        guard Set(nativeImportBindings.map(\.key)).count
                == nativeImportBindings.count
        else {
            throw ShellBuildReceipt.Error.invalid(
                "native import bindings contain duplicate NativeCallKeys"
            )
        }
        let nativeImportCandidatesByKey = Dictionary(
            uniqueKeysWithValues: nativeImportCandidates.map { ($0.key, $0) }
        )
        for binding in nativeImportBindings {
            guard binding.importedModules
                    == Array(Set(binding.importedModules)).sorted(),
                  binding.importedModules.allSatisfy(Self.isModulePath),
                  let record = nativeImportCandidatesByKey[binding.key],
                  Self.isValidNativeImportBinding(
                      binding,
                      record: record,
                      declarations: declarations,
                      sourcePaths: sourcePaths
                  )
            else {
                let generatedContext = binding.generated.map { generated in
                    let owner = generated.ownerType ?? "<none>"
                    let invocationParameters = generated
                        .invocationParameterSwiftTypes
                        ?? generated.parameterSwiftTypes
                    return [
                        "symbol=\(generated.declarationMangledName)",
                        "dispatch=\(generated.dispatch.rawValue)",
                        "owner=\(owner)",
                        "base=\(generated.baseName)",
                        "labels=\(generated.argumentLabels)",
                        "parameters=\(generated.parameterSwiftTypes)",
                        "invocationParameters=\(invocationParameters)",
                        "result=\(generated.resultSwiftType)",
                        "nativeModule=\(generated.nativeModuleName ?? "<none>")",
                        "imports=\(binding.importedModules)",
                    ].joined(separator: "; ")
                } ?? ""
                throw ShellBuildReceipt.Error.invalid(
                    "native import binding \(binding.key.rawValue.hex) for "
                        + "\(nativeImportCandidatesByKey[binding.key]?.canonicalCallee ?? "<missing>") "
                        + "using \(binding.strategy.rawValue) is invalid"
                        + (generatedContext.isEmpty ? "" : "; " + generatedContext)
                )
            }
        }
        guard Set(nativeImportBindings.map(\.key))
                == Set(nativeImportCandidates.map(\.key))
        else {
            throw ShellBuildReceipt.Error.invalid(
                "native import bindings do not cover every candidate exactly once"
            )
        }
        let entrySymbols = Set(roots.compactMap { root in
            root.bridge == nil ? nil : root.declarationMangledName
        })
        let nativeImportSymbols = Set(
            nativeImportCandidates.flatMap(\.silMangledNames)
        )
        guard entrySymbols.isDisjoint(with: nativeImportSymbols) else {
            throw ShellBuildReceipt.Error.invalid(
                "an exact Swift symbol cannot be both an Entry and a NativeImport"
            )
        }
        let nativeTypesByBindingIdentity = Dictionary(
            grouping: nativeTypes,
            by: NativeTypeIdentity.init
        )
        guard nativeTypes == nativeTypes.sorted(by: {
            $0.id.rawValue < $1.id.rawValue
        }) else {
            throw ShellBuildReceipt.Error.invalid(
                "native types are not ordered by TypeID"
            )
        }
        guard Set(nativeTypes.map(\.id)).count == nativeTypes.count else {
            throw ShellBuildReceipt.Error.invalid(
                "native types contain duplicate TypeIDs"
            )
        }
        guard nativeTypeBindings == nativeTypeBindings.sorted(by: {
            NativeTypeIdentity($0) < NativeTypeIdentity($1)
        }) else {
            throw ShellBuildReceipt.Error.invalid(
                "native type bindings are not canonically ordered"
            )
        }
        let nativeTypeBindingIdentities = nativeTypeBindings.map(
            NativeTypeIdentity.init
        )
        guard Set(nativeTypeBindingIdentities).count
                == nativeTypeBindings.count
        else {
            throw ShellBuildReceipt.Error.invalid(
                "native type bindings contain duplicate identities"
            )
        }
        for (binding, identity) in zip(
            nativeTypeBindings,
            nativeTypeBindingIdentities
        ) {
            guard let records = nativeTypesByBindingIdentity[identity],
                  records.count == 1,
                  let record = records.first
            else {
                throw ShellBuildReceipt.Error.invalid(
                    "native type binding \(identity) does not identify exactly one type record"
                )
            }
            guard Self.isValidNativeTypeBinding(
                binding,
                record: record,
                moduleName: metadata.frontendInvocation.moduleName,
                sourcePaths: sourcePaths
            ) else {
                throw ShellBuildReceipt.Error.invalid(
                    "native type binding \(identity) is invalid; strategy="
                        + "\(binding.strategy.rawValue), imports="
                        + "\(binding.importedModules), generated="
                        + "\(String(describing: binding.generated)), kind="
                        + "\(record.kind), runtime="
                        + "\(record.objectiveCRuntimeName ?? "<none>")"
                )
            }
        }
        let candidateNativeTypeIDs = nativeImportCandidates.reduce(
            into: Set<Core.TypeID>()
        ) { result, nativeImport in
            nativeImport.parameterTypes.forEach {
                result.formUnion($0.referencedNativeTypeIDs)
            }
            result.formUnion(nativeImport.resultType.referencedNativeTypeIDs)
        }
        let requiredNativeTypeIdentities = Set(
            nativeTypes.filter {
                $0.isEmittedToDevice || candidateNativeTypeIDs.contains($0.id)
            }.map(
                NativeTypeIdentity.init
            )
        )
        guard Set(nativeTypeBindingIdentities) == requiredNativeTypeIdentities
        else {
            let missing = requiredNativeTypeIdentities
                .subtracting(nativeTypeBindingIdentities).sorted()
            let extra = Set(nativeTypeBindingIdentities)
                .subtracting(requiredNativeTypeIdentities).sorted()
            throw ShellBuildReceipt.Error.invalid(
                "native type bindings do not exactly cover emitted or candidate-referenced types; "
                    + "missing=\(missing), extra=\(extra)"
            )
        }
        guard superclassEdges == superclassEdges.sorted(by: { $0.orderKey < $1.orderKey }),
              Set(superclassEdges.map(\.subtype)).count == superclassEdges.count,
              superclassEdges.allSatisfy({ $0.subtype != $0.superclass }),
              reloadRules == reloadRules.sorted(by: { $0.orderKey < $1.orderKey }),
              Set(reloadRules).count == reloadRules.count,
              factories == factories.sorted(by: { $0.id.rawValue < $1.id.rawValue }),
              Set(factories.map(\.id)).count == factories.count,
              Set(factories.map(\.controllerType)).count == factories.count
        else {
            throw ShellBuildReceipt.Error.invalid(
                "reload metadata is duplicated, unordered, or self-referential"
            )
        }
        for rule in reloadRules {
            guard !rule.sourceLogicalPaths.isEmpty,
                  rule.sourceLogicalPaths == rule.sourceLogicalPaths.sorted(),
                  Set(rule.sourceLogicalPaths).count == rule.sourceLogicalPaths.count,
                  Set(rule.sourceLogicalPaths).isSubset(of: sourcePaths)
            else {
                throw ShellBuildReceipt.Error.invalid(
                    "a reload rule has an empty, duplicated, or unknown source"
                )
            }
            try rule.invalidationHints.validate()
            try Self.validateNominal(rule.controllerType)
        }
        try superclassEdges.forEach {
            try Self.validateNominal($0.subtype)
            try Self.validateNominal($0.superclass)
        }
        try factories.forEach { try Self.validateNominal($0.controllerType) }
    }

    private static func validateRoot(
        _ root: ShellBuildReceipt.Root,
        declaration: ReleaseCompiler.DeclarationCandidate
    ) throws {
        let isObserver = root.sourceDeclaration.kind == .propertyObservers
            && [.willSet, .didSet].contains(root.memberRole)
        let isAsyncFunction = declaration.effects.isAsync
            && root.sourceDeclaration.kind == .function
            && root.memberRole == .functionBody
        let expectedTransformKind: ShellBuildReceipt.SourceBodyTransform.Kind? =
            if isObserver {
                .propertyObserver
            } else if isAsyncFunction {
                .asynchronousFunction
            } else {
                nil
            }
        let hasSourceBodyInstallation = expectedTransformKind != nil
        guard root.declarationUTF8Offset >= 0,
              !root.expectedDeclarationPrefix.isEmpty,
              Self.isBoundText(root.declarationMangledName),
              Self.isBoundText(root.expectedDeclarationPrefix),
              (root.declarationInsertion.map {
                  !$0.isEmpty && Self.isBoundText($0)
              } ?? true),
              root.sourceDeclaration.isWellFormed,
              root.sourceDeclaration.member(root.memberRole) != nil,
              root.sourceBodyTransform?.kind == expectedTransformKind,
              !isAsyncFunction
                  || !declaration.parameterConventions.contains(.inout),
              !hasSourceBodyInstallation || (
                  root.declarationInsertion == nil
                      && root.nativeReplacement == nil
                      && root.bridge != nil
              ),
              root.bridge != nil || root.nativeReplacement != nil
        else {
            throw ShellBuildReceipt.Error.invalid(
                "bridge root \(root.declarationMangledName) is incomplete or oversized"
            )
        }
        if let bridge = root.bridge {
            let requiredStrings = [
                bridge.privateImportSourceFile, bridge.resultSwiftType,
                bridge.originalInvocation,
            ] + bridge.parameterExpressions + bridge.parameterSwiftTypes
                + (bridge.bridgeInvocation.map { [$0] } ?? [])
            guard requiredStrings.allSatisfy(Self.isBoundText),
                  (bridge.bridgeInvocation == nil) == isObserver,
                  bridge.sourceSupplementalDeclaration.map(Self.isBoundText) ?? true,
                  (bridge.sourceSupplementalDeclaration != nil) == isAsyncFunction
            else {
                throw ShellBuildReceipt.Error.invalid(
                    "HLBC Bridge metadata for \(root.declarationMangledName) is invalid"
                )
            }
        }
        if let transform = root.sourceBodyTransform {
            let span = transform.closingBraceUTF8Offset
                .subtractingReportingOverflow(transform.openingBraceUTF8Offset)
            let maximumSpan = isAsyncFunction
                ? 64 * 1_024 - 1 : 64 * 1_024 + 1
            guard transform.openingBraceUTF8Offset >= 0,
                  !span.overflow,
                  span.partialValue >= 1,
                  span.partialValue <= maximumSpan
            else {
                throw ShellBuildReceipt.Error.invalid(
                    "source body transform for \(root.declarationMangledName) is invalid"
                )
            }
        }
        if let replacement = root.nativeReplacement {
            guard replacement.declarationAnchorUTF8Offset >= 0,
                  replacement.declarationAnchor.utf8.last == UInt8(ascii: "{"),
                  replacement.declarationOccurrence <= 65_535,
                  Self.isBoundText(replacement.declarationAnchor),
                  !replacement.loweredType.isEmpty,
                  Self.isBoundText(replacement.loweredType),
                  replacement.importedModules == replacement.importedModules.sorted(),
                  Set(replacement.importedModules).count == replacement.importedModules.count,
                  replacement.importedModules.allSatisfy(Self.isModulePath)
            else {
                throw ShellBuildReceipt.Error.invalid(
                    "native replacement metadata for \(root.declarationMangledName) is invalid"
                )
            }
        }
        if let nominal = root.nominalType {
            try validateNominal(nominal)
            guard nominal.sourceFileLogicalID.map({ $0 == declaration.sourceFileLogicalID }) ?? true else {
                throw ShellBuildReceipt.Error.invalid("nominal scope disagrees with its declaration source")
            }
        }
    }

    private static func validateNominal(_ nominal: ShellBuildReceipt.NominalType) throws {
        guard isModulePath(nominal.moduleName), isBoundText(nominal.canonicalName),
              nominal.sourceFileLogicalID.map(isSafeLogicalPath) ?? true else {
            throw ShellBuildReceipt.Error.invalid("nominal type identity is invalid")
        }
    }

    private static func isValidGeneratedNativeImport(
        _ generated: ShellBuildReceipt.GeneratedNativeImport?,
        importedModules: [String],
        declarations: [ReleaseCompiler.DeclarationCandidate],
        sourcePaths: Set<String>
    ) -> Bool {
        guard let generated else { return true }
        let declaration = declarations.first(where: {
            $0.mangledName == generated.declarationMangledName
                && $0.sourceFileLogicalID == generated.sourceFileLogicalID
        })
        let isFrozenForeignReference = generated.declarationMangledName.hasPrefix("#")
            || generated.declarationMangledName.hasPrefix("$hlx_native_foreign_")
        let isFrozenExternalSwiftReference = declaration == nil
            && generated.declarationMangledName.hasPrefix("$s")
            && !importedModules.isEmpty
        let isCompilerOperation = generated.dispatch == .initializer
            || generated.dispatch == .nativeUpcast
            || generated.dispatch == .anyObjectBridge
        let isFrozenImportedGlobal = generated.dispatch == .staticGetter
            && generated.declarationMangledName.hasPrefix("$hlx_native_global_")
        guard declaration != nil || isFrozenForeignReference
                || isFrozenExternalSwiftReference || isCompilerOperation
                || isFrozenImportedGlobal else {
            return false
        }
        let requiresImportedType = isFrozenForeignReference
            || isFrozenExternalSwiftReference || isCompilerOperation
            || isFrozenImportedGlobal || declaration.map {
            ($0.loweredSignature.parameters + [$0.loweredSignature.result])
                .contains { $0.contains("__C.") }
        } == true
        let invocationParameterSwiftTypes = generated
            .invocationParameterSwiftTypes ?? generated.parameterSwiftTypes
        let invocationAdapterIsValid: Bool = {
            guard let invocationTypes = generated.invocationParameterSwiftTypes
            else { return true }
            return invocationTypes != generated.parameterSwiftTypes
                && invocationTypes.allSatisfy(
                    FrontendReceipt.SwiftTypeSpelling.isGeneratedType
                )
        }()
        let originIsValid = generated.nativeModuleName != nil
            || sourcePaths.contains(generated.sourceFileLogicalID)
        guard originIsValid,
              !requiresImportedType || !importedModules.isEmpty,
              generated.nativeModuleName.map({
                  isModulePath($0) && importedModules.contains($0)
              }) ?? true,
              isBoundText(generated.declarationMangledName),
              isSwiftIdentifier(generated.baseName)
                || generated.dispatch == .globalFunction
                    && Core.SwiftName.isOperator(generated.baseName),
              generated.argumentLabels.allSatisfy({
                  $0 == "_" || isSwiftIdentifier($0)
              }),
              generated.parameterSwiftTypes.allSatisfy(isBoundText),
              invocationParameterSwiftTypes.count
                == generated.parameterSwiftTypes.count,
              invocationAdapterIsValid,
              isBoundText(generated.resultSwiftType)
        else { return false }
        switch generated.dispatch {
        case .globalFunction:
            return generated.ownerType == nil
                && generated.argumentLabels.count == generated.parameterSwiftTypes.count
        case .initializer:
            guard let owner = generated.ownerType else { return false }
            return generated.baseName == "init"
                && generated.argumentLabels.count == generated.parameterSwiftTypes.count
                && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(owner)
        case .staticMethod:
            guard let owner = generated.ownerType else { return false }
            return generated.argumentLabels.count == generated.parameterSwiftTypes.count
                && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(owner)
        case .nativeUpcast:
            guard let owner = generated.ownerType else { return false }
            return generated.baseName == "upcast"
                && generated.argumentLabels == ["_"]
                && generated.parameterSwiftTypes.count == 1
                && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(owner)
        case .anyObjectBridge:
            guard let owner = generated.ownerType else { return false }
            return generated.baseName == "bridge"
                && generated.argumentLabels == ["_"]
                && generated.parameterSwiftTypes == ["Swift.Any"]
                && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(owner)
        case .staticGetter:
            guard let owner = generated.ownerType else { return false }
            return generated.argumentLabels.isEmpty
                && generated.parameterSwiftTypes.isEmpty
                && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(owner)
        case .staticSetter:
            guard let owner = generated.ownerType else { return false }
            return generated.argumentLabels == ["_"]
                && generated.parameterSwiftTypes.count == 1
                && Core.NativeCall.isVoid(generated.resultSwiftType)
                && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(owner)
        case .instanceMethod:
            guard let owner = generated.ownerType,
                  !generated.parameterSwiftTypes.isEmpty
            else { return false }
            return generated.argumentLabels.count + 1 == generated.parameterSwiftTypes.count
                && generated.parameterSwiftTypes.last == owner
                && invocationParameterSwiftTypes.last == owner
                && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(owner)
        case .instanceGetter:
            guard let owner = generated.ownerType else { return false }
            return generated.argumentLabels.isEmpty
                && generated.parameterSwiftTypes == [owner]
                && invocationParameterSwiftTypes == [owner]
                && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(owner)
        case .instanceSetter, .instanceValueSetter:
            guard let owner = generated.ownerType else { return false }
            return generated.argumentLabels == ["_"]
                && generated.parameterSwiftTypes.count == 2
                && generated.parameterSwiftTypes.last == owner
                && invocationParameterSwiftTypes.last == owner
                && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(owner)
        }
    }

    private static func isValidNativeImportBinding(
        _ binding: ShellBuildReceipt.NativeImportBinding,
        record: InterfaceArchive.NativeImportRecord,
        declarations: [ReleaseCompiler.DeclarationCandidate],
        sourcePaths: Set<String>
    ) -> Bool {
        switch binding.strategy {
        case .factory:
            return binding.factoryReference.map(isModulePath) == true
                && binding.generated == nil
                && binding.cFunction == nil
                && (record.descriptor.target.backend == .builtin
                    || record.descriptor.target.backend == .swiftAdapter)
        case .generatedSwiftAdapter:
            return binding.factoryReference == nil
                && record.descriptor.target.backend == .swiftAdapter
                && binding.generated != nil
                && binding.cFunction == nil
                && (binding.generated?.nativeModuleName == nil
                    || binding.generated?.nativeModuleName
                        == record.descriptor.target.module)
                && isValidGeneratedNativeImport(
                    binding.generated,
                    importedModules: binding.importedModules,
                    declarations: declarations,
                    sourcePaths: sourcePaths
                )
        case .objectiveCInvoker:
            return binding.factoryReference == nil
                && binding.generated == nil
                && binding.cFunction == nil
                && binding.importedModules.isEmpty
                && record.descriptor.target.backend == .objectiveCMessage
                && !record.effects.isAsync
        case .cInvoker:
            guard binding.factoryReference == nil,
                  binding.generated == nil,
                  record.descriptor.target.backend == .cFunction,
                  !record.effects.isAsync,
                  let function = binding.cFunction
            else { return false }
            return isModulePath(function.moduleName)
                && isSwiftIdentifier(function.swiftName)
                && binding.importedModules == [function.moduleName]
                && record.descriptor.target.module == function.moduleName
                && record.descriptor.target.member == function.swiftName
                && function.parameterSwiftTypes
                    == record.descriptor.physicalSignature.parameters
                        .compactMap(\.type.canonicalName)
                && function.parameterSwiftTypes.allSatisfy(
                    FrontendReceipt.SwiftTypeSpelling.isGeneratedType
                )
                && function.resultSwiftType
                    == (record.descriptor.physicalSignature.result.canonicalName
                        ?? "Swift.Void")
                && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
                    function.resultSwiftType
                )
        }
    }

    private static func isValidGeneratedNativeType(
        _ generated: ShellBuildReceipt.GeneratedNativeType?,
        record: InterfaceArchive.TypeRecord,
        moduleName: String,
        importedModules: [String],
        sourcePaths: Set<String>
    ) -> Bool {
        guard let generated else { return true }
        let modulePrefix = moduleName + "."
        let isSourceType = record.canonicalName.hasPrefix(modulePrefix)
        let acceptedSwiftTypes: Set<String> = if isSourceType {
            [String(record.canonicalName.dropFirst(modulePrefix.count))]
        } else {
            Set(record.swiftTypeAliases + [record.canonicalName])
        }
        let originIsValid: Bool
        if let nativeModuleName = generated.nativeModuleName {
            originIsValid = !isSourceType
                && isModulePath(nativeModuleName)
                && importedModules.contains(nativeModuleName)
                && !sourcePaths.contains(generated.sourceFileLogicalID)
        } else {
            originIsValid = sourcePaths.contains(
                generated.sourceFileLogicalID
            )
        }
        let encodingIsValid: Bool = switch generated.representation {
        case .objectiveCStructure:
            generated.nativeABIEncoding.map {
                !$0.isEmpty && $0.utf8.count <= 4_096
            } == true
        case .reference, .rawRepresentable, .opaqueValue:
            generated.nativeABIEncoding == nil
        }
        return encodingIsValid
            && originIsValid
            && (isSourceType ? importedModules.isEmpty : !importedModules.isEmpty)
            && acceptedSwiftTypes.contains(generated.swiftType)
            && FrontendReceipt.SwiftTypeSpelling.isGeneratedType(generated.swiftType)
    }

    private static func isValidNativeTypeBinding(
        _ binding: ShellBuildReceipt.NativeTypeBinding,
        record: InterfaceArchive.TypeRecord,
        moduleName: String,
        sourcePaths: Set<String>
    ) -> Bool {
        guard !binding.canonicalName.isEmpty,
              binding.importedModules
                == Array(Set(binding.importedModules)).sorted(),
              binding.importedModules.allSatisfy(Self.isModulePath)
        else { return false }
        switch binding.strategy {
        case .factory:
            return binding.operationsExpression.map(Self.isBoundExpression) == true
                && record.objectiveCRuntimeName == nil
                && Self.isValidGeneratedNativeType(
                    binding.generated,
                    record: record,
                    moduleName: moduleName,
                    importedModules: binding.importedModules,
                    sourcePaths: sourcePaths
                )
        case .objectiveCReference:
            return binding.operationsExpression == nil
                && binding.generated == nil
                && !binding.importedModules.isEmpty
                && record.kind == .reference
                && record.isCopyable
                && record.objectiveCRuntimeName.map(
                    Core.NativeCall.isCanonicalObjectiveCRuntimeClassName
                ) == true
        }
    }

    private static func isSafeLogicalPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 16 * 1_024 else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..") && !components.contains("")
            && !path.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func isBoundText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 * 1_024
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func isBoundOptionalText(_ value: String) -> Bool {
        value.utf8.count <= 64 * 1_024
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func isBoundExpression(_ value: String) -> Bool {
        isBoundText(value)
    }

    private static func isModulePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            guard let first = $0.first, first == "_" || first.isLetter else { return false }
            return $0.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
        }
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        Core.SwiftName.isIdentifier(value)
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
            "unsupported Shell Build Receipt schema \(version)"
        case let .documentTooLarge(actual, maximum):
            "Shell Build Receipt is \(actual) bytes; maximum is \(maximum)"
        case .nonCanonical:
            "Shell Build Receipt is not canonical JSON"
        case let .invalid(reason):
            "invalid Shell Build Receipt: \(reason)"
        }
    }
}

public enum Codec {
    public static let maximumDocumentBytes = 32 * 1_024 * 1_024

    public static func encode(_ document: ShellBuildReceipt.Document) throws -> Data {
        try document.validate()
        return try Core.CanonicalJSON.encode(document)
    }

    public static func decode(_ data: Data) throws -> ShellBuildReceipt.Document {
        guard data.count <= maximumDocumentBytes else {
            throw ShellBuildReceipt.Error.documentTooLarge(
                actual: data.count,
                maximum: maximumDocumentBytes
            )
        }
        let document: ShellBuildReceipt.Document
        do {
            document = try JSONDecoder().decode(ShellBuildReceipt.Document.self, from: data)
        } catch {
            throw ShellBuildReceipt.Error.invalid("JSON decoding failed: \(error)")
        }
        guard try Core.CanonicalJSON.encode(document) == data else {
            throw ShellBuildReceipt.Error.nonCanonical
        }
        try document.validate()
        return document
    }
}
}
