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
}
}
