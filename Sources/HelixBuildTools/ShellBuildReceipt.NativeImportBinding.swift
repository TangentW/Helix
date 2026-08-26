import HelixCompiler
import HelixCore
import HelixInterface

extension ShellBuildReceipt.NativeImportBinding {
/// Binds one receipt strategy to a concrete compact ID without changing its
/// stable NativeCallKey. Release materialization and trusted development
/// Adapter generation deliberately share this conversion.
public func bridgeBinding(
    for record: InterfaceArchive.NativeImportRecord
) throws -> BridgeGeneration.NativeImportBinding {
    guard key == record.key, let id = record.id else {
        throw ShellBuild.Error.nativeImportBindingMismatch
    }
    let bridgeStrategy: BridgeGeneration.NativeImportBinding.Strategy = switch
        strategy
    {
    case .factory: .factory
    case .generatedSwiftAdapter: .generatedSwiftAdapter
    case .objectiveCInvoker: .objectiveCInvoker
    case .cInvoker: .cInvoker
    }
    return .init(
        id: id,
        key: key,
        strategy: bridgeStrategy,
        factoryReference: factoryReference,
        importedModules: importedModules,
        generated: generated.map { generated in
            let dispatch: BridgeGeneration.GeneratedNativeImport.Dispatch =
                switch generated.dispatch {
                case .globalFunction: .globalFunction
                case .initializer: .initializer
                case .staticMethod: .staticMethod
                case .nativeUpcast: .nativeUpcast
                case .anyObjectBridge: .anyObjectBridge
                case .staticGetter: .staticGetter
                case .staticSetter: .staticSetter
                case .instanceMethod: .instanceMethod
                case .instanceGetter: .instanceGetter
                case .instanceSetter: .instanceSetter
                case .instanceValueSetter: .instanceValueSetter
                }
            return .init(
                declarationMangledName: generated.declarationMangledName,
                sourceFileLogicalID: generated.sourceFileLogicalID,
                dispatch: dispatch,
                ownerType: generated.ownerType,
                baseName: generated.baseName,
                argumentLabels: generated.argumentLabels,
                parameterSwiftTypes: generated.parameterSwiftTypes,
                invocationParameterSwiftTypes:
                    generated.invocationParameterSwiftTypes,
                resultSwiftType: generated.resultSwiftType,
                nativeModuleName: generated.nativeModuleName
            )
        },
        cFunction: cFunction.map {
            .init(
                moduleName: $0.moduleName,
                swiftName: $0.swiftName,
                parameterSwiftTypes: $0.parameterSwiftTypes,
                resultSwiftType: $0.resultSwiftType
            )
        }
    )
}
}
