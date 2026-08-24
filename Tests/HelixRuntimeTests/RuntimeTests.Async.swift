import Foundation
import HelixBytecode
import HelixCore
import HelixVM
import HelixVerifier
import Testing
@testable import HelixRuntime

private actor RuntimeAsyncGate {
    private var didArrive = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        didArrive = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForArrival() async {
        guard !didArrive else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor RuntimeAsyncCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int { count }
}

extension RuntimeTests {
@Suite("Runtime sequential async routing")
struct AsyncRouting {
    @Test("A synchronous isolated callback overrides inherited task-local context")
    func isolatesSynchronousCallbackInsideAsyncContext() async throws {
        let generation = try Runtime.Generation(
            id: .init(rawValue: 1),
            parentID: nil,
            packageID: "HLX-runtime-async-context",
            packageHash: .sha256("runtime-async-context"),
            images: [],
            removedEntries: [.init(rawValue: 0)],
            estimatedByteCount: 0
        )
        let lease = Runtime.GenerationLease(
            snapshot: .init(generation: generation, parent: nil)
        )
        let outer = Runtime.ExecutionContext(lease: lease)
        let isolated = Runtime.ExecutionContext(lease: lease)
        let storage = Runtime.ExecutionContextStorage()

        let observedIsolated = await storage.withContext(outer) {
            await Task.yield()
            #expect(storage.current === outer)
            return storage.withIsolatedContext(isolated) {
                storage.current === isolated
            }
        }

        #expect(observedIsolated)
        #expect(storage.current == nil)
    }

    @Test("Async context installation overrides and restores another task context")
    func isolatesTransferredAsyncContext() async throws {
        let generation = try Runtime.Generation(
            id: .init(rawValue: 1),
            parentID: nil,
            packageID: "HLX-runtime-async-context-transfer",
            packageHash: .sha256("runtime-async-context-transfer"),
            images: [],
            removedEntries: [.init(rawValue: 0)],
            estimatedByteCount: 0
        )
        let lease = Runtime.GenerationLease(
            snapshot: .init(generation: generation, parent: nil)
        )
        let outer = Runtime.ExecutionContext(lease: lease)
        let transferred = Runtime.ExecutionContext(lease: lease)
        let storage = Runtime.ExecutionContextStorage()

        await storage.withContext(outer) {
            #expect(storage.current === outer)
            await storage.withContext(transferred) {
                await Task.yield()
                #expect(storage.current === transferred)
            }
            #expect(storage.current === outer)
        }
        #expect(storage.current == nil)
    }

    @Test("A suspended call pins its generation and task-local nested routing")
    func pinsGenerationAcrossSuspension() async throws {
        let gate = RuntimeAsyncGate()
        let bridge = Runtime.Bridge()
        let fixture = try makeFixture()

        let asyncInvoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.asyncImportID,
            key: fixture.asyncImportKey,
            parameterTypes: [],
            resultType: .int64,
            effects: .init(isAsync: true),
            contract: fixture.asyncContract
        ) { _, _ in
            await gate.suspend()
            return .returned(try .integerValue(1))
        }
        let nestedInvoker = VM.ClosureNativeInvoker(
            id: fixture.nestedImportID,
            key: fixture.nestedImportKey,
            parameterTypes: [],
            resultType: .int64,
            contract: fixture.nestedContract
        ) { _, context in
            try context.checkpoint(workUnits: 1)
            let decision: Runtime.BridgeDispatchResult<Int64> = try bridge
                .dispatch(
                    entry: fixture.nestedEntry,
                    arguments: { _ in [] },
                    decodeResult: { value in
                        guard let value else {
                            throw VM.RuntimeTrap.typeMismatch(
                                expected: .int64,
                                actual: nil
                            )
                        }
                        return try Runtime.BridgeValueCodec.decode(
                            value,
                            as: Int64.self
                        )
                    }
                )
            try context.checkpoint(workUnits: 1)
            let value: Int64 = switch decision {
            case .originalRequired: 2
            case let .returned(value): value
            }
            return .returned(try .integerValue(value))
        }
        let runtime = Runtime.Engine(
            originals: try .init([
                .init(
                    index: fixture.asyncEntry,
                    parameterTypes: [],
                    resultType: .int64,
                    effects: .init(isAsync: true),
                    invokeAsync: { _ in
                        .returned(try! .integerValue(1))
                    }
                ),
                .init(
                    index: fixture.nestedEntry,
                    parameterTypes: [],
                    resultType: .int64
                ) { _ in
                    .returned(try! .integerValue(2))
                },
            ]),
            shellInterfaceHash: fixture.shellHash,
            nativeCatalog: try .init([nestedInvoker]),
            asyncNativeCatalog: try .init([asyncInvoker])
        )
        let generation = try Runtime.Generation(
            id: .init(rawValue: 1),
            parentID: nil,
            packageID: "HLX-runtime-sequential-async",
            packageHash: .sha256(fixture.bytes),
            images: [fixture.image],
            estimatedByteCount: fixture.bytes.count
        )
        try runtime.activate(generation, expectedActiveID: nil)
        try bridge.install(
            runtime: runtime,
            interfaceHash: fixture.shellHash,
            registrationCount: 2
        )

        let invocation = Task {
            guard let prepared = try bridge.prepareAsyncDispatch(
                entry: fixture.asyncEntry,
                arguments: { _ in [] }
            ) else {
                throw VM.RuntimeTrap.nativeFailure(
                    "active async route was not prepared"
                )
            }
            return try await bridge.dispatchAsync(
                prepared: prepared,
                decodeResult: { value in
                    guard let value else {
                        throw VM.RuntimeTrap.typeMismatch(
                            expected: .int64,
                            actual: nil
                        )
                    }
                    return try Runtime.BridgeValueCodec.decode(
                        value,
                        as: Int64.self
                    )
                }
            )
        }

        await gate.waitForArrival()
        try runtime.rollback(expectedActiveID: generation.id, to: nil)
        #expect(runtime.registry.snapshot().activeGenerationID == nil)
        #expect(runtime.registry.lease(for: generation.id) != nil)
        await gate.release()

        let value = try await invocation.value
        #expect(value == 77)
        #expect(runtime.registry.lease(for: generation.id) == nil)
    }

    @Test("Prepared async dispatch is installation-bound and one-shot")
    func preparedDispatchOwnershipAndReplay() async throws {
        let fixture = try makeFixture()
        let runtime = try makeRuntime(
            fixture: fixture,
            fallbackAllowed: false,
            original: { _ in .returned(try! .integerValue(11)) },
            asyncInvoke: { _, _ in .returned(try .integerValue(1)) }
        )
        let generation = try generation(fixture: fixture, package: "ownership")
        try runtime.activate(generation, expectedActiveID: nil)
        let owner = Runtime.Bridge()
        let foreign = Runtime.Bridge()
        for bridge in [owner, foreign] {
            try bridge.install(
                runtime: runtime,
                interfaceHash: fixture.shellHash,
                registrationCount: 2
            )
        }
        let prepared = try #require(try owner.prepareAsyncDispatch(
            entry: fixture.asyncEntry,
            arguments: { _ in [] }
        ))

        await #expect(throws: VM.RuntimeTrap.nativeFailure(
            "prepared async Bridge dispatch belongs to another installation"
        )) {
            let _: Int64 = try await foreign.dispatchAsync(
                prepared: prepared,
                decodeResult: decodeInt64
            )
        }
        #expect(
            try await owner.dispatchAsync(
                prepared: prepared,
                decodeResult: decodeInt64
            ) == 77
        )
        await #expect(throws: VM.RuntimeTrap.nativeFailure(
            "prepared async Bridge dispatch was reused"
        )) {
            let _: Int64 = try await owner.dispatchAsync(
                prepared: prepared,
                decodeResult: decodeInt64
            )
        }
    }

    @Test("Async preparation pins nested synchronous argument encoding")
    func pinsNestedRoutingDuringAsyncPreparation() async throws {
        let fixture = try makeFixture()
        let runtime = try makeRuntime(
            fixture: fixture,
            fallbackAllowed: false,
            original: { _ in .returned(try! .integerValue(11)) },
            asyncInvoke: { _, _ in .returned(try .integerValue(1)) }
        )
        let generation = try generation(
            fixture: fixture,
            package: "preparation-context"
        )
        try runtime.activate(generation, expectedActiveID: nil)
        let bridge = Runtime.Bridge()
        try bridge.install(
            runtime: runtime,
            interfaceHash: fixture.shellHash,
            registrationCount: 2
        )

        var nestedValue: Int64?
        let prepared = try #require(try bridge.prepareAsyncDispatch(
            entry: fixture.asyncEntry,
            arguments: { _ in
                try runtime.rollback(
                    expectedActiveID: generation.id,
                    to: nil
                )
                let decision: Runtime.BridgeDispatchResult<Int64> = try bridge
                    .dispatch(
                        entry: fixture.nestedEntry,
                        arguments: { _ in [] },
                        decodeResult: decodeInt64
                    )
                nestedValue = switch decision {
                case .originalRequired: -1
                case let .returned(value): value
                }
                return []
            }
        ))

        #expect(nestedValue == 77)
        #expect(runtime.registry.snapshot().activeGenerationID == nil)
        #expect(
            try await bridge.dispatchAsync(
                prepared: prepared,
                decodeResult: decodeInt64
            ) == 77
        )
    }

    @Test("Safe async patch failure falls back through OriginalCatalog")
    func preparedDispatchUsesCatalogFallback() async throws {
        let fixture = try makeFixture(fallbackAllowed: true)
        let originalCalls = RuntimeAsyncCounter()
        let runtime = try makeRuntime(
            fixture: fixture,
            fallbackAllowed: true,
            original: { _ in
                await originalCalls.increment()
                return .returned(try! .integerValue(99))
            },
            asyncInvoke: { _, _ in
                await Task.yield()
                throw VM.RuntimeTrap.explicit("recoverable async patch failure")
            }
        )
        let generation = try generation(fixture: fixture, package: "fallback")
        try runtime.activate(generation, expectedActiveID: nil)
        let bridge = Runtime.Bridge()
        try bridge.install(
            runtime: runtime,
            interfaceHash: fixture.shellHash,
            registrationCount: 2
        )
        let prepared = try #require(try bridge.prepareAsyncDispatch(
            entry: fixture.asyncEntry,
            arguments: { _ in [] }
        ))

        #expect(
            try await bridge.dispatchAsync(
                prepared: prepared,
                decodeResult: decodeInt64
            ) == 99
        )
        #expect(await originalCalls.value() == 1)
    }

    @Test("OriginalCatalog preserves MainActor on an async erased adapter")
    func preservesMainActorOriginalIsolation() async throws {
        let entry = Core.EntryIndex(rawValue: 0)
        let catalog = try Runtime.OriginalCatalog([
            .init(
                index: entry,
                parameterTypes: [],
                resultType: .int64,
                effects: .init(requiresMainActor: true, isAsync: true),
                invokeMainActorAsync: { _ in
                    await Task.yield()
                    MainActor.preconditionIsolated()
                    return .returned(try! .integerValue(23))
                }
            ),
        ])

        #expect(
            await catalog[entry]?.invokeAsync([])
                == .returned(try .integerValue(23))
        )
    }

    @Test("OriginalCatalog rejects bodies whose async or actor shape disagrees")
    func rejectsOriginalExecutionShapeMismatch() {
        let asyncEffects = Core.Effects(isAsync: true)
        let mainActorEffects = Core.Effects(
            requiresMainActor: true,
            isAsync: true
        )

        #expect(throws: Runtime.ActivationError.self) {
            _ = try Runtime.OriginalCatalog([
                .init(
                    index: .init(rawValue: 0),
                    parameterTypes: [],
                    resultType: .void,
                    effects: asyncEffects,
                    invoke: { _ in .returned(nil) }
                ),
            ])
        }
        #expect(throws: Runtime.ActivationError.self) {
            _ = try Runtime.OriginalCatalog([
                .init(
                    index: .init(rawValue: 0),
                    parameterTypes: [],
                    resultType: .void,
                    effects: .init(),
                    invokeAsync: { _ in .returned(nil) }
                ),
            ])
        }
        #expect(throws: Runtime.ActivationError.self) {
            _ = try Runtime.OriginalCatalog([
                .init(
                    index: .init(rawValue: 0),
                    parameterTypes: [],
                    resultType: .void,
                    effects: mainActorEffects,
                    invokeAsync: { _ in .returned(nil) }
                ),
            ])
        }
        #expect(throws: Runtime.ActivationError.self) {
            _ = try Runtime.OriginalCatalog([
                .init(
                    index: .init(rawValue: 0),
                    parameterTypes: [],
                    resultType: .void,
                    effects: asyncEffects,
                    invokeMainActorAsync: { _ in .returned(nil) }
                ),
            ])
        }
    }

    @Test("Cancellation never replays a fallback original")
    func cancellationDoesNotFallback() async throws {
        let gate = RuntimeAsyncGate()
        let originalCalls = RuntimeAsyncCounter()
        let fixture = try makeFixture(fallbackAllowed: true)
        let asyncInvoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.asyncImportID,
            key: fixture.asyncImportKey,
            parameterTypes: [],
            resultType: .int64,
            effects: .init(isAsync: true),
            contract: fixture.asyncContract
        ) { _, _ in
            await gate.suspend()
            return .returned(try .integerValue(1))
        }
        let nestedInvoker = VM.ClosureNativeInvoker(
            id: fixture.nestedImportID,
            key: fixture.nestedImportKey,
            parameterTypes: [],
            resultType: .int64,
            contract: fixture.nestedContract
        ) { _, context in
            try context.checkpoint(workUnits: 1)
            return .returned(try .integerValue(77))
        }
        let runtime = Runtime.Engine(
            originals: try .init([
                .init(
                    index: fixture.asyncEntry,
                    parameterTypes: [],
                    resultType: .int64,
                    effects: .init(isAsync: true),
                    fallbackAllowed: true,
                    invokeAsync: { _ in
                        await originalCalls.increment()
                        return .returned(try! .integerValue(99))
                    }
                ),
                .init(
                    index: fixture.nestedEntry,
                    parameterTypes: [],
                    resultType: .int64
                ) { _ in .returned(try! .integerValue(2)) },
            ]),
            nativeCatalog: try .init([nestedInvoker]),
            asyncNativeCatalog: try .init([asyncInvoker])
        )
        let generation = try Runtime.Generation(
            id: .init(rawValue: 1),
            parentID: nil,
            packageID: "HLX-runtime-cancel",
            packageHash: .sha256(fixture.bytes),
            images: [fixture.image],
            estimatedByteCount: fixture.bytes.count
        )
        try runtime.activate(generation, expectedActiveID: nil)

        let invocation = Task {
            await runtime.invokeAsync(entry: fixture.asyncEntry, arguments: [])
        }
        await gate.waitForArrival()
        invocation.cancel()
        await gate.release()

        #expect(await invocation.value == .trapped(.executionCancelled))
        #expect(await originalCalls.value() == 0)
    }

    private struct Fixture {
        var image: Verification.Image
        var bytes: Data
        var shellHash: Core.Digest
        var asyncEntry: Core.EntryIndex
        var nestedEntry: Core.EntryIndex
        var asyncImportID: Core.NativeImportID
        var nestedImportID: Core.NativeImportID
        var asyncImportKey: Core.NativeImportKey
        var nestedImportKey: Core.NativeImportKey
        var asyncContract: Core.NativeImportContract
        var nestedContract: Core.NativeImportContract
    }

    private func makeFixture(
        fallbackAllowed: Bool = false
    ) throws -> Fixture {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.runtime.sequential-async",
            buildNumber: "1",
            seed: "fixture"
        )
        let shellHash = Core.Digest.sha256("runtime-sequential-async-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-runtime-sequential-async-fixture"
        )
        let asyncEntry = Core.EntryIndex(rawValue: 0)
        let nestedEntry = Core.EntryIndex(rawValue: 1)
        let asyncSignature = Core.LoweredSignature(
            parameters: [],
            result: "Swift.Int",
            isAsync: true
        )
        let nestedSignature = Core.LoweredSignature(
            parameters: [],
            result: "Swift.Int"
        )
        let asyncKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func asyncValue() async -> Int",
            loweredSignature: asyncSignature,
            role: .function
        )
        let nestedKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func nestedValue() -> Int",
            loweredSignature: nestedSignature,
            role: .function
        )
        let asyncContract = Core.NativeImportContract.suspending(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 60_000_000,
            allowsMainThread: true
        )
        let nestedContract = Core.NativeImportContract.cooperative(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 1_000_000,
            allowsMainThread: false
        )
        let asyncImportID = Core.NativeImportID(rawValue: 0)
        let nestedImportID = Core.NativeImportID(rawValue: 1)
        let asyncImportKey = try Core.NativeImportKey.derive(
            namespace: namespace,
            canonicalCallee: "Fixture.suspend()",
            signature: asyncSignature,
            effects: .init(isAsync: true),
            contract: asyncContract
        )
        let nestedImportKey = try Core.NativeImportKey.derive(
            namespace: namespace,
            canonicalCallee: "Fixture.callNested()",
            signature: nestedSignature,
            effects: .init(),
            contract: nestedContract
        )
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "asyncValue",
            parameterRegisters: [],
            resultType: .int64,
            registerTypes: [.int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .nativeApply(
                            result: .init(rawValue: 0),
                            importID: asyncImportID,
                            arguments: []
                        ),
                        .nativeApply(
                            result: .init(rawValue: 1),
                            importID: nestedImportID,
                            arguments: []
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ],
            effects: .init(isAsync: true)
        )
        let nested = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "nestedValue",
            parameterRegisters: [],
            resultType: .int64,
            registerTypes: [.int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .constantInteger(
                            result: .init(rawValue: 0),
                            bitPattern: 77
                        ),
                        .returnValue(.init(rawValue: 0)),
                    ]
                ),
            ]
        )
        let capabilities: Set<Core.Capability> = [
            .baselineV1, .nativeImportsV1, .sequentialAsyncV1,
        ]
        let imports = [
            Bytecode.ImportRequirement(
                id: asyncImportID,
                key: asyncImportKey,
                signature: asyncSignature,
                effects: .init(isAsync: true),
                contract: asyncContract
            ),
            Bytecode.ImportRequirement(
                id: nestedImportID,
                key: nestedImportKey,
                signature: nestedSignature,
                effects: .init(),
                contract: nestedContract
            ),
        ]
        let module = Bytecode.Module(
            name: "RuntimeSequentialAsyncFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            requestedResources: .init(
                maxWallTimeMainThreadMilliseconds: 1_000
            ),
            functions: [root, nested],
            entries: [
                .init(
                    entryIndex: asyncEntry,
                    functionKey: asyncKey,
                    functionID: root.id
                ),
                .init(
                    entryIndex: nestedEntry,
                    functionKey: nestedKey,
                    functionID: nested.id
                ),
            ],
            imports: imports
        )
        let shellImports = [
            Verification.ResolvedNativeImport(
                id: asyncImportID,
                key: asyncImportKey,
                parameterTypes: [],
                resultType: .int64,
                signature: asyncSignature,
                effects: .init(isAsync: true),
                contract: asyncContract
            ),
            Verification.ResolvedNativeImport(
                id: nestedImportID,
                key: nestedImportKey,
                parameterTypes: [],
                resultType: .int64,
                signature: nestedSignature,
                effects: .init(),
                contract: nestedContract
            ),
        ]
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: asyncEntry,
                    key: asyncKey,
                    parameterTypes: [],
                    parameterConventions: [],
                    resultType: .int64,
                    effects: .init(isAsync: true),
                    fallbackAllowed: fallbackAllowed
                ),
                .init(
                    index: nestedEntry,
                    key: nestedKey,
                    parameterTypes: [],
                    parameterConventions: [],
                    resultType: .int64
                ),
            ],
            imports: shellImports
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
                allowedNativeImports: [asyncImportID, nestedImportID]
            )
        )
        return .init(
            image: image,
            bytes: bytes,
            shellHash: shellHash,
            asyncEntry: asyncEntry,
            nestedEntry: nestedEntry,
            asyncImportID: asyncImportID,
            nestedImportID: nestedImportID,
            asyncImportKey: asyncImportKey,
            nestedImportKey: nestedImportKey,
            asyncContract: asyncContract,
            nestedContract: nestedContract
        )
    }

    private func makeRuntime(
        fixture: Fixture,
        fallbackAllowed: Bool,
        original: @escaping Runtime.AsyncOriginalInvocation,
        asyncInvoke: @escaping @Sendable (
            [VM.Value],
            VM.NativeInvocationContext
        ) async throws -> VM.NativeInvocationResult
    ) throws -> Runtime.Engine {
        let asyncInvoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.asyncImportID,
            key: fixture.asyncImportKey,
            parameterTypes: [],
            resultType: .int64,
            effects: .init(isAsync: true),
            contract: fixture.asyncContract,
            invoke: asyncInvoke
        )
        let nestedInvoker = VM.ClosureNativeInvoker(
            id: fixture.nestedImportID,
            key: fixture.nestedImportKey,
            parameterTypes: [],
            resultType: .int64,
            contract: fixture.nestedContract
        ) { _, context in
            try context.checkpoint(workUnits: 1)
            return .returned(try .integerValue(77))
        }
        return Runtime.Engine(
            originals: try .init([
                .init(
                    index: fixture.asyncEntry,
                    parameterTypes: [],
                    resultType: .int64,
                    effects: .init(isAsync: true),
                    fallbackAllowed: fallbackAllowed,
                    invokeAsync: original
                ),
                .init(
                    index: fixture.nestedEntry,
                    parameterTypes: [],
                    resultType: .int64
                ) { _ in .returned(try! .integerValue(2)) },
            ]),
            shellInterfaceHash: fixture.shellHash,
            nativeCatalog: try .init([nestedInvoker]),
            asyncNativeCatalog: try .init([asyncInvoker])
        )
    }

    private func generation(
        fixture: Fixture,
        package: String
    ) throws -> Runtime.Generation {
        try Runtime.Generation(
            id: .init(rawValue: 1),
            parentID: nil,
            packageID: "HLX-runtime-async-\(package)",
            packageHash: .sha256(fixture.bytes),
            images: [fixture.image],
            estimatedByteCount: fixture.bytes.count
        )
    }

    private func decodeInt64(_ value: VM.Value?) throws -> Int64 {
        guard let value else {
            throw VM.RuntimeTrap.typeMismatch(expected: .int64, actual: nil)
        }
        return try Runtime.BridgeValueCodec.decode(value, as: Int64.self)
    }
}
}

private extension VM.Value {
    static func integerValue(_ value: Int64) throws -> Self {
        .integer(
            try VM.Integer(
                signed: value,
                bitWidth: 64,
                isSigned: true
            )
        )
    }
}
