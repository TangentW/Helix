import Foundation

extension Hub {
/// Loss-minimal editor for the small set of PBX objects owned by Helix.
/// Existing records remain byte-for-byte intact unless Helix must change them.
struct PBXProjectDocument {
    private(set) var objects: [String: Hub.OpenStep.Value]
    let projectObjectID: String

    private let originalText: String
    private var replacements: [String: Hub.OpenStep.Value] = [:]
    private var additions: [String: Hub.OpenStep.Value] = [:]

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Hub.Error.invalidProject("project.pbxproj is not UTF-8")
        }
        var parser = try Hub.OpenStep.Parser(data: data)
        guard case let .dictionary(root) = try parser.parse(),
              let parsedObjects = root["objects"]?.dictionary,
              let rootID = root["rootObject"]?.string,
              parsedObjects[rootID]?.dictionary?["isa"]?.string == "PBXProject"
        else {
            throw Hub.Error.invalidProject("PBXProject root object is missing")
        }
        originalText = text
        objects = parsedObjects
        projectObjectID = rootID
    }

    func object(_ identifier: String) throws -> [String: Hub.OpenStep.Value] {
        guard let value = objects[identifier]?.dictionary else {
            throw Hub.Error.invalidProject("PBX object \(identifier) is missing")
        }
        return value
    }

    mutating func updateObject(
        _ identifier: String,
        _ transform: (inout [String: Hub.OpenStep.Value]) throws -> Void
    ) throws {
        var dictionary = try object(identifier)
        try transform(&dictionary)
        let value = Hub.OpenStep.Value.dictionary(dictionary)
        objects[identifier] = value
        if additions[identifier] != nil {
            additions[identifier] = value
        } else {
            replacements[identifier] = value
        }
    }

    mutating func addObject(
        _ identifier: String,
        isa: String,
        fields: [String: Hub.OpenStep.Value]
    ) throws {
        var dictionary = fields
        dictionary["isa"] = .string(isa)
        let value = Hub.OpenStep.Value.dictionary(dictionary)
        if let existing = objects[identifier] {
            guard existing.dictionary?["isa"]?.string == isa else {
                throw Hub.Error.invalidProject(
                    "deterministic PBX identifier \(identifier) collides with an existing object"
                )
            }
            objects[identifier] = value
            replacements[identifier] = value
            return
        }
        objects[identifier] = value
        additions[identifier] = value
    }

    func configurationID(targetID: String, named name: String) throws -> String {
        let target = try object(targetID)
        guard let listID = target["buildConfigurationList"]?.string,
              let list = objects[listID]?.dictionary,
              let configurationIDs = list["buildConfigurations"]?.array
        else {
            throw Hub.Error.invalidProject("target has no build configuration list")
        }
        let matches = configurationIDs.compactMap(\.string).filter { identifier in
            objects[identifier]?.dictionary?["name"]?.string == name
        }
        guard matches.count == 1, let identifier = matches.first else {
            throw Hub.Error.invalidProject(
                "target does not have exactly one \(name) build configuration"
            )
        }
        return identifier
    }

    func serialized() throws -> Data {
        var text = originalText
        for identifier in replacements.keys.sorted() {
            guard let value = replacements[identifier] else { continue }
            text = try Self.replacingRecord(
                identifier: identifier,
                value: value,
                in: text
            )
        }
        let grouped = Dictionary(grouping: additions.keys) { identifier in
            additions[identifier]?.dictionary?["isa"]?.string ?? ""
        }
        for isa in grouped.keys.sorted() {
            guard !isa.isEmpty else {
                throw Hub.Error.invalidProject("new PBX object has no isa")
            }
            let records = try grouped[isa, default: []].sorted().map { identifier in
                guard let value = additions[identifier] else {
                    throw Hub.Error.invalidProject("new PBX object disappeared")
                }
                return "\t\t\(identifier) = \(Self.render(value));"
            }.joined(separator: "\n")
            text = try Self.inserting(records: records, section: isa, into: text)
        }
        let data = Data(text.utf8)
        do {
            var parser = try Hub.OpenStep.Parser(data: data)
            _ = try parser.parse()
        } catch {
            throw Hub.Error.invalidProject(
                "generated PBX text failed validation: \(error)"
            )
        }
        return data
    }

    private static func replacingRecord(
        identifier: String,
        value: Hub.OpenStep.Value,
        in text: String
    ) throws -> String {
        let escaped = NSRegularExpression.escapedPattern(for: identifier)
        let expression = try NSRegularExpression(
            pattern: "(?m)^[\\t ]*\(escaped)(?:[\\t ]*/\\*[^\\r\\n]*?\\*/)?[\\t ]*=[\\t ]*"
        )
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: full)
        guard matches.count == 1, let match = matches.first,
              let prefixRange = Range(match.range, in: text)
        else {
            throw Hub.Error.invalidProject(
                "cannot uniquely locate PBX object \(identifier) for editing"
            )
        }
        let brace = prefixRange.upperBound
        guard brace < text.endIndex, text[brace] == "{" else {
            throw Hub.Error.invalidProject("PBX object \(identifier) is malformed")
        }
        let end = try dictionaryRecordEnd(from: brace, in: text)
        let start = prefixRange.lowerBound
        return text.replacingCharacters(
            in: start..<end,
            with: "\t\t\(identifier) = \(render(value));"
        )
    }

    private static func dictionaryRecordEnd(
        from openingBrace: String.Index,
        in text: String
    ) throws -> String.Index {
        var index = openingBrace
        var depth = 0
        var quoted = false
        var escaped = false
        var lineComment = false
        var blockComment = false
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            let following = next < text.endIndex ? text[next] : "\0"
            if lineComment {
                if character == "\n" { lineComment = false }
            } else if blockComment {
                if character == "*", following == "/" {
                    blockComment = false
                    index = next
                }
            } else if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else if character == "/", following == "/" {
                lineComment = true
                index = next
            } else if character == "/", following == "*" {
                blockComment = true
                index = next
            } else if character == "\"" {
                quoted = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    var end = text.index(after: index)
                    while end < text.endIndex, text[end].isWhitespace, text[end] != "\n" {
                        end = text.index(after: end)
                    }
                    guard end < text.endIndex, text[end] == ";" else {
                        throw Hub.Error.invalidProject("PBX object record lacks a semicolon")
                    }
                    return text.index(after: end)
                }
            }
            index = text.index(after: index)
        }
        throw Hub.Error.invalidProject("PBX object dictionary is unterminated")
    }

    private static func inserting(
        records: String,
        section: String,
        into text: String
    ) throws -> String {
        let marker = "/* End \(section) section */"
        if let range = text.range(of: marker) {
            return text.replacingCharacters(
                in: range.lowerBound..<range.lowerBound,
                with: records + "\n"
            )
        }
        let expression = try NSRegularExpression(
            pattern: "(?m)^[\\t ]*\\};[\\t ]*\\r?\\n[\\t ]*rootObject[\\t ]*="
        )
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.matches(in: text, range: full).last,
              let objectsEnd = Range(match.range, in: text)
        else {
            throw Hub.Error.invalidProject("cannot locate PBX objects dictionary terminator")
        }
        let block = "\n/* Begin \(section) section */\n\(records)\n/* End \(section) section */\n"
        return text.replacingCharacters(
            in: objectsEnd.lowerBound..<objectsEnd.lowerBound,
            with: block
        )
    }

    private static func render(_ value: Hub.OpenStep.Value) -> String {
        switch value {
        case let .string(value):
            return renderString(value)
        case let .array(values):
            guard !values.isEmpty else { return "()" }
            return "(" + values.map { render($0) + "," }.joined(separator: " ") + " )"
        case let .dictionary(values):
            guard !values.isEmpty else { return "{}" }
            let body = values.keys.sorted().map { key in
                "\(renderString(key)) = \(render(values[key]!));"
            }.joined(separator: " ")
            return "{ \(body) }"
        }
    }

    private static func renderString(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_.$/<>+-*[]@")
        )
        if !value.isEmpty,
           value.unicodeScalars.allSatisfy({ safe.contains($0) }),
           !value.contains("//"), !value.contains("/*") {
            return value
        }
        var result = "\""
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result + "\""
    }
}
}

extension Hub.OpenStep.Value {
    static func strings(_ values: [String]) -> Self {
        .array(values.map(Self.string))
    }
}
