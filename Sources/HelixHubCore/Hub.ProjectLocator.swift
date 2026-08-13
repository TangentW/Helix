import Foundation

extension Hub {
public struct ProjectCandidate: Hashable, Sendable, Identifiable {
    public var projectURL: URL
    public var workspaceURL: URL?
    public var id: String { projectURL.standardizedFileURL.path }
    public var displayName: String {
        projectURL.deletingPathExtension().lastPathComponent
    }

    public init(projectURL: URL, workspaceURL: URL? = nil) {
        self.projectURL = projectURL.standardizedFileURL
        self.workspaceURL = workspaceURL?.standardizedFileURL
    }
}

/// Resolves a Finder selection into concrete Xcode projects without recursing
/// through dependencies, DerivedData, or generated package workspaces.
public struct ProjectLocator: Sendable {
    public init() {}

    public func locate(from selectionURL: URL) throws -> [Hub.ProjectCandidate] {
        let selection = selectionURL.standardizedFileURL
        switch selection.pathExtension.lowercased() {
        case "xcodeproj":
            return try requireProjects([.init(projectURL: selection)])
        case "xcworkspace":
            return try projects(in: selection)
        default:
            return try projects(inDirectory: selection)
        }
    }

    private func projects(in workspaceURL: URL) throws -> [Hub.ProjectCandidate] {
        let document = workspaceURL.appendingPathComponent("contents.xcworkspacedata")
        let data: Data
        do {
            data = try Data(contentsOf: document)
        } catch {
            throw Hub.Error.invalidProject("workspace contents.xcworkspacedata is unreadable")
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw Hub.Error.invalidProject("workspace document is oversized")
        }
        let delegate = WorkspaceDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.error == nil else {
            throw Hub.Error.invalidProject("workspace XML is malformed")
        }
        let root = workspaceURL.deletingLastPathComponent()
        let candidates = delegate.locations.compactMap { location -> Hub.ProjectCandidate? in
            let path: String
            if location.hasPrefix("group:") {
                path = String(location.dropFirst("group:".count))
            } else if location.hasPrefix("container:") {
                path = String(location.dropFirst("container:".count))
            } else if location.hasPrefix("absolute:") {
                path = String(location.dropFirst("absolute:".count))
            } else {
                return nil
            }
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : root.appendingPathComponent(path)
            guard url.pathExtension.lowercased() == "xcodeproj" else { return nil }
            return .init(projectURL: url, workspaceURL: workspaceURL)
        }
        return try requireProjects(candidates)
    }

    private func projects(inDirectory directoryURL: URL) throws -> [Hub.ProjectCandidate] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw Hub.Error.invalidProject("selection is not a project, workspace, or directory")
        }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw Hub.Error.invalidProject("selected directory is unreadable")
        }
        guard urls.count <= 10_000 else {
            throw Hub.Error.invalidProject("selected directory contains too many entries")
        }
        let workspaces = urls.filter { $0.pathExtension.lowercased() == "xcworkspace" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let workspace = workspaces.first {
            return try projects(in: workspace)
        }
        return try requireProjects(urls.compactMap {
            $0.pathExtension.lowercased() == "xcodeproj"
                ? Hub.ProjectCandidate(projectURL: $0) : nil
        })
    }

    private func requireProjects(
        _ candidates: [Hub.ProjectCandidate]
    ) throws -> [Hub.ProjectCandidate] {
        var unique: [String: Hub.ProjectCandidate] = [:]
        for candidate in candidates {
            let project = candidate.projectURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.fileExists(
                    atPath: project.appendingPathComponent("project.pbxproj").path
                  )
            else { continue }
            unique[project.standardizedFileURL.path] = candidate
        }
        let result = unique.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        guard !result.isEmpty else {
            throw Hub.Error.invalidProject("no concrete .xcodeproj was found")
        }
        return result
    }
}
}

private final class WorkspaceDelegate: NSObject, XMLParserDelegate {
    var locations: [String] = []
    var error: (any Swift.Error)?

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "FileRef", let location = attributeDict["location"],
              locations.count < 10_000
        else { return }
        locations.append(location)
    }

    func parser(_: XMLParser, parseErrorOccurred parseError: any Swift.Error) {
        error = parseError
    }
}
