import Foundation
import HelixDevProtocol

public enum DebugSymbols {}

extension DebugSymbols {
public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case unsafePath(String)
    case missingPath(String)
    case invalidBundle(String)
    case duplicateLogicalPath(String)

    public var description: String {
        switch self {
        case let .unsafePath(path):
            "debug-symbol path contains unsupported control characters: \(path)"
        case let .missingPath(path):
            "debug-symbol path does not exist: \(path)"
        case let .invalidBundle(path):
            "debug-symbol bundle layout is invalid: \(path)"
        case let .duplicateLogicalPath(path):
            "debug-symbol source map repeats logical path: \(path)"
        }
    }
}

public struct SourceMapping: Hashable, Sendable {
    public let logicalPath: String
    public let absolutePath: String

    public init(logicalPath: String, absolutePath: String) throws {
        try DebugSymbols.validate(path: logicalPath)
        try DebugSymbols.validate(path: absolutePath)
        let sourceURL = URL(fileURLWithPath: absolutePath).standardizedFileURL
        guard sourceURL.path == absolutePath else {
            throw DebugSymbols.Error.unsafePath(absolutePath)
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw DebugSymbols.Error.missingPath(absolutePath)
        }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw DebugSymbols.Error.missingPath(absolutePath)
        }
        self.logicalPath = logicalPath
        self.absolutePath = absolutePath
    }
}

/// A dSYM whose DWARF UUID has already been matched to one Native generation.
/// The value is emitted only after the App confirms that the image is active.
public struct Artifact: Hashable, Sendable {
    public let imageUUID: UUID
    public let bundleURL: URL
    public let dwarfURL: URL
    public let swiftModuleURL: URL
    public let sourceMappings: [DebugSymbols.SourceMapping]

    public init(
        imageUUID: UUID,
        bundleURL: URL,
        dwarfURL: URL,
        swiftModuleURL: URL,
        sourceMappings: [DebugSymbols.SourceMapping]
    ) throws {
        guard bundleURL.isFileURL, dwarfURL.isFileURL, swiftModuleURL.isFileURL else {
            throw DebugSymbols.Error.unsafePath(bundleURL.absoluteString)
        }
        let bundle = bundleURL.standardizedFileURL
        let dwarf = dwarfURL.standardizedFileURL
        let swiftModule = swiftModuleURL.standardizedFileURL
        try DebugSymbols.validate(path: bundle.path)
        try DebugSymbols.validate(path: dwarf.path)
        try DebugSymbols.validate(path: swiftModule.path)

        var isDirectory: ObjCBool = false
        guard bundle.pathExtension == "dSYM",
              FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              dwarf.resolvingSymlinksInPath().path.hasPrefix(
                  bundle.resolvingSymlinksInPath().path + "/"
              )
        else {
            throw DebugSymbols.Error.invalidBundle(bundle.path)
        }
        guard FileManager.default.fileExists(atPath: dwarf.path),
              FileManager.default.fileExists(atPath: swiftModule.path)
        else {
            throw DebugSymbols.Error.missingPath(dwarf.path)
        }
        let dwarfValues = try dwarf.resourceValues(forKeys: [.isRegularFileKey])
        let moduleValues = try swiftModule.resourceValues(forKeys: [.isRegularFileKey])
        guard dwarfValues.isRegularFile == true else {
            throw DebugSymbols.Error.missingPath(dwarf.path)
        }
        guard swiftModule.pathExtension == "swiftmodule",
              moduleValues.isRegularFile == true
        else {
            throw DebugSymbols.Error.missingPath(swiftModule.path)
        }
        do {
            let data = try Data(contentsOf: dwarf, options: [.mappedIfSafe])
            let inspector = MachO.Inspector()
            let descriptor = try inspector.inspect(data)
            guard descriptor.uuid == imageUUID else {
                throw DebugSymbols.Error.invalidBundle(
                    "DWARF UUID does not match image \(imageUUID.uuidString)"
                )
            }
            guard try inspector.hasLinkedDebugInformation(data) else {
                throw DebugSymbols.Error.invalidBundle("DWARF has no linked debug information")
            }
        } catch let error as DebugSymbols.Error {
            throw error
        } catch {
            throw DebugSymbols.Error.invalidBundle(
                "\(dwarf.path): \(String(describing: error))"
            )
        }
        guard !sourceMappings.isEmpty else {
            throw DebugSymbols.Error.invalidBundle(bundle.path)
        }
        let sortedMappings = sourceMappings.sorted {
            ($0.logicalPath, $0.absolutePath) < ($1.logicalPath, $1.absolutePath)
        }
        for pair in zip(sortedMappings, sortedMappings.dropFirst())
            where pair.0.logicalPath == pair.1.logicalPath
        {
            throw DebugSymbols.Error.duplicateLogicalPath(pair.0.logicalPath)
        }

        self.imageUUID = imageUUID
        self.bundleURL = bundle
        self.dwarfURL = dwarf
        self.swiftModuleURL = swiftModule
        self.sourceMappings = sortedMappings
    }

    /// Commands can be pasted into the Xcode LLDB console after activation.
    public func lldbCommands() -> [String] {
        [
            "target symbols add --uuid \(imageUUID.uuidString) \(DebugSymbols.quote(dwarfURL.path))",
            "settings append target.swift-module-search-paths "
                + DebugSymbols.quote(swiftModuleURL.deletingLastPathComponent().path),
        ] + sourceMappings.map {
            "settings append target.source-map "
                + "\(DebugSymbols.quote($0.logicalPath)) \(DebugSymbols.quote($0.absolutePath))"
        }
    }
}

private static func validate(path: String) throws {
    guard !path.isEmpty,
          !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    else {
        throw DebugSymbols.Error.unsafePath(path)
    }
}

private static func quote(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
}
