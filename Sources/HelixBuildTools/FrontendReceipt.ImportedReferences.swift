import Foundation
import HelixCore
import HelixInterface

extension FrontendReceipt.Adapter {
    struct ImportedNativeType: Hashable, Sendable {
        enum Representation: String, Hashable, Sendable {
            case reference
            case rawRepresentable
            case opaqueValue
        }

        var canonicalName: String
        var swiftType: String
        var kind: InterfaceArchive.TypeKind
        var aliases: [String]
        var representation: Representation
        var sourceFileLogicalID: String
        var importedModules: [String]
        var requiresMainActor: Bool
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
                  ],
                  let items = document["items"] as? [Any]
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "imported reference discovery source does not map to the requested source set"
                )
            }
            let modules = imports(in: items).filter { $0 != moduleName }
            guard !modules.isEmpty else { continue }
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
            let requiresMainActor = next.requiresMainActor
                || itemRequiresMainActor(item, demangled: demangled)

            func record(_ rawType: Any?) {
                guard let mangled = rawType as? String else { return }
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
                            requiresMainActor: requiresMainActor
                        )
                    )
                }
                guard let spelling,
                      let rootModule = spelling.split(separator: ".")
                        .first.map(String.init),
                      mangled.hasPrefix("$sSo")
                        || importedModules.contains(rootModule),
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
        let canonical = isSelectorType(discovered)
            ? "ObjectiveC.Selector" : discovered
        guard let representation = importedNominalRepresentation(
            mangled,
            spelling: canonical
        ) else { return nil }
        let kind: InterfaceArchive.TypeKind = representation == .reference
            ? .reference : .value
        return importedType(
            canonicalName: canonical,
            swiftType: canonical,
            kind: kind,
            representation: representation,
            source: source,
            importedModules: importedModules,
            requiresMainActor: representation == .reference && requiresMainActor
        )
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
        case "G" where rawMangledType.hasPrefix("$sSo") && spelling.contains("<"):
            return .reference
        default: return nil
        }
    }

    func importedNativeNominal(in raw: String) -> String? {
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
        source: SourceState,
        importedModules: [String],
        requiresMainActor: Bool
    ) -> ImportedNativeType {
        .init(
            canonicalName: canonicalName,
            swiftType: swiftType,
            kind: kind,
            aliases: aliases,
            representation: representation,
            sourceFileLogicalID: source.logicalPath,
            importedModules: importedModules,
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
        let uses = discoveredTypes + operationTypes
        var result: [String: ImportedNativeType] = [:]
        for use in uses.sorted(by: {
            ($0.canonicalName, $0.sourceFileLogicalID)
                < ($1.canonicalName, $1.sourceFileLogicalID)
        }) {
            guard !use.canonicalName.isEmpty,
                  !use.swiftType.isEmpty,
                  !use.importedModules.isEmpty
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "imported native type metadata is incomplete"
                )
            }
            if var existing = result[use.canonicalName] {
                guard existing.swiftType == use.swiftType else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported native type \(use.canonicalName) has conflicting Swift spellings"
                    )
                }
                var mergeActorIsolation = true
                if existing.representation == .opaqueValue,
                   use.representation == .rawRepresentable {
                    existing.kind = use.kind
                    existing.representation = .rawRepresentable
                    existing.requiresMainActor = use.requiresMainActor
                    mergeActorIsolation = false
                } else if existing.representation == .rawRepresentable,
                          use.representation == .opaqueValue {
                    // Explicit enum/OptionSet evidence is more precise than
                    // the fallback opaque-value classification, including its
                    // actor-neutral value semantics.
                    mergeActorIsolation = false
                } else if existing.kind != use.kind
                            || existing.representation != use.representation {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported native type \(use.canonicalName) has conflicting "
                            + "representations: \(existing.kind.rawValue)/"
                            + "\(existing.representation.rawValue) versus "
                            + "\(use.kind.rawValue)/\(use.representation.rawValue)"
                    )
                }
                existing.sourceFileLogicalID = min(
                    existing.sourceFileLogicalID,
                    use.sourceFileLogicalID
                )
                existing.importedModules = Array(Set(
                    existing.importedModules + use.importedModules
                )).sorted()
                existing.aliases = Array(Set(
                    existing.aliases + use.aliases
                )).sorted()
                if mergeActorIsolation {
                    existing.requiresMainActor = existing.requiresMainActor
                        || use.requiresMainActor
                }
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
        }.sorted { $0.canonicalName < $1.canonicalName }
    }

    static func objectiveCClassNames(inMangledType mangledType: String) -> [String] {
        let bytes = Array(mangledType.utf8)
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
                  cursor + length < bytes.count,
                  bytes[cursor + length] == UInt8(ascii: "C")
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
            index = cursor + length + 1
        }
        return names.sorted()
    }

    func makeNativeTypeLookup(
        records: [InterfaceArchive.TypeRecord],
        importedTypes: [ImportedNativeType],
        sourceNominals: [SourceNominal]
    ) throws -> [String: Core.TypeID] {
        var result = Dictionary(uniqueKeysWithValues: records.map {
            ($0.canonicalName, $0.id)
        })
        let sourceTypeNames = Set(sourceNominals.map(\.canonicalName))
        for imported in importedTypes {
            let exactMatches = records.filter {
                $0.canonicalName == imported.canonicalName
            }
            let qualifiedMatches = records.filter {
                !sourceTypeNames.contains($0.canonicalName)
                    && $0.canonicalName.split(separator: ".").last
                        == Substring(imported.canonicalName)
            }
            let matches = exactMatches.isEmpty ? qualifiedMatches : exactMatches
            guard matches.count == 1, let record = matches.first else {
                throw FrontendReceipt.Error.invalidRequest(
                    "imported type \(imported.canonicalName) has no unique frozen TypeID"
                )
            }
            let aliases = Set([
                imported.canonicalName,
                imported.swiftType,
                "__C.\(imported.canonicalName)",
            ] + imported.aliases)
            for alias in aliases.sorted() {
                if let existing = result[alias], existing != record.id {
                    throw FrontendReceipt.Error.invalidRequest(
                        "native type alias \(alias) resolves to multiple TypeIDs"
                    )
                }
                result[alias] = record.id
            }
        }
        return result
    }

    func makeImportedSwiftTypeAliases(
        _ importedTypes: [ImportedNativeType]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
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
            )
            for alias in aliases {
                if let existing = result[alias], existing != imported.swiftType {
                    throw FrontendReceipt.Error.invalidRequest(
                        "imported Swift type alias \(alias) is ambiguous"
                    )
                }
                result[alias] = imported.swiftType
            }
        }
        return result
    }
}
