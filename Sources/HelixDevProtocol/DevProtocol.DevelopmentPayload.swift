import Foundation
import HelixBytecode
import HelixCore

extension DevProtocol {
/// Authenticated HLBC transaction payload used only by a trusted development
/// session. The bytecode and every newly compiled Adapter image are framed and
/// hashed together so activation cannot observe a partially installed native
/// capability set.
public enum DevelopmentPayload {}
}

extension DevProtocol.DevelopmentPayload {
public enum Binding: String, Codable, Hashable, Sendable {
    /// Runtime constructs the invoker from the compiler-authored descriptor.
    case objectiveCInvoker
    /// A signed development image exports the shared Swift Adapter Body ABI.
    case swiftAdapter
    /// Runtime resolves one exact Catalog-authorized C symbol and applies the
    /// shared, finite C ABI trampoline matrix.
    case cInvoker
}

public struct NativeImport: Codable, Hashable, Sendable {
    public var id: Core.NativeImportID
    public var key: Core.NativeCall.Key
    public var descriptor: Core.NativeCall.Descriptor
    public var parameterTypes: [Bytecode.ValueType]
    public var resultType: Bytecode.ValueType
    public var contract: Core.NativeImportContract
    public var capability: Core.Capability
    public var binding: DevProtocol.DevelopmentPayload.Binding
    /// Nil means this exact import must already exist in the session Registry.
    public var imageIndex: UInt16?
    /// Stable Adapter ABI export. Generic Objective-C imports never name one.
    public var exportSymbol: String?

    public init(
        id: Core.NativeImportID,
        key: Core.NativeCall.Key,
        descriptor: Core.NativeCall.Descriptor,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        contract: Core.NativeImportContract,
        capability: Core.Capability = .nativeImportsV1,
        binding: DevProtocol.DevelopmentPayload.Binding,
        imageIndex: UInt16? = nil,
        exportSymbol: String? = nil
    ) {
        self.id = id
        self.key = key
        self.descriptor = descriptor
        self.parameterTypes = parameterTypes
        self.resultType = resultType
        self.contract = contract
        self.capability = capability
        self.binding = binding
        self.imageIndex = imageIndex
        self.exportSymbol = exportSymbol
    }

    public func validate(imageCount: Int) throws {
        try descriptor.validate(contract: contract)
        guard try descriptor.canonicalized() == descriptor,
              try Core.NativeCall.Key.derive(descriptor: descriptor) == key,
              descriptor.loweredSignature.parameters.count == parameterTypes.count,
              descriptor.loweredSignature.isThrowing == descriptor.effects.mayThrow,
              descriptor.loweredSignature.isAsync == descriptor.effects.isAsync,
              capability == .nativeImportsV1
        else {
            throw DevProtocol.Error.invalidArtifact(
                "development NativeImport descriptor is inconsistent"
            )
        }
        if let imageIndex {
            guard Int(imageIndex) < imageCount else {
                throw DevProtocol.Error.invalidArtifact(
                    "development NativeImport references an unknown Adapter image"
                )
            }
        }
        switch binding {
        case .objectiveCInvoker:
            guard descriptor.target.backend == .objectiveCMessage,
                  !descriptor.effects.isAsync,
                  imageIndex == nil,
                  exportSymbol == nil
            else {
                throw DevProtocol.Error.invalidArtifact(
                    "Objective-C development import has an executable Adapter"
                )
            }
        case .swiftAdapter:
            guard descriptor.target.backend == .swiftAdapter else {
                throw DevProtocol.Error.invalidArtifact(
                    "Swift development Adapter has a non-Swift descriptor"
                )
            }
            try validateAdapterReference()
        case .cInvoker:
            guard descriptor.target.backend == .cFunction,
                  !descriptor.effects.isAsync,
                  imageIndex == nil,
                  exportSymbol == nil
            else {
                throw DevProtocol.Error.invalidArtifact(
                    "C development import has an executable Adapter or a non-C descriptor"
                )
            }
        }
    }

    private func validateAdapterReference() throws {
        if imageIndex == nil {
            guard exportSymbol == nil else {
                throw DevProtocol.Error.invalidArtifact(
                    "an existing session Adapter cannot name a new export"
                )
            }
            return
        }
        guard let exportSymbol,
              exportSymbol == "hlx_swift_adapter_body_v1_\(key.rawValue.hex)",
              exportSymbol.utf8.count <= 256
        else {
            throw DevProtocol.Error.invalidArtifact(
                "development Adapter export does not match NativeCallKey"
            )
        }
    }
}

public struct Image: Codable, Hashable, Sendable {
    public var installName: String
    public var uuid: UUID
    public var byteLength: UInt64
    public var sha256: Core.Digest

    public init(
        installName: String,
        uuid: UUID,
        byteLength: UInt64,
        sha256: Core.Digest
    ) {
        self.installName = installName
        self.uuid = uuid
        self.byteLength = byteLength
        self.sha256 = sha256
    }

    public func validate() throws {
        let prefix = "@rpath/HLXDevAdapter-"
        let suffix = ".dylib"
        let digest = installName
            .dropFirst(prefix.count)
            .dropLast(suffix.count)
        guard installName.hasPrefix(prefix),
              installName.hasSuffix(suffix),
              digest.count == 64,
              digest.allSatisfy({ character in
                  ("0"..."9").contains(character)
                      || ("a"..."f").contains(character)
              }),
              uuid.uuidString != "00000000-0000-0000-0000-000000000000",
              byteLength > 0,
              byteLength <= UInt64(64 * 1_024 * 1_024)
        else {
            throw DevProtocol.Error.invalidArtifact(
                "development Adapter image descriptor is invalid"
            )
        }
    }
}

public struct Manifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var shellInterfaceHash: Core.Digest
    public var compilerFingerprint: String
    public var sdkBuild: String
    public var targetTriple: String
    public var bytecodeLength: UInt64
    public var bytecodeSHA256: Core.Digest
    public var nativeImports: [DevProtocol.DevelopmentPayload.NativeImport]
    public var images: [DevProtocol.DevelopmentPayload.Image]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        shellInterfaceHash: Core.Digest,
        compilerFingerprint: String,
        sdkBuild: String,
        targetTriple: String,
        bytecodeLength: UInt64,
        bytecodeSHA256: Core.Digest,
        nativeImports: [DevProtocol.DevelopmentPayload.NativeImport] = [],
        images: [DevProtocol.DevelopmentPayload.Image] = []
    ) {
        self.schemaVersion = schemaVersion
        self.shellInterfaceHash = shellInterfaceHash
        self.compilerFingerprint = compilerFingerprint
        self.sdkBuild = sdkBuild
        self.targetTriple = targetTriple
        self.bytecodeLength = bytecodeLength
        self.bytecodeSHA256 = bytecodeSHA256
        self.nativeImports = nativeImports.sorted { $0.id < $1.id }
        self.images = images
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              !compilerFingerprint.isEmpty,
              compilerFingerprint.utf8.count <= 4_096,
              !compilerFingerprint.unicodeScalars.contains(where: {
                  $0.value == 0
              }),
              !sdkBuild.isEmpty,
              sdkBuild.utf8.count <= 128,
              !sdkBuild.unicodeScalars.contains(where: { $0.value == 0 }),
              !targetTriple.isEmpty,
              targetTriple.utf8.count <= 256,
              !targetTriple.unicodeScalars.contains(where: { $0.value == 0 }),
              bytecodeLength > 0,
              bytecodeLength <= UInt64(64 * 1_024 * 1_024),
              nativeImports.count <= 65_536,
              images.count <= 1_024,
              nativeImports == nativeImports.sorted(by: { $0.id < $1.id }),
              Set(nativeImports.map(\.id)).count == nativeImports.count,
              Set(nativeImports.map(\.key)).count == nativeImports.count,
              Set(images.map(\.installName)).count == images.count,
              Set(images.map(\.uuid)).count == images.count
        else {
            throw DevProtocol.Error.invalidArtifact(
                "development payload manifest is invalid"
            )
        }
        try images.forEach { try $0.validate() }
        try nativeImports.forEach { try $0.validate(imageCount: images.count) }
        let referenced = Set(nativeImports.compactMap(\.imageIndex).map(Int.init))
        guard referenced == Set(images.indices) else {
            throw DevProtocol.Error.invalidArtifact(
                "development Adapter images must each have at least one import"
            )
        }
    }
}

public struct Artifact: Hashable, Sendable {
    public static let magic = Data([0x48, 0x4c, 0x58, 0x44, 0x45, 0x56, 0x41, 0x1a])
    public static let version: UInt16 = 1

    public var manifest: DevProtocol.DevelopmentPayload.Manifest
    public var bytecode: Data
    public var images: [Data]

    public init(
        shellInterfaceHash: Core.Digest,
        compilerFingerprint: String,
        sdkBuild: String,
        targetTriple: String,
        bytecode: Data,
        nativeImports: [DevProtocol.DevelopmentPayload.NativeImport] = [],
        imageDescriptors: [DevProtocol.DevelopmentPayload.Image] = [],
        images: [Data] = []
    ) {
        manifest = .init(
            shellInterfaceHash: shellInterfaceHash,
            compilerFingerprint: compilerFingerprint,
            sdkBuild: sdkBuild,
            targetTriple: targetTriple,
            bytecodeLength: UInt64(bytecode.count),
            bytecodeSHA256: .sha256(bytecode),
            nativeImports: nativeImports,
            images: imageDescriptors
        )
        self.bytecode = bytecode
        self.images = images
    }

    public func encoded(
        maximumManifestBytes: Int = 16 * 1_024 * 1_024,
        maximumPayloadBytes: Int = 64 * 1_024 * 1_024
    ) throws -> Data {
        try validate(
            maximumManifestBytes: maximumManifestBytes,
            maximumPayloadBytes: maximumPayloadBytes
        )
        let manifestBytes = try Core.CanonicalJSON.encode(manifest)
        var result = Data()
        result.append(Self.magic)
        result.append(UInt8(truncatingIfNeeded: Self.version))
        result.append(UInt8(truncatingIfNeeded: Self.version >> 8))
        DevProtocol.FrameCodec.append(UInt32(manifestBytes.count), to: &result)
        result.append(manifestBytes)
        result.append(bytecode)
        for image in images { result.append(image) }
        return result
    }

    public static func decode(
        _ bytes: Data,
        maximumManifestBytes: Int = 16 * 1_024 * 1_024,
        maximumPayloadBytes: Int = 64 * 1_024 * 1_024
    ) throws -> Self {
        guard bytes.count <= maximumPayloadBytes,
              bytes.count >= Self.magic.count + 2 + 4,
              bytes.prefix(Self.magic.count) == Self.magic
        else {
            throw DevProtocol.Error.invalidArtifact(
                "HLBC development payload has a bad or missing header"
            )
        }
        let versionOffset = Self.magic.count
        let version = UInt16(bytes[versionOffset])
            | (UInt16(bytes[versionOffset + 1]) << 8)
        guard version == Self.version else {
            throw DevProtocol.Error.invalidArtifact(
                "unsupported HLBC development payload version \(version)"
            )
        }
        let lengthOffset = versionOffset + 2
        let manifestLength = Int(
            DevProtocol.FrameCodec.readUInt32(
                bytes[lengthOffset..<(lengthOffset + 4)]
            )
        )
        let manifestStart = lengthOffset + 4
        let manifestEnd = manifestStart.addingReportingOverflow(manifestLength)
        guard manifestLength > 0,
              manifestLength <= maximumManifestBytes,
              !manifestEnd.overflow,
              manifestEnd.partialValue <= bytes.count
        else { throw DevProtocol.Error.frameTooLarge }
        let manifestBytes = bytes.subdata(
            in: manifestStart..<manifestEnd.partialValue
        )
        let manifest: DevProtocol.DevelopmentPayload.Manifest
        do {
            manifest = try JSONDecoder().decode(
                DevProtocol.DevelopmentPayload.Manifest.self,
                from: manifestBytes
            )
        } catch {
            throw DevProtocol.Error.invalidArtifact(
                "HLBC development manifest decoding failed"
            )
        }
        guard try Core.CanonicalJSON.encode(manifest) == manifestBytes else {
            throw DevProtocol.Error.nonCanonicalMessage
        }
        try manifest.validate()
        var offset = manifestEnd.partialValue
        let bytecodeEnd = offset.addingReportingOverflow(
            Int(manifest.bytecodeLength)
        )
        guard !bytecodeEnd.overflow,
              bytecodeEnd.partialValue <= bytes.count
        else {
            throw DevProtocol.Error.invalidArtifact(
                "HLBC development bytecode is truncated"
            )
        }
        let bytecode = bytes.subdata(in: offset..<bytecodeEnd.partialValue)
        offset = bytecodeEnd.partialValue
        var images: [Data] = []
        images.reserveCapacity(manifest.images.count)
        for descriptor in manifest.images {
            guard descriptor.byteLength <= UInt64(Int.max) else {
                throw DevProtocol.Error.frameTooLarge
            }
            let end = offset.addingReportingOverflow(Int(descriptor.byteLength))
            guard !end.overflow, end.partialValue <= bytes.count else {
                throw DevProtocol.Error.invalidArtifact(
                    "development Adapter image is truncated"
                )
            }
            images.append(bytes.subdata(in: offset..<end.partialValue))
            offset = end.partialValue
        }
        let artifact = Self(
            shellInterfaceHash: manifest.shellInterfaceHash,
            compilerFingerprint: manifest.compilerFingerprint,
            sdkBuild: manifest.sdkBuild,
            targetTriple: manifest.targetTriple,
            bytecode: bytecode,
            nativeImports: manifest.nativeImports,
            imageDescriptors: manifest.images,
            images: images
        )
        guard artifact.manifest == manifest, offset == bytes.count else {
            throw DevProtocol.Error.invalidArtifact(
                "HLBC development payload has trailing or inconsistent bytes"
            )
        }
        try artifact.validate(
            maximumManifestBytes: maximumManifestBytes,
            maximumPayloadBytes: maximumPayloadBytes
        )
        return artifact
    }

    private func validate(
        maximumManifestBytes: Int,
        maximumPayloadBytes: Int
    ) throws {
        guard maximumManifestBytes > 0,
              maximumPayloadBytes > 0,
              images.count == manifest.images.count,
              UInt64(bytecode.count) == manifest.bytecodeLength,
              Core.Digest.sha256(bytecode) == manifest.bytecodeSHA256,
              zip(images, manifest.images).allSatisfy({ data, descriptor in
                  UInt64(data.count) == descriptor.byteLength
                      && Core.Digest.sha256(data) == descriptor.sha256
              })
        else {
            throw DevProtocol.Error.invalidArtifact(
                "HLBC development payload hashes or lengths do not match"
            )
        }
        try manifest.validate()
        let manifestBytes = try Core.CanonicalJSON.encode(manifest)
        let total = Self.magic.count + 2 + 4 + manifestBytes.count
            + bytecode.count + images.reduce(0) { $0 + $1.count }
        guard manifestBytes.count <= maximumManifestBytes,
              total <= maximumPayloadBytes,
              manifestBytes.count <= Int(UInt32.max)
        else { throw DevProtocol.Error.frameTooLarge }
    }
}
}
