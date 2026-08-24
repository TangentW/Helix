import Foundation
#if canImport(HelixCore)
import HelixCore
import HelixVM
#endif

extension Runtime {
/// Opaque, one-shot dispatch prepared by a generated async Swift wrapper
/// before that wrapper reaches its first suspension point.
///
/// Preparation pins one immutable generation and encodes arguments while
/// the permanent source-body wrapper can still choose its lexical original.
/// App code cannot construct or inspect this value, and a prepared dispatch
/// cannot be replayed or transferred to another ``Bridge`` installation.
public final class PreparedAsyncBridgeDispatch: @unchecked Sendable {
    struct Payload {
        let bridgeID: UUID
        let runtime: Runtime.Engine
        let context: Runtime.ExecutionContext
        let entry: Core.EntryIndex
        let arguments: [VM.Value]
    }

    private let lock = NSLock()
    private var payload: Payload?

    init(
        bridgeID: UUID,
        runtime: Runtime.Engine,
        context: Runtime.ExecutionContext,
        entry: Core.EntryIndex,
        arguments: [VM.Value]
    ) {
        payload = .init(
            bridgeID: bridgeID,
            runtime: runtime,
            context: context,
            entry: entry,
            arguments: arguments
        )
    }

    func consume(
        bridgeID: UUID,
        runtime: Runtime.Engine
    ) throws -> Payload {
        try lock.withLock {
            guard let payload else {
                throw VM.RuntimeTrap.nativeFailure(
                    "prepared async Bridge dispatch was reused"
                )
            }
            guard payload.bridgeID == bridgeID, payload.runtime === runtime else {
                throw VM.RuntimeTrap.nativeFailure(
                    "prepared async Bridge dispatch belongs to another installation"
                )
            }
            self.payload = nil
            return payload
        }
    }
}
}
