import Foundation
import HelixBytecode
import HelixCore
import HelixInterface

extension CanonicalSIL {
public struct TypeEnvironment: Sendable {
    private struct RawField: Sendable {
        var name: String
        var type: String
    }

    private struct RawEnumCase: Sendable {
        var name: String
        var associatedTypes: [String]
    }

    private enum RawKind: Sendable {
        case structure([RawField])
        case enumeration([RawEnumCase])
    }

    private struct RawDefinition: Sendable {
        var key: Bytecode.LocalTypeKey
        var kind: RawKind
        var conformsToError: Bool
    }

    private var rawDefinitions: [Bytecode.LocalTypeKey: RawDefinition]
    private var structFactories: [String: Bytecode.LocalTypeKey]
    private var requiresTypedErrors: Bool
    private var nativeTypes: [String: Core.TypeID]
    private var nativeTypeKinds: [Core.TypeID: InterfaceArchive.TypeKind]

    public static let empty = Self()

    public init() {
        rawDefinitions = [:]
        structFactories = [:]
        requiresTypedErrors = false
        nativeTypes = [:]
        nativeTypeKinds = [:]
    }

    init(text: String, functions: [CanonicalSIL.Function]) throws {
        rawDefinitions = try Self.extractDefinitions(text)
        structFactories = [:]
        nativeTypes = [:]
        nativeTypeKinds = [:]
        // Keep payload-free legacy Error patches on the 1.0 String error path.
        // Typed storage is enabled only when the SIL or a local declaration needs it.
        requiresTypedErrors = text.contains("checked_cast_addr_br")
            || text.contains("Result<")
            || rawDefinitions.values.contains(where: Self.hasStoredErrorPayload)
        for function in functions {
            if let key = try detectStructFactory(function) {
                structFactories[function.mangledName] = key
            }
        }
    }

    /// Returns an environment that resolves the exact native types frozen in
    /// the target Shell. Both module-qualified SIL spellings and their
    /// module-relative form are accepted; ambiguous aliases fail closed.
    func includingNativeTypes(
        _ records: [String: Core.TypeID],
        kinds: [Core.TypeID: InterfaceArchive.TypeKind] = [:]
    ) throws -> Self {
        let frozenTypeIDs = Set(records.values)
        guard Set(kinds.keys).isSubset(of: frozenTypeIDs) else {
            throw CanonicalSIL.LoweringError.invalidCallTable(
                "native type kind metadata references an unknown TypeID"
            )
        }
        var result = self
        for (id, kind) in kinds {
            if let existing = result.nativeTypeKinds[id], existing != kind {
                throw CanonicalSIL.LoweringError.invalidCallTable(
                    "native TypeID \(id) has conflicting kind metadata"
                )
            }
            result.nativeTypeKinds[id] = kind
        }
        for (canonicalName, id) in records.sorted(by: { $0.key < $1.key }) {
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
        case let .tuple(elements):
            elements.contains(where: containsReferenceNativeValue)
        case .array, .dictionary:
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
        }
    }

    func resolve(_ raw: String) throws -> Bytecode.ValueType {
        var type = raw.trimmingCharacters(in: .whitespaces)
        if type.hasPrefix("$*") {
            return .address(try resolve(String(type.dropFirst(2))))
        }
        if type.hasPrefix("@inout ") {
            return .address(try resolve(String(type.dropFirst("@inout ".count))))
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

        if type.contains(" -> ") {
            return .closure(try resolveClosureSignature(type))
        }

        for optionalPrefix in ["Optional<", "Swift.Optional<"]
        where type.hasPrefix(optionalPrefix) && type.hasSuffix(">") {
            return .optional(try resolve(genericBody(type, prefix: optionalPrefix)))
        }
        for arrayPrefix in ["Array<", "Swift.Array<"]
        where type.hasPrefix(arrayPrefix) && type.hasSuffix(">") {
            return .array(try resolve(genericBody(type, prefix: arrayPrefix)))
        }
        for dictionaryPrefix in ["Dictionary<", "Swift.Dictionary<"]
        where type.hasPrefix(dictionaryPrefix) && type.hasSuffix(">") {
            let components = splitTopLevel(genericBody(type, prefix: dictionaryPrefix))
            guard components.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Dictionary generic arguments must contain Key and Value"
                )
            }
            let key = try resolve(components[0])
            guard Self.isSupportedDictionaryKey(key) else {
                throw CanonicalSIL.LoweringError.unsupportedType(
                    "Dictionary key \(key)"
                )
            }
            return .dictionary(key: key, value: try resolve(components[1]))
        }
        for resultPrefix in ["Result<", "Swift.Result<"]
        where type.hasPrefix(resultPrefix) && type.hasSuffix(">") {
            let components = splitTopLevel(genericBody(type, prefix: resultPrefix))
            guard components.count == 2 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "Result generic arguments must contain Success and Failure"
                )
            }
            let success = try resolve(components[0])
            let failure = try resolve(components[1])
            return .local(resultKey(success: success, failure: failure))
        }
        if type.hasPrefix("("), type.hasSuffix(")") {
            let elements = splitTopLevelTuple(type)
            if elements.count == 1, elements[0].isEmpty { return .void }
            return .tuple(try elements.map { try resolve(removeTupleLabel($0)) })
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
        case "Float", "Swift.Float", "Builtin.FPIEEE32": return .float(bitWidth: 32)
        case "Double", "Swift.Double", "Builtin.FPIEEE64": return .float(bitWidth: 64)
        case "CGFloat", "CoreFoundation.CGFloat", "CoreGraphics.CGFloat":
            return .float(bitWidth: 64)
        case "String", "Swift.String": return .string
        case "Any", "Swift.Any": return .any
        case "any Error", "Swift.Error": return preservesTypedErrors ? .error : .string
        case "Never", "Swift.Never": return .never
        default:
            if let id = nativeTypes[type] { return .native(id) }
            if let key = localKey(for: type) { return .local(key) }
            throw CanonicalSIL.LoweringError.unsupportedType(type)
        }
    }

    func localKey(for raw: String) -> Bytecode.LocalTypeKey? {
        let type = raw.trimmingCharacters(in: .whitespaces)
        let exact = Bytecode.LocalTypeKey(rawValue: type)
        if rawDefinitions[exact] != nil { return exact }
        guard let separator = type.firstIndex(of: ".") else { return nil }
        let withoutModule = Bytecode.LocalTypeKey(
            rawValue: String(type[type.index(after: separator)...])
        )
        return rawDefinitions[withoutModule] == nil ? nil : withoutModule
    }

    private func resolveClosureSignature(
        _ raw: String
    ) throws -> Bytecode.ClosureSignature {
        var type = raw.trimmingCharacters(in: .whitespaces)
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
              !type.hasPrefix("@error "),
              !type.contains(" @error "),
              let arrow = type.range(of: " -> ", options: .backwards)
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
        if components.count == 1, components[0].isEmpty {
            parameters = []
        } else {
            parameters = try components.map { try resolve(removeTupleLabel($0)) }
        }
        let result = try resolve(String(type[arrow.upperBound...]))
        return .init(parameters: parameters, result: result)
    }

    func structFactory(_ mangledName: String) -> Bytecode.LocalTypeKey? {
        structFactories[mangledName]
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
                        .init(name: $0.name, type: try resolve($0.type))
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
                            payload = try resolve(removeTupleLabel(item.associatedTypes[0]))
                        default:
                            payload = .tuple(
                                try item.associatedTypes.map {
                                    try resolve(removeTupleLabel($0))
                                }
                            )
                        }
                        return .init(name: item.name, payloadType: payload)
                    }
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
                        .init(name: "success", payloadType: try resolve(arguments[0])),
                        .init(name: "failure", payloadType: try resolve(arguments[1])),
                    ]
                )
            )
        }
        throw CanonicalSIL.LoweringError.unsupportedType(key.rawValue)
    }

    func definitions(
        referencedBy functions: [IntermediateRepresentation.Function]
    ) throws -> [Bytecode.LocalTypeDefinition] {
        var pending: [Bytecode.LocalTypeKey] = []
        var seen = Set<Bytecode.LocalTypeKey>()
        func collect(_ type: Bytecode.ValueType) {
            switch type {
            case let .local(key):
                if seen.insert(key).inserted { pending.append(key) }
            case let .array(element), let .optional(element), let .address(element):
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
            let item = try definition(for: key)
            result.append(item)
            switch item.kind {
            case let .structure(fields):
                fields.forEach { collect($0.type) }
            case let .enumeration(cases):
                cases.compactMap(\.payloadType).forEach(collect)
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
                try localTypeExpansionDepth(
                    dependency,
                    definitions: definitions,
                    visiting: &visiting,
                    depths: &depths
                )
            case let .array(element), let .optional(element), let .address(element):
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
    ) throws -> Bytecode.LocalTypeKey? {
        guard let shape = try structFactoryShape(function) else { return nil }
        let key = shape.key
        let fields = shape.fields
        let rawResult = shape.rawResult

        let semanticLines = function.body.split(separator: "\n").map { rawLine in
            CanonicalSIL.DebugMetadata.strippingComment(from: String(rawLine))
                .trimmingCharacters(in: .whitespaces)
        }.filter {
            !$0.isEmpty && !$0.hasPrefix("bb") && !$0.hasPrefix("debug_value")
        }
        if semanticLines.count == 2,
           let construction = captures(
            semanticLines[0],
            pattern: #"^(%[0-9]+) = struct \$([^ ]+) \((.*)\)$"#
           ), construction[1] == key.rawValue,
           let returned = captures(
            semanticLines[1],
            pattern: #"^return (%[0-9]+)$"#
           ), returned[0] == construction[0],
           splitTopLevel(construction[2]) == fields.indices.map({ "%\($0)" }) {
            return key
        }

        guard rawResult.hasPrefix("@out "),
              semanticLines.count == fields.count * 2 + 2
        else { return nil }
        var lineIndex = 0
        for (fieldIndex, field) in fields.enumerated() {
            guard let projection = captures(
                semanticLines[lineIndex],
                pattern: #"^(%[0-9]+) = struct_element_addr %0, #(.+)\.([^.]+)$"#
            ), projection[1] == key.rawValue,
               projection[2] == field.name
            else { return nil }
            let source = "%\(fieldIndex + 1)"
            let destination = projection[0]
            let initialization = semanticLines[lineIndex + 1]
            let copiesAddress = captures(
                initialization,
                pattern: #"^copy_addr(?: \[take\])? (%[0-9]+) to \[init\] (%[0-9]+)$"#
            ).map { $0 == [source, destination] } ?? false
            let storesValue = captures(
                initialization,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init)\] )?(%[0-9]+)$"#
            ).map { $0 == [source, destination] } ?? false
            guard copiesAddress || storesValue else { return nil }
            lineIndex += 2
        }
        guard let emptyTuple = captures(
            semanticLines[lineIndex],
            pattern: #"^(%[0-9]+) = tuple \(\)$"#
        ), let returned = captures(
            semanticLines[lineIndex + 1],
            pattern: #"^return (%[0-9]+)$"#
        ), returned[0] == emptyTuple[0]
        else { return nil }
        return key
    }

    private func structFactoryShape(
        _ function: CanonicalSIL.Function
    ) throws -> (key: Bytecode.LocalTypeKey, fields: [Bytecode.LocalStructField], rawResult: String)? {
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
        guard parameters.count == fields.count + 1,
              parameters.last?.trimmingCharacters(in: .whitespaces)
                == "@thin \(key.rawValue).Type"
        else { return nil }
        for (parameter, field) in zip(parameters.dropLast(), fields) {
            guard try resolve(parameter) == field.type else { return nil }
        }
        return (key, fields, rawResult)
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
        var result: [Bytecode.LocalTypeKey: RawDefinition] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard let header = captures(
                line,
                pattern: #"^(?:(?:@[^\s]+|public|internal|package|private|fileprivate)\s+)*(?:indirect )?(struct|enum)\s+([^\s:{]+)(?:\s*:\s*([^\{]+))?\s*\{$"#
            ) else {
                index += 1
                continue
            }
            let name = header[1]
            if name.contains("<") {
                index += 1
                continue
            }
            let key = Bytecode.LocalTypeKey(rawValue: name)
            var fields: [RawField] = []
            var cases: [RawEnumCase] = []
            index += 1
            while index < lines.count {
                let member = lines[index].trimmingCharacters(in: .whitespaces)
                if member == "}" { break }
                if header[0] == "struct",
                   let field = captures(
                    member,
                    pattern: #"^(?:@[^\s]+\s+)*@_hasStorage\s+(?:(?:public|internal|package|private|fileprivate)\s+)?(?:var|let)\s+([^:]+):\s*(.+?)(?:\s*\{.*)?$"#
                   ) {
                    fields.append(.init(name: field[0], type: field[1]))
                } else if header[0] == "enum",
                          let item = captures(
                    member,
                    pattern: #"^(?:indirect )?case\s+([^\s(]+)(?:\((.*)\))?$"#
                          ) {
                    cases.append(
                        .init(
                            name: item[0],
                            associatedTypes: item[1].isEmpty
                                ? []
                                : splitTopLevel(item[1])
                        )
                    )
                }
                index += 1
            }
            guard index < lines.count else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "unterminated nominal type \(name)"
                )
            }
            let conformances = header[2]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let definition = RawDefinition(
                key: key,
                kind: header[0] == "struct" ? .structure(fields) : .enumeration(cases),
                conformsToError: conformances.contains("Error")
                    || conformances.contains("Swift.Error")
            )
            guard result.updateValue(definition, forKey: key) == nil else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "duplicate nominal type \(name)"
                )
            }
            index += 1
        }
        return result
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

    private static func isSupportedDictionaryKey(
        _ type: Bytecode.ValueType
    ) -> Bool {
        switch type {
        case .bool, .integer, .string:
            true
        default:
            false
        }
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
