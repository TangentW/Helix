import Foundation
import HelixCore
import HelixVerifier
import HelixVM

extension Runtime.Engine {
/// Verifies that the code-signed production registry, Shell descriptors, and
/// canonical Release manifest describe one exact immutable capability table.
/// Objective-C and C entries additionally recheck their ABI on this device.
public func validateNativeCapabilities(
    against manifest: Core.NativeCapability.Manifest,
    shell: Verification.ShellInterface
) throws {
    do {
        try manifest.validate()
    } catch {
        throw Runtime.NativeCapabilityError.invalidManifest(
            String(describing: error)
        )
    }
    guard shell.interfaceHash == manifest.identity.shellInterfaceHash,
          shell.interfaceHash == shellInterfaceHash,
          shell.compatibility == manifest.identity.compatibility,
          shell.capabilities == Set(manifest.capabilities),
          shell.imports.count == manifest.entries.count
    else {
        throw Runtime.NativeCapabilityError.shellMismatch
    }

    let expectedIDs = Set(manifest.entries.map(\.id))
    guard nativeCatalog.ids.isDisjoint(with: asyncNativeCatalog.ids),
          nativeCatalog.ids.union(asyncNativeCatalog.ids) == expectedIDs
    else {
        throw Runtime.NativeCapabilityError.registryInventoryMismatch
    }

    var objectiveCInvokers: [Runtime.ObjectiveCInvoker] = []
    var cInvokers: [Runtime.CInvoker] = []
    for entry in manifest.entries {
        guard let resolved = shell.imports[entry.id],
              resolved.key == entry.key,
              resolved.descriptor == entry.descriptor,
              resolved.contract == entry.contract,
              resolved.capability == entry.requiredCapability
        else {
            throw Runtime.NativeCapabilityError.entryMismatch(entry.key)
        }
        if resolved.effects.isAsync {
            guard let invoker = asyncNativeCatalog[entry.id],
                  invoker.key == entry.key,
                  invoker.parameterTypes == resolved.parameterTypes,
                  invoker.resultType == resolved.resultType,
                  invoker.effects == resolved.effects,
                  invoker.contract == resolved.contract,
                  entry.descriptor.target.backend == .swiftAdapter
                    || entry.descriptor.target.backend == .builtin
            else {
                throw Runtime.NativeCapabilityError.entryMismatch(entry.key)
            }
            continue
        }

        guard let invoker = nativeCatalog[entry.id],
              invoker.key == entry.key,
              invoker.parameterTypes == resolved.parameterTypes,
              invoker.resultType == resolved.resultType,
              invoker.effects == resolved.effects,
              invoker.contract == resolved.contract
        else {
            throw Runtime.NativeCapabilityError.entryMismatch(entry.key)
        }
        switch entry.descriptor.target.backend {
        case .objectiveCMessage:
            guard let objectiveC = invoker as? Runtime.ObjectiveCInvoker,
                  objectiveC.descriptor == entry.descriptor
            else {
                throw Runtime.NativeCapabilityError.entryMismatch(entry.key)
            }
            objectiveCInvokers.append(objectiveC)
        case .cFunction:
            guard let c = invoker as? Runtime.CInvoker,
                  c.descriptor == entry.descriptor
            else {
                throw Runtime.NativeCapabilityError.entryMismatch(entry.key)
            }
            cInvokers.append(c)
        case .swiftAdapter, .builtin:
            break
        }
    }
    let manifestHash = try manifest.contentHash()
    try nativeCapabilityValidationState.validateOnce(for: manifestHash) {
        for invoker in objectiveCInvokers {
            do {
                try invoker.validateRuntimeABI()
            } catch {
                throw Runtime.NativeCapabilityError.deviceABIRejected(
                    invoker.key,
                    String(describing: error)
                )
            }
        }
        for invoker in cInvokers {
            do {
                try invoker.validateRuntimeABI()
            } catch {
                throw Runtime.NativeCapabilityError.deviceABIRejected(
                    invoker.key,
                    String(describing: error)
                )
            }
        }
    }
}
}

extension Runtime {
final class NativeCapabilityValidationState: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptedManifest: Core.Digest?

    func validateOnce(
        for manifestHash: Core.Digest,
        _ body: () throws -> Void
    ) throws {
        try lock.withLock {
            if let acceptedManifest {
                guard acceptedManifest == manifestHash else {
                    throw Runtime.NativeCapabilityError.manifestIdentityMismatch
                }
                return
            }
            try body()
            acceptedManifest = manifestHash
        }
    }
}

public enum NativeCapabilityError: Swift.Error, Equatable, Sendable,
    CustomStringConvertible {
    case invalidManifest(String)
    case shellMismatch
    case manifestIdentityMismatch
    case registryInventoryMismatch
    case entryMismatch(Core.NativeCall.Key)
    case deviceABIRejected(Core.NativeCall.Key, String)

    public var description: String {
        switch self {
        case let .invalidManifest(reason):
            "invalid Release native capability manifest: \(reason)"
        case .shellMismatch:
            "Release native capability manifest does not match the linked Shell"
        case .manifestIdentityMismatch:
            "production Runtime cannot replace its pinned native capability manifest"
        case .registryInventoryMismatch:
            "production native Registry does not exactly match the Release manifest"
        case let .entryMismatch(key):
            "production native capability \(key) disagrees across Manifest, Shell, or Registry"
        case let .deviceABIRejected(key, reason):
            "device ABI rejected released native capability \(key): \(reason)"
        }
    }
}
}
