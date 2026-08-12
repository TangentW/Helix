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
    struct ImportedReference: Sendable {
        var runtimeName: String
        var sourceFileLogicalID: String
        var importedModules: [String]
        var requiresMainActor: Bool
    }

    func discoverImportedReferences(
        documents: [FrontendReceipt.TypedAST.Object],
        sourcesByPhysicalPath: [String: SourceState],
        moduleName: String,
        demangled: [String: String]
    ) throws -> [ImportedReference] {
        var uses: [String: [ImportedReference]] = [:]

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
            collectImportedReferences(
                items: items,
                inheritedMainActor: false,
                source: source,
                importedModules: modules,
                demangled: demangled,
                uses: &uses
            )
        }

        return uses.keys.sorted().compactMap { runtimeName in
            guard let values = uses[runtimeName],
                  let sourceFileLogicalID = values.map(\.sourceFileLogicalID).min()
            else { return nil }
            return ImportedReference(
                runtimeName: runtimeName,
                sourceFileLogicalID: sourceFileLogicalID,
                importedModules: Array(
                    Set(values.flatMap(\.importedModules))
                ).sorted(),
                requiresMainActor: values.contains(where: \.requiresMainActor)
            )
        }
    }

    private func collectImportedReferences(
        items: [Any],
        inheritedMainActor: Bool,
        source: SourceState,
        importedModules: [String],
        demangled: [String: String],
        uses: inout [String: [ImportedReference]]
    ) {
        for value in items {
            guard let item = value as? [String: Any],
                  let kind = item["_kind"] as? String
            else { continue }
            let requiresMainActor = inheritedMainActor
                || itemRequiresMainActor(item, demangled: demangled)

            func record(_ rawType: Any?) {
                guard let mangled = rawType as? String else { return }
                let runtimeNames = Self.objectiveCClassNames(
                    inMangledType: mangled
                )
                for runtimeName in runtimeNames.sorted() {
                    uses[runtimeName, default: []].append(
                        .init(
                            runtimeName: runtimeName,
                            sourceFileLogicalID: source.logicalPath,
                            importedModules: importedModules,
                            requiresMainActor: requiresMainActor
                        )
                    )
                }
            }

            if kind == "var_decl", item["readImpl"] as? String == "stored" {
                record(item["interface_type"])
            } else if kind == "func_decl" {
                if let parameters = item["params"] as? [String: Any],
                   let values = parameters["params"] as? [[String: Any]] {
                    for parameter in values {
                        record(parameter["interface_type"])
                    }
                }
                record(item["result"])
            }

            if let members = item["members"] as? [Any] {
                collectImportedReferences(
                    items: members,
                    inheritedMainActor: requiresMainActor,
                    source: source,
                    importedModules: importedModules,
                    demangled: demangled,
                    uses: &uses
                )
            }
        }
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
        references: [ImportedReference],
        operationTypes: [ImportedNativeType]
    ) throws -> [ImportedNativeType] {
        var uses = operationTypes
        uses.append(contentsOf: references.map {
            ImportedNativeType(
                canonicalName: $0.runtimeName,
                swiftType: $0.runtimeName,
                kind: .reference,
                aliases: [],
                representation: .reference,
                sourceFileLogicalID: $0.sourceFileLogicalID,
                importedModules: $0.importedModules,
                requiresMainActor: $0.requiresMainActor
            )
        })
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
}
