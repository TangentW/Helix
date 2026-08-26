import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVM
#endif

extension Runtime {
/// Shared byte storage and scalar/value codec for verified native ABI slots.
/// Object and callback ownership remain backend-specific.
enum NativeABIValue {}
}

extension Runtime.NativeABIValue {
final class Allocation {
    let pointer: UnsafeMutableRawPointer
    let byteCount: Int

    init(byteCount: Int, alignment: Int) {
        self.byteCount = byteCount
        pointer = .allocate(
            byteCount: max(1, byteCount),
            alignment: max(1, alignment)
        )
        pointer.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: max(1, byteCount)
        )
    }

    deinit { pointer.deallocate() }
}

final class CString {
    let pointer: UnsafeMutablePointer<CChar>
    private let count: Int

    init(_ value: String) {
        let bytes = Array(value.utf8CString)
        count = bytes.count
        pointer = .allocate(capacity: bytes.count)
        bytes.withUnsafeBufferPointer {
            pointer.initialize(from: $0.baseAddress!, count: $0.count)
        }
    }

    deinit {
        pointer.deinitialize(count: count)
        pointer.deallocate()
    }
}

static func encode(
    _ value: VM.Value,
    as physical: Core.NativeCall.ABIType,
    catalog: VM.NativeTypeCatalog
) throws -> Allocation {
    guard let size = physical.size,
          let alignment = physical.alignment,
          let encoding = physical.encoding
    else {
        throw VM.RuntimeTrap.nativeFailure(
            "native ABI parameter has incomplete storage metadata"
        )
    }
    let bytes: Data
    switch physical.kind {
    case .boolean:
        guard case let .bool(value) = value, size == 1 else {
            throw VM.RuntimeTrap.typeMismatch(expected: .bool, actual: value.type)
        }
        bytes = Data([value ? 1 : 0])
    case .signedInteger, .unsignedInteger:
        guard case let .integer(integer) = value,
              integer.bitWidth == size * 8,
              integer.isSigned == (physical.kind == .signedInteger)
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "native integer width or signedness mismatch"
            )
        }
        bytes = lowBytes(integer.rawBits, count: Int(size))
    case .floatingPoint:
        guard case let .float(float) = value,
              float.bitWidth == size * 8
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "native floating-point width mismatch"
            )
        }
        bytes = lowBytes(float.bitPattern, count: Int(size))
    case .structure:
        guard case let .native(native) = value else {
            throw VM.RuntimeTrap.nativeFailure(
                "native structure requires a native ABI value"
            )
        }
        bytes = try catalog.encodeNativeABI(
            native,
            expectedEncoding: encoding,
            expectedSize: size,
            expectedAlignment: alignment
        )
    case .void, .bridgeValue, .object, .classObject, .selector, .block,
         .pointer:
        throw VM.RuntimeTrap.nativeFailure(
            "native ABI parameter kind \(physical.kind) cannot use byte storage"
        )
    }
    guard bytes.count == Int(size) else {
        throw VM.RuntimeTrap.nativeFailure(
            "native ABI encoder returned an invalid byte count"
        )
    }
    let allocation = Allocation(
        byteCount: bytes.count,
        alignment: Int(alignment)
    )
    bytes.withUnsafeBytes { source in
        guard let baseAddress = source.baseAddress else { return }
        allocation.pointer.copyMemory(
            from: baseAddress,
            byteCount: bytes.count
        )
    }
    return allocation
}

static func decode(
    _ bytes: Data,
    physical: Core.NativeCall.ABIType,
    logical: Bytecode.ValueType,
    catalog: VM.NativeTypeCatalog
) throws -> VM.Value? {
    switch physical.kind {
    case .void:
        guard logical == .void, bytes.isEmpty else {
            throw VM.RuntimeTrap.nativeFailure(
                "native Void result disagrees with its logical type"
            )
        }
        return nil
    case .boolean:
        guard logical == .bool, bytes.count == 1 else {
            throw VM.RuntimeTrap.nativeFailure(
                "native Bool result disagrees with its logical type"
            )
        }
        return .bool(bytes[bytes.startIndex] != 0)
    case .signedInteger, .unsignedInteger:
        guard case let .integer(width, signed) = logical,
              let size = physical.size,
              bytes.count == Int(size),
              width == size * 8,
              signed == (physical.kind == .signedInteger)
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "native integer result disagrees with its logical type"
            )
        }
        return .integer(try .init(
            rawBits: bits(bytes),
            bitWidth: width,
            isSigned: signed
        ))
    case .floatingPoint:
        guard case let .float(width) = logical,
              let size = physical.size,
              bytes.count == Int(size),
              width == size * 8
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "native floating-point result disagrees with its logical type"
            )
        }
        return .float(try .init(
            bitPattern: bits(bytes),
            bitWidth: width
        ))
    case .structure:
        guard case let .native(id) = logical,
              let encoding = physical.encoding,
              let size = physical.size,
              let alignment = physical.alignment,
              bytes.count == Int(size)
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "native structure result disagrees with its logical type"
            )
        }
        return .native(try catalog.decodeNativeABI(
            bytes,
            as: id,
            expectedEncoding: encoding,
            expectedSize: size,
            expectedAlignment: alignment
        ))
    case .bridgeValue, .object, .classObject, .selector, .block, .pointer:
        throw VM.RuntimeTrap.nativeFailure(
            "native ABI result kind \(physical.kind) cannot use byte storage"
        )
    }
}

private static func lowBytes(_ value: UInt64, count: Int) -> Data {
    var copy = value
    return withUnsafeBytes(of: &copy) { Data($0.prefix(count)) }
}

private static func bits(_ bytes: Data) -> UInt64 {
    var value: UInt64 = 0
    withUnsafeMutableBytes(of: &value) { destination in
        _ = bytes.copyBytes(to: destination)
    }
    return value
}
}
