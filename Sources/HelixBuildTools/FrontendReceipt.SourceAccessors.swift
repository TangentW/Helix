import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt.Adapter {
    /// Builds Shell roots for explicit computed-property and subscript accessors.
    /// The typed parent declaration owns replacement syntax while canonical SIL
    /// remains authoritative for each accessor's executable ABI.
    func makeReloadableAccessorDrafts(
        _ item: FrontendReceipt.TypedAST.Object,
        context: NominalContext?,
        source: SourceState,
        importedModules: [String],
        moduleName: String,
        configuration: PatchConfiguration.Document,
        demangled: [String: String],
        silFile: CanonicalSIL.File,
        typeEnvironment: CanonicalSIL.TypeEnvironment,
        nativeTypes: [String: Core.TypeID],
        localValueTypes: [String: Bytecode.LocalTypeKey],
        importedSwiftTypeAliases: [String: String]
    ) throws -> [Draft]? {
        guard let kind = item["_kind"] as? String,
            ["var_decl", "subscript_decl"].contains(kind),
            let declarationUSR = item["usr"] as? String,
            declarationUSR.hasPrefix("s:"),
            !Self.hasGenericSignature(item),
            let accessors = item["accessors"] as? [FrontendReceipt.TypedAST.Object],
            context?.kind != .actor,
            context?.isFileScopeNameable != false,
            context?.isAvailabilityConstrained != true,
            context?.isGenericContext != true,
            kind != "subscript_decl" || context != nil
        else { return nil }

        let explicitCoroutines = accessors.contains {
            $0["implicit"] as? Bool != true
                && ($0["_read"] as? Bool == true || $0["_modify"] as? Bool == true)
        }
        guard !explicitCoroutines,
            let getter = accessors.first(where: {
                $0["get"] as? Bool == true && $0["implicit"] as? Bool != true
            })
        else { return nil }

        let setter = accessors.first {
            $0["set"] as? Bool == true && $0["implicit"] as? Bool != true
        }
        switch kind {
        case "var_decl":
            guard item["readImpl"] as? String == "getter",
                item["writeImpl"] == nil || item["writeImpl"] as? String == "setter"
            else { return nil }
        case "subscript_decl":
            guard item["readImpl"] as? String == "getter",
                item["writeImpl"] == nil || item["writeImpl"] as? String == "setter"
            else { return nil }
        default:
            return nil
        }

        let parentAttributeKinds = Set(
            (item["attrs"] as? [FrontendReceipt.TypedAST.Object] ?? []).compactMap {
                $0["_kind"] as? String
            }
        )
        let forbiddenAttributes: Set<String> = [
            "transparent_attr", "inlinable_attr", "always_emit_into_client_attr",
            "cdecl_attr", "silgen_name_attr", "available_attr",
        ]
        guard parentAttributeKinds.isDisjoint(with: forbiddenAttributes),
            hasOnlySupportedAccessorAttributes(
                item,
                accessors: [getter] + (setter.map { [$0] } ?? []),
                demangled: demangled,
                forbiddenAttributes: forbiddenAttributes
            )
        else { return nil }

        let isStatic = item["static"] as? Bool == true
        let access = item["access"] as? String ?? "internal"
        let sourceOwnerType = context.flatMap {
            sourceTypeReference($0.canonicalName)
        }
        guard context == nil || sourceOwnerType != nil,
            !isStatic || context != nil
        else { return nil }
        let receiver: (swiftType: String, valueType: Bytecode.ValueType)? = {
            guard !isStatic, let context, let sourceOwnerType else { return nil }
            if let id = context.referenceTypeID {
                return (sourceOwnerType, .native(id))
            }
            if let key = context.localValueTypeKey {
                return (sourceOwnerType, .local(key))
            }
            return nil
        }()

        let memberInputs: [(FrontendReceipt.TypedAST.Object, Core.DynamicReplacement.MemberRole)] =
            [(getter, .getter)] + (setter.map { [($0, .setter)] } ?? [])
        var memberPlans: [SourceAccessorMemberPlan] = []
        for (accessor, role) in memberInputs {
            let sil = try resolvedAccessorFunction(
                accessor,
                source: source,
                silFile: silFile,
                declarationUSR: declarationUSR
            )
            guard
                let parameters = try sourceAccessorParameters(
                    accessor,
                    demangled: demangled,
                    importedSwiftTypeAliases: importedSwiftTypeAliases
                )
            else { return nil }
            memberPlans.append(
                .init(
                    accessor: accessor,
                    role: role,
                    sil: sil,
                    parameters: parameters,
                    syntax: try sourceAccessorSyntax(
                        accessor,
                        role: role,
                        sil: sil,
                        source: source,
                        context: context,
                        isStatic: isStatic
                    )
                ))
        }
        if kind == "var_decl" {
            guard memberPlans[0].parameters.isEmpty,
                setter == nil
                    || (memberPlans.count == 2
                        && memberPlans[1].parameters.count == 1)
            else {
                throw FrontendReceipt.Error.malformedAST(
                    "computed property \(declarationUSR) has an invalid accessor parameter shape"
                )
            }
        }
        guard
            memberPlans.allSatisfy({
                supportedIsolation($0.sil.isolation)
                    && !$0.syntax.hasTypedThrows
                    && ($0.role == .getter || !$0.syntax.mayThrow)
                    && ($0.role == .getter
                        || !$0.sil.loweredType.contains("@async"))
            })
        else { return nil }
        let declarationRequiresMainActor = accessorRequiresMainActor(
            item,
            accessor: memberPlans[0].accessor,
            sil: memberPlans[0].sil,
            demangled: demangled
        )
        guard
            memberPlans.allSatisfy({ member in
                accessorRequiresMainActor(
                    item,
                    accessor: member.accessor,
                    sil: member.sil,
                    demangled: demangled
                ) == declarationRequiresMainActor
            })
        else { return nil }
        let isolationPrefix = declarationRequiresMainActor ? "@MainActor " : ""

        let declarationSite: SourceAccessorDeclarationSite
        let sourceDeclaration: Core.DynamicReplacement.Declaration
        let replacementName: String
        let originalLabels: [String]
        let getterIndexParameters: [SourceAccessorParameter]
        let generatedResultType: String
        let canonicalResultType: String
        let declarationBaseName: String

        if kind == "var_decl" {
            guard let name = baseName(in: item), Self.isSwiftIdentifier(name) else {
                return nil
            }
            let propertyType = try demangledType(item["interface_type"], using: demangled)
            let generatedPropertyType = FrontendReceipt.SwiftTypeSpelling
                .replacingNominalAliases(
                    in: propertyType,
                    aliases: importedSwiftTypeAliases
                )
            declarationSite = try propertyDeclarationSite(
                item,
                name: name,
                source: source
            )
            guard let propertySourceName = declarationSite.sourceName else {
                throw FrontendReceipt.Error.malformedAST(
                    "\(source.logicalPath): computed property has no source spelling"
                )
            }
            replacementName = SwiftFrontend.DynamicReplacement.replacementBaseName(
                usr: declarationUSR,
                baseName: name
            )
            declarationBaseName = name
            originalLabels = []
            getterIndexParameters = []
            generatedResultType = generatedPropertyType
            canonicalResultType = propertyType
            let members = try accessorMembers(
                getter: memberPlans[0].syntax,
                setter: setter == nil ? nil : memberPlans[1].syntax,
                originalReference: propertySourceName,
                originalLabels: [],
                getterIndexParameters: [],
                isStatic: isStatic
            )
            let memberModifier = try typeMemberModifier(
                isStatic: isStatic,
                declarationOffset: declarationSite.declarationUTF8Offset,
                source: source
            )
            sourceDeclaration = .init(
                identity: declarationUSR,
                kind: .property,
                originalReference: propertySourceName,
                replacementHeader: isolationPrefix + memberModifier
                    + "var \(replacementName): \(generatedPropertyType)",
                members: members,
                enclosingPrefix: sourceOwnerType.map { "extension \($0) {" } ?? "",
                enclosingSuffix: sourceOwnerType == nil ? "" : "}"
            )
        } else {
            guard context != nil, let sourceOwnerType else { return nil }
            let labels = argumentLabels(in: item)
            guard let sourceLabels = sourceArgumentLabels(labels) else { return nil }
            let parameters = memberPlans[0].parameters
            guard !parameters.isEmpty, labels.count == parameters.count else {
                return nil
            }
            let resultType = try demangledType(getter["result"], using: demangled)
            let generatedType = FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
                in: resultType,
                aliases: importedSwiftTypeAliases
            )
            declarationSite = try subscriptDeclarationSite(item, source: source)
            replacementName = SwiftFrontend.DynamicReplacement.replacementBaseName(
                usr: declarationUSR,
                baseName: "subscript"
            )
            declarationBaseName = "subscript"
            originalLabels = labels
            getterIndexParameters = parameters
            generatedResultType = generatedType
            canonicalResultType = resultType
            let originalReference = Self.originalReference(
                baseName: "subscript",
                labels: sourceLabels
            )
            let members = try accessorMembers(
                getter: memberPlans[0].syntax,
                setter: setter == nil ? nil : memberPlans[1].syntax,
                originalReference: originalReference,
                originalLabels: sourceLabels,
                getterIndexParameters: parameters,
                isStatic: isStatic
            )
            let renderedParameters = renderSubscriptParameters(
                parameters,
                labels: sourceLabels,
                replacementFirstLabel: replacementName
            )
            let memberModifier = try typeMemberModifier(
                isStatic: isStatic,
                declarationOffset: declarationSite.declarationUTF8Offset,
                source: source
            )
            sourceDeclaration = .init(
                identity: declarationUSR,
                kind: .subscriptDeclaration,
                originalReference: originalReference,
                replacementHeader: isolationPrefix + memberModifier
                    + "subscript(\(renderedParameters)) -> \(generatedType)",
                members: members,
                enclosingPrefix: "extension \(sourceOwnerType) {",
                enclosingSuffix: "}"
            )
        }
        guard sourceDeclaration.isWellFormed else {
            throw FrontendReceipt.Error.unsupportedDeclaration(
                "\(source.logicalPath): computed accessor declaration has an invalid replacement shape"
            )
        }

        let declarationInsertion: String? =
            parentAttributeKinds.contains("dynamic_attr")
                || item["dynamic"] as? Bool == true ? nil : "dynamic "
        return try memberPlans.map { member in
            let accessor = member.accessor
            let memberRole = member.role
            let sil = member.sil
            let syntax = member.syntax
            let memberAccess = accessor["access"] as? String ?? access
            let selectedByConfiguration =
                configuration.modules[moduleName]?.includes(
                    logicalPath: source.logicalPath
                ) == true
                && configuration.modules[moduleName]?.entrypoints.allows(
                    accessLevel: memberAccess
                ) == true
            let explicitParameters = member.parameters
            if memberRole == .getter, kind == "subscript_decl" {
                guard explicitParameters == getterIndexParameters else {
                    throw FrontendReceipt.Error.malformedAST(
                        "subscript getter parameter metadata changed while indexing"
                    )
                }
            }
            if memberRole == .setter, kind == "subscript_decl" {
                guard explicitParameters.count == getterIndexParameters.count + 1,
                    Array(explicitParameters.dropFirst()) == getterIndexParameters
                else {
                    throw FrontendReceipt.Error.malformedAST(
                        "subscript setter parameters do not match its getter"
                    )
                }
            }
            let explicitSwiftTypes = explicitParameters.map(\.swiftType)
            let generatedExplicitSwiftTypes = explicitParameters.map(\.generatedSwiftType)
            let explicitValueTypes = explicitSwiftTypes.map {
                FrontendReceipt.ValueTypeParser.parse(
                    $0,
                    allowVoid: false,
                    nativeTypes: nativeTypes,
                    localTypes: localValueTypes
                ) ?? .never
            }
            let parameterSwiftTypes =
                explicitSwiftTypes
                + (receiver.map { [$0.swiftType] } ?? [])
            let generatedParameterSwiftTypes =
                generatedExplicitSwiftTypes
                + (receiver.map { [$0.swiftType] } ?? [])
            let parameterTypes =
                explicitValueTypes
                + (receiver.map { [$0.valueType] } ?? [])
            let resultSwiftType =
                memberRole == .setter
                ? "Swift.Void" : canonicalResultType
            let generatedAccessorResultType =
                memberRole == .setter
                ? "Swift.Void" : generatedResultType
            let resultType: Bytecode.ValueType =
                memberRole == .setter
                ? .void
                : FrontendReceipt.ValueTypeParser.parse(
                    canonicalResultType,
                    allowVoid: false,
                    nativeTypes: nativeTypes,
                    localTypes: localValueTypes
                ) ?? .never
            let parameterConventions = try CanonicalSIL.Lowerer(
                typeEnvironment: typeEnvironment
            ).parseParameterConventions(
                sil.loweredType,
                parameterTypes: parameterTypes
            )
            guard parameterConventions.count == parameterTypes.count else {
                throw FrontendReceipt.Error.malformedAST(
                    "\(sil.mangledName) has an inconsistent accessor ownership signature"
                )
            }
            let requiresMainActor = declarationRequiresMainActor
            let isolation = requiresMainActor ? "MainActor" : nil
            let isAsync = sil.loweredType.range(
                of: #"(?:^|\s)@async(?:\s|$)"#,
                options: .regularExpression
            ) != nil
            let effects = Core.Effects(
                mayThrow: syntax.mayThrow,
                requiresMainActor: requiresMainActor,
                isAsync: isAsync
            )
            let interfaceLabels: [String]
            if kind == "var_decl" {
                interfaceLabels = memberRole == .setter ? ["_"] : []
            } else {
                interfaceLabels =
                    memberRole == .setter
                    ? ["_"] + originalLabels : originalLabels
            }
            let canonicalReference =
                kind == "var_decl"
                ? declarationBaseName
                : Self.originalReference(baseName: "subscript", labels: originalLabels)
            let canonicalDeclaration =
                (context.map { "\($0.canonicalName)." } ?? "")
                + "\(canonicalReference)."
                + (memberRole == .getter ? "getter" : "setter")
            let forcedPatchability: InterfaceArchive.Patchability?
            if selectedByConfiguration && isAsync {
                forcedPatchability = .rejected(
                    "HLXIDX005",
                    explanation: "async computed accessors are NativeImport-only in sequential async v1"
                )
            } else if context != nil && !isStatic && receiver == nil {
                forcedPatchability = .rejected(
                    "HLXIDX020",
                    explanation: "this accessor receiver has no ABI-safe HLBC self Bridge"
                )
            } else {
                forcedPatchability = nil
            }
            let interface = ReleaseCompiler.DeclarationInterface(
                declarationKind: memberRole == .getter
                    ? "source-accessor-getter" : "source-accessor-setter",
                baseName: declarationBaseName,
                argumentLabels: interfaceLabels.map { $0.isEmpty ? "_" : $0 },
                accessLevel: memberAccess,
                canonicalFormalType: try demangledType(
                    accessor["interface_type"],
                    using: demangled
                ),
                loweredSILType: sil.loweredType,
                effects: effects,
                isolation: isolation,
                dispatchIdentity: accessor["usr"] as? String
            )
            let candidate = ReleaseCompiler.DeclarationCandidate(
                moduleName: moduleName,
                sourceFileLogicalID: source.logicalPath,
                canonicalDeclaration: canonicalDeclaration,
                mangledName: sil.mangledName,
                role: memberRole == .getter ? .getter : .setter,
                loweredSignature: .init(
                    parameters: explicitSwiftTypes,
                    result: resultSwiftType,
                    isThrowing: syntax.mayThrow,
                    isAsync: isAsync,
                    isolation: isolation
                ),
                parameterTypes: parameterTypes,
                parameterConventions: parameterConventions,
                resultType: resultType,
                interface: interface,
                canonicalSILBody: sil.body,
                effects: effects,
                isAsync: isAsync,
                hasInOut: parameterConventions.contains(.inout),
                hasCompleteDynamicCoverage: true,
                forcedPatchability: forcedPatchability
            )

            let root: ShellBuildReceipt.Root? =
                if selectedByConfiguration && !isAsync {
                    try makeAccessorRoot(
                        accessor: accessor,
                        memberRole: memberRole,
                        declarationSite: declarationSite,
                        declarationInsertion: declarationInsertion,
                        sourceDeclaration: sourceDeclaration,
                        sil: sil,
                        source: source,
                        importedModules: importedModules,
                        context: context,
                        moduleName: moduleName
                    )
                } else {
                    nil
                }
            let bridge = isAsync ? nil : makeAccessorBridge(
                declarationKind: kind,
                memberRole: memberRole,
                replacementName: replacementName,
                sourcePropertyName: kind == "var_decl"
                    ? sourceDeclaration.originalReference : nil,
                originalLabels: originalLabels,
                explicitParameters: explicitParameters,
                generatedParameterSwiftTypes: generatedParameterSwiftTypes,
                generatedResultSwiftType: generatedAccessorResultType,
                receiver: receiver,
                context: context,
                isStatic: isStatic,
                parameterConventions: parameterConventions,
                parameterTypes: parameterTypes,
                resultType: resultType,
                source: source
            )
            let nativeImport = try makeAccessorNativeImport(
                declarationKind: kind,
                memberRole: memberRole,
                baseName: declarationBaseName,
                parameterSwiftTypes: parameterSwiftTypes,
                generatedParameterSwiftTypes: generatedParameterSwiftTypes,
                parameterTypes: parameterTypes,
                resultSwiftType: resultSwiftType,
                generatedResultSwiftType: generatedAccessorResultType,
                resultType: resultType,
                parameterConventions: parameterConventions,
                sil: sil,
                source: source,
                importedModules: importedModules,
                moduleName: moduleName,
                context: context,
                access: memberAccess,
                effects: effects,
                isolation: isolation,
                isStatic: isStatic,
                configuration: configuration
            )
            return .init(
                candidate: candidate,
                root: root,
                bridge: bridge,
                nativeImportDeclaration: nativeImport,
                referenceReceiverType: context?.referenceTypeID == nil || isStatic
                    ? nil : context?.moduleQualifiedName
            )
        }
    }
}

extension FrontendReceipt.Adapter {
    struct SourceAccessorDeclarationSite {
        var declarationUTF8Offset: Int
        var expectedDeclarationPrefix: String
        var sourceName: String?
    }

    struct SourceAccessorParameter: Equatable {
        var name: String
        var swiftType: String
        var generatedSwiftType: String
    }

    struct SourceAccessorSyntax {
        var header: String
        var mayThrow: Bool
        var hasTypedThrows: Bool
        var valueParameterName: String?
    }

    struct SourceAccessorMemberPlan {
        var accessor: FrontendReceipt.TypedAST.Object
        var role: Core.DynamicReplacement.MemberRole
        var sil: CanonicalSIL.Function
        var parameters: [SourceAccessorParameter]
        var syntax: SourceAccessorSyntax
    }
}
