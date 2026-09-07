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

    private let functionsByMangledName: [String: [CanonicalSIL.Function]]
    private let functionsByDeclarationLocation: [
        DeclarationLocationKey: [CanonicalSIL.Function]
    ]
    private var symbolIdentities: [String: FrontendReceipt.SILSymbolIdentity] = [:]

    init(file: CanonicalSIL.File) {
        self.init(functions: file.functions)
    }

    init(functions: [CanonicalSIL.Function]) {
        // Many functions share a source file. Resolve its symlinks once while
        // constructing this module-local, immutable location index.
        var canonicalPaths: [String: String] = [:]
        functionsByMangledName = Dictionary(
            grouping: functions,
            by: \.mangledName
        )
        functionsByDeclarationLocation = Dictionary(grouping: functions.compactMap {
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

    func resolvingCollisions(using demangler: FrontendReceipt.Demangler) throws -> Self {
        var result = self
        let symbols = Set(functionsByDeclarationLocation.values.filter { $0.count > 1 }
            .flatMap { $0.map(\.mangledName) })
        result.symbolIdentities = try demangler.symbolIdentities(symbols)
        return result
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
        if let exact = functionsByMangledName[astSymbol] {
            guard exact.count == 1 else {
                throw FrontendReceipt.Error.ambiguousSILFunction(astSymbol,
                    exact.map { "\($0.mangledName): \($0.loweredType) at \(String(describing: $0.declarationLocation))" }.sorted())
            }
            return exact.first
        }
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
        let candidates = functionsByDeclarationLocation[key] ?? []
        let matches = disambiguate(candidates, item: item)
        guard matches.count <= 1 else {
            throw FrontendReceipt.Error.ambiguousSILFunction(
                "\(astSymbol) at \(location.file):\(location.line):\(location.column)",
                candidates.map(evidence).sorted()
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
        let candidates = functionsByDeclarationLocation[key] ?? []
        let matches = disambiguate(candidates, item: item)
        guard matches.count <= 1 else {
            throw FrontendReceipt.Error.ambiguousSILFunction(
                "closure@\(location.file):\(location.line):\(location.column), AST discriminator=\(item["discriminator"] ?? "unavailable")",
                candidates.map(evidence).sorted()
            )
        }
        return matches.first
    }

    private func evidence(_ function: CanonicalSIL.Function) -> String {
        "\(function.mangledName): \(function.loweredType), \(symbolIdentities[function.mangledName]?.evidence ?? "symbol tree unavailable"), location=\(String(describing: function.declarationLocation))"
    }

    private func disambiguate(
        _ candidates: [CanonicalSIL.Function],
        item: FrontendReceipt.TypedAST.Object
    ) -> [CanonicalSIL.Function] {
        guard candidates.count > 1 else { return candidates }
        let expected: String?
        switch item["_kind"] as? String {
        case "closure_expr": expected = "ExplicitClosure"
        case "func_decl": expected = "Function"
        case "accessor_decl":
            let accessors = [("get", "Getter"), ("set", "Setter"), ("_read", "ReadAccessor"),
                             ("_modify", "ModifyAccessor"), ("willSet", "WillSet"), ("didSet", "DidSet")]
            let kinds = accessors.filter { item[$0.0] as? Bool == true }.map(\.1)
            expected = kinds.count == 1 ? kinds[0] : nil
        default: expected = nil
        }
        guard let expected else { return candidates }
        let discriminator = (item["discriminator"] as? String).flatMap(Int.init)
        let knownRoles: Set<String> = ["Function", "Getter", "Setter", "ReadAccessor", "ModifyAccessor",
            "WillSet", "DidSet", "ExplicitClosure", "ImplicitClosure", "ProtocolWitness",
            "ReabstractionThunk", "ReabstractionThunkHelper", "CurryThunk", "DispatchThunk"]
        let matches = candidates.filter { function in
            guard let identity = symbolIdentities[function.mangledName],
                  let kind = identity.kind, knownRoles.contains(kind) else {
                // Unknown compiler roles cannot be discarded to manufacture a
                // unique candidate. They remain in the fail-closed diagnostic.
                return true
            }
            guard kind == expected else { return false }
            if expected == "ExplicitClosure", let discriminator,
               let actual = identity.discriminator { return actual == discriminator }
            return true
        }
        if matches.count == 1, let selected = matches.first {
            let identity = symbolIdentities[selected.mangledName]
            guard identity?.kind == expected,
                  expected != "ExplicitClosure" || discriminator == nil
                    || identity?.discriminator == discriminator else { return candidates }
        }
        return matches
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
