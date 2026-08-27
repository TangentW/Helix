import HelixCore

extension InterfaceArchive.Archive {
/// Projects the only production NativeImport authority from this exact Shell.
/// Dormant development candidates are deliberately excluded.
public func nativeCapabilityManifest() throws -> Core.NativeCapability.Manifest {
    try validate()
    let emitted = try nativeImports.filter(\.isEmittedToDevice).map {
        record -> (
            id: Core.NativeImportID,
            record: InterfaceArchive.NativeImportRecord
        ) in
        guard let id = record.id else {
            throw InterfaceArchive.Error.invalidArchive(
                "emitted native capability has no compact ID"
            )
        }
        return (id, record)
    }.sorted { $0.id < $1.id }
    let manifest = Core.NativeCapability.Manifest(
        identity: .init(
            bundleID: metadata.bundleID,
            buildNumber: metadata.buildNumber,
            shellNamespaceID: metadata.shellNamespaceID,
            shellInterfaceHash: shellInterfaceHash,
            targetTriple: metadata.targetTriple,
            minimumOSVersion: metadata.minimumOS,
            xcodeBuild: metadata.xcodeBuild,
            sdkBuild: metadata.sdkBuild,
            compatibility: compatibility
        ),
        capabilities: Set(capabilities),
        entries: emitted.map { item in
            Core.NativeCapability.Entry(
                id: item.id,
                key: item.record.key,
                descriptor: item.record.descriptor,
                contract: item.record.contract,
                requiredCapability: item.record.capability
            )
        }
    )
    try manifest.validate()
    return manifest
}
}
