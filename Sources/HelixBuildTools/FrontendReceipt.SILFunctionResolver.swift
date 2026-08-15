import Foundation
import HelixCompiler
import HelixCore

extension FrontendReceipt {
/// Resolves a typed-AST declaration to its physical canonical-SIL function.
/// Swift overlays can spell the same ABI type under different modules in the
/// AST USR and SIL symbol, so exact mangled-name equality is only the fast path.
struct SILFunctionResolver: Sendable {
    private struct DeclarationLocationKey: Hashable, Sendable {
        var file: String
        var line: Int
        var column: Int
    }

    let file: CanonicalSIL.File
    private let functionsByDeclarationLocation: [
        DeclarationLocationKey: [CanonicalSIL.Function]
    ]

    init(file: CanonicalSIL.File) {
        self.file = file
        functionsByDeclarationLocation = Dictionary(grouping: file.functions.compactMap {
            function -> (DeclarationLocationKey, CanonicalSIL.Function)? in
            guard let location = function.declarationLocation else { return nil }
            return (
                .init(
                    file: Self.canonicalPath(location.file),
                    line: location.line,
                    column: location.column
                ),
                function
            )
        }, by: \.0).mapValues { $0.map(\.1) }
    }

    func function(
        for item: FrontendReceipt.TypedAST.Object,
        source: FrontendReceipt.Adapter.SourceState,
        baseName: String? = nil
    ) throws -> CanonicalSIL.Function? {
        guard let usr = item["usr"] as? String, usr.hasPrefix("s:") else {
            return nil
        }
        let astSymbol = "$s" + usr.dropFirst(2)
        if let exact = file.function(mangledName: astSymbol) { return exact }
        guard let location = declarationLocation(
            for: item,
            source: source,
            baseName: baseName
        ) else { return nil }

        let key = DeclarationLocationKey(
            file: Self.canonicalPath(location.file),
            line: location.line,
            column: location.column
        )
        let matches = functionsByDeclarationLocation[key] ?? []
        guard matches.count <= 1 else {
            throw FrontendReceipt.Error.ambiguousSILFunction(
                astSymbol,
                matches.map(\.mangledName).sorted()
            )
        }
        return matches.first
    }

    private func declarationLocation(
        for item: FrontendReceipt.TypedAST.Object,
        source: FrontendReceipt.Adapter.SourceState,
        baseName: String?
    ) -> Core.SourceLocation? {
        guard let range = FrontendReceipt.Adapter().sourceRange(in: item) else {
            return nil
        }
        var offset = range.start
        if let baseName,
           let body = item["body"] as? FrontendReceipt.TypedAST.Object,
           let bodyRange = FrontendReceipt.Adapter().sourceRange(in: body),
           range.start >= 0,
           bodyRange.start >= range.start,
           bodyRange.start <= source.contents.count,
           let header = String(
               data: source.contents.subdata(in: range.start..<bodyRange.start),
               encoding: .utf8
           ),
           let token = FrontendReceipt.Adapter.functionToken(
               in: header,
               baseName: baseName
           ) {
            offset += header[..<token.nameStart].utf8.count
        }
        return sourceLocation(atUTF8Offset: offset, in: source)
    }

    private func sourceLocation(
        atUTF8Offset offset: Int,
        in source: FrontendReceipt.Adapter.SourceState
    ) -> Core.SourceLocation? {
        guard offset >= 0, offset <= source.contents.count else { return nil }
        var line = 1
        var column = 1
        for byte in source.contents.prefix(offset) {
            if byte == UInt8(ascii: "\n") {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return .init(file: source.url.path, line: line, column: column)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }
}
}
