import Foundation
import HelixBytecode
import HelixCore
import HelixRuntime
import HelixVerifier
import HelixVM

extension Benchmarks {
struct Fixture {
    let entry = Core.EntryIndex(rawValue: 0)
    let shellHash = Core.Digest.sha256("helix-benchmark-shell")
    let compatibility = Core.Compatibility(
        runtime: Core.Versions.runtime,
        bytecode: Core.Versions.bytecode,
        interfaceArchive: Core.Versions.interfaceArchive,
        compilerFingerprint: "helix-benchmark-swift"
    )
    let bytes: Data
    let shell: Verification.ShellInterface
    let image: Verification.Image
    let uiNativeImportImage: Verification.Image
    let uiNativeCatalog: VM.NativeCatalog
    let closureImage: Verification.Image
    let originalRuntime: Runtime.Engine
    let patchedRuntime: Runtime.Engine
    let originalBridge: Runtime.Bridge
    let patchedBridge: Runtime.Bridge

    init() throws {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.benchmark",
            buildNumber: "1",
            seed: "performance-baseline"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "BenchmarkFeature",
            sourceFileLogicalID: "Sources/BenchmarkFeature.swift",
            canonicalDeclaration: "func transform(_: Int) -> Int",
            loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            role: .function
        )
        let function = Self.makeFunction()
        let module = Bytecode.Module(
            name: "BenchmarkPatch",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            requestedResources: .init(
                maxWallTimeMainThreadMilliseconds: 1_000,
                maxWallTimeBackgroundMilliseconds: 1_000
            ),
            functions: [function],
            entries: [.init(entryIndex: entry, functionKey: key, functionID: function.id)]
        )
        shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            entries: [
                .init(
                    index: entry,
                    key: key,
                    parameterTypes: [.int64],
                    resultType: .int64
                ),
            ]
        )
        bytes = try Bytecode.Encoder.encode(module)
        image = try Verification.Engine().verify(
            bytes: bytes,
            shell: shell,
            policy: .init(
                resourceCeiling: .init(
                    maxWallTimeMainThreadMilliseconds: 1_000,
                    maxWallTimeBackgroundMilliseconds: 1_000
                )
            )
        )
        let uiNativeFixture = try Self.makeUINativeImportImage(
            compatibility: compatibility,
            namespace: namespace
        )
        uiNativeImportImage = uiNativeFixture.image
        uiNativeCatalog = uiNativeFixture.catalog
        closureImage = try Self.makeClosureImage(compatibility: compatibility)

        originalRuntime = Runtime.Engine(
            originals: try Self.originalCatalog(entry: entry),
            shellInterfaceHash: shellHash
        )
        patchedRuntime = Runtime.Engine(
            originals: try Self.originalCatalog(entry: entry),
            shellInterfaceHash: shellHash
        )
        let generation = try Runtime.Generation(
            id: .init(rawValue: 1),
            parentID: nil,
            packageID: "HLX-benchmark-generation",
            packageHash: .sha256(bytes),
            images: [image],
            estimatedByteCount: bytes.count
        )
        try patchedRuntime.activate(generation, expectedActiveID: nil)

        originalBridge = Runtime.Bridge()
        patchedBridge = Runtime.Bridge()
        try originalBridge.install(
            runtime: originalRuntime,
            interfaceHash: shellHash,
            registrationCount: 1
        )
        try patchedBridge.install(
            runtime: patchedRuntime,
            interfaceHash: shellHash,
            registrationCount: 1
        )
    }

    @inline(never)
    static func directTransform(_ input: Int64) -> Int64 {
        input + 27
    }

    static func input(for iteration: Int) -> Int64 {
        Int64(iteration & 1_023)
    }

    func invokeOriginalRuntime(_ input: Int64) throws -> Int64 {
        try decode(
            originalRuntime.invoke(
                entry: entry,
                arguments: [.integer(integer(input))]
            ),
            scenario: .runtimeOriginalCatalog
        )
    }

    func invokeImage(_ input: Int64) throws -> Int64 {
        try decode(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [.integer(integer(input))]
            ),
            scenario: .verifiedImageInvocation
        )
    }

    func invokeClosureImage(_ input: Int64) throws -> Int64 {
        try decode(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: closureImage,
                arguments: [.integer(integer(input))]
            ),
            scenario: .closureImageInvocation
        )
    }

    func invokeUINativeImport(_ input: Int64) throws -> Int64 {
        try decode(
            VM.Interpreter(nativeCatalog: uiNativeCatalog).invoke(
                entry: entry,
                image: uiNativeImportImage,
                arguments: [.integer(integer(input))]
            ),
            scenario: .uiNativeImportInvocation
        )
    }

    func invokeOriginalBridge(_ input: Int64) throws -> Int64 {
        try invokeBridge(originalBridge, input: input, scenario: .bridgeOriginalFastPath)
    }

    func invokePatchedBridge(_ input: Int64) throws -> Int64 {
        try invokeBridge(patchedBridge, input: input, scenario: .bridgeHLBCPatch)
    }

    func verifyImageHashByte() throws -> UInt64 {
        let verified = try Verification.Engine().verify(
            bytes: bytes,
            shell: shell,
            policy: .init(
                resourceCeiling: .init(
                    maxWallTimeMainThreadMilliseconds: 1_000,
                    maxWallTimeBackgroundMilliseconds: 1_000
                )
            )
        )
        return UInt64(verified.imageHash.bytes[0])
    }

    private func invokeBridge(
        _ bridge: Runtime.Bridge,
        input: Int64,
        scenario: Benchmarks.ScenarioName
    ) throws -> Int64 {
        let decision = try bridge.dispatch(
            entry: entry,
            arguments: { encoder in
                try encoder.encodeArguments(count: 1) {
                    [try encoder.encode(input)]
                }
            },
            decodeResult: { value in
                guard let value else {
                    throw Benchmarks.Error.unexpectedResult(
                        scenario: scenario,
                        detail: "the patch returned Void"
                    )
                }
                return try Runtime.BridgeValueCodec.decode(value, as: Int64.self)
            }
        )
        switch decision {
        case .originalRequired:
            return Self.directTransform(input)
        case let .returned(result):
            return result
        }
    }

    private func decode(
        _ result: VM.ExecutionResult,
        scenario: Benchmarks.ScenarioName
    ) throws -> Int64 {
        guard case let .returned(.some(.integer(value))) = result else {
            throw Benchmarks.Error.unexpectedResult(
                scenario: scenario,
                detail: String(describing: result)
            )
        }
        return value.signedValue
    }

    private func integer(_ value: Int64) throws -> VM.Integer {
        try VM.Integer(signed: value, bitWidth: 64, isSigned: true)
    }

    private static func originalCatalog(entry: Core.EntryIndex) throws -> Runtime.OriginalCatalog {
        try Runtime.OriginalCatalog([
            .init(
                index: entry,
                parameterTypes: [.int64],
                resultType: .int64
            ) { arguments in
                guard case let .integer(input) = arguments.first else {
                    return .trapped(.explicit("benchmark original received a non-integer"))
                }
                let result = directTransform(input.signedValue)
                return .returned(
                    .integer(try! VM.Integer(signed: result, bitWidth: 64, isSigned: true))
                )
            },
        ])
    }

    private static func makeFunction() -> Bytecode.Function {
        Bytecode.Function(
            id: .init(rawValue: 0),
            name: "transform",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64, .int64, .bool, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(result: .init(rawValue: 1), value: 27),
                        .checkedBinary(
                            result: .init(rawValue: 2),
                            overflow: .init(rawValue: 3),
                            operation: .add,
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .conditionalBranch(
                            condition: .init(rawValue: 3),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: [.init(rawValue: 2)]
                        ),
                    ]
                ),
                .init(id: .init(rawValue: 1), instructions: [.trap(.integerOverflow)]),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 4)],
                    instructions: [.returnValue(.init(rawValue: 4))]
                ),
            ]
        )
    }

    private static func makeClosureImage(
        compatibility: Core.Compatibility
    ) throws -> Verification.Image {
        let shellHash = Core.Digest.sha256("helix-benchmark-closure-shell")
        let entry = Core.EntryIndex(rawValue: 0)
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.benchmark.closure",
            buildNumber: "1",
            seed: "performance-baseline"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "BenchmarkFeature",
            sourceFileLogicalID: "Sources/BenchmarkFeature.swift",
            canonicalDeclaration: "func closureTransform(_: Int) -> Int",
            loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            role: .function
        )
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            result: .int64
        )
        let root = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "closureTransform",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .int64, .closure(signature), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .constantInteger(result: .init(rawValue: 1), value: 27),
                        .makeClosure(
                            result: .init(rawValue: 2),
                            function: .init(rawValue: 1),
                            captures: [.init(rawValue: 1)]
                        ),
                        .closureApply(
                            result: .init(rawValue: 3),
                            closure: .init(rawValue: 2),
                            arguments: [.init(rawValue: 0)]
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
        let body = Bytecode.Function(
            id: .init(rawValue: 1),
            name: "closureBody",
            kind: .closureBody,
            parameterRegisters: [.init(rawValue: 0), .init(rawValue: 1)],
            resultType: .int64,
            registerTypes: [.int64, .int64, .int64, .bool, .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0), .init(rawValue: 1)],
                    instructions: [
                        .checkedBinary(
                            result: .init(rawValue: 2),
                            overflow: .init(rawValue: 3),
                            operation: .add,
                            lhs: .init(rawValue: 0),
                            rhs: .init(rawValue: 1)
                        ),
                        .conditionalBranch(
                            condition: .init(rawValue: 3),
                            trueTarget: .init(rawValue: 1),
                            trueArguments: [],
                            falseTarget: .init(rawValue: 2),
                            falseArguments: [.init(rawValue: 2)]
                        ),
                    ]
                ),
                .init(id: .init(rawValue: 1), instructions: [.trap(.integerOverflow)]),
                .init(
                    id: .init(rawValue: 2),
                    parameters: [.init(rawValue: 4)],
                    instructions: [.returnValue(.init(rawValue: 4))]
                ),
            ]
        )
        let capabilities: Set<Core.Capability> = [.baselineV1, .closureValuesV1]
        let module = Bytecode.Module(
            name: "BenchmarkClosurePatch",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            requestedResources: .init(
                maxWallTimeMainThreadMilliseconds: 1_000,
                maxWallTimeBackgroundMilliseconds: 1_000
            ),
            functions: [root, body],
            entries: [
                .init(entryIndex: entry, functionKey: key, functionID: root.id),
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
                    resultType: .int64
                ),
            ]
        )
        return try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(
                acceptedCapabilities: capabilities,
                resourceCeiling: .init(
                    maxWallTimeMainThreadMilliseconds: 1_000,
                    maxWallTimeBackgroundMilliseconds: 1_000
                )
            )
        )
    }

    private static func makeUINativeImportImage(
        compatibility: Core.Compatibility,
        namespace: Core.ShellNamespaceID
    ) throws -> (image: Verification.Image, catalog: VM.NativeCatalog) {
        let shellHash = Core.Digest.sha256("helix-benchmark-ui-native-shell")
        let entry = Core.EntryIndex(rawValue: 0)
        let importID = Core.NativeImportID(rawValue: 0)
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let effects = Core.Effects(requiresMainActor: true)
        let contract = Core.NativeImportContract.bounded(
            kind: .serviceMethod,
            domain: .uiKit,
            access: .read,
            maximumDurationMicroseconds: 2_000,
            allowsMainThread: true
        )
        let key = try Core.NativeImportKey.derive(
            namespace: namespace,
            canonicalCallee: "HelixBenchmark.UIBridge.transform(_:)",
            signature: signature,
            effects: effects,
            contract: contract
        )
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "BenchmarkFeature",
            sourceFileLogicalID: "Sources/BenchmarkFeature.swift",
            canonicalDeclaration: "func uiTransform(_: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "uiTransform",
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
                            importID: importID,
                            arguments: [.init(rawValue: 0)]
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ],
            effects: effects
        )
        let requirement = Bytecode.ImportRequirement(
            id: importID,
            key: key,
            signature: signature,
            effects: effects,
            contract: contract
        )
        let module = Bytecode.Module(
            name: "BenchmarkUINativeImport",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: [.baselineV1, .nativeImportsV1, .mainActorSyncV1],
            requestedResources: .init(
                maxWallTimeMainThreadMilliseconds: 1_000,
                maxWallTimeBackgroundMilliseconds: 1_000
            ),
            functions: [function],
            entries: [
                .init(
                    entryIndex: entry,
                    functionKey: functionKey,
                    functionID: function.id
                ),
            ],
            imports: [requirement]
        )
        let descriptor = Verification.ResolvedNativeImport(
            id: importID,
            key: key,
            parameterTypes: [.int64],
            resultType: .int64,
            signature: signature,
            effects: effects,
            contract: contract
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: [.baselineV1, .nativeImportsV1, .mainActorSyncV1],
            entries: [
                .init(
                    index: entry,
                    key: functionKey,
                    parameterTypes: [.int64],
                    resultType: .int64,
                    effects: effects
                ),
            ],
            imports: [descriptor]
        )
        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(
                acceptedCapabilities: [
                    .baselineV1,
                    .nativeImportsV1,
                    .mainActorSyncV1,
                ],
                resourceCeiling: .init(
                    maxWallTimeMainThreadMilliseconds: 1_000,
                    maxWallTimeBackgroundMilliseconds: 1_000
                ),
                allowedNativeImports: [importID],
                allowMainActorSynchronousEntries: true
            )
        )
        return (
            image,
            try VM.NativeCatalog([
                UINativeImportInvoker(
                    id: importID,
                    key: key,
                    contract: contract
                ),
            ])
        )
    }

    private struct UINativeImportInvoker: VM.NativeInvoker {
        let id: Core.NativeImportID
        let key: Core.NativeImportKey
        let contract: Core.NativeImportContract
        let parameterTypes: [Bytecode.ValueType] = [.int64]
        let resultType: Bytecode.ValueType = .int64
        let effects = Core.Effects(requiresMainActor: true)

        func invoke(
            arguments: [VM.Value],
            context: VM.NativeInvocationContext
        ) -> VM.NativeInvocationResult {
            guard case let .integer(input) = arguments.first else {
                return .businessError("UI NativeImport benchmark received a non-integer")
            }
            let (value, overflow) = input.signedValue.addingReportingOverflow(27)
            guard !overflow else { return .businessError("UI NativeImport benchmark overflow") }
            do {
                return .returned(
                    .integer(
                        try VM.Integer(
                            signed: value,
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            } catch {
                return .businessError(String(describing: error))
            }
        }
    }
}
}
