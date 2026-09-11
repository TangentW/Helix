import Foundation
import HelixCore
import HelixInterface

extension FrontendReceipt.Adapter {
    enum ImportedIsolationEvidence: String, Codable, Hashable, Sendable {
        /// The declaration was unavailable, so isolation is conservatively
        /// inherited from the source context that mentioned the value.
        case enclosingContext
        /// The imported declaration or nominal was measured directly.
        case importedDeclaration
    }

    struct ImportedNativeType: Codable, Hashable, Sendable {
        enum Representation: String, Codable, Hashable, Sendable {
            case reference
            case rawRepresentable
            case opaqueValue
        }

        enum RepresentationEvidence: String, Codable, Hashable, Sendable {
            case nominal
            /// Clang typedef mangling preserves identity but erases its layout.
            case clangTypealias
        }

        var canonicalName: String
        var swiftType: String
        var kind: InterfaceArchive.TypeKind
        var aliases: [String]
        var representation: Representation
        var representationEvidence: RepresentationEvidence = .nominal
        var sourceFileLogicalID: String
        var importedModules: [String]
        /// External module that owns reusable compiler-visible TypeOps. Nil
        /// means the type is rooted in the application source boundary.
        var nativeModuleName: String? = nil
        /// Exact declaring module recovered from that module's Symbol Graph.
        /// Nil means source-only discovery could not prove provenance.
        var objectiveCModuleName: String? = nil
        /// Exact Objective-C runtime class identity proven by Clang import or
        /// the declaring module's Symbol Graph. Nil for Swift-only references,
        /// protocol existentials, and value overlays.
        var objectiveCRuntimeName: String? = nil
        var requiresMainActor: Bool
        var isolationEvidence: ImportedIsolationEvidence = .enclosingContext
        /// An in-memory diagnostic example, never a persisted identity input.
        var sourceLocation: Core.SourceLocation? = nil

        private enum CodingKeys: String, CodingKey {
            case canonicalName, swiftType, kind, aliases, representation
            case representationEvidence
            case sourceFileLogicalID, importedModules, nativeModuleName
            case objectiveCModuleName, objectiveCRuntimeName
            case requiresMainActor, isolationEvidence
        }
    }
    func discoverImportedNativeTypes(
        documents: [FrontendReceipt.TypedAST.Object],
        sourcesByPhysicalPath: [String: SourceState],
        moduleName: String,
        demangled: [String: String]
    ) throws -> [ImportedNativeType] {
        var uses: [ImportedNativeType] = []

        for document in documents {
            guard let filename = document["filename"] as? String,
                  let source = sourcesByPhysicalPath[
                      URL(fileURLWithPath: filename)
                        .resolvingSymlinksInPath().standardizedFileURL.path
                  ]
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "imported reference discovery source does not map to the requested source set"
                )
            }
            let items = try FrontendReceipt.TypedAST.items(in: document)
            let modules = imports(in: items).filter { $0 != moduleName }
            guard !modules.isEmpty else { continue }
            uses += sourceOverlayTypes(
                in: items,
                source: source,
                importedModules: modules,
                demangled: demangled
            )
            collectImportedNativeTypes(
                root: items,
                inheritedMainActor: false,
                source: source,
                importedModules: modules,
                demangled: demangled,
                uses: &uses
            )
        }
        return try mergeImportedNativeTypes(
            discoveredTypes: [],
            operationTypes: uses
        )
    }

    private func collectImportedNativeTypes(
        root: Any,
        inheritedMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        demangled: [String: String],
        uses: inout [ImportedNativeType]
    ) {
        var pending: [(value: Any, requiresMainActor: Bool)] = [
            (root, inheritedMainActor),
        ]
        while let next = pending.popLast() {
            if let values = next.value as? [Any] {
                pending.append(contentsOf: values.reversed().map {
                    ($0, next.requiresMainActor)
                })
                continue
            }
            guard let item = next.value as? [String: Any] else { continue }
            if item["implicit"] as? Bool == true,
               let kind = item["_kind"] as? String,
               Self.implicitDeclarationContexts.contains(kind) {
                // Synthesized declarations inherit framework signatures from
                // a superclass without making those types part of the
                // source-authored patch boundary.
                continue
            }
            let requiresMainActor = next.requiresMainActor
                || itemRequiresMainActor(item, demangled: demangled)

            func record(_ rawType: Any?) {
                guard let mangled = rawType as? String else { return }
                let firstUse = uses.count
                defer {
                    var location = sourceRange(in: item).flatMap {
                        source.sourceLocation(atUTF8Offset: $0.start)
                    }
                    location?.file = source.logicalPath
                    for index in firstUse..<uses.count {
                        uses[index].sourceLocation = location
                    }
                }
                let spelling = demangled[mangled].map(
                    normalizeImportedTypeSpelling
                )
                let unavailableGenericBase: String?
                if let spelling, let open = spelling.firstIndex(of: "<") {
                    unavailableGenericBase = spelling[..<open]
                        .split(separator: ".").last.map(String.init)
                } else {
                    unavailableGenericBase = nil
                }
                for runtimeName in Self.objectiveCClassNames(
                    inMangledType: mangled
                ) where runtimeName != unavailableGenericBase {
                    uses.append(
                        importedType(
                            canonicalName: runtimeName,
                            swiftType: runtimeName,
                            kind: .reference,
                            representation: .reference,
                            source: source,
                            importedModules: importedModules,
                            objectiveCRuntimeName: runtimeName,
                            requiresMainActor: requiresMainActor
                        )
                    )
                }
                uses += importedClangTypealiasTypes(
                    inMangledType: mangled,
                    source: source,
                    importedModules: importedModules
                )
                guard let spelling,
                      isImportedMangledType(
                          mangled,
                          importedModules: importedModules
                      ),
                      let type = importedNativeType(
                          rawMangledType: mangled,
                          spelling: spelling,
                          source: source,
                          importedModules: importedModules,
                          requiresMainActor: requiresMainActor
                      )
                else { return }
                uses.append(type)
            }

            switch item["_kind"] as? String {
            case "parameter":
                record(item["interface_type"])
            case "var_decl" where item["readImpl"] as? String == "stored":
                record(item["interface_type"])
            case "func_decl":
                record(item["result"])
            default:
                break
            }

            for child in item.values {
                if child is [Any] || child is [String: Any] {
                    pending.append((child, requiresMainActor))
                }
            }
        }
    }

    private static let implicitDeclarationContexts: Set<String> = [
        "constructor_decl", "destructor_decl",
    ]

    func importedNativeType(
        rawMangledType: Any?,
        spelling: String,
        source: SourceState,
        importedModules: [String],
        requiresMainActor: Bool
    ) -> ImportedNativeType? {
        guard let discovered = importedNativeNominal(in: spelling),
              let mangled = rawMangledType as? String
        else { return nil }
        let importedTypealiases = Self.objectiveCTypealiasNames(
            inMangledType: mangled
        )
        let clangTypealias = importedTypealiases.count == 1
            && isImportedClangTypealias(mangled)
            ? importedTypealiases.first : nil
        let swiftType = isSelectorType(discovered)
            ? "ObjectiveC.Selector" : discovered
        let objectiveCRuntimeName = Self.objectiveCNominalIdentity(
            inMangledType: mangled
        )
        let canonical = objectiveCRuntimeName ?? clangTypealias ?? swiftType
        guard let representation = importedNominalRepresentation(
            mangled,
            spelling: swiftType
        ) else { return nil }
        let kind: InterfaceArchive.TypeKind = representation == .reference
            ? .reference : .value
        return importedType(
            canonicalName: canonical,
            swiftType: swiftType,
            kind: kind,
            aliases: clangTypealias.map { ["__C.\($0)"] } ?? [],
            representation: representation,
            representationEvidence: clangTypealias == nil ? .nominal : .clangTypealias,
            source: source,
            importedModules: importedModules,
            objectiveCRuntimeName: representation == .reference
                ? objectiveCRuntimeName : nil,
            requiresMainActor: representation == .reference && requiresMainActor
        )
    }

    /// Uses the ABI identity rather than an often-aliased source spelling to
    /// recognize nested Swift framework types such as `Notification.Name`.
    func isImportedMangledType(
        _ mangled: String,
        importedModules: [String]
    ) -> Bool {
        if mangled.hasPrefix("$sSo") { return true }
        return importedModules.contains { module in
            mangled.hasPrefix("$s\(module.utf8.count)\(module)")
        }
    }

    func importedNominalRepresentation(
        _ rawMangledType: String,
        spelling: String
    ) -> ImportedNativeType.Representation? {
        var value = rawMangledType
        guard value.hasPrefix("$s"), value.hasSuffix("D") else { return nil }
        value.removeLast()
        while value.hasSuffix("Sg") { value.removeLast(2) }
        switch value.last {
        case "C": return .reference
        case "V", "O": return .opaqueValue
        case "a" where rawMangledType.hasPrefix("$sSo"):
            // Imported Clang typedefs erase their underlying Swift layout in
            // the mangling. Box the declared alias opaquely instead of guessing
            // whether its C representation was a pointer or scalar.
            return .opaqueValue
        case "G" where rawMangledType.hasPrefix("$sSo") && spelling.contains("<"):
            return .reference
        default: return nil
        }
    }

    func isImportedClangTypealias(_ rawMangledType: String) -> Bool {
        var value = rawMangledType
        guard value.hasPrefix("$s"), value.hasSuffix("D") else { return false }
        value.removeLast()
        while value.hasSuffix("Sg") { value.removeLast(2) }
        return value.hasSuffix("a")
            && Self.objectiveCNominalIdentity(inMangledType: rawMangledType) != nil
    }

    func importedNativeNominal(in raw: String) -> String? {
        guard FrontendReceipt.ImportedNominalIdentity.isConcreteSpelling(raw) else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("?") { value.removeLast() }
        for prefix in ["Swift.Optional<", "Optional<"]
        where value.hasPrefix(prefix) && value.hasSuffix(">") {
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            return importedNativeNominal(
                in: String(value[start..<value.index(before: value.endIndex)])
            )
        }
        if value.hasPrefix("["), value.hasSuffix("]")
            || value.hasPrefix("Swift.Array<") || value.hasPrefix("Array<")
            || value.hasPrefix("Swift.Dictionary<") || value.hasPrefix("Dictionary<") {
            return nil
        }
        guard FrontendReceipt.ValueTypeParser.parse(
            value,
            allowVoid: true
        ) == nil,
              !value.contains(" -> "),
              !value.isEmpty
        else { return nil }
        return value
    }

    func normalizeImportedTypeSpelling(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("(extension in "),
              let separator = value.range(of: "):") {
            value = String(value[separator.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.replacingOccurrences(of: "__C.", with: "")
    }

    func importedType(
        canonicalName: String,
        swiftType: String,
        kind: InterfaceArchive.TypeKind,
        aliases: [String] = [],
        representation: ImportedNativeType.Representation,
        representationEvidence: ImportedNativeType.RepresentationEvidence = .nominal,
        source: SourceState,
        importedModules: [String],
        objectiveCRuntimeName: String? = nil,
        requiresMainActor: Bool
    ) -> ImportedNativeType {
        .init(
            canonicalName: canonicalName,
            swiftType: swiftType,
            kind: kind,
            aliases: aliases,
            representation: representation,
            representationEvidence: representationEvidence,
            sourceFileLogicalID: source.logicalPath,
            importedModules: importedModules,
            objectiveCRuntimeName: objectiveCRuntimeName,
            requiresMainActor: requiresMainActor
        )
    }

    func itemRequiresMainActor(
        _ item: [String: Any],
        demangled: [String: String]
    ) -> Bool {
        let attributes = item["attrs"] as? [[String: Any]] ?? []
        return attributes.contains { attribute in
            guard attribute["_kind"] as? String == "custom_attr",
                  let type = attribute["type"] as? String,
                  let value = demangled[type],
                  let name = Self.customAttributeName(value)
            else { return false }
            return Self.isMainActor(name)
        }
    }

    func mergeImportedNativeTypes(
        discoveredTypes: [ImportedNativeType],
        operationTypes: [ImportedNativeType]
    ) throws -> [ImportedNativeType] {
        let uses = try normalizeImportedNominalIdentities(
            normalizeExplicitAliasIdentities(
                normalizeClangTypealiasIdentities(
                    normalizeCatalogAliasIdentities(
                        concreteImportedNominalUses(discoveredTypes + operationTypes)
                    )
                )
            )
        )
        var result: [String: ImportedNativeType] = [:]
        for originalUse in uses.sorted(by: {
            ($0.canonicalName, $0.sourceFileLogicalID)
                < ($1.canonicalName, $1.sourceFileLogicalID)
        }) {
            var use = originalUse
            if use.canonicalName == "Swift.AnyObject" {
                // AnyObject is a class existential, not an actor-isolated
                // nominal type. Concrete UIKit references retain their own
                // MainActor identity until an explicit erasure operation.
                use.requiresMainActor = false
                use.isolationEvidence = .importedDeclaration
            }
            guard !use.canonicalName.isEmpty,
                  !use.swiftType.isEmpty,
                  !use.importedModules.isEmpty,
                  use.objectiveCRuntimeName.map(
                      Core.NativeCall.isCanonicalObjectiveCRuntimeClassName
                  ) ?? true,
                  use.objectiveCRuntimeName == nil || use.kind == .reference
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "imported native type metadata is incomplete for "
                        + "\(use.canonicalName) (Swift: \(use.swiftType), "
                        + "kind: \(use.kind.rawValue), modules: "
                        + "\(use.importedModules.joined(separator: ",")), "
                        + "Objective-C runtime: "
                        + "\(use.objectiveCRuntimeName ?? "none"))"
                )
            }
            if var existing = result[use.canonicalName] {
                if isLogicalValueBridge(existing, for: use) {
                    var exactReference = use
                    exactReference.importedModules = Array(Set(
                        existing.importedModules + use.importedModules
                    )).sorted()
                    result[use.canonicalName] = exactReference
                    continue
                }
                if isLogicalValueBridge(use, for: existing) {
                    existing.importedModules = Array(Set(
                        existing.importedModules + use.importedModules
                    )).sorted()
                    result[use.canonicalName] = existing
                    continue
                }
                if existing.swiftType != use.swiftType {
                    if existing.swiftType == use.canonicalName {
                        existing.aliases.append(existing.swiftType)
                        existing.swiftType = use.swiftType
                    } else if use.swiftType == use.canonicalName {
                        existing.aliases.append(use.swiftType)
                    } else {
                        throw FrontendReceipt.ImportedNominalIdentity.conflict(
                            "imported native type \(use.canonicalName) has conflicting Swift spellings",
                            uses: [existing, use]
                        )
                    }
                }
                if existing.representation == .opaqueValue,
                   use.representation == .rawRepresentable {
                    existing.kind = use.kind
                    existing.representation = .rawRepresentable
                    existing.representationEvidence = use.representationEvidence
                    existing.requiresMainActor = use.requiresMainActor
                    existing.isolationEvidence = use.isolationEvidence
                } else if existing.representation == .rawRepresentable,
                          use.representation == .opaqueValue {
                    // Explicit enum/OptionSet evidence is more precise than
                    // the fallback opaque-value classification, including its
                    // actor-neutral value semantics.
                } else if existing.representation == .rawRepresentable,
                          use.representation == .rawRepresentable,
                          Set([existing.kind, use.kind]) == Set([.value, .enumeration]) {
                    // A direct enum observation refines the value fallback;
                    // it cannot turn a reference or an unrelated layout into an enum.
                    existing.kind = .enumeration
                    try mergeImportedIsolation(into: &existing, from: use)
                } else if existing.kind != use.kind
                            || existing.representation != use.representation {
                    throw FrontendReceipt.ImportedNominalIdentity.conflict(
                        "imported native type \(use.canonicalName) has conflicting "
                            + "representations",
                        uses: [existing, use]
                    )
                } else {
                    try mergeImportedIsolation(into: &existing, from: use)
                }
                if use.representationEvidence == .nominal {
                    existing.representationEvidence = .nominal
                }
                existing.importedModules = Array(Set(
                    existing.importedModules + use.importedModules
                )).sorted()
                if let existingModule = existing.objectiveCModuleName,
                   let incomingModule = use.objectiveCModuleName,
                   existingModule != incomingModule {
                    throw FrontendReceipt.ImportedNominalIdentity.conflict(
                        "imported native type \(use.canonicalName) has conflicting declaring modules",
                        uses: [existing, use]
                    )
                }
                existing.objectiveCModuleName = existing.objectiveCModuleName
                    ?? use.objectiveCModuleName
                if let existingRuntimeName = existing.objectiveCRuntimeName,
                   let incomingRuntimeName = use.objectiveCRuntimeName,
                   existingRuntimeName != incomingRuntimeName {
                    throw FrontendReceipt.ImportedNominalIdentity.conflict(
                        "imported native type \(use.canonicalName) has conflicting "
                            + "Objective-C runtime identities",
                        uses: [existing, use]
                    )
                }
                existing.objectiveCRuntimeName = existing.objectiveCRuntimeName
                    ?? use.objectiveCRuntimeName
                existing.aliases = Array(Set(
                    existing.aliases + use.aliases
                )).sorted()
                mergeImportedOrigin(into: &existing, from: use)
                result[use.canonicalName] = existing
            } else {
                var canonical = use
                canonical.importedModules = Array(Set(use.importedModules)).sorted()
                canonical.aliases = Array(Set(use.aliases)).sorted()
                result[use.canonicalName] = canonical
            }
        }
        let preciseAliases = Set(result.values
            .filter { $0.representation == .rawRepresentable }
            .flatMap(\.aliases))
        return result.values.filter {
            !($0.representation == .opaqueValue
                && preciseAliases.contains($0.canonicalName))
        }.map { value in
            var value = value
            // Compiler bridges such as String/NSString and Double/CGFloat
            // prove conversion, not nominal identity. Keeping the VM-owned
            // side as a native alias would later rewrite every logical use to
            // the physical bridge representation.
            value.aliases.removeAll {
                FrontendReceipt.ValueTypeParser.isBuiltinValueSpelling($0)
            }
            return value
        }.sorted { $0.canonicalName < $1.canonicalName }
    }

    private func concreteImportedNominalUses(_ uses: [ImportedNativeType]) throws -> [ImportedNativeType] {
        try uses.compactMap { original in
            // A stale/intermediate generic spelling must not enter alias or
            // canonical-name groups. Preserve independently proven Clang ABI
            // evidence, including contradictory runtime facts for validation.
            var use = original
            if let runtime = use.objectiveCRuntimeName {
                guard Core.NativeCall.isCanonicalObjectiveCRuntimeClassName(runtime), use.kind == .reference else {
                    throw FrontendReceipt.ImportedNominalIdentity.conflict(
                        "invalid Objective-C runtime evidence before generic-spelling filtering", uses: [use])
                }
            }
            if !FrontendReceipt.ImportedNominalIdentity.isConcreteSpelling(use.swiftType) {
                guard let runtime = use.objectiveCRuntimeName,
                      use.kind == .reference, use.representation == .reference else { return nil }
                use.swiftType = runtime
            }
            if !FrontendReceipt.ImportedNominalIdentity.isConcreteSpelling(use.canonicalName) {
                guard let runtime = use.objectiveCRuntimeName else { return nil }
                use.canonicalName = runtime
            }
            use.aliases.removeAll { !FrontendReceipt.ImportedNominalIdentity.isConcreteSpelling($0) }
            return use
        }
    }

    /// A module Catalog sees a nominal in its declaring compiler context and
    /// therefore normally publishes more aliases than a consumer AST. Let one
    /// unique Catalog superset canonicalize the weaker source observation;
    /// never infer identity from a short alias shared by multiple nominals.
    private func normalizeCatalogAliasIdentities(
        _ uses: [ImportedNativeType]
    ) -> [ImportedNativeType] {
        let authorities = uses.filter { $0.nativeModuleName != nil }
        guard !authorities.isEmpty else { return uses }

        func names(of type: ImportedNativeType) -> Set<String> {
            Set([type.canonicalName, type.swiftType] + type.aliases)
        }

        let authorityNames = authorities.map(names)
        var authoritiesByName: [String: [Int]] = [:]
        for index in authorities.indices {
            for name in authorityNames[index] {
                authoritiesByName[name, default: []].append(index)
            }
        }

        func hasCompatibleValueRepresentation(
            _ lhs: ImportedNativeType,
            _ rhs: ImportedNativeType
        ) -> Bool {
            lhs.kind != .reference
                && rhs.kind != .reference
                && Set([
                    lhs.representation,
                    rhs.representation,
                ]).isSubset(of: [.opaqueValue, .rawRepresentable])
        }

        func preservesObjectiveCRuntimeSpelling(
            _ observedNames: Set<String>,
            authority: ImportedNativeType
        ) -> Bool {
            guard let runtimeName = authority.objectiveCRuntimeName else {
                return false
            }
            return observedNames.contains(runtimeName)
                || observedNames.contains("__C.\(runtimeName)")
                || authority.objectiveCModuleName.map {
                    observedNames.contains("\($0).\(runtimeName)")
                } == true
        }

        return uses.map { use in
            guard use.nativeModuleName == nil else { return use }
            let observedNames = names(of: use)
            // Every candidate must contain every observed name. Start with the
            // smallest exact-name bucket, retaining duplicate/conflicting facts.
            let anchor = observedNames.min {
                (authoritiesByName[$0]?.count ?? 0, $0) < (authoritiesByName[$1]?.count ?? 0, $1)
            }
            let candidates = (anchor.flatMap { authoritiesByName[$0] } ?? []).filter { index in
                let authority = authorities[index]
                let hasMatchingRepresentation =
                    (authority.kind == use.kind
                        && authority.representation == use.representation
                        || hasCompatibleValueRepresentation(
                            authority,
                            use
                        ))
                        && authority.objectiveCRuntimeName
                            == use.objectiveCRuntimeName
                let correctsWeakObjectiveCReference =
                    use.kind == .value
                        && use.representation == .opaqueValue
                        && use.objectiveCRuntimeName == nil
                        && authority.kind == .reference
                        && authority.representation == .reference
                        && authority.objectiveCRuntimeName != nil
                        && preservesObjectiveCRuntimeSpelling(
                            observedNames,
                            authority: authority
                        )
                // A typedef's opaque box is a layout fallback, not evidence
                // contradicting the uniquely measured declaring module. Keep
                // every observed alias and require an exact Clang alias match.
                let resolvesClangTypealiasLayout =
                    use.representationEvidence == .clangTypealias
                        && use.kind == .value && use.representation == .opaqueValue
                        && use.objectiveCRuntimeName == nil
                        && authority.representationEvidence == .nominal
                        && authority.objectiveCModuleName != nil
                        && use.aliases.contains { $0.hasPrefix("__C.") && authorityNames[index].contains($0) }
                return (hasMatchingRepresentation
                        || correctsWeakObjectiveCReference || resolvesClangTypealiasLayout)
                    && (use.objectiveCModuleName == nil
                        || authority.objectiveCModuleName
                            == use.objectiveCModuleName)
                    && authorityNames[index].isSuperset(of: observedNames)
            }
            guard candidates.count == 1, let authorityIndex = candidates.first
            else { return use }
            let authority = authorities[authorityIndex]
            var normalized = use
            normalized.canonicalName = authority.canonicalName
            normalized.swiftType = authority.swiftType
            normalized.aliases = Array(observedNames.union(authorityNames[authorityIndex]))
                .sorted()
            normalized.kind = authority.kind
            normalized.representationEvidence = authority.representationEvidence
            if !hasCompatibleValueRepresentation(use, authority) {
                normalized.representation = authority.representation
            }
            normalized.objectiveCModuleName = authority.objectiveCModuleName
            normalized.objectiveCRuntimeName = authority.objectiveCRuntimeName
            return normalized
        }
    }

    /// Coalesces compiler spellings only when both records publish the exact
    /// same complete alias universe and representation. This handles module-
    /// qualified versus relative nested names without treating a shared short
    /// alias as proof that otherwise distinct native types are identical.
    private func normalizeExplicitAliasIdentities(
        _ uses: [ImportedNativeType]
    ) -> [ImportedNativeType] {
        struct AliasIdentity: Hashable {
            var names: [String]
            var kind: InterfaceArchive.TypeKind
            var representation: ImportedNativeType.Representation
            var objectiveCModuleName: String?
            var objectiveCRuntimeName: String?
        }

        let groups = Dictionary(grouping: uses) { use in
            AliasIdentity(
                names: Array(Set(
                    [use.canonicalName, use.swiftType] + use.aliases
                )).sorted(),
                kind: use.kind,
                representation: use.representation,
                objectiveCModuleName: use.objectiveCModuleName,
                objectiveCRuntimeName: use.objectiveCRuntimeName
            )
        }
        var canonicalByIdentity: [AliasIdentity: String] = [:]
        for (identity, values) in groups {
            let canonicalNames = Set(values.map(\.canonicalName))
            guard canonicalNames.count > 1 else { continue }
            canonicalByIdentity[identity] = canonicalNames.min { lhs, rhs in
                let left = (lhs.split(separator: ".").count, lhs.count, lhs)
                let right = (rhs.split(separator: ".").count, rhs.count, rhs)
                return left < right
            }
        }
        return uses.map { use in
            let identity = AliasIdentity(
                names: Array(Set(
                    [use.canonicalName, use.swiftType] + use.aliases
                )).sorted(),
                kind: use.kind,
                representation: use.representation,
                objectiveCModuleName: use.objectiveCModuleName,
                objectiveCRuntimeName: use.objectiveCRuntimeName
            )
            guard let canonicalName = canonicalByIdentity[identity] else {
                return use
            }
            var result = use
            result.canonicalName = canonicalName
            return result
        }
    }

    /// Clang importer may expose a Swift value at the call site while SIL
    /// carries the bridged Objective-C class (for example String/NSString).
    /// That value-side record describes a conversion, not a second native
    /// nominal. Exact runtime class evidence owns TypeOps and must not inherit
    /// the logical Swift value spelling as an alias.
    private func isLogicalValueBridge(
        _ candidate: ImportedNativeType,
        for exactReference: ImportedNativeType
    ) -> Bool {
        guard candidate.kind == .value,
              candidate.representation == .opaqueValue,
              candidate.objectiveCRuntimeName == nil,
              exactReference.kind == .reference,
              exactReference.representation == .reference,
              exactReference.objectiveCRuntimeName
                == exactReference.canonicalName
        else { return false }
        return ([candidate.swiftType] + candidate.aliases).contains {
            FrontendReceipt.ValueTypeParser.parse(
                $0,
                allowVoid: false
            ) != nil
        }
    }

    private func mergeImportedIsolation(
        into existing: inout ImportedNativeType,
        from incoming: ImportedNativeType
    ) throws {
        switch (existing.isolationEvidence, incoming.isolationEvidence) {
        case (.importedDeclaration, .importedDeclaration):
            guard existing.requiresMainActor == incoming.requiresMainActor else {
                throw FrontendReceipt.ImportedNominalIdentity.conflict(
                    "imported native type \(incoming.canonicalName) has conflicting declaration isolation",
                    uses: [existing, incoming]
                )
            }
        case (.importedDeclaration, .enclosingContext):
            break
        case (.enclosingContext, .importedDeclaration):
            existing.requiresMainActor = incoming.requiresMainActor
            existing.isolationEvidence = .importedDeclaration
        case (.enclosingContext, .enclosingContext):
            existing.requiresMainActor = existing.requiresMainActor
                || incoming.requiresMainActor
        }
    }

    /// A Catalog module is a compiler context that can render TypeOps, not a
    /// distinct runtime identity for the nominal. Keep its module and logical
    /// generated-source path together, prefer any measured external origin to
    /// a consumer source mention, and choose deterministically when reexports
    /// make the same type available from more than one Catalog.
    private func mergeImportedOrigin(
        into existing: inout ImportedNativeType,
        from incoming: ImportedNativeType
    ) {
        switch (existing.nativeModuleName, incoming.nativeModuleName) {
        case (.none, .none):
            if (incoming.sourceFileLogicalID, incoming.sourceLocation?.line ?? Int.max,
                incoming.sourceLocation?.column ?? Int.max)
                < (existing.sourceFileLogicalID, existing.sourceLocation?.line ?? Int.max,
                   existing.sourceLocation?.column ?? Int.max) {
                existing.sourceFileLogicalID = incoming.sourceFileLogicalID
                existing.sourceLocation = incoming.sourceLocation
            }
        case (.none, .some):
            existing.nativeModuleName = incoming.nativeModuleName
            existing.sourceFileLogicalID = incoming.sourceFileLogicalID
            existing.sourceLocation = incoming.sourceLocation
        case (.some, .none):
            break
        case let (.some(existingModule), .some(incomingModule)):
            if (incomingModule, incoming.sourceFileLogicalID,
                incoming.sourceLocation?.line ?? Int.max, incoming.sourceLocation?.column ?? Int.max)
                < (existingModule, existing.sourceFileLogicalID,
                   existing.sourceLocation?.line ?? Int.max, existing.sourceLocation?.column ?? Int.max) {
                existing.nativeModuleName = incomingModule
                existing.sourceFileLogicalID = incoming.sourceFileLogicalID
                existing.sourceLocation = incoming.sourceLocation
            }
        }
    }

    /// Clang typedefs may surface under their ABI name in typed AST while SIL
    /// uses the Swift overlay spelling. Only coalesce identities when the
    /// runtime record and overlay record explicitly point at one another.
    private func normalizeClangTypealiasIdentities(
        _ uses: [ImportedNativeType]
    ) throws -> [ImportedNativeType] {
        var overlaysByRuntime: [String: Set<String>] = [:]
        for use in uses {
            for alias in use.aliases where alias.hasPrefix("__C.") {
                let runtimeName = String(alias.dropFirst("__C.".count))
                if runtimeName != use.canonicalName {
                    overlaysByRuntime[runtimeName, default: []]
                        .insert(use.canonicalName)
                }
            }
        }
        let runtimeUses = Dictionary(grouping: uses, by: \.canonicalName)
        for (runtimeName, records) in runtimeUses
        where runtimeName.hasPrefix("NS") && runtimeName.count > 2
            && !runtimeName.contains(".") && !runtimeName.contains("<") {
            let overlayName = String(runtimeName.dropFirst(2))
            let exactOverlay = runtimeUses[overlayName] ?? []
            // The NS prefix only nominates a candidate. Equality requires
            // exact runtime-class evidence on both sides; nested name prefixes
            // and matching representations cannot prove a parent identity.
            guard !exactOverlay.isEmpty,
                  (records + exactOverlay).allSatisfy({
                      $0.kind == .reference && $0.representation == .reference
                          && $0.objectiveCRuntimeName == runtimeName
                  })
            else { continue }
            overlaysByRuntime[runtimeName, default: []].insert(overlayName)
        }

        var normalized = uses
        var indicesByCurrentName = Dictionary(grouping: uses.indices) { uses[$0].canonicalName }
        for runtimeName in overlaysByRuntime.keys.sorted() {
            guard let overlayNames = overlaysByRuntime[runtimeName],
                  !overlayNames.isEmpty
            else { continue }
            guard overlayNames.count == 1, let overlayName = overlayNames.first
            else { continue }
            let overlaySwiftTypes = Set((runtimeUses[overlayName] ?? []).map(\.swiftType))
            let overlaySwiftType = overlaySwiftTypes.count == 1
                ? overlaySwiftTypes.first! : overlayName
            // Update the index as names change so ordered alias chains retain
            // the same semantics as scanning the current normalized inventory.
            let indices = indicesByCurrentName.removeValue(forKey: runtimeName) ?? []
            for index in indices {
                normalized[index].aliases = Array(Set(
                    normalized[index].aliases
                        + [runtimeName, normalized[index].swiftType]
                )).sorted()
                normalized[index].canonicalName = overlayName
                normalized[index].swiftType = overlaySwiftType
            }
            indicesByCurrentName[overlayName, default: []].append(contentsOf: indices)
        }
        return normalized
    }

    /// Clang import may expose a flat ABI identity in mangling while canonical
    /// SIL prints its nested Swift overlay name. Once one exact use proves that
    /// mapping, normalize every record for that ABI identity before merging.
    private func normalizeImportedNominalIdentities(
        _ uses: [ImportedNativeType]
    ) throws -> [ImportedNativeType] {
        let byCanonicalName = Dictionary(grouping: uses, by: \.canonicalName)
        for name in byCanonicalName.keys.sorted() {
            let records = byCanonicalName[name, default: []]
            guard Set(records.compactMap(\.objectiveCRuntimeName)).count <= 1 else {
                throw FrontendReceipt.ImportedNominalIdentity.conflict(
                    "imported nominal \(name) has conflicting Objective-C runtime identities", uses: records)
            }
        }
        // Runtime class identity remains authoritative after an earlier merge
        // has selected a nested Swift canonical spelling. This also makes
        // incremental merges of normalized and raw observations idempotent.
        let indicesByABIName = Dictionary(grouping: uses.indices) {
            let use = uses[$0]
            // Objective-C lightweight generics erase their arguments at
            // runtime. That class identity cannot merge Swift instantiations.
            if use.canonicalName.contains("<") || use.swiftType.contains("<") {
                return use.canonicalName
            }
            return use.objectiveCRuntimeName ?? use.canonicalName
        }
        var overlayByRuntime: [String: String] = [:]
        var normalized = uses
        for runtimeName in indicesByABIName.keys.sorted() {
            guard let indices = indicesByABIName[runtimeName] else {
                continue
            }
            let matchingUses = indices.map { uses[$0] }
            guard let overlayName = try FrontendReceipt.ImportedNominalIdentity
                .overlaySpelling(canonicalName: runtimeName, uses: matchingUses)
            else { continue }
            // Normalize Swift spellings before either the nested identity pass
            // or the final merge consumes them. Keep raw ABI spellings intact.
            for index in indices
            where normalized[index].swiftType != runtimeName
                && normalized[index].swiftType != overlayName {
                normalized[index].aliases = Array(Set(
                    normalized[index].aliases + [normalized[index].swiftType]
                )).sorted()
                normalized[index].swiftType = overlayName
            }
            var overlayComponents = overlayName.split(separator: ".")
            let moduleRoots = FrontendReceipt.ImportedNominalIdentity.moduleRoots(in: matchingUses)
            if let first = overlayComponents.first,
               moduleRoots.contains(String(first)) {
                overlayComponents.removeFirst()
            }
            guard overlayComponents.count >= 2 else {
                // A different top-level Swift spelling can be a contextual
                // abstraction over several runtime classes. Flat Clang/Swift
                // renames are handled by the explicit typealias pass above;
                // this pass exists only for proven nested overlay spellings.
                continue
            }
            overlayByRuntime[runtimeName] = overlayName
        }
        let runtimesByOverlay = Dictionary(
            grouping: overlayByRuntime.map { ($0.key, $0.value) },
            by: \.1
        )
        for runtimeName in overlayByRuntime.keys.sorted() {
            guard let overlayName = overlayByRuntime[runtimeName],
                  runtimesByOverlay[overlayName]?.count == 1
            else {
                // A Swift abstraction can be carried by several concrete
                // Objective-C classes (for example DispatchObject by both an
                // object and a queue). That is a contextual physical bridge,
                // not a nominal alias, so keep every runtime identity exact.
                continue
            }
            for index in indicesByABIName[runtimeName] ?? [] {
                normalized[index].aliases = Array(Set(
                    normalized[index].aliases
                        + [runtimeName, normalized[index].swiftType]
                )).sorted()
                normalized[index].canonicalName = overlayName
                normalized[index].swiftType = overlayName
            }
        }
        return normalized
    }

    static func objectiveCClassNames(inMangledType mangledType: String) -> [String] {
        objectiveCNames(
            inMangledType: mangledType,
            terminator: "C"
        )
    }

    static func objectiveCTypealiasNames(
        inMangledType mangledType: String
    ) -> [String] {
        objectiveCNames(
            inMangledType: mangledType,
            terminator: "a"
        )
    }

    /// Finds Clang-imported protocol identities in a mangled type. Requiring
    /// the exact `So..._p` production distinguishes protocol existentials from
    /// source-level `Any` and `AnyObject`, which share an AnyObject-shaped
    /// foreign calling convention.
    static func objectiveCProtocolNames(
        inMangledType mangledType: String
    ) -> [String] {
        objectiveCNames(
            inMangledType: mangledType,
            terminator: "_p"
        )
    }

    /// Records Clang typedefs even when they are nested inside Optional,
    /// collection, tuple, or callback spellings. Their exact `So...a`
    /// mangling is ABI evidence; known VM scalar aliases remain represented by
    /// their scalar value type instead of becoming opaque native handles.
    func importedClangTypealiasTypes(
        inMangledType mangledType: String,
        source: SourceState,
        importedModules: [String]
    ) -> [ImportedNativeType] {
        Self.objectiveCTypealiasNames(inMangledType: mangledType).compactMap {
            runtimeName in
            guard FrontendReceipt.ValueTypeParser.parse(
                runtimeName,
                allowVoid: false
            ) == nil else { return nil }
            return importedType(
                canonicalName: runtimeName,
                swiftType: runtimeName,
                kind: .value,
                aliases: ["__C.\(runtimeName)"],
                representation: .opaqueValue,
                representationEvidence: .clangTypealias,
                source: source,
                importedModules: importedModules,
                requiresMainActor: false
            )
        }
    }

    /// Returns the exact Clang-imported nominal ABI identity. Unlike the
    /// scanning helpers, this deliberately rejects containers and function
    /// types so a nested imported type cannot be mistaken for the outer value.
    static func objectiveCNominalIdentity(
        inMangledType mangledType: String
    ) -> String? {
        var value = mangledType
        guard value.hasPrefix("$s"), value.hasSuffix("D") else { return nil }
        value.removeLast()
        while value.hasSuffix("Sg") { value.removeLast(2) }
        guard value.hasPrefix("$sSo") else { return nil }

        let bytes = Array(value.utf8)
        var cursor = 4
        let lengthStart = cursor
        while cursor < bytes.count,
              bytes[cursor] >= UInt8(ascii: "0"),
              bytes[cursor] <= UInt8(ascii: "9") {
            cursor += 1
        }
        guard cursor > lengthStart,
              let length = Int(String(
                  decoding: bytes[lengthStart..<cursor],
                  as: UTF8.self
              )),
              length > 0,
              length == bytes.count - cursor - 1,
              [
                  UInt8(ascii: "C"), UInt8(ascii: "V"),
                  UInt8(ascii: "O"), UInt8(ascii: "a"),
              ].contains(bytes[cursor + length])
        else { return nil }
        return String(
            decoding: bytes[cursor..<(cursor + length)],
            as: UTF8.self
        )
    }

    private static func objectiveCNames(
        inMangledType mangledType: String,
        terminator: String
    ) -> [String] {
        let bytes = Array(mangledType.utf8)
        let terminatorBytes = Array(terminator.utf8)
        guard !terminatorBytes.isEmpty else { return [] }
        var names: Set<String> = []
        var index = 0
        while index + 3 < bytes.count {
            guard bytes[index] == UInt8(ascii: "S"),
                  bytes[index + 1] == UInt8(ascii: "o")
            else {
                index += 1
                continue
            }
            var cursor = index + 2
            let lengthStart = cursor
            while cursor < bytes.count,
                  bytes[cursor] >= UInt8(ascii: "0"),
                  bytes[cursor] <= UInt8(ascii: "9") {
                cursor += 1
            }
            guard cursor > lengthStart,
                  let length = Int(String(
                      decoding: bytes[lengthStart..<cursor],
                      as: UTF8.self
                  )),
                  length > 0,
                  length <= bytes.count - cursor,
                  terminatorBytes.count <= bytes.count - cursor - length,
                  bytes[(cursor + length)..<(cursor + length
                    + terminatorBytes.count)].elementsEqual(terminatorBytes)
            else {
                index += 2
                continue
            }
            let name = String(
                decoding: bytes[cursor..<(cursor + length)],
                as: UTF8.self
            )
            if Self.isSwiftIdentifier(name) {
                names.insert(name)
            }
            index = cursor + length + terminatorBytes.count
        }
        return names.sorted()
    }

    func makeNativeTypeLookup(
        records: [InterfaceArchive.TypeRecord],
        importedTypes: [ImportedNativeType],
        sourceNominals: [SourceNominal]
    ) throws -> [String: Core.TypeID] {
        let recordsByCanonicalName = Dictionary(uniqueKeysWithValues: records.map {
            ($0.canonicalName, $0)
        })
        var result = recordsByCanonicalName.mapValues(\.id)
        var inferredAliases: [String: Set<Core.TypeID>] = [:]
        let sourceTypeNames = Set(sourceNominals.map(\.canonicalName))
        var nonSourceRecordsByLeafName: [String: [InterfaceArchive.TypeRecord]] = [:]
        for record in records where !sourceTypeNames.contains(record.canonicalName) {
            guard let leaf = record.canonicalName.split(separator: ".").last else {
                continue
            }
            nonSourceRecordsByLeafName[String(leaf), default: []].append(record)
        }
        for source in sourceNominals where source.kind == .reference {
            guard let record = recordsByCanonicalName[source.canonicalName] else {
                continue
            }
            // Generated Swift is compiled inside the current module, where a
            // source class is spelled without the leading module component.
            inferredAliases[source.localTypeKey.rawValue, default: []]
                .insert(record.id)
        }
        for imported in importedTypes {
            let matches: [InterfaceArchive.TypeRecord]
            if let exact = recordsByCanonicalName[imported.canonicalName] {
                matches = [exact]
            } else {
                matches = nonSourceRecordsByLeafName[imported.canonicalName] ?? []
            }
            guard matches.count == 1, let record = matches.first else {
                throw FrontendReceipt.Error.invalidRequest(
                    "imported type \(imported.canonicalName) has no unique TypeID"
                )
            }
            let aliases = Set([
                imported.canonicalName,
                imported.swiftType,
                "__C.\(imported.canonicalName)",
            ] + imported.aliases).filter {
                !FrontendReceipt.ValueTypeParser.isBuiltinValueSpelling($0)
            }
            for alias in aliases {
                inferredAliases[alias, default: []].insert(record.id)
            }
        }
        for (alias, typeIDs) in inferredAliases
        where result[alias] == nil && typeIDs.count == 1 {
            result[alias] = typeIDs.first
        }
        return result
    }

    func makeImportedSwiftTypeAliases(
        _ importedTypes: [ImportedNativeType]
    ) throws -> [String: String] {
        struct Candidate {
            var swiftType: String
            var isExact: Bool
        }
        var candidates: [String: [Candidate]] = [:]
        for imported in importedTypes {
            guard FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
                imported.swiftType
            ) else {
                throw FrontendReceipt.Error.invalidRequest(
                    "imported type \(imported.canonicalName) has an unsafe Swift spelling"
                )
            }
            let aliases = Set(
                [imported.canonicalName, imported.swiftType,
                 "__C.\(imported.canonicalName)"] + imported.aliases
            ).filter {
                !FrontendReceipt.ValueTypeParser.isBuiltinValueSpelling($0)
            }
            for alias in aliases {
                candidates[alias, default: []].append(
                    .init(
                        swiftType: imported.swiftType,
                        isExact: alias == imported.canonicalName
                            || alias == imported.swiftType
                    )
                )
            }
        }
        return candidates.compactMapValues { values in
            let exact = Set(values.filter(\.isExact).map(\.swiftType))
            if exact.count == 1 { return exact.first }
            guard exact.isEmpty else { return nil }
            let inferred = Set(values.map(\.swiftType))
            return inferred.count == 1 ? inferred.first : nil
        }
    }
}
