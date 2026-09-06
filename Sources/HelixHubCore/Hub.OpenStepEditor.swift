import Foundation

extension Hub {
/// Edits use immutable source coordinates, so unchanged tokens and comments are
/// copied exactly once even when many objects in a large project are touched.
struct OpenStepEditor {
    private struct Edit {
        var range: Range<Int>
        var text: String
    }

    private let scalars: [Unicode.Scalar]
    private let newline: String
    private var edits: [Edit] = []

    init(text: String) {
        scalars = Array(text.unicodeScalars)
        newline = text.contains("\r\n") ? "\r\n" : "\n"
    }

    mutating func replace(_ syntax: OpenStep.Syntax, with value: OpenStep.Value) {
        guard syntax.value != value else { return }
        switch (syntax.value, value) {
        case let (.dictionary(old), .dictionary(new)):
            for key in old.keys.sorted() {
                guard let entry = syntax.entries[key] else { continue }
                if let replacement = new[key] {
                    replace(entry.value, with: replacement)
                } else {
                    edits.append(.init(range: entry.range, text: ""))
                }
            }
            let added = new.keys.filter { old[$0] == nil }.sorted()
            if !added.isEmpty {
                let indent = indentation(at: syntax.range.lowerBound)
                let body = added.map { key in
                    indent + "\t" + Self.render(.string(key)) + " = " + Self.render(new[key]!) + ";"
                }.joined(separator: newline)
                insert(newline + body + newline + indent, at: syntax.range.upperBound - 1)
            }
        case let (.array(old), .array(new)):
            replaceArray(syntax, old: old, new: new)
        default:
            edits.append(.init(range: syntax.range, text: Self.render(value)))
        }
    }

    func serialized() throws -> Data {
        let ordered = edits.enumerated().sorted {
            if $0.element.range.lowerBound != $1.element.range.lowerBound {
                return $0.element.range.lowerBound < $1.element.range.lowerBound
            }
            // Insertions precede a removal at the same original coordinate.
            if $0.element.range.isEmpty != $1.element.range.isEmpty {
                return $0.element.range.isEmpty
            }
            return $0.offset < $1.offset
        }.map(\.element)
        var cursor = 0
        var output = String.UnicodeScalarView()
        for edit in ordered {
            guard edit.range.lowerBound >= cursor, edit.range.upperBound <= scalars.count else {
                throw Hub.Error.invalidProject("PBX edits overlap at scalar \(edit.range.lowerBound)")
            }
            output.append(contentsOf: scalars[cursor..<edit.range.lowerBound])
            output.append(contentsOf: edit.text.unicodeScalars)
            cursor = edit.range.upperBound
        }
        output.append(contentsOf: scalars[cursor...])
        return Data(String(output).utf8)
    }

    private mutating func replaceArray(
        _ syntax: OpenStep.Syntax, old: [OpenStep.Value], new: [OpenStep.Value]
    ) {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var added = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): added.insert(offset)
            }
        }
        for index in removed.sorted() {
            edits.append(.init(range: syntax.elements[index].range, text: ""))
        }
        let survivors = old.indices.filter { !removed.contains($0) }
        var survivorIndex = 0
        var pending: [OpenStep.Value] = []
        for index in new.indices {
            if added.contains(index) {
                pending.append(new[index])
            } else {
                let element = syntax.elements[survivors[survivorIndex]]
                if !pending.isEmpty {
                    let separator = arraySeparator(syntax, at: element.value.range.lowerBound)
                    insert(pending.map { Self.render($0) + "," + separator }.joined(),
                           at: element.value.range.lowerBound)
                    pending.removeAll(keepingCapacity: true)
                }
                survivorIndex += 1
            }
        }
        if !pending.isEmpty {
            if let last = survivors.last, !syntax.elements[last].hasComma {
                insert(",", at: syntax.elements[last].value.range.upperBound)
            }
            let position = syntax.range.upperBound - 1
            let separator = arraySeparator(syntax, at: syntax.range.lowerBound) + "\t"
            insert(separator + pending.map { Self.render($0) + "," }.joined(separator: separator)
                   + arraySeparator(syntax, at: syntax.range.lowerBound), at: position)
        }
    }

    private func arraySeparator(_ syntax: OpenStep.Syntax, at position: Int) -> String {
        scalars[syntax.range].contains("\n") ? newline + indentation(at: position) : " "
    }

    private func indentation(at position: Int) -> String {
        var start = position
        while start > 0, scalars[start - 1] != "\n", scalars[start - 1] != "\r" { start -= 1 }
        var end = start
        while end < scalars.count, scalars[end] == " " || scalars[end] == "\t" { end += 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    private mutating func insert(_ text: String, at position: Int) {
        edits.append(.init(range: position..<position, text: text))
    }

    private static func render(_ value: OpenStep.Value) -> String {
        switch value {
        case let .array(values):
            return "(" + values.map { render($0) + "," }.joined(separator: " ") + ")"
        case let .dictionary(values):
            return "{ " + values.keys.sorted().map {
                render(.string($0)) + " = " + render(values[$0]!) + ";"
            }.joined(separator: " ") + " }"
        case let .string(value):
            // OpenStep bare words permit ASCII only; +, @, *, <, > and []
            // require quotes even though the old hand-written lexer accepted them.
            let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.$/-")
            if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }),
               !value.contains("//"), !value.contains("/*") { return value }
            var result = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\\": result += "\\\\"
                case "\"": result += "\\\""
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\t": result += "\\t"
                case "\0": result += "\\U0000"
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        }
    }
}
}
