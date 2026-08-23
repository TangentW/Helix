import HelixBytecode
import HelixCore

enum CompilerCapabilities {}

extension CompilerCapabilities {
    static func infer(
        for functions: [IntermediateRepresentation.Function],
        imports: [Bytecode.ImportRequirement] = [],
        entryParameterConventions: [
            Core.EntryIndex: [Bytecode.ParameterConvention]
        ] = [:],
        localTypes: [Bytecode.LocalTypeDefinition] = []
    ) -> Set<Core.Capability> {
        var capabilities: Set<Core.Capability> = [.baselineV1]
        if entryParameterConventions.values.contains(where: {
            $0.contains(.borrowed)
        }) {
            capabilities.insert(.borrowCallsV1)
        }
        for function in functions {
            switch function.kind {
            case .ordinary:
                break
            case .closureBody:
                capabilities.insert(.closureValuesV1)
            case .concreteSpecialization:
                capabilities.insert(.compilerSpecializationsV1)
            }
            let referencedTypes = function.registerTypes + function.stackSlotTypes
                + [function.resultType]
                + (function.thrownType.map { [$0] } ?? [])
            for type in referencedTypes {
                collect(type, into: &capabilities)
            }
            if function.registerTypes.contains(where: \.containsNestedClosureValue)
                || function.stackSlotTypes.contains(where: \.containsClosureValue)
                || function.resultType.containsClosureValue {
                capabilities.insert(.escapingClosureValuesV1)
            }
            if function.effects.requiresMainActor {
                capabilities.insert(.mainActorSyncV1)
            }
            if function.effects.isAsync {
                capabilities.insert(.asyncLeafEntriesV1)
            }
            if function.parameterConventions.contains(.borrowed) {
                capabilities.insert(.borrowCallsV1)
            }
            if let thrownType = function.thrownType {
                collectThrownType(thrownType, into: &capabilities)
            }
            // Capability inference must remain total even for malformed IR; verification
            // owns the duplicate-block diagnostic instead of allowing a Dictionary trap.
            let blocks = Dictionary(
                function.blocks.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for instruction in function.blocks.flatMap(\.instructions) {
                if case .progressionNext = instruction {
                    capabilities.insert(.collectionsV1)
                }
                let closureCaptures: [Bytecode.Register]? = switch instruction {
                case let .makeClosure(_, _, captures, _):
                    captures
                default:
                    nil
                }
                if closureCaptures?.contains(where: { register in
                       guard function.registerTypes.indices.contains(
                           Int(register.rawValue)
                       ) else { return false }
                       if case .closure = function.registerTypes[Int(register.rawValue)] {
                           return true
                       }
                       return false
                   }) == true {
                    capabilities.insert(.escapingClosureValuesV1)
                }
                let errorTarget: Bytecode.BlockID? = switch instruction {
                case let .tryApply(_, _, _, target),
                     let .existentialTryApply(_, _, _, _, target),
                     let .entryTryApply(_, _, _, target),
                     let .nativeTryApply(_, _, _, target),
                     let .closureTryApply(_, _, _, target):
                    target
                default:
                    nil
                }
                guard let errorTarget,
                      let parameter = blocks[errorTarget]?.parameters.first,
                      function.registerTypes.indices.contains(Int(parameter.rawValue))
                else { continue }
                switch function.registerTypes[Int(parameter.rawValue)] {
                case .error: capabilities.insert(.structuredErrorsV1)
                case .string: capabilities.insert(.untypedThrowsV1)
                case .local: capabilities.insert(.typedThrowsV1)
                default: break
                }
            }
        }
        if !localTypes.isEmpty { capabilities.insert(.localNominalsV1) }
        for definition in localTypes {
            switch definition.kind {
            case let .structure(fields):
                for field in fields {
                    collect(field.type, into: &capabilities)
                    if field.type.containsClosureValue {
                        capabilities.insert(.escapingClosureValuesV1)
                    }
                }
            case let .enumeration(cases):
                for item in cases {
                    if let payload = item.payloadType {
                        collect(payload, into: &capabilities)
                        if payload.containsClosureValue {
                            capabilities.insert(.escapingClosureValuesV1)
                        }
                    }
                }
            case let .class(fields, hostedSuperclass, _):
                capabilities.insert(.localClassesV1)
                if hostedSuperclass != nil {
                    capabilities.insert(.hostedObjectiveCClassesV1)
                    capabilities.insert(.nativeTypesV1)
                }
                for field in fields {
                    collect(field.type, into: &capabilities)
                    if field.type.containsClosureValue {
                        capabilities.insert(.escapingClosureValuesV1)
                    }
                }
            }
        }
        if !imports.isEmpty { capabilities.insert(.nativeImportsV1) }
        for requirement in imports {
            capabilities.insert(requirement.requiredCapability)
        }
        return capabilities
    }

    private static func collect(
        _ type: Bytecode.ValueType,
        into capabilities: inout Set<Core.Capability>
    ) {
        switch type {
        case .string:
            capabilities.insert(.stringsV1)
        case .any:
            capabilities.insert(.anyValuesV1)
        case .native:
            capabilities.insert(.nativeTypesV1)
        case .local:
            capabilities.insert(.localNominalsV1)
        case .error:
            capabilities.insert(.structuredErrorsV1)
        case let .closure(signature):
            capabilities.insert(.closureValuesV1)
            if signature.effects.requiresMainActor {
                capabilities.insert(.mainActorSyncV1)
            }
            if let thrownType = signature.thrownType {
                collectThrownType(thrownType, into: &capabilities)
            }
            for component in signature.componentTypes {
                collect(component, into: &capabilities)
            }
        case let .address(pointee):
            capabilities.insert(.addressValuesV1)
            collect(pointee, into: &capabilities)
        case let .mutableCell(pointee):
            capabilities.insert(.mutableCapturesV1)
            collect(pointee, into: &capabilities)
        case let .nonOwningReference(_, pointee):
            capabilities.insert(.nonOwningReferencesV1)
            collect(pointee, into: &capabilities)
        case let .arrayState(_, element):
            capabilities.insert(.collectionsV1)
            collect(element, into: &capabilities)
        case let .array(element):
            capabilities.insert(.collectionsV1)
            collect(element, into: &capabilities)
        case let .dictionary(key, value):
            capabilities.insert(.collectionsV1)
            collect(key, into: &capabilities)
            collect(value, into: &capabilities)
        case let .dictionaryState(key, value):
            capabilities.insert(.collectionsV1)
            collect(key, into: &capabilities)
            collect(value, into: &capabilities)
        case let .set(element):
            capabilities.insert(.collectionsV1)
            collect(element, into: &capabilities)
        case let .tuple(elements):
            for element in elements { collect(element, into: &capabilities) }
        case let .optional(wrapped):
            collect(wrapped, into: &capabilities)
        case .void, .never, .bool, .integer, .float:
            break
        }
    }

    private static func collectThrownType(
        _ type: Bytecode.ValueType,
        into capabilities: inout Set<Core.Capability>
    ) {
        switch type {
        case .string:
            capabilities.formUnion([.stringsV1, .untypedThrowsV1])
        case .error:
            capabilities.insert(.structuredErrorsV1)
        case .local:
            capabilities.formUnion([.localNominalsV1, .typedThrowsV1])
        default:
            break
        }
    }
}
