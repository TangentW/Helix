import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
import Testing
@testable import HelixRuntime

extension RuntimeTests {
@Suite("Runtime native callbacks")
struct NativeCallback {
    @Test("Escaping callback re-enters its pinned image after rollback")
    func escapingCallbackPinsGeneration() throws {
        let fixture = try Fixture()
        let callbackBox = CallbackBox()
        let observed = IntegerBox()
        let callbackImport = VM.ClosureNativeInvoker(
            id: fixture.exportID,
            key: fixture.exportKey,
            parameterTypes: [.closure(fixture.callbackBoundarySignature)],
            resultType: .void,
            effects: fixture.effects,
            contract: fixture.exportContract,
            invoke: { arguments, context in
                callbackBox.value = try context.makeCallback(
                    parameterIndex: 0,
                    from: arguments[0]
                )
                return .returned(nil)
            }
        )
        let observationImport = VM.ClosureNativeInvoker(
            id: fixture.observationID,
            key: fixture.observationKey,
            parameterTypes: [.int64],
            resultType: .void,
            effects: fixture.effects,
            contract: fixture.observationContract,
            invoke: { arguments, _ in
                guard case let .integer(value) = arguments[0] else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: .int64,
                        actual: arguments[0].type
                    )
                }
                observed.append(value.signedValue)
                return .returned(nil)
            }
        )
        let runtime = try Runtime.Engine(
            originals: fixture.originals(observed: observed),
            nativeCatalog: .init([callbackImport, observationImport]),
            bridgeInputLimits: .init(maximumValueNodes: 1)
        )
        let generation = try fixture.generation(id: 1)
        _ = try runtime.activate(generation, expectedActiveID: nil)

        #expect(runtime.invoke(entry: fixture.entry, arguments: []) == .returned(nil))
        let callback = try #require(callbackBox.value)
        try runtime.rollback(expectedActiveID: generation.id, to: nil)

        #expect(throws: Runtime.BridgeInputError.self) {
            try runtime.encodeNativeCallbackArguments(
                for: callback,
                count: 2
            ) { encoder in
                [try encoder.encode(1), try encoder.encode(2)]
            }
        }

        callback.invokeVoid {
            [.integer(try VM.Integer(signed: 42, bitWidth: 64, isSigned: true))]
        }
        #expect(observed.values == [42])
    }

    @Test("A result callback routes its pinned frozen entry after rollback")
    func resultCallbackPinsFrozenEntryGeneration() throws {
        let fixture = try Fixture(callbackResult: .int64)
        let callbackBox = CallbackBox()
        let observed = IntegerBox()
        let callbackImport = VM.ClosureNativeInvoker(
            id: fixture.exportID,
            key: fixture.exportKey,
            parameterTypes: [.closure(fixture.callbackBoundarySignature)],
            resultType: .void,
            effects: fixture.effects,
            contract: fixture.exportContract,
            invoke: { arguments, context in
                callbackBox.value = try context.makeCallback(
                    parameterIndex: 0,
                    from: arguments[0]
                )
                return .returned(nil)
            }
        )
        let observationImport = VM.ClosureNativeInvoker(
            id: fixture.observationID,
            key: fixture.observationKey,
            parameterTypes: [.int64],
            resultType: .void,
            effects: fixture.effects,
            contract: fixture.observationContract,
            invoke: { arguments, _ in
                guard case let .integer(value) = arguments[0] else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: .int64,
                        actual: arguments[0].type
                    )
                }
                observed.append(value.signedValue)
                return .returned(nil)
            }
        )
        let runtime = try Runtime.Engine(
            originals: fixture.originals(observed: observed),
            nativeCatalog: .init([callbackImport, observationImport])
        )
        let generation = try fixture.generation(
            id: 1,
            target: .entry
        )
        _ = try runtime.activate(generation, expectedActiveID: nil)
        #expect(runtime.invoke(entry: fixture.entry, arguments: []) == .returned(nil))
        let callback = try #require(callbackBox.value)
        try runtime.rollback(expectedActiveID: generation.id, to: nil)

        let result: Int64 = callback.invokeResult(
            arguments: {
                [.integer(try VM.Integer(
                    signed: 42,
                    bitWidth: 64,
                    isSigned: true
                ))]
            },
            decodeResult: { value in
                guard case let .integer(integer) = value else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: .int64,
                        actual: value.type
                    )
                }
                return integer.signedValue
            },
            failureResult: { -1 }
        )
        #expect(result == 42)
        #expect(observed.values == [42])
    }

    @Test("An escaping NativeImport function closure keeps its generation")
    func nativeImportClosurePinsGeneration() throws {
        let fixture = try Fixture()
        let callbackBox = CallbackBox()
        let observed = IntegerBox()
        let callbackImport = VM.ClosureNativeInvoker(
            id: fixture.exportID,
            key: fixture.exportKey,
            parameterTypes: [.closure(fixture.callbackBoundarySignature)],
            resultType: .void,
            effects: fixture.effects,
            contract: fixture.exportContract,
            invoke: { arguments, context in
                callbackBox.value = try context.makeCallback(
                    parameterIndex: 0,
                    from: arguments[0]
                )
                return .returned(nil)
            }
        )
        let observationImport = VM.ClosureNativeInvoker(
            id: fixture.observationID,
            key: fixture.observationKey,
            parameterTypes: [.int64],
            resultType: .void,
            effects: fixture.effects,
            contract: fixture.observationContract,
            invoke: { arguments, _ in
                guard case let .integer(value) = arguments[0] else {
                    throw VM.RuntimeTrap.typeMismatch(
                        expected: .int64,
                        actual: arguments[0].type
                    )
                }
                observed.append(value.signedValue)
                return .returned(nil)
            }
        )
        let runtime = try Runtime.Engine(
            originals: fixture.originals(observed: observed),
            nativeCatalog: .init([callbackImport, observationImport])
        )
        let generation = try fixture.generation(
            id: 1,
            target: .nativeImport
        )
        _ = try runtime.activate(generation, expectedActiveID: nil)
        #expect(runtime.invoke(entry: fixture.entry, arguments: []) == .returned(nil))
        let callback = try #require(callbackBox.value)
        try runtime.rollback(expectedActiveID: generation.id, to: nil)

        callback.invokeVoid {
            [.integer(try VM.Integer(signed: 42, bitWidth: 64, isSigned: true))]
        }
        #expect(observed.values == [42])
    }

    @Test("Verifier rejects a lexical closure at an escaping callback boundary")
    func lexicalClosureCannotEscape() throws {
        let fixture = try Fixture()
        #expect(throws: Verification.Error.self) {
            try fixture.generation(id: 1, closureLifetime: .lexical)
        }
    }

    @Test("Actor restriction cannot hide a lexical closure from an escaping callback")
    func convertedLexicalClosureCannotEscape() throws {
        let fixture = try Fixture()
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "a dynamically scoped closure cannot enter an escaping NativeImport callback"
            )
        ) {
            try fixture.generation(
                id: 1,
                closureLifetime: .lexical,
                restrictCallbackToMainActor: true
            )
        }
    }

    @Test("An outer closure cannot hide a lexical callback capture")
    func nestedLexicalClosureCannotEscape() throws {
        let fixture = try Fixture()
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "a dynamically scoped closure cannot enter an escaping NativeImport callback"
            )
        ) {
            try fixture.generation(
                id: 1,
                closureLifetime: .lexical,
                wrapsCallback: true
            )
        }
    }

    @Test("An aggregate capture cannot hide a lexical callback")
    func aggregateLexicalClosureCannotEscape() throws {
        let fixture = try Fixture()
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 3,
                reason: "a dynamically scoped closure cannot enter an escaping NativeImport callback"
            )
        ) {
            try fixture.generation(
                id: 1,
                closureLifetime: .lexical,
                wrapsCallbackInArray: true
            )
        }
    }

    private struct Fixture {
        enum CallbackTarget: Equatable {
            case image
            case entry
            case nativeImport
        }

        let entry = Core.EntryIndex(rawValue: 0)
        let callbackEntry = Core.EntryIndex(rawValue: 1)
        let exportID = Core.NativeImportID(rawValue: 0)
        let observationID = Core.NativeImportID(rawValue: 1)
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.runtime.callback",
            buildNumber: "1",
            seed: "fixture"
        )
        let shellHash = Core.Digest.sha256("runtime-native-callback-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "runtime-native-callback"
        )
        let effects = Core.Effects(
            mayAllocate: true,
            hasExternalSideEffects: true
        )
        let callbackBoundarySignature: Bytecode.ClosureSignature
        let callbackSignature: Bytecode.ClosureSignature
        let exportContract: Core.NativeImportContract
        let observationContract: Core.NativeImportContract
        let exportSignature: Core.LoweredSignature
        let exportKey: Core.NativeImportKey
        let observationKey: Core.NativeImportKey
        let entryKey: Core.FunctionKey
        let callbackEntryKey: Core.FunctionKey

        init(callbackResult: Bytecode.ValueType = .void) throws {
            guard callbackResult == .void || callbackResult == .int64 else {
                throw VM.RuntimeTrap.nativeFailure(
                    "Runtime callback fixture received an unsupported result"
                )
            }
            callbackBoundarySignature = .init(
                parameters: [.int64],
                parameterConventions: [.owned],
                result: callbackResult
            )
            callbackSignature = .init(
                parameters: [.int64],
                parameterConventions: [.owned],
                result: callbackResult
            )
            exportContract = .bounded(
                kind: .globalFunction,
                domain: .application,
                access: .write,
                maximumDurationMicroseconds: 500,
                allowsMainThread: true,
                callbacks: [.init(parameterIndex: 0, lifetime: .escaping)]
            )
            observationContract = .bounded(
                kind: .globalFunction,
                domain: .application,
                access: .write,
                maximumDurationMicroseconds: 500,
                allowsMainThread: true
            )
            let callbackResultSpelling = callbackResult == .void
                ? "Swift.Void" : "Swift.Int"
            exportSignature = .init(
                parameters: [
                    "@escaping (Swift.Int) -> \(callbackResultSpelling)",
                ],
                result: "Swift.Void"
            )
            exportKey = try Core.NativeImportKey.derive(
                namespace: namespace,
                canonicalCallee: "Fixture.retainCallback(_:)",
                signature: exportSignature,
                effects: effects,
                contract: exportContract
            )
            observationKey = try Core.NativeImportKey.derive(
                namespace: namespace,
                canonicalCallee: "Fixture.observe(_:)",
                signature: .init(
                    parameters: ["Swift.Int"],
                    result: "Swift.Void"
                ),
                effects: effects,
                contract: observationContract
            )
            entryKey = try Core.FunctionKey.derive(
                namespace: namespace,
                module: "Fixture",
                sourceFileLogicalID: "Sources/Fixture.swift",
                canonicalDeclaration: "func installCallback()",
                loweredSignature: .init(parameters: [], result: "Swift.Void"),
                role: .function
            )
            callbackEntryKey = try Core.FunctionKey.derive(
                namespace: namespace,
                module: "Fixture",
                sourceFileLogicalID: "Sources/Fixture.swift",
                canonicalDeclaration: "func originalCallback(_: Int)",
                loweredSignature: .init(
                    parameters: ["Swift.Int"],
                    result: callbackResultSpelling
                ),
                role: .function
            )
        }

        func originals(observed: IntegerBox) throws -> Runtime.OriginalCatalog {
            try .init([
                .init(
                    index: entry,
                    parameterTypes: [],
                    resultType: .void,
                    effects: effects,
                    invoke: { _ in .returned(nil) }
                ),
                .init(
                    index: callbackEntry,
                    parameterTypes: [.int64],
                    resultType: callbackSignature.result,
                    effects: effects,
                    invoke: { arguments in
                        guard arguments.count == 1,
                              case let .integer(value) = arguments[0]
                        else {
                            return .trapped(
                                .typeMismatch(
                                    expected: .int64,
                                    actual: arguments.first?.type
                                )
                            )
                        }
                        observed.append(value.signedValue)
                        return .returned(
                            callbackSignature.result == .void
                                ? nil : arguments[0]
                        )
                    }
                ),
            ])
        }

        func generation(
            id: UInt64,
            closureLifetime: Bytecode.ClosureLifetime = .invocation,
            restrictCallbackToMainActor: Bool = false,
            wrapsCallback: Bool = false,
            wrapsCallbackInArray: Bool = false,
            target: CallbackTarget = .image
        ) throws -> Runtime.Generation {
            precondition(
                [
                    restrictCallbackToMainActor,
                    wrapsCallback,
                    wrapsCallbackInArray,
                ].filter { $0 }.count <= 1
            )
            let closureType = Bytecode.ValueType.closure(callbackSignature)
            var boundarySignature = callbackBoundarySignature
            boundarySignature.effects.requiresMainActor =
                restrictCallbackToMainActor
            let callbackRegister: Bytecode.Register = .init(
                rawValue: wrapsCallbackInArray
                    ? 2
                    : (restrictCallbackToMainActor || wrapsCallback ? 1 : 0)
            )
            let closureTarget: Bytecode.ClosureTarget = switch target {
            case .image: .image(.init(rawValue: 1))
            case .entry: .entry(callbackEntry)
            case .nativeImport: .nativeImport(observationID)
            }
            var entryInstructions: [Bytecode.Instruction] = [
                .makeClosure(
                    result: .init(rawValue: 0),
                    target: closureTarget,
                    captures: [],
                    lifetime: closureLifetime
                ),
            ]
            var entryRegisterTypes = [closureType]
            if restrictCallbackToMainActor {
                entryRegisterTypes.append(.closure(boundarySignature))
                entryInstructions.append(
                    .convertClosure(
                        result: callbackRegister,
                        source: .init(rawValue: 0)
                    )
                )
            }
            if wrapsCallback {
                entryRegisterTypes.append(closureType)
                entryInstructions.append(
                    .makeClosure(
                        result: callbackRegister,
                        target: .image(.init(rawValue: 2)),
                        captures: [.init(rawValue: 0)]
                    )
                )
            }
            if wrapsCallbackInArray {
                entryRegisterTypes.append(.array(closureType))
                entryInstructions.append(
                    .makeArray(
                        result: .init(rawValue: 1),
                        elements: [.init(rawValue: 0)]
                    )
                )
                entryRegisterTypes.append(closureType)
                entryInstructions.append(
                    .makeClosure(
                        result: callbackRegister,
                        target: .image(.init(rawValue: 2)),
                        captures: [.init(rawValue: 1)]
                    )
                )
            }
            entryInstructions.append(
                .nativeApply(
                    result: nil,
                    importID: exportID,
                    arguments: [callbackRegister]
                )
            )
            if closureLifetime == .lexical {
                entryInstructions.append(
                    .endClosureScope(closure: .init(rawValue: 0))
                )
            }
            entryInstructions.append(.returnValue(nil))
            let entryFunction = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "installCallback",
                parameterRegisters: [],
                resultType: .void,
                registerTypes: entryRegisterTypes,
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        instructions: entryInstructions
                    ),
                ],
                effects: effects
            )
            let callbackFunction = Bytecode.Function(
                id: .init(rawValue: 1),
                name: "callback",
                kind: .closureBody,
                parameterRegisters: [.init(rawValue: 0)],
                parameterConventions: [.owned],
                resultType: callbackSignature.result,
                registerTypes: [.int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .nativeApply(
                                result: nil,
                                importID: observationID,
                                arguments: [.init(rawValue: 0)]
                            ),
                            .returnValue(
                                callbackSignature.result == .void
                                    ? nil : .init(rawValue: 0)
                            ),
                        ]
                    ),
                ],
                effects: effects
            )
            let wrapperFunction: Bytecode.Function
            if wrapsCallbackInArray {
                let wrapperResult: Bytecode.Register? =
                    callbackSignature.result == .void
                        ? nil : .init(rawValue: 4)
                wrapperFunction = .init(
                    id: .init(rawValue: 2),
                    name: "aggregateCallbackWrapper",
                    kind: .closureBody,
                    parameterRegisters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                    ],
                    parameterConventions: [.owned, .borrowed],
                    resultType: callbackSignature.result,
                    registerTypes: [
                        .int64, .array(.closure(callbackSignature)), .int64,
                        .closure(callbackSignature),
                    ] + (callbackSignature.result == .void
                        ? [] : [callbackSignature.result]),
                    entryBlock: .init(rawValue: 0),
                    blocks: [
                        .init(
                            id: .init(rawValue: 0),
                            parameters: [
                                .init(rawValue: 0), .init(rawValue: 1),
                            ],
                            instructions: [
                                .constantInteger(
                                    result: .init(rawValue: 2),
                                    bitPattern: 0
                                ),
                                .arrayGet(
                                    result: .init(rawValue: 3),
                                    array: .init(rawValue: 1),
                                    index: .init(rawValue: 2)
                                ),
                                .closureApply(
                                    result: wrapperResult,
                                    closure: .init(rawValue: 3),
                                    arguments: [.init(rawValue: 0)]
                                ),
                                .returnValue(wrapperResult),
                            ]
                        ),
                    ],
                    effects: effects
                )
            } else {
                let wrapperResult: Bytecode.Register? =
                    callbackSignature.result == .void
                        ? nil : .init(rawValue: 2)
                wrapperFunction = .init(
                    id: .init(rawValue: 2),
                    name: "callbackWrapper",
                    kind: .closureBody,
                    parameterRegisters: [
                        .init(rawValue: 0), .init(rawValue: 1),
                    ],
                    parameterConventions: [.owned, .borrowed],
                    resultType: callbackSignature.result,
                    registerTypes: [.int64, .closure(callbackSignature)]
                        + (callbackSignature.result == .void
                            ? [] : [callbackSignature.result]),
                    entryBlock: .init(rawValue: 0),
                    blocks: [
                        .init(
                            id: .init(rawValue: 0),
                            parameters: [
                                .init(rawValue: 0), .init(rawValue: 1),
                            ],
                            instructions: [
                                .closureApply(
                                    result: wrapperResult,
                                    closure: .init(rawValue: 1),
                                    arguments: [.init(rawValue: 0)]
                                ),
                                .returnValue(wrapperResult),
                            ]
                        ),
                    ],
                    effects: effects
                )
            }
            let observationSignature = Core.LoweredSignature(
                parameters: ["Swift.Int"],
                result: "Swift.Void"
            )
            var capabilities: Set<Core.Capability> = [
                .baselineV1, .nativeImportsV1, .closureValuesV1,
                .escapingClosureValuesV1,
            ]
            if restrictCallbackToMainActor {
                capabilities.insert(.mainActorSyncV1)
            }
            if wrapsCallbackInArray {
                capabilities.insert(.collectionsV1)
            }
            let module = Bytecode.Module(
                name: "RuntimeNativeCallbackFixture",
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                capabilities: capabilities,
                requestedResources: .init(
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                functions: [entryFunction]
                    + (target == .image ? [callbackFunction] : [])
                    + (wrapsCallback || wrapsCallbackInArray
                        ? [wrapperFunction] : []),
                entries: [
                    .init(
                        entryIndex: entry,
                        functionKey: entryKey,
                        functionID: entryFunction.id
                    ),
                ],
                imports: [
                    .init(
                        id: exportID,
                        key: exportKey,
                        signature: exportSignature,
                        effects: effects,
                        contract: exportContract
                    ),
                    .init(
                        id: observationID,
                        key: observationKey,
                        signature: observationSignature,
                        effects: effects,
                        contract: observationContract
                    ),
                ]
            )
            let shell = try Verification.ShellInterface(
                interfaceHash: shellHash,
                compatibility: compatibility,
                capabilities: capabilities,
                entries: [
                    .init(
                        index: entry,
                        key: entryKey,
                        parameterTypes: [],
                        parameterConventions: entryFunction.parameterConventions,
                        resultType: .void,
                        effects: effects
                    ),
                    .init(
                        index: callbackEntry,
                        key: callbackEntryKey,
                        parameterTypes: [.int64],
                        parameterConventions: [.owned],
                        resultType: callbackSignature.result,
                        effects: effects
                    ),
                ],
                imports: [
                    .init(
                        id: exportID,
                        key: exportKey,
                        parameterTypes: [.closure(boundarySignature)],
                        resultType: .void,
                        signature: exportSignature,
                        effects: effects,
                        contract: exportContract
                    ),
                    .init(
                        id: observationID,
                        key: observationKey,
                        parameterTypes: [.int64],
                        resultType: .void,
                        signature: observationSignature,
                        effects: effects,
                        contract: observationContract
                    ),
                ]
            )
            let bytes = try Bytecode.Encoder.encode(module)
            let image = try Verification.Engine().verify(
                bytes: bytes,
                shell: shell,
                policy: .init(
                    acceptedCapabilities: capabilities,
                    resourceCeiling: .init(
                        maxWallTimeMainThreadMilliseconds: 1_000
                    ),
                    allowedNativeImports: [exportID, observationID]
                )
            )
            return try Runtime.Generation(
                id: .init(rawValue: id),
                parentID: nil,
                packageID: "HLX-runtime-native-callback-\(id)",
                packageHash: .sha256(bytes),
                images: [image],
                estimatedByteCount: bytes.count
            )
        }
    }

    private final class CallbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: VM.NativeCallback?

        var value: VM.NativeCallback? {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    private final class IntegerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int64] = []

        var values: [Int64] { lock.withLock { storage } }
        func append(_ value: Int64) { lock.withLock { storage.append(value) } }
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
