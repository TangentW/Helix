import Foundation

extension FrontendReceipt {
/// Structural facts from the captured toolchain's demangler, scoped to an
/// exact SIL symbol. Display names and debug coordinates are not identities.
struct SILSymbolIdentity: Sendable {
    var kind: String?
    var discriminator: Int?

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
        guard sections.map(\.0) == symbols else {
            throw FrontendReceipt.Error.demanglingFailed("symbol-tree result order/membership differs from request: expected=\(symbols), actual=\(sections.map(\.0))")
        }
        return Dictionary(uniqueKeysWithValues: sections.map { symbol, lines in
            let roots = lines.filter { $0.hasPrefix("  kind=") }
            guard lines.first == "kind=Global", roots.count == 1 else {
                return (symbol, Self(kind: nil, discriminator: nil))
            }
            let kind = String(roots[0].dropFirst("  kind=".count).prefix { $0 != "," })
            let indices = lines.compactMap { line -> Int? in
                guard line.hasPrefix("    kind=Number, index=") else { return nil }
                return Int(line.dropFirst("    kind=Number, index=".count))
            }
            return (symbol, Self(kind: kind, discriminator: indices.count == 1 ? indices[0] : nil))
        })
    }

    var evidence: String {
        "compiler symbol-tree kind=\(kind ?? "unresolved"), discriminator=\(discriminator.map(String.init) ?? "unresolved")"
    }
}
}

extension FrontendReceipt.Demangler {
    func symbolIdentities(_ symbols: Set<String>) throws -> [String: FrontendReceipt.SILSymbolIdentity] {
        let ordered = symbols.sorted()
        var result: [String: FrontendReceipt.SILSymbolIdentity] = [:]
        // Only colliding locations need these trees. Batch them to keep a large
        // module from launching a demangler process for every declaration.
        // Sorted Set slices prove that these batches have disjoint symbols.
        for start in stride(from: 0, to: ordered.count, by: 256) {
            let chunk = Array(ordered[start..<min(start + 256, ordered.count)])
            let output = try run(arguments: ["--expand", "--tree-only"] + chunk)
            result.merge(try FrontendReceipt.SILSymbolIdentity.parse(output, symbols: chunk)) { _, new in new }
        }
        return result
    }
}
