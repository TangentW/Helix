import Foundation

extension SwiftFrontend {
/// Lossless-enough access to the JSON typed AST emitted by the Swift
/// frontend. Objects intentionally remain dictionaries because this compiler
/// SPI is versioned with the captured toolchain rather than with Helix.
public enum TypedAST {
    public typealias Object = [String: Any]

    public enum ParseError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case malformed(String)

        public var description: String {
            switch self {
            case let .malformed(reason): "malformed Swift typed AST: \(reason)"
            }
        }
    }

    public static func parseDocuments(_ output: String) throws -> [Object] {
        let bytes = Array(output.utf8)
        var documents: [Object] = []
        var cursor = 0
        while true {
            while cursor < bytes.count, bytes[cursor].isJSONWhitespace { cursor += 1 }
            guard cursor < bytes.count else { break }
            guard bytes[cursor] == UInt8(ascii: "{") else {
                throw ParseError.malformed(
                    "non-JSON bytes precede source document \(documents.count)"
                )
            }
            let start = cursor
            var depth = 0
            var inString = false
            var escaped = false
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == UInt8(ascii: "\\") {
                        escaped = true
                    } else if byte == UInt8(ascii: "\"") {
                        inString = false
                    }
                } else {
                    switch byte {
                    case UInt8(ascii: "\""): inString = true
                    case UInt8(ascii: "{"): depth += 1
                    case UInt8(ascii: "}"):
                        depth -= 1
                        guard depth >= 0 else {
                            throw ParseError.malformed("unbalanced JSON object")
                        }
                    default: break
                    }
                }
                cursor += 1
                if depth == 0 { break }
            }
            guard depth == 0, !inString else {
                throw ParseError.malformed("truncated JSON object")
            }
            let data = Data(bytes[start..<cursor])
            let value: Any
            do {
                value = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw ParseError.malformed(String(describing: error))
            }
            guard let object = value as? Object,
                  object["_kind"] as? String == "source_file"
            else {
                throw ParseError.malformed("top-level JSON value is not a source_file")
            }
            documents.append(object)
        }
        guard !documents.isEmpty else {
            throw ParseError.malformed("frontend emitted no source documents")
        }
        return documents
    }

    public static func mangledTypes(in documents: [Object]) -> Set<String> {
        var result = Set<String>()
        func visit(_ value: Any) {
            if let object = value as? Object {
                for item in object.values { visit(item) }
            } else if let array = value as? [Any] {
                for item in array { visit(item) }
            } else if let string = value as? String,
                      string.hasPrefix("$s"), string.hasSuffix("D") {
                result.insert(string)
            }
        }
        for document in documents { visit(document) }
        return result
    }
}
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == UInt8(ascii: " ") || self == UInt8(ascii: "\n")
            || self == UInt8(ascii: "\r") || self == UInt8(ascii: "\t")
    }
}
