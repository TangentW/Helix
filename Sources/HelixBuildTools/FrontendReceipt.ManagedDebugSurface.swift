import Foundation
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt {
enum ManagedDebugSurface {}
}

extension FrontendReceipt.ManagedDebugSurface {
    struct Expansion: Sendable {
        var importedTypes: [FrontendReceipt.Adapter.ImportedNativeType]
        var operations: [FrontendReceipt.Adapter.ImportedOperation]
    }

    private struct OwnerSurface: Sendable {
        var moduleName: String
        var preciseIdentifier: String
        var swiftPath: String
        var runtimeName: String?
        var requiresMainActor: Bool
        var properties: [SwiftFrontend.SymbolGraph.Symbol]
    }

    private struct OwnerMatch: Sendable {
        var score: Int
        var surface: OwnerSurface
    }

    private struct Candidate: Hashable, Sendable {
        var moduleName: String
        var probeOwnerType: String
        var ownerType: String
        var ownerAliases: [String]
        var memberName: String
        var sourceFileLogicalID: String
        var importedModules: [String]
        var requiresMainActor: Bool
    }

    /// Expands only types already frozen by the source module. Public SDK
    /// declarations nominate probes, but the captured frontend remains the
    /// authority for Swift spelling, isolation, and the exact callable ABI.
    static func expand(
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        minimumOS: Core.SemanticVersion,
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> Expansion {
        let moduleNames = Set(importedTypes.flatMap(\.importedModules).compactMap {
            $0.split(separator: ".").first.map(String.init)
        }).sorted()
        guard moduleNames.count <= 32 else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed Debug surface exceeds the 32-module audit bound"
            )
        }

        var matchesByType: [Int: [OwnerMatch]] = [:]
        for moduleName in moduleNames where isProbeIdentifier(moduleName) {
            let graph = try frontend.emitSymbolGraph(
                moduleName: moduleName,
                invocation: invocation
            )
            let surfaces = ownerSurfaces(in: graph, minimumOS: minimumOS)
            for index in importedTypes.indices where importedTypes[index]
                .importedModules.contains(where: {
                    $0.split(separator: ".").first == Substring(moduleName)
                }) {
                guard let match = bestOwnerMatch(
                    for: importedTypes[index],
                    in: surfaces
                ) else { continue }
                matchesByType[index, default: []].append(match)
            }
        }

        var enrichedTypes = importedTypes
        var candidates: [Candidate] = []
        for index in importedTypes.indices.sorted(by: {
            importedTypes[$0].canonicalName < importedTypes[$1].canonicalName
        }) {
            guard let matches = matchesByType[index],
                  let selected = uniqueBestMatch(matches)
            else { continue }
            enrichedTypes[index] = enrich(
                importedTypes[index],
                with: selected.surface
            )
            candidates += makeCandidates(
                surface: selected.surface,
                importedType: enrichedTypes[index]
            )
        }
        enrichedTypes = try FrontendReceipt.Adapter().mergeImportedNativeTypes(
            references: [],
            operationTypes: enrichedTypes
        )
        candidates = Array(Set(candidates)).sorted(by: candidateOrdering)
        guard candidates.count <= 4_096 else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed Debug surface exceeds the 4096-operation audit bound"
            )
        }

        let operations = try probe(
            candidates,
            importedTypes: enrichedTypes,
            frontend: frontend,
            invocation: invocation
        )
        return Expansion(
            importedTypes: enrichedTypes,
            operations: try FrontendReceipt.Adapter()
                .mergeImportedOperations(operations)
        )
    }

    private static func ownerSurfaces(
        in graph: SwiftFrontend.SymbolGraph.Document,
        minimumOS: Core.SemanticVersion
    ) -> [OwnerSurface] {
        let typeKinds: Set<String> = [
            "swift.actor", "swift.class", "swift.enum", "swift.protocol",
            "swift.struct", "swift.typealias",
        ]
        var owners: [String: SwiftFrontend.SymbolGraph.Symbol] = [:]
        var ambiguousOwners = Set<String>()
        for symbol in graph.symbols {
            guard typeKinds.contains(symbol.kind.identifier),
                  !symbol.pathComponents.isEmpty,
                  symbol.pathComponents.allSatisfy(isProbeIdentifier),
                  isAvailable(symbol, minimumOS: minimumOS)
            else { continue }
            if owners[symbol.identifier.precise] != nil {
                ambiguousOwners.insert(symbol.identifier.precise)
            } else {
                owners[symbol.identifier.precise] = symbol
            }
        }
        for precise in ambiguousOwners { owners.removeValue(forKey: precise) }
        var memberOwner: [String: String] = [:]
        var ambiguousMembers = Set<String>()
        for relationship in graph.relationships where relationship.kind == "memberOf" {
            if let existing = memberOwner[relationship.source],
               existing != relationship.target {
                ambiguousMembers.insert(relationship.source)
            } else {
                memberOwner[relationship.source] = relationship.target
            }
        }
        for precise in ambiguousMembers { memberOwner.removeValue(forKey: precise) }
        var propertiesByOwner: [String: [SwiftFrontend.SymbolGraph.Symbol]] = [:]
        for symbol in graph.symbols where symbol.kind.identifier == "swift.type.property" {
            guard symbol.accessLevel == "public" || symbol.accessLevel == "open",
                  let owner = memberOwner[symbol.identifier.precise],
                  owners[owner] != nil,
                  symbol.pathComponents.count >= 2,
                  let member = symbol.pathComponents.last,
                  isProbeIdentifier(member),
                  isAvailable(symbol, minimumOS: minimumOS),
                  !symbol.declarationFragments.contains(where: {
                      $0.spelling == "async" || $0.spelling == "throws"
                  })
            else { continue }
            propertiesByOwner[owner, default: []].append(symbol)
        }
        return owners.keys.sorted().compactMap { precise -> OwnerSurface? in
            guard let owner = owners[precise],
                  let properties = propertiesByOwner[precise],
                  !properties.isEmpty
            else { return nil }
            return OwnerSurface(
                moduleName: graph.module.name,
                preciseIdentifier: precise,
                swiftPath: owner.pathComponents.joined(separator: "."),
                runtimeName: objectiveCRuntimeName(precise),
                requiresMainActor: requiresMainActor(owner),
                properties: properties.sorted {
                    ($0.pathComponents.joined(separator: "\u{0}"),
                     $0.identifier.precise)
                        < ($1.pathComponents.joined(separator: "\u{0}"),
                           $1.identifier.precise)
                }
            )
        }
    }

    private static func bestOwnerMatch(
        for type: FrontendReceipt.Adapter.ImportedNativeType,
        in surfaces: [OwnerSurface]
    ) -> OwnerMatch? {
        let scored = surfaces.compactMap { surface -> OwnerMatch? in
            let score = matchScore(type, surface: surface)
            return score == 0 ? nil : .init(
                score: score,
                surface: surface
            )
        }
        return uniqueBestMatch(scored)
    }

    private static func uniqueBestMatch(_ matches: [OwnerMatch]) -> OwnerMatch? {
        guard let maximum = matches.map(\.score).max() else { return nil }
        let best = matches.filter { $0.score == maximum }
        let identities = Set(best.map {
            [$0.surface.moduleName, $0.surface.preciseIdentifier]
                .joined(separator: "|")
        })
        guard identities.count == 1 else { return nil }
        return best.sorted {
            ($0.surface.moduleName, $0.surface.preciseIdentifier)
                < ($1.surface.moduleName, $1.surface.preciseIdentifier)
        }.first
    }

    private static func matchScore(
        _ type: FrontendReceipt.Adapter.ImportedNativeType,
        surface: OwnerSurface
    ) -> Int {
        let rawNames = Set(
            [type.canonicalName, type.swiftType] + type.aliases
        )
        if let runtimeName = surface.runtimeName,
           rawNames.contains(runtimeName) || rawNames.contains("__C.\(runtimeName)") {
            return 400
        }
        let qualified = "\(surface.moduleName).\(surface.swiftPath)"
        if rawNames.contains(qualified) { return 300 }
        let normalized = Set(rawNames.map {
            normalizedTypeName($0, moduleName: surface.moduleName)
        })
        if normalized.contains(surface.swiftPath) { return 200 }
        if !surface.swiftPath.contains("."), normalized.contains(where: {
            !$0.contains(".") && $0 == surface.swiftPath
        }) {
            return 100
        }
        return 0
    }

    private static func enrich(
        _ type: FrontendReceipt.Adapter.ImportedNativeType,
        with surface: OwnerSurface
    ) -> FrontendReceipt.Adapter.ImportedNativeType {
        var result = type
        let qualified = "\(surface.moduleName).\(surface.swiftPath)"
        result.aliases = Array(Set(
            result.aliases + [result.canonicalName, result.swiftType,
                              surface.swiftPath, qualified]
                + [surface.runtimeName].compactMap { $0 }
                + (surface.runtimeName.map { ["__C.\($0)"] } ?? [])
        )).sorted()
        if let runtimeName = surface.runtimeName,
           normalizedTypeName(result.canonicalName, moduleName: nil) == runtimeName,
           runtimeName != surface.swiftPath {
            result.canonicalName = surface.swiftPath
            result.swiftType = surface.swiftPath
        }
        result.requiresMainActor = surface.requiresMainActor
        return result
    }

    private static func makeCandidates(
        surface: OwnerSurface,
        importedType: FrontendReceipt.Adapter.ImportedNativeType
    ) -> [Candidate] {
        let ownerAliases = Array(Set(
            [surface.swiftPath, "\(surface.moduleName).\(surface.swiftPath)",
             importedType.canonicalName, importedType.swiftType]
                + importedType.aliases
                + [surface.runtimeName].compactMap { $0 }
        )).sorted()
        return surface.properties.compactMap { property in
            guard let memberName = property.pathComponents.last else { return nil }
            let isNonisolated = property.declarationFragments.contains {
                $0.spelling == "nonisolated"
            }
            return Candidate(
                moduleName: surface.moduleName,
                probeOwnerType: surface.swiftPath,
                ownerType: importedType.swiftType,
                ownerAliases: ownerAliases,
                memberName: memberName,
                sourceFileLogicalID: importedType.sourceFileLogicalID,
                importedModules: importedType.importedModules,
                requiresMainActor: !isNonisolated && (
                    surface.requiresMainActor || requiresMainActor(property)
                )
            )
        }
    }

    private static func probe(
        _ candidates: [Candidate],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> [FrontendReceipt.Adapter.ImportedOperation] {
        var operations: [FrontendReceipt.Adapter.ImportedOperation] = []
        for start in stride(from: 0, to: candidates.count, by: 256) {
            let end = min(start + 256, candidates.count)
            operations += try probeBatch(
                Array(candidates[start..<end]),
                importedTypes: importedTypes,
                frontend: frontend,
                invocation: invocation
            )
        }
        return operations
    }

    private static func probeBatch(
        _ candidates: [Candidate],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> [FrontendReceipt.Adapter.ImportedOperation] {
        guard !candidates.isEmpty else { return [] }
        do {
            return try measure(
                candidates,
                importedTypes: importedTypes,
                frontend: frontend,
                invocation: invocation
            )
        } catch let error as SwiftFrontend.Error {
            guard case .compilationFailed = error else { throw error }
            guard candidates.count > 1 else { return [] }
            let middle = candidates.count / 2
            return try probeBatch(
                Array(candidates[..<middle]),
                importedTypes: importedTypes,
                frontend: frontend,
                invocation: invocation
            ) + probeBatch(
                Array(candidates[middle...]),
                importedTypes: importedTypes,
                frontend: frontend,
                invocation: invocation
            )
        }
    }

    private static func measure(
        _ candidates: [Candidate],
        importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> [FrontendReceipt.Adapter.ImportedOperation] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-managed-debug-surface-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("ManagedDebugSurface.swift")
        let source = renderSource(candidates)
        let contents = Data(source.utf8)
        guard contents.count <= 8 * 1_024 * 1_024 else {
            throw FrontendReceipt.Error.frontendFailed(
                "managed Debug probe source exceeds 8 MiB"
            )
        }
        try contents.write(to: sourceURL, options: .atomic)
        let astOutput = try frontend.emitTypedAST(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let documents = try FrontendReceipt.TypedAST.parseDocuments(astOutput)
        let demangled = try FrontendReceipt.Demangler(
            compilerURL: frontend.compilerURL
        ).demangle(FrontendReceipt.TypedAST.mangledTypes(in: documents))
        let canonicalSIL = try frontend.emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let silFile = try CanonicalSIL.File(text: canonicalSIL)
        let state = FrontendReceipt.Adapter.SourceState(
            logicalPath: "HelixManagedDebug/ManagedDebugSurface.swift",
            url: sourceURL,
            contents: contents,
            contentHash: .sha256(contents)
        )
        let surface = try FrontendReceipt.Adapter().discoverImportedOperationSurface(
            documents: documents,
            sourcesByPhysicalPath: [
                sourceURL.resolvingSymlinksInPath().standardizedFileURL.path: state,
            ],
            moduleName: invocation.moduleName,
            demangled: demangled,
            silFile: silFile
        )
        let aliases = candidateLookup(candidates)
        let nativeTypes = placeholderNativeTypes(importedTypes)
        let swiftAliases = try FrontendReceipt.Adapter()
            .makeImportedSwiftTypeAliases(importedTypes)
        return surface.operations.compactMap { operation in
            guard operation.dispatch == .staticGetter,
                  operation.parameterSwiftTypes.isEmpty,
                  let candidate = aliases[operationIdentity(
                      ownerType: operation.ownerType,
                      memberName: operation.baseName
                  )]
            else { return nil }
            var measured = operation
            measured.ownerType = candidate.ownerType
            measured.parameterSwiftTypes = operation.parameterSwiftTypes.map {
                FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                    in: $0,
                    aliases: swiftAliases
                )
            }
            measured.resultSwiftType = FrontendReceipt.SwiftTypeSpelling
                .replacingNominalAliases(
                    in: operation.resultSwiftType,
                    aliases: swiftAliases
                )
            guard FrontendReceipt.ValueTypeParser.parse(
                      measured.resultSwiftType,
                      allowVoid: false,
                      nativeTypes: nativeTypes
                  ) != nil
            else { return nil }
            measured.sourceFileLogicalID = candidate.sourceFileLogicalID
            measured.importedModules = candidate.importedModules
            measured.requiresMainActor = candidate.requiresMainActor
            measured.isolationEvidence = .importedDeclaration
            return measured
        }
    }

    private static func renderSource(_ candidates: [Candidate]) -> String {
        let imports = Set(candidates.map(\.moduleName)).sorted().map { "import \($0)" }
        let declarations = candidates.enumerated().map { index, candidate in
            let isolation = candidate.requiresMainActor ? "@MainActor " : ""
            let owner = escapedPath(candidate.probeOwnerType)
            let member = escapedIdentifier(candidate.memberName)
            return "\(isolation)private func helixManagedDebugProbe\(index)() { "
                + "_ = \(owner).\(member) }"
        }
        return (imports + [""] + declarations + [""]).joined(separator: "\n")
    }

    private static func candidateLookup(_ candidates: [Candidate]) -> [String: Candidate] {
        var result: [String: Candidate] = [:]
        var ambiguous = Set<String>()
        for candidate in candidates {
            for owner in candidate.ownerAliases + [candidate.ownerType] {
                let identity = operationIdentity(
                    ownerType: owner,
                    memberName: candidate.memberName
                )
                if let existing = result[identity], existing != candidate {
                    ambiguous.insert(identity)
                } else {
                    result[identity] = candidate
                }
            }
        }
        for identity in ambiguous { result.removeValue(forKey: identity) }
        return result
    }

    private static func placeholderNativeTypes(
        _ types: [FrontendReceipt.Adapter.ImportedNativeType]
    ) -> [String: Core.TypeID] {
        let placeholder = Core.TypeID(rawValue: .sha256("managed-debug-type-probe"))
        var result: [String: Core.TypeID] = [:]
        for type in types {
            for name in Set(
                [type.canonicalName, type.swiftType, "__C.\(type.canonicalName)"]
                    + type.aliases
            ) {
                result[name] = placeholder
            }
        }
        return result
    }

    private static func operationIdentity(
        ownerType: String,
        memberName: String
    ) -> String {
        normalizedTypeName(ownerType, moduleName: nil) + "|" + memberName
    }

    private static func normalizedTypeName(
        _ raw: String,
        moduleName: String?
    ) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("?") { value.removeLast() }
        if value.hasPrefix("__C.") { value.removeFirst("__C.".count) }
        if let moduleName, value.hasPrefix("\(moduleName).") {
            value.removeFirst(moduleName.count + 1)
        }
        if let generic = value.firstIndex(of: "<") {
            value = String(value[..<generic])
        }
        return value
    }

    private static func objectiveCRuntimeName(_ preciseIdentifier: String) -> String? {
        for marker in ["c:objc(cs)", "c:objc(pl)"]
        where preciseIdentifier.hasPrefix(marker) {
            let name = String(preciseIdentifier.dropFirst(marker.count))
            return isProbeIdentifier(name) ? name : nil
        }
        return nil
    }

    private static func requiresMainActor(
        _ symbol: SwiftFrontend.SymbolGraph.Symbol
    ) -> Bool {
        symbol.declarationFragments.contains {
            $0.preciseIdentifier == "s:ScM" && $0.spelling == "MainActor"
        }
    }

    private static func isAvailable(
        _ symbol: SwiftFrontend.SymbolGraph.Symbol,
        minimumOS: Core.SemanticVersion
    ) -> Bool {
        let values = symbol.availability ?? []
        if values.contains(where: {
            $0.domain == "Swift" && $0.isUnconditionallyUnavailable == true
        }) {
            return false
        }
        guard let ios = values.first(where: { $0.domain == "iOS" }) else {
            return true
        }
        guard ios.isUnconditionallyUnavailable != true else { return false }
        let required = (
            Int(minimumOS.major), Int(minimumOS.minor), Int(minimumOS.patch)
        )
        if let introduced = ios.introduced,
           (introduced.major, introduced.minor, introduced.patch) > required {
            return false
        }
        if let obsoleted = ios.obsoleted,
           (obsoleted.major, obsoleted.minor, obsoleted.patch) <= required {
            return false
        }
        return true
    }

    private static func escapedPath(_ value: String) -> String {
        value.split(separator: ".").map {
            escapedIdentifier(String($0))
        }.joined(separator: ".")
    }

    private static func escapedIdentifier(_ value: String) -> String {
        "`\(value)`"
    }

    private static func isProbeIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 512
            && FrontendReceipt.Adapter.isSwiftIdentifier(value)
    }

    private static func candidateOrdering(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        (lhs.moduleName, lhs.ownerType, lhs.memberName, lhs.sourceFileLogicalID)
            < (rhs.moduleName, rhs.ownerType, rhs.memberName, rhs.sourceFileLogicalID)
    }
}
