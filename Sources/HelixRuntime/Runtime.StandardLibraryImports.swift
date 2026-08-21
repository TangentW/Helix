#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVM
#endif

extension Runtime {
/// Trusted Swift standard-library operations installed by every current Shell.
public enum StandardLibraryImports {
    static let maximumPrintUTF8Bytes = 64 * 1_024

    /// Creates the frozen NativeImport used for ordinary Swift `print` calls.
    public static func makePrint(
        id: Core.NativeImportID,
        key: Core.NativeImportKey
    ) -> any VM.NativeInvoker {
        makePrint(id: id, key: key) { output in
            Swift.print(output, terminator: "")
        }
    }

    static func makePrint(
        id: Core.NativeImportID,
        key: Core.NativeImportKey,
        emit: @escaping @Sendable (String) -> Void
    ) -> any VM.NativeInvoker {
        let descriptor = Bytecode.StandardLibraryImports.swiftPrint
        return VM.ClosureNativeInvoker(
            id: id,
            key: key,
            parameterTypes: descriptor.parameterTypes,
            resultType: descriptor.resultType,
            effects: descriptor.effects,
            contract: descriptor.contract,
            invoke: { arguments, context in
                try context.checkpoint(workUnits: 1)
                let output = try formatPrint(arguments: arguments)
                try context.checkpoint(
                    workUnits: UInt64(output.utf8.count / 16)
                )
                emit(output)
                // I/O is synchronous by contract. The post-write checkpoint
                // detects a deadline overrun before control returns to HLBC.
                try context.checkpoint()
                return .returned(nil)
            }
        )
    }

    static func formatPrint(arguments: [VM.Value]) throws -> String {
        guard arguments.count == 3,
              case let .array(storage) = arguments[0],
              storage.elementType == .any
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "Swift.print expects Array<Any>, String, and String"
            )
        }
        let separator = try Runtime.BridgeValueCodec.decode(
            arguments[1],
            as: String.self
        )
        let terminator = try Runtime.BridgeValueCodec.decode(
            arguments[2],
            as: String.self
        )

        var buffer = PrintBuffer(maximumUTF8Bytes: maximumPrintUTF8Bytes)
        for (index, value) in storage.elements.enumerated() {
            if index > 0 { buffer.write(separator) }
            let decoded = try Runtime.BridgeValueCodec.decodeAny(value)
            Swift.print(decoded, terminator: "", to: &buffer)
            if buffer.didExceedLimit { break }
        }
        if !buffer.didExceedLimit { buffer.write(terminator) }
        guard !buffer.didExceedLimit else {
            throw VM.RuntimeTrap.nativeFailure(
                "Swift.print output exceeds \(maximumPrintUTF8Bytes) UTF-8 bytes"
            )
        }
        return buffer.output
    }

    private struct PrintBuffer: TextOutputStream {
        var output = ""
        var utf8ByteCount = 0
        var didExceedLimit = false
        let maximumUTF8Bytes: Int

        init(maximumUTF8Bytes: Int) {
            self.maximumUTF8Bytes = maximumUTF8Bytes
            output.reserveCapacity(256)
        }

        mutating func write(_ string: String) {
            guard !didExceedLimit else { return }
            let next = utf8ByteCount.addingReportingOverflow(string.utf8.count)
            guard !next.overflow, next.partialValue <= maximumUTF8Bytes else {
                didExceedLimit = true
                return
            }
            output.append(contentsOf: string)
            utf8ByteCount = next.partialValue
        }
    }
}
}
