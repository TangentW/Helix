import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixDevProtocol
import HelixRuntime
import HelixVM
#endif

#if canImport(Darwin)
import Darwin
#endif

/// Development-only loading of exact Swift Adapter bodies and Catalog-bound C
/// symbols. Dynamic Replacement registration is intentionally a separate API.
public enum DevelopmentAdapter {}

extension DevelopmentAdapter {
public final class LoadedImage: @unchecked Sendable {
    public let fileURL: URL
    public let byteCount: Int
    public let descriptor: MachO.Descriptor
    public let nativeInvokers: [any VM.NativeInvoker]
    public let asyncNativeInvokers: [any VM.AsyncNativeInvoker]
    let handle: UnsafeMutableRawPointer?

    public init(
        fileURL: URL,
        byteCount: Int,
        descriptor: MachO.Descriptor,
        nativeInvokers: [any VM.NativeInvoker],
        asyncNativeInvokers: [any VM.AsyncNativeInvoker] = [],
        handle: UnsafeMutableRawPointer? = nil
    ) {
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.descriptor = descriptor
        self.nativeInvokers = nativeInvokers
        self.asyncNativeInvokers = asyncNativeInvokers
        self.handle = handle
    }

    // No dlclose: invokers and escaped native callbacks can retain executable
    // addresses from this image until the development process exits.
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidImage(String)
    case writeFailed(String)
    case dynamicLoaderRejected(String)
    case stateUncertain(String)
    case unknownCFunction(String)

    public var description: String {
        switch self {
        case let .invalidImage(reason):
            "development Adapter preflight failed: \(reason)"
        case let .writeFailed(reason):
            "development Adapter write failed: \(reason)"
        case let .dynamicLoaderRejected(reason):
            "dyld rejected development Adapter: \(reason)"
        case let .stateUncertain(reason):
            "development Adapter was mapped but could not be bound: \(reason)"
        case let .unknownCFunction(symbol):
            "cataloged C function is not linked into this process: \(symbol)"
        }
    }

    public var isStateUncertain: Bool {
        if case .stateUncertain = self { return true }
        return false
    }
}

public protocol Loading: Sendable {
    func load(
        bytes: Data,
        descriptor: DevProtocol.DevelopmentPayload.Image,
        imports: [DevProtocol.DevelopmentPayload.NativeImport],
        identity: DevProtocol.SessionIdentity,
        cacheDirectory: URL
    ) throws -> DevelopmentAdapter.LoadedImage

    func makeCInvoker(
        for nativeImport: DevProtocol.DevelopmentPayload.NativeImport
    ) throws -> any VM.NativeInvoker
}

public struct SystemLoader: DevelopmentAdapter.Loading {
    public init() {}

    public func load(
        bytes: Data,
        descriptor expected: DevProtocol.DevelopmentPayload.Image,
        imports: [DevProtocol.DevelopmentPayload.NativeImport],
        identity: DevProtocol.SessionIdentity,
        cacheDirectory: URL
    ) throws -> DevelopmentAdapter.LoadedImage {
        guard !imports.isEmpty,
              imports.allSatisfy({
                  $0.binding == .swiftAdapter
                      && $0.exportSymbol != nil
                      && $0.descriptor.target.backend == .swiftAdapter
              }),
              UInt64(bytes.count) == expected.byteLength,
              Core.Digest.sha256(bytes) == expected.sha256
        else {
            throw DevelopmentAdapter.Error.invalidImage(
                "manifest, imports, length, or hash is inconsistent"
            )
        }
        let descriptor: MachO.Descriptor
        do {
            descriptor = try MachO.Inspector().inspect(bytes)
            try MachO.Inspector().preflight(
                descriptor,
                expectedArchitecture: try architecture(identity.architecture),
                expectedInstallName: expected.installName,
                expectedPlatform: platform(identity.platform),
                allowedDependencyPrefixes: [
                    "/System/Library/", "/usr/lib/", "@rpath/",
                    "@loader_path/", "@executable_path/",
                ]
            )
            guard descriptor.isCodeSigned, descriptor.uuid == expected.uuid else {
                throw DevelopmentAdapter.Error.invalidImage(
                    "code signature or Mach-O UUID does not match the transaction"
                )
            }
        } catch let error as DevelopmentAdapter.Error {
            throw error
        } catch {
            throw DevelopmentAdapter.Error.invalidImage(String(describing: error))
        }

        try prepare(cacheDirectory)
        let fileURL = cacheDirectory.appendingPathComponent(
            "HLXDevAdapter-\(expected.uuid.uuidString)-\(UUID().uuidString).dylib"
        )
        try write(bytes, to: fileURL)

        #if canImport(Darwin)
        guard let handle = dlopen(fileURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) }
                ?? "unknown dlopen error"
            try? FileManager.default.removeItem(at: fileURL)
            throw DevelopmentAdapter.Error.dynamicLoaderRejected(reason)
        }
        typealias Factory = @convention(c) () -> UnsafeMutableRawPointer?
        let factories: [(DevProtocol.DevelopmentPayload.NativeImport, Factory)]
        do {
            factories = try imports.map { nativeImport in
                guard let name = nativeImport.exportSymbol,
                      let symbol = dlsym(handle, name)
                else {
                    throw DevelopmentAdapter.Error.invalidImage(
                        "required Adapter export is missing for \(nativeImport.key)"
                    )
                }
                return (nativeImport, unsafeBitCast(symbol, to: Factory.self))
            }
        } catch {
            dlclose(handle)
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        let retainedBodies = factories.map { ($0.0, $0.1()) }
        guard retainedBodies.allSatisfy({ $0.1 != nil }) else {
            for (nativeImport, pointer) in retainedBodies {
                guard let pointer else { continue }
                if nativeImport.descriptor.effects.isAsync {
                    _ = Unmanaged<Runtime.AsyncNativeAdapterBody>
                        .fromOpaque(pointer).takeRetainedValue()
                } else {
                    _ = Unmanaged<Runtime.NativeAdapterBody>
                        .fromOpaque(pointer).takeRetainedValue()
                }
            }
            dlclose(handle)
            try? FileManager.default.removeItem(at: fileURL)
            throw DevelopmentAdapter.Error.stateUncertain(
                "an exported Adapter factory returned no body"
            )
        }
        var nativeInvokers: [any VM.NativeInvoker] = []
        var asyncInvokers: [any VM.AsyncNativeInvoker] = []
        for (nativeImport, pointer) in retainedBodies {
            guard let pointer else { continue }
            if nativeImport.descriptor.effects.isAsync {
                let body = Unmanaged<Runtime.AsyncNativeAdapterBody>
                    .fromOpaque(pointer).takeRetainedValue()
                asyncInvokers.append(body.makeInvoker(
                    id: nativeImport.id,
                    key: nativeImport.key,
                    parameterTypes: nativeImport.parameterTypes,
                    resultType: nativeImport.resultType,
                    effects: nativeImport.descriptor.effects,
                    contract: nativeImport.contract
                ))
            } else {
                let body = Unmanaged<Runtime.NativeAdapterBody>
                    .fromOpaque(pointer).takeRetainedValue()
                nativeInvokers.append(body.makeInvoker(
                    id: nativeImport.id,
                    key: nativeImport.key,
                    parameterTypes: nativeImport.parameterTypes,
                    resultType: nativeImport.resultType,
                    effects: nativeImport.descriptor.effects,
                    contract: nativeImport.contract
                ))
            }
        }
        return .init(
            fileURL: fileURL,
            byteCount: bytes.count,
            descriptor: descriptor,
            nativeInvokers: nativeInvokers,
            asyncNativeInvokers: asyncInvokers,
            handle: handle
        )
        #else
        try? FileManager.default.removeItem(at: fileURL)
        throw DevelopmentAdapter.Error.dynamicLoaderRejected(
            "dlopen is unavailable"
        )
        #endif
    }

    public func makeCInvoker(
        for nativeImport: DevProtocol.DevelopmentPayload.NativeImport
    ) throws -> any VM.NativeInvoker {
        guard nativeImport.binding == .cInvoker,
              nativeImport.descriptor.target.backend == .cFunction,
              !nativeImport.descriptor.effects.isAsync,
              nativeImport.imageIndex == nil,
              nativeImport.exportSymbol == nil
        else {
            throw DevelopmentAdapter.Error.invalidImage(
                "C invoker request has an inconsistent descriptor"
            )
        }
        #if canImport(Darwin)
        guard let process = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(
                  process,
                  nativeImport.descriptor.target.entryPoint
              )
        else {
            throw DevelopmentAdapter.Error.unknownCFunction(
                nativeImport.descriptor.target.entryPoint
            )
        }
        defer { dlclose(process) }
        let invoker = Runtime.CInvoker(
            id: nativeImport.id,
            key: nativeImport.key,
            descriptor: nativeImport.descriptor,
            function: UnsafeRawPointer(symbol),
            parameterTypes: nativeImport.parameterTypes,
            resultType: nativeImport.resultType,
            effects: nativeImport.descriptor.effects,
            contract: nativeImport.contract
        )
        try invoker.validateConfiguration()
        return invoker
        #else
        throw DevelopmentAdapter.Error.unknownCFunction(
            nativeImport.descriptor.target.entryPoint
        )
        #endif
    }

    private func prepare(_ cacheDirectory: URL) throws {
        guard cacheDirectory.isFileURL, cacheDirectory.path.hasPrefix("/") else {
            throw DevelopmentAdapter.Error.writeFailed("cache path is invalid")
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
            throw DevelopmentAdapter.Error.writeFailed(String(describing: error))
        }
    }

    private func write(_ bytes: Data, to fileURL: URL) throws {
        do {
            #if canImport(Darwin)
            let descriptor = Darwin.open(
                fileURL.path,
                O_WRONLY | O_CREAT | O_EXCL,
                S_IRUSR | S_IWUSR | S_IXUSR
            )
            guard descriptor >= 0 else {
                throw DevelopmentAdapter.Error.writeFailed(
                    String(cString: strerror(errno))
                )
            }
            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: true
            )
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            try handle.close()
            #else
            guard FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil
            ) else {
                throw DevelopmentAdapter.Error.writeFailed(
                    "cannot exclusively create Adapter image"
                )
            }
            try bytes.write(to: fileURL)
            #endif
        } catch let error as DevelopmentAdapter.Error {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw DevelopmentAdapter.Error.writeFailed(String(describing: error))
        }
    }

    private func architecture(_ value: String) throws -> MachO.Architecture {
        switch value {
        case "arm64", "arm64e": .arm64
        case "x86_64": .x86_64
        default:
            throw DevelopmentAdapter.Error.invalidImage(
                "unsupported process architecture \(value)"
            )
        }
    }

    private func platform(_ value: DevProtocol.ApplePlatform) -> MachO.Platform {
        switch value {
        case .iOS: .iOS
        case .iOSSimulator: .iOSSimulator
        case .macOS: .macOS
        }
    }
}
}
