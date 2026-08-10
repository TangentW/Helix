import Darwin
import Foundation
import HelixPatch

public enum PatchDelivery {}

extension PatchDelivery {
public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidInput(String)
    case appContainerUnavailable(String)
    case stagingFailed(String)

    public var description: String {
        switch self {
        case let .invalidInput(reason): "invalid Simulator patch staging input: \(reason)"
        case let .appContainerUnavailable(reason):
            "booted Simulator App container is unavailable: \(reason)"
        case let .stagingFailed(reason): "cannot stage Simulator patch: \(reason)"
        }
    }
}

public struct SimulatorStager: Sendable {
    public typealias ContainerResolver = @Sendable (String) throws -> URL

    private let containerResolver: ContainerResolver

    public init() {
        containerResolver = Self.resolveBootedContainer
    }

    public init(containerResolver: @escaping ContainerResolver) {
        self.containerResolver = containerResolver
    }

    @discardableResult
    public func stage(
        packageURL: URL,
        bundleID: String,
        relativeInboxPath: String
    ) throws -> URL {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 4_096,
              Self.isSafeInboxPath(relativeInboxPath)
        else {
            throw PatchDelivery.Error.invalidInput("bundle ID or inbox path")
        }
        let descriptor = Darwin.open(
            packageURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw PatchDelivery.Error.invalidInput("package is missing or symbolic")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = Darwin.stat()
        let maximum = PatchPackage.DecodingLimits().maximumPackageBytes
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0,
              UInt64(information.st_size) <= UInt64(maximum)
        else {
            throw PatchDelivery.Error.invalidInput("package is not a bounded regular file")
        }
        let bytes = try handle.readToEnd() ?? Data()
        guard bytes.count == Int(information.st_size) else {
            throw PatchDelivery.Error.stagingFailed("package changed while reading")
        }

        let container = try containerResolver(bundleID).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard container.isFileURL,
              FileManager.default.fileExists(
                  atPath: container.path,
                  isDirectory: &isDirectory
              ),
              isDirectory.boolValue,
              (try? container.resourceValues(
                  forKeys: [.isSymbolicLinkKey]
              ).isSymbolicLink) != true
        else {
            throw PatchDelivery.Error.appContainerUnavailable(container.path)
        }
        let destination = container.appendingPathComponent(
            relativeInboxPath
        ).standardizedFileURL
        guard Self.contains(destination, in: container) else {
            throw PatchDelivery.Error.invalidInput("inbox escapes the App container")
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: destination, options: .atomic)
        } catch {
            throw PatchDelivery.Error.stagingFailed(error.localizedDescription)
        }
        return destination
    }

    private static func resolveBootedContainer(bundleID: String) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "simctl", "get_app_container", "booted", bundleID, "data",
        ]
        let output = Pipe()
        let diagnostics = Pipe()
        process.standardOutput = output
        process.standardError = diagnostics
        do {
            try process.run()
        } catch {
            throw PatchDelivery.Error.appContainerUnavailable(
                error.localizedDescription
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              data.count <= 64 * 1_024,
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/")
        else {
            let detail = String(decoding: errorData.prefix(4_096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PatchDelivery.Error.appContainerUnavailable(
                detail.isEmpty ? "simctl returned no container" : detail
            )
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func isSafeInboxPath(_ path: String) -> Bool {
        guard path.hasPrefix("Documents/"), path.hasSuffix(".hlxp"),
              path.utf8.count <= 4_096, !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("") && !components.contains(".")
            && !components.contains("..")
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }
}
}
