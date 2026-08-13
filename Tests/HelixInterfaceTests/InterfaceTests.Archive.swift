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
        changed.nativeTypes[0].layoutFingerprint = .sha256("Fixture.Point.layout.changed")

        #expect(try first.computeShellInterfaceHash() != changed.computeShellInterfaceHash())
    }

    @Test("Fallback policy participates in the device interface hash")
    func fallbackPolicyChangesInterfaceHash() throws {
        let original = try fixture()
        var changed = original
        changed.functions[0].fallbackAllowed = true

        #expect(try original.computeShellInterfaceHash() != changed.computeShellInterfaceHash())
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
