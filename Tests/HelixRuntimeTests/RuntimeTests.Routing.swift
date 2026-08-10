import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
import Testing
@testable import HelixRuntime

enum RuntimeTests {}

extension RuntimeTests {
@Suite("Generation registry and Runtime routing")
struct Routing {
    @Test("Bridge bootstrap binds the generated entry table to one Shell interface")
    func bridgeBootstrapChecksFrozenContract() throws {
        let interfaceHash = Core.Digest.sha256("bridge-shell")
        let originals = try Runtime.OriginalCatalog([
            .init(
                index: .init(rawValue: 0),
                parameterTypes: [.int64],
                resultType: .int64,
                invoke: { arguments in .returned(arguments[0]) }
            ),
        ])
        let runtime = Runtime.Engine(
            originals: originals,
            shellInterfaceHash: interfaceHash
        )
        let bridge = Runtime.Bridge()
        try bridge.install(
            runtime: runtime,
            interfaceHash: interfaceHash,
            registrationCount: 1
        )
        // Idempotent bootstrap is required because applications may call it from
        // more than one initialization path.
        try bridge.install(
            runtime: runtime,
            interfaceHash: interfaceHash,
            registrationCount: 1
        )
        let input = try VM.Integer(signed: 9, bitWidth: 64, isSigned: true)
        #expect(
            bridge.invoke(entry: .init(rawValue: 0), arguments: [.integer(input)])
                == .returned(.integer(input))
        )
        #expect(throws: Runtime.BridgeBootstrapError.interfaceHashMismatch) {
            try Runtime.Bridge().install(
                runtime: runtime,
                interfaceHash: .sha256("other-shell"),
                registrationCount: 1
            )
        }
    }

    @Test("Bridge installation is atomically published under concurrent access")
    func concurrentBridgePublication() throws {
        let fixture = try RuntimeFixture(entry: .init(rawValue: 0))
        let baseRuntime = try fixture.makeRuntime(fallbackAllowed: false)
        let runtime = Runtime.Engine(
            originals: baseRuntime.originals,
            shellInterfaceHash: fixture.shellHash
        )
        let bridge = Runtime.Bridge()
        let failures = FailureBox()

        DispatchQueue.concurrentPerform(iterations: 512) { iteration in
            do {
                if iteration.isMultiple(of: 8) {
                    try bridge.install(
                        runtime: runtime,
                        interfaceHash: fixture.shellHash,
                        registrationCount: 1
                    )
                } else {
                    let decision: Runtime.BridgeDispatchResult<Int64> = try bridge.dispatch(
                        entry: fixture.entry,
                        arguments: { _ in [] },
                        decodeResult: { _ in 0 }
                    )
                    guard case .originalRequired = decision else {
                        failures.record("an unpatched Bridge returned a patched result")
                        return
                    }
                }
            } catch let error as Runtime.BridgeDispatchError where error == .notInstalled {
                // A reader that wins the race before release publication must
                // observe a complete absence, never a partial Installation.
            } catch {
                failures.record(String(describing: error))
            }
        }

        #expect(failures.messages.isEmpty)
        #expect(bridge.installedInterfaceHash == fixture.shellHash)
    }

    @Test("Bridge routing latch observes direct registry activation")
    func registryActivationPublishesRoutingLatch() throws {
        let fixture = try RuntimeFixture(entry: .init(rawValue: 0))
        let baseRuntime = try fixture.makeRuntime(fallbackAllowed: false)
        let runtime = Runtime.Engine(
            originals: baseRuntime.originals,
            shellInterfaceHash: fixture.shellHash
        )
        let bridge = Runtime.Bridge()
        try bridge.install(
            runtime: runtime,
            interfaceHash: fixture.shellHash,
            registrationCount: 1
        )
        let generation = try fixture.generation(id: 1, parent: nil, constant: 30)
        _ = try runtime.registry.activate(generation, expectedActiveID: nil)

        let decision: Runtime.BridgeDispatchResult<Int64> = try bridge.dispatch(
            entry: fixture.entry,
            arguments: { encoder in [try encoder.encode(Int64(9))] },
            decodeResult: { value in
                guard case let .integer(integer)? = value else {
                    throw VM.RuntimeTrap.typeMismatch(expected: .int64, actual: value?.type)
                }
                return integer.signedValue
            }
        )
        guard case let .returned(result) = decision else {
            Issue.record("the directly activated generation was not routed")
            return
        }
        #expect(result == 30)
    }

    @Test("Activation and rollback switch the whole route table")
    func activationAndRollback() throws {
        let fixture = try RuntimeFixture()
        let runtime = try fixture.makeRuntime(fallbackAllowed: false)
        let input = try int(9)

        #expect(runtime.invoke(entry: fixture.entry, arguments: [.integer(input)]) == .returned(.integer(try int(3))))

        let generation = try fixture.generation(id: 1, parent: nil, constant: 30)
        try runtime.activate(generation, expectedActiveID: nil)
        #expect(runtime.invoke(entry: fixture.entry, arguments: [.integer(input)]) == .returned(.integer(try int(30))))

        try runtime.rollback(expectedActiveID: generation.id, to: nil)
        #expect(runtime.invoke(entry: fixture.entry, arguments: [.integer(input)]) == .returned(.integer(try int(3))))
    }

    @Test("Generated Bridge dispatch is lazy and preserves the lexical original")
    func typedBridgeDispatch() throws {
        let fixture = try RuntimeFixture(entry: .init(rawValue: 0))
        let baseRuntime = try fixture.makeRuntime(fallbackAllowed: false)
        let runtime = Runtime.Engine(
            originals: baseRuntime.originals,
            shellInterfaceHash: fixture.shellHash
        )
        let bridge = Runtime.Bridge()
        try bridge.install(
            runtime: runtime,
            interfaceHash: fixture.shellHash,
            registrationCount: 1
        )
        var encodedArgumentCount = 0

        func dispatch(_ input: Int64) throws -> Int64 {
            let decision = try bridge.dispatch(
                entry: fixture.entry,
                arguments: { encoder in
                    encodedArgumentCount += 1
                    return [try encoder.encode(input)]
                },
                decodeResult: { value in
                    guard let value else {
                        throw VM.RuntimeTrap.typeMismatch(expected: .int64, actual: nil)
                    }
                    return try Runtime.BridgeValueCodec.decode(value, as: Int64.self)
                }
            )
            switch decision {
            case .originalRequired:
                return input + 1
            case let .returned(result):
                return result
            }
        }

        #expect(try dispatch(9) == 10)
        #expect(encodedArgumentCount == 0)

        let patched = try fixture.generation(id: 1, parent: nil, constant: 30)
        _ = try runtime.activate(patched, expectedActiveID: nil)
        #expect(try dispatch(9) == 30)
        #expect(encodedArgumentCount == 1)

        let restored = try Runtime.Generation(
            id: .init(rawValue: 2),
            parentID: patched.id,
            packageID: "HLX-runtime-bridge-restore",
            packageHash: .sha256("bridge-restore"),
            images: [],
            removedEntries: [fixture.entry],
            estimatedByteCount: 0
        )
        _ = try runtime.activate(restored, expectedActiveID: patched.id)
        #expect(try dispatch(9) == 10)
        #expect(encodedArgumentCount == 1)
    }

    @Test("Only generated Bridge routing may execute an async HLBC entry")
    func asyncEntryRequiresBridgeContext() throws {
        let entry = Core.EntryIndex(rawValue: 0)
        let shellHash = Core.Digest.sha256("runtime-async-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-runtime-async-fixture"
        )
        let key = try Core.FunctionKey.derive(
            namespace: .derive(
                bundleID: "dev.helix.runtime.async",
                buildNumber: "1",
                seed: "fixture"
            ),
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func value(_: Int) async -> Int",
            loweredSignature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int",
                isAsync: true
            ),
            role: .function
        )
        let effects = Core.Effects(isAsync: true)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "async leaf",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(result: .init(rawValue: 1), value: 41),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ],
            effects: effects
        )
        let capabilities: Set<Core.Capability> = [
            .baselineV1, .asyncLeafEntriesV1,
        ]
        let module = Bytecode.Module(
            name: "RuntimeAsyncFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            requestedResources: .init(
                maxWallTimeMainThreadMilliseconds: 1_000
            ),
            functions: [function],
            entries: [
                .init(entryIndex: entry, functionKey: key, functionID: function.id),
            ]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: entry,
                    key: key,
                    parameterTypes: [.int64],
                    resultType: .int64,
                    effects: effects
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
                )
            )
        )
        let runtime = Runtime.Engine(
            originals: try .init([
                .init(
                    index: entry,
                    parameterTypes: [.int64],
                    resultType: .int64
                ) { _ in .returned(.integer(try! int(1))) },
            ]),
            shellInterfaceHash: shellHash
        )
        try runtime.activate(
            .init(
                id: .init(rawValue: 1),
                parentID: nil,
                packageID: "HLX-runtime-async",
                packageHash: .sha256(bytes),
                images: [image],
                estimatedByteCount: bytes.count
            ),
            expectedActiveID: nil
        )
        let input = VM.Value.integer(try int(9))

        #expect(
            runtime.invoke(entry: entry, arguments: [input])
                == .trapped(
                    .explicit(
                        "async HLBC entry requires its generated Swift async Bridge"
                    )
                )
        )
        let bridge = Runtime.Bridge()
        try bridge.install(
            runtime: runtime,
            interfaceHash: shellHash,
            registrationCount: 1
        )
        let decision: Runtime.BridgeDispatchResult<Int64> = try bridge.dispatch(
            entry: entry,
            arguments: { encoder in [try encoder.encode(Int64(9))] },
            decodeResult: { value in
                guard let value else {
                    throw VM.RuntimeTrap.typeMismatch(expected: .int64, actual: nil)
                }
                return try Runtime.BridgeValueCodec.decode(value, as: Int64.self)
            }
        )
        guard case let .returned(result) = decision else {
            Issue.record("the generated Bridge path did not execute the async leaf")
            return
        }
        #expect(result == 41)
    }

    @Test("Bridge value codec preserves primitive and aggregate shapes")
    func bridgeValueCodec() throws {
        let signed = try Runtime.BridgeValueCodec.encode(Int16(-42))
        let unsigned = try Runtime.BridgeValueCodec.encode(UInt64.max)
        #expect(try Runtime.BridgeValueCodec.decode(signed, as: Int16.self) == -42)
        #expect(try Runtime.BridgeValueCodec.decode(unsigned, as: UInt64.self) == .max)

        let optional = try Runtime.BridgeValueCodec.encodeOptional(Int32(7)) {
            try Runtime.BridgeValueCodec.encode($0)
        }
        #expect(
            try Runtime.BridgeValueCodec.decodeOptional(optional) {
                try Runtime.BridgeValueCodec.decode($0, as: Int32.self)
            } == 7
        )
        let tuple = try Runtime.BridgeValueCodec.encodeTuple([
            try Runtime.BridgeValueCodec.encode(true),
            try Runtime.BridgeValueCodec.encode("Helix"),
        ])
        let elements = try Runtime.BridgeValueCodec.decodeTuple(tuple, count: 2)
        #expect(try Runtime.BridgeValueCodec.decode(elements[0], as: Bool.self))
        #expect(try Runtime.BridgeValueCodec.decode(elements[1], as: String.self) == "Helix")

        let array = try Runtime.BridgeValueCodec.encodeArray(
            [Int32(3), Int32(5)],
            elementType: .integer(bitWidth: 32, signed: true)
        ) {
            try Runtime.BridgeValueCodec.encode($0)
        }
        #expect(
            try Runtime.BridgeValueCodec.decodeArray(
                array,
                elementType: .integer(bitWidth: 32, signed: true)
            ) {
                try Runtime.BridgeValueCodec.decode($0, as: Int32.self)
            } == [3, 5]
        )

        let dictionary = try Runtime.BridgeValueCodec.encodeDictionary(
            ["alpha": Int32(3), "beta": Int32(5)],
            keyType: .string,
            valueType: .integer(bitWidth: 32, signed: true),
            encodeKey: { try Runtime.BridgeValueCodec.encode($0) },
            encodeValue: { try Runtime.BridgeValueCodec.encode($0) }
        )
        #expect(
            try Runtime.BridgeValueCodec.decodeDictionary(
                dictionary,
                keyType: .string,
                valueType: .integer(bitWidth: 32, signed: true),
                decodeKey: { try Runtime.BridgeValueCodec.decode($0, as: String.self) },
                decodeValue: { try Runtime.BridgeValueCodec.decode($0, as: Int32.self) }
            ) == ["alpha": 3, "beta": 5]
        )
    }

    @Test("Bridge input limits fall back only when the frozen entry allows it")
    func bridgeInputLimitFallbackPolicy() throws {
        let fixture = try RuntimeFixture(entry: .init(rawValue: 0))

        func configuredRuntime(fallbackAllowed: Bool) throws -> (
            Runtime.Engine,
            Runtime.Bridge
        ) {
            let base = try fixture.makeRuntime(fallbackAllowed: fallbackAllowed)
            let runtime = Runtime.Engine(
                originals: base.originals,
                shellInterfaceHash: fixture.shellHash
            )
            let bridge = Runtime.Bridge()
            try bridge.install(
                runtime: runtime,
                interfaceHash: fixture.shellHash,
                registrationCount: 1
            )
            let resources = Core.ResourceLimits(
                maxVMHeapBytes: 8,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
            let generation = try fixture.generation(
                id: 1,
                parent: nil,
                constant: 30,
                fallbackAllowed: fallbackAllowed,
                requestedResources: resources
            )
            _ = try runtime.activate(generation, expectedActiveID: nil)
            return (runtime, bridge)
        }

        let (_, fallbackBridge) = try configuredRuntime(fallbackAllowed: true)
        let fallback: Runtime.BridgeDispatchResult<Int64> = try fallbackBridge.dispatch(
            entry: fixture.entry,
            arguments: { encoder in [try encoder.encode("too large")] },
            decodeResult: { _ in 0 }
        )
        guard case .originalRequired = fallback else {
            Issue.record("a fallback-safe bridge input rejection did not select previous")
            return
        }

        let (_, strictBridge) = try configuredRuntime(fallbackAllowed: false)
        #expect(
            throws: Runtime.BridgeInputError.estimatedVMByteLimitExceeded(maximum: 8)
        ) {
            let _: Runtime.BridgeDispatchResult<Int64> = try strictBridge.dispatch(
                entry: fixture.entry,
                arguments: { encoder in [try encoder.encode("too large")] },
                decodeResult: { _ in 0 }
            )
        }
    }

    @Test("A delta generation inherits parent routes until a tombstone restores the original")
    func deltaInheritanceAndTombstone() throws {
        let fixture = try RuntimeFixture()
        let runtime = try fixture.makeRuntime(fallbackAllowed: false)
        let first = try fixture.generation(id: 1, parent: nil, constant: 10)
        try runtime.activate(first, expectedActiveID: nil)

        let unrelatedEntry = Core.EntryIndex(rawValue: 9_999)
        let inherited = try Runtime.Generation(
            id: .init(rawValue: 2),
            parentID: first.id,
            packageID: "HLX-runtime-inherited",
            packageHash: .sha256("inherited"),
            images: [],
            removedEntries: [unrelatedEntry],
            estimatedByteCount: 0
        )
        _ = try runtime.registry.activate(inherited, expectedActiveID: first.id)
        #expect(
            runtime.registry.route(for: fixture.entry, startingAt: inherited.id) != nil
        )

        let restored = try Runtime.Generation(
            id: .init(rawValue: 3),
            parentID: inherited.id,
            packageID: "HLX-runtime-restored",
            packageHash: .sha256("restored"),
            images: [],
            removedEntries: [fixture.entry],
            estimatedByteCount: 0
        )
        try runtime.activate(restored, expectedActiveID: inherited.id)
        #expect(runtime.registry.route(for: fixture.entry, startingAt: restored.id) == nil)
        #expect(
            runtime.invoke(entry: fixture.entry, arguments: [.integer(try int(1))])
                == .returned(.integer(try int(3)))
        )
    }

    @Test("A stale activation cannot partially replace the active generation")
    func compareAndSwapRejectsStaleActivation() throws {
        let fixture = try RuntimeFixture()
        let runtime = try fixture.makeRuntime(fallbackAllowed: false)
        let first = try fixture.generation(id: 1, parent: nil, constant: 10)
        let stale = try fixture.generation(id: 2, parent: nil, constant: 20)
        try runtime.activate(first, expectedActiveID: nil)

        #expect(throws: Runtime.ActivationError.self) {
            try runtime.activate(stale, expectedActiveID: nil)
        }
        #expect(runtime.registry.snapshot().activeGenerationID == first.id)
    }

    @Test("Safe fallback runs the original body only before side effects")
    func safeFallback() throws {
        let fixture = try RuntimeFixture()
        let runtime = try fixture.makeRuntime(fallbackAllowed: true)
        let generation = try fixture.generation(
            id: 1,
            parent: nil,
            trap: "fixture trap",
            fallbackAllowed: true
        )
        try runtime.activate(generation, expectedActiveID: nil)

        #expect(
            runtime.invoke(entry: fixture.entry, arguments: [.integer(try int(1))])
                == .returned(.integer(try int(3)))
        )
    }

    @Test("An original body pins its generation across a nested activation")
    func nestedInvocationKeepsGeneration() throws {
        let fixture = try RuntimeFixture()
        let box = RuntimeBox()
        let entryZero = Core.EntryIndex(rawValue: 0)
        let originals = try Runtime.OriginalCatalog([
            .init(index: entryZero, parameterTypes: [.int64], resultType: .int64) { arguments in
                guard let runtime = box.runtime, let next = box.nextGeneration else {
                    return .trapped(.explicit("runtime box is not initialized"))
                }
                do {
                    try runtime.activate(next, expectedActiveID: .init(rawValue: 1))
                } catch {
                    return .trapped(.explicit(String(describing: error)))
                }
                return runtime.invoke(entry: fixture.entry, arguments: arguments)
            },
            .init(index: fixture.entry, parameterTypes: [.int64], resultType: .int64) { _ in
                .returned(.integer(try! int(1)))
            },
        ])
        let runtime = Runtime.Engine(originals: originals)
        box.runtime = runtime
        let first = try fixture.generation(id: 1, parent: nil, constant: 11)
        let second = try fixture.generation(id: 2, parent: first.id, constant: 22)
        box.nextGeneration = second
        try runtime.activate(first, expectedActiveID: nil)

        let result = runtime.invoke(entry: entryZero, arguments: [.integer(try int(0))])
        #expect(result == .returned(.integer(try int(11))))
        #expect(runtime.registry.snapshot().activeGenerationID == second.id)
    }

    @Test("Loaded generation roots remain retained until process exit")
    func registryRetainsRolledBackRoots() throws {
        let fixture = try RuntimeFixture()
        let runtime = try fixture.makeRuntime(fallbackAllowed: false)
        let first = try fixture.generation(id: 1, parent: nil, constant: 10)
        let second = try fixture.generation(id: 2, parent: first.id, constant: 20)
        try runtime.activate(first, expectedActiveID: nil)
        try runtime.activate(second, expectedActiveID: first.id)
        try runtime.rollback(expectedActiveID: second.id, to: first.id)

        let snapshot = runtime.registry.snapshot()
        #expect(snapshot.activeGenerationID == first.id)
        #expect(snapshot.loadedGenerationIDs == [first.id, second.id])
        #expect(runtime.registry.lease(for: second.id) != nil)
    }

    @Test("Rollback cannot reactivate a quarantined generation")
    func quarantinedGenerationCannotBeReactivated() throws {
        let fixture = try RuntimeFixture()
        let runtime = try fixture.makeRuntime(fallbackAllowed: false)
        let first = try fixture.generation(id: 1, parent: nil, constant: 10)
        let second = try fixture.generation(id: 2, parent: first.id, constant: 20)
        try runtime.activate(first, expectedActiveID: nil)
        try runtime.activate(second, expectedActiveID: first.id)
        runtime.registry.quarantine(first.id, rollbackIfActive: false)

        #expect(throws: Runtime.ActivationError.quarantined(first.id)) {
            try runtime.rollback(expectedActiveID: second.id, to: first.id)
        }
        #expect(runtime.registry.snapshot().activeGenerationID == second.id)

        runtime.registry.quarantine(second.id)
        #expect(runtime.registry.snapshot().activeGenerationID == nil)
    }

    @Test("Rollback cannot jump across generation branches")
    func rollbackRequiresAnAncestor() throws {
        let fixture = try RuntimeFixture()
        let runtime = try fixture.makeRuntime(fallbackAllowed: false)
        let first = try fixture.generation(id: 1, parent: nil, constant: 10)
        let abandoned = try fixture.generation(id: 2, parent: first.id, constant: 20)
        try runtime.activate(first, expectedActiveID: nil)
        try runtime.activate(abandoned, expectedActiveID: first.id)
        try runtime.rollback(expectedActiveID: abandoned.id, to: first.id)
        let active = try fixture.generation(id: 3, parent: first.id, constant: 30)
        try runtime.activate(active, expectedActiveID: first.id)

        #expect(
            throws: Runtime.ActivationError.rollbackTargetIsNotAncestor(
                target: abandoned.id,
                active: active.id
            )
        ) {
            try runtime.rollback(expectedActiveID: active.id, to: abandoned.id)
        }
        #expect(runtime.registry.snapshot().activeGenerationID == active.id)
    }

    @Test("Runtime activation rejects an image for another Shell")
    func activationChecksRuntimeShellBinding() throws {
        let fixture = try RuntimeFixture()
        let originals = try Runtime.OriginalCatalog([
            .init(index: fixture.entry, parameterTypes: [.int64], resultType: .int64) { _ in
                .returned(.integer(try! int(3)))
            },
        ])
        let runtime = Runtime.Engine(
            originals: originals,
            shellInterfaceHash: .sha256("another-runtime-shell")
        )
        let generation = try fixture.generation(id: 1, parent: nil, constant: 10)

        #expect(throws: Runtime.ActivationError.self) {
            try runtime.activate(generation, expectedActiveID: nil)
        }
        #expect(runtime.registry.snapshot().activeGenerationID == nil)
    }

    @Test("A nested effectful Shell entry prevents replaying the outer original")
    func nestedEntrySideEffectDisablesFallback() throws {
        let shellHash = Core.Digest.sha256("nested-effects-shell")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.runtime.effects",
            buildNumber: "1",
            seed: "fixture"
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-runtime-effects-fixture"
        )
        let outerEntry = Core.EntryIndex(rawValue: 0)
        let innerEntry = Core.EntryIndex(rawValue: 1)
        let outerKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func outer(_: Int) -> Int",
            loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            role: .function
        )
        let innerKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func commit(_: Int)",
            loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Void"),
            role: .function
        )
        let effects = Core.Effects(hasExternalSideEffects: true)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "outer",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .entryApply(result: nil, entry: innerEntry, arguments: [.init(rawValue: 0)]),
                        .trap(.explicit("after commit")),
                    ]
                ),
            ],
            effects: effects
        )
        let module = Bytecode.Module(
            name: "NestedEffects",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            requestedResources: .init(maxWallTimeMainThreadMilliseconds: 1_000),
            functions: [function],
            entries: [.init(entryIndex: outerEntry, functionKey: outerKey, functionID: function.id)]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            entries: [
                .init(
                    index: outerEntry,
                    key: outerKey,
                    parameterTypes: [.int64],
                    resultType: .int64,
                    effects: effects,
                    fallbackAllowed: true
                ),
                .init(
                    index: innerEntry,
                    key: innerKey,
                    parameterTypes: [.int64],
                    resultType: .void,
                    effects: .init(hasExternalSideEffects: true)
                ),
            ]
        )
        let bytes = try Bytecode.Encoder.encode(module)
        let image = try Verification.Engine().verify(
            bytes: bytes,
            shell: shell,
            policy: .init(resourceCeiling: .init(maxWallTimeMainThreadMilliseconds: 1_000))
        )
        let committed = Counter()
        let replayed = Counter()
        let runtime = Runtime.Engine(
            originals: try .init([
                .init(
                    index: outerEntry,
                    parameterTypes: [.int64],
                    resultType: .int64,
                    fallbackAllowed: true
                ) { _ in
                    replayed.increment()
                    return .returned(.integer(try! int(99)))
                },
                .init(index: innerEntry, parameterTypes: [.int64], resultType: .void) { _ in
                    committed.increment()
                    return .returned(nil)
                },
            ]),
            shellInterfaceHash: shellHash
        )
        let generation = try Runtime.Generation(
            id: .init(rawValue: 1),
            parentID: nil,
            packageID: "HLX-nested-effects",
            packageHash: .sha256(bytes),
            images: [image],
            estimatedByteCount: bytes.count
        )
        try runtime.activate(generation, expectedActiveID: nil)

        #expect(
            runtime.invoke(entry: outerEntry, arguments: [.integer(try int(1))])
                == .trapped(.explicit("after commit"))
        )
        #expect(committed.value == 1)
        #expect(replayed.value == 0)
    }

    private final class RuntimeBox: @unchecked Sendable {
        var runtime: Runtime.Engine?
        var nextGeneration: Runtime.Generation?
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var messages: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func record(_ message: String) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }
    }

    private struct RuntimeFixture {
        let entry: Core.EntryIndex
        let shellHash = Core.Digest.sha256("runtime-shell")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.runtime",
            buildNumber: "1",
            seed: "fixture"
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-runtime-fixture"
        )
        let key: Core.FunctionKey

        init(entry: Core.EntryIndex = .init(rawValue: 1)) throws {
            self.entry = entry
            key = try Core.FunctionKey.derive(
                namespace: namespace,
                module: "Fixture",
                sourceFileLogicalID: "Sources/Fixture.swift",
                canonicalDeclaration: "func value(_: Int) -> Int",
                loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
                role: .function
            )
        }

        func makeRuntime(fallbackAllowed: Bool) throws -> Runtime.Engine {
            let original = Runtime.OriginalEntry(
                index: entry,
                parameterTypes: [.int64],
                resultType: .int64,
                fallbackAllowed: fallbackAllowed
            ) { _ in
                .returned(.integer(try! int(3)))
            }
            return try Runtime.Engine(originals: Runtime.OriginalCatalog([original]))
        }

        func generation(
            id: UInt64,
            parent: Runtime.GenerationID?,
            constant: Int64,
            fallbackAllowed: Bool = false,
            requestedResources: Core.ResourceLimits = .init(
                maxWallTimeMainThreadMilliseconds: 1_000
            )
        ) throws -> Runtime.Generation {
            let function = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "constant\(constant)",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .int64,
                registerTypes: [.int64, .int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [
                            .constantInteger(result: .init(rawValue: 1), value: constant),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ]
            )
            return try makeGeneration(
                id: id,
                parent: parent,
                function: function,
                fallbackAllowed: fallbackAllowed,
                requestedResources: requestedResources
            )
        }

        func generation(
            id: UInt64,
            parent: Runtime.GenerationID?,
            trap: String,
            fallbackAllowed: Bool = false
        ) throws -> Runtime.Generation {
            let function = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "trap",
                parameterRegisters: [.init(rawValue: 0)],
                resultType: .int64,
                registerTypes: [.int64],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: [.trap(.explicit(trap))]
                    ),
                ]
            )
            return try makeGeneration(
                id: id,
                parent: parent,
                function: function,
                fallbackAllowed: fallbackAllowed,
                requestedResources: .init(
                    maxWallTimeMainThreadMilliseconds: 1_000
                )
            )
        }

        private func makeGeneration(
            id: UInt64,
            parent: Runtime.GenerationID?,
            function: Bytecode.Function,
            fallbackAllowed: Bool,
            requestedResources: Core.ResourceLimits
        ) throws -> Runtime.Generation {
            let module = Bytecode.Module(
                name: "RuntimeFixture",
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                requestedResources: requestedResources,
                functions: [function],
                entries: [.init(entryIndex: entry, functionKey: key, functionID: function.id)]
            )
            let shell = try Verification.ShellInterface(
                interfaceHash: shellHash,
                compatibility: compatibility,
                entries: [
                    .init(
                        index: entry,
                        key: key,
                        parameterTypes: [.int64],
                        resultType: .int64,
                        fallbackAllowed: fallbackAllowed
                    ),
                ]
            )
            let bytes = try Bytecode.Encoder.encode(module)
            let image = try Verification.Engine().verify(
                bytes: bytes,
                shell: shell,
                policy: .init(resourceCeiling: .init(maxWallTimeMainThreadMilliseconds: 1_000))
            )
            return try Runtime.Generation(
                id: .init(rawValue: id),
                parentID: parent,
                packageID: "HLX-runtime-\(id)",
                packageHash: .sha256(bytes),
                images: [image],
                estimatedByteCount: bytes.count
            )
        }
    }
}
}

private func int(_ value: Int64) throws -> VM.Integer {
    try VM.Integer(signed: value, bitWidth: 64, isSigned: true)
}
