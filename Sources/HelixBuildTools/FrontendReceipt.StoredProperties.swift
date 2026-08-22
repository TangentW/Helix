import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt.Adapter {
    func makeStoredPropertyDrafts(
        _ item: [String: Any],
        context: NominalContext?,
        source: SourceState,
        importedModules: [String],
        moduleName: String,
        configuration: PatchConfiguration.Document,
        demangled: [String: String],
        silFile: CanonicalSIL.File,
        nativeTypes: [String: Core.TypeID],
        importedSwiftTypeAliases: [String: String]
    ) throws -> [Draft] {
        guard let context,
              context.kind == .reference,
              let receiverType = context.referenceTypeID,
              item["static"] as? Bool != true,
              item["readImpl"] as? String == "stored",
              let name = baseName(in: item),
              Self.isSwiftIdentifier(name),
              let access = item["access"] as? String,
              let propertySwiftType = try? demangledType(
                item["interface_type"],
                using: demangled
              ),
              let propertyType = FrontendReceipt.ValueTypeParser.parse(
                propertySwiftType,
                allowVoid: false,
                nativeTypes: nativeTypes
              ),
              let scope = configuration.modules[moduleName]?.nativeImports.sourceScope,
              let accessors = item["accessors"] as? [[String: Any]]
        else { return [] }

        let isolation = propertyRequiresMainActor(item, demangled: demangled)
            ? "MainActor" : nil
        let effects = Core.Effects(requiresMainActor: isolation != nil)
        let generatedPropertySwiftType = FrontendReceipt.SwiftTypeSpelling
            .replacingNominalAliases(
                in: propertySwiftType,
                aliases: importedSwiftTypeAliases
            )
        var drafts: [Draft] = []

        if let getter = accessors.first(where: { $0["get"] as? Bool == true }) {
            let canonical = "\(moduleName).\(context.canonicalName).\(name).get"
            if scope.includes(
                logicalPath: source.logicalPath,
                canonicalCallee: canonical,
                accessLevel: access
            ) {
                drafts.append(try makeStoredPropertyDraft(
                    accessor: getter,
                    dispatch: .instanceGetter,
                    canonicalCallee: canonical,
                    silSymbols: [
                        CanonicalSIL.NativePropertySymbol.getter(
                            ownerType: context.moduleQualifiedName,
                            property: name
                        ),
                        CanonicalSIL.NativePropertySymbol.getter(
                            ownerType: context.canonicalName,
                            property: name
                        ),
                    ],
                    name: name,
                    access: access,
                    propertySwiftType: propertySwiftType,
                    generatedPropertySwiftType: generatedPropertySwiftType,
                    propertyType: propertyType,
                    context: context,
                    receiverType: receiverType,
                    source: source,
                    importedModules: importedModules,
                    moduleName: moduleName,
                    effects: effects,
                    isolation: isolation,
                    silFile: silFile
                ))
            }
        }

        if item["writeImpl"] as? String == "stored",
           let setter = accessors.first(where: { $0["set"] as? Bool == true }) {
            let canonical = "\(moduleName).\(context.canonicalName).\(name).set"
            if scope.includes(
                logicalPath: source.logicalPath,
                canonicalCallee: canonical,
                accessLevel: access
            ) {
                drafts.append(try makeStoredPropertyDraft(
                    accessor: setter,
                    dispatch: .instanceSetter,
                    canonicalCallee: canonical,
                    silSymbols: [
                        CanonicalSIL.NativePropertySymbol.setter(
                            ownerType: context.moduleQualifiedName,
                            property: name
                        ),
                        CanonicalSIL.NativePropertySymbol.setter(
                            ownerType: context.canonicalName,
                            property: name
                        ),
                    ],
                    name: name,
                    access: access,
                    propertySwiftType: propertySwiftType,
                    generatedPropertySwiftType: generatedPropertySwiftType,
                    propertyType: propertyType,
                    context: context,
                    receiverType: receiverType,
                    source: source,
                    importedModules: importedModules,
                    moduleName: moduleName,
                    effects: effects,
                    isolation: isolation,
                    silFile: silFile
                ))
            }
        }
        return drafts
    }

    private func makeStoredPropertyDraft(
        accessor: [String: Any],
        dispatch: NativeImportDiscovery.Dispatch,
        canonicalCallee: String,
        silSymbols: [String],
        name: String,
        access: String,
        propertySwiftType: String,
        generatedPropertySwiftType: String,
        propertyType: Bytecode.ValueType,
        context: NominalContext,
        receiverType: Core.TypeID,
        source: SourceState,
        importedModules: [String],
        moduleName: String,
        effects: Core.Effects,
        isolation: String?,
        silFile: CanonicalSIL.File
    ) throws -> Draft {
        guard let usr = accessor["usr"] as? String, usr.hasPrefix("s:") else {
            throw FrontendReceipt.Error.malformedAST(
                "stored property \(canonicalCallee) has no Swift accessor identity"
            )
        }
        let astMangledName = "$s" + usr.dropFirst(2)
        guard let sil = try FrontendReceipt.SILFunctionResolver(file: silFile)
            .function(for: accessor, source: source, baseName: name)
        else {
            throw FrontendReceipt.Error.missingSILFunction(astMangledName)
        }
        let mangledName = sil.mangledName
        let isSetter = dispatch == .instanceSetter
        let parameterSwiftTypes = isSetter
            ? [propertySwiftType, context.canonicalName]
            : [context.canonicalName]
        let generatedParameterSwiftTypes = isSetter
            ? [generatedPropertySwiftType, context.canonicalName]
            : [context.canonicalName]
        let parameterTypes: [Bytecode.ValueType] = isSetter
            ? [propertyType, .native(receiverType)]
            : [.native(receiverType)]
        let resultSwiftType = isSetter ? "Swift.Void" : propertySwiftType
        let generatedResultSwiftType = isSetter
            ? "Swift.Void" : generatedPropertySwiftType
        let resultType: Bytecode.ValueType = isSetter ? .void : propertyType
        let signature = Core.LoweredSignature(
            parameters: parameterSwiftTypes,
            result: resultSwiftType,
            isolation: isolation
        )
        let interface = ReleaseCompiler.DeclarationInterface(
            declarationKind: isSetter ? "stored-property-setter" : "stored-property-getter",
            baseName: name,
            argumentLabels: isSetter ? ["_"] : [],
            accessLevel: access,
            canonicalFormalType: propertySwiftType,
            loweredSILType: sil.loweredType,
            effects: effects,
            isolation: isolation,
            dispatchIdentity: usr
        )
        let candidate = ReleaseCompiler.DeclarationCandidate(
            moduleName: moduleName,
            sourceFileLogicalID: source.logicalPath,
            canonicalDeclaration: "\(context.canonicalName).\(name)."
                + (isSetter ? "setter" : "getter"),
            mangledName: mangledName,
            role: .method,
            loweredSignature: signature,
            parameterTypes: parameterTypes,
            resultType: resultType,
            interface: interface,
            canonicalSILBody: sil.body,
            effects: effects,
            hasCompleteDynamicCoverage: false,
            forcedPatchability: .rejected(
                "HLXIDX023",
                explanation: "stored property access is represented by an exact NativeImport"
            )
        )
        return Draft(
            candidate: candidate,
            root: nil,
            bridge: nil,
            nativeImportDeclaration: .init(
                moduleName: moduleName,
                sourceFileLogicalID: source.logicalPath,
                mangledName: mangledName,
                silSymbols: Array(Set(silSymbols + [mangledName])).sorted(),
                canonicalCallee: canonicalCallee,
                accessLevel: access,
                dispatch: dispatch,
                ownerType: context.canonicalName,
                baseName: name,
                argumentLabels: isSetter ? ["_"] : [],
                parameterSwiftTypes: generatedParameterSwiftTypes,
                parameterProjection: .identity(
                    parameterCount: parameterTypes.count
                ),
                resultSwiftType: generatedResultSwiftType,
                importedModules: propertySwiftType == generatedPropertySwiftType
                    ? [] : importedModules,
                parameterTypes: parameterTypes,
                resultType: resultType,
                signature: signature,
                inferredEffects: effects,
                isGeneric: false,
                hasInOut: false,
                hasTypedThrows: false,
                hasUnsupportedAttributes: false
            ),
            referenceReceiverType: context.moduleQualifiedName
        )
    }

    private func propertyRequiresMainActor(
        _ item: [String: Any],
        demangled: [String: String]
    ) -> Bool {
        let attributes = item["attrs"] as? [[String: Any]] ?? []
        return attributes.contains { attribute in
            guard attribute["_kind"] as? String == "custom_attr",
                  let mangled = attribute["type"] as? String,
                  var name = demangled[mangled]
            else { return false }
            if name.hasSuffix(".Type") { name.removeLast(5) }
            return name.split(separator: ".").last == "MainActor"
        }
    }
}
