import Foundation

extension CanonicalSIL {
enum SymbolIdentity {
    /// Returns the module identifier encoded at the beginning of a modern
    /// Swift symbol. Helix uses it only to keep image-local discovery inside
    /// the module that was type-checked from the frozen source set.
    static func moduleName(of mangledName: String) -> String? {
        let bytes = Array(mangledName.utf8)
        guard bytes.count > 2,
              bytes[0] == UInt8(ascii: "$"),
              bytes[1] == UInt8(ascii: "s")
        else { return nil }

        var cursor = 2
        var length = 0
        var hasLength = false
        while cursor < bytes.count,
              bytes[cursor] >= UInt8(ascii: "0"),
              bytes[cursor] <= UInt8(ascii: "9") {
            hasLength = true
            let digit = Int(bytes[cursor] - UInt8(ascii: "0"))
            let next = length.multipliedReportingOverflow(by: 10)
            guard !next.overflow else { return nil }
            let added = next.partialValue.addingReportingOverflow(digit)
            guard !added.overflow else { return nil }
            length = added.partialValue
            cursor += 1
        }
        guard hasLength, length > 0, length <= bytes.count - cursor else {
            return nil
        }
        return String(decoding: bytes[cursor..<(cursor + length)], as: UTF8.self)
    }
}
}

extension CanonicalSIL.Function {
    /// Synthesized value-type initializers carry a metatype solely to select
    /// the Swift constructor. They are lowered by local-type construction, not
    /// linked as ordinary functions with an unsupported metatype ABI.
    var hasNominalValueConstructorABI: Bool {
        guard let arrow = loweredType.range(of: " -> ", options: .backwards) else {
            return false
        }
        var result = loweredType[arrow.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        for prefix in ["@out ", "@owned "] where result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
        }
        guard !result.isEmpty else { return false }
        let parameters = loweredType[..<arrow.lowerBound]
        return parameters.contains("@thin \(result).Type")
    }
}
