#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

public enum Verification {}

extension Verification {
public enum Metadata {
    public static let version = Core.SemanticVersion(1, 0, 0)
    public static let supportedCapabilities: Set<Core.Capability> = [
        .baselineV1,
        .stringsV1,
        .collectionsV1,
        .nativeTypesV1,
        .nativeImportsV1,
        .untypedThrowsV1,
        .localNominalsV1,
        .structuredErrorsV1,
        .typedThrowsV1,
        .mainActorIsolationV1,
        .addressValuesV1,
        .borrowCallsV1,
        .closureValuesV1,
        .escapingClosureValuesV1,
        .mutableCapturesV1,
        .nonOwningReferencesV1,
        .compilerSpecializationsV1,
        .sequentialAsyncV1,
        .anyValuesV1,
        .localClassesV1,
        .hostedObjectiveCClassesV1,
    ]
}
}
