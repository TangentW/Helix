import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVM
#endif

extension Runtime {
enum ObjectiveCBlock {}
}

extension Runtime.ObjectiveCBlock {
    private final class CallbackBox: @unchecked Sendable {
        let callback: VM.NativeCallback
        let catalog: VM.NativeTypeCatalog

        init(
            callback: VM.NativeCallback,
            catalog: VM.NativeTypeCatalog
        ) {
            self.callback = callback
            self.catalog = catalog
        }

        func invokeVoid(_ values: [Any?]) {
            callback.invokeVoid {
                guard values.count == callback.signature.parameters.count else {
                    throw VM.RuntimeTrap.nativeFailure(
                        "Objective-C Block callback arity mismatch"
                    )
                }
                return try zip(values, callback.signature.parameters).map {
                    try Self.encode($0.0, as: $0.1, catalog: catalog)
                }
            }
        }

        func invokeBool(_ values: [Any?]) -> Bool {
            callback.invokeResult(
                arguments: {
                    guard values.count == callback.signature.parameters.count else {
                        throw VM.RuntimeTrap.nativeFailure(
                            "Objective-C Block callback arity mismatch"
                        )
                    }
                    return try zip(values, callback.signature.parameters).map {
                        try Self.encode($0.0, as: $0.1, catalog: catalog)
                    }
                },
                decodeResult: { value in
                    guard case let .bool(result) = value else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .bool,
                            actual: value.type
                        )
                    }
                    return result
                },
                failureResult: { false }
            )
        }

        func invokeInteger(_ values: [Any?]) -> Int {
            callback.invokeResult(
                arguments: {
                    guard values.count == callback.signature.parameters.count else {
                        throw VM.RuntimeTrap.nativeFailure(
                            "Objective-C Block callback arity mismatch"
                        )
                    }
                    return try zip(values, callback.signature.parameters).map {
                        try Self.encode($0.0, as: $0.1, catalog: catalog)
                    }
                },
                decodeResult: { value in
                    guard case let .integer(result) = value,
                          result.isSigned,
                          let integer = Int(exactly: result.signedValue)
                    else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .int64,
                            actual: value.type
                        )
                    }
                    return integer
                },
                failureResult: { 0 }
            )
        }

        private static func encode(
            _ value: Any?,
            as type: Bytecode.ValueType,
            catalog: VM.NativeTypeCatalog
        ) throws -> VM.Value {
            switch type {
            case .bool:
                guard let value = value as? Bool else {
                    throw VM.RuntimeTrap.typeMismatch(expected: type, actual: nil)
                }
                return .bool(value)
            case let .integer(bitWidth, signed):
                guard let value = value as? Int else {
                    throw VM.RuntimeTrap.typeMismatch(expected: type, actual: nil)
                }
                return .integer(try .init(
                    signed: Int64(value),
                    bitWidth: bitWidth,
                    isSigned: signed
                ))
            case let .float(bitWidth):
                guard bitWidth == 64, let value = value as? Double else {
                    throw VM.RuntimeTrap.typeMismatch(expected: type, actual: nil)
                }
                return .float(try .init(
                    bitPattern: value.bitPattern,
                    bitWidth: bitWidth
                ))
            case .string:
                guard let value = value as? NSString else {
                    throw VM.RuntimeTrap.typeMismatch(expected: type, actual: nil)
                }
                return .string(value as String)
            case let .native(id):
                guard let value = value as AnyObject? else {
                    throw VM.RuntimeTrap.typeMismatch(expected: type, actual: nil)
                }
                return .native(try catalog.boxReference(value, as: id))
            case .error:
                guard let error = value as? NSError else {
                    throw VM.RuntimeTrap.typeMismatch(expected: type, actual: nil)
                }
                return .error(.init(
                    message: Runtime.ObjectiveCInvoker.errorMessage(error)
                ))
            case let .optional(wrapped):
                guard let value else { return .optional(nil) }
                return .optional(try encode(value, as: wrapped, catalog: catalog))
            default:
                throw VM.RuntimeTrap.nativeFailure(
                    "Objective-C Block callback parameter \(type) is unsupported"
                )
            }
        }

    }

    static func make(
        parameterIndex: Int,
        value: VM.Value,
        expectedType: Bytecode.ValueType,
        context: VM.NativeInvocationContext
    ) throws -> AnyObject? {
        let callbackValue: VM.Value
        let signature: Bytecode.ClosureSignature
        switch (value, expectedType) {
        case let (.closure, .closure(expected)):
            callbackValue = value
            signature = expected
        case (.optional(nil), .optional(.closure)):
            return nil
        case let (.optional(.some(wrapped)), .optional(.closure(expected))):
            callbackValue = wrapped
            signature = expected
        default:
            throw VM.RuntimeTrap.typeMismatch(
                expected: expectedType,
                actual: value.type
            )
        }
        let callback = try context.makeCallback(
            parameterIndex: parameterIndex,
            from: callbackValue
        )
        guard callback.signature == signature
                || callback.signature.isMainActorRestriction(of: signature)
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C Block callback signature mismatch"
            )
        }
        let box = CallbackBox(
            callback: callback,
            catalog: context.nativeTypeCatalog
        )
        return try makeBlock(box: box, signature: callback.signature)
    }

    private static func makeBlock(
        box: CallbackBox,
        signature: Bytecode.ClosureSignature
    ) throws -> AnyObject {
        typealias Void0 = @convention(block) @Sendable () -> Void
        typealias VoidBool = @convention(block) @Sendable (Bool) -> Void
        typealias VoidInteger = @convention(block) @Sendable (Int) -> Void
        typealias VoidDouble = @convention(block) @Sendable (Double) -> Void
        typealias VoidObject = @convention(block) @Sendable (AnyObject?) -> Void
        typealias VoidObject2 = @convention(block) @Sendable (
            AnyObject?, AnyObject?
        ) -> Void
        typealias VoidObject3 = @convention(block) @Sendable (
            AnyObject?, AnyObject?, AnyObject?
        ) -> Void
        typealias VoidBoolObject = @convention(block) @Sendable (
            Bool, AnyObject?
        ) -> Void
        typealias VoidObjectBool = @convention(block) @Sendable (
            AnyObject?, Bool
        ) -> Void
        typealias Bool0 = @convention(block) @Sendable () -> Bool
        typealias BoolObject = @convention(block) @Sendable (AnyObject?) -> Bool
        typealias BoolObject2 = @convention(block) @Sendable (
            AnyObject?, AnyObject?
        ) -> Bool
        typealias IntegerObject2 = @convention(block) @Sendable (
            AnyObject?, AnyObject?
        ) -> Int

        let block: AnyObject
        switch shape(for: signature) {
        case .void0:
            let value: Void0 = { box.invokeVoid([]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .voidBool:
            let value: VoidBool = { box.invokeVoid([$0]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .voidInteger:
            let value: VoidInteger = { box.invokeVoid([$0]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .voidDouble:
            let value: VoidDouble = { box.invokeVoid([$0]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .voidObject:
            let value: VoidObject = { box.invokeVoid([$0]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .voidObject2:
            let value: VoidObject2 = { box.invokeVoid([$0, $1]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .voidObject3:
            let value: VoidObject3 = { box.invokeVoid([$0, $1, $2]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .voidBoolObject:
            let value: VoidBoolObject = { box.invokeVoid([$0, $1]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .voidObjectBool:
            let value: VoidObjectBool = { box.invokeVoid([$0, $1]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .bool0:
            let value: Bool0 = { box.invokeBool([]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .boolObject:
            let value: BoolObject = { box.invokeBool([$0]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .boolObject2:
            let value: BoolObject2 = { box.invokeBool([$0, $1]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case .integerObject2:
            let value: IntegerObject2 = { box.invokeInteger([$0, $1]) }
            block = unsafeBitCast(value, to: AnyObject.self)
        case nil:
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C Block ABI shape is unsupported"
            )
        }
        return block
    }

    static func supports(_ signature: Bytecode.ClosureSignature) -> Bool {
        Bytecode.ObjectiveCBlockABI.supports(signature)
            && shape(for: signature) != nil
    }

    private enum Shape {
        case void0
        case voidBool
        case voidInteger
        case voidDouble
        case voidObject
        case voidObject2
        case voidObject3
        case voidBoolObject
        case voidObjectBool
        case bool0
        case boolObject
        case boolObject2
        case integerObject2
    }

    private static func shape(
        for signature: Bytecode.ClosureSignature
    ) -> Shape? {
        let parameters = signature.parameters
        switch signature.result {
        case .void:
            if parameters.isEmpty { return .void0 }
            if parameters == [.bool] { return .voidBool }
            if parameters == [.int64] { return .voidInteger }
            if parameters == [.float(bitWidth: 64)] { return .voidDouble }
            if parameters.count == 1, isObject(parameters[0]) {
                return .voidObject
            }
            if parameters.count == 2,
               parameters[0] == .bool,
               isObject(parameters[1])
            {
                return .voidBoolObject
            }
            if parameters.count == 2,
               isObject(parameters[0]),
               parameters[1] == .bool
            {
                return .voidObjectBool
            }
            if parameters.count == 2,
               parameters.allSatisfy(isObject)
            {
                return .voidObject2
            }
            if parameters.count == 3,
               parameters.allSatisfy(isObject)
            {
                return .voidObject3
            }
        case .bool:
            if parameters.isEmpty { return .bool0 }
            if parameters.count == 1, isObject(parameters[0]) {
                return .boolObject
            }
            if parameters.count == 2,
               parameters.allSatisfy(isObject)
            {
                return .boolObject2
            }
        case .integer(bitWidth: 64, signed: true):
            if parameters.count == 2,
               parameters.allSatisfy(isObject)
            {
                return .integerObject2
            }
        default:
            break
        }
        return nil
    }

    private static func isObject(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .native, .string, .error: true
        case let .optional(wrapped): isObject(wrapped)
        default: false
        }
    }
}
