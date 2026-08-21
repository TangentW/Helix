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
            parameterTypes: [.closure(fixture.callbackSignature)],
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
            originals: .init([
                .init(
                    index: fixture.entry,
                    parameterTypes: [],
                    resultType: .void,
                    invoke: { _ in .returned(nil) }
                ),
            ]),
            nativeCatalog: .init([callbackImport, observationImport])
        )
        let generation = try fixture.generation(id: 1)
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

    private struct Fixture {
        let entry = Core.EntryIndex(rawValue: 0)
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
        let callbackSignature: Bytecode.ClosureSignature
        let exportContract: Core.NativeImportContract
        let observationContract: Core.NativeImportContract
        let exportKey: Core.NativeImportKey
        let observationKey: Core.NativeImportKey
        let entryKey: Core.FunctionKey

        init() throws {
            callbackSignature = .init(
                parameters: [.int64],
                parameterConventions: [.owned],
                result: .void,
                effects: effects
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
            exportKey = try Core.NativeImportKey.derive(
                namespace: namespace,
                canonicalCallee: "Fixture.retainCallback(_:)",
                signature: .init(
                    parameters: ["@escaping (Swift.Int) -> Swift.Void"],
                    result: "Swift.Void"
                ),
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
        }

        func generation(
            id: UInt64,
            closureLifetime: Bytecode.ClosureLifetime = .invocation
        ) throws -> Runtime.Generation {
            let closureType = Bytecode.ValueType.closure(callbackSignature)
            var entryInstructions: [Bytecode.Instruction] = [
                .makeClosure(
                    result: .init(rawValue: 0),
                    function: .init(rawValue: 1),
                    captures: [],
                    lifetime: closureLifetime
                ),
                .nativeApply(
                    result: nil,
                    importID: exportID,
                    arguments: [.init(rawValue: 0)]
                ),
            ]
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
                registerTypes: [closureType],
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
                resultType: .void,
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
                            .returnValue(nil),
                        ]
                    ),
                ],
                effects: effects
            )
            let exportSignature = Core.LoweredSignature(
                parameters: ["@escaping (Swift.Int) -> Swift.Void"],
                result: "Swift.Void"
            )
            let observationSignature = Core.LoweredSignature(
                parameters: ["Swift.Int"],
                result: "Swift.Void"
            )
            let capabilities: Set<Core.Capability> = [
                .baselineV1, .nativeImportsV1, .closureValuesV1,
                .escapingClosureValuesV1,
            ]
            let module = Bytecode.Module(
                name: "RuntimeNativeCallbackFixture",
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                capabilities: capabilities,
                requestedResources: .init(
                    maxWallTimeMainThreadMilliseconds: 1_000
                ),
                functions: [entryFunction, callbackFunction],
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
                        resultType: .void,
                        effects: effects
                    ),
                ],
                imports: [
                    .init(
                        id: exportID,
                        key: exportKey,
                        parameterTypes: [.closure(callbackSignature)],
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
