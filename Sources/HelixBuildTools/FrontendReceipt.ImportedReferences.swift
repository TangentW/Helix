import Foundation
import HelixCore
import HelixInterface

extension FrontendReceipt.Adapter {
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
                var runtimeNames = Set(
                    Self.objectiveCClassRuntimeNames(
                        in: demangled[mangled] ?? ""
                    )
                )
                if let exact = Self.objectiveCClassRuntimeName(mangled) {
                    runtimeNames.insert(exact)
                }
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

    private func itemRequiresMainActor(
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

    private static func objectiveCClassRuntimeName(_ mangled: String) -> String? {
        let prefix = "$sSo"
        guard mangled.hasPrefix(prefix), mangled.hasSuffix("D") else { return nil }
        let bytes = Array(mangled.dropFirst(prefix.count).utf8)
        var digitCount = 0
        while digitCount < bytes.count,
              bytes[digitCount] >= UInt8(ascii: "0"),
              bytes[digitCount] <= UInt8(ascii: "9") {
            digitCount += 1
        }
        guard digitCount > 0,
              let length = Int(String(decoding: bytes[..<digitCount], as: UTF8.self)),
              length > 0,
              digitCount + length < bytes.count,
              bytes[digitCount + length] == UInt8(ascii: "C")
        else { return nil }
        let suffix = String(
            decoding: bytes[(digitCount + length + 1)...],
            as: UTF8.self
        )
        guard suffix == "D" || suffix == "SgD" else { return nil }
        let name = String(
            decoding: bytes[digitCount..<(digitCount + length)],
            as: UTF8.self
        )
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "_"
              })
        else { return nil }
        return name
    }

    private static func objectiveCClassRuntimeNames(
        in demangledType: String
    ) -> [String] {
        Array(Set(
            demangledType.components(separatedBy: "__C.").dropFirst().compactMap {
                suffix -> String? in
                let name = String(suffix.prefix {
                    $0.isLetter || $0.isNumber || $0 == "_"
                })
                guard let first = name.first,
                      first.isLetter || first == "_"
                else { return nil }
                return name
            }
        )).sorted()
    }

    func makeNativeTypeLookup(
        records: [InterfaceArchive.TypeRecord],
        importedReferences: [ImportedReference],
        sourceNominals: [SourceNominal]
    ) throws -> [String: Core.TypeID] {
        var result = Dictionary(uniqueKeysWithValues: records.map {
            ($0.canonicalName, $0.id)
        })
        let sourceTypeNames = Set(sourceNominals.map(\.canonicalName))
        for reference in importedReferences {
            let exactMatches = records.filter {
                $0.canonicalName == reference.runtimeName
            }
            let qualifiedMatches = records.filter {
                !sourceTypeNames.contains($0.canonicalName)
                    && $0.canonicalName.split(separator: ".").last
                        == Substring(reference.runtimeName)
            }
            let matches = exactMatches.isEmpty ? qualifiedMatches : exactMatches
            guard matches.count == 1, let record = matches.first else {
                throw FrontendReceipt.Error.invalidRequest(
                    "Objective-C runtime type \(reference.runtimeName) has no unique frozen TypeID"
                )
            }
            for alias in [reference.runtimeName, "__C.\(reference.runtimeName)"] {
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
