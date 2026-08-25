import Foundation
import HelixBytecode
import HelixCore

extension FrontendReceipt {
/// Parses the source-level function-type subset used by generated bridges.
/// Lifetime and Swift concurrency annotations are retained separately from the
/// VM closure signature because they belong to the native boundary contract.
enum FunctionTypeSpelling {
    struct Attributes: Equatable, Sendable {
        var isEscaping = false
        var isSendable = false
        var globalActor: String?
        var usesBlockConvention = false
    }

    struct Function: Equatable, Sendable {
        var attributes: Attributes
        var parameters: [String]
        var result: String
        var isAsync: Bool
        var isThrowing: Bool

        var isSynchronousNonthrowing: Bool {
            !isAsync && !isThrowing
        }

        var declaredSpelling: String {
            FunctionTypeSpelling.rendered(attributes: attributes)
                + "(\(parameters.joined(separator: ", "))) -> \(result)"
        }

        /// A generated local closure must not repeat parameter-only
        /// `@escaping`, and Swift can perform the block conversion at the call.
        var generatedSpelling: String {
            var annotations: [String] = []
            if let globalActor = attributes.globalActor {
                annotations.append("@\(globalActor)")
            }
            if attributes.isSendable { annotations.append("@Sendable") }
            let prefix = annotations.isEmpty
                ? "" : annotations.joined(separator: " ") + " "
            return prefix + "(\(parameters.joined(separator: ", "))) -> \(result)"
        }
    }

    struct CallbackBoundary: Equatable, Sendable {
        var function: Function
        var isOptional: Bool

        var lifetime: Core.NativeImportCallbackLifetime {
            isOptional || function.attributes.isEscaping
                ? .escaping : .nonescaping
        }

        var generatedSpelling: String {
            isOptional
                ? "Swift.Optional<\(function.generatedSpelling)>"
                : function.generatedSpelling
        }

        var declaredSpelling: String {
            isOptional
                ? "Swift.Optional<\(function.declaredSpelling)>"
                : function.declaredSpelling
        }
    }

    static func parse(_ raw: String) -> Function? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var attributes = Attributes()
        var hasExplicitConvention = false
        while value.hasPrefix("@") {
            guard let annotation = consumeAnnotation(from: &value) else {
                return nil
            }
            switch annotation {
            case "escaping":
                guard !attributes.isEscaping else { return nil }
                attributes.isEscaping = true
            case "Sendable":
                guard !attributes.isSendable else { return nil }
                attributes.isSendable = true
            case "convention(block)":
                guard !hasExplicitConvention else { return nil }
                hasExplicitConvention = true
                attributes.usesBlockConvention = true
            case "convention(swift)":
                guard !hasExplicitConvention else { return nil }
                hasExplicitConvention = true
            default:
                guard isGlobalActorAnnotation(annotation),
                      attributes.globalActor == nil
                else { return nil }
                attributes.globalActor = annotation
            }
        }

        guard let arrow = topLevelArrow(in: value) else {
            // Optional callback syntax adds a grouping pair around the
            // function type. Accept only a pair enclosing the entire value.
            guard let unwrapped = removingOneEnclosingPair(from: value) else {
                return nil
            }
            var nested = unwrapped
            let prefix = rendered(attributes: attributes)
            if !prefix.isEmpty { nested = prefix + nested }
            return parse(nested)
        }
        let left = value[..<arrow.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = value[arrow.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ["Void", "Swift.Void"].contains(result) { result = "()" }
        guard !left.isEmpty, !result.isEmpty,
              left.first == "(",
              let close = matchingClosingParenthesis(
                  for: left.startIndex,
                  in: left
              )
        else { return nil }

        let effectText = left[left.index(after: close)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effects = effectText.split(whereSeparator: \.isWhitespace)
        guard Set(effects).count == effects.count,
              effects.allSatisfy({
                  $0 == "async" || $0 == "throws" || $0 == "rethrows"
              }),
              !(effects.contains("throws") && effects.contains("rethrows"))
        else { return nil }
        let body = String(left[left.index(after: left.startIndex)..<close])
        guard let parameters = splitTopLevel(body, separator: ",") else {
            return nil
        }
        return .init(
            attributes: attributes,
            parameters: body.isEmpty ? [] : parameters,
            result: result,
            isAsync: effects.contains("async"),
            isThrowing: effects.contains("throws")
                || effects.contains("rethrows")
        )
    }

    static func callbackBoundary(in raw: String) -> CallbackBoundary? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let function = parse(value) {
            return .init(function: function, isOptional: false)
        }
        guard let wrapped = optionalWrappedType(value),
              let function = parse(wrapped),
              !function.attributes.isEscaping
        else { return nil }
        return .init(function: function, isOptional: true)
    }

    static func parameterSpellings(in functionType: String) -> [String]? {
        parse(functionType)?.parameters.map(removeTupleLabel)
    }

    static func overlayCallbackParameters(
        _ values: [String],
        formalFunctionType: String
    ) -> [String] {
        guard let formal = parameterSpellings(in: formalFunctionType),
              formal.count == values.count
        else { return values }
        return zip(values, formal).map { value, parameter in
            guard var declared = callbackBoundary(in: parameter) else {
                return value
            }
            guard let argument = callbackBoundary(in: value) else {
                return declared.declaredSpelling
            }
            let declaredActor = declared.function.attributes.globalActor
            let argumentActor = argument.function.attributes.globalActor
            if let declaredActor, let argumentActor,
               normalizedGlobalActor(declaredActor)
                != normalizedGlobalActor(argumentActor) {
                return value
            }
            declared.function.attributes.globalActor = argumentActor
                ?? declaredActor
            declared.function.attributes.isSendable =
                declared.function.attributes.isSendable
                || argument.function.attributes.isSendable
            declared.function.attributes.usesBlockConvention =
                declared.function.attributes.usesBlockConvention
                || argument.function.attributes.usesBlockConvention
            return declared.declaredSpelling
        }
    }

    static func applyingAuthoritativeLifetimes(
        _ lifetimes: [Int: Core.NativeImportCallbackLifetime],
        to values: [String]
    ) -> [String]? {
        var callbackIndices = Set<Int>()
        let result = values.enumerated().map { index, value -> String in
            guard var boundary = callbackBoundary(in: value) else {
                return value
            }
            callbackIndices.insert(index)
            guard let lifetime = lifetimes[index] else { return value }
            if boundary.isOptional {
                guard lifetime == .escaping else { return value }
                boundary.function.attributes.isEscaping = false
            } else {
                boundary.function.attributes.isEscaping = lifetime == .escaping
            }
            return boundary.declaredSpelling
        }
        guard callbackIndices == Set(lifetimes.keys) else { return nil }
        for (index, lifetime) in lifetimes {
            guard let boundary = callbackBoundary(in: result[index]),
                  boundary.lifetime == lifetime
            else { return nil }
        }
        return result
    }

    static func applyingGlobalActor(
        _ actor: String,
        to raw: String
    ) -> String? {
        guard var boundary = callbackBoundary(in: raw) else { return nil }
        if let existing = boundary.function.attributes.globalActor,
           normalizedGlobalActor(existing) != normalizedGlobalActor(actor) {
            return nil
        }
        boundary.function.attributes.globalActor = actor
        return boundary.declaredSpelling
    }

    /// Non-Sendable closure literals inherit their enclosing global actor even
    /// when Swift's printed callback type omits that region-isolation detail.
    /// Preserve the restriction at a frozen native boundary; `@Sendable`
    /// callbacks retain their explicitly declared executor contract.
    static func applyingInheritedGlobalActor(
        _ actor: String,
        to raw: String
    ) -> String? {
        guard let boundary = callbackBoundary(in: raw) else { return nil }
        guard !boundary.function.attributes.isSendable else {
            return boundary.declaredSpelling
        }
        return applyingGlobalActor(actor, to: raw)
    }

    private static func consumeAnnotation(from value: inout String) -> String? {
        guard value.first == "@" else { return nil }
        var index = value.index(after: value.startIndex)
        let nameStart = index
        while index < value.endIndex,
              value[index] == "." || value[index] == "_"
                || value[index].isLetter || value[index].isNumber {
            index = value.index(after: index)
        }
        guard index > nameStart else { return nil }
        var annotation = String(value[nameStart..<index])
        if index < value.endIndex, value[index] == "(" {
            guard let close = matchingClosingParenthesis(for: index, in: value) else {
                return nil
            }
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

    private static func rendered(attributes: Attributes) -> String {
        var values: [String] = []
        if attributes.isEscaping { values.append("@escaping") }
        if let actor = attributes.globalActor { values.append("@\(actor)") }
        if attributes.isSendable { values.append("@Sendable") }
        if attributes.usesBlockConvention {
            values.append("@convention(block)")
        }
        return values.isEmpty ? "" : values.joined(separator: " ") + " "
    }

    private static func isGlobalActorAnnotation(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard let final = components.last, final.hasSuffix("Actor") else {
            return false
        }
        return components.allSatisfy { component in
            guard let first = component.first,
                  first == "_" || first.isLetter
            else { return false }
            return component.dropFirst().allSatisfy {
                $0 == "_" || $0.isLetter || $0.isNumber
            }
        }
    }

    private static func normalizedGlobalActor(_ value: String) -> String {
        value == "Swift.MainActor" ? "MainActor" : value
    }

    private static func optionalWrappedType(_ value: String) -> String? {
        if value.hasSuffix("?") {
            return String(value.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["Optional<", "Swift.Optional<"]
        where value.hasPrefix(prefix) && value.hasSuffix(">") {
            return String(value.dropFirst(prefix.count).dropLast())
        }
        return nil
    }

    private static func removingOneEnclosingPair(from value: String) -> String? {
        guard value.first == "(",
              let close = matchingClosingParenthesis(
                  for: value.startIndex,
                  in: value
              ), close == value.index(before: value.endIndex)
        else { return nil }
        return String(value[value.index(after: value.startIndex)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchingClosingParenthesis(
        for open: String.Index,
        in value: some StringProtocol
    ) -> String.Index? {
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

    private static func topLevelArrow(in value: String) -> Range<String.Index>? {
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

    private static func splitTopLevel(
        _ raw: String,
        separator: Character
    ) -> [String]? {
        guard !raw.isEmpty else { return [] }
        var result: [String] = []
        var start = raw.startIndex
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
            default: break
            }
            guard angleDepth >= 0, parenthesisDepth >= 0,
                  bracketDepth >= 0
            else { return nil }
            if raw[index] == separator,
               angleDepth == 0, parenthesisDepth == 0, bracketDepth == 0 {
                let component = raw[start..<index]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty else { return nil }
                result.append(component)
                start = raw.index(after: index)
            }
        }
        guard angleDepth == 0, parenthesisDepth == 0, bracketDepth == 0 else {
            return nil
        }
        let tail = raw[start...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        result.append(tail)
        return result
    }

    private static func removeTupleLabel(_ raw: String) -> String {
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
}

/// The single automatic NativeImport boundary profile shared by discovery,
/// catalog validation, and generated SDK probing.
enum NativeBridgeProfile {
    static func authoritativeLifetimes(
        _ callbacks: [Core.NativeImportCallback]
    ) -> [Int: Core.NativeImportCallbackLifetime]? {
        var result: [Int: Core.NativeImportCallbackLifetime] = [:]
        result.reserveCapacity(callbacks.count)
        for callback in callbacks {
            guard result.updateValue(
                callback.lifetime,
                forKey: Int(callback.parameterIndex)
            ) == nil else { return nil }
        }
        return result
    }

    /// A closure assigned through a setter is a stored value, not a
    /// nonescaping call parameter. This remains true when the source-level
    /// function type has no legal place to spell `@escaping`.
    static func storedValueLifetimes(
        parameterTypes: [Bytecode.ValueType]
    ) -> [Int: Core.NativeImportCallbackLifetime] {
        Dictionary(uniqueKeysWithValues: parameterTypes.indices.compactMap {
            index in parameterTypes[index].directClosureShape == nil
                ? nil : (index, .escaping)
        })
    }

    static func callbacks(
        parameterSpellings: [String],
        parameterTypes: [Bytecode.ValueType],
        authoritativeLifetimes: [Int: Core.NativeImportCallbackLifetime]? = nil
    ) -> [Core.NativeImportCallback]? {
        guard parameterSpellings.count == parameterTypes.count else {
            return nil
        }
        var callbacks: [Core.NativeImportCallback] = []
        for (index, pair) in zip(parameterSpellings, parameterTypes).enumerated() {
            let (spelling, type) = pair
            if let shape = type.directClosureShape {
                guard let boundary = FrontendReceipt.FunctionTypeSpelling
                        .callbackBoundary(in: spelling),
                      boundary.isOptional == shape.isOptional,
                      boundary.function.isSynchronousNonthrowing,
                      shape.signature.isNativeBridgeCallback,
                      let parameterIndex = UInt16(exactly: index)
                else { return nil }
                let lifetime = authoritativeLifetimes?[index]
                    ?? boundary.lifetime
                // Explicit `@escaping` and Optional closure syntax establish a
                // minimum lifetime that an external contract cannot weaken.
                // Only an unannotated direct function type is ambiguous: SIL
                // or a storing setter may authoritatively promote it.
                guard boundary.lifetime != .escaping || lifetime == .escaping
                else { return nil }
                callbacks.append(
                    .init(
                        parameterIndex: parameterIndex,
                        lifetime: lifetime
                    )
                )
            } else {
                guard type.isOrdinaryNativeImportBridgeValue else { return nil }
            }
        }
        guard authoritativeLifetimes.map({
            Set($0.keys) == Set(callbacks.map { Int($0.parameterIndex) })
        }) ?? true else { return nil }
        return callbacks
    }

    static func generatedParameterSpellings(
        _ parameterSpellings: [String],
        parameterTypes: [Bytecode.ValueType]
    ) -> [String]? {
        guard callbacks(
            parameterSpellings: parameterSpellings,
            parameterTypes: parameterTypes
        ) != nil else { return nil }
        return zip(parameterSpellings, parameterTypes).map { spelling, type in
            guard type.directClosureShape != nil,
                  let boundary = FrontendReceipt.FunctionTypeSpelling
                    .callbackBoundary(in: spelling)
            else { return spelling }
            return boundary.generatedSpelling
        }
    }

    static func isResult(_ type: Bytecode.ValueType) -> Bool {
        type.isNativeImportBridgeResult
    }
}
}
