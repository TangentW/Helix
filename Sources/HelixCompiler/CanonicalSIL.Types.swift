import Foundation
import HelixBytecode
import HelixCore
import HelixInterface

extension CanonicalSIL {
public struct TypeEnvironment: Sendable {
    indirect enum StructFieldPlan: Sendable {
        case parameter(index: Int, type: Bytecode.ValueType)
        case tuple(
            type: Bytecode.ValueType,
            elements: [StructFieldPlan]
        )
    }

    struct StructFactory: Sendable {
        var key: Bytecode.LocalTypeKey
        var fieldPlans: [StructFieldPlan]
        var physicalParameterTypes: [Bytecode.ValueType]
    }

    enum ZeroSizedAggregate: Sendable {
        case tuple([Bytecode.ValueType])
        case structure(
            key: Bytecode.LocalTypeKey,
            fields: [Bytecode.LocalStructField]
        )
    }

    private struct RawField: Sendable {
        var name: String
        var type: String
        var hasImmutableDeclarationInitializer: Bool
    }

    private struct RawEnumCase: Sendable {
        var name: String
        var associatedTypes: [String]
        var hasAvailabilityConstraint: Bool
    }

    private struct RawHostedMethod: Equatable, Sendable {
        var name: String
        var selector: String
        var abi: Bytecode.HostedMethodABI
    }

    private enum RawKind: Sendable {
        case structure([RawField])
        case enumeration([RawEnumCase])
        case `class`(
            fields: [RawField],
            superclass: String?,
            isFinal: Bool,
            hostedMethods: [RawHostedMethod]
        )
    }

    private struct RawDefinition: Sendable {
        var key: Bytecode.LocalTypeKey
        var parentScope: String?
        var kind: RawKind
        var conformsToError: Bool
        var isCopyable: Bool
        var hasUnparsedInstanceStorage: Bool
    }

    private struct RawGenericDefinition: Sendable {
        var key: Bytecode.LocalTypeKey
        var parentScope: String?
        var parameters: [String]
        var requirements: [CanonicalSIL.GenericSignature.Requirement]
        var kind: RawKind
        var conformsToError: Bool
    }

    private struct NominalHeader {
        var isFinal: Bool
        var declaredAccess: String?
        var kind: String
        var name: String
        var conformances: [String]
        var requirements: String?
    }

    private struct DefinitionInventory: Sendable {
        var concrete: [Bytecode.LocalTypeKey: RawDefinition]
        var generic: [Bytecode.LocalTypeKey: RawGenericDefinition]
    }

    /// An opaque declaration summary can be checked before conformance or
    /// function parsing succeeds. It does not authorize layouts by itself.
    struct DeclarationSummary: Sendable {
        private let inventory: DefinitionInventory
        private let hasErrorBoundary: Bool

        init(text: String) throws {
            inventory = try TypeEnvironment.extractDefinitions(text)
            hasErrorBoundary = text.contains("checked_cast_addr_br")
                || text.contains("Result<") || TypeEnvironment.hasClosureErrorBoundary(in: text)
        }

        func environment(functions: [CanonicalSIL.Function],
            conformances: CanonicalSIL.ProtocolConformance.Environment
        ) throws -> TypeEnvironment {
            try TypeEnvironment(inventory: inventory, hasErrorBoundary: hasErrorBoundary,
                functions: functions, conformances: conformances)
        }
    }

    private struct DefinitionParser {
        let lines: [String]
        var index = 0
        var definitions: [Bytecode.LocalTypeKey: RawDefinition] = [:]
        var genericDefinitions: [
            Bytecode.LocalTypeKey: RawGenericDefinition
        ] = [:]
        var fileScopes: [Bytecode.LocalTypeKey: Bool] = [:]
        var declarationEvidence: [Bytecode.LocalTypeKey: [String]] = [:]
        var ambiguousNames = Set<Bytecode.LocalTypeKey>()

        // Canonical SIL starts with a declaration summary before function
        // bodies. Walk that brace tree so nested namespace identities remain
        // exact without treating arbitrary SIL text as a Swift type parser.
        mutating func parse() throws -> DefinitionInventory {
            try scanScope(parentScope: nil, stopsAtClosingBrace: false)
            removeDefinitionsWithImplicitOuterArchetypes()
            // The textual SIL summary does not carry private discriminators.
            // Keep unrelated definitions usable but never guess these layouts.
            func isUnambiguous(_ key: Bytecode.LocalTypeKey) -> Bool {
                var name: String? = key.rawValue
                while let current = name {
                    if ambiguousNames.contains(.init(rawValue: current)) { return false }
                    name = TypeEnvironment.parentScope(of: current)
                }
                return true
            }
            definitions = definitions.filter { isUnambiguous($0.key) }
            genericDefinitions = genericDefinitions.filter { isUnambiguous($0.key) }
            return .init(
                concrete: definitions,
                generic: genericDefinitions
            )
        }

        private mutating func removeDefinitionsWithImplicitOuterArchetypes() {
            let genericScopes = Set(
                genericDefinitions.keys.map(\.rawValue)
            )
            func hasGenericAncestor(_ rawParent: String?) -> Bool {
                var parent = rawParent
                while let current = parent {
                    if genericScopes.contains(current) { return true }
                    parent = TypeEnvironment.parentScope(of: current)
                }
                return false
            }
            definitions = definitions.filter {
                !hasGenericAncestor($0.value.parentScope)
            }
            genericDefinitions = genericDefinitions.filter {
                !hasGenericAncestor($0.value.parentScope)
            }
        }

        private mutating func scanScope(
            parentScope: String?,
            stopsAtClosingBrace: Bool,
            defaultFileScope: Bool = false
        ) throws {
            while index < lines.count {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line == "}" {
                    guard stopsAtClosingBrace else {
                        index += 1
                        continue
                    }
                    index += 1
                    return
                }
                if let extended = TypeEnvironment.captures(
                    line,
                    pattern: TypeEnvironment.extensionHeaderPattern
                ) {
                    let scope = TypeEnvironment.qualified(
                        extended[0],
                        relativeTo: parentScope
                    )
                    let fileScopedExtension = ["private", "fileprivate"].contains(
                        TypeEnvironment.declaredAccess(in: line) ?? "")
                    index += 1
                    try scanScope(parentScope: scope, stopsAtClosingBrace: true,
                                  defaultFileScope: fileScopedExtension)
                    continue
                }
                if let header = try TypeEnvironment.nominalHeader(in: line) {
                    try parseNominal(header, parentScope: parentScope, defaultFileScope: defaultFileScope)
                    continue
                }
                if TypeEnvironment.braceDelta(in: line) > 0 {
                    try skipBracedDeclaration()
                } else {
                    index += 1
                }
            }
            guard !stopsAtClosingBrace else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "unterminated declaration scope \(parentScope ?? "<module>")"
                )
            }
        }

        private mutating func parseNominal(
            _ header: NominalHeader,
            parentScope: String?,
            defaultFileScope: Bool = false
        ) throws {
            let shortName = header.name
            let declarationRequirements = header.requirements
            let generic = CanonicalSIL.SwiftTypeIdentity.genericType(
                CanonicalSIL.SwiftTypeIdentity.normalized(shortName)
            )
            let unqualifiedName = generic?.name ?? shortName
            let genericParameters = generic?.arguments ?? []
            guard genericParameters.allSatisfy(
                CanonicalSIL.GenericSignature.isParameter
            ), Set(genericParameters).count == genericParameters.count else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "nominal type \(shortName) has unsupported generic parameters"
                )
            }
            let name = TypeEnvironment.qualified(
                unqualifiedName,
                relativeTo: parentScope
            )
            let key = Bytecode.LocalTypeKey(rawValue: name)
            // Extension access is a default for immediate members. An explicit
            // member modifier overrides that default, unlike a private owner.
            let isFileScoped = (header.declaredAccess.map { ["private", "fileprivate"].contains($0) }
                ?? defaultFileScope) || parentScope.map {
                fileScopes[.init(rawValue: $0)] == true
            } == true
            let evidence = "SIL line \(index + 1): \(lines[index].trimmingCharacters(in: .whitespaces)); "
                + "parent=\(parentScope ?? "<file>"), declaredAccess=\(header.declaredAccess ?? "implicit"), "
                + "extensionDefaultFileScoped=\(defaultFileScope), effectiveFileScoped=\(isFileScoped)"
            if let existingScope = fileScopes[key] {
                guard existingScope && isFileScoped else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "duplicate nominal type \(name): \(declarationEvidence[key, default: []].joined(separator: "; ")); \(evidence)")
                }
                ambiguousNames.insert(key)
                definitions.removeValue(forKey: key)
                genericDefinitions.removeValue(forKey: key)
            }
            fileScopes[key] = isFileScoped
            declarationEvidence[key, default: []].append(evidence)
            var fields: [RawField] = []
            var hasUnparsedInstanceStorage = false
            var cases: [RawEnumCase] = []
            var caseNames = Set<String>()
            var pendingEnumCaseAvailability = false
            var hostedMethods: [RawHostedMethod] = []
            index += 1

            while index < lines.count {
                let member = lines[index].trimmingCharacters(in: .whitespaces)
                if member == "}" {
                    index += 1
                    guard !ambiguousNames.contains(key) else { return }
                    let conformances = header.conformances
                    // Existing non-final classes belong to the frozen Shell. A
                    // downloaded image can add only final logical classes, so
                    // do not accidentally reinterpret an ordinary app class as
                    // patch-local while the Shell is still being indexed.
                    if header.kind == "class", !header.isFinal {
                        return
                    }
                    let kind: RawKind
                    switch header.kind {
                    case "struct":
                        kind = .structure(fields)
                    case "enum":
                        kind = .enumeration(cases)
                    case "class":
                        let inherited = conformances.first
                        kind = .class(
                            fields: fields,
                            superclass: inherited,
                            isFinal: header.isFinal,
                            hostedMethods: hostedMethods
                        )
                    default:
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "unknown nominal declaration kind \(header.kind)"
                        )
                    }
                    let conformsToError = conformances.contains("Error")
                        || conformances.contains("Swift.Error")
                    let isCopyable = !conformances.contains("~Copyable")
                        && !conformances.contains("Swift.~Copyable")
                    if genericParameters.isEmpty {
                        let definition = RawDefinition(
                            key: key,
                            parentScope: TypeEnvironment.parentScope(of: name),
                            kind: kind,
                            conformsToError: conformsToError,
                            isCopyable: isCopyable,
                            hasUnparsedInstanceStorage:
                                hasUnparsedInstanceStorage
                        )
                        guard definitions.updateValue(
                            definition,
                            forKey: key
                        ) == nil, genericDefinitions[key] == nil else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "duplicate nominal type \(name)"
                            )
                        }
                    } else {
                        let clauseText = "<" + genericParameters.joined(
                            separator: ", "
                        ) + (declarationRequirements.map {
                            " where " + $0
                        } ?? "") + ">"
                        let clause: CanonicalSIL.GenericSignature.Clause
                        do {
                            clause = try CanonicalSIL.GenericSignature
                                .standaloneClause(clauseText)
                        } catch {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "generic nominal \(name) has an invalid signature"
                            )
                        }
                        let definition = RawGenericDefinition(
                            key: key,
                            parentScope: TypeEnvironment.parentScope(of: name),
                            parameters: clause.parameters,
                            requirements: clause.requirements,
                            kind: kind,
                            conformsToError: conformsToError
                        )
                        guard genericDefinitions.updateValue(
                            definition,
                            forKey: key
                        ) == nil, definitions[key] == nil else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "duplicate generic nominal type \(name)"
                            )
                        }
                    }
                    return
                }
                if let nested = try TypeEnvironment.nominalHeader(in: member) {
                    pendingEnumCaseAvailability = false
                    if genericParameters.isEmpty {
                        try parseNominal(nested, parentScope: name)
                    } else {
                        // Nested types of a generic context implicitly carry
                        // outer archetypes. Keep that distinct shape closed
                        // until it has an explicit frontend-backed model.
                        try skipBracedDeclaration()
                    }
                    continue
                }
                if header.kind == "struct" || header.kind == "class",
                   let field = TypeEnvironment.captures(
                    member,
                    pattern: TypeEnvironment.storedFieldPattern
                   ) {
                    fields.append(.init(
                        name: field[0],
                        type: field[1],
                        hasImmutableDeclarationInitializer:
                            member.contains("@_hasInitialValue")
                                && member.range(
                                    of: #"(?:^|\s)let(?:\s|$)"#,
                                    options: .regularExpression
                                ) != nil
                    ))
                } else if (header.kind == "struct" || header.kind == "class"),
                          member.contains("@_hasStorage"),
                          member.range(
                              of: #"(?:^|\s)(?:static|class)\s+(?:var|let)(?:\s|$)"#,
                              options: .regularExpression
                          ) == nil {
                    hasUnparsedInstanceStorage = true
                } else if header.kind == "class",
                          let method = TypeEnvironment.hostedMethodDeclaration(
                            in: member
                          ) {
                    hostedMethods.append(method)
                } else if header.kind == "enum",
                          let declarations = try TypeEnvironment
                            .enumCaseDeclarations(in: member) {
                    for var declaration in declarations {
                        declaration.hasAvailabilityConstraint =
                            pendingEnumCaseAvailability
                        guard caseNames.insert(declaration.name).inserted else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "duplicate enum case \(name).\(declaration.name)"
                            )
                        }
                        cases.append(declaration)
                    }
                }
                if header.kind == "enum" {
                    pendingEnumCaseAvailability = member.hasPrefix("@available(")
                }
                if TypeEnvironment.braceDelta(in: member) > 0 {
                    try skipBracedDeclaration()
                } else {
                    index += 1
                }
            }
            throw CanonicalSIL.LoweringError.malformedSIL(
                "unterminated nominal type \(name)"
            )
        }

        private mutating func skipBracedDeclaration() throws {
            var depth = 0
            repeat {
                guard index < lines.count else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "unterminated braced declaration"
                    )
                }
                depth += TypeEnvironment.braceDelta(in: lines[index])
                index += 1
            } while depth > 0
        }
    }

    private var rawDefinitions: [Bytecode.LocalTypeKey: RawDefinition]
    private var rawGenericDefinitions: [
        Bytecode.LocalTypeKey: RawGenericDefinition
    ]
    private var protocolConformances: CanonicalSIL.ProtocolConformance
        .Environment?
    private var factoryCandidates: [CanonicalSIL.Function]
    private var structFactories: [String: StructFactory]
    private var classAllocators: [String: Bytecode.LocalTypeKey]
    private var requiresTypedErrors: Bool
    private var nativeTypes: [String: Core.TypeID]
    private var canonicalNativeTypes: [String: Core.TypeID]
    private var nativeAliasCandidates: [String: Set<Core.TypeID>]
    private var nativeTypeKinds: [Core.TypeID: InterfaceArchive.TypeKind]
    private var mainActorNativeTypes: Set<Core.TypeID>

    struct HostedMethodCandidate: Sendable {
        var typeKey: Bytecode.LocalTypeKey
        var methodIndex: UInt32
        var selector: String
        var abi: Bytecode.HostedMethodABI
        var symbol: String
        var function: CanonicalSIL.Function
    }

    struct HostedMethodContext: Equatable, Sendable {
        var typeKey: Bytecode.LocalTypeKey
        var methodIndex: UInt32
        var selector: String
        var abi: Bytecode.HostedMethodABI
    }

    public static let empty = Self()

    public init() {
        rawDefinitions = [:]
        rawGenericDefinitions = [:]
        protocolConformances = nil
        factoryCandidates = []
        structFactories = [:]
        classAllocators = [:]
        requiresTypedErrors = false
        nativeTypes = [:]
        canonicalNativeTypes = [:]
        nativeAliasCandidates = [:]
        nativeTypeKinds = [:]
        mainActorNativeTypes = []
    }

    init(
        text: String,
        functions: [CanonicalSIL.Function],
        protocolConformances: CanonicalSIL.ProtocolConformance.Environment?
            = nil
    ) throws {
        self = try DeclarationSummary(text: text).environment(functions: functions,
            conformances: protocolConformances ?? CanonicalSIL.ProtocolConformance.Environment(text: text))
    }

    private init(inventory: DefinitionInventory, hasErrorBoundary: Bool,
        functions: [CanonicalSIL.Function], conformances: CanonicalSIL.ProtocolConformance.Environment
    ) throws {
        self.protocolConformances = conformances
        // A witness table can expose an erased local type name absent from the
        // declaration summary. Do not reuse an unrelated same-spelled layout.
        rawDefinitions = inventory.concrete.filter { !conformances.isAmbiguousType($0.key.rawValue) }
        rawGenericDefinitions = inventory.generic.filter { !conformances.isAmbiguousType($0.key.rawValue) }
        factoryCandidates = functions
        structFactories = [:]
        classAllocators = [:]
        nativeTypes = [:]
        canonicalNativeTypes = [:]
        nativeAliasCandidates = [:]
        nativeTypeKinds = [:]
        mainActorNativeTypes = []
        // Payload-free throws use the lightweight String error representation.
        // Typed storage is enabled only when SIL semantics, a local declaration,
        // or a closure boundary must preserve the Error existential identity.
        requiresTypedErrors = hasErrorBoundary
            || rawDefinitions.values.contains(where: Self.hasStoredErrorPayload)
            || rawGenericDefinitions.values.contains(
                where: Self.hasStoredErrorPayload
            )
        // Native aliases arrive from the frozen Shell after textual SIL is
        // parsed. Build everything whose field graph is already resolvable,
        // then rebuild strictly once those aliases have been injected.
        try rebuildFactoryTables(allowingUnresolvedTypes: true)
    }

    /// Reuses declarations from the same SIL text after closed-dispatch rewriting.
    /// Factory detection must see the rewritten bodies; layout and error-storage
    /// facts still come from the original, already validated declaration text.
    func replacingFactoryCandidates(_ functions: [CanonicalSIL.Function]) throws -> Self {
        var result = self
        result.factoryCandidates = functions
        try result.rebuildFactoryTables(allowingUnresolvedTypes: true)
        return result
    }

    /// Returns an environment that resolves the exact native types frozen in
    /// the target Shell. Exact compiler-proven aliases and unambiguous
    /// module-relative forms are accepted. Ambiguous shorthand is omitted so
    /// nested SDK types with the same terminal name retain their identities.
    public func includingNativeTypes(
        _ records: [String: Core.TypeID],
        aliases: [String: Set<Core.TypeID>] = [:],
        kinds: [Core.TypeID: InterfaceArchive.TypeKind] = [:],
        requiresMainActor: Set<Core.TypeID> = []
    ) throws -> Self {
        let frozenTypeIDs = Set(records.values)
        guard Set(kinds.keys).isSubset(of: frozenTypeIDs),
              requiresMainActor.isSubset(of: frozenTypeIDs),
              aliases.allSatisfy({ alias, ids in
                  !alias.isEmpty
                      && alias.utf8.count <= 1_024
                      && alias == alias.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      )
                      && !ids.isEmpty
                      && ids.isSubset(of: frozenTypeIDs)
              })
        else {
            throw CanonicalSIL.LoweringError.invalidCallTable(
                "native type metadata references an unknown TypeID"
            )
        }
        var result = self
        result.mainActorNativeTypes.formUnion(requiresMainActor)
        for (id, kind) in kinds {
            if let existing = result.nativeTypeKinds[id], existing != kind {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "native TypeID \(id) has conflicting kind metadata"
                )
            }
            result.nativeTypeKinds[id] = kind
        }
        for (canonicalName, id) in records.sorted(by: { $0.key < $1.key }) {
            let localMatches = result.localKeys(matchingNativeName: canonicalName)
            guard localMatches.count <= 1 else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "native type \(canonicalName) ambiguously matches local declarations"
                )
            }
            if let local = localMatches.first {
                result.rawDefinitions.removeValue(forKey: local)
                result.rawGenericDefinitions.removeValue(forKey: local)
                result.structFactories = result.structFactories.filter {
                    $0.value.key != local
                }
                result.classAllocators = result.classAllocators.filter { $0.value != local }
            }
            guard !canonicalName.isEmpty,
                  result.localKey(for: canonicalName) == nil
            else {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "native type \(canonicalName) conflicts with a local type"
                )
            }
            if let existing = result.canonicalNativeTypes[canonicalName],
               existing != id {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "native type \(canonicalName) resolves to multiple TypeIDs"
                )
            }
            result.canonicalNativeTypes[canonicalName] = id
        }
        for (alias, ids) in aliases {
            result.nativeAliasCandidates[alias, default: []].formUnion(ids)
        }
        result.rebuildNativeTypeAliases()
        try result.rebuildFactoryTables(allowingUnresolvedTypes: false)
        return result
    }

    private mutating func rebuildNativeTypeAliases() {
        nativeTypes = canonicalNativeTypes
        var candidates = nativeAliasCandidates
        for (canonicalName, id) in canonicalNativeTypes {
            guard let separator = canonicalName.firstIndex(of: ".") else {
                continue
            }
            let alias = String(canonicalName[canonicalName.index(after: separator)...])
            guard !alias.isEmpty, alias != canonicalName else { continue }
            candidates[alias, default: []].insert(id)
        }
        for (alias, ids) in candidates where ids.count == 1 {
            guard let id = ids.first,
                  localKey(for: alias) == nil,
                  nativeTypes[alias].map({ $0 == id }) ?? true
            else { continue }
            nativeTypes[alias] = id
        }
    }

    private mutating func rebuildFactoryTables(
        allowingUnresolvedTypes: Bool
    ) throws {
        structFactories.removeAll(keepingCapacity: true)
        classAllocators.removeAll(keepingCapacity: true)
        for function in factoryCandidates {
            do {
                if let factory = try detectStructFactory(function) {
                    structFactories[function.mangledName] = factory
                }
            } catch {
                guard allowingUnresolvedTypes,
                      let loweringError = error as? CanonicalSIL.LoweringError,
                      case .unsupportedType = loweringError
                else { throw error }
            }
            if let key = try detectClassAllocator(function) {
                classAllocators[function.mangledName] = key
            }
        }
    }

    func containsReferenceNativeValue(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case let .native(id):
            nativeTypeKinds[id] == .reference
        case let .optional(wrapped):
            containsReferenceNativeValue(wrapped)
        case let .mutableCell(pointee):
            containsReferenceNativeValue(pointee)
        case let .nonOwningReference(_, pointee):
            containsReferenceNativeValue(pointee)
        case let .arrayState(_, element):
            containsReferenceNativeValue(element)
        case let .dictionaryState(key, value):
            containsReferenceNativeValue(key)
                || containsReferenceNativeValue(value)
        case let .tuple(elements):
            elements.contains(where: containsReferenceNativeValue)
        case .array, .dictionary, .set:
            // Objective-C collection parameters are reference bridges. This
            // matters only when their element graph contains native handles.
            true
        case .void, .never, .bool, .integer, .float, .string, .any, .local,
             .error, .address, .closure:
            false
        }
    }

    /// Clang-imported value types are physically passed without ARC ownership
    /// markers even though the VM represents them with managed native handles.
    /// An absent SIL marker therefore means +0, not a consuming transfer.
    func isNonreferenceNativeValue(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case let .native(id):
            guard let kind = nativeTypeKinds[id] else { return false }
            return kind != .reference
        case let .optional(wrapped):
            return isNonreferenceNativeValue(wrapped)
        default:
            return false
        }
    }

    /// Whether a represented value can keep a strong class identity alive.
    /// This is separate from native-handle linearity: Swift-managed local and
    /// aggregate values are copyable, but their SIL ownership endpoints remain
    /// observable through weak and unowned references.
    func containsOwningReference(_ type: Bytecode.ValueType) -> Bool {
        var visiting = Set<Bytecode.LocalTypeKey>()

        func visit(_ type: Bytecode.ValueType) -> Bool {
            switch type {
            case let .native(id):
                return nativeTypeKinds[id] == .reference
            case let .local(key):
                if isClass(key) { return true }
                guard visiting.insert(key).inserted,
                      let definition = try? definition(for: key)
                else { return false }
                defer { visiting.remove(key) }
                switch definition.kind {
                case let .structure(fields):
                    return fields.contains { visit($0.type) }
                case let .enumeration(cases):
                    return cases.contains { item in
                        item.payloadType.map(visit) == true
                    }
                case .class:
                    return true
                }
            case let .optional(wrapped), let .array(wrapped),
                 let .set(wrapped), let .arrayState(_, wrapped):
                return visit(wrapped)
            case let .dictionary(key, value),
                 let .dictionaryState(key, value):
                return visit(key) || visit(value)
            case let .tuple(elements):
                return elements.contains(where: visit)
            case .any, .error:
                // Their concrete payload is dynamic, so conservatively keep
                // every ownership transfer explicit even when one invocation
                // happens to contain no class reference.
                return true
            case .void, .never, .bool, .integer, .float, .string, .address,
                 .nonOwningReference, .mutableCell, .closure:
                // Capture cells and closures have dedicated lifetime
                // protocols; this predicate covers ordinary value ownership
                // and dynamically typed payload containers.
                return false
            }
        }

        return visit(type)
    }

    /// An owned opened-existential receiver is copied out of its erased
    /// container without a runtime TypeOps lookup. Admit only recursively
    /// value-copyable shapes for which that copy has no hidden linear owner.
    func isSafelyCopyableExistentialReceiver(
        _ type: Bytecode.ValueType
    ) -> Bool {
        var visiting = Set<Bytecode.LocalTypeKey>()

        func visit(_ type: Bytecode.ValueType) -> Bool {
            switch type {
            case .void, .never, .bool, .integer, .float, .string:
                return true
            case let .optional(wrapped), let .array(wrapped), let .set(wrapped):
                return visit(wrapped)
            case let .dictionary(key, value):
                return visit(key) && visit(value)
            case let .tuple(elements):
                return elements.allSatisfy(visit)
            case let .local(key):
                guard visiting.insert(key).inserted,
                      let definition = try? definition(for: key)
                else { return false }
                defer { visiting.remove(key) }
                switch definition.kind {
                case let .structure(fields):
                    return fields.allSatisfy { visit($0.type) }
                case let .enumeration(cases):
                    return cases.allSatisfy {
                        $0.payloadType.map(visit) != false
                    }
                case .class:
                    return false
                }
            case .any, .native, .error, .address, .mutableCell,
                 .nonOwningReference, .arrayState, .dictionaryState, .closure:
                return false
            }
        }

        return visit(type)
    }

    func matchesPseudogenericNativeType(
        _ raw: String,
        expected typeID: Core.TypeID
    ) -> Bool {
        var spelling = raw.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in [
                "$", "@owned ", "@guaranteed ", "@unowned ",
                "@autoreleased ", "@in_guaranteed ",
            ] where spelling.hasPrefix(prefix) {
                spelling.removeFirst(prefix.count)
                spelling = spelling.trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        guard let open = spelling.firstIndex(of: "<"),
              spelling.hasSuffix(">"),
              spelling[spelling.index(after: open)..<spelling.index(before: spelling.endIndex)]
                .contains("τ_")
        else { return false }
        let base = String(spelling[..<open])
        return nativeTypes.contains { alias, id in
            guard id == typeID, let aliasOpen = alias.firstIndex(of: "<") else {
                return false
            }
            return alias.hasSuffix(">") && String(alias[..<aliasOpen]) == base
        }
    }

    /// Matches the conventional Foundation value-overlay to Objective-C
    /// reference spelling used in compiler-generated block thunks. Exact
    /// aliases are handled by ordinary type parsing before this fallback.
    func matchesObjectiveCBridgeNativeType(
        _ raw: String,
        expected typeID: Core.TypeID
    ) -> Bool {
        var spelling = raw.trimmingCharacters(in: .whitespaces)
        if spelling.hasPrefix("$") { spelling.removeFirst() }
        let physicalName = spelling.split(separator: ".").last.map(String.init)
            ?? spelling
        guard !physicalName.isEmpty,
              physicalName.allSatisfy({
                  $0 == "_" || $0.isLetter || $0.isNumber
              })
        else { return false }

        let exceptionalNames: [String: String] = [
            "Decimal": "NSDecimalNumber",
        ]
        return nativeTypes.contains { alias, id in
            // Conventional NS bridging is a Foundation overlay contract, not
            // a spelling rule for arbitrary app or framework native types.
            guard id == typeID, alias.hasPrefix("Foundation.") else {
                return false
            }
            let foundationName = alias.dropFirst("Foundation.".count)
            let swiftName: String
            if let genericStart = foundationName.firstIndex(of: "<") {
                guard foundationName.hasSuffix(">") else { return false }
                swiftName = String(foundationName[..<genericStart])
            } else {
                swiftName = String(foundationName)
            }
            guard !swiftName.isEmpty,
                  !swiftName.contains("."),
                  swiftName.allSatisfy({
                      $0 == "_" || $0.isLetter || $0.isNumber
                  })
            else { return false }
            return physicalName == "NS\(swiftName)"
                || exceptionalNames[swiftName] == physicalName
        }
    }

    func isNativeType(_ typeID: Core.TypeID, named name: String) -> Bool {
        nativeTypes[name] == typeID
    }

    var preservesTypedErrors: Bool {
        requiresTypedErrors
    }

    private static func hasClosureErrorBoundary(in text: String) -> Bool {
        text.range(
            of: #"@(?:callee|block_storage)[^\n]*\b(?:any\s+)?(?:Swift\.)?Error\b"#,
            options: .regularExpression
        ) != nil
    }

    func resolvePreservingErrorExistentials(
        _ raw: String
    ) throws -> Bytecode.ValueType {
        var environment = self
        environment.requiresTypedErrors = true
        return try environment.resolve(raw)
    }

    private static func hasStoredErrorPayload(_ definition: RawDefinition) -> Bool {
        guard definition.conformsToError else { return false }
        switch definition.kind {
        case let .structure(fields):
            return !fields.isEmpty
        case let .enumeration(cases):
            return cases.contains { !$0.associatedTypes.isEmpty }
        case let .class(fields, _, _, _):
            return !fields.isEmpty
        }
    }

    private static func hasStoredErrorPayload(
        _ definition: RawGenericDefinition
    ) -> Bool {
        guard definition.conformsToError else { return false }
        switch definition.kind {
        case let .structure(fields):
            return !fields.isEmpty
        case let .enumeration(cases):
            return cases.contains { !$0.associatedTypes.isEmpty }
        case let .class(fields, _, _, _):
            return !fields.isEmpty
        }
    }

    func resolve(_ raw: String) throws -> Bytecode.ValueType {
        try resolve(raw, relativeTo: nil)
    }

    func collectionIndexModel(
        for raw: String
    ) -> CanonicalSIL.CollectionIndex.Model {
        CanonicalSIL.CollectionIndex.model(for: raw)
    }

    private func resolve(
        _ raw: String,
        relativeTo parentScope: String?
    ) throws -> Bytecode.ValueType {
        var type = raw.trimmingCharacters(in: .whitespaces)
        if let pointee = explicitAddressPointee(in: type) {
            return .address(
                ValueRepresentation.storable(
                    try resolve(pointee, relativeTo: parentScope)
                )
            )
        }
        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            if type.hasPrefix("$"), !type.hasPrefix("$*") {
                type.removeFirst()
                removedPrefix = true
            }
            for ownership in [
                "@owned ",
                "@guaranteed ",
                "@unowned ",
                "@autoreleased ",
                "@unowned_inner_pointer ",
                "@closureCapture ",
                "@inferredImmutable ",
                "@in ",
                "@in_guaranteed ",
                "@out ",
            ]
            where type.hasPrefix(ownership) {
                type.removeFirst(ownership.count)
                removedPrefix = true
            }
        }

        for (prefix, kind): (String, Bytecode.NonOwningReferenceKind) in [
            ("@sil_weak ", .weak),
            ("@sil_unowned ", .unowned),
        ] where type.hasPrefix(prefix) {
            let pointee = ValueRepresentation.storable(
                try resolve(
                    String(type.dropFirst(prefix.count)),
                    relativeTo: parentScope
                )
            )
            return .nonOwningReference(kind: kind, pointee: pointee)
        }
        if type.hasPrefix("@sil_unmanaged ") {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "unmanaged reference storage"
            )
        }

        // Captured mutable locals are printed as `@closureCapture $*T`.
        // Ownership decoration is orthogonal to the pointee identity, so
        // recognize the address again after removing those decorations.
        if let pointee = explicitAddressPointee(in: type) {
            return .address(
                ValueRepresentation.storable(
                    try resolve(pointee, relativeTo: parentScope)
                )
            )
        }

        if type.hasPrefix("{ "), type.hasSuffix(" }") {
            let contents = String(type.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespaces)
            guard contents.hasPrefix("var ") else {
                throw CanonicalSIL.LoweringError.unsupportedType(raw)
            }
            let pointee = ValueRepresentation.storable(
                try resolve(
                    String(contents.dropFirst("var ".count)),
                    relativeTo: parentScope
                )
            )
            if case .nonOwningReference = pointee { return pointee }
            return .mutableCell(pointee)
        }

        if type.contains(" -> "),
           CanonicalSIL.FunctionTypeSyntax.outerArrow(in: type) != nil {
            return .closure(
                try resolveClosureSignature(type, relativeTo: parentScope)
            )
        }

        // Declaration summaries preserve Swift's postfix Optional spelling,
        // while function ABIs usually print the equivalent generic form.
        if type.last == "?" || type.last == "!" {
            let wrapped = String(type.dropLast())
                .trimmingCharacters(in: .whitespaces)
            guard !wrapped.isEmpty else {
                throw CanonicalSIL.LoweringError.unsupportedType(raw)
            }
            return .optional(
                ValueRepresentation.storable(
                    try resolve(wrapped, relativeTo: parentScope)
                )
            )
        }

        if type.hasPrefix("["), type.hasSuffix("]") {
            let body = String(type.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else {
                throw CanonicalSIL.LoweringError.unsupportedType(raw)
            }
            if let pair = splitTopLevelKeyValue(body) {
                return try dictionaryType(
                    key: pair.key,
                    value: pair.value,
                    relativeTo: parentScope
                )
            }
            return .array(
                ValueRepresentation.storable(
                    try resolve(body, relativeTo: parentScope)
                )
            )
        }

        for optionalPrefix in ["Optional<", "Swift.Optional<"]
        where type.hasPrefix(optionalPrefix) && type.hasSuffix(">") {
            return .optional(
                ValueRepresentation.storable(
                    try resolve(
                        genericBody(type, prefix: optionalPrefix),
                        relativeTo: parentScope
                    )
                )
            )
        }
        for arrayPrefix in ["Array<", "Swift.Array<"]
        where type.hasPrefix(arrayPrefix) && type.hasSuffix(">") {
            return .array(
                ValueRepresentation.storable(
                    try resolve(
                        genericBody(type, prefix: arrayPrefix),
                        relativeTo: parentScope
                    )
                )
            )
        }

        // These standard-library adapters are compiler-only views in HLBC.
        // Array-backed integer-index slices retain a logical base in the VM
        // value; adapters with private index wrappers remain fail-closed for
        // index-sensitive APIs even when their elements normalize to Array.
        for slicePrefix in ["Slice<", "Swift.Slice<"]
        where type.hasPrefix(slicePrefix) && type.hasSuffix(">") {
            let base = ValueRepresentation.storable(
                try resolve(
                    genericBody(type, prefix: slicePrefix),
                    relativeTo: parentScope
                )
            )
            guard case .array = base else {
                throw CanonicalSIL.LoweringError.unsupportedType(type)
            }
            return base
        }
        for slicePrefix in ["ArraySlice<", "Swift.ArraySlice<"]
        where type.hasPrefix(slicePrefix) && type.hasSuffix(">") {
            return .array(
                ValueRepresentation.storable(
                    try resolve(
                        genericBody(type, prefix: slicePrefix),
                        relativeTo: parentScope
                    )
                )
            )
        }
        for repeatedPrefix in ["Repeated<", "Swift.Repeated<"]
        where type.hasPrefix(repeatedPrefix) && type.hasSuffix(">") {
            return .array(
                ValueRepresentation.storable(
                    try resolve(
                        genericBody(type, prefix: repeatedPrefix),
                        relativeTo: parentScope
                    )
                )
            )
        }
        for reversedPrefix in [
            "ReversedCollection<", "Swift.ReversedCollection<",
        ] where type.hasPrefix(reversedPrefix) && type.hasSuffix(">") {
            let element = try representedSequenceElement(
                genericBody(type, prefix: reversedPrefix),
                relativeTo: parentScope
            )
            return .array(element)
        }
        for enumeratedPrefix in [
            "EnumeratedSequence<", "Swift.EnumeratedSequence<",
        ] where type.hasPrefix(enumeratedPrefix) && type.hasSuffix(">") {
            let element = try representedSequenceElement(
                genericBody(type, prefix: enumeratedPrefix),
                relativeTo: parentScope
            )
            return .array(.tuple([.int64, element]))
        }
        for zipPrefix in ["Zip2Sequence<", "Swift.Zip2Sequence<"]
        where type.hasPrefix(zipPrefix) && type.hasSuffix(">") {
            let components = splitTopLevel(
                genericBody(type, prefix: zipPrefix)
            )
            guard components.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Zip2Sequence requires two sequence arguments"
                )
            }
            let lhs = try representedSequenceElement(
                components[0],
                relativeTo: parentScope
            )
            let rhs = try representedSequenceElement(
                components[1],
                relativeTo: parentScope
            )
            return .array(.tuple([lhs, rhs]))
        }
        for joinedPrefix in [
            "FlattenSequence<", "Swift.FlattenSequence<",
            "JoinedSequence<", "Swift.JoinedSequence<",
        ] where type.hasPrefix(joinedPrefix) && type.hasSuffix(">") {
            let outer = ValueRepresentation.storable(
                try resolve(
                    genericBody(type, prefix: joinedPrefix),
                    relativeTo: parentScope
                )
            )
            guard case let .array(.array(element)) = outer else {
                throw CanonicalSIL.LoweringError.unsupportedType(type)
            }
            return .array(element)
        }
        for setPrefix in ["Set<", "Swift.Set<"]
        where type.hasPrefix(setPrefix) && type.hasSuffix(">") {
            let element = ValueRepresentation.storable(
                try resolve(
                    genericBody(type, prefix: setPrefix),
                    relativeTo: parentScope
                )
            )
            guard element.isVMHashable else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "Set element \(element) does not have VM-defined Hashable semantics"
                )
            }
            return .set(element)
        }
        // Dictionary.Keys and Dictionary.Values are compiler-only collection
        // views. Their supported sequence surface is represented by an Array;
        // private view storage and index APIs remain intentionally unavailable.
        for (suffix, selectsKey) in [(".Keys", true), (".Values", false)]
        where type.hasSuffix(suffix) {
            let dictionaryName = String(type.dropLast(suffix.count))
            let dictionary = ValueRepresentation.storable(
                try resolve(dictionaryName, relativeTo: parentScope)
            )
            guard case let .dictionary(key, value) = dictionary else {
                throw CanonicalSIL.LoweringError.unsupportedType(type)
            }
            return .array(selectsKey ? key : value)
        }
        for dictionaryPrefix in ["Dictionary<", "Swift.Dictionary<"]
        where type.hasPrefix(dictionaryPrefix) && type.hasSuffix(">") {
            let components = splitTopLevel(genericBody(type, prefix: dictionaryPrefix))
            guard components.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Dictionary generic arguments must contain Key and Value"
                )
            }
            return try dictionaryType(
                key: components[0],
                value: components[1],
                relativeTo: parentScope
            )
        }
        for resultPrefix in ["Result<", "Swift.Result<"]
        where type.hasPrefix(resultPrefix) && type.hasSuffix(">") {
            let components = splitTopLevel(genericBody(type, prefix: resultPrefix))
            guard components.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Result generic arguments must contain Success and Failure"
                )
            }
            let success = ValueRepresentation.storable(
                try resolve(components[0], relativeTo: parentScope)
            )
            let failure = ValueRepresentation.storable(
                try resolve(components[1], relativeTo: parentScope)
            )
            return .local(resultKey(success: success, failure: failure))
        }
        if type.hasPrefix("("), type.hasSuffix(")") {
            let elements = splitTopLevelTuple(type)
            if elements.count == 1 {
                if elements[0].isEmpty { return .void }
                if let labeled = splitTopLevelKeyValue(elements[0]) {
                    // A single labeled enum associated value is the one place
                    // canonical SIL carries a physical one-element tuple.
                    return .tuple([
                        ValueRepresentation.storable(
                            try resolve(
                                labeled.value,
                                relativeTo: parentScope
                            )
                        ),
                    ])
                }
                // Swift has no single-element tuple type. Parentheses around
                // one type are grouping, which is common around Optional
                // closure spellings such as `((Int) -> String)?`.
                return try resolve(
                    removeTupleLabel(elements[0]),
                    relativeTo: parentScope
                )
            }
            return .tuple(
                try elements.map {
                    ValueRepresentation.storable(
                        try resolve(
                            removeTupleLabel($0),
                            relativeTo: parentScope
                        )
                    )
                }
            )
        }

        if type == "any Error" || type == "any Swift.Error"
            || type == "Swift.Error" {
            return preservesTypedErrors ? .error : .string
        }
        if CanonicalSIL.ProtocolExistential.Identity(
            spelling: type
        ) != nil {
            return .any
        }

        switch type {
        case "Int", "Swift.Int": return .int64
        case "UInt", "Swift.UInt": return .integer(bitWidth: 64, signed: false)
        case "Int8", "Swift.Int8", "Builtin.Int8":
            return .integer(bitWidth: 8, signed: true)
        case "Int16", "Swift.Int16", "Builtin.Int16":
            return .integer(bitWidth: 16, signed: true)
        case "Int32", "Swift.Int32", "Builtin.Int32":
            return .integer(bitWidth: 32, signed: true)
        case "Int64", "Swift.Int64", "Builtin.Int64":
            return .integer(bitWidth: 64, signed: true)
        case "UInt8", "Swift.UInt8": return .integer(bitWidth: 8, signed: false)
        case "UInt16", "Swift.UInt16": return .integer(bitWidth: 16, signed: false)
        case "UInt32", "Swift.UInt32": return .integer(bitWidth: 32, signed: false)
        case "UInt64", "Swift.UInt64": return .integer(bitWidth: 64, signed: false)
        case "Builtin.Int1": return .bool
        case "Bool", "Swift.Bool": return .bool
        case "Float", "Swift.Float", "Float32", "Builtin.FPIEEE32":
            return .float(bitWidth: 32)
        case "Double", "Swift.Double", "Float64", "Builtin.FPIEEE64":
            return .float(bitWidth: 64)
        case "CGFloat", "CoreFoundation.CGFloat", "CoreGraphics.CGFloat":
            return .float(bitWidth: 64)
        case "String", "Swift.String": return .string
        case "Character", "Swift.Character": return .string
        case "Substring", "Swift.Substring": return .array(.string)
        case "Any", "Swift.Any": return .any
        case "Void", "Swift.Void": return .void
        case "Never", "Swift.Never": return .never
        default:
            if let id = nativeTypes[type] { return .native(id) }
            if let key = localKey(for: type, relativeTo: parentScope) {
                return .local(key)
            }
            throw CanonicalSIL.LoweringError.unsupportedType(type)
        }
    }

    private func representedSequenceElement(
        _ raw: String,
        relativeTo parentScope: String?
    ) throws -> Bytecode.ValueType {
        if let element = CanonicalSIL.TextRepresentation.kind(of: raw)?
            .sequenceElement {
            return element
        }
        if let progression = try CanonicalSIL.Progression.sequenceType(
            raw,
            resolve: {
                ValueRepresentation.storable(
                    try resolve($0, relativeTo: parentScope)
                )
            }
        ) {
            guard progression.supportsIteration else {
                throw CanonicalSIL.LoweringError.unsupportedType(raw)
            }
            return progression.element
        }
        let type = ValueRepresentation.storable(
            try resolve(raw, relativeTo: parentScope)
        )
        guard let element = type.managedCollectionElement else {
            throw CanonicalSIL.LoweringError.unsupportedType(raw)
        }
        return element
    }

    func localKey(for raw: String) -> Bytecode.LocalTypeKey? {
        localKey(for: raw, relativeTo: nil)
    }

    /// Returns whether a SIL member owner names one declaration in the local
    /// nominal inventory. Generic member syntax names the declaration without
    /// concrete arguments, so it cannot be resolved to a `LocalTypeKey` yet.
    func containsLocalDeclaration(_ raw: String) -> Bool {
        let declaration = raw.trimmingCharacters(in: .whitespaces)
        let exact = Bytecode.LocalTypeKey(rawValue: declaration)
        if rawDefinitions[exact] != nil || rawGenericDefinitions[exact] != nil {
            return true
        }
        let suffix = "." + declaration
        let matches = Set(
            rawDefinitions.keys.filter { $0.rawValue.hasSuffix(suffix) }
                + rawGenericDefinitions.keys.filter {
                    $0.rawValue.hasSuffix(suffix)
                }
        )
        return matches.count == 1
    }

    /// SIL member references name the generic declaration (`#Box.value`),
    /// while operand types name a concrete instance (`Box<Int>`). This is the
    /// sole declaration/instance equivalence rule used by aggregate lowering.
    func matchesLocalDeclaration(
        _ rawDeclaration: String,
        concrete key: Bytecode.LocalTypeKey
    ) -> Bool {
        if localKey(for: rawDeclaration) == key { return true }
        guard let instance = genericInstantiation(
            for: key.rawValue,
            relativeTo: nil
        ), instance.key == key else { return false }
        let declaration = rawDeclaration.trimmingCharacters(in: .whitespaces)
        let expected = instance.definition.key.rawValue
        if declaration == expected { return true }
        let suffix = "." + declaration
        let matches = rawGenericDefinitions.keys.filter {
            $0.rawValue.hasSuffix(suffix)
        }
        return matches.count == 1 && matches.first == instance.definition.key
    }

    private func localKey(
        for raw: String,
        relativeTo parentScope: String?
    ) -> Bytecode.LocalTypeKey? {
        let type = raw.trimmingCharacters(in: .whitespaces)
        let exact = Bytecode.LocalTypeKey(rawValue: type)
        if rawDefinitions[exact] != nil { return exact }
        if let parentScope {
            let relative = Bytecode.LocalTypeKey(
                rawValue: "\(parentScope).\(type)"
            )
            if rawDefinitions[relative] != nil { return relative }
        }
        if let generic = genericInstantiation(
            for: type,
            relativeTo: parentScope
        ) {
            return generic.key
        }
        if let separator = type.firstIndex(of: ".") {
            let withoutModule = Bytecode.LocalTypeKey(
                rawValue: String(type[type.index(after: separator)...])
            )
            if rawDefinitions[withoutModule] != nil { return withoutModule }
        }
        let suffix = ".\(type)"
        let matches = rawDefinitions.keys.filter { $0.rawValue.hasSuffix(suffix) }
        return matches.count == 1 ? matches[0] : nil
    }

    private struct GenericInstantiation {
        var definition: RawGenericDefinition
        var arguments: [String]
        var key: Bytecode.LocalTypeKey
    }

    private func genericInstantiation(
        for raw: String,
        relativeTo parentScope: String?
    ) -> GenericInstantiation? {
        let normalized = CanonicalSIL.SwiftTypeIdentity.normalized(raw)
        guard let application = CanonicalSIL.SwiftTypeIdentity.genericType(
            normalized
        ) else { return nil }

        let definition: RawGenericDefinition
        if let exact = rawGenericDefinitions[
            .init(rawValue: application.name)
        ] {
            // A declaration-qualified identity is authoritative. Do not also
            // reinterpret its first component as a module shorthand.
            definition = exact
        } else if let parentScope,
                  let relative = rawGenericDefinitions[
                    .init(rawValue: parentScope + "." + application.name)
                  ] {
            definition = relative
        } else {
            var lookupNames = [application.name]
            if let separator = application.name.firstIndex(of: ".") {
                lookupNames.append(
                    String(application.name[
                        application.name.index(after: separator)...
                    ])
                )
            }
            var candidates = lookupNames.compactMap {
                rawGenericDefinitions[.init(rawValue: $0)]
            }
            for lookupName in lookupNames {
                let suffix = "." + lookupName
                candidates += rawGenericDefinitions.values.filter {
                    $0.key.rawValue.hasSuffix(suffix)
                }
            }
            let matches = Dictionary(
                grouping: candidates,
                by: { $0.key }
            ).compactMap(\.value.first)
            guard matches.count == 1, let match = matches.first else {
                return nil
            }
            definition = match
        }
        guard
              definition.parameters.count == application.arguments.count,
              (try? CanonicalSIL.GenericSignature.containsAny(
                of: definition.parameters,
                in: application.arguments.joined(separator: ",")
              )) == false,
              application.arguments.allSatisfy({
                (try? resolve($0, relativeTo: parentScope)) != nil
              })
        else { return nil }
        let key = Bytecode.LocalTypeKey(
            rawValue: definition.key.rawValue + "<"
                + application.arguments.joined(separator: ", ") + ">"
        )
        return .init(
            definition: definition,
            arguments: application.arguments,
            key: key
        )
    }

    private func localKeys(
        matchingNativeName canonicalName: String
    ) -> [Bytecode.LocalTypeKey] {
        var spellings = Set([canonicalName])
        if let separator = canonicalName.firstIndex(of: ".") {
            spellings.insert(String(canonicalName[canonicalName.index(after: separator)...]))
        }
        if let generic = CanonicalSIL.SwiftTypeIdentity.genericType(
            CanonicalSIL.SwiftTypeIdentity.normalized(canonicalName)
        ) {
            spellings.insert(generic.name)
            if let separator = generic.name.firstIndex(of: ".") {
                spellings.insert(
                    String(generic.name[generic.name.index(after: separator)...])
                )
            }
        }
        return Set(
            rawDefinitions.keys.filter { spellings.contains($0.rawValue) }
                + rawGenericDefinitions.keys.filter {
                    spellings.contains($0.rawValue)
                }
        ).sorted()
    }

    private func explicitAddressPointee(in type: String) -> String? {
        if type.hasPrefix("$*") { return String(type.dropFirst(2)) }
        for convention in ["@inout ", "@inout_aliasable "]
        where type.hasPrefix(convention) {
            return String(type.dropFirst(convention.count))
        }
        return nil
    }

    private func resolveClosureSignature(
        _ raw: String,
        relativeTo parentScope: String?
    ) throws -> Bytecode.ClosureSignature {
        var type = try CanonicalSIL.SubstitutedFunctionType
            .specialize(raw)
            .trimmingCharacters(in: .whitespaces)
        var requiresMainActor = false
        var removedAttribute = true
        while removedAttribute {
            removedAttribute = false
            for attribute in [
                "@noescape ",
                "@callee_guaranteed ",
                "@callee_owned ",
                "@Sendable ",
                "@escaping ",
                "@autoclosure ",
            ] where type.hasPrefix(attribute) {
                type.removeFirst(attribute.count)
                type = type.trimmingCharacters(in: .whitespaces)
                removedAttribute = true
                break
            }
            if removedAttribute { continue }
            if let actor = type.range(
                of: #"^@[A-Za-z_][A-Za-z0-9_.]*Actor\b\s*"#,
                options: .regularExpression
            ) {
                let annotation = String(type[actor])
                    .trimmingCharacters(in: .whitespaces)
                switch CanonicalSIL.FunctionIsolation
                    .loweredTypeAnnotation(in: annotation) {
                case .mainActor:
                    requiresMainActor = true
                case let .unsupported(name):
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "closure global actor \(name)"
                    )
                case .none:
                    throw CanonicalSIL.LoweringError.unsupportedType(raw)
                }
                type.removeSubrange(actor)
                type = type.trimmingCharacters(in: .whitespaces)
                removedAttribute = true
                continue
            }
            if type.range(
                of: #"^@isolated\s*\([^)]*\)\s*"#,
                options: .regularExpression
            ) != nil {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "isolated(any) closure"
                )
            }
        }
        guard !type.hasPrefix("@convention("),
              !type.hasPrefix("@async "),
              !type.contains(" @async "),
              let arrow = CanonicalSIL.FunctionTypeSyntax.outerArrow(in: type)
        else {
            throw CanonicalSIL.LoweringError.unsupportedType(raw)
        }
        let prefix = String(type[..<arrow.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let clauses = try closureParameterAndEffectClauses(
            prefix,
            original: raw
        )
        let parameterTuple = clauses.parameters
        let sourceError = try sourceClosureErrorChannel(
            clauses.effects,
            relativeTo: parentScope
        )
        let components = splitTopLevelTuple(parameterTuple)
        let parameters: [Bytecode.ValueType]
        let parameterConventions: [Bytecode.ParameterConvention]
        if components.count == 1, components[0].isEmpty {
            parameters = []
            parameterConventions = []
        } else {
            let spellings = components.map(removeTupleLabel)
            parameters = try spellings.map {
                ValueRepresentation.storable(
                    try resolve($0, relativeTo: parentScope)
                )
            }
            parameterConventions = zip(spellings, parameters).map {
                spelling, parameter in
                closureParameterConvention(
                    spelling,
                    parameter: parameter
                )
            }
        }
        let resultText = String(type[arrow.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        let resultComponents = splitTopLevelTuple(resultText)
        let result: Bytecode.ValueType
        let silError: ClosureErrorChannel?
        if resultComponents.count == 1,
           let error = try closureErrorChannel(
            resultComponents[0],
            relativeTo: parentScope
           ) {
            result = .void
            silError = error
        } else if resultComponents.count == 2,
                  let error = try closureErrorChannel(
                    resultComponents[1],
                    relativeTo: parentScope
                  ) {
            result = try resolve(
                resultComponents[0],
                relativeTo: parentScope
            )
            silError = error
        } else {
            result = try resolve(resultText, relativeTo: parentScope)
            silError = nil
        }
        guard !sourceError.isPresent || silError == nil else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "closure type encodes its error channel twice: \(raw)"
            )
        }
        let thrownType = sourceError.isPresent
            ? sourceError.thrownType : silError?.thrownType
        return .init(
            parameters: parameters,
            parameterConventions: parameterConventions,
            result: result,
            thrownType: thrownType,
            effects: .init(
                mayThrow: thrownType != nil,
                requiresMainActor: requiresMainActor
            )
        )
    }

    private func closureParameterConvention(
        _ raw: String,
        parameter: Bytecode.ValueType
    ) -> Bytecode.ParameterConvention {
        if case .address = parameter { return .inout }
        let spelling = raw.trimmingCharacters(in: .whitespaces)
            .trimmingPrefix("$")
        let explicitlyBorrowed = spelling.hasPrefix("@guaranteed ")
            || spelling.hasPrefix("@unowned ")
            || spelling.hasPrefix("@in_guaranteed ")
        let explicitlyOwned = spelling.hasPrefix("@owned ")
        return (parameter.requiresLinearOwnership
            || containsOwningReference(parameter))
            && (explicitlyBorrowed
                || (!explicitlyOwned
                    && isNonreferenceNativeValue(parameter)))
                ? .borrowed
                : .owned
    }

    private struct ClosureErrorChannel {
        var thrownType: Bytecode.ValueType?
    }

    private struct SourceClosureErrorChannel {
        var isPresent: Bool
        var thrownType: Bytecode.ValueType?
    }

    private func closureParameterAndEffectClauses(
        _ prefix: String,
        original: String
    ) throws -> (parameters: String, effects: String) {
        guard prefix.first == "(" else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "closure type has no parameter tuple: \(original)"
            )
        }
        var depth = 0
        for index in prefix.indices {
            switch prefix[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    let end = prefix.index(after: index)
                    return (
                        String(prefix[..<end]),
                        String(prefix[end...])
                            .trimmingCharacters(in: .whitespaces)
                    )
                }
            default:
                break
            }
            guard depth >= 0 else { break }
        }
        throw CanonicalSIL.LoweringError.malformedSIL(
            "closure type has an unbalanced parameter tuple: \(original)"
        )
    }

    private func sourceClosureErrorChannel(
        _ raw: String,
        relativeTo parentScope: String?
    ) throws -> SourceClosureErrorChannel {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            return .init(isPresent: false, thrownType: nil)
        }
        guard !value.contains("async") else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "async closure"
            )
        }
        guard value.hasPrefix("throws") else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "closure effect clause \(value)"
            )
        }
        let errorSpelling = String(value.dropFirst("throws".count))
            .trimmingCharacters(in: .whitespaces)
        let errorType: Bytecode.ValueType
        if errorSpelling.isEmpty {
            errorType = try resolve(
                "any Error",
                relativeTo: parentScope
            )
        } else {
            guard errorSpelling.first == "(",
                  errorSpelling.last == ")"
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "typed closure throws clause is malformed"
                )
            }
            let spelling = String(errorSpelling.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            guard !spelling.isEmpty else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "typed closure throws clause has no error type"
                )
            }
            errorType = try resolve(spelling, relativeTo: parentScope)
        }
        return .init(
            isPresent: true,
            thrownType: try validatedClosureThrownType(errorType)
        )
    }

    private func closureErrorChannel(
        _ raw: String,
        relativeTo parentScope: String?
    ) throws -> ClosureErrorChannel? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let prefixes = ["@error_indirect ", "@error "]
        guard let prefix = prefixes.first(where: value.hasPrefix) else {
            return nil
        }
        let type = try resolve(
            String(value.dropFirst(prefix.count)),
            relativeTo: parentScope
        )
        return .init(thrownType: try validatedClosureThrownType(type))
    }

    private func validatedClosureThrownType(
        _ type: Bytecode.ValueType
    ) throws -> Bytecode.ValueType? {
        switch type {
        case .never:
            return nil
        case .string, .error:
            return type
        case let .local(key) where try definition(for: key).conformsToError:
            return type
        default:
            throw CanonicalSIL.LoweringError.malformedSIL(
                "closure has a non-Error error result"
            )
        }
    }

    func structFactory(_ mangledName: String) -> StructFactory? {
        structFactories[mangledName]
    }

    func classAllocator(_ mangledName: String) -> Bytecode.LocalTypeKey? {
        classAllocators[mangledName]
    }

    func isHostedClassAllocator(_ mangledName: String) -> Bool {
        guard let key = classAllocators[mangledName] else { return false }
        return (try? hostedSuperclass(for: key)) != nil
    }

    func isStructFactory(_ mangledName: String) -> Bool {
        structFactories[mangledName] != nil
    }

    /// A function-local nominal declaration is absent from canonical SIL's
    /// declaration summary. Its synthesized memberwise initializer may still
    /// remain in the semantic pass after the optimized root has scalarized it.
    /// Omit only an exact, side-effect-free identity constructor; any body with
    /// computation remains an ordinary image candidate and fails closed when
    /// its nominal shape is unavailable.
    func isOpaqueStructFactory(_ function: CanonicalSIL.Function) -> Bool {
        guard function.loweredType.contains("@convention(method)"),
              let arrow = CanonicalSIL.FunctionTypeSyntax.outerArrow(
                in: function.loweredType
              )
        else { return false }
        var result = function.loweredType[arrow.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        if result.hasPrefix("@owned ") {
            result.removeFirst("@owned ".count)
        }
        guard !result.isEmpty, (try? resolve(result)) == nil else {
            return false
        }

        let prefix = String(function.loweredType[..<arrow.lowerBound])
        guard let parameterRange = outerParameterTuple(in: prefix) else {
            return false
        }
        let parameters = splitTopLevel(String(prefix[parameterRange]))
        guard var metatype = parameters.last?
            .trimmingCharacters(in: .whitespaces),
              metatype.hasPrefix("@thin "),
              metatype.hasSuffix(".Type")
        else { return false }
        metatype.removeFirst("@thin ".count)
        metatype.removeLast(".Type".count)
        guard metatype == result else { return false }

        let lines = function.body.split(separator: "\n").map { rawLine in
            CanonicalSIL.DebugMetadata.strippingComment(from: String(rawLine))
                .trimmingCharacters(in: .whitespaces)
        }.filter {
            !$0.isEmpty && !$0.hasPrefix("bb") && !$0.hasPrefix("debug_value")
        }
        if lines.count == 2,
           let construction = Self.captures(
            lines[0],
            pattern: #"^(%[0-9]+) = struct \$([^ ]+) \((.*)\)$"#
           ), construction[1] == result,
           let returned = Self.captures(
            lines[1],
            pattern: #"^return (%[0-9]+)$"#
           ), returned[0] == construction[0] {
            let rawOperands = splitTopLevel(construction[2])
            let valueParameters = Array(parameters.dropLast())
            if valueParameters.isEmpty {
                return rawOperands == [""]
            }
            guard rawOperands.count == valueParameters.count else {
                return false
            }
            for (index, pair) in zip(rawOperands, valueParameters).enumerated() {
                let operand = pair.0.split(
                    separator: ":",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard (1...2).contains(operand.count),
                      operand[0].trimmingCharacters(in: .whitespaces)
                        == "%\(index)"
                else { return false }
                if operand.count == 2,
                   CanonicalSIL.SwiftTypeIdentity.normalized(
                    String(operand[1])
                   ) != CanonicalSIL.SwiftTypeIdentity.normalized(pair.1) {
                    return false
                }
            }
            return true
        }

        guard parameters.count == 1, lines.count == 4,
              let allocation = Self.captures(
                lines[0],
                pattern: #"^(%[0-9]+) = alloc_stack(?: \[[^]]+\])? \$([^,]+)(?:,.*)?$"#
              ), allocation[1] == result,
              let load = Self.captures(
                lines[1],
                pattern: #"^(%[0-9]+) = load(?: \[(?:trivial|copy|take)\])? (%[0-9]+)$"#
              ), load[1] == allocation[0],
              let deallocation = Self.captures(
                lines[2],
                pattern: #"^dealloc_stack (%[0-9]+)$"#
              ), deallocation[0] == allocation[0],
              let returned = Self.captures(
                lines[3],
                pattern: #"^return (%[0-9]+)$"#
              ), returned[0] == load[0]
        else { return false }
        return true
    }

    func definition(for key: Bytecode.LocalTypeKey) throws -> Bytecode.LocalTypeDefinition {
        if let raw = rawDefinitions[key] {
            return try materializeDefinition(
                key: key,
                parentScope: raw.parentScope,
                kind: raw.kind,
                conformsToError: raw.conformsToError,
                substitutions: [:]
            )
        }
        if let generic = genericInstantiation(
            for: key.rawValue,
            relativeTo: nil
        ), generic.key == key {
            let bindings = Dictionary(
                uniqueKeysWithValues: zip(
                    generic.definition.parameters,
                    generic.arguments
                ).map { ($0.0, $0.1) }
            )
            let substitutions: [String: String]
            if generic.definition.requirements.isEmpty {
                substitutions = bindings
            } else {
                guard let protocolConformances else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "generic nominal \(key) has no conformance environment"
                    )
                }
                let clause = CanonicalSIL.GenericSignature.Clause(
                    parameters: generic.definition.parameters,
                    requirements: generic.definition.requirements
                )
                do {
                    substitutions = try CanonicalSIL.GenericSignature.resolve(
                        clause,
                        bindings: bindings,
                        conformances: protocolConformances,
                        typeEnvironment: self
                    ).substitutions
                } catch {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "generic nominal \(key) does not satisfy its constraints: \(error)"
                    )
                }
            }
            return try materializeDefinition(
                key: key,
                parentScope: generic.definition.parentScope,
                kind: generic.definition.kind,
                conformsToError: generic.definition.conformsToError,
                substitutions: substitutions
            )
        }
        // A concrete Result is represented as a patch-local enum; no Swift metadata
        // or native generic layout is admitted into the portable bytecode image.
        if key.rawValue.hasPrefix("Swift.Result<"), key.rawValue.hasSuffix(">") {
            let body = genericBody(key.rawValue, prefix: "Swift.Result<")
            let arguments = splitTopLevel(body)
            guard arguments.count == 2 else {
                throw CanonicalSIL.LoweringError.unsupportedType(key.rawValue)
            }
            return .init(
                key: key,
                kind: .enumeration(
                    cases: [
                        .init(
                            name: "success",
                            payloadType: try CanonicalSIL.ValueTypeSpelling
                                .parse(arguments[0])
                        ),
                        .init(
                            name: "failure",
                            payloadType: try CanonicalSIL.ValueTypeSpelling
                                .parse(arguments[1])
                        ),
                    ]
                )
            )
        }
        throw CanonicalSIL.LoweringError.unsupportedType(key.rawValue)
    }

    /// Captures the exact source-level spellings needed by generated Shell
    /// codecs alongside the portable logical aggregate definition. Generic,
    /// class, and compiler-synthesized value identities remain image-local.
    public func frozenValueTypeRecord(
        key: Bytecode.LocalTypeKey,
        canonicalName: String,
        sourceFileLogicalID: String
    ) throws -> InterfaceArchive.FrozenValueTypeRecord {
        guard let raw = rawDefinitions[key] else {
            throw CanonicalSIL.LoweringError.unsupportedType(key.rawValue)
        }
        guard !raw.hasUnparsedInstanceStorage else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "indexed Shell value \(key) contains unmodeled instance storage"
            )
        }
        let definition = try definition(for: key)
        let kind: InterfaceArchive.FrozenValueTypeKind
        switch (raw.kind, definition.kind) {
        case let (.structure(rawFields), .structure(fields)):
            guard rawFields.count == fields.count else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "indexed struct \(key) changed field arity while materializing"
                )
            }
            guard !rawFields.contains(where: \.hasImmutableDeclarationInitializer)
            else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "indexed struct \(key) has a let property with a declaration initializer"
                )
            }
            guard !rawFields.contains(where: {
                Self.hasUnsupportedFrozenExistential(in: $0.type)
            }) else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "indexed struct \(key) stores a protocol existential"
                )
            }
            kind = .structure(
                fields: zip(rawFields, fields).map { rawField, field in
                    .init(
                        name: field.name,
                        swiftType: rawField.type,
                        type: field.type
                    )
                }
            )
        case let (.enumeration(rawCases), .enumeration(cases)):
            guard rawCases.count == cases.count else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "indexed enum \(key) changed case arity while materializing"
                )
            }
            guard !rawCases.contains(where: \.hasAvailabilityConstraint) else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "indexed enum \(key) has an availability-constrained case"
                )
            }
            kind = .enumeration(
                cases: try zip(rawCases, cases).map { rawCase, item in
                    guard !rawCase.associatedTypes.contains(where: {
                        Self.hasUnsupportedFrozenExistential(in: $0)
                    }) else {
                        throw CanonicalSIL.LoweringError.unsupportedType(
                            "indexed enum \(key).\(item.name) stores a protocol existential"
                        )
                    }
                    let associatedValues = try rawCase.associatedTypes.map { spelling in
                        let labeled = splitTopLevelKeyValue(spelling)
                        let swiftType = labeled?.value ?? spelling
                        let type = ValueRepresentation.storable(
                            try resolve(
                                swiftType,
                                relativeTo: raw.parentScope
                            )
                        )
                        return InterfaceArchive.FrozenEnumAssociatedValue(
                            label: labeled?.key == "_" ? nil : labeled?.key,
                            swiftType: swiftType,
                            type: type
                        )
                    }
                    let result = InterfaceArchive.FrozenEnumCase(
                        name: item.name,
                        associatedValues: associatedValues
                    )
                    guard result.payloadType == item.payloadType else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "indexed enum \(key).\(item.name) payload changed while materializing"
                        )
                    }
                    return result
                }
            )
        default:
            throw CanonicalSIL.LoweringError.unsupportedType(
                "indexed Shell value \(key) is not a concrete struct or enum"
            )
        }
        let record = try InterfaceArchive.FrozenValueTypeRecord(
            key: key,
            canonicalName: canonicalName,
            sourceFileLogicalID: sourceFileLogicalID,
            kind: kind,
            conformsToError: raw.conformsToError,
            isCopyable: raw.isCopyable
        )
        guard record.definition == definition else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "indexed value codec shape disagrees with \(key)"
            )
        }
        return record
    }

    /// Replays the current frontend summary against every value layout frozen
    /// in the target Shell. Swift spellings are included so equal-width source
    /// changes such as `Int` to `Int64` cannot evade the interface gate.
    public func validateFrozenValueTypes(
        _ records: [InterfaceArchive.FrozenValueTypeRecord]
    ) throws {
        for frozen in records {
            let current = try frozenValueTypeRecord(
                key: frozen.key,
                canonicalName: frozen.canonicalName,
                sourceFileLogicalID: frozen.sourceFileLogicalID
            )
            guard current == frozen else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "indexed Shell value layout changed for \(frozen.key)"
                )
            }
        }
    }

    private func materializeDefinition(
        key: Bytecode.LocalTypeKey,
        parentScope: String?,
        kind rawKind: RawKind,
        conformsToError: Bool,
        substitutions: [String: String]
    ) throws -> Bytecode.LocalTypeDefinition {
        func concrete(_ raw: String) throws -> String {
            try CanonicalSIL.GenericSignature.substituting(
                substitutions,
                in: raw,
                preservesQuotedSpellings: false
            )
        }

        let kind: Bytecode.LocalTypeKind
        switch rawKind {
        case let .structure(fields):
            kind = .structure(
                fields: try fields.map {
                    .init(
                        name: $0.name,
                        type: ValueRepresentation.storable(
                            try resolve(
                                concrete($0.type),
                                relativeTo: parentScope
                            )
                        )
                    )
                }
            )
        case let .enumeration(cases):
            kind = .enumeration(
                cases: try cases.map { item in
                    let concreteTypes = try item.associatedTypes.map(concrete)
                    let payload: Bytecode.ValueType?
                    switch concreteTypes.count {
                    case 0:
                        payload = nil
                    case 1:
                        let value = ValueRepresentation.storable(
                            try resolve(
                                removeTupleLabel(concreteTypes[0]),
                                relativeTo: parentScope
                            )
                        )
                        // Swift represents a single labeled associated value
                        // as a one-element tuple in canonical SIL.
                        payload = splitTopLevelKeyValue(concreteTypes[0]) == nil
                            ? value : .tuple([value])
                    default:
                        payload = .tuple(
                            try concreteTypes.map {
                                ValueRepresentation.storable(
                                    try resolve(
                                        removeTupleLabel($0),
                                        relativeTo: parentScope
                                    )
                                )
                            }
                        )
                    }
                    return .init(name: item.name, payloadType: payload)
                }
            )
        case let .class(fields, rawSuperclass, isFinal, _):
            guard isFinal else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "non-final patch-local class \(key)"
                )
            }
            let hostedSuperclass: Bytecode.HostedSuperclass?
            if let rawSuperclass {
                let superclass = try concrete(rawSuperclass)
                switch try? resolve(superclass, relativeTo: parentScope) {
                case let .native(typeID):
                    hostedSuperclass = .init(typeID: typeID)
                case let .local(parentKey):
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "patch-local class inheritance \(key): \(parentKey)"
                    )
                case nil:
                    // Protocol-only inheritance does not affect object layout.
                    hostedSuperclass = nil
                default:
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "class superclass \(superclass)"
                    )
                }
            } else {
                hostedSuperclass = nil
            }
            kind = .class(
                fields: try fields.map {
                    .init(
                        name: $0.name,
                        type: ValueRepresentation.storable(
                            try resolve(
                                concrete($0.type),
                                relativeTo: parentScope
                            )
                        )
                    )
                },
                hostedSuperclass: hostedSuperclass,
                hostedMethods: []
            )
        }
        return .init(
            key: key,
            kind: kind,
            conformsToError: conformsToError
        )
    }

    func definitions(
        referencedBy functions: [IntermediateRepresentation.Function],
        hostedMethods: [Bytecode.LocalTypeKey: [Bytecode.HostedMethod]] = [:]
    ) throws -> [Bytecode.LocalTypeDefinition] {
        var pending: [Bytecode.LocalTypeKey] = []
        var seen = Set<Bytecode.LocalTypeKey>()
        func collect(_ type: Bytecode.ValueType) {
            switch type {
            case let .local(key):
                if seen.insert(key).inserted { pending.append(key) }
            case let .array(element), let .optional(element), let .set(element),
                 let .address(element), let .mutableCell(element),
                 let .nonOwningReference(_, element),
                 let .arrayState(_, element):
                collect(element)
            case let .dictionary(key, value):
                collect(key)
                collect(value)
            case let .dictionaryState(key, value):
                collect(key)
                collect(value)
            case let .tuple(elements):
                elements.forEach(collect)
            case let .closure(signature):
                signature.componentTypes.forEach(collect)
            case .void, .never, .bool, .integer, .float, .string, .any, .native,
                 .error:
                break
            }
        }
        for function in functions {
            let functionTypes = function.registerTypes
                + function.stackSlotTypes
                + [function.resultType]
                + (function.thrownType.map { [$0] } ?? [])
            for type in functionTypes {
                collect(type)
            }
        }
        var result: [Bytecode.LocalTypeDefinition] = []
        while let key = pending.popLast() {
            var item = try definition(for: key)
            if let methods = hostedMethods[key],
               case let .class(fields, superclass, _) = item.kind {
                item.kind = .class(
                    fields: fields,
                    hostedSuperclass: superclass,
                    hostedMethods: methods
                )
            }
            result.append(item)
            switch item.kind {
            case let .structure(fields):
                fields.forEach { collect($0.type) }
            case let .enumeration(cases):
                cases.compactMap(\.payloadType).forEach(collect)
            case let .class(fields, _, _):
                fields.forEach { collect($0.type) }
            }
        }
        let definitions = result.sorted { $0.key < $1.key }
        try validateLocalTypeGraph(definitions)
        return definitions
    }

    private func validateLocalTypeGraph(
        _ definitions: [Bytecode.LocalTypeDefinition]
    ) throws {
        let definitionsByKey = Dictionary(
            definitions.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var visiting = Set<Bytecode.LocalTypeKey>()
        var depths: [Bytecode.LocalTypeKey: Int] = [:]
        for key in definitionsByKey.keys.sorted() {
            _ = try localTypeExpansionDepth(
                key,
                definitions: definitionsByKey,
                visiting: &visiting,
                depths: &depths
            )
        }
    }

    private func localTypeExpansionDepth(
        _ key: Bytecode.LocalTypeKey,
        definitions: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        visiting: inout Set<Bytecode.LocalTypeKey>,
        depths: inout [Bytecode.LocalTypeKey: Int]
    ) throws -> Int {
        if let depth = depths[key] { return depth }
        guard visiting.insert(key).inserted else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "recursive local nominal type \(key)"
            )
        }
        defer { visiting.remove(key) }
        guard let definition = definitions[key] else {
            throw CanonicalSIL.LoweringError.unsupportedType(key.rawValue)
        }

        func typeDepth(_ type: Bytecode.ValueType) throws -> Int {
            switch type {
            case let .local(dependency):
                if case .class = definitions[dependency]?.kind {
                    0
                } else {
                    try localTypeExpansionDepth(
                        dependency,
                        definitions: definitions,
                        visiting: &visiting,
                        depths: &depths
                    )
                }
            case let .array(element), let .optional(element), let .set(element),
                 let .address(element), let .mutableCell(element),
                 let .arrayState(_, element):
                try typeDepth(element) + 1
            case let .dictionary(key, value):
                try max(typeDepth(key), typeDepth(value)) + 1
            case let .dictionaryState(key, value):
                try max(typeDepth(key), typeDepth(value)) + 1
            case let .tuple(elements):
                try (elements.map(typeDepth).max() ?? 0) + 1
            case .closure, .nonOwningReference:
                // A closure context is reference-like storage. Local values
                // mentioned by its callable signature do not recursively
                // expand the containing nominal's inline layout.
                0
            case .error:
                // The verifier and VM treat Error as a dynamic graph leaf and
                // cap its concrete value tree when the existential is built.
                0
            case .void, .never, .bool, .integer, .float, .string, .any, .native:
                0
            }
        }

        let memberTypes: [Bytecode.ValueType] = switch definition.kind {
        case let .structure(fields): fields.map(\.type)
        case let .enumeration(cases): cases.compactMap(\.payloadType)
        case let .class(fields, _, _): fields.map(\.type)
        }
        let depth = try (memberTypes.map(typeDepth).max() ?? 0) + 1
        guard depth <= 32 else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "local nominal expanded shape deeper than 32 levels"
            )
        }
        depths[key] = depth
        return depth
    }

    func structFields(for key: Bytecode.LocalTypeKey) throws -> [Bytecode.LocalStructField] {
        guard case let .structure(fields) = try definition(for: key).kind else {
            throw CanonicalSIL.LoweringError.malformedSIL("\(key) is not a struct")
        }
        return fields
    }

    /// Returns the recursively known aggregate shape only when Swift can
    /// erase every stored component from its physical calling convention.
    /// Enums still carry a discriminator and classes still carry identity, so
    /// neither is zero-sized even when its declared payload is empty.
    func zeroSizedAggregate(
        for type: Bytecode.ValueType
    ) throws -> ZeroSizedAggregate? {
        var visiting = Set<Bytecode.LocalTypeKey>()
        guard try isStaticallyZeroSized(type, visiting: &visiting) else {
            return nil
        }
        switch type {
        case let .tuple(elements):
            return .tuple(elements)
        case let .local(key):
            return .structure(key: key, fields: try structFields(for: key))
        default:
            return nil
        }
    }

    func isStaticallyZeroSized(
        _ type: Bytecode.ValueType
    ) throws -> Bool {
        var visiting = Set<Bytecode.LocalTypeKey>()
        return try isStaticallyZeroSized(type, visiting: &visiting)
    }

    private func isStaticallyZeroSized(
        _ type: Bytecode.ValueType,
        visiting: inout Set<Bytecode.LocalTypeKey>
    ) throws -> Bool {
        switch type {
        case let .tuple(elements):
            for element in elements
            where try !isStaticallyZeroSized(element, visiting: &visiting) {
                return false
            }
            return true
        case let .local(key):
            guard visiting.insert(key).inserted else { return false }
            defer { visiting.remove(key) }
            guard case let .structure(fields) = try definition(for: key).kind else {
                return false
            }
            for field in fields
            where try !isStaticallyZeroSized(field.type, visiting: &visiting) {
                return false
            }
            return true
        default:
            return false
        }
    }

    func classFields(for key: Bytecode.LocalTypeKey) throws -> [Bytecode.LocalStructField] {
        guard case let .class(fields, _, _) = try definition(for: key).kind else {
            throw CanonicalSIL.LoweringError.malformedSIL("\(key) is not a class")
        }
        return fields
    }

    func hostedSuperclass(
        for key: Bytecode.LocalTypeKey
    ) throws -> Bytecode.HostedSuperclass? {
        guard case let .class(_, superclass, _) = try definition(for: key).kind else {
            return nil
        }
        return superclass
    }

    func hostedMethodCandidates(
        in file: CanonicalSIL.File
    ) throws -> [HostedMethodCandidate] {
        var result: [HostedMethodCandidate] = []
        for (key, raw) in rawDefinitions.sorted(by: { $0.key < $1.key }) {
            guard case let .class(_, superclass, isFinal, methods) = raw.kind,
                  isFinal,
                  superclass != nil,
                  !methods.isEmpty
            else { continue }
            for (index, method) in methods.enumerated() {
                guard let methodIndex = UInt32(exactly: index) else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "hosted class \(key) has too many methods"
                    )
                }
                let matches = try file.functions.filter { function in
                    try hostedMethodContext(for: function) == .init(
                        typeKey: key,
                        methodIndex: methodIndex,
                        selector: method.selector,
                        abi: method.abi
                    )
                }
                guard matches.count == 1, let function = matches.first else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "hosted method \(key).\(method.name) resolves to \(matches.count) canonical SIL bodies"
                    )
                }
                result.append(
                    .init(
                        typeKey: key,
                        methodIndex: methodIndex,
                        selector: method.selector,
                        abi: method.abi,
                        symbol: function.mangledName,
                        function: function
                    )
                )
            }
        }
        return result.sorted {
            ($0.typeKey, $0.methodIndex, $0.symbol)
                < ($1.typeKey, $1.methodIndex, $1.symbol)
        }
    }

    func hostedMethodContext(
        for function: CanonicalSIL.Function
    ) throws -> HostedMethodContext? {
        guard function.loweredType.contains("@convention(method)"),
              !function.mangledName.hasSuffix("TD"),
              !function.mangledName.hasSuffix("To")
        else { return nil }
        var rawMatches: [(
            key: Bytecode.LocalTypeKey,
            index: Int,
            method: RawHostedMethod
        )] = []
        for (key, raw) in rawDefinitions {
            guard case let .class(_, superclass, isFinal, methods) = raw.kind,
                  isFinal,
                  superclass != nil
            else { continue }
            for (index, method) in methods.enumerated() {
                let nameFragment = "\(method.name.utf8.count)\(method.name)"
                if function.mangledName.contains(nameFragment) {
                    rawMatches.append((key, index, method))
                }
            }
        }
        guard !rawMatches.isEmpty else { return nil }
        let signature = try CanonicalSIL.Lowerer(
            typeEnvironment: self
        ).parseFunctionType(function.loweredType)
        var matches: [HostedMethodContext] = []
        for candidate in rawMatches {
            let key = candidate.key
            let method = candidate.method
            let index = candidate.index
            guard signature.result == .void,
                  !signature.effects.mayThrow,
                  !signature.effects.isAsync,
                  signature.parameters == expectedHostedParameters(
                    abi: method.abi,
                    typeKey: key
                  ),
                  let methodIndex = UInt32(exactly: index)
            else { continue }
            matches.append(
                .init(
                    typeKey: key,
                    methodIndex: methodIndex,
                    selector: method.selector,
                    abi: method.abi
                )
            )
        }
        guard matches.count <= 1 else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "function @\(function.mangledName) ambiguously matches hosted methods"
            )
        }
        return matches.first
    }

    func hostedMethodRequiresMainActor(
        _ context: HostedMethodContext
    ) throws -> Bool {
        guard let superclass = try hostedSuperclass(for: context.typeKey) else {
            return false
        }
        return mainActorNativeTypes.contains(superclass.typeID)
    }

    private func expectedHostedParameters(
        abi: Bytecode.HostedMethodABI,
        typeKey: Bytecode.LocalTypeKey
    ) -> [Bytecode.ValueType] {
        switch abi {
        case .voidNoArguments: [.local(typeKey)]
        case .voidBool: [.bool, .local(typeKey)]
        }
    }

    func isClass(_ key: Bytecode.LocalTypeKey) -> Bool {
        if let raw = rawDefinitions[key], case .class = raw.kind {
            return true
        }
        if let generic = genericInstantiation(
            for: key.rawValue,
            relativeTo: nil
        ), generic.key == key, case .class = generic.definition.kind {
            return true
        }
        return false
    }

    func isReferenceType(_ raw: String) -> Bool {
        guard let type = try? resolve(raw) else { return false }
        switch type {
        case let .local(key):
            return isClass(key)
        case let .native(typeID):
            return nativeTypeKinds[typeID] == .reference
        default:
            return false
        }
    }

    func satisfiesSuperclassConstraint(
        concrete: String,
        superclass: String
    ) -> Bool {
        guard isReferenceType(superclass),
              let concreteType = try? resolve(concrete),
              let superclassType = try? resolve(superclass)
        else { return false }
        if concreteType == superclassType { return true }
        guard case let .local(key) = concreteType,
              case let .native(superclassID) = superclassType,
              let hosted = try? hostedSuperclass(for: key)
        else { return false }
        return hosted.typeID == superclassID
    }

    /// Supplies only Swift conformances whose semantics are already defined by
    /// the portable value model. User and framework conformances must come
    /// from exact frontend witness evidence instead of being inferred from a
    /// coincidentally similar storage representation.
    func standardConformanceAssociatedTypes(
        concrete raw: String,
        protocolName: String
    ) -> [String: String]? {
        let name =
            protocolName.hasPrefix("Swift.")
            ? String(protocolName.dropFirst("Swift.".count))
            : protocolName
        // Progressions such as Range<Int> have a compiler-owned Sequence
        // representation but are not ordinary storable collection values.
        // Validate every standard Sequence family through the shared semantic
        // classifier before consulting its closed conformance hierarchy.
        if (try? representedSequenceElement(raw, relativeTo: nil)) != nil,
            let evidence = CanonicalSIL.StandardConformance.associatedTypes(
                concrete: raw,
                protocolName: protocolName
            )
        {
            return evidence
        }
        guard let type = try? resolve(raw) else { return nil }
        if let evidence = CanonicalSIL.StandardConformance.associatedTypes(
            concrete: raw,
            protocolName: protocolName,
            representedType: type
        ) {
            return evidence
        }
        switch name {
        case "Error":
            if type == .never { return [:] }
            guard case .local(let key) = type,
                (try? definition(for: key).conformsToError) == true
            else { return nil }
            return [:]
        default:
            return nil
        }
    }

    func storedFieldIndex(
        type key: Bytecode.LocalTypeKey,
        name: String
    ) throws -> Int {
        let fields: [Bytecode.LocalStructField]
        switch try definition(for: key).kind {
        case let .structure(values), let .class(values, _, _):
            fields = values
        case .enumeration:
            throw CanonicalSIL.LoweringError.malformedSIL(
                "local enum \(key) has no stored field \(name)"
            )
        }
        guard let index = fields.firstIndex(where: { $0.name == name }) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "local type \(key) has no field \(name)"
            )
        }
        return index
    }

    func structFieldIndex(
        type key: Bytecode.LocalTypeKey,
        name: String
    ) throws -> Int {
        let fields = try structFields(for: key)
        guard let index = fields.firstIndex(where: { $0.name == name }) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "local struct \(key) has no field \(name)"
            )
        }
        return index
    }

    func enumCaseIndex(
        type key: Bytecode.LocalTypeKey,
        name: String
    ) throws -> Int {
        guard case let .enumeration(cases) = try definition(for: key).kind,
              let index = cases.firstIndex(where: { $0.name == name })
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "local enum \(key) has no case \(name)"
            )
        }
        return index
    }

    private func detectStructFactory(
        _ function: CanonicalSIL.Function
    ) throws -> StructFactory? {
        guard let shape = try structFactoryShape(function) else { return nil }
        let key = shape.key
        let fields = shape.fields
        let rawResult = shape.rawResult
        let fieldPlans = shape.fieldPlans
        let physicalParameterTypes = shape.physicalParameterTypes

        let semanticLines = function.body.split(separator: "\n").map { rawLine in
            CanonicalSIL.DebugMetadata.strippingComment(from: String(rawLine))
                .trimmingCharacters(in: .whitespaces)
        }.filter {
            !$0.isEmpty && !$0.hasPrefix("bb") && !$0.hasPrefix("debug_value")
        }

        // A synthesized initializer for a fieldless struct reads its
        // uninitialized `self` stack slot. This is valid only because the type
        // has a single possible value. Accept that exact side-effect-free SIL
        // shape rather than treating arbitrary zero-argument factories as
        // constructors.
        if fields.isEmpty, !rawResult.hasPrefix("@out "),
           semanticLines.count == 4,
           let allocation = captures(
            semanticLines[0],
            pattern: #"^(%[0-9]+) = alloc_stack(?: \[[^]]+\])? \$([^,]+)(?:,.*)?$"#
           ), localKey(for: allocation[1]) == key,
           let load = captures(
            semanticLines[1],
            pattern: #"^(%[0-9]+) = load(?: \[(?:trivial|copy|take)\])? (%[0-9]+)$"#
           ), load[1] == allocation[0],
           let deallocation = captures(
            semanticLines[2],
            pattern: #"^dealloc_stack (%[0-9]+)$"#
           ), deallocation[0] == allocation[0],
           let returned = captures(
            semanticLines[3],
            pattern: #"^return (%[0-9]+)$"#
           ), returned[0] == load[0] {
            return .init(
                key: key,
                fieldPlans: fieldPlans,
                physicalParameterTypes: physicalParameterTypes
            )
        }

        if !rawResult.hasPrefix("@out "), semanticLines.count >= 2,
           let construction = captures(
            semanticLines[semanticLines.count - 2],
            pattern: #"^(%[0-9]+) = struct \$([^ ]+) \((.*)\)$"#
           ), localKey(for: construction[1]) == key,
           let returned = captures(
            semanticLines[semanticLines.count - 1],
            pattern: #"^return (%[0-9]+)$"#
           ), returned[0] == construction[0] {
            var tupleDefinitions: [String: [String]] = [:]
            for line in semanticLines.dropLast(2) {
                guard let tuple = captures(
                    line,
                    pattern: #"^(%[0-9]+) = tuple(?: \$\([^\n]*\))? \((.*)\)$"#
                ) else { return nil }
                let operands = splitTopLevel(tuple[1]).compactMap { component in
                    component.split(separator: ":", maxSplits: 1).first.map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                }
                tupleDefinitions[tuple[0]] = operands
            }

            func matches(
                _ token: String,
                plan: StructFieldPlan
            ) -> Bool {
                switch plan {
                case let .parameter(index, _):
                    return token == "%\(index)"
                case let .tuple(_, elements):
                    guard let operands = tupleDefinitions[token],
                          operands.count == elements.count
                    else { return false }
                    return zip(operands, elements).allSatisfy(matches)
                }
            }

            let operands = splitTopLevel(construction[2]).compactMap {
                $0.split(separator: ":", maxSplits: 1).first.map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }
            guard operands.count == fields.count else { return nil }
            guard zip(operands, fieldPlans).allSatisfy(matches) else {
                return nil
            }
            return .init(
                key: key,
                fieldPlans: fieldPlans,
                physicalParameterTypes: physicalParameterTypes
            )
        }

        guard rawResult.hasPrefix("@out "), semanticLines.count >= 2,
              let emptyTuple = captures(
            semanticLines[semanticLines.count - 2],
            pattern: #"^(%[0-9]+) = tuple \(\)$"#
        ), let returned = captures(
            semanticLines[semanticLines.count - 1],
            pattern: #"^return (%[0-9]+)$"#
        ), returned[0] == emptyTuple[0]
        else { return nil }

        var expectedPaths: [Int: [Int]] = [:]
        func recordExpectedPaths(
            _ plan: StructFieldPlan,
            path: [Int]
        ) {
            switch plan {
            case let .parameter(index, _):
                expectedPaths[index] = path
            case let .tuple(_, elements):
                for (index, element) in elements.enumerated() {
                    recordExpectedPaths(element, path: path + [index])
                }
            }
        }
        for (fieldIndex, plan) in fieldPlans.enumerated() {
            recordExpectedPaths(plan, path: [fieldIndex])
        }

        var addressPaths: [String: [Int]] = ["%0": []]
        var initializedParameters = Set<Int>()
        for line in semanticLines.dropLast(2) {
            if let projection = captures(
                line,
                pattern: #"^(%[0-9]+) = struct_element_addr (%[0-9]+), #(.+)\.([^.]+)$"#
            ), projection[1] == "%0",
               matchesLocalDeclaration(projection[2], concrete: key),
               let fieldIndex = fields.firstIndex(where: {
                   $0.name == projection[3]
               }) {
                addressPaths[projection[0]] = [fieldIndex]
                continue
            }
            if let projection = captures(
                line,
                pattern: #"^(%[0-9]+) = tuple_element_addr (%[0-9]+), ([0-9]+)$"#
            ), let base = addressPaths[projection[1]],
               let index = Int(projection[2]) {
                addressPaths[projection[0]] = base + [index]
                continue
            }
            let initialization = captures(
                line,
                pattern: #"^copy_addr(?: \[take\])? (%[0-9]+) to \[init\] (%[0-9]+)$"#
            ) ?? captures(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init)\] )?(%[0-9]+)$"#
            )
            guard let initialization,
                  let rawParameter = Int(initialization[0].dropFirst()),
                  rawParameter > 0,
                  let destinationPath = addressPaths[initialization[1]],
                  expectedPaths[rawParameter - 1] == destinationPath,
                  initializedParameters.insert(rawParameter - 1).inserted
            else { return nil }
        }
        guard initializedParameters == Set(expectedPaths.keys) else {
            return nil
        }
        return .init(
            key: key,
            fieldPlans: fieldPlans,
            physicalParameterTypes: physicalParameterTypes
        )
    }

    private func detectClassAllocator(
        _ function: CanonicalSIL.Function
    ) throws -> Bytecode.LocalTypeKey? {
        guard let arrow = CanonicalSIL.FunctionTypeSyntax.outerArrow(
            in: function.loweredType
        ) else {
            return nil
        }
        var rawResult = function.loweredType[arrow.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        if rawResult.hasPrefix("@owned ") {
            rawResult.removeFirst("@owned ".count)
        }
        guard case let .local(key) = try? resolve(rawResult), isClass(key) else {
            return nil
        }
        let parameters = function.loweredType[..<arrow.lowerBound]
        return parameters.contains("@thick \(key.rawValue).Type") ? key : nil
    }

    private func structFactoryShape(
        _ function: CanonicalSIL.Function
    ) throws -> (
        key: Bytecode.LocalTypeKey,
        fields: [Bytecode.LocalStructField],
        fieldPlans: [StructFieldPlan],
        physicalParameterTypes: [Bytecode.ValueType],
        rawResult: String
    )? {
        guard let arrow = CanonicalSIL.FunctionTypeSyntax.outerArrow(
            in: function.loweredType
        ) else {
            return nil
        }
        let rawResult = String(function.loweredType[arrow.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard case let .local(key) = try? resolve(rawResult),
              case let .structure(fields) = try definition(for: key).kind
        else { return nil }
        let prefix = String(function.loweredType[..<arrow.lowerBound])
        guard let parametersRange = outerParameterTuple(in: prefix)
        else { return nil }
        let parameters = splitTopLevel(String(prefix[parametersRange]))

        var physicalParameterTypes: [Bytecode.ValueType] = []
        func makePlan(_ type: Bytecode.ValueType) -> StructFieldPlan {
            if case let .tuple(elements) = type {
                return .tuple(
                    type: type,
                    elements: elements.map(makePlan)
                )
            }
            let index = physicalParameterTypes.count
            physicalParameterTypes.append(type)
            return .parameter(index: index, type: type)
        }
        let fieldPlans = fields.map { makePlan($0.type) }

        guard parameters.count == physicalParameterTypes.count + 1,
              var metatype = parameters.last?
                .trimmingCharacters(in: .whitespaces),
              metatype.hasPrefix("@thin "),
              metatype.hasSuffix(".Type")
        else { return nil }
        metatype.removeFirst("@thin ".count)
        metatype.removeLast(".Type".count)
        guard localKey(for: metatype) == key else { return nil }
        for (parameter, expectedType) in zip(
            parameters.dropLast(),
            physicalParameterTypes
        ) {
            guard ValueRepresentation.storable(try resolve(parameter))
                    == expectedType
            else { return nil }
        }
        return (
            key,
            fields,
            fieldPlans,
            physicalParameterTypes,
            rawResult
        )
    }

    /// Finds the final balanced parameter tuple in a function-type prefix.
    /// Looking for the last `(` is incorrect once a parameter is itself a
    /// tuple or closure, because that delimiter belongs to the nested type.
    private func outerParameterTuple(
        in prefix: String
    ) -> Range<String.Index>? {
        guard let close = prefix.lastIndex(of: ")"),
              let open = CanonicalSIL.FunctionTypeSyntax
                .matchingOpeningParenthesis(for: close, in: prefix)
        else { return nil }
        return prefix.index(after: open)..<close
    }

    private func resultKey(
        success: Bytecode.ValueType,
        failure: Bytecode.ValueType
    ) -> Bytecode.LocalTypeKey {
        .init(rawValue: "Swift.Result<\(success), \(failure)>")
    }

    private static func extractDefinitions(
        _ text: String
    ) throws -> DefinitionInventory {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var parser = DefinitionParser(lines: lines)
        return try parser.parse()
    }

    private static func nominalHeader(
        in line: String
    ) throws -> NominalHeader? {
        guard let captures = captures(
            line,
            pattern: nominalHeaderPattern
        ) else { return nil }
        var declaration = captures[2]
            .trimmingCharacters(in: .whitespaces)
        let requirements: String?
        let wherePartition: (before: String, after: String)?
        do {
            wherePartition = try CanonicalSIL.GenericSignature
                .partitionTopLevel(declaration, at: " where ")
        } catch {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "nominal declaration has unbalanced generic syntax"
            )
        }
        if let partition = wherePartition {
            guard !partition.before.isEmpty, !partition.after.isEmpty else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "nominal declaration has an empty where clause"
                )
            }
            declaration = partition.before
            requirements = partition.after
        } else {
            requirements = nil
        }

        let name: String
        let conformances: [String]
        let inheritancePartition: (before: String, after: String)?
        do {
            inheritancePartition = try CanonicalSIL.GenericSignature
                .partitionTopLevel(declaration, at: ":")
        } catch {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "nominal declaration has unbalanced inheritance syntax"
            )
        }
        if let partition = inheritancePartition {
            guard !partition.before.isEmpty, !partition.after.isEmpty else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "nominal declaration has an empty inheritance clause"
                )
            }
            name = partition.before
            do {
                conformances = try CanonicalSIL.GenericSignature
                    .splitTopLevel(partition.after)
            } catch {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "nominal inheritance clause is malformed"
                )
            }
            guard conformances.allSatisfy({ !$0.isEmpty }) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "nominal inheritance clause contains an empty type"
                )
            }
        } else {
            name = declaration
            conformances = []
        }
        guard !name.isEmpty else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "nominal declaration has no name"
            )
        }
        return .init(
            isFinal: !captures[0].isEmpty,
            declaredAccess: declaredAccess(in: line),
            kind: captures[1],
            name: name,
            conformances: conformances,
            requirements: requirements
        )
    }

    private static func declaredAccess(in line: String) -> String? {
        captures(line, pattern: #"^(?:@[^\s]+\s+)*(public|internal|package|private|fileprivate)\s"#)?.first
    }

    private static let nominalHeaderPattern =
        #"^(?:(?:@[^\s]+|public|internal|package|private|fileprivate)\s+)*(?:(final)\s+)?(?:indirect )?(struct|enum|class)\s+(.+?)\s*\{$"#
    private static let extensionHeaderPattern =
        #"^(?:(?:@[^\s]+|public|internal|package|private|fileprivate)\s+)*extension\s+([^\s:{]+)(?:\s*:\s*[^\{]+)?(?:\s+where\s+[^\{]+)?\s*\{$"#
    private static let storedFieldPattern =
        #"^(?:@[^\s]+\s+)*@_hasStorage\s+(?:@[^\s]+\s+)*(?:(?:public|internal|package|private|fileprivate)\s+)?(?:final\s+)?(?:var|let)\s+([^:]+):\s*(.+?)(?:\s*\{.*)?$"#
    private static let enumCaseDeclarationPattern =
        #"^([^\s(,]+)(?:\((.*)\))?$"#

    private static let hostedMethodPattern =
        #"^(?:(?:@[^\s]+|public|internal|package|private|fileprivate|override|final|dynamic|class|nonisolated)\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)(?:\s+(?:async|throws|rethrows))*\s*$"#

    // Only fixed grammar expressions are shared. Source-dependent patterns
    // retain their existing lifetime and cannot grow an unbounded global cache.
    private static let declarationExpressions: [String: NSRegularExpression] = {
        let patterns = [nominalHeaderPattern, extensionHeaderPattern,
                        storedFieldPattern, enumCaseDeclarationPattern, hostedMethodPattern]
        return Dictionary(uniqueKeysWithValues: patterns.map { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                preconditionFailure("invalid internal SIL declaration expression")
            }
            return (pattern, expression)
        })
    }()

    private static func hasUnsupportedFrozenExistential(
        in spelling: String
    ) -> Bool {
        CanonicalSIL.ProtocolExistential.Identity.containsProtocolExistential(
            in: spelling
        ) || spelling.range(
            of: #"(?<![A-Za-z0-9_])(?:Swift\.)?AnyObject(?![A-Za-z0-9_])"#,
            options: .regularExpression
        ) != nil
    }

    private static func hostedMethodDeclaration(
        in line: String
    ) -> RawHostedMethod? {
        guard let capture = captures(line, pattern: hostedMethodPattern) else {
            return nil
        }
        guard let functionKeyword = line.range(
            of: #"\bfunc\s+"#,
            options: .regularExpression
        ) else { return nil }
        let declarationPrefix = String(line[..<functionKeyword.lowerBound])
        let modifiers = declarationPrefix.split(whereSeparator: \.isWhitespace)
        guard modifiers.contains("override"),
              !modifiers.contains("class"),
              !modifiers.contains("static")
        else { return nil }
        let name = capture[0]
        let explicitSelector = captures(
            declarationPrefix,
            pattern: #"@objc\(([^)]+)\)"#
        )?.first
        let parameters = capture[1].trimmingCharacters(in: .whitespaces)
        if parameters.isEmpty {
            return .init(
                name: name,
                selector: explicitSelector ?? name,
                abi: .voidNoArguments
            )
        }
        guard let parameter = hostedBooleanParameter(parameters) else {
            return nil
        }
        let selector = explicitSelector ?? {
            guard parameter.externalLabel != "_" else { return "\(name):" }
            let label = parameter.externalLabel
            let initial = label.prefix(1).uppercased()
            return "\(name)With\(initial)\(label.dropFirst()):"
        }()
        return .init(name: name, selector: selector, abi: .voidBool)
    }

    private static func hostedBooleanParameter(
        _ declaration: String
    ) -> (externalLabel: String, localName: String)? {
        guard !declaration.contains(","),
              let colon = declaration.firstIndex(of: ":")
        else { return nil }
        let names = declaration[..<colon].split(whereSeparator: \.isWhitespace)
        guard !names.isEmpty, names.count <= 2 else { return nil }
        let type = declaration[declaration.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "Swift.", with: "")
        guard type == "Bool" else { return nil }
        let external = String(names[0])
        let local = String(names.count == 2 ? names[1] : names[0])
        guard external == "_" || isSwiftIdentifier(external),
              isSwiftIdentifier(local)
        else { return nil }
        return (external, local)
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func enumCaseDeclarations(
        in line: String
    ) throws -> [RawEnumCase]? {
        let body: Substring
        if line.hasPrefix("case ") {
            body = line.dropFirst("case ".count)
        } else if line.hasPrefix("indirect case ") {
            body = line.dropFirst("indirect case ".count)
        } else {
            return nil
        }

        let declarations = splitTopLevel(String(body))
        guard !declarations.isEmpty else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "enum case declaration is empty"
            )
        }
        return try declarations.map { declaration in
            guard !declaration.isEmpty,
                  let captures = captures(
                    declaration,
                    pattern: enumCaseDeclarationPattern
                  ),
                  isSwiftDeclarationIdentifier(captures[0])
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "invalid enum case declaration \(line)"
                )
            }
            let associatedTypes = captures[1].isEmpty
                ? [] : splitTopLevel(captures[1])
            guard associatedTypes.allSatisfy({ !$0.isEmpty }) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "enum case declaration has an empty associated value"
                )
            }
            return .init(
                name: captures[0],
                associatedTypes: associatedTypes,
                hasAvailabilityConstraint: false
            )
        }
    }

    private static func isSwiftDeclarationIdentifier(_ value: String) -> Bool {
        if value.hasPrefix("`"), value.hasSuffix("`"), value.count > 2 {
            return isSwiftIdentifier(String(value.dropFirst().dropLast()))
        }
        return isSwiftIdentifier(value)
    }

    private static func qualified(
        _ name: String,
        relativeTo parentScope: String?
    ) -> String {
        guard !name.contains("."), let parentScope, !parentScope.isEmpty else {
            return name
        }
        return "\(parentScope).\(name)"
    }

    private static func parentScope(of name: String) -> String? {
        guard let separator = name.lastIndex(of: ".") else { return nil }
        return String(name[..<separator])
    }

    private static func braceDelta(in line: String) -> Int {
        var depth = 0
        var isQuoted = false
        var isEscaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\", isQuoted {
                isEscaped = true
            } else if character == "\"" {
                isQuoted.toggle()
            } else if !isQuoted, character == "/" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "/" { break }
            } else if !isQuoted, character == "{" {
                depth += 1
            } else if !isQuoted, character == "}" {
                depth -= 1
            }
            index = line.index(after: index)
        }
        return depth
    }

    private func genericBody(_ type: String, prefix: String) -> String {
        let start = type.index(type.startIndex, offsetBy: prefix.count)
        return String(type[start..<type.index(before: type.endIndex)])
    }

    private func dictionaryType(
        key rawKey: String,
        value rawValue: String,
        relativeTo parentScope: String?
    ) throws -> Bytecode.ValueType {
        let key = ValueRepresentation.storable(
            try resolve(rawKey, relativeTo: parentScope)
        )
        guard key.isVMHashable else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "Dictionary key \(key) does not have VM-defined Hashable semantics"
            )
        }
        return .dictionary(
            key: key,
            value: ValueRepresentation.storable(
                try resolve(rawValue, relativeTo: parentScope)
            )
        )
    }

    private func splitTopLevelKeyValue(
        _ raw: String
    ) -> (key: String, value: String)? {
        var depth = 0
        for index in raw.indices {
            switch raw[index] {
            case "(", "<", "[": depth += 1
            case ")", "]": depth -= 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)]
                    : nil
                if previous != "-" { depth -= 1 }
            case ":" where depth == 0:
                let key = String(raw[..<index])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(raw[raw.index(after: index)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !value.isEmpty else { return nil }
                return (key, value)
            default: break
            }
        }
        return nil
    }

    private func splitTopLevelTuple(_ raw: String) -> [String] {
        guard raw.hasPrefix("("), raw.hasSuffix(")") else { return [raw] }
        return splitTopLevel(String(raw.dropFirst().dropLast()))
    }

    private func removeTupleLabel(_ raw: String) -> String {
        var depth = 0
        for index in raw.indices {
            switch raw[index] {
            case "(", "<", "[": depth += 1
            case ")", "]": depth -= 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)]
                    : nil
                if previous != "-" { depth -= 1 }
            case ":" where depth == 0:
                return String(raw[raw.index(after: index)...])
                    .trimmingCharacters(in: .whitespaces)
            default: break
            }
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    private func splitTopLevel(_ raw: String) -> [String] {
        Self.splitTopLevel(raw)
    }

    private static func splitTopLevel(_ raw: String) -> [String] {
        var result: [String] = []
        var start = raw.startIndex
        var depth = 0
        for index in raw.indices {
            switch raw[index] {
            case "(", "<", "[": depth += 1
            case ")", "]": depth -= 1
            case ">":
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)]
                    : nil
                if previous != "-" { depth -= 1 }
            case "," where depth == 0:
                result.append(
                    String(raw[start..<index]).trimmingCharacters(in: .whitespaces)
                )
                start = raw.index(after: index)
            default: break
            }
        }
        result.append(String(raw[start...]).trimmingCharacters(in: .whitespaces))
        return result
    }

    private func captures(_ value: String, pattern: String) -> [String]? {
        Self.captures(value, pattern: pattern)
    }

    private static func captures(_ value: String, pattern: String) -> [String]? {
        guard let expression = declarationExpressions[pattern]
            ?? (try? NSRegularExpression(pattern: pattern)) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }
}
}
