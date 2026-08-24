import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt.Adapter {
    func makeAccessorRoot(
        accessor: FrontendReceipt.TypedAST.Object,
        memberRole: Core.DynamicReplacement.MemberRole,
        declarationSite: SourceAccessorDeclarationSite,
        declarationInsertion: String?,
        sourceDeclaration: Core.DynamicReplacement.Declaration,
        sil: CanonicalSIL.Function,
        source: SourceState,
        importedModules: [String],
        context: NominalContext?,
        moduleName: String
    ) throws -> ShellBuildReceipt.Root {
        guard let accessorRange = sourceRange(in: accessor),
            let body = accessor["body"] as? FrontendReceipt.TypedAST.Object,
            let bodyRange = sourceRange(in: body),
            bodyRange.start >= 0,
            bodyRange.start < source.contents.count,
            source.contents[bodyRange.start] == UInt8(ascii: "{")
        else {
            throw FrontendReceipt.Error.malformedAST(
                "\(sil.mangledName) has no exact accessor body range"
            )
        }
        let anchorOffset =
            accessorRange.start == bodyRange.start
            ? declarationSite.declarationUTF8Offset : accessorRange.start
        guard anchorOffset >= 0, anchorOffset <= bodyRange.start else {
            throw FrontendReceipt.Error.malformedAST(
                "\(sil.mangledName) has an invalid accessor declaration range"
            )
        }
        guard bodyRange.start - anchorOffset <= 512 * 1_024 else {
            throw FrontendReceipt.Error.unsupportedDeclaration(
                "\(sil.mangledName) accessor declaration anchor is too large"
            )
        }
        let anchorData = source.contents.subdata(in: anchorOffset..<(bodyRange.start + 1))
        guard let anchor = String(data: anchorData, encoding: .utf8),
            let occurrence = Self.occurrence(
                of: anchorData,
                at: anchorOffset,
                in: source.contents
            )
        else {
            throw FrontendReceipt.Error.malformedAST(
                "\(sil.mangledName) has an inconsistent accessor anchor"
            )
        }
        return .init(
            declarationMangledName: sil.mangledName,
            declarationUTF8Offset: declarationSite.declarationUTF8Offset,
            expectedDeclarationPrefix: declarationSite.expectedDeclarationPrefix,
            declarationInsertion: declarationInsertion,
            sourceDeclaration: sourceDeclaration,
            memberRole: memberRole,
            reloadRole: .modelOrService,
            nominalType: context.flatMap {
                guard $0.referenceTypeID != nil || $0.localValueTypeKey != nil else {
                    return nil
                }
                return .init(moduleName: moduleName, canonicalName: $0.canonicalName)
            },
            nativeReplacement: .init(
                declarationAnchorUTF8Offset: anchorOffset,
                declarationAnchor: anchor,
                declarationOccurrence: occurrence,
                loweredType: sil.loweredType,
                importedModules: importedModules
            )
        )
    }

    func makeAccessorBridge(
        declarationKind: String,
        memberRole: Core.DynamicReplacement.MemberRole,
        replacementName: String,
        sourcePropertyName: String?,
        originalLabels: [String],
        explicitParameters: [SourceAccessorParameter],
        generatedParameterSwiftTypes: [String],
        generatedResultSwiftType: String,
        receiver: (swiftType: String, valueType: Bytecode.ValueType)?,
        context: NominalContext?,
        isStatic: Bool,
        parameterConventions: [Bytecode.ParameterConvention],
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        source: SourceState
    ) -> ShellBuildReceipt.Bridge? {
        guard [.getter, .setter].contains(memberRole),
            parameterTypes.allSatisfy({ $0 != .never }), resultType != .never,
            context == nil || isStatic || receiver != nil,
            parameterConventions.filter({ $0 == .inout }).count <= 1
        else { return nil }
        let parameterNames = explicitParameters.map { sourceIdentifier($0.name) }
        let expressions = parameterNames + (receiver.map { _ in ["self"] } ?? [])
        let receiverExpression: String
        if isStatic {
            guard let context, let owner = sourceTypeReference(context.canonicalName) else {
                return nil
            }
            receiverExpression = owner
        } else if receiver != nil {
            receiverExpression = "argument\(explicitParameters.count)"
        } else {
            receiverExpression = ""
        }
        let originalInvocation: String
        let bridgeInvocation: String
        if declarationKind == "var_decl" {
            guard let sourcePropertyName else { return nil }
            if memberRole == .getter {
                originalInvocation = sourcePropertyName
                bridgeInvocation =
                    receiverExpression.isEmpty
                    ? replacementName
                    : "\(receiverExpression).\(replacementName)"
            } else {
                guard let valueName = parameterNames.first else { return nil }
                originalInvocation = "\(sourcePropertyName) = \(valueName)"
                bridgeInvocation =
                    (receiverExpression.isEmpty
                        ? replacementName
                        : "\(receiverExpression).\(replacementName)") + " = argument0"
            }
        } else {
            let indexNames =
                memberRole == .setter
                ? Array(parameterNames.dropFirst()) : parameterNames
            guard !originalLabels.isEmpty,
                indexNames.count == originalLabels.count,
                memberRole != .setter || parameterNames.count == originalLabels.count + 1
            else { return nil }
            let originalBase = isStatic ? "Self" : "self"
            originalInvocation =
                originalBase + "["
                + Self.arguments(
                    labels: originalLabels,
                    values: indexNames
                ) + "]" + (memberRole == .setter ? " = \(parameterNames[0])" : "")
            let firstIndex = memberRole == .setter ? 1 : 0
            let indexValues = indexNames.indices.map { "argument\(firstIndex + $0)" }
            var replacementLabels = originalLabels
            replacementLabels[0] = replacementName
            bridgeInvocation =
                receiverExpression + "["
                + Self.arguments(
                    labels: replacementLabels,
                    values: indexValues
                ) + "]" + (memberRole == .setter ? " = argument0" : "")
        }
        return .init(
            privateImportSourceFile: source.logicalPath,
            parameterExpressions: expressions,
            parameterSwiftTypes: generatedParameterSwiftTypes,
            resultSwiftType: generatedResultSwiftType,
            originalInvocation: originalInvocation,
            bridgeInvocation: bridgeInvocation
        )
    }

    func makeAccessorNativeImport(
        declarationKind: String,
        memberRole: Core.DynamicReplacement.MemberRole,
        baseName: String,
        parameterSwiftTypes: [String],
        generatedParameterSwiftTypes: [String],
        parameterTypes: [Bytecode.ValueType],
        resultSwiftType: String,
        generatedResultSwiftType: String,
        resultType: Bytecode.ValueType,
        parameterConventions: [Bytecode.ParameterConvention],
        sil: CanonicalSIL.Function,
        source: SourceState,
        importedModules: [String],
        moduleName: String,
        context: NominalContext?,
        access: String,
        effects: Core.Effects,
        isolation: String?,
        isStatic: Bool,
        configuration: PatchConfiguration.Document
    ) throws -> NativeImportDiscovery.Declaration? {
        guard [.getter, .setter].contains(memberRole),
            declarationKind == "var_decl", let context,
            isStatic || context.referenceTypeID != nil
        else { return nil }
        let marker = memberRole == .getter ? "get" : "set"
        let canonicalCallee = "\(moduleName).\(context.canonicalName).\(baseName).\(marker)"
        guard
            configuration.modules[moduleName]?.nativeImports.sourceScope?.includes(
                logicalPath: source.logicalPath,
                canonicalCallee: canonicalCallee,
                accessLevel: access
            ) == true
        else { return nil }
        let callbacks = FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: parameterSwiftTypes,
            parameterTypes: parameterTypes,
            authoritativeLifetimes: memberRole == .setter
                ? FrontendReceipt.NativeBridgeProfile.storedValueLifetimes(
                    parameterTypes: parameterTypes
                ) : [:]
        )
        guard let callbacks else { return nil }
        return .init(
            moduleName: moduleName,
            sourceFileLogicalID: source.logicalPath,
            mangledName: sil.mangledName,
            silSymbols: [sil.mangledName],
            canonicalCallee: canonicalCallee,
            accessLevel: access,
            dispatch: isStatic
                ? (memberRole == .getter ? .staticGetter : .staticSetter)
                : (memberRole == .getter ? .instanceGetter : .instanceSetter),
            ownerType: context.canonicalName,
            baseName: baseName,
            argumentLabels: memberRole == .getter ? [] : ["_"],
            parameterSwiftTypes: generatedParameterSwiftTypes,
            parameterProjection: .identity(parameterCount: parameterTypes.count),
            resultSwiftType: generatedResultSwiftType,
            importedModules: parameterSwiftTypes == generatedParameterSwiftTypes
                && resultSwiftType == generatedResultSwiftType ? [] : importedModules,
            parameterTypes: parameterTypes,
            resultType: resultType,
            signature: .init(
                parameters: parameterSwiftTypes,
                result: resultSwiftType,
                isThrowing: effects.mayThrow,
                isolation: isolation
            ),
            callbacks: callbacks,
            inferredEffects: effects,
            isGeneric: false,
            hasInOut: parameterConventions.contains(.inout),
            hasTypedThrows: false,
            hasUnsupportedAttributes: false
        )
    }
}
