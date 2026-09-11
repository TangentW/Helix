import Foundation

extension CanonicalSIL {
/// Compiler-emitted import-as-member context, scoped by the physical SIL symbol.
/// A source spelling or a mangled-name substring alone cannot establish this context.
public struct ClangMember: Hashable, Sendable {
    public var owner: String
    public var member: String
    public var loweredType: String
    public var silLine: Int

    static func inventory(in text: String) -> [String: [Self]] {
        var result: [String: [Self]] = [:]
        for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("sil "),
                  let start = line.range(of: "[clang "),
                  let end = line[start.upperBound...].firstIndex(of: "]"),
                  let symbolStart = line.range(of: " @", range: end..<line.endIndex),
                  let typeStart = line.range(of: " : $", range: symbolStart.upperBound..<line.endIndex)
            else { continue }
            let context = line[start.upperBound..<end]
            guard let dot = context.lastIndex(of: "."), dot != context.startIndex else { continue }
            let owner = String(context[..<dot])
            let member = String(context[context.index(after: dot)...])
            guard !member.isEmpty else { continue }
            let symbol = String(line[symbolStart.upperBound..<typeStart.lowerBound])
            var type = String(line[typeStart.upperBound...])
            if type.hasSuffix(" {") { type.removeLast(2) }
            result[symbol, default: []].append(.init(owner: owner, member: member,
                loweredType: type, silLine: offset + 1))
        }
        return result
    }
}
}
