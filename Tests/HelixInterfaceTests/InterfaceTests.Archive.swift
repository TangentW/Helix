import Foundation
import HelixBytecode
import HelixCore
import Testing
@testable import HelixInterface

enum InterfaceTests {}

extension InterfaceTests {
@Suite("HLXI release interface archive")
struct Archive {
    @Test("The archive is canonical, bounded, and tamper evident")
    func canonicalRoundTrip() throws {
        let archive = try fixture()
        let first = try InterfaceArchive.Codec.encode(archive)
        let second = try InterfaceArchive.Codec.encode(archive)
        #expect(first == second)
        #expect(Array(first.prefix(8)) == InterfaceArchive.Codec.magic)

        let decoded = try InterfaceArchive.Codec.decode(first)
        #expect(decoded.archive == archive.normalized())
        #expect(decoded.archive.shellInterfaceHash == archive.shellInterfaceHash)

        var tampered = first
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        #expect(throws: InterfaceArchive.Error.payloadHashMismatch) {
            try InterfaceArchive.Codec.decode(tampered)
        }
        #expect(throws: InterfaceArchive.Error.fileTooLarge(actual: first.count, maximum: first.count - 1)) {
            try InterfaceArchive.Codec.decode(
                first,
                limits: .init(maximumFileBytes: first.count - 1, maximumPayloadBytes: first.count)
            )
        }
    }

    @Test("Schema 3 remains readable but cannot carry schema-4 ABI adapters")
    func preservesSchemaThreeArchiveCompatibility() throws {
        var legacy = try fixture()
        legacy.schemaVersion = 3

        let bytes = try InterfaceArchive.Codec.encode(legacy)
        let decoded = try InterfaceArchive.Codec.decode(bytes)
        #expect(decoded.archive == legacy.normalized())
        #expect(decoded.archive.schemaVersion == 3)

        let signature = Core.LoweredSignature(parameters: [], result: "Swift.Int")
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let key = try Core.NativeImportKey.derive(
            namespace: legacy.metadata.shellNamespaceID,
            canonicalCallee: "Fixture.schemaFourOnly()",
            signature: signature,
            effects: .init(),
            contract: contract
        )
        legacy.nativeImports = [
            .init(
                id: nil,
                key: key,
                canonicalCallee: "Fixture.schemaFourOnly()",
                silMangledNames: ["$s7Fixture14schemaFourOnlySiyF"],
                parameterTypes: [],
                resultType: .int64,
                signature: signature,
                effects: .init(),
                contract: contract,
                isEmittedToDevice: false,
                abiAdapter: .direct
            ),
        ]

        #expect(throws: InterfaceArchive.Error.invalidArchive(
            "NativeImport ABI adapters require HLXI archive schema 4"
        )) {
            try InterfaceArchive.Codec.encode(legacy)
        }
    }

    @Test("Server-only candidates do not enter the device interface hash")
    func candidateImportIsNotDeviceAuthority() throws {
        let original = try fixture()
        let namespace = original.metadata.shellNamespaceID
        let signature = Core.LoweredSignature(parameters: [], result: "Swift.Int")
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let key = try Core.NativeImportKey.derive(
            namespace: namespace,
            canonicalCallee: "Secret.unapproved()",
            signature: signature,
            effects: .init(),
            contract: contract
        )
        var candidate = original
        candidate.nativeImports.append(
            .init(
                id: nil,
                key: key,
                canonicalCallee: "Secret.unapproved()",
                silMangledNames: ["$s6Secret10unapprovedSiyF"],
                parameterTypes: [],
                resultType: .int64,
                signature: signature,
                effects: .init(),
                contract: contract,
                isEmittedToDevice: false
            )
        )
        #expect(try candidate.computeShellInterfaceHash() == original.shellInterfaceHash)
    }

    @Test("Frontend replay arguments cannot override outputs or load compiler code")
    func rejectsUnsafeFrontendArguments() throws {
        var archive = try fixture()
        archive.metadata.frontendInvocation.semanticArguments = ["-Xfrontend", "-load-library"]

        #expect(throws: InterfaceArchive.Error.invalidArchive(
            "unsafe or reserved frontend argument -load-library"
        )) {
            try archive.validate()
        }
    }

    @Test("Native layout metadata participates in the device interface hash")
    func nativeLayoutChangesInterfaceHash() throws {
        let original = try fixture()
        let typeID = Core.TypeID.derive(
            namespace: original.metadata.shellNamespaceID,
            canonicalType: "Fixture.Point"
        )
        var first = original
        first.capabilities.append(.nativeTypesV1)
        first.nativeTypes = [
            .init(
                id: typeID,
                canonicalName: "Fixture.Point",
                kind: .value,
                layoutFingerprint: .sha256("Fixture.Point.layout.v1"),
                isCopyable: true,
                isEmittedToDevice: true,
                estimatedSize: 16
            ),
        ]
        var changed = first
        changed.nativeTypes[0].layoutFingerprint = .sha256("Fixture.Point.layout.v2")

        #expect(try first.computeShellInterfaceHash() != changed.computeShellInterfaceHash())
    }

    @Test("Fallback policy participates in the device interface hash")
    func fallbackPolicyChangesInterfaceHash() throws {
        let original = try fixture()
        var changed = original
        changed.functions[0].fallbackAllowed = true

        #expect(try original.computeShellInterfaceHash() != changed.computeShellInterfaceHash())
    }

    @Test("HLXI 2.3 preserves its device projection hash domain")
    func legacyDeviceProjectionHashDomain() throws {
        var legacy = try fixture()
        legacy.compatibility.bytecode = .init(1, 8, 0)
        legacy.compatibility.interfaceArchive = .init(2, 3, 0)
        legacy.shellInterfaceHash = try legacy.computeShellInterfaceHash()

        // This value was produced by the released HLXI.DeviceProjection.v2
        // contract. A 2.4 Runtime must validate it without re-identifying the
        // historical Shell under the v3 async authority domain.
        #expect(
            legacy.shellInterfaceHash.hex
                == "77af57e8316e5dbbe80040f3b5adb953bbe073e7d43f7f4dd85b07b2a57b07b9"
        )
        let bytes = try InterfaceArchive.Codec.encode(legacy)
        #expect(try InterfaceArchive.Codec.decode(bytes).archive == legacy.normalized())
    }

    @Test("Device types and effects require their frozen HLBC and HLXI versions")
    func deviceFeaturesRequireCurrentCompatibility() throws {
        let oldStringBytecode = try featureArchive(
            parameterType: .string,
            canonicalParameter: "Swift.String",
            capabilities: [.stringsV1],
            bytecode: .init(1, 0, 0)
        )
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "Float, String, and Array device types require HLBC 1.1 compatibility"
            )
        ) {
            try oldStringBytecode.validate()
        }

        let oldThrowsBytecode = try featureArchive(
            parameterType: .int64,
            canonicalParameter: "Swift.Int",
            effects: .init(mayThrow: true),
            capabilities: [.untypedThrowsV1],
            bytecode: .init(1, 1, 0)
        )
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "throwing device effects require HLBC 1.2 compatibility"
            )
        ) {
            try oldThrowsBytecode.validate()
        }

        let oldBytecode = try dictionaryArchive(
            bytecode: .init(1, 2, 0),
            interfaceArchive: .init(2, 1, 0)
        )
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "Dictionary device types require HLBC 1.3 compatibility"
            )
        ) {
            try oldBytecode.validate()
        }

        let oldArchive = try dictionaryArchive(
            bytecode: .init(1, 3, 0),
            interfaceArchive: .init(2, 0, 0)
        )
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "Dictionary device types require HLXI 2.1 compatibility"
            )
        ) {
            try oldArchive.validate()
        }

        try dictionaryArchive(
            bytecode: .init(1, 3, 0),
            interfaceArchive: .init(2, 1, 0)
        ).validate()

        var oldLocalNominals = try fixture()
        oldLocalNominals.capabilities.append(contentsOf: [
            .localNominalsV1, .structuredErrorsV1,
        ])
        oldLocalNominals.compatibility.bytecode = .init(1, 5, 0)
        oldLocalNominals.shellInterfaceHash = try oldLocalNominals.computeShellInterfaceHash()
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "local nominal and structured Error capabilities require HLBC 1.6 compatibility"
            )
        ) {
            try oldLocalNominals.validate()
        }

        var oldAddresses = try fixture()
        oldAddresses.capabilities.append(contentsOf: [
            .addressValuesV1, .borrowCallsV1,
        ])
        oldAddresses.compatibility.bytecode = .init(1, 6, 0)
        oldAddresses.shellInterfaceHash = try oldAddresses.computeShellInterfaceHash()
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "address and borrowed-call capabilities require HLBC 1.7 compatibility"
            )
        ) {
            try oldAddresses.validate()
        }

        var oldClosureBytecode = try fixture()
        oldClosureBytecode.capabilities.append(contentsOf: [
            .closureValuesV1, .escapingClosureValuesV1,
            .compilerSpecializationsV1,
        ])
        oldClosureBytecode.compatibility.bytecode = .init(1, 7, 0)
        oldClosureBytecode.shellInterfaceHash = try oldClosureBytecode
            .computeShellInterfaceHash()
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "closure and compiler-specialization capabilities require HLBC 1.8 and HLXI 2.3 compatibility"
            )
        ) {
            try oldClosureBytecode.validate()
        }

        var oldClosureArchive = try fixture()
        oldClosureArchive.capabilities.append(contentsOf: [
            .closureValuesV1, .escapingClosureValuesV1,
            .compilerSpecializationsV1,
        ])
        oldClosureArchive.compatibility.interfaceArchive = .init(2, 2, 0)
        oldClosureArchive.shellInterfaceHash = try oldClosureArchive
            .computeShellInterfaceHash()
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "closure and compiler-specialization capabilities require HLBC 1.8 and HLXI 2.3 compatibility"
            )
        ) {
            try oldClosureArchive.validate()
        }

        var asyncArchive = try fixture()
        let asyncSignature = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int",
            isAsync: true
        )
        asyncArchive.functions[0].canonicalDeclaration =
            "func transform(_: Int) async -> Int"
        asyncArchive.functions[0].loweredSignature = asyncSignature
        asyncArchive.functions[0].effects.isAsync = true
        asyncArchive.functions[0].key = try Core.FunctionKey.derive(
            namespace: asyncArchive.metadata.shellNamespaceID,
            module: asyncArchive.functions[0].moduleName,
            sourceFileLogicalID: asyncArchive.functions[0].sourceFileLogicalID,
            canonicalDeclaration: asyncArchive.functions[0].canonicalDeclaration,
            loweredSignature: asyncSignature,
            role: asyncArchive.functions[0].role
        )
        asyncArchive.capabilities.append(.asyncLeafEntriesV1)
        asyncArchive.shellInterfaceHash = try asyncArchive.computeShellInterfaceHash()
        try asyncArchive.validate()

        var oldAsyncBytecode = asyncArchive
        oldAsyncBytecode.compatibility.bytecode = .init(1, 8, 0)
        oldAsyncBytecode.shellInterfaceHash = try oldAsyncBytecode.computeShellInterfaceHash()
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "async leaf entries require HLBC 1.9 and HLXI 2.4 compatibility"
            )
        ) {
            try oldAsyncBytecode.validate()
        }

        var oldAsyncArchive = asyncArchive
        oldAsyncArchive.compatibility.interfaceArchive = .init(2, 3, 0)
        oldAsyncArchive.shellInterfaceHash = try oldAsyncArchive.computeShellInterfaceHash()
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "async leaf entries require HLBC 1.9 and HLXI 2.4 compatibility"
            )
        ) {
            try oldAsyncArchive.validate()
        }

        var mismatchedAsync = asyncArchive
        mismatchedAsync.functions[0].loweredSignature.isAsync = false
        mismatchedAsync.functions[0].key = try Core.FunctionKey.derive(
            namespace: mismatchedAsync.metadata.shellNamespaceID,
            module: mismatchedAsync.functions[0].moduleName,
            sourceFileLogicalID: mismatchedAsync.functions[0].sourceFileLogicalID,
            canonicalDeclaration: mismatchedAsync.functions[0].canonicalDeclaration,
            loweredSignature: mismatchedAsync.functions[0].loweredSignature,
            role: mismatchedAsync.functions[0].role
        )
        mismatchedAsync.shellInterfaceHash = try mismatchedAsync.computeShellInterfaceHash()
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "function lowered signature and effects disagree"
            )
        ) {
            try mismatchedAsync.validate()
        }

        let anyArchive = try featureArchive(
            parameterType: .any,
            canonicalParameter: "Swift.Any",
            capabilities: [.anyValuesV1],
            bytecode: .init(1, 10, 0)
        )
        try anyArchive.validate()

        var oldAnyBytecode = anyArchive
        oldAnyBytecode.compatibility.bytecode = .init(1, 9, 0)
        oldAnyBytecode.shellInterfaceHash = try oldAnyBytecode
            .computeShellInterfaceHash()
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "Any values require HLBC 1.10 and HLXI 2.5 compatibility"
            )
        ) {
            try oldAnyBytecode.validate()
        }

        var oldAnyArchive = anyArchive
        oldAnyArchive.compatibility.interfaceArchive = .init(2, 4, 0)
        oldAnyArchive.shellInterfaceHash = try oldAnyArchive
            .computeShellInterfaceHash()
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "Any values require HLBC 1.10 and HLXI 2.5 compatibility"
            )
        ) {
            try oldAnyArchive.validate()
        }

        var inoutEntry = try fixture()
        inoutEntry.capabilities.append(.addressValuesV1)
        inoutEntry.functions[0].parameterConventions = [.inout]
        inoutEntry.shellInterfaceHash = try inoutEntry.computeShellInterfaceHash()
        #expect(
            throws: InterfaceArchive.Error.invalidArchive(
                "Shell entry signatures cannot contain inout parameters"
            )
        ) {
            try inoutEntry.validate()
        }
    }

    private func featureArchive(
        parameterType: Bytecode.ValueType,
        canonicalParameter: String,
        effects: Core.Effects = .init(),
        capabilities: [Core.Capability],
        bytecode: Core.SemanticVersion
    ) throws -> InterfaceArchive.Archive {
        var archive = try fixture()
        let isThrowing = effects.mayThrow
        let signature = Core.LoweredSignature(
            parameters: [canonicalParameter],
            result: "Swift.Int",
            isThrowing: isThrowing
        )
        archive.functions[0].canonicalDeclaration = isThrowing
            ? "func transform(_: Int) throws -> Int"
            : "func transform(_: \(canonicalParameter)) -> Int"
        archive.functions[0].loweredSignature = signature
        archive.functions[0].parameterTypes = [parameterType]
        archive.functions[0].effects = effects
        archive.functions[0].key = try Core.FunctionKey.derive(
            namespace: archive.metadata.shellNamespaceID,
            module: archive.functions[0].moduleName,
            sourceFileLogicalID: archive.functions[0].sourceFileLogicalID,
            canonicalDeclaration: archive.functions[0].canonicalDeclaration,
            loweredSignature: signature,
            role: archive.functions[0].role
        )
        archive.capabilities.append(contentsOf: capabilities)
        archive.compatibility.bytecode = bytecode
        archive.shellInterfaceHash = try archive.computeShellInterfaceHash()
        return archive
    }

    private func dictionaryArchive(
        bytecode: Core.SemanticVersion,
        interfaceArchive: Core.SemanticVersion
    ) throws -> InterfaceArchive.Archive {
        var archive = try fixture()
        let dictionaryType = Bytecode.ValueType.dictionary(
            key: .string,
            value: .int64
        )
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Dictionary<Swift.String, Swift.Int>"],
            result: "Swift.Int"
        )
        archive.functions[0].canonicalDeclaration =
            "func transform(_: [String: Int]) -> Int"
        archive.functions[0].loweredSignature = signature
        archive.functions[0].parameterTypes = [dictionaryType]
        archive.functions[0].key = try Core.FunctionKey.derive(
            namespace: archive.metadata.shellNamespaceID,
            module: archive.functions[0].moduleName,
            sourceFileLogicalID: archive.functions[0].sourceFileLogicalID,
            canonicalDeclaration: archive.functions[0].canonicalDeclaration,
            loweredSignature: signature,
            role: archive.functions[0].role
        )
        archive.capabilities.append(contentsOf: [.stringsV1, .collectionsV1])
        archive.compatibility.bytecode = bytecode
        archive.compatibility.interfaceArchive = interfaceArchive
        archive.shellInterfaceHash = try archive.computeShellInterfaceHash()
        return archive
    }

    private func fixture() throws -> InterfaceArchive.Archive {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.interface",
            buildNumber: "42",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func transform(_: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.interface",
            buildNumber: "42",
            shellNamespaceID: namespace,
            machOUUIDs: [UUID(uuidString: "11111111-2222-3333-4444-555555555555")!],
            targetTriple: "arm64-apple-ios15.0",
            minimumOS: .init(15),
            xcodeBuild: "18A1",
            sdkBuild: "24A1",
            frontendInvocation: .init(
                moduleName: "Fixture",
                targetTriple: "arm64-apple-ios15.0",
                sdkName: "iphoneos",
                sdkBuild: "24A1"
            ),
            transformPipelineHash: .sha256("transform"),
            sourceBaselineHash: .sha256("baseline")
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-interface-fixture"
        )
        let function = InterfaceArchive.FunctionRecord(
            key: key,
            entryIndex: .init(rawValue: 0),
            moduleName: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func transform(_: Int) -> Int",
            mangledName: "$s7Fixture9transformyS2iF",
            role: .function,
            loweredSignature: signature,
            parameterTypes: [.int64],
            resultType: .int64,
            effects: .init(),
            interfaceFingerprint: .sha256("interface"),
            bodyFingerprint: .sha256("body"),
            patchability: .eligible,
            bridgeSymbol: "hlx_entry_0"
        )
        return try .make(
            metadata: metadata,
            compatibility: compatibility,
            capabilities: [.baselineV1],
            sources: [.init(logicalPath: "Sources/Fixture.swift", contentHash: .sha256("source"))],
            functions: [function],
            bridgeRegistrationCount: 1
        )
    }
}
}
