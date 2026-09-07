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

    struct ConditionalConformance: Hashable, Sendable {
        var requirement: String
        var evidence: String
    }

    struct Record: Hashable, Sendable {
        // A record occurrence is local to this SIL document. Printed type and
        // protocol names are lookup hints, not declaration identity.
        var sourceLine: Int
        var header: String
        var conformingType: String
        var protocolName: String
        var moduleName: String
        var genericClause: String?
        var associatedTypes: [String: String]
        var associatedConformances: [String: String]
        var conditionalConformances: [ConditionalConformance]
        var baseProtocols: [String]
        var witnesses: [Witness]
        var unsupportedMembers: [String]

        var isComplete: Bool { unsupportedMembers.isEmpty }

        func witnesses(for requirement: String) -> [Witness] {
            witnesses.filter { $0.requirement == requirement }
        }

        var orderKey: String {
            [moduleName, conformingType, protocolName, genericClause ?? ""]
                .joined(separator: "\u{0}")
        }

        var evidence: String {
            "SIL line \(sourceLine): \(header); witnesses=\(witnesses.map { "#\($0.requirement): \($0.loweredType) -> \($0.symbol ?? "nil")" }); "
                + "associatedTypes=\(associatedTypes.sorted { $0.key < $1.key }), associatedConformances=\(associatedConformances.sorted { $0.key < $1.key }), "
                + "conditions=\(conditionalConformances), bases=\(baseProtocols), unsupported=\(unsupportedMembers)"
        }
    }

    /// Compiler-only inventory of concrete conformance evidence emitted by the
    /// captured Swift frontend. Runtime witness metadata never enters HLBC.
    struct Environment: Sendable {
        private static let maximumRecords = 16_384
        private static let maximumMembersPerRecord = 1_024
        private static let maximumLineUTF8Count = 64 * 1_024

        let records: [Record]
        let unambiguousRecords: [Record]
        private let ambiguitiesByType: [String: [Record]]
        private let witnessTargetsByModule: [String: Set<String>]

        private struct TypeLookupKey: Hashable {
            var module: String
            var spelling: String
        }

        private struct ConformanceLookupKey: Hashable {
            var type: TypeLookupKey
            var protocolSpelling: String
        }

        private static func typeKey(_ record: Record) -> TypeLookupKey {
            .init(module: record.moduleName,
                  spelling: typeBase(relative(record.conformingType, to: record.moduleName)))
        }

        private static func typeBase(_ spelling: String) -> String {
            let normalized = CanonicalSIL.SwiftTypeIdentity.normalized(spelling)
            guard let components = try? CanonicalSIL.GenericSignature.splitTopLevel(
                normalized, separator: ".") else { return normalized }
            // Generic parameter spellings cannot disambiguate nominal scopes.
            return components.map { String($0.prefix { $0 != "<" }) }.joined(separator: ".")
        }

        private static func typeScopes(_ spelling: String) -> [String] {
            var components = typeBase(spelling).split(separator: ".").map(String.init)
            var scopes: [String] = []
            while !components.isEmpty {
                scopes.append(components.joined(separator: "."))
                components.removeLast()
            }
            return scopes
        }

        private static func relative(_ spelling: String, to module: String) -> String {
            let normalized = CanonicalSIL.SwiftTypeIdentity.normalized(spelling)
            return normalized.hasPrefix(module + ".")
                ? String(normalized.dropFirst(module.count + 1)) : normalized
        }

        func isAmbiguousType(_ spelling: String) -> Bool {
            Self.typeScopes(spelling).contains { ambiguitiesByType[$0] != nil }
        }

        func ambiguityEvidence(for spelling: String) -> [String] {
            Set(Self.typeScopes(spelling).flatMap { ambiguitiesByType[$0, default: []] })
                .sorted { $0.sourceLine < $1.sourceLine }.map(\.evidence)
        }

        func containsWitnessTarget(
            _ symbol: String,
            moduleName: String
        ) -> Bool {
            witnessTargetsByModule[moduleName]?.contains(symbol) == true
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
                let sourceLine = index + 1
                let hasBody = line.hasSuffix("{")
                let header = try Self.parseHeader(line, hasBody: hasBody)
                index += 1
                // Imported modules may expose only a witness-table declaration.
                // It proves a conformance exists but carries no dispatch target.
                guard hasBody else { continue }
                var associatedTypes: [String: String] = [:]
                var associatedConformances: [String: String] = [:]
                var conditionalConformances: [ConditionalConformance] = []
                var baseProtocols = Set<String>()
                var witnesses: [Witness] = []
                var unsupportedMembers: [String] = []
                var memberCount = 0
                var memberOrigins: [String: String] = [:]
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
                    // Keep both raw facts before rejecting a duplicate member.
                    func register(_ key: String) throws {
                        let fact = "SIL line \(index + 1): \(member)"
                        if let previous = memberOrigins.updateValue(fact, forKey: key) {
                            throw Self.malformed("duplicate \(key) in SIL line \(sourceLine): \(line); \(previous); \(fact)")
                        }
                    }
                    if let pair = try Self.associatedType(in: member) {
                        try register("associated type " + pair.name)
                        associatedTypes[pair.name] = pair.value
                    } else if let pair = try Self.associatedConformance(
                        in: member
                    ) {
                        try register("associated conformance " + pair.name)
                        associatedConformances[pair.name] = pair.value
                    } else if let name = try Self.baseProtocol(in: member) {
                        try register("base protocol " + name)
                        baseProtocols.insert(name)
                    } else if let conformance = try Self
                        .conditionalConformance(in: member) {
                        try register("conditional conformance " + conformance.requirement)
                        conditionalConformances.append(conformance)
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
                if !Self.conditionalConformancesAreCovered(
                    conditionalConformances,
                    by: header.genericClause
                ) {
                    unsupportedMembers.append(
                        "inconsistent conditional conformance evidence"
                    )
                }
                parsed.append(
                    .init(
                        sourceLine: sourceLine,
                        header: line,
                        conformingType: header.conformingType,
                        protocolName: header.protocolName,
                        moduleName: header.moduleName,
                        genericClause: header.genericClause,
                        associatedTypes: associatedTypes,
                        associatedConformances: associatedConformances,
                        conditionalConformances: conditionalConformances,
                        baseProtocols: baseProtocols.sorted(),
                        witnesses: witnesses,
                        unsupportedMembers: unsupportedMembers
                    )
                )
            }
            let sorted = parsed.sorted {
                ($0.orderKey, $0.sourceLine) < ($1.orderKey, $1.sourceLine)
            }
            records = sorted
            let groups = Dictionary(grouping: sorted) {
                ConformanceLookupKey(type: Self.typeKey($0),
                    protocolSpelling: Self.relative($0.protocolName, to: $0.moduleName))
            }
            let ambiguousTypeKeys = Set(groups.filter { $0.value.count > 1 }.keys.map(\.type))
            func isAmbiguous(_ record: Record) -> Bool {
                let key = Self.typeKey(record)
                return Self.typeScopes(key.spelling).contains {
                    ambiguousTypeKeys.contains(.init(module: key.module, spelling: $0))
                }
            }
            // Filtering unsupported members or conditional clauses must not
            // turn a name collision into a falsely unique dispatch target.
            unambiguousRecords = sorted.filter { !isAmbiguous($0) }
            ambiguitiesByType = sorted.filter(isAmbiguous)
                .reduce(into: [:]) { result, record in
                    let key = Self.typeKey(record)
                    for spelling in [key.spelling, key.module + "." + key.spelling] {
                        result[spelling, default: []].append(record)
                    }
                }
            witnessTargetsByModule = sorted.reduce(into: [:]) { result, record in
                result[record.moduleName, default: []].formUnion(record.witnesses.compactMap(\.symbol))
            }
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

        private static func conditionalConformance(
            in line: String
        ) throws -> ConditionalConformance? {
            let prefix = "conditional_conformance "
            guard line.hasPrefix(prefix) else { return nil }
            let body = String(line.dropFirst(prefix.count))
            guard let separator = topLevelSeparator(":", in: body) else {
                throw malformed("conditional conformance has no evidence")
            }
            var requirement = body[..<separator]
                .trimmingCharacters(in: .whitespaces)
            let evidence = body[body.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if requirement.first == "(", requirement.last == ")" {
                requirement.removeFirst()
                requirement.removeLast()
                requirement = requirement.trimmingCharacters(in: .whitespaces)
            }
            guard !requirement.isEmpty, !evidence.isEmpty,
                  requirement.rangeOfCharacter(from: .newlines) == nil,
                  evidence.rangeOfCharacter(from: .newlines) == nil
            else {
                throw malformed("conditional conformance is malformed")
            }
            return .init(requirement: requirement, evidence: evidence)
        }

        private static func conditionalConformancesAreCovered(
            _ values: [ConditionalConformance],
            by rawClause: String?
        ) -> Bool {
            guard !values.isEmpty else { return true }
            guard let rawClause,
                  let clause = try? CanonicalSIL.GenericSignature
                    .standaloneClause(rawClause)
            else { return false }

            var declared = Set<String>()
            for requirement in clause.requirements
            where requirement.relation == .conformance {
                guard let constraints = try? CanonicalSIL.GenericSignature
                    .splitComposition(requirement.right)
                else { return false }
                for constraint in constraints {
                    declared.insert(
                        normalizedRequirement(
                            left: requirement.left,
                            right: constraint
                        )
                    )
                }
            }

            var seen = Set<String>()
            for value in values {
                guard let partition = try? CanonicalSIL.GenericSignature
                    .partitionTopLevel(value.requirement, at: ":"),
                      !partition.before.isEmpty,
                      !partition.after.isEmpty,
                      let constraints = try? CanonicalSIL.GenericSignature
                        .splitComposition(partition.after),
                      !constraints.isEmpty
                else { return false }
                for constraint in constraints {
                    let key = normalizedRequirement(
                        left: partition.before,
                        right: constraint
                    )
                    guard declared.contains(key), seen.insert(key).inserted else {
                        return false
                    }
                }
            }
            return true
        }

        private static func normalizedRequirement(
            left: String,
            right: String
        ) -> String {
            left.filter { !$0.isWhitespace }
                + ":" + right.filter { !$0.isWhitespace }
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
