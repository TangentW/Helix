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
        case anyObjectBridge
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
        /// Module that owns the imported declaration. This controls call
        /// identity and policy even when the executable adapter must remain
        /// application-local because it references an application type.
        var declaringModuleName: String? = nil
        /// Reusable Pack placement. Nil identifies an application/compiler-
        /// local adapter that cannot enter a reusable module Pack.
        var nativeModuleName: String? = nil
        var accessLevel: String
        var dispatch: NativeImportDiscovery.Dispatch
        var ownerType: String?
        var baseName: String
        var argumentLabels: [String]
        var parameterSwiftTypes: [String]
        var physicalParameterSwiftTypes: [String]? = nil
        var invocationParameterSwiftTypes: [String]? = nil
        var parameterProjection: InterfaceArchive.NativeImportParameterProjection
        var resultSwiftType: String
        var importedModules: [String] = []
        var parameterTypes: [Bytecode.ValueType]
        var resultType: Bytecode.ValueType
        var signature: Core.LoweredSignature
        var callbacks: [Core.NativeImportCallback] = []
        var inferredEffects: Core.Effects
        var isGeneric: Bool
        var hasInOut: Bool
        var hasTypedThrows: Bool
        var hasUnsupportedAttributes: Bool
        var abiAdapter: InterfaceArchive.NativeImportABIAdapter = .direct
        var foreignDispatch: CanonicalSIL.NativeBridgeSymbols.ForeignDispatch =
            .ordinary
        var objectiveC: FrontendReceipt.ObjectiveCABI.Evidence? = nil
        var c: FrontendReceipt.CABI.Evidence? = nil
    }

    struct GeneratedBinding: Hashable, Sendable {
        var declarationMangledName: String
        var sourceFileLogicalID: String
        var dispatch: NativeImportDiscovery.Dispatch
        var ownerType: String?
        var baseName: String
        var argumentLabels: [String]
        var parameterSwiftTypes: [String]
        var invocationParameterSwiftTypes: [String]?
        var resultSwiftType: String
        var importedModules: [String]
        var nativeModuleName: String? = nil
        var cFunction: CFunctionBinding? = nil
    }

    /// Structured compiler-bound function reference for the generic C
    /// invoker. The Bridge renders this data; no project-supplied expression
    /// crosses the receipt boundary.
    struct CFunctionBinding: Hashable, Sendable {
        var moduleName: String
        var swiftName: String
        var parameterSwiftTypes: [String]
        var resultSwiftType: String
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
            configuration: PatchConfiguration.Document,
            nativeTypeKinds: [Core.TypeID: InterfaceArchive.TypeKind] = [:]
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
                    requiresMainActor: declaration.inferredEffects.requiresMainActor,
                    isAsync: declaration.inferredEffects.isAsync
                )
                let objectiveCPhysical: Core.NativeCall.PhysicalSignature? = if
                    !effects.isAsync,
                    let evidence = declaration.objectiveC {
                    FrontendReceipt.ObjectiveCABI.physicalSignature(
                        evidence: evidence,
                        logicalParameterTypes: declaration.parameterTypes,
                        logicalResultType: declaration.resultType,
                        nativeTypeKinds: nativeTypeKinds,
                        targetTriple: metadata.frontendInvocation.targetTriple
                    )
                } else {
                    nil
                }
                let cPhysical: Core.NativeCall.PhysicalSignature? = if
                    !effects.isAsync,
                    !effects.mayThrow,
                    let evidence = declaration.c {
                    FrontendReceipt.CABI.physicalSignature(
                        evidence: evidence,
                        logicalParameterTypes: declaration.parameterTypes,
                        logicalResultType: declaration.resultType,
                        nativeTypeKinds: nativeTypeKinds,
                        targetTriple: metadata.frontendInvocation.targetTriple
                    )
                } else {
                    nil
                }
                if declaration.foreignDispatch == .superclass,
                   objectiveCPhysical == nil
                    || declaration.objectiveC?.lexicalSuperclassName == nil {
                    diagnostics.append(
                        .init(
                            code: "HLXNID009",
                            severity: .note,
                            message: "\(declaration.canonicalCallee): lexical super dispatch requires an exact Objective-C ABI and superclass",
                            location: .init(
                                file: declaration.sourceFileLogicalID,
                                line: 1,
                                column: 1
                            )
                        )
                    )
                    continue
                }
                let domain = nativeDomain(
                    objectiveCPhysical != nil
                        ? declaration.objectiveC?.moduleName
                        : cPhysical != nil
                            ? declaration.c?.moduleName
                            : declaration.declaringModuleName
                )
                let contract = if effects.isAsync {
                    Core.NativeImportContract.suspending(
                        kind: contractKind(for: declaration.dispatch),
                        domain: domain,
                        access: operationAccess,
                        maximumDurationMicroseconds:
                            scope.maximumSuspendingDurationMicroseconds,
                        allowsMainThread: scope.allowsMainThread
                    )
                } else {
                    Core.NativeImportContract.bounded(
                        kind: contractKind(for: declaration.dispatch),
                        domain: domain,
                        access: operationAccess,
                        maximumDurationMicroseconds:
                            boundedDuration(
                                for: declaration,
                                scope: scope
                            ),
                        allowsMainThread: scope.allowsMainThread,
                        callbacks: declaration.callbacks
                    )
                }
                try contract.validate(effects: effects)
                let receiverIndex = isInstanceDispatch(declaration.dispatch)
                    ? declaration.signature.parameters.indices.last.flatMap {
                        UInt16(exactly: $0)
                    } : nil
                let callDescriptor: Core.NativeCall.Descriptor
                if let physicalSignature = objectiveCPhysical,
                   let evidence = declaration.objectiveC,
                   let moduleName = evidence.moduleName,
                   let owner = objectiveCOwner(
                       declaration.ownerType,
                       moduleName: moduleName
                   ) {
                    callDescriptor = try .objectiveCMessage(
                        module: moduleName,
                        owner: owner,
                        member: objectiveCMember(for: declaration),
                        selector: evidence.selector,
                        dispatch: nativeDispatch(for: declaration.dispatch),
                        receiverArgumentIndex: receiverIndex,
                        signature: declaration.signature,
                        effects: effects,
                        contract: contract,
                        argumentLabels: declaration.argumentLabels,
                        physicalSignature: physicalSignature,
                        metadata: .init(
                            runtimeClassName: evidence.runtimeClassName,
                            dispatchClassName: evidence.dispatchClassName,
                            methodFamily: evidence.methodFamily,
                            lexicalSuperclassName:
                                evidence.lexicalSuperclassName,
                            errorFailure: evidence.errorFailure,
                            property: evidence.property
                        )
                    )
                } else if let physicalSignature = cPhysical,
                          let evidence = declaration.c,
                          let moduleName = evidence.moduleName {
                    callDescriptor = try .cFunction(
                        module: moduleName,
                        member: declaration.baseName,
                        symbol: evidence.symbol,
                        signature: declaration.signature,
                        effects: effects,
                        contract: contract,
                        argumentLabels: declaration.argumentLabels,
                        physicalSignature: physicalSignature
                    )
                } else {
                    let physicalSources = try physicalArgumentSources(
                        projection: declaration.parameterProjection,
                        logicalParameterCount:
                            declaration.signature.parameters.count
                    )
                    callDescriptor = try .swiftAdapter(
                        canonicalCallee: declaration.canonicalCallee,
                        signature: declaration.signature,
                        effects: effects,
                        contract: contract,
                        argumentLabels: declaration.argumentLabels,
                        physicalParameterTypes:
                            declaration.physicalParameterSwiftTypes
                                ?? declaration.invocationParameterSwiftTypes
                                ?? declaration.parameterSwiftTypes,
                        physicalArgumentSources: physicalSources,
                        receiverArgumentIndex: receiverIndex
                    )
                }
                let key = try Core.NativeCall.Key.derive(
                    descriptor: callDescriptor
                )
                candidates.append(
                    .init(
                        record: .init(
                            id: nil,
                            key: key,
                            descriptor: callDescriptor,
                            silMangledNames: declaration.silSymbols.isEmpty
                                ? [declaration.mangledName]
                                : declaration.silSymbols,
                            parameterTypes: declaration.parameterTypes,
                            parameterProjection: declaration.parameterProjection,
                            resultType: declaration.resultType,
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
                            invocationParameterSwiftTypes:
                                declaration.invocationParameterSwiftTypes,
                            resultSwiftType: declaration.resultSwiftType,
                            importedModules: declaration.importedModules,
                            nativeModuleName: declaration.nativeModuleName,
                            cFunction: cPhysical.flatMap { physical in
                                guard let evidence = declaration.c,
                                      let moduleName = evidence.moduleName
                                else { return nil }
                                return .init(
                                    moduleName: moduleName,
                                    swiftName: declaration.baseName,
                                    parameterSwiftTypes: physical.parameters
                                        .compactMap { $0.type.canonicalName },
                                    resultSwiftType:
                                        physical.result.canonicalName
                                            ?? "Swift.Void"
                                )
                            }
                        )
                    )
                )
            }
            guard Set(candidates.map(\.record.key)).count == candidates.count else {
                throw FrontendReceipt.Error.invalidRequest(
                    "source NativeImport discovery produced duplicate identities"
                )
            }
            return .init(
                candidates: candidates.sorted { $0.record.key.rawValue < $1.record.key.rawValue },
                diagnostics: diagnostics.sorted(by: diagnosticOrder)
            )
        }

        private func physicalArgumentSources(
            projection: InterfaceArchive.NativeImportParameterProjection,
            logicalParameterCount: Int
        ) throws -> [Core.NativeCall.ArgumentSource] {
            guard projection.isValid(
                logicalParameterCount: logicalParameterCount
            ) else {
                throw FrontendReceipt.Error.invalidRequest(
                    "source NativeImport has an invalid physical parameter projection"
                )
            }
            let logicalByPhysical = Dictionary(uniqueKeysWithValues:
                projection.logicalParameterIndices.enumerated().map {
                    (physical: $0.element, logical: UInt16($0.offset))
                }
            )
            let defaultByPhysical = Dictionary(uniqueKeysWithValues:
                projection.defaultArguments.map {
                    ($0.physicalParameterIndex, $0)
                }
            )
            return try (0..<projection.physicalParameterCount).map { index in
                if let logical = logicalByPhysical[index] {
                    return .argument(logical)
                }
                guard let defaultArgument = defaultByPhysical[index] else {
                    throw FrontendReceipt.Error.invalidRequest(
                        "source NativeImport has an incomplete default-argument projection"
                    )
                }
                switch defaultArgument.origin {
                case .externalGenerator:
                    guard let symbol = defaultArgument.generatorSymbol else {
                        throw FrontendReceipt.Error.invalidRequest(
                            "source NativeImport default generator has no symbol"
                        )
                    }
                    return .defaultGenerator(symbol)
                case .optionalNone:
                    return .optionalNone
                }
            }
        }

        private func boundedDuration(
            for declaration: NativeImportDiscovery.Declaration,
            scope: PatchConfiguration.NativeImportSourceScope
        ) -> UInt32 {
            let ceiling = declaration.inferredEffects.requiresMainActor
                && scope.allowsMainThread
                ? Core.NativeImportExecutionPolicy
                    .maximumMainThreadDurationMicroseconds
                : Core.NativeImportExecutionPolicy
                    .maximumBoundedDurationMicroseconds
            return min(scope.maximumBoundedDurationMicroseconds, ceiling)
        }

        private func nativeDomain(_ moduleName: String?) -> Core.NativeImportDomain {
            switch moduleName {
            case "Foundation": .foundation
            case "UIKit": .uiKit
            default: .application
            }
        }

        private func objectiveCOwner(
            _ raw: String?,
            moduleName: String
        ) -> String? {
            guard var owner = raw, !owner.isEmpty else { return nil }
            let prefix = moduleName + "."
            if owner.hasPrefix(prefix) {
                owner.removeFirst(prefix.count)
            }
            return owner.isEmpty ? nil : owner
        }

        private func objectiveCMember(
            for declaration: NativeImportDiscovery.Declaration
        ) -> String {
            switch declaration.dispatch {
            case .instanceGetter, .staticGetter:
                return declaration.baseName + ".get"
            case .instanceSetter, .staticSetter:
                return declaration.baseName + ".set"
            case .instanceValueSetter:
                return declaration.baseName + ".mutate"
            case .initializer, .globalFunction, .staticMethod, .instanceMethod:
                return declaration.baseName + "("
                    + declaration.argumentLabels.map {
                        ($0 == "_" ? "_" : $0) + ":"
                    }.joined() + ")"
            case .nativeUpcast:
                return "upcast"
            case .anyObjectBridge:
                return "bridge"
            }
        }

        private func nativeDispatch(
            for dispatch: NativeImportDiscovery.Dispatch
        ) -> Core.NativeCall.Dispatch {
            switch dispatch {
            case .initializer: .initializer
            case .staticMethod, .nativeUpcast, .anyObjectBridge,
                 .staticGetter, .staticSetter:
                .static
            case .instanceMethod, .instanceGetter, .instanceSetter,
                 .instanceValueSetter:
                .instance
            case .globalFunction: .global
            }
        }

        private func rejection(
            for declaration: NativeImportDiscovery.Declaration,
            scope: PatchConfiguration.NativeImportSourceScope
        ) -> (code: String, reason: String)? {
            switch declaration.dispatch {
            case .globalFunction, .initializer, .staticMethod, .nativeUpcast,
                 .anyObjectBridge,
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
                guard supportsAsyncDispatch(declaration.dispatch) else {
                    return (
                        "HLXNID002",
                        "async NativeImport dispatch has no exact generated adapter"
                    )
                }
                guard declaration.callbacks.isEmpty,
                      !declaration.parameterTypes.contains(where: \.containsClosureValue),
                      !declaration.resultType.containsClosureValue
                else {
                    return (
                        "HLXNID002",
                        "closure values cannot cross a suspending NativeImport boundary"
                    )
                }
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
            guard isSwiftIdentifier(declaration.baseName)
                    || declaration.dispatch == .globalFunction
                        && Core.SwiftName.isOperator(declaration.baseName),
                  declaration.argumentLabels.allSatisfy({
                      $0 == "_" || isSwiftIdentifier($0)
                  })
            else {
                return ("HLXNID007", "callee name or argument label is not representable in generated Swift")
            }
            let explicitParameterTypes = isInstanceDispatch(declaration.dispatch)
                ? Array(declaration.parameterTypes.dropLast())
                : declaration.parameterTypes
            let invocationParameterSwiftTypes = declaration
                .invocationParameterSwiftTypes ?? declaration.parameterSwiftTypes
            let invocationAdapterIsValid: Bool = {
                guard let invocationTypes = declaration
                    .invocationParameterSwiftTypes
                else { return true }
                return invocationTypes != declaration.parameterSwiftTypes
                    && invocationTypes.allSatisfy(
                        FrontendReceipt.SwiftTypeSpelling.isGeneratedType
                    )
            }()
            guard let callbackLifetimes = FrontendReceipt.NativeBridgeProfile
                .authoritativeLifetimes(declaration.callbacks)
            else {
                return (
                    "HLXNID005",
                    "callback parameters are duplicated or invalid"
                )
            }
            let inferredCallbacks = FrontendReceipt.NativeBridgeProfile.callbacks(
                parameterSpellings: declaration.signature.parameters,
                parameterTypes: declaration.parameterTypes,
                authoritativeLifetimes: callbackLifetimes
            )
            guard declaration.argumentLabels.count == explicitParameterTypes.count,
                  declaration.parameterSwiftTypes.count == declaration.parameterTypes.count,
                  invocationParameterSwiftTypes.count
                    == declaration.parameterTypes.count,
                  invocationAdapterIsValid,
                  !isInstanceDispatch(declaration.dispatch)
                    || invocationParameterSwiftTypes.last
                        == declaration.ownerType,
                  declaration.parameterProjection.isValid(
                      logicalParameterCount: declaration.parameterTypes.count
                  ),
                  inferredCallbacks == declaration.callbacks,
                  FrontendReceipt.NativeBridgeProfile.isResult(
                      declaration.resultType
                  )
            else {
                return (
                    "HLXNID005",
                    "signature is outside the automatic indexed-value Bridge profile"
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
            case .nativeUpcast, .anyObjectBridge: return .pure
            case .globalFunction, .initializer, .staticMethod, .instanceMethod: break
            }
            return switch profile {
            case .pure: .pure
            case .read: .read
            case .readWrite: .readWrite
            }
        }

        private func supportsAsyncDispatch(
            _ dispatch: NativeImportDiscovery.Dispatch
        ) -> Bool {
            switch dispatch {
            case .globalFunction, .initializer, .staticMethod, .staticGetter,
                 .instanceMethod, .instanceGetter:
                true
            case .nativeUpcast, .anyObjectBridge, .staticSetter, .instanceSetter,
                 .instanceValueSetter:
                false
            }
        }

        private func contractKind(
            for dispatch: NativeImportDiscovery.Dispatch
        ) -> Core.NativeImportKind {
            switch dispatch {
            case .globalFunction: .globalFunction
            case .initializer: .initializer
            case .staticMethod, .nativeUpcast, .anyObjectBridge: .staticMethod
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
                 .anyObjectBridge,
                 .staticGetter, .staticSetter: false
            }
        }

        private func isNativeValue(_ type: Bytecode.ValueType) -> Bool {
            if case .native = type { return true }
            return false
        }

        private func isSwiftIdentifier(_ value: String) -> Bool {
            Core.SwiftName.isIdentifier(value)
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
