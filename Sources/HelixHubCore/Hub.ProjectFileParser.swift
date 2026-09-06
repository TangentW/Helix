import Foundation

extension Hub {
/// Parses the project graph without invoking a build or modifying Xcode files.
public struct ProjectFileParser: Sendable {
    public init() {}

    public func parse(projectURL: URL) throws -> Hub.XcodeProject {
        let projectURL = projectURL.standardizedFileURL
        guard projectURL.pathExtension.lowercased() == "xcodeproj" else {
            throw Hub.Error.unsupportedProject(
                "select a concrete .xcodeproj; workspace composition is inspected separately"
            )
        }
        let projectFile = projectURL.appendingPathComponent("project.pbxproj")
        let data = try readProjectFile(projectFile)
        var parser = try Hub.OpenStep.Parser(data: data)
        guard case let .dictionary(root) = try parser.parse(),
              let objects = root["objects"]?.dictionary,
              let rootObjectID = root["rootObject"]?.string,
              let project = objects[rootObjectID]?.dictionary,
              project["isa"]?.string == "PBXProject"
        else {
            throw Hub.Error.invalidProject("PBXProject root object is missing")
        }
        let sourceRoot = projectURL.deletingLastPathComponent().standardizedFileURL
        let mainGroupID = project["mainGroup"]?.string
        let resolver = ProjectPathResolver(
            sourceRootURL: sourceRoot,
            mainGroupID: mainGroupID,
            objects: objects
        )
        let targetIDs = stringArray(project["targets"])
        guard targetIDs.count <= 4_096 else {
            throw Hub.Error.invalidProject("project declares too many targets")
        }
        let targets: [Hub.XcodeTarget] = try targetIDs.compactMap {
            try makeTarget(id: $0, objects: objects, resolver: resolver)
        }.sorted { (lhs: Hub.XcodeTarget, rhs: Hub.XcodeTarget) in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let projectConfigurations = configurationNames(
            listID: project["buildConfigurationList"]?.string,
            objects: objects
        )
        return .init(
            projectURL: projectURL,
            sourceRootURL: sourceRoot,
            name: projectURL.deletingPathExtension().lastPathComponent,
            objectVersion: root["objectVersion"]?.string ?? "unknown",
            configurations: projectConfigurations,
            targets: targets,
            sharedSchemes: sharedSchemes(in: projectURL)
        )
    }

    private func makeTarget(
        id: String,
        objects: [String: Hub.OpenStep.Value],
        resolver: ProjectPathResolver
    ) throws -> Hub.XcodeTarget? {
        guard let object = objects[id]?.dictionary,
              let isa = object["isa"]?.string,
              ["PBXNativeTarget", "PBXAggregateTarget"].contains(isa),
              let name = object["name"]?.string,
              !name.isEmpty, name.utf8.count <= 1_024
        else { return nil }
        let productType = object["productType"]?.string
        let productReference = object["productReference"]?.string
        let buildableName = productReference.flatMap {
            resolver.fileName(id: $0)
        }
        let configurations = try configurationDetails(
            listID: object["buildConfigurationList"]?.string,
            objects: objects,
            resolver: resolver
        )
        let hasSourcesPhase = stringArray(object["buildPhases"]).contains {
            objects[$0]?.dictionary?["isa"]?.string == "PBXSourcesBuildPhase"
        }
        let hasSynchronizedSourceGroup = !stringArray(
            object["fileSystemSynchronizedGroups"]
        ).isEmpty
        let products = stringArray(object["packageProductDependencies"]).compactMap {
            objects[$0]?.dictionary?["productName"]?.string
        }
        return .init(
            id: id,
            name: name,
            productName: object["productName"]?.string ?? name,
            buildableName: buildableName,
            productType: productType,
            kind: targetKind(isa: isa, productType: productType),
            configurationNames: configurations.map(\.name),
            supportsSourceCompilation: hasSourcesPhase || hasSynchronizedSourceGroup,
            packageProducts: Array(Set(products)).sorted(),
            baseConfigurationPaths: Dictionary(
                uniqueKeysWithValues: configurations.compactMap {
                    guard let path = $0.baseConfigurationPath else { return nil }
                    return ($0.name, path)
                }
            )
        )
    }

    private func configurationDetails(
        listID: String?,
        objects: [String: Hub.OpenStep.Value],
        resolver: ProjectPathResolver
    ) throws -> [(name: String, baseConfigurationPath: String?)] {
        guard let listID, let list = objects[listID]?.dictionary else { return [] }
        let identifiers = stringArray(list["buildConfigurations"])
        let byName = Dictionary(grouping: identifiers) { objects[$0]?.dictionary?["name"]?.string ?? "" }
        for name in byName.keys.sorted() where byName[name]!.count > 1 {
            let evidence = byName[name]!.map { id in
                "\(id) (base=\(objects[id]?.dictionary?["baseConfigurationReference"]?.string ?? "none"))"
            }.joined(separator: "; ")
            throw Hub.Error.invalidProject("configuration list \(listID) repeats name \(String(reflecting: name)): \(evidence)")
        }
        return identifiers.compactMap { identifier in
            guard let configuration = objects[identifier]?.dictionary,
                  let name = configuration["name"]?.string
            else { return nil }
            let base = configuration["baseConfigurationReference"]?.string.flatMap {
                resolver.relativePath(fileID: $0)
            }
            return (name, base)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func configurationNames(
        listID: String?,
        objects: [String: Hub.OpenStep.Value]
    ) -> [String] {
        guard let listID, let list = objects[listID]?.dictionary else { return [] }
        return stringArray(list["buildConfigurations"]).compactMap {
            objects[$0]?.dictionary?["name"]?.string
        }.sorted()
    }

    private func targetKind(
        isa: String,
        productType: String?
    ) -> Hub.XcodeTarget.Kind {
        guard isa != "PBXAggregateTarget" else { return .aggregate }
        switch productType {
        case "com.apple.product-type.application": return .application
        case "com.apple.product-type.framework": return .framework
        case "com.apple.product-type.library.static",
             "com.apple.product-type.library.dynamic": return .library
        case let value? where value.contains("app-extension"): return .appExtension
        case let value? where value.contains("test"): return .testBundle
        default: return .other
        }
    }

    private func sharedSchemes(in projectURL: URL) -> [Hub.XcodeScheme] {
        let directory = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes",
            isDirectory: true
        )
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "xcscheme" }
            .map {
                Hub.XcodeScheme(
                    name: $0.deletingPathExtension().lastPathComponent,
                    url: $0.standardizedFileURL
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func readProjectFile(_ url: URL) throws -> Data {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw Hub.Error.invalidProject("cannot read project.pbxproj metadata")
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= Hub.OpenStep.maximumDocumentBytes
        else {
            throw Hub.Error.invalidProject("project.pbxproj is missing or oversized")
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw Hub.Error.invalidProject("cannot read project.pbxproj")
        }
    }
}
}

private func stringArray(_ value: Hub.OpenStep.Value?) -> [String] {
    value?.array?.compactMap(\.string) ?? []
}

private struct ProjectPathResolver {
    let sourceRootURL: URL
    let mainGroupID: String?
    let objects: [String: Hub.OpenStep.Value]
    let parents: [String: String]

    init(
        sourceRootURL: URL,
        mainGroupID: String?,
        objects: [String: Hub.OpenStep.Value]
    ) {
        self.sourceRootURL = sourceRootURL
        self.mainGroupID = mainGroupID
        self.objects = objects
        var parents: [String: String] = [:]
        for (identifier, value) in objects {
            guard let object = value.dictionary,
                  ["PBXGroup", "PBXVariantGroup", "PBXFileSystemSynchronizedRootGroup"]
                    .contains(object["isa"]?.string ?? "")
            else { continue }
            for child in stringArray(object["children"]) where parents[child] == nil {
                parents[child] = identifier
            }
        }
        self.parents = parents
    }

    func fileName(id: String) -> String? {
        guard let object = objects[id]?.dictionary else { return nil }
        return object["path"]?.string ?? object["name"]?.string
    }

    func relativePath(fileID: String) -> String? {
        guard let url = url(for: fileID, visiting: []) else { return nil }
        return safeRelativePath(for: url)
    }

    private func url(for identifier: String, visiting: Set<String>) -> URL? {
        guard !visiting.contains(identifier), visiting.count < 128,
              let object = objects[identifier]?.dictionary
        else { return nil }
        let isa = object["isa"]?.string ?? ""
        let isGroup = ["PBXGroup", "PBXVariantGroup", "PBXFileSystemSynchronizedRootGroup"]
            .contains(isa)
        let path = object["path"]?.string
            ?? (isGroup ? "" : object["name"]?.string ?? "")
        let sourceTree = object["sourceTree"]?.string ?? "<group>"
        let base: URL
        switch sourceTree {
        case "SOURCE_ROOT":
            base = sourceRootURL
        case "<absolute>":
            base = URL(fileURLWithPath: "/", isDirectory: true)
        case "<group>":
            if identifier == mainGroupID || parents[identifier] == nil {
                base = sourceRootURL
            } else if let parent = parents[identifier] {
                var next = visiting
                next.insert(identifier)
                guard let resolved = url(for: parent, visiting: next) else { return nil }
                base = resolved
            } else {
                base = sourceRootURL
            }
        default:
            // SDKROOT, BUILT_PRODUCTS_DIR, and other build-setting trees are
            // not editable project sources.
            return nil
        }
        return path.isEmpty
            ? base.standardizedFileURL
            : base.appendingPathComponent(path, isDirectory: isGroup).standardizedFileURL
    }

    private func safeRelativePath(for url: URL) -> String? {
        let root = sourceRootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/"), !path.contains("\u{0}") else { return nil }
        let relative = String(path.dropFirst(root.count + 1))
        guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else {
            return nil
        }
        return relative
    }
}
