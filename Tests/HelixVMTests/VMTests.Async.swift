import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import Testing
@testable import HelixVM

private actor AsyncCallTrace {
    private var values: [Int64] = []

    func append(_ value: Int64) {
        values.append(value)
    }

    func snapshot() -> [Int64] {
        values
    }
}

private final class AsyncManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0

    func now() -> UInt64 {
        lock.withLock { nanoseconds }
    }

    func advance(milliseconds: UInt64) {
        lock.withLock { nanoseconds += milliseconds * 1_000_000 }
    }
}

extension VMTests {
@Suite("HLVM sequential async execution")
struct AsyncExecution {
    @Test("Multiple NativeImport awaits suspend and resume one VM frame in order")
    func executesMultipleSequentialAwaits() async throws {
        let trace = AsyncCallTrace()
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "twiceAsync",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .nativeApply(
                            result: .init(rawValue: 1),
                            importID: .init(rawValue: 0),
                            arguments: [.init(rawValue: 0)]
                        ),
                        .nativeApply(
                            result: .init(rawValue: 2),
                            importID: .init(rawValue: 0),
                            arguments: [.init(rawValue: 1)]
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ],
            effects: .init(isAsync: true)
        )
        let fixture = try makeAsyncFixture(
            function: function,
            limits: .init(
                maxWallTimeMainThreadMilliseconds: 60_000,
                maxWallTimeBackgroundMilliseconds: 60_000
            ),
            importMaximumDurationMicroseconds: 60_000_000
        )
        let invoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.importID,
            key: fixture.importKey,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: fixture.importEffects,
            contract: fixture.importContract
        ) { arguments, _ in
            guard case let .integer(value) = arguments.first else {
                return .businessError("expected Int")
            }
            await trace.append(value.signedValue)
            await Task.yield()
            return .returned(
                .integer(
                    try VM.Integer(
                        signed: value.signedValue + 1,
                        bitWidth: 64,
                        isSigned: true
                    )
                )
            )
        }
        let interpreter = VM.Interpreter(
            asyncNativeCatalog: try .init([invoker])
        )
        let input = try VM.Value.integerValue(40)
        let result = await interpreter.invokeAsync(
            entry: .init(rawValue: 0),
            image: fixture.image,
            arguments: [input]
        )
        #expect(result == .returned(try .integerValue(42)))
        #expect(await trace.snapshot() == [40, 41])
    }

    @Test("Async try_apply resumes its typed error continuation")
    func catchesAsyncBusinessError() async throws {
        let effects = Core.Effects(mayThrow: true, isAsync: true)
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "catchAsync",
            parameterRegisters: [],
            resultType: .int64,
            registerTypes: [.int64, .string, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    instructions: [
                        .nativeTryApply(
                            importID: .init(rawValue: 0),
                            arguments: [],
                            normalTarget: .init(rawValue: 1),
                            errorTarget: .init(rawValue: 2)
                        ),
                    ]
                ),
                .init(
                    id: .init(rawValue: 1),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 1)],
                    instructions: [
                        .constantInteger(
                            result: .init(rawValue: 2),
                            bitPattern: 99
                        ),
                        .returnValue(.init(rawValue: 2)),
                    ]
                ),
            ],
            effects: .init(isAsync: true)
        )
        let fixture = try makeAsyncFixture(
            function: function,
            importEffects: effects,
            importParameterTypes: [],
            additionalCapabilities: [.stringsV1, .untypedThrowsV1],
            entrySignature: .init(
                parameters: [],
                result: "Swift.Int",
                isAsync: true
            ),
            importSignature: .init(
                parameters: [],
                result: "Swift.Int",
                isThrowing: true,
                isAsync: true
            )
        )
        let invoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.importID,
            key: fixture.importKey,
            parameterTypes: [],
            resultType: .int64,
            effects: effects,
            contract: fixture.importContract
        ) { _, _ in
            .businessError("rejected")
        }

        #expect(
            await VM.Interpreter(
                asyncNativeCatalog: try .init([invoker])
            ).invokeAsync(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: []
            ) == .returned(try .integerValue(99))
        )
    }

    @Test("Cancellation wins over a suspended NativeImport result")
    func cancelsSuspendedExecution() async throws {
        let fixture = try makeAsyncFixture(function: Self.oneAwaitFunction())
        let budget = VM.InvocationBudget(
            limits: fixture.image.effectiveResourceLimits,
            isMainThread: false
        )
        let invoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.importID,
            key: fixture.importKey,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: fixture.importEffects,
            contract: fixture.importContract
        ) { arguments, _ in
            await Task.yield()
            budget.cancel()
            return .returned(arguments[0])
        }

        let result = await VM.Interpreter(
            asyncNativeCatalog: try .init([invoker])
        ).invokeAsync(
            entry: .init(rawValue: 0),
            image: fixture.image,
            arguments: [try .integerValue(7)],
            budget: budget
        )
        #expect(result == .trapped(.executionCancelled))
    }

    @Test("Suspended host time pauses only the root active-time deadline")
    func pausesRootDeadlineDuringNativeSuspension() async throws {
        let clock = AsyncManualClock()
        let limits = Core.ResourceLimits(
            maxWallTimeMainThreadMilliseconds: 10,
            maxWallTimeBackgroundMilliseconds: 10
        )
        let fixture = try makeAsyncFixture(
            function: Self.oneAwaitFunction(),
            limits: limits,
            importMaximumDurationMicroseconds: 100_000
        )
        let invoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.importID,
            key: fixture.importKey,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: fixture.importEffects,
            contract: fixture.importContract
        ) { arguments, _ in
            await Task.yield()
            clock.advance(milliseconds: 50)
            return .returned(arguments[0])
        }
        let budget = VM.InvocationBudget(
            limits: fixture.image.effectiveResourceLimits,
            isMainThread: false,
            nowNanoseconds: clock.now
        )
        let result = await VM.Interpreter(
            asyncNativeCatalog: try .init([invoker])
        ).invokeAsync(
            entry: .init(rawValue: 0),
            image: fixture.image,
            arguments: [try .integerValue(8)],
            budget: budget
        )
        #expect(result == .returned(try .integerValue(8)))
    }

    @Test("An async NativeImport keeps its exact wall-clock deadline")
    func enforcesAsyncNativeDeadline() async throws {
        let clock = AsyncManualClock()
        let limits = Core.ResourceLimits(
            maxWallTimeMainThreadMilliseconds: 100,
            maxWallTimeBackgroundMilliseconds: 100
        )
        let fixture = try makeAsyncFixture(
            function: Self.oneAwaitFunction(),
            limits: limits,
            importMaximumDurationMicroseconds: 20_000
        )
        let invoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.importID,
            key: fixture.importKey,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: fixture.importEffects,
            contract: fixture.importContract
        ) { arguments, _ in
            await Task.yield()
            clock.advance(milliseconds: 50)
            return .returned(arguments[0])
        }
        let budget = VM.InvocationBudget(
            limits: fixture.image.effectiveResourceLimits,
            isMainThread: false,
            nowNanoseconds: clock.now
        )
        let result = await VM.Interpreter(
            asyncNativeCatalog: try .init([invoker])
        ).invokeAsync(
            entry: .init(rawValue: 0),
            image: fixture.image,
            arguments: [try .integerValue(8)],
            budget: budget
        )
        #expect(
            result == .trapped(
                .nativeImportDeadlineExceeded(fixture.importID)
            )
        )
    }

    @Test("Swift Task cancellation is observed after native resumption")
    func observesTaskCancellation() async throws {
        let fixture = try makeAsyncFixture(function: Self.oneAwaitFunction())
        let invoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.importID,
            key: fixture.importKey,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: fixture.importEffects,
            contract: fixture.importContract
        ) { arguments, _ in
            await Task.yield()
            withUnsafeCurrentTask { $0?.cancel() }
            return .returned(arguments[0])
        }
        let invocation = Task {
            await VM.Interpreter(
                asyncNativeCatalog: try! .init([invoker])
            ).invokeAsync(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [try! .integerValue(9)]
            )
        }

        #expect(await invocation.value == .trapped(.executionCancelled))
    }

    @Test("The suspended-frame limit includes nested async image calls")
    func enforcesSuspendedFrameLimit() async throws {
        let helper = Self.oneAwaitFunction(id: .init(rawValue: 1))
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "nestedAsync",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .apply(
                            result: .init(rawValue: 1),
                            function: helper.id,
                            arguments: [.init(rawValue: 0)]
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ],
            effects: .init(isAsync: true)
        )
        let fixture = try makeAsyncFixture(
            function: root,
            additionalFunctions: [helper],
            limits: .init(maxSuspendedFrames: 1)
        )
        let invoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.importID,
            key: fixture.importKey,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: fixture.importEffects,
            contract: fixture.importContract
        ) { arguments, _ in
            .returned(arguments[0])
        }

        #expect(
            await VM.Interpreter(
                asyncNativeCatalog: try .init([invoker])
            ).invokeAsync(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [try .integerValue(1)]
            ) == .trapped(.suspendedFrameLimitExceeded)
        )
    }

    @Test("A nonisolated async function may await a MainActor import")
    @MainActor
    func crossesToMainActorImport() async throws {
        let effects = Core.Effects(requiresMainActor: true, isAsync: true)
        let fixture = try makeAsyncFixture(
            function: Self.oneAwaitFunction(),
            limits: .init(
                maxWallTimeMainThreadMilliseconds: 60_000,
                maxWallTimeBackgroundMilliseconds: 60_000
            ),
            importEffects: effects,
            importSignature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int",
                isAsync: true,
                isolation: "MainActor"
            ),
            importMaximumDurationMicroseconds: 60_000_000
        )
        let invoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.importID,
            key: fixture.importKey,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: effects,
            contract: fixture.importContract
        ) { arguments, context in
            try await context.withMainActor {
                await Task.yield()
                MainActor.preconditionIsolated()
                return .returned(arguments[0])
            }
        }

        let result = await VM.Interpreter(
            asyncNativeCatalog: try .init([invoker])
        ).invokeAsync(
            entry: .init(rawValue: 0),
            image: fixture.image,
            arguments: [try .integerValue(11)]
        )
        #expect(result == .returned(try .integerValue(11)))
    }

    @Test("A MainActor async NativeImport must enter through its actor gate")
    func rejectsMainActorGateBypass() async throws {
        let effects = Core.Effects(requiresMainActor: true, isAsync: true)
        let fixture = try makeAsyncFixture(
            function: Self.oneAwaitFunction(),
            importEffects: effects,
            importSignature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int",
                isAsync: true,
                isolation: "MainActor"
            )
        )
        let invoker = VM.ClosureAsyncNativeInvoker(
            id: fixture.importID,
            key: fixture.importKey,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: effects,
            contract: fixture.importContract
        ) { arguments, _ in
            .returned(arguments[0])
        }

        #expect(
            await VM.Interpreter(
                asyncNativeCatalog: try .init([invoker])
            ).invokeAsync(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [try .integerValue(12)]
            ) == .trapped(.nativeFailure(
                "async MainActor native import bypassed its actor gate"
            ))
        )
    }

    @Test("Sync and async NativeImport catalogs reject crossed effects")
    func rejectsCrossedNativeCatalogEffects() throws {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.vm.async-catalog",
            buildNumber: "1",
            seed: "fixture"
        )
        let asyncEffects = Core.Effects(isAsync: true)
        let asyncContract = Core.NativeImportContract.suspending(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 1_000_000,
            allowsMainThread: true
        )
        let signature = Core.LoweredSignature(
            parameters: [],
            result: "Swift.Int",
            isAsync: true
        )
        let key = try Core.NativeImportKey.derive(
            namespace: namespace,
            canonicalCallee: "Fixture.value()",
            signature: signature,
            effects: asyncEffects,
            contract: asyncContract
        )
        let crossedSync = VM.ClosureNativeInvoker(
            id: .init(rawValue: 0),
            key: key,
            parameterTypes: [],
            resultType: .int64,
            effects: asyncEffects,
            contract: asyncContract
        ) { _, _ in .returned(try .integerValue(1)) }
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try VM.NativeCatalog([crossedSync])
        }

        let syncContract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 1_000,
            allowsMainThread: true
        )
        let crossedAsync = VM.ClosureAsyncNativeInvoker(
            id: .init(rawValue: 1),
            key: key,
            parameterTypes: [],
            resultType: .int64,
            effects: .init(),
            contract: syncContract
        ) { _, _ in .returned(try .integerValue(1)) }
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try VM.AsyncNativeCatalog([crossedAsync])
        }
    }

    private static func oneAwaitFunction(
        id: Bytecode.FunctionID = .init(rawValue: 0)
    ) -> Bytecode.Function {
        .init(
            id: id,
            name: "oneAwait",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .nativeApply(
                            result: .init(rawValue: 1),
                            importID: .init(rawValue: 0),
                            arguments: [.init(rawValue: 0)]
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ],
            effects: .init(isAsync: true)
        )
    }

    private struct AsyncFixture {
        var image: Verification.Image
        var importID: Core.NativeImportID
        var importKey: Core.NativeImportKey
        var importEffects: Core.Effects
        var importContract: Core.NativeImportContract
    }

    private func makeAsyncFixture(
        function: Bytecode.Function,
        additionalFunctions: [Bytecode.Function] = [],
        limits: Core.ResourceLimits = .init(),
        importEffects: Core.Effects = .init(isAsync: true),
        importParameterTypes: [Bytecode.ValueType] = [.int64],
        additionalCapabilities: Set<Core.Capability> = [],
        entrySignature: Core.LoweredSignature = .init(
            parameters: ["Swift.Int"],
            result: "Swift.Int",
            isAsync: true
        ),
        importSignature: Core.LoweredSignature = .init(
            parameters: ["Swift.Int"],
            result: "Swift.Int",
            isAsync: true
        ),
        importMaximumDurationMicroseconds: UInt32 = 1_000_000
    ) throws -> AsyncFixture {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.vm.async",
            buildNumber: "1",
            seed: "fixture"
        )
        let shellHash = Core.Digest.sha256("vm-async-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-vm-async-fixture"
        )
        let entryKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func run(_ value: Int) async -> Int",
            loweredSignature: entrySignature,
            role: .function
        )
        let contract = Core.NativeImportContract.suspending(
            kind: .globalFunction,
            domain: .application,
            access: importEffects.hasExternalSideEffects ? .write : .pure,
            maximumDurationMicroseconds: importMaximumDurationMicroseconds,
            allowsMainThread: true
        )
        let importID = Core.NativeImportID(rawValue: 0)
        let importKey = try Core.NativeImportKey.derive(
            namespace: namespace,
            canonicalCallee: "Fixture.awaited(_:)",
            signature: importSignature,
            effects: importEffects,
            contract: contract
        )
        let capabilities = Set<Core.Capability>([
            .baselineV1, .nativeImportsV1, .sequentialAsyncV1,
        ]).union(additionalCapabilities)
        let requirement = Bytecode.ImportRequirement(
            id: importID,
            key: importKey,
            signature: importSignature,
            effects: importEffects,
            contract: contract
        )
        let descriptor = Verification.ResolvedNativeImport(
            id: importID,
            key: importKey,
            parameterTypes: importParameterTypes,
            resultType: .int64,
            signature: importSignature,
            effects: importEffects,
            contract: contract
        )
        let module = Bytecode.Module(
            name: "VMAsyncFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            requestedResources: limits,
            functions: [function] + additionalFunctions,
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: entryKey,
                    functionID: function.id
                ),
            ],
            imports: [requirement]
        )
        let parameterTypes = function.parameterRegisters.compactMap {
            function.type(of: $0)
        }
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: entryKey,
                    parameterTypes: parameterTypes,
                    parameterConventions: function.parameterConventions,
                    resultType: function.resultType,
                    effects: function.effects
                ),
            ],
            imports: [descriptor]
        )
        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(
                acceptedCapabilities: capabilities,
                resourceCeiling: limits,
                allowedNativeImports: [importID]
            )
        )
        return .init(
            image: image,
            importID: importID,
            importKey: importKey,
            importEffects: importEffects,
            importContract: contract
        )
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

private extension NSLock {
    func withLock<Result>(_ operation: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return operation()
    }
}
