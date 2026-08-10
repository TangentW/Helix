import Foundation
import HelixBytecode
import HelixCore
import HelixInterface
import HelixPatch

extension CLI {
public enum ArtifactKind: String, Codable, Hashable, Sendable {
    case interfaceArchive = "HLXI"
    case bytecode = "HLBC"
    case patchPackage = "HLXP"
}

public struct ArchiveSummary: Codable, Hashable, Sendable {
    public var schemaVersion: UInt16
    public var archiveHash: Core.Digest
    public var bundleID: String
    public var buildNumber: String
    public var targetTriple: String
    public var modules: [String]
    public var functionCount: Int
    public var eligibleFunctionCount: Int
    public var nativeImportCount: Int
    public var nativeTypeCount: Int
    public var shellInterfaceHash: Core.Digest
    public var compilerFingerprint: String
}

public struct BytecodeSummary: Codable, Hashable, Sendable {
    public var formatVersion: String
    public var imageHash: Core.Digest
    public var moduleName: String
    public var functionCount: Int
    public var entryCount: Int
    public var importCount: Int
    public var capabilities: [String]
    public var shellInterfaceHash: Core.Digest
    public var compilerFingerprint: String
}

public struct PackagePayloadSummary: Codable, Hashable, Sendable {
    public var path: String
    public var backend: String
    public var byteLength: UInt64
    public var sha256: Core.Digest
    public var changedFunctionCount: Int
}

public struct PackageSummary: Codable, Hashable, Sendable {
    public var packageID: String
    public var campaignID: String
    public var revision: UInt64
    public var distributionPolicy: String
    public var targetCount: Int
    public var payloads: [CLI.PackagePayloadSummary]
    public var signerKeyID: String
    public var issuerKeyID: String
    public var notBeforeUnixSeconds: Int64
    public var expiresAtUnixSeconds: Int64
    public var validation: String
}

public struct Inspection: Codable, Hashable, Sendable {
    public var kind: CLI.ArtifactKind
    public var sha256: Core.Digest
    public var byteLength: UInt64
    public var archive: CLI.ArchiveSummary?
    public var bytecode: CLI.BytecodeSummary?
    public var package: CLI.PackageSummary?

    public func canonicalJSON() throws -> String {
        String(decoding: try Core.CanonicalJSON.encode(self), as: UTF8.self) + "\n"
    }

    public func humanDescription() -> String {
        var lines = [
            "Kind: \(kind.rawValue)",
            "SHA-256: \(sha256.hex)",
            "Bytes: \(byteLength)",
        ]
        if let archive {
            lines.append("Bundle: \(archive.bundleID) (build \(archive.buildNumber))")
            lines.append("Target: \(archive.targetTriple)")
            lines.append("Modules: \(archive.modules.joined(separator: ", "))")
            lines.append(
                "Functions: \(archive.functionCount) (\(archive.eligibleFunctionCount) eligible)"
            )
            lines.append("Shell interface: \(archive.shellInterfaceHash.hex)")
        }
        if let bytecode {
            lines.append("Module: \(bytecode.moduleName)")
            lines.append("Format: \(bytecode.formatVersion)")
            lines.append("Functions: \(bytecode.functionCount); entries: \(bytecode.entryCount)")
            lines.append("Capabilities: \(bytecode.capabilities.joined(separator: ", "))")
            lines.append("Shell interface: \(bytecode.shellInterfaceHash.hex)")
        }
        if let package {
            lines.append("Package: \(package.packageID) revision \(package.revision)")
            lines.append("Campaign: \(package.campaignID)")
            lines.append("Distribution: \(package.distributionPolicy)")
            lines.append("Targets: \(package.targetCount); payloads: \(package.payloads.count)")
            lines.append("Signer: \(package.signerKeyID) (issuer \(package.issuerKeyID))")
            lines.append("Validation: \(package.validation)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct ArtifactInspector: Sendable {
    public init() {}

    public func inspect(_ data: Data) throws -> CLI.Inspection {
        let digest = Core.Digest.sha256(data)
        let byteLength = UInt64(data.count)
        if hasMagic(data, InterfaceArchive.Codec.magic) {
            let decoded = try InterfaceArchive.Codec.decode(data)
            let archive = decoded.archive
            return .init(
                kind: .interfaceArchive,
                sha256: digest,
                byteLength: byteLength,
                archive: .init(
                    schemaVersion: archive.schemaVersion,
                    archiveHash: decoded.archiveHash,
                    bundleID: archive.metadata.bundleID,
                    buildNumber: archive.metadata.buildNumber,
                    targetTriple: archive.metadata.targetTriple,
                    modules: Array(Set(archive.functions.map(\.moduleName))).sorted(),
                    functionCount: archive.functions.count,
                    eligibleFunctionCount: archive.functions.count(where: { $0.patchability.isEligible }),
                    nativeImportCount: archive.nativeImports.count,
                    nativeTypeCount: archive.nativeTypes.count,
                    shellInterfaceHash: archive.shellInterfaceHash,
                    compilerFingerprint: archive.compatibility.compilerFingerprint
                ),
                bytecode: nil,
                package: nil
            )
        }
        if hasMagic(data, Bytecode.Format.magic) {
            let decoded = try Bytecode.Decoder.decode(data)
            return .init(
                kind: .bytecode,
                sha256: digest,
                byteLength: byteLength,
                archive: nil,
                bytecode: summary(decoded),
                package: nil
            )
        }
        if data.starts(with: PatchPackage.Container.magic) {
            let package = try PatchPackage.Container.decode(data)
            let manifest = package.manifest
            return .init(
                kind: .patchPackage,
                sha256: digest,
                byteLength: byteLength,
                archive: nil,
                bytecode: nil,
                package: .init(
                    packageID: manifest.packageID,
                    campaignID: manifest.campaignID,
                    revision: manifest.revision,
                    distributionPolicy: manifest.distributionPolicy.rawValue,
                    targetCount: manifest.targets.count,
                    payloads: manifest.payloads.sorted(by: { $0.path < $1.path }).map {
                        .init(
                            path: $0.path,
                            backend: $0.backend.rawValue,
                            byteLength: $0.byteLength,
                            sha256: $0.sha256,
                            changedFunctionCount: $0.changedFunctionKeys.count
                        )
                    },
                    signerKeyID: package.signatureEnvelope.certificate.keyID,
                    issuerKeyID: package.signatureEnvelope.certificate.issuerKeyID,
                    notBeforeUnixSeconds: manifest.notBeforeUnixSeconds,
                    expiresAtUnixSeconds: manifest.expiresAtUnixSeconds,
                    validation: "container structure and payload hashes only; signature trust not evaluated"
                )
            )
        }
        throw CLI.Error.unsupportedArtifact
    }

    public func disassemble(_ data: Data) throws -> String {
        if hasMagic(data, Bytecode.Format.magic) {
            return Bytecode.Disassembler.disassemble(try Bytecode.Decoder.decode(data).module) + "\n"
        }
        if data.starts(with: PatchPackage.Container.magic) {
            let package = try PatchPackage.Container.decode(data)
            let bytecodePayloads = package.manifest.payloads.filter { $0.backend == .hlbc }
            guard bytecodePayloads.count == 1,
                  let payload = package.payloads[bytecodePayloads[0].path]
            else {
                throw CLI.Error.input("HLXP disassembly requires exactly one HLBC payload")
            }
            return Bytecode.Disassembler.disassemble(try Bytecode.Decoder.decode(payload).module) + "\n"
        }
        throw CLI.Error.input("disassembly accepts an HLBC or single-HLBC HLXP artifact")
    }

    private func summary(_ decoded: Bytecode.DecodedContainer) -> CLI.BytecodeSummary {
        let module = decoded.module
        return .init(
            formatVersion: "\(decoded.header.formatMajor).\(decoded.header.formatMinor)",
            imageHash: decoded.header.imageHash,
            moduleName: module.name,
            functionCount: module.functions.count,
            entryCount: module.entries.count,
            importCount: module.imports.count,
            capabilities: module.capabilities.sorted().map(\.rawValue),
            shellInterfaceHash: module.shellInterfaceHash,
            compilerFingerprint: module.compatibility.compilerFingerprint
        )
    }

    private func hasMagic(_ data: Data, _ magic: [UInt8]) -> Bool {
        data.starts(with: magic)
    }
}
}
