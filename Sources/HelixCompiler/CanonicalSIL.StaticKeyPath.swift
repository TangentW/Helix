import Foundation
import HelixBytecode
import HelixCore

extension CanonicalSIL {
/// Converts a fully static, read-only Swift KeyPath into an ordinary typed
/// access function. KeyPath metadata and objects remain compiler-only.
enum StaticKeyPath {
    struct Capture: Hashable, Sendable {
        var identity: String
        var rootType: Bytecode.ValueType
        var valueType: Bytecode.ValueType
    }

    struct Rewrite: Sendable {
        var function: CanonicalSIL.Function
        var adapter: CanonicalSIL.DirectCallBinding.ABIAdapter
    }

    struct RewriteError: Error, Equatable, Sendable, CustomStringConvertible {
        var symbol: String
        var reason: String

        var description: String { reason }
    }

    private struct Literal: Sendable {
        var token: String
        var capture: Capture
        var rootSpelling: String
        var valueSpelling: String
        var components: [Component]
    }

    private enum Component: Sendable {
        case stored(StoredComponent)
        case getter(GetterComponent)
        case optional(OptionalComponent)

        var outputType: Bytecode.ValueType {
            switch self {
            case let .stored(value): value.outputType
            case let .getter(value): value.outputType
            case let .optional(value): value.outputType
            }
        }

        var outputSpelling: String {
            switch self {
            case let .stored(value): value.outputSpelling
            case let .getter(value): value.outputSpelling
            case let .optional(value): value.outputSpelling
            }
        }

        var identity: String {
            switch self {
            case let .stored(value):
                "stored:\(value.ownerKey.rawValue)#\(value.fieldIndex):\(value.outputType)"
            case let .getter(value):
                "getter:\(value.propertyIdentity):\(value.symbol):\(value.loweredType)"
                    + ":\(value.inputConvention):\(value.hasIndirectResult)"
                    + ":\(value.inputType)->\(value.outputType)"
            case let .optional(value):
                "optional:\(value.operation.rawValue):\(value.inputType)->\(value.outputType)"
            }
        }
    }

    private struct OptionalComponent: Sendable {
        enum Operation: String, Sendable {
            case chain
            case force
            case wrap
        }

        var operation: Operation
        var inputType: Bytecode.ValueType
        var outputType: Bytecode.ValueType
        var outputSpelling: String
    }

    private struct StoredComponent: Sendable {
        enum Storage: Sendable {
            case structure
            case `class`
        }

        var storage: Storage
        var ownerKey: Bytecode.LocalTypeKey
        var ownerSpelling: String
        var fieldName: String
        var fieldIndex: Int
        var outputType: Bytecode.ValueType
        var outputSpelling: String
    }

    private struct GetterComponent: Sendable {
        var propertyIdentity: String
        var symbol: String
        var loweredType: String
        var inputType: Bytecode.ValueType
        var inputConvention: Bytecode.ParameterConvention
        var outputType: Bytecode.ValueType
        var outputSpelling: String
        var hasIndirectResult: Bool
    }

    private struct Builder {
        var nextValue = 1
        var nextBlock = 1
        var lines: [String]

        init(rootSpelling: String) {
            lines = ["bb0(%0 : $\(rootSpelling)):"]
        }

        mutating func value() -> String {
            defer { nextValue += 1 }
            return "%\(nextValue)"
        }

        mutating func append(_ instruction: String) {
            lines.append("  \(instruction)")
        }

        mutating func reserveBlock() -> Int {
            defer { nextBlock += 1 }
            return nextBlock
        }

        mutating func beginBlock(_ id: Int, parameter: (String, String)? = nil) {
            lines.append("")
            if let parameter {
                lines.append("bb\(id)(\(parameter.0) : $\(parameter.1)):")
            } else {
                lines.append("bb\(id):")
            }
        }
    }

    /// Finds the compiler-generated KeyPath-to-function thunks captured by one
    /// function and replaces each with a normal, typed projection function.
    static func rewrites(
        in owner: CanonicalSIL.Function,
        file: CanonicalSIL.File,
        environment: CanonicalSIL.TypeEnvironment
    ) throws -> [String: Rewrite] {
        var literals: [String: Literal] = [:]
        var symbols: [String: String] = [:]
        var result: [String: Rewrite] = [:]

        for rawLine in owner.body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = CanonicalSIL.DebugMetadata.strippingComment(from: String(rawLine))
                .trimmingCharacters(in: .whitespaces)
            if let literal = try parseLiteral(in: line, environment: environment) {
                literals[literal.token] = literal
                continue
            }
            if let reference = captures(
                line,
                pattern: #"^(%[0-9]+) = (?:dynamic_)?function_ref @([^\s:]+) : \$(.+)$"#
            ) {
                symbols[reference[0]] = reference[1]
                continue
            }
            if let alias = captures(
                line,
                pattern: #"^(%[0-9]+) = (?:begin_borrow|copy_value|move_value)(?: \[[^\]]+\])* (%[0-9]+)$"#
            ) {
                if let literal = literals[alias[1]] {
                    var copy = literal
                    copy.token = alias[0]
                    literals[alias[0]] = copy
                }
                if let symbol = symbols[alias[1]] {
                    symbols[alias[0]] = symbol
                }
                continue
            }
            guard let application = captures(
                line,
                pattern: #"^(%[0-9]+) = partial_apply(?: \[[^\]]+\])* (%[0-9]+)\((.*)\) : \$(.+)$"#
            ), let symbol = symbols[application[1]]
            else { continue }

            let captureTokens = silValues(in: application[2])
            guard captureTokens.count == 1,
                  let literal = literals[captureTokens[0]]
            else { continue }
            guard let thunk = file.function(mangledName: symbol) else {
                throw RewriteError(
                    symbol: symbol,
                    reason: "static KeyPath closure has no compiler-generated thunk body"
                )
            }
            do {
                try validateThunk(thunk, literal: literal, environment: environment)
                let rewritten = try synthesize(
                    symbol: symbol,
                    literal: literal,
                    environment: environment
                )
                let rewrite = Rewrite(
                    function: rewritten,
                    adapter: .staticKeyPathProjection(
                        identity: literal.capture.identity
                    )
                )
                if let existing = result[symbol] {
                    guard existing.function == rewrite.function,
                          existing.adapter == rewrite.adapter
                    else {
                        throw RewriteError(
                            symbol: symbol,
                            reason: "one KeyPath thunk is captured with different static paths"
                        )
                    }
                } else {
                    result[symbol] = rewrite
                }
            } catch let error as RewriteError {
                throw error
            } catch {
                throw RewriteError(symbol: symbol, reason: String(describing: error))
            }
        }
        return result
    }

    /// Parses a compiler-only KeyPath literal while lowering its owner. The
    /// returned value has no VM representation and may only satisfy a matching
    /// static projection adapter.
    static func capture(
        in instruction: String,
        environment: CanonicalSIL.TypeEnvironment
    ) throws -> (token: String, value: Capture)? {
        try parseLiteral(in: instruction, environment: environment).map {
            ($0.token, $0.capture)
        }
    }

    /// Resolves the physical type of a read-only KeyPath parameter without
    /// admitting KeyPath itself into Bytecode.ValueType.
    static func parameterTypes(
        in raw: String,
        environment: CanonicalSIL.TypeEnvironment
    ) throws -> (root: Bytecode.ValueType, value: Bytecode.ValueType)? {
        var spelling = stripSILTypeDecorations(raw)
        let prefixes = ["KeyPath<", "Swift.KeyPath<"]
        guard let prefix = prefixes.first(where: spelling.hasPrefix),
              spelling.hasSuffix(">")
        else { return nil }
        spelling.removeFirst(prefix.count)
        spelling.removeLast()
        let arguments = try splitTopLevel(spelling, separator: ",")
        guard arguments.count == 2 else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "KeyPath with malformed generic arguments"
            )
        }
        let root = ValueRepresentation.storable(
            try environment.resolve(arguments[0])
        )
        let value = ValueRepresentation.storable(
            try environment.resolve(arguments[1])
        )
        try validateEndpoint(root, role: "root")
        try validateEndpoint(value, role: "value")
        return (root, value)
    }

    static func isAccessorThunk(_ function: CanonicalSIL.Function) -> Bool {
        function.loweredType.range(
            of: #"@convention\s*\(\s*keypath_accessor_getter\s*\)"#,
            options: .regularExpression
        ) != nil
    }

    private static func parseLiteral(
        in instruction: String,
        environment: CanonicalSIL.TypeEnvironment
    ) throws -> Literal? {
        guard let marker = instruction.range(of: " = keypath $") else {
            return nil
        }
        let token = instruction[..<marker.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard token.first == "%", token.dropFirst().allSatisfy(\.isNumber) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "KeyPath literal has an invalid result token"
            )
        }
        let suffix = String(instruction[marker.upperBound...])
        guard let typeEnd = matchingAngleEnd(in: suffix),
              typeEnd < suffix.endIndex
        else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "KeyPath literal has a malformed concrete type"
            )
        }
        let typeSpelling = String(suffix[...typeEnd])
        guard let endpoints = try parameterTypes(
            in: typeSpelling,
            environment: environment
        ) else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "only static read-only KeyPath literals are supported"
            )
        }
        let descriptorStart = suffix.index(after: typeEnd)
        let descriptorSuffix = suffix[descriptorStart...]
            .trimmingCharacters(in: .whitespaces)
        guard descriptorSuffix.hasPrefix(",") else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "KeyPath literal has no static component descriptor"
            )
        }
        let descriptorBody = descriptorSuffix.dropFirst()
            .trimmingCharacters(in: .whitespaces)
        guard descriptorBody.hasPrefix("("),
              let descriptorEnd = matchingParenthesisEnd(in: descriptorBody)
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "KeyPath literal has a malformed component descriptor"
            )
        }
        let trailing = descriptorBody[descriptorBody.index(after: descriptorEnd)...]
            .trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "static KeyPath components with captured values"
            )
        }
        let componentStart = descriptorBody.index(after: descriptorBody.startIndex)
        let descriptor = descriptorBody[componentStart..<descriptorEnd]
        let clauses = try splitTopLevel(String(descriptor), separator: ";")
        let rootIndices = clauses.indices.filter {
            clauses[$0].hasPrefix("root $")
        }
        guard rootIndices.count == 1, let rootIndex = rootIndices.first,
              rootIndex + 1 < clauses.endIndex
        else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "KeyPath literal has no concrete root and component path"
            )
        }
        let qualifiers = Array(clauses[..<rootIndex])
        guard qualifiers.allSatisfy(isSupportedQualifier) else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "static KeyPath has an unproven descriptor qualifier"
            )
        }
        let rootSpelling = String(
            clauses[rootIndex].dropFirst("root $".count)
        )
            .trimmingCharacters(in: .whitespaces)
        let descriptorRoot = ValueRepresentation.storable(
            try environment.resolve(rootSpelling)
        )
        guard descriptorRoot == endpoints.root else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "KeyPath descriptor root differs from its concrete type"
            )
        }

        var currentType = endpoints.root
        var components: [Component] = []
        for clause in clauses[(rootIndex + 1)...] {
            let component = try parseComponent(
                clause,
                inputType: currentType,
                environment: environment
            )
            components.append(component)
            currentType = component.outputType
        }
        let optionalOperations = components.enumerated().compactMap {
            index, component -> (Int, OptionalComponent.Operation)? in
            guard case let .optional(value) = component else { return nil }
            return (index, value.operation)
        }
        let chainCount = optionalOperations.count { $0.1 == .chain }
        let wrapIndices = optionalOperations.compactMap {
            $0.1 == .wrap ? $0.0 : nil
        }
        if chainCount > 0 {
            guard case .optional = endpoints.value else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "optional KeyPath chaining does not produce an Optional value"
                )
            }
        }
        guard wrapIndices.count <= 1,
              wrapIndices.first.map({
                  chainCount > 0 && $0 == components.index(before: components.endIndex)
              }) ?? true
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "optional KeyPath wrap is not the final chained component"
            )
        }
        guard currentType == endpoints.value,
              let valueSpelling = components.last?.outputSpelling
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "KeyPath component result differs from its concrete value type"
            )
        }
        let identity = (qualifiers.map { "qualifier:\($0)" }
            + ["root:\(endpoints.root)"]
            + components.map(\.identity)
            + ["value:\(endpoints.value)"])
            .joined(separator: "|")
        return .init(
            token: String(token),
            capture: .init(
                identity: identity,
                rootType: endpoints.root,
                valueType: endpoints.value
            ),
            rootSpelling: rootSpelling,
            valueSpelling: valueSpelling,
            components: components
        )
    }

    private static func parseComponent(
        _ raw: String,
        inputType: Bytecode.ValueType,
        environment: CanonicalSIL.TypeEnvironment
    ) throws -> Component {
        let component = raw.trimmingCharacters(in: .whitespaces)
        if component.hasPrefix("stored_property #") {
            return try .stored(
                parseStoredComponent(
                    component,
                    inputType: inputType,
                    environment: environment
                )
            )
        }
        if component.hasPrefix("gettable_property $") {
            return try .getter(
                parseGetterComponent(
                    component,
                    inputType: inputType,
                    environment: environment
                )
            )
        }
        for (prefix, operation) in [
            ("optional_chain : $", OptionalComponent.Operation.chain),
            ("optional_force : $", OptionalComponent.Operation.force),
            ("optional_wrap : $", OptionalComponent.Operation.wrap),
        ] where component.hasPrefix(prefix) {
            let outputSpelling = String(component.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard !outputSpelling.isEmpty else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "optional KeyPath component has no result type"
                )
            }
            let outputType = ValueRepresentation.storable(
                try environment.resolve(outputSpelling)
            )
            switch operation {
            case .chain, .force:
                guard inputType == .optional(outputType) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "optional KeyPath projection does not unwrap its input"
                    )
                }
            case .wrap:
                guard outputType == .optional(inputType) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "optional KeyPath wrap does not contain its input"
                    )
                }
            }
            try validateEndpoint(outputType, role: "component value")
            return .optional(
                .init(
                    operation: operation,
                    inputType: inputType,
                    outputType: outputType,
                    outputSpelling: outputSpelling
                )
            )
        }
        throw CanonicalSIL.LoweringError.unsupportedType(
            "static KeyPath component `\(component)`"
        )
    }

    private static func parseStoredComponent(
        _ component: String,
        inputType: Bytecode.ValueType,
        environment: CanonicalSIL.TypeEnvironment
    ) throws -> StoredComponent {
        let prefix = "stored_property #"
        guard let typeMarker = component.range(of: " : $", options: .backwards) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "stored KeyPath component has no field type"
            )
        }
        let fieldStart = component.index(
            component.startIndex,
            offsetBy: prefix.count
        )
        let fieldIdentity = String(component[fieldStart..<typeMarker.lowerBound])
        guard let separator = fieldIdentity.lastIndex(of: ".") else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "stored KeyPath component has no owner"
            )
        }
        let ownerSpelling = String(fieldIdentity[..<separator])
        let fieldName = String(fieldIdentity[fieldIdentity.index(after: separator)...])
        let outputSpelling = String(component[typeMarker.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !ownerSpelling.isEmpty, !fieldName.isEmpty, !outputSpelling.isEmpty,
              let ownerKey = environment.localKey(for: ownerSpelling),
              inputType == .local(ownerKey)
        else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "stored KeyPath components require an exact patch-local owner"
            )
        }
        let definition = try environment.definition(for: ownerKey)
        let fields: [Bytecode.LocalStructField]
        let storage: StoredComponent.Storage
        switch definition.kind {
        case let .structure(values):
            fields = values
            storage = .structure
        case let .class(values, _, _):
            fields = values
            storage = .class
        case .enumeration:
            throw CanonicalSIL.LoweringError.unsupportedType(
                "stored KeyPath component on enum \(ownerKey)"
            )
        }
        let index = try environment.storedFieldIndex(
            type: ownerKey,
            name: fieldName
        )
        let outputType = ValueRepresentation.storable(
            try environment.resolve(outputSpelling)
        )
        guard fields.indices.contains(index), fields[index].type == outputType else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "stored KeyPath field type differs from \(ownerKey).\(fieldName)"
            )
        }
        try validateEndpoint(outputType, role: "component value")
        return .init(
            storage: storage,
            ownerKey: ownerKey,
            ownerSpelling: ownerSpelling,
            fieldName: fieldName,
            fieldIndex: index,
            outputType: outputType,
            outputSpelling: outputSpelling
        )
    }

    private static func parseGetterComponent(
        _ component: String,
        inputType: Bytecode.ValueType,
        environment: CanonicalSIL.TypeEnvironment
    ) throws -> GetterComponent {
        let fields = try splitTopLevel(component, separator: ",")
        guard fields.count >= 3,
              fields[0].hasPrefix("gettable_property $"),
              let id = fields.first(where: {
                  $0.hasPrefix("id @") || $0.hasPrefix("id #")
              }),
              let accessor = fields.first(where: { $0.hasPrefix("getter @") })
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "gettable KeyPath component has incomplete getter metadata"
            )
        }
        let outputSpelling = String(
            fields[0].dropFirst("gettable_property $".count)
        ).trimmingCharacters(in: .whitespaces)
        let outputType = ValueRepresentation.storable(
            try environment.resolve(outputSpelling)
        )
        try validateEndpoint(outputType, role: "component value")
        let keyPathAccessor = try parseFunctionMetadata(accessor, label: "getter")
        let lowerer = CanonicalSIL.Lowerer(typeEnvironment: environment)
        let accessorSignature = try lowerer.parseFunctionType(
            keyPathAccessor.loweredType
        )
        guard keyPathAccessor.loweredType.range(
                of: #"@convention\s*\(\s*keypath_accessor_getter\s*\)"#,
                options: .regularExpression
              ) != nil,
              accessorSignature.parameters == [inputType],
              accessorSignature.parameterConventions.count == 1,
              accessorSignature.parameterConventions[0] != .inout,
              accessorSignature.result == outputType,
              accessorSignature.hasIndirectResult,
              !accessorSignature.effects.mayThrow,
              !accessorSignature.effects.isAsync,
              accessorSignature.indirectErrorType == nil,
              accessorSignature.erasedMetatypes.isEmpty
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "KeyPath accessor @\(keyPathAccessor.symbol) disagrees with its property getter"
            )
        }
        let propertyIdentity: String
        let executable: (symbol: String, loweredType: String)
        let signature: (
            parameters: [Bytecode.ValueType],
            parameterConventions: [Bytecode.ParameterConvention],
            result: Bytecode.ValueType,
            hasIndirectResult: Bool,
            indirectErrorType: Bytecode.ValueType?,
            effects: Core.Effects,
            erasedMetatypes: [CanonicalSIL.Lowerer.ErasedMetatype]
        )
        if id.hasPrefix("id @") {
            let ordinary = try parseFunctionMetadata(id, label: "id")
            signature = try lowerer.parseFunctionType(ordinary.loweredType)
            propertyIdentity = "@\(ordinary.symbol)"
            executable = ordinary
            guard signature.parameterConventions
                    == accessorSignature.parameterConventions
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "KeyPath accessor @\(keyPathAccessor.symbol) disagrees with its property getter"
                )
            }
        } else {
            let foreign = try parseForeignPropertyMetadata(id)
            // Imported Objective-C properties do not have an ordinary Swift
            // getter symbol in the descriptor. Execute the concrete generated
            // accessor; its body still resolves the exact measured
            // NativeImport through the normal call graph.
            signature = accessorSignature
            propertyIdentity = foreign
            executable = keyPathAccessor
        }
        guard signature.parameters == [inputType],
              signature.parameterConventions.count == 1,
              signature.parameterConventions[0] != .inout,
              signature.result == outputType,
              !signature.effects.mayThrow,
              !signature.effects.isAsync,
              signature.indirectErrorType == nil,
              signature.erasedMetatypes.isEmpty
        else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "KeyPath getter \(propertyIdentity) has a non-concrete property ABI"
            )
        }
        return .init(
            propertyIdentity: propertyIdentity,
            symbol: executable.symbol,
            loweredType: executable.loweredType,
            inputType: inputType,
            inputConvention: signature.parameterConventions[0],
            outputType: outputType,
            outputSpelling: outputSpelling,
            hasIndirectResult: signature.hasIndirectResult
        )
    }

    private static func isSupportedQualifier(_ raw: String) -> Bool {
        captures(
            raw,
            pattern: #"^objc "(?:[^"\\]|\\.)+"$"#
        ) != nil
    }

    private static func parseForeignPropertyMetadata(_ raw: String) throws -> String {
        let prefix = "id #"
        guard raw.hasPrefix(prefix),
              let separator = raw.range(of: " : "),
              separator.lowerBound > raw.index(
                raw.startIndex,
                offsetBy: prefix.count
              )
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "KeyPath id metadata is malformed"
            )
        }
        let identityStart = raw.index(raw.startIndex, offsetBy: prefix.count)
        let identity = String(raw[identityStart..<separator.lowerBound])
        guard identity.contains("!getter") else {
            throw CanonicalSIL.LoweringError.unsupportedType(
                "foreign KeyPath component is not a concrete property getter"
            )
        }
        return "#\(identity)"
    }

    private static func parseFunctionMetadata(
        _ raw: String,
        label: String
    ) throws -> (symbol: String, loweredType: String) {
        let prefix = "\(label) @"
        guard raw.hasPrefix(prefix),
              let separator = raw.range(of: " : $"),
              separator.lowerBound > raw.index(raw.startIndex, offsetBy: prefix.count)
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "KeyPath \(label) metadata is malformed"
            )
        }
        let symbolStart = raw.index(raw.startIndex, offsetBy: prefix.count)
        return (
            String(raw[symbolStart..<separator.lowerBound]),
            String(raw[separator.upperBound...])
        )
    }

    private static func synthesize(
        symbol: String,
        literal: Literal,
        environment: CanonicalSIL.TypeEnvironment
    ) throws -> CanonicalSIL.Function {
        var builder = Builder(rootSpelling: literal.rootSpelling)
        var currentToken = "%0"
        var currentType = literal.capture.rootType
        var currentIsOwned = false

        for component in literal.components {
            switch component {
            case let .stored(stored):
                guard currentType == .local(stored.ownerKey) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "static KeyPath stored projection changes owner type"
                    )
                }
                let next: String
                switch stored.storage {
                case .structure:
                    next = builder.value()
                    builder.append(
                        "\(next) = struct_extract \(currentToken), "
                            + "#\(stored.ownerSpelling).\(stored.fieldName)"
                    )
                case .class:
                    let address = builder.value()
                    builder.append(
                        "\(address) = ref_element_addr [immutable] \(currentToken), "
                            + "#\(stored.ownerSpelling).\(stored.fieldName)"
                    )
                    next = builder.value()
                    builder.append("\(next) = load [copy] \(address)")
                }
                currentToken = next
                currentType = stored.outputType
                currentIsOwned = currentType.requiresLinearOwnership

            case let .getter(getter):
                guard getter.inputType == currentType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "static KeyPath getter input changes component type"
                    )
                }
                var argument = currentToken
                if currentType.requiresLinearOwnership,
                   !currentIsOwned,
                   getter.inputConvention == .owned {
                    let copy = builder.value()
                    builder.append("\(copy) = copy_value \(currentToken)")
                    argument = copy
                }
                let reference = builder.value()
                builder.append(
                    "\(reference) = function_ref @\(getter.symbol) : $\(getter.loweredType)"
                )
                let next: String
                if getter.hasIndirectResult {
                    let destination = builder.value()
                    builder.append(
                        "\(destination) = alloc_stack $\(getter.outputSpelling)"
                    )
                    let applied = builder.value()
                    builder.append(
                        "\(applied) = apply \(reference)(\(destination), \(argument)) "
                            + ": $\(getter.loweredType)"
                    )
                    next = builder.value()
                    builder.append("\(next) = load [take] \(destination)")
                    builder.append("dealloc_stack \(destination)")
                } else {
                    next = builder.value()
                    builder.append(
                        "\(next) = apply \(reference)(\(argument)) "
                            + ": $\(getter.loweredType)"
                    )
                }
                if currentType.requiresLinearOwnership,
                   currentIsOwned,
                   getter.inputConvention == .borrowed {
                    builder.append("destroy_value \(currentToken)")
                }
                currentToken = next
                currentType = getter.outputType
                currentIsOwned = currentType.requiresLinearOwnership

            case let .optional(optional):
                guard optional.inputType == currentType else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "static KeyPath optional projection changes input type"
                    )
                }
                switch optional.operation {
                case .chain, .force:
                    let someBlock = builder.reserveBlock()
                    let noneBlock = builder.reserveBlock()
                    builder.append(
                        "switch_enum \(currentToken), "
                            + "case #Optional.some!enumelt: bb\(someBlock), "
                            + "case #Optional.none!enumelt: bb\(noneBlock)"
                    )
                    builder.beginBlock(noneBlock)
                    if optional.operation == .chain {
                        guard case .optional = literal.capture.valueType else {
                            throw CanonicalSIL.LoweringError.malformedSIL(
                                "optional KeyPath chain has a non-Optional result"
                            )
                        }
                        let none = builder.value()
                        builder.append(
                            "\(none) = enum $\(literal.valueSpelling), "
                                + "#Optional.none!enumelt"
                        )
                        builder.append("return \(none)")
                    } else {
                        builder.append("unreachable")
                    }
                    let payload = builder.value()
                    builder.beginBlock(
                        someBlock,
                        parameter: (payload, optional.outputSpelling)
                    )
                    currentToken = payload
                    currentType = optional.outputType
                    currentIsOwned = currentType.requiresLinearOwnership

                case .wrap:
                    var payload = currentToken
                    if currentType.requiresLinearOwnership, !currentIsOwned {
                        let copy = builder.value()
                        builder.append("\(copy) = copy_value \(currentToken)")
                        payload = copy
                    }
                    let next = builder.value()
                    builder.append(
                        "\(next) = enum $\(optional.outputSpelling), "
                            + "#Optional.some!enumelt, \(payload)"
                    )
                    currentToken = next
                    currentType = optional.outputType
                    currentIsOwned = currentType.requiresLinearOwnership
                }
            }
        }
        guard currentType == literal.capture.valueType else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "static KeyPath synthesis produced the wrong result type"
            )
        }
        builder.append("return \(currentToken)")
        return .init(
            mangledName: symbol,
            loweredType: "@convention(thin) (@guaranteed \(literal.rootSpelling)) "
                + "-> \(literal.valueSpelling)",
            body: builder.lines.joined(separator: "\n")
        )
    }

    private static func validateThunk(
        _ function: CanonicalSIL.Function,
        literal: Literal,
        environment: CanonicalSIL.TypeEnvironment
    ) throws {
        let adapter = CanonicalSIL.DirectCallBinding.ABIAdapter
            .staticKeyPathProjection(identity: literal.capture.identity)
        let signature = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).parseFunctionType(
            function.loweredType,
            bridgingTo: (
                [literal.capture.rootType],
                literal.capture.valueType
            ),
            abiAdapter: adapter
        )
        guard signature.parameters == [literal.capture.rootType],
              signature.result == literal.capture.valueType,
              signature.hasIndirectResult,
              signature.indirectErrorType == .never,
              !signature.effects.mayThrow,
              !signature.effects.isAsync,
              signature.erasedMetatypes.isEmpty
        else {
            throw RewriteError(
                symbol: function.mangledName,
                reason: "compiler KeyPath thunk has an unexpected concrete ABI"
            )
        }

        let lines = function.body.split(separator: "\n", omittingEmptySubsequences: false)
            .map {
                CanonicalSIL.DebugMetadata.strippingComment(from: String($0))
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter {
                !$0.isEmpty
                    && !$0.hasPrefix("debug_value")
                    && !$0.hasPrefix("fix_lifetime")
                    && !$0.hasPrefix("[")
            }
        guard let header = lines.first,
              header.hasPrefix("bb0("), header.hasSuffix("):")
        else {
            throw RewriteError(
                symbol: function.mangledName,
                reason: "compiler KeyPath thunk is not one straight-line block"
            )
        }
        let parametersText = String(header.dropFirst("bb0(".count).dropLast(2))
        let parameters = try splitTopLevel(parametersText, separator: ",")
        let tokens = try parameters.map { parameter -> String in
            guard let separator = parameter.range(of: " : "),
                  parameter[..<separator.lowerBound].first == "%"
            else {
                throw RewriteError(
                    symbol: function.mangledName,
                    reason: "compiler KeyPath thunk has malformed block parameters"
                )
            }
            return String(parameter[..<separator.lowerBound])
        }
        guard tokens.count == 4 else {
            throw RewriteError(
                symbol: function.mangledName,
                reason: "compiler KeyPath thunk does not have result, error, root, and path parameters"
            )
        }
        let destination = tokens[0]
        let rootAddress = tokens[2]
        let path = tokens[3]
        var rootValue: String?
        var stack: String?
        var reference: String?
        var runtimeFunctionType: String?
        var emptyTuple: String?
        var positions: [String: Int] = [:]
        var rootRetains = 0
        var rootReleases = 0
        var pathRetains = 0
        var pathReleases = 0
        var destroyCount = 0

        for (index, line) in lines.dropFirst().enumerated() {
            if let load = captures(
                line,
                pattern: #"^(%[0-9]+) = load(?: \[(?:trivial|copy)\])? (%[0-9]+)$"#
            ), load[1] == rootAddress, rootValue == nil {
                rootValue = load[0]
                positions["load"] = index
                continue
            }
            if let allocation = captures(
                line,
                pattern: #"^(%[0-9]+) = alloc_stack \$(.+)$"#
            ), stack == nil,
               ValueRepresentation.storable(try environment.resolve(allocation[1]))
                    == literal.capture.rootType {
                stack = allocation[0]
                positions["allocate"] = index
                continue
            }
            if let store = captures(
                line,
                pattern: #"^store (%[0-9]+) to (?:\[(?:trivial|init)\] )?(%[0-9]+)$"#
            ), store[0] == rootValue, store[1] == stack,
               positions["store"] == nil {
                positions["store"] = index
                continue
            }
            if let functionReference = captures(
                line,
                pattern: #"^(%[0-9]+) = function_ref @([^\s:]+) : \$(.+)$"#
            ), functionReference[1] == "swift_getAtKeyPath", reference == nil {
                reference = functionReference[0]
                runtimeFunctionType = functionReference[2]
                positions["reference"] = index
                continue
            }
            if let apply = captures(
                line,
                pattern: #"^(%[0-9]+) = apply (%[0-9]+)(?:<.+>)?\((.*)\) : \$(.+)$"#
            ), apply[1] == reference,
               silValues(in: apply[2]) == [destination, stack, path],
               apply[3] == runtimeFunctionType,
               positions["apply"] == nil {
                positions["apply"] = index
                continue
            }
            if line == "retain_value \(rootValue ?? "")" {
                rootRetains += 1
                positions["rootRetain"] = index
                continue
            }
            if line == "release_value \(rootValue ?? "")" {
                rootReleases += 1
                positions["rootRelease"] = index
                continue
            }
            if line == "strong_retain \(rootValue ?? "")" {
                rootRetains += 1
                positions["rootRetain"] = index
                continue
            }
            if line == "strong_release \(rootValue ?? "")" {
                rootReleases += 1
                positions["rootRelease"] = index
                continue
            }
            if line == "strong_retain \(path)" {
                pathRetains += 1
                positions["pathRetain"] = index
                continue
            }
            if line == "strong_release \(path)" {
                pathReleases += 1
                positions["pathRelease"] = index
                continue
            }
            if line == "destroy_addr \(stack ?? "")" {
                destroyCount += 1
                positions["destroy"] = index
                continue
            }
            if line == "dealloc_stack \(stack ?? "")",
               positions["deallocate"] == nil {
                positions["deallocate"] = index
                continue
            }
            if let tuple = captures(
                line,
                pattern: #"^(%[0-9]+) = tuple \(\)$"#
            ), emptyTuple == nil {
                emptyTuple = tuple[0]
                positions["tuple"] = index
                continue
            }
            if line == "return \(emptyTuple ?? "")",
               positions["return"] == nil {
                positions["return"] = index
                continue
            }
            throw RewriteError(
                symbol: function.mangledName,
                reason: "compiler KeyPath thunk contains an unproven operation: \(line)"
            )
        }
        let required = [
            "load", "allocate", "store", "reference", "apply",
            "pathRetain", "pathRelease", "deallocate", "tuple", "return",
        ]
        guard required.allSatisfy({ positions[$0] != nil }),
              positions["load"]! < positions["store"]!,
              positions["allocate"]! < positions["store"]!,
              positions["store"]! < positions["apply"]!,
              positions["reference"]! < positions["apply"]!,
              positions["pathRetain"]! < positions["apply"]!,
              positions["apply"]! < positions["pathRelease"]!,
              positions["apply"]! < positions["deallocate"]!,
              positions["deallocate"]! < positions["return"]!,
              positions["tuple"]! < positions["return"]!,
              rootReleases == 0,
              rootRetains == destroyCount,
              rootRetains <= 1,
              pathRetains == 1,
              pathReleases == 1,
              destroyCount <= 1,
              positions["destroy"].map({
                positions["apply"]! < $0
                    && $0 < positions["deallocate"]!
              }) ?? true,
              positions["rootRetain"].map({
                $0 < positions["store"]!
              }) ?? true
        else {
            throw RewriteError(
                symbol: function.mangledName,
                reason: "compiler KeyPath thunk does not match the proven ownership skeleton"
            )
        }
    }

    private static func validateEndpoint(
        _ type: Bytecode.ValueType,
        role: String
    ) throws {
        switch type {
        case .void, .never, .address, .mutableCell, .nonOwningReference,
             .arrayState,
             .dictionaryState, .closure:
            throw CanonicalSIL.LoweringError.unsupportedType(
                "static KeyPath \(role) \(type)"
            )
        case .bool, .integer, .float, .string, .any, .array, .dictionary,
             .set, .native, .local, .error, .tuple, .optional:
            break
        }
    }

    private static func stripSILTypeDecorations(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in [
                "$", "@owned ", "@guaranteed ", "@unowned ",
                "@in_guaranteed ", "@autoreleased ", "@closureCapture ",
            ] where result.hasPrefix(prefix) {
                result.removeFirst(prefix.count)
                result = result.trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return result
    }

    private static func matchingAngleEnd(in value: String) -> String.Index? {
        guard let start = value.firstIndex(of: "<") else { return nil }
        var depth = 0
        var index = start
        while index < value.endIndex {
            switch value[index] {
            case "<": depth += 1
            case ">":
                let previous = index > value.startIndex
                    ? value[value.index(before: index)] : nil
                if previous != "-" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            default: break
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func matchingParenthesisEnd(
        in value: String
    ) -> String.Index? {
        guard value.first == "(" else { return nil }
        var depth = 0
        var quoted = false
        var escaped = false
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else {
                switch character {
                case "\"": quoted = true
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return index }
                    if depth < 0 { return nil }
                default: break
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func splitTopLevel(
        _ value: String,
        separator: Character
    ) throws -> [String] {
        var result: [String] = []
        var start = value.startIndex
        var parentheses = 0
        var angles = 0
        var brackets = 0
        var braces = 0
        var quoted = false
        var escaped = false
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else {
                switch character {
                case "\"": quoted = true
                case "(": parentheses += 1
                case ")": parentheses -= 1
                case "<": angles += 1
                case ">":
                    let previous = index > value.startIndex
                        ? value[value.index(before: index)] : nil
                    if previous != "-" { angles -= 1 }
                case "[": brackets += 1
                case "]": brackets -= 1
                case "{": braces += 1
                case "}": braces -= 1
                default: break
                }
                guard parentheses >= 0, angles >= 0, brackets >= 0, braces >= 0 else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "static KeyPath metadata has unbalanced delimiters"
                    )
                }
                if character == separator,
                   parentheses == 0, angles == 0, brackets == 0, braces == 0 {
                    result.append(
                        String(value[start..<index])
                            .trimmingCharacters(in: .whitespaces)
                    )
                    start = value.index(after: index)
                }
            }
            index = value.index(after: index)
        }
        guard !quoted, parentheses == 0, angles == 0, brackets == 0, braces == 0 else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "static KeyPath metadata has unbalanced delimiters"
            )
        }
        result.append(
            String(value[start...]).trimmingCharacters(in: .whitespaces)
        )
        return result
    }

    private static func silValues(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"%[0-9]+"#) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func captures(
        _ text: String,
        pattern: String
    ) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("invalid static KeyPath parser pattern")
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.range == range
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else {
                return ""
            }
            return String(text[range])
        }
    }
}
}
