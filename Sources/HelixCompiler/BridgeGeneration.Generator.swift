import Foundation
import HelixBytecode
import HelixCore
import HelixInterface

public enum BridgeGeneration {}

extension BridgeGeneration {
/// Location in which a permanent Shell entry dispatch site is emitted.
public enum Installation: Hashable, Sendable {
    /// Emits a generated declaration that replaces the original dynamically.
    case dynamicReplacement
    /// Rewrites the exact body in the derived copy of its defining source.
    case sourceBody
}

public struct Root: Hashable, Sendable {
    public var functionKey: Core.FunctionKey
    public var entryIndex: Core.EntryIndex
    public var sourceFileLogicalID: String
    public var privateImportSourceFile: String
    public var sourceDeclaration: Core.DynamicReplacement.Declaration
    public var memberRole: Core.DynamicReplacement.MemberRole
    public var parameterExpressions: [String]
    public var parameterSwiftTypes: [String]
    public var resultSwiftType: String
    public var originalInvocation: String
    public var bridgeInvocation: String?
    public var installation: BridgeGeneration.Installation

    public init(
        functionKey: Core.FunctionKey,
        entryIndex: Core.EntryIndex,
        sourceFileLogicalID: String,
        privateImportSourceFile: String,
        sourceDeclaration: Core.DynamicReplacement.Declaration,
        memberRole: Core.DynamicReplacement.MemberRole,
        parameterExpressions: [String],
        parameterSwiftTypes: [String],
        resultSwiftType: String,
        originalInvocation: String,
        bridgeInvocation: String?,
        installation: BridgeGeneration.Installation = .dynamicReplacement
    ) {
        self.functionKey = functionKey
        self.entryIndex = entryIndex
        self.sourceFileLogicalID = sourceFileLogicalID
        self.privateImportSourceFile = privateImportSourceFile
        self.sourceDeclaration = sourceDeclaration
        self.memberRole = memberRole
        self.parameterExpressions = parameterExpressions
        self.parameterSwiftTypes = parameterSwiftTypes
        self.resultSwiftType = resultSwiftType
        self.originalInvocation = originalInvocation
        self.bridgeInvocation = bridgeInvocation
        self.installation = installation
    }
}

public struct NativeImportBinding: Hashable, Sendable {
    public var id: Core.NativeImportID
    public var key: Core.NativeImportKey
    public var invokerExpression: String
    public var importedModules: [String]
    public var generated: BridgeGeneration.GeneratedNativeImport?

    public init(
        id: Core.NativeImportID,
        key: Core.NativeImportKey,
        invokerExpression: String,
        importedModules: [String] = [],
        generated: BridgeGeneration.GeneratedNativeImport? = nil
    ) {
        self.id = id
        self.key = key
        self.invokerExpression = invokerExpression
        self.importedModules = importedModules.sorted()
        self.generated = generated
    }
}

public struct GeneratedNativeImport: Hashable, Sendable {
    public enum Dispatch: String, Hashable, Sendable {
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
    public var resultSwiftType: String

    public init(
        declarationMangledName: String,
        sourceFileLogicalID: String,
        dispatch: Dispatch,
        ownerType: String? = nil,
        baseName: String,
        argumentLabels: [String],
        parameterSwiftTypes: [String],
        resultSwiftType: String
    ) {
        self.declarationMangledName = declarationMangledName
        self.sourceFileLogicalID = sourceFileLogicalID
        self.dispatch = dispatch
        self.ownerType = ownerType
        self.baseName = baseName
        self.argumentLabels = argumentLabels
        self.parameterSwiftTypes = parameterSwiftTypes
        self.resultSwiftType = resultSwiftType
    }

    public static func groupName(sourceFileLogicalID: String) -> String {
        "HelixNativeImports_\(Core.Digest.sha256(sourceFileLogicalID).hex)"
    }

    public static func factoryName(key: Core.NativeImportKey) -> String {
        "make_\(key.rawValue.hex)"
    }

    public static func bindingExpression(
        sourceFileLogicalID: String,
        id: Core.NativeImportID,
        key: Core.NativeImportKey
    ) -> String {
        let group = groupName(sourceFileLogicalID: sourceFileLogicalID)
        let factory = factoryName(key: key)
        return "\(group).\(factory)(id: Core.NativeImportID(rawValue: \(id.rawValue)), "
            + "key: Core.NativeImportKey(rawValue: try! Core.Digest(hex: "
            + "\(String(reflecting: key.rawValue.hex)))))"
    }
}

public struct NativeTypeBinding: Hashable, Sendable {
    public var id: Core.TypeID
    public var canonicalName: String
    public var layoutFingerprint: Core.Digest
    public var requiresMainActor: Bool
    public var operationsExpression: String
    public var importedModules: [String]
    public var generated: BridgeGeneration.GeneratedNativeType?

    public init(
        id: Core.TypeID,
        canonicalName: String,
        layoutFingerprint: Core.Digest,
        requiresMainActor: Bool = false,
        operationsExpression: String,
        importedModules: [String] = [],
        generated: BridgeGeneration.GeneratedNativeType? = nil
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.layoutFingerprint = layoutFingerprint
        self.requiresMainActor = requiresMainActor
        self.operationsExpression = operationsExpression
        self.importedModules = importedModules.sorted()
        self.generated = generated
    }
}

public struct GeneratedNativeType: Hashable, Sendable {
    public enum Representation: String, Hashable, Sendable {
        case reference
        case rawRepresentable
        case opaqueValue
    }

    public var sourceFileLogicalID: String
    public var swiftType: String
    public var representation: Representation

    public init(
        sourceFileLogicalID: String,
        swiftType: String,
        representation: Representation = .reference
    ) {
        self.sourceFileLogicalID = sourceFileLogicalID
        self.swiftType = swiftType
        self.representation = representation
    }

    public static func groupName(sourceFileLogicalID: String) -> String {
        "HelixBridgeEntries_\(Core.Digest.sha256(sourceFileLogicalID).hex.prefix(12))"
    }

    public static func factoryName(id: Core.TypeID) -> String {
        "makeNativeType_\(id.rawValue.hex)"
    }

    public static func bindingExpression(
        sourceFileLogicalID: String,
        id: Core.TypeID,
        canonicalName: String,
        layoutFingerprint: Core.Digest,
        requiresMainActor: Bool,
        estimatedSize: UInt64
    ) -> String {
        let group = groupName(sourceFileLogicalID: sourceFileLogicalID)
        let factory = factoryName(id: id)
        return "\(group).\(factory)(id: Core.TypeID(rawValue: try! Core.Digest(hex: "
            + "\(String(reflecting: id.rawValue.hex)))), canonicalName: "
            + "\(String(reflecting: canonicalName)), layoutFingerprint: try! Core.Digest(hex: "
            + "\(String(reflecting: layoutFingerprint.hex))), requiresMainActor: "
            + "\(requiresMainActor), estimatedSize: \(estimatedSize))"
    }
}

public struct Output: Sendable {
    public var moduleName: String
    public var sourceFiles: [String: String]
    public var registrationCount: UInt32
    public var interfaceHash: Core.Digest
}

public struct Generator: Sendable {
    public init() {}

    /// Returns the stable source path for the replacement entries associated
    /// with one original Swift file. The path depends only on the logical
    /// source identity, so Xcode can reference it before a Shell is indexed.
    public static func entrySourcePath(for sourceFileLogicalID: String) -> String {
        let digest = Core.Digest.sha256(sourceFileLogicalID).hex
        return "Generated/HelixBridge.Entry_\(digest.prefix(12)).swift"
    }

    /// Returns the stable source path for generated NativeImport adapters
    /// associated with one original Swift file.
    public static func nativeImportSourcePath(for sourceFileLogicalID: String) -> String {
        let digest = Core.Digest.sha256(sourceFileLogicalID).hex
        return "Generated/HelixBridge.NativeImport_\(digest).swift"
    }

    public func generate(
        archive: InterfaceArchive.Archive,
        moduleName: String,
        roots: [BridgeGeneration.Root],
        nativeImports: [BridgeGeneration.NativeImportBinding] = [],
        nativeTypes: [BridgeGeneration.NativeTypeBinding] = []
    ) throws -> BridgeGeneration.Output {
        try archive.validate()
        guard BridgeGeneration.isValidSwiftIdentifier(moduleName) else {
            throw BridgeGeneration.Error.invalidModuleName
        }
        let eligible = archive.functions.filter(\.patchability.isEligible)
        guard roots.count == eligible.count,
              Set(roots.map(\.functionKey)).count == roots.count,
              Set(roots.map(\.entryIndex)).count == roots.count
        else {
            throw BridgeGeneration.Error.incompleteRootSet
        }
        let byKey = Dictionary(uniqueKeysWithValues: eligible.map { ($0.key, $0) })
        let frozenValueTypes = Dictionary(
            uniqueKeysWithValues: archive.frozenValueTypes.map { ($0.key, $0) }
        )
        for root in roots {
            guard let record = byKey[root.functionKey],
                  record.entryIndex == root.entryIndex,
                  record.sourceFileLogicalID == root.sourceFileLogicalID
            else {
                throw BridgeGeneration.Error.rootDoesNotMatchArchive(root.functionKey)
            }
            try validateRoot(
                root,
                record: record,
                archive: archive,
                frozenValueTypes: frozenValueTypes
            )
        }
        for values in Dictionary(
            grouping: roots,
            by: { $0.sourceDeclaration.identity }
        ).values {
            guard let first = values.first,
                  values.allSatisfy({
                      $0.sourceFileLogicalID == first.sourceFileLogicalID
                          && $0.sourceDeclaration == first.sourceDeclaration
                          && $0.installation == first.installation
                  }),
                  Set(values.map(\.memberRole)).count == values.count
            else {
                throw BridgeGeneration.Error.incompleteRootSet
            }
        }
        try validateFrozenValueCodecs(
            archive: archive,
            frozenValueTypes: frozenValueTypes
        )
        try validateNativeBindings(
            archive: archive,
            imports: nativeImports,
            types: nativeTypes
        )

        let grouped = Dictionary(grouping: roots, by: \.sourceFileLogicalID)
        let generatedTypes = nativeTypes.compactMap { binding -> (
            BridgeGeneration.NativeTypeBinding,
            BridgeGeneration.GeneratedNativeType
        )? in
            binding.generated.map { (binding, $0) }
        }
        let generatedTypeGroups = Dictionary(
            grouping: generatedTypes,
            by: { $0.1.sourceFileLogicalID }
        )
        let frozenValueGroups = Dictionary(
            grouping: archive.frozenValueTypes,
            by: \.sourceFileLogicalID
        )
        let sourceGroups = Set(grouped.keys)
            .union(generatedTypeGroups.keys)
            .union(frozenValueGroups.keys)
            .sorted()
        let nativeTypesByID = Dictionary(uniqueKeysWithValues: archive.nativeTypes.map {
            ($0.id, $0)
        })
        var files: [String: String] = [:]
        var entryGroupNames: [String] = []
        for source in sourceGroups {
            let values = grouped[source] ?? []
            let typeValues = generatedTypeGroups[source] ?? []
            let frozenValues = frozenValueGroups[source] ?? []
            let privateImportSourceFile = URL(fileURLWithPath: source).lastPathComponent
            guard values.allSatisfy({
                $0.privateImportSourceFile == privateImportSourceFile
            }), typeValues.allSatisfy({ $0.1.sourceFileLogicalID == source }) else {
                if let first = values.first {
                    throw BridgeGeneration.Error.invalidRoot(first.functionKey)
                }
                throw BridgeGeneration.Error.incompleteNativeTypeBindings
            }
            let groupName = BridgeGeneration.GeneratedNativeType.groupName(
                sourceFileLogicalID: source
            )
            entryGroupNames.append(groupName)
            let generatedTypeImports = Array(
                Set(typeValues.flatMap { $0.0.importedModules })
            ).sorted().map { "import \($0)" }
            var lines = [
                "// Generated by Helix Release Bridge Generator. Do not edit.",
                "@_private(sourceFile: \(String(reflecting: privateImportSourceFile))) import \(moduleName)",
            ] + generatedTypeImports + [
                "import Foundation",
            ] + BridgeGeneration.RuntimeImports.productionLines + [
                "",
                "enum \(groupName) {",
                "    static func makeOriginalEntries(",
                "        nativeTypeCatalog: VM.NativeTypeCatalog",
                "    ) -> [Runtime.OriginalEntry] {",
                "        [",
            ]
            let sortedValues = values.sorted(by: { $0.entryIndex < $1.entryIndex })
            for (offset, root) in sortedValues.enumerated() {
                let record = byKey[root.functionKey]!
                lines.append(indent(try renderOriginalEntry(
                    root,
                    record: record,
                    frozenValueTypes: frozenValueTypes
                ), spaces: 12)
                    + (offset == sortedValues.count - 1 ? "" : ","))
            }
            lines.append(contentsOf: [
                "        ]",
                "    }",
            ])
            for (binding, generated) in typeValues.sorted(by: { $0.0.id.rawValue < $1.0.id.rawValue }) {
                guard let record = nativeTypesByID[binding.id] else {
                    throw BridgeGeneration.Error.nativeTypeBindingMismatch(binding.id)
                }
                lines.append("")
                lines.append(indent(
                    try renderGeneratedNativeTypeFactory(
                        binding: binding,
                        generated: generated,
                        record: record
                    ),
                    spaces: 4
                ))
            }
            for record in frozenValues.sorted(by: { $0.key < $1.key }) {
                lines.append("")
                lines.append(indent(
                    try renderFrozenValueCodec(
                        record,
                        frozenValueTypes: frozenValueTypes
                    ),
                    spaces: 4
                ))
            }
            lines.append("}")
            let replacementGroups = Dictionary(
                grouping: sortedValues,
                by: { $0.sourceDeclaration.identity }
            ).values.sorted {
                $0[0].sourceDeclaration.identity < $1[0].sourceDeclaration.identity
            }
            for replacementGroup in replacementGroups
            where replacementGroup[0].installation == .dynamicReplacement {
                lines.append("")
                lines.append(try renderReplacementDeclaration(
                    replacementGroup,
                    records: byKey,
                    frozenValueTypes: frozenValueTypes
                ))
            }
            lines.append("")
            files[Self.entrySourcePath(for: source)] = lines.joined(separator: "\n")
        }
        for source in archive.sources.map(\.logicalPath)
        where grouped[source] == nil && generatedTypeGroups[source] == nil
                && frozenValueGroups[source] == nil {
            let path = Self.entrySourcePath(for: source)
            guard files[path] == nil else { throw BridgeGeneration.Error.outputCollision(path) }
            files[path] = Self.emptyGeneratedSource(
                purpose: "replacement entries",
                sourceFileLogicalID: source
            )
        }
        let generatedImports = nativeImports.compactMap { binding -> (
            BridgeGeneration.NativeImportBinding,
            BridgeGeneration.GeneratedNativeImport
        )? in
            binding.generated.map { (binding, $0) }
        }
        let generatedImportGroups = Dictionary(
            grouping: generatedImports,
            by: { $0.1.sourceFileLogicalID }
        )
        for (source, values) in generatedImportGroups.sorted(by: { $0.key < $1.key }) {
            let path = Self.nativeImportSourcePath(for: source)
            guard files[path] == nil else { throw BridgeGeneration.Error.outputCollision(path) }
            files[path] = try renderGeneratedNativeImportFile(
                sourceFileLogicalID: source,
                moduleName: moduleName,
                bindings: values.map(\.0),
                archive: archive
            )
        }
        for source in archive.sources.map(\.logicalPath)
        where generatedImportGroups[source] == nil {
            let path = Self.nativeImportSourcePath(for: source)
            guard files[path] == nil else { throw BridgeGeneration.Error.outputCollision(path) }
            files[path] = Self.emptyGeneratedSource(
                purpose: "NativeImport adapters",
                sourceFileLogicalID: source
            )
        }
        let bridgeTypeName = "\(moduleName)Bridge"
        let shellFactory = renderShellFactory(archive: archive)
        let patchBuildContractFactory = renderPatchBuildContractFactory(archive: archive)
        let originalCatalogFactory = renderOriginalCatalogFactory(
            entryGroupNames: entryGroupNames
        )
        let nativeCatalogFactory = try renderNativeCatalogFactory(
            imports: nativeImports,
            records: archive.nativeImports,
            types: nativeTypes
        )
        let nativeImportStatements = Array(
            Set(nativeImports.flatMap(\.importedModules) + nativeTypes.flatMap(\.importedModules))
        ).sorted().map { "import \($0)" }.joined(separator: "\n")
        files["Generated/\(bridgeTypeName).swift"] = """
        // Generated by Helix Release Bridge Generator. Do not edit.
        \(BridgeGeneration.RuntimeImports.production)
        \(nativeImportStatements)

        public enum \(bridgeTypeName) {
            public static let interfaceHash = try! Core.Digest(hex: "\(archive.shellInterfaceHash.hex)")
            public static let registrationCount: UInt32 = \(eligible.count)

        \(shellFactory)

        \(patchBuildContractFactory)

        \(originalCatalogFactory)

        \(nativeCatalogFactory)

            public static func bootstrap(using runtime: Runtime.Engine) throws {
                try Runtime.Bridge.shared.install(
                    runtime: runtime,
                    interfaceHash: interfaceHash,
                    registrationCount: registrationCount
                )
            }
        }
        """
        return .init(
            moduleName: moduleName,
            sourceFiles: files,
            registrationCount: UInt32(eligible.count),
            interfaceHash: archive.shellInterfaceHash
        )
    }

    private static func emptyGeneratedSource(
        purpose: String,
        sourceFileLogicalID: String
    ) -> String {
        """
        // Generated by Helix Release Bridge Generator. Do not edit.
        // No \(purpose) were required for \(sourceFileLogicalID).

        """
    }

    private indirect enum SwiftTypeShape {
        struct FunctionAttributes {
            var isEscaping: Bool
            var isSendable: Bool
            var globalActor: String?
        }

        case named(String)
        case array(SwiftTypeShape)
        case dictionary(key: SwiftTypeShape, value: SwiftTypeShape)
        case set(SwiftTypeShape)
        case optional(SwiftTypeShape)
        case tuple([SwiftTypeShape])
        case function(
            attributes: FunctionAttributes,
            parameters: [SwiftTypeShape],
            result: SwiftTypeShape
        )

        var rendered: String {
            switch self {
            case let .named(name): return name == "Swift.Any" ? "Any" : name
            case let .array(element): return "Swift.Array<\(element.rendered)>"
            case let .dictionary(key, value):
                return "Swift.Dictionary<\(key.rendered), \(value.rendered)>"
            case let .set(element): return "Swift.Set<\(element.rendered)>"
            case let .optional(wrapped): return "Swift.Optional<\(wrapped.rendered)>"
            case let .tuple(elements):
                return "(\(elements.map(\.rendered).joined(separator: ", ")))"
            case let .function(attributes, parameters, result):
                var annotations: [String] = []
                if attributes.isEscaping { annotations.append("@escaping") }
                if let actor = attributes.globalActor {
                    annotations.append("@\(actor)")
                }
                if attributes.isSendable { annotations.append("@Sendable") }
                let prefix = annotations.isEmpty
                    ? "" : annotations.joined(separator: " ") + " "
                return prefix + "(\(parameters.map(\.rendered).joined(separator: ", ")))"
                    + " -> \(result.rendered)"
            }
        }

        /// Renders an outer SDK callback while strengthening each direct
        /// callable argument to `@escaping`. Swift's type checker then proves
        /// that the imported API really supplies that lifetime; attempting to
        /// pass this wrapper to a nonescaping nested parameter is rejected.
        var nativeCallbackRendered: String {
            switch self {
            case let .function(attributes, parameters, result):
                return SwiftTypeShape.function(
                    attributes: attributes,
                    parameters: parameters.map(\.requiringStoredCallable),
                    result: result
                ).rendered
            case let .optional(.function(attributes, parameters, result)):
                return SwiftTypeShape.optional(
                    .function(
                        attributes: attributes,
                        parameters: parameters.map(\.requiringStoredCallable),
                        result: result
                    )
                ).rendered
            default:
                return rendered
            }
        }

        private var requiringStoredCallable: SwiftTypeShape {
            guard case let .function(attributes, parameters, result) = self
            else {
                // Optional function values are already escaping storage and do
                // not permit an `@escaping` annotation inside Optional.
                return self
            }
            var storedAttributes = attributes
            storedAttributes.isEscaping = true
            return .function(
                attributes: storedAttributes,
                parameters: parameters,
                result: result
            )
        }
    }

    package func validateRoot(
        _ root: BridgeGeneration.Root,
        record: InterfaceArchive.FunctionRecord,
        archive: InterfaceArchive.Archive,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws {
        let hasExactLogicalParameters =
            root.parameterSwiftTypes.count == record.loweredSignature.parameters.count
        let hasBridgedReceiver: Bool = {
            guard [.method, .getter, .setter, .willSet, .didSet].contains(record.role),
                  root.parameterSwiftTypes.count
                    == record.loweredSignature.parameters.count + 1,
                  let receiver = record.parameterTypes.last
            else { return false }
            switch receiver {
            case .native:
                return true
            case let .local(key):
                return frozenValueTypes[key] != nil
            default:
                return false
            }
        }()
        let strings = [
            root.resultSwiftType, root.originalInvocation,
            root.privateImportSourceFile,
        ] + root.parameterExpressions + root.parameterSwiftTypes
            + (root.bridgeInvocation.map { [$0] } ?? [])
        let isObserver = root.sourceDeclaration.kind == .propertyObservers
            && [.willSet, .didSet].contains(root.memberRole)
        let expectedInstallation: BridgeGeneration.Installation =
            isObserver || record.effects.isAsync ? .sourceBody : .dynamicReplacement
        guard !root.privateImportSourceFile.isEmpty,
              root.sourceDeclaration.isWellFormed,
              root.sourceDeclaration.member(root.memberRole) != nil,
              root.installation == expectedInstallation,
              !root.resultSwiftType.isEmpty,
              !root.originalInvocation.isEmpty,
              (root.bridgeInvocation == nil) == isObserver,
              root.parameterExpressions.count == record.parameterTypes.count,
              root.parameterSwiftTypes.count == record.parameterTypes.count,
              hasExactLogicalParameters || hasBridgedReceiver,
              root.parameterExpressions.allSatisfy({ !$0.isEmpty }),
              strings.allSatisfy({
                  $0.utf8.count <= 64 * 1_024
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              })
        else {
            throw BridgeGeneration.Error.invalidRoot(root.functionKey)
        }
        guard record.effects.mayThrow == record.loweredSignature.isThrowing,
              record.effects.isAsync == record.loweredSignature.isAsync,
              !record.effects.isAsync || (
                  !isObserver
                      && !record.parameterConventions.contains(.inout)
              )
        else {
            throw BridgeGeneration.Error.invalidRoot(root.functionKey)
        }
        guard record.loweredSignature.isolation == nil
                || (record.effects.requiresMainActor
                    && record.loweredSignature.isolation.map {
                        ["MainActor", "Swift.MainActor"].contains($0)
                    } == true)
        else {
            throw BridgeGeneration.Error.unsupportedIsolatedRoot(root.functionKey)
        }
        for (spelling, type) in zip(root.parameterSwiftTypes, record.parameterTypes) {
            try validate(
                parseSwiftType(spelling),
                matches: type,
                archive: archive,
                frozenValueTypes: frozenValueTypes,
                key: root.functionKey
            )
        }
        try validate(
            parseSwiftType(root.resultSwiftType),
            matches: record.resultType,
            archive: archive,
            frozenValueTypes: frozenValueTypes,
            key: root.functionKey
        )
    }

    private func validateFrozenValueCodecs(
        archive: InterfaceArchive.Archive,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws {
        for record in archive.frozenValueTypes {
            guard swiftTypeMatches(
                try parseSwiftType(record.swiftType(
                    moduleName: archive.metadata.frontendInvocation.moduleName
                )),
                type: .local(record.key),
                archive: archive,
                frozenValueTypes: frozenValueTypes
            ) else {
                throw BridgeGeneration.Error.frozenValueTypeMismatch(record.key)
            }
            let members: [(String, Bytecode.ValueType)] = switch record.kind {
            case let .structure(fields):
                fields.map { ($0.swiftType, $0.type) }
            case let .enumeration(cases):
                cases.flatMap { item in
                    item.associatedValues.map { ($0.swiftType, $0.type) }
                }
            }
            for (swiftType, valueType) in members {
                guard swiftTypeMatches(
                    try parseSwiftType(swiftType),
                    type: valueType,
                    archive: archive,
                    frozenValueTypes: frozenValueTypes
                ) else {
                    throw BridgeGeneration.Error.frozenValueTypeMismatch(record.key)
                }
            }
        }
    }

    private func parseSwiftType(_ raw: String) throws -> SwiftTypeShape {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BridgeGeneration.Error.invalidSwiftType(raw) }
        try validateBalancedDelimiters(value)
        if let function = try parseSwiftFunctionType(value) {
            return function
        }
        if value.hasPrefix("@") {
            throw BridgeGeneration.Error.invalidSwiftType(raw)
        }
        if value.hasSuffix("?") {
            return .optional(try parseSwiftType(String(value.dropLast())))
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            let inner = String(value.dropFirst().dropLast())
            if let components = try dictionaryComponents(inner) {
                return .dictionary(
                    key: try parseSwiftType(components.key),
                    value: try parseSwiftType(components.value)
                )
            }
            return .array(try parseSwiftType(inner))
        }
        for prefix in ["Swift.Array<", "Array<"] where value.hasPrefix(prefix) {
            guard value.hasSuffix(">") else {
                throw BridgeGeneration.Error.invalidSwiftType(raw)
            }
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            return .array(
                try parseSwiftType(String(value[start..<value.index(before: value.endIndex)]))
            )
        }
        for prefix in ["Swift.Dictionary<", "Dictionary<"] where value.hasPrefix(prefix) {
            guard value.hasSuffix(">") else {
                throw BridgeGeneration.Error.invalidSwiftType(raw)
            }
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            let components = try splitTopLevel(
                String(value[start..<value.index(before: value.endIndex)])
            )
            guard components.count == 2 else {
                throw BridgeGeneration.Error.invalidSwiftType(raw)
            }
            return .dictionary(
                key: try parseSwiftType(components[0]),
                value: try parseSwiftType(components[1])
            )
        }
        for prefix in ["Swift.Set<", "Set<"] where value.hasPrefix(prefix) {
            guard value.hasSuffix(">") else {
                throw BridgeGeneration.Error.invalidSwiftType(raw)
            }
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            return .set(
                try parseSwiftType(String(value[start..<value.index(before: value.endIndex)]))
            )
        }
        for prefix in ["Swift.Optional<", "Optional<"] where value.hasPrefix(prefix) {
            guard value.hasSuffix(">") else {
                throw BridgeGeneration.Error.invalidSwiftType(raw)
            }
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            return .optional(try parseSwiftType(String(value[start..<value.index(before: value.endIndex)])))
        }
        if value.hasPrefix("("), value.hasSuffix(")"), value != "()" {
            let inner = String(value.dropFirst().dropLast())
            let elements = try splitTopLevel(inner).map {
                try parseSwiftType(removingSwiftTupleLabel($0))
            }
            guard elements.count >= 2 else {
                throw BridgeGeneration.Error.invalidSwiftType(raw)
            }
            return .tuple(elements)
        }
        return .named(value)
    }

    private func parseSwiftFunctionType(
        _ raw: String
    ) throws -> SwiftTypeShape? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var isSendable = false
        var globalActor: String?
        var hasEscaping = false
        var hasExplicitConvention = false
        while value.hasPrefix("@") {
            guard let annotation = consumeSwiftTypeAnnotation(from: &value) else {
                throw BridgeGeneration.Error.invalidSwiftType(raw)
            }
            switch annotation {
            case "escaping":
                guard !hasEscaping else {
                    throw BridgeGeneration.Error.invalidSwiftType(raw)
                }
                hasEscaping = true
            case "convention(block)", "convention(swift)":
                guard !hasExplicitConvention else {
                    throw BridgeGeneration.Error.invalidSwiftType(raw)
                }
                hasExplicitConvention = true
            case "Sendable":
                guard !isSendable else {
                    throw BridgeGeneration.Error.invalidSwiftType(raw)
                }
                isSendable = true
            default:
                guard isGlobalActorTypeAnnotation(annotation),
                      globalActor == nil
                else { throw BridgeGeneration.Error.invalidSwiftType(raw) }
                globalActor = annotation
            }
        }
        guard let arrow = topLevelSwiftFunctionArrow(in: value) else {
            if let unwrapped = removingSwiftTypeParentheses(value) {
                var annotations: [String] = []
                if hasEscaping { annotations.append("@escaping") }
                if let globalActor { annotations.append("@\(globalActor)") }
                if isSendable { annotations.append("@Sendable") }
                let prefix = annotations.isEmpty
                    ? "" : annotations.joined(separator: " ") + " "
                return try parseSwiftFunctionType(prefix + unwrapped)
            }
            return nil
        }
        let left = value[..<arrow.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = value[arrow.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard left.first == "(", !result.isEmpty,
              let close = matchingSwiftTypeParenthesis(
                  for: left.startIndex,
                  in: left
              )
        else { throw BridgeGeneration.Error.invalidSwiftType(raw) }
        let effects = left[left.index(after: close)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard effects.isEmpty else {
            // Async and throwing callback ABIs require a different Runtime
            // error/suspension contract and are intentionally not erased.
            throw BridgeGeneration.Error.invalidSwiftType(raw)
        }
        let body = String(left[left.index(after: left.startIndex)..<close])
        let parameterSpellings = body.isEmpty ? [] : try splitTopLevel(body)
        let parameters = try parameterSpellings.map { parameter in
            try parseSwiftType(removingSwiftTupleLabel(parameter))
        }
        return .function(
            attributes: .init(
                isEscaping: hasEscaping,
                isSendable: isSendable,
                globalActor: globalActor
            ),
            parameters: parameters,
            result: try parseSwiftType(result)
        )
    }

    private func consumeSwiftTypeAnnotation(
        from value: inout String
    ) -> String? {
        guard value.first == "@" else { return nil }
        var index = value.index(after: value.startIndex)
        let start = index
        while index < value.endIndex,
              value[index] == "." || value[index] == "_"
                || value[index].isLetter || value[index].isNumber {
            index = value.index(after: index)
        }
        guard index > start else { return nil }
        var annotation = String(value[start..<index])
        if index < value.endIndex, value[index] == "(" {
            guard let close = matchingSwiftTypeParenthesis(
                for: index,
                in: value
            ) else { return nil }
            annotation += value[index...close]
            index = value.index(after: close)
        }
        guard index == value.endIndex || value[index].isWhitespace else {
            return nil
        }
        value.removeSubrange(value.startIndex..<index)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return annotation
    }

    private func isGlobalActorTypeAnnotation(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.last?.hasSuffix("Actor") == true else { return false }
        return components.allSatisfy { component in
            guard let first = component.first,
                  first == "_" || first.isLetter
            else { return false }
            return component.dropFirst().allSatisfy {
                $0 == "_" || $0.isLetter || $0.isNumber
            }
        }
    }

    private func removingSwiftTypeParentheses(_ value: String) -> String? {
        guard value.first == "(",
              let close = matchingSwiftTypeParenthesis(
                  for: value.startIndex,
                  in: value
              ), close == value.index(before: value.endIndex)
        else { return nil }
        return String(value[value.index(after: value.startIndex)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchingSwiftTypeParenthesis<S: StringProtocol>(
        for open: S.Index,
        in value: S
    ) -> S.Index? {
        var depth = 0
        var index = open
        while index < value.endIndex {
            switch value[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            guard depth >= 0 else { return nil }
            index = value.index(after: index)
        }
        return nil
    }

    private func topLevelSwiftFunctionArrow(
        in value: String
    ) -> Range<String.Index>? {
        var angleDepth = 0
        var parenthesisDepth = 0
        var bracketDepth = 0
        var index = value.startIndex
        while index < value.endIndex {
            switch value[index] {
            case "<": angleDepth += 1
            case ">":
                let previous = index > value.startIndex
                    ? value[value.index(before: index)] : nil
                if previous != "-" { angleDepth -= 1 }
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            case "-" where angleDepth == 0 && parenthesisDepth == 0
                    && bracketDepth == 0:
                let next = value.index(after: index)
                if next < value.endIndex, value[next] == ">" {
                    return index..<value.index(after: next)
                }
            default: break
            }
            guard angleDepth >= 0, parenthesisDepth >= 0,
                  bracketDepth >= 0
            else { return nil }
            index = value.index(after: index)
        }
        return nil
    }

    private func removingSwiftTupleLabel(_ raw: String) -> String {
        var angleDepth = 0
        var parenthesisDepth = 0
        var bracketDepth = 0
        for index in raw.indices {
            switch raw[index] {
            case "<": angleDepth += 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)] : nil
                if previous != "-" { angleDepth -= 1 }
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            case ":" where angleDepth == 0 && parenthesisDepth == 0
                    && bracketDepth == 0:
                return String(raw[raw.index(after: index)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            default: break
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateBalancedDelimiters(_ value: String) throws {
        var angleDepth = 0
        var parenthesisDepth = 0
        var previous: Character?
        for character in value {
            switch character {
            case "<": angleDepth += 1
            case ">" where previous != "-": angleDepth -= 1
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            default: break
            }
            guard angleDepth >= 0, parenthesisDepth >= 0 else {
                throw BridgeGeneration.Error.invalidSwiftType(value)
            }
            previous = character
        }
        guard angleDepth == 0, parenthesisDepth == 0 else {
            throw BridgeGeneration.Error.invalidSwiftType(value)
        }
    }

    private func splitTopLevel(_ value: String) throws -> [String] {
        var result: [String] = []
        var start = value.startIndex
        var angleDepth = 0
        var parenthesisDepth = 0
        for index in value.indices {
            switch value[index] {
            case "<": angleDepth += 1
            case ">":
                let previous = index > value.startIndex
                    ? value[value.index(before: index)] : nil
                if previous != "-" { angleDepth -= 1 }
                guard angleDepth >= 0 else {
                    throw BridgeGeneration.Error.invalidSwiftType(value)
                }
            case "(": parenthesisDepth += 1
            case ")":
                parenthesisDepth -= 1
                guard parenthesisDepth >= 0 else {
                    throw BridgeGeneration.Error.invalidSwiftType(value)
                }
            case "," where angleDepth == 0 && parenthesisDepth == 0:
                result.append(String(value[start..<index]))
                start = value.index(after: index)
            default: break
            }
        }
        guard angleDepth == 0, parenthesisDepth == 0 else {
            throw BridgeGeneration.Error.invalidSwiftType(value)
        }
        result.append(String(value[start...]))
        return result
    }

    private func dictionaryComponents(_ value: String) throws -> (key: String, value: String)? {
        var angleDepth = 0
        var parenthesisDepth = 0
        var squareDepth = 0
        for index in value.indices {
            switch value[index] {
            case "<": angleDepth += 1
            case ">":
                let previous = index > value.startIndex
                    ? value[value.index(before: index)] : nil
                if previous != "-" { angleDepth -= 1 }
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "[": squareDepth += 1
            case "]": squareDepth -= 1
            case ":" where angleDepth == 0 && parenthesisDepth == 0 && squareDepth == 0:
                let key = String(value[..<index]).trimmingCharacters(in: .whitespaces)
                let next = value.index(after: index)
                let element = String(value[next...]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !element.isEmpty else {
                    throw BridgeGeneration.Error.invalidSwiftType(value)
                }
                return (key, element)
            default: break
            }
            guard angleDepth >= 0, parenthesisDepth >= 0, squareDepth >= 0 else {
                throw BridgeGeneration.Error.invalidSwiftType(value)
            }
        }
        guard angleDepth == 0, parenthesisDepth == 0, squareDepth == 0 else {
            throw BridgeGeneration.Error.invalidSwiftType(value)
        }
        return nil
    }

    private func validate(
        _ shape: SwiftTypeShape,
        matches type: Bytecode.ValueType,
        archive: InterfaceArchive.Archive,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]? = nil,
        key: Core.FunctionKey
    ) throws {
        guard swiftTypeMatches(
            shape,
            type: type,
            archive: archive,
            frozenValueTypes: frozenValueTypes
        ) else {
            throw BridgeGeneration.Error.swiftTypeMismatch(key)
        }
    }

    private func swiftTypeMatches(
        _ shape: SwiftTypeShape,
        type: Bytecode.ValueType,
        archive: InterfaceArchive.Archive,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]? = nil
    ) -> Bool {
        switch (shape, type) {
        case let (.named(name), .integer(width, signed)):
            let stem = signed ? "Int" : "UInt"
            let names = width == 64
                ? [stem, "Swift.\(stem)", "\(stem)64", "Swift.\(stem)64"]
                : ["\(stem)\(width)", "Swift.\(stem)\(width)"]
            return names.contains(name)
        case let (.named(name), .float(width)):
            let names = width == 32
                ? ["Float", "Swift.Float"]
                : ["Double", "Swift.Double", "CGFloat", "CoreFoundation.CGFloat",
                   "CoreGraphics.CGFloat"]
            return names.contains(name)
        case let (.named(name), .native(typeID)):
            guard let canonicalName = archive.nativeTypes.first(where: {
                $0.id == typeID
            })?.canonicalName else { return false }
            let modulePrefix = archive.metadata.frontendInvocation.moduleName + "."
            let moduleRelativeName = canonicalName.hasPrefix(modulePrefix)
                ? String(canonicalName.dropFirst(modulePrefix.count))
                : canonicalName
            return name == canonicalName || name == moduleRelativeName
        case let (.named(name), .local(key)):
            let record = frozenValueTypes?[key]
                ?? archive.frozenValueTypes.first(where: { $0.key == key })
            guard let record else { return false }
            let modulePrefix = archive.metadata.frontendInvocation.moduleName + "."
            let moduleRelativeName = record.canonicalName.hasPrefix(modulePrefix)
                ? String(record.canonicalName.dropFirst(modulePrefix.count))
                : record.canonicalName
            return name == record.canonicalName || name == moduleRelativeName
        case let (.optional(shape), .optional(type)):
            return swiftTypeMatches(
                shape,
                type: type,
                archive: archive,
                frozenValueTypes: frozenValueTypes
            )
        case let (.array(shape), .array(type)):
            return swiftTypeMatches(
                shape,
                type: type,
                archive: archive,
                frozenValueTypes: frozenValueTypes
            )
        case let (.dictionary(keyShape, valueShape), .dictionary(keyType, valueType)):
            return swiftTypeMatches(
                keyShape,
                type: keyType,
                archive: archive,
                frozenValueTypes: frozenValueTypes
            ) && swiftTypeMatches(
                valueShape,
                type: valueType,
                archive: archive,
                frozenValueTypes: frozenValueTypes
            )
        case let (.set(shape), .set(type)):
            return swiftTypeMatches(
                shape,
                type: type,
                archive: archive,
                frozenValueTypes: frozenValueTypes
            )
        case let (.tuple(shapes), .tuple(types)):
            return shapes.count == types.count && zip(shapes, types).allSatisfy {
                swiftTypeMatches(
                    $0.0,
                    type: $0.1,
                    archive: archive,
                    frozenValueTypes: frozenValueTypes
                )
            }
        case let (
            .function(attributes, parameterShapes, resultShape),
            .closure(signature)
        ):
            let requiresMainActor: Bool
            switch attributes.globalActor {
            case nil:
                requiresMainActor = false
            case "MainActor", "Swift.MainActor":
                requiresMainActor = true
            default:
                return false
            }
            return signature.effects.requiresMainActor == requiresMainActor
                && parameterShapes.count == signature.parameters.count
                && signature.hasCanonicalCallableEffects
                && signature.hasCanonicalThrownType
                && !signature.effects.mayThrow
                && !signature.effects.isAsync
                && zip(parameterShapes, signature.parameters).allSatisfy {
                    swiftTypeMatches(
                        $0.0,
                        type: $0.1,
                        archive: archive,
                        frozenValueTypes: frozenValueTypes
                    )
                }
                && swiftTypeMatches(
                    resultShape,
                    type: signature.result,
                    archive: archive,
                    frozenValueTypes: frozenValueTypes
                )
        case let (.named(name), .bool):
            return ["Bool", "Swift.Bool"].contains(name)
        case let (.named(name), .string):
            return [
                "String", "Swift.String", "Character", "Swift.Character",
            ].contains(name)
        case let (.named(name), .array(element)):
            return element == .string
                && ["Substring", "Swift.Substring"].contains(name)
        case let (.named(name), .any):
            return ["Any", "Swift.Any"].contains(name)
        case let (.named(name), .error):
            return [
                "Error", "Swift.Error", "any Error", "any Swift.Error",
            ].contains(name)
        case let (.named(name), .void):
            return ["Void", "Swift.Void", "()"].contains(name)
        default:
            return false
        }
    }

    private struct BoundaryRendering {
        var shapes: [SwiftTypeShape]
        var writebackIndex: Int?
        var writebackName: String?
        var encoderName: String
        var arguments: [String]
        var argumentArray: String
        var resultShape: SwiftTypeShape
        var decodeResult: String
    }

    private func renderBoundary(
        _ root: BridgeGeneration.Root,
        record: InterfaceArchive.FunctionRecord,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws -> BoundaryRendering {
        let shapes = try root.parameterSwiftTypes.map(parseSwiftType)
        let writebackIndex = record.parameterConventions.firstIndex(of: .inout)
        let writebackName = writebackIndex.map {
            generatedLocalIdentifier("Writeback\($0)", root: root)
        }
        let encoderName = generatedLocalIdentifier("Encoder", root: root)
        let boundaryExpressions = root.parameterExpressions.indices.map { index in
            index == writebackIndex
                ? writebackName! : root.parameterExpressions[index]
        }
        let arguments = zip(
            zip(boundaryExpressions, shapes),
            record.parameterTypes
        ).map {
            renderEncode(
                expression: $0.0.0,
                shape: $0.0.1,
                type: $0.1,
                nativeCatalog: "try Runtime.Bridge.shared.requireNativeTypeCatalog()",
                inputEncoder: encoderName,
                frozenValueTypes: frozenValueTypes
            )
        }
        let resultShape = try parseSwiftType(root.resultSwiftType)
        return .init(
            shapes: shapes,
            writebackIndex: writebackIndex,
            writebackName: writebackName,
            encoderName: encoderName,
            arguments: arguments,
            argumentArray: renderArray(arguments, indentation: 20),
            resultShape: resultShape,
            decodeResult: renderDecodeResult(
                shape: resultShape,
                type: record.resultType,
                frozenValueTypes: frozenValueTypes
            )
        )
    }

    package func renderReplacementBody(
        _ root: BridgeGeneration.Root,
        record: InterfaceArchive.FunctionRecord,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws -> String {
        guard !record.effects.isAsync else {
            throw BridgeGeneration.Error.invalidRoot(root.functionKey)
        }
        let boundary = try renderBoundary(
            root,
            record: record,
            frozenValueTypes: frozenValueTypes
        )
        let originalAttempt = record.effects.mayThrow ? "try " : ""
        let writebackDeclaration = boundary.writebackIndex.map { index in
            "let \(boundary.writebackName!): \(boundary.shapes[index].rendered) = "
                + root.parameterExpressions[index]
        }
        let applyWritebacks = boundary.writebackIndex.map { index -> String in
            let writebacksName = generatedLocalIdentifier(
                "Writebacks",
                root: root
            )
            let decodedName = generatedLocalIdentifier(
                "DecodedWriteback\(index)",
                root: root
            )
            let decoded = renderDecode(
                expression: "\(writebacksName)[0].value",
                shape: boundary.shapes[index],
                type: record.parameterTypes[index],
                frozenValueTypes: frozenValueTypes
            )
            return """
            ,
            applyWritebacks: { \(writebacksName) in
                guard \(writebacksName).count == 1,
                      \(writebacksName)[0].parameterIndex == \(index)
                else {
                    throw VM.RuntimeTrap.nativeFailure("generated Bridge received an invalid writeback set")
                }
                let \(decodedName): \(boundary.shapes[index].rendered) = \(decoded)
                \(root.parameterExpressions[index]) = \(decodedName)
            }
            """
        } ?? ""
        let originalFallback = record.resultType == .void
            ? "\(originalAttempt)\(root.originalInvocation)\n    return ()"
            : "return \(originalAttempt)\(root.originalInvocation)"
        let decisionName = generatedLocalIdentifier("Decision", root: root)
        let resultName = generatedLocalIdentifier("Result", root: root)
        let dispatch = (writebackDeclaration.map { $0 + "\n" } ?? "") + """
        let \(decisionName) = try Runtime.Bridge.shared.dispatch(
            entry: .init(rawValue: \(root.entryIndex.rawValue)),
            arguments: { \(boundary.encoderName) in
                try \(boundary.encoderName).encodeArguments(count: \(boundary.arguments.count)) { \(boundary.argumentArray) }
            },
            decodeResult: \(boundary.decodeResult)\(applyWritebacks)
        )
        switch \(decisionName) {
        case .originalRequired:
            \(originalFallback)
        case let .returned(\(resultName)):
            return \(resultName)
        }
        """
        let body: String
        if record.effects.mayThrow {
            body = dispatch
        } else {
            body = "do {\n" + indent(dispatch, spaces: 4)
                + "\n} catch {\n    Runtime.Bridge.terminate(error)\n}"
        }
        return body
    }

    package func renderAsyncSourceBodyTemplate(
        _ root: BridgeGeneration.Root,
        record: InterfaceArchive.FunctionRecord,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws -> BridgeGeneration.SourceBodyTransform.Body {
        guard record.effects.isAsync,
              !record.parameterConventions.contains(.inout)
        else {
            throw BridgeGeneration.Error.invalidRoot(root.functionKey)
        }
        let boundary = try renderBoundary(
            root,
            record: record,
            frozenValueTypes: frozenValueTypes
        )
        let originalAttempt = record.effects.mayThrow ? "try await " : "await "
        let closureEffects = record.effects.mayThrow ? "async throws" : "async"
        let preparedName = generatedLocalIdentifier("PreparedDispatch", root: root)
        var prefix = """
        let \(preparedName) = try Runtime.Bridge.shared.prepareAsyncDispatch(
            entry: .init(rawValue: \(root.entryIndex.rawValue)),
            arguments: { \(boundary.encoderName) in
                try \(boundary.encoderName).encodeArguments(count: \(boundary.arguments.count)) { \(boundary.argumentArray) }
            }
        )
        guard let \(preparedName) else {
            return \(originalAttempt){ () \(closureEffects) -> \(boundary.resultShape.rendered) in
        """
        var suffix = """
            }()
        }
        return try await Runtime.Bridge.shared.dispatchAsync(
            prepared: \(preparedName),
            decodeResult: \(boundary.decodeResult)
        )
        """
        if !record.effects.mayThrow {
            prefix = "do {\n" + indent(prefix, spaces: 4)
            suffix = indent(suffix, spaces: 4)
                + "\n} catch {\n    Runtime.Bridge.terminate(error)\n}"
        }
        return .preservingOriginal(
            prefix: "{\n" + indent(prefix, spaces: 4) + "\n",
            suffix: "\n" + indent(suffix, spaces: 4) + "\n}"
        )
    }

    private func generatedLocalIdentifier(
        _ role: String,
        root: BridgeGeneration.Root
    ) -> String {
        let occupied = Set(root.parameterExpressions.map { expression in
            expression.trimmingCharacters(in: CharacterSet(
                charactersIn: "&` \t\r\n"
            ))
        })
        let base = "helix\(role)_"
            + String(root.functionKey.description.prefix(16))
        var candidate = base
        var discriminator = 0
        while occupied.contains(candidate) {
            discriminator += 1
            candidate = "\(base)_\(discriminator)"
        }
        return candidate
    }

    private func renderReplacementDeclaration(
        _ roots: [BridgeGeneration.Root],
        records: [Core.FunctionKey: InterfaceArchive.FunctionRecord],
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws -> String {
        guard let first = roots.first else {
            throw BridgeGeneration.Error.incompleteRootSet
        }
        let declaration = first.sourceDeclaration
        let rootsByRole = Dictionary(uniqueKeysWithValues: roots.map {
            ($0.memberRole, $0)
        })
        let renderedDeclaration: String
        if declaration.kind == .function {
            guard roots.count == 1,
                  let root = rootsByRole[.functionBody],
                  let record = records[root.functionKey]
            else {
                throw BridgeGeneration.Error.invalidRoot(first.functionKey)
            }
            let body = try renderReplacementBody(
                root,
                record: record,
                frozenValueTypes: frozenValueTypes
            )
            renderedDeclaration = """
            @_dynamicReplacement(for: \(declaration.originalReference))
            \(declaration.replacementHeader) {
            \(indent(body, spaces: 4))
            }
            """
        } else {
            let accessors = try declaration.members.compactMap {
                member -> String? in
                if let root = rootsByRole[member.role] {
                    guard let record = records[root.functionKey] else {
                        throw BridgeGeneration.Error.invalidRoot(root.functionKey)
                    }
                    let body = try renderReplacementBody(
                        root,
                        record: record,
                        frozenValueTypes: frozenValueTypes
                    )
                    return "\(member.header) {\n"
                        + indent(body, spaces: 4) + "\n}"
                }
                // Swift requires a setter replacement declaration to carry a
                // getter, so unchanged companions chain to the previous
                // implementation explicitly.
                return "\(member.header) {\n"
                    + indent(member.fallbackBody, spaces: 4) + "\n}"
            }
            guard !accessors.isEmpty,
                  Set(roots.map(\.memberRole)).isSubset(
                    of: Set(declaration.members.map(\.role))
                  )
            else {
                throw BridgeGeneration.Error.invalidRoot(first.functionKey)
            }
            renderedDeclaration = """
            @_dynamicReplacement(for: \(declaration.originalReference))
            \(declaration.replacementHeader) {
            \(indent(accessors.joined(separator: "\n"), spaces: 4))
            }
            """
        }
        guard !declaration.enclosingPrefix.isEmpty else {
            return renderedDeclaration
        }
        return declaration.enclosingPrefix + "\n"
            + indent(renderedDeclaration, spaces: 4) + "\n"
            + declaration.enclosingSuffix
    }

    private func renderOriginalEntry(
        _ root: BridgeGeneration.Root,
        record: InterfaceArchive.FunctionRecord,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws -> String {
        guard let bridgeInvocation = root.bridgeInvocation else {
            return """
            Runtime.OriginalEntry(
                index: .init(rawValue: \(root.entryIndex.rawValue)),
                parameterTypes: \(renderValueTypes(record.parameterTypes)),
                parameterConventions: \(renderParameterConventions(record.parameterConventions)),
                resultType: \(render(record.resultType)),
                effects: \(render(record.effects)),
                fallbackAllowed: \(record.fallbackAllowed),
                invoke: { _ in
                    .trapped(.nativeFailure("a Swift property observer has no source-callable original entry"))
                }
            )
            """
        }
        let shapes = try root.parameterSwiftTypes.map(parseSwiftType)
        let decoded = zip(
            zip(shapes, record.parameterTypes),
            record.parameterConventions
        ).enumerated().map { offset, pair in
            let ((shape, type), convention) = pair
            return "\(convention == .inout ? "var" : "let") argument\(offset): "
                + "\(shape.rendered) = "
                + renderDecode(
                    expression: "arguments[\(offset)]",
                    shape: shape,
                    type: type,
                    frozenValueTypes: frozenValueTypes
                )
        }
        let writebacks = try renderOriginalWritebacks(
            record: record,
            shapes: shapes,
            frozenValueTypes: frozenValueTypes
        )
        let call = renderOriginalCall(
            root,
            bridgeInvocation: bridgeInvocation,
            record: record
        )
        let invocation: String
        if record.resultType == .void {
            let callBody = renderThrowingOriginalCall(
                call,
                resultDeclaration: nil,
                record: record,
                writebacks: writebacks
            )
            invocation = callBody
                + "\nreturn .init(outcome: .returned(try Runtime.BridgeValueCodec.encodeVoid()), "
                + "writebacks: \(writebacks))"
        } else {
            let resultShape = try parseSwiftType(root.resultSwiftType)
            let resultDeclaration = "let result: \(resultShape.rendered)"
            let callBody = renderThrowingOriginalCall(
                call,
                resultDeclaration: resultDeclaration,
                record: record,
                writebacks: writebacks
            )
            let encoded = renderEncode(
                expression: "result",
                shape: resultShape,
                type: record.resultType,
                nativeCatalog: "nativeTypeCatalog",
                frozenValueTypes: frozenValueTypes
            )
            invocation = callBody
                + "\nreturn .init(outcome: .returned(\(encoded)), "
                + "writebacks: \(writebacks))"
        }
        let actorGuard = record.effects.requiresMainActor && !record.effects.isAsync
            ? ["guard Thread.isMainThread else {",
               "    return .trapped(.nativeFailure(\"MainActor original entry ran off the main thread\"))",
               "}"]
            : []
        let body = (decoded + actorGuard + [invocation]).joined(separator: "\n")
        let invocationLabel: String
        if record.effects.isAsync {
            invocationLabel = record.effects.requiresMainActor
                ? "invokeMainActorAsync" : "invokeAsync"
        } else {
            invocationLabel = "invoke"
        }
        return """
        Runtime.OriginalEntry(
            index: .init(rawValue: \(root.entryIndex.rawValue)),
            parameterTypes: \(renderValueTypes(record.parameterTypes)),
            parameterConventions: \(renderParameterConventions(record.parameterConventions)),
            resultType: \(render(record.resultType)),
            effects: \(render(record.effects)),
            fallbackAllowed: \(record.fallbackAllowed),
            \(invocationLabel): { arguments in
                guard arguments.count == \(record.parameterTypes.count) else {
                    return .trapped(.nativeFailure("generated original entry argument count mismatch"))
                }
                do {
        \(indent(body, spaces: 20))
                } catch let trap as VM.RuntimeTrap {
                    return .trapped(trap)
                } catch {
                    return .trapped(.nativeFailure(String(describing: error)))
                }
            }
        )
        """
    }

    private func renderOriginalCall(
        _ root: BridgeGeneration.Root,
        bridgeInvocation: String,
        record: InterfaceArchive.FunctionRecord
    ) -> String {
        let callAttempt = (record.effects.mayThrow ? "try " : "")
            + (record.effects.isAsync ? "await " : "")
        if record.effects.isAsync {
            // Async source-body roots call a unique source-local thunk. Unlike
            // a wrapper re-entry, that call is statically resolved and must
            // not suppress legitimate recursive calls made by the original.
            return "\(callAttempt)\(bridgeInvocation)"
        }
        let bypassAttempt = record.effects.mayThrow ? "try " : ""
        let bypass = """
        \(bypassAttempt)Runtime.Bridge.shared.withOriginalBypass(
            entry: .init(rawValue: \(root.entryIndex.rawValue))
        ) {
            \(callAttempt)\(bridgeInvocation)
        }
        """
        guard record.effects.requiresMainActor else { return bypass }
        return """
        \(record.effects.mayThrow ? "try " : "")MainActor.assumeIsolated {
        \(indent(bypass, spaces: 4))
        }
        """
    }

    private func renderThrowingOriginalCall(
        _ call: String,
        resultDeclaration: String?,
        record: InterfaceArchive.FunctionRecord,
        writebacks: String
    ) -> String {
        let assignment = resultDeclaration.map { "\($0) = " } ?? ""
        guard record.effects.mayThrow else { return assignment + call }
        let declaration = resultDeclaration.map { "\($0)\n" } ?? ""
        return """
        \(declaration)do {
            \(resultDeclaration == nil ? "" : "result = ")\(call)
        } catch {
            return .init(
                outcome: .businessError(String(describing: error)),
                writebacks: \(writebacks)
            )
        }
        """
    }

    private func renderOriginalWritebacks(
        record: InterfaceArchive.FunctionRecord,
        shapes: [SwiftTypeShape],
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws -> String {
        guard let index = record.parameterConventions.firstIndex(of: .inout) else {
            return "[]"
        }
        guard record.parameterConventions.filter({ $0 == .inout }).count == 1,
              shapes.indices.contains(index),
              record.parameterTypes.indices.contains(index)
        else {
            throw BridgeGeneration.Error.invalidRoot(record.key)
        }
        let encoded = renderEncode(
            expression: "argument\(index)",
            shape: shapes[index],
            type: record.parameterTypes[index],
            nativeCatalog: "nativeTypeCatalog",
            frozenValueTypes: frozenValueTypes
        )
        return "[.init(parameterIndex: \(index), value: \(encoded))]"
    }

    package func renderFrozenValueCodec(
        _ record: InterfaceArchive.FrozenValueTypeRecord,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws -> String {
        let swiftType = record.key.rawValue.split(separator: ".").map {
            escapedSwiftIdentifier(String($0))
        }.joined(separator: ".")
        switch record.kind {
        case let .structure(fields):
            let shapes = try fields.map { try parseSwiftType($0.swiftType) }
            let inputFields = zip(fields, shapes).map { field, shape in
                renderEncode(
                    expression: "value.\(escapedSwiftIdentifier(field.name))",
                    shape: shape,
                    type: field.type,
                    nativeCatalog: "try Runtime.Bridge.shared.requireNativeTypeCatalog()",
                    inputEncoder: "encoder",
                    frozenValueTypes: frozenValueTypes
                )
            }
            let resultFields = zip(fields, shapes).map { field, shape in
                renderEncode(
                    expression: "value.\(escapedSwiftIdentifier(field.name))",
                    shape: shape,
                    type: field.type,
                    nativeCatalog: "try Runtime.Bridge.shared.requireNativeTypeCatalog()",
                    frozenValueTypes: frozenValueTypes
                )
            }
            let decodedFields = zip(fields, shapes).enumerated().map {
                offset, pair in
                "field\(offset): " + renderDecode(
                    expression: "fields[\(offset)]",
                    shape: pair.1,
                    type: pair.0.type,
                    frozenValueTypes: frozenValueTypes
                )
            }
            let decodedBinding = fields.isEmpty
                ? "_ = try Runtime.BridgeValueCodec.decodeStructure"
                : "let fields = try Runtime.BridgeValueCodec.decodeStructure"
            let constructionArguments = [
                "__helix_\(record.codecIdentifier): ()",
            ] + decodedFields
            return """
            static func encodeInput_\(record.codecIdentifier)(
                _ value: \(swiftType),
                using encoder: Runtime.BridgeValueCodec.Encoder
            ) throws -> VM.Value {
                try encoder.encodeStructure(
                    type: \(render(record.key)),
                    fieldTypes: \(renderValueTypes(fields.map(\.type)))
                ) {
                    \(renderArray(inputFields, indentation: 20))
                }
            }

            static func encodeResult_\(record.codecIdentifier)(
                _ value: \(swiftType)
            ) throws -> VM.Value {
                try Runtime.BridgeValueCodec.encodeStructure(
                    type: \(render(record.key)),
                    fieldTypes: \(renderValueTypes(fields.map(\.type))),
                    fields: \(renderArray(resultFields, indentation: 20))
                )
            }

            static func decode_\(record.codecIdentifier)(
                _ value: VM.Value
            ) throws -> \(swiftType) {
                \(decodedBinding)(
                    value,
                    type: \(render(record.key)),
                    fieldTypes: \(renderValueTypes(fields.map(\.type)))
                )
                return \(swiftType)(
                    \(constructionArguments.joined(separator: ",\n        "))
                )
            }
            """
        case let .enumeration(cases):
            let inputCases = try cases.enumerated().map { offset, item in
                try renderFrozenEnumEncodeCase(
                    item,
                    caseIndex: offset,
                    inputEncoder: "encoder",
                    record: record,
                    frozenValueTypes: frozenValueTypes
                )
            }
            let resultCases = try cases.enumerated().map { offset, item in
                try renderFrozenEnumEncodeCase(
                    item,
                    caseIndex: offset,
                    inputEncoder: nil,
                    record: record,
                    frozenValueTypes: frozenValueTypes
                )
            }
            let decodeCases = try cases.enumerated().map { offset, item in
                try renderFrozenEnumDecodeCase(
                    item,
                    caseIndex: offset,
                    frozenValueTypes: frozenValueTypes
                )
            }
            let payloadTypes = cases.map { render($0.payloadType) }
                .joined(separator: ", ")
            return """
            static func encodeInput_\(record.codecIdentifier)(
                _ value: \(swiftType),
                using encoder: Runtime.BridgeValueCodec.Encoder
            ) throws -> VM.Value {
                switch value {
            \(indent(inputCases.joined(separator: "\n"), spaces: 4))
                }
            }

            static func encodeResult_\(record.codecIdentifier)(
                _ value: \(swiftType)
            ) throws -> VM.Value {
                switch value {
            \(indent(resultCases.joined(separator: "\n"), spaces: 4))
                }
            }

            static func decode_\(record.codecIdentifier)(
                _ value: VM.Value
            ) throws -> \(swiftType) {
                let decoded = try Runtime.BridgeValueCodec.decodeEnumeration(
                    value,
                    type: \(render(record.key)),
                    payloadTypes: [\(payloadTypes)]
                )
                switch decoded.caseIndex {
            \(indent(decodeCases.joined(separator: "\n"), spaces: 4))
                default:
                    throw VM.RuntimeTrap.nativeFailure(
                        "verified frozen enum decoder received an impossible case"
                    )
                }
            }
            """
        }
    }

    private func renderFrozenEnumEncodeCase(
        _ item: InterfaceArchive.FrozenEnumCase,
        caseIndex: Int,
        inputEncoder: String?,
        record: InterfaceArchive.FrozenValueTypeRecord,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws -> String {
        let caseName = escapedSwiftIdentifier(item.name)
        let bindings = item.associatedValues.enumerated().map { offset, associated in
            let label = associated.label.map {
                escapedSwiftIdentifier($0) + ": "
            } ?? ""
            return label + "associated\(offset)"
        }
        let pattern = bindings.isEmpty
            ? ".\(caseName)"
            : "let .\(caseName)(\(bindings.joined(separator: ", ")))"
        let encodedValues = try item.associatedValues.enumerated().map {
            offset, associated in
            renderEncode(
                expression: "associated\(offset)",
                shape: try parseSwiftType(associated.swiftType),
                type: associated.type,
                nativeCatalog: "try Runtime.Bridge.shared.requireNativeTypeCatalog()",
                inputEncoder: inputEncoder,
                frozenValueTypes: frozenValueTypes
            )
        }
        let payload: String
        if encodedValues.isEmpty {
            payload = "nil"
        } else if encodedValues.count == 1,
                  item.associatedValues[0].label == nil {
            payload = encodedValues[0]
        } else if let inputEncoder {
            payload = "try \(inputEncoder).encodeTuple(count: \(encodedValues.count)) { "
                + "\(renderArray(encodedValues, indentation: 12)) }"
        } else {
            payload = "try Runtime.BridgeValueCodec.encodeTuple("
                + "\(renderArray(encodedValues, indentation: 12)))"
        }
        let invocation: String
        if let inputEncoder {
            invocation = "try \(inputEncoder).encodeEnumeration("
                + "type: \(render(record.key)), caseIndex: \(caseIndex), "
                + "payloadType: \(render(item.payloadType))) { \(payload) }"
        } else {
            invocation = "try Runtime.BridgeValueCodec.encodeEnumeration("
                + "type: \(render(record.key)), caseIndex: \(caseIndex), "
                + "payloadType: \(render(item.payloadType)), payload: \(payload))"
        }
        return "case \(pattern):\n    return \(invocation)"
    }

    private func renderFrozenEnumDecodeCase(
        _ item: InterfaceArchive.FrozenEnumCase,
        caseIndex: Int,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws -> String {
        let caseName = escapedSwiftIdentifier(item.name)
        guard !item.associatedValues.isEmpty else {
            return "case \(caseIndex):\n    return .\(caseName)"
        }
        let payloadValues: [String]
        let prelude: [String]
        if item.associatedValues.count == 1,
           item.associatedValues[0].label == nil {
            payloadValues = ["payload"]
            prelude = [
                "guard let payload = decoded.payload else {",
                "    throw VM.RuntimeTrap.nativeFailure(\"verified frozen enum payload is missing\")",
                "}",
            ]
        } else {
            payloadValues = item.associatedValues.indices.map {
                "payloadValues[\($0)]"
            }
            prelude = [
                "guard let payload = decoded.payload else {",
                "    throw VM.RuntimeTrap.nativeFailure(\"verified frozen enum payload is missing\")",
                "}",
                "let payloadValues = try Runtime.BridgeValueCodec.decodeTuple(",
                "    payload, count: \(item.associatedValues.count)",
                ")",
            ]
        }
        let arguments = try zip(item.associatedValues, payloadValues).map {
            associated, expression in
            let decoded = renderDecode(
                expression: expression,
                shape: try parseSwiftType(associated.swiftType),
                type: associated.type,
                frozenValueTypes: frozenValueTypes
            )
            let label = associated.label.map {
                escapedSwiftIdentifier($0) + ": "
            } ?? ""
            return label + decoded
        }
        return "case \(caseIndex):\n"
            + indent(prelude.joined(separator: "\n"), spaces: 4)
            + "\n    return .\(caseName)(\(arguments.joined(separator: ", ")))"
    }

    private func renderOriginalCatalogFactory(entryGroupNames: [String]) -> String {
        let expression = entryGroupNames.isEmpty
            ? "[]"
            : entryGroupNames.map {
                "\($0).makeOriginalEntries(nativeTypeCatalog: nativeTypeCatalog)"
            }.joined(separator: " + ")
        return """
            public static func makeOriginalCatalog(
                nativeTypeCatalog: VM.NativeTypeCatalog
            ) throws -> Runtime.OriginalCatalog {
                try Runtime.OriginalCatalog(\(expression))
            }
        """
    }

    private func renderGeneratedNativeTypeFactory(
        binding: BridgeGeneration.NativeTypeBinding,
        generated: BridgeGeneration.GeneratedNativeType,
        record: InterfaceArchive.TypeRecord
    ) throws -> String {
        guard record.isCopyable else {
            throw BridgeGeneration.Error.nativeTypeBindingMismatch(binding.id)
        }
        let swiftType = generated.swiftType.split(separator: ".").map {
            escapedSwiftIdentifier(String($0))
        }.joined(separator: ".")
        let factory = BridgeGeneration.GeneratedNativeType.factoryName(id: binding.id)
        let operations: String
        switch generated.representation {
        case .reference:
            guard record.kind == .reference else {
                throw BridgeGeneration.Error.nativeTypeBindingMismatch(binding.id)
            }
            operations = """
            VM.NativeTypeOperations.reference(
                id: id,
                canonicalName: canonicalName,
                layoutFingerprint: layoutFingerprint,
                requiresMainActor: requiresMainActor,
                estimatedSize: estimatedSize,
                estimatedByteCount: { (_: \(swiftType)) in estimatedSize }
            )
            """
        case .rawRepresentable:
            guard record.kind == .value || record.kind == .enumeration else {
                throw BridgeGeneration.Error.nativeTypeBindingMismatch(binding.id)
            }
            let kind = record.kind == .value ? "value" : "enumeration"
            operations = """
            VM.NativeTypeOperations(
                id: id,
                canonicalName: canonicalName,
                kind: .\(kind),
                layoutFingerprint: layoutFingerprint,
                requiresMainActor: requiresMainActor,
                estimatedSize: estimatedSize,
                clone: { (value: \(swiftType)) in value },
                estimatedByteCount: { (_: \(swiftType)) in estimatedSize },
                equals: { $0.rawValue == $1.rawValue },
                hash: { value, hasher in hasher.combine(value.rawValue) }
            )
            """
        case .opaqueValue:
            guard record.kind == .value else {
                throw BridgeGeneration.Error.nativeTypeBindingMismatch(binding.id)
            }
            operations = """
            VM.NativeTypeOperations.opaqueValue(
                id: id,
                canonicalName: canonicalName,
                layoutFingerprint: layoutFingerprint,
                requiresMainActor: requiresMainActor,
                estimatedSize: estimatedSize,
                clone: { (value: \(swiftType)) in value }
            )
            """
        }
        return """
        static func \(factory)(
            id: Core.TypeID,
            canonicalName: String,
            layoutFingerprint: Core.Digest,
            requiresMainActor: Bool,
            estimatedSize: UInt64
        ) -> VM.NativeTypeOperations {
        \(indent(operations, spaces: 4))
        }
        """
    }

    private func renderGeneratedNativeImportFile(
        sourceFileLogicalID: String,
        moduleName: String,
        bindings: [BridgeGeneration.NativeImportBinding],
        archive: InterfaceArchive.Archive
    ) throws -> String {
        let records = Dictionary(uniqueKeysWithValues: archive.nativeImports.compactMap { record in
            record.id.map { ($0, record) }
        })
        let groupName = BridgeGeneration.GeneratedNativeImport.groupName(
            sourceFileLogicalID: sourceFileLogicalID
        )
        let generatedImports = Array(
            Set(bindings.flatMap(\.importedModules))
        ).sorted().map { "import \($0)" }
        var lines = [
            "// Generated by Helix Release Bridge Generator. Do not edit.",
            "@_private(sourceFile: \(quoted(URL(fileURLWithPath: sourceFileLogicalID).lastPathComponent))) import \(moduleName)",
        ] + generatedImports + [
            "import Foundation",
        ] + BridgeGeneration.RuntimeImports.productionLines + [
            "",
            "enum \(groupName) {",
        ]
        let sorted = bindings.sorted { $0.id < $1.id }
        for (offset, binding) in sorted.enumerated() {
            guard let generated = binding.generated, let record = records[binding.id] else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
            if offset > 0 { lines.append("") }
            lines.append(
                indent(
                    try renderGeneratedNativeImportFactory(
                        binding: binding,
                        generated: generated,
                        record: record
                    ),
                    spaces: 4
                )
            )
        }
        lines.append("}")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func renderGeneratedNativeImportFactory(
        binding: BridgeGeneration.NativeImportBinding,
        generated: BridgeGeneration.GeneratedNativeImport,
        record: InterfaceArchive.NativeImportRecord
    ) throws -> String {
        let shapes = try generated.parameterSwiftTypes.map(parseSwiftType)
        let callbackByParameter = Dictionary(
            uniqueKeysWithValues: record.contract.callbacks.map {
                (Int($0.parameterIndex), $0)
            }
        )
        let decoded = try zip(shapes, record.parameterTypes).enumerated().map {
            offset, pair in
            let binding = generated.dispatch == .instanceValueSetter
                && offset == record.parameterTypes.count - 1 ? "var" : "let"
            if callbackByParameter[offset] != nil {
                return try renderGeneratedNativeCallbackParameter(
                    offset: offset,
                    shape: pair.0,
                    type: pair.1
                )
            }
            return "\(binding) argument\(offset): \(pair.0.rendered) = "
                + renderDecode(
                    expression: "arguments[\(offset)]",
                    shape: pair.0,
                    type: pair.1
                )
        }
        let resultShape = try parseSwiftType(generated.resultSwiftType)
        let directCall = renderGeneratedNativeImportCall(
            generated: generated,
            effects: record.effects
        )
        let invocation: String
        if record.resultType == .void {
            let call = renderMainActorCall(directCall, effects: record.effects)
            let callBody = renderGeneratedThrowingCall(
                call,
                resultDeclaration: nil,
                effects: record.effects
            )
            invocation = callBody
                + "\nreturn .returned(try Runtime.BridgeValueCodec.encodeVoid())"
        } else {
            let encodedValue = renderEncode(
                expression: "result",
                shape: resultShape,
                type: record.resultType,
                nativeCatalog: "try Runtime.Bridge.shared.requireNativeTypeCatalog()",
                inputEncoder: "nativeResultEncoder"
            )
            let encoded = """
            try Runtime.BridgeValueCodec.encodeNativeImportResult(
                expectedType: \(render(record.resultType)),
                context: context
            ) { nativeResultEncoder in
            \(indent(encodedValue, spaces: 4))
            }
            """
            if record.effects.requiresMainActor {
                // Keep potentially non-Sendable native values actor-isolated;
                // only their Sendable VM representation crosses the boundary.
                let actorAttempt = record.effects.isAsync
                    ? "try await " : "try "
                if record.effects.mayThrow {
                    invocation = """
                    return \(actorAttempt)context.withMainActor {
                        let result: \(resultShape.rendered)
                        do {
                            result = \(directCall)
                        } catch let trap as VM.RuntimeTrap {
                            throw trap
                        } catch {
                            return .businessError(String(describing: error))
                        }
                        return .returned(\(encoded))
                    }
                    """
                } else {
                    invocation = """
                    return \(actorAttempt)context.withMainActor {
                        let result: \(resultShape.rendered) = \(directCall)
                        return .returned(\(encoded))
                    }
                    """
                }
            } else {
                let callBody = renderGeneratedThrowingCall(
                    directCall,
                    resultDeclaration: "let result: \(resultShape.rendered)",
                    effects: record.effects
                )
                invocation = callBody + "\nreturn .returned(\(encoded))"
            }
        }
        let body = (decoded + [invocation]).joined(separator: "\n")
        let factoryName = BridgeGeneration.GeneratedNativeImport.factoryName(key: binding.key)
        let invokerProtocol = record.effects.isAsync
            ? "VM.AsyncNativeInvoker" : "VM.NativeInvoker"
        let invokerType = record.effects.isAsync
            ? "VM.ClosureAsyncNativeInvoker" : "VM.ClosureNativeInvoker"
        return """
        static func \(factoryName)(
            id: Core.NativeImportID,
            key: Core.NativeImportKey
        ) -> any \(invokerProtocol) {
            \(invokerType)(
                id: id,
                key: key,
                parameterTypes: \(renderValueTypes(record.parameterTypes)),
                resultType: \(render(record.resultType)),
                effects: \(render(record.effects)),
                contract: \(render(record.contract)),
                invoke: { arguments, context in
                    guard arguments.count == \(record.parameterTypes.count) else {
                        throw VM.RuntimeTrap.nativeFailure(
                            "generated NativeImport argument count mismatch"
                        )
                    }
        \(indent(body, spaces: 20))
                }
            )
        }
        """
    }

    private func renderGeneratedNativeCallbackParameter(
        offset: Int,
        shape: SwiftTypeShape,
        type: Bytecode.ValueType
    ) throws -> String {
        switch (shape, type) {
        case let (
            .function(_, parameterShapes, resultShape),
            .closure(signature)
        ):
            let callbackName = "nativeCallback\(offset)"
            let wrapper = try renderGeneratedNativeCallbackWrapper(
                callbackName: callbackName,
                parameterShapes: parameterShapes,
                resultShape: resultShape,
                signature: signature
            )
            return """
            let \(callbackName) = try context.makeCallback(
                parameterIndex: \(offset),
                from: arguments[\(offset)]
            )
            let argument\(offset): \(shape.nativeCallbackRendered) = \(wrapper)
            """
        case let (
            .optional(.function(_, parameterShapes, resultShape)),
            .optional(.closure(signature))
        ):
            let callbackName = "nativeCallback\(offset)"
            let wrapper = try renderGeneratedNativeCallbackWrapper(
                callbackName: callbackName,
                parameterShapes: parameterShapes,
                resultShape: resultShape,
                signature: signature
            )
            return """
            let argument\(offset): \(shape.nativeCallbackRendered) = try Runtime.BridgeValueCodec.decodeOptional(
                arguments[\(offset)]
            ) { callbackValue in
                let \(callbackName) = try context.makeCallback(
                    parameterIndex: \(offset),
                    from: callbackValue
                )
                return \(wrapper)
            }
            """
        default:
            throw BridgeGeneration.Error.invalidSwiftType(shape.rendered)
        }
    }

    private func renderGeneratedNativeCallbackWrapper(
        callbackName: String,
        parameterShapes: [SwiftTypeShape],
        resultShape: SwiftTypeShape,
        signature: Bytecode.ClosureSignature
    ) throws -> String {
        guard parameterShapes.count == signature.parameters.count,
              signature.result.isNativeBridgeCallbackResult
        else {
            throw BridgeGeneration.Error.invalidSwiftType(
                "native callback parameter shape"
            )
        }
        guard let unsafeParameter = zip(
            parameterShapes,
            signature.parameters
        ).first(where: {
            !isSafeNativeCallbackArgumentSpelling(
                shape: $0.0,
                type: $0.1
            )
        }) else {
            return try renderValidatedNativeCallbackWrapper(
                callbackName: callbackName,
                parameterShapes: parameterShapes,
                resultShape: resultShape,
                signature: signature
            )
        }
        throw BridgeGeneration.Error.invalidSwiftType(
            "unsafe native callback argument \(unsafeParameter.0.rendered) "
                + "for \(unsafeParameter.1)"
        )
    }

    private func renderValidatedNativeCallbackWrapper(
        callbackName: String,
        parameterShapes: [SwiftTypeShape],
        resultShape: SwiftTypeShape,
        signature: Bytecode.ClosureSignature
    ) throws -> String {
        let parameters = parameterShapes.indices.map { index in
            "callbackArgument\(index)"
        }.joined(separator: ", ")
        let encoded = zip(parameterShapes, signature.parameters).enumerated().map {
            index, pair in
            renderEncode(
                expression: "callbackArgument\(index)",
                shape: pair.0,
                type: pair.1,
                nativeCatalog: "try Runtime.Bridge.shared.requireNativeTypeCatalog()",
                inputEncoder: "callbackEncoder"
            )
        }
        let arguments = encoded.isEmpty
            ? "[]"
            : "[\n\(indent(encoded.joined(separator: ",\n"), spaces: 12))\n        ]"
        let opening = parameters.isEmpty ? "{" : "{ \(parameters) in"
        let encodedArguments = """
        try Runtime.Bridge.shared.encodeNativeCallbackArguments(
            for: \(callbackName),
            count: \(signature.parameters.count)
        ) { callbackEncoder in
            \(arguments)
        }
        """
        if signature.result == .void {
            return """
            \(opening)
                \(callbackName).invokeVoid {
            \(indent(encodedArguments, spaces: 12))
                }
            }
            """
        }
        guard let failureResult = renderNativeCallbackFailureResult(
            shape: resultShape,
            type: signature.result
        ) else {
            throw BridgeGeneration.Error.invalidSwiftType(
                "native callback result shape"
            )
        }
        let decoded = renderDecode(
            expression: "callbackResult",
            shape: resultShape,
            type: signature.result
        )
        return """
        \(opening)
            \(callbackName).invokeResult(
                arguments: {
        \(indent(encodedArguments, spaces: 20))
                },
                decodeResult: { callbackResult in
                    \(decoded)
                },
                failureResult: {
                    \(failureResult)
                }
            )
        }
        """
    }

    /// Renders the deterministic value returned only after a nonthrowing
    /// native callback fails. Eligibility is derived from the logical value
    /// shape; no SDK declaration or native nominal receives a special case.
    private func renderNativeCallbackFailureResult(
        shape: SwiftTypeShape,
        type: Bytecode.ValueType
    ) -> String? {
        switch (shape, type) {
        case (.named, .bool):
            return "false"
        case (.named, .integer), (.named, .float):
            return "0"
        case let (.named(name), .string):
            if ["Character", "Swift.Character"].contains(name) {
                return "\(name)(\(String(reflecting: "\0")))"
            }
            return "\(name)()"
        case let (.named(name), .array(element))
        where element == .string
                && ["Substring", "Swift.Substring"].contains(name):
            return "\(name)()"
        case (.named, .any):
            return "false as Swift.Bool"
        case (.optional, .optional):
            return "nil"
        case (.array, .array), (.set, .set):
            return "[]"
        case (.dictionary, .dictionary):
            return "[:]"
        case let (.tuple(shapes), .tuple(types)):
            guard shapes.count == types.count else { return nil }
            let elements = zip(shapes, types).map {
                renderNativeCallbackFailureResult(shape: $0.0, type: $0.1)
            }
            guard elements.allSatisfy({ $0 != nil }) else { return nil }
            return "(\(elements.compactMap { $0 }.joined(separator: ", ")))"
        case (.named, .void):
            return "()"
        default:
            return nil
        }
    }

    /// A direct callable is strengthened to `@escaping` in the generated outer
    /// callback type. The final generated call is the lifetime proof: Swift
    /// rejects the adapter if the imported API can supply only a nonescaping
    /// nested value. Optional function values are escaping by construction.
    private func isSafeNativeCallbackArgumentSpelling(
        shape: SwiftTypeShape,
        type: Bytecode.ValueType
    ) -> Bool {
        switch (shape, type) {
        case let (.function(_, _, _), .closure(signature)):
            return signature.isNativeBridgeCallable
        case let (
            .optional(.function(_, _, _)),
            .optional(.closure(signature))
        ):
            return signature.isNativeBridgeCallable
        default:
            return !type.containsClosureValue && type.isNativeBridgeValue
        }
    }

    private func renderGeneratedNativeImportCall(
        generated: BridgeGeneration.GeneratedNativeImport,
        effects: Core.Effects
    ) -> String {
        let target: String
        switch generated.dispatch {
        case .globalFunction:
            target = Core.SwiftName.isOperator(generated.baseName)
                ? "(\(generated.baseName))"
                : escapedSwiftIdentifier(generated.baseName)
        case .initializer:
            target = generated.ownerType!.split(separator: ".").map {
                escapedSwiftIdentifier(String($0))
            }.joined(separator: ".")
        case .staticMethod:
            let owner = generated.ownerType!.split(separator: ".").map {
                escapedSwiftIdentifier(String($0))
            }.joined(separator: ".")
            target = owner + "." + escapedSwiftIdentifier(generated.baseName)
        case .nativeUpcast:
            let owner = generated.ownerType!.split(separator: ".").map {
                escapedSwiftIdentifier(String($0))
            }.joined(separator: ".")
            return "argument0 as \(owner)"
        case .anyObjectBridge:
            let owner = generated.ownerType!.split(separator: ".").map {
                escapedSwiftIdentifier(String($0))
            }.joined(separator: ".")
            return "argument0 as \(owner)"
        case .staticGetter:
            let owner = generated.ownerType!.split(separator: ".").map {
                escapedSwiftIdentifier(String($0))
            }.joined(separator: ".")
            return renderEffectfulNativeCall(
                owner + "." + escapedSwiftIdentifier(generated.baseName),
                effects: effects
            )
        case .staticSetter:
            let owner = generated.ownerType!.split(separator: ".").map {
                escapedSwiftIdentifier(String($0))
            }.joined(separator: ".")
            return owner + "." + escapedSwiftIdentifier(generated.baseName)
                + " = argument0"
        case .instanceMethod:
            target = "argument\(generated.parameterSwiftTypes.count - 1)."
                + escapedSwiftIdentifier(generated.baseName)
        case .instanceGetter:
            return renderEffectfulNativeCall(
                "argument0." + escapedSwiftIdentifier(generated.baseName),
                effects: effects
            )
        case .instanceSetter:
            return "argument1." + escapedSwiftIdentifier(generated.baseName)
                + " = argument0"
        case .instanceValueSetter:
            let mutation = "argument1." + escapedSwiftIdentifier(generated.baseName)
                + " = argument0; return argument1"
            return "{ \(mutation) }()"
        }
        let arguments = generated.argumentLabels.enumerated().map { offset, label in
            label == "_"
                ? "argument\(offset)"
                : "\(label): argument\(offset)"
        }.joined(separator: ", ")
        return renderEffectfulNativeCall(
            "\(target)(\(arguments))",
            effects: effects
        )
    }

    private func renderEffectfulNativeCall(
        _ expression: String,
        effects: Core.Effects
    ) -> String {
        (effects.mayThrow ? "try " : "")
            + (effects.isAsync ? "await " : "")
            + expression
    }

    private func renderMainActorCall(_ directCall: String, effects: Core.Effects) -> String {
        guard effects.requiresMainActor else { return directCall }
        let attempt = effects.isAsync ? "try await " : "try "
        return """
        \(attempt)context.withMainActor {
        \(indent(directCall, spaces: 4))
        }
        """
    }

    private func renderGeneratedThrowingCall(
        _ call: String,
        resultDeclaration: String?,
        effects: Core.Effects
    ) -> String {
        let assignment = resultDeclaration.map { "\($0) = " } ?? ""
        guard effects.mayThrow else { return assignment + call }
        let declaration = resultDeclaration.map { "\($0)\n" } ?? ""
        return """
        \(declaration)do {
            \(resultDeclaration == nil ? "" : "result = ")\(call)
        } catch let trap as VM.RuntimeTrap {
            throw trap
        } catch {
            return .businessError(String(describing: error))
        }
        """
    }

    private func renderDecodeResult(
        shape: SwiftTypeShape,
        type: Bytecode.ValueType,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) -> String {
        if type == .void {
            return "{ value in try Runtime.BridgeValueCodec.decodeVoid(value); return () }"
        }
        return """
        { value in
            guard let value else {
                throw VM.RuntimeTrap.typeMismatch(expected: \(render(type)), actual: nil)
            }
            return \(renderDecode(
                expression: "value",
                shape: shape,
                type: type,
                frozenValueTypes: frozenValueTypes
            ))
        }
        """
    }

    private func renderEncode(
        expression: String,
        shape: SwiftTypeShape,
        type: Bytecode.ValueType,
        nativeCatalog: String,
        inputEncoder: String? = nil,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ] = [:]
    ) -> String {
        switch (shape, type) {
        case (.named, .any):
            if let inputEncoder {
                return "try \(inputEncoder).encodeAny(\(expression))"
            }
            return "try Runtime.BridgeValueCodec.encodeAny(\(expression))"
        case (.named, .bool), (.named, .integer), (.named, .float), (.named, .string):
            if let inputEncoder {
                return "try \(inputEncoder).encode(\(expression))"
            }
            return "try Runtime.BridgeValueCodec.encode(\(expression))"
        case let (.named(name), .array(element))
        where element == .string
                && ["Substring", "Swift.Substring"].contains(name):
            if let inputEncoder {
                return "try \(inputEncoder).encode(\(expression))"
            }
            return "try Runtime.BridgeValueCodec.encode(\(expression))"
        case let (.named, .native(typeID)):
            if let inputEncoder {
                return "try \(inputEncoder).encodeNative(\(expression), as: \(render(typeID)), "
                    + "catalog: \(nativeCatalog))"
            }
            return "try Runtime.BridgeValueCodec.encodeNative(\(expression), as: \(render(typeID)), "
                + "catalog: \(nativeCatalog))"
        case let (.named, .local(key)):
            guard let record = frozenValueTypes[key] else {
                preconditionFailure("validated frozen value requires a generated codec")
            }
            let group = BridgeGeneration.GeneratedNativeType.groupName(
                sourceFileLogicalID: record.sourceFileLogicalID
            )
            if let inputEncoder {
                return "try \(group).encodeInput_\(record.codecIdentifier)("
                    + "\(expression), using: \(inputEncoder))"
            }
            return "try \(group).encodeResult_\(record.codecIdentifier)(\(expression))"
        case (.named, .error):
            if let inputEncoder {
                return "try \(inputEncoder).encodeError(\(expression))"
            }
            return "try Runtime.BridgeValueCodec.encodeError(\(expression))"
        case let (
            .optional(.function(_, parameterShapes, resultShape)),
            .optional(.closure(signature))
        ):
            guard let inputEncoder,
                  signature.isNativeBridgeCallable
            else {
                preconditionFailure(
                    "validated optional native callable requires a callback encoder"
                )
            }
            let encoded = renderEncodeNativeClosure(
                expression: "wrapped",
                parameterShapes: parameterShapes,
                resultShape: resultShape,
                signature: signature,
                nativeCatalog: nativeCatalog,
                inputEncoder: inputEncoder,
                frozenValueTypes: frozenValueTypes
            )
            return "try \(inputEncoder).encodeOptional(\(expression)) { wrapped in "
                + "\(encoded) }"
        case let (.optional(wrappedShape), .optional(wrappedType)):
            let encoded = renderEncode(
                expression: "wrapped",
                shape: wrappedShape,
                type: wrappedType,
                nativeCatalog: nativeCatalog,
                inputEncoder: inputEncoder,
                frozenValueTypes: frozenValueTypes
            )
            if let inputEncoder {
                return "try \(inputEncoder).encodeOptional(\(expression)) { wrapped in "
                    + "\(encoded) }"
            }
            return "try Runtime.BridgeValueCodec.encodeOptional(\(expression)) { wrapped in "
                + "\(encoded) }"
        case let (.array(elementShape), .array(elementType)):
            let encoded = renderEncode(
                expression: "element",
                shape: elementShape,
                type: elementType,
                nativeCatalog: nativeCatalog,
                inputEncoder: inputEncoder,
                frozenValueTypes: frozenValueTypes
            )
            if let inputEncoder {
                return "try \(inputEncoder).encodeArray(\(expression), elementType: "
                    + "\(render(elementType))) { element in \(encoded) }"
            }
            return "try Runtime.BridgeValueCodec.encodeArray(\(expression), elementType: "
                + "\(render(elementType))) { element in \(encoded) }"
        case let (.dictionary(keyShape, valueShape), .dictionary(keyType, valueType)):
            let encodedKey = renderEncode(
                expression: "key",
                shape: keyShape,
                type: keyType,
                nativeCatalog: nativeCatalog,
                inputEncoder: inputEncoder,
                frozenValueTypes: frozenValueTypes
            )
            let encodedValue = renderEncode(
                expression: "value",
                shape: valueShape,
                type: valueType,
                nativeCatalog: nativeCatalog,
                inputEncoder: inputEncoder,
                frozenValueTypes: frozenValueTypes
            )
            if let inputEncoder {
                return "try \(inputEncoder).encodeDictionary(\(expression), keyType: "
                    + "\(render(keyType)), valueType: \(render(valueType)), "
                    + "encodeKey: { key in \(encodedKey) }, "
                    + "encodeValue: { value in \(encodedValue) })"
            }
            return "try Runtime.BridgeValueCodec.encodeDictionary(\(expression), keyType: "
                + "\(render(keyType)), valueType: \(render(valueType)), "
                + "encodeKey: { key in \(encodedKey) }, "
                + "encodeValue: { value in \(encodedValue) })"
        case let (.set(elementShape), .set(elementType)):
            let encoded = renderEncode(
                expression: "element",
                shape: elementShape,
                type: elementType,
                nativeCatalog: nativeCatalog,
                inputEncoder: inputEncoder,
                frozenValueTypes: frozenValueTypes
            )
            if let inputEncoder {
                return "try \(inputEncoder).encodeSet(\(expression), elementType: "
                    + "\(render(elementType))) { element in \(encoded) }"
            }
            return "try Runtime.BridgeValueCodec.encodeSet(\(expression), elementType: "
                + "\(render(elementType))) { element in \(encoded) }"
        case let (.tuple(shapes), .tuple(types)):
            let values = zip(shapes, types).enumerated().map { offset, pair in
                renderEncode(
                    expression: "(\(expression)).\(offset)",
                    shape: pair.0,
                    type: pair.1,
                    nativeCatalog: nativeCatalog,
                    inputEncoder: inputEncoder,
                    frozenValueTypes: frozenValueTypes
                )
            }
            if let inputEncoder {
                return "try \(inputEncoder).encodeTuple(count: \(values.count)) { "
                    + "\(renderArray(values, indentation: 8)) }"
            }
            return "try Runtime.BridgeValueCodec.encodeTuple(\(renderArray(values, indentation: 8)))"
        case let (
            .function(_, parameterShapes, resultShape),
            .closure(signature)
        ):
            guard let inputEncoder,
                  signature.isNativeBridgeCallable
            else {
                preconditionFailure(
                    "validated native callable requires an escaping callback encoder"
                )
            }
            return renderEncodeNativeClosure(
                expression: expression,
                parameterShapes: parameterShapes,
                resultShape: resultShape,
                signature: signature,
                nativeCatalog: nativeCatalog,
                inputEncoder: inputEncoder,
                frozenValueTypes: frozenValueTypes
            )
        case (.named, .void):
            return "try Runtime.BridgeValueCodec.encodeVoid(\(expression))"
        default:
            preconditionFailure("validated bridge type cannot reach an unsupported encoder")
        }
    }

    private func renderEncodeNativeClosure(
        expression: String,
        parameterShapes: [SwiftTypeShape],
        resultShape: SwiftTypeShape,
        signature: Bytecode.ClosureSignature,
        nativeCatalog: String,
        inputEncoder: String,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ] = [:]
    ) -> String {
        precondition(parameterShapes.count == signature.parameters.count)
        let decoded = zip(parameterShapes, signature.parameters).enumerated().map {
            index, pair in
            "let nativeArgument\(index) = " + renderDecode(
                expression: "nativeArguments[\(index)]",
                shape: pair.0,
                type: pair.1,
                frozenValueTypes: frozenValueTypes
            )
        }
        let arguments = parameterShapes.indices.map {
            "nativeArgument\($0)"
        }.joined(separator: ", ")
        let call = "(\(expression))(\(arguments))"
        let isolatedCall = signature.effects.requiresMainActor
            ? "MainActor.assumeIsolated { \(call) }"
            : call
        let invocation: String
        if signature.result == .void {
            invocation = "\(isolatedCall)\nreturn nil"
        } else {
            let encoded = renderEncode(
                expression: "nativeResult",
                shape: resultShape,
                type: signature.result,
                nativeCatalog: nativeCatalog,
                inputEncoder: "nativeResultEncoder",
                frozenValueTypes: frozenValueTypes
            )
            invocation = "let nativeResult = \(isolatedCall)\nreturn \(encoded)"
        }
        let body = (decoded + [invocation]).joined(separator: "\n")
        return """
        try \(inputEncoder).encodeNativeClosure(
            signature: \(render(signature))
        ) { nativeArguments, nativeResultEncoder in
        \(indent(body, spaces: 4))
        }
        """
    }

    private func renderDecode(
        expression: String,
        shape: SwiftTypeShape,
        type: Bytecode.ValueType,
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ] = [:]
    ) -> String {
        switch (shape, type) {
        case (.named, .any):
            return "try Runtime.BridgeValueCodec.decodeAny(\(expression))"
        case let (.named(name), .bool), let (.named(name), .integer),
             let (.named(name), .float), let (.named(name), .string):
            return "try Runtime.BridgeValueCodec.decode(\(expression), as: \(name).self)"
        case let (.named(name), .array(element))
        where element == .string
                && ["Substring", "Swift.Substring"].contains(name):
            return "try Runtime.BridgeValueCodec.decode(\(expression), as: \(name).self)"
        case let (.named(name), .native(typeID)):
            return "try Runtime.BridgeValueCodec.decodeNative(\(expression), as: \(name).self, "
                + "typeID: \(render(typeID)))"
        case let (.named, .local(key)):
            guard let record = frozenValueTypes[key] else {
                preconditionFailure("validated frozen value requires a generated codec")
            }
            let group = BridgeGeneration.GeneratedNativeType.groupName(
                sourceFileLogicalID: record.sourceFileLogicalID
            )
            return "try \(group).decode_\(record.codecIdentifier)(\(expression))"
        case (.named, .error):
            return "try Runtime.BridgeValueCodec.decodeError(\(expression))"
        case let (.optional(wrappedShape), .optional(wrappedType)):
            let decoded = renderDecode(
                expression: "wrapped",
                shape: wrappedShape,
                type: wrappedType,
                frozenValueTypes: frozenValueTypes
            )
            return "try Runtime.BridgeValueCodec.decodeOptional(\(expression)) { wrapped in "
                + "\(decoded) }"
        case let (.array(elementShape), .array(elementType)):
            let decoded = renderDecode(
                expression: "element",
                shape: elementShape,
                type: elementType,
                frozenValueTypes: frozenValueTypes
            )
            return "try Runtime.BridgeValueCodec.decodeArray(\(expression), elementType: "
                + "\(render(elementType))) { element in \(decoded) }"
        case let (.dictionary(keyShape, valueShape), .dictionary(keyType, valueType)):
            let decodedKey = renderDecode(
                expression: "key",
                shape: keyShape,
                type: keyType,
                frozenValueTypes: frozenValueTypes
            )
            let decodedValue = renderDecode(
                expression: "value",
                shape: valueShape,
                type: valueType,
                frozenValueTypes: frozenValueTypes
            )
            return "try Runtime.BridgeValueCodec.decodeDictionary(\(expression), keyType: "
                + "\(render(keyType)), valueType: \(render(valueType)), "
                + "decodeKey: { key in \(decodedKey) }, "
                + "decodeValue: { value in \(decodedValue) })"
        case let (.set(elementShape), .set(elementType)):
            let decoded = renderDecode(
                expression: "element",
                shape: elementShape,
                type: elementType,
                frozenValueTypes: frozenValueTypes
            )
            return "try Runtime.BridgeValueCodec.decodeSet(\(expression), elementType: "
                + "\(render(elementType))) { element in \(decoded) }"
        case let (.tuple(shapes), .tuple(types)):
            let temporary = "tuple_\(Core.Digest.sha256(expression).hex.prefix(8))"
            let values = zip(shapes, types).enumerated().map { offset, pair in
                renderDecode(
                    expression: "\(temporary)[\(offset)]",
                    shape: pair.0,
                    type: pair.1,
                    frozenValueTypes: frozenValueTypes
                )
            }
            return "try { () throws -> \(shape.rendered) in let \(temporary) = "
                + "try Runtime.BridgeValueCodec.decodeTuple(\(expression), count: \(shapes.count)); "
                + "return (\(values.joined(separator: ", "))) }()"
        default:
            preconditionFailure("validated bridge type cannot reach an unsupported decoder")
        }
    }

    private func render(_ typeID: Core.TypeID) -> String {
        "Core.TypeID(rawValue: \(render(typeID.rawValue)))"
    }

    private func render(_ key: Bytecode.LocalTypeKey) -> String {
        "Bytecode.LocalTypeKey(rawValue: \(quoted(key.rawValue)))"
    }

    private func indent(_ value: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    private func validateNativeBindings(
        archive: InterfaceArchive.Archive,
        imports: [BridgeGeneration.NativeImportBinding],
        types: [BridgeGeneration.NativeTypeBinding]
    ) throws {
        let emittedImports = archive.nativeImports.filter(\.isEmittedToDevice)
        let expectedImportIDs = Set(emittedImports.compactMap(\.id))
        guard expectedImportIDs.count == emittedImports.count,
              Set(imports.map(\.id)).count == imports.count,
              Set(imports.map(\.id)) == expectedImportIDs
        else {
            throw BridgeGeneration.Error.incompleteNativeImportBindings
        }
        let importsByID = Dictionary(uniqueKeysWithValues: emittedImports.compactMap { record in
            record.id.map { ($0, record) }
        })
        for binding in imports {
            guard let record = importsByID[binding.id],
                  record.key == binding.key,
                  isUsableExpression(binding.invokerExpression),
                  binding.importedModules == Array(Set(binding.importedModules)).sorted(),
                  binding.importedModules.allSatisfy(isValidModulePath)
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
            if let generated = binding.generated {
                try validateGeneratedNativeImport(
                    generated,
                    binding: binding,
                    record: record,
                    archive: archive
                )
            }
        }

        let emittedTypes = archive.nativeTypes.filter(\.isEmittedToDevice)
        let expectedTypeIDs = Set(emittedTypes.map(\.id))
        guard Set(types.map(\.id)).count == types.count,
              Set(types.map(\.id)) == expectedTypeIDs
        else {
            throw BridgeGeneration.Error.incompleteNativeTypeBindings
        }
        let typesByID = Dictionary(uniqueKeysWithValues: emittedTypes.map { ($0.id, $0) })
        for binding in types {
            guard let record = typesByID[binding.id],
                  record.canonicalName == binding.canonicalName,
                  record.layoutFingerprint == binding.layoutFingerprint,
                  record.requiresMainActor == binding.requiresMainActor,
                  isUsableExpression(binding.operationsExpression),
                  binding.importedModules == Array(Set(binding.importedModules)).sorted(),
                  binding.importedModules.allSatisfy(isValidModulePath)
            else {
                throw BridgeGeneration.Error.nativeTypeBindingMismatch(binding.id)
            }
            if let generated = binding.generated {
                try validateGeneratedNativeType(
                    generated,
                    binding: binding,
                    record: record,
                    archive: archive
                )
            }
        }
    }

    private func validateGeneratedNativeType(
        _ generated: BridgeGeneration.GeneratedNativeType,
        binding: BridgeGeneration.NativeTypeBinding,
        record: InterfaceArchive.TypeRecord,
        archive: InterfaceArchive.Archive
    ) throws {
        let expectedExpression = BridgeGeneration.GeneratedNativeType.bindingExpression(
            sourceFileLogicalID: generated.sourceFileLogicalID,
            id: binding.id,
            canonicalName: record.canonicalName,
            layoutFingerprint: record.layoutFingerprint,
            requiresMainActor: record.requiresMainActor,
            estimatedSize: record.estimatedSize
        )
        let shape = try parseSwiftType(generated.swiftType)
        guard binding.operationsExpression == expectedExpression,
              archive.sources.contains(where: {
                  $0.logicalPath == generated.sourceFileLogicalID
              }),
              isSafeLogicalPath(generated.sourceFileLogicalID),
              isValidGeneratedSwiftTypeSpelling(generated.swiftType),
              swiftTypeMatches(shape, type: .native(record.id), archive: archive),
              Self.generatedRepresentation(generated.representation, matches: record.kind),
              record.isCopyable
        else {
            throw BridgeGeneration.Error.nativeTypeBindingMismatch(binding.id)
        }
    }

    private static func generatedRepresentation(
        _ representation: BridgeGeneration.GeneratedNativeType.Representation,
        matches kind: InterfaceArchive.TypeKind
    ) -> Bool {
        switch representation {
        case .reference: kind == .reference
        case .rawRepresentable: kind == .value || kind == .enumeration
        case .opaqueValue: kind == .value
        }
    }

    private func validateGeneratedNativeImport(
        _ generated: BridgeGeneration.GeneratedNativeImport,
        binding: BridgeGeneration.NativeImportBinding,
        record: InterfaceArchive.NativeImportRecord,
        archive: InterfaceArchive.Archive
    ) throws {
        let expectedExpression = BridgeGeneration.GeneratedNativeImport.bindingExpression(
            sourceFileLogicalID: generated.sourceFileLogicalID,
            id: binding.id,
            key: binding.key
        )
        let expectedDeadlineMode: Core.NativeImportDeadlineMode =
            record.effects.isAsync ? .suspending : .bounded
        guard binding.invokerExpression == expectedExpression,
              record.silMangledNames.contains(generated.declarationMangledName),
              isSafeLogicalPath(generated.sourceFileLogicalID),
              isValidSwiftIdentifier(generated.baseName)
                || generated.dispatch == .globalFunction
                    && Core.SwiftName.isOperator(generated.baseName),
              generated.parameterSwiftTypes.count == record.parameterTypes.count,
              !isReceiverDispatch(generated.dispatch) || !record.parameterTypes.isEmpty,
              generated.argumentLabels.count == record.parameterTypes.count
                - (isReceiverDispatch(generated.dispatch) ? 1 : 0),
              generated.argumentLabels.allSatisfy({
                  $0 == "_" || isValidSwiftIdentifier($0)
              }),
              record.capability == .nativeImportsV1,
              record.contract.domain == .application,
              record.contract.execution.deadlineMode == expectedDeadlineMode,
              !record.effects.isAsync || (
                  record.abiAdapter == .direct
                      && record.contract.callbacks.isEmpty
                      && !record.resultType.containsClosureValue
                      && supportsAsyncGeneratedDispatch(generated.dispatch)
              ),
              areGeneratedNativeImportParameters(
                  record.parameterTypes,
                  callbacks: record.contract.callbacks
              )
        else {
            throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
        }
        switch generated.dispatch {
        case .globalFunction:
            guard generated.ownerType == nil,
                  record.contract.kind == .globalFunction,
                  isGeneratedResultType(record.resultType)
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .initializer:
            guard record.contract.kind == .initializer,
                  let owner = generated.ownerType,
                  generated.baseName == "init",
                  isValidGeneratedSwiftTypeSpelling(owner),
                  isNativeType(record.resultType),
                  generated.resultSwiftType == owner
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .staticMethod:
            guard record.contract.kind == .staticMethod,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  isGeneratedResultType(record.resultType)
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .nativeUpcast:
            guard record.contract.kind == .staticMethod,
                  let owner = generated.ownerType,
                  generated.baseName == "upcast",
                  isValidGeneratedSwiftTypeSpelling(owner),
                  generated.argumentLabels == ["_"],
                  record.parameterTypes.count == 1,
                  isNativeType(record.parameterTypes[0]),
                  isNativeType(record.resultType),
                  generated.resultSwiftType == owner
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .anyObjectBridge:
            guard record.contract.kind == .staticMethod,
                  let owner = generated.ownerType,
                  generated.baseName == "bridge",
                  isValidGeneratedSwiftTypeSpelling(owner),
                  generated.argumentLabels == ["_"],
                  record.parameterTypes == [.any],
                  isNativeType(record.resultType),
                  generated.resultSwiftType == owner
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .staticGetter:
            guard record.contract.kind == .staticGetter,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  generated.argumentLabels.isEmpty,
                  generated.parameterSwiftTypes.isEmpty,
                  record.parameterTypes.isEmpty,
                  record.resultType != .void,
                  isGeneratedResultType(record.resultType)
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .staticSetter:
            guard record.contract.kind == .staticSetter,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  generated.argumentLabels == ["_"],
                  record.parameterTypes.count == 1,
                  record.resultType == .void,
                  generated.resultSwiftType == "Swift.Void"
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .instanceMethod:
            guard record.contract.kind == .instanceMethod,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  record.parameterTypes.last.map(isNativeType) == true,
                  generated.parameterSwiftTypes.last == owner,
                  isGeneratedResultType(record.resultType)
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .instanceGetter:
            guard record.contract.kind == .instanceGetter,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  generated.argumentLabels.isEmpty,
                  record.parameterTypes.count == 1,
                  isNativeType(record.parameterTypes[0]),
                  generated.parameterSwiftTypes == [owner],
                  record.resultType != .void,
                  isGeneratedResultType(record.resultType)
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .instanceSetter:
            guard record.contract.kind == .instanceSetter,
                  record.abiAdapter == .direct,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  generated.argumentLabels == ["_"],
                  record.parameterTypes.count == 2,
                  isNativeType(record.parameterTypes[1]),
                  generated.parameterSwiftTypes.last == owner,
                  record.resultType == .void
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .instanceValueSetter:
            guard record.contract.kind == .instanceSetter,
                  record.abiAdapter == .mutatingValueReceiver,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  generated.argumentLabels == ["_"],
                  record.parameterTypes.count == 2,
                  isNativeType(record.parameterTypes[1]),
                  generated.parameterSwiftTypes.last == owner,
                  record.resultType == record.parameterTypes[1],
                  generated.resultSwiftType == owner
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        }
        do {
            let parameterShapes = try generated.parameterSwiftTypes.map(parseSwiftType)
            let resultShape = try parseSwiftType(generated.resultSwiftType)
            guard zip(parameterShapes, record.parameterTypes).allSatisfy({
                swiftTypeMatches($0.0, type: $0.1, archive: archive)
            }), swiftTypeMatches(resultShape, type: record.resultType, archive: archive)
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        } catch {
            throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
        }
    }

    private func isReceiverDispatch(
        _ dispatch: BridgeGeneration.GeneratedNativeImport.Dispatch
    ) -> Bool {
        switch dispatch {
        case .instanceMethod, .instanceGetter, .instanceSetter,
             .instanceValueSetter: true
        case .globalFunction, .initializer, .staticMethod, .nativeUpcast,
             .anyObjectBridge,
             .staticGetter, .staticSetter: false
        }
    }

    private func supportsAsyncGeneratedDispatch(
        _ dispatch: BridgeGeneration.GeneratedNativeImport.Dispatch
    ) -> Bool {
        switch dispatch {
        case .globalFunction, .initializer, .staticMethod, .staticGetter,
             .instanceMethod, .instanceGetter:
            true
        case .nativeUpcast, .anyObjectBridge, .staticSetter, .instanceSetter,
             .instanceValueSetter:
            false
        }
    }

    private func areGeneratedNativeImportParameters(
        _ types: [Bytecode.ValueType],
        callbacks: [Core.NativeImportCallback]
    ) -> Bool {
        var callbackByParameter: [Int: Core.NativeImportCallback] = [:]
        for callback in callbacks {
            let index = Int(callback.parameterIndex)
            guard index < types.count,
                  callbackByParameter.updateValue(
                      callback,
                      forKey: index
                  ) == nil
            else { return false }
        }
        return types.indices.allSatisfy { index in
            if callbackByParameter[index] != nil {
                guard let shape = types[index].directClosureShape else {
                    return false
                }
                return shape.signature.isNativeBridgeCallback
            }
            return types[index].isOrdinaryNativeImportBridgeValue
        }
    }

    private func isGeneratedResultType(_ type: Bytecode.ValueType) -> Bool {
        type.isNativeImportBridgeResult
    }

    private func isNativeType(_ type: Bytecode.ValueType) -> Bool {
        if case .native = type { return true }
        return false
    }

    private func isValidGeneratedSwiftTypeSpelling(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 64 * 1_024 else { return false }
        if value.hasSuffix("?") {
            return isValidGeneratedSwiftTypeSpelling(String(value.dropLast()))
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            return isValidGeneratedSwiftTypeSpelling(String(value.dropFirst().dropLast()))
        }
        if let open = value.firstIndex(of: "<") {
            guard value.hasSuffix(">"),
                  isValidModulePath(String(value[..<open]))
            else { return false }
            let body = value[value.index(after: open)..<value.index(before: value.endIndex)]
            var arguments: [String] = []
            var start = body.startIndex
            var depth = 0
            for index in body.indices {
                switch body[index] {
                case "<": depth += 1
                case ">":
                    depth -= 1
                    if depth < 0 { return false }
                case "," where depth == 0:
                    arguments.append(
                        String(body[start..<index]).trimmingCharacters(in: .whitespaces)
                    )
                    start = body.index(after: index)
                default: break
                }
            }
            guard depth == 0 else { return false }
            arguments.append(
                String(body[start...]).trimmingCharacters(in: .whitespaces)
            )
            return !arguments.isEmpty
                && arguments.allSatisfy(isValidGeneratedSwiftTypeSpelling)
        }
        return isValidModulePath(value)
    }

    private func isSafeLogicalPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 16 * 1_024,
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains("..")
    }

    private func isUsableExpression(_ expression: String) -> Bool {
        !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !expression.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private func isValidModulePath(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".").allSatisfy { component in
            guard let first = component.first, first == "_" || first.isLetter else {
                return false
            }
            return component.dropFirst().allSatisfy {
                $0 == "_" || $0.isLetter || $0.isNumber
            }
        }
    }

    private func renderShellFactory(archive: InterfaceArchive.Archive) -> String {
        let entries = archive.functions
            .filter(\.patchability.isEligible)
            .sorted { $0.entryIndex! < $1.entryIndex! }
            .map(renderEntry)
        let imports = archive.nativeImports
            .filter(\.isEmittedToDevice)
            .sorted { $0.id! < $1.id! }
            .map(renderImport)
        let types = archive.nativeTypes
            .filter(\.isEmittedToDevice)
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map(renderType)
        let frozenValueTypes = archive.frozenValueTypes
            .sorted { $0.key < $1.key }
            .map(renderFrozenValueType)
        return """
            public static func makeShellInterface() throws -> Verification.ShellInterface {
                try Verification.ShellInterface(
                    interfaceHash: interfaceHash,
                    compatibility: \(render(archive.compatibility)),
                    capabilities: \(renderCapabilities(archive.capabilities)),
                    entries: \(renderArray(entries, indentation: 20)),
                    imports: \(renderArray(imports, indentation: 20)),
                    types: \(renderArray(types, indentation: 20)),
                    frozenValueTypes: \(renderArray(frozenValueTypes, indentation: 20))
                )
            }
        """
    }

    private func renderPatchBuildContractFactory(
        archive: InterfaceArchive.Archive
    ) -> String {
        let imports = archive.nativeImports.compactMap { record -> String? in
            guard record.isEmittedToDevice, let id = record.id else { return nil }
            return "Core.NativeImportID(rawValue: \(id.rawValue))"
        }.sorted()
        return """
            public static func makePatchBuildContract() throws -> PatchRuntime.BuildContract {
                try PatchRuntime.BuildContract(
                    bundleID: \(quoted(archive.metadata.bundleID)),
                    buildNumber: \(quoted(archive.metadata.buildNumber)),
                    shellNamespaceID: Core.ShellNamespaceID(
                        rawValue: \(render(archive.metadata.shellNamespaceID.rawValue))
                    ),
                    shellInterfaceHash: interfaceHash,
                    minimumOSVersion: \(render(archive.metadata.minimumOS)),
                    compatibility: \(render(archive.compatibility)),
                    capabilities: \(renderCapabilities(archive.capabilities)),
                    nativeImportIDs: Set(\(renderArray(imports, indentation: 24))),
                    runtimeImageIdentity: .current
                )
            }
        """
    }

    private func renderNativeCatalogFactory(
        imports: [BridgeGeneration.NativeImportBinding],
        records: [InterfaceArchive.NativeImportRecord],
        types: [BridgeGeneration.NativeTypeBinding]
    ) throws -> String {
        let recordsByID = Dictionary(
            uniqueKeysWithValues: records.compactMap { record in
                record.id.map { ($0, record) }
            }
        )
        var synchronousImportExpressions: [String] = []
        var asynchronousImportExpressions: [String] = []
        for binding in imports.sorted(by: { $0.id < $1.id }) {
            guard let record = recordsByID[binding.id], record.isEmittedToDevice else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
            if record.effects.isAsync {
                asynchronousImportExpressions.append(binding.invokerExpression)
            } else {
                synchronousImportExpressions.append(binding.invokerExpression)
            }
        }
        let typeExpressions = types.sorted(by: { $0.id.rawValue < $1.id.rawValue })
            .map(\.operationsExpression)
        return """
            public static func makeNativeCatalog() throws -> VM.NativeCatalog {
                try VM.NativeCatalog(\(renderArray(synchronousImportExpressions, indentation: 16)))
            }

            public static func makeAsyncNativeCatalog() throws -> VM.AsyncNativeCatalog {
                try VM.AsyncNativeCatalog(\(renderArray(asynchronousImportExpressions, indentation: 16)))
            }

            public static func makeNativeTypeCatalog() throws -> VM.NativeTypeCatalog {
                try VM.NativeTypeCatalog(\(renderArray(typeExpressions, indentation: 16)))
            }

            public static func makeRuntime(
                registry: Runtime.GenerationRegistry = .init(),
                observer: any Runtime.Observing = Runtime.NoopObserver()
            ) throws -> Runtime.Engine {
                let nativeCatalog = try makeNativeCatalog()
                let asyncNativeCatalog = try makeAsyncNativeCatalog()
                let nativeTypeCatalog = try makeNativeTypeCatalog()
                return Runtime.Engine(
                    registry: registry,
                    originals: try makeOriginalCatalog(nativeTypeCatalog: nativeTypeCatalog),
                    shellInterfaceHash: interfaceHash,
                    nativeCatalog: nativeCatalog,
                    asyncNativeCatalog: asyncNativeCatalog,
                    nativeTypeCatalog: nativeTypeCatalog,
                    observer: observer
                )
            }
        """
    }

    private func renderEntry(_ record: InterfaceArchive.FunctionRecord) -> String {
        """
        Verification.ResolvedEntry(
            index: .init(rawValue: \(record.entryIndex!.rawValue)),
            key: Core.FunctionKey(rawValue: \(render(record.key.rawValue))),
            parameterTypes: \(renderValueTypes(record.parameterTypes)),
            parameterConventions: \(renderParameterConventions(record.parameterConventions)),
            resultType: \(render(record.resultType)),
            effects: \(render(record.effects)),
            fallbackAllowed: \(record.fallbackAllowed)
        )
        """
    }

    private func renderImport(_ record: InterfaceArchive.NativeImportRecord) -> String {
        """
        Verification.ResolvedNativeImport(
            id: .init(rawValue: \(record.id!.rawValue)),
            key: Core.NativeImportKey(rawValue: \(render(record.key.rawValue))),
            parameterTypes: \(renderValueTypes(record.parameterTypes)),
            resultType: \(render(record.resultType)),
            signature: \(render(record.signature)),
            effects: \(render(record.effects)),
            contract: \(render(record.contract)),
            capability: Core.Capability(rawValue: \(quoted(record.capability.rawValue)))
        )
        """
    }

    private func renderType(_ record: InterfaceArchive.TypeRecord) -> String {
        """
        Verification.ResolvedNativeType(
            id: Core.TypeID(rawValue: \(render(record.id.rawValue))),
            canonicalName: \(quoted(record.canonicalName)),
            kind: .\(record.kind.rawValue),
            layoutFingerprint: \(render(record.layoutFingerprint)),
            isCopyable: \(record.isCopyable),
            requiresMainActor: \(record.requiresMainActor),
            estimatedSize: \(record.estimatedSize)
        )
        """
    }

    private func renderFrozenValueType(
        _ record: InterfaceArchive.FrozenValueTypeRecord
    ) -> String {
        """
        Verification.ResolvedFrozenValueType(
            definition: \(render(record.definition)),
            layoutFingerprint: \(render(record.layoutFingerprint)),
            isCopyable: \(record.isCopyable)
        )
        """
    }

    private func render(_ definition: Bytecode.LocalTypeDefinition) -> String {
        let kind: String = switch definition.kind {
        case let .structure(fields):
            ".structure(fields: [" + fields.map {
                "Bytecode.LocalStructField(name: \(quoted($0.name)), type: \(render($0.type)))"
            }.joined(separator: ", ") + "])"
        case let .enumeration(cases):
            ".enumeration(cases: [" + cases.map {
                "Bytecode.LocalEnumCase(name: \(quoted($0.name)), payloadType: \(render($0.payloadType)))"
            }.joined(separator: ", ") + "])"
        case .class:
            preconditionFailure("a frozen Shell value cannot be a class")
        }
        return "Bytecode.LocalTypeDefinition(key: \(render(definition.key)), "
            + "kind: \(kind), conformsToError: \(definition.conformsToError))"
    }

    private func render(_ compatibility: Core.Compatibility) -> String {
        """
        Core.Compatibility(
            runtime: \(render(compatibility.runtime)),
            bytecode: \(render(compatibility.bytecode)),
            interfaceArchive: \(render(compatibility.interfaceArchive)),
            compilerFingerprint: \(quoted(compatibility.compilerFingerprint))
        )
        """
    }

    private func render(_ version: Core.SemanticVersion) -> String {
        "Core.SemanticVersion(\(version.major), \(version.minor), \(version.patch))"
    }

    private func render(_ signature: Core.LoweredSignature) -> String {
        let parameters = signature.parameters.map(quoted).joined(separator: ", ")
        let isolation = signature.isolation.map(quoted) ?? "nil"
        return "Core.LoweredSignature(parameters: [\(parameters)], result: \(quoted(signature.result)), "
            + "isThrowing: \(signature.isThrowing), isAsync: \(signature.isAsync), "
            + "isolation: \(isolation))"
    }

    private func render(_ contract: Core.NativeImportContract) -> String {
        let callbacks = contract.callbacks.map { callback in
            "Core.NativeImportCallback(parameterIndex: \(callback.parameterIndex), "
                + "lifetime: .\(callback.lifetime.rawValue))"
        }.joined(separator: ", ")
        return """
        Core.NativeImportContract(
            kind: .\(contract.kind.rawValue),
            domain: Core.NativeImportDomain(rawValue: \(quoted(contract.domain.rawValue))),
            access: .\(contract.access.rawValue),
            execution: Core.NativeImportExecutionPolicy(
                deadlineMode: .\(contract.execution.deadlineMode.rawValue),
                maximumDurationMicroseconds: \(contract.execution.maximumDurationMicroseconds),
                allowsMainThread: \(contract.execution.allowsMainThread)
            ),
            callbacks: [\(callbacks)]
        )
        """
    }

    private func render(_ effects: Core.Effects) -> String {
        "Core.Effects(mayThrow: \(effects.mayThrow), mayAllocate: \(effects.mayAllocate), "
            + "hasExternalSideEffects: \(effects.hasExternalSideEffects), "
            + "requiresMainActor: \(effects.requiresMainActor), "
            + "isAsync: \(effects.isAsync))"
    }

    private func render(_ signature: Bytecode.ClosureSignature) -> String {
        "Bytecode.ClosureSignature(parameters: "
            + "\(renderValueTypes(signature.parameters)), parameterConventions: "
            + "\(renderParameterConventions(signature.parameterConventions)), "
            + "result: \(render(signature.result)), "
            + "thrownType: \(render(signature.thrownType)), "
            + "effects: \(render(signature.effects)))"
    }

    private func render(_ type: Bytecode.ValueType) -> String {
        switch type {
        case .void: ".void"
        case .never: ".never"
        case .bool: ".bool"
        case let .integer(bitWidth, signed):
            ".integer(bitWidth: \(bitWidth), signed: \(signed))"
        case let .float(bitWidth): ".float(bitWidth: \(bitWidth))"
        case .string: ".string"
        case .any: ".any"
        case let .array(element): ".array(\(render(element)))"
        case let .dictionary(key, value):
            ".dictionary(key: \(render(key)), value: \(render(value)))"
        case let .set(element): ".set(\(render(element)))"
        case let .native(id): ".native(Core.TypeID(rawValue: \(render(id.rawValue))))"
        case let .local(key):
            ".local(Bytecode.LocalTypeKey(rawValue: \(quoted(key.rawValue))))"
        case .error: ".error"
        case let .address(pointee): ".address(\(render(pointee)))"
        case let .mutableCell(pointee): ".mutableCell(\(render(pointee)))"
        case let .nonOwningReference(kind, pointee):
            ".nonOwningReference(kind: .\(kind.rawValue), pointee: \(render(pointee)))"
        case let .arrayState(kind, element):
            ".arrayState(kind: .\(kind.rawValue), element: \(render(element)))"
        case let .dictionaryState(key, value):
            ".dictionaryState(key: \(render(key)), value: \(render(value)))"
        case let .closure(signature):
            ".closure(\(render(signature)))"
        case let .tuple(elements): ".tuple(\(renderValueTypes(elements)))"
        case let .optional(wrapped): ".optional(\(render(wrapped)))"
        }
    }

    private func render(_ type: Bytecode.ValueType?) -> String {
        type.map(render) ?? "nil"
    }

    private func renderValueTypes(_ types: [Bytecode.ValueType]) -> String {
        "[\(types.map(render).joined(separator: ", "))]"
    }

    private func renderParameterConventions(
        _ conventions: [Bytecode.ParameterConvention]
    ) -> String {
        "[\(conventions.map { ".\($0.rawValue)" }.joined(separator: ", "))]"
    }

    private func renderCapabilities(_ capabilities: [Core.Capability]) -> String {
        let values = capabilities.sorted().map {
            "Core.Capability(rawValue: \(quoted($0.rawValue)))"
        }
        return "[\(values.joined(separator: ", "))]"
    }

    private func render(_ digest: Core.Digest) -> String {
        "try! Core.Digest(hex: \(quoted(digest.hex)))"
    }

    private func renderArray(_ elements: [String], indentation: Int) -> String {
        guard !elements.isEmpty else { return "[]" }
        let prefix = String(repeating: " ", count: indentation)
        let closing = String(repeating: " ", count: max(0, indentation - 4))
        return "[\n" + elements.map { indent($0, with: prefix) }.joined(separator: ",\n")
            + "\n\(closing)]"
    }

    private func indent(_ value: String, with prefix: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    private func quoted(_ value: String) -> String {
        String(reflecting: value)
    }

    private func escapedSwiftIdentifier(_ value: String) -> String {
        Self.swiftKeywords.contains(value) ? "`\(value)`" : value
    }

    private static let swiftKeywords: Set<String> = [
        "Any", "Self", "actor", "any", "as", "associatedtype", "async", "await",
        "break", "borrowing", "case", "catch", "class", "consuming", "continue",
        "default", "defer", "deinit", "distributed", "do", "each", "else", "enum",
        "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard",
        "if", "import", "in", "init", "inout", "internal", "is", "isolated", "let",
        "macro", "nil", "nonisolated", "open", "operator", "package", "precedencegroup",
        "private", "protocol", "public", "repeat", "return", "rethrows", "self", "sending",
        "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "typealias", "var", "where", "while",
    ]
}

private static func isValidSwiftIdentifier(_ value: String) -> Bool {
    Core.SwiftName.isIdentifier(value)
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidModuleName
    case incompleteRootSet
    case rootDoesNotMatchArchive(Core.FunctionKey)
    case invalidRoot(Core.FunctionKey)
    case invalidSwiftType(String)
    case swiftTypeMismatch(Core.FunctionKey)
    case frozenValueTypeMismatch(Bytecode.LocalTypeKey)
    case unsupportedIsolatedRoot(Core.FunctionKey)
    case incompleteNativeImportBindings
    case nativeImportBindingMismatch(Core.NativeImportID)
    case incompleteNativeTypeBindings
    case nativeTypeBindingMismatch(Core.TypeID)
    case outputCollision(String)

    public var description: String {
        switch self {
        case .invalidModuleName: "bridge module name is not a valid Swift identifier"
        case .incompleteRootSet: "bridge roots do not exactly cover eligible HLXI entries"
        case let .rootDoesNotMatchArchive(key): "bridge root does not match HLXI function \(key)"
        case let .invalidRoot(key): "bridge root \(key) has incomplete typed source metadata"
        case let .invalidSwiftType(type): "bridge contains an invalid Swift type spelling: \(type)"
        case let .swiftTypeMismatch(key):
            "bridge Swift type metadata disagrees with the frozen value type for \(key)"
        case let .frozenValueTypeMismatch(key):
            "bridge codec metadata disagrees with frozen Shell value \(key)"
        case let .unsupportedIsolatedRoot(key):
            "bridge root \(key) uses an unsupported actor isolation; v1 accepts nonisolated and MainActor entries"
        case .incompleteNativeImportBindings:
            "native import bindings do not exactly cover the emitted HLXI imports"
        case let .nativeImportBindingMismatch(id):
            "native import binding \(id) disagrees with its frozen HLXI descriptor"
        case .incompleteNativeTypeBindings:
            "native type bindings do not exactly cover the emitted HLXI types"
        case let .nativeTypeBindingMismatch(id):
            "native type binding \(id) disagrees with its frozen HLXI descriptor"
        case let .outputCollision(path):
            "generated Bridge source path collides: \(path)"
        }
    }
}
}
