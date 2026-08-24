import Foundation
import HelixCompiler
import HelixCore

extension FrontendReceipt.Adapter {
    func propertyDeclarationSite(
        _ item: FrontendReceipt.TypedAST.Object,
        name: String,
        source: SourceState
    ) throws -> SourceAccessorDeclarationSite {
        guard let range = sourceRange(in: item), range.start >= 0,
            range.end >= range.start, range.end < source.contents.count
        else {
            throw FrontendReceipt.Error.malformedAST(
                "\(source.logicalPath): property has no typed source range"
            )
        }
        let plainName = Data(name.utf8)
        let escapedName = Data("`\(name)`".utf8)
        let sourceNameData: Data
        if range.start + plainName.count <= source.contents.count,
            source.contents[range.start..<(range.start + plainName.count)] == plainName
        {
            sourceNameData = plainName
        } else if range.start + escapedName.count <= source.contents.count,
            source.contents[range.start..<(range.start + escapedName.count)]
                == escapedName
        {
            sourceNameData = escapedName
        } else {
            throw FrontendReceipt.Error.malformedAST(
                "\(source.logicalPath): property identity does not match its typed source range"
            )
        }
        guard let sourceName = String(data: sourceNameData, encoding: .utf8)
        else {
            throw FrontendReceipt.Error.malformedAST(
                "\(source.logicalPath): property name is not UTF-8"
            )
        }
        let lowerBound = max(0, range.start - 4_096)
        let keyword = Data("var".utf8)
        var selected: Int?
        if range.start >= keyword.count {
            for offset in lowerBound...(range.start - keyword.count)
            where source.contents[offset..<(offset + keyword.count)] == keyword {
                let precedingIsIdentifier =
                    offset > 0
                    && (Self.isASCIIIdentifierByte(source.contents[offset - 1])
                        || source.contents[offset - 1] >= 0x80)
                let following = offset + keyword.count
                let followingIsIdentifier =
                    following < source.contents.count
                    && (Self.isASCIIIdentifierByte(source.contents[following])
                        || source.contents[following] >= 0x80)
                guard !precedingIsIdentifier, !followingIsIdentifier,
                    sourceTriviaOnly(
                        in: following..<range.start,
                        contents: source.contents
                    ),
                    !isLineCommentedToken(
                        "var",
                        at: offset,
                        contents: source.contents
                    )
                else { continue }
                selected = offset
            }
        }
        guard let offset = selected,
            let prefix = String(
                data: source.contents.subdata(
                    in: offset..<(range.start + sourceNameData.count)
                ),
                encoding: .utf8
            )
        else {
            throw FrontendReceipt.Error.unsupportedDeclaration(
                "\(source.logicalPath): computed property \(name) has no exact var token"
            )
        }
        return .init(
            declarationUTF8Offset: offset,
            expectedDeclarationPrefix: prefix,
            sourceName: sourceName
        )
    }

    func subscriptDeclarationSite(
        _ item: FrontendReceipt.TypedAST.Object,
        source: SourceState
    ) throws -> SourceAccessorDeclarationSite {
        guard let range = sourceRange(in: item), range.start >= 0,
            range.end >= range.start, range.end < source.contents.count
        else {
            throw FrontendReceipt.Error.malformedAST(
                "\(source.logicalPath): subscript has no typed source range"
            )
        }
        let upperBound = range.end + 1
        let scanUpperBound = min(range.end + 1, range.start + 64 * 1_024)
        let selected = accessorSourceWords(
            matching: ["subscript"],
            in: range.start..<scanUpperBound,
            contents: source.contents,
            stopAfterFirstMatch: true
        )?.first { word in
            guard word.value == "subscript",
                let following = sourceTriviaEnd(
                    from: word.offset + word.value.utf8.count,
                    through: scanUpperBound,
                    contents: source.contents
                )
            else { return false }
            return following < scanUpperBound
                && source.contents[following] == UInt8(ascii: "(")
        }?.offset
        guard let selected, selected < upperBound else {
            throw FrontendReceipt.Error.malformedAST(
                "\(source.logicalPath): subscript range has no exact declaration token"
            )
        }
        return .init(
            declarationUTF8Offset: selected,
            expectedDeclarationPrefix: "subscript",
            sourceName: nil
        )
    }

    static func isASCIIIdentifierByte(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "_")
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    static func isSwiftWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    func sourceArgumentLabels(_ labels: [String]) -> [String]? {
        labels.allSatisfy {
            $0.isEmpty || $0 == "_" || Core.SwiftName.isIdentifier($0)
        } ? labels : nil
    }

    func sourceIdentifier(_ value: String) -> String {
        // Callers have already validated compiler-normalized identifier data.
        Core.SwiftName.escapedIdentifier(value) ?? value
    }

    func sourceTypeReference(_ canonicalName: String) -> String? {
        let components = canonicalName.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty else { return nil }
        var rendered: [String] = []
        for component in components {
            guard let value = Core.SwiftName.escapedIdentifier(String(component)) else {
                return nil
            }
            rendered.append(value)
        }
        return rendered.joined(separator: ".")
    }

    func typeMemberModifier(
        isStatic: Bool,
        declarationOffset: Int,
        source: SourceState
    ) throws -> String {
        guard isStatic else { return "" }
        let lowerBound = max(0, declarationOffset - 64 * 1_024)
        guard
            let modifier = exactTypeMemberModifier(
                before: declarationOffset,
                lowerBound: lowerBound,
                contents: source.contents
            )
        else {
            throw FrontendReceipt.Error.unsupportedDeclaration(
                "\(source.logicalPath): static accessor has no exact source modifier"
            )
        }
        return modifier + " "
    }

    /// The modifier must be the last declaration token before `var` or
    /// `subscript`; comments and whitespace are the only legal intervening
    /// bytes. Searching raw candidates backwards avoids lexing unrelated prior
    /// bodies while the suffix proof excludes strings, comments, and names.
    func exactTypeMemberModifier(
        before declarationOffset: Int,
        lowerBound: Int,
        contents: Data
    ) -> String? {
        guard lowerBound >= 0, lowerBound < declarationOffset,
            declarationOffset <= contents.count
        else { return nil }
        let candidates = [
            (value: "static", token: Data("static".utf8)),
            (value: "class", token: Data("class".utf8)),
        ]
        for offset in stride(
            from: declarationOffset - 1,
            through: lowerBound,
            by: -1
        ) {
            for candidate in candidates {
                let end = offset + candidate.token.count
                guard end <= declarationOffset,
                    contents[offset..<end] == candidate.token
                else { continue }
                let precedingIsIdentifier =
                    offset > 0
                    && (Self.isASCIIIdentifierByte(contents[offset - 1])
                        || contents[offset - 1] >= 0x80)
                let followingIsIdentifier =
                    end < contents.count
                    && (Self.isASCIIIdentifierByte(contents[end])
                        || contents[end] >= 0x80)
                guard !precedingIsIdentifier, !followingIsIdentifier,
                    !isLineCommentedToken(
                        candidate.value,
                        at: offset,
                        contents: contents
                    ),
                    sourceTriviaOnly(
                        in: end..<declarationOffset,
                        contents: contents
                    )
                else { continue }
                return candidate.value
            }
        }
        return nil
    }

    /// Returns declaration-level identifier words outside comments, strings,
    /// interpolations, and backticked identifiers. The scan is deliberately
    /// bounded by compiler-provided declaration ranges.
    func accessorSourceWords(
        matching expected: Set<String>,
        in range: Range<Int>,
        contents: Data,
        stopAfterFirstMatch: Bool = false
    ) -> [(value: String, offset: Int)]? {
        guard !expected.isEmpty, range.lowerBound >= 0,
            range.upperBound <= contents.count
        else {
            return nil
        }
        var words: [(value: String, offset: Int)] = []
        var cursor = range.lowerBound
        var lineComment = false
        var blockCommentDepth = 0
        var stringState: (pounds: Int, quotes: Int)?
        var backtickedIdentifier = false

        while cursor < range.upperBound {
            let byte = contents[cursor]
            let next =
                cursor + 1 < range.upperBound
                ? contents[cursor + 1] : nil

            if lineComment {
                if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                    lineComment = false
                }
                cursor += 1
                continue
            }
            if blockCommentDepth > 0 {
                if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                    blockCommentDepth += 1
                    cursor += 2
                } else if byte == UInt8(ascii: "*"), next == UInt8(ascii: "/") {
                    blockCommentDepth -= 1
                    cursor += 2
                } else {
                    cursor += 1
                }
                continue
            }
            if let activeString = stringState {
                if accessorInterpolationStarts(
                    at: cursor,
                    pounds: activeString.pounds,
                    upperBound: range.upperBound,
                    contents: contents
                ) {
                    guard
                        let end = accessorInterpolationEnd(
                            at: cursor,
                            pounds: activeString.pounds,
                            upperBound: range.upperBound,
                            contents: contents
                        )
                    else { return nil }
                    cursor = end
                    continue
                }
                if accessorStringTerminator(
                    at: cursor,
                    state: activeString,
                    upperBound: range.upperBound,
                    contents: contents
                ) {
                    cursor += activeString.quotes + activeString.pounds
                    stringState = nil
                } else if activeString.pounds == 0,
                    byte == UInt8(ascii: "\\")
                {
                    cursor += min(2, range.upperBound - cursor)
                } else {
                    cursor += 1
                }
                continue
            }
            if backtickedIdentifier {
                if byte == UInt8(ascii: "`") { backtickedIdentifier = false }
                cursor += 1
                continue
            }

            if byte == UInt8(ascii: "/"), next == UInt8(ascii: "/") {
                lineComment = true
                cursor += 2
                continue
            }
            if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                blockCommentDepth = 1
                cursor += 2
                continue
            }
            if byte == UInt8(ascii: "`") {
                backtickedIdentifier = true
                cursor += 1
                continue
            }
            if let opening = accessorStringOpening(
                at: cursor,
                upperBound: range.upperBound,
                contents: contents
            ) {
                // Swift permits arbitrarily long raw-string delimiters. A
                // small build-time ceiling keeps repeated terminator checks
                // linear for ordinary source and fails closed for adversarial
                // declaration trivia.
                guard opening.pounds <= 64 else { return nil }
                stringState = opening
                cursor += opening.pounds + opening.quotes
                continue
            }
            if Self.isASCIIIdentifierByte(byte) || byte >= 0x80 {
                let start = cursor
                repeat {
                    cursor += 1
                } while cursor < range.upperBound
                    && (Self.isASCIIIdentifierByte(contents[cursor])
                        || contents[cursor] >= 0x80)
                guard
                    let value = String(
                        data: contents.subdata(in: start..<cursor),
                        encoding: .utf8
                    )
                else { return nil }
                if expected.contains(value) {
                    words.append((value, start))
                    if stopAfterFirstMatch { return words }
                }
                continue
            }
            cursor += 1
        }
        guard blockCommentDepth == 0, stringState == nil,
            !backtickedIdentifier
        else { return nil }
        return words
    }

    /// Skips one interpolation while preserving the surrounding string state.
    /// A small recursion limit makes nested interpolated strings deterministic;
    /// regex/division syntax inside an interpolation remains fail-closed because
    /// distinguishing those tokens requires the full Swift lexer.
    func accessorInterpolationEnd(
        at offset: Int,
        pounds: Int,
        upperBound: Int,
        contents: Data,
        nestingDepth: Int = 0
    ) -> Int? {
        guard nestingDepth < 64,
            accessorInterpolationStarts(
                at: offset,
                pounds: pounds,
                upperBound: upperBound,
                contents: contents
            )
        else { return nil }
        var cursor = offset + pounds + 2
        var parenthesisDepth = 1
        var lineComment = false
        var blockCommentDepth = 0
        var stringState: (pounds: Int, quotes: Int)?
        var backtickedIdentifier = false

        while cursor < upperBound {
            let byte = contents[cursor]
            let next = cursor + 1 < upperBound ? contents[cursor + 1] : nil
            if lineComment {
                if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                    lineComment = false
                }
                cursor += 1
                continue
            }
            if blockCommentDepth > 0 {
                if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                    blockCommentDepth += 1
                    cursor += 2
                } else if byte == UInt8(ascii: "*"), next == UInt8(ascii: "/") {
                    blockCommentDepth -= 1
                    cursor += 2
                } else {
                    cursor += 1
                }
                continue
            }
            if let activeString = stringState {
                if accessorInterpolationStarts(
                    at: cursor,
                    pounds: activeString.pounds,
                    upperBound: upperBound,
                    contents: contents
                ) {
                    guard
                        let end = accessorInterpolationEnd(
                            at: cursor,
                            pounds: activeString.pounds,
                            upperBound: upperBound,
                            contents: contents,
                            nestingDepth: nestingDepth + 1
                        )
                    else { return nil }
                    cursor = end
                } else if accessorStringTerminator(
                    at: cursor,
                    state: activeString,
                    upperBound: upperBound,
                    contents: contents
                ) {
                    cursor += activeString.quotes + activeString.pounds
                    stringState = nil
                } else if activeString.pounds == 0,
                    byte == UInt8(ascii: "\\")
                {
                    cursor += min(2, upperBound - cursor)
                } else {
                    cursor += 1
                }
                continue
            }
            if backtickedIdentifier {
                if byte == UInt8(ascii: "`") { backtickedIdentifier = false }
                cursor += 1
                continue
            }
            if byte == UInt8(ascii: "/"), next == UInt8(ascii: "/") {
                lineComment = true
                cursor += 2
            } else if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                blockCommentDepth = 1
                cursor += 2
            } else if byte == UInt8(ascii: "/") {
                return nil
            } else if byte == UInt8(ascii: "`") {
                backtickedIdentifier = true
                cursor += 1
            } else if let opening = accessorStringOpening(
                at: cursor,
                upperBound: upperBound,
                contents: contents
            ) {
                guard opening.pounds <= 64 else { return nil }
                stringState = opening
                cursor += opening.pounds + opening.quotes
            } else if byte == UInt8(ascii: "(") {
                parenthesisDepth += 1
                cursor += 1
            } else if byte == UInt8(ascii: ")") {
                parenthesisDepth -= 1
                cursor += 1
                if parenthesisDepth == 0 { return cursor }
            } else {
                cursor += 1
            }
        }
        return nil
    }

    func accessorStringOpening(
        at offset: Int,
        upperBound: Int,
        contents: Data
    ) -> (pounds: Int, quotes: Int)? {
        var cursor = offset
        while cursor < upperBound, contents[cursor] == UInt8(ascii: "#") {
            cursor += 1
        }
        guard cursor < upperBound, contents[cursor] == UInt8(ascii: "\"") else {
            return nil
        }
        let quotes =
            cursor + 2 < upperBound
                && contents[cursor + 1] == UInt8(ascii: "\"")
                && contents[cursor + 2] == UInt8(ascii: "\"")
            ? 3 : 1
        return (cursor - offset, quotes)
    }

    func accessorStringTerminator(
        at offset: Int,
        state: (pounds: Int, quotes: Int),
        upperBound: Int,
        contents: Data
    ) -> Bool {
        guard offset + state.quotes + state.pounds <= upperBound else {
            return false
        }
        for index in 0..<state.quotes
        where contents[offset + index] != UInt8(ascii: "\"") {
            return false
        }
        for index in 0..<state.pounds
        where contents[offset + state.quotes + index] != UInt8(ascii: "#") {
            return false
        }
        return true
    }

    func accessorInterpolationStarts(
        at offset: Int,
        pounds: Int,
        upperBound: Int,
        contents: Data
    ) -> Bool {
        guard offset + pounds + 1 < upperBound,
            contents[offset] == UInt8(ascii: "\\")
        else { return false }
        for index in 0..<pounds
        where contents[offset + 1 + index] != UInt8(ascii: "#") {
            return false
        }
        return contents[offset + 1 + pounds] == UInt8(ascii: "(")
    }

    func sourceTriviaEnd(
        from start: Int,
        through upperBound: Int,
        contents: Data
    ) -> Int? {
        guard start >= 0, start <= upperBound, upperBound <= contents.count else {
            return nil
        }
        var cursor = start
        var blockDepth = 0
        while cursor < upperBound {
            let byte = contents[cursor]
            if blockDepth > 0 {
                if byte == UInt8(ascii: "/"), cursor + 1 < upperBound,
                    contents[cursor + 1] == UInt8(ascii: "*")
                {
                    blockDepth += 1
                    cursor += 2
                } else if byte == UInt8(ascii: "*"), cursor + 1 < upperBound,
                    contents[cursor + 1] == UInt8(ascii: "/")
                {
                    blockDepth -= 1
                    cursor += 2
                } else {
                    cursor += 1
                }
            } else if Self.isSwiftWhitespace(byte) {
                cursor += 1
            } else if byte == UInt8(ascii: "/"), cursor + 1 < upperBound,
                contents[cursor + 1] == UInt8(ascii: "/")
            {
                cursor += 2
                while cursor < upperBound,
                    ![UInt8(ascii: "\n"), UInt8(ascii: "\r")]
                        .contains(contents[cursor])
                {
                    cursor += 1
                }
            } else if byte == UInt8(ascii: "/"), cursor + 1 < upperBound,
                contents[cursor + 1] == UInt8(ascii: "*")
            {
                blockDepth = 1
                cursor += 2
            } else {
                return cursor
            }
        }
        return blockDepth == 0 ? cursor : nil
    }

    func sourceTriviaOnly(in range: Range<Int>, contents: Data) -> Bool {
        sourceTriviaEnd(
            from: range.lowerBound,
            through: range.upperBound,
            contents: contents
        ) == range.upperBound
    }

    func isLineCommentedToken(
        _ token: String,
        at offset: Int,
        contents: Data
    ) -> Bool {
        var lineStart = offset
        while lineStart > 0,
            ![UInt8(ascii: "\n"), UInt8(ascii: "\r")]
                .contains(contents[lineStart - 1])
        {
            lineStart -= 1
        }
        guard offset + token.utf8.count <= contents.count,
            let words = accessorSourceWords(
                matching: [token],
                in: lineStart..<(offset + token.utf8.count),
                contents: contents
            )
        else { return true }
        return !words.contains { $0.offset == offset }
    }

    func sourceAccessorParameters(
        _ accessor: FrontendReceipt.TypedAST.Object,
        demangled: [String: String],
        importedSwiftTypeAliases: [String: String]
    ) throws -> [SourceAccessorParameter]? {
        let parameters =
            (accessor["params"] as? FrontendReceipt.TypedAST.Object)?["params"]
            as? [FrontendReceipt.TypedAST.Object] ?? []
        guard
            parameters.allSatisfy({
                $0["inout"] as? Bool != true
                    && $0["variadic"] as? Bool != true
                    && ($0["attrs"] as? [FrontendReceipt.TypedAST.Object] ?? []).isEmpty
                    && $0["isolated"] as? Bool != true
                    && $0["sending"] as? Bool != true
            })
        else { return nil }
        let names = parameters.map { baseName(in: $0) ?? "_" }
        guard names.allSatisfy(Self.isSwiftIdentifier) else { return nil }
        var usedNames = Set(names.filter { $0 != "_" })
        return try zip(parameters.indices, parameters).map { index, parameter in
            var name = names[index]
            if name == "_" {
                name = "__helixAccessorArgument\(index)"
                while usedNames.contains(name) { name += "_" }
                usedNames.insert(name)
            }
            let type = try demangledType(parameter["interface_type"], using: demangled)
            return .init(
                name: name,
                swiftType: type,
                generatedSwiftType: FrontendReceipt.SwiftTypeSpelling
                    .replacingNominalAliases(
                        in: type,
                        aliases: importedSwiftTypeAliases
                    )
            )
        }
    }

    func sourceAccessorSyntax(
        _ accessor: FrontendReceipt.TypedAST.Object,
        role: Core.DynamicReplacement.MemberRole,
        sil: CanonicalSIL.Function,
        source: SourceState,
        context: NominalContext?,
        isStatic: Bool
    ) throws -> SourceAccessorSyntax {
        guard let body = accessor["body"] as? FrontendReceipt.TypedAST.Object,
            let bodyRange = sourceRange(in: body),
            let accessorRange = sourceRange(in: accessor),
            bodyRange.start >= 0, bodyRange.start < source.contents.count,
            accessorRange.start >= 0, accessorRange.start <= bodyRange.start,
            source.contents[bodyRange.start] == UInt8(ascii: "{")
        else {
            throw FrontendReceipt.Error.malformedAST(
                "\(sil.mangledName) has no exact accessor syntax"
            )
        }
        let keyword: String
        switch role {
        case .getter: keyword = "get"
        case .setter: keyword = "set"
        case .willSet: keyword = "willSet"
        case .didSet: keyword = "didSet"
        case .functionBody:
            throw FrontendReceipt.Error.malformedAST(
                "\(sil.mangledName) has a non-accessor member role"
            )
        }
        let rawHeader: String
        if accessorRange.start == bodyRange.start {
            rawHeader = keyword
        } else {
            guard
                let value = String(
                    data: source.contents.subdata(
                        in: accessorRange.start..<bodyRange.start
                    ),
                    encoding: .utf8
                )
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "\(sil.mangledName) accessor header is not UTF-8"
                )
            }
            rawHeader = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let keywordSuffix = rawHeader.dropFirst(keyword.count)
        guard rawHeader.hasPrefix(keyword),
            keywordSuffix.isEmpty
                || keywordSuffix.first == "("
                || keywordSuffix.first?.isWhitespace == true,
            rawHeader.utf8.count <= 64 * 1_024,
            !rawHeader.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw FrontendReceipt.Error.unsupportedDeclaration(
                "\(sil.mangledName) has an unsupported accessor header"
            )
        }
        let attributeKinds = Set(
            (accessor["attrs"] as? [FrontendReceipt.TypedAST.Object] ?? [])
                .compactMap { $0["_kind"] as? String }
        )
        let implicitSelf =
            accessor["implicit_self_decl"]
            as? FrontendReceipt.TypedAST.Object
        let selfIsInOut = implicitSelf?["inout"] as? Bool == true
        let ownership: String
        if attributeKinds.contains("mutating_attr") {
            ownership = "mutating "
        } else if attributeKinds.contains("nonmutating_attr") {
            ownership = "nonmutating "
        } else if !isStatic, context?.kind?.isValue == true, implicitSelf != nil,
            role == .getter, selfIsInOut
        {
            ownership = "mutating "
        } else if !isStatic, context?.kind?.isValue == true, implicitSelf != nil,
            role == .setter, !selfIsInOut
        {
            ownership = "nonmutating "
        } else {
            ownership = ""
        }
        return .init(
            header: ownership + rawHeader,
            mayThrow: sil.loweredType.contains("@error"),
            hasTypedThrows: (accessor["thrown_type"] as? String)?.isEmpty == false,
            valueParameterName: [.setter, .willSet, .didSet].contains(role)
                ? ((accessor["params"] as? FrontendReceipt.TypedAST.Object)?["params"]
                    as? [FrontendReceipt.TypedAST.Object])?.first.flatMap {
                        baseName(in: $0)
                    }
                : nil
        )
    }

    func accessorMembers(
        getter: SourceAccessorSyntax,
        setter: SourceAccessorSyntax?,
        originalReference: String,
        originalLabels: [String],
        getterIndexParameters: [SourceAccessorParameter],
        isStatic: Bool
    ) throws -> [Core.DynamicReplacement.Member] {
        let subscriptReference =
            originalLabels.isEmpty
            ? nil
            : "\(isStatic ? "Self" : "self")["
                + Self.arguments(
                    labels: originalLabels,
                    values: getterIndexParameters.map { sourceIdentifier($0.name) }
                ) + "]"
        var members = [
            Core.DynamicReplacement.Member(
                role: .getter,
                header: getter.header,
                fallbackBody: originalLabels.isEmpty
                    ? "return \(getter.mayThrow ? "try " : "")\(originalReference)"
                    : "return \(getter.mayThrow ? "try " : "")\(subscriptReference!)"
            )
        ]
        if let setter {
            guard let rawValue = setter.valueParameterName, rawValue != "_",
                Core.SwiftName.isIdentifier(rawValue)
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "computed setter has no replacement value parameter"
                )
            }
            let value = sourceIdentifier(rawValue)
            let fallback: String
            if originalLabels.isEmpty {
                fallback = "\(originalReference) = \(value)"
            } else {
                fallback = "\(subscriptReference!) = \(value)"
            }
            members.append(
                .init(
                    role: .setter,
                    header: setter.header,
                    fallbackBody: fallback
                ))
        }
        return members
    }

    func renderSubscriptParameters(
        _ parameters: [SourceAccessorParameter],
        labels: [String],
        replacementFirstLabel: String
    ) -> String {
        zip(parameters.indices, parameters).map { index, parameter in
            let label = index == 0 ? replacementFirstLabel : labels[index]
            let external = label.isEmpty || label == "_" ? "_" : label
            return "\(external) \(sourceIdentifier(parameter.name)): "
                + parameter.generatedSwiftType
        }.joined(separator: ", ")
    }

    func hasOnlySupportedAccessorAttributes(
        _ item: FrontendReceipt.TypedAST.Object,
        accessors: [FrontendReceipt.TypedAST.Object],
        demangled: [String: String],
        forbiddenAttributes: Set<String>
    ) -> Bool {
        let attributes =
            (item["attrs"] as? [FrontendReceipt.TypedAST.Object] ?? [])
            + accessors.flatMap {
                $0["attrs"] as? [FrontendReceipt.TypedAST.Object] ?? []
            }
        guard
            Set(attributes.compactMap { $0["_kind"] as? String })
                .isDisjoint(with: forbiddenAttributes)
        else { return false }
        let custom = attributes.filter { $0["_kind"] as? String == "custom_attr" }
        return custom.allSatisfy { attribute in
            guard let mangled = attribute["type"] as? String,
                let type = demangled[mangled],
                let name = Self.customAttributeName(type)
            else { return false }
            return Self.isMainActor(name)
        }
    }

    func supportedIsolation(_ isolation: CanonicalSIL.FunctionIsolation) -> Bool {
        switch isolation {
        case .unspecified, .nonisolated:
            true
        case .globalActor(let name):
            Self.isMainActor(name)
        case .actorInstance, .unknown:
            false
        }
    }

    func accessorRequiresMainActor(
        _ item: FrontendReceipt.TypedAST.Object,
        accessor: FrontendReceipt.TypedAST.Object,
        sil: CanonicalSIL.Function,
        demangled: [String: String]
    ) -> Bool {
        if case .globalActor(let name) = sil.isolation, Self.isMainActor(name) {
            return true
        }
        return propertyRequiresMainActor(item, demangled: demangled)
            || propertyRequiresMainActor(accessor, demangled: demangled)
    }

    func resolvedAccessorFunction(
        _ accessor: FrontendReceipt.TypedAST.Object,
        source: SourceState,
        silFile: CanonicalSIL.File,
        declarationUSR: String
    ) throws -> CanonicalSIL.Function {
        guard let accessorUSR = accessor["usr"] as? String,
            accessorUSR.hasPrefix("s:")
        else {
            throw FrontendReceipt.Error.malformedAST(
                "computed declaration \(declarationUSR) has no accessor identity"
            )
        }
        guard
            let sil = try FrontendReceipt.SILFunctionResolver(file: silFile)
                .function(for: accessor, source: source)
        else {
            throw FrontendReceipt.Error.missingSILFunction("$s" + accessorUSR.dropFirst(2))
        }
        return sil
    }
}
