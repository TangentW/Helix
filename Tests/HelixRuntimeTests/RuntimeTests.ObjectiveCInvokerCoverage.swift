import HelixBytecode
import HelixCore
import HelixObjectiveCRuntimeSupport
import HelixRuntimeTestSupport
import HelixVM
import Testing
@testable import HelixRuntime

extension RuntimeTests.ObjectiveCInvoker {
    @Test("Signed, unsigned, Float, and Double values preserve their exact ABI")
    func scalarABIMatrix() throws {
        let fixture = try Fixture()
        let receiver = try fixture.objectValue(HelixRuntimeTestObject())

        let unsignedSum = try fixture.call(
            member: "addUnsignedLeft(_:right:)",
            selector: "addUnsignedLeft:right:",
            dispatch: .static,
            kind: .staticMethod,
            logicalParameters: [
                .init(type: "Swift.UInt"), .init(type: "Swift.UInt"),
            ],
            logicalResult: "Swift.UInt",
            valueParameterTypes: [
                .integer(bitWidth: 64, signed: false),
                .integer(bitWidth: 64, signed: false),
            ],
            valueResultType: .integer(bitWidth: 64, signed: false),
            physicalParameters: [
                .init(type: fixture.unsignedABI, source: .argument(0)),
                .init(type: fixture.unsignedABI, source: .argument(1)),
            ],
            physicalResult: fixture.unsignedABI
        )
        #expect(
            try fixture.invoke(
                unsignedSum,
                arguments: [fixture.unsigned(19), fixture.unsigned(23)]
            ) == .returned(fixture.unsigned(42))
        )

        let floatScale = try fixture.call(
            member: "scaleFloat(_:)",
            selector: "scaleFloat:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [
                fixture.objectParameter(), .init(type: "Swift.Float"),
            ],
            logicalResult: "Swift.Float",
            valueParameterTypes: [
                .native(fixture.objectTypeID), .float(bitWidth: 32),
            ],
            valueResultType: .float(bitWidth: 32),
            physicalParameters: [
                .init(type: fixture.floatABI, source: .argument(1)),
            ],
            physicalResult: fixture.floatABI
        )
        #expect(
            try fixture.invoke(
                floatScale,
                arguments: [receiver, fixture.float(2.5)]
            ) == .returned(fixture.float(5))
        )

        let doubleScale = try fixture.call(
            member: "scaleDouble(_:)",
            selector: "scaleDouble:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [
                fixture.objectParameter(), .init(type: "Swift.Double"),
            ],
            logicalResult: "Swift.Double",
            physicalParameters: [
                .init(type: fixture.doubleABI, source: .argument(1)),
            ],
            physicalResult: fixture.doubleABI
        )
        #expect(
            try fixture.invoke(
                doubleScale,
                arguments: [receiver, fixture.double(3.25)]
            ) == .returned(fixture.double(6.5))
        )
    }

    @Test("Optional objects preserve nil and validate concrete Objective-C classes")
    func optionalObjectsAndRuntimeClasses() throws {
        let fixture = try Fixture()
        let object = HelixRuntimeTestObject()
        let receiver = try fixture.objectValue(object)
        let optionalString = Bytecode.ValueType.optional(.string)
        let nullable = try fixture.call(
            member: "nullableEcho(_:)",
            selector: "nullableEcho:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [
                fixture.objectParameter(), .init(type: "Swift.String?"),
            ],
            logicalResult: "Swift.String?",
            valueParameterTypes: [
                .native(fixture.objectTypeID), optionalString,
            ],
            valueResultType: optionalString,
            physicalParameters: [
                .init(
                    type: fixture.objectABI("Foundation.NSString", nullable: true),
                    source: .argument(1)
                ),
            ],
            physicalResult: fixture.objectABI("Foundation.NSString", nullable: true)
        )
        #expect(
            try fixture.invoke(
                nullable,
                arguments: [receiver, .optional(nil)]
            ) == .returned(.optional(nil))
        )
        #expect(
            try fixture.invoke(
                nullable,
                arguments: [receiver, .optional(.string("present"))]
            ) == .returned(.optional(.string("present")))
        )

        let typeChecked = try fixture.call(
            member: "recordString(_:)",
            selector: "recordString:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .write,
            logicalParameters: [
                fixture.objectParameter(), fixture.objectParameter(),
            ],
            logicalResult: "Swift.Void",
            physicalParameters: [
                .init(
                    type: fixture.objectABI("Foundation.NSString"),
                    source: .argument(1)
                ),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true)
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(typeChecked, arguments: [receiver, receiver])
        }
        #expect(object.invocationCount == 0)

        let protocolChecked = try fixture.call(
            member: "recordNamingObject(_:)",
            selector: "recordNamingObject:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .write,
            logicalParameters: [
                fixture.objectParameter(), fixture.objectParameter(),
            ],
            logicalResult: "Swift.Void",
            physicalParameters: [
                .init(
                    type: fixture.objectABI("any HelixRuntimeTestNaming"),
                    source: .argument(1)
                ),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true)
        )
        let conforming = try fixture.objectValue(HelixRuntimeTestNamedObject())
        #expect(
            try fixture.invoke(
                protocolChecked,
                arguments: [receiver, conforming]
            ) == .returned(nil)
        )
        #expect(object.invocationCount == 1)
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                protocolChecked,
                arguments: [receiver, receiver]
            )
        }
        #expect(object.invocationCount == 1)
    }

    @Test("ARC method families and replacement initializers transfer one owned result")
    func objectOwnershipFamilies() throws {
        let fixture = try Fixture()
        let object = HelixRuntimeTestObject()
        object.name = "copy source"
        let receiver = try fixture.objectValue(object)
        let copy = try fixture.call(
            member: "copyName()",
            selector: "copyName",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.String",
            physicalParameters: [],
            physicalResult: fixture.objectABI("Foundation.NSString"),
            resultConvention: .directOwned,
            methodFamily: .copy
        )
        #expect(
            try fixture.invoke(copy, arguments: [receiver])
                == .returned(.string("copy source"))
        )

        let replacement = try fixture.call(
            member: "initReturningReplacement()",
            selector: "initReturningReplacement",
            dispatch: .initializer,
            kind: .initializer,
            logicalParameters: [],
            logicalResult: fixture.objectTypeName,
            physicalParameters: [],
            physicalResult: fixture.objectABI(fixture.objectTypeName),
            resultConvention: .directOwned,
            effects: .init(mayAllocate: true),
            methodFamily: .initializer
        )
        guard case let .returned(.some(.native(native))) = try fixture.invoke(
            replacement,
            arguments: []
        ) else {
            Issue.record("replacement initializer did not return a native object")
            return
        }
        #expect(native.value(as: HelixRuntimeTestObject.self)?.name == "replacement")
    }

    @Test("Unknown selectors, nil receivers, and unavailable APIs fail before dispatch")
    func failClosedRuntimeBoundaries() throws {
        let fixture = try Fixture()
        let receiver = try fixture.objectValue(HelixRuntimeTestObject())
        let unknown = try fixture.call(
            member: "unknown()",
            selector: "helixUnknownSelector",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [fixture.objectParameter()],
            logicalResult: "Swift.Void",
            physicalParameters: [],
            physicalResult: .void
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(unknown, arguments: [receiver])
        }

        let optionalReceiver = Bytecode.ValueType.optional(
            .native(fixture.objectTypeID)
        )
        let nilReceiver = try fixture.call(
            member: "echo(_:)",
            selector: "echo:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [
                .init(type: "\(fixture.objectTypeName)?"),
                .init(type: "Swift.String"),
            ],
            logicalResult: "Swift.String",
            valueParameterTypes: [optionalReceiver, .string],
            physicalParameters: [
                .init(
                    type: fixture.objectABI("Foundation.NSString"),
                    source: .argument(1)
                ),
            ],
            physicalResult: fixture.objectABI("Foundation.NSString")
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                nilReceiver,
                arguments: [.optional(nil), .string("ignored")]
            )
        }

        let unavailable = try fixture.call(
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
            physicalResult: fixture.objectABI("Foundation.NSString"),
            availability: [
                .init(platform: "macOS", introduced: .init(15)),
            ],
            environment: .init(platform: "macOS", version: .init(14, 5))
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                unavailable,
                arguments: [receiver, .string("ignored")]
            )
        }
    }

    @Test("Receiver ancestry and dynamic override ABI are checked without messaging the object")
    func validatesRuntimeReceiverClassAndOverride() throws {
        let broadFixture = try Fixture(
            receiverClass: HelixRuntimeTestLyingObject.self
        )
        let echoForLiar = try broadFixture.call(
            member: "echo(_:)",
            selector: "echo:",
            dispatch: .instance,
            kind: .instanceMethod,
            logicalParameters: [
                broadFixture.objectParameter(), .init(type: "Swift.String"),
            ],
            logicalResult: "Swift.String",
            physicalParameters: [
                .init(
                    type: broadFixture.objectABI("Foundation.NSString"),
                    source: .argument(1)
                ),
            ],
            physicalResult: broadFixture.objectABI("Foundation.NSString")
        )
        do {
            _ = try broadFixture.invoke(
                echoForLiar,
                arguments: [
                    try broadFixture.objectValue(HelixRuntimeTestLyingObject()),
                    .string("ignored"),
                ]
            )
            Issue.record("a receiver outside the cataloged class hierarchy was accepted")
        } catch {
            #expect(String(describing: error).contains("wrong class"))
        }
        let liar = HelixRuntimeTestLyingObject()
        let liarPointer = Unmanaged.passUnretained(liar).toOpaque()
        #expect(!"HelixRuntimeTestObject".withCString {
            helix_runtime_objective_c_object_is_kind_of(liarPointer, $0)
        })
        #expect(!"HelixRuntimeTestNaming".withCString {
            helix_runtime_objective_c_object_conforms_to_protocol(
                liarPointer,
                $0
            )
        })

        let fixture = try Fixture()
        let incompatible = HelixRuntimeTestMakeIncompatibleEchoObject()
        let echo = try fixture.call(
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
        do {
            _ = try fixture.invoke(
                echo,
                arguments: [
                    try fixture.objectValue(incompatible),
                    .string("ignored"),
                ]
            )
            Issue.record("an Objective-C override with a conflicting ABI was invoked")
        } catch {
            #expect(String(describing: error).contains("override ABI"))
        }
    }

    @Test("Optional and Error Blocks use reusable object-shaped trampolines")
    func optionalAndErrorBlocks() throws {
        let fixture = try Fixture()
        let receiver = try fixture.objectValue(HelixRuntimeTestObject())
        let boolVoid = Bytecode.ClosureSignature(
            parameters: [.bool],
            parameterConventions: [.owned],
            result: .void
        )
        var nullableBlock = fixture.blockABI
        nullableBlock.isNullable = true
        let optionalCall = try fixture.call(
            member: "callOptional(_:)",
            selector: "callOptional:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .readWrite,
            callbacks: [.init(parameterIndex: 1, lifetime: .nonescaping)],
            logicalParameters: [
                fixture.objectParameter(),
                .init(
                    type: "((Swift.Bool) -> Swift.Void)?",
                    callbackLifetime: .nonescaping
                ),
            ],
            logicalResult: "Swift.Void",
            valueParameterTypes: [
                .native(fixture.objectTypeID), .optional(.closure(boolVoid)),
            ],
            physicalParameters: [
                .init(
                    type: nullableBlock,
                    ownership: .borrowed,
                    source: .argument(1)
                ),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true)
        )
        #expect(
            try fixture.invoke(
                optionalCall,
                arguments: [receiver, .optional(nil)]
            ) == .returned(nil)
        )

        let errorVoid = Bytecode.ClosureSignature(
            parameters: [.error],
            parameterConventions: [.borrowed],
            result: .void
        )
        let closure = VM.Value.closure(.init(
            functionID: .init(rawValue: 4),
            signature: errorVoid,
            captures: []
        ))
        let errorCall = try fixture.call(
            member: "callError(_:)",
            selector: "callError:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .readWrite,
            callbacks: [.init(parameterIndex: 1, lifetime: .nonescaping)],
            logicalParameters: [
                fixture.objectParameter(),
                .init(
                    type: "(Swift.Error) -> Swift.Void",
                    callbackLifetime: .nonescaping
                ),
            ],
            logicalResult: "Swift.Void",
            valueParameterTypes: [
                .native(fixture.objectTypeID), .closure(errorVoid),
            ],
            physicalParameters: [
                .init(
                    type: fixture.blockABI,
                    ownership: .borrowed,
                    source: .argument(1)
                ),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true)
        )
        let observation = CallbackObservation()
        #expect(
            try fixture.invoke(
                errorCall,
                arguments: [receiver, closure],
                callbackHost: observation.host(result: nil)
            ) == .returned(nil)
        )
        guard case let .error(error)? = observation.arguments.last?.first else {
            Issue.record("NSError callback did not become a VM Error value")
            return
        }
        #expect(error.message.contains("dev.helix.callback(17)"))
        #expect(observation.failures.isEmpty)
    }

    @Test("Unsupported ABI kinds and Block shapes fail before Objective-C dispatch")
    func unsupportedShapesFailClosed() throws {
        let fixture = try Fixture()
        let object = HelixRuntimeTestObject()
        let receiver = try fixture.objectValue(object)
        let classObject = try fixture.call(
            member: "recordString(_:)",
            selector: "recordString:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .write,
            logicalParameters: [
                fixture.objectParameter(), fixture.objectParameter(),
            ],
            logicalResult: "Swift.Void",
            physicalParameters: [
                .init(
                    type: .init(
                        kind: .classObject,
                        canonicalName: "ObjectiveC.Class",
                        encoding: "#"
                    ),
                    source: .argument(1)
                ),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true)
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(classObject, arguments: [receiver, receiver])
        }

        let unsupportedSignature = Bytecode.ClosureSignature(
            parameters: [.bool, .bool],
            parameterConventions: [.owned, .owned],
            result: .void
        )
        let unsupportedBlock = try fixture.call(
            member: "callNow(_:)",
            selector: "callNow:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .readWrite,
            callbacks: [.init(parameterIndex: 1, lifetime: .nonescaping)],
            logicalParameters: [
                fixture.objectParameter(),
                .init(
                    type: "(Swift.Bool, Swift.Bool) -> Swift.Void",
                    callbackLifetime: .nonescaping
                ),
            ],
            logicalResult: "Swift.Void",
            valueParameterTypes: [
                .native(fixture.objectTypeID), .closure(unsupportedSignature),
            ],
            physicalParameters: [
                .init(
                    type: fixture.blockABI,
                    ownership: .borrowed,
                    source: .argument(1)
                ),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true)
        )
        let closure = VM.Value.closure(.init(
            functionID: .init(rawValue: 6),
            signature: unsupportedSignature,
            captures: []
        ))
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                unsupportedBlock,
                arguments: [receiver, closure],
                callbackHost: CallbackObservation().host(result: nil)
            )
        }
        #expect(object.invocationCount == 0)
    }

    @Test("Descriptor metadata and ABI buffers share one temporary-byte ceiling")
    func invocationStorageIsBounded() throws {
        let fixture = try Fixture()
        let object = HelixRuntimeTestObject()
        let receiver = try fixture.objectValue(object)
        let call = try fixture.call(
            member: "recordString(_:)",
            selector: "recordString:",
            dispatch: .instance,
            kind: .instanceMethod,
            access: .write,
            logicalParameters: [
                fixture.objectParameter(), .init(type: "Swift.String"),
            ],
            logicalResult: "Swift.Void",
            physicalParameters: [
                .init(
                    type: fixture.objectABI("Foundation.NSString"),
                    source: .argument(1)
                ),
            ],
            physicalResult: .void,
            effects: .init(hasExternalSideEffects: true)
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                call,
                arguments: [receiver, .string("must not dispatch")],
                limits: .init(
                    maxNativeOwnedBytes: 8,
                    maxWallTimeMainThreadMilliseconds: 1_000
                )
            )
        }
        #expect(object.invocationCount == 0)
    }
}
