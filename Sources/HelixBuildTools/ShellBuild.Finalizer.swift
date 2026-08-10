import Foundation
import HelixDevProtocol
import HelixInterface

extension ShellBuild {
public struct Finalizer: Sendable {
    public init() {}

    public func finalize(
        provisionalArchive: InterfaceArchive.Archive,
        linkedExecutable: Data
    ) throws -> InterfaceArchive.Archive {
        let descriptor = try MachO.Inspector().inspect(linkedExecutable)
        guard descriptor.fileType == 2 else {
            throw ShellBuild.Error.executableMismatch("Mach-O file type is not MH_EXECUTE")
        }
        guard !descriptor.hasWritableExecutableSegment else {
            throw ShellBuild.Error.executableMismatch("Mach-O contains a writable executable segment")
        }
        let expectedArchitecture = try architecture(
            for: provisionalArchive.metadata.targetTriple
        )
        guard descriptor.architecture == expectedArchitecture else {
            throw ShellBuild.Error.executableMismatch(
                "expected \(expectedArchitecture.rawValue), got \(descriptor.architecture.rawValue)"
            )
        }
        let expectedPlatform: MachO.Platform =
            provisionalArchive.metadata.frontendInvocation.sdkName == "iphonesimulator"
                ? .iOSSimulator
                : .iOS
        guard descriptor.platform == expectedPlatform else {
            throw ShellBuild.Error.executableMismatch(
                "expected platform \(expectedPlatform.rawValue), got "
                    + "\(descriptor.platform.map(String.init(describing:)) ?? "none")"
            )
        }
        guard let uuid = descriptor.uuid else {
            throw ShellBuild.Error.missingMachOUUID
        }
        return try finalize(provisionalArchive: provisionalArchive, machOUUIDs: [uuid])
    }

    public func finalize(
        provisionalArchive: InterfaceArchive.Archive,
        machOUUIDs: [UUID]
    ) throws -> InterfaceArchive.Archive {
        try provisionalArchive.validate()
        guard provisionalArchive.metadata.machOUUIDs.isEmpty else {
            throw ShellBuild.Error.prelinkArchiveRequired
        }
        guard !machOUUIDs.isEmpty, Set(machOUUIDs).count == machOUUIDs.count else {
            throw ShellBuild.Error.missingMachOUUID
        }
        let interfaceHash = provisionalArchive.shellInterfaceHash
        var finalized = provisionalArchive
        finalized.metadata.machOUUIDs = machOUUIDs
        finalized = finalized.normalized()
        finalized.shellInterfaceHash = try finalized.computeShellInterfaceHash()
        guard finalized.shellInterfaceHash == interfaceHash else {
            throw ShellBuild.Error.invalidInput(
                "post-link identity changed the device-visible Shell interface"
            )
        }
        try finalized.validate()
        return finalized
    }

    private func architecture(for targetTriple: String) throws -> MachO.Architecture {
        let architecture = targetTriple.split(separator: "-", maxSplits: 1).first
        switch architecture {
        case "arm64", "arm64e": return .arm64
        case "x86_64": return .x86_64
        default:
            throw ShellBuild.Error.executableMismatch(
                "unsupported target architecture \(architecture.map(String.init) ?? "none")"
            )
        }
    }
}
}
