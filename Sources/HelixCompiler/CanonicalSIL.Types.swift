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
    }

    private struct RawEnumCase: Sendable {
        var name: String
        var associatedTypes: [String]
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
    }

    private struct DefinitionParser {
        let lines: [String]
        var index = 0
        var definitions: [Bytecode.LocalTypeKey: RawDefinition] = [:]

        // Canonical SIL starts with a declaration summary before function
        // bodies. Walk that brace tree so nested namespace identities remain
        // exact without treating arbitrary SIL text as a Swift type parser.
        mutating func parse() throws -> [Bytecode.LocalTypeKey: RawDefinition] {
            try scanScope(parentScope: nil, stopsAtClosingBrace: false)
            return definitions
        }

        private mutating func scanScope(
            parentScope: String?,
            stopsAtClosingBrace: Bool
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
                    index += 1
                    try scanScope(parentScope: scope, stopsAtClosingBrace: true)
                    continue
                }
                if let header = TypeEnvironment.captures(
                    line,
                    pattern: TypeEnvironment.nominalHeaderPattern
                ) {
                    try parseNominal(header, parentScope: parentScope)
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
            _ header: [String],
            parentScope: String?
        ) throws {
            let shortName = header[2]
            guard !shortName.contains("<") else {
                try skipBracedDeclaration()
                return
            }
            let name = TypeEnvironment.qualified(
                shortName,
                relativeTo: parentScope
            )
            let key = Bytecode.LocalTypeKey(rawValue: name)
            var fields: [RawField] = []
            var cases: [RawEnumCase] = []
            var hostedMethods: [RawHostedMethod] = []
            index += 1

            while index < lines.count {
                let member = lines[index].trimmingCharacters(in: .whitespaces)
                if member == "}" {
                    index += 1
                    let conformances = header[3]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    // Existing non-final classes belong to the frozen Shell. A
                    // downloaded image can add only final logical classes, so
                    // do not accidentally reinterpret an ordinary app class as
                    // patch-local while the Shell is still being indexed.
                    if header[1] == "class", header[0].isEmpty {
                        return
                    }
                    let kind: RawKind
                    switch header[1] {
                    case "struct":
                        kind = .structure(fields)
                    case "enum":
                        kind = .enumeration(cases)
                    case "class":
                        let inherited = conformances.first
                        kind = .class(
                            fields: fields,
                            superclass: inherited,
                            isFinal: !header[0].isEmpty,
                            hostedMethods: hostedMethods
                        )
                    default:
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "unknown nominal declaration kind \(header[1])"
                        )
                    }
                    let definition = RawDefinition(
                        key: key,
                        parentScope: TypeEnvironment.parentScope(of: name),
                        kind: kind,
                        conformsToError: conformances.contains("Error")
                            || conformances.contains("Swift.Error")
                    )
                    guard definitions.updateValue(definition, forKey: key) == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "duplicate nominal type \(name)"
                        )
                    }
                    return
                }
                if let nested = TypeEnvironment.captures(
                    member,
                    pattern: TypeEnvironment.nominalHeaderPattern
                ) {
                    try parseNominal(nested, parentScope: name)
                    continue
                }
                if header[1] == "struct" || header[1] == "class",
                   let field = TypeEnvironment.captures(
                    member,
                    pattern: TypeEnvironment.storedFieldPattern
                   ) {
                    fields.append(.init(name: field[0], type: field[1]))
                } else if header[1] == "class",
                          let method = TypeEnvironment.hostedMethodDeclaration(
                            in: member
                          ) {
                    hostedMethods.append(method)
                } else if header[1] == "enum",
                          let item = TypeEnvironment.captures(
                    member,
                    pattern: TypeEnvironment.enumCasePattern
                          ) {
                    cases.append(
                        .init(
                            name: item[0],
                            associatedTypes: item[1].isEmpty
                                ? []
                                : TypeEnvironment.splitTopLevel(item[1])
                        )
                    )
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
    private var structFactories: [String: StructFactory]
    private var classAllocators: [String: Bytecode.LocalTypeKey]
    private var requiresTypedErrors: Bool
    private var nativeTypes: [String: Core.TypeID]
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
        structFactories = [:]
        classAllocators = [:]
        requiresTypedErrors = false
        nativeTypes = [:]
        nativeTypeKinds = [:]
        mainActorNativeTypes = []
    }

    init(text: String, functions: [CanonicalSIL.Function]) throws {
        rawDefinitions = try Self.extractDefinitions(text)
        structFactories = [:]
        classAllocators = [:]
        nativeTypes = [:]
        nativeTypeKinds = [:]
        mainActorNativeTypes = []
        // Payload-free throws use the lightweight String error representation.
        // Typed storage is enabled only when SIL semantics or a local declaration needs it.
        requiresTypedErrors = text.contains("checked_cast_addr_br")
            || text.contains("Result<")
            || rawDefinitions.values.contains(where: Self.hasStoredErrorPayload)
        for function in functions {
            if let factory = try detectStructFactory(function) {
                structFactories[function.mangledName] = factory
            }
            if let key = try detectClassAllocator(function) {
                classAllocators[function.mangledName] = key
            }
        }
    }

    /// Returns an environment that resolves the exact native types frozen in
    /// the target Shell. Both module-qualified SIL spellings and their
    /// module-relative form are accepted; ambiguous aliases fail closed.
    func includingNativeTypes(
        _ records: [String: Core.TypeID],
        kinds: [Core.TypeID: InterfaceArchive.TypeKind] = [:],
        requiresMainActor: Set<Core.TypeID> = []
    ) throws -> Self {
        let frozenTypeIDs = Set(records.values)
        guard Set(kinds.keys).isSubset(of: frozenTypeIDs),
              requiresMainActor.isSubset(of: frozenTypeIDs)
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
                result.structFactories = result.structFactories.filter {
                    $0.value.key != local
                }
                result.classAllocators = result.classAllocators.filter { $0.value != local }
            }
            var aliases = [canonicalName]
            if let separator = canonicalName.firstIndex(of: ".") {
                aliases.append(String(canonicalName[canonicalName.index(after: separator)...]))
            }
            for alias in aliases {
                guard !alias.isEmpty, result.localKey(for: alias) == nil else {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "native type \(canonicalName) conflicts with local type \(alias)"
                    )
                }
                if let existing = result.nativeTypes[alias], existing != id {
                    throw CanonicalSIL.LoweringError.invalidCallTable(
                        "native type alias \(alias) resolves to multiple TypeIDs"
                    )
                }
                result.nativeTypes[alias] = id
            }
        }
        return result
    }

    func containsReferenceNativeValue(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case let .native(id):
            nativeTypeKinds[id] == .reference
        case let .optional(wrapped):
            containsReferenceNativeValue(wrapped)
        case let .mutableCell(pointee):
            containsReferenceNativeValue(pointee)
        case let .arrayBuilder(element):
            containsReferenceNativeValue(element)
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

    var preservesTypedErrors: Bool {
        requiresTypedErrors
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

    func resolve(_ raw: String) throws -> Bytecode.ValueType {
        try resolve(raw, relativeTo: nil)
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
                "@in ",
                "@in_guaranteed ",
                "@out ",
            ]
            where type.hasPrefix(ownership) {
                type.removeFirst(ownership.count)
                removedPrefix = true
            }
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
            return .mutableCell(
                ValueRepresentation.storable(
                    try resolve(
                        String(contents.dropFirst("var ".count)),
                        relativeTo: parentScope
                    )
                )
            )
        }

        if type.contains(" -> ") {
            return .closure(
                try resolveClosureSignature(type, relativeTo: parentScope)
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
        // Their supported APIs observe sequence elements, not private storage
        // or index wrappers, so lowering normalizes them to the VM's typed
        // Array representation and keeps unsupported index APIs fail-closed.
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
            let base = ValueRepresentation.storable(
                try resolve(
                    genericBody(type, prefix: reversedPrefix),
                    relativeTo: parentScope
                )
            )
            guard case .array = base else {
                throw CanonicalSIL.LoweringError.unsupportedType(type)
            }
            return base
        }
        for enumeratedPrefix in [
            "EnumeratedSequence<", "Swift.EnumeratedSequence<",
        ] where type.hasPrefix(enumeratedPrefix) && type.hasSuffix(">") {
            let base = ValueRepresentation.storable(
                try resolve(
                    genericBody(type, prefix: enumeratedPrefix),
                    relativeTo: parentScope
                )
            )
            guard case let .array(element) = base else {
                throw CanonicalSIL.LoweringError.unsupportedType(type)
            }
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
            let sequences = try components.map {
                ValueRepresentation.storable(
                    try resolve($0, relativeTo: parentScope)
                )
            }
            guard case let .array(lhs) = sequences[0],
                  case let .array(rhs) = sequences[1]
            else {
                throw CanonicalSIL.LoweringError.unsupportedType(type)
            }
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
        for dictionaryPrefix in ["Dictionary<", "Swift.Dictionary<"]
        where type.hasPrefix(dictionaryPrefix) && type.hasSuffix(">") {
            let components = splitTopLevel(genericBody(type, prefix: dictionaryPrefix))
            guard components.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Dictionary generic arguments must contain Key and Value"
                )
            }
            let key = ValueRepresentation.storable(
                try resolve(components[0], relativeTo: parentScope)
            )
            guard key.isVMHashable else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "Dictionary key \(key) does not have VM-defined Hashable semantics"
                )
            }
            return .dictionary(
                key: key,
                value: ValueRepresentation.storable(
                    try resolve(components[1], relativeTo: parentScope)
                )
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
            if elements.count == 1, elements[0].isEmpty { return .void }
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
        case "Any", "Swift.Any": return .any
        case "any Error", "Swift.Error": return preservesTypedErrors ? .error : .string
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

    func localKey(for raw: String) -> Bytecode.LocalTypeKey? {
        localKey(for: raw, relativeTo: nil)
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

    private func localKeys(
        matchingNativeName canonicalName: String
    ) -> [Bytecode.LocalTypeKey] {
        var spellings = Set([canonicalName])
        if let separator = canonicalName.firstIndex(of: ".") {
            spellings.insert(String(canonicalName[canonicalName.index(after: separator)...]))
        }
        return rawDefinitions.keys.filter { spellings.contains($0.rawValue) }.sorted()
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
        var removedAttribute = true
        while removedAttribute {
            removedAttribute = false
            for attribute in [
                "@noescape ",
                "@callee_guaranteed ",
                "@callee_owned ",
            ] where type.hasPrefix(attribute) {
                type.removeFirst(attribute.count)
                removedAttribute = true
            }
        }
        guard !type.hasPrefix("@convention("),
              !type.hasPrefix("@async "),
              !type.contains(" @async "),
              let arrow = outerClosureArrow(in: type)
        else {
            throw CanonicalSIL.LoweringError.unsupportedType(raw)
        }
        let parameterTuple = String(type[..<arrow.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard parameterTuple.first == "(", parameterTuple.last == ")" else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "closure type has no parameter tuple: \(raw)"
            )
        }
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
        let mayThrow: Bool
        if resultComponents.count == 1,
           let error = try closureErrorChannel(
            resultComponents[0],
            relativeTo: parentScope
           ) {
            result = .void
            mayThrow = error
        } else if resultComponents.count == 2,
                  let error = try closureErrorChannel(
                    resultComponents[1],
                    relativeTo: parentScope
                  ) {
            result = try resolve(
                resultComponents[0],
                relativeTo: parentScope
            )
            mayThrow = error
        } else {
            result = try resolve(resultText, relativeTo: parentScope)
            mayThrow = false
        }
        return .init(
            parameters: parameters,
            parameterConventions: parameterConventions,
            result: result,
            effects: .init(mayThrow: mayThrow)
        )
    }

    private func closureParameterConvention(
        _ raw: String,
        parameter: Bytecode.ValueType
    ) -> Bytecode.ParameterConvention {
        let spelling = raw.trimmingCharacters(in: .whitespaces)
            .trimmingPrefix("$")
        let explicitlyBorrowed = spelling.hasPrefix("@guaranteed ")
            || spelling.hasPrefix("@unowned ")
            || spelling.hasPrefix("@in_guaranteed ")
        return parameter.requiresLinearOwnership && explicitlyBorrowed
            ? .borrowed
            : .owned
    }

    private func closureErrorChannel(
        _ raw: String,
        relativeTo parentScope: String?
    ) throws -> Bool? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let prefixes = ["@error_indirect ", "@error "]
        guard let prefix = prefixes.first(where: value.hasPrefix) else {
            return nil
        }
        let type = try resolve(
            String(value.dropFirst(prefix.count)),
            relativeTo: parentScope
        )
        switch type {
        case .never:
            return false
        case .string, .error:
            return true
        default:
            throw CanonicalSIL.LoweringError.malformedSIL(
                "closure has a non-Error error result"
            )
        }
    }

    private func outerClosureArrow(
        in text: String
    ) -> Range<String.Index>? {
        var parenthesisDepth = 0
        var angleDepth = 0
        var bracketDepth = 0
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "<": angleDepth += 1
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" { angleDepth -= 1 }
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            case "-" where parenthesisDepth == 0
                    && angleDepth == 0
                    && bracketDepth == 0:
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == ">" {
                    return index..<text.index(after: next)
                }
            default:
                break
            }
            guard parenthesisDepth >= 0,
                  angleDepth >= 0,
                  bracketDepth >= 0
            else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    func structFactory(_ mangledName: String) -> StructFactory? {
        structFactories[mangledName]
    }

    func classAllocator(_ mangledName: String) -> Bytecode.LocalTypeKey? {
        classAllocators[mangledName]
    }

    func isClassAllocator(_ mangledName: String) -> Bool {
        classAllocators[mangledName] != nil
    }

    func isHostedClassAllocator(_ mangledName: String) -> Bool {
        guard let key = classAllocators[mangledName] else { return false }
        return (try? hostedSuperclass(for: key)) != nil
    }

    func isStructFactory(_ mangledName: String) -> Bool {
        structFactories[mangledName] != nil
    }

    func hasStructFactorySignature(_ function: CanonicalSIL.Function) -> Bool {
        (try? structFactoryShape(function)) != nil
    }

    func definition(for key: Bytecode.LocalTypeKey) throws -> Bytecode.LocalTypeDefinition {
        if let raw = rawDefinitions[key] {
            let kind: Bytecode.LocalTypeKind
            switch raw.kind {
            case let .structure(fields):
                kind = .structure(
                    fields: try fields.map {
                        .init(
                            name: $0.name,
                            type: ValueRepresentation.storable(
                                try resolve(
                                    $0.type,
                                    relativeTo: raw.parentScope
                                )
                            )
                        )
                    }
                )
            case let .enumeration(cases):
                kind = .enumeration(
                    cases: try cases.map { item in
                        let payload: Bytecode.ValueType?
                        switch item.associatedTypes.count {
                        case 0:
                            payload = nil
                        case 1:
                            payload = ValueRepresentation.storable(
                                try resolve(
                                    removeTupleLabel(item.associatedTypes[0]),
                                    relativeTo: raw.parentScope
                                )
                            )
                        default:
                            payload = .tuple(
                                try item.associatedTypes.map {
                                    ValueRepresentation.storable(
                                        try resolve(
                                            removeTupleLabel($0),
                                            relativeTo: raw.parentScope
                                        )
                                    )
                                }
                            )
                        }
                        return .init(name: item.name, payloadType: payload)
                    }
                )
            case let .class(fields, superclass, isFinal, _):
                guard isFinal else {
                    throw CanonicalSIL.LoweringError.unsupportedType(
                        "non-final patch-local class \(key)"
                    )
                }
                let hostedSuperclass: Bytecode.HostedSuperclass?
                if let superclass {
                    switch try? resolve(superclass, relativeTo: raw.parentScope) {
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
                                    $0.type,
                                    relativeTo: raw.parentScope
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
                conformsToError: raw.conformsToError
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
                            payloadType: ValueRepresentation.storable(
                                try resolve(arguments[0])
                            )
                        ),
                        .init(
                            name: "failure",
                            payloadType: ValueRepresentation.storable(
                                try resolve(arguments[1])
                            )
                        ),
                    ]
                )
            )
        }
        throw CanonicalSIL.LoweringError.unsupportedType(key.rawValue)
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
                 let .arrayBuilder(element):
                collect(element)
            case let .dictionary(key, value):
                collect(key)
                collect(value)
            case let .tuple(elements):
                elements.forEach(collect)
            case let .closure(signature):
                (signature.parameters + [signature.result]).forEach(collect)
            case .void, .never, .bool, .integer, .float, .string, .any, .native,
                 .error:
                break
            }
        }
        for function in functions {
            for type in function.registerTypes + function.stackSlotTypes + [function.resultType] {
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
                 let .arrayBuilder(element):
                try typeDepth(element) + 1
            case let .dictionary(key, value):
                try max(typeDepth(key), typeDepth(value)) + 1
            case let .tuple(elements):
                try (elements.map(typeDepth).max() ?? 0) + 1
            case .closure:
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "closure stored in a local nominal type"
                )
            case .error:
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "Error existential stored in a local nominal type"
                )
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
        guard let raw = rawDefinitions[key] else { return false }
        if case .class = raw.kind { return true }
        return false
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
            ), projection[1] == "%0", localKey(for: projection[2]) == key,
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
        guard let arrow = function.loweredType.range(of: " -> ", options: .backwards) else {
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
        guard let arrow = function.loweredType.range(of: " -> ", options: .backwards) else {
            return nil
        }
        let rawResult = String(function.loweredType[arrow.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard case let .local(key) = try? resolve(rawResult),
              case let .structure(fields) = try definition(for: key).kind
        else { return nil }
        let prefix = String(function.loweredType[..<arrow.lowerBound])
        guard let open = prefix.lastIndex(of: "("),
              let close = prefix.lastIndex(of: ")"),
              open < close
        else { return nil }
        let parameters = splitTopLevel(String(prefix[prefix.index(after: open)..<close]))

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
              parameters.last?.trimmingCharacters(in: .whitespaces)
                == "@thin \(key.rawValue).Type"
        else { return nil }
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

    private func resultKey(
        success: Bytecode.ValueType,
        failure: Bytecode.ValueType
    ) -> Bytecode.LocalTypeKey {
        .init(rawValue: "Swift.Result<\(success), \(failure)>")
    }

    private static func extractDefinitions(
        _ text: String
    ) throws -> [Bytecode.LocalTypeKey: RawDefinition] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var parser = DefinitionParser(lines: lines)
        return try parser.parse()
    }

    private static let nominalHeaderPattern =
        #"^(?:(?:@[^\s]+|public|internal|package|private|fileprivate)\s+)*(?:(final)\s+)?(?:indirect )?(struct|enum|class)\s+([^\s:{]+)(?:\s*:\s*([^\{]+))?\s*\{$"#
    private static let extensionHeaderPattern =
        #"^(?:(?:@[^\s]+|public|internal|package|private|fileprivate)\s+)*extension\s+([^\s:{]+)(?:\s*:\s*[^\{]+)?(?:\s+where\s+[^\{]+)?\s*\{$"#
    private static let storedFieldPattern =
        #"^(?:@[^\s]+\s+)*@_hasStorage\s+(?:(?:public|internal|package|private|fileprivate)\s+)?(?:final\s+)?(?:var|let)\s+([^:]+):\s*(.+?)(?:\s*\{.*)?$"#
    private static let enumCasePattern =
        #"^(?:indirect )?case\s+([^\s(]+)(?:\((.*)\))?$"#

    private static let hostedMethodPattern =
        #"^(?:(?:@[^\s]+|public|internal|package|private|fileprivate|override|final|dynamic|class|nonisolated)\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)(?:\s+(?:async|throws|rethrows))*\s*$"#

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
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }
}
}
