import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

extension FrontendReceipt.Adapter {
    /// Builds independently selectable roots for explicit `willSet` and
    /// `didSet` bodies. Swift has no source-level way to call an observer, so
    /// the generated permanent Bridge executes the exact baseline body when no
    /// patch is active and exposes no synthetic OriginalEntry invocation.
    func makeReloadableObserverDrafts(
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
        guard item["_kind"] as? String == "var_decl",
            let declarationUSR = item["usr"] as? String,
            declarationUSR.hasPrefix("s:"),
            item["readImpl"] as? String == "stored",
            item["writeImpl"] as? String == "stored_with_observers",
            item["static"] as? Bool != true,
            !Self.hasGenericSignature(item),
            let accessors = item["accessors"] as? [FrontendReceipt.TypedAST.Object],
            context?.kind != .actor,
            context?.isFileScopeNameable != false,
            context?.isAvailabilityConstrained != true,
            context?.isGenericContext != true
        else { return nil }

        let observerInputs = accessors.compactMap {
            accessor -> (FrontendReceipt.TypedAST.Object, Core.DynamicReplacement.MemberRole)? in
            guard accessor["implicit"] as? Bool != true else { return nil }
            if accessor["willSet"] as? Bool == true { return (accessor, .willSet) }
            if accessor["didSet"] as? Bool == true { return (accessor, .didSet) }
            return nil
        }
        guard !observerInputs.isEmpty else { return nil }

        let forbiddenAttributes: Set<String> = [
            "transparent_attr", "inlinable_attr", "always_emit_into_client_attr",
            "cdecl_attr", "silgen_name_attr", "available_attr",
            "lazy_attr", "reference_ownership_attr", "objc_attr",
        ]
        let parentAttributeKinds = Set(
            (item["attrs"] as? [FrontendReceipt.TypedAST.Object] ?? []).compactMap {
                $0["_kind"] as? String
            }
        )
        guard parentAttributeKinds.isDisjoint(with: forbiddenAttributes) else {
            return []
        }

        let propertyType = try demangledType(item["interface_type"], using: demangled)
        let generatedPropertyType = FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
            in: propertyType,
            aliases: importedSwiftTypeAliases
        )
        let sourceOwnerType = context.flatMap {
            sourceTypeReference($0.canonicalName)
        }
        guard context == nil || sourceOwnerType != nil else { return [] }
        let receiver: (swiftType: String, valueType: Bytecode.ValueType)? = {
            guard let context, let sourceOwnerType else { return nil }
            if let id = context.referenceTypeID {
                return (sourceOwnerType, .native(id))
            }
            if let key = context.localValueTypeKey {
                return (sourceOwnerType, .local(key))
            }
            return nil
        }()

        var memberPlans: [SourceObserverMemberPlan] = []
        for (accessor, role) in observerInputs {
            guard hasOnlySupportedAccessorAttributes(
                item,
                accessors: [accessor],
                demangled: demangled,
                forbiddenAttributes: forbiddenAttributes
            ), let body = try sourceObserverBody(
                accessor,
                source: source
            ) else { continue }
            let sil = try resolvedAccessorFunction(
                accessor,
                source: source,
                silFile: silFile,
                declarationUSR: declarationUSR
            )
            guard let parameters = try sourceAccessorParameters(
                accessor,
                demangled: demangled,
                importedSwiftTypeAliases: importedSwiftTypeAliases
            ), parameters.count <= 1,
                parameters.first?.swiftType == nil
                    || parameters.first?.swiftType == propertyType,
                !sil.loweredType.contains("@async"),
                !sil.loweredType.contains("@error"),
                supportedIsolation(sil.isolation)
            else { continue }
            let syntax = try sourceAccessorSyntax(
                accessor,
                role: role,
                sil: sil,
                source: source,
                context: context,
                isStatic: false
            )
            guard syntax.valueParameterName != "_",
                !syntax.mayThrow,
                !syntax.hasTypedThrows
            else { continue }
            memberPlans.append(
                .init(
                    accessor: accessor,
                    role: role,
                    sil: sil,
                    parameters: parameters,
                    syntax: syntax,
                    body: body
                ))
        }
        guard !memberPlans.isEmpty else { return [] }

        let declarationRequiresMainActor = accessorRequiresMainActor(
            item,
            accessor: memberPlans[0].accessor,
            sil: memberPlans[0].sil,
            demangled: demangled
        )
        // Actor isolation belongs to the separately excluded concurrency
        // execution model, so this synchronous observer profile fails closed.
        guard !declarationRequiresMainActor,
            memberPlans.allSatisfy({ member in
                accessorRequiresMainActor(
                    item,
                    accessor: member.accessor,
                    sil: member.sil,
                    demangled: demangled
                ) == false
            })
        else { return [] }

        guard let name = baseName(in: item), Self.isSwiftIdentifier(name) else {
            return []
        }
        let declarationSite = try propertyDeclarationSite(item, name: name, source: source)
        guard let sourcePropertyName = declarationSite.sourceName else {
            throw FrontendReceipt.Error.malformedAST(
                "\(source.logicalPath): observed property has no source spelling"
            )
        }
        let replacementName = SwiftFrontend.DynamicReplacement.replacementBaseName(
            usr: declarationUSR,
            baseName: name
        )
        let replacementInitializer = context == nil ? " = \(sourcePropertyName)" : ""
        let sourceDeclaration = Core.DynamicReplacement.Declaration(
            identity: declarationUSR,
            kind: .propertyObservers,
            originalReference: sourcePropertyName,
            replacementHeader: "var \(replacementName): \(generatedPropertyType)"
                + replacementInitializer,
            members: memberPlans.map {
                .init(
                    role: $0.role,
                    header: $0.syntax.header,
                    fallbackBody: $0.body.fallbackBody
                )
            },
            enclosingPrefix: sourceOwnerType.map { "extension \($0) {" } ?? "",
            enclosingSuffix: sourceOwnerType == nil ? "" : "}"
        )
        guard sourceDeclaration.isWellFormed else {
            throw FrontendReceipt.Error.unsupportedDeclaration(
                "\(source.logicalPath): property observer declaration has an invalid replacement shape"
            )
        }

        let selectedByConfiguration =
            configuration.modules[moduleName]?.includes(logicalPath: source.logicalPath) == true
            && configuration.modules[moduleName]?.entrypoints.allows(accessLevel: item["access"] as? String ?? "internal") == true
        return try memberPlans.map { member in
            let explicitValueTypes = member.parameters.map {
                FrontendReceipt.ValueTypeParser.parse(
                    $0.swiftType,
                    allowVoid: false,
                    nativeTypes: nativeTypes,
                    localTypes: localValueTypes
                ) ?? .never
            }
            let parameterTypes = explicitValueTypes
                + (receiver.map { [$0.valueType] } ?? [])
            let parameterConventions = try CanonicalSIL.Lowerer(
                typeEnvironment: typeEnvironment
            ).parseParameterConventions(
                member.sil.loweredType,
                parameterTypes: parameterTypes
            )
            guard parameterConventions.count == parameterTypes.count else {
                throw FrontendReceipt.Error.malformedAST(
                    "\(member.sil.mangledName) has an inconsistent observer ownership signature"
                )
            }
            let isolation: String? = nil
            let effects = Core.Effects()
            let role: Core.FunctionRole = member.role == .willSet ? .willSet : .didSet
            let access = item["access"] as? String ?? "internal"
            let interface = ReleaseCompiler.DeclarationInterface(
                declarationKind: member.role == .willSet
                    ? "source-property-willset" : "source-property-didset",
                baseName: name,
                argumentLabels: member.parameters.map { _ in "_" },
                accessLevel: access,
                canonicalFormalType: try demangledType(
                    member.accessor["interface_type"],
                    using: demangled
                ),
                loweredSILType: member.sil.loweredType,
                effects: effects,
                isolation: isolation,
                dispatchIdentity: member.accessor["usr"] as? String
            )
            let candidate = ReleaseCompiler.DeclarationCandidate(
                moduleName: moduleName,
                sourceFileLogicalID: source.logicalPath,
                canonicalDeclaration: (context.map { "\($0.canonicalName)." } ?? "")
                    + "\(name).\(member.role.rawValue)",
                mangledName: member.sil.mangledName,
                role: role,
                loweredSignature: .init(
                    parameters: member.parameters.map(\.swiftType),
                    result: "Swift.Void",
                    isolation: isolation
                ),
                parameterTypes: parameterTypes,
                parameterConventions: parameterConventions,
                resultType: .void,
                interface: interface,
                canonicalSILBody: member.sil.body,
                effects: effects,
                hasInOut: parameterConventions.contains(.inout),
                hasCompleteDynamicCoverage: true,
                forcedPatchability: context != nil && receiver == nil
                    ? .rejected(
                        "HLXIDX020",
                        explanation: "this observer receiver has no ABI-safe HLBC self Bridge"
                    ) : nil
            )
            let root: ShellBuildReceipt.Root?
            if selectedByConfiguration {
                var value = try makeAccessorRoot(
                    accessor: member.accessor,
                    memberRole: member.role,
                    declarationSite: declarationSite,
                    declarationInsertion: nil,
                    sourceDeclaration: sourceDeclaration,
                    sil: member.sil,
                    source: source,
                    importedModules: importedModules,
                    context: context,
                    moduleName: moduleName
                )
                // Swift cannot IRGen observer-only replacement properties from
                // Native generation. The Shell source body itself carries the
                // permanent HLBC dispatch wrapper instead.
                value.nativeReplacement = nil
                value.sourceBodyTransform = member.body.transform
                root = value
            } else {
                root = nil
            }
            let generatedParameterTypes = member.parameters.map(\.generatedSwiftType)
                + (receiver.map { [$0.swiftType] } ?? [])
            let bridge: ShellBuildReceipt.Bridge? = {
                guard parameterTypes.allSatisfy({ $0 != .never }),
                    context == nil || receiver != nil,
                    parameterConventions.filter({ $0 == .inout }).count <= 1
                else { return nil }
                return .init(
                    privateImportSourceFile: source.logicalPath,
                    parameterExpressions: member.parameters.map {
                        sourceIdentifier($0.name)
                    }
                        + (receiver.map { _ in ["self"] } ?? []),
                    parameterSwiftTypes: generatedParameterTypes,
                    resultSwiftType: "Swift.Void",
                    originalInvocation: member.body.fallbackBody,
                    bridgeInvocation: nil
                )
            }()
            return .init(
                candidate: candidate,
                root: root,
                bridge: bridge,
                nativeImportDeclaration: nil,
                referenceReceiverType: context?.referenceTypeID == nil
                    ? nil : context?.moduleQualifiedName
            )
        }
    }

    func sourceObserverBody(
        _ accessor: FrontendReceipt.TypedAST.Object,
        source: SourceState
    ) throws -> SourceObserverBody? {
        guard let body = accessor["body"] as? FrontendReceipt.TypedAST.Object,
            let range = sourceRange(in: body),
            range.start >= 0, range.end >= range.start,
            range.end < source.contents.count,
            source.contents[range.start] == UInt8(ascii: "{"),
            source.contents[range.end] == UInt8(ascii: "}")
        else {
            throw FrontendReceipt.Error.malformedAST(
                "\(source.logicalPath): property observer has no exact body range"
            )
        }
        guard !observerBodyUsesMagicLiteral(body) else { return nil }
        let bodyData = source.contents.subdata(in: (range.start + 1)..<range.end)
        guard bodyData.count <= 64 * 1_024,
            let text = String(data: bodyData, encoding: .utf8),
            !text.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw FrontendReceipt.Error.unsupportedDeclaration(
                "\(source.logicalPath): property observer body is unsupported or oversized"
            )
        }
        let completeBody = source.contents.subdata(in: range.start..<(range.end + 1))
        return .init(
            fallbackBody: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "do {}" : text,
            transform: .init(
                openingBraceUTF8Offset: range.start,
                closingBraceUTF8Offset: range.end,
                expectedBodyHash: .sha256(completeBody)
            )
        )
    }

    func observerBodyUsesMagicLiteral(_ body: FrontendReceipt.TypedAST.Object) -> Bool {
        containsASTObject(body) {
            $0["_kind"] as? String == "magic_identifier_literal_expr"
        }
    }

    private func containsASTObject(
        _ root: Any,
        where predicate: (FrontendReceipt.TypedAST.Object) -> Bool
    ) -> Bool {
        var pending: [Any] = [root]
        while let value = pending.popLast() {
            if let object = value as? FrontendReceipt.TypedAST.Object {
                if predicate(object) { return true }
                pending.append(contentsOf: object.values)
            } else if let values = value as? [Any] {
                pending.append(contentsOf: values)
            }
        }
        return false
    }

    struct SourceObserverBody {
        var fallbackBody: String
        var transform: ShellBuildReceipt.SourceBodyTransform
    }

    struct SourceObserverMemberPlan {
        var accessor: FrontendReceipt.TypedAST.Object
        var role: Core.DynamicReplacement.MemberRole
        var sil: CanonicalSIL.Function
        var parameters: [SourceAccessorParameter]
        var syntax: SourceAccessorSyntax
        var body: SourceObserverBody
    }
}
