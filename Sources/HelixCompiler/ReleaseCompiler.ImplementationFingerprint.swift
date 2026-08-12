import HelixCore

extension ReleaseCompiler {
public enum ImplementationFingerprint {
    /// Computes the versioned implementation fingerprint for a root whose
    /// transitive implementation graph is unavailable. Indexer uses this for
    /// typed clients that provide one declaration at a time.
    public static func compute(
        symbol: String,
        loweredType: String,
        body: String
    ) -> Core.Digest {
        var hasher = Core.StableHasher(domain: "HLX.ImplementationFingerprint.v1")
        hasher.append(UInt64(1))
        hasher.append(symbol)
        hasher.append(loweredType)
        hasher.append(ReleaseCompiler.BodyFingerprint.compute(body))
        return hasher.finalize()
    }

    public static func compute(
        root: CanonicalSIL.Function,
        in file: CanonicalSIL.File,
        archivedSymbols: Set<String>,
        imageLocalSymbols: Set<String> = []
    ) -> Core.Digest {
        var functions: [String: CanonicalSIL.Function] = [root.mangledName: root]
        var pending = referencedSymbols(in: root.body).sorted()
        var visited = Set<String>()

        while let symbol = pending.popLast() {
            guard visited.insert(symbol).inserted,
                  !archivedSymbols.contains(symbol),
                  isCompilerGeneratedSymbol(symbol) || imageLocalSymbols.contains(symbol),
                  let function = file.function(mangledName: symbol)
            else { continue }
            functions[symbol] = function
            pending.append(contentsOf: referencedSymbols(in: function.body).sorted())
        }

        var hasher = Core.StableHasher(domain: "HLX.ImplementationFingerprint.v1")
        hasher.append(UInt64(functions.count))
        for symbol in functions.keys.sorted() {
            guard let function = functions[symbol] else { continue }
            hasher.append(symbol)
            hasher.append(function.loweredType)
            hasher.append(ReleaseCompiler.BodyFingerprint.compute(function.body))
        }
        return hasher.finalize()
    }

    static func referencedSymbols(in body: String) -> Set<String> {
        Set(body.split(separator: "\n").compactMap { line -> String? in
            guard let marker = line.range(of: "function_ref @") else { return nil }
            let suffix = line[marker.upperBound...]
            let end = suffix.firstIndex { $0 == " " || $0 == ":" }
                ?? suffix.endIndex
            let symbol = String(suffix[..<end])
            return symbol.isEmpty ? nil : symbol
        })
    }

    static func isCompilerGeneratedSymbol(_ symbol: String) -> Bool {
        symbol.contains("cfU") || symbol.contains("fU")
            || symbol.contains("_Tg") || symbol.contains("Tf")
            || isDefaultArgumentGenerator(symbol)
    }

    /// Swift emits one directly callable helper for every default argument.
    /// The stable mangling tail is `fA_` for argument zero and `fA<n>_` for
    /// later arguments, including methods and initializers.
    static func isDefaultArgumentGenerator(_ symbol: String) -> Bool {
        guard symbol.last == "_" else { return false }
        let body = symbol.dropLast()
        guard let marker = body.range(of: "fA", options: .backwards) else {
            return false
        }
        return body[marker.upperBound...].allSatisfy(\.isNumber)
    }
}
}
