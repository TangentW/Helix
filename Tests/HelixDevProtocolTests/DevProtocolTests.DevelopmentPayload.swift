import Foundation
import HelixBytecode
import HelixCore
import Testing
@testable import HelixDevProtocol

extension DevProtocolTests {
@Suite("Development payload framing")
struct DevelopmentPayload {
    @Test("Bytecode, capability metadata, and Adapter images round-trip canonically")
    func roundTripsCompleteTransaction() throws {
        let fixture = try PayloadFixture()
        let bytes = try fixture.artifact.encoded()
        let decoded = try DevProtocol.DevelopmentPayload.Artifact.decode(bytes)

        #expect(decoded == fixture.artifact)
        #expect(try decoded.encoded() == bytes)
        #expect(decoded.manifest.schemaVersion == 1)
        #expect(decoded.manifest.nativeImports.map(\.key) == [fixture.key])
        #expect(decoded.manifest.nativeTypes == [fixture.nativeType])
    }

    @Test("Every framed region is length- and hash-bound")
    func rejectsCorruptionAndTrailingBytes() throws {
        let fixture = try PayloadFixture()
        let encoded = try fixture.artifact.encoded()

        var corruptBytecode = encoded
        let bytecodeOffset = try payloadOffset(encoded)
        corruptBytecode[bytecodeOffset] ^= 1
        #expect(throws: DevProtocol.Error.self) {
            _ = try DevProtocol.DevelopmentPayload.Artifact.decode(
                corruptBytecode
            )
        }

        var corruptImage = encoded
        corruptImage[corruptImage.index(before: corruptImage.endIndex)] ^= 1
        #expect(throws: DevProtocol.Error.self) {
            _ = try DevProtocol.DevelopmentPayload.Artifact.decode(corruptImage)
        }

        var trailing = encoded
        trailing.append(0)
        #expect(throws: DevProtocol.Error.self) {
            _ = try DevProtocol.DevelopmentPayload.Artifact.decode(trailing)
        }
    }

    @Test("Noncanonical manifests and inconsistent Adapter references fail closed")
    func rejectsNoncanonicalAndInconsistentMetadata() throws {
        let fixture = try PayloadFixture()
        let encoded = try fixture.artifact.encoded()
        let headerCount = DevProtocol.DevelopmentPayload.Artifact.magic.count + 2
        let manifestLength = Int(
            DevProtocol.FrameCodec.readUInt32(
                encoded[headerCount..<(headerCount + 4)]
            )
        )
        let manifestStart = headerCount + 4
        var noncanonical = Data()
        noncanonical.append(encoded.prefix(headerCount))
        var increasedLength = Data()
        DevProtocol.FrameCodec.append(UInt32(manifestLength + 1), to: &increasedLength)
        noncanonical.append(increasedLength)
        noncanonical.append(0x20)
        noncanonical.append(
            encoded[manifestStart..<(manifestStart + manifestLength)]
        )
        noncanonical.append(encoded[(manifestStart + manifestLength)...])
        #expect(throws: DevProtocol.Error.nonCanonicalMessage) {
            _ = try DevProtocol.DevelopmentPayload.Artifact.decode(noncanonical)
        }

        var invalid = fixture.nativeImport
        invalid.exportSymbol = "wrong_export"
        let inconsistent = DevProtocol.DevelopmentPayload.Artifact(
            shellInterfaceHash: fixture.shellHash,
            compilerFingerprint: "swift-fixture",
            sdkBuild: "22A1",
            targetTriple: "arm64-apple-ios17.0-simulator",
            bytecode: fixture.bytecode,
            nativeImports: [invalid],
            imageDescriptors: [fixture.imageDescriptor],
            images: [fixture.image]
        )
        #expect(throws: DevProtocol.Error.self) {
            _ = try inconsistent.encoded()
        }

        var unsafeImage = fixture.imageDescriptor
        unsafeImage.installName = "@rpath/HLXDevAdapter-../fixture.dylib"
        let unsafe = DevProtocol.DevelopmentPayload.Artifact(
            shellInterfaceHash: fixture.shellHash,
            compilerFingerprint: "swift-fixture",
            sdkBuild: "22A1",
            targetTriple: "arm64-apple-ios17.0-simulator",
            bytecode: fixture.bytecode,
            nativeImports: [fixture.nativeImport],
            imageDescriptors: [unsafeImage],
            images: [fixture.image]
        )
        #expect(throws: DevProtocol.Error.self) {
            _ = try unsafe.encoded()
        }

        var invalidIdentity = fixture.artifact
        invalidIdentity.manifest.sdkBuild = "22A1\0unexpected"
        #expect(throws: DevProtocol.Error.self) {
            _ = try invalidIdentity.encoded()
        }

        var invalidType = fixture.nativeType
        invalidType.exportSymbol = "wrong_type_export"
        var invalidTypeArtifact = fixture.artifact
        invalidTypeArtifact.manifest.nativeTypes = [invalidType]
        #expect(throws: DevProtocol.Error.self) {
            _ = try invalidTypeArtifact.encoded()
        }

        var invalidObjectiveCType = fixture.nativeType
        invalidObjectiveCType.binding = .objectiveCReference
        invalidObjectiveCType.objectiveCRuntimeName = "UIView"
        #expect(throws: DevProtocol.Error.self) {
            try invalidObjectiveCType.validate(imageCount: 1)
        }
    }

    private func payloadOffset(_ encoded: Data) throws -> Int {
        let headerCount = DevProtocol.DevelopmentPayload.Artifact.magic.count + 2
        guard encoded.count >= headerCount + 4 else {
            throw DevProtocol.Error.truncatedFrame
        }
        return headerCount + 4 + Int(
            DevProtocol.FrameCodec.readUInt32(
                encoded[headerCount..<(headerCount + 4)]
            )
        )
    }
}
}

private struct PayloadFixture {
    let shellHash = Core.Digest.sha256("development-payload-shell")
    let bytecode = Data("typed-bytecode".utf8)
    let image = Data("signed-adapter-image".utf8)
    let key: Core.NativeCall.Key
    let nativeImport: DevProtocol.DevelopmentPayload.NativeImport
    let nativeType: DevProtocol.DevelopmentPayload.NativeType
    let imageDescriptor: DevProtocol.DevelopmentPayload.Image
    let artifact: DevProtocol.DevelopmentPayload.Artifact

    init() throws {
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.value()",
            signature: .init(parameters: [], result: "Swift.Int"),
            effects: .init(),
            contract: contract
        )
        key = try .derive(descriptor: descriptor)
        nativeImport = .init(
            id: .init(rawValue: 3),
            key: key,
            descriptor: descriptor,
            parameterTypes: [],
            resultType: .int64,
            contract: contract,
            binding: .swiftAdapter,
            imageIndex: 0,
            exportSymbol: "hlx_swift_adapter_body_v1_\(key.rawValue.hex)"
        )
        let typeID = Core.TypeID(rawValue: .sha256("Fixture.NativeValue"))
        nativeType = .init(
            id: typeID,
            canonicalName: "Fixture.NativeValue",
            kind: .value,
            layoutFingerprint: .sha256("Fixture.NativeValue.Layout"),
            isCopyable: true,
            estimatedSize: 8,
            binding: .swiftAdapter,
            imageIndex: 0,
            exportSymbol: "hlx_native_type_ops_v1_\(typeID.rawValue.hex)"
        )
        imageDescriptor = .init(
            installName: "@rpath/HLXDevAdapter-\(shellHash.hex).dylib",
            uuid: UUID(uuidString: "776E2F49-25A0-49AB-904A-31C5A7643CA1")!,
            byteLength: UInt64(image.count),
            sha256: .sha256(image)
        )
        artifact = .init(
            shellInterfaceHash: shellHash,
            compilerFingerprint: "swift-fixture",
            sdkBuild: "22A1",
            targetTriple: "arm64-apple-ios17.0-simulator",
            bytecode: bytecode,
            nativeImports: [nativeImport],
            nativeTypes: [nativeType],
            imageDescriptors: [imageDescriptor],
            images: [image]
        )
    }
}
