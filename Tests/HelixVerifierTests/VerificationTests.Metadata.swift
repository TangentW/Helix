import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("Verifier metadata")
struct Metadata {
    @Test func moduleHasVersion() {
        #expect(Verification.Metadata.version == .init(1, 0, 0))
    }

    @Test("Shell validates native callback shape and lifetime authority")
    func nativeCallbackBoundary() throws {
        let callbackSignature = Bytecode.ClosureSignature(
            parameters: [.bool],
            parameterConventions: [.owned],
            result: .void
        )
        let contract = Core.NativeImportContract.bounded(
            kind: .staticMethod,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true,
            callbacks: [.init(parameterIndex: 0, lifetime: .escaping)]
        )
        let descriptor = try nativeImport(
            id: .init(rawValue: 0),
            canonicalCallee: "Fixture.Callbacks.install(_:)",
            parameterTypes: [.optional(.closure(callbackSignature))],
            resultType: .void,
            signature: .init(
                parameters: ["((Swift.Bool) -> Swift.Void)?"],
                result: "Swift.Void"
            ),
            effects: .init(),
            contract: contract
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "callback-shell"
        )
        _ = try Verification.ShellInterface(
            interfaceHash: .sha256("callback-shell"),
            compatibility: compatibility,
            capabilities: [
                .baselineV1, .nativeImportsV1, .closureValuesV1,
                .escapingClosureValuesV1,
            ],
            imports: [try refreshed(descriptor)]
        )

        var returning = descriptor
        var returningSignature = callbackSignature
        returningSignature.result = .bool
        returning.parameterTypes = [
            .optional(.closure(returningSignature)),
        ]
        returning.signature.parameters = ["((Swift.Bool) -> Swift.Bool)?"]
        _ = try Verification.ShellInterface(
            interfaceHash: .sha256("callback-shell"),
            compatibility: compatibility,
            capabilities: [
                .baselineV1, .nativeImportsV1, .closureValuesV1,
                .escapingClosureValuesV1,
            ],
            imports: [try refreshed(returning)]
        )

        let nativeCallable = Bytecode.ClosureSignature(
            parameters: [.bool],
            parameterConventions: [.owned],
            result: .void
        )
        let higherOrderCallback = Bytecode.ClosureSignature(
            parameters: [.closure(nativeCallable)],
            parameterConventions: [.owned],
            result: .void
        )
        var higherOrder = descriptor
        higherOrder.parameterTypes = [.closure(higherOrderCallback)]
        higherOrder.signature.parameters = [
            "(@escaping (Swift.Bool) -> Swift.Void) -> Swift.Void",
        ]
        higherOrder.contract.callbacks = [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ]
        _ = try Verification.ShellInterface(
            interfaceHash: .sha256("callback-shell"),
            compatibility: compatibility,
            capabilities: [
                .baselineV1, .nativeImportsV1, .closureValuesV1,
                .escapingClosureValuesV1,
            ],
            imports: [try refreshed(higherOrder)]
        )
        #expect(throws: Verification.Error.self) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("callback-shell"),
                compatibility: compatibility,
                capabilities: [
                    .baselineV1, .nativeImportsV1, .closureValuesV1,
                ],
                imports: [try refreshed(higherOrder)]
            )
        }

        returningSignature.result = .native(
            .init(rawValue: .sha256("unsupported-native-callback-result"))
        )
        returning.parameterTypes = [
            .optional(.closure(returningSignature)),
        ]
        returning.signature.parameters = [
            "((Swift.Bool) -> UnsupportedNativeResult)?",
        ]
        #expect(throws: Verification.Error.self) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("callback-shell"),
                compatibility: compatibility,
                capabilities: [
                    .baselineV1, .nativeImportsV1, .closureValuesV1,
                    .escapingClosureValuesV1,
                ],
                imports: [try refreshed(returning)]
            )
        }

        var missingLifetime = descriptor
        missingLifetime.contract.callbacks = []
        #expect(throws: Verification.Error.self) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("callback-shell"),
                compatibility: compatibility,
                capabilities: [
                    .baselineV1, .nativeImportsV1, .closureValuesV1,
                    .escapingClosureValuesV1,
                ],
                imports: [try refreshed(missingLifetime)]
            )
        }

        var illegalNonescapingOptional = descriptor
        illegalNonescapingOptional.contract.callbacks = [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ]
        #expect(throws: Verification.Error.self) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("callback-shell"),
                compatibility: compatibility,
                capabilities: [
                    .baselineV1, .nativeImportsV1, .closureValuesV1,
                    .escapingClosureValuesV1,
                ],
                imports: [try refreshed(illegalNonescapingOptional)]
            )
        }
    }

    @Test("Shell admits only bounded native callable results")
    func nativeCallableResultBoundary() throws {
        let callable = Bytecode.ClosureSignature(
            parameters: [.bool],
            parameterConventions: [.owned],
            result: .int64
        )
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        var descriptor = try nativeImport(
            id: .init(rawValue: 0),
            canonicalCallee: "Fixture.makeCallable()",
            parameterTypes: [],
            resultType: .closure(callable),
            signature: .init(
                parameters: [],
                result: "(Swift.Bool) -> Swift.Int"
            ),
            effects: .init(),
            contract: contract
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "callable-result-shell"
        )
        let capabilities: Set<Core.Capability> = [
            .baselineV1, .nativeImportsV1, .closureValuesV1,
            .escapingClosureValuesV1,
        ]
        _ = try Verification.ShellInterface(
            interfaceHash: .sha256("callable-result-shell"),
            compatibility: compatibility,
            capabilities: capabilities,
            imports: [try refreshed(descriptor)]
        )

        descriptor.resultType = .optional(.closure(callable))
        descriptor.signature.result = "((Swift.Bool) -> Swift.Int)?"
        _ = try Verification.ShellInterface(
            interfaceHash: .sha256("callable-result-shell"),
            compatibility: compatibility,
            capabilities: capabilities,
            imports: [try refreshed(descriptor)]
        )

        for missing in [
            Core.Capability.closureValuesV1,
            Core.Capability.escapingClosureValuesV1,
        ] {
            #expect(throws: Verification.Error.self) {
                try Verification.ShellInterface(
                    interfaceHash: .sha256("callable-result-shell"),
                    compatibility: compatibility,
                    capabilities: capabilities.subtracting([missing]),
                    imports: [try refreshed(descriptor)]
                )
            }
        }

        var mainActorCallable = callable
        mainActorCallable.effects.requiresMainActor = true
        descriptor.resultType = .closure(mainActorCallable)
        descriptor.signature.result = "@MainActor (Swift.Bool) -> Swift.Int"
        #expect(throws: Verification.Error.self) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("callable-result-shell"),
                compatibility: compatibility,
                capabilities: capabilities,
                imports: [try refreshed(descriptor)]
            )
        }
        _ = try Verification.ShellInterface(
            interfaceHash: .sha256("callable-result-shell"),
            compatibility: compatibility,
            capabilities: capabilities.union([.mainActorIsolationV1]),
            imports: [try refreshed(descriptor)]
        )

        descriptor.parameterTypes = [.closure(mainActorCallable)]
        descriptor.resultType = .void
        descriptor.signature.parameters = [
            "@escaping @MainActor (Swift.Bool) -> Swift.Int",
        ]
        descriptor.signature.result = "Swift.Void"
        descriptor.contract.callbacks = [
            .init(parameterIndex: 0, lifetime: .escaping),
        ]
        #expect(throws: Verification.Error.self) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("callable-result-shell"),
                compatibility: compatibility,
                capabilities: capabilities,
                imports: [try refreshed(descriptor)]
            )
        }
        _ = try Verification.ShellInterface(
            interfaceHash: .sha256("callable-result-shell"),
            compatibility: compatibility,
            capabilities: capabilities.union([.mainActorIsolationV1]),
            imports: [try refreshed(descriptor)]
        )

        let recursive = Bytecode.ClosureSignature(
            parameters: [.closure(callable)],
            parameterConventions: [.owned],
            result: .void
        )
        descriptor.parameterTypes = []
        descriptor.resultType = .closure(recursive)
        descriptor.signature.parameters = []
        descriptor.signature.result = "((Swift.Bool) -> Swift.Int) -> Swift.Void"
        descriptor.contract.callbacks = []
        #expect(throws: Verification.Error.self) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("callable-result-shell"),
                compatibility: compatibility,
                capabilities: capabilities,
                imports: [try refreshed(descriptor)]
            )
        }
    }

    @Test("Native Error callbacks require the structured Error capability")
    func nativeErrorCallbackBoundary() throws {
        let callback = Bytecode.ClosureSignature(
            parameters: [.optional(.error)],
            parameterConventions: [.borrowed],
            result: .void
        )
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true,
            callbacks: [.init(parameterIndex: 0, lifetime: .escaping)]
        )
        let descriptor = try nativeImport(
            id: .init(rawValue: 0),
            canonicalCallee: "Fixture.installErrorCallback(_:)",
            parameterTypes: [.closure(callback)],
            resultType: .void,
            signature: .init(
                parameters: ["@escaping ((any Swift.Error)?) -> Swift.Void"],
                result: "Swift.Void"
            ),
            effects: .init(),
            contract: contract
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "error-callback-shell"
        )
        let baseCapabilities: Set<Core.Capability> = [
            .baselineV1, .nativeImportsV1, .closureValuesV1,
            .escapingClosureValuesV1,
        ]
        #expect(throws: Verification.Error.self) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("error-callback-shell"),
                compatibility: compatibility,
                capabilities: baseCapabilities,
                imports: [descriptor]
            )
        }
        _ = try Verification.ShellInterface(
            interfaceHash: .sha256("error-callback-shell"),
            compatibility: compatibility,
            capabilities: baseCapabilities.union([.structuredErrorsV1]),
            imports: [descriptor]
        )

        var ordinaryParameter = descriptor
        ordinaryParameter.parameterTypes = [.optional(.error)]
        ordinaryParameter.signature.parameters = ["(any Swift.Error)?"]
        ordinaryParameter.contract.callbacks = []
        #expect(throws: Verification.Error.self) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("error-callback-shell"),
                compatibility: compatibility,
                capabilities: baseCapabilities.union([.structuredErrorsV1]),
                imports: [try refreshed(ordinaryParameter)]
            )
        }

        var ordinaryResult = descriptor
        ordinaryResult.parameterTypes = []
        ordinaryResult.signature.parameters = []
        ordinaryResult.contract.callbacks = []
        ordinaryResult.resultType = .optional(.error)
        ordinaryResult.signature.result = "(any Swift.Error)?"
        #expect(throws: Verification.Error.self) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("error-callback-shell"),
                compatibility: compatibility,
                capabilities: baseCapabilities.union([.structuredErrorsV1]),
                imports: [try refreshed(ordinaryResult)]
            )
        }
    }

    private func nativeImport(
        id: Core.NativeImportID,
        canonicalCallee: String,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        signature: Core.LoweredSignature,
        effects: Core.Effects,
        contract: Core.NativeImportContract
    ) throws -> Verification.ResolvedNativeImport {
        let call = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: canonicalCallee,
            signature: signature,
            effects: effects,
            contract: contract
        )
        return .init(
            id: id,
            key: try Core.NativeCall.Key.derive(descriptor: call),
            descriptor: call,
            parameterTypes: parameterTypes,
            resultType: resultType,
            contract: contract
        )
    }

    private func refreshed(
        _ value: Verification.ResolvedNativeImport
    ) throws -> Verification.ResolvedNativeImport {
        var result = value
        let nonescaping = Set(result.contract.callbacks.compactMap {
            $0.lifetime == .nonescaping ? Int($0.parameterIndex) : nil
        })
        result.descriptor.physicalSignature.parameters = result.signature
            .parameters.enumerated().map { index, type in
                .init(
                    type: .bridgeValue(type),
                    ownership: nonescaping.contains(index) ? .borrowed : .owned,
                    source: .argument(UInt16(index))
                )
            }
        let resultSpelling = result.signature.result
        result.descriptor.physicalSignature.result = [
            "()", "Void", "Swift.Void",
        ].contains(resultSpelling) ? .void : .bridgeValue(resultSpelling)
        result.descriptor.physicalSignature.resultConvention = .direct
        result.descriptor.physicalSignature.errorConvention = result.signature
            .isThrowing ? .swiftThrows : .none
        result.descriptor = try result.descriptor.canonicalized()
        result.key = try Core.NativeCall.Key.derive(
            descriptor: result.descriptor
        )
        return result
    }
}
}
