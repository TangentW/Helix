import Foundation
import HelixBytecode
import HelixCore
import HelixRuntimeTestSupport
import Testing
@testable import HelixRuntime
@testable import HelixVM

extension RuntimeTests {
@Suite("Generic Objective-C invocation", .serialized)
struct ObjectiveCInvoker {
    @Test("One invoker handles instance, class, property, and initializer dispatch")
    func commonDispatchForms() throws {
        let fixture = try Fixture()
        let receiver = HelixRuntimeTestObject()
        let receiverValue = try fixture.objectValue(receiver)

        let echo = try fixture.call(
            member: "echo(_:)",
            selector: "echo:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [
                fixture.objectParameter(),
                .init(type: "Swift.String"),
            ],
            logicalResult: "Swift.String",
            physicalParameters: [
                .init(type: fixture.objectABI("Foundation.NSString"), source: .argument(1)),
            ],
            physicalResult: fixture.objectABI("Foundation.NSString")
        )
        #expect(
            try fixture.invoke(
                echo,
                arguments: [receiverValue, .string("hello")]
            ) == .returned(.string("hello"))
        )

        let sum = try fixture.call(
            member: "addLeft(_:right:)",
            selector: "addLeft:right:",
            dispatch: .static,
            kind: .staticMethod,
            logicalParameters: [
                .init(type: "Swift.Int"), .init(type: "Swift.Int"),
            ],
            logicalResult: "Swift.Int",
            physicalParameters: [
                .init(type: fixture.integerABI, source: .argument(0)),
                .init(type: fixture.integerABI, source: .argument(1)),
            ],
            physicalResult: fixture.integerABI
        )
        #expect(
            try fixture.invoke(
                sum,
                arguments: [fixture.integer(19), fixture.integer(23)]
            ) == .returned(fixture.integer(42))
        )

        let inheritedClassMethod = try fixture.call(
            owner: "HelixRuntimeTestDerived",
            runtimeClass: "HelixRuntimeTestBase",
            dispatchClass: "HelixRuntimeTestDerived",
            member: "classMarker()",
            selector: "classMarker",
            dispatch: .static,
            kind: .staticMethod,
            logicalParameters: [],
            logicalResult: "Swift.String",
            physicalParameters: [],
            physicalResult: fixture.objectABI("Foundation.NSString")
        )
        #expect(
            try fixture.invoke(inheritedClassMethod, arguments: [])
                == .returned(.string("derived class"))
        )

        let setter = try fixture.call(
            member: "enabled.setter",
            selector: "markEnabled:",
            dispatch: .instance,
            kind: .instanceSetter,
            access: .write,
            logicalParameters: [fixture.objectParameter(), .init(type: "Swift.Bool")],
            logicalResult: "Swift.Void",
            physicalParameters: [
                .init(type: fixture.boolABI, source: .argument(1)),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true),
            property: .init(name: "enabled", accessor: .setter)
        )
        #expect(
            try fixture.invoke(
                setter,
                arguments: [receiverValue, .bool(true)]
            ) == .returned(nil)
        )

        let getter = try fixture.call(
            member: "enabled.getter",
            selector: "isEnabled",
            dispatch: .instance,
            kind: .instanceGetter,
            access: .read,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.Bool",
            physicalParameters: [],
            physicalResult: fixture.boolABI,
            property: .init(name: "enabled", accessor: .getter)
        )
        #expect(
            try fixture.invoke(getter, arguments: [receiverValue])
                == .returned(.bool(true))
        )
        let redirectingReceiver = HelixRuntimeTestMakeRedirectingPropertyObject()
        #expect(HelixRuntimeTestRedirectingPropertyIsInstalled())
        let redirectedResult = try fixture.invoke(
            getter,
            arguments: [try fixture.objectValue(redirectingReceiver)]
        )
        #expect(
            redirectedResult == .returned(.bool(true)),
            "cataloged owner property returned \(redirectedResult)"
        )
        let redirectedAccessor = try fixture.call(
            member: "enabled.getter",
            selector: "helixRedirectedEnabled",
            dispatch: .instance,
            kind: .instanceGetter,
            access: .read,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.Bool",
            physicalParameters: [],
            physicalResult: fixture.boolABI,
            property: .init(name: "enabled", accessor: .getter)
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                redirectedAccessor,
                arguments: [try fixture.objectValue(redirectingReceiver)]
            )
        }

        let initializer = try fixture.call(
            member: "init(name:)",
            selector: "initWithName:",
            dispatch: .initializer,
            kind: .initializer,
            logicalParameters: [.init(type: "Swift.String")],
            logicalResult: fixture.objectTypeName,
            physicalParameters: [
                .init(type: fixture.objectABI("Foundation.NSString"), source: .argument(0)),
            ],
            physicalResult: fixture.objectABI(fixture.objectTypeName),
            resultConvention: .directOwned,
            effects: .init(mayAllocate: true),
            methodFamily: .initializer
        )
        guard case let .returned(.some(.native(native))) = try fixture.invoke(
            initializer,
            arguments: [.string("created")]
        ) else {
            Issue.record("initializer did not return a native object")
            return
        }
        #expect(native.value(as: HelixRuntimeTestObject.self)?.name == "created")

        let inheritedFixture = try Fixture(
            receiverClass: HelixRuntimeTestDerived.self
        )
        let inheritedType =
            "HelixRuntimeTestSupport.HelixRuntimeTestDerived"
        let inheritedInitializer = try inheritedFixture.call(
            owner: "HelixRuntimeTestDerived",
            runtimeClass: "NSObject",
            dispatchClass: "HelixRuntimeTestDerived",
            member: "init()",
            selector: "init",
            dispatch: .initializer,
            kind: .initializer,
            logicalParameters: [],
            logicalResult: inheritedType,
            physicalParameters: [],
            physicalResult: inheritedFixture.objectABI(inheritedType),
            resultConvention: .directOwned,
            effects: .init(mayAllocate: true),
            methodFamily: .initializer
        )
        guard case let .returned(.some(.native(inheritedNative))) =
            try inheritedFixture.invoke(
                inheritedInitializer,
                arguments: []
            )
        else {
            Issue.record("inherited initializer did not return a native object")
            return
        }
        #expect(inheritedNative.value(as: HelixRuntimeTestDerived.self) != nil)
    }

    @Test("Logical Any parameters bridge through Objective-C id")
    func nativeReferenceInsideAny() throws {
        let fixture = try Fixture()
        let receiver = HelixRuntimeTestObject()
        let named = HelixRuntimeTestNamedObject()
        named.name = "native-any"
        let receiverValue = try fixture.objectValue(receiver)
        let namedValue = try fixture.objectValue(named)
        let erased = VM.Value.any(.init(
            dynamicType: .native(fixture.objectTypeID),
            payload: namedValue
        ))
        let call = try fixture.call(
            member: "recordNamingObject(_:)",
            selector: "recordNamingObject:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .write,
            logicalParameters: [
                fixture.objectParameter(),
                .init(type: "Swift.Any"),
            ],
            logicalResult: "Swift.Void",
            valueParameterTypes: [.native(fixture.objectTypeID), .any],
            physicalParameters: [
                .init(
                    type: fixture.objectABI(
                        "any HelixRuntimeTestNaming & AnyObject"
                    ),
                    source: .argument(1)
                ),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true)
        )

        #expect(
            try fixture.invoke(
                call,
                arguments: [receiverValue, erased]
            ) == .returned(nil)
        )
        #expect(receiver.invocationCount == 1)

        let anyResult = try fixture.call(
            member: "identityObject(_:)",
            selector: "identityObject:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [
                fixture.objectParameter(),
                fixture.objectParameter(),
            ],
            logicalResult: "Swift.Any",
            valueResultType: .any,
            physicalParameters: [
                .init(
                    type: fixture.objectABI("Swift.AnyObject"),
                    source: .argument(1)
                ),
            ],
            physicalResult: fixture.objectABI("Swift.AnyObject")
        )
        #expect(throws: VM.RuntimeTrap.self) {
            try anyResult.invoker.validateConfiguration()
        }
    }

    @Test("Bitwise-copyable structure codecs are general and preserve layout")
    func structureRoundTrip() throws {
        let fixture = try Fixture()
        let receiver = try fixture.objectValue(HelixRuntimeTestObject())
        var point = HelixRuntimeTestPoint()
        point.x = 2.5
        point.y = -4
        let nativePoint = try fixture.catalog.box(point, as: fixture.pointTypeID)
        let call = try fixture.call(
            member: "translatePoint(_:dx:dy:)",
            selector: "translatePoint:dx:dy:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [
                fixture.objectParameter(),
                .init(type: fixture.pointTypeName),
                .init(type: "Swift.Double"),
                .init(type: "Swift.Double"),
            ],
            logicalResult: fixture.pointTypeName,
            physicalParameters: [
                .init(type: fixture.pointABI, source: .argument(1)),
                .init(type: fixture.doubleABI, source: .argument(2)),
                .init(type: fixture.doubleABI, source: .argument(3)),
            ],
            physicalResult: fixture.pointABI
        )
        guard case let .returned(.some(.native(result))) = try fixture.invoke(
            call,
            arguments: [
                receiver, .native(nativePoint), fixture.double(1.25),
                fixture.double(10),
            ]
        ), let decoded = result.value(as: HelixRuntimeTestPoint.self) else {
            Issue.record("structure result did not decode through Native TypeOps")
            return
        }
        #expect(decoded.x == 3.75)
        #expect(decoded.y == 6)
        #expect(fixture.pointEncoding == String(cString: HelixRuntimeTestPointEncoding()))
    }

    @Test("NSError-out and Objective-C exceptions become bounded VM failures")
    func nativeFailures() throws {
        let fixture = try Fixture()
        let receiver = try fixture.objectValue(HelixRuntimeTestObject())
        let throwingEffects = Core.Effects(mayThrow: true)
        let failure = try fixture.call(
            member: "fail()",
            selector: "failWithError:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.Void",
            physicalParameters: [
                .init(
                    type: .init(
                        kind: .pointer,
                        canonicalName: "Foundation.NSErrorPointer",
                        encoding: "^@",
                        isNullable: true
                    ),
                    convention: .indirectOut,
                    source: .errorOut
                ),
            ],
            physicalResult: fixture.boolABI,
            errorConvention: .nsErrorOut,
            effects: throwingEffects,
            errorFailure: .falseBoolean
        )
        #expect(
            try fixture.invoke(failure, arguments: [receiver])
                == .businessError("dev.helix.fixture(73): fixture failure")
        )
        let boundedError = Runtime.ObjectiveCInvoker.errorMessage(NSError(
            domain: String(repeating: "域", count: 1_000),
            code: 73,
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(repeating: "过长的原生错误", count: 1_000),
            ]
        ))
        #expect(boundedError.utf8.count <= 1_024)
        #expect(boundedError.contains("(73):"))

        let exception = try fixture.call(
            member: "raiseFixtureException()",
            selector: "raiseFixtureException",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.Void",
            physicalParameters: [],
            physicalResult: .void
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(exception, arguments: [receiver])
        }
    }

    @Test("Lexical super dispatch bypasses an override without changing the ABI path")
    func lexicalSuper() throws {
        let fixture = try Fixture(receiverClass: HelixRuntimeTestDerived.self)
        let receiver = try fixture.objectValue(HelixRuntimeTestDerived())
        let dynamic = try fixture.call(
            owner: "HelixRuntimeTestDerived",
            runtimeClass: "HelixRuntimeTestDerived",
            member: "marker()",
            selector: "marker",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.String",
            physicalParameters: [],
            physicalResult: fixture.objectABI("Foundation.NSString")
        )
        #expect(
            try fixture.invoke(dynamic, arguments: [receiver])
                == .returned(.string("derived"))
        )
        let lexical = try fixture.call(
            owner: "HelixRuntimeTestDerived",
            runtimeClass: "HelixRuntimeTestBase",
            member: "super.marker()",
            selector: "marker",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.String",
            physicalParameters: [],
            physicalResult: fixture.objectABI("Foundation.NSString"),
            lexicalSuperclass: "HelixRuntimeTestBase"
        )
        #expect(
            try fixture.invoke(lexical, arguments: [receiver])
                == .returned(.string("base"))
        )
        let invalidLexicalHierarchy = try fixture.call(
            owner: "HelixRuntimeTestDerived",
            runtimeClass: "HelixRuntimeTestDerived",
            member: "invalid.super.marker()",
            selector: "marker",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.String",
            physicalParameters: [],
            physicalResult: fixture.objectABI("Foundation.NSString"),
            lexicalSuperclass: "HelixRuntimeTestBase"
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                invalidLexicalHierarchy,
                arguments: [receiver]
            )
        }

        let dynamicProperty = try fixture.call(
            owner: "HelixRuntimeTestDerived",
            runtimeClass: "HelixRuntimeTestDerived",
            member: "markerProperty.getter",
            selector: "markerProperty",
            dispatch: .instance,
            kind: .instanceGetter,
            access: .read,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.String",
            physicalParameters: [],
            physicalResult: fixture.objectABI("Foundation.NSString"),
            property: .init(name: "markerProperty", accessor: .getter)
        )
        #expect(
            try fixture.invoke(dynamicProperty, arguments: [receiver])
                == .returned(.string("derived property"))
        )
        let lexicalProperty = try fixture.call(
            owner: "HelixRuntimeTestDerived",
            runtimeClass: "HelixRuntimeTestBase",
            member: "super.markerProperty.getter",
            selector: "markerProperty",
            dispatch: .instance,
            kind: .instanceGetter,
            access: .read,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.String",
            physicalParameters: [],
            physicalResult: fixture.objectABI("Foundation.NSString"),
            lexicalSuperclass: "HelixRuntimeTestBase",
            property: .init(name: "markerProperty", accessor: .getter)
        )
        #expect(
            try fixture.invoke(lexicalProperty, arguments: [receiver])
                == .returned(.string("base property"))
        )
    }

    @Test("Nonescaping, escaping, and result-producing Blocks reuse ABI shapes")
    func blockLifetimesAndResults() throws {
        let fixture = try Fixture()
        let object = HelixRuntimeTestObject()
        let receiver = try fixture.objectValue(object)
        let observation = CallbackObservation()
        let boolVoid = Bytecode.ClosureSignature(
            parameters: [.bool],
            parameterConventions: [.owned],
            result: .void
        )
        let closure = VM.Value.closure(.init(
            functionID: .init(rawValue: 1),
            signature: boolVoid,
            captures: []
        ))

        let immediate = try fixture.call(
            member: "callNow(_:)",
            selector: "callNow:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .readWrite,
            callbacks: [.init(parameterIndex: 1, lifetime: .nonescaping)],
            logicalParameters: [
                fixture.objectParameter(),
                .init(type: "(Swift.Bool) -> Swift.Void", callbackLifetime: .nonescaping),
            ],
            logicalResult: "Swift.Void",
            physicalParameters: [
                .init(type: fixture.blockABI, ownership: .borrowed, source: .argument(1)),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true)
        )
        #expect(
            try fixture.invoke(
                immediate,
                arguments: [receiver, closure],
                callbackHost: observation.host(result: nil)
            ) == .returned(nil)
        )
        #expect(observation.arguments == [[.bool(true)]])

        let escaping = try fixture.call(
            member: "storeCallback(_:)",
            selector: "storeCallback:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .write,
            callbacks: [.init(parameterIndex: 1, lifetime: .escaping)],
            logicalParameters: [
                fixture.objectParameter(),
                .init(type: "(Swift.Bool) -> Swift.Void", callbackLifetime: .escaping),
            ],
            logicalResult: "Swift.Void",
            physicalParameters: [
                .init(type: fixture.blockABI, source: .argument(1)),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true)
        )
        #expect(
            try fixture.invoke(
                escaping,
                arguments: [receiver, closure],
                callbackHost: observation.host(result: nil)
            ) == .returned(nil)
        )
        object.triggerStoredCallback(false)
        #expect(observation.arguments == [[.bool(true)], [.bool(false)]])

        let predicateSignature = Bytecode.ClosureSignature(
            parameters: [.string],
            parameterConventions: [.owned],
            result: .bool
        )
        let predicate = VM.Value.closure(.init(
            functionID: .init(rawValue: 2),
            signature: predicateSignature,
            captures: []
        ))
        let resultBlock = try fixture.call(
            member: "evaluateObject(_:predicate:)",
            selector: "evaluateObject:predicate:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .read,
            callbacks: [.init(parameterIndex: 2, lifetime: .nonescaping)],
            logicalParameters: [
                fixture.objectParameter(), .init(type: "Swift.String"),
                .init(type: "(Swift.String) -> Swift.Bool", callbackLifetime: .nonescaping),
            ],
            logicalResult: "Swift.Bool",
            physicalParameters: [
                .init(type: fixture.objectABI("Foundation.NSString"), source: .argument(1)),
                .init(type: fixture.blockABI, ownership: .borrowed, source: .argument(2)),
            ],
            physicalResult: fixture.boolABI
        )
        #expect(
            try fixture.invoke(
                resultBlock,
                arguments: [receiver, .string("candidate"), predicate],
                callbackHost: observation.host(result: .bool(true))
            ) == .returned(.bool(true))
        )
        #expect(observation.arguments.last == [.string("candidate")])

        let twoObjectPredicateSignature = Bytecode.ClosureSignature(
            parameters: [.string, .string],
            parameterConventions: [.owned, .owned],
            result: .bool
        )
        let twoObjectPredicate = VM.Value.closure(.init(
            functionID: .init(rawValue: 3),
            signature: twoObjectPredicateSignature,
            captures: []
        ))
        let twoObjectResultBlock = try fixture.call(
            member: "evaluateLeft(_:right:predicate:)",
            selector: "evaluateLeft:right:predicate:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .read,
            callbacks: [.init(parameterIndex: 3, lifetime: .nonescaping)],
            logicalParameters: [
                fixture.objectParameter(),
                .init(type: "Swift.String"),
                .init(type: "Swift.String"),
                .init(
                    type: "(Swift.String, Swift.String) -> Swift.Bool",
                    callbackLifetime: .nonescaping
                ),
            ],
            logicalResult: "Swift.Bool",
            physicalParameters: [
                .init(type: fixture.objectABI("Foundation.NSString"), source: .argument(1)),
                .init(type: fixture.objectABI("Foundation.NSString"), source: .argument(2)),
                .init(type: fixture.blockABI, ownership: .borrowed, source: .argument(3)),
            ],
            physicalResult: fixture.boolABI
        )
        #expect(
            try fixture.invoke(
                twoObjectResultBlock,
                arguments: [
                    receiver, .string("left"), .string("right"), twoObjectPredicate,
                ],
                callbackHost: observation.host(result: .bool(true))
            ) == .returned(.bool(true))
        )
        #expect(observation.arguments.last == [.string("left"), .string("right")])
        #expect(observation.failures.isEmpty)
    }

    @Test("Runtime ABI evidence rejects mismatched catalog metadata")
    func rejectsCatalogRuntimeDrift() throws {
        let fixture = try Fixture()
        let receiver = try fixture.objectValue(HelixRuntimeTestObject())
        let supported = try fixture.call(
            member: "echo(_:)",
            selector: "echo:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [
                fixture.objectParameter(), .init(type: "Swift.String"),
            ],
            logicalResult: "Swift.String",
            physicalParameters: [
                .init(
                    type: fixture.objectABI("Foundation.NSString"),
                    source: .argument(1)
                ),
            ],
            physicalResult: fixture.objectABI("Foundation.NSString")
        )
        try supported.invoker.validateRuntimeABI()

        let unsupported = try fixture.call(
            member: "echo(_:)",
            selector: "echo:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [
                fixture.objectParameter(), .init(type: "Swift.String"),
            ],
            logicalResult: "Swift.String",
            valueResultType: .int64,
            physicalParameters: [
                .init(
                    type: fixture.objectABI("Foundation.NSString"),
                    source: .argument(1)
                ),
            ],
            physicalResult: fixture.objectABI("Foundation.NSString")
        )
        #expect(throws: VM.RuntimeTrap.self) {
            try unsupported.invoker.validateConfiguration()
        }

        let wrong = try fixture.call(
            member: "echo(_:)",
            selector: "echo:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [fixture.objectParameter(), .init(type: "Swift.Int")],
            logicalResult: "Swift.String",
            physicalParameters: [
                .init(type: fixture.integerABI, source: .argument(1)),
            ],
            physicalResult: fixture.objectABI("Foundation.NSString")
        )
        #expect(throws: VM.RuntimeTrap.self) {
            try wrong.invoker.validateRuntimeABI()
        }
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                wrong,
                arguments: [receiver, fixture.integer(1)]
            )
        }
    }

    @Test("Swift integer overlays preserve an ABI-compatible unsigned representation")
    func signedSwiftIntegerOverUnsignedObjectiveCABI() throws {
        let fixture = try Fixture()
        let call = try fixture.call(
            member: "addUnsignedLeft(_:right:)",
            selector: "addUnsignedLeft:right:",
            dispatch: .static,
            kind: .staticMethod,
            logicalParameters: [
                .init(type: "Swift.Int"), .init(type: "Swift.Int"),
            ],
            logicalResult: "Swift.Int",
            physicalParameters: [
                .init(type: fixture.integerABI, source: .argument(0)),
                .init(type: fixture.integerABI, source: .argument(1)),
            ],
            physicalResult: fixture.integerABI
        )

        try call.invoker.validateRuntimeABI()
        #expect(
            try fixture.invoke(
                call,
                arguments: [fixture.integer(19), fixture.integer(23)]
            ) == .returned(fixture.integer(42))
        )
    }

    @Test("Abstract declarations defer selector evidence to the concrete receiver")
    func receiverBoundAbstractDeclaration() throws {
        let fixture = try Fixture(
            receiverClass: HelixRuntimeTestAbstractObject.self
        )
        let call = try fixture.call(
            owner: "HelixRuntimeTestAbstractObject",
            runtimeClass: "HelixRuntimeTestAbstractObject",
            member: "abstractEcho(_:)",
            selector: "abstractEcho:",
            dispatch: .instance,
            kind: .instanceMethod,
            implementationLookup: .dynamicObjectWhenDeclarationMissing,
            logicalParameters: [
                fixture.objectParameter(), .init(type: "Swift.String"),
            ],
            logicalResult: "Swift.String",
            physicalParameters: [
                .init(
                    type: fixture.objectABI("Foundation.NSString"),
                    source: .argument(1)
                ),
            ],
            physicalResult: fixture.objectABI("Foundation.NSString")
        )

        try call.invoker.validateRuntimeABI()
        #expect(
            try fixture.invoke(
                call,
                arguments: [
                    try fixture.objectValue(HelixRuntimeTestConcreteObject()),
                    .string("value"),
                ]
            ) == .returned(.string("concrete:value"))
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                call,
                arguments: [
                    try fixture.objectValue(HelixRuntimeTestAbstractObject()),
                    .string("value"),
                ]
            )
        }
    }

    @Test("Class-cluster initializers validate the allocated concrete object")
    func classClusterInitializer() throws {
        let fixture = try Fixture(receiverClass: HelixRuntimeTestCluster.self)
        let call = try fixture.call(
            owner: "HelixRuntimeTestCluster",
            runtimeClass: "HelixRuntimeTestCluster",
            dispatchClass: "HelixRuntimeTestCluster",
            member: "init(value:)",
            selector: "initWithValue:",
            dispatch: .initializer,
            kind: .initializer,
            implementationLookup: .dynamicObjectWhenDeclarationMissing,
            logicalParameters: [.init(type: "Swift.String")],
            logicalResult: fixture.objectTypeName,
            physicalParameters: [
                .init(
                    type: fixture.objectABI("Foundation.NSString"),
                    source: .argument(0)
                ),
            ],
            physicalResult: fixture.objectABI(fixture.objectTypeName),
            resultConvention: .directOwned,
            effects: .init(mayAllocate: true),
            methodFamily: .initializer
        )

        try call.invoker.validateRuntimeABI()
        guard case let .returned(.some(.native(native))) = try fixture.invoke(
            call,
            arguments: [.string("cluster")]
        ) else {
            Issue.record("class-cluster initializer did not return a native object")
            return
        }
        #expect(
            native.value(as: HelixRuntimeTestCluster.self)?.value == "cluster"
        )
    }

    @Test("Optimized ABI validation retains every temporary encoding owner")
    func retainsTemporaryEncodingOwners() throws {
        let receiverType = Core.TypeID(
            rawValue: .sha256("ObjectiveCInvoker.NSURLComponents")
        )
        let effects = Core.Effects(
            mayAllocate: true,
            hasExternalSideEffects: true
        )
        let contract = Core.NativeImportContract.bounded(
            kind: .instanceSetter,
            domain: .application,
            access: .write,
            maximumDurationMicroseconds: 2_000,
            allowsMainThread: true
        )
        let descriptor = try Core.NativeCall.Descriptor(
            target: .init(
                backend: .objectiveCMessage,
                module: "Foundation",
                owner: "NSURLComponents",
                member: "query.set",
                entryPoint: "setQuery:",
                dispatch: .instance,
                receiverArgumentIndex: 1
            ),
            logicalSignature: .init(
                parameters: [
                    .init(type: "Swift.Optional<Swift.String>"),
                    .init(type: "NSURLComponents"),
                ],
                result: .init(type: "Swift.Void")
            ),
            physicalSignature: .init(
                callingConvention: .objectiveC,
                parameters: [.init(
                    type: .init(
                        kind: .object,
                        canonicalName: "NSString",
                        encoding: "@",
                        isNullable: true
                    ),
                    source: .argument(0)
                )],
                result: .void,
                resultConvention: .direct
            ),
            objectiveC: .init(
                runtimeClassName: "NSURLComponents",
                methodFamily: .none,
                property: .init(name: "query", accessor: .setter)
            ),
            effects: effects
        ).validated(contract: contract)
        let key = try Core.NativeCall.Key.derive(descriptor: descriptor)
        let invoker = Runtime.ObjectiveCInvoker(
            id: .init(rawValue: 0),
            key: key,
            descriptor: descriptor,
            parameterTypes: [.optional(.string), .native(receiverType)],
            resultType: .void,
            effects: effects,
            contract: contract
        )

        try invoker.validateConfiguration()
        try invoker.validateRuntimeABI()
    }
}
}

extension RuntimeTests.ObjectiveCInvoker {
    struct Call {
        let invoker: Runtime.ObjectiveCInvoker
        let effects: Core.Effects
        let contract: Core.NativeImportContract
    }

    struct Fixture {
        let objectTypeID = Core.TypeID(rawValue: .sha256("ObjectiveCInvoker.Object"))
        let pointTypeID = Core.TypeID(rawValue: .sha256("ObjectiveCInvoker.Point"))
        let objectTypeName: String
        let pointTypeName = "HelixRuntimeTestSupport.HelixRuntimeTestPoint"
        let pointEncoding: String
        let boolEncoding: String
        let integerEncoding: String
        let unsignedEncoding: String
        let floatEncoding: String
        let doubleEncoding: String
        let catalog: VM.NativeTypeCatalog
        private let receiverTypeName: String

        init<Receiver: AnyObject>(
            receiverClass: Receiver.Type = HelixRuntimeTestObject.self
        ) throws {
            pointEncoding = String(cString: HelixRuntimeTestPointEncoding())
            boolEncoding = String(cString: HelixRuntimeTestBoolEncoding())
            integerEncoding = String(cString: HelixRuntimeTestIntegerEncoding())
            unsignedEncoding = String(cString: HelixRuntimeTestUnsignedEncoding())
            floatEncoding = String(cString: HelixRuntimeTestFloatEncoding())
            doubleEncoding = String(cString: HelixRuntimeTestDoubleEncoding())
            let typeName = "HelixRuntimeTestSupport.\(String(describing: Receiver.self))"
            receiverTypeName = typeName
            objectTypeName = typeName
            catalog = try .init([
                .reference(
                    id: objectTypeID,
                    canonicalName: receiverTypeName,
                    layoutFingerprint: .sha256("ObjectiveCInvoker.Object.Layout"),
                    estimatedByteCount: { (_: Receiver) in
                        UInt64(MemoryLayout<Receiver>.stride)
                    }
                ),
                .objectiveCStructure(
                    id: pointTypeID,
                    canonicalName: pointTypeName,
                    layoutFingerprint: .sha256("ObjectiveCInvoker.Point.Layout"),
                    encoding: pointEncoding,
                    clone: { (value: HelixRuntimeTestPoint) in value }
                ),
            ])
        }

        var boolABI: Core.NativeCall.ABIType {
            .init(
                kind: .boolean,
                canonicalName: "ObjectiveC.BOOL",
                size: UInt16(MemoryLayout<Bool>.size),
                alignment: UInt16(MemoryLayout<Bool>.alignment),
                encoding: boolEncoding
            )
        }

        var integerABI: Core.NativeCall.ABIType {
            .init(
                kind: .signedInteger,
                canonicalName: "ObjectiveC.NSInteger",
                size: UInt16(MemoryLayout<Int>.size),
                alignment: UInt16(MemoryLayout<Int>.alignment),
                encoding: integerEncoding
            )
        }

        var doubleABI: Core.NativeCall.ABIType {
            .init(
                kind: .floatingPoint,
                canonicalName: "Swift.Double",
                size: UInt16(MemoryLayout<Double>.size),
                alignment: UInt16(MemoryLayout<Double>.alignment),
                encoding: doubleEncoding
            )
        }

        var unsignedABI: Core.NativeCall.ABIType {
            .init(
                kind: .unsignedInteger,
                canonicalName: "ObjectiveC.NSUInteger",
                size: UInt16(MemoryLayout<UInt>.size),
                alignment: UInt16(MemoryLayout<UInt>.alignment),
                encoding: unsignedEncoding
            )
        }

        var floatABI: Core.NativeCall.ABIType {
            .init(
                kind: .floatingPoint,
                canonicalName: "Swift.Float",
                size: UInt16(MemoryLayout<Float>.size),
                alignment: UInt16(MemoryLayout<Float>.alignment),
                encoding: floatEncoding
            )
        }

        var pointABI: Core.NativeCall.ABIType {
            .init(
                kind: .structure,
                canonicalName: pointTypeName,
                size: UInt16(MemoryLayout<HelixRuntimeTestPoint>.size),
                alignment: UInt16(MemoryLayout<HelixRuntimeTestPoint>.alignment),
                encoding: pointEncoding
            )
        }

        var blockABI: Core.NativeCall.ABIType {
            .init(
                kind: .block,
                canonicalName: "ObjectiveC.Block",
                encoding: "@?"
            )
        }

        func objectABI(
            _ name: String,
            nullable: Bool = false
        ) -> Core.NativeCall.ABIType {
            .init(
                kind: .object,
                canonicalName: name,
                encoding: "@",
                isNullable: nullable
            )
        }

        func objectParameter() -> Core.NativeCall.LogicalParameter {
            .init(type: receiverTypeName)
        }

        func objectValue(_ object: AnyObject) throws -> VM.Value {
            .native(try catalog.boxReference(object, as: objectTypeID))
        }

        func integer(_ value: Int64) throws -> VM.Value {
            .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
        }

        func unsigned(_ value: UInt64) throws -> VM.Value {
            .integer(try .init(rawBits: value, bitWidth: 64, isSigned: false))
        }

        func float(_ value: Float) throws -> VM.Value {
            .float(try .init(bitPattern: UInt64(value.bitPattern), bitWidth: 32))
        }

        func double(_ value: Double) throws -> VM.Value {
            .float(.init(value))
        }

        func call(
            owner: String = "HelixRuntimeTestObject",
            runtimeClass: String = "HelixRuntimeTestObject",
            dispatchClass: String? = nil,
            member: String,
            selector: String,
            dispatch: Core.NativeCall.Dispatch,
            kind: Core.NativeImportKind,
            implementationLookup:
                Core.NativeCall.ObjectiveCImplementationLookup = .declaringClass,
            access: Core.NativeImportAccess = .pure,
            callbacks: [Core.NativeImportCallback] = [],
            logicalParameters: [Core.NativeCall.LogicalParameter],
            logicalResult: String,
            valueParameterTypes: [Bytecode.ValueType]? = nil,
            valueResultType: Bytecode.ValueType? = nil,
            physicalParameters: [Core.NativeCall.ABIParameter],
            physicalResult: Core.NativeCall.ABIType,
            resultConvention: Core.NativeCall.ABIConvention = .direct,
            errorConvention: Core.NativeCall.ErrorConvention = .none,
            effects: Core.Effects = .init(),
            methodFamily: Core.NativeCall.ObjectiveCMethodFamily = .none,
            lexicalSuperclass: String? = nil,
            errorFailure: Core.NativeCall.ObjectiveCErrorFailure? = nil,
            property: Core.NativeCall.ObjectiveCProperty? = nil,
            availability: [Core.NativeCall.Availability] = [],
            environment: Runtime.NativeEnvironment = .init(
                platform: "macOS",
                version: .init(14)
            )
        ) throws -> Call {
            let contract = Core.NativeImportContract.bounded(
                kind: kind,
                domain: .application,
                access: access,
                maximumDurationMicroseconds: 2_000,
                allowsMainThread: true,
                callbacks: callbacks
            )
            let descriptor = try Core.NativeCall.Descriptor(
                target: .init(
                    backend: .objectiveCMessage,
                    module: "HelixRuntimeTestSupport",
                    owner: owner,
                    member: member,
                    entryPoint: selector,
                    dispatch: dispatch,
                    receiverArgumentIndex: dispatch == .instance ? 0 : nil
                ),
                logicalSignature: .init(
                    parameters: logicalParameters,
                    result: .init(type: logicalResult),
                    isThrowing: effects.mayThrow,
                    isAsync: effects.isAsync,
                    isolation: effects.requiresMainActor ? "MainActor" : nil
                ),
                physicalSignature: .init(
                    callingConvention: .objectiveC,
                    parameters: physicalParameters,
                    result: physicalResult,
                    resultConvention: resultConvention,
                    errorConvention: errorConvention
                ),
                objectiveC: .init(
                    runtimeClassName: runtimeClass,
                    dispatchClassName: dispatch == .instance
                        ? nil : (dispatchClass ?? runtimeClass),
                    methodFamily: methodFamily,
                    implementationLookup: implementationLookup,
                    lexicalSuperclassName: lexicalSuperclass,
                    errorFailure: errorFailure,
                    property: property
                ),
                effects: effects,
                availability: availability
            ).validated(contract: contract)
            let key = try Core.NativeCall.Key.derive(descriptor: descriptor)
            let inferredParameterTypes: [Bytecode.ValueType] = logicalParameters.map { parameter in
                if parameter.type == "Swift.String" { return .string }
                if parameter.type == "Swift.Bool" { return .bool }
                if parameter.type == "Swift.Int" { return .int64 }
                if parameter.type == "Swift.Double" {
                    return .float(bitWidth: 64)
                }
                if parameter.type == pointTypeName { return .native(pointTypeID) }
                if parameter.type.contains("->") {
                    if parameter.type.contains("Swift.String") {
                        let parameters: [Bytecode.ValueType] = parameter.type.contains(",")
                            ? [.string, .string]
                            : [.string]
                        return .closure(.init(
                            parameters: parameters,
                            parameterConventions: Array(
                                repeating: .owned,
                                count: parameters.count
                            ),
                            result: .bool
                        ))
                    }
                    return .closure(.init(
                        parameters: [.bool],
                        parameterConventions: [.owned],
                        result: .void
                    ))
                }
                return .native(objectTypeID)
            }
            let inferredResultType: Bytecode.ValueType = switch logicalResult {
            case "Swift.Void": .void
            case "Swift.String": .string
            case "Swift.Bool": .bool
            case "Swift.Int": .int64
            case "Swift.Float": .float(bitWidth: 32)
            case "Swift.Double": .float(bitWidth: 64)
            case pointTypeName: .native(pointTypeID)
            default: .native(objectTypeID)
            }
            return .init(
                invoker: Runtime.ObjectiveCInvoker(
                    id: .init(rawValue: UInt32(truncatingIfNeeded: key.rawValue.bytes[0])),
                    key: key,
                    descriptor: descriptor,
                    parameterTypes: valueParameterTypes ?? inferredParameterTypes,
                    resultType: valueResultType ?? inferredResultType,
                    effects: effects,
                    contract: contract,
                    environment: environment
                ),
                effects: effects,
                contract: contract
            )
        }

        func invoke(
            _ call: Call,
            arguments: [VM.Value],
            callbackHost: VM.NativeCallbackHost? = nil,
            limits: Core.ResourceLimits = .init(
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        ) throws -> VM.NativeInvocationResult {
            let budget = VM.InvocationBudget(
                limits: limits,
                isMainThread: Thread.isMainThread,
                nowNanoseconds: { 0 }
            )
            let context = try budget.beginNativeInvocation(
                id: call.invoker.id,
                effects: call.effects,
                contract: call.contract,
                parameterTypes: call.invoker.parameterTypes,
                callbackHost: callbackHost,
                nativeTypeCatalog: catalog,
                isMainThread: Thread.isMainThread
            )
            do {
                let result = try call.invoker.invoke(
                    arguments: arguments,
                    context: context
                )
                try context.finish(requireCooperation: false)
                return result
            } catch {
                try? context.finish(requireCooperation: false)
                throw error
            }
        }
    }

    final class CallbackObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var argumentStorage: [[VM.Value]] = []
        private var failureStorage: [VM.RuntimeTrap] = []

        var arguments: [[VM.Value]] { lock.withLock { argumentStorage } }
        var failures: [VM.RuntimeTrap] { lock.withLock { failureStorage } }

        func host(result: VM.Value?) -> VM.NativeCallbackHost {
            .init(
                invoke: { [self] _, arguments, _ in
                    lock.withLock { argumentStorage.append(arguments) }
                    return .returned(result)
                },
                reportFailure: { [self] failure in
                    lock.withLock { failureStorage.append(failure) }
                }
            )
        }
    }
}
