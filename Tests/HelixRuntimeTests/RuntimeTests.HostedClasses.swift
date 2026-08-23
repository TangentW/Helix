import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
import Testing
@testable import HelixRuntime

extension RuntimeTests {
@Suite("Objective-C hosted patch-local classes")
struct HostedClasses {
    @Test("A hosted class is a native subclass and dispatches bounded callbacks")
    func allocatesAndDispatchesCallbacks() throws {
        let fixture = try Fixture(trapAfterSuper: false)
        let host = try fixture.allocate()

        let dynamicClass: AnyClass = try #require(object_getClass(host))
        #expect(dynamicClass !== HostedFixtureBase.self)
        #expect(NSStringFromClass(dynamicClass).hasPrefix("HelixHosted_"))

        host.helixEvent()
        host.helixEvent(animated: true)

        #expect(host.eventCount == 1)
        #expect(host.animationValues == [true])
        #expect(fixture.observer.hostedDiagnostics.isEmpty)
    }

    @Test("A trap after exact-super dispatch never replays the side effect")
    func trapsWithoutReplayingSuper() throws {
        let fixture = try Fixture(trapAfterSuper: true)
        let host = try fixture.allocate()

        host.helixEvent()
        #expect(host.eventCount == 1)
        #expect(fixture.observer.hostedDiagnostics.count == 1)
        #expect(fixture.observer.hostedDiagnostics.first?.typeKey == fixture.typeKey)
        #expect(fixture.observer.hostedDiagnostics.first?.selector == "helixEvent")

        // One failed callback disables its object-local route. Later calls use
        // the exact superclass implementation without re-entering HLBC.
        host.helixEvent()
        #expect(host.eventCount == 2)
        #expect(fixture.observer.hostedDiagnostics.count == 1)

        // Circuit breaking is object-wide: a partially mutated object must not
        // continue through a different hosted callback.
        host.helixEvent(animated: true)
        #expect(host.animationValues == [true])
        #expect(fixture.observer.hostedDiagnostics.count == 1)
    }

    @Test("A trap before side effects falls back to exact super once")
    func trapsWithSafeFallback() throws {
        let fixture = try Fixture(
            trapBeforeSuper: true,
            trapAfterSuper: false
        )
        let host = try fixture.allocate()

        host.helixEvent()
        #expect(host.eventCount == 1)
        #expect(fixture.observer.hostedDiagnostics.count == 1)

        host.helixEvent()
        #expect(host.eventCount == 2)
        #expect(fixture.observer.hostedDiagnostics.count == 1)
    }

    @Test("Hosted allocation is charged to the invocation native budget")
    func enforcesNativeAllocationBudget() throws {
        let fixture = try Fixture(
            trapAfterSuper: false,
            maxNativeOwnedBytes: 7
        )
        #expect(
            fixture.engine.invoke(entry: fixture.entry, arguments: [])
                == .trapped(.nativeOwnedMemoryLimitExceeded)
        )
    }

    @Test("A hosted instance pins its creating generation after rollback")
    func pinsCreatingGeneration() throws {
        let fixture = try Fixture(trapAfterSuper: false)
        let host = try fixture.allocate()

        try fixture.engine.rollback(
            expectedActiveID: .init(rawValue: 1),
            to: nil
        )
        host.helixEvent()

        #expect(host.eventCount == 1)
        #expect(fixture.observer.hostedDiagnostics.isEmpty)
    }

    private struct Fixture {
        let typeKey = Bytecode.LocalTypeKey(rawValue: "Patch.HostedFixture")
        let entry = Core.EntryIndex(rawValue: 0)
        let engine: Runtime.Engine
        let typeCatalog: VM.NativeTypeCatalog
        let nativeTypeID: Core.TypeID
        let observer: HostedObserver

        init(
            trapBeforeSuper: Bool = false,
            trapAfterSuper: Bool,
            maxNativeOwnedBytes: UInt64 = 8 * 1_024 * 1_024
        ) throws {
            precondition(!(trapBeforeSuper && trapAfterSuper))
            let trapMode = trapBeforeSuper
                ? "before"
                : (trapAfterSuper ? "after" : "none")
            let namespace = Core.ShellNamespaceID.derive(
                bundleID: "dev.helix.hosted-runtime",
                buildNumber: "1",
                seed: trapMode
            )
            let shellHash = Core.Digest.sha256(
                "hosted-runtime-\(trapMode)"
            )
            let compatibility = Core.Compatibility(
                runtime: Core.Versions.runtime,
                bytecode: Core.Versions.bytecode,
                interfaceArchive: Core.Versions.interfaceArchive,
                compilerFingerprint: "hosted-runtime-fixture"
            )
            nativeTypeID = Core.TypeID.derive(
                namespace: namespace,
                canonicalType: "HelixRuntimeTests.HostedFixtureBase"
            )
            let layout = Core.Digest.sha256("HostedFixtureBase-layout")
            let baseOperations = VM.NativeTypeOperations.reference(
                id: nativeTypeID,
                canonicalName: "HelixRuntimeTests.HostedFixtureBase",
                layoutFingerprint: layout,
                estimatedSize: 8,
                describe: { (value: HostedFixtureBase) in
                    String(describing: value)
                }
            )
            typeCatalog = try VM.NativeTypeCatalog([baseOperations])
            let functionKey = try Core.FunctionKey.derive(
                namespace: namespace,
                module: "HostedRuntimeFixture",
                sourceFileLogicalID: "Patch.swift",
                canonicalDeclaration: "func makeHosted() -> HostedFixtureBase",
                loweredSignature: .init(
                    parameters: [],
                    result: "HelixRuntimeTests.HostedFixtureBase"
                ),
                role: .function
            )
            let noArgumentMethod = Bytecode.HostedMethod(
                selector: "helixEvent",
                functionID: .init(rawValue: 1),
                abi: .voidNoArguments
            )
            let boolMethod = Bytecode.HostedMethod(
                selector: "helixEventWithAnimated:",
                functionID: .init(rawValue: 2),
                abi: .voidBool
            )
            let root = Bytecode.Function(
                id: .init(rawValue: 0),
                name: "makeHosted",
                parameterRegisters: [],
                resultType: .native(nativeTypeID),
                registerTypes: [.local(typeKey), .native(nativeTypeID)],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        instructions: [
                            .allocateObject(result: .init(rawValue: 0)),
                            .projectHostedObject(
                                result: .init(rawValue: 1),
                                object: .init(rawValue: 0)
                            ),
                            .returnValue(.init(rawValue: 1)),
                        ]
                    ),
                ],
                effects: .init(mayAllocate: true)
            )
            var noArgumentInstructions: [Bytecode.Instruction]
            if trapBeforeSuper {
                noArgumentInstructions = [
                    .trap(.explicit("before hosted super")),
                ]
            } else {
                noArgumentInstructions = [
                    .hostedSuperApply(
                        object: .init(rawValue: 0),
                        methodIndex: 0,
                        arguments: []
                    ),
                    trapAfterSuper
                        ? .trap(.explicit("after hosted super"))
                        : .returnValue(nil),
                ]
            }
            let noArgumentFunction = Bytecode.Function(
                id: noArgumentMethod.functionID,
                name: "HostedFixture.helixEvent",
                parameterRegisters: [.init(rawValue: 0)],
                parameterConventions: [.borrowed],
                resultType: .void,
                registerTypes: [.local(typeKey)],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0)],
                        instructions: noArgumentInstructions
                    ),
                ],
                effects: .init(hasExternalSideEffects: true)
            )
            let boolFunction = Bytecode.Function(
                id: boolMethod.functionID,
                name: "HostedFixture.helixEvent(animated:)",
                parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
                parameterConventions: [.owned, .borrowed],
                resultType: .void,
                registerTypes: [.bool, .local(typeKey)],
                entryBlock: .init(rawValue: 0),
                blocks: [
                    .init(
                        id: .init(rawValue: 0),
                        parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                        instructions: [
                            .hostedSuperApply(
                                object: .init(rawValue: 1),
                                methodIndex: 1,
                                arguments: [.init(rawValue: 0)]
                            ),
                            .returnValue(nil),
                        ]
                    ),
                ],
                effects: .init(hasExternalSideEffects: true)
            )
            let limits = Core.ResourceLimits(
                maxNativeOwnedBytes: maxNativeOwnedBytes,
                maxWallTimeMainThreadMilliseconds: 1_000
            )
            let module = Bytecode.Module(
                name: "HostedRuntimeFixture",
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                capabilities: [
                    .baselineV1,
                    .nativeTypesV1,
                    .localNominalsV1,
                    .localClassesV1,
                    .borrowCallsV1,
                    .hostedObjectiveCClassesV1,
                ],
                requestedResources: limits,
                localTypes: [
                    .init(
                        key: typeKey,
                        kind: .class(
                            fields: [],
                            hostedSuperclass: .init(typeID: nativeTypeID),
                            hostedMethods: [noArgumentMethod, boolMethod]
                        )
                    ),
                ],
                functions: [root, noArgumentFunction, boolFunction],
                entries: [
                    .init(
                        entryIndex: entry,
                        functionKey: functionKey,
                        functionID: root.id
                    ),
                ]
            )
            let shell = try Verification.ShellInterface(
                interfaceHash: shellHash,
                compatibility: compatibility,
                capabilities: module.capabilities,
                entries: [
                    .init(
                        index: entry,
                        key: functionKey,
                        parameterTypes: [],
                        parameterConventions: root.parameterConventions,
                        resultType: .native(nativeTypeID),
                        effects: .init(mayAllocate: true)
                    ),
                ],
                types: [
                    .init(
                        id: nativeTypeID,
                        canonicalName: "HelixRuntimeTests.HostedFixtureBase",
                        kind: .reference,
                        layoutFingerprint: layout,
                        isCopyable: true,
                        estimatedSize: 8
                    ),
                ]
            )
            let bytes = try Bytecode.Encoder.encode(module)
            let image = try Verification.Engine().verify(
                bytes: bytes,
                shell: shell,
                policy: .init(
                    acceptedCapabilities: module.capabilities,
                    resourceCeiling: limits
                )
            )
            observer = HostedObserver()
            let fallback = try typeCatalog.box(
                HostedFixtureBase(),
                as: nativeTypeID
            )
            engine = Runtime.Engine(
                originals: try .init([
                    .init(
                        index: entry,
                        parameterTypes: [],
                        resultType: .native(nativeTypeID)
                    ) { _ in .returned(.native(fallback)) },
                ]),
                shellInterfaceHash: shellHash,
                nativeTypeCatalog: typeCatalog,
                observer: observer
            )
            let generation = try Runtime.Generation(
                id: .init(rawValue: 1),
                parentID: nil,
                packageID: "HLX-hosted-\(trapMode)",
                packageHash: .sha256(bytes),
                images: [image],
                estimatedByteCount: bytes.count
            )
            try engine.activate(generation, expectedActiveID: nil)
        }

        func allocate() throws -> HostedFixtureBase {
            guard case let .returned(.native(value)?) = engine.invoke(
                entry: entry,
                arguments: []
            ), let host = value.value(as: HostedFixtureBase.self) else {
                throw FixtureError.allocationFailed
            }
            return host
        }
    }

    private enum FixtureError: Error {
        case allocationFailed
    }
}
}

private class HostedFixtureBase: NSObject {
    private(set) var eventCount = 0
    private(set) var animationValues: [Bool] = []

    @objc dynamic func helixEvent() {
        eventCount += 1
    }

    @objc(helixEventWithAnimated:)
    dynamic func helixEvent(animated: Bool) {
        animationValues.append(animated)
    }
}

private final class HostedObserver: Runtime.Observing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Runtime.HostedTrapDiagnostic] = []

    var hostedDiagnostics: [Runtime.HostedTrapDiagnostic] {
        lock.withLock { storage }
    }

    func didActivate(generation: Runtime.GenerationID) {}
    func didRollback(from: Runtime.GenerationID, to: Runtime.GenerationID?) {}
    func didTrap(hostedDiagnostic: Runtime.HostedTrapDiagnostic) {
        lock.withLock { storage.append(hostedDiagnostic) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
