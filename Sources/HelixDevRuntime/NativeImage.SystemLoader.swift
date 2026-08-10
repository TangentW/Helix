import Foundation
import HelixCore
import HelixDevProtocol

#if canImport(Darwin)
import Darwin
#endif

/// Development-only loading support for signed Swift replacement images.
public enum NativeImage {}

extension NativeImage {
/// Retained ownership record for one mapped native replacement generation.
///
/// Helix intentionally keeps the dynamic-loader handle alive until process exit:
/// Swift frames, metadata, closures, and witness tables may retain addresses in
/// an older generation even after a newer implementation becomes active.
public final class LoadedImage: @unchecked Sendable {
    /// Generation registered by the image.
    public let generationID: DevProtocol.GenerationID
    /// Private App-container URL from which dyld mapped the image.
    public let fileURL: URL
    /// Mapped artifact size used for session budgeting.
    public let byteCount: Int
    /// Mach-O metadata captured during preflight.
    public let descriptor: MachO.Descriptor
    /// Number of Dynamic Replacement roots registered by the image entry point.
    public let registeredRootCount: UInt32
    let handle: UnsafeMutableRawPointer

    init(
        generationID: DevProtocol.GenerationID,
        fileURL: URL,
        byteCount: Int,
        descriptor: MachO.Descriptor,
        registeredRootCount: UInt32,
        handle: UnsafeMutableRawPointer
    ) {
        self.generationID = generationID
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.descriptor = descriptor
        self.registeredRootCount = registeredRootCount
        self.handle = handle
    }

    // Intentionally no dlclose: Swift frames, metadata, closures, and witness
    // tables can retain addresses in a prior generation until process exit.
}

/// Native image preflight, persistence, and dynamic-loader failures.
public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    /// Mach-O structure, platform, architecture, signing, UUID, or dependencies failed preflight.
    case invalidImage(String)
    /// The image could not be persisted safely in the private cache.
    case writeFailed(String)
    /// `dlopen` rejected the preflighted image before registration.
    case dynamicLoaderRejected(String)
    /// The image was mapped but its generated registration root did not complete.
    ///
    /// Further native injection is unsafe because mapped Swift state cannot be
    /// rolled back; the App must restart.
    case stateUncertain(String)

    /// Human-readable native image failure detail.
    public var description: String {
        switch self {
        case let .invalidImage(reason): "native image preflight failed: \(reason)"
        case let .writeFailed(reason): "native image write failed: \(reason)"
        case let .dynamicLoaderRejected(reason): "dyld rejected native image: \(reason)"
        case let .stateUncertain(reason): "native image is mapped but registration is incomplete: \(reason)"
        }
    }
}

/// Abstraction over native image loading, primarily for deterministic tests.
public protocol Loading: Sendable {
    /// Preflights, persists, maps, and registers one offered native generation.
    func load(
        bytes: Data,
        offer: DevProtocol.PatchOffer,
        identity: DevProtocol.SessionIdentity,
        cacheDirectory: URL
    ) throws -> NativeImage.LoadedImage
}

/// System implementation backed by Mach-O inspection, `dlopen`, and `dlsym`.
///
/// This loader is development-only and relies on a correctly signed image built
/// for the exact process identity. Production hot patches use HLBC instead.
public struct SystemLoader: NativeImage.Loading {
    /// Creates a stateless system loader.
    public init() {}

    /// Loads and registers a complete native payload.
    ///
    /// The image UUID, signing presence, architecture, platform, install name,
    /// dependencies, and registration count are checked against the authenticated
    /// offer before a ``LoadedImage`` is returned.
    public func load(
        bytes: Data,
        offer: DevProtocol.PatchOffer,
        identity: DevProtocol.SessionIdentity,
        cacheDirectory: URL
    ) throws -> NativeImage.LoadedImage {
        let descriptor: MachO.Descriptor
        do {
            descriptor = try MachO.Inspector().inspect(bytes)
            let expectedArchitecture: MachO.Architecture
            switch identity.architecture {
            case "arm64", "arm64e": expectedArchitecture = .arm64
            case "x86_64": expectedArchitecture = .x86_64
            default:
                throw NativeImage.Error.invalidImage(
                    "unsupported process architecture \(identity.architecture)"
                )
            }
            let expectedPlatform: MachO.Platform
            switch identity.platform {
            case .iOS: expectedPlatform = .iOS
            case .iOSSimulator: expectedPlatform = .iOSSimulator
            case .macOS: expectedPlatform = .macOS
            }
            let stem = "HLXLive-\(identity.sessionID.uuidString)-g\(offer.generationID.rawValue)"
            try MachO.Inspector().preflight(
                descriptor,
                expectedArchitecture: expectedArchitecture,
                expectedInstallName: "@rpath/\(stem).dylib",
                expectedPlatform: expectedPlatform,
                allowedDependencyPrefixes: [
                    "/System/Library/", "/usr/lib/", "@rpath/",
                    "@loader_path/", "@executable_path/",
                ]
            )
            guard descriptor.isCodeSigned,
                  descriptor.uuid == offer.debugSymbolsUUID
            else {
                throw NativeImage.Error.invalidImage(
                    "code signature or Mach-O UUID does not match the offer"
                )
            }
        } catch {
            if let error = error as? NativeImage.Error { throw error }
            throw NativeImage.Error.invalidImage(String(describing: error))
        }
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            var directory = cacheDirectory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        } catch {
            throw NativeImage.Error.writeFailed(String(describing: error))
        }
        let fileURL = cacheDirectory.appendingPathComponent(
            "HLXLive-g\(offer.generationID.rawValue)-\(UUID().uuidString).dylib",
            isDirectory: false
        )
        do {
            let handle: FileHandle
            #if canImport(Darwin)
            let fileDescriptor = Darwin.open(
                fileURL.path,
                O_WRONLY | O_CREAT | O_EXCL,
                S_IRUSR | S_IWUSR | S_IXUSR
            )
            guard fileDescriptor >= 0 else {
                throw NativeImage.Error.writeFailed(
                    String(cString: strerror(errno))
                )
            }
            handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
            #else
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw NativeImage.Error.writeFailed("cannot exclusively create image file")
            }
            handle = try FileHandle(forWritingTo: fileURL)
            #endif
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            if let error = error as? NativeImage.Error { throw error }
            throw NativeImage.Error.writeFailed(String(describing: error))
        }

        #if canImport(Darwin)
        guard let imageHandle = dlopen(fileURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            try? FileManager.default.removeItem(at: fileURL)
            throw NativeImage.Error.dynamicLoaderRejected(reason)
        }
        typealias Registration = @convention(c) () -> UInt32
        guard let registrationSymbol = dlsym(imageHandle, "hlx_generation_registration_v1") else {
            throw NativeImage.Error.stateUncertain("registration symbol is missing")
        }
        let registration = unsafeBitCast(registrationSymbol, to: Registration.self)
        let rootCount = registration()
        guard rootCount == UInt32(offer.changedFunctions.count) else {
            throw NativeImage.Error.stateUncertain(
                "expected \(offer.changedFunctions.count) roots, image registered \(rootCount)"
            )
        }
        return .init(
            generationID: offer.generationID,
            fileURL: fileURL,
            byteCount: bytes.count,
            descriptor: descriptor,
            registeredRootCount: rootCount,
            handle: imageHandle
        )
        #else
        try? FileManager.default.removeItem(at: fileURL)
        throw NativeImage.Error.dynamicLoaderRejected("dlopen is unavailable")
        #endif
    }
}
}
