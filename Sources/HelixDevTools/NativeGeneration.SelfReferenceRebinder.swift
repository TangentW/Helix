import Foundation
import HelixCompiler
import HelixCore

extension NativeGeneration {
public struct SelfReferenceTarget: Hashable, Sendable {
    public var mangledName: String
    public var sourceFilePath: String
    public var sourceDeclaration: Core.DynamicReplacement.Declaration
    public var memberRole: Core.DynamicReplacement.MemberRole

    public init(
        mangledName: String,
        sourceFilePath: String,
        sourceDeclaration: Core.DynamicReplacement.Declaration,
        memberRole: Core.DynamicReplacement.MemberRole
    ) {
        self.mangledName = mangledName
        self.sourceFilePath = sourceFilePath
        self.sourceDeclaration = sourceDeclaration
        self.memberRole = memberRole
    }
}

public struct SelfReferenceEdit: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case currentReplacement
        case explicitPrevious
    }

    public var sourceRange: Range<Int>
    public var replacement: Data
    public var kind: Kind

    public init(sourceRange: Range<Int>, replacement: Data, kind: Kind) {
        self.sourceRange = sourceRange
        self.replacement = replacement
        self.kind = kind
    }
}

public struct SelfReferencePlan: Hashable, Sendable {
    public var mangledName: String
    public var replacementBaseName: String
    public var edits: [NativeGeneration.SelfReferenceEdit]

    public init(
        mangledName: String,
        replacementBaseName: String,
        edits: [NativeGeneration.SelfReferenceEdit]
    ) {
        self.mangledName = mangledName
        self.replacementBaseName = replacementBaseName
        self.edits = edits.sorted { $0.sourceRange.lowerBound < $1.sourceRange.lowerBound }
    }

    public var currentReferenceCount: Int {
        edits.count { $0.kind == .currentReplacement }
    }

    public var explicitPreviousCount: Int {
        edits.count { $0.kind == .explicitPrevious }
    }
}

public enum SelfReferenceError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case malformedTypedAST(String)
    case missingSource(String)
    case missingDeclaration(String)
    case invalidSourceRange(String)
    case unsupportedReference(String)
    case invalidPreviousMarker(String)
    case overlappingEdits(String)

    public var description: String {
        switch self {
        case let .malformedTypedAST(reason): reason
        case let .missingSource(path): "typed AST has no source document for \(path)"
        case let .missingDeclaration(symbol): "typed AST has no declaration for \(symbol)"
        case let .invalidSourceRange(reason): "invalid typed-AST source range: \(reason)"
        case let .unsupportedReference(kind):
            "self reference uses unsupported typed-AST expression \(kind)"
        case let .invalidPreviousMarker(reason):
            "invalid LiveReload.previous marker: \(reason)"
        case let .overlappingEdits(symbol):
            "typed-AST self-reference edits overlap for \(symbol)"
        }
    }
}

/// Rebinds only references whose typed-AST USR is identical to the declaration
/// being replaced. Text is used solely to apply compiler-provided byte ranges;
/// it never decides which call is recursive.
public struct SelfReferenceRebinder: Sendable {
    public init() {}

    public func analyze(
        astOutput: String,
        sources: [String: Data],
        targets: [NativeGeneration.SelfReferenceTarget]
    ) throws -> [String: NativeGeneration.SelfReferencePlan] {
        let documents: [SwiftFrontend.TypedAST.Object]
        do {
            documents = try SwiftFrontend.TypedAST.parseDocuments(astOutput)
        } catch {
            throw NativeGeneration.SelfReferenceError.malformedTypedAST(
                String(describing: error)
            )
        }
        var normalizedSources: [String: Data] = [:]
        for (path, contents) in sources {
            let normalized = Self.normalizedPath(path)
            guard normalizedSources.updateValue(contents, forKey: normalized) == nil else {
                throw NativeGeneration.SelfReferenceError.malformedTypedAST(
                    "duplicate normalized source path \(normalized)"
                )
            }
        }
        var documentsByPath: [String: SwiftFrontend.TypedAST.Object] = [:]
        for document in documents {
            guard let filename = document["filename"] as? String else {
                throw NativeGeneration.SelfReferenceError.malformedTypedAST(
                    "source document has no filename"
                )
            }
            let normalized = Self.normalizedPath(filename)
            guard documentsByPath.updateValue(document, forKey: normalized) == nil else {
                throw NativeGeneration.SelfReferenceError.malformedTypedAST(
                    "duplicate typed-AST source document \(normalized)"
                )
            }
        }
        guard Set(targets.map(\.mangledName)).count == targets.count else {
            throw NativeGeneration.SelfReferenceError.malformedTypedAST(
                "duplicate self-reference target"
            )
        }

        var plans: [String: NativeGeneration.SelfReferencePlan] = [:]
        for target in targets {
            let path = Self.normalizedPath(target.sourceFilePath)
            guard let source = normalizedSources[path] else {
                throw NativeGeneration.SelfReferenceError.missingSource(path)
            }
            guard let document = documentsByPath[path] else {
                throw NativeGeneration.SelfReferenceError.missingSource(path)
            }
            let plan = try analyze(
                target: target,
                document: document,
                source: source
            )
            plans[target.mangledName] = plan
        }
        return plans
    }

    public func rewrite(
        _ body: NativeGeneration.ExtractedBody,
        using plan: NativeGeneration.SelfReferencePlan
    ) throws -> String {
        var bytes = Data(body.contents.utf8)
        let applicable = plan.edits.filter {
            body.sourceRange.contains($0.sourceRange.lowerBound)
                && $0.sourceRange.upperBound <= body.sourceRange.upperBound
        }
        guard applicable.count == plan.edits.count else {
            throw NativeGeneration.SelfReferenceError.invalidSourceRange(
                "an edit for \(plan.mangledName) escaped its function body"
            )
        }
        for edit in applicable.sorted(by: { $0.sourceRange.lowerBound > $1.sourceRange.lowerBound }) {
            let lower = edit.sourceRange.lowerBound - body.sourceRange.lowerBound
            let upper = edit.sourceRange.upperBound - body.sourceRange.lowerBound
            guard lower >= 0, upper >= lower, upper <= bytes.count else {
                throw NativeGeneration.SelfReferenceError.invalidSourceRange(plan.mangledName)
            }
            bytes.replaceSubrange(lower..<upper, with: edit.replacement)
        }
        guard let result = String(data: bytes, encoding: .utf8) else {
            throw NativeGeneration.SelfReferenceError.invalidSourceRange(
                "rewritten body for \(plan.mangledName) is not UTF-8"
            )
        }
        return result
    }
}
}

private extension NativeGeneration.SelfReferenceRebinder {
    typealias Object = SwiftFrontend.TypedAST.Object

    struct Marker: Hashable {
        var callRange: Range<Int>
        var resultRange: Range<Int>
    }

    func analyze(
        target: NativeGeneration.SelfReferenceTarget,
        document: Object,
        source: Data
    ) throws -> NativeGeneration.SelfReferencePlan {
        guard target.sourceDeclaration.isWellFormed,
              target.sourceDeclaration.member(target.memberRole) != nil
        else {
            throw NativeGeneration.SelfReferenceError.malformedTypedAST(
                "Native target has an invalid replacement declaration"
            )
        }
        if target.sourceDeclaration.kind != .function {
            return try analyzeAccessor(
                target: target,
                document: document
            )
        }
        guard let usr = SwiftFrontend.DynamicReplacement.declarationUSR(
            mangledName: target.mangledName
        ), target.memberRole == .functionBody,
            target.sourceDeclaration.identity == usr
        else {
            throw NativeGeneration.SelfReferenceError.malformedTypedAST(
                "Native function target does not match its replacement declaration: "
                    + target.mangledName
            )
        }
        let declarations = objects(in: document).filter {
            $0["_kind"] as? String == "func_decl" && $0["usr"] as? String == usr
        }
        guard declarations.count == 1, let declaration = declarations.first,
              let body = declaration["body"] as? Object,
              let name = declaration["name"] as? Object,
              let base = name["base_name"] as? Object,
              let baseName = base["name"] as? String,
              Self.isSwiftIdentifier(baseName)
        else {
            throw NativeGeneration.SelfReferenceError.missingDeclaration(target.mangledName)
        }
        let replacementName = SwiftFrontend.DynamicReplacement.replacementBaseName(
            usr: usr,
            baseName: baseName
        )
        let markers = Array(Set(try previousMarkers(
            in: body,
            targetUSR: usr,
            source: source
        ))).sorted { $0.callRange.lowerBound < $1.callRange.lowerBound }
        try validateDisjoint(markers.map(\.callRange), symbol: target.mangledName)

        let allObjects = objects(in: body)
        for object in allObjects {
            guard let decl = object["decl"] as? Object,
                  decl["decl_usr"] as? String == usr,
                  let kind = object["_kind"] as? String,
                  kind.hasSuffix("_expr"), kind != "declref_expr"
            else { continue }
            throw NativeGeneration.SelfReferenceError.unsupportedReference(kind)
        }

        var edits = try markers.map { marker -> NativeGeneration.SelfReferenceEdit in
            let result = try slice(marker.resultRange, from: source)
            let call = try slice(marker.callRange, from: source)
            let padding = max(0, call.count(where: { $0 == 0x0a })
                - result.count(where: { $0 == 0x0a }))
            var replacement = Data([UInt8(ascii: "(")])
            replacement.append(result)
            replacement.append(UInt8(ascii: ")"))
            replacement.append(contentsOf: repeatElement(UInt8(ascii: "\n"), count: padding))
            return .init(
                sourceRange: marker.callRange,
                replacement: replacement,
                kind: .explicitPrevious
            )
        }

        for object in allObjects {
            guard object["_kind"] as? String == "declref_expr",
                  let decl = object["decl"] as? Object,
                  decl["decl_usr"] as? String == usr,
                  let referencedName = decl["base_name"] as? String,
                  referencedName == baseName,
                  let location = Self.range(in: object)
            else { continue }
            let referenceRange = location.lowerBound..<(location.lowerBound + baseName.utf8.count)
            guard !markers.contains(where: { $0.callRange.contains(referenceRange.lowerBound) }) else {
                continue
            }
            guard try slice(referenceRange, from: source) == Data(baseName.utf8) else {
                throw NativeGeneration.SelfReferenceError.invalidSourceRange(
                    "self reference for \(target.mangledName) does not select \(baseName)"
                )
            }
            edits.append(
                .init(
                    sourceRange: referenceRange,
                    replacement: Data(replacementName.utf8),
                    kind: .currentReplacement
                )
            )
        }
        edits = Array(Set(edits)).sorted { $0.sourceRange.lowerBound < $1.sourceRange.lowerBound }
        try validateDisjoint(edits.map(\.sourceRange), symbol: target.mangledName)
        return .init(
            mangledName: target.mangledName,
            replacementBaseName: replacementName,
            edits: edits
        )
    }

    func analyzeAccessor(
        target: NativeGeneration.SelfReferenceTarget,
        document: Object
    ) throws -> NativeGeneration.SelfReferencePlan {
        guard let accessorUSR = SwiftFrontend.DynamicReplacement.declarationUSR(
            mangledName: target.mangledName
        ) else {
            throw NativeGeneration.SelfReferenceError.malformedTypedAST(
                "Native accessor target is not a Swift symbol: \(target.mangledName)"
            )
        }
        let parents = objects(in: document).filter {
            guard $0["usr"] as? String == target.sourceDeclaration.identity,
                accessorParentKind($0) == target.sourceDeclaration.kind,
                let accessors = $0["accessors"] as? [Object]
            else { return false }
            return accessors.contains { $0["usr"] as? String == accessorUSR }
        }
        guard parents.count == 1, let parent = parents.first,
              let accessors = parent["accessors"] as? [Object],
              let accessor = accessors.first(where: {
                  $0["usr"] as? String == accessorUSR
              }), accessorMatchesRole(accessor, target.memberRole),
              let body = accessor["body"] as? Object
        else {
            throw NativeGeneration.SelfReferenceError.missingDeclaration(
                target.mangledName
            )
        }
        let targetUSRs = Set([
            target.sourceDeclaration.identity,
            accessorUSR,
        ])
        for object in objects(in: body) {
            if object["_kind"] as? String == "call_expr", isPreviousCall(object) {
                throw NativeGeneration.SelfReferenceError.unsupportedReference(
                    "LiveReload.previous in an accessor"
                )
            }
            guard let declaration = object["decl"] as? Object,
                  let referencedUSR = declaration["decl_usr"] as? String,
                  targetUSRs.contains(referencedUSR)
            else { continue }
            // A property reference would need its replacement name rebound;
            // a subscript reference would additionally require a typed label
            // insertion. Until both are modeled as source edits, reject the
            // uncommon recursive accessor instead of silently calling the
            // previous implementation from generated replacement syntax.
            throw NativeGeneration.SelfReferenceError.unsupportedReference(
                object["_kind"] as? String ?? "accessor reference"
            )
        }
        return .init(
            mangledName: target.mangledName,
            replacementBaseName: "",
            edits: []
        )
    }

    func accessorParentKind(
        _ parent: Object
    ) -> Core.DynamicReplacement.DeclarationKind? {
        switch parent["_kind"] as? String {
        case "var_decl":
            return parent["readImpl"] as? String == "stored"
                ? .propertyObservers : .property
        case "subscript_decl":
            return .subscriptDeclaration
        default:
            return nil
        }
    }

    func accessorMatchesRole(
        _ accessor: Object,
        _ role: Core.DynamicReplacement.MemberRole
    ) -> Bool {
        switch role {
        case .getter: accessor["get"] as? Bool == true
        case .setter: accessor["set"] as? Bool == true
        case .willSet: accessor["willSet"] as? Bool == true
        case .didSet: accessor["didSet"] as? Bool == true
        case .functionBody: false
        }
    }

    func previousMarkers(
        in body: Object,
        targetUSR: String,
        source: Data
    ) throws -> [Marker] {
        var result: [Marker] = []
        try walk(body, closureDepth: 0) { object, closureDepth in
            guard object["_kind"] as? String == "call_expr",
                  isPreviousCall(object)
            else { return }
            guard closureDepth == 0 else {
                throw NativeGeneration.SelfReferenceError.invalidPreviousMarker(
                    "the marker cannot be nested in another closure"
                )
            }
            guard let callRange = Self.range(in: object),
                  let arguments = object["args"] as? Object,
                  let items = arguments["args"] as? [Any], items.count == 1,
                  let argument = items[0] as? Object,
                  let expression = argument["expr"] as? Object,
                  let closure = unwrapClosure(expression),
                  closure["single_expression"] as? Bool == true,
                  let closureBody = closure["body"] as? Object,
                  let elements = closureBody["elements"] as? [Any], elements.count == 1,
                  let returnStatement = elements[0] as? Object,
                  returnStatement["_kind"] as? String == "return_stmt",
                  returnStatement["implicit"] as? Bool == true,
                  let previousExpression = returnStatement["result"] as? Object,
                  let resultRange = Self.range(in: previousExpression)
            else {
                throw NativeGeneration.SelfReferenceError.invalidPreviousMarker(
                    "use exactly one single-expression closure"
                )
            }
            let selfReferences = objects(in: previousExpression).filter {
                ($0["decl"] as? Object)?["decl_usr"] as? String == targetUSR
            }
            guard !selfReferences.isEmpty else {
                throw NativeGeneration.SelfReferenceError.invalidPreviousMarker(
                    "the closure does not reference the function being replaced"
                )
            }
            for nested in objects(in: previousExpression)
            where nested["_kind"] as? String == "closure_expr" {
                let nestedReferences = objects(in: nested).contains {
                    ($0["decl"] as? Object)?["decl_usr"] as? String == targetUSR
                }
                guard !nestedReferences else {
                    throw NativeGeneration.SelfReferenceError.invalidPreviousMarker(
                        "the previous self call cannot be nested in a second closure"
                    )
                }
            }
            guard callRange.lowerBound <= resultRange.lowerBound,
                  resultRange.upperBound <= callRange.upperBound,
                  callRange.upperBound <= source.count
            else {
                throw NativeGeneration.SelfReferenceError.invalidSourceRange(
                    "LiveReload.previous ranges are inconsistent"
                )
            }
            result.append(.init(callRange: callRange, resultRange: resultRange))
        }
        return result
    }

    func isPreviousCall(_ call: Object) -> Bool {
        guard let function = call["fn"] as? Object else { return false }
        return objects(in: function).contains { object in
            guard object["_kind"] as? String == "declref_expr",
                  let decl = object["decl"] as? Object,
                  decl["base_name"] as? String == "previous",
                  let usr = decl["decl_usr"] as? String
            else { return false }
            return SwiftFrontend.DynamicReplacement.isPreviousMarkerUSR(usr)
        }
    }

    func unwrapClosure(_ expression: Object) -> Object? {
        var current = expression
        while current["_kind"] as? String != "closure_expr" {
            guard current["implicit"] as? Bool == true,
                  let child = current["sub_expr"] as? Object
            else { return nil }
            current = child
        }
        return current
    }

    func objects(in value: Any) -> [Object] {
        var result: [Object] = []
        func visit(_ value: Any) {
            if let object = value as? Object {
                result.append(object)
                for child in object.values { visit(child) }
            } else if let array = value as? [Any] {
                for child in array { visit(child) }
            }
        }
        visit(value)
        return result
    }

    func walk(
        _ value: Any,
        closureDepth: Int,
        visit: (Object, Int) throws -> Void
    ) throws {
        if let object = value as? Object {
            try visit(object, closureDepth)
            let nextDepth = closureDepth + ((object["_kind"] as? String) == "closure_expr" ? 1 : 0)
            for child in object.values {
                try walk(child, closureDepth: nextDepth, visit: visit)
            }
        } else if let array = value as? [Any] {
            for child in array {
                try walk(child, closureDepth: closureDepth, visit: visit)
            }
        }
    }

    func slice(_ range: Range<Int>, from source: Data) throws -> Data {
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound <= source.count
        else {
            throw NativeGeneration.SelfReferenceError.invalidSourceRange(
                "\(range.lowerBound)..<\(range.upperBound) exceeds \(source.count) bytes"
            )
        }
        return source.subdata(in: range)
    }

    func validateDisjoint(_ ranges: [Range<Int>], symbol: String) throws {
        let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.upperBound > pair.1.lowerBound {
            throw NativeGeneration.SelfReferenceError.overlappingEdits(symbol)
        }
    }

    static func range(in object: Object) -> Range<Int>? {
        guard let range = object["range"] as? Object,
              let start = range["start"] as? Int,
              let end = range["end"] as? Int,
              start >= 0, end >= start, end < Int.max
        else { return nil }
        return start..<(end + 1)
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
