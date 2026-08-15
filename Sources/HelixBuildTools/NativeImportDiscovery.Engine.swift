import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

/// Build-time source discovery for NativeImport. A selected range is always
/// expanded into exact per-operation records; no wildcard reaches the device.
enum NativeImportDiscovery {}

extension NativeImportDiscovery {
    enum Dispatch: String, Codable, Hashable, Sendable {
        case globalFunction
        case initializer
        case staticMethod
        case nativeUpcast
        case instanceMethod
        case staticGetter
        case staticSetter
        case instanceGetter
        case instanceSetter
        case instanceValueSetter
    }

    struct Declaration: Hashable, Sendable {
        var moduleName: String
        var sourceFileLogicalID: String
        var mangledName: String
        var silSymbols: [String] = []
        var canonicalCallee: String
        var accessLevel: String
        var dispatch: NativeImportDiscovery.Dispatch
        var ownerType: String?
        var baseName: String
        var argumentLabels: [String]
        var parameterSwiftTypes: [String]
        var resultSwiftType: String
        var importedModules: [String] = []
        var parameterTypes: [Bytecode.ValueType]
        var resultType: Bytecode.ValueType
        var signature: Core.LoweredSignature
        var inferredEffects: Core.Effects
        var isGeneric: Bool
        var hasInOut: Bool
        var hasTypedThrows: Bool
        var hasUnsupportedAttributes: Bool
        var abiAdapter: InterfaceArchive.NativeImportABIAdapter = .direct
    }

    struct GeneratedBinding: Hashable, Sendable {
        var declarationMangledName: String
        var sourceFileLogicalID: String
        var dispatch: NativeImportDiscovery.Dispatch
        var ownerType: String?
        var baseName: String
        var argumentLabels: [String]
        var parameterSwiftTypes: [String]
        var resultSwiftType: String
        var importedModules: [String]
    }

    struct Candidate: Hashable, Sendable {
        var record: InterfaceArchive.NativeImportRecord
        var generatedBinding: NativeImportDiscovery.GeneratedBinding
    }

    struct Result: Sendable {
        var candidates: [NativeImportDiscovery.Candidate]
        var diagnostics: [Core.Diagnostic]
    }

    struct Engine: Sendable {
        func discover(
            declarations: [NativeImportDiscovery.Declaration],
            metadata: InterfaceArchive.ReleaseMetadata,
            configuration: PatchConfiguration.Document
        ) throws -> NativeImportDiscovery.Result {
            try configuration.validate()
            guard let module = configuration.modules[metadata.frontendInvocation.moduleName],
                  module.nativeImports.candidateIndex == .sourceAndCatalog,
                  module.nativeImports.emit == .scoped,
                  let scope = module.nativeImports.sourceScope,
                  let profile = scope.profile
            else {
                return .init(candidates: [], diagnostics: [])
            }
            guard declarations.allSatisfy({
                $0.moduleName == metadata.frontendInvocation.moduleName
            }) else {
                throw FrontendReceipt.Error.invalidRequest(
                    "source NativeImport discovery received declarations from another Swift module"
                )
            }

            var candidates: [NativeImportDiscovery.Candidate] = []
            var diagnostics: [Core.Diagnostic] = []
            for declaration in declarations.sorted(by: declarationOrder) {
                guard scope.includes(
                    logicalPath: declaration.sourceFileLogicalID,
                    canonicalCallee: declaration.canonicalCallee,
                    accessLevel: declaration.accessLevel
                ) else { continue }
                if let rejection = rejection(
                    for: declaration,
                    scope: scope
                ) {
                    diagnostics.append(
                        .init(
                            code: rejection.code,
                            severity: .note,
                            message: "\(declaration.canonicalCallee): \(rejection.reason)",
                            location: .init(
                                file: declaration.sourceFileLogicalID,
                                line: 1,
                                column: 1
                            )
                        )
                    )
                    continue
                }

                let operationAccess = access(
                    for: profile,
                    dispatch: declaration.dispatch
                )
                let effects = Core.Effects(
                    mayThrow: declaration.inferredEffects.mayThrow,
                    mayAllocate: true,
                    hasExternalSideEffects: operationAccess.hasExternalSideEffects,
                    requiresMainActor: declaration.inferredEffects.requiresMainActor
                )
                let contract = Core.NativeImportContract.bounded(
                    kind: contractKind(for: declaration.dispatch),
                    domain: .application,
                    access: operationAccess,
                    maximumDurationMicroseconds: scope.maximumDurationMicroseconds,
                    allowsMainThread: scope.allowsMainThread
                )
                try contract.validate(effects: effects)
                let key = try Core.NativeImportKey.derive(
                    namespace: metadata.shellNamespaceID,
                    canonicalCallee: declaration.canonicalCallee,
                    signature: declaration.signature,
                    effects: effects,
                    contract: contract
                )
                candidates.append(
                    .init(
                        record: .init(
                            id: nil,
                            key: key,
                            canonicalCallee: declaration.canonicalCallee,
                            silMangledNames: declaration.silSymbols.isEmpty
                                ? [declaration.mangledName]
                                : declaration.silSymbols,
                            parameterTypes: declaration.parameterTypes,
                            resultType: declaration.resultType,
                            signature: declaration.signature,
                            effects: effects,
                            contract: contract,
                            capability: .nativeImportsV1,
                            isEmittedToDevice: true,
                            abiAdapter: declaration.abiAdapter
                        ),
                        generatedBinding: .init(
                            declarationMangledName: declaration.mangledName,
                            sourceFileLogicalID: declaration.sourceFileLogicalID,
                            dispatch: declaration.dispatch,
                            ownerType: declaration.ownerType,
                            baseName: declaration.baseName,
                            argumentLabels: declaration.argumentLabels,
                            parameterSwiftTypes: declaration.parameterSwiftTypes,
                            resultSwiftType: declaration.resultSwiftType,
                            importedModules: declaration.importedModules
                        )
                    )
                )
            }
            guard Set(candidates.map(\.record.key)).count == candidates.count,
                  Set(candidates.flatMap(\.record.silMangledNames)).count
                    == candidates.reduce(0, { $0 + $1.record.silMangledNames.count })
            else {
                throw FrontendReceipt.Error.invalidRequest(
                    "source NativeImport discovery produced duplicate identities"
                )
            }
            return .init(
                candidates: candidates.sorted { $0.record.key.rawValue < $1.record.key.rawValue },
                diagnostics: diagnostics.sorted(by: diagnosticOrder)
            )
        }

        private func rejection(
            for declaration: NativeImportDiscovery.Declaration,
            scope: PatchConfiguration.NativeImportSourceScope
        ) -> (code: String, reason: String)? {
            switch declaration.dispatch {
            case .globalFunction, .initializer, .staticMethod, .nativeUpcast,
                 .staticGetter, .staticSetter:
                break
            case .instanceMethod, .instanceGetter, .instanceSetter:
                guard declaration.ownerType != nil,
                      declaration.parameterTypes.last.map(isNativeValue) == true,
                      declaration.parameterSwiftTypes.count == declaration.parameterTypes.count,
                      declaration.argumentLabels.count + 1 == declaration.parameterTypes.count
                else {
                    return (
                        "HLXNID001",
                        "instance NativeImport requires one exact source-class receiver as its final physical parameter"
                    )
                }
            case .instanceValueSetter:
                guard declaration.ownerType != nil,
                      declaration.parameterTypes.count == 2,
                      declaration.parameterTypes.last.map(isNativeValue) == true,
                      declaration.resultType == declaration.parameterTypes.last,
                      declaration.argumentLabels == ["_"],
                      declaration.abiAdapter == .mutatingValueReceiver
                else {
                    return (
                        "HLXNID001",
                        "mutating value NativeImport requires one exact value receiver"
                    )
                }
            }
            if declaration.inferredEffects.isAsync {
                return ("HLXNID002", "async NativeImport requires a suspension-aware contract")
            }
            if declaration.isGeneric || declaration.hasInOut || declaration.hasTypedThrows {
                return (
                    "HLXNID003",
                    "generic, inout/ownership, and typed-throws declarations require an explicit ABI adapter"
                )
            }
            if declaration.hasUnsupportedAttributes {
                return (
                    "HLXNID004",
                    "custom calling or isolation attributes require an explicit catalog factory"
                )
            }
            guard isSwiftIdentifier(declaration.baseName),
                  declaration.argumentLabels.allSatisfy({
                      $0 == "_" || isSwiftIdentifier($0)
                  })
            else {
                return ("HLXNID007", "callee name or argument label is not representable in generated Swift")
            }
            let explicitParameterTypes = isInstanceDispatch(declaration.dispatch)
                ? Array(declaration.parameterTypes.dropLast())
                : declaration.parameterTypes
            guard declaration.argumentLabels.count == explicitParameterTypes.count,
                  declaration.parameterSwiftTypes.count == declaration.parameterTypes.count,
                  explicitParameterTypes.allSatisfy(isAutomaticallyBridgeable),
                  isAutomaticallyBridgeableResult(declaration.resultType)
            else {
                return (
                    "HLXNID005",
                    "signature is outside the automatic frozen-value Bridge profile"
                )
            }
            if declaration.inferredEffects.requiresMainActor && !scope.allowsMainThread {
                return (
                    "HLXNID006",
                    "MainActor declaration is excluded because the sourceScope forbids main-thread execution"
                )
            }
            guard declaration.dispatch == .globalFunction
                    || declaration.ownerType.map(FrontendReceipt.SwiftTypeSpelling.isGeneratedType) == true
            else {
                return ("HLXNID007", "static owner is not a representable Swift type path")
            }
            return nil
        }

        private func access(
            for profile: PatchConfiguration.NativeImportSourceProfile,
            dispatch: NativeImportDiscovery.Dispatch
        ) -> Core.NativeImportAccess {
            switch dispatch {
            case .instanceGetter, .staticGetter: return .read
            case .instanceSetter, .instanceValueSetter, .staticSetter: return .write
            case .nativeUpcast: return .pure
            case .globalFunction, .initializer, .staticMethod, .instanceMethod: break
            }
            return switch profile {
            case .boundedPure: .pure
            case .boundedRead: .read
            case .boundedReadWrite: .readWrite
            }
        }

        private func contractKind(
            for dispatch: NativeImportDiscovery.Dispatch
        ) -> Core.NativeImportKind {
            switch dispatch {
            case .globalFunction: .globalFunction
            case .initializer: .initializer
            case .staticMethod, .nativeUpcast: .staticMethod
            case .staticGetter: .staticGetter
            case .staticSetter: .staticSetter
            case .instanceMethod: .instanceMethod
            case .instanceGetter: .instanceGetter
            case .instanceSetter, .instanceValueSetter: .instanceSetter
            }
        }

        private func isInstanceDispatch(_ dispatch: NativeImportDiscovery.Dispatch) -> Bool {
            switch dispatch {
            case .instanceMethod, .instanceGetter, .instanceSetter,
                 .instanceValueSetter: true
            case .globalFunction, .initializer, .staticMethod, .nativeUpcast,
                 .staticGetter, .staticSetter: false
            }
        }

        private func isNativeValue(_ type: Bytecode.ValueType) -> Bool {
            if case .native = type { return true }
            return false
        }

        private func isAutomaticallyBridgeable(_ type: Bytecode.ValueType) -> Bool {
            switch type {
            case .bool, .integer, .float, .string, .any, .native:
                true
            case let .array(element), let .optional(element):
                isAutomaticallyBridgeable(element)
            case let .dictionary(key, value):
                isDictionaryKey(key) && isAutomaticallyBridgeable(value)
            case let .tuple(elements):
                !elements.isEmpty && elements.allSatisfy(isAutomaticallyBridgeable)
            case .void, .never, .local, .error, .address, .closure:
                false
            }
        }

        private func isAutomaticallyBridgeableResult(_ type: Bytecode.ValueType) -> Bool {
            type == .void || isAutomaticallyBridgeable(type)
        }

        private func isDictionaryKey(_ type: Bytecode.ValueType) -> Bool {
            switch type {
            case .bool, .integer, .string: true
            default: false
            }
        }

        private func isSwiftIdentifier(_ value: String) -> Bool {
            guard let first = value.first, first == "_" || first.isLetter else {
                return false
            }
            return value.dropFirst().allSatisfy {
                $0 == "_" || $0.isLetter || $0.isNumber
            }
        }

        private func declarationOrder(
            _ lhs: NativeImportDiscovery.Declaration,
            _ rhs: NativeImportDiscovery.Declaration
        ) -> Bool {
            (lhs.sourceFileLogicalID, lhs.canonicalCallee, lhs.mangledName)
                < (rhs.sourceFileLogicalID, rhs.canonicalCallee, rhs.mangledName)
        }

        private func diagnosticOrder(_ lhs: Core.Diagnostic, _ rhs: Core.Diagnostic) -> Bool {
            (
                lhs.location?.file ?? "",
                lhs.location?.line ?? 0,
                lhs.code,
                lhs.message
            ) < (
                rhs.location?.file ?? "",
                rhs.location?.line ?? 0,
                rhs.code,
                rhs.message
            )
        }
    }
}
