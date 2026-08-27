import Foundation
import HelixObjectiveCRuntimeSupport
#if canImport(HelixCore)
import HelixCore
import HelixVerifier
import HelixVM
#endif

extension Runtime {
/// Constructs reference TypeOps from Shell data. The class lookup happens once
/// while the immutable native type catalog is assembled; every later box still
/// checks the concrete object against Objective-C metadata without sending an
/// overridable introspection message.
public enum ObjectiveCTypeOperations {
    public static func make(
        shellType: Verification.ResolvedNativeType
    ) throws -> VM.NativeTypeOperations {
        guard shellType.kind == .reference,
              shellType.isCopyable,
              let runtimeName = shellType.objectiveCRuntimeName,
              Core.NativeCall.isCanonicalObjectiveCRuntimeClassName(runtimeName),
              let runtimeClass = NSClassFromString(runtimeName)
        else {
            throw VM.RuntimeTrap.nativeFailure(
                "Objective-C TypeOps metadata is invalid or class is unavailable for "
                    + shellType.canonicalName
            )
        }
        return .objectiveCReference(
            id: shellType.id,
            canonicalName: shellType.canonicalName,
            layoutFingerprint: shellType.layoutFingerprint,
            requiresMainActor: shellType.requiresMainActor,
            estimatedSize: shellType.estimatedSize,
            referenceClass: runtimeClass,
            accepts: { object in
                runtimeName.withCString { name in
                    helix_runtime_objective_c_object_is_kind_of(
                        Unmanaged.passUnretained(object).toOpaque(),
                        name
                    )
                }
            }
        )
    }
}
}
