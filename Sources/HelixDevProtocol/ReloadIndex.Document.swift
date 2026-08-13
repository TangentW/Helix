import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixLiveReloadAPI
#endif

public enum ReloadIndex {}

extension ReloadIndex {
public enum FunctionRole: String, Codable, Hashable, Sendable {
    case eventHandler
    case viewLoadOrInitialization
    case layoutCallback
    case tableOrCollectionDataSource
    case drawingOrConfiguration
    case swiftUIViewBody
    case modelOrService
    case unknown
}

public struct Root: Codable, Hashable, Sendable {
    public var functionKey: Core.FunctionKey
    public var nominalTypeID: LiveReload.NominalTypeID?
    public var role: ReloadIndex.FunctionRole

    public init(
        functionKey: Core.FunctionKey,
        nominalTypeID: LiveReload.NominalTypeID?,
        role: ReloadIndex.FunctionRole
    ) {
        self.functionKey = functionKey
        self.nominalTypeID = nominalTypeID
        self.role = role
    }
}

public struct SourceRoots: Codable, Hashable, Sendable {
    public var sourceFileID: LiveReload.SourceFileID
    public var roots: [Core.FunctionKey]

    public init(sourceFileID: LiveReload.SourceFileID, roots: [Core.FunctionKey]) {
        self.sourceFileID = sourceFileID
        self.roots = roots.sorted { $0.description < $1.description }
    }
}

public struct SuperclassEdge: Codable, Hashable, Sendable {
    public var subtype: LiveReload.NominalTypeID
    public var superclass: LiveReload.NominalTypeID

    public init(
        subtype: LiveReload.NominalTypeID,
        superclass: LiveReload.NominalTypeID
    ) {
        self.subtype = subtype
        self.superclass = superclass
    }
}

public struct Rule: Codable, Hashable, Sendable {
    public var sourceFileIDs: [LiveReload.SourceFileID]
    public var controllerTypeID: LiveReload.NominalTypeID
    public var policy: LiveReload.Policy
    public var invalidationHints: LiveReload.InvalidationHints
    public var factoryID: LiveReload.FactoryID?

    public init(
        sourceFileIDs: [LiveReload.SourceFileID],
        controllerTypeID: LiveReload.NominalTypeID,
        policy: LiveReload.Policy,
        invalidationHints: LiveReload.InvalidationHints = [],
        factoryID: LiveReload.FactoryID? = nil
    ) {
        self.sourceFileIDs = sourceFileIDs.sorted { $0.description < $1.description }
        self.controllerTypeID = controllerTypeID
        self.policy = policy
        self.invalidationHints = invalidationHints
        self.factoryID = factoryID
    }
}

public struct FactoryDescriptor: Codable, Hashable, Sendable {
    public var id: LiveReload.FactoryID
    public var controllerTypeID: LiveReload.NominalTypeID

    public init(id: LiveReload.FactoryID, controllerTypeID: LiveReload.NominalTypeID) {
        self.id = id
        self.controllerTypeID = controllerTypeID
    }
}

/// Build-time metadata used to turn a saved function body into a native
/// Dynamic Replacement declaration. The descriptor is emitted from the typed
/// source index; the Helix service never guesses a declaration by name.
public struct NativeReplacement: Codable, Hashable, Sendable {
    public var functionKey: Core.FunctionKey
    public var sourceFileID: LiveReload.SourceFileID
    public var declarationAnchor: String
    public var declarationOccurrence: UInt32
    public var loweredType: String
    public var originalReference: String
    public var replacementDeclaration: String
    public var enclosingPrefix: String
    public var enclosingSuffix: String
    public var importedModules: [String]

    public init(
        functionKey: Core.FunctionKey,
        sourceFileID: LiveReload.SourceFileID,
        declarationAnchor: String,
        declarationOccurrence: UInt32 = 0,
        loweredType: String,
        originalReference: String,
        replacementDeclaration: String,
        enclosingPrefix: String = "",
        enclosingSuffix: String = "",
        importedModules: [String] = []
    ) {
        self.functionKey = functionKey
        self.sourceFileID = sourceFileID
        self.declarationAnchor = declarationAnchor
        self.declarationOccurrence = declarationOccurrence
        self.loweredType = loweredType
        self.originalReference = originalReference
        self.replacementDeclaration = replacementDeclaration
        self.enclosingPrefix = enclosingPrefix
        self.enclosingSuffix = enclosingSuffix
        self.importedModules = importedModules.sorted()
    }
}

public struct Document: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var sourceRoots: [ReloadIndex.SourceRoots]
    public var roots: [ReloadIndex.Root]
    public var nativeReplacements: [ReloadIndex.NativeReplacement]
    public var superclassEdges: [ReloadIndex.SuperclassEdge]
    public var explicitReloadRules: [ReloadIndex.Rule]
    public var factories: [ReloadIndex.FactoryDescriptor]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        sourceRoots: [ReloadIndex.SourceRoots],
        roots: [ReloadIndex.Root],
        nativeReplacements: [ReloadIndex.NativeReplacement] = [],
        superclassEdges: [ReloadIndex.SuperclassEdge] = [],
        explicitReloadRules: [ReloadIndex.Rule] = [],
        factories: [ReloadIndex.FactoryDescriptor] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sourceRoots = sourceRoots.sorted { $0.sourceFileID.description < $1.sourceFileID.description }
        self.roots = roots.sorted { $0.functionKey.description < $1.functionKey.description }
        self.nativeReplacements = nativeReplacements.sorted {
            $0.functionKey.description < $1.functionKey.description
        }
        self.superclassEdges = superclassEdges.sorted { $0.subtype.description < $1.subtype.description }
        self.explicitReloadRules = explicitReloadRules.sorted(by: Self.ruleOrder)
        self.factories = factories.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func contentHash() throws -> Core.Digest {
        try validate()
        return .sha256(try Core.CanonicalJSON.encode(self))
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DevProtocol.Error.malformedMessage(
                "unsupported Reload Index schema \(schemaVersion)"
            )
        }
        guard sourceRoots == sourceRoots.sorted(by: {
            $0.sourceFileID.description < $1.sourceFileID.description
        }), roots == roots.sorted(by: {
            $0.functionKey.description < $1.functionKey.description
        }), nativeReplacements == nativeReplacements.sorted(by: {
            $0.functionKey.description < $1.functionKey.description
        }), superclassEdges == superclassEdges.sorted(by: Self.edgeOrder),
            explicitReloadRules == explicitReloadRules.sorted(by: Self.ruleOrder),
            factories == factories.sorted(by: { $0.id.rawValue < $1.id.rawValue })
        else {
            throw DevProtocol.Error.malformedMessage(
                "Reload Index collections are not canonically ordered"
            )
        }
        guard Set(sourceRoots.map(\.sourceFileID)).count == sourceRoots.count,
              Set(roots.map(\.functionKey)).count == roots.count,
              Set(nativeReplacements.map(\.functionKey)).count == nativeReplacements.count,
              Set(superclassEdges.map(\.subtype)).count == superclassEdges.count,
              Set(explicitReloadRules).count == explicitReloadRules.count,
              Set(factories.map(\.id)).count == factories.count,
              Set(factories.map(\.controllerTypeID)).count == factories.count
        else {
            throw DevProtocol.Error.malformedMessage("Reload Index contains duplicate identities")
        }
        let knownRoots = Set(roots.map(\.functionKey))
        for source in sourceRoots {
            guard !source.roots.isEmpty,
                  Set(source.roots).count == source.roots.count,
                  source.roots == source.roots.sorted(by: { $0.description < $1.description }),
                  Set(source.roots).isSubset(of: knownRoots)
            else {
                throw DevProtocol.Error.malformedMessage(
                    "source-to-root mapping is empty, duplicated, unordered, or dangling"
                )
            }
        }
        let factoryByID = Dictionary(uniqueKeysWithValues: factories.map { ($0.id, $0) })
        let knownSources = Set(sourceRoots.map(\.sourceFileID))
        for replacement in nativeReplacements {
            guard knownRoots.contains(replacement.functionKey),
                  knownSources.contains(replacement.sourceFileID),
                  replacement.declarationAnchor.utf8.last == UInt8(ascii: "{"),
                  replacement.declarationAnchor.range(
                      of: #"^func\s+"#,
                      options: .regularExpression
                  ) != nil,
                  replacement.declarationOccurrence <= 65_535,
                  replacement.declarationAnchor.utf8.count <= 64 * 1_024,
                  !replacement.loweredType.isEmpty,
                  replacement.loweredType.utf8.count <= 64 * 1_024,
                  !replacement.originalReference.isEmpty,
                  replacement.originalReference.utf8.count <= 16 * 1_024,
                  replacement.replacementDeclaration.contains("func "),
                  replacement.replacementDeclaration.utf8.count <= 64 * 1_024,
                  replacement.enclosingPrefix.utf8.count <= 64 * 1_024,
                  replacement.enclosingSuffix.utf8.count <= 64 * 1_024,
                  replacement.importedModules.count <= 256,
                  Set(replacement.importedModules).count == replacement.importedModules.count,
                  replacement.importedModules == replacement.importedModules.sorted(),
                  replacement.importedModules.allSatisfy(Self.isModulePath),
                  !Self.containsNull(replacement.declarationAnchor),
                  !Self.containsNull(replacement.loweredType),
                  !Self.containsNull(replacement.originalReference),
                  !Self.containsNull(replacement.replacementDeclaration),
                  !Self.containsNull(replacement.enclosingPrefix),
                  !Self.containsNull(replacement.enclosingSuffix)
            else {
                throw DevProtocol.Error.malformedMessage(
                    "Native replacement metadata is incomplete, oversized, or dangling"
                )
            }
        }
        for factory in factories {
            guard !factory.id.rawValue.isEmpty, factory.id.rawValue.utf8.count <= 512 else {
                throw DevProtocol.Error.malformedMessage("factory ID is empty or too large")
            }
        }
        for rule in explicitReloadRules {
            guard !rule.sourceFileIDs.isEmpty,
                  Set(rule.sourceFileIDs).count == rule.sourceFileIDs.count,
                  rule.sourceFileIDs == rule.sourceFileIDs.sorted(by: {
                      $0.description < $1.description
                  }),
                  Set(rule.sourceFileIDs).isSubset(of: knownSources)
            else {
                throw DevProtocol.Error.malformedMessage(
                    "explicit reload rule has invalid source identities"
                )
            }
            let hint = DevProtocol.ReloadHint(
                nominalTypeID: rule.controllerTypeID,
                policy: rule.policy,
                invalidationHints: rule.invalidationHints,
                factoryID: rule.factoryID
            )
            try hint.validate()
            if let factoryID = rule.factoryID,
               factoryByID[factoryID]?.controllerTypeID != rule.controllerTypeID
            {
                throw DevProtocol.Error.malformedMessage(
                    "reload rule references a missing or mismatched factory"
                )
            }
        }
        guard superclassEdges.allSatisfy({ $0.subtype != $0.superclass }) else {
            throw DevProtocol.Error.malformedMessage("Reload Index contains a self superclass edge")
        }
        let parentBySubtype = Dictionary(
            uniqueKeysWithValues: superclassEdges.map { ($0.subtype, $0.superclass) }
        )
        for start in parentBySubtype.keys {
            var visited = Set<LiveReload.NominalTypeID>()
            var cursor: LiveReload.NominalTypeID? = start
            while let type = cursor {
                guard visited.insert(type).inserted else {
                    throw DevProtocol.Error.malformedMessage(
                        "Reload Index contains a superclass cycle"
                    )
                }
                cursor = parentBySubtype[type]
            }
        }
    }

    public func hints(
        changedSources: Set<LiveReload.SourceFileID>,
        changedFunctions: Set<Core.FunctionKey>
    ) throws -> [DevProtocol.ReloadHint] {
        try validate()
        var result = explicitReloadRules.compactMap { rule -> DevProtocol.ReloadHint? in
            guard !changedSources.isDisjoint(with: rule.sourceFileIDs) else { return nil }
            return .init(
                nominalTypeID: rule.controllerTypeID,
                policy: rule.policy,
                invalidationHints: rule.invalidationHints,
                factoryID: rule.factoryID
            )
        }
        let rootMap = roots.reduce(into: [Core.FunctionKey: ReloadIndex.Root]()) {
            $0[$1.functionKey] = $1
        }
        let factoryByType = factories.reduce(
            into: [LiveReload.NominalTypeID: ReloadIndex.FactoryDescriptor]()
        ) { $0[$1.controllerTypeID] = $1 }
        for function in changedFunctions.sorted(by: { $0.description < $1.description }) {
            guard let root = rootMap[function], let nominal = root.nominalTypeID else { continue }
            let policy: LiveReload.Policy
            let hints: LiveReload.InvalidationHints
            switch root.role {
            case .eventHandler, .modelOrService:
                policy = .observeOnly
                hints = []
            case .layoutCallback:
                policy = .invalidate
                hints = [.constraints, .layout]
            case .tableOrCollectionDataSource:
                policy = .invalidate
                hints = [.tableData, .collectionData]
            case .drawingOrConfiguration:
                policy = .invalidate
                hints = [.display, .layout]
            case .viewLoadOrInitialization:
                policy = factoryByType[nominal] == nil ? .invokeHook : .recreate
                hints = []
            case .swiftUIViewBody, .unknown:
                policy = .observeOnly
                hints = []
            }
            result.append(
                .init(
                    nominalTypeID: nominal,
                    policy: policy,
                    invalidationHints: hints,
                    factoryID: policy == .recreate ? factoryByType[nominal]?.id : nil
                )
            )
        }
        var seen = Set<String>()
        let unique = result.filter {
            let key = "\($0.nominalTypeID?.description ?? "none"):\($0.policy.rawValue):\($0.invalidationHints.rawValue):\($0.factoryID?.rawValue ?? "none")"
            return seen.insert(key).inserted
        }
        return unique.sorted {
            let lhs = "\($0.nominalTypeID?.description ?? ""):\($0.policy.rawValue):\($0.factoryID?.rawValue ?? "")"
            let rhs = "\($1.nominalTypeID?.description ?? ""):\($1.policy.rawValue):\($1.factoryID?.rawValue ?? "")"
            return lhs < rhs
        }
    }

    private static func edgeOrder(
        _ lhs: ReloadIndex.SuperclassEdge,
        _ rhs: ReloadIndex.SuperclassEdge
    ) -> Bool {
        if lhs.subtype != rhs.subtype {
            return lhs.subtype.description < rhs.subtype.description
        }
        return lhs.superclass.description < rhs.superclass.description
    }

    private static func ruleOrder(_ lhs: ReloadIndex.Rule, _ rhs: ReloadIndex.Rule) -> Bool {
        let left = "\(lhs.controllerTypeID.description):\(lhs.policy.rawValue):\(lhs.factoryID?.rawValue ?? ""):\(lhs.sourceFileIDs.map(\.description).joined(separator: ","))"
        let right = "\(rhs.controllerTypeID.description):\(rhs.policy.rawValue):\(rhs.factoryID?.rawValue ?? ""):\(rhs.sourceFileIDs.map(\.description).joined(separator: ","))"
        return left < right
    }

    private static func containsNull(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0 }
    }

    private static func isModulePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            guard let first = $0.first, first == "_" || first.isLetter else { return false }
            return $0.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
        }
    }
}
}
