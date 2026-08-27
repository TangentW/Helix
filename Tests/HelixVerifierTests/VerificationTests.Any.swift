import HelixBytecode
import HelixCore
import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("HLBC Any verifier")
struct AnyVerifier {
    @Test("Verified Any erasure and casts require their exact capability and types")
    func acceptsValidAnyInstructions() throws {
        let function = validFunction()
        let image = try verify(
            function: function,
            capabilities: [.baselineV1, .anyValuesV1]
        )

        #expect(image.module.capabilities.contains(.anyValuesV1))
    }

    @Test("Native Any identities must name a frozen Shell type")
    func validatesNativeDynamicTypesAgainstShell() throws {
        let typeID = Core.TypeID(rawValue: .sha256("AnyVerifier.Native"))
        let nativeType = Verification.ResolvedNativeType(
            id: typeID,
            canonicalName: "Fixture.Native",
            kind: .reference,
            layoutFingerprint: .sha256("AnyVerifier.Native.Layout"),
            isCopyable: true,
            estimatedSize: 8
        )
        let function = Bytecode.Function(
            id: .init(rawValue: 0),
            name: "eraseNative",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .any,
            registerTypes: [.native(typeID), .any],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .eraseToAny(
                            result: .init(rawValue: 1),
                            value: .init(rawValue: 0),
                            dynamicType: .native(typeID)
                        ),
                        .returnValue(.init(rawValue: 1)),
                    ]
                ),
            ]
        )
        let capabilities: Set<Core.Capability> = [
            .baselineV1, .anyValuesV1, .nativeTypesV1,
        ]

        _ = try verify(
            function: function,
            moduleCapabilities: capabilities,
            shellCapabilities: capabilities,
            policyCapabilities: capabilities,
            parameterTypes: [.native(typeID)],
            resultType: .any,
            nativeTypes: [nativeType]
        )
        #expect(throws: Verification.Error.self) {
            _ = try verify(
                function: function,
                moduleCapabilities: capabilities,
                shellCapabilities: capabilities,
                policyCapabilities: capabilities,
                parameterTypes: [.native(typeID)],
                resultType: .any
            )
        }
        var noncopyable = nativeType
        noncopyable.isCopyable = false
        #expect(throws: Verification.Error.self) {
            _ = try verify(
                function: function,
                moduleCapabilities: capabilities,
                shellCapabilities: capabilities,
                policyCapabilities: capabilities,
                parameterTypes: [.native(typeID)],
                resultType: .any,
                nativeTypes: [noncopyable]
            )
        }
    }

    @Test("An Any type cannot be smuggled without the Any capability")
    func rejectsMissingCapability() throws {
        let function = validFunction()

        #expect(throws: Verification.Error.capabilityDenied(.anyValuesV1)) {
            try verify(
                function: function,
                moduleCapabilities: [.baselineV1],
                shellCapabilities: [.baselineV1, .anyValuesV1],
                policyCapabilities: [.baselineV1, .anyValuesV1]
            )
        }
    }

    @Test("Any instructions reject values outside the closed payload set")
    func rejectsUnsupportedPayloadAndTarget() throws {
        var invalidErasure = validFunction()
        invalidErasure.registerTypes.insert(.tuple([]), at: 1)
        invalidErasure.blocks[0].instructions = [
            .makeTuple(result: .init(rawValue: 1), elements: []),
            .eraseToAny(
                result: .init(rawValue: 2),
                value: .init(rawValue: 1),
                dynamicType: .tuple([])
            ),
            .returnValue(.init(rawValue: 0)),
        ]
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "erase_to_any dynamic type must match a supported VM value and Any result"
            )
        ) {
            try verify(
                function: invalidErasure,
                capabilities: [.baselineV1, .anyValuesV1]
            )
        }

        var invalidTarget = validFunction()
        invalidTarget.registerTypes[2] = .optional(.tuple([]))
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "checked_cast_any requires Any and a matching Optional<dynamic target>"
            )
        ) {
            try verify(
                function: invalidTarget,
                capabilities: [.baselineV1, .anyValuesV1]
            )
        }
    }

    @Test("Any descriptors must match their physical register storage")
    func rejectsDescriptorStorageMismatch() throws {
        var invalidErasure = validFunction()
        invalidErasure.blocks[0].instructions[0] = .eraseToAny(
            result: .init(rawValue: 1),
            value: .init(rawValue: 0),
            dynamicType: .string
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 0,
                reason: "erase_to_any dynamic type must match a supported VM value and Any result"
            )
        ) {
            try verify(
                function: invalidErasure,
                capabilities: [.baselineV1, .anyValuesV1]
            )
        }

        var invalidCheckedCast = validFunction()
        invalidCheckedCast.blocks[0].instructions[1] = .checkedCastAny(
            result: .init(rawValue: 2),
            value: .init(rawValue: 1),
            targetType: .character
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 1,
                reason: "checked_cast_any requires Any and a matching Optional<dynamic target>"
            )
        ) {
            try verify(
                function: invalidCheckedCast,
                capabilities: [.baselineV1, .anyValuesV1]
            )
        }

        var invalidForceCast = validFunction()
        invalidForceCast.blocks[0].instructions[2] = .forceCastAny(
            result: .init(rawValue: 3),
            value: .init(rawValue: 1),
            targetType: .character
        )
        #expect(
            throws: Verification.Error.invalidInstruction(
                function: .init(rawValue: 0),
                block: .init(rawValue: 0),
                offset: 2,
                reason: "force_cast_any requires Any and a matching dynamic target"
            )
        ) {
            try verify(
                function: invalidForceCast,
                capabilities: [.baselineV1, .anyValuesV1]
            )
        }
    }

    @Test("Shell Any signatures require the Any capability")
    func shellBoundaryRequiresCapability() throws {
        let compatibility = compatibility()
        let key = try functionKey(
            signature: .init(parameters: ["Swift.Any"], result: "Swift.Any")
        )
        let entry = Verification.ResolvedEntry(
            index: .init(rawValue: 0),
            key: key,
            parameterTypes: [.any],
            parameterConventions: [.owned],
            resultType: .any,
            effects: .init()
        )

        #expect(
            throws: Verification.Error.invalidShellInterface(
                "Any in entry 0 signature requires swift-any-1"
            )
        ) {
            try Verification.ShellInterface(
                interfaceHash: .sha256("any-verifier-shell"),
                compatibility: compatibility,
                capabilities: [.baselineV1],
                entries: [entry]
            )
        }
        _ = try Verification.ShellInterface(
            interfaceHash: .sha256("any-verifier-shell"),
            compatibility: compatibility,
            capabilities: [.baselineV1, .anyValuesV1],
            entries: [entry]
        )
    }

    private func validFunction() -> Bytecode.Function {
        .init(
            id: .init(rawValue: 0),
            name: "anyRoundTrip",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64, .any, .optional(.int64), .int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [
                        .eraseToAny(
                            result: .init(rawValue: 1),
                            value: .init(rawValue: 0),
                            dynamicType: .integer(.int)
                        ),
                        .checkedCastAny(
                            result: .init(rawValue: 2),
                            value: .init(rawValue: 1),
                            targetType: .integer(.int)
                        ),
                        .forceCastAny(
                            result: .init(rawValue: 3),
                            value: .init(rawValue: 1),
                            targetType: .integer(.int)
                        ),
                        .returnValue(.init(rawValue: 3)),
                    ]
                ),
            ]
        )
    }

    private func verify(
        function: Bytecode.Function,
        capabilities: Set<Core.Capability>
    ) throws -> Verification.Image {
        try verify(
            function: function,
            moduleCapabilities: capabilities,
            shellCapabilities: capabilities,
            policyCapabilities: capabilities
        )
    }

    private func verify(
        function: Bytecode.Function,
        moduleCapabilities: Set<Core.Capability>,
        shellCapabilities: Set<Core.Capability>,
        policyCapabilities: Set<Core.Capability>,
        parameterTypes: [Bytecode.ValueType] = [.int64],
        resultType: Bytecode.ValueType = .int64,
        nativeTypes: [Verification.ResolvedNativeType] = []
    ) throws -> Verification.Image {
        let signature = Core.LoweredSignature(
            parameters: parameterTypes.map(\.description),
            result: resultType.description
        )
        let key = try functionKey(signature: signature)
        let shellHash = Core.Digest.sha256("any-verifier-shell")
        let module = Bytecode.Module(
            name: "AnyVerifierFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility(),
            capabilities: moduleCapabilities,
            functions: [function],
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: key,
                    functionID: function.id
                ),
            ]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility(),
            capabilities: shellCapabilities,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: key,
                    parameterTypes: parameterTypes,
                    parameterConventions: function.parameterConventions,
                    resultType: resultType,
                    effects: function.effects
                ),
            ],
            types: nativeTypes
        )
        return try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(acceptedCapabilities: policyCapabilities)
        )
    }

    private func functionKey(
        signature: Core.LoweredSignature
    ) throws -> Core.FunctionKey {
        try .derive(
            namespace: .derive(
                bundleID: "dev.helix.any-verifier",
                buildNumber: "1",
                seed: "fixture"
            ),
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func anyRoundTrip(_ value: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
    }

    private func compatibility() -> Core.Compatibility {
        .init(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-any-verifier"
        )
    }
}
}
