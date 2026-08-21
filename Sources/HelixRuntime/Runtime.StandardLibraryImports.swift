#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVM
#endif

extension Runtime {
/// Trusted Swift standard-library operations installed by every current Shell.
public enum StandardLibraryImports {
    static let maximumRenderedUTF8Bytes = 64 * 1_024

    private enum VariadicRenderingStyle: Sendable {
        case standard
        case debug

        var operationName: String {
            switch self {
            case .standard: "Swift.print"
            case .debug: "Swift.debugPrint"
            }
        }
    }

    private enum StringRenderingStyle: Sendable {
        case describing
        case reflecting

        var operationName: String {
            switch self {
            case .describing: "Swift.String.init(describing:)"
            case .reflecting: "Swift.String.init(reflecting:)"
            }
        }
    }

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
        makeVariadicOutput(
            id: id,
            key: key,
            descriptor: Bytecode.StandardLibraryImports.swiftPrint,
            style: .standard,
            emit: emit
        )
    }

    /// Creates the frozen NativeImport used for Swift `debugPrint` calls.
    public static func makeDebugPrint(
        id: Core.NativeImportID,
        key: Core.NativeImportKey
    ) -> any VM.NativeInvoker {
        makeDebugPrint(id: id, key: key) { output in
            Swift.print(output, terminator: "")
        }
    }

    static func makeDebugPrint(
        id: Core.NativeImportID,
        key: Core.NativeImportKey,
        emit: @escaping @Sendable (String) -> Void
    ) -> any VM.NativeInvoker {
        makeVariadicOutput(
            id: id,
            key: key,
            descriptor: Bytecode.StandardLibraryImports.swiftDebugPrint,
            style: .debug,
            emit: emit
        )
    }

    /// Creates the fixed Any bridge for Swift's generic describing initializer.
    public static func makeStringDescribing(
        id: Core.NativeImportID,
        key: Core.NativeImportKey
    ) -> any VM.NativeInvoker {
        makeStringRendering(
            id: id,
            key: key,
            descriptor: Bytecode.StandardLibraryImports.swiftStringDescribing,
            style: .describing
        )
    }

    /// Creates the fixed Any bridge for Swift's generic reflecting initializer.
    public static func makeStringReflecting(
        id: Core.NativeImportID,
        key: Core.NativeImportKey
    ) -> any VM.NativeInvoker {
        makeStringRendering(
            id: id,
            key: key,
            descriptor: Bytecode.StandardLibraryImports.swiftStringReflecting,
            style: .reflecting
        )
    }

    private static func makeVariadicOutput(
        id: Core.NativeImportID,
        key: Core.NativeImportKey,
        descriptor: Bytecode.StandardLibraryImports.Descriptor,
        style: VariadicRenderingStyle,
        emit: @escaping @Sendable (String) -> Void
    ) -> any VM.NativeInvoker {
        VM.ClosureNativeInvoker(
            id: id,
            key: key,
            parameterTypes: descriptor.parameterTypes,
            resultType: descriptor.resultType,
            effects: descriptor.effects,
            contract: descriptor.contract,
            invoke: { arguments, context in
                try context.checkpoint(workUnits: 1)
                let output = try formatVariadicOutput(
                    arguments: arguments,
                    style: style
                )
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

    private static func makeStringRendering(
        id: Core.NativeImportID,
        key: Core.NativeImportKey,
        descriptor: Bytecode.StandardLibraryImports.Descriptor,
        style: StringRenderingStyle
    ) -> any VM.NativeInvoker {
        VM.ClosureNativeInvoker(
            id: id,
            key: key,
            parameterTypes: descriptor.parameterTypes,
            resultType: descriptor.resultType,
            effects: descriptor.effects,
            contract: descriptor.contract,
            invoke: { arguments, context in
                try context.checkpoint(workUnits: 1)
                let output = try formatString(
                    arguments: arguments,
                    style: style
                )
                try context.checkpoint(
                    workUnits: UInt64(output.utf8.count / 16)
                )
                return .returned(.string(output))
            }
        )
    }

    static func formatPrint(arguments: [VM.Value]) throws -> String {
        try formatVariadicOutput(arguments: arguments, style: .standard)
    }

    static func formatDebugPrint(arguments: [VM.Value]) throws -> String {
        try formatVariadicOutput(arguments: arguments, style: .debug)
    }

    static func formatStringDescribing(arguments: [VM.Value]) throws -> String {
        try formatString(arguments: arguments, style: .describing)
    }

    static func formatStringReflecting(arguments: [VM.Value]) throws -> String {
        try formatString(arguments: arguments, style: .reflecting)
    }

    private static func formatVariadicOutput(
        arguments: [VM.Value],
        style: VariadicRenderingStyle
    ) throws -> String {
        guard arguments.count == 3,
              case let .array(storage) = arguments[0],
              storage.elementType == .any
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "\(style.operationName) expects Array<Any>, String, and String"
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

        var buffer = BoundedTextBuffer(
            maximumUTF8Bytes: maximumRenderedUTF8Bytes
        )
        for (index, value) in storage.elements.enumerated() {
            if index > 0 { buffer.write(separator) }
            let decoded = try Runtime.BridgeValueCodec.decodeAny(value)
            switch style {
            case .standard:
                Swift.print(decoded, terminator: "", to: &buffer)
            case .debug:
                Swift.debugPrint(decoded, terminator: "", to: &buffer)
            }
            if buffer.didExceedLimit { break }
        }
        if !buffer.didExceedLimit { buffer.write(terminator) }
        guard !buffer.didExceedLimit else {
            throw outputLimitFailure(operation: style.operationName)
        }
        return buffer.output
    }

    private static func formatString(
        arguments: [VM.Value],
        style: StringRenderingStyle
    ) throws -> String {
        guard arguments.count == 1 else {
            throw VM.RuntimeTrap.nativeFailure(
                "\(style.operationName) expects one Any value"
            )
        }
        let decoded = try Runtime.BridgeValueCodec.decodeAny(arguments[0])
        var buffer = BoundedTextBuffer(
            maximumUTF8Bytes: maximumRenderedUTF8Bytes
        )
        switch style {
        case .describing:
            Swift.print(decoded, terminator: "", to: &buffer)
        case .reflecting:
            Swift.debugPrint(decoded, terminator: "", to: &buffer)
        }
        guard !buffer.didExceedLimit else {
            throw outputLimitFailure(operation: style.operationName)
        }
        return buffer.output
    }

    private static func outputLimitFailure(
        operation: String
    ) -> VM.RuntimeTrap {
        .nativeFailure(
            "\(operation) output exceeds \(maximumRenderedUTF8Bytes) UTF-8 bytes"
        )
    }

    private struct BoundedTextBuffer: TextOutputStream {
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
