import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
#endif

#if canImport(ObjectiveC)
import ObjectiveC
#endif

extension Runtime {
/// Runtime support for patch-local classes whose native identity is an
/// Objective-C subclass of a frozen Shell type.
enum HostedClasses {
    private static let registry = Registry()

    static func makeObjectHost(
        engine: Runtime.Engine,
        context: Runtime.ExecutionContext,
        image: Verification.Image
    ) -> VM.ObjectHost {
        VM.ObjectHost(
            allocate: { [weak engine, weak context] object, definition in
                guard let engine, let context else {
                    throw VM.RuntimeTrap.nativeFailure(
                        "Helix Runtime was released while allocating a hosted class"
                    )
                }
                return try allocate(
                    engine: engine,
                    lease: context.lease,
                    image: image,
                    object: object,
                    definition: definition
                )
            },
            invokeSuper: { object, method, arguments in
                try invokeSuper(object: object, method: method, arguments: arguments)
            }
        )
    }

    static func validateBindings(
        image: Verification.Image,
        nativeTypeCatalog: VM.NativeTypeCatalog
    ) throws {
        for definition in image.module.localTypes {
            guard case let .class(_, hostedSuperclass, methods) = definition.kind,
                  let hostedSuperclass
            else { continue }
            guard let operations = nativeTypeCatalog[hostedSuperclass.typeID],
                  operations.kind == .reference,
                  operations.isCopyable,
                  let superclass = operations.referenceClass?.metatype
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "hosted class \(definition.key) has no concrete frozen superclass TypeOps"
                )
            }
            try registry.validate(
                superclass: superclass,
                definition: definition,
                methods: methods
            )
        }
    }

    private static func allocate(
        engine: Runtime.Engine,
        lease: Runtime.GenerationLease,
        image: Verification.Image,
        object: VM.ObjectReference,
        definition: Bytecode.LocalTypeDefinition
    ) throws -> VM.NativeValue {
        #if canImport(ObjectiveC)
        guard case let .class(_, hostedSuperclass, methods) = definition.kind,
              let hostedSuperclass,
              let operations = engine.nativeTypeCatalog[hostedSuperclass.typeID],
              let superclass = operations.referenceClass?.metatype
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "hosted class \(definition.key) has no frozen superclass binding"
            )
        }
        guard !operations.requiresMainActor || Thread.isMainThread else {
            throw VM.RuntimeTrap.mainActorViolation
        }
        let hostClass: AnyClass = try registry.resolve(
            imageHash: image.imageHash,
            superclass: superclass,
            definition: definition,
            methods: methods
        )
        guard let objectType = hostClass as? NSObject.Type else {
            throw VM.RuntimeTrap.nativeFailure(
                "hosted superclass for \(definition.key) is not NSObject-compatible"
            )
        }
        let instance = objectType.init()
        guard let dynamicClass = object_getClass(instance), dynamicClass === hostClass else {
            throw VM.RuntimeTrap.nativeFailure(
                "hosted class \(definition.key) initializer replaced its allocated object"
            )
        }
        let context = ObjectContext(
            engine: engine,
            lease: lease,
            image: image,
            typeKey: definition.key,
            superclassTypeID: hostedSuperclass.typeID,
            storage: object.storage,
            hostClass: hostClass,
            methods: methods
        )
        objc_setAssociatedObject(
            instance,
            &Association.contextKey,
            context,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return try engine.nativeTypeCatalog.boxReference(
            instance,
            as: hostedSuperclass.typeID
        )
        #else
        _ = engine
        _ = lease
        _ = image
        _ = object
        _ = definition
        throw VM.RuntimeTrap.nativeFailure(
            "Objective-C hosted classes are unavailable on this platform"
        )
        #endif
    }

    private static func invokeSuper(
        object: VM.ObjectReference,
        method: Bytecode.HostedMethod,
        arguments: [VM.Value]
    ) throws {
        #if canImport(ObjectiveC)
        guard let host = object.nativeHost?.value(as: AnyObject.self) else {
            throw VM.RuntimeTrap.nativeFailure("hosted object has no native instance")
        }
        try callExactSuper(
            object: host,
            hostClass: object_getClass(host),
            selector: NSSelectorFromString(method.selector),
            abi: method.abi,
            arguments: arguments
        )
        #else
        _ = object
        _ = method
        _ = arguments
        throw VM.RuntimeTrap.nativeFailure(
            "Objective-C hosted classes are unavailable on this platform"
        )
        #endif
    }
}
}

#if canImport(ObjectiveC)
private extension Runtime.HostedClasses {
    enum Association {
        nonisolated(unsafe) static var contextKey: UInt8 = 0
    }

    final class ObjectContext: @unchecked Sendable {
        let engine: Runtime.Engine
        let lease: Runtime.GenerationLease
        let image: Verification.Image
        let typeKey: Bytecode.LocalTypeKey
        let superclassTypeID: Core.TypeID
        let storage: VM.ObjectStorage
        let hostClass: AnyClass

        private let methodsBySelector: [String: Bytecode.HostedMethod]
        private let enabled = Runtime.AtomicFlag(true)

        init(
            engine: Runtime.Engine,
            lease: Runtime.GenerationLease,
            image: Verification.Image,
            typeKey: Bytecode.LocalTypeKey,
            superclassTypeID: Core.TypeID,
            storage: VM.ObjectStorage,
            hostClass: AnyClass,
            methods: [Bytecode.HostedMethod]
        ) {
            self.engine = engine
            self.lease = lease
            self.image = image
            self.typeKey = typeKey
            self.superclassTypeID = superclassTypeID
            self.storage = storage
            self.hostClass = hostClass
            methodsBySelector = Dictionary(
                uniqueKeysWithValues: methods.map { ($0.selector, $0) }
            )
        }

        func dispatch(
            object: AnyObject,
            selector: Selector,
            boolArgument: Bool?
        ) {
            let selectorName = NSStringFromSelector(selector)
            guard let method = methodsBySelector[selectorName] else {
                return
            }
            let arguments: [VM.Value]
            switch (method.abi, boolArgument) {
            case (.voidNoArguments, nil):
                arguments = []
            case let (.voidBool, value?):
                arguments = [.bool(value)]
            default:
                enabled.storeRelease(false)
                try? Runtime.HostedClasses.callExactSuper(
                    object: object,
                    hostClass: hostClass,
                    selector: selector,
                    abi: method.abi,
                    arguments: boolArgument.map { [.bool($0)] } ?? []
                )
                return
            }
            guard enabled.loadAcquire() else {
                try? Runtime.HostedClasses.callExactSuper(
                    object: object,
                    hostClass: hostClass,
                    selector: selector,
                    abi: method.abi,
                    arguments: arguments
                )
                return
            }
            do {
                let nativeHost = try engine.nativeTypeCatalog.boxReference(
                    object,
                    as: superclassTypeID
                )
                let reference = VM.ObjectReference(
                    typeKey: typeKey,
                    storage: storage,
                    nativeHost: nativeHost
                )
                let invocationArguments = arguments + [.object(reference)]
                let outcome = engine.invokeHostedMethod(
                    method,
                    typeKey: typeKey,
                    image: image,
                    lease: lease,
                    arguments: invocationArguments
                )
                guard case .returned = outcome.result else {
                    enabled.storeRelease(false)
                    if !outcome.sideEffectsCommitted {
                        try Runtime.HostedClasses.callExactSuper(
                            object: object,
                            hostClass: hostClass,
                            selector: selector,
                            abi: method.abi,
                            arguments: arguments
                        )
                    }
                    return
                }
            } catch {
                enabled.storeRelease(false)
                try? Runtime.HostedClasses.callExactSuper(
                    object: object,
                    hostClass: hostClass,
                    selector: selector,
                    abi: method.abi,
                    arguments: arguments
                )
            }
        }
    }

    struct RegistryKey: Hashable {
        var imageHash: Core.Digest
        var typeKey: Bytecode.LocalTypeKey
        var superclass: ObjectIdentifier
        var methods: [Bytecode.HostedMethod]
    }

    final class Registry: @unchecked Sendable {
        private static let maximumClasses = 512
        private let lock = NSLock()
        private var classes: [RegistryKey: AnyClass] = [:]

        func validate(
            superclass: AnyClass,
            definition: Bytecode.LocalTypeDefinition,
            methods: [Bytecode.HostedMethod]
        ) throws {
            guard superclass is NSObject.Type else {
                throw VM.RuntimeTrap.nativeFailure(
                    "hosted superclass for \(definition.key) is not NSObject-compatible"
                )
            }
            for method in methods {
                try validate(method: method, on: superclass)
            }
        }

        func resolve(
            imageHash: Core.Digest,
            superclass: AnyClass,
            definition: Bytecode.LocalTypeDefinition,
            methods: [Bytecode.HostedMethod]
        ) throws -> AnyClass {
            let key = RegistryKey(
                imageHash: imageHash,
                typeKey: definition.key,
                superclass: ObjectIdentifier(superclass),
                methods: methods
            )
            return try lock.withLock {
                if let existing = classes[key] { return existing }
                guard classes.count < Self.maximumClasses else {
                    throw VM.RuntimeTrap.nativeFailure(
                        "hosted class process limit \(Self.maximumClasses) exceeded"
                    )
                }
                try validate(
                    superclass: superclass,
                    definition: definition,
                    methods: methods
                )
                let className = uniqueClassName(imageHash: imageHash, key: definition.key)
                guard objc_lookUpClass(className) == nil,
                      let allocated: AnyClass = objc_allocateClassPair(
                        superclass,
                        className,
                        0
                      )
                else {
                    throw VM.RuntimeTrap.nativeFailure(
                        "Objective-C host class name collision for \(definition.key)"
                    )
                }
                var registered = false
                defer {
                    if !registered { objc_disposeClassPair(allocated) }
                }
                for method in methods {
                    try add(method: method, to: allocated, superclass: superclass)
                }
                objc_registerClassPair(allocated)
                registered = true
                classes[key] = allocated
                return allocated
            }
        }

        private func validate(
            method: Bytecode.HostedMethod,
            on superclass: AnyClass
        ) throws {
            let selector = NSSelectorFromString(method.selector)
            guard let nativeMethod = class_getInstanceMethod(superclass, selector),
                  let encoding = method_getTypeEncoding(nativeMethod)
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "superclass does not implement hosted selector \(method.selector)"
                )
            }
            let argumentCount = method_getNumberOfArguments(nativeMethod)
            let expectedCount: UInt32 = switch method.abi {
            case .voidNoArguments: 2
            case .voidBool: 3
            }
            guard argumentCount == expectedCount,
                  String(cString: encoding).first == "v",
                  copiedType(method_copyReturnType(nativeMethod)) == "v",
                  copiedType(method_copyArgumentType(nativeMethod, 0)) == "@",
                  copiedType(method_copyArgumentType(nativeMethod, 1)) == ":"
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "selector \(method.selector) does not match \(method.abi.rawValue)"
                )
            }
            if method.abi == .voidBool {
                guard let argument = copiedType(
                    method_copyArgumentType(nativeMethod, 2)
                ), argument == "B" || argument == "c" else {
                    throw VM.RuntimeTrap.nativeFailure(
                        "selector \(method.selector) does not carry an Objective-C Bool"
                    )
                }
            }
        }

        private func add(
            method: Bytecode.HostedMethod,
            to hostClass: AnyClass,
            superclass: AnyClass
        ) throws {
            let selector = NSSelectorFromString(method.selector)
            guard let nativeMethod = class_getInstanceMethod(superclass, selector),
                  let encoding = method_getTypeEncoding(nativeMethod)
            else {
                throw VM.RuntimeTrap.nativeFailure(
                    "superclass method \(method.selector) disappeared during registration"
                )
            }
            let implementation: IMP
            switch method.abi {
            case .voidNoArguments:
                let block: @convention(block) (AnyObject) -> Void = { object in
                    dispatch(object: object, selector: selector, boolArgument: nil)
                }
                implementation = imp_implementationWithBlock(block)
            case .voidBool:
                let block: @convention(block) (AnyObject, Bool) -> Void = { object, value in
                    dispatch(object: object, selector: selector, boolArgument: value)
                }
                implementation = imp_implementationWithBlock(block)
            }
            guard class_addMethod(hostClass, selector, implementation, encoding) else {
                _ = imp_removeBlock(implementation)
                throw VM.RuntimeTrap.nativeFailure(
                    "could not install hosted selector \(method.selector)"
                )
            }
        }

        private func uniqueClassName(
            imageHash: Core.Digest,
            key: Bytecode.LocalTypeKey
        ) -> String {
            let typeHash = Core.Digest.sha256(key.rawValue).hex.prefix(16)
            return "HelixHosted_\(imageHash.hex.prefix(20))_\(typeHash)"
        }

        private func copiedType(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
            guard let pointer else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }
    }

    static func dispatch(
        object: AnyObject,
        selector: Selector,
        boolArgument: Bool?
    ) {
        guard let context = objc_getAssociatedObject(
            object,
            &Association.contextKey
        ) as? ObjectContext else {
            // Initialization may dispatch before Helix can attach context. The
            // exact superclass implementation is the only safe fallback.
            guard let hostClass = object_getClass(object) else { return }
            let abi: Bytecode.HostedMethodABI = boolArgument == nil
                ? .voidNoArguments
                : .voidBool
            try? callExactSuper(
                object: object,
                hostClass: hostClass,
                selector: selector,
                abi: abi,
                arguments: boolArgument.map { [.bool($0)] } ?? []
            )
            return
        }
        context.dispatch(
            object: object,
            selector: selector,
            boolArgument: boolArgument
        )
    }

    static func callExactSuper(
        object: AnyObject,
        hostClass: AnyClass?,
        selector: Selector,
        abi: Bytecode.HostedMethodABI,
        arguments: [VM.Value]
    ) throws {
        guard let hostClass,
              let superclass = class_getSuperclass(hostClass),
              class_getInstanceMethod(superclass, selector) != nil
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "hosted superclass does not implement \(NSStringFromSelector(selector))"
            )
        }
        let implementation = class_getMethodImplementation(superclass, selector)
        switch abi {
        case .voidNoArguments:
            guard arguments.isEmpty else {
                throw VM.RuntimeTrap.nativeFailure("void hosted super call received arguments")
            }
            typealias Function = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(implementation, to: Function.self)(object, selector)
        case .voidBool:
            guard arguments.count == 1, case let .bool(value) = arguments[0] else {
                throw VM.RuntimeTrap.nativeFailure("Bool hosted super call has an invalid argument")
            }
            typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(implementation, to: Function.self)(object, selector, value)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#else
private extension Runtime.HostedClasses {
    final class Registry: @unchecked Sendable {
        func validate(
            superclass: AnyClass,
            definition: Bytecode.LocalTypeDefinition,
            methods: [Bytecode.HostedMethod]
        ) throws {
            _ = superclass
            _ = definition
            _ = methods
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C hosted classes are unavailable on this platform"
            )
        }
    }
}
#endif
