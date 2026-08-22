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
        let descriptor = Verification.ResolvedNativeImport(
            id: .init(rawValue: 0),
            key: .init(rawValue: .sha256("callback-import")),
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
            imports: [descriptor]
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
            imports: [returning]
        )

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
                imports: [returning]
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
                imports: [missingLifetime]
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
                imports: [illegalNonescapingOptional]
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
        let descriptor = Verification.ResolvedNativeImport(
            id: .init(rawValue: 0),
            key: .init(rawValue: .sha256("error-callback-import")),
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
                imports: [ordinaryParameter]
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
                imports: [ordinaryResult]
            )
        }
    }
}
}
