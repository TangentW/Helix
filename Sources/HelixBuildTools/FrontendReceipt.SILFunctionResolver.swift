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
    private let functionsByMangledName: [String: CanonicalSIL.Function]
    private let functionsByDeclarationLocation: [
        DeclarationLocationKey: [CanonicalSIL.Function]
    ]

    init(file: CanonicalSIL.File) {
        self.file = file
        // Many functions share a source file. Resolve its symlinks once while
        // constructing this module-local, immutable location index.
        var canonicalPaths: [String: String] = [:]
        functionsByMangledName = Dictionary(
            grouping: file.functions,
            by: \.mangledName
        ).compactMapValues(\.first)
        functionsByDeclarationLocation = Dictionary(grouping: file.functions.compactMap {
            function -> (DeclarationLocationKey, CanonicalSIL.Function)? in
            guard let location = function.declarationLocation else { return nil }
            let path = canonicalPaths[location.file] ?? Self.canonicalPath(location.file)
            canonicalPaths[location.file] = path
            return (
                .init(
                    file: path,
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
        if let exact = functionsByMangledName[astSymbol] { return exact }
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

    func function(
        forClosure item: FrontendReceipt.TypedAST.Object,
        source: FrontendReceipt.Adapter.SourceState
    ) throws -> CanonicalSIL.Function? {
        guard item["_kind"] as? String == "closure_expr",
              let range = FrontendReceipt.Adapter().sourceRange(in: item),
              let location = sourceLocation(
                  atUTF8Offset: range.start,
                  in: source
              )
        else { return nil }
        let key = DeclarationLocationKey(
            file: Self.canonicalPath(location.file),
            line: location.line,
            column: location.column
        )
        let matches = functionsByDeclarationLocation[key] ?? []
        guard matches.count <= 1 else {
            throw FrontendReceipt.Error.ambiguousSILFunction(
                "closure@\(location.file):\(location.line):\(location.column)",
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
        return source.sourceLocation(atUTF8Offset: offset)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }
}
}
