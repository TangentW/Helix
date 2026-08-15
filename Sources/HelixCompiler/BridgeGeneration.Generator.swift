import Foundation
import HelixBytecode
import HelixCore
import HelixInterface

public enum BridgeGeneration {}

extension BridgeGeneration {
public struct Root: Hashable, Sendable {
    public var functionKey: Core.FunctionKey
    public var entryIndex: Core.EntryIndex
    public var sourceFileLogicalID: String
    public var privateImportSourceFile: String
    public var originalReference: String
    public var replacementDeclaration: String
    public var parameterExpressions: [String]
    public var parameterSwiftTypes: [String]
    public var resultSwiftType: String
    public var originalInvocation: String
    public var bridgeInvocation: String
    public var enclosingPrefix: String
    public var enclosingSuffix: String

    public init(
        functionKey: Core.FunctionKey,
        entryIndex: Core.EntryIndex,
        sourceFileLogicalID: String,
        privateImportSourceFile: String,
        originalReference: String,
        replacementDeclaration: String,
        parameterExpressions: [String],
        parameterSwiftTypes: [String],
        resultSwiftType: String,
        originalInvocation: String,
        bridgeInvocation: String,
        enclosingPrefix: String = "",
        enclosingSuffix: String = ""
    ) {
        self.functionKey = functionKey
        self.entryIndex = entryIndex
        self.sourceFileLogicalID = sourceFileLogicalID
        self.privateImportSourceFile = privateImportSourceFile
        self.originalReference = originalReference
        self.replacementDeclaration = replacementDeclaration
        self.parameterExpressions = parameterExpressions
        self.parameterSwiftTypes = parameterSwiftTypes
        self.resultSwiftType = resultSwiftType
        self.originalInvocation = originalInvocation
        self.bridgeInvocation = bridgeInvocation
        self.enclosingPrefix = enclosingPrefix
        self.enclosingSuffix = enclosingSuffix
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
        for root in roots {
            guard let record = byKey[root.functionKey],
                  record.entryIndex == root.entryIndex,
                  record.sourceFileLogicalID == root.sourceFileLogicalID
            else {
                throw BridgeGeneration.Error.rootDoesNotMatchArchive(root.functionKey)
            }
            try validateRoot(root, record: record, archive: archive)
        }
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
        let sourceGroups = Set(grouped.keys).union(generatedTypeGroups.keys).sorted()
        let nativeTypesByID = Dictionary(uniqueKeysWithValues: archive.nativeTypes.map {
            ($0.id, $0)
        })
        var files: [String: String] = [:]
        var entryGroupNames: [String] = []
        for source in sourceGroups {
            let values = grouped[source] ?? []
            let typeValues = generatedTypeGroups[source] ?? []
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
                lines.append(indent(try renderOriginalEntry(root, record: record), spaces: 12)
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
            lines.append("}")
            for root in sortedValues {
                let record = byKey[root.functionKey]!
                lines.append("")
                lines.append(try renderReplacement(root, record: record))
            }
            lines.append("")
            files[Self.entrySourcePath(for: source)] = lines.joined(separator: "\n")
        }
        for source in archive.sources.map(\.logicalPath)
        where grouped[source] == nil && generatedTypeGroups[source] == nil {
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
        let nativeCatalogFactory = renderNativeCatalogFactory(
            imports: nativeImports,
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
        case named(String)
        case array(SwiftTypeShape)
        case dictionary(key: SwiftTypeShape, value: SwiftTypeShape)
        case optional(SwiftTypeShape)
        case tuple([SwiftTypeShape])

        var rendered: String {
            switch self {
            case let .named(name): name == "Swift.Any" ? "Any" : name
            case let .array(element): "Swift.Array<\(element.rendered)>"
            case let .dictionary(key, value):
                "Swift.Dictionary<\(key.rendered), \(value.rendered)>"
            case let .optional(wrapped): "Swift.Optional<\(wrapped.rendered)>"
            case let .tuple(elements): "(\(elements.map(\.rendered).joined(separator: ", ")))"
            }
        }
    }

    private func validateRoot(
        _ root: BridgeGeneration.Root,
        record: InterfaceArchive.FunctionRecord,
        archive: InterfaceArchive.Archive
    ) throws {
        let hasExactLogicalParameters =
            root.parameterSwiftTypes.count == record.loweredSignature.parameters.count
        let hasBridgedReferenceReceiver: Bool = {
            guard record.role == .method,
                  root.parameterSwiftTypes.count
                    == record.loweredSignature.parameters.count + 1,
                  let receiver = record.parameterTypes.last,
                  case .native = receiver
            else { return false }
            return true
        }()
        let strings = [
            root.privateImportSourceFile, root.originalReference, root.replacementDeclaration,
            root.resultSwiftType, root.originalInvocation,
            root.bridgeInvocation, root.enclosingPrefix, root.enclosingSuffix,
        ] + root.parameterExpressions + root.parameterSwiftTypes
        guard !root.privateImportSourceFile.isEmpty,
              !root.originalReference.isEmpty,
              root.replacementDeclaration.contains("func "),
              !root.resultSwiftType.isEmpty,
              !root.originalInvocation.isEmpty,
              !root.bridgeInvocation.isEmpty,
              root.parameterExpressions.count == record.parameterTypes.count,
              root.parameterSwiftTypes.count == record.parameterTypes.count,
              hasExactLogicalParameters || hasBridgedReferenceReceiver,
              root.parameterExpressions.allSatisfy({ !$0.isEmpty }),
              strings.allSatisfy({
                  $0.utf8.count <= 64 * 1_024
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              }),
              root.enclosingPrefix.isEmpty == root.enclosingSuffix.isEmpty
        else {
            throw BridgeGeneration.Error.invalidRoot(root.functionKey)
        }
        guard record.effects.mayThrow == record.loweredSignature.isThrowing,
              record.effects.isAsync == record.loweredSignature.isAsync
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
                key: root.functionKey
            )
        }
        try validate(
            parseSwiftType(root.resultSwiftType),
            matches: record.resultType,
            archive: archive,
            key: root.functionKey
        )
    }

    private func parseSwiftType(_ raw: String) throws -> SwiftTypeShape {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BridgeGeneration.Error.invalidSwiftType(raw) }
        try validateBalancedDelimiters(value)
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
        for prefix in ["Swift.Optional<", "Optional<"] where value.hasPrefix(prefix) {
            guard value.hasSuffix(">") else {
                throw BridgeGeneration.Error.invalidSwiftType(raw)
            }
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            return .optional(try parseSwiftType(String(value[start..<value.index(before: value.endIndex)])))
        }
        if value.hasPrefix("("), value.hasSuffix(")"), value != "()" {
            let inner = String(value.dropFirst().dropLast())
            let elements = try splitTopLevel(inner).map(parseSwiftType)
            guard elements.count >= 2 else {
                throw BridgeGeneration.Error.invalidSwiftType(raw)
            }
            return .tuple(elements)
        }
        return .named(value)
    }

    private func validateBalancedDelimiters(_ value: String) throws {
        var angleDepth = 0
        var parenthesisDepth = 0
        for character in value {
            switch character {
            case "<": angleDepth += 1
            case ">": angleDepth -= 1
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            default: break
            }
            guard angleDepth >= 0, parenthesisDepth >= 0 else {
                throw BridgeGeneration.Error.invalidSwiftType(value)
            }
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
                angleDepth -= 1
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
            case ">": angleDepth -= 1
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
        key: Core.FunctionKey
    ) throws {
        guard swiftTypeMatches(shape, type: type, archive: archive) else {
            throw BridgeGeneration.Error.swiftTypeMismatch(key)
        }
    }

    private func swiftTypeMatches(
        _ shape: SwiftTypeShape,
        type: Bytecode.ValueType,
        archive: InterfaceArchive.Archive
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
        case let (.optional(shape), .optional(type)):
            return swiftTypeMatches(shape, type: type, archive: archive)
        case let (.array(shape), .array(type)):
            return swiftTypeMatches(shape, type: type, archive: archive)
        case let (.dictionary(keyShape, valueShape), .dictionary(keyType, valueType)):
            return swiftTypeMatches(keyShape, type: keyType, archive: archive)
                && swiftTypeMatches(valueShape, type: valueType, archive: archive)
        case let (.tuple(shapes), .tuple(types)):
            return shapes.count == types.count && zip(shapes, types).allSatisfy {
                swiftTypeMatches($0.0, type: $0.1, archive: archive)
            }
        case let (.named(name), .bool):
            return ["Bool", "Swift.Bool"].contains(name)
        case let (.named(name), .string):
            return ["String", "Swift.String"].contains(name)
        case let (.named(name), .any):
            return ["Any", "Swift.Any"].contains(name)
        case let (.named(name), .void):
            return ["Void", "Swift.Void", "()"].contains(name)
        default:
            return false
        }
    }

    private func renderReplacement(
        _ root: BridgeGeneration.Root,
        record: InterfaceArchive.FunctionRecord
    ) throws -> String {
        let shapes = try root.parameterSwiftTypes.map(parseSwiftType)
        let arguments = zip(zip(root.parameterExpressions, shapes), record.parameterTypes).map {
            renderEncode(
                expression: $0.0.0,
                shape: $0.0.1,
                type: $0.1,
                nativeCatalog: "try Runtime.Bridge.shared.requireNativeTypeCatalog()",
                inputEncoder: "encoder"
            )
        }
        let resultShape = try parseSwiftType(root.resultSwiftType)
        let decodeResult = renderDecodeResult(shape: resultShape, type: record.resultType)
        let array = renderArray(arguments, indentation: 20)
        let originalAttempt = (record.effects.mayThrow ? "try " : "")
            + (record.effects.isAsync ? "await " : "")
        let dispatch = """
        let decision = try Runtime.Bridge.shared.dispatch(
            entry: .init(rawValue: \(root.entryIndex.rawValue)),
            arguments: { encoder in
                try encoder.encodeArguments(count: \(arguments.count)) { \(array) }
            },
            decodeResult: \(decodeResult)
        )
        switch decision {
        case .originalRequired:
            return \(originalAttempt)\(root.originalInvocation)
        case let .returned(result):
            return result
        }
        """
        let body: String
        if record.effects.mayThrow {
            body = dispatch
        } else {
            body = "do {\n" + indent(dispatch, spaces: 4)
                + "\n} catch {\n    Runtime.Bridge.terminate(error)\n}"
        }
        let wrapper = """
        @_dynamicReplacement(for: \(root.originalReference))
        \(root.replacementDeclaration) {
        \(indent(body, spaces: 4))
        }
        """
        guard !root.enclosingPrefix.isEmpty else { return wrapper }
        return root.enclosingPrefix + "\n" + indent(wrapper, spaces: 4)
            + "\n" + root.enclosingSuffix
    }

    private func renderOriginalEntry(
        _ root: BridgeGeneration.Root,
        record: InterfaceArchive.FunctionRecord
    ) throws -> String {
        if record.effects.isAsync {
            // Async entries can only be reached through their exact Swift async
            // wrapper. The synchronous catalog descriptor exists for identity,
            // fallback policy, and activation checks; nested HLVM calls are
            // rejected by the Verifier and fail closed here as defense in depth.
            return """
            Runtime.OriginalEntry(
                index: .init(rawValue: \(root.entryIndex.rawValue)),
                parameterTypes: \(renderValueTypes(record.parameterTypes)),
                resultType: \(render(record.resultType)),
                fallbackAllowed: \(record.fallbackAllowed),
                invoke: { _ in
                    .trapped(.nativeFailure("async Shell entry requires its generated async Bridge"))
                }
            )
            """
        }
        let shapes = try root.parameterSwiftTypes.map(parseSwiftType)
        let decoded = zip(shapes, record.parameterTypes).enumerated().map { offset, pair in
            "let argument\(offset): \(pair.0.rendered) = "
                + renderDecode(expression: "arguments[\(offset)]", shape: pair.0, type: pair.1)
        }
        let call = renderOriginalCall(root, record: record)
        let invocation: String
        if record.resultType == .void {
            let callBody = renderThrowingOriginalCall(call, resultDeclaration: nil, record: record)
            invocation = callBody + "\nreturn .returned(try Runtime.BridgeValueCodec.encodeVoid())"
        } else {
            let resultShape = try parseSwiftType(root.resultSwiftType)
            let resultDeclaration = "let result: \(resultShape.rendered)"
            let callBody = renderThrowingOriginalCall(
                call,
                resultDeclaration: resultDeclaration,
                record: record
            )
            let encoded = renderEncode(
                expression: "result",
                shape: resultShape,
                type: record.resultType,
                nativeCatalog: "nativeTypeCatalog"
            )
            invocation = callBody + "\nreturn .returned(\(encoded))"
        }
        let actorGuard = record.effects.requiresMainActor
            ? ["guard Thread.isMainThread else {",
               "    return .trapped(.nativeFailure(\"MainActor original entry ran off the main thread\"))",
               "}"]
            : []
        let body = (decoded + actorGuard + [invocation]).joined(separator: "\n")
        return """
        Runtime.OriginalEntry(
            index: .init(rawValue: \(root.entryIndex.rawValue)),
            parameterTypes: \(renderValueTypes(record.parameterTypes)),
            resultType: \(render(record.resultType)),
            fallbackAllowed: \(record.fallbackAllowed),
            invoke: { arguments in
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
        record: InterfaceArchive.FunctionRecord
    ) -> String {
        let attempt = record.effects.mayThrow ? "try " : ""
        let bypass = """
        \(attempt)Runtime.Bridge.shared.withOriginalBypass(
            entry: .init(rawValue: \(root.entryIndex.rawValue))
        ) {
            \(attempt)\(root.bridgeInvocation)
        }
        """
        guard record.effects.requiresMainActor else { return bypass }
        return """
        \(attempt)MainActor.assumeIsolated {
        \(indent(bypass, spaces: 4))
        }
        """
    }

    private func renderThrowingOriginalCall(
        _ call: String,
        resultDeclaration: String?,
        record: InterfaceArchive.FunctionRecord
    ) -> String {
        let assignment = resultDeclaration.map { "\($0) = " } ?? ""
        guard record.effects.mayThrow else { return assignment + call }
        let declaration = resultDeclaration.map { "\($0)\n" } ?? ""
        return """
        \(declaration)do {
            \(resultDeclaration == nil ? "" : "result = ")\(call)
        } catch {
            return .businessError(String(describing: error))
        }
        """
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
        let decoded = zip(shapes, record.parameterTypes).enumerated().map { offset, pair in
            let binding = generated.dispatch == .instanceValueSetter
                && offset == record.parameterTypes.count - 1 ? "var" : "let"
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
            let encoded = renderEncode(
                expression: "result",
                shape: resultShape,
                type: record.resultType,
                nativeCatalog: "try Runtime.Bridge.shared.requireNativeTypeCatalog()"
            )
            if record.effects.requiresMainActor {
                // Keep potentially non-Sendable native values actor-isolated;
                // only their Sendable VM representation crosses the boundary.
                let call = """
                try context.withMainActor {
                    let result: \(resultShape.rendered) = \(directCall)
                    return \(encoded)
                }
                """
                let callBody = renderGeneratedThrowingCall(
                    call,
                    resultDeclaration: "let encodedResult: VM.Value",
                    effects: record.effects
                )
                invocation = callBody + "\nreturn .returned(encodedResult)"
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
        return """
        static func \(factoryName)(
            id: Core.NativeImportID,
            key: Core.NativeImportKey
        ) -> any VM.NativeInvoker {
            VM.ClosureNativeInvoker(
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

    private func renderGeneratedNativeImportCall(
        generated: BridgeGeneration.GeneratedNativeImport,
        effects: Core.Effects
    ) -> String {
        let target: String
        switch generated.dispatch {
        case .globalFunction:
            target = escapedSwiftIdentifier(generated.baseName)
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
        case .staticGetter:
            let owner = generated.ownerType!.split(separator: ".").map {
                escapedSwiftIdentifier(String($0))
            }.joined(separator: ".")
            return owner + "." + escapedSwiftIdentifier(generated.baseName)
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
            return "argument0." + escapedSwiftIdentifier(generated.baseName)
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
        let direct = (effects.mayThrow ? "try " : "") + "\(target)(\(arguments))"
        return direct
    }

    private func renderMainActorCall(_ directCall: String, effects: Core.Effects) -> String {
        guard effects.requiresMainActor else { return directCall }
        return """
        try context.withMainActor {
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
        type: Bytecode.ValueType
    ) -> String {
        if type == .void {
            return "{ value in try Runtime.BridgeValueCodec.decodeVoid(value); return () }"
        }
        return """
        { value in
            guard let value else {
                throw VM.RuntimeTrap.typeMismatch(expected: \(render(type)), actual: nil)
            }
            return \(renderDecode(expression: "value", shape: shape, type: type))
        }
        """
    }

    private func renderEncode(
        expression: String,
        shape: SwiftTypeShape,
        type: Bytecode.ValueType,
        nativeCatalog: String,
        inputEncoder: String? = nil
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
        case let (.named, .native(typeID)):
            if let inputEncoder {
                return "try \(inputEncoder).encodeNative(\(expression), as: \(render(typeID)), "
                    + "catalog: \(nativeCatalog))"
            }
            return "try Runtime.BridgeValueCodec.encodeNative(\(expression), as: \(render(typeID)), "
                + "catalog: \(nativeCatalog))"
        case let (.optional(wrappedShape), .optional(wrappedType)):
            let encoded = renderEncode(
                expression: "wrapped",
                shape: wrappedShape,
                type: wrappedType,
                nativeCatalog: nativeCatalog,
                inputEncoder: inputEncoder
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
                inputEncoder: inputEncoder
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
                inputEncoder: inputEncoder
            )
            let encodedValue = renderEncode(
                expression: "value",
                shape: valueShape,
                type: valueType,
                nativeCatalog: nativeCatalog,
                inputEncoder: inputEncoder
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
        case let (.tuple(shapes), .tuple(types)):
            let values = zip(shapes, types).enumerated().map { offset, pair in
                renderEncode(
                    expression: "(\(expression)).\(offset)",
                    shape: pair.0,
                    type: pair.1,
                    nativeCatalog: nativeCatalog,
                    inputEncoder: inputEncoder
                )
            }
            if let inputEncoder {
                return "try \(inputEncoder).encodeTuple(count: \(values.count)) { "
                    + "\(renderArray(values, indentation: 8)) }"
            }
            return "try Runtime.BridgeValueCodec.encodeTuple(\(renderArray(values, indentation: 8)))"
        case (.named, .void):
            return "try Runtime.BridgeValueCodec.encodeVoid(\(expression))"
        default:
            preconditionFailure("validated bridge type cannot reach an unsupported encoder")
        }
    }

    private func renderDecode(
        expression: String,
        shape: SwiftTypeShape,
        type: Bytecode.ValueType
    ) -> String {
        switch (shape, type) {
        case (.named, .any):
            return "try Runtime.BridgeValueCodec.decodeAny(\(expression))"
        case let (.named(name), .bool), let (.named(name), .integer),
             let (.named(name), .float), let (.named(name), .string):
            return "try Runtime.BridgeValueCodec.decode(\(expression), as: \(name).self)"
        case let (.named(name), .native(typeID)):
            return "try Runtime.BridgeValueCodec.decodeNative(\(expression), as: \(name).self, "
                + "typeID: \(render(typeID)))"
        case let (.optional(wrappedShape), .optional(wrappedType)):
            return "try Runtime.BridgeValueCodec.decodeOptional(\(expression)) { wrapped in "
                + "\(renderDecode(expression: "wrapped", shape: wrappedShape, type: wrappedType)) }"
        case let (.array(elementShape), .array(elementType)):
            let decoded = renderDecode(
                expression: "element",
                shape: elementShape,
                type: elementType
            )
            return "try Runtime.BridgeValueCodec.decodeArray(\(expression), elementType: "
                + "\(render(elementType))) { element in \(decoded) }"
        case let (.dictionary(keyShape, valueShape), .dictionary(keyType, valueType)):
            let decodedKey = renderDecode(
                expression: "key",
                shape: keyShape,
                type: keyType
            )
            let decodedValue = renderDecode(
                expression: "value",
                shape: valueShape,
                type: valueType
            )
            return "try Runtime.BridgeValueCodec.decodeDictionary(\(expression), keyType: "
                + "\(render(keyType)), valueType: \(render(valueType)), "
                + "decodeKey: { key in \(decodedKey) }, "
                + "decodeValue: { value in \(decodedValue) })"
        case let (.tuple(shapes), .tuple(types)):
            let temporary = "tuple_\(Core.Digest.sha256(expression).hex.prefix(8))"
            let values = zip(shapes, types).enumerated().map { offset, pair in
                renderDecode(
                    expression: "\(temporary)[\(offset)]",
                    shape: pair.0,
                    type: pair.1
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
        guard binding.invokerExpression == expectedExpression,
              record.silMangledNames.contains(generated.declarationMangledName),
              isSafeLogicalPath(generated.sourceFileLogicalID),
              isValidSwiftIdentifier(generated.baseName),
              generated.parameterSwiftTypes.count == record.parameterTypes.count,
              !isReceiverDispatch(generated.dispatch) || !record.parameterTypes.isEmpty,
              generated.argumentLabels.count == record.parameterTypes.count
                - (isReceiverDispatch(generated.dispatch) ? 1 : 0),
              generated.argumentLabels.allSatisfy({
                  $0 == "_" || isValidSwiftIdentifier($0)
              }),
              !record.effects.isAsync,
              record.capability == .nativeImportsV1,
              record.contract.domain == .application,
              record.contract.execution.deadlineMode == .bounded
        else {
            throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
        }
        switch generated.dispatch {
        case .globalFunction:
            guard generated.ownerType == nil,
                  record.contract.kind == .globalFunction,
                  record.parameterTypes.allSatisfy(isGeneratedValueType),
                  isGeneratedResultType(record.resultType)
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .initializer:
            guard record.contract.kind == .initializer,
                  let owner = generated.ownerType,
                  generated.baseName == "init",
                  isValidGeneratedSwiftTypeSpelling(owner),
                  record.parameterTypes.allSatisfy(isGeneratedValueType),
                  isNativeType(record.resultType),
                  generated.resultSwiftType == owner
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .staticMethod:
            guard record.contract.kind == .staticMethod,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  record.parameterTypes.allSatisfy(isGeneratedValueType),
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
        case .staticGetter:
            guard record.contract.kind == .staticGetter,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  generated.argumentLabels.isEmpty,
                  generated.parameterSwiftTypes.isEmpty,
                  record.parameterTypes.isEmpty,
                  record.resultType != .void,
                  isGeneratedValueType(record.resultType)
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .staticSetter:
            guard record.contract.kind == .staticSetter,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  generated.argumentLabels == ["_"],
                  record.parameterTypes.count == 1,
                  isGeneratedValueType(record.parameterTypes[0]),
                  record.resultType == .void,
                  generated.resultSwiftType == "Swift.Void"
            else {
                throw BridgeGeneration.Error.nativeImportBindingMismatch(binding.id)
            }
        case .instanceMethod:
            guard record.contract.kind == .instanceMethod,
                  let owner = generated.ownerType,
                  isValidGeneratedSwiftTypeSpelling(owner),
                  record.parameterTypes.dropLast().allSatisfy(isGeneratedValueType),
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
                  isGeneratedValueType(record.resultType)
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
                  isGeneratedValueType(record.parameterTypes[0]),
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
                  isGeneratedValueType(record.parameterTypes[0]),
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
             .staticGetter, .staticSetter: false
        }
    }

    private func isGeneratedValueType(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .bool, .integer, .float, .string, .any, .native:
            true
        case let .array(element), let .optional(element):
            isGeneratedValueType(element)
        case let .dictionary(key, value):
            isGeneratedDictionaryKey(key) && isGeneratedValueType(value)
        case let .tuple(elements):
            !elements.isEmpty && elements.allSatisfy(isGeneratedValueType)
        case .void, .never, .local, .error, .address, .closure:
            false
        }
    }

    private func isGeneratedResultType(_ type: Bytecode.ValueType) -> Bool {
        type == .void || isGeneratedValueType(type)
    }

    private func isNativeType(_ type: Bytecode.ValueType) -> Bool {
        if case .native = type { return true }
        return false
    }

    private func isGeneratedDictionaryKey(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .bool, .integer, .string: true
        default: false
        }
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
        return """
            public static func makeShellInterface() throws -> Verification.ShellInterface {
                try Verification.ShellInterface(
                    interfaceHash: interfaceHash,
                    compatibility: \(render(archive.compatibility)),
                    capabilities: \(renderCapabilities(archive.capabilities)),
                    entries: \(renderArray(entries, indentation: 20)),
                    imports: \(renderArray(imports, indentation: 20)),
                    types: \(renderArray(types, indentation: 20))
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
        types: [BridgeGeneration.NativeTypeBinding]
    ) -> String {
        let importExpressions = imports.sorted(by: { $0.id < $1.id }).map(\.invokerExpression)
        let typeExpressions = types.sorted(by: { $0.id.rawValue < $1.id.rawValue })
            .map(\.operationsExpression)
        return """
            public static func makeNativeCatalog() throws -> VM.NativeCatalog {
                try VM.NativeCatalog(\(renderArray(importExpressions, indentation: 16)))
            }

            public static func makeNativeTypeCatalog() throws -> VM.NativeTypeCatalog {
                try VM.NativeTypeCatalog(\(renderArray(typeExpressions, indentation: 16)))
            }

            public static func makeRuntime(
                registry: Runtime.GenerationRegistry = .init(),
                observer: any Runtime.Observing = Runtime.NoopObserver()
            ) throws -> Runtime.Engine {
                let nativeCatalog = try makeNativeCatalog()
                let nativeTypeCatalog = try makeNativeTypeCatalog()
                return Runtime.Engine(
                    registry: registry,
                    originals: try makeOriginalCatalog(nativeTypeCatalog: nativeTypeCatalog),
                    shellInterfaceHash: interfaceHash,
                    nativeCatalog: nativeCatalog,
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
        """
        Core.NativeImportContract(
            kind: .\(contract.kind.rawValue),
            domain: Core.NativeImportDomain(rawValue: \(quoted(contract.domain.rawValue))),
            access: .\(contract.access.rawValue),
            execution: Core.NativeImportExecutionPolicy(
                deadlineMode: .\(contract.execution.deadlineMode.rawValue),
                maximumDurationMicroseconds: \(contract.execution.maximumDurationMicroseconds),
                allowsMainThread: \(contract.execution.allowsMainThread)
            )
        )
        """
    }

    private func render(_ effects: Core.Effects) -> String {
        "Core.Effects(mayThrow: \(effects.mayThrow), mayAllocate: \(effects.mayAllocate), "
            + "hasExternalSideEffects: \(effects.hasExternalSideEffects), "
            + "requiresMainActor: \(effects.requiresMainActor), "
            + "isAsync: \(effects.isAsync))"
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
        case let .native(id): ".native(Core.TypeID(rawValue: \(render(id.rawValue))))"
        case let .local(key):
            ".local(Bytecode.LocalTypeKey(rawValue: \(quoted(key.rawValue))))"
        case .error: ".error"
        case let .address(pointee): ".address(\(render(pointee)))"
        case let .closure(signature):
            ".closure(Bytecode.ClosureSignature(parameters: "
                + "\(renderValueTypes(signature.parameters)), result: \(render(signature.result)), "
                + "effects: \(render(signature.effects))))"
        case let .tuple(elements): ".tuple(\(renderValueTypes(elements)))"
        case let .optional(wrapped): ".optional(\(render(wrapped)))"
        }
    }

    private func renderValueTypes(_ types: [Bytecode.ValueType]) -> String {
        "[\(types.map(render).joined(separator: ", "))]"
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
    guard let first = value.first, first == "_" || first.isLetter else {
        return false
    }
    return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidModuleName
    case incompleteRootSet
    case rootDoesNotMatchArchive(Core.FunctionKey)
    case invalidRoot(Core.FunctionKey)
    case invalidSwiftType(String)
    case swiftTypeMismatch(Core.FunctionKey)
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
        case let .unsupportedIsolatedRoot(key):
            "bridge root \(key) uses an unsupported actor isolation; v1 accepts MainActor only for synchronous or non-suspending async entries"
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
