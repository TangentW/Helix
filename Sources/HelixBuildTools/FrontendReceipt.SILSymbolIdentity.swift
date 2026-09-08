import Foundation

extension FrontendReceipt {
/// Structural facts from the captured toolchain's demangler, scoped to an
/// exact SIL symbol. Display names and debug coordinates are not identities.
struct SILSymbolIdentity: Sendable {
    var kind: String?
    var discriminator: Int?
    var isStatic = false
    var isAdapter = false
    var wrappers: [String] = []
    var roots: [String] = []

    private struct Node {
        var depth: Int
        var kind: String
        var index: Int?
    }

    private static let adapterAttributes: Set<String> = [
        "ObjCAttribute", "NonObjCAttribute", "MergedFunction",
        "FunctionSignatureSpecialization",
    ]
    static let sourceRoles: Set<String> = [
        "Function", "Getter", "Setter", "ReadAccessor", "ModifyAccessor",
        "WillSet", "DidSet", "ExplicitClosure", "ImplicitClosure",
        "Initializer",
    ]
    private static let adapterRoles: Set<String> = [
        "ProtocolWitness", "ReabstractionThunk", "ReabstractionThunkHelper",
        "CurryThunk", "DispatchThunk", "PartialApplyForwarder",
        "KeyPathGetterThunkHelper", "KeyPathSetterThunkHelper",
        "UnsafeMutableAddressor", "UnsafeAddressor", "OwningAddressor",
        "OwningMutableAddressor", "NativeOwningAddressor", "NativeOwningMutableAddressor",
        "NativePinningAddressor", "NativePinningMutableAddressor",
    ]

    static func parse(_ output: String, symbols: [String]) throws -> [String: Self] {
        var sections: [(String, [String])] = []
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("Demangling for ") {
                sections.append((String(line.dropFirst("Demangling for ".count)), []))
            } else if !line.isEmpty, !sections.isEmpty {
                sections[sections.count - 1].1.append(line)
            } else if !line.isEmpty {
                throw FrontendReceipt.Error.demanglingFailed("unexpected symbol-tree preamble: \(line)")
            }
        }
        guard Set(symbols).count == symbols.count, sections.map(\.0) == symbols else {
            throw FrontendReceipt.Error.demanglingFailed("symbol-tree result order/membership differs from request: expected=\(symbols), actual=\(sections.map(\.0))")
        }
        return Dictionary(uniqueKeysWithValues: sections.map { symbol, lines in
            (symbol, parseTree(lines))
        })
    }

    private static func parseTree(_ lines: [String]) -> Self {
        var result = Self(kind: nil, discriminator: nil)
        result.roots = lines.filter { $0.hasPrefix("  kind=") }
            .map { String($0.dropFirst("  kind=".count).prefix { $0 != "," }) }
        var nodes: [Node] = []
        for line in lines {
            let indentation = line.prefix { $0 == " " }.count
            let content = line.dropFirst(indentation)
            guard indentation.isMultiple(of: 2), content.hasPrefix("kind="),
                  indentation / 2 <= (nodes.last?.depth ?? -1) + 1
            else { return result }
            let fields = content.dropFirst(5).components(separatedBy: ", ")
            nodes.append(.init(depth: indentation / 2, kind: fields[0],
                index: fields.count == 2 && fields[1].hasPrefix("index=")
                    ? Int(fields[1].dropFirst(6)) : nil))
        }
        guard nodes.first?.kind == "Global", nodes.filter({ $0.depth == 0 }).count == 1 else { return result }
        func children(of index: Int) -> [Int] {
            let depth = nodes[index].depth
            return nodes.indices.dropFirst(index + 1).prefix { nodes[$0].depth > depth }
                .filter { nodes[$0].depth == depth + 1 }
        }
        let roots = children(of: 0)
        let attributes = roots.filter { adapterAttributes.contains(nodes[$0].kind) }
        let entities = roots.filter { !adapterAttributes.contains(nodes[$0].kind) }
        // Signature-specialization attributes contain transformation parameters.
        // They prove a generated variant, never a source-equivalent callable.
        guard entities.count == 1, attributes.allSatisfy({
            nodes[$0].kind == "FunctionSignatureSpecialization" || children(of: $0).isEmpty
        }) else { return result }
        result.wrappers = attributes.map { nodes[$0].kind }
        var entity = entities[0]
        // Static is a declaration wrapper. Closure contexts may also contain
        // Static, but only a wrapper around the entity describes that entity.
        if nodes[entity].kind == "Static" {
            let nested = children(of: entity)
            guard nested.count == 1 else { return result }
            result.isStatic = true
            result.wrappers.append("Static")
            entity = nested[0]
        }
        result.kind = nodes[entity].kind
        result.isAdapter = !attributes.isEmpty || adapterRoles.contains(nodes[entity].kind)
        if result.kind == "ExplicitClosure" || result.kind == "ImplicitClosure" {
            let numbers = children(of: entity).filter { nodes[$0].kind == "Number" }
            if numbers.count == 1 { result.discriminator = nodes[numbers[0]].index }
        }
        return result
    }

    var evidence: String {
        "compiler symbol-tree kind=\(kind ?? "unresolved"), discriminator=\(discriminator.map(String.init) ?? "unresolved"), static=\(isStatic), adapter=\(isAdapter), wrappers=\(wrappers), roots=\(roots)"
    }
}
}

extension FrontendReceipt.Demangler {
    func symbolIdentities(_ symbols: Set<String>) throws -> [String: FrontendReceipt.SILSymbolIdentity] {
        let ordered = symbols.sorted()
        var result: [String: FrontendReceipt.SILSymbolIdentity] = [:]
        // Source-mapping inventories include unique and colliding fallbacks.
        // Sorted Set slices prove that these batches have disjoint symbols.
        for start in stride(from: 0, to: ordered.count, by: 256) {
            let chunk = Array(ordered[start..<min(start + 256, ordered.count)])
            let output = try run(arguments: ["--expand", "--tree-only"] + chunk)
            result.merge(try FrontendReceipt.SILSymbolIdentity.parse(output, symbols: chunk)) { _, new in new }
        }
        return result
    }
}
