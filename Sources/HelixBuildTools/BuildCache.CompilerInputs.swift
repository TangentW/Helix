import Darwin
import Foundation
import HelixCore

extension BuildCache {
/// Content identity for non-SDK compiler inputs found through Swift/Clang
/// search paths. Toolchain and SDK identities remain separate key components.
public enum CompilerInputs {}
}

extension BuildCache.CompilerInputs {
public struct Snapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var importedModules: [String]
    public var searchRoots: [String]
    public var explicitPaths: [String]
    public var fileCount: UInt64
    public var byteCount: UInt64
    public var contentHash: Core.Digest
    public var isComplete: Bool
    /// Diagnostic provenance only; absent from complete and legacy snapshots.
    public var incompleteReasons: [String]?

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        importedModules: [String],
        searchRoots: [String],
        explicitPaths: [String],
        fileCount: UInt64,
        byteCount: UInt64,
        contentHash: Core.Digest,
        isComplete: Bool,
        incompleteReasons: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.importedModules = Array(Set(importedModules)).sorted()
        self.searchRoots = searchRoots
        self.explicitPaths = explicitPaths
        self.fileCount = fileCount
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.isComplete = isComplete
        self.incompleteReasons = incompleteReasons.map { Array(Set($0)).sorted() }
    }
}

/// Captures only compiler-facing interface inputs. Objects, generated outputs,
/// resources, and implementation binaries are intentionally excluded.
public static func capture(
    arguments: [String],
    currentModuleName: String,
    workingDirectory: URL,
    importedModules: Set<String>? = nil
) -> BuildCache.CompilerInputs.Snapshot {
    capture(
        arguments: arguments, currentModuleName: currentModuleName,
        workingDirectory: workingDirectory, importedModules: importedModules,
        directoryCache: nil
    )
}

static func capture(
    arguments: [String],
    currentModuleName: String,
    workingDirectory: URL,
    importedModules: Set<String>?,
    directoryCache: DirectoryInventoryCache?
) -> BuildCache.CompilerInputs.Snapshot {
    let parsed = parseArguments(
        arguments,
        currentModuleName: currentModuleName,
        workingDirectory: workingDirectory
    )
    var fingerprint = Fingerprinter(isComplete: parsed.isComplete)
    for reason in parsed.incompleteReasons { fingerprint.markIncomplete(reason) }
    var additionalExplicitPaths = Set<String>()
    let dependencyModules = importedModules.map {
        Set($0.compactMap(moduleRoot)).subtracting([currentModuleName])
    }
    if importedModules?.contains(where: { moduleRoot($0) == nil }) == true {
        fingerprint.markIncomplete("Invalid imported module names: \(importedModules!.filter { moduleRoot($0) == nil }.sorted())")
    }
    fingerprint.hasher.append(
        dependencyModules == nil ? "all-modules" : "selected-modules"
    )
    for module in dependencyModules?.sorted() ?? [] {
        fingerprint.hasher.append(module)
    }

    for (locationIndex, location) in parsed.values.enumerated() {
        let logicalRoot = "\(location.kind.rawValue)[\(locationIndex)]"
        fingerprint.hasher.append(location.kind.rawValue)
        fingerprint.hasher.append(UInt64(locationIndex))
        let original = URL(fileURLWithPath: location.path)
        var information = Darwin.stat()
        if lstat(original.path, &information) != 0 {
            if errno == ENOENT {
                fingerprint.hasher.append("missing")
            } else {
                fingerprint.hasher.append("unreadable")
                fingerprint.markIncomplete("Unreadable compiler input: \(original.path)")
            }
            continue
        }
        let resolved = original.resolvingSymlinksInPath().standardizedFileURL
        guard lstat(resolved.path, &information) == 0 else {
            fingerprint.hasher.append("unresolved")
            fingerprint.markIncomplete("Unresolved compiler input: \(original.path)")
            continue
        }
        if information.st_mode & S_IFMT == S_IFREG {
            do {
                let maximumBytes: Int = switch location.kind {
                case .overlayInput: 16 * 1_024 * 1_024
                case .moduleMapInput: 8 * 1_024 * 1_024
                case .bridgingHeaderInput: 64 * 1_024 * 1_024
                case .searchRoot where resolved.pathExtension.lowercased() == "hmap":
                    64 * 1_024 * 1_024
                case .searchRoot, .explicitInput: 512 * 1_024 * 1_024
                }
                var externalManifest: ExternalReferences.Manifest?
                if location.kind == .overlayInput {
                    _ = try fingerprint.appendFile(
                        resolved,
                        logicalPath: logicalRoot,
                        maximumBytes: maximumBytes
                    ) { data in
                        let manifest = try ExternalReferences.overlayManifest(
                            data,
                            relativeTo: resolved.deletingLastPathComponent()
                        )
                        externalManifest = manifest
                        return manifest.identityData
                    }
                } else if location.kind == .searchRoot,
                          resolved.pathExtension.lowercased() == "hmap" {
                    _ = try fingerprint.appendFile(
                        resolved,
                        logicalPath: logicalRoot,
                        maximumBytes: maximumBytes
                    ) { data in
                        let manifest = try ExternalReferences.headerMapManifest(
                            data,
                            relativeTo: resolved.deletingLastPathComponent()
                        )
                        externalManifest = manifest
                        return manifest.identityData
                    }
                } else {
                    _ = try fingerprint.appendFile(
                        resolved,
                        logicalPath: logicalRoot,
                        maximumBytes: maximumBytes
                    )
                }
                if location.kind == .overlayInput {
                    guard let externalManifest else {
                        throw BuildCache.Error.io(
                            "VFS overlay identity is unavailable"
                        )
                    }
                    for reference in externalManifest.references
                    where !isToolchainOrSDKPath(reference.path) {
                        additionalExplicitPaths.insert(reference.path)
                        try fingerprint.appendReferencedPath(
                            URL(fileURLWithPath: reference.path),
                            logicalPath: "\(logicalRoot)/\(reference.logicalID)"
                        )
                    }
                } else if location.kind == .searchRoot,
                          resolved.pathExtension.lowercased() == "hmap" {
                    guard let externalManifest else {
                        throw BuildCache.Error.io(
                            "header-map identity is unavailable"
                        )
                    }
                    for reference in externalManifest.references
                    where !isToolchainOrSDKPath(reference.path) {
                        additionalExplicitPaths.insert(reference.path)
                        try fingerprint.appendReferencedPath(
                            URL(fileURLWithPath: reference.path),
                            logicalPath: "\(logicalRoot)/\(reference.logicalID)"
                        )
                    }
                } else if location.kind == .moduleMapInput {
                    try fingerprint.appendReferencedPath(
                        resolved.deletingLastPathComponent(),
                        logicalPath: "\(logicalRoot)/module-map-root",
                        compilerInterfacesOnly: true,
                        excluding: resolved
                    )
                } else if location.kind == .bridgingHeaderInput {
                    try fingerprint.appendReferencedPath(
                        resolved.deletingLastPathComponent(),
                        logicalPath: "\(logicalRoot)/bridging-header-root",
                        compilerInterfacesOnly: true,
                        excluding: resolved
                    )
                }
            } catch {
                fingerprint.hasher.append("unstable-file")
                fingerprint.markIncomplete("\(original.path): \(error)")
            }
            continue
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            fingerprint.hasher.append("unsupported-node")
            fingerprint.markIncomplete("Unsupported compiler input node: \(original.path)")
            continue
        }
        do {
            let subpaths = try directoryCache?.subpaths(of: resolved, maximumCount: 250_000)
                ?? boundedSubpaths(of: resolved, maximumCount: 250_000)
            var moduleMapRoots = Set<String>()
            if location.kind == .searchRoot, let dependencyModules {
                for subpath in subpaths where isModuleMapPath(subpath) {
                    let child = resolved.appendingPathComponent(subpath)
                    do {
                        if try moduleMap(
                            at: child,
                            declaresAny: dependencyModules
                        ) {
                            moduleMapRoots.insert(
                                (subpath as NSString).deletingLastPathComponent
                            )
                        }
                    } catch {
                        fingerprint.markIncomplete("Module map \(child.path): \(error)")
                    }
                }
                for subpath in subpaths where importedModuleContainer(
                    subpath,
                    modules: dependencyModules
                ) {
                    let child = resolved.appendingPathComponent(subpath)
                    var childInformation = Darwin.stat()
                    if lstat(child.path, &childInformation) == 0,
                       childInformation.st_mode & S_IFMT == S_IFLNK,
                       lstat(
                           child.resolvingSymlinksInPath().standardizedFileURL.path,
                           &childInformation
                       ) == 0,
                       childInformation.st_mode & S_IFMT == S_IFDIR {
                        // A module-directory link is valid compiler input, but
                        // FileManager does not traverse it. Disable reuse until
                        // the directory can be fingerprinted without cycles.
                        fingerprint.markIncomplete("Module directory symlink is not fingerprinted: \(child.path) -> \(child.resolvingSymlinksInPath().path)")
                    }
                }
            }
            for subpath in subpaths where isCompilerInterfacePath(subpath) {
                if belongsToCurrentModule(subpath, moduleName: currentModuleName) {
                    continue
                }
                if location.kind == .searchRoot,
                   let dependencyModules,
                   !(parsed.hasBridgingHeader && isHeaderInterfacePath(subpath)),
                   !belongsToImportedModule(
                       subpath,
                       modules: dependencyModules,
                       moduleMapRoots: moduleMapRoots
                   ) {
                    continue
                }
                let child = resolved.appendingPathComponent(subpath)
                var childInformation = Darwin.stat()
                guard lstat(child.path, &childInformation) == 0 else {
                    fingerprint.markIncomplete("Compiler input disappeared or became unreadable: \(child.path)")
                    continue
                }
                if childInformation.st_mode & S_IFMT == S_IFLNK {
                    let target = child.resolvingSymlinksInPath().standardizedFileURL
                    guard lstat(target.path, &childInformation) == 0,
                          childInformation.st_mode & S_IFMT == S_IFREG
                    else {
                        fingerprint.markIncomplete("Compiler interface symlink does not resolve to a regular file: \(child.path) -> \(target.path)")
                        continue
                    }
                    do {
                        try fingerprint.appendFile(
                            target,
                            logicalPath: "\(logicalRoot)/\(subpath)"
                        )
                    } catch {
                        fingerprint.markIncomplete("\(child.path) -> \(target.path): \(error)")
                    }
                } else if childInformation.st_mode & S_IFMT == S_IFREG {
                    do {
                        try fingerprint.appendFile(
                            child,
                            logicalPath: "\(logicalRoot)/\(subpath)"
                        )
                    } catch {
                        fingerprint.markIncomplete("\(child.path): \(error)")
                    }
                }
                if fingerprint.fileCount > 100_000
                    || fingerprint.byteCount > 1_024 * 1_024 * 1_024 {
                    fingerprint.markIncomplete("Compiler input budget exceeded at \(child.path): \(fingerprint.fileCount) files, \(fingerprint.byteCount) bytes")
                    break
                }
            }
        } catch {
            fingerprint.hasher.append("directory-read-failed")
            fingerprint.markIncomplete("Compiler input directory \(resolved.path): \(error)")
        }
    }

    return .init(
        importedModules: dependencyModules?.sorted() ?? [],
        searchRoots: parsed.values.filter { $0.kind == .searchRoot }
            .map(\.path),
        explicitPaths: Array(Set(parsed.values.filter {
            $0.kind != .searchRoot
        }.map(\.path)).union(additionalExplicitPaths)).sorted(),
        fileCount: fingerprint.fileCount,
        byteCount: fingerprint.byteCount,
        contentHash: fingerprint.hasher.finalize(),
        isComplete: fingerprint.isComplete,
        incompleteReasons: fingerprint.incompleteReasons.isEmpty ? nil : fingerprint.incompleteReasons.sorted()
    )
}

private static func importedModuleContainer(
    _ path: String,
    modules: Set<String>
) -> Bool {
    let name = (path as NSString).lastPathComponent
    return [".swiftmodule", ".framework"].contains { suffix in
        name.hasSuffix(suffix) && modules.contains(String(name.dropLast(suffix.count)))
    }
}

private static func moduleRoot(_ value: String) -> String? {
    guard let root = value.split(separator: ".").first.map(String.init),
          !root.isEmpty,
          root.utf8.count <= 1_024,
          root.unicodeScalars.allSatisfy({ scalar in
              scalar.value >= 0x80
                  || scalar == "_"
                  || CharacterSet.alphanumerics.contains(scalar)
          })
    else { return nil }
    return root
}

private static func belongsToImportedModule(
    _ path: String,
    modules: Set<String>,
    moduleMapRoots: Set<String>
) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    let name = components.last ?? path
    if components.contains(where: { component in
        [".swiftmodule", ".framework"].contains { suffix in
            component.hasSuffix(suffix)
                && modules.contains(String(component.dropLast(suffix.count)))
        }
    }) || [".swiftinterface", ".private.swiftinterface", ".swiftdoc", ".swiftsourceinfo", ".modulemap", ".h"].contains(where: { suffix in
        name.hasSuffix(suffix) && modules.contains(String(name.dropLast(suffix.count)))
    }) {
        return true
    }
    return moduleMapRoots.contains { root in
        root.isEmpty || root == "." || path == root || path.hasPrefix(root + "/")
    }
}

private static func isModuleMapPath(_ path: String) -> Bool {
    (path as NSString).lastPathComponent.lowercased()
        .hasSuffix(".modulemap")
}

private static func moduleMap(
    at url: URL,
    declaresAny modules: Set<String>
) throws -> Bool {
    let data = try Fingerprinter.readStableData(
        url,
        maximumBytes: 8 * 1_024 * 1_024
    )
    guard let source = String(data: data, encoding: .utf8) else {
        throw BuildCache.Error.io("module map is not UTF-8")
    }
    return modules.contains { module in
        let escaped = NSRegularExpression.escapedPattern(for: module)
        let pattern = #"(?:^|[^A-Za-z0-9_])module\s+"# + escaped
            + #"(?:$|[.\s\{\[])"#
        return source.range(of: pattern, options: .regularExpression) != nil
    }
}

static func isCompilerInterfacePath(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent.lowercased()
    let suffixes = [
        ".swiftmodule", ".swiftinterface", ".swiftdoc", ".swiftsourceinfo",
        ".swiftcrossimport", ".abi.json", ".modulemap", ".pcm", ".pch",
        ".h", ".hh", ".hpp", ".inc", ".apinotes",
    ]
    return suffixes.contains { name.hasSuffix($0) }
}

static func boundedSubpaths(
    of root: URL,
    maximumCount: Int
) throws -> [String] {
    guard maximumCount > 0 else {
        throw BuildCache.Error.io("directory entry limit is invalid")
    }
    guard let resolvedRoot = Darwin.realpath(root.path, nil) else {
        throw BuildCache.Error.io("cannot resolve compiler input directory")
    }
    defer { Darwin.free(resolvedRoot) }
    let normalizedRoot = URL(
        fileURLWithPath: String(cString: resolvedRoot),
        isDirectory: true
    ).standardizedFileURL
    let prefix = normalizedRoot.path.hasSuffix("/")
        ? normalizedRoot.path : normalizedRoot.path + "/"
    var traversalFailed = false
    guard let enumerator = FileManager.default.enumerator(
        at: normalizedRoot,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { _, _ in
            traversalFailed = true
            return false
        }
    ) else {
        throw BuildCache.Error.io("cannot enumerate compiler input directory")
    }
    var result: [String] = []
    result.reserveCapacity(min(maximumCount, 4_096))
    while let child = enumerator.nextObject() as? URL {
        guard result.count < maximumCount else {
            throw BuildCache.Error.io("compiler input directory exceeds entry limit")
        }
        let path = child.standardizedFileURL.path
        guard path.hasPrefix(prefix) else {
            throw BuildCache.Error.io("compiler input enumeration escaped its root")
        }
        result.append(String(path.dropFirst(prefix.count)))
    }
    guard !traversalFailed else {
        throw BuildCache.Error.io("compiler input directory traversal failed")
    }
    return result.sorted()
}

private static func isHeaderInterfacePath(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent.lowercased()
    return [".h", ".hh", ".hpp", ".inc", ".pch", ".apinotes"]
        .contains { name.hasSuffix($0) }
}

}
