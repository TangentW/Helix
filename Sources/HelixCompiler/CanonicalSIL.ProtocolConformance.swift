import Foundation

extension CanonicalSIL {
enum ProtocolConformance {}
}

extension CanonicalSIL.ProtocolConformance {
    struct Witness: Hashable, Sendable {
        var requirement: String
        var loweredType: String
        var symbol: String?
    }

    struct Record: Hashable, Sendable {
        var conformingType: String
        var protocolName: String
        var moduleName: String
        var genericClause: String?
        var associatedTypes: [String: String]
        var associatedConformances: [String: String]
        var baseProtocols: [String]
        var witnesses: [Witness]
        var unsupportedMembers: [String]

        var isComplete: Bool { unsupportedMembers.isEmpty }

        func witnesses(for requirement: String) -> [Witness] {
            witnesses.filter { $0.requirement == requirement }
        }

        var orderKey: String {
            [conformingType, protocolName, genericClause ?? ""]
                .joined(separator: "\u{0}")
        }

        var identityKey: String {
            [conformingType, protocolName].joined(separator: "\u{0}")
        }
    }

    /// Compiler-only inventory of concrete conformance evidence emitted by the
    /// captured Swift frontend. Runtime witness metadata never enters HLBC.
    struct Environment: Sendable {
        private static let maximumRecords = 16_384
        private static let maximumMembersPerRecord = 1_024
        private static let maximumLineUTF8Count = 64 * 1_024

        let records: [Record]

        func containsWitnessTarget(
            _ symbol: String,
            moduleName: String
        ) -> Bool {
            records.contains { record in
                record.moduleName == moduleName
                    && record.witnesses.contains { $0.symbol == symbol }
            }
        }

        init(text: String) throws {
            let lines = text.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).map(String.init)
            var parsed: [Record] = []
            var index = 0
            var tableCount = 0
            while index < lines.count {
                let line = lines[index]
                    .trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("sil_witness_table ") else {
                    index += 1
                    continue
                }
                guard tableCount < Self.maximumRecords else {
                    throw Self.malformed("too many protocol conformance records")
                }
                tableCount += 1
                let hasBody = line.hasSuffix("{")
                let header = try Self.parseHeader(line, hasBody: hasBody)
                index += 1
                // Imported modules may expose only a witness-table declaration.
                // It proves a conformance exists but carries no dispatch target.
                guard hasBody else { continue }
                var associatedTypes: [String: String] = [:]
                var associatedConformances: [String: String] = [:]
                var baseProtocols = Set<String>()
                var witnesses: [Witness] = []
                var unsupportedMembers: [String] = []
                var memberCount = 0
                var terminated = false
                while index < lines.count {
                    let member = lines[index]
                        .trimmingCharacters(in: .whitespaces)
                    if member == "}" {
                        terminated = true
                        index += 1
                        break
                    }
                    guard member.utf8.count <= Self.maximumLineUTF8Count else {
                        throw Self.malformed(
                            "protocol conformance member exceeds the size limit"
                        )
                    }
                    if !member.isEmpty {
                        memberCount += 1
                        guard memberCount <= Self.maximumMembersPerRecord else {
                            throw Self.malformed(
                                "protocol conformance has too many members"
                            )
                        }
                    }
                    if let pair = try Self.associatedType(in: member) {
                        guard associatedTypes.updateValue(
                            pair.value,
                            forKey: pair.name
                        ) == nil else {
                            throw Self.malformed(
                                "duplicate associated type \(pair.name) in "
                                    + "\(header.conformingType): \(header.protocolName)"
                            )
                        }
                    } else if let pair = try Self.associatedConformance(
                        in: member
                    ) {
                        guard associatedConformances.updateValue(
                            pair.value,
                            forKey: pair.name
                        ) == nil else {
                            throw Self.malformed(
                                "duplicate associated conformance \(pair.name) in "
                                    + "\(header.conformingType): \(header.protocolName)"
                            )
                        }
                    } else if let name = try Self.baseProtocol(in: member) {
                        guard baseProtocols.insert(name).inserted else {
                            throw Self.malformed(
                                "duplicate base protocol \(name) in "
                                    + "\(header.conformingType): \(header.protocolName)"
                            )
                        }
                    } else if let witness = try Self.witness(in: member) {
                        // SILDeclRef text can erase argument labels. Consequently,
                        // distinct protocol requirements may have the same printed
                        // name and lowered type; table order is the only evidence
                        // this inventory can faithfully retain.
                        witnesses.append(witness)
                    } else if !member.isEmpty,
                              !member.hasPrefix("//") {
                        unsupportedMembers.append(member)
                    }
                    index += 1
                }
                guard terminated else {
                    throw Self.malformed(
                        "unterminated protocol conformance "
                            + "\(header.conformingType): \(header.protocolName)"
                    )
                }
                parsed.append(
                    .init(
                        conformingType: header.conformingType,
                        protocolName: header.protocolName,
                        moduleName: header.moduleName,
                        genericClause: header.genericClause,
                        associatedTypes: associatedTypes,
                        associatedConformances: associatedConformances,
                        baseProtocols: baseProtocols.sorted(),
                        witnesses: witnesses,
                        unsupportedMembers: unsupportedMembers
                    )
                )
            }
            let sorted = parsed.sorted { $0.orderKey < $1.orderKey }
            guard Set(sorted.map(\.identityKey)).count == sorted.count else {
                throw Self.malformed("duplicate protocol conformance record")
            }
            records = sorted
        }

        private struct Header {
            var conformingType: String
            var protocolName: String
            var moduleName: String
            var genericClause: String?
        }

        private static func parseHeader(
            _ line: String,
            hasBody: Bool
        ) throws -> Header {
            guard line.utf8.count <= maximumLineUTF8Count else {
                throw malformed(
                    "malformed protocol conformance header: "
                        + String(line.prefix(256))
                )
            }
            var body = String(line.dropFirst("sil_witness_table ".count))
            if hasBody {
                body.removeLast()
            }
            body = body.trimmingCharacters(in: .whitespaces)
            guard let moduleRange = body.range(
                of: " module ",
                options: .backwards
            ) else {
                throw malformed("protocol conformance header has no module")
            }
            let moduleName = body[moduleRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            body = body[..<moduleRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard Self.isIdentifierPath(moduleName) else {
                throw malformed("protocol conformance has an invalid module")
            }
            body = try strippingHeaderAttributes(from: body)
            var genericClause: String?
            if body.hasPrefix("<") {
                guard let close = matchingClose(
                    in: body,
                    from: body.startIndex,
                    open: "<",
                    close: ">"
                ) else {
                    throw malformed(
                        "protocol conformance generic clause is unterminated"
                    )
                }
                genericClause = String(body[...close])
                body = body[body.index(after: close)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let separator = topLevelSeparator(":", in: body) else {
                throw malformed(
                    "protocol conformance header has no type/protocol separator"
                )
            }
            let conformingType = body[..<separator]
                .trimmingCharacters(in: .whitespaces)
            let protocolName = body[body.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !conformingType.isEmpty,
                  !protocolName.isEmpty,
                  protocolName.utf8.count <= 1_024,
                  conformingType.utf8.count <= 4_096
            else {
                throw malformed("protocol conformance has an invalid identity")
            }
            return .init(
                conformingType: conformingType,
                protocolName: protocolName,
                moduleName: moduleName,
                genericClause: genericClause
            )
        }

        private static func strippingHeaderAttributes(
            from raw: String
        ) throws -> String {
            var value = raw.trimmingCharacters(in: .whitespaces)
            let modifiers = Set([
                "public", "public_external", "hidden", "shared", "private",
                "package", "package_external", "non_abi", "public_non_abi",
                "serialized",
            ])
            while !value.isEmpty {
                if value.hasPrefix("[") {
                    guard let close = matchingClose(
                        in: value,
                        from: value.startIndex,
                        open: "[",
                        close: "]"
                    ) else {
                        throw malformed(
                            "protocol conformance attribute is unterminated"
                        )
                    }
                    value = value[value.index(after: close)...]
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
                let tokenEnd = value.firstIndex(where: \.isWhitespace)
                    ?? value.endIndex
                let token = String(value[..<tokenEnd])
                guard modifiers.contains(token) else { break }
                value = value[tokenEnd...]
                    .trimmingCharacters(in: .whitespaces)
            }
            return value
        }

        private static func associatedType(
            in line: String
        ) throws -> (name: String, value: String)? {
            let prefix = "associated_type "
            guard line.hasPrefix(prefix) else { return nil }
            let body = String(line.dropFirst(prefix.count))
            guard let separator = topLevelSeparator(":", in: body) else {
                throw malformed("associated type has no value")
            }
            let name = body[..<separator]
                .trimmingCharacters(in: .whitespaces)
            let value = body[body.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard isIdentifierPath(name), !value.isEmpty else {
                throw malformed("associated type is malformed")
            }
            return (name, value)
        }

        private static func associatedConformance(
            in line: String
        ) throws -> (name: String, value: String)? {
            let prefixes = [
                "associated_conformance ",
                "associated_type_protocol ",
            ]
            guard let prefix = prefixes.first(where: line.hasPrefix) else {
                return nil
            }
            let body = String(line.dropFirst(prefix.count))
            guard let separator = topLevelSeparator(":", in: body) else {
                throw malformed("associated conformance has no evidence")
            }
            let name = body[..<separator]
                .trimmingCharacters(in: .whitespaces)
            let value = body[body.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else {
                throw malformed("associated conformance is malformed")
            }
            return (name, value)
        }

        private static func baseProtocol(in line: String) throws -> String? {
            let prefix = "base_protocol "
            guard line.hasPrefix(prefix) else { return nil }
            let body = String(line.dropFirst(prefix.count))
            guard let separator = topLevelSeparator(":", in: body) else {
                throw malformed("base protocol has no conformance evidence")
            }
            let name = body[..<separator]
                .trimmingCharacters(in: .whitespaces)
            guard isIdentifierPath(name) else {
                throw malformed("base protocol has an invalid identity")
            }
            return name
        }

        private static func witness(in line: String) throws -> Witness? {
            let prefix = "method #"
            guard line.hasPrefix(prefix) else { return nil }
            let syntax = removingTrailingComment(from: line)
            let body = String(syntax.dropFirst(prefix.count))
            guard let targetSeparator = body.range(
                of: " : ",
                options: .backwards
            ) else {
                throw malformed("protocol witness has no target")
            }
            let declaration = String(body[..<targetSeparator.lowerBound])
            let target = body[targetSeparator.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            guard let typeSeparator = topLevelSeparator(
                ":",
                in: declaration
            ) else {
                throw malformed("protocol witness has no lowered type")
            }
            let requirement = declaration[..<typeSeparator]
                .trimmingCharacters(in: .whitespaces)
            let loweredType = declaration[
                declaration.index(after: typeSeparator)...
            ].trimmingCharacters(in: .whitespaces)
            guard !requirement.isEmpty,
                  !loweredType.isEmpty,
                  requirement.utf8.count <= 2_048,
                  loweredType.utf8.count <= maximumLineUTF8Count
            else {
                throw malformed("protocol witness is malformed")
            }
            let symbol: String?
            if target == "nil" || target == "no_default" {
                symbol = nil
            } else if target.hasPrefix("@") {
                let value = String(target.dropFirst())
                guard !value.isEmpty,
                      value.rangeOfCharacter(
                        from: .whitespacesAndNewlines
                      ) == nil
                else {
                    throw malformed("protocol witness target is malformed")
                }
                symbol = value
            } else {
                throw malformed("protocol witness target is unsupported")
            }
            return .init(
                requirement: requirement,
                loweredType: loweredType,
                symbol: symbol
            )
        }

        private static func topLevelSeparator(
            _ separator: Character,
            in text: String
        ) -> String.Index? {
            var depths: [Character: Int] = ["(": 0, "<": 0, "[": 0]
            var isQuoted = false
            var isEscaped = false
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if isQuoted {
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == "\"" {
                        isQuoted = false
                    }
                    index = text.index(after: index)
                    continue
                }
                if character == "\"" {
                    isQuoted = true
                } else {
                    switch character {
                    case "(": depths["(", default: 0] += 1
                    case ")": depths["(", default: 0] -= 1
                    case "<": depths["<", default: 0] += 1
                    case ">":
                        let previous = index > text.startIndex
                            ? text[text.index(before: index)] : nil
                        if previous != "-" { depths["<", default: 0] -= 1 }
                    case "[": depths["[", default: 0] += 1
                    case "]": depths["[", default: 0] -= 1
                    default: break
                    }
                    if depths.values.contains(where: { $0 < 0 }) {
                        return nil
                    }
                    if character == separator,
                       depths.values.allSatisfy({ $0 == 0 }) {
                        return index
                    }
                }
                index = text.index(after: index)
            }
            guard !isQuoted,
                  depths.values.allSatisfy({ $0 == 0 })
            else { return nil }
            return nil
        }

        private static func matchingClose(
            in text: String,
            from openIndex: String.Index,
            open: Character,
            close: Character
        ) -> String.Index? {
            var depth = 0
            var index = openIndex
            while index < text.endIndex {
                if text[index] == open {
                    depth += 1
                } else if text[index] == close {
                    let previous = index > text.startIndex
                        ? text[text.index(before: index)] : nil
                    if close != ">" || previous != "-" {
                        depth -= 1
                        if depth == 0 { return index }
                    }
                }
                guard depth >= 0 else { return nil }
                index = text.index(after: index)
            }
            return nil
        }

        private static func removingTrailingComment(
            from line: String
        ) -> String {
            var isQuoted = false
            var isEscaped = false
            var index = line.startIndex
            while index < line.endIndex {
                let character = line[index]
                if isQuoted {
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == "\"" {
                        isQuoted = false
                    }
                } else if character == "\"" {
                    isQuoted = true
                } else if character == "/" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "/" {
                        return line[..<index]
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
                index = line.index(after: index)
            }
            return line.trimmingCharacters(in: .whitespaces)
        }

        private static func isIdentifierPath(_ value: String) -> Bool {
            value.range(
                of: #"^[A-Za-z_][A-Za-z0-9_.]*$"#,
                options: .regularExpression
            ) != nil
        }

        private static func malformed(
            _ reason: String
        ) -> CanonicalSIL.LoweringError {
            .malformedSIL(reason)
        }
    }
}
