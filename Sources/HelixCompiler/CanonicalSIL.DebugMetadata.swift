import Foundation
import HelixCore

extension CanonicalSIL {
struct DebugScope: Hashable, Sendable {
    var id: UInt32
    var location: Core.SourceLocation
    var parentSymbol: String?
}

struct DebugLineLocation: Hashable, Sendable {
    var line: Int
    var location: Core.SourceLocation
}

enum DebugMetadata {
    struct ParsedLine: Sendable {
        var instruction: String
        var location: Core.SourceLocation?
    }

    private struct RawScope {
        var location: Core.SourceLocation?
        var parentID: UInt32?
        var parentSymbol: String?
        var line: Int
        var text: String
    }

    private static let scopeHeaderRegex = makeRegex(#"^sil_scope ([0-9]+) \{"#)
    private static let scopeParentRegex = makeRegex(#"\bparent ([0-9]+)"#)
    private static let scopeParentSymbolRegex = makeRegex(#"\bparent @([^\s}]+)"#)
    private static let instructionScopeRegex = makeRegex(#",\s*scope\s+([0-9]+)\s*$"#)
    private static let anchoredLocationRegex = makeRegex(
        #"(?:,\s*)?loc\s+(?:\*\s*)?\"((?:\\.|[^\"\\])*)\":([0-9]+):([0-9]+)\s*$"#
    )
    private static let locationRegex = makeRegex(
        #"(?:,\s*)?loc\s+(?:\*\s*)?\"((?:\\.|[^\"\\])*)\":([0-9]+):([0-9]+)"#
    )
    private static let fileIDMappingRegex = makeRegex(
        #"^//\s+'((?:\\.|[^'\\])*)'\s+=>\s+'((?:\\.|[^'\\])*)'\s*$"#
    )

    static func sourceModules(in text: String) throws -> [String: String] {
        var modulesByFile: [String: String] = [:]
        for rawLine in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let match = firstMatch(in: line, regex: fileIDMappingRegex),
                  let encodedFileID = capture(match, at: 1, in: line),
                  let encodedPath = capture(match, at: 2, in: line)
            else { continue }
            let fileID = try decodeSILUTF8Literal(encodedFileID)
            let path = try decodeSILUTF8Literal(encodedPath)
            guard let separator = fileID.firstIndex(of: "/"),
                  separator > fileID.startIndex,
                  !path.isEmpty
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "debug file mapping has an invalid identity"
                )
            }
            let moduleName = String(fileID[..<separator])
            if let existing = modulesByFile[path], existing != moduleName {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "debug file path \(String(reflecting: path)) is mapped to conflicting modules "
                    + "\(String(reflecting: existing)) and \(String(reflecting: moduleName)) (file ID \(String(reflecting: fileID)))"
                )
            }
            modulesByFile[path] = moduleName
        }
        return modulesByFile
    }

    static func scopes(in text: String) throws -> [CanonicalSIL.DebugScope] {
        var rawScopes: [UInt32: RawScope] = [:]
        for (lineIndex, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("sil_scope ") else { continue }
            guard let id = firstCapture(in: line, regex: scopeHeaderRegex)
                .flatMap(UInt32.init)
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "debug scope has an invalid identifier"
                )
            }
            if let existing = rawScopes[id] {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "debug scope \(id) is defined more than once: "
                    + "SIL line \(existing.line): \(existing.text); SIL line \(lineIndex + 1): \(line)"
                )
            }
            rawScopes[id] = .init(
                location: try sourceLocation(in: line),
                parentID: firstCapture(in: line, regex: scopeParentRegex)
                    .flatMap(UInt32.init),
                parentSymbol: firstCapture(in: line, regex: scopeParentSymbolRegex),
                line: lineIndex + 1, text: line
            )
        }

        var resolved: [UInt32: Core.SourceLocation] = [:]
        var visiting = Set<UInt32>()
        func resolve(_ id: UInt32) throws -> Core.SourceLocation? {
            if let location = resolved[id] { return location }
            guard let scope = rawScopes[id] else { return nil }
            guard visiting.insert(id).inserted else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "debug scope inheritance contains a cycle at scope \(id), SIL line \(scope.line): \(scope.text)"
                )
            }
            defer { visiting.remove(id) }
            let location = try scope.location ?? scope.parentID.flatMap { try resolve($0) }
            if let location { resolved[id] = location }
            return location
        }
        for id in rawScopes.keys { _ = try resolve(id) }
        return resolved.map {
            .init(
                id: $0.key,
                location: $0.value,
                parentSymbol: rawScopes[$0.key]?.parentSymbol
            )
        }
            .sorted { $0.id < $1.id }
    }

    static func parse(
        _ line: String,
        scopes: [UInt32: Core.SourceLocation]
    ) throws -> ParsedLine {
        var instruction = strippingComment(from: line).trimmingCharacters(in: .whitespaces)
        var scopeLocation: Core.SourceLocation?
        if let match = lastMatch(in: instruction, regex: instructionScopeRegex) {
            let idText = capture(match, at: 1, in: instruction)
            guard let idText, let id = UInt32(idText) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "instruction debug scope has an invalid identifier"
                )
            }
            scopeLocation = scopes[id]
            guard let range = Range(match.range, in: instruction) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "instruction debug scope has an invalid text range"
                )
            }
            instruction.removeSubrange(range)
            instruction = instruction.trimmingCharacters(in: .whitespaces)
        }
        let directLocation = try sourceLocation(in: instruction, removeFrom: &instruction)
        return .init(
            instruction: instruction.trimmingCharacters(in: .whitespaces),
            location: directLocation ?? scopeLocation
        )
    }

    static func strippingMetadata(from line: String) -> String {
        (try? parse(line, scopes: [:]).instruction) ?? line
    }

    private static func sourceLocation(in text: String) throws -> Core.SourceLocation? {
        var ignored = text
        return try sourceLocation(in: text, removeFrom: &ignored, anchored: false)
    }

    private static func sourceLocation(
        in text: String,
        removeFrom output: inout String,
        anchored: Bool = true
    ) throws -> Core.SourceLocation? {
        let regex = anchored ? anchoredLocationRegex : locationRegex
        guard let match = lastMatch(in: text, regex: regex) else { return nil }
        guard let encodedFile = capture(match, at: 1, in: text),
              let lineText = capture(match, at: 2, in: text),
              let columnText = capture(match, at: 3, in: text),
              let line = Int(lineText),
              let column = Int(columnText)
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "source location has invalid line or column data"
            )
        }
        if anchored {
            guard let range = Range(match.range, in: output) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "source location has an invalid text range"
                )
            }
            output.removeSubrange(range)
        }
        guard line > 0, column > 0 else { return nil }
        let file = try decodeSILUTF8Literal(encodedFile)
        guard !file.isEmpty else { return nil }
        return .init(file: file, line: line, column: column)
    }

    private static func firstCapture(
        in text: String,
        regex: NSRegularExpression
    ) -> String? {
        guard let match = firstMatch(in: text, regex: regex) else { return nil }
        return capture(match, at: 1, in: text)
    }

    private static func firstMatch(
        in text: String,
        regex: NSRegularExpression
    ) -> NSTextCheckingResult? {
        return regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
    }

    private static func lastMatch(
        in text: String,
        regex: NSRegularExpression
    ) -> NSTextCheckingResult? {
        return regex.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).last
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("invalid internal SIL debug metadata expression")
        }
        return regex
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        at index: Int,
        in text: String
    ) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func decodeSILUTF8Literal(_ encoded: String) throws -> String {
        let input = Array(encoded.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            guard byte == 0x5C else {
                output.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < input.count else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "debug file path ends with an incomplete escape"
                )
            }
            let escaped = input[index]
            switch escaped {
            case 0x5C: output.append(0x5C)
            case 0x22: output.append(0x22)
            case 0x6E: output.append(0x0A)
            case 0x72: output.append(0x0D)
            case 0x74: output.append(0x09)
            default:
                guard index + 1 < input.count,
                      let high = hexValue(escaped),
                      let low = hexValue(input[index + 1])
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "debug file path contains an unsupported escape"
                    )
                }
                output.append((high << 4) | low)
                index += 1
            }
            index += 1
        }
        guard let result = String(bytes: output, encoding: .utf8) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "debug file path is not valid UTF-8"
            )
        }
        return result
    }

    /// Removes a SIL line comment while preserving comment markers inside
    /// quoted string literals.
    static func strippingComment(from line: String) -> String {
        var inString = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "/" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "/" {
                    return String(line[..<index])
                }
            }
            index = line.index(after: index)
        }
        return line
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
}
