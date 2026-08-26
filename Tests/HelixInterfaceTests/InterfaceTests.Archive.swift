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

    @Test("Only the current HLXI schema and compatibility tuple are accepted")
    func schemaAndCompatibilityAreExact() throws {
        var bytes = try InterfaceArchive.Codec.encode(fixture())
        bytes[8] = 2
        #expect(throws: InterfaceArchive.Error.unsupportedSchema(2)) {
            try InterfaceArchive.Codec.decode(bytes)
        }

        var wrongSchema = try fixture()
        wrongSchema.schemaVersion = 2
        #expect(throws: InterfaceArchive.Error.unsupportedSchema(2)) {
            try InterfaceArchive.Codec.encode(wrongSchema)
        }

        var wrongCompatibility = try fixture()
        wrongCompatibility.compatibility.interfaceArchive = .init(1, 1, 0)
        wrongCompatibility.shellInterfaceHash =
            try wrongCompatibility.computeShellInterfaceHash()
        #expect(throws: InterfaceArchive.Error.invalidArchive(
            "archive compatibility must match the current Helix 1.0 formats"
        )) {
            try wrongCompatibility.validate()
        }
    }

    @Test("Server-only candidates do not enter the device interface hash")
    func candidateImportIsNotDeviceAuthority() throws {
        let original = try fixture()
        let signature = Core.LoweredSignature(parameters: [], result: "Swift.Int")
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Secret.unapproved()",
            signature: signature,
            effects: .init(),
            contract: contract
        )
        let key = try Core.NativeCall.Key.derive(descriptor: descriptor)
        var candidate = original
        candidate.nativeImports.append(
            .init(
                id: nil,
                key: key,
                descriptor: descriptor,
                silMangledNames: ["$s6Secret10unapprovedSiyF"],
                parameterTypes: [],
                resultType: .int64,
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
        changed.nativeTypes[0].layoutFingerprint = .sha256("Fixture.Point.layout.changed")

        #expect(try first.computeShellInterfaceHash() != changed.computeShellInterfaceHash())
    }

    @Test("Swift native aliases remain server-side compiler metadata")
    func nativeAliasesDoNotChangeDeviceInterface() throws {
        var original = try fixture()
        let canonicalName = "NSURLSessionDataTask"
        let typeID = Core.TypeID.derive(
            namespace: original.metadata.shellNamespaceID,
            canonicalType: canonicalName
        )
        original.capabilities.append(.nativeTypesV1)
        original.nativeTypes = [
            .init(
                id: typeID,
                canonicalName: canonicalName,
                kind: .reference,
                layoutFingerprint: .sha256("NSURLSessionDataTask.layout"),
                isCopyable: true,
                isEmittedToDevice: true,
                estimatedSize: 8
            ),
        ]
        original.shellInterfaceHash = try original.computeShellInterfaceHash()

        var aliased = original
        aliased.nativeTypes[0].swiftTypeAliases = [
            "URLSessionDataTask", "URLSessionDataTask", canonicalName,
        ]
        aliased = aliased.normalized()
        aliased.shellInterfaceHash = try aliased.computeShellInterfaceHash()

        #expect(aliased.nativeTypes[0].swiftTypeAliases == [
            "URLSessionDataTask",
        ])
        #expect(aliased.shellInterfaceHash == original.shellInterfaceHash)
        try aliased.validate()
        let decoded = try InterfaceArchive.Codec.decode(
            InterfaceArchive.Codec.encode(aliased)
        ).archive
        #expect(decoded.nativeTypes[0].swiftTypeAliases == [
            "URLSessionDataTask",
        ])

        var oversized = aliased
        oversized.nativeTypes[0].swiftTypeAliases = [
            String(repeating: "A", count: 1_025),
        ]
        #expect(throws: InterfaceArchive.Error.invalidArchive(
            "native type identity or alias metadata is invalid"
        )) {
            try oversized.validate()
        }
    }

    @Test("Fallback policy participates in the device interface hash")
    func fallbackPolicyChangesInterfaceHash() throws {
        let original = try fixture()
        var changed = original
        changed.functions[0].fallbackAllowed = true

        #expect(try original.computeShellInterfaceHash() != changed.computeShellInterfaceHash())
    }

    @Test("Frozen Shell value layouts are canonical, hashed, bounded, and fail closed")
    func frozenValueLayoutContract() throws {
        let counterKey = Bytecode.LocalTypeKey(rawValue: "Counter")
        let modeKey = Bytecode.LocalTypeKey(rawValue: "Mode")
        let mode = try InterfaceArchive.FrozenValueTypeRecord(
            key: modeKey,
            canonicalName: "Fixture.Mode",
            sourceFileLogicalID: "Sources/Fixture.swift",
            kind: .enumeration(cases: [
                .init(name: "idle"),
                .init(name: "count", associatedValues: [
                    .init(swiftType: "Swift.Int", type: .int64),
                ]),
                .init(name: "named", associatedValues: [
                    .init(label: "label", swiftType: "Swift.String", type: .string),
                ]),
            ])
        )
        let counter = try InterfaceArchive.FrozenValueTypeRecord(
            key: counterKey,
            canonicalName: "Fixture.Counter",
            sourceFileLogicalID: "Sources/Fixture.swift",
            kind: .structure(fields: [
                .init(name: "value", swiftType: "Swift.Int", type: .int64),
                .init(name: "mode", swiftType: "Mode", type: .local(modeKey)),
                .init(
                    name: "tags",
                    swiftType: "Swift.Array<Swift.String>",
                    type: .array(.string)
                ),
            ])
        )

        func archive(
            records: [InterfaceArchive.FrozenValueTypeRecord]
        ) throws -> InterfaceArchive.Archive {
            var value = try fixture()
            value.capabilities.append(contentsOf: [
                .collectionsV1, .localNominalsV1, .stringsV1,
            ])
            value.frozenValueTypes = records.sorted { $0.key < $1.key }
            value.functions[0].canonicalDeclaration =
                "func inspect(_: Counter) -> Int"
            value.functions[0].loweredSignature = .init(
                parameters: ["Fixture.Counter"],
                result: "Swift.Int"
            )
            value.functions[0].parameterTypes = [.local(counterKey)]
            value.functions[0].parameterConventions = [.owned]
            value.functions[0].key = try Core.FunctionKey.derive(
                namespace: value.metadata.shellNamespaceID,
                module: "Fixture",
                sourceFileLogicalID: "Sources/Fixture.swift",
                canonicalDeclaration: value.functions[0].canonicalDeclaration,
                loweredSignature: value.functions[0].loweredSignature,
                role: .function
            )
            value.shellInterfaceHash = try value.computeShellInterfaceHash()
            return value
        }

        let original = try archive(records: [counter, mode])
        try original.validate()
        let decoded = try InterfaceArchive.Codec.decode(
            InterfaceArchive.Codec.encode(original)
        ).archive
        #expect(decoded.frozenValueTypes == [counter, mode].sorted { $0.key < $1.key })
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.compatibility.interfaceArchive == .init(1, 0, 0))

        let equalWidthSpelling = try InterfaceArchive.FrozenValueTypeRecord(
            key: counterKey,
            canonicalName: "Fixture.Counter",
            sourceFileLogicalID: "Sources/Fixture.swift",
            kind: .structure(fields: [
                .init(name: "value", swiftType: "Swift.Int64", type: .int64),
                .init(name: "mode", swiftType: "Mode", type: .local(modeKey)),
                .init(
                    name: "tags",
                    swiftType: "Swift.Array<Swift.String>",
                    type: .array(.string)
                ),
            ])
        )
        let changed = try archive(records: [equalWidthSpelling, mode])
        #expect(original.shellInterfaceHash != changed.shellInterfaceHash)

        var missingCollections = original
        missingCollections.capabilities.removeAll { $0 == .collectionsV1 }
        missingCollections.shellInterfaceHash = try missingCollections
            .computeShellInterfaceHash()
        #expect(throws: InterfaceArchive.Error.self) {
            try missingCollections.validate()
        }

        let recursive = try InterfaceArchive.FrozenValueTypeRecord(
            key: counterKey,
            canonicalName: "Fixture.Counter",
            sourceFileLogicalID: "Sources/Fixture.swift",
            kind: .structure(fields: [
                .init(name: "next", swiftType: "Counter", type: .local(counterKey)),
            ])
        )
        #expect(throws: InterfaceArchive.Error.self) {
            try archive(records: [recursive]).validate()
        }

        var deeplyNested: [InterfaceArchive.FrozenValueTypeRecord] = []
        for offset in (0..<17).reversed() {
            let key = offset == 0
                ? counterKey
                : Bytecode.LocalTypeKey(rawValue: "Depth\(offset)")
            let field: InterfaceArchive.FrozenStoredProperty
            if offset == 16 {
                field = .init(
                    name: "value",
                    swiftType: "Swift.Int",
                    type: .int64
                )
            } else {
                let next = Bytecode.LocalTypeKey(rawValue: "Depth\(offset + 1)")
                field = .init(
                    name: "next",
                    swiftType: "Depth\(offset + 1)?",
                    type: .optional(.local(next))
                )
            }
            deeplyNested.append(try .init(
                key: key,
                canonicalName: "Fixture.\(key.rawValue)",
                sourceFileLogicalID: "Sources/Fixture.swift",
                kind: .structure(fields: [field])
            ))
        }
        #expect(throws: InterfaceArchive.Error.self) {
            try archive(records: deeplyNested).validate()
        }

        let errorMode = try InterfaceArchive.FrozenValueTypeRecord(
            key: modeKey,
            canonicalName: "Fixture.Mode",
            sourceFileLogicalID: "Sources/Fixture.swift",
            kind: mode.kind,
            conformsToError: true
        )
        #expect(throws: InterfaceArchive.Error.self) {
            try archive(records: [counter, errorMode]).validate()
        }
        var structuredError = try archive(records: [counter, errorMode])
        structuredError.capabilities.append(.structuredErrorsV1)
        structuredError.shellInterfaceHash = try structuredError
            .computeShellInterfaceHash()
        try structuredError.validate()

        let native = try InterfaceArchive.FrozenValueTypeRecord(
            key: counterKey,
            canonicalName: "Fixture.Counter",
            sourceFileLogicalID: "Sources/Fixture.swift",
            kind: .structure(fields: [
                .init(
                    name: "object",
                    swiftType: "Fixture.Object",
                    type: .native(.init(rawValue: .sha256("Fixture.Object")))
                ),
            ])
        )
        #expect(throws: InterfaceArchive.Error.self) {
            try archive(records: [native]).validate()
        }

        let unsafe = try InterfaceArchive.FrozenValueTypeRecord(
            key: counterKey,
            canonicalName: "Fixture.Counter",
            sourceFileLogicalID: "Sources/Fixture.swift",
            kind: .structure(fields: [
                .init(name: "value; fatalError()", swiftType: "Swift.Int", type: .int64),
            ])
        )
        #expect(!unsafe.hasSafeSourceCodecShape)
        #expect(throws: InterfaceArchive.Error.self) {
            try archive(records: [unsafe]).validate()
        }

        let noncopyable = try InterfaceArchive.FrozenValueTypeRecord(
            key: counterKey,
            canonicalName: "Fixture.Counter",
            sourceFileLogicalID: "Sources/Fixture.swift",
            kind: .structure(fields: []),
            isCopyable: false
        )
        #expect(throws: InterfaceArchive.Error.self) {
            try archive(records: [noncopyable]).validate()
        }
    }

    @Test("Native callback contracts survive archive validation and hashing")
    func nativeCallbackContractRoundTrip() throws {
        var archive = try fixture()
        let callback = Bytecode.ClosureSignature(
            parameters: [.bool],
            parameterConventions: [.owned],
            result: .void
        )
        let signature = Core.LoweredSignature(
            parameters: ["@escaping (Swift.Bool) -> Swift.Void"],
            result: "Swift.Void"
        )
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true,
            callbacks: [.init(parameterIndex: 0, lifetime: .escaping)]
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.install(_:)",
            signature: signature,
            effects: .init(),
            contract: contract,
            physicalParameterTypes: [
                "Swift.Any",
                "Swift.Optional<Swift.Int>",
                signature.parameters[0],
            ],
            physicalArgumentSources: [
                .defaultGenerator("$s7Fixture7installFfA_"),
                .optionalNone,
                .argument(0),
            ]
        )
        let key = try Core.NativeCall.Key.derive(descriptor: descriptor)
        archive.capabilities += [
            .nativeImportsV1, .closureValuesV1, .escapingClosureValuesV1,
        ]
        let projection = InterfaceArchive.NativeImportParameterProjection(
            physicalParameterCount: 3,
            logicalParameterIndices: [2],
            defaultArguments: [
                .externalGenerator(
                    physicalParameterIndex: 0,
                    symbol: "$s7Fixture7installFfA_"
                ),
                .optionalNone(physicalParameterIndex: 1),
            ]
        )
        archive.nativeImports = [
            .init(
                id: .init(rawValue: 0),
                key: key,
                descriptor: descriptor,
                silMangledNames: ["$s7Fixture7installyyySbccF"],
                parameterTypes: [.closure(callback)],
                parameterProjection: projection,
                resultType: .void,
                contract: contract,
                isEmittedToDevice: true
            ),
        ]
        archive.shellInterfaceHash = try archive.computeShellInterfaceHash()

        try archive.validate()
        let decoded = try InterfaceArchive.Codec.decode(
            InterfaceArchive.Codec.encode(archive)
        ).archive
        #expect(decoded.nativeImports[0].contract.callbacks == contract.callbacks)
        #expect(decoded.nativeImports[0].parameterProjection == projection)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.compatibility.interfaceArchive == .init(1, 0, 0))

        var returning = archive
        var returningCallback = callback
        returningCallback.result = .bool
        returning.nativeImports[0].parameterTypes = [
            .closure(returningCallback),
        ]
        returning.nativeImports[0].signature.parameters = [
            "@escaping (Swift.Bool) -> Swift.Bool",
        ]
        returning.nativeImports[0].key = try Core.NativeCall.Key.derive(
            descriptor: returning.nativeImports[0].descriptor
        )
        returning.shellInterfaceHash = try returning.computeShellInterfaceHash()
        try returning.validate()

        returningCallback.result = .native(
            .init(rawValue: .sha256("unsupported-native-callback-result"))
        )
        returning.nativeImports[0].parameterTypes = [
            .closure(returningCallback),
        ]
        returning.nativeImports[0].signature.parameters = [
            "@escaping (Swift.Bool) -> UnsupportedNativeResult",
        ]
        returning.nativeImports[0].key = try Core.NativeCall.Key.derive(
            descriptor: returning.nativeImports[0].descriptor
        )
        returning.shellInterfaceHash = try returning.computeShellInterfaceHash()
        #expect(throws: InterfaceArchive.Error.invalidArchive(
            "native import has an unsupported callback signature"
        )) {
            try returning.validate()
        }

        for invalid in [
            InterfaceArchive.NativeImportParameterProjection(
                physicalParameterCount: 3,
                logicalParameterIndices: [3]
            ),
            .init(
                physicalParameterCount: 3,
                logicalParameterIndices: [2, 2]
            ),
            .init(
                physicalParameterCount: 3,
                logicalParameterIndices: [2, 1]
            ),
        ] {
            var malformed = decoded
            malformed.nativeImports[0].parameterProjection = invalid
            malformed.shellInterfaceHash = try malformed
                .computeShellInterfaceHash()
            #expect(throws: InterfaceArchive.Error.self) {
                try malformed.validate()
            }
        }

        var signatureCountMismatch = decoded
        signatureCountMismatch.nativeImports[0].signature.parameters = []
        signatureCountMismatch.shellInterfaceHash = try signatureCountMismatch
            .computeShellInterfaceHash()
        #expect(throws: InterfaceArchive.Error.self) {
            try signatureCountMismatch.validate()
        }

        var isolationMismatch = decoded
        isolationMismatch.nativeImports[0].signature.isolation = "Swift.MainActor"
        isolationMismatch.shellInterfaceHash = try isolationMismatch
            .computeShellInterfaceHash()
        #expect(throws: InterfaceArchive.Error.self) {
            try isolationMismatch.validate()
        }

        var borrowedCallback = decoded
        borrowedCallback.nativeImports[0].parameterTypes = [
            .closure(.init(
                parameters: [.bool],
                parameterConventions: [.borrowed],
                result: .void
            )),
        ]
        borrowedCallback.shellInterfaceHash = try borrowedCallback
            .computeShellInterfaceHash()
        #expect(throws: InterfaceArchive.Error.self) {
            try borrowedCallback.validate()
        }

        var unbridgeableCallback = decoded
        unbridgeableCallback.nativeImports[0].parameterTypes = [
            .closure(.init(
                parameters: [.address(.bool)],
                parameterConventions: [.owned],
                result: .void
            )),
        ]
        unbridgeableCallback.shellInterfaceHash = try unbridgeableCallback
            .computeShellInterfaceHash()
        #expect(throws: InterfaceArchive.Error.self) {
            try unbridgeableCallback.validate()
        }

        var errorCallback = decoded
        errorCallback.capabilities.append(.structuredErrorsV1)
        errorCallback.nativeImports[0].parameterTypes = [
            .closure(.init(
                parameters: [.optional(.error)],
                parameterConventions: [.borrowed],
                result: .void
            )),
        ]
        errorCallback.nativeImports[0].signature.parameters = [
            "@escaping ((any Swift.Error)?) -> Swift.Void",
        ]
        errorCallback.nativeImports[0].key = try Core.NativeCall.Key.derive(
            descriptor: errorCallback.nativeImports[0].descriptor
        )
        errorCallback.shellInterfaceHash = try errorCallback
            .computeShellInterfaceHash()
        try errorCallback.validate()

        var ordinaryError = errorCallback
        ordinaryError.nativeImports[0].parameterTypes = [.optional(.error)]
        ordinaryError.nativeImports[0].signature.parameters = [
            "(any Swift.Error)?",
        ]
        ordinaryError.nativeImports[0].contract.callbacks = []
        ordinaryError.nativeImports[0].key = try Core.NativeCall.Key.derive(
            descriptor: ordinaryError.nativeImports[0].descriptor
        )
        ordinaryError.shellInterfaceHash = try ordinaryError
            .computeShellInterfaceHash()
        #expect(throws: InterfaceArchive.Error.invalidArchive(
            "native import has an unsupported ordinary parameter"
        )) {
            try ordinaryError.validate()
        }
    }

    @Test("Physical variants may omit an optional callback default")
    func optionalCallbackDefaultVariants() throws {
        var archive = try fixture()
        archive.capabilities += [
            .nativeImportsV1, .closureValuesV1, .escapingClosureValuesV1,
        ]
        let symbol = "$s7Fixture8scheduleyyyyccSgF"
        let callback = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void
        )
        let omittedSignature = Core.LoweredSignature(
            parameters: [],
            result: "Swift.Void"
        )
        let explicitSignature = Core.LoweredSignature(
            parameters: ["Swift.Optional<@escaping () -> Swift.Void>"],
            result: "Swift.Void"
        )
        let omittedContract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let explicitContract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true,
            callbacks: [.init(parameterIndex: 0, lifetime: .escaping)]
        )
        let omittedDescriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.schedule()",
            signature: omittedSignature,
            effects: .init(),
            contract: omittedContract,
            physicalParameterTypes: [explicitSignature.parameters[0]],
            physicalArgumentSources: [.optionalNone]
        )
        let explicitDescriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.schedule(completion:)",
            signature: explicitSignature,
            effects: .init(),
            contract: explicitContract
        )
        let omittedKey = try Core.NativeCall.Key.derive(
            descriptor: omittedDescriptor
        )
        let explicitKey = try Core.NativeCall.Key.derive(
            descriptor: explicitDescriptor
        )
        archive.nativeImports = [
            .init(
                id: .init(rawValue: 0),
                key: omittedKey,
                descriptor: omittedDescriptor,
                silMangledNames: [symbol],
                parameterTypes: [],
                parameterProjection: .init(
                    physicalParameterCount: 1,
                    logicalParameterIndices: [],
                    defaultArguments: [
                        .optionalNone(physicalParameterIndex: 0),
                    ]
                ),
                resultType: .void,
                contract: omittedContract,
                isEmittedToDevice: true
            ),
            .init(
                id: .init(rawValue: 1),
                key: explicitKey,
                descriptor: explicitDescriptor,
                silMangledNames: [symbol],
                parameterTypes: [.optional(.closure(callback))],
                resultType: .void,
                contract: explicitContract,
                isEmittedToDevice: true
            ),
        ]
        archive.shellInterfaceHash = try archive.computeShellInterfaceHash()

        try archive.validate()
    }

    @Test("A nonisolated native declaration may use a MainActor nominal type")
    func nonisolatedNativeImportWithMainActorNominal() throws {
        var archive = try fixture()
        let typeID = Core.TypeID.derive(
            namespace: archive.metadata.shellNamespaceID,
            canonicalType: "UIKit.UIApplication"
        )
        let signature = Core.LoweredSignature(
            parameters: ["UIKit.UIApplication"],
            result: "Swift.Double"
        )
        let effects = Core.Effects()
        let contract = Core.NativeImportContract.bounded(
            kind: .instanceGetter,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "UIKit.UIApplication.backgroundTimeRemaining.getter",
            signature: signature,
            effects: effects,
            contract: contract
        )
        let key = try Core.NativeCall.Key.derive(descriptor: descriptor)
        archive.capabilities += [.nativeImportsV1, .nativeTypesV1]
        archive.nativeTypes = [
            .init(
                id: typeID,
                canonicalName: "UIKit.UIApplication",
                kind: .reference,
                layoutFingerprint: .sha256("UIKit.UIApplication.reference.v1"),
                isCopyable: true,
                requiresMainActor: true,
                isEmittedToDevice: true,
                estimatedSize: 8
            ),
        ]
        archive.nativeImports = [
            .init(
                id: .init(rawValue: 0),
                key: key,
                descriptor: descriptor,
                silMangledNames: ["$s7Fixture33backgroundTimeRemainingImportSdyF"],
                parameterTypes: [.native(typeID)],
                resultType: .float(bitWidth: 64),
                contract: contract,
                isEmittedToDevice: true
            ),
        ]
        archive.shellInterfaceHash = try archive.computeShellInterfaceHash()

        try archive.validate()

        var unsafeEntry = archive
        unsafeEntry.functions[0].parameterTypes = [.native(typeID)]
        unsafeEntry.shellInterfaceHash = try unsafeEntry.computeShellInterfaceHash()
        #expect(throws: InterfaceArchive.Error.invalidArchive(
            "function func transform(_: Int) -> Int moves a MainActor native type off actor"
        )) {
            try unsafeEntry.validate()
        }
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
