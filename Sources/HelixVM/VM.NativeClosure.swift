import Foundation
#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// One typed, native-origin callable represented as a VM closure.
///
/// The Swift closure context is deliberately type-erased only after generated
/// code has frozen its exact callable signature. The wrapper is unchecked
/// Sendable because Swift callback values are not assumed Sendable; a recursive
/// admission gate rejects overlapping invocation while permitting ordinary
/// same-thread re-entry.
package final class NativeClosure: @unchecked Sendable, Hashable {
    /// Fixed retained-handle accounting shared by the bridge encoder and VM.
    /// The native capture graph is not copied into VM ownership.
    package static let estimatedVMByteCount: UInt64 = 64

    package let signature: Bytecode.ClosureSignature

    private let invocation: (
        [VM.Value],
        VM.InvocationBudget
    ) throws -> VM.Value?
    private let executionGate = VM.NativeCallbackExecutionGate()

    package init(
        signature: Bytecode.ClosureSignature,
        invoke: @escaping (
            [VM.Value],
            VM.InvocationBudget
        ) throws -> VM.Value?
    ) {
        self.signature = signature
        invocation = invoke
    }

    package func invoke(
        arguments: [VM.Value],
        budget: VM.InvocationBudget
    ) throws -> VM.Value? {
        try budget.checkDeadline()
        guard signature.isNativeBridgeCallable,
              arguments.count == signature.parameters.count,
              zip(arguments, signature.parameters).allSatisfy({
                  $0.matches($1)
              })
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "native closure invocation disagrees with its frozen ABI"
            )
        }
        guard !signature.effects.requiresMainActor || Thread.isMainThread else {
            throw VM.RuntimeTrap.mainActorViolation
        }
        guard executionGate.tryEnter() else {
            throw VM.RuntimeTrap.nativeFailure(
                "concurrent invocation of a non-Sendable native closure is unsupported"
            )
        }
        defer { executionGate.leave() }

        let result: VM.Value?
        do {
            result = try invocation(arguments, budget)
        } catch let trap as VM.RuntimeTrap {
            try budget.checkDeadline()
            throw trap
        } catch {
            try budget.checkDeadline()
            throw VM.RuntimeTrap.nativeFailure(
                "native closure bridge failed: \(error)"
            )
        }
        try budget.checkDeadline()
        guard result?.matches(signature.result) ?? (signature.result == .void)
        else {
            throw VM.RuntimeTrap.typeMismatch(
                expected: signature.result,
                actual: result?.type
            )
        }
        return result
    }

    package static func == (lhs: VM.NativeClosure, rhs: VM.NativeClosure) -> Bool {
        lhs === rhs
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
}
