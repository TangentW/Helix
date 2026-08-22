import Foundation
import HelixBytecode
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
        var members: [SwiftFrontend.SymbolGraph.Symbol]
    }

    private struct OwnerMatch: Sendable {
        var score: Int
        var surface: OwnerSurface
    }

    private struct Candidate: Hashable, Sendable {
        var preciseIdentifier: String
        var moduleName: String
        var probeOwnerType: String
        var ownerType: String
        var dispatch: NativeImportDiscovery.Dispatch
        var memberName: String
        var argumentLabels: [String]
        var parameterTypes: [String]
        var sourceFileLogicalID: String
        var importedModules: [String]
        var requiresMainActor: Bool
        var mayThrow: Bool
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
            discoveredTypes: [],
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
            "swift.class", "swift.enum", "swift.struct", "swift.typealias",
        ]
        let memberKinds: Set<String> = [
            "swift.init", "swift.method", "swift.property",
            "swift.type.method", "swift.type.property",
        ]
        var owners: [String: SwiftFrontend.SymbolGraph.Symbol] = [:]
        var ambiguousOwners = Set<String>()
        for symbol in graph.symbols {
            guard typeKinds.contains(symbol.kind.identifier),
                  !symbol.pathComponents.isEmpty,
                  symbol.pathComponents.allSatisfy(isProbeIdentifier),
                  !symbol.declarationFragments.contains(where: {
                      $0.kind == "genericParameter"
                  }),
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
        var membersByOwner: [String: [SwiftFrontend.SymbolGraph.Symbol]] = [:]
        for symbol in graph.symbols where memberKinds.contains(symbol.kind.identifier) {
            guard symbol.accessLevel == "public" || symbol.accessLevel == "open",
                  let owner = memberOwner[symbol.identifier.precise],
                  owners[owner] != nil,
                  symbol.pathComponents.count >= 2,
                  isAvailable(symbol, minimumOS: minimumOS),
                  !symbol.declarationFragments.contains(where: {
                      $0.spelling == "async"
                  })
            else { continue }
            membersByOwner[owner, default: []].append(symbol)
        }
        return owners.keys.sorted().compactMap { precise -> OwnerSurface? in
            guard let owner = owners[precise],
                  let members = membersByOwner[precise],
                  !members.isEmpty
            else { return nil }
            return OwnerSurface(
                moduleName: graph.module.name,
                preciseIdentifier: precise,
                swiftPath: owner.pathComponents.joined(separator: "."),
                runtimeName: objectiveCRuntimeName(precise),
                requiresMainActor: requiresMainActor(owner),
                members: members.sorted {
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
        surface.members.flatMap { member in
            makeCandidates(
                member: member,
                surface: surface,
                importedType: importedType
            )
        }
    }

    private static func makeCandidates(
        member: SwiftFrontend.SymbolGraph.Symbol,
        surface: OwnerSurface,
        importedType: FrontendReceipt.Adapter.ImportedNativeType
    ) -> [Candidate] {
        let isNonisolated = member.declarationFragments.contains {
            $0.spelling == "nonisolated"
        }
        let requiresActor = !isNonisolated && (
            surface.requiresMainActor || requiresMainActor(member)
        )
        func candidate(
            dispatch: NativeImportDiscovery.Dispatch,
            memberName: String,
            labels: [String] = [],
            parameterTypes: [String] = [],
            mayThrow: Bool = false
        ) -> Candidate {
            Candidate(
                preciseIdentifier: member.identifier.precise,
                moduleName: surface.moduleName,
                probeOwnerType: surface.swiftPath,
                ownerType: importedType.swiftType,
                dispatch: dispatch,
                memberName: memberName,
                argumentLabels: labels,
                parameterTypes: parameterTypes,
                sourceFileLogicalID: importedType.sourceFileLogicalID,
                importedModules: importedType.importedModules,
                requiresMainActor: requiresActor,
                mayThrow: mayThrow
            )
        }

        switch member.kind.identifier {
        case "swift.type.property", "swift.property":
            guard let memberName = member.pathComponents.last,
                  isProbeIdentifier(memberName),
                  !member.declarationFragments.contains(where: {
                      $0.spelling == "async" || $0.spelling == "throws"
                          || $0.spelling == "rethrows"
                  }),
                  let type = propertyType(member),
                  FrontendReceipt.SwiftTypeSpelling.isGeneratedType(type)
            else { return [] }
            let isStatic = member.kind.identifier == "swift.type.property"
            var values = [candidate(
                dispatch: isStatic ? .staticGetter : .instanceGetter,
                memberName: memberName
            )]
            if member.declarationFragments.contains(where: {
                $0.kind == "keyword" && $0.spelling == "set"
            }) {
                let setter: NativeImportDiscovery.Dispatch
                if isStatic {
                    setter = .staticSetter
                } else {
                    setter = importedType.representation == .reference
                        ? .instanceSetter : .instanceValueSetter
                }
                values.append(candidate(
                    dispatch: setter,
                    memberName: memberName,
                    labels: ["_"],
                    parameterTypes: [type]
                ))
            }
            return values
        case "swift.init", "swift.method", "swift.type.method":
            guard !member.declarationFragments.contains(where: {
                $0.kind == "genericParameter"
                    || $0.spelling == "mutating"
                    || $0.spelling == "consuming"
            }), let signature = callableSignature(member)
            else { return [] }
            let dispatch: NativeImportDiscovery.Dispatch = switch member.kind.identifier {
            case "swift.init": .initializer
            case "swift.type.method": .staticMethod
            default: .instanceMethod
            }
            return [candidate(
                dispatch: dispatch,
                memberName: dispatch == .initializer ? "init" : signature.baseName,
                labels: signature.argumentLabels,
                parameterTypes: signature.parameterTypes,
                mayThrow: signature.mayThrow
            )]
        default:
            return []
        }
    }

    private struct CallableSignature {
        var baseName: String
        var argumentLabels: [String]
        var parameterTypes: [String]
        var mayThrow: Bool
    }

    private static func callableSignature(
        _ symbol: SwiftFrontend.SymbolGraph.Symbol
    ) -> CallableSignature? {
        let declaration = symbol.declarationFragments.map(\.spelling).joined()
        let compactDeclaration = declaration.filter { !$0.isWhitespace }
        guard !compactDeclaration.contains("throws("),
              !compactDeclaration.contains("init?(") && !compactDeclaration.contains("init!("),
              !symbol.declarationFragments.contains(where: {
                  $0.kind == "genericParameter" || $0.spelling == "async"
              })
        else { return nil }
        let labels = symbol.declarationFragments.compactMap { fragment in
            fragment.kind == "externalParam" ? fragment.spelling : nil
        }
        let parameters = symbol.functionSignature?.parameters ?? []
        guard labels.count == parameters.count,
              labels.allSatisfy({ $0 == "_" || isProbeIdentifier($0) }),
              parameters.count <= 16
        else { return nil }
        let parameterTypes = parameters.compactMap(parameterType)
        guard parameterTypes.count == parameters.count else { return nil }
        let baseName: String
        if symbol.kind.identifier == "swift.init" {
            baseName = "init"
        } else {
            guard let name = symbol.declarationFragments.first(where: {
                $0.kind == "identifier"
            })?.spelling, isProbeIdentifier(name)
            else { return nil }
            baseName = name
        }
        return .init(
            baseName: baseName,
            argumentLabels: labels,
            parameterTypes: parameterTypes,
            mayThrow: symbol.declarationFragments.contains(where: {
                $0.kind == "keyword"
                    && ($0.spelling == "throws" || $0.spelling == "rethrows")
            })
        )
    }

    private static func parameterType(
        _ parameter: SwiftFrontend.SymbolGraph.Parameter
    ) -> String? {
        let value = parameter.declarationFragments.map(\.spelling).joined()
        guard let separator = value.firstIndex(of: ":") else { return nil }
        let type = value[value.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard type.utf8.count <= 16 * 1_024,
              FrontendReceipt.SwiftTypeSpelling.isGeneratedType(type),
              type != "Self", !type.hasPrefix("Self.")
        else { return nil }
        return type
    }

    private static func propertyType(
        _ symbol: SwiftFrontend.SymbolGraph.Symbol
    ) -> String? {
        let value = symbol.declarationFragments.map(\.spelling).joined()
        guard let separator = value.firstIndex(of: ":") else { return nil }
        let remainder = value[value.index(after: separator)...]
        let end = remainder.range(of: " {")?.lowerBound ?? remainder.endIndex
        let type = remainder[..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return type.isEmpty ? nil : type
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
        let resolver = FrontendReceipt.SILFunctionResolver(file: silFile)
        var candidatesByWitness: [String: Candidate] = [:]
        var ambiguousWitnesses = Set<String>()
        let measuredDocuments = try documents.compactMap { document ->
            FrontendReceipt.TypedAST.Object? in
            guard let items = document["items"] as? [Any] else { return nil }
            var measuredItems: [Any] = []
            for value in items {
                guard let item = value as? [String: Any],
                      item["_kind"] as? String == "func_decl",
                      let usr = item["usr"] as? String,
                      usr.hasPrefix("s:")
                else {
                    measuredItems.append(value)
                    continue
                }
                guard let function = try resolver.function(
                    for: item,
                    source: state,
                    baseName: FrontendReceipt.Adapter().baseName(in: item)
                ) else {
                    // The compiler may eliminate an unreferenced private probe.
                    continue
                }
                measuredItems.append(value)
                guard let name = FrontendReceipt.Adapter().baseName(in: item),
                      name.hasPrefix("helixManagedDebugProbe"),
                      let index = Int(name.dropFirst("helixManagedDebugProbe".count)),
                      candidates.indices.contains(index)
                else { continue }
                let candidate = candidates[index]
                if let existing = candidatesByWitness[function.mangledName],
                   existing != candidate {
                    ambiguousWitnesses.insert(function.mangledName)
                } else {
                    candidatesByWitness[function.mangledName] = candidate
                }
            }
            var filtered = document
            filtered["items"] = measuredItems
            return filtered
        }
        for witness in ambiguousWitnesses {
            candidatesByWitness.removeValue(forKey: witness)
        }
        let surface = try FrontendReceipt.Adapter().discoverImportedOperationSurface(
            documents: measuredDocuments,
            sourcesByPhysicalPath: [
                sourceURL.resolvingSymlinksInPath().standardizedFileURL.path: state,
            ],
            moduleName: invocation.moduleName,
            demangled: demangled,
            silFile: silFile
        )
        let nativeTypes = placeholderNativeTypes(importedTypes)
        let swiftAliases = try FrontendReceipt.Adapter()
            .makeImportedSwiftTypeAliases(importedTypes)
        return surface.operations.compactMap {
            operation -> FrontendReceipt.Adapter.ImportedOperation? in
            let matching = Set(operation.witnessFunctions.compactMap {
                candidatesByWitness[$0]
            })
            guard matching.count == 1,
                  let candidate = matching.first,
                  operation.dispatch == candidate.dispatch,
                  operation.baseName == candidate.memberName,
                  operation.argumentLabels == candidate.argumentLabels,
                  operation.mayThrow == candidate.mayThrow
            else { return nil }
            var measured = operation
            measured.ownerType = candidate.ownerType
            measured.parameterSwiftTypes = operation.parameterSwiftTypes.map {
                FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                    in: $0,
                    aliases: swiftAliases
                )
            }
            for index in candidate.parameterTypes.indices
            where measured.parameterSwiftTypes.indices.contains(index) {
                let formal = FrontendReceipt.SwiftTypeSpelling
                    .replacingNominalAliases(
                        in: candidate.parameterTypes[index],
                        aliases: swiftAliases
                    )
                if let boundary = FrontendReceipt.FunctionTypeSpelling
                    .callbackBoundary(in: formal) {
                    measured.parameterSwiftTypes[index] = boundary.declaredSpelling
                }
            }
            measured.resultSwiftType = FrontendReceipt.SwiftTypeSpelling
                .replacingNominalAliases(
                    in: operation.resultSwiftType,
                    aliases: swiftAliases
                )
            let parameters = measured.parameterSwiftTypes.compactMap {
                FrontendReceipt.ValueTypeParser.parse(
                    $0,
                    allowVoid: false,
                    nativeTypes: nativeTypes
                )
            }
            guard parameters.count == measured.parameterSwiftTypes.count,
                  FrontendReceipt.NativeBridgeProfile.callbacks(
                      parameterSpellings: measured.parameterSwiftTypes,
                      parameterTypes: parameters
                  ) != nil,
                  let result = FrontendReceipt.ValueTypeParser.parse(
                      measured.resultSwiftType,
                      allowVoid: true,
                      nativeTypes: nativeTypes
                  ),
                  FrontendReceipt.NativeBridgeProfile.isResult(result)
            else { return nil }
            measured.sourceFileLogicalID = candidate.sourceFileLogicalID
            measured.importedModules = candidate.importedModules
            // Isolation belongs to the imported declaration. A nonisolated
            // member may accept or return an actor-isolated nominal value
            // without making the call itself actor-isolated.
            measured.requiresMainActor = candidate.requiresMainActor
            measured.isolationEvidence = .importedDeclaration
            return measured
        }
    }

    private static func renderSource(_ candidates: [Candidate]) -> String {
        let imports = Set(candidates.map(\.moduleName)).sorted().map { "import \($0)" }
        let declarations = candidates.enumerated().map { index, candidate in
            renderProbe(index: index, candidate: candidate)
        }
        return (imports + [""] + declarations + [""]).joined(separator: "\n")
    }

    private static func renderProbe(index: Int, candidate: Candidate) -> String {
        let isolation = candidate.requiresMainActor ? "@MainActor " : ""
        let throwing = candidate.mayThrow ? " throws" : ""
        let tryPrefix = candidate.mayThrow ? "try " : ""
        let owner = escapedPath(candidate.probeOwnerType)
        let member = escapedIdentifier(candidate.memberName)
        var parameters: [String] = []
        if isInstanceDispatch(candidate.dispatch) {
            parameters.append("_ receiver: \(owner)")
        }
        parameters += candidate.parameterTypes.enumerated().map {
            "_ argument\($0.offset): \($0.element)"
        }
        let arguments = zip(
            candidate.argumentLabels,
            candidate.parameterTypes.indices
        ).map { label, offset in
            label == "_" ? "argument\(offset)" : "\(escapedIdentifier(label)): argument\(offset)"
        }.joined(separator: ", ")
        let call: String = switch candidate.dispatch {
        case .initializer:
            "\(owner)(\(arguments))"
        case .staticMethod:
            "\(owner).\(member)(\(arguments))"
        case .instanceMethod:
            "receiver.\(member)(\(arguments))"
        case .staticGetter:
            "\(owner).\(member)"
        case .staticSetter:
            "\(owner).\(member) = argument0"
        case .instanceGetter:
            "receiver.\(member)"
        case .instanceSetter:
            "receiver.\(member) = argument0"
        case .instanceValueSetter:
            "mutableReceiver.\(member) = argument0"
        case .globalFunction, .nativeUpcast, .anyObjectBridge:
            preconditionFailure("managed member probe has invalid dispatch")
        }
        let mutableReceiver = candidate.dispatch == .instanceValueSetter
            ? "\n    var mutableReceiver = receiver" : ""
        return "\(isolation)private func helixManagedDebugProbe\(index)("
            + "\(parameters.joined(separator: ", ")))\(throwing) {"
            + "\(mutableReceiver)\n    _ = \(tryPrefix)\(call)\n}"
    }

    private static func isInstanceDispatch(
        _ dispatch: NativeImportDiscovery.Dispatch
    ) -> Bool {
        switch dispatch {
        case .instanceMethod, .instanceGetter, .instanceSetter,
             .instanceValueSetter: true
        case .globalFunction, .initializer, .staticMethod, .nativeUpcast,
             .anyObjectBridge,
             .staticGetter, .staticSetter: false
        }
    }

    private static func placeholderNativeTypes(
        _ types: [FrontendReceipt.Adapter.ImportedNativeType]
    ) -> [String: Core.TypeID] {
        var result: [String: Core.TypeID] = [:]
        for type in types {
            let placeholder = Core.TypeID(rawValue: .sha256(
                "managed-debug-type-probe:\(type.canonicalName)"
            ))
            for name in Set(
                [type.canonicalName, type.swiftType, "__C.\(type.canonicalName)"]
                    + type.aliases
            ) {
                result[name] = placeholder
            }
        }
        return result
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
        let left = [
            lhs.moduleName, lhs.ownerType, lhs.dispatch.rawValue, lhs.memberName,
            lhs.argumentLabels.joined(separator: ":"),
            lhs.parameterTypes.joined(separator: ","), lhs.preciseIdentifier,
            lhs.sourceFileLogicalID,
        ]
        let right = [
            rhs.moduleName, rhs.ownerType, rhs.dispatch.rawValue, rhs.memberName,
            rhs.argumentLabels.joined(separator: ":"),
            rhs.parameterTypes.joined(separator: ","), rhs.preciseIdentifier,
            rhs.sourceFileLogicalID,
        ]
        return left.lexicographicallyPrecedes(right)
    }
}
