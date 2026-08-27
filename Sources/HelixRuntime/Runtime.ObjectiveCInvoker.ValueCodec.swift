import Foundation
import HelixObjectiveCRuntimeSupport
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVM
#endif

extension Runtime.ObjectiveCInvoker {
    final class Allocation: @unchecked Sendable {
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

    struct PreparedArgument {
        var encoding: String
        var kind: HelixRuntimeObjectiveCArgumentKind
        var bytes: Allocation?
        var object: AnyObject?
    }

    func receiverObject(
        arguments: [VM.Value],
        catalog: VM.NativeTypeCatalog
    ) throws -> AnyObject? {
        guard let index = descriptor.target.receiverArgumentIndex else {
            return nil
        }
        guard descriptor.target.dispatch == .instance else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C receiver is present on non-instance dispatch"
            )
        }
        return try object(
            from: arguments[Int(index)],
            expected: parameterTypes[Int(index)],
            nullable: false,
            catalog: catalog
        )
    }

    func prepare(
        _ value: VM.Value?,
        parameter: Core.NativeCall.ABIParameter,
        context: VM.NativeInvocationContext
    ) throws -> PreparedArgument {
        guard let encoding = parameter.type.encoding else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C parameter has no type encoding"
            )
        }
        if parameter.source.kind == .errorOut {
            return .init(
                encoding: encoding,
                kind: HelixRuntimeObjectiveCArgumentErrorOut
            )
        }
        guard let value else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C parameter has no projected value"
            )
        }
        switch parameter.type.kind {
        case .object:
            let object = try object(
                from: value,
                expected: parameter.source.logicalArgumentIndex.map {
                    parameterTypes[Int($0)]
                },
                nullable: parameter.type.isNullable,
                catalog: context.nativeTypeCatalog
            )
            return .init(
                encoding: encoding,
                kind: HelixRuntimeObjectiveCArgumentObject,
                object: try validateObjectiveCObject(
                    object,
                    physicalType: parameter.type,
                    role: "argument"
                )
            )
        case .block:
            guard let index = parameter.source.logicalArgumentIndex else {
                return .init(
                    encoding: encoding,
                    kind: HelixRuntimeObjectiveCArgumentBlock,
                    object: nil
                )
            }
            return .init(
                encoding: encoding,
                kind: HelixRuntimeObjectiveCArgumentBlock,
                object: try Runtime.ObjectiveCBlock.make(
                    parameterIndex: Int(index),
                    value: value,
                    expectedType: parameterTypes[Int(index)],
                    context: context
                )
            )
        case .boolean:
            guard case let .bool(boolean) = value else {
                throw VM.RuntimeTrap.typeMismatch(
                    expected: .bool,
                    actual: value.type
                )
            }
            return bytes(
                [boolean ? 1 : 0],
                parameter: parameter,
                encoding: encoding
            )
        case .signedInteger, .unsignedInteger:
            guard case let .integer(integer) = value,
                  integer.bitWidth == UInt16(parameter.type.size! * 8),
                  integer.isSigned == (parameter.type.kind == .signedInteger)
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C integer width or signedness mismatch"
                )
            }
            return integerBytes(
                integer.rawBits,
                parameter: parameter,
                encoding: encoding
            )
        case .floatingPoint:
            guard case let .float(float) = value,
                  float.bitWidth == UInt16(parameter.type.size! * 8)
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C floating-point width mismatch"
                )
            }
            return integerBytes(
                float.bitPattern,
                parameter: parameter,
                encoding: encoding
            )
        case .structure:
            guard case let .native(native) = value,
                  let size = parameter.type.size,
                  let alignment = parameter.type.alignment
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C structure requires a native ABI value"
                )
            }
            let data = try context.nativeTypeCatalog.encodeNativeABI(
                native,
                expectedEncoding: encoding,
                expectedSize: size,
                expectedAlignment: alignment
            )
            return bytes(
                Array(data),
                parameter: parameter,
                encoding: encoding
            )
        case .void, .bridgeValue, .classObject, .selector, .pointer:
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C parameter ABI kind \(parameter.type.kind) is unsupported"
            )
        }
    }

    func bytes(
        _ value: [UInt8],
        parameter: Core.NativeCall.ABIParameter,
        encoding: String
    ) -> PreparedArgument {
        let storage = Allocation(
            byteCount: value.count,
            alignment: Int(parameter.type.alignment ?? 1)
        )
        value.withUnsafeBytes {
            guard let baseAddress = $0.baseAddress else { return }
            storage.pointer.copyMemory(
                from: baseAddress,
                byteCount: value.count
            )
        }
        return .init(
            encoding: encoding,
            kind: HelixRuntimeObjectiveCArgumentBytes,
            bytes: storage
        )
    }

    func integerBytes(
        _ value: UInt64,
        parameter: Core.NativeCall.ABIParameter,
        encoding: String
    ) -> PreparedArgument {
        var nativeEndian = value
        let size = Int(parameter.type.size!)
        let bytes = withUnsafeBytes(of: &nativeEndian) {
            Array($0.prefix(size))
        }
        return self.bytes(bytes, parameter: parameter, encoding: encoding)
    }

    func object(
        from value: VM.Value,
        expected: Bytecode.ValueType?,
        nullable: Bool,
        catalog: VM.NativeTypeCatalog
    ) throws -> AnyObject? {
        switch value {
        case let .optional(wrapped):
            guard nullable else {
                throw VM.RuntimeTrap.nativeFailure(
                    "nil is forbidden for this Objective-C parameter"
                )
            }
            guard let wrapped else { return nil }
            let wrappedType: Bytecode.ValueType? = if case let .optional(type) = expected {
                type
            } else {
                nil
            }
            return try object(
                from: wrapped,
                expected: wrappedType,
                nullable: false,
                catalog: catalog
            )
        case let .native(native):
            return try catalog.referencedObject(in: native)
        case .any:
            guard expected == .any else {
                throw VM.RuntimeTrap.nativeFailure(
                    "VM Any value is not authorized for this Objective-C object slot"
                )
            }
            return try Runtime.BridgeValueCodec.decodeAny(
                value,
                nativeTypeCatalog: catalog
            ) as AnyObject
        case let .string(string):
            return string as NSString
        case let .error(error):
            return NSError(
                domain: "dev.helix.patch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error.message]
            )
        default:
            throw VM.RuntimeTrap.nativeFailure(
                "VM value \(value.type) cannot cross an Objective-C object slot"
            )
        }
    }

    func decodeResult(
        bytes: Data,
        object: AnyObject?,
        catalog: VM.NativeTypeCatalog
    ) throws -> VM.Value? {
        let physical = descriptor.physicalSignature.result
        switch physical.kind {
        case .void:
            guard resultType == .void else {
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C Void result disagrees with logical result"
                )
            }
            return nil
        case .object:
            let object = try validateObjectiveCObject(
                object,
                physicalType: physical,
                role: "result"
            )
            return try decodeObjectResult(
                object,
                nullable: physical.isNullable,
                catalog: catalog
            )
        case .boolean:
            guard resultType == .bool, let value = decodeBoolean(bytes) else {
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C Bool result disagrees with logical result"
                )
            }
            return .bool(value)
        case .signedInteger, .unsignedInteger:
            guard case let .integer(bitWidth, signed) = resultType,
                  bitWidth == UInt16(physical.size! * 8),
                  signed == (physical.kind == .signedInteger)
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C integer result disagrees with logical result"
                )
            }
            return .integer(try .init(
                rawBits: decodeBits(bytes),
                bitWidth: bitWidth,
                isSigned: signed
            ))
        case .floatingPoint:
            guard case let .float(bitWidth) = resultType,
                  bitWidth == UInt16(physical.size! * 8)
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C floating result disagrees with logical result"
                )
            }
            return .float(try .init(
                bitPattern: decodeBits(bytes),
                bitWidth: bitWidth
            ))
        case .structure:
            guard case let .native(id) = resultType,
                  let encoding = physical.encoding,
                  let size = physical.size,
                  let alignment = physical.alignment
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C structure result has no native TypeID"
                )
            }
            return .native(try catalog.decodeNativeABI(
                bytes,
                as: id,
                expectedEncoding: encoding,
                expectedSize: size,
                expectedAlignment: alignment
            ))
        case .bridgeValue, .classObject, .selector, .block, .pointer:
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C result ABI kind \(physical.kind) is unsupported"
            )
        }
    }

    func decodeObjectResult(
        _ object: AnyObject?,
        nullable: Bool,
        catalog: VM.NativeTypeCatalog
    ) throws -> VM.Value {
        switch resultType {
        case let .optional(wrapped):
            guard nullable else {
                throw VM.RuntimeTrap.nativeFailure(
                    "non-null Objective-C result was modeled as Optional"
                )
            }
            guard let object else { return .optional(nil) }
            return .optional(try decodeObject(
                object,
                as: wrapped,
                catalog: catalog
            ))
        default:
            guard let object else {
                throw VM.RuntimeTrap.nativeFailure(
                    "non-null Objective-C result returned nil"
                )
            }
            return try decodeObject(object, as: resultType, catalog: catalog)
        }
    }

    func validateObjectiveCObject(
        _ object: AnyObject?,
        physicalType: Core.NativeCall.ABIType,
        role: String
    ) throws -> AnyObject? {
        guard let object else { return nil }
        guard let canonicalName = physicalType.canonicalName else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C \(role) has no cataloged object type"
            )
        }
        let leafName = canonicalName.split(separator: ".").last.map(String.init)
            ?? canonicalName
        let dynamicallyTypedNames: Set<String> = [
            "AnyObject", "id", "ObjectiveC.id", "Swift.AnyObject",
        ]
        if dynamicallyTypedNames.contains(canonicalName)
            || dynamicallyTypedNames.contains(leafName)
        {
            return object
        }
        if canonicalName.hasPrefix("any ") {
            guard let protocolNames = objectiveCProtocolNames(canonicalName)
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "cataloged Objective-C \(role) protocol identity is malformed"
                )
            }
            if protocolNames.isEmpty { return object }
            let opaque = Unmanaged.passUnretained(object).toOpaque()
            for name in protocolNames {
                guard name.withCString({
                    helix_runtime_objective_c_object_conforms_to_protocol(
                        opaque,
                        $0
                    )
                })
                else {
                    throw VM.RuntimeTrap.nativeFailure(
                        "Objective-C \(role) does not conform to cataloged protocol \(name)"
                    )
                }
            }
            return object
        }
        let matches = leafName.withCString {
            helix_runtime_objective_c_object_is_kind_of(
                Unmanaged.passUnretained(object).toOpaque(),
                $0
            )
        }
        guard matches
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C \(role) does not match cataloged class \(canonicalName)"
            )
        }
        return object
    }

    func objectiveCProtocolNames(_ canonicalName: String) -> [String]? {
        guard canonicalName.hasPrefix("any ") else { return nil }
        let names = canonicalName.dropFirst("any ".count).split(separator: "&")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: ".").last.map(String.init) ?? ""
            }
        guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return names.filter { $0 != "AnyObject" }
    }

    func decodeObject(
        _ object: AnyObject,
        as type: Bytecode.ValueType,
        catalog: VM.NativeTypeCatalog
    ) throws -> VM.Value {
        switch type {
        case let .native(id):
            return .native(try catalog.boxReference(object, as: id))
        case .string:
            guard let string = object as? NSString else {
                throw VM.RuntimeTrap.typeMismatch(expected: .string, actual: nil)
            }
            return .string(string as String)
        case .error:
            guard let error = object as? NSError else {
                throw VM.RuntimeTrap.typeMismatch(expected: .error, actual: nil)
            }
            return .error(.init(message: Self.errorMessage(error)))
        default:
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C object cannot decode as \(type)"
            )
        }
    }

    func decodeBoolean(_ bytes: Data) -> Bool? {
        guard bytes.count == 1 else { return nil }
        return bytes[bytes.startIndex] != 0
    }

    func decodeBits(_ bytes: Data) -> UInt64 {
        var value: UInt64 = 0
        withUnsafeMutableBytes(of: &value) { destination in
            _ = bytes.copyBytes(to: destination)
        }
        return value
    }

    static func errorMessage(_ error: NSError) -> String {
        let domain = boundedUTF8(error.domain, maximumBytes: 256)
        let detail = boundedUTF8(
            error.localizedDescription,
            maximumBytes: 700
        )
        return "\(domain)(\(error.code)): \(detail)"
    }

    private static func boundedUTF8(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        var bytes = Array(value.utf8.prefix(maximumBytes + 1))
        guard bytes.count > maximumBytes else { return value }
        bytes.removeLast()
        while String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
