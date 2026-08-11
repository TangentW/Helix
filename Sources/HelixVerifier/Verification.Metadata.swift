import HelixBytecode
import HelixCore

public enum Verification {}

extension Verification {
public enum Metadata {
    public static let version = Core.SemanticVersion(0, 1, 0)
    public static let supportedCapabilities: Set<Core.Capability> = [
        .baselineV1,
        .stringsV1,
        .collectionsV1,
        .nativeTypesV1,
        .nativeImportsV2,
        .untypedThrowsV1,
        .localNominalsV1,
        .structuredErrorsV1,
        .mainActorSyncV1,
        .addressValuesV1,
        .borrowCallsV1,
        .closureValuesV1,
        .escapingClosureValuesV1,
        .compilerSpecializationsV1,
        .asyncLeafEntriesV1,
        .anyValuesV1,
    ]
}
}
