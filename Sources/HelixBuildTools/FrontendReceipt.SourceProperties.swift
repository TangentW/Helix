import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt.Adapter {
    func makeSourcePropertyDrafts(
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
              context.isFileScopeNameable,
              !context.isAvailabilityConstrained,
              !context.isGenericContext,
              !Self.hasAvailabilityAttribute(item),
              !Self.hasGenericSignature(item),
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

        let isStatic = item["static"] as? Bool == true
        let receiverType = isStatic ? nil : context.referenceTypeID
        let readImplementation = item["readImpl"] as? String
        let writeImplementation = item["writeImpl"] as? String
        // Static access has no bridged receiver. Instance access currently
        // requires the identity-preserving source-class Bridge; value-type
        // mutation needs a distinct inout ABI and actor instances are outside
        // the synchronous closure stage.
        guard isStatic || context.kind == .reference && receiverType != nil else {
            return []
        }

        let isolation = propertyRequiresMainActor(item, demangled: demangled)
            ? "MainActor" : nil
        let effects = Core.Effects(requiresMainActor: isolation != nil)
        let generatedPropertySwiftType = FrontendReceipt.SwiftTypeSpelling
            .replacingNominalAliases(
                in: propertySwiftType,
                aliases: importedSwiftTypeAliases
            )
        var drafts: [Draft] = []

        if let readImplementation,
           ["getter", "stored"].contains(readImplementation),
           let getter = accessors.first(where: { $0["get"] as? Bool == true }) {
            let canonical = "\(moduleName).\(context.canonicalName).\(name).get"
            if scope.includes(
                logicalPath: source.logicalPath,
                canonicalCallee: canonical,
                accessLevel: access
            ), let draft = try makeSourcePropertyDraft(
                    accessor: getter,
                    dispatch: isStatic ? .staticGetter : .instanceGetter,
                    canonicalCallee: canonical,
                    silSymbols: sourcePropertySymbols(
                        operation: .getter,
                        isStored: readImplementation == "stored",
                        isStatic: isStatic,
                        context: context,
                        name: name
                    ),
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
                ) {
                drafts.append(draft)
            }
        }

        if let writeImplementation,
           ["setter", "stored", "stored_with_observers"].contains(writeImplementation),
           let setter = accessors.first(where: { $0["set"] as? Bool == true }) {
            let canonical = "\(moduleName).\(context.canonicalName).\(name).set"
            if scope.includes(
                logicalPath: source.logicalPath,
                canonicalCallee: canonical,
                accessLevel: access
            ), let draft = try makeSourcePropertyDraft(
                    accessor: setter,
                    dispatch: isStatic ? .staticSetter : .instanceSetter,
                    canonicalCallee: canonical,
                    silSymbols: sourcePropertySymbols(
                        operation: .setter,
                        isStored: ["stored", "stored_with_observers"].contains(
                            writeImplementation
                        ),
                        isStatic: isStatic,
                        context: context,
                        name: name
                    ),
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
                ) {
                drafts.append(draft)
            }
        }
        return drafts
    }

    private func makeSourcePropertyDraft(
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
        receiverType: Core.TypeID?,
        source: SourceState,
        importedModules: [String],
        moduleName: String,
        effects: Core.Effects,
        isolation: String?,
        silFile: CanonicalSIL.File
    ) throws -> Draft? {
        guard let usr = accessor["usr"] as? String, usr.hasPrefix("s:") else {
            throw FrontendReceipt.Error.malformedAST(
                "source property \(canonicalCallee) has no Swift accessor identity"
            )
        }
        let astMangledName = "$s" + usr.dropFirst(2)
        guard let sil = try FrontendReceipt.SILFunctionResolver(file: silFile)
            .function(for: accessor, source: source, baseName: name)
        else {
            throw FrontendReceipt.Error.missingSILFunction(astMangledName)
        }
        // Async and throwing accessors require a different invocation ABI.
        // Canonical SIL is authoritative here; checking its complete lowered
        // type also excludes async/throwing callable property shapes, which are
        // outside the synchronous native-callable profile.
        guard !sil.loweredType.contains("@async"),
              !sil.loweredType.contains("@error")
        else { return nil }

        let mangledName = sil.mangledName
        let isSetter = dispatch == .instanceSetter || dispatch == .staticSetter
        let receiverSwiftTypes = receiverType.map { _ in [context.canonicalName] } ?? []
        let receiverValueTypes = receiverType.map { [Bytecode.ValueType.native($0)] } ?? []
        let parameterSwiftTypes = (isSetter ? [propertySwiftType] : [])
            + receiverSwiftTypes
        let generatedParameterSwiftTypes = (
            isSetter ? [generatedPropertySwiftType] : []
        ) + receiverSwiftTypes
        let parameterTypes = (isSetter ? [propertyType] : [])
            + receiverValueTypes
        let resultSwiftType = isSetter ? "Swift.Void" : propertySwiftType
        let generatedResultSwiftType = isSetter
            ? "Swift.Void" : generatedPropertySwiftType
        let resultType: Bytecode.ValueType = isSetter ? .void : propertyType
        let callbacks = FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: parameterSwiftTypes,
            parameterTypes: parameterTypes,
            authoritativeLifetimes: isSetter
                ? FrontendReceipt.NativeBridgeProfile.storedValueLifetimes(
                    parameterTypes: parameterTypes
                ) : [:]
        )
        guard let callbacks else { return nil }
        let signature = Core.LoweredSignature(
            parameters: parameterSwiftTypes,
            result: resultSwiftType,
            isolation: isolation
        )
        let interface = ReleaseCompiler.DeclarationInterface(
            declarationKind: isSetter ? "source-property-setter" : "source-property-getter",
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
                explanation: "source property access is represented by an exact NativeImport"
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
                callbacks: callbacks,
                inferredEffects: effects,
                isGeneric: false,
                hasInOut: false,
                hasTypedThrows: false,
                hasUnsupportedAttributes: false
            ),
            referenceReceiverType: receiverType == nil
                ? nil : context.moduleQualifiedName
        )
    }

    private enum SourcePropertyOperation {
        case getter
        case setter
    }

    /// Stored class fields lower through storage projections as well as their
    /// accessor functions. Computed and static properties use only their exact
    /// accessor symbol, which `makeSourcePropertyDraft` appends after resolving
    /// canonical SIL.
    private func sourcePropertySymbols(
        operation: SourcePropertyOperation,
        isStored: Bool,
        isStatic: Bool,
        context: NominalContext,
        name: String
    ) -> [String] {
        guard isStored, !isStatic, context.kind == .reference else { return [] }
        return [context.moduleQualifiedName, context.canonicalName].map { owner in
            switch operation {
            case .getter:
                CanonicalSIL.NativePropertySymbol.getter(
                    ownerType: owner,
                    property: name
                )
            case .setter:
                CanonicalSIL.NativePropertySymbol.setter(
                    ownerType: owner,
                    property: name
                )
            }
        }
    }

    func propertyRequiresMainActor(
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
