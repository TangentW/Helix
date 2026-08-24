import HelixBytecode
import HelixCore
import HelixInterface

extension BridgeGeneration {
/// Swift source fragments used to install permanent Bridge routing in an
/// original declaration body. Some Swift declarations cannot safely rely on
/// dynamic-replacement chaining, so the Shell source owns their dispatch site.
public struct SourceBodyTransform: Sendable {
    public enum Body: Sendable {
        /// Replaces the complete body with generated statements.
        case replacement(String)
        /// Wraps the exact original statements between generated fragments.
        /// The materializer restores their logical source location when it
        /// inserts them, preserving diagnostics and magic-literal behavior.
        case preservingOriginal(prefix: String, suffix: String)

        package func render(
            originalBody: String,
            logicalPath: String,
            openingBraceLine: Int,
            openingBraceColumn: Int
        ) -> String {
            switch self {
            case let .replacement(replacement):
                replacement
            case let .preservingOriginal(prefix, suffix):
                prefix
                    + BridgeGeneration.SourceBodyTransform.sourceLocatedBody(
                        originalBody,
                        logicalPath: logicalPath,
                        openingBraceLine: openingBraceLine,
                        openingBraceColumn: openingBraceColumn
                    )
                    + suffix
            }
        }
    }

    public var bodies: [Core.FunctionKey: Body]
    public var supplementalDeclarations: [String: String]

    public init(
        bodies: [Core.FunctionKey: Body],
        supplementalDeclarations: [String: String]
    ) {
        self.bodies = bodies
        self.supplementalDeclarations = supplementalDeclarations
    }

    /// Re-emits body text at its original logical line and byte column. Swift
    /// reports columns in UTF-8 bytes; aligning same-line bodies keeps
    /// `#column` exact without rewriting user source expressions.
    package static func sourceLocatedBody(
        _ originalBody: String,
        logicalPath: String,
        openingBraceLine: Int,
        openingBraceColumn: Int,
        closesSourceLocation: Bool = true
    ) -> String {
        let startsOnFollowingLine = originalBody.utf8.first.map {
            $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r")
        } ?? true
        let alignment = startsOnFollowingLine
            ? "" : String(repeating: " ", count: max(0, openingBraceColumn))
        return "#sourceLocation(file: \(String(reflecting: logicalPath)), "
            + "line: \(openingBraceLine))\n"
            + alignment + originalBody
            + (closesSourceLocation ? "\n#sourceLocation()\n" : "\n")
    }
}
}

extension BridgeGeneration.Generator {
    /// Renders every Bridge that must live in its original source context.
    /// Property observers use a complete replacement because they have no
    /// source-callable original. Async functions retain their exact original
    /// statements inside an immediately invoked nonescaping async closure;
    /// this avoids the Swift runtime's recursive async previous-replacement
    /// thunk while preserving `self`, `super`, and implicit-return semantics.
    public func renderSourceBodyTransform(
        archive: InterfaceArchive.Archive,
        roots: [BridgeGeneration.Root]
    ) throws -> BridgeGeneration.SourceBodyTransform {
        try archive.validate()
        let sourceBodyRoots = roots.filter { $0.installation == .sourceBody }
        guard !sourceBodyRoots.isEmpty else {
            return .init(bodies: [:], supplementalDeclarations: [:])
        }
        guard Set(sourceBodyRoots.map(\.functionKey)).count
                == sourceBodyRoots.count
        else {
            throw BridgeGeneration.Error.incompleteRootSet
        }

        let records = Dictionary(
            uniqueKeysWithValues: archive.functions.map { ($0.key, $0) }
        )
        let frozenValueTypes = Dictionary(
            uniqueKeysWithValues: archive.frozenValueTypes.map { ($0.key, $0) }
        )
        for root in sourceBodyRoots {
            guard let record = records[root.functionKey],
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

        let bodies = try Dictionary(uniqueKeysWithValues: sourceBodyRoots.map {
            root -> (Core.FunctionKey, BridgeGeneration.SourceBodyTransform.Body) in
            guard let record = records[root.functionKey] else {
                throw BridgeGeneration.Error.rootDoesNotMatchArchive(root.functionKey)
            }
            if root.sourceDeclaration.kind == .propertyObservers {
                let statements = try renderReplacementBody(
                    root,
                    record: record,
                    frozenValueTypes: frozenValueTypes
                )
                return (
                    root.functionKey,
                    .replacement("{\n\(indentSourceBody(statements, spaces: 4))\n}")
                )
            }
            guard record.effects.isAsync,
                  root.sourceDeclaration.kind == .function,
                  root.memberRole == .functionBody
            else {
                throw BridgeGeneration.Error.invalidRoot(root.functionKey)
            }
            return (
                root.functionKey,
                try renderAsyncSourceBodyTemplate(
                    root,
                    record: record,
                    frozenValueTypes: frozenValueTypes
                )
            )
        })
        let requiredFrozenValues = try requiredFrozenValueTypes(
            for: sourceBodyRoots,
            records: records,
            frozenValueTypes: frozenValueTypes
        )
        let frozenValuesBySource = Dictionary(
            grouping: requiredFrozenValues,
            by: \.sourceFileLogicalID
        )
        let sourceFileLogicalIDs = Set(sourceBodyRoots.map(\.sourceFileLogicalID))
            .union(frozenValuesBySource.keys)
        let supplementalDeclarations = try Dictionary(
            uniqueKeysWithValues: sourceFileLogicalIDs.sorted().map {
                sourceFileLogicalID in
                let codecs = try (frozenValuesBySource[sourceFileLogicalID] ?? [])
                    .sorted(by: { $0.key < $1.key }).map {
                        try renderFrozenValueCodec(
                            $0,
                            frozenValueTypes: frozenValueTypes
                        )
                    }
                let codecContainer = codecs.isEmpty ? "" : """
                    enum \(BridgeGeneration.GeneratedNativeType.groupName(
                        sourceFileLogicalID: sourceFileLogicalID
                    )) {
                    \(indentSourceBody(codecs.joined(separator: "\n\n"), spaces: 4))
                    }
                    """
                let source = [
                    "// Generated by Helix inside the original module. Do not edit.",
                    BridgeGeneration.RuntimeImports.production,
                    codecContainer,
                ].filter { !$0.isEmpty }.joined(separator: "\n\n")
                return (sourceFileLogicalID, source)
            }
        )
        return .init(
            bodies: bodies,
            supplementalDeclarations: supplementalDeclarations
        )
    }

    /// Codecs must remain in each value's defining source file so private
    /// stored state stays source-accessible. Include the full transitive value
    /// graph even when a dependency's file has no transformed root of its own.
    private func requiredFrozenValueTypes(
        for roots: [BridgeGeneration.Root],
        records: [Core.FunctionKey: InterfaceArchive.FunctionRecord],
        frozenValueTypes: [
            Bytecode.LocalTypeKey: InterfaceArchive.FrozenValueTypeRecord
        ]
    ) throws -> [InterfaceArchive.FrozenValueTypeRecord] {
        var required = Set<Bytecode.LocalTypeKey>()
        func collect(_ type: Bytecode.ValueType) throws {
            switch type {
            case let .local(key):
                guard required.insert(key).inserted else { return }
                guard let record = frozenValueTypes[key] else {
                    throw BridgeGeneration.Error.frozenValueTypeMismatch(key)
                }
                switch record.kind {
                case let .structure(fields):
                    for field in fields { try collect(field.type) }
                case let .enumeration(cases):
                    for payload in cases.compactMap(\.payloadType) {
                        try collect(payload)
                    }
                }
            case let .array(element), let .optional(element), let .set(element):
                try collect(element)
            case let .dictionary(key, value):
                try collect(key)
                try collect(value)
            case let .tuple(elements):
                for element in elements { try collect(element) }
            default:
                break
            }
        }
        for root in roots {
            guard let record = records[root.functionKey] else {
                throw BridgeGeneration.Error.rootDoesNotMatchArchive(root.functionKey)
            }
            for type in record.parameterTypes + [record.resultType] {
                try collect(type)
            }
        }
        return required.compactMap { frozenValueTypes[$0] }
    }

    private func indentSourceBody(_ value: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }
}
