import Foundation

extension VM {
/// Native ABI metadata attached only to compiler-proven bridge types.
public enum NativeABI {}
}

extension VM.NativeABI {
/// Byte codec for one concrete, bitwise-copyable C or Objective-C value type.
/// The generated App bridge creates these codecs; downloaded HLBC can only use
/// a frozen TypeID and cannot nominate a Swift type or memory layout.
public struct Codec: Sendable {
    public let encoding: String
    public let size: UInt16
    public let alignment: UInt16

    private let encodeValue: @Sendable (VM.NativeValue) throws -> Data
    private let decodeValue: @Sendable (Data) throws -> VM.NativeValue

    public init<Value: BitwiseCopyable>(
        encoding: String,
        valueType: Value.Type = Value.self,
        box: @escaping @Sendable (Value) throws -> VM.NativeValue
    ) {
        precondition(!encoding.isEmpty && encoding.utf8.count <= 4_096)
        precondition(MemoryLayout<Value>.size > 0)
        precondition(MemoryLayout<Value>.size <= Int(UInt16.max))
        precondition(MemoryLayout<Value>.alignment <= Int(UInt16.max))
        self.encoding = encoding
        size = UInt16(MemoryLayout<Value>.size)
        alignment = UInt16(MemoryLayout<Value>.alignment)
        encodeValue = { native in
            guard let value = native.value(as: valueType) else {
                throw VM.RuntimeTrap.nativeTypeMismatch(expected: native.typeID)
            }
            var copy = value
            return withUnsafeBytes(of: &copy) { Data($0) }
        }
        decodeValue = { bytes in
            guard bytes.count == MemoryLayout<Value>.size else {
                throw VM.RuntimeTrap.nativeFailure(
                    "native ABI value has an invalid byte count"
                )
            }
            let value = bytes.withUnsafeBytes {
                $0.loadUnaligned(as: Value.self)
            }
            return try box(value)
        }
    }

    package func encode(_ value: VM.NativeValue) throws -> Data {
        let result = try encodeValue(value)
        guard result.count == Int(size) else {
            throw VM.RuntimeTrap.nativeFailure(
                "native ABI encoder returned an invalid byte count"
            )
        }
        return result
    }

    package func decode(_ bytes: Data) throws -> VM.NativeValue {
        try decodeValue(bytes)
    }
}
}
