import Foundation
import HelixBytecode

extension CanonicalSIL {
enum ProtocolExistential {}
}

extension CanonicalSIL.ProtocolExistential {
    /// A source-level protocol existential identity. Protocol metadata is kept
    /// in the compiler and deliberately does not become part of HLBC.
    struct Identity: Hashable, Sendable, CustomStringConvertible {
        static let maximumProtocolCount = 16

        var protocols: [String]
        var requiresClass: Bool

        init?(spelling raw: String) {
            var spelling = Self.strippingTypeDecorations(from: raw)
            guard spelling.hasPrefix("any ") else { return nil }
            spelling.removeFirst("any ".count)
            let components = Self.splitComposition(spelling).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard !components.isEmpty,
                  components.count <= Self.maximumProtocolCount,
                  components.allSatisfy({ !$0.isEmpty })
            else { return nil }

            var requiresClass = false
            var protocols: [String] = []
            for component in components {
                let normalized = Self.normalizedProtocolName(component)
                if normalized == "AnyObject" {
                    requiresClass = true
                    continue
                }
                // Error has a dedicated typed representation. Sendable is a
                // concurrency marker with no synchronous witness surface.
                guard normalized != "Error",
                      normalized != "Sendable",
                      normalized != "_Concurrency.Sendable",
                      Self.isIdentifierPath(normalized)
                else { return nil }
                protocols.append(normalized)
            }
            protocols.sort()
            guard !protocols.isEmpty,
                  Set(protocols).count == protocols.count
            else { return nil }
            self.protocols = protocols
            self.requiresClass = requiresClass
        }

        static func optionalPayload(
            spelling raw: String
        ) -> Identity? {
            let spelling = strippingTypeDecorations(from: raw)
            if spelling.hasSuffix("?") || spelling.hasSuffix("!") {
                return Identity(spelling: String(spelling.dropLast()))
            }
            for prefix in ["Optional<", "Swift.Optional<"]
            where spelling.hasPrefix(prefix) && spelling.hasSuffix(">") {
                let start = spelling.index(
                    spelling.startIndex,
                    offsetBy: prefix.count
                )
                return Identity(
                    spelling: String(spelling[start..<spelling.index(before: spelling.endIndex)])
                )
            }
            return nil
        }

        static func functionResult(
            spelling raw: String
        ) -> Identity? {
            let spelling = raw.trimmingCharacters(in: .whitespaces)
                .trimmingPrefix("$")
            var angles = 0
            var parentheses = 0
            var brackets = 0
            var quoted = false
            var escaped = false
            var index = spelling.startIndex
            while index < spelling.endIndex {
                let character = spelling[index]
                if quoted {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        quoted = false
                    }
                    index = spelling.index(after: index)
                    continue
                }
                switch character {
                case "\"": quoted = true
                case "<": angles += 1
                case ">": angles -= 1
                case "(": parentheses += 1
                case ")": parentheses -= 1
                case "[": brackets += 1
                case "]": brackets -= 1
                case "-" where angles == 0 && parentheses == 0
                    && brackets == 0:
                    let next = spelling.index(after: index)
                    if next < spelling.endIndex, spelling[next] == ">" {
                        return Identity(
                            spelling: String(spelling[spelling.index(
                                after: next
                            )...])
                        )
                    }
                default: break
                }
                guard angles >= 0, parentheses >= 0, brackets >= 0 else {
                    return nil
                }
                index = spelling.index(after: index)
            }
            return nil
        }

        /// Finds source-level protocol existential spellings nested anywhere
        /// in a SIL type. This is intentionally lexical: the compiler keeps
        /// protocol identities outside HLBC, so Shell and NativeImport
        /// boundary checks must run before the represented type becomes Any.
        static func identities(in raw: String) -> [Identity] {
            existentialSpellings(in: raw).compactMap(Identity.init(spelling:))
        }

        /// Unlike `identities(in:)`, this boundary predicate also recognizes
        /// protocol spellings that the current image-local profile does not
        /// lower, such as Sendable or an Error composition. Plain `any Error`
        /// retains its separate typed boundary representation.
        static func containsProtocolExistential(in raw: String) -> Bool {
            existentialSpellings(in: raw).contains { spelling in
                let normalized = strippingTypeDecorations(from: spelling)
                    .filter { !$0.isWhitespace }
                return normalized != "anyError"
                    && normalized != "anySwift.Error"
            }
        }

        private static func existentialSpellings(in raw: String) -> [String] {
            var result: [String] = []
            var index = raw.startIndex
            while index < raw.endIndex {
                guard raw[index...].hasPrefix("any") else {
                    index = raw.index(after: index)
                    continue
                }
                let keywordEnd = raw.index(index, offsetBy: "any".count)
                let hasIdentifierBefore = index > raw.startIndex
                    && Self.isIdentifierCharacter(
                        raw[raw.index(before: index)]
                    )
                guard !hasIdentifierBefore,
                      keywordEnd < raw.endIndex,
                      raw[keywordEnd].isWhitespace
                else {
                    index = keywordEnd
                    continue
                }

                var end = keywordEnd
                while end < raw.endIndex,
                      Self.isExistentialSpellingCharacter(raw[end]) {
                    end = raw.index(after: end)
                }
                result.append(String(raw[index..<end]))
                index = end
            }
            return result
        }

        var description: String {
            "any " + (protocols + (requiresClass ? ["AnyObject"] : []))
                .joined(separator: " & ")
        }

        func containsProtocol(
            _ raw: String,
            moduleName: String
        ) -> Bool {
            protocols.contains { name in
                Self.namesEquivalent(
                    name,
                    raw,
                    moduleName: moduleName
                )
            }
        }

        static func namesEquivalent(
            _ lhs: String,
            _ rhs: String,
            moduleName: String
        ) -> Bool {
            let lhs = normalizedProtocolName(lhs)
            let rhs = normalizedProtocolName(rhs)
            return lhs == rhs
                || lhs == moduleName + "." + rhs
                || rhs == moduleName + "." + lhs
        }

        private static func normalizedProtocolName(_ raw: String) -> String {
            let compact = raw.filter { !$0.isWhitespace }
            return compact.hasPrefix("Swift.")
                ? String(compact.dropFirst("Swift.".count)) : compact
        }

        private static func strippingTypeDecorations(
            from raw: String
        ) -> String {
            var spelling = raw.trimmingCharacters(in: .whitespaces)
            var changed = true
            while changed {
                changed = false
                for prefix in [
                    "$*", "$", "@owned ", "@guaranteed ", "@unowned ",
                    "@autoreleased ", "@in ", "@in_guaranteed ", "@out ",
                    "@closureCapture ",
                ] where spelling.hasPrefix(prefix) {
                    spelling.removeFirst(prefix.count)
                    spelling = spelling.trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
            }
            return spelling
        }

        private static func splitComposition(_ raw: String) -> [String] {
            var result: [String] = []
            var start = raw.startIndex
            var angles = 0
            var parentheses = 0
            for index in raw.indices {
                switch raw[index] {
                case "<": angles += 1
                case ">": angles -= 1
                case "(": parentheses += 1
                case ")": parentheses -= 1
                default: break
                }
                guard angles >= 0, parentheses >= 0 else { return [] }
                if raw[index] == "&", angles == 0, parentheses == 0 {
                    result.append(String(raw[start..<index]))
                    start = raw.index(after: index)
                }
            }
            guard angles == 0, parentheses == 0 else { return [] }
            result.append(String(raw[start...]))
            return result
        }

        private static func isIdentifierPath(_ raw: String) -> Bool {
            let components = raw.split(separator: ".", omittingEmptySubsequences: false)
            guard !components.isEmpty else { return false }
            return components.allSatisfy { component in
                guard let first = component.first,
                      first == "_" || first.isLetter
                else { return false }
                return component.dropFirst().allSatisfy {
                    $0 == "_" || $0.isLetter || $0.isNumber
                }
            }
        }

        private static func isIdentifierCharacter(_ character: Character) -> Bool {
            character == "_" || character.isLetter || character.isNumber
        }

        private static func isExistentialSpellingCharacter(
            _ character: Character
        ) -> Bool {
            character.isWhitespace
                || isIdentifierCharacter(character)
                || character == "."
                || character == "&"
        }
    }

    struct OpenedArchetype: Hashable, Sendable {
        var spelling: String
        var identity: Identity

        init?(spelling raw: String) {
            let spelling = raw.trimmingCharacters(in: .whitespaces)
            guard spelling.hasPrefix("@opened("),
                  let close = Self.matchingClose(in: spelling),
                  spelling[spelling.index(after: close)...]
                    .trimmingCharacters(in: .whitespaces) == "Self"
            else { return nil }
            let bodyStart = spelling.index(
                spelling.startIndex,
                offsetBy: "@opened(".count
            )
            let body = spelling[bodyStart..<close]
            guard let separator = Self.firstTopLevelComma(in: body) else {
                return nil
            }
            let existential = body[body.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard let identity = Identity(spelling: existential) else {
                return nil
            }
            self.spelling = spelling
            self.identity = identity
        }

        private static func matchingClose(in raw: String) -> String.Index? {
            var parentheses = 0
            var quoted = false
            var escaped = false
            var index = raw.startIndex
            while index < raw.endIndex {
                let character = raw[index]
                if quoted {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        quoted = false
                    }
                } else if character == "\"" {
                    quoted = true
                } else if character == "(" {
                    parentheses += 1
                } else if character == ")" {
                    parentheses -= 1
                    if parentheses == 0 { return index }
                }
                guard parentheses >= 0 else { return nil }
                index = raw.index(after: index)
            }
            return nil
        }

        private static func firstTopLevelComma<T: StringProtocol>(
            in raw: T
        ) -> T.Index? {
            var angles = 0
            var parentheses = 0
            var quoted = false
            var escaped = false
            for index in raw.indices {
                let character = raw[index]
                if quoted {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        quoted = false
                    }
                    continue
                }
                switch character {
                case "\"": quoted = true
                case "<": angles += 1
                case ">": angles -= 1
                case "(": parentheses += 1
                case ")": parentheses -= 1
                case "," where angles == 0 && parentheses == 0:
                    return index
                default: break
                }
                guard angles >= 0, parentheses >= 0 else { return nil }
            }
            return nil
        }
    }

    struct WitnessReference: Hashable, Sendable {
        var result: String
        var openedArchetype: OpenedArchetype
        var requirement: String
        var requirementType: String
        var receiver: String
        var receiverType: String
        var functionType: String

        static func inventory(
            in body: String
        ) throws -> [String: WitnessReference] {
            let lines = body.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).map(String.init)
            var references: [String: WitnessReference] = [:]
            for rawLine in lines {
                let line = CanonicalSIL.DebugMetadata.strippingComment(
                    from: rawLine
                ).trimmingCharacters(in: .whitespaces)
                if line.contains(" = witness_method $@opened(") {
                    guard let reference = parse(line) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "malformed opened protocol witness reference"
                        )
                    }
                    guard references.updateValue(
                        reference,
                        forKey: reference.result
                    ) == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "duplicate opened protocol witness value \(reference.result)"
                        )
                    }
                    continue
                }
                guard let alias = alias(in: line),
                      let reference = references[alias.source]
                else { continue }
                guard references.updateValue(
                    reference,
                    forKey: alias.result
                ) == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "duplicate opened protocol witness alias \(alias.result)"
                    )
                }
            }
            return references
        }

        private static func parse(_ line: String) -> WitnessReference? {
            guard let assignment = line.range(of: " = witness_method $"),
                  line[..<assignment.lowerBound].first == "%"
            else { return nil }
            let result = String(line[..<assignment.lowerBound])
            let body = line[assignment.upperBound...]
            guard let requirementMarker = topLevelRange(of: ", #", in: body)
            else { return nil }
            let openedSpelling = body[..<requirementMarker.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard let opened = OpenedArchetype(spelling: openedSpelling)
            else { return nil }
            let declarationAndType = body[requirementMarker.upperBound...]
            guard let functionMarker = declarationAndType.range(
                of: " : $",
                options: .backwards
            ) else { return nil }
            let declaration = declarationAndType[..<functionMarker.lowerBound]
            let functionType = declarationAndType[functionMarker.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            guard let requirementSeparator = topLevelIndex(
                of: ":",
                in: declaration
            ) else { return nil }
            let requirement = declaration[..<requirementSeparator]
                .trimmingCharacters(in: .whitespaces)
            let requirementAndReceiver = declaration[
                declaration.index(after: requirementSeparator)...
            ]
            guard let receiverSeparator = topLevelIndex(
                of: ",",
                in: requirementAndReceiver
            ) else { return nil }
            let requirementType = requirementAndReceiver[
                ..<receiverSeparator
            ].trimmingCharacters(in: .whitespaces)
            let receiverClause = requirementAndReceiver[
                requirementAndReceiver.index(after: receiverSeparator)...
            ].trimmingCharacters(in: .whitespaces)
            guard let receiverTypeMarker = receiverClause.range(of: " : $"),
                  let receiver = silValue(in: receiverClause),
                  receiverClause[..<receiverTypeMarker.lowerBound]
                    .trimmingCharacters(in: .whitespaces) == receiver,
                  !requirement.isEmpty,
                  !requirementType.isEmpty,
                  !functionType.isEmpty
            else { return nil }
            var receiverType = receiverClause[receiverTypeMarker.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            if receiverType.hasPrefix("*") { receiverType.removeFirst() }
            guard let receiverOpened = OpenedArchetype(
                spelling: receiverType
            ), receiverOpened == opened
            else { return nil }
            return .init(
                result: result,
                openedArchetype: opened,
                requirement: requirement,
                requirementType: requirementType,
                receiver: receiver,
                receiverType: receiverType,
                functionType: functionType
            )
        }

        private static func alias(
            in line: String
        ) -> (result: String, source: String)? {
            for marker in [
                " = begin_borrow ", " = copy_value ", " = move_value ",
            ] {
                guard let range = line.range(of: marker) else { continue }
                let result = line[..<range.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                let suffix = line[range.upperBound...]
                guard result.first == "%", let source = silValue(in: suffix)
                else { return nil }
                return (String(result), source)
            }
            return nil
        }

        private static func silValue<T: StringProtocol>(
            in raw: T
        ) -> String? {
            guard let start = raw.firstIndex(of: "%") else { return nil }
            let digitsStart = raw.index(after: start)
            let digits = raw[digitsStart...].prefix(while: \.isNumber)
            guard !digits.isEmpty else { return nil }
            let end = raw.index(digitsStart, offsetBy: digits.count)
            return String(raw[start..<end])
        }

        private static func topLevelRange<T: StringProtocol>(
            of marker: String,
            in text: T
        ) -> Range<T.Index>? {
            var state = DelimiterState()
            var index = text.startIndex
            while index < text.endIndex {
                if state.isTopLevel, text[index...].hasPrefix(marker) {
                    return index..<text.index(index, offsetBy: marker.count)
                }
                guard state.consume(
                    text[index],
                    previous: previousCharacter(index, in: text)
                ) else { return nil }
                index = text.index(after: index)
            }
            return nil
        }

        private static func topLevelIndex<T: StringProtocol>(
            of marker: Character,
            in text: T
        ) -> T.Index? {
            var state = DelimiterState()
            var index = text.startIndex
            while index < text.endIndex {
                if state.isTopLevel, text[index] == marker { return index }
                guard state.consume(
                    text[index],
                    previous: previousCharacter(index, in: text)
                ) else { return nil }
                index = text.index(after: index)
            }
            return nil
        }

        private static func previousCharacter<T: StringProtocol>(
            _ index: T.Index,
            in text: T
        ) -> Character? {
            index > text.startIndex ? text[text.index(before: index)] : nil
        }

        private struct DelimiterState {
            var parentheses = 0
            var angles = 0
            var brackets = 0
            var quoted = false
            var escaped = false

            var isTopLevel: Bool {
                !quoted && parentheses == 0 && angles == 0 && brackets == 0
            }

            mutating func consume(
                _ character: Character,
                previous: Character?
            ) -> Bool {
                if quoted {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        quoted = false
                    }
                    return true
                }
                if character == "\"" {
                    quoted = true
                } else {
                    switch character {
                    case "(": parentheses += 1
                    case ")": parentheses -= 1
                    case "<": angles += 1
                    case ">":
                        if previous != "-" { angles -= 1 }
                    case "[": brackets += 1
                    case "]": brackets -= 1
                    default: break
                    }
                }
                return parentheses >= 0 && angles >= 0 && brackets >= 0
            }
        }
    }

    struct Conformer: Hashable, Sendable {
        var spelling: String
        var dynamicType: Bytecode.DynamicType
    }

    struct DispatchCandidate: Hashable, Sendable {
        var conformer: Conformer
        var symbol: String
        var function: CanonicalSIL.Function
    }

    struct ResolutionError: Error, Equatable, Sendable,
        CustomStringConvertible {
        var description: String

        init(_ description: String) {
            self.description = description
        }
    }

    struct Resolver: Sendable {
        private let file: CanonicalSIL.File
        private let moduleName: String
        private let typeEnvironment: CanonicalSIL.TypeEnvironment
        private let recordsByConformingType: [
            String: [CanonicalSIL.ProtocolConformance.Record]
        ]
        private let functionsBySymbol: [String: [CanonicalSIL.Function]]

        init(
            file: CanonicalSIL.File,
            function: CanonicalSIL.Function,
            typeEnvironment: CanonicalSIL.TypeEnvironment? = nil
        ) throws {
            guard let moduleName = file.owningModule(of: function) else {
                throw ResolutionError(
                    "protocol existential caller has no current-module identity"
                )
            }
            self.file = file
            self.moduleName = moduleName
            self.typeEnvironment = typeEnvironment ?? file.typeEnvironment
            recordsByConformingType = Dictionary(
                grouping: file.protocolConformances.unambiguousRecords.filter {
                    $0.moduleName == moduleName
                        && $0.genericClause == nil
                        && $0.isComplete
                },
                by: \.conformingType
            )
            functionsBySymbol = Dictionary(
                grouping: file.functions,
                by: \.mangledName
            )
        }

        func conformers(
            to identity: Identity,
            alsoConformingTo source: Identity? = nil
        ) throws -> [Conformer] {
            let required = source.map {
                IdentityRequirement(primary: identity, secondary: $0)
            } ?? IdentityRequirement(primary: identity, secondary: nil)
            var result: [Conformer] = []
            for spelling in recordsByConformingType.keys.sorted() {
                guard let records = recordsByConformingType[spelling],
                      required.matches(records, moduleName: moduleName)
                else { continue }
                let dynamicType: Bytecode.DynamicType
                do {
                    dynamicType = try CanonicalSIL.DynamicType.parse(
                        spelling,
                        resolveStorage: self.typeEnvironment.resolve
                    )
                } catch {
                    // A conformance whose value cannot be represented cannot
                    // enter a VM-owned existential and is not a dispatch case.
                    continue
                }
                // User-defined existential dispatch is limited to image-local
                // nominal values. Retroactive conformances of standard or
                // imported values are outside the frozen patch contract.
                guard case let .local(key) = dynamicType else { continue }
                if identity.requiresClass || source?.requiresClass == true {
                    guard self.typeEnvironment.isClass(key) else { continue }
                }
                result.append(.init(spelling: spelling, dynamicType: dynamicType))
            }
            guard result.count
                    <= Bytecode.ExistentialTypeSet.maximumTypeCountV1,
                  Set(result.map(\.dynamicType)).count == result.count
            else {
                throw ResolutionError(
                    "protocol existential conformers exceed the bounded set or collide in represented identity"
                )
            }
            return result
        }

        func accepts(
            _ dynamicType: Bytecode.DynamicType,
            as identity: Identity
        ) throws -> Bool {
            try conformers(to: identity).contains {
                $0.dynamicType == dynamicType
            }
        }

        func acceptedTypeSet(
            for identity: Identity,
            source: Identity? = nil
        ) throws -> Bytecode.ExistentialTypeSet {
            .init(types: try conformers(
                to: identity,
                alsoConformingTo: source
            ).map(\.dynamicType))
        }

        func dispatchCandidates(
            for reference: WitnessReference
        ) throws -> [DispatchCandidate] {
            let conformers = try conformers(to: reference.openedArchetype.identity)
            guard !conformers.isEmpty else {
                throw ResolutionError(
                    "opened \(reference.openedArchetype.identity) has no represented complete conformer"
                )
            }
            var result: [DispatchCandidate] = []
            for conformer in conformers {
                let records = recordsByConformingType[
                    conformer.spelling,
                    default: []
                ]
                let witnesses = records.flatMap { record in
                    record.witnesses.filter {
                        $0.requirement == reference.requirement
                            && Self.equivalentType(
                                $0.loweredType,
                                reference.requirementType
                            )
                    }
                }
                guard witnesses.count == 1,
                      let symbol = witnesses[0].symbol
                else {
                    throw ResolutionError(
                        "\(conformer.spelling) has no unique complete witness for #\(reference.requirement)"
                    )
                }
                let functions = functionsBySymbol[symbol, default: []]
                guard functions.count == 1,
                      let function = functions.first,
                      file.isCurrentModuleDefinition(
                        mangledName: symbol,
                        moduleName: moduleName
                      ),
                      CanonicalSIL.ProtocolConformance.StaticDispatch
                        .isWitnessThunk(function),
                      !CanonicalSIL.GenericFunction.isGeneric(
                        loweredType: function.loweredType
                      )
                else {
                    throw ResolutionError(
                        "#\(reference.requirement) for \(conformer.spelling) has no unique concrete local witness thunk"
                    )
                }
                result.append(.init(
                    conformer: conformer,
                    symbol: symbol,
                    function: function
                ))
            }
            guard result.count
                    <= Bytecode.ExistentialDispatchTable.maximumTargetCountV1
            else {
                throw ResolutionError(
                    "opened protocol witness dispatch exceeds the bounded target count"
                )
            }
            return result
        }

        private struct IdentityRequirement {
            var primary: Identity
            var secondary: Identity?

            func matches(
                _ records: [CanonicalSIL.ProtocolConformance.Record],
                moduleName: String
            ) -> Bool {
                guard matches(
                    primary,
                    records: records,
                    moduleName: moduleName
                ) else { return false }
                guard let secondary else { return true }
                return matches(
                    secondary,
                    records: records,
                    moduleName: moduleName
                )
            }

            private func matches(
                _ identity: Identity,
                records: [CanonicalSIL.ProtocolConformance.Record],
                moduleName: String
            ) -> Bool {
                identity.protocols.allSatisfy { protocolName in
                    records.contains {
                        Identity.namesEquivalent(
                            protocolName,
                            $0.protocolName,
                            moduleName: moduleName
                        )
                    }
                }
            }
        }

        private static func equivalentType(
            _ lhs: String,
            _ rhs: String
        ) -> Bool {
            lhs.trimmingCharacters(in: .whitespacesAndNewlines)
                == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
