import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore

extension FrontendReceipt {
enum TypedAST {
    typealias Object = SwiftFrontend.TypedAST.Object

    static func parseDocuments(_ output: String) throws -> [Object] {
        do {
            return try SwiftFrontend.TypedAST.parseDocuments(output)
        } catch {
            throw FrontendReceipt.Error.malformedAST(String(describing: error))
        }
    }

    static func mangledTypes(in documents: [Object]) -> Set<String> {
        SwiftFrontend.TypedAST.mangledTypes(in: documents)
    }
}

struct Demangler {
    var compilerURL: URL

    func demangle(_ mangledTypes: Set<String>) throws -> [String: String] {
        let ordered = mangledTypes.sorted()
        guard !ordered.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for start in stride(from: 0, to: ordered.count, by: 256) {
            let end = min(start + 256, ordered.count)
            let chunk = Array(ordered[start..<end])
            let output = try run(arguments: ["-compact"] + chunk)
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            let normalized = lines.last?.isEmpty == true ? Array(lines.dropLast()) : lines
            guard normalized.count == chunk.count else {
                throw FrontendReceipt.Error.demanglingFailed(
                    "expected \(chunk.count) results, received \(normalized.count)"
                )
            }
            for (mangled, demangled) in zip(chunk, normalized) {
                let value = String(demangled)
                guard !value.isEmpty else {
                    throw FrontendReceipt.Error.demanglingFailed(mangled)
                }
                result[mangled] = value
            }
        }
        return result
    }

    private func run(arguments: [String]) throws -> String {
        let resolvedCompiler = compilerURL.resolvingSymlinksInPath()
        let sibling = resolvedCompiler.deletingLastPathComponent()
            .appendingPathComponent("swift-demangle")
        let driver: SwiftFrontend.Driver
        let invocation: [String]
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            driver = .init(compilerURL: sibling)
            invocation = arguments
        } else {
            driver = .init(compilerURL: URL(fileURLWithPath: "/usr/bin/xcrun"))
            invocation = ["swift-demangle"] + arguments
        }
        let output = try driver.run(arguments: invocation)
        guard output.terminationStatus == 0 else {
            throw FrontendReceipt.Error.demanglingFailed(output.standardError)
        }
        return output.standardOutput
    }
}

enum ValueTypeParser {
    static func parse(
        _ spelling: String,
        allowVoid: Bool,
        nativeTypes: [String: Core.TypeID] = [:]
    ) -> Bytecode.ValueType? {
        let value = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        if let function = FrontendReceipt.FunctionTypeSpelling.parse(value) {
            let globalActor = function.attributes.globalActor
            guard function.isSynchronousNonthrowing,
                  globalActor == nil
                    || globalActor == "MainActor"
                    || globalActor == "Swift.MainActor"
            else { return nil }
            let parameters = function.parameters.compactMap {
                parse(
                    removeTupleLabel($0),
                    allowVoid: false,
                    nativeTypes: nativeTypes
                )
            }
            guard parameters.count == function.parameters.count,
                  let result = parse(
                      function.result,
                      allowVoid: true,
                      nativeTypes: nativeTypes
                  )
            else { return nil }
            return .closure(
                .init(
                    parameters: parameters,
                    parameterConventions: parameters.map(
                        \.nativeCallbackParameterConvention
                    ),
                    result: result,
                    effects: .init(requiresMainActor: globalActor != nil)
                )
            )
        }
        // A source annotation is valid here only as part of the function-type
        // grammar above. Do not let an unknown annotation fall through to a
        // nominal type lookup.
        if value.hasPrefix("@") { return nil }
        if ["()", "Void", "Swift.Void"].contains(value) {
            return allowVoid ? .void : nil
        }
        if ["Never", "Swift.Never"].contains(value) { return .never }
        if let wrapped = optionalWrappedType(value) {
            return parse(
                wrapped,
                allowVoid: false,
                nativeTypes: nativeTypes
            ).map(Bytecode.ValueType.optional)
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            let body = String(value.dropFirst().dropLast())
            if let components = dictionaryComponents(body),
               let key = parse(components.key, allowVoid: false, nativeTypes: nativeTypes),
               let element = parse(components.value, allowVoid: false, nativeTypes: nativeTypes) {
                return .dictionary(key: key, value: element)
            }
            return parse(
                body,
                allowVoid: false,
                nativeTypes: nativeTypes
            ).map(Bytecode.ValueType.array)
        }
        for prefix in ["Array<", "Swift.Array<"]
        where value.hasPrefix(prefix) && value.hasSuffix(">") {
            let wrapped = String(value.dropFirst(prefix.count).dropLast())
            return parse(
                wrapped,
                allowVoid: false,
                nativeTypes: nativeTypes
            ).map(Bytecode.ValueType.array)
        }
        for prefix in ["Set<", "Swift.Set<"]
        where value.hasPrefix(prefix) && value.hasSuffix(">") {
            let wrapped = String(value.dropFirst(prefix.count).dropLast())
            return parse(
                wrapped,
                allowVoid: false,
                nativeTypes: nativeTypes
            ).map(Bytecode.ValueType.set)
        }
        for prefix in ["Dictionary<", "Swift.Dictionary<"]
        where value.hasPrefix(prefix) && value.hasSuffix(">") {
            let body = String(value.dropFirst(prefix.count).dropLast())
            let components = splitTopLevel(body)
            guard components.count == 2,
                  let key = parse(components[0], allowVoid: false, nativeTypes: nativeTypes),
                  let element = parse(components[1], allowVoid: false, nativeTypes: nativeTypes)
            else { return nil }
            return .dictionary(key: key, value: element)
        }
        if value.first == "(", value.last == ")" {
            let body = String(value.dropFirst().dropLast())
            let components = splitTopLevel(body)
            if components.count > 1 {
                let elements = components.compactMap {
                    parse(
                        removeTupleLabel($0),
                        allowVoid: false,
                        nativeTypes: nativeTypes
                    )
                }
                return elements.count == components.count ? .tuple(elements) : nil
            }
            if let only = components.first {
                return parse(
                    removeTupleLabel(only),
                    allowVoid: allowVoid,
                    nativeTypes: nativeTypes
                )
            }
        }
        let name = value.hasPrefix("Swift.") ? String(value.dropFirst(6)) : value
        if let id = nativeTypes[value] {
            return .native(id)
        }
        switch name {
        case "Bool": return .bool
        case "Int": return .integer(bitWidth: 64, signed: true)
        case "UInt": return .integer(bitWidth: 64, signed: false)
        case "Int8": return .integer(bitWidth: 8, signed: true)
        case "Int16": return .integer(bitWidth: 16, signed: true)
        case "Int32": return .integer(bitWidth: 32, signed: true)
        case "Int64": return .integer(bitWidth: 64, signed: true)
        case "UInt8": return .integer(bitWidth: 8, signed: false)
        case "UInt16": return .integer(bitWidth: 16, signed: false)
        case "UInt32": return .integer(bitWidth: 32, signed: false)
        case "UInt64": return .integer(bitWidth: 64, signed: false)
        case "Float": return .float(bitWidth: 32)
        case "Double": return .float(bitWidth: 64)
        case "CGFloat", "CoreFoundation.CGFloat", "CoreGraphics.CGFloat": return .float(bitWidth: 64)
        case "String": return .string
        case "Any": return .any
        default: return nil
        }
    }

    private static func optionalWrappedType(_ value: String) -> String? {
        if value.hasSuffix("?") {
            return String(value.dropLast())
        }
        for prefix in ["Optional<", "Swift.Optional<"] {
            if value.hasPrefix(prefix), value.hasSuffix(">") {
                return String(value.dropFirst(prefix.count).dropLast())
            }
        }
        return nil
    }

    private static func dictionaryComponents(_ value: String) -> (key: String, value: String)? {
        var depth = 0
        for index in value.indices {
            switch value[index] {
            case "<", "(", "[": depth += 1
            case ">", ")", "]": depth -= 1
            case ":" where depth == 0:
                let next = value.index(after: index)
                let key = String(value[..<index]).trimmingCharacters(in: .whitespaces)
                let element = String(value[next...]).trimmingCharacters(in: .whitespaces)
                return key.isEmpty || element.isEmpty ? nil : (key, element)
            default: break
            }
            guard depth >= 0 else { return nil }
        }
        return nil
    }

    private static func splitTopLevel(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        var result: [String] = []
        var angleDepth = 0
        var parenthesisDepth = 0
        var start = value.startIndex
        for index in value.indices {
            switch value[index] {
            case "<": angleDepth += 1
            case ">":
                let previous = index > value.startIndex
                    ? value[value.index(before: index)]
                    : nil
                if previous != "-" { angleDepth -= 1 }
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case "," where angleDepth == 0 && parenthesisDepth == 0:
                result.append(String(value[start..<index]).trimmingCharacters(in: .whitespaces))
                start = value.index(after: index)
            default: break
            }
        }
        result.append(String(value[start...]).trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func removeTupleLabel(_ value: String) -> String {
        var angleDepth = 0
        var parenthesisDepth = 0
        for index in value.indices {
            switch value[index] {
            case "<": angleDepth += 1
            case ">": angleDepth -= 1
            case "(": parenthesisDepth += 1
            case ")": parenthesisDepth -= 1
            case ":" where angleDepth == 0 && parenthesisDepth == 0:
                return String(value[value.index(after: index)...])
                    .trimmingCharacters(in: .whitespaces)
            default: break
            }
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
}
