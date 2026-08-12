import HelixBytecode

extension VM {
/// Runtime-owned bridge for local classes backed by an Objective-C instance.
///
/// The VM supplies logical identity and field storage. The host supplies only
/// allocation and exact-super dispatch for descriptors accepted by Verifier.
public struct ObjectHost: @unchecked Sendable {
    public typealias Allocator = @Sendable (
        _ object: VM.ObjectReference,
        _ definition: Bytecode.LocalTypeDefinition
    ) throws -> VM.NativeValue

    public typealias SuperInvoker = @Sendable (
        _ object: VM.ObjectReference,
        _ method: Bytecode.HostedMethod,
        _ arguments: [VM.Value]
    ) throws -> Void

    private let allocator: Allocator
    private let superInvoker: SuperInvoker

    public init(
        allocate: @escaping Allocator,
        invokeSuper: @escaping SuperInvoker
    ) {
        allocator = allocate
        superInvoker = invokeSuper
    }

    func allocate(
        object: VM.ObjectReference,
        definition: Bytecode.LocalTypeDefinition
    ) throws -> VM.NativeValue {
        try allocator(object, definition)
    }

    func invokeSuper(
        object: VM.ObjectReference,
        method: Bytecode.HostedMethod,
        arguments: [VM.Value]
    ) throws {
        try superInvoker(object, method, arguments)
    }
}
}
