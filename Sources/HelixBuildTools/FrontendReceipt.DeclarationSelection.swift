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
        var declaration: Declaration?
        var item: TypedAST.Object
        var source: Adapter.SourceState
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
                    if parent == nil, ["func_decl", "var_decl", "subscript_decl"].contains(kind),
                       let usr = item["usr"] as? String, usr.hasPrefix("s:") {
                        let key = Key(logicalPath: source.logicalPath, usr: usr)
                        let offset = Adapter().sourceRange(in: item)?.start
                        let location = offset.flatMap { $0 >= 0 && $0 < source.contents.count ? source.sourceLocation(atUTF8Offset: $0) : nil }
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
                        members.append(.init(declaration: declaration, item: item, source: source))
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
        case .ambiguousSILFunction, .missingSILFunction: return true
        default: return false
        }
    }

    static func declaration(in item: TypedAST.Object, source: Adapter.SourceState) -> Declaration? {
        guard let usr = item["usr"] as? String, usr.hasPrefix("s:") else { return nil }
        let offset = Adapter().sourceRange(in: item)?.start
        let location = offset.flatMap { $0 >= 0 && $0 < source.contents.count ? source.sourceLocation(atUTF8Offset: $0) : nil }
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

    var diagnostics: [Core.Diagnostic] {
        exclusions.values.map(\.diagnostic).sorted {
            ($0.location?.file ?? "", $0.location?.line ?? 0, $0.message)
                < ($1.location?.file ?? "", $1.location?.line ?? 0, $1.message)
        }
    }

    func availableDocuments(sourcesByPhysicalPath: [String: Adapter.SourceState]) throws -> [TypedAST.Object] {
        guard !exclusions.isEmpty else { return documents }
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
            result["items"] = filter(try TypedAST.items(in: document), logicalPath: source.logicalPath)
            return result
        }
    }
}
}
