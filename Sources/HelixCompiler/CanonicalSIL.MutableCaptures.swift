import Foundation
import HelixBytecode

extension CanonicalSIL {
/// Normalizes frame-relative captures of a constructed Swift closure into a
/// VM-managed cell ABI. The same `@closureCapture` spelling also appears on
/// directly called helpers such as `defer`; those retain their address ABI.
enum MutableCaptures {
    struct Signature: Equatable, Sendable {
        var parameters: [Bytecode.ValueType]
        var parameterConventions: [Bytecode.ParameterConvention]
        var logicalIndices: Set<Int>
    }

    /// Reference-backed scratch state keeps mutable-capture bookkeeping out
    /// of the already large SIL lowering stack frame.
    final class LoweringState {
        struct Address {
            var register: Bytecode.Register
            var pointee: Bytecode.ValueType
        }

        var addresses: [String: Address] = [:]
        var temporaryBorrowOwners: [String: Bytecode.Register] = [:]
    }

    static func normalize(
        body: String,
        role: Bytecode.FunctionKind,
        parameters: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention],
        erasedPhysicalIndices: Set<Int>,
        hasIndirectResult: Bool,
        hasIndirectError: Bool
    ) throws -> Signature {
        guard parameters.count == parameterConventions.count else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "function parameter ownership count is inconsistent"
            )
        }
        guard role == .closureBody,
              body.contains("@closureCapture")
        else {
            return .init(
                parameters: parameters,
                parameterConventions: parameterConventions,
                logicalIndices: []
            )
        }
        guard let components = entryBlockParameters(in: body) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "mutable closure capture has no canonical entry block"
            )
        }

        let leadingAddressCount = (hasIndirectResult ? 1 : 0)
            + (hasIndirectError ? 1 : 0)
        guard components.count
                == leadingAddressCount + erasedPhysicalIndices.count + parameters.count
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "mutable closure capture entry parameters differ from its function ABI"
            )
        }

        var normalizedParameters = parameters
        var normalizedConventions = parameterConventions
        var logicalIndices = Set<Int>()
        var logicalIndex = 0
        for (physicalIndex, component) in components.enumerated() {
            guard physicalIndex >= leadingAddressCount else { continue }
            let valuePhysicalIndex = physicalIndex - leadingAddressCount
            if erasedPhysicalIndices.contains(valuePhysicalIndex) { continue }
            guard normalizedParameters.indices.contains(logicalIndex) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "mutable closure capture has an invalid logical parameter index"
                )
            }
            defer { logicalIndex += 1 }
            guard component.contains("@closureCapture") else { continue }
            guard case let .address(pointee) = normalizedParameters[logicalIndex]
            else {
                // Immutable captures carry the same entry-block decoration
                // but already have a regular value ABI.
                continue
            }
            guard normalizedConventions[logicalIndex] == .inout else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "@closureCapture must describe an inout address parameter"
                )
            }
            normalizedParameters[logicalIndex] = .mutableCell(pointee)
            normalizedConventions[logicalIndex] = .owned
            logicalIndices.insert(logicalIndex)
        }
        guard logicalIndex == parameters.count else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "mutable closure capture did not resolve every logical parameter"
            )
        }
        return .init(
            parameters: normalizedParameters,
            parameterConventions: normalizedConventions,
            logicalIndices: logicalIndices
        )
    }

    private static func entryBlockParameters(in body: String) -> [String]? {
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLine = String(rawLine)
            let line = CanonicalSIL.DebugMetadata.strippingComment(
                from: rawLine
            )
                .trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("bb0") else { continue }
            guard let open = line.firstIndex(of: "(") else { return [] }
            guard let close = matchingClose(in: line, after: open),
                  line[line.index(after: close)...]
                    .trimmingCharacters(in: .whitespaces) == ":"
            else { return nil }
            let contents = line[line.index(after: open)..<close]
            return splitTopLevel(String(contents))
        }
        return nil
    }

    private static func matchingClose(
        in text: String,
        after open: String.Index
    ) -> String.Index? {
        var depth = 0
        for index in text.indices where index >= open {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    private static func splitTopLevel(_ text: String) -> [String]? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var result: [String] = []
        var start = text.startIndex
        var depths = (parenthesis: 0, angle: 0, square: 0)
        for index in text.indices {
            switch text[index] {
            case "(": depths.parenthesis += 1
            case ")": depths.parenthesis -= 1
            case "<": depths.angle += 1
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" { depths.angle -= 1 }
            case "[": depths.square += 1
            case "]": depths.square -= 1
            case "," where depths == (0, 0, 0):
                result.append(
                    String(text[start..<index])
                        .trimmingCharacters(in: .whitespaces)
                )
                start = text.index(after: index)
            default: break
            }
            guard depths.parenthesis >= 0,
                  depths.angle >= 0,
                  depths.square >= 0
            else { return nil }
        }
        guard depths == (0, 0, 0) else { return nil }
        result.append(
            String(text[start...]).trimmingCharacters(in: .whitespaces)
        )
        return result
    }
}
}
