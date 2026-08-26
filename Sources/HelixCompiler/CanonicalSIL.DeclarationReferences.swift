import Foundation
import HelixCore

extension CanonicalSIL {
/// Exact source-location-to-declaration evidence from the captured Swift
/// frontend. It is compiler input only: runtime dispatch remains bound to a
/// cataloged NativeCall descriptor and never accepts source-provided text.
struct DeclarationReferenceMap: Sendable {
    private struct Span: Sendable {
        var lowerBound: Int
        var upperBound: Int
        var declarationUSR: String

        var width: Int { upperBound - lowerBound }

        func contains(_ offset: Int) -> Bool {
            lowerBound <= offset && offset <= upperBound
        }
    }

    private struct FileIndex: Sendable {
        var locations: SourceTransform.LocationMap
        var points: [Int: Set<String>]
        var assignmentSpans: [Span]
        var assignmentPrefixMaximums: [Int]

        init(
            locations: SourceTransform.LocationMap,
            points: [Int: Set<String>],
            assignmentSpans: [Span]
        ) {
            self.locations = locations
            self.points = points
            self.assignmentSpans = assignmentSpans.sorted {
                if $0.lowerBound != $1.lowerBound {
                    return $0.lowerBound < $1.lowerBound
                }
                if $0.upperBound != $1.upperBound {
                    return $0.upperBound < $1.upperBound
                }
                return $0.declarationUSR < $1.declarationUSR
            }
            var maximum = Int.min
            assignmentPrefixMaximums = self.assignmentSpans.map { span in
                maximum = max(maximum, span.upperBound)
                return maximum
            }
        }

        func declarationUSR(line: Int, column: Int) -> String? {
            guard let offset = locations.utf8Offset(
                line: line,
                column: column
            ) else { return nil }
            if let exact = points[offset] {
                return exact.count == 1 ? exact.first : nil
            }
            var lower = 0
            var upper = assignmentSpans.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if assignmentSpans[middle].lowerBound <= offset {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            var narrowest: Int?
            var candidates = Set<String>()
            var index = lower
            while index > 0 {
                index -= 1
                guard assignmentPrefixMaximums[index] >= offset else { break }
                let span = assignmentSpans[index]
                guard span.contains(offset) else { continue }
                if let currentWidth = narrowest,
                   span.width < currentWidth {
                    narrowest = span.width
                    candidates = [span.declarationUSR]
                } else if let currentWidth = narrowest,
                          span.width == currentWidth {
                    candidates.insert(span.declarationUSR)
                } else if narrowest == nil {
                    narrowest = span.width
                    candidates = [span.declarationUSR]
                }
            }
            return candidates.count == 1 ? candidates.first : nil
        }
    }

    static let empty = Self(files: [:], aliases: [:])

    private var files: [String: FileIndex]
    private var aliases: [String: String]

    init(
        documents: [SwiftFrontend.TypedAST.Object],
        sourceFiles: [URL]
    ) throws {
        var sources: [String: Data] = [:]
        var aliases: [String: String] = [:]
        for source in sourceFiles {
            let standardized = source.standardizedFileURL
            let canonical = standardized.resolvingSymlinksInPath().path
            guard sources[canonical] == nil else {
                throw SwiftFrontend.TypedAST.ParseError.malformed(
                    "typed-AST primary sources resolve to the same file"
                )
            }
            sources[canonical] = try Data(contentsOf: source)
            for alias in Self.pathAliases(source.path) {
                guard aliases[alias] == nil || aliases[alias] == canonical else {
                    throw SwiftFrontend.TypedAST.ParseError.malformed(
                        "typed-AST source aliases resolve ambiguously"
                    )
                }
                aliases[alias] = canonical
            }
        }

        var points: [String: [Int: Set<String>]] = [:]
        var assignmentSpans: [String: [Span]] = [:]
        var documentedSources = Set<String>()
        var referenceCount = 0
        for document in documents {
            guard let rawFilename = document["filename"] as? String else {
                throw SwiftFrontend.TypedAST.ParseError.malformed(
                    "source document has no filename"
                )
            }
            guard let canonical = Self.pathAliases(rawFilename).lazy
                .compactMap({ aliases[$0] })
                .first,
                  sources[canonical] != nil
            else {
                throw SwiftFrontend.TypedAST.ParseError.malformed(
                    "source document is outside the requested primary set"
                )
            }
            guard documentedSources.insert(canonical).inserted else {
                throw SwiftFrontend.TypedAST.ParseError.malformed(
                    "typed-AST contains the same primary source more than once"
                )
            }
            for alias in Self.pathAliases(rawFilename) {
                guard aliases[alias] == nil || aliases[alias] == canonical else {
                    throw SwiftFrontend.TypedAST.ParseError.malformed(
                        "typed-AST document aliases resolve ambiguously"
                    )
                }
                aliases[alias] = canonical
            }

            var pending: [Any] = [document]
            while let value = pending.popLast() {
                if let array = value as? [Any] {
                    pending.append(contentsOf: array)
                    continue
                }
                guard let object = value as? SwiftFrontend.TypedAST.Object else {
                    continue
                }
                pending.append(contentsOf: object.values)
                let kind = object["_kind"] as? String
                if kind == "declref_expr" || kind == "member_ref_expr",
                   let declaration = Self.objectiveCDeclaration(in: object),
                   let range = object["range"]
                    as? SwiftFrontend.TypedAST.Object,
                   let offset = range[
                    kind == "member_ref_expr" ? "end" : "start"
                   ] as? Int {
                    try Self.consumeReference(&referenceCount)
                    points[canonical, default: [:]][offset, default: []]
                        .insert(declaration)
                }
                if kind == "assign_expr",
                   let destination = object["dest"]
                    as? SwiftFrontend.TypedAST.Object,
                   let source = object["src"]
                    as? SwiftFrontend.TypedAST.Object,
                   let sourceRange = source["range"]
                    as? SwiftFrontend.TypedAST.Object,
                   let sourceStart = sourceRange["start"] as? Int,
                   let assigned = Self.assignedObjectiveCDeclaration(
                    in: destination
                   ),
                   assigned.offset < sourceStart {
                    try Self.consumeReference(&referenceCount)
                    assignmentSpans[canonical, default: []].append(
                        .init(
                            lowerBound: assigned.offset,
                            upperBound: sourceStart - 1,
                            declarationUSR: assigned.usr
                        )
                    )
                }
            }
        }
        guard documentedSources == Set(sources.keys) else {
            throw SwiftFrontend.TypedAST.ParseError.malformed(
                "typed-AST does not exactly cover the requested primary sources"
            )
        }

        self.files = Dictionary(uniqueKeysWithValues: sources.map {
            canonical, source in
            (canonical, FileIndex(
                locations: SourceTransform.LocationMap(source),
                points: points[canonical] ?? [:],
                assignmentSpans: assignmentSpans[canonical] ?? []
            ))
        })
        self.aliases = aliases
    }

    private init(files: [String: FileIndex], aliases: [String: String]) {
        self.files = files
        self.aliases = aliases
    }

    func usr(at location: Core.SourceLocation?) -> String? {
        guard let location else { return nil }
        for path in Self.pathAliases(location.file) {
            guard let canonical = aliases[path],
                  let file = files[canonical]
            else { continue }
            return file.declarationUSR(
                line: location.line,
                column: location.column
            )
        }
        return nil
    }

    private static func objectiveCDeclaration(
        in object: SwiftFrontend.TypedAST.Object
    ) -> String? {
        guard let declaration = object["decl"]
                as? SwiftFrontend.TypedAST.Object,
              let usr = declaration["decl_usr"] as? String,
              usr.hasPrefix("c:objc(")
        else { return nil }
        return usr
    }

    /// `assign_expr.dest` directly names the outer l-value member. Looking
    /// through its base would confuse an Objective-C getter followed by a
    /// Swift-only property write with an Objective-C setter.
    private static func assignedObjectiveCDeclaration(
        in destination: SwiftFrontend.TypedAST.Object
    ) -> (usr: String, offset: Int)? {
        guard destination["_kind"] as? String == "member_ref_expr",
              let usr = objectiveCDeclaration(in: destination),
              let range = destination["range"]
                as? SwiftFrontend.TypedAST.Object,
              let offset = range["end"] as? Int
        else { return nil }
        return (usr, offset)
    }

    private static func pathAliases(_ path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        return Array(Set([
            path,
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().standardizedFileURL.path,
        ])).sorted()
    }

    private static func consumeReference(_ count: inout Int) throws {
        count += 1
        guard count <= 1_000_000 else {
            throw SwiftFrontend.TypedAST.ParseError.malformed(
                "Objective-C declaration reference inventory exceeds its audit bound"
            )
        }
    }
}
}
