import HelixCompiler
import HelixCore
import HelixInterface

extension ShellBuildReceipt.NativeTypeBinding {
/// Converts validated receipt metadata into the compiler-facing TypeOps
/// binding used by both release materialization and development Adapters.
public func bridgeBinding(
    for record: InterfaceArchive.TypeRecord
) throws -> BridgeGeneration.NativeTypeBinding {
    guard canonicalName == record.canonicalName,
          layoutFingerprint == record.layoutFingerprint,
          requiresMainActor == record.requiresMainActor
    else { throw ShellBuild.Error.nativeTypeBindingMismatch }
    let bridgeStrategy: BridgeGeneration.NativeTypeBinding.Strategy = switch
        strategy
    {
    case .factory: .factory
    case .objectiveCReference: .objectiveCReference
    }
    return .init(
        id: record.id,
        canonicalName: canonicalName,
        layoutFingerprint: layoutFingerprint,
        requiresMainActor: requiresMainActor,
        strategy: bridgeStrategy,
        operationsExpression: operationsExpression,
        importedModules: importedModules,
        generated: generated.map { generated in
            let representation: BridgeGeneration.GeneratedNativeType
                .Representation = switch generated.representation {
            case .reference: .reference
            case .rawRepresentable: .rawRepresentable
            case .opaqueValue: .opaqueValue
            case .objectiveCStructure: .objectiveCStructure
            }
            return .init(
                sourceFileLogicalID: generated.sourceFileLogicalID,
                swiftType: generated.swiftType,
                representation: representation,
                nativeABIEncoding: generated.nativeABIEncoding,
                nativeModuleName: generated.nativeModuleName
            )
        }
    )
}
}
