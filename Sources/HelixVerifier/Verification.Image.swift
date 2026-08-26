import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

extension Verification {
public struct NativeCallContext: Equatable, Sendable, CustomStringConvertible {
    public var key: Core.NativeCall.Key
    public var location: Core.SourceLocation?

    public init(
        key: Core.NativeCall.Key,
        location: Core.SourceLocation? = nil
    ) {
        self.key = key
        self.location = location
    }

    public var description: String {
        let prefix = location.map { "\($0): " } ?? ""
        return "\(prefix)native call \(key)"
    }
}

public struct Image: Sendable {
    public let imageHash: Core.Digest
    public let module: Bytecode.Module
    public let shell: Verification.ShellInterface
    public let effectiveResourceLimits: Core.ResourceLimits

    init(
        imageHash: Core.Digest,
        module: Bytecode.Module,
        shell: Verification.ShellInterface,
        effectiveResourceLimits: Core.ResourceLimits
    ) {
        self.imageHash = imageHash
        self.module = module
        self.shell = shell
        self.effectiveResourceLimits = effectiveResourceLimits
    }

    public func function(id: Bytecode.FunctionID) -> Bytecode.Function? {
        module.functions.first { $0.id == id }
    }

    public func function(entry: Core.EntryIndex) -> Bytecode.Function? {
        guard let mapping = module.entries.first(where: { $0.entryIndex == entry }) else { return nil }
        return function(id: mapping.functionID)
    }
}

public protocol ImageVerifying: Sendable {
    func verify(
        bytes: Data,
        shell: Verification.ShellInterface,
        policy: Core.RuntimePolicy
    ) throws -> Verification.Image
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidShellInterface(String)
    case shellInterfaceHashMismatch
    case incompatibleToolchain
    case runtimeVersionTooOld(requiredMajor: UInt16, actualMajor: UInt16)
    case missingBaselineCapability
    case unsupportedCapability(Core.Capability)
    case capabilityDenied(Core.Capability)
    case capabilityUnavailableInShell(Core.Capability)
    case duplicateFunction(Bytecode.FunctionID)
    case duplicateEntry(Core.EntryIndex)
    case duplicateNativeCall(Verification.NativeCallContext)
    case unknownEntry(Core.EntryIndex)
    case entryKeyMismatch(Core.EntryIndex)
    case entrySignatureMismatch(Core.EntryIndex)
    case unknownNativeCall(Verification.NativeCallContext)
    case nativeCallDescriptorMismatch(Verification.NativeCallContext)
    case nativeCallDenied(Verification.NativeCallContext)
    case unknownNativeType(Core.TypeID)
    case invalidModule(String)
    case invalidSourceMap(String)
    case invalidFunction(function: Bytecode.FunctionID, reason: String)
    case invalidBlock(function: Bytecode.FunctionID, block: Bytecode.BlockID, reason: String)
    case invalidInstruction(function: Bytecode.FunctionID, block: Bytecode.BlockID, offset: Int, reason: String)

    public var description: String {
        switch self {
        case let .invalidShellInterface(reason): "invalid shell interface: \(reason)"
        case .shellInterfaceHashMismatch: "HLBC image targets a different Shell interface"
        case .incompatibleToolchain: "HLBC compatibility tuple does not match the Shell"
        case let .runtimeVersionTooOld(required, actual):
            "HLBC requires runtime major \(required), current runtime major is \(actual)"
        case .missingBaselineCapability: "HLBC baseline capability is missing"
        case let .unsupportedCapability(capability): "this Runtime does not implement capability \(capability)"
        case let .capabilityDenied(capability): "runtime policy denies capability \(capability)"
        case let .capabilityUnavailableInShell(capability): "Shell does not provide capability \(capability)"
        case let .duplicateFunction(id): "duplicate HLBC function \(id)"
        case let .duplicateEntry(index): "duplicate HLBC entry \(index)"
        case let .duplicateNativeCall(context):
            "\(context) is declared more than once"
        case let .unknownEntry(index): "unknown Shell entry \(index)"
        case let .entryKeyMismatch(index): "function key mismatch for Shell entry \(index)"
        case let .entrySignatureMismatch(index): "signature mismatch for Shell entry \(index)"
        case let .unknownNativeCall(context):
            "\(context) is not published by this Shell"
        case let .nativeCallDescriptorMismatch(context):
            "\(context) does not match the Shell descriptor"
        case let .nativeCallDenied(context):
            "runtime policy denies \(context)"
        case let .unknownNativeType(type): "Shell does not provide native type \(type)"
        case let .invalidModule(reason): "invalid HLBC module: \(reason)"
        case let .invalidSourceMap(reason): "invalid HLBC source map: \(reason)"
        case let .invalidFunction(function, reason): "invalid function \(function): \(reason)"
        case let .invalidBlock(function, block, reason): "invalid block \(function).\(block): \(reason)"
        case let .invalidInstruction(function, block, offset, reason):
            "invalid instruction \(function).\(block)#\(offset): \(reason)"
        }
    }
}
}
