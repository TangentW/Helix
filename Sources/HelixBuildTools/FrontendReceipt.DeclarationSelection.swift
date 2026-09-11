import Foundation
import HelixCore

extension FrontendReceipt {
/// This authority is local to one validated AST/source inventory. A property
/// owns its accessors, and a function owns its nested functions and closures.
struct DeclarationSelection {
    struct Key: Hashable, Sendable {
        var logicalPath: String
        var usr: String
    }

    struct Declaration: Sendable {
        var key: Key
        var location: Core.SourceLocation?
        var isImplicit: Bool
    }

    struct Member {
        // An ordinal identifies one node in this validated AST inventory only.
        // It is diagnostic provenance, never a persisted declaration identity.
        var ordinal: Int
        var declaration: Declaration?
        var item: TypedAST.Object
        var source: Adapter.SourceState
    }

    struct UnownedKey: Hashable {
        var logicalPath: String
        var ordinal: Int
    }

    struct UnownedExclusion {
        var member: Member
        var reasons: Set<String>

        var diagnostic: Core.Diagnostic {
            var location = Adapter().sourceRange(in: member.item).flatMap {
                member.source.sourceLocation(atUTF8Offset: $0.start)
            } ?? .init(file: member.source.logicalPath, line: 1, column: 1)
            location.file = member.source.logicalPath
            let kind = member.item["_kind"] as? String ?? "item"
            return .init(code: "HLXIDX025", severity: .warning,
                message: "Excluded source file \(member.source.logicalPath): AST/SIL identity for unowned \(kind) at AST node \(member.ordinal) is unresolved; no Shell entry or source NativeImport is emitted for this file",
                location: location, notes: reasons.sorted())
        }
    }

    struct Exclusion: Sendable {
        var declaration: Declaration
        var reasons: Set<String>

        var diagnostic: Core.Diagnostic {
            .init(code: "HLXIDX024", severity: .warning,
                message: "Excluded declaration \(declaration.key.usr) in \(declaration.key.logicalPath): AST/SIL identity is unresolved; no Shell entry or source NativeImport is emitted for this declaration",
                location: declaration.location, notes: reasons.sorted())
        }
    }

    let documents: [TypedAST.Object]
    let members: [Member]
    private(set) var exclusions: [Key: Exclusion] = [:]
    private(set) var unownedExclusions: [UnownedKey: UnownedExclusion] = [:]
    var excludedFilePaths: Set<String> { Set(unownedExclusions.keys.map(\.logicalPath)) }
    let failurePolicy: DeclarationFailurePolicy

    init(documents: [TypedAST.Object], sourcesByPhysicalPath: [String: Adapter.SourceState],
         options: IndexingOptions?) throws {
        failurePolicy = options?.failurePolicy ?? .strict
        var selected: [TypedAST.Object] = []
        var members: [Member] = []
        var declarations: [Key: Declaration] = [:]
        for document in documents {
            guard let filename = document["filename"] as? String,
                  let source = sourcesByPhysicalPath[URL(fileURLWithPath: filename).resolvingSymlinksInPath().standardizedFileURL.path]
            else { throw FrontendReceipt.Error.malformedAST("declaration selection document is outside the validated source set") }
            var scoped = document
            let items = try TypedAST.items(in: document)
            if options?.includes(logicalPath: source.logicalPath) == false {
                scoped["items"] = items.filter { ($0 as? TypedAST.Object)?["_kind"] as? String == "import_decl" }
            } else {
                var pending: [(Any, Declaration?)] = items.map { ($0, nil) }
                while let (value, parent) = pending.popLast() {
                    if let array = value as? [Any] { pending.append(contentsOf: array.map { ($0, parent) }); continue }
                    guard let item = value as? TypedAST.Object else { continue }
                    let kind = item["_kind"] as? String
                    var declaration = parent
                    if parent == nil, ["func_decl", "var_decl", "subscript_decl", "constructor_decl", "destructor_decl"].contains(kind),
                       let usr = item["usr"] as? String, usr.hasPrefix("s:") {
                        let key = Key(logicalPath: source.logicalPath, usr: usr)
                        let offset = Adapter().sourceRange(in: item)?.start
                        var location = offset.flatMap { $0 >= 0 && $0 < source.contents.count ? source.sourceLocation(atUTF8Offset: $0) : nil }
                        location?.file = source.logicalPath
                        if let existing = declarations[key] {
                            throw FrontendReceipt.Error.malformedAST("duplicate source declaration USR \(usr) in \(source.logicalPath): \(String(describing: existing.location)) and \(String(describing: location))")
                        }
                        let current = Declaration(key: key, location: location, isImplicit: item["implicit"] as? Bool == true)
                        declarations[key] = current
                        declaration = current
                    }
                    // Synthesized backing declarations are not source roots.
                    // Their consumers still resolve exact SIL facts on demand.
                    if declaration?.isImplicit != true, ["func_decl", "accessor_decl", "closure_expr"].contains(kind) {
                        members.append(.init(ordinal: members.count, declaration: declaration, item: item, source: source))
                    }
                    for key in item.keys.sorted() where key != "decl" {
                        let child = item[key]!
                        if child is [Any] || child is TypedAST.Object { pending.append((child, declaration)) }
                    }
                }
            }
            selected.append(scoped)
            try Task.checkCancellation()
        }
        self.documents = selected
        self.members = members
    }

    static func isMappingFailure(_ error: Swift.Error) -> Bool {
        guard let error = error as? FrontendReceipt.Error else { return false }
        switch error {
        case .ambiguousSILFunction, .missingSILFunction, .ambiguousForeignParameterMapping: return true
        default: return false
        }
    }

    static func declaration(in item: TypedAST.Object, source: Adapter.SourceState) -> Declaration? {
        guard let usr = item["usr"] as? String, usr.hasPrefix("s:") else { return nil }
        let offset = Adapter().sourceRange(in: item)?.start
        var location = offset.flatMap { $0 >= 0 && $0 < source.contents.count ? source.sourceLocation(atUTF8Offset: $0) : nil }
        location?.file = source.logicalPath
        return .init(key: .init(logicalPath: source.logicalPath, usr: usr), location: location,
            isImplicit: item["implicit"] as? Bool == true)
    }

    mutating func merge(_ values: [Exclusion]) {
        for value in values {
            for reason in value.reasons { exclude(value.declaration, reason: reason) }
        }
    }

    mutating func exclude(_ declaration: Declaration, reason: String) {
        var value = exclusions[declaration.key] ?? .init(declaration: declaration, reasons: [])
        value.reasons.insert(reason)
        exclusions[declaration.key] = value
    }

    mutating func exclude(_ member: Member, reason: String) {
        if let declaration = member.declaration {
            exclude(declaration, reason: reason)
        } else {
            // Without compiler-backed ownership, quarantining only a closure
            // could retain a caller whose lowered body still depends on it.
            let key = UnownedKey(logicalPath: member.source.logicalPath, ordinal: member.ordinal)
            var value = unownedExclusions[key] ?? .init(member: member, reasons: [])
            value.reasons.insert(reason)
            unownedExclusions[key] = value
        }
    }

    var diagnostics: [Core.Diagnostic] {
        (exclusions.values.map(\.diagnostic) + unownedExclusions.values.map(\.diagnostic)).sorted {
            ($0.location?.file ?? "", $0.location?.line ?? 0, $0.message)
                < ($1.location?.file ?? "", $1.location?.line ?? 0, $1.message)
        }
    }

    func availableDocuments(sourcesByPhysicalPath: [String: Adapter.SourceState]) throws -> [TypedAST.Object] {
        guard !exclusions.isEmpty || !unownedExclusions.isEmpty else { return documents }
        let excludedFiles = excludedFilePaths
        func filter(_ items: [Any], logicalPath: String) -> [Any] {
            items.compactMap { value in
                guard var item = value as? TypedAST.Object else { return value }
                if let usr = item["usr"] as? String, exclusions[.init(logicalPath: logicalPath, usr: usr)] != nil { return nil }
                if let members = item["members"] as? [Any] { item["members"] = filter(members, logicalPath: logicalPath) }
                return item
            }
        }
        return try documents.map { document in
            guard let filename = document["filename"] as? String,
                  let source = sourcesByPhysicalPath[URL(fileURLWithPath: filename).resolvingSymlinksInPath().standardizedFileURL.path]
            else { throw FrontendReceipt.Error.malformedAST("declaration filtering document is outside the validated source set") }
            var result = document
            let items = try TypedAST.items(in: document)
            result["items"] = excludedFiles.contains(source.logicalPath)
                ? items.filter { ($0 as? TypedAST.Object)?["_kind"] as? String == "import_decl" }
                : filter(items, logicalPath: source.logicalPath)
            return result
        }
    }
}
}
