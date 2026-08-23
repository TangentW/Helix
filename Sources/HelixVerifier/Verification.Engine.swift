import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

extension Verification {
public struct Engine: Verification.ImageVerifying {
    public let decodingLimits: Bytecode.DecodingLimits
    public let structuralLimits: Verification.StructuralLimits

    public init(
        decodingLimits: Bytecode.DecodingLimits = .init(),
        structuralLimits: Verification.StructuralLimits = .init()
    ) {
        self.decodingLimits = decodingLimits
        self.structuralLimits = structuralLimits
    }

    public func verify(
        bytes: Data,
        shell: Verification.ShellInterface,
        policy: Core.RuntimePolicy
    ) throws -> Verification.Image {
        // ShellInterface remains mutable for host assembly and tests, so recheck
        // its ABI boundary at the trust transition instead of relying on init.
        try shell.validateBoundarySignatures()
        let container = try Bytecode.Decoder.decode(bytes, limits: decodingLimits)
        let module = container.module

        try verifyModuleStructure(module)

        guard container.header.shellInterfaceHash.constantTimeEquals(shell.interfaceHash) else {
            throw Verification.Error.shellInterfaceHashMismatch
        }
        guard shell.compatibility.isCompatible(with: module.compatibility) else {
            throw Verification.Error.incompatibleToolchain
        }
        guard container.header.minimumRuntimeMajor <= Core.Versions.runtime.major else {
            throw Verification.Error.runtimeVersionTooOld(
                requiredMajor: container.header.minimumRuntimeMajor,
                actualMajor: Core.Versions.runtime.major
            )
        }
        guard module.capabilities.contains(.baselineV1) else {
            throw Verification.Error.missingBaselineCapability
        }
        for capability in module.capabilities {
            guard Verification.Metadata.supportedCapabilities.contains(capability) else {
                throw Verification.Error.unsupportedCapability(capability)
            }
            guard policy.acceptedCapabilities.contains(capability) else {
                throw Verification.Error.capabilityDenied(capability)
            }
            guard shell.capabilities.contains(capability) else {
                throw Verification.Error.capabilityUnavailableInShell(capability)
            }
        }
        let localTypes = try verifyLocalTypes(
            module.localTypes,
            capabilities: module.capabilities
        )

        let effectiveLimits = module.requestedResources.constrained(by: policy.resourceCeiling)
        let functionMap = try verifyUniqueFunctions(module.functions)
        try verifyLocalClassDescriptors(
            localTypes,
            functions: functionMap,
            shell: shell,
            capabilities: module.capabilities
        )
        let entryFunctionIDs = Set(module.entries.map(\.functionID))
        try verifyLocalTypeReferences(module.functions, localTypes: localTypes)
        try verifySourceMap(module.sourceMap, functions: functionMap)
        try verifyEntries(
            module.entries,
            functions: functionMap,
            shell: shell,
            policy: policy,
            capabilities: module.capabilities
        )
        let declaredImports = try verifyImports(
            module.imports,
            shell: shell,
            policy: policy,
            capabilities: module.capabilities
        )
        try verifyNativeTypes(module.functions, shell: shell)
        for definition in module.localTypes {
            switch definition.kind {
            case let .structure(fields), let .class(fields, _, _):
                for field in fields {
                    try verifyNativeTypes(field.type, shell: shell)
                }
            case let .enumeration(cases):
                for item in cases {
                    if let payload = item.payloadType {
                        try verifyNativeTypes(payload, shell: shell)
                    }
                }
            }
        }
        try verifyTypeCapabilities(
            module.functions,
            localTypes: module.localTypes,
            capabilities: module.capabilities
        )
        for function in module.functions {
            try verifyFunction(
                function,
                functions: functionMap,
                shell: shell,
                effectiveLimits: effectiveLimits,
                declaredImports: declaredImports,
                localTypes: localTypes,
                capabilities: module.capabilities,
                entryFunctionIDs: entryFunctionIDs
            )
        }

        return Verification.Image(
            imageHash: container.header.imageHash,
            module: module,
            shell: shell,
            effectiveResourceLimits: effectiveLimits
        )
    }

    private func verifyModuleStructure(_ module: Bytecode.Module) throws {
        try verifyIdentifier(module.name, label: "module name")
        guard !module.functions.isEmpty else {
            throw Verification.Error.invalidModule("at least one function is required")
        }
        guard !module.entries.isEmpty else {
            throw Verification.Error.invalidModule("at least one patch entry is required")
        }
        guard module.functions.count <= structuralLimits.maximumFunctions else {
            throw Verification.Error.invalidModule("function count exceeds the structural limit")
        }
        guard module.entries.count <= structuralLimits.maximumEntries else {
            throw Verification.Error.invalidModule("entry count exceeds the structural limit")
        }
        guard module.imports.count <= structuralLimits.maximumImports else {
            throw Verification.Error.invalidModule("native import count exceeds the structural limit")
        }
        guard module.sourceMap.count <= structuralLimits.maximumSourceMapEntries else {
            throw Verification.Error.invalidModule("source map count exceeds the structural limit")
        }
        guard module.capabilities.count <= structuralLimits.maximumCapabilities else {
            throw Verification.Error.invalidModule("capability count exceeds the structural limit")
        }
        guard module.localTypes.count <= structuralLimits.maximumLocalTypes else {
            throw Verification.Error.invalidModule("local type count exceeds the structural limit")
        }
        for capability in module.capabilities {
            try verifyIdentifier(capability.rawValue, label: "capability")
        }

        var totalInstructions = 0
        for function in module.functions {
            try verifyIdentifier(function.name, label: "function name")
            guard function.blocks.count <= structuralLimits.maximumBlocksPerFunction else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "block count exceeds the structural limit"
                )
            }
            var instructionCount = 0
            for block in function.blocks {
                let addition = instructionCount.addingReportingOverflow(block.instructions.count)
                guard !addition.overflow,
                      addition.partialValue <= structuralLimits.maximumInstructionsPerFunction
                else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "instruction count exceeds the structural limit"
                    )
                }
                instructionCount = addition.partialValue
            }
            let addition = totalInstructions.addingReportingOverflow(instructionCount)
            guard !addition.overflow,
                  addition.partialValue <= structuralLimits.maximumTotalInstructions
            else {
                throw Verification.Error.invalidModule("total instruction count exceeds the structural limit")
            }
            totalInstructions = addition.partialValue
            if let location = function.sourceLocation {
                try verifySourceLocation(location) { reason in
                    Verification.Error.invalidFunction(function: function.id, reason: reason)
                }
            }
        }
    }

    private func verifyLocalTypes(
        _ definitions: [Bytecode.LocalTypeDefinition],
        capabilities: Set<Core.Capability>
    ) throws -> [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition] {
        if !definitions.isEmpty, !capabilities.contains(.localNominalsV1) {
            throw Verification.Error.capabilityDenied(.localNominalsV1)
        }
        var result: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition] = [:]
        var totalMembers = 0
        for definition in definitions {
            try verifyIdentifier(definition.key.rawValue, label: "local type key")
            guard result.updateValue(definition, forKey: definition.key) == nil else {
                throw Verification.Error.invalidModule(
                    "duplicate local type \(definition.key)"
                )
            }
            let members: Int
            switch definition.kind {
            case let .structure(fields):
                members = fields.count
                guard Set(fields.map(\.name)).count == fields.count else {
                    throw Verification.Error.invalidModule(
                        "local struct \(definition.key) has duplicate fields"
                    )
                }
                for field in fields {
                    try verifyIdentifier(field.name, label: "local struct field")
                }
            case let .enumeration(cases):
                members = cases.count
                guard !cases.isEmpty else {
                    throw Verification.Error.invalidModule(
                        "local enum \(definition.key) has no cases"
                    )
                }
                guard Set(cases.map(\.name)).count == cases.count else {
                    throw Verification.Error.invalidModule(
                        "local enum \(definition.key) has duplicate cases"
                    )
                }
                for item in cases {
                    try verifyIdentifier(item.name, label: "local enum case")
                }
            case let .class(fields, hostedSuperclass, hostedMethods):
                guard capabilities.contains(.localClassesV1) else {
                    throw Verification.Error.capabilityDenied(.localClassesV1)
                }
                if hostedSuperclass != nil {
                    guard capabilities.contains(.hostedObjectiveCClassesV1) else {
                        throw Verification.Error.capabilityDenied(
                            .hostedObjectiveCClassesV1
                        )
                    }
                    // Runtime intentionally exposes only inherited no-argument
                    // initialization in hosted profile v1. Until an initializer
                    // descriptor proves field initialization order, a native
                    // callback could otherwise observe uninitialized VM storage.
                    guard fields.isEmpty else {
                        throw Verification.Error.invalidModule(
                            "hosted class \(definition.key) cannot declare stored fields"
                        )
                    }
                } else if !hostedMethods.isEmpty {
                    throw Verification.Error.invalidModule(
                        "VM-only class \(definition.key) declares native callbacks"
                    )
                }
                guard !definition.conformsToError else {
                    throw Verification.Error.invalidModule(
                        "local class \(definition.key) cannot conform to Error"
                    )
                }
                members = fields.count + hostedMethods.count
                guard Set(fields.map(\.name)).count == fields.count else {
                    throw Verification.Error.invalidModule(
                        "local class \(definition.key) has duplicate fields"
                    )
                }
                for field in fields {
                    try verifyIdentifier(field.name, label: "local class field")
                }
                guard Set(hostedMethods.map(\.selector)).count == hostedMethods.count else {
                    throw Verification.Error.invalidModule(
                        "hosted class \(definition.key) has duplicate selectors"
                    )
                }
                guard Set(hostedMethods.map(\.functionID)).count
                        == hostedMethods.count
                else {
                    throw Verification.Error.invalidModule(
                        "hosted class \(definition.key) reuses one callback function"
                    )
                }
                for method in hostedMethods {
                    try verifyObjectiveCSelector(method.selector)
                    let colonCount = method.selector.reduce(into: 0) { count, character in
                        if character == ":" { count += 1 }
                    }
                    let expectedColonCount = switch method.abi {
                    case .voidNoArguments: 0
                    case .voidBool: 1
                    }
                    guard colonCount == expectedColonCount else {
                        throw Verification.Error.invalidModule(
                            "hosted selector \(method.selector) does not match \(method.abi.rawValue)"
                        )
                    }
                }
            }
            guard members <= structuralLimits.maximumLocalTypeMembers else {
                throw Verification.Error.invalidModule(
                    "local type \(definition.key) has too many members"
                )
            }
            let addition = totalMembers.addingReportingOverflow(members)
            guard !addition.overflow,
                  addition.partialValue <= structuralLimits.maximumTotalLocalTypeMembers
            else {
                throw Verification.Error.invalidModule(
                    "total local type member count exceeds the structural limit"
                )
            }
            totalMembers = addition.partialValue
        }

        func verifyMemberType(
            _ type: Bytecode.ValueType,
            depth: Int,
            permitsNative: Bool
        ) throws {
            guard depth <= structuralLimits.maximumLocalTypeNestingDepth else {
                throw Verification.Error.invalidModule(
                    "local type member nesting exceeds "
                        + "\(structuralLimits.maximumLocalTypeNestingDepth) levels"
                )
            }
            switch type {
            case .any:
                break
            case .void, .never:
                throw Verification.Error.invalidModule(
                    "local type members cannot be Void or Never"
                )
            case .native:
                guard permitsNative else {
                    throw Verification.Error.invalidModule(
                        "HLBC local types cannot contain native values"
                    )
                }
            case .address:
                throw Verification.Error.invalidModule(
                    "local type members cannot contain address values"
                )
            case .mutableCell:
                throw Verification.Error.invalidModule(
                    "local type members cannot contain mutable capture cells"
                )
            case .nonOwningReference:
                throw Verification.Error.invalidModule(
                    "local type members cannot contain non-owning reference storage"
                )
            case .arrayState:
                throw Verification.Error.invalidModule(
                    "local type members cannot contain Array operation states"
                )
            case .dictionaryState:
                throw Verification.Error.invalidModule(
                    "local type members cannot contain Dictionary operation states"
                )
            case let .closure(signature):
                guard signature.hasCanonicalCallableEffects else {
                    throw Verification.Error.invalidModule(
                        "local type closure signature cannot carry execution authority"
                    )
                }
                guard signature.hasCanonicalThrownType else {
                    throw Verification.Error.invalidModule(
                        "local type closure signature has inconsistent throwing ABI"
                    )
                }
                if let thrownType = signature.thrownType {
                    switch thrownType {
                    case .string:
                        guard capabilities.contains(.untypedThrowsV1) else {
                            throw Verification.Error.capabilityDenied(.untypedThrowsV1)
                        }
                    case .error:
                        guard capabilities.contains(.structuredErrorsV1) else {
                            throw Verification.Error.capabilityDenied(.structuredErrorsV1)
                        }
                    case let .local(key)
                    where result[key]?.conformsToError == true:
                        guard capabilities.contains(.typedThrowsV1) else {
                            throw Verification.Error.capabilityDenied(.typedThrowsV1)
                        }
                    default:
                        throw Verification.Error.invalidModule(
                            "local type closure has a non-Error thrown type"
                        )
                    }
                }
                guard signature.parameters.count <= 64,
                      signature.parameterConventions.count
                        == signature.parameters.count,
                      zip(
                        signature.parameters,
                        signature.parameterConventions
                      ).allSatisfy({ parameter, convention in
                        switch (parameter, convention) {
                        case (.address, .inout): true
                        case (.address, _), (_, .inout): false
                        default: true
                        }
                      }),
                      !signature.effects.isAsync
                else {
                    throw Verification.Error.invalidModule(
                        "local type member contains an invalid closure signature"
                    )
                }
                for parameter in signature.parameters {
                    switch parameter {
                    case .void, .never, .mutableCell, .nonOwningReference,
                         .arrayState,
                         .dictionaryState:
                        throw Verification.Error.invalidModule(
                            "local type closure parameter has invalid storage"
                        )
                    case let .address(pointee):
                        switch pointee {
                        case .void, .never, .address, .mutableCell,
                             .nonOwningReference,
                             .arrayState, .dictionaryState:
                            throw Verification.Error.invalidModule(
                                "local type inout closure parameter has invalid storage"
                            )
                        default:
                            try verifyMemberType(
                                pointee,
                                depth: depth + 1,
                                permitsNative: true
                            )
                        }
                    default:
                        try verifyMemberType(
                            parameter,
                            depth: depth + 1,
                            permitsNative: true
                        )
                    }
                }
                switch signature.result {
                case .void:
                    break
                case .never, .address, .mutableCell, .nonOwningReference,
                     .arrayState,
                     .dictionaryState:
                    throw Verification.Error.invalidModule(
                        "local type closure result has invalid storage"
                    )
                default:
                    try verifyMemberType(
                        signature.result,
                        depth: depth + 1,
                        permitsNative: true
                    )
                }
            case let .local(key):
                guard result[key] != nil else {
                    throw Verification.Error.invalidModule(
                        "local type references unknown definition \(key)"
                    )
                }
            case .error:
                // Error is a dynamic leaf in the static nominal graph. Its
                // concrete local payload is checked when the existential is
                // constructed and at every VM boundary, with runtime depth
                // and fuel limits on both paths.
                break
            case let .integer(bitWidth, _):
                guard [8, 16, 32, 64].contains(bitWidth) else {
                    throw Verification.Error.invalidModule(
                        "local type contains unsupported integer width \(bitWidth)"
                    )
                }
            case let .float(bitWidth):
                guard bitWidth == 32 || bitWidth == 64 else {
                    throw Verification.Error.invalidModule(
                        "local type contains unsupported float width \(bitWidth)"
                    )
                }
            case let .array(element), let .optional(element):
                try verifyMemberType(
                    element,
                    depth: depth + 1,
                    permitsNative: permitsNative
                )
            case let .set(element):
                guard element.isVMHashable else {
                    throw Verification.Error.invalidModule(
                        "local type Set element lacks VM-defined Hashable semantics"
                    )
                }
                try verifyMemberType(
                    element,
                    depth: depth + 1,
                    permitsNative: permitsNative
                )
            case let .dictionary(key, value):
                guard key.isVMHashable else {
                    throw Verification.Error.invalidModule(
                        "local type Dictionary key lacks VM-defined Hashable semantics"
                    )
                }
                try verifyMemberType(key, depth: depth + 1, permitsNative: permitsNative)
                try verifyMemberType(value, depth: depth + 1, permitsNative: permitsNative)
            case let .tuple(elements):
                guard elements.count <= 64 else {
                    throw Verification.Error.invalidModule(
                        "local type tuple contains more than 64 elements"
                    )
                }
                for element in elements {
                    try verifyMemberType(
                        element,
                        depth: depth + 1,
                        permitsNative: permitsNative
                    )
                }
            case .bool, .string:
                break
            }
        }
        for definition in definitions {
            switch definition.kind {
            case let .structure(fields):
                for field in fields {
                    try verifyMemberType(field.type, depth: 0, permitsNative: false)
                }
            case let .enumeration(cases):
                for item in cases {
                    if let payload = item.payloadType {
                        try verifyMemberType(payload, depth: 0, permitsNative: false)
                    }
                }
            case let .class(fields, _, _):
                for field in fields {
                    try verifyMemberType(field.type, depth: 0, permitsNative: true)
                }
            }
        }
        try verifyLocalTypeGraph(result)
        return result
    }

    private func verifyLocalTypeGraph(
        _ definitions: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) throws {
        var visiting = Set<Bytecode.LocalTypeKey>()
        var depths: [Bytecode.LocalTypeKey: Int] = [:]
        for key in definitions.keys.sorted() {
            _ = try localTypeExpansionDepth(
                key,
                definitions: definitions,
                visiting: &visiting,
                depths: &depths
            )
        }
    }

    private func localTypeExpansionDepth(
        _ key: Bytecode.LocalTypeKey,
        definitions: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        visiting: inout Set<Bytecode.LocalTypeKey>,
        depths: inout [Bytecode.LocalTypeKey: Int]
    ) throws -> Int {
        if let depth = depths[key] { return depth }
        guard visiting.insert(key).inserted else {
            throw Verification.Error.invalidModule(
                "local type graph is recursive at \(key); "
                    + "recursive HLBC local values are unsupported"
            )
        }
        defer { visiting.remove(key) }
        guard let definition = definitions[key] else {
            throw Verification.Error.invalidModule(
                "local type references unknown definition \(key)"
            )
        }

        func typeDepth(_ type: Bytecode.ValueType) throws -> Int {
            switch type {
            case let .local(dependency):
                if case .class = definitions[dependency]?.kind {
                    0
                } else {
                    try localTypeExpansionDepth(
                        dependency,
                        definitions: definitions,
                        visiting: &visiting,
                        depths: &depths
                    )
                }
            case let .array(element), let .optional(element), let .set(element),
                 let .mutableCell(element), let .arrayState(_, element):
                try typeDepth(element) + 1
            case let .dictionary(key, value):
                try max(typeDepth(key), typeDepth(value)) + 1
            case let .dictionaryState(key, value):
                try max(typeDepth(key), typeDepth(value)) + 1
            case let .tuple(elements):
                try (elements.map(typeDepth).max() ?? 0) + 1
            case .void, .never, .bool, .integer, .float, .string, .any, .native,
                 .error, .address, .closure, .nonOwningReference:
                0
            }
        }

        let memberTypes: [Bytecode.ValueType] = switch definition.kind {
        case let .structure(fields): fields.map(\.type)
        case let .enumeration(cases): cases.compactMap(\.payloadType)
        case let .class(fields, _, _): fields.map(\.type)
        }
        let depth = try (memberTypes.map(typeDepth).max() ?? 0) + 1
        guard depth <= structuralLimits.maximumLocalTypeNestingDepth else {
            throw Verification.Error.invalidModule(
                "local type expanded shape exceeds "
                    + "\(structuralLimits.maximumLocalTypeNestingDepth) levels"
            )
        }
        depths[key] = depth
        return depth
    }

    private func verifyLocalTypeReferences(
        _ functions: [Bytecode.Function],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) throws {
        func visit(_ type: Bytecode.ValueType) throws {
            switch type {
            case let .local(key):
                guard localTypes[key] != nil else {
                    throw Verification.Error.invalidModule(
                        "function type references unknown local type \(key)"
                    )
                }
            case let .array(element), let .optional(element), let .set(element):
                try visit(element)
            case let .address(pointee), let .mutableCell(pointee),
                 let .nonOwningReference(_, pointee),
                 let .arrayState(_, pointee):
                try visit(pointee)
            case let .closure(signature):
                for component in signature.componentTypes {
                    try visit(component)
                }
            case let .dictionary(key, value):
                try visit(key)
                try visit(value)
            case let .dictionaryState(key, value):
                try visit(key)
                try visit(value)
            case let .tuple(elements):
                for element in elements { try visit(element) }
            case .void, .never, .bool, .integer, .float, .string, .any, .native,
                 .error:
                break
            }
        }
        for function in functions {
            let types = function.registerTypes + function.stackSlotTypes
                + [function.resultType]
                + (function.thrownType.map { [$0] } ?? [])
            for type in types {
                try visit(type)
            }
        }
    }

    private func verifyIdentifier(_ value: String, label: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= structuralLimits.maximumIdentifierUTF8Bytes,
              !value.utf8.contains(0)
        else {
            throw Verification.Error.invalidModule("\(label) is empty, oversized, or contains NUL")
        }
    }

    private func verifyObjectiveCSelector(_ selector: String) throws {
        try verifyIdentifier(selector, label: "Objective-C selector")
        let components = selector.split(separator: ":", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == false,
              components.dropLast().allSatisfy({ component in
                  component.unicodeScalars.allSatisfy {
                      $0 == "_" || CharacterSet.alphanumerics.contains($0)
                  }
              }),
              !selector.unicodeScalars.contains(where: {
                  $0 != ":" && $0 != "_" && !CharacterSet.alphanumerics.contains($0)
              })
        else {
            throw Verification.Error.invalidModule(
                "hosted method selector \(selector) is malformed"
            )
        }
    }

    private func verifyLocalClassDescriptors(
        _ localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        functions: [Bytecode.FunctionID: Bytecode.Function],
        shell: Verification.ShellInterface,
        capabilities: Set<Core.Capability>
    ) throws {
        for definition in localTypes.values {
            guard case let .class(_, hostedSuperclass, methods) = definition.kind else {
                continue
            }
            guard capabilities.contains(.localClassesV1) else {
                throw Verification.Error.capabilityDenied(.localClassesV1)
            }
            if let hostedSuperclass {
                guard capabilities.contains(.hostedObjectiveCClassesV1),
                      let native = shell.types[hostedSuperclass.typeID],
                      native.kind == .reference,
                      native.isCopyable
                else {
                    throw Verification.Error.invalidModule(
                        "hosted class \(definition.key) has no frozen reference superclass"
                    )
                }
            }
            for method in methods {
                guard let function = functions[method.functionID] else {
                    throw Verification.Error.invalidModule(
                        "hosted class \(definition.key) references unknown function \(method.functionID)"
                    )
                }
                let parameters = function.parameterRegisters.compactMap(function.type(of:))
                let expected: [Bytecode.ValueType] = switch method.abi {
                case .voidNoArguments: [.local(definition.key)]
                case .voidBool: [.bool, .local(definition.key)]
                }
                let actorCompatible = hostedSuperclass
                    .flatMap { shell.types[$0.typeID] }
                    .map {
                        !$0.requiresMainActor
                            || function.effects.requiresMainActor
                    } ?? true
                guard parameters.count == function.parameterRegisters.count,
                      parameters == expected,
                      function.resultType == .void,
                      !function.effects.mayThrow,
                      !function.effects.isAsync,
                      actorCompatible
                else {
                    throw Verification.Error.invalidModule(
                        "hosted selector \(method.selector) has an incompatible HLBC function"
                    )
                }
            }
        }
    }

    private func verifySourceMap(
        _ sourceMap: [Bytecode.SourceMapEntry],
        functions: [Bytecode.FunctionID: Bytecode.Function]
    ) throws {
        struct Coordinate: Hashable {
            var functionID: Bytecode.FunctionID
            var blockID: Bytecode.BlockID
            var instructionOffset: UInt32
        }

        var seen = Set<Coordinate>()
        for entry in sourceMap {
            let coordinate = Coordinate(
                functionID: entry.functionID,
                blockID: entry.blockID,
                instructionOffset: entry.instructionOffset
            )
            guard seen.insert(coordinate).inserted else {
                throw Verification.Error.invalidSourceMap("duplicate location for \(entry.functionID).\(entry.blockID)#\(entry.instructionOffset)")
            }
            guard let function = functions[entry.functionID] else {
                throw Verification.Error.invalidSourceMap("unknown function \(entry.functionID)")
            }
            guard let block = function.blocks.first(where: { $0.id == entry.blockID }) else {
                throw Verification.Error.invalidSourceMap("unknown block \(entry.functionID).\(entry.blockID)")
            }
            guard let offset = Int(exactly: entry.instructionOffset),
                  block.instructions.indices.contains(offset)
            else {
                throw Verification.Error.invalidSourceMap(
                    "instruction offset is outside \(entry.functionID).\(entry.blockID)"
                )
            }
            try verifySourceLocation(entry.location) { Verification.Error.invalidSourceMap($0) }
        }
    }

    private func verifySourceLocation<Failure: Swift.Error>(
        _ location: Core.SourceLocation,
        error: (String) -> Failure
    ) throws {
        guard !location.file.isEmpty,
              location.file.utf8.count <= structuralLimits.maximumSourcePathUTF8Bytes,
              !location.file.utf8.contains(0),
              location.line > 0,
              location.column > 0
        else {
            throw error("source location has an invalid path, line, or column")
        }
    }

    private func verifyUniqueFunctions(_ functions: [Bytecode.Function]) throws -> [Bytecode.FunctionID: Bytecode.Function] {
        var result: [Bytecode.FunctionID: Bytecode.Function] = [:]
        for function in functions {
            guard result.updateValue(function, forKey: function.id) == nil else {
                throw Verification.Error.duplicateFunction(function.id)
            }
        }
        return result
    }

    private func verifyEntries(
        _ entries: [Bytecode.EntryPoint],
        functions: [Bytecode.FunctionID: Bytecode.Function],
        shell: Verification.ShellInterface,
        policy: Core.RuntimePolicy,
        capabilities: Set<Core.Capability>
    ) throws {
        var seen = Set<Core.EntryIndex>()
        for entry in entries {
            guard seen.insert(entry.entryIndex).inserted else {
                throw Verification.Error.duplicateEntry(entry.entryIndex)
            }
            guard let shellEntry = shell.entries[entry.entryIndex] else {
                throw Verification.Error.unknownEntry(entry.entryIndex)
            }
            guard shellEntry.key == entry.functionKey else {
                throw Verification.Error.entryKeyMismatch(entry.entryIndex)
            }
            guard let function = functions[entry.functionID] else {
                throw Verification.Error.invalidFunction(
                    function: entry.functionID,
                    reason: "entry references a missing function"
                )
            }
            guard function.kind == .ordinary else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "closure bodies and compiler specializations cannot be patch entries"
                )
            }
            let parameterTypes = try function.parameterRegisters.map { register -> Bytecode.ValueType in
                guard let type = function.type(of: register) else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "parameter register \(register) is out of range"
                    )
                }
                return type
            }
            guard parameterTypes == shellEntry.parameterTypes,
                  function.parameterConventions
                    == shellEntry.parameterConventions,
                  !function.parameterConventions.contains(.inout),
                  function.resultType == shellEntry.resultType,
                  function.effects == shellEntry.effects
            else {
                throw Verification.Error.entrySignatureMismatch(entry.entryIndex)
            }
            if case .local = function.thrownType {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "typed throws cannot cross a Shell entry"
                )
            }
            if shellEntry.effects.requiresMainActor {
                guard policy.allowMainActorSynchronousEntries,
                      shell.capabilities.contains(.mainActorSyncV1),
                      capabilities.contains(.mainActorSyncV1)
                else {
                    throw Verification.Error.capabilityDenied(.mainActorSyncV1)
                }
            }
            if shellEntry.effects.isAsync,
               !capabilities.contains(.asyncLeafEntriesV1) {
                throw Verification.Error.capabilityDenied(.asyncLeafEntriesV1)
            }
            if shellEntry.effects.mayThrow,
               !capabilities.contains(.untypedThrowsV1),
               !capabilities.contains(.structuredErrorsV1) {
                throw Verification.Error.capabilityDenied(.untypedThrowsV1)
            }
        }
    }

    private func verifyImports(
        _ imports: [Bytecode.ImportRequirement],
        shell: Verification.ShellInterface,
        policy: Core.RuntimePolicy,
        capabilities: Set<Core.Capability>
    ) throws -> [Core.NativeImportID: Bytecode.ImportRequirement] {
        if !imports.isEmpty, !capabilities.contains(.nativeImportsV1) {
            throw Verification.Error.capabilityDenied(.nativeImportsV1)
        }
        var seen = Set<Core.NativeImportID>()
        var result: [Core.NativeImportID: Bytecode.ImportRequirement] = [:]
        for requirement in imports {
            guard seen.insert(requirement.id).inserted else {
                throw Verification.Error.duplicateImport(requirement.id)
            }
            guard policy.allowedNativeImports.contains(requirement.id) else {
                throw Verification.Error.importDenied(requirement.id)
            }
            guard let descriptor = shell.imports[requirement.id] else {
                throw Verification.Error.unknownImport(requirement.id)
            }
            guard capabilities.contains(requirement.requiredCapability) else {
                throw Verification.Error.capabilityDenied(requirement.requiredCapability)
            }
            guard descriptor.key == requirement.key,
                  descriptor.signature == requirement.signature,
                  descriptor.effects == requirement.effects,
                  descriptor.contract == requirement.contract,
                  descriptor.capability == requirement.requiredCapability
            else {
                throw Verification.Error.importDescriptorMismatch(requirement.id)
            }
            if descriptor.effects.mayThrow,
               !capabilities.contains(.untypedThrowsV1),
               !capabilities.contains(.structuredErrorsV1) {
                throw Verification.Error.capabilityDenied(.untypedThrowsV1)
            }
            do {
                try descriptor.contract.validate(effects: descriptor.effects)
            } catch {
                throw Verification.Error.invalidShellInterface(
                    "native import \(requirement.id) contract is invalid: \(error)"
                )
            }
            if !descriptor.effects.requiresMainActor,
               (descriptor.parameterTypes + [descriptor.resultType]).contains(where: {
                   usesMainActorNativeType($0, shell: shell)
               }) {
                throw Verification.Error.importDescriptorMismatch(requirement.id)
            }
            result[requirement.id] = requirement
        }
        return result
    }

    private func verifyNativeTypes(_ functions: [Bytecode.Function], shell: Verification.ShellInterface) throws {
        for function in functions {
            let types = function.registerTypes + function.stackSlotTypes
                + [function.resultType]
                + (function.thrownType.map { [$0] } ?? [])
            for type in types {
                try verifyNativeTypes(type, shell: shell)
            }
            if !function.effects.requiresMainActor,
               types
                .contains(where: { usesMainActorNativeType($0, shell: shell) }) {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "MainActor native type is used by a nonisolated function"
                )
            }
        }
    }

    private func usesMainActorNativeType(
        _ type: Bytecode.ValueType,
        shell: Verification.ShellInterface
    ) -> Bool {
        switch type {
        case let .native(id): shell.types[id]?.requiresMainActor == true
        case let .array(element), let .optional(element), let .set(element),
             let .address(element), let .mutableCell(element),
             let .nonOwningReference(_, element),
             let .arrayState(_, element):
            usesMainActorNativeType(element, shell: shell)
        case let .dictionary(key, value):
            usesMainActorNativeType(key, shell: shell)
                || usesMainActorNativeType(value, shell: shell)
        case let .dictionaryState(key, value):
            usesMainActorNativeType(key, shell: shell)
                || usesMainActorNativeType(value, shell: shell)
        case let .tuple(elements):
            elements.contains { usesMainActorNativeType($0, shell: shell) }
        case let .closure(signature):
            signature.componentTypes.contains {
                usesMainActorNativeType($0, shell: shell)
            }
        case .void, .never, .bool, .integer, .float, .string, .any, .local,
             .error:
            false
        }
    }

    private func verifyNativeTypes(_ type: Bytecode.ValueType, shell: Verification.ShellInterface) throws {
        switch type {
        case let .native(id):
            guard shell.types[id] != nil else { throw Verification.Error.unknownNativeType(id) }
        case let .tuple(elements):
            for element in elements { try verifyNativeTypes(element, shell: shell) }
        case let .optional(wrapped), let .address(wrapped),
             let .mutableCell(wrapped),
             let .nonOwningReference(_, wrapped),
             let .arrayState(_, wrapped):
            try verifyNativeTypes(wrapped, shell: shell)
        case let .array(element):
            try verifyNativeTypes(element, shell: shell)
        case let .set(element):
            try verifyNativeTypes(element, shell: shell)
        case let .dictionary(key, value):
            try verifyNativeTypes(key, shell: shell)
            try verifyNativeTypes(value, shell: shell)
        case let .dictionaryState(key, value):
            try verifyNativeTypes(key, shell: shell)
            try verifyNativeTypes(value, shell: shell)
        case let .closure(signature):
            for component in signature.componentTypes {
                try verifyNativeTypes(component, shell: shell)
            }
        case .void, .never, .bool, .integer, .float, .string, .any, .local,
             .error:
            break
        }
    }

    private func verifyTypeCapabilities(
        _ functions: [Bytecode.Function],
        localTypes: [Bytecode.LocalTypeDefinition],
        capabilities: Set<Core.Capability>
    ) throws {
        func visit(_ type: Bytecode.ValueType) throws {
            switch type {
            case .string:
                guard capabilities.contains(.stringsV1) else {
                    throw Verification.Error.capabilityDenied(.stringsV1)
                }
            case .any:
                guard capabilities.contains(.anyValuesV1) else {
                    throw Verification.Error.capabilityDenied(.anyValuesV1)
                }
            case .native:
                guard capabilities.contains(.nativeTypesV1) else {
                    throw Verification.Error.capabilityDenied(.nativeTypesV1)
                }
            case .local:
                guard capabilities.contains(.localNominalsV1) else {
                    throw Verification.Error.capabilityDenied(.localNominalsV1)
                }
            case .error:
                guard capabilities.contains(.structuredErrorsV1) else {
                    throw Verification.Error.capabilityDenied(.structuredErrorsV1)
                }
            case let .address(pointee):
                guard capabilities.contains(.addressValuesV1) else {
                    throw Verification.Error.capabilityDenied(.addressValuesV1)
                }
                try visit(pointee)
            case let .mutableCell(pointee):
                guard capabilities.contains(.mutableCapturesV1) else {
                    throw Verification.Error.capabilityDenied(.mutableCapturesV1)
                }
                try visit(pointee)
            case let .nonOwningReference(_, pointee):
                guard capabilities.contains(.nonOwningReferencesV1) else {
                    throw Verification.Error.capabilityDenied(
                        .nonOwningReferencesV1
                    )
                }
                try visit(pointee)
            case let .arrayState(_, element):
                guard capabilities.contains(.collectionsV1) else {
                    throw Verification.Error.capabilityDenied(.collectionsV1)
                }
                try visit(element)
            case let .dictionaryState(key, value):
                guard capabilities.contains(.collectionsV1) else {
                    throw Verification.Error.capabilityDenied(.collectionsV1)
                }
                try visit(key)
                try visit(value)
            case let .closure(signature):
                guard capabilities.contains(.closureValuesV1) else {
                    throw Verification.Error.capabilityDenied(.closureValuesV1)
                }
                if signature.effects.requiresMainActor,
                   !capabilities.contains(.mainActorSyncV1) {
                    throw Verification.Error.capabilityDenied(.mainActorSyncV1)
                }
                if let thrownType = signature.thrownType {
                    switch thrownType {
                    case .string:
                        guard capabilities.contains(.untypedThrowsV1) else {
                            throw Verification.Error.capabilityDenied(.untypedThrowsV1)
                        }
                    case .error:
                        guard capabilities.contains(.structuredErrorsV1) else {
                            throw Verification.Error.capabilityDenied(.structuredErrorsV1)
                        }
                    case .local:
                        guard capabilities.contains(.typedThrowsV1) else {
                            throw Verification.Error.capabilityDenied(.typedThrowsV1)
                        }
                    default:
                        break
                    }
                }
                for component in signature.componentTypes {
                    try visit(component)
                }
            case let .array(element):
                guard capabilities.contains(.collectionsV1) else {
                    throw Verification.Error.capabilityDenied(.collectionsV1)
                }
                try visit(element)
            case let .dictionary(key, value):
                guard capabilities.contains(.collectionsV1) else {
                    throw Verification.Error.capabilityDenied(.collectionsV1)
                }
                try visit(key)
                try visit(value)
            case let .set(element):
                guard capabilities.contains(.collectionsV1) else {
                    throw Verification.Error.capabilityDenied(.collectionsV1)
                }
                try visit(element)
            case let .tuple(elements):
                for element in elements { try visit(element) }
            case let .optional(wrapped):
                try visit(wrapped)
            case .void, .never, .bool, .integer, .float:
                break
            }
        }
        for function in functions {
            let storesEscapingClosure = function.registerTypes.contains(
                where: \.containsNestedClosureValue
            ) || function.stackSlotTypes.contains(
                where: \.containsClosureValue
            ) || function.resultType.containsClosureValue
            if storesEscapingClosure,
               !capabilities.contains(.escapingClosureValuesV1) {
                throw Verification.Error.capabilityDenied(
                    .escapingClosureValuesV1
                )
            }
            let types = function.registerTypes + function.stackSlotTypes
                + [function.resultType]
                + (function.thrownType.map { [$0] } ?? [])
            for type in types {
                try visit(type)
            }
        }
        for definition in localTypes {
            switch definition.kind {
            case let .structure(fields):
                for field in fields {
                    if field.type.containsClosureValue,
                       !capabilities.contains(.escapingClosureValuesV1) {
                        throw Verification.Error.capabilityDenied(
                            .escapingClosureValuesV1
                        )
                    }
                    try visit(field.type)
                }
            case let .enumeration(cases):
                for item in cases {
                    if let payload = item.payloadType {
                        if payload.containsClosureValue,
                           !capabilities.contains(.escapingClosureValuesV1) {
                            throw Verification.Error.capabilityDenied(
                                .escapingClosureValuesV1
                            )
                        }
                        try visit(payload)
                    }
                }
            case let .class(fields, hostedSuperclass, _):
                guard capabilities.contains(.localClassesV1) else {
                    throw Verification.Error.capabilityDenied(.localClassesV1)
                }
                if hostedSuperclass != nil,
                   !capabilities.contains(.hostedObjectiveCClassesV1) {
                    throw Verification.Error.capabilityDenied(
                        .hostedObjectiveCClassesV1
                    )
                }
                for field in fields {
                    if field.type.containsClosureValue,
                       !capabilities.contains(.escapingClosureValuesV1) {
                        throw Verification.Error.capabilityDenied(
                            .escapingClosureValuesV1
                        )
                    }
                    try visit(field.type)
                }
            }
        }
    }

    private func verifyFunction(
        _ function: Bytecode.Function,
        functions: [Bytecode.FunctionID: Bytecode.Function],
        shell: Verification.ShellInterface,
        effectiveLimits: Core.ResourceLimits,
        declaredImports: [Core.NativeImportID: Bytecode.ImportRequirement],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        capabilities: Set<Core.Capability>,
        entryFunctionIDs: Set<Bytecode.FunctionID>
    ) throws {
        switch function.kind {
        case .ordinary:
            break
        case .closureBody:
            guard capabilities.contains(.closureValuesV1) else {
                throw Verification.Error.capabilityDenied(.closureValuesV1)
            }
        case .concreteSpecialization:
            guard capabilities.contains(.compilerSpecializationsV1) else {
                throw Verification.Error.capabilityDenied(.compilerSpecializationsV1)
            }
        }
        if function.effects.mayThrow,
           !capabilities.contains(.untypedThrowsV1),
           !capabilities.contains(.structuredErrorsV1),
           !capabilities.contains(.typedThrowsV1) {
            throw Verification.Error.capabilityDenied(.untypedThrowsV1)
        }
        guard function.hasCanonicalThrownType else {
            throw Verification.Error.invalidFunction(
                function: function.id,
                reason: "throwing effect and thrown type disagree"
            )
        }
        if let thrownType = function.thrownType {
            switch thrownType {
            case .string:
                guard capabilities.contains(.untypedThrowsV1) else {
                    throw Verification.Error.capabilityDenied(.untypedThrowsV1)
                }
            case .error:
                guard capabilities.contains(.structuredErrorsV1) else {
                    throw Verification.Error.capabilityDenied(.structuredErrorsV1)
                }
            case let .local(key):
                guard capabilities.contains(.typedThrowsV1) else {
                    throw Verification.Error.capabilityDenied(.typedThrowsV1)
                }
                guard localTypes[key]?.conformsToError == true else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "typed throws requires a local Error-conforming nominal"
                    )
                }
            default:
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "function has a non-Error thrown type"
                )
            }
        }
        if function.effects.requiresMainActor, !capabilities.contains(.mainActorSyncV1) {
            throw Verification.Error.capabilityDenied(.mainActorSyncV1)
        }
        if function.effects.isAsync {
            guard capabilities.contains(.asyncLeafEntriesV1) else {
                throw Verification.Error.capabilityDenied(.asyncLeafEntriesV1)
            }
            guard function.kind == .ordinary, entryFunctionIDs.contains(function.id) else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "async functions must be non-suspending Shell entries"
                )
            }
        }
        guard function.parameterConventions.count == function.parameterRegisters.count else {
            throw Verification.Error.invalidFunction(
                function: function.id,
                reason: "parameter convention count does not match parameter registers"
            )
        }
        for (register, convention) in zip(
            function.parameterRegisters,
            function.parameterConventions
        ) {
            guard let type = function.type(of: register) else { continue }
            switch (convention, type) {
            case (.inout, .address):
                guard capabilities.contains(.addressValuesV1) else {
                    throw Verification.Error.capabilityDenied(.addressValuesV1)
                }
            case (.borrowed, .address), (.owned, .address), (.inout, _):
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "parameter convention does not match its value/address type"
                )
            case (.borrowed, _):
                guard capabilities.contains(.borrowCallsV1) else {
                    throw Verification.Error.capabilityDenied(.borrowCallsV1)
                }
            case (.owned, _):
                break
            }
        }
        let frameValueCount = function.registerTypes.count.addingReportingOverflow(
            function.stackSlotTypes.count
        )
        guard !frameValueCount.overflow,
              frameValueCount.partialValue <= Int(effectiveLimits.maxFrameRegisters)
        else {
            throw Verification.Error.invalidFunction(
                function: function.id,
                reason: "register and stack-slot count exceeds policy"
            )
        }
        guard !function.blocks.isEmpty else {
            throw Verification.Error.invalidFunction(function: function.id, reason: "function has no blocks")
        }
        try verifyTypeShapes(
            function,
            shell: shell,
            localTypes: localTypes
        )

        var blocks: [Bytecode.BlockID: Bytecode.Block] = [:]
        for block in function.blocks {
            guard blocks.updateValue(block, forKey: block.id) == nil else {
                throw Verification.Error.invalidBlock(function: function.id, block: block.id, reason: "duplicate block")
            }
        }
        guard let entry = blocks[function.entryBlock] else {
            throw Verification.Error.invalidFunction(function: function.id, reason: "entry block is missing")
        }
        guard entry.parameters == function.parameterRegisters else {
            throw Verification.Error.invalidBlock(
                function: function.id,
                block: entry.id,
                reason: "entry block parameters must equal function parameter registers"
            )
        }
        for block in function.blocks where block.id != function.entryBlock {
            guard !block.parameters.contains(where: {
                guard let type = function.type(of: $0) else { return false }
                return switch type {
                case .address, .mutableCell: true
                default: false
                }
            }) else {
                throw Verification.Error.invalidBlock(
                    function: function.id,
                    block: block.id,
                    reason: "address and mutable-cell values cannot be HLBC block parameters"
                )
            }
        }

        var definitions: [Bytecode.Register: (block: Bytecode.BlockID, offset: Int)] = [:]
        for block in function.blocks {
            for parameter in block.parameters {
                try requireRegister(parameter, function: function, block: block.id, offset: -1)
                guard definitions.updateValue((block.id, -1), forKey: parameter) == nil else {
                    throw Verification.Error.invalidBlock(
                        function: function.id,
                        block: block.id,
                        reason: "register \(parameter) has more than one definition"
                    )
                }
            }
            guard let terminator = block.instructions.last, terminator.isTerminator else {
                throw Verification.Error.invalidBlock(
                    function: function.id,
                    block: block.id,
                    reason: "block must end in exactly one terminator"
                )
            }
            for (offset, instruction) in block.instructions.enumerated() {
                if instruction.isTerminator && offset != block.instructions.count - 1 {
                    throw Verification.Error.invalidInstruction(
                        function: function.id,
                        block: block.id,
                        offset: offset,
                        reason: "terminator is not the final instruction"
                    )
                }
                for result in instruction.resultRegisters {
                    try requireRegister(result, function: function, block: block.id, offset: offset)
                    guard definitions.updateValue((block.id, offset), forKey: result) == nil else {
                        throw Verification.Error.invalidInstruction(
                            function: function.id,
                            block: block.id,
                            offset: offset,
                            reason: "register \(result) has more than one definition"
                        )
                    }
                }
            }
        }
        try verifyClosureScopeLifetimes(
            function,
            blocks: blocks,
            shell: shell,
            localTypes: localTypes
        )

        let predecessors = try buildPredecessors(function: function, blocks: blocks)
        guard predecessors[function.entryBlock]?.isEmpty == true else {
            throw Verification.Error.invalidBlock(
                function: function.id,
                block: function.entryBlock,
                reason: "entry block cannot have predecessors"
            )
        }
        let reachable = computeReachable(entry: function.entryBlock, predecessors: predecessors)
        guard reachable.count == blocks.count else {
            let missing = Set(blocks.keys).subtracting(reachable).sorted()
            throw Verification.Error.invalidFunction(function: function.id, reason: "unreachable blocks: \(missing)")
        }
        let dominators = computeDominators(entry: function.entryBlock, blocks: Set(blocks.keys), predecessors: predecessors)

        for block in function.blocks {
            for (offset, instruction) in block.instructions.enumerated() {
                for operand in instruction.operandRegisters {
                    try requireRegister(operand, function: function, block: block.id, offset: offset)
                    guard let definition = definitions[operand] else {
                        throw Verification.Error.invalidInstruction(
                            function: function.id,
                            block: block.id,
                            offset: offset,
                            reason: "register \(operand) is used before definition"
                        )
                    }
                    if definition.block == block.id {
                        guard definition.offset < offset else {
                            throw Verification.Error.invalidInstruction(
                                function: function.id,
                                block: block.id,
                                offset: offset,
                                reason: "register \(operand) does not dominate its use"
                            )
                        }
                    } else if !(dominators[block.id]?.contains(definition.block) ?? false) {
                        throw Verification.Error.invalidInstruction(
                            function: function.id,
                            block: block.id,
                            offset: offset,
                            reason: "register \(operand) does not dominate its use"
                        )
                    }
                }
                try verifyInstructionTypes(
                    instruction,
                    function: function,
                    block: block,
                    offset: offset,
                    functions: functions,
                    blocks: blocks,
                    shell: shell,
                    declaredImports: declaredImports,
                    localTypes: localTypes,
                    capabilities: capabilities,
                    effectiveLimits: effectiveLimits
                )
            }
        }
        let borrowedMutableCells = try borrowedMutableCellFacts(function)
        try verifyBorrowedMutableCellLifetimes(
            function,
            facts: borrowedMutableCells
        )
        try verifyOwnership(
            function: function,
            blocks: blocks,
            functions: functions,
            shell: shell
        )
        try verifyMutableCellLifecycle(
            function: function,
            blocks: blocks,
            dominators: dominators,
            localTypes: localTypes
        )
        try verifyStackLifecycle(
            function: function,
            blocks: blocks,
            localTypes: localTypes
        )
        try verifyAddressLifecycle(
            function: function,
            functions: functions,
            borrowedMutableCells: borrowedMutableCells
        )
    }

    private func verifyTypeShapes(
        _ function: Bytecode.Function,
        shell: Verification.ShellInterface,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) throws {
        func verify(_ type: Bytecode.ValueType, depth: Int, isRegister: Bool) throws {
            guard depth <= 32 else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "type nesting exceeds 32 levels"
                )
            }
            switch type {
            case let .integer(bitWidth, _):
                guard [8, 16, 32, 64].contains(bitWidth) else {
                    throw Verification.Error.invalidFunction(function: function.id, reason: "unsupported integer width \(bitWidth)")
                }
            case let .float(bitWidth):
                guard bitWidth == 32 || bitWidth == 64 else {
                    throw Verification.Error.invalidFunction(function: function.id, reason: "unsupported float width \(bitWidth)")
                }
            case let .tuple(elements):
                guard elements.count <= 64 else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "tuple contains more than 64 elements"
                    )
                }
                for element in elements {
                    try verify(element, depth: depth + 1, isRegister: false)
                }
            case let .optional(wrapped):
                try verify(wrapped, depth: depth + 1, isRegister: false)
            case let .array(element):
                try verify(element, depth: depth + 1, isRegister: false)
            case let .set(element):
                guard element.isVMHashable else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "Set element lacks VM-defined Hashable semantics"
                    )
                }
                try verify(element, depth: depth + 1, isRegister: false)
            case let .dictionary(key, value):
                guard key.isVMHashable else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "Dictionary key lacks VM-defined Hashable semantics"
                    )
                }
                try verify(key, depth: depth + 1, isRegister: false)
                try verify(value, depth: depth + 1, isRegister: false)
            case let .address(pointee):
                guard isRegister, depth == 0 else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "address values must be top-level registers"
                    )
                }
                switch pointee {
                case .void, .never, .address, .mutableCell,
                     .nonOwningReference, .arrayState,
                     .dictionaryState:
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "address pointee must be a concrete non-address value type"
                    )
                default:
                    try verify(pointee, depth: depth + 1, isRegister: false)
                }
            case let .mutableCell(pointee):
                guard isRegister, depth == 0 else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "mutable cells must be top-level registers"
                    )
                }
                switch pointee {
                case .void, .never, .address, .mutableCell,
                     .nonOwningReference, .arrayState,
                     .dictionaryState:
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "mutable-cell pointee must be a concrete value type"
                    )
                default:
                    try verify(pointee, depth: depth + 1, isRegister: false)
                }
            case let .nonOwningReference(kind, pointee):
                guard isRegister, depth == 0 else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "non-owning references must be top-level registers"
                    )
                }
                if case .optional = pointee {
                    // Both weak and optional unowned storage use an Optional
                    // strong value at their checked load boundary.
                } else {
                    guard kind == .unowned else {
                        throw Verification.Error.invalidFunction(
                            function: function.id,
                            reason: "weak references must load an Optional value"
                        )
                    }
                }
                guard isValidNonOwningReference(
                    kind: kind,
                    pointee: pointee,
                    shell: shell,
                    localTypes: localTypes
                ) else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "non-owning reference pointee must be a local or native class"
                    )
                }
            case let .arrayState(_, element):
                guard isRegister, depth == 0 else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "Array operation states must be top-level registers"
                    )
                }
                switch element {
                case .void, .never, .address, .mutableCell,
                     .nonOwningReference, .arrayState,
                     .dictionaryState:
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "Array-state element must be a concrete value type"
                    )
                default:
                    try verify(element, depth: depth + 1, isRegister: false)
                }
            case let .dictionaryState(key, value):
                guard isRegister, depth == 0 else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "Dictionary operation states must be top-level registers"
                    )
                }
                guard key.isVMHashable else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "Dictionary-state key lacks VM-defined Hashable semantics"
                    )
                }
                for component in [key, value] {
                    switch component {
                    case .void, .never, .address, .mutableCell,
                         .nonOwningReference, .arrayState,
                         .dictionaryState:
                        throw Verification.Error.invalidFunction(
                            function: function.id,
                            reason: "Dictionary-state components must be concrete value types"
                        )
                    default:
                        try verify(
                            component,
                            depth: depth + 1,
                            isRegister: false
                        )
                    }
                }
            case let .closure(signature):
                guard signature.parameters.count <= 64 else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "closure signature contains more than 64 parameters"
                    )
                }
                guard signature.hasCanonicalCallableEffects else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "closure signature cannot carry execution authority"
                    )
                }
                guard signature.hasCanonicalThrownType else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "closure signature has inconsistent throwing ABI"
                    )
                }
                if let thrownType = signature.thrownType {
                    switch thrownType {
                    case .string, .error:
                        break
                    case let .local(key)
                    where localTypes[key]?.conformsToError == true:
                        break
                    default:
                        throw Verification.Error.invalidFunction(
                            function: function.id,
                            reason: "closure signature has a non-Error thrown type"
                        )
                    }
                }
                guard signature.parameterConventions.count
                        == signature.parameters.count,
                      zip(
                        signature.parameters,
                        signature.parameterConventions
                      ).allSatisfy({ parameter, convention in
                        switch (parameter, convention) {
                        case (.address, .inout): true
                        case (.address, _), (_, .inout): false
                        default: true
                        }
                      })
                else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "closure signature has invalid parameter ownership"
                    )
                }
                guard !signature.effects.isAsync else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "async closures require a suspension-aware closure contract"
                    )
                }
                for parameter in signature.parameters {
                    switch parameter {
                    case .void, .never, .mutableCell, .nonOwningReference,
                         .arrayState,
                         .dictionaryState:
                        throw Verification.Error.invalidFunction(
                            function: function.id,
                            reason: "closure parameters must be concrete values or inout addresses"
                        )
                    case let .address(pointee):
                        switch pointee {
                        case .void, .never, .address, .mutableCell,
                             .nonOwningReference,
                             .arrayState, .dictionaryState:
                            throw Verification.Error.invalidFunction(
                                function: function.id,
                                reason: "inout closure pointee must be a concrete value type"
                            )
                        default:
                            try verify(
                                pointee,
                                depth: depth + 1,
                                isRegister: false
                            )
                        }
                    default:
                        try verify(parameter, depth: depth + 1, isRegister: false)
                    }
                }
                switch signature.result {
                case .never, .address, .mutableCell, .nonOwningReference,
                     .arrayState,
                     .dictionaryState:
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "closure result must be Void or a concrete non-address value"
                    )
                default:
                    try verify(signature.result, depth: depth + 1, isRegister: false)
                }
            case .void, .never:
                guard !isRegister else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "Void/Never cannot be stored in a register"
                    )
                }
            case .bool, .string, .any, .native, .local, .error:
                break
            }
        }
        for type in function.registerTypes {
            try verify(type, depth: 0, isRegister: true)
        }
        for type in function.stackSlotTypes {
            if case .address = type {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "stack slots store values rather than addresses"
                )
            }
            if case .mutableCell = type {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "mutable cells cannot be stored in stack slots"
                )
            }
            if case .nonOwningReference = type {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "non-owning reference storage cannot be stored in stack slots"
                )
            }
            if case .arrayState = type {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "Array operation states cannot be stored in stack slots"
                )
            }
            if case .dictionaryState = type {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "Dictionary operation states cannot be stored in stack slots"
                )
            }
            try verify(type, depth: 0, isRegister: true)
        }
        if case .address = function.resultType {
            throw Verification.Error.invalidFunction(
                function: function.id,
                reason: "address values cannot be returned"
            )
        }
        if case .mutableCell = function.resultType {
            throw Verification.Error.invalidFunction(
                function: function.id,
                reason: "mutable cells cannot be returned"
            )
        }
        if case .nonOwningReference = function.resultType {
            throw Verification.Error.invalidFunction(
                function: function.id,
                reason: "non-owning reference storage cannot be returned"
            )
        }
        if case .arrayState = function.resultType {
            throw Verification.Error.invalidFunction(
                function: function.id,
                reason: "Array operation states cannot be returned"
            )
        }
        if case .dictionaryState = function.resultType {
            throw Verification.Error.invalidFunction(
                function: function.id,
                reason: "Dictionary operation states cannot be returned"
            )
        }
        if function.parameterRegisters.contains(where: { parameter in
            guard let type = function.type(of: parameter) else { return false }
            return switch type {
            case .arrayState, .dictionaryState: true
            default: false
            }
        }) {
            throw Verification.Error.invalidFunction(
                function: function.id,
                reason: "collection operation states cannot be function parameters"
            )
        }
        try verify(function.resultType, depth: 0, isRegister: false)
    }

    /// Verifies lexical closure dynamic extents over the CFG, including Swift's
    /// `withoutActuallyEscaping`. Throwing bodies close the same scope
    /// independently on their normal and error edges, while loops may create a
    /// fresh scope after the prior iteration closed. Closed values are
    /// propagated only while live so a branch-local scope does not poison an
    /// unrelated merge.
    private func verifyClosureScopeLifetimes(
        _ function: Bytecode.Function,
        blocks: [Bytecode.BlockID: Bytecode.Block],
        shell: Verification.ShellInterface,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) throws {
        let scopedRegisters: Set<Bytecode.Register> = Set(
            function.blocks.flatMap { block -> [Bytecode.Register] in
                block.instructions.compactMap {
                    instruction -> Bytecode.Register? in
                    switch instruction {
                    case let .beginClosureScope(result, _):
                        result
                    case let .makeClosure(result, _, _, .lexical):
                        result
                    default:
                        nil
                    }
                }
            }
        )
        let hasScopeEnd = function.blocks.contains { block in
            block.instructions.contains { instruction in
                if case .endClosureScope = instruction { return true }
                return false
            }
        }
        guard !scopedRegisters.isEmpty || hasScopeEnd else { return }
        var parentsByValue: [
            Bytecode.Register: Set<Bytecode.Register>
        ] = [:]

        func canContainClosure(
            _ type: Bytecode.ValueType,
            visiting: inout Set<Bytecode.LocalTypeKey>
        ) -> Bool {
            if type.containsClosureValue { return true }
            switch type {
            case .any, .error:
                return true
            case let .local(key):
                guard visiting.insert(key).inserted,
                      let definition = localTypes[key]
                else { return false }
                defer { visiting.remove(key) }
                switch definition.kind {
                case let .structure(fields), let .class(fields, _, _):
                    return fields.contains {
                        canContainClosure($0.type, visiting: &visiting)
                    }
                case let .enumeration(cases):
                    return cases.contains {
                        $0.payloadType.map {
                            canContainClosure($0, visiting: &visiting)
                        } == true
                    }
                }
            case let .optional(wrapped), let .array(wrapped),
                 let .set(wrapped), let .address(wrapped),
                 let .mutableCell(wrapped),
                 let .nonOwningReference(_, wrapped),
                 let .arrayState(_, wrapped):
                return canContainClosure(wrapped, visiting: &visiting)
            case let .dictionary(key, value),
                 let .dictionaryState(key, value):
                return canContainClosure(key, visiting: &visiting)
                    || canContainClosure(value, visiting: &visiting)
            case let .tuple(elements):
                return elements.contains {
                    canContainClosure($0, visiting: &visiting)
                }
            case .closure:
                return true
            case .void, .never, .bool, .integer, .float, .string, .native:
                return false
            }
        }

        func canContainClosure(_ register: Bytecode.Register) -> Bool {
            guard let type = function.type(of: register) else { return false }
            var visiting = Set<Bytecode.LocalTypeKey>()
            return canContainClosure(type, visiting: &visiting)
        }

        func addParents(
            _ parents: some Sequence<Bytecode.Register>,
            to result: Bytecode.Register
        ) {
            parentsByValue[result, default: []].formUnion(parents)
        }

        for instruction in function.blocks.flatMap(\.instructions) {
            let operands = instruction.operandRegisters
            let structurallyPropagatesOperands: Bool = switch instruction {
            case .apply, .entryApply, .nativeApply, .closureApply:
                // A call result is not storage derived from its arguments.
                // Runtime graph checks still catch a callee that actually
                // returns a dynamically scoped closure value.
                false
            default:
                true
            }
            if structurallyPropagatesOperands {
                for result in instruction.resultRegisters
                where canContainClosure(result) {
                    addParents(operands, to: result)
                }
            }
        }

        for block in function.blocks {
            guard let terminator = block.instructions.last else { continue }
            let edges: [(Bytecode.BlockID, [Bytecode.Register])] =
                switch terminator {
                case let .branch(target, arguments):
                    [(target, arguments)]
                case let .conditionalBranch(
                    _,
                    trueTarget,
                    trueArguments,
                    falseTarget,
                    falseArguments
                ):
                    [
                        (trueTarget, trueArguments),
                        (falseTarget, falseArguments),
                    ]
                default:
                    []
                }
            for (target, arguments) in edges {
                guard let parameters = blocks[target]?.parameters else {
                    continue
                }
                for (parameter, argument) in zip(parameters, arguments)
                where canContainClosure(parameter) {
                    addParents([argument], to: parameter)
                }
            }
        }

        func depends(
            _ candidate: Bytecode.Register,
            on ancestor: Bytecode.Register
        ) -> Bool {
            var pending = [candidate]
            var visited = Set<Bytecode.Register>()
            while let current = pending.popLast(),
                  visited.insert(current).inserted {
                let parents = parentsByValue[current] ?? []
                if parents.contains(ancestor) { return true }
                pending.append(contentsOf: parents)
            }
            return false
        }

        var scopeAncestorsByRegister: [
            Bytecode.Register: Set<Bytecode.Register>
        ] = [:]
        func scopeAncestors(
            of candidate: Bytecode.Register
        ) -> Set<Bytecode.Register> {
            if let cached = scopeAncestorsByRegister[candidate] {
                return cached
            }
            var ancestors = Set<Bytecode.Register>()
            var pending = [candidate]
            var visited = Set<Bytecode.Register>()
            while let current = pending.popLast(),
                  visited.insert(current).inserted {
                if scopedRegisters.contains(current) {
                    ancestors.insert(current)
                }
                pending.append(contentsOf: parentsByValue[current] ?? [])
            }
            scopeAncestorsByRegister[candidate] = ancestors
            return ancestors
        }

        var usesBeforeDefinition: [Bytecode.BlockID: Set<Bytecode.Register>]
            = [:]
        var definitions: [Bytecode.BlockID: Set<Bytecode.Register>] = [:]
        for block in function.blocks {
            var blockDefinitions = Set<Bytecode.Register>()
            var blockUses = Set<Bytecode.Register>()
            for instruction in block.instructions {
                for operand in instruction.operandRegisters {
                    for scope in scopeAncestors(of: operand)
                    where !blockDefinitions.contains(scope) {
                        blockUses.insert(scope)
                    }
                }
                switch instruction {
                case let .beginClosureScope(result, _):
                    blockDefinitions.insert(result)
                case let .makeClosure(result, _, _, .lexical):
                    blockDefinitions.insert(result)
                default:
                    break
                }
            }
            usesBeforeDefinition[block.id] = blockUses
            definitions[block.id] = blockDefinitions
        }

        var liveIn = Dictionary(
            uniqueKeysWithValues: function.blocks.map {
                ($0.id, Set<Bytecode.Register>())
            }
        )
        var changed = true
        while changed {
            changed = false
            for block in function.blocks.reversed() {
                let liveOut = Set(
                    (block.instructions.last?.successorBlocks ?? []).flatMap {
                        liveIn[$0] ?? []
                    }
                )
                let next = (usesBeforeDefinition[block.id] ?? [])
                    .union(liveOut.subtracting(definitions[block.id] ?? []))
                if liveIn[block.id] != next {
                    liveIn[block.id] = next
                    changed = true
                }
            }
        }

        struct ScopeState: Equatable {
            var open = Set<Bytecode.Register>()
            var closed = Set<Bytecode.Register>()
        }
        var incoming: [Bytecode.BlockID: ScopeState] = [
            function.entryBlock: .init(),
        ]
        var pending = [function.entryBlock]
        var queued = Set(pending)

        while let blockID = pending.popLast() {
            queued.remove(blockID)
            guard let block = blocks[blockID],
                  var state = incoming[blockID]
            else { continue }
            for (offset, instruction) in block.instructions.enumerated() {
                func fail(_ reason: String) -> Verification.Error {
                    .invalidInstruction(
                        function: function.id,
                        block: block.id,
                        offset: offset,
                        reason: reason
                    )
                }
                if let used = instruction.operandRegisters.first(where: {
                    !state.closed.isDisjoint(
                        with: scopeAncestors(of: $0)
                    )
                }) {
                    throw fail(
                        "closed dynamic closure scope \(used) is reused"
                    )
                }
                switch instruction {
                case let .beginClosureScope(result, _):
                    guard !state.open.contains(result) else {
                        throw fail(
                            "a closure scope result cannot be reopened before it closes"
                        )
                    }
                    state.closed.remove(result)
                    state.open.insert(result)
                case let .makeClosure(result, _, _, .lexical):
                    guard !state.open.contains(result) else {
                        throw fail(
                            "a lexical closure scope is reentered before it closes"
                        )
                    }
                    state.closed.remove(result)
                    state.open.insert(result)
                case let .endClosureScope(closure):
                    guard state.open.contains(closure) else {
                        throw fail(
                            "end_closure_scope has no matching open scope"
                        )
                    }
                    guard !state.open.contains(where: {
                        $0 != closure && depends($0, on: closure)
                    }) else {
                        throw fail(
                            "an outer closure scope cannot end before its nested scope"
                        )
                    }
                    state.open.remove(closure)
                    state.closed.insert(closure)
                case let .nativeApply(_, importID, arguments),
                     let .nativeTryApply(importID, arguments, _, _):
                    let nonescapingParameters = Set(
                        shell.imports[importID]?.contract.callbacks.compactMap {
                            callback in
                            callback.lifetime == .nonescaping
                                ? Int(callback.parameterIndex) : nil
                        } ?? []
                    )
                    for (index, argument) in arguments.enumerated()
                    where !state.open.isDisjoint(
                        with: scopeAncestors(of: argument)
                    )
                        && !nonescapingParameters.contains(index) {
                        throw fail(
                            "a dynamically scoped closure cannot enter an escaping NativeImport callback"
                        )
                    }
                case .returnValue, .throwError:
                    guard state.open.isEmpty else {
                        throw fail(
                            "a dynamic closure scope reaches a normal function exit"
                        )
                    }
                case .sourceFailure, .trap:
                    // A fatal VM exit discards the entire frame; there is no
                    // continuation from which a scoped closure can be used.
                    state.open.removeAll()
                    state.closed.removeAll()
                default:
                    break
                }
            }

            for successor in block.instructions.last?.successorBlocks ?? [] {
                var edge = state
                edge.closed.formIntersection(liveIn[successor] ?? [])
                if var existing = incoming[successor] {
                    let old = existing
                    existing.open.formUnion(edge.open)
                    existing.closed.formUnion(edge.closed)
                    guard existing != old else { continue }
                    incoming[successor] = existing
                } else {
                    incoming[successor] = edge
                }
                if queued.insert(successor).inserted {
                    pending.append(successor)
                }
            }
        }
    }

    private struct BorrowedMutableCellFacts {
        var sourceAddressByCell: [
            Bytecode.Register: Bytecode.Register
        ] = [:]
        var sourceAddressesByClosure: [
            Bytecode.Register: Set<Bytecode.Register>
        ] = [:]

        var isEmpty: Bool { sourceAddressByCell.isEmpty }
    }

    /// Resolves every borrowed-cell projection back to the active address that
    /// owns its lifetime. Lexical closures retain those roots as verifier-only
    /// facts; no address capability enters their runtime value representation.
    private func borrowedMutableCellFacts(
        _ function: Bytecode.Function
    ) throws -> BorrowedMutableCellFacts {
        var definitions: [Bytecode.Register: Bytecode.Instruction] = [:]
        for block in function.blocks {
            for instruction in block.instructions {
                for result in instruction.resultRegisters {
                    definitions[result] = instruction
                }
            }
        }
        var facts = BorrowedMutableCellFacts()
        var resolving = Set<Bytecode.Register>()

        func sourceAddress(
            of register: Bytecode.Register
        ) throws -> Bytecode.Register? {
            if let cached = facts.sourceAddressByCell[register] {
                return cached
            }
            guard resolving.insert(register).inserted else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "borrowed mutable-cell provenance contains a cycle"
                )
            }
            defer { resolving.remove(register) }
            let result: Bytecode.Register? = switch definitions[register] {
            case let .borrowMutableCell(_, address):
                address
            case let .copyValue(_, source), let .moveValue(_, source):
                try sourceAddress(of: source)
            case let .projectMutableCell(_, cell, _):
                try sourceAddress(of: cell)
            default:
                nil
            }
            if let result {
                facts.sourceAddressByCell[register] = result
            }
            return result
        }

        for index in function.registerTypes.indices {
            guard let raw = UInt32(exactly: index) else { continue }
            _ = try sourceAddress(of: .init(rawValue: raw))
        }
        guard !facts.isEmpty else { return facts }

        for block in function.blocks {
            for instruction in block.instructions {
                let construction: (
                    result: Bytecode.Register,
                    captures: [Bytecode.Register],
                    lifetime: Bytecode.ClosureLifetime
                )? = switch instruction {
                case let .makeClosure(result, _, captures, lifetime):
                    (result, captures, lifetime)
                default:
                    nil
                }
                guard let construction,
                      construction.lifetime == .lexical
                else { continue }
                let sources = try Set(construction.captures.compactMap { capture in
                    try sourceAddress(of: capture)
                })
                if !sources.isEmpty {
                    facts.sourceAddressesByClosure[construction.result] = sources
                }
            }
        }
        return facts
    }

    /// A cell borrowed from caller-owned inout storage is only a representation
    /// adapter for a lexical closure capture. It may be copied or projected
    /// locally, but cannot enter an invocation-lifetime closure or any other
    /// storage/call boundary.
    private func verifyBorrowedMutableCellLifetimes(
        _ function: Bytecode.Function,
        facts: BorrowedMutableCellFacts
    ) throws {
        guard !facts.isEmpty else { return }

        for block in function.blocks {
            for (offset, instruction) in block.instructions.enumerated() {
                let borrowedOperands = instruction.operandRegisters.filter(
                    { facts.sourceAddressByCell[$0] != nil }
                )
                guard !borrowedOperands.isEmpty else { continue }
                let permitted: Bool = switch instruction {
                case .copyValue, .moveValue, .destroyValue,
                     .projectMutableCell, .loadMutableCell,
                     .storeMutableCell:
                    true
                case let .makeClosure(_, _, captures, lifetime):
                    lifetime == .lexical
                        && borrowedOperands.allSatisfy(captures.contains)
                default:
                    false
                }
                guard permitted else {
                    throw Verification.Error.invalidInstruction(
                        function: function.id,
                        block: block.id,
                        offset: offset,
                        reason: "a borrowed mutable cell may only enter a lexical closure"
                    )
                }
            }
        }
    }

    private func buildPredecessors(
        function: Bytecode.Function,
        blocks: [Bytecode.BlockID: Bytecode.Block]
    ) throws -> [Bytecode.BlockID: Set<Bytecode.BlockID>] {
        var result = Dictionary(uniqueKeysWithValues: blocks.keys.map { ($0, Set<Bytecode.BlockID>()) })
        for block in function.blocks {
            guard let terminator = block.instructions.last else { continue }
            for target in successors(of: terminator) {
                guard blocks[target] != nil else {
                    throw Verification.Error.invalidBlock(
                        function: function.id,
                        block: block.id,
                        reason: "branch targets missing block \(target)"
                    )
                }
                result[target, default: []].insert(block.id)
            }
        }
        return result
    }

    private func successors(of instruction: Bytecode.Instruction) -> [Bytecode.BlockID] {
        instruction.successorBlocks
    }

    private func computeReachable(
        entry: Bytecode.BlockID,
        predecessors: [Bytecode.BlockID: Set<Bytecode.BlockID>]
    ) -> Set<Bytecode.BlockID> {
        var successors: [Bytecode.BlockID: Set<Bytecode.BlockID>] = [:]
        for (block, values) in predecessors {
            for predecessor in values { successors[predecessor, default: []].insert(block) }
        }
        var reached: Set<Bytecode.BlockID> = [entry]
        var worklist = [entry]
        while let block = worklist.popLast() {
            for successor in successors[block, default: []] where reached.insert(successor).inserted {
                worklist.append(successor)
            }
        }
        return reached
    }

    private func computeDominators(
        entry: Bytecode.BlockID,
        blocks: Set<Bytecode.BlockID>,
        predecessors: [Bytecode.BlockID: Set<Bytecode.BlockID>]
    ) -> [Bytecode.BlockID: Set<Bytecode.BlockID>] {
        var dominators = Dictionary(uniqueKeysWithValues: blocks.map { ($0, $0 == entry ? Set([$0]) : blocks) })
        var changed = true
        while changed {
            changed = false
            for block in blocks where block != entry {
                let incoming = predecessors[block, default: []]
                var next = incoming.compactMap { dominators[$0] }.reduce(blocks) { $0.intersection($1) }
                next.insert(block)
                if next != dominators[block] {
                    dominators[block] = next
                    changed = true
                }
            }
        }
        return dominators
    }

    private func verifyInstructionTypes(
        _ instruction: Bytecode.Instruction,
        function: Bytecode.Function,
        block: Bytecode.Block,
        offset: Int,
        functions: [Bytecode.FunctionID: Bytecode.Function],
        blocks: [Bytecode.BlockID: Bytecode.Block],
        shell: Verification.ShellInterface,
        declaredImports: [Core.NativeImportID: Bytecode.ImportRequirement],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        capabilities: Set<Core.Capability>,
        effectiveLimits: Core.ResourceLimits
    ) throws {
        func type(_ register: Bytecode.Register) -> Bytecode.ValueType { function.type(of: register)! }
        func fail(_ reason: String) -> Verification.Error {
            .invalidInstruction(function: function.id, block: block.id, offset: offset, reason: reason)
        }
        func parameterTypes(
            of callee: Bytecode.Function
        ) throws -> [Bytecode.ValueType] {
            try callee.parameterRegisters.map { register in
                guard let type = callee.type(of: register) else {
                    throw fail(
                        "callee \(callee.id) has a parameter register outside its type table"
                    )
                }
                return type
            }
        }
        switch instruction {
        case let .constantInteger(result, bitPattern):
            guard case let .integer(width, _) = type(result) else {
                throw fail("const_int result must be an integer")
            }
            let mask = width == 64 ? UInt64.max : (UInt64(1) << width) - 1
            guard bitPattern & ~mask == 0 else {
                throw fail("integer bit pattern does not fit \(width) bits")
            }
        case let .constantBool(result, _):
            guard type(result) == .bool else { throw fail("const_bool result must be Bool") }
        case let .constantFloat(result, bitPattern):
            guard case let .float(width) = type(result) else {
                throw fail("const_float result must be a float")
            }
            if width == 32, bitPattern > UInt64(UInt32.max) {
                throw fail("floating bit pattern does not fit binary32")
            }
        case let .constantString(result, value):
            guard capabilities.contains(.stringsV1) else {
                throw fail("const_string requires \(Core.Capability.stringsV1)")
            }
            guard type(result) == .string else { throw fail("const_string result must be String") }
            guard UInt64(value.utf8.count) <= effectiveLimits.maxVMHeapBytes else {
                throw fail("string literal exceeds VM heap quota")
            }
        case let .copyValue(result, source):
            guard type(result) == type(source) else { throw fail("copy source and result types differ") }
            guard isCopyable(type(source), shell: shell) else {
                throw fail("copy_value requires a copyable type")
            }
        case let .convertClosure(result, source):
            guard case let .closure(actual) = type(source),
                  case let .closure(restricted) = type(result),
                  restricted.isMainActorRestriction(of: actual),
                  isCopyable(type(source), shell: shell)
            else {
                throw fail(
                    "convert_closure requires an ABI-identical MainActor restriction"
                )
            }
        case let .moveValue(result, source):
            guard type(result) == type(source) else { throw fail("copy/move source and result types differ") }
            if case .address = type(source) {
                throw fail("address values cannot be moved")
            }
        case let .destroyValue(register):
            if case .address = type(register) {
                throw fail("address values are ended with end_access, not destroy_value")
            }
        case let .makeTuple(result, elements):
            guard case let .tuple(expected) = type(result),
                  expected == elements.map(type)
            else {
                throw fail("make_tuple elements do not match the result tuple type")
            }
        case let .unpackTuple(results, tuple):
            guard case let .tuple(elements) = type(tuple),
                  elements == results.map(type)
            else {
                throw fail("unpack_tuple results do not match the tuple element types")
            }
        case let .makeStruct(result, fields):
            guard capabilities.contains(.localNominalsV1),
                  case let .local(key) = type(result),
                  let definition = localTypes[key],
                  case let .structure(expectedFields) = definition.kind,
                  expectedFields.map(\.type) == fields.map(type)
            else {
                throw fail("make_struct fields do not match the local struct definition")
            }
        case let .structExtract(result, structure, fieldIndex):
            guard capabilities.contains(.localNominalsV1),
                  case let .local(key) = type(structure),
                  let definition = localTypes[key],
                  case let .structure(fields) = definition.kind,
                  let index = Int(exactly: fieldIndex),
                  fields.indices.contains(index),
                  type(result) == fields[index].type
            else {
                throw fail("struct_extract field does not match the local struct definition")
            }
        case let .makeEnum(result, caseIndex, payload):
            guard capabilities.contains(.localNominalsV1),
                  case let .local(key) = type(result),
                  let definition = localTypes[key],
                  case let .enumeration(cases) = definition.kind,
                  let index = Int(exactly: caseIndex),
                  cases.indices.contains(index)
            else {
                throw fail("make_enum references an invalid local enum case")
            }
            guard payload.map(type) == cases[index].payloadType else {
                throw fail("make_enum payload does not match the local enum case")
            }
        case let .switchEnum(enumeration, caseTargets, defaultTarget):
            guard capabilities.contains(.localNominalsV1),
                  case let .local(key) = type(enumeration),
                  let definition = localTypes[key],
                  case let .enumeration(cases) = definition.kind
            else {
                throw fail("switch_enum operand must be a declared local enum")
            }
            guard caseTargets.count <= cases.count else {
                throw fail("switch_enum contains more targets than enum cases")
            }
            let indices = caseTargets.map(\.caseIndex)
            guard Set(indices).count == indices.count else {
                throw fail("switch_enum contains duplicate case indices")
            }
            for item in caseTargets {
                guard let index = Int(exactly: item.caseIndex),
                      cases.indices.contains(index),
                      let target = blocks[item.target]
                else {
                    throw fail("switch_enum references an invalid case or target")
                }
                if let payload = cases[index].payloadType {
                    guard target.parameters.count == 1,
                          target.parameters.first.map(type) == payload
                    else {
                        throw fail("switch_enum payload target has the wrong parameter")
                    }
                } else if !target.parameters.isEmpty {
                    throw fail("switch_enum no-payload target must not accept parameters")
                }
            }
            if let defaultTarget {
                guard caseTargets.count < cases.count,
                      let target = blocks[defaultTarget],
                      target.parameters.isEmpty
                else {
                    throw fail("switch_enum default must cover omitted cases without a payload")
                }
            } else {
                guard Set(indices) == Set(cases.indices.map(UInt32.init)) else {
                    throw fail("switch_enum without a default must be exhaustive")
                }
            }
        case let .makeError(result, payload):
            guard capabilities.contains(.structuredErrorsV1),
                  type(result) == .error,
                  case let .local(key) = type(payload),
                  localTypes[key]?.conformsToError == true
            else {
                throw fail("make_error requires a local Error-conforming payload")
            }
        case let .castError(result, error, expectedType):
            guard capabilities.contains(.structuredErrorsV1),
                  type(error) == .error,
                  type(result) == .optional(.local(expectedType)),
                  localTypes[expectedType]?.conformsToError == true
            else {
                throw fail("cast_error requires Error and Optional<local Error> types")
            }
        case let .eraseToAny(result, value, dynamicType):
            guard capabilities.contains(.anyValuesV1) else {
                throw fail("erase_to_any requires \(Core.Capability.anyValuesV1)")
            }
            guard type(result) == .any,
                  dynamicType.isAnyPayloadOrExistentialV1,
                  dynamicType.storageType == type(value)
            else {
                throw fail(
                    "erase_to_any dynamic type must match a supported VM value and Any result"
                )
            }
        case let .checkedCastAny(result, value, targetType):
            guard capabilities.contains(.anyValuesV1) else {
                throw fail("checked_cast_any requires \(Core.Capability.anyValuesV1)")
            }
            guard type(value) == .any,
                  case let .optional(target) = type(result),
                  targetType.isAnyCastTargetV1,
                  targetType.storageType == target
            else {
                throw fail(
                    "checked_cast_any requires Any and a matching Optional<dynamic target>"
                )
            }
        case let .forceCastAny(result, value, targetType):
            guard capabilities.contains(.anyValuesV1) else {
                throw fail("force_cast_any requires \(Core.Capability.anyValuesV1)")
            }
            guard type(value) == .any,
                  targetType.isAnyCastTargetV1,
                  targetType.storageType == type(result)
            else {
                throw fail(
                    "force_cast_any requires Any and a matching dynamic target"
                )
            }
        case let .makeOptionalSome(result, value):
            guard case let .optional(wrapped) = type(result), wrapped == type(value) else {
                throw fail("optional_some payload does not match the Optional type")
            }
        case let .makeOptionalNone(result):
            guard case .optional = type(result) else {
                throw fail("optional_none result must be Optional")
            }
        case let .optionalIsSome(result, optional):
            guard type(result) == .bool, case .optional = type(optional) else {
                throw fail("optional_is_some needs an Optional operand and Bool result")
            }
        case let .unwrapOptional(result, optional):
            guard case let .optional(wrapped) = type(optional), wrapped == type(result) else {
                throw fail("optional_unwrap result does not match the wrapped type")
            }
        case let .switchOptional(optional, someTarget, noneTarget):
            guard case let .optional(wrapped) = type(optional) else {
                throw fail("switch_optional operand must be Optional")
            }
            guard let someBlock = blocks[someTarget],
                  someBlock.parameters.count == 1,
                  someBlock.parameters.first.map(type) == wrapped
            else {
                throw fail("switch_optional some target must accept the wrapped value")
            }
            guard let noneBlock = blocks[noneTarget], noneBlock.parameters.isEmpty else {
                throw fail("switch_optional none target must not accept arguments")
            }
        case let .storeStack(slot, source, _):
            guard let slotType = function.type(of: slot), slotType == type(source) else {
                throw fail("store_stack source does not match a declared stack slot")
            }
        case let .loadStack(result, slot, mode):
            guard let slotType = function.type(of: slot), slotType == type(result) else {
                throw fail("load_stack result does not match a declared stack slot")
            }
            if mode == .copy, !isCopyable(slotType, shell: shell) {
                throw fail("load_stack.copy requires a copyable slot type")
            }
        case let .destroyStack(slot),
             let .destroyStackIfInitialized(slot):
            guard function.type(of: slot) != nil else {
                throw fail("stack destroy references an unknown slot")
            }
        case let .stackAddress(result, slot):
            guard capabilities.contains(.addressValuesV1),
                  let slotType = function.type(of: slot),
                  type(result) == .address(slotType)
            else {
                throw fail("stack_address result must address its declared stack slot")
            }
        case let .projectAggregateAddress(result, base, fieldIndex):
            let fieldType: Bytecode.ValueType? = if let index = Int(
                exactly: fieldIndex
            ) {
                switch type(base) {
                case let .address(.tuple(elements))
                    where elements.indices.contains(index):
                    elements[index]
                case let .address(.local(key)):
                    if let definition = localTypes[key],
                       case let .structure(fields) = definition.kind,
                       fields.indices.contains(index) {
                        fields[index].type
                    } else {
                        nil
                    }
                default:
                    nil
                }
            } else {
                nil
            }
            guard capabilities.contains(.addressValuesV1),
                  let fieldType,
                  type(result) == .address(fieldType)
            else {
                throw fail(
                    "project_aggregate_address must reference a valid aggregate field"
                )
            }
        case let .makeMutableCell(result, initialValue):
            guard capabilities.contains(.mutableCapturesV1),
                  case let .mutableCell(pointee) = type(result),
                  initialValue.map(type) == nil
                    || initialValue.map(type) == pointee,
                  isCopyable(pointee, shell: shell)
            else {
                throw fail(
                    "make_mutable_cell requires a copyable matching pointee"
                )
            }
        case let .borrowMutableCell(result, address):
            guard capabilities.contains(.mutableCapturesV1),
                  capabilities.contains(.addressValuesV1),
                  case let .address(pointee) = type(address),
                  type(result) == .mutableCell(pointee),
                  isCopyable(pointee, shell: shell)
            else {
                throw fail(
                    "borrow_mutable_cell requires a matching active address"
                )
            }
        case let .projectMutableCell(result, cell, fieldIndex):
            guard capabilities.contains(.mutableCapturesV1),
                  case let .mutableCell(aggregate) = type(cell),
                  let fieldType = mutableCellFieldType(
                    aggregate,
                    fieldIndex: fieldIndex,
                    localTypes: localTypes
                  ),
                  type(result) == .mutableCell(fieldType)
            else {
                throw fail(
                    "project_mutable_cell must reference a valid aggregate field"
                )
            }
        case let .loadMutableCell(result, cell):
            guard capabilities.contains(.mutableCapturesV1),
                  case let .mutableCell(pointee) = type(cell),
                  type(result) == pointee,
                  isCopyable(pointee, shell: shell)
            else {
                throw fail(
                    "load_mutable_cell result must match a copyable pointee"
                )
            }
        case let .storeMutableCell(cell, source, _):
            guard capabilities.contains(.mutableCapturesV1),
                  case let .mutableCell(pointee) = type(cell),
                  type(source) == pointee,
                  isCopyable(pointee, shell: shell)
            else {
                throw fail(
                    "store_mutable_cell source must match a copyable pointee"
                )
            }
        case let .makeNonOwningReference(result, initialValue):
            guard capabilities.contains(.nonOwningReferencesV1),
                  case let .nonOwningReference(kind, pointee) = type(result),
                  isValidNonOwningReference(
                    kind: kind,
                    pointee: pointee,
                    shell: shell,
                    localTypes: localTypes
                  ),
                  initialValue.map(type) == nil
                    || initialValue.map(type) == pointee
            else {
                throw fail(
                    "make_nonowning_reference requires a matching class reference pointee"
                )
            }
        case let .loadNonOwningReference(result, reference, _):
            guard capabilities.contains(.nonOwningReferencesV1),
                  case let .nonOwningReference(kind, pointee) = type(reference),
                  isValidNonOwningReference(
                    kind: kind,
                    pointee: pointee,
                    shell: shell,
                    localTypes: localTypes
                  ),
                  type(result) == pointee
            else {
                throw fail(
                    "load_nonowning_reference result must match its strong pointee"
                )
            }
        case let .storeNonOwningReference(reference, source, _):
            guard capabilities.contains(.nonOwningReferencesV1),
                  case let .nonOwningReference(kind, pointee) = type(reference),
                  isValidNonOwningReference(
                    kind: kind,
                    pointee: pointee,
                    shell: shell,
                    localTypes: localTypes
                  ),
                  type(source) == pointee
            else {
                throw fail(
                    "store_nonowning_reference source must match its strong pointee"
                )
            }
        case let .allocateObject(result):
            guard capabilities.contains(.localClassesV1),
                  case let .local(key) = type(result),
                  let definition = localTypes[key],
                  case .class = definition.kind
            else {
                throw fail("allocate_object result must be a declared local class")
            }
        case let .projectObjectAddress(result, object, fieldIndex):
            guard capabilities.contains(.localClassesV1),
                  capabilities.contains(.addressValuesV1),
                  case let .local(key) = type(object),
                  let definition = localTypes[key],
                  case let .class(fields, _, _) = definition.kind,
                  let index = Int(exactly: fieldIndex),
                  fields.indices.contains(index),
                  type(result) == .address(fields[index].type)
            else {
                throw fail("project_object_address must reference a valid local class field")
            }
        case let .projectHostedObject(result, object):
            guard capabilities.contains(.hostedObjectiveCClassesV1),
                  case let .local(key) = type(object),
                  let definition = localTypes[key],
                  case let .class(_, hostedSuperclass, _) = definition.kind,
                  let hostedSuperclass,
                  type(result) == .native(hostedSuperclass.typeID)
            else {
                throw fail("project_hosted_object must produce the frozen native superclass")
            }
        case let .hostedSuperApply(object, methodIndex, arguments):
            guard capabilities.contains(.hostedObjectiveCClassesV1),
                  case let .local(key) = type(object),
                  let definition = localTypes[key],
                  case let .class(_, hostedSuperclass, methods) = definition.kind,
                  hostedSuperclass != nil,
                  let index = Int(exactly: methodIndex),
                  methods.indices.contains(index),
                  methods[index].functionID == function.id
            else {
                throw fail("hosted_super_apply must target the current hosted method")
            }
            let expectedArguments: [Bytecode.ValueType] = switch methods[index].abi {
            case .voidNoArguments: []
            case .voidBool: [.bool]
            }
            guard arguments.count == expectedArguments.count,
                  zip(arguments, expectedArguments).allSatisfy({ type($0.0) == $0.1 })
            else {
                throw fail("hosted_super_apply arguments do not match the callback ABI")
            }
        case let .beginAccess(result, address, _):
            guard capabilities.contains(.addressValuesV1),
                  case .address = type(address),
                  type(result) == type(address)
            else {
                throw fail("begin_access requires matching address operands")
            }
        case let .endAccess(address):
            guard capabilities.contains(.addressValuesV1), case .address = type(address) else {
                throw fail("end_access requires an address")
            }
        case let .loadAddress(result, address, mode):
            guard capabilities.contains(.addressValuesV1),
                  case let .address(pointee) = type(address),
                  type(result) == pointee
            else {
                throw fail("load_address result must match its address pointee")
            }
            guard mode != .copy || isCopyable(type(result), shell: shell) else {
                throw fail("load_address.copy requires a copyable pointee")
            }
        case let .storeAddress(address, source, _):
            guard capabilities.contains(.addressValuesV1),
                  case let .address(pointee) = type(address),
                  type(source) == pointee
            else {
                throw fail("store_address source must match its address pointee")
            }
            // All StackStoreMode cases are memory-safe after lifecycle
            // verification; replace is reserved for conditional initialization.
        case let .destroyAddress(address),
             let .destroyAddressIfInitialized(address):
            guard capabilities.contains(.addressValuesV1),
                  case .address = type(address)
            else {
                throw fail("destroy_address requires an address")
            }
        case let .checkedBinary(result, overflow, operation, lhs, rhs):
            guard type(result) == type(lhs), type(lhs) == type(rhs), case .integer = type(lhs) else {
                throw fail("checked binary operands and result must use one integer type")
            }
            guard type(overflow) == .bool else { throw fail("checked binary overflow result must be Bool") }
            if operation == .shiftLeft || operation == .shiftRight {
                guard case .integer = type(rhs) else { throw fail("shift amount must be an integer") }
            }
        case let .floatingBinary(result, _, lhs, rhs):
            guard type(result) == type(lhs),
                  type(lhs) == type(rhs),
                  case .float = type(lhs)
            else {
                throw fail("floating binary operands and result must use one float type")
            }
        case let .floatingUnary(result, _, operand):
            guard type(result) == type(operand), case .float = type(operand) else {
                throw fail("floating unary operand and result must use one float type")
            }
        case let .floatingPredicate(result, _, operand):
            guard type(result) == .bool, case .float = type(operand) else {
                throw fail("floating predicate requires a float operand and Bool result")
            }
        case let .floatingBinaryPredicate(result, _, lhs, rhs):
            guard type(result) == .bool,
                  type(lhs) == type(rhs),
                  case .float = type(lhs)
            else {
                throw fail(
                    "floating binary predicate requires one float type and Bool result"
                )
            }
        case let .floatingTernary(
            result, _, multiplicand, multiplier, addend
        ):
            guard type(result) == type(multiplicand),
                  type(multiplicand) == type(multiplier),
                  type(multiplier) == type(addend),
                  case .float = type(result)
            else {
                throw fail("floating ternary operands and result must use one float type")
            }
        case let .floatingIntegerProperty(result, operation, operand):
            guard case let .float(width) = type(operand) else {
                throw fail("floating integer property requires a float operand")
            }
            let expected: Bytecode.ValueType = switch operation {
            case .exponent, .significandWidth: .int64
            case .exponentBitPattern: .integer(bitWidth: 64, signed: false)
            case .significandBitPattern:
                .integer(bitWidth: width, signed: false)
            }
            guard type(result) == expected else {
                throw fail(
                    "floating integer property has an operation-specific result type"
                )
            }
        case let .integerUnary(result, operation, operand):
            guard case let .integer(width, signed) = type(operand) else {
                throw fail("integer unary operation requires an integer operand")
            }
            switch operation {
            case .magnitude:
                guard type(result) == .integer(bitWidth: width, signed: false) else {
                    throw fail("integer magnitude must produce the same-width unsigned type")
                }
            case .nonzeroBitCount, .leadingZeroBitCount,
                 .trailingZeroBitCount, .byteSwapped, .bigEndian,
                 .littleEndian:
                guard type(result) == type(operand) else {
                    throw fail("integer bit operation must preserve its operand type")
                }
            case .signum:
                guard signed, type(result) == type(operand) else {
                    throw fail("integer signum requires one signed integer type")
                }
            }
        case let .integerFullWidthMultiply(high, low, lhs, rhs):
            guard case let .integer(width, _) = type(lhs),
                  type(rhs) == type(lhs),
                  type(high) == type(lhs),
                  type(low) == .integer(bitWidth: width, signed: false)
            else {
                throw fail(
                    "full-width multiply requires matching operands, high result, and unsigned low result"
                )
            }
        case let .integerFullWidthDivide(
            quotient, remainder, dividendHigh, dividendLow, divisor
        ):
            guard case let .integer(width, _) = type(divisor),
                  type(dividendHigh) == type(divisor),
                  type(dividendLow)
                    == .integer(bitWidth: width, signed: false),
                  type(quotient) == type(divisor),
                  type(remainder) == type(divisor)
            else {
                throw fail(
                    "full-width divide requires a same-type high/divisor/result and unsigned low word"
                )
            }
        case let .scalarBitCast(result, operand):
            switch (type(operand), type(result)) {
            case let (.integer(sourceWidth, _), .float(targetWidth)),
                 let (.float(sourceWidth), .integer(targetWidth, _)):
                guard sourceWidth == targetWidth else {
                    throw fail("scalar bitcast must preserve its storage width")
                }
            default:
                throw fail("scalar bitcast requires one integer and one float")
            }
        case let .integerConvert(result, operation, value):
            guard case let .integer(sourceWidth, sourceSigned) = type(value),
                  case let .integer(targetWidth, _) = type(result)
            else {
                throw fail("integer_convert requires integer input and result")
            }
            switch operation {
            case .truncate:
                guard targetWidth < sourceWidth else {
                    throw fail("integer truncation requires a narrower result")
                }
            case .signExtend:
                guard sourceSigned, targetWidth > sourceWidth else {
                    throw fail("sign extension requires a signed input and wider result")
                }
            case .zeroExtend:
                guard !sourceSigned, targetWidth > sourceWidth else {
                    throw fail("zero extension requires an unsigned input and wider result")
                }
            case .reinterpret:
                guard targetWidth == sourceWidth else {
                    throw fail("integer reinterpretation must preserve bit width")
                }
            case .clamp:
                break
            }
        case let .floatingConvert(result, operation, value):
            guard case let .float(targetWidth) = type(result) else {
                throw fail("floating_convert result must be Float32 or Float64")
            }
            switch operation {
            case .truncate:
                guard type(value) == .float(bitWidth: 64), targetWidth == 32 else {
                    throw fail("floating truncation requires Float64 to Float32")
                }
            case .extend:
                guard type(value) == .float(bitWidth: 32), targetWidth == 64 else {
                    throw fail("floating extension requires Float32 to Float64")
                }
            case .signedIntegerToFloat:
                guard case .integer(_, signed: true) = type(value) else {
                    throw fail("signed integer-to-float conversion requires a signed integer")
                }
            case .unsignedIntegerToFloat:
                guard case .integer(_, signed: false) = type(value) else {
                    throw fail("unsigned integer-to-float conversion requires an unsigned integer")
                }
            }
        case let .booleanBinary(result, _, lhs, rhs):
            guard type(result) == .bool, type(lhs) == .bool, type(rhs) == .bool else {
                throw fail("boolean binary operands and result must be Bool")
            }
        case let .select(result, condition, trueValue, falseValue):
            guard type(condition) == .bool,
                  type(result) == type(trueValue),
                  type(trueValue) == type(falseValue)
            else {
                throw fail("select requires a Bool condition and matching value types")
            }
            guard isCopyable(type(result), shell: shell) else {
                throw fail("select requires a copyable value type")
            }
        case let .stringConcat(result, lhs, rhs):
            guard capabilities.contains(.stringsV1) else {
                throw fail("String concatenation requires \(Core.Capability.stringsV1)")
            }
            guard type(result) == .string, type(lhs) == .string, type(rhs) == .string else {
                throw fail("string_concat operands and result must be String")
            }
        case let .stringCount(result, string):
            guard capabilities.contains(.stringsV1) else {
                throw fail("String.count requires \(Core.Capability.stringsV1)")
            }
            guard type(result) == .int64, type(string) == .string else {
                throw fail("string_count needs a String operand and Int64 result")
            }
        case let .stringIsEmpty(result, string):
            guard capabilities.contains(.stringsV1) else {
                throw fail("String.isEmpty requires \(Core.Capability.stringsV1)")
            }
            guard type(result) == .bool, type(string) == .string else {
                throw fail("string_is_empty needs a String operand and Bool result")
            }
        case let .stringPredicate(result, _, string, pattern):
            guard capabilities.contains(.stringsV1) else {
                throw fail("String predicates require \(Core.Capability.stringsV1)")
            }
            guard type(result) == .bool,
                  type(string) == .string,
                  type(pattern) == .string
            else {
                throw fail("String predicates need two String operands and a Bool result")
            }
        case let .stringTransform(result, _, string):
            guard capabilities.contains(.stringsV1) else {
                throw fail("String transforms require \(Core.Capability.stringsV1)")
            }
            guard type(result) == .string, type(string) == .string else {
                throw fail("string transform operand and result must both be String")
            }
        case let .stringCharacters(result, string):
            guard capabilities.contains(.stringsV1),
                  capabilities.contains(.collectionsV1)
            else {
                throw fail(
                    "String character materialization requires String and Collection capabilities"
                )
            }
            guard type(result) == .array(.string), type(string) == .string else {
                throw fail(
                    "string_characters requires a String and produces Array<String>"
                )
            }
        case let .stringJoin(result, elements, separator, elementKind):
            guard capabilities.contains(.stringsV1),
                  capabilities.contains(.collectionsV1)
            else {
                throw fail(
                    "String joining requires String and Collection capabilities"
                )
            }
            guard type(result) == .string,
                  type(elements) == .array(.string),
                  separator.map({ type($0) == .string }) ?? true
            else {
                throw fail(
                    "string_join requires Array<String>, an optional String separator, and a String result"
                )
            }
            if elementKind == .character, separator != nil {
                throw fail("character string_join cannot carry a separator")
            }
        case let .scalarFromString(result, string, radix):
            guard capabilities.contains(.stringsV1) else {
                throw fail("Scalar text parsing requires \(Core.Capability.stringsV1)")
            }
            guard type(string) == .string,
                  case let .optional(target) = type(result)
            else {
                throw fail(
                    "scalar_from_string requires a String and an Optional scalar result"
                )
            }
            switch target {
            case .integer:
                guard radix.map({ type($0) == .int64 }) ?? true else {
                    throw fail("integer scalar_from_string radix must be Int64")
                }
            case .bool, .float:
                guard radix == nil else {
                    throw fail(
                        "Bool and floating scalar_from_string cannot carry a radix"
                    )
                }
            default:
                throw fail(
                    "scalar_from_string supports only Bool, integer, and floating-point targets"
                )
            }
        case let .integerToString(result, value, radix, uppercase):
            guard capabilities.contains(.stringsV1) else {
                throw fail("Integer formatting requires \(Core.Capability.stringsV1)")
            }
            guard type(result) == .string,
                  case .integer = type(value),
                  type(radix) == .int64,
                  type(uppercase) == .bool
            else {
                throw fail(
                    "integer_to_string requires an integer, Int64 radix, Bool case, and String result"
                )
            }
        case let .stringify(result, value):
            guard capabilities.contains(.stringsV1) else {
                throw fail("String interpolation requires \(Core.Capability.stringsV1)")
            }
            guard type(result) == .string else {
                throw fail("stringify result must be String")
            }
            switch type(value) {
            case .bool, .integer, .float, .string:
                break
            default:
                throw fail(
                    "stringify supports only Bool, integer, floating-point, and String values"
                )
            }
        case let .makeArray(result, elements):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("make_array requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(elementType) = type(result),
                  elements.allSatisfy({ type($0) == elementType })
            else {
                throw fail("make_array elements must match its Array element type")
            }
        case let .arrayCount(result, array):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array.count requires \(Core.Capability.collectionsV1)")
            }
            guard type(result) == .int64, case .array = type(array) else {
                throw fail("array_count needs an Array operand and Int64 result")
            }
        case let .arrayIsEmpty(result, array):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array.isEmpty requires \(Core.Capability.collectionsV1)")
            }
            guard type(result) == .bool, case .array = type(array) else {
                throw fail("array_is_empty needs an Array operand and Bool result")
            }
        case let .arrayIndexBase(result, array):
            guard capabilities.contains(.collectionsV1) else {
                throw fail(
                    "Array-backed index identity requires \(Core.Capability.collectionsV1)"
                )
            }
            guard type(result) == .int64, case .array = type(array) else {
                throw fail(
                    "array_index_base needs an Array-backed operand and Int64 result"
                )
            }
        case let .arrayRebase(result, array, indexBase):
            guard capabilities.contains(.collectionsV1) else {
                throw fail(
                    "Array-backed index identity requires \(Core.Capability.collectionsV1)"
                )
            }
            guard case .array = type(array),
                  type(result) == type(array),
                  type(indexBase) == .int64
            else {
                throw fail(
                    "array_rebase requires matching Arrays and an Int64 base"
                )
            }
        case let .arrayGet(result, array, index):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array subscript requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(index) == .int64,
                  type(result) == element
            else {
                throw fail("array_get types do not match Array.Element and Int index")
            }
            guard isCopyable(element, shell: shell) else {
                throw fail("array_get requires a copyable element type")
            }
        case let .arrayBoundary(result, _, array):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array boundary lookup requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(result) == .optional(element)
            else {
                throw fail("array boundary result must be Optional<Array.Element>")
            }
            guard isCopyable(element, shell: shell) else {
                throw fail("array boundary lookup requires a copyable element type")
            }
        case let .arraySearch(result, _, array, value):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array index search requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(value) == element,
                  type(result) == .optional(.int64),
                  element.isVMEquatable
            else {
                throw fail(
                    "array_search requires a matching VM-Equatable element and Optional<Int> result"
                )
            }
        case let .arrayAdapter(result, operation, array):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array adapters require \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  isCopyable(element, shell: shell)
            else {
                throw fail("array_adapter requires a copyable Array element")
            }
            let expected: Bytecode.ValueType = switch operation {
            case .reversed:
                .array(element)
            case .enumerated:
                .array(.tuple([.int64, element]))
            }
            guard type(result) == expected else {
                throw fail("array_adapter result does not match its operation")
            }
        case let .arrayRepeat(result, value, count):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array repetition requires \(Core.Capability.collectionsV1)")
            }
            guard type(count) == .int64,
                  type(result) == .array(type(value)),
                  isCopyable(type(value), shell: shell)
            else {
                throw fail("array_repeat requires a copyable value and Int count")
            }
        case let .arraySubsequence(result, _, array, bound):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array subsequences require \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(result) == type(array),
                  type(bound) == .int64,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_subsequence requires matching Arrays and an Int bound"
                )
            }
        case let .arrayRangeSlice(
            result,
            array,
            lowerBound,
            upperBound
        ):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array slices require \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(result) == type(array),
                  type(lowerBound) == .int64,
                  type(upperBound) == .int64,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_slice requires matching Arrays and Int bounds"
                )
            }
        case let .arrayZip(result, lhs, rhs):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("zip requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(lhsElement) = type(lhs),
                  case let .array(rhsElement) = type(rhs),
                  type(result) == .array(.tuple([lhsElement, rhsElement])),
                  isCopyable(lhsElement, shell: shell),
                  isCopyable(rhsElement, shell: shell)
            else {
                throw fail("array_zip result must contain both Array elements")
            }
        case let .arrayJoined(result, arrays, separator):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("joined requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(.array(element)) = type(arrays),
                  type(result) == .array(element),
                  separator.map({ type($0) == .array(element) }) ?? true,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_joined requires nested Arrays and a matching separator"
                )
            }
        case let .arrayReplaceSubrange(
            result,
            array,
            lowerBound,
            upperBound,
            replacement
        ):
            guard capabilities.contains(.collectionsV1) else {
                throw fail(
                    "Array range replacement requires \(Core.Capability.collectionsV1)"
                )
            }
            guard case let .array(element) = type(array),
                  type(result) == type(array),
                  type(replacement) == type(array),
                  type(lowerBound) == .int64,
                  type(upperBound) == .int64,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_replace requires matching Arrays and Int bounds"
                )
            }
        case let .arraySwap(result, array, lhsIndex, rhsIndex):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array swap requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(result) == type(array),
                  type(lhsIndex) == .int64,
                  type(rhsIndex) == .int64,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_swap requires a copyable Array and two Int indices"
                )
            }
        case let .arrayAppend(result, array, value):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array.append requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(result) == .array(element),
                  type(value) == element
            else {
                throw fail("array_append value and result must match Array.Element")
            }
            guard isCopyable(element, shell: shell) else {
                throw fail("array_append requires a copyable element type")
            }
        case let .makeArrayBuilder(result):
            guard capabilities.contains(.collectionsV1) else {
                throw fail(
                    "make_array_builder requires \(Core.Capability.collectionsV1)"
                )
            }
            guard case let .arrayState(.builder, element) = type(result),
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "make_array_builder requires a copyable element type"
                )
            }
        case let .arrayBuilderAppend(builder, value):
            guard capabilities.contains(.collectionsV1),
                  case let .arrayState(.builder, element) = type(builder),
                  type(value) == element,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_builder_append requires a matching copyable element"
                )
            }
        case let .arrayBuilderAppendContents(builder, array):
            guard capabilities.contains(.collectionsV1),
                  case let .arrayState(.builder, element) = type(builder),
                  type(array) == .array(element),
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_builder_append_contents requires a matching copyable Array"
                )
            }
        case let .finishArrayBuilder(result, builder):
            guard capabilities.contains(.collectionsV1),
                  case let .arrayState(.builder, element) = type(builder),
                  type(result) == .array(element),
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "finish_array_builder must produce its matching Array"
                )
            }
        case let .makeArrayMutationState(result, array):
            guard capabilities.contains(.collectionsV1),
                  case let .arrayState(.mutation, element) = type(result),
                  type(array) == .array(element),
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "make_array_mutation_state requires a matching copyable Array"
                )
            }
        case let .arrayMutationGet(result, state, index):
            guard capabilities.contains(.collectionsV1),
                  case let .arrayState(.mutation, element) = type(state),
                  type(result) == element,
                  type(index) == .int64,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_mutation_get requires its matching state, element, and Int index"
                )
            }
        case let .arrayMutationSwap(state, lhsIndex, rhsIndex):
            guard capabilities.contains(.collectionsV1),
                  case let .arrayState(.mutation, element) = type(state),
                  type(lhsIndex) == .int64,
                  type(rhsIndex) == .int64,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_mutation_swap requires a copyable mutation state and Int indices"
                )
            }
        case let .finishArrayMutation(result, state):
            guard capabilities.contains(.collectionsV1),
                  case let .arrayState(.mutation, element) = type(state),
                  type(result) == .array(element),
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "finish_array_mutation must produce its matching Array"
                )
            }
        case let .makeDictionaryBuilder(result, initialValue):
            guard capabilities.contains(.collectionsV1),
                  case let .dictionaryState(key, value) = type(result),
                  key.isVMHashable,
                  isCopyable(key, shell: shell),
                  isCopyable(value, shell: shell),
                  initialValue.map({
                      type($0) == .dictionary(key: key, value: value)
                  }) ?? true
            else {
                throw fail(
                    "make_dictionary_builder requires matching copyable Dictionary types"
                )
            }
        case let .dictionaryBuilderGet(result, builder, key):
            guard capabilities.contains(.collectionsV1),
                  case let .dictionaryState(keyType, valueType) = type(builder),
                  type(key) == keyType,
                  type(result) == .optional(valueType),
                  keyType.isVMHashable,
                  isCopyable(valueType, shell: shell)
            else {
                throw fail(
                    "dictionary_builder_get requires matching key and Optional value types"
                )
            }
        case let .dictionaryBuilderSet(builder, key, value):
            guard capabilities.contains(.collectionsV1),
                  case let .dictionaryState(keyType, valueType) = type(builder),
                  type(key) == keyType,
                  type(value) == valueType,
                  keyType.isVMHashable,
                  isCopyable(keyType, shell: shell),
                  isCopyable(valueType, shell: shell)
            else {
                throw fail(
                    "dictionary_builder_set requires matching copyable key/value types"
                )
            }
        case let .dictionaryBuilderAppendArrayElement(builder, key, element):
            guard capabilities.contains(.collectionsV1),
                  case let .dictionaryState(
                    keyType,
                    .array(elementType)
                  ) = type(builder),
                  type(key) == keyType,
                  type(element) == elementType,
                  keyType.isVMHashable,
                  isCopyable(keyType, shell: shell),
                  isCopyable(elementType, shell: shell)
            else {
                throw fail(
                    "dictionary_builder_append_array_element requires matching copyable key/Array element types"
                )
            }
        case let .finishDictionaryBuilder(result, builder):
            guard capabilities.contains(.collectionsV1),
                  case let .dictionaryState(key, value) = type(builder),
                  type(result) == .dictionary(key: key, value: value),
                  key.isVMHashable,
                  isCopyable(key, shell: shell),
                  isCopyable(value, shell: shell)
            else {
                throw fail(
                    "finish_dictionary_builder must produce its matching Dictionary"
                )
            }
        case let .arraySorted(result, array):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array sorting requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(result) == type(array),
                  element.isVMComparable,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_sorted requires a copyable VM-Comparable Array"
                )
            }
        case let .makeArraySortState(result, array):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array sorting requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(result) == .arrayState(
                    kind: .stableSort,
                    element: element
                  ),
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "make_array_sort_state requires a matching copyable Array"
                )
            }
        case let .arraySortNextComparison(result, state):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array sorting requires \(Core.Capability.collectionsV1)")
            }
            guard case let .arrayState(.stableSort, element) = type(state),
                  type(result) == .optional(.tuple([element, element])),
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_sort_next_comparison requires its matching state"
                )
            }
        case let .arraySortAcceptComparison(state, rightPrecedesLeft):
            guard capabilities.contains(.collectionsV1),
                  case .arrayState(.stableSort, _) = type(state),
                  type(rightPrecedesLeft) == .bool
            else {
                throw fail(
                    "array_sort_accept_comparison requires state and Bool"
                )
            }
        case let .finishArraySort(result, state):
            guard capabilities.contains(.collectionsV1),
                  case let .arrayState(.stableSort, element) = type(state),
                  type(result) == .array(element),
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "finish_array_sort must produce its matching Array"
                )
            }
        case let .arraySplitSeparator(
            result,
            array,
            separator,
            maximumSplits,
            omittingEmptySubsequences
        ):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array splitting requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(separator) == element,
                  type(maximumSplits) == .int64,
                  type(omittingEmptySubsequences) == .bool,
                  type(result) == .array(.array(element)),
                  element.isVMEquatable,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_split requires matching VM-Equatable Array, "
                        + "separator, Int maximum, and Bool omission flag"
                )
            }
        case let .makeArraySplitState(
            result,
            array,
            maximumSplits,
            omittingEmptySubsequences
        ):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array splitting requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(result) == .arrayState(kind: .split, element: element),
                  type(maximumSplits) == .int64,
                  type(omittingEmptySubsequences) == .bool,
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "make_array_split_state requires a matching copyable "
                        + "Array, Int maximum, and Bool omission flag"
                )
            }
        case let .arraySplitNextElement(result, state):
            guard capabilities.contains(.collectionsV1),
                  case let .arrayState(.split, element) = type(state),
                  type(result) == .optional(element),
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "array_split_next_element requires its matching split state"
                )
            }
        case let .arraySplitAcceptElement(state, isSeparator):
            guard capabilities.contains(.collectionsV1),
                  case .arrayState(.split, _) = type(state),
                  type(isSeparator) == .bool
            else {
                throw fail(
                    "array_split_accept_element requires split state and Bool"
                )
            }
        case let .finishArraySplit(result, state):
            guard capabilities.contains(.collectionsV1),
                  case let .arrayState(.split, element) = type(state),
                  type(result) == .array(.array(element)),
                  isCopyable(element, shell: shell)
            else {
                throw fail(
                    "finish_array_split must produce its matching nested Array"
                )
            }
        case let .arrayUpdate(result, array, index, value):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array subscript update requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(result) == .array(element),
                  type(index) == .int64,
                  type(value) == element
            else {
                throw fail("array_update types do not match Array.Element and Int index")
            }
            guard isCopyable(element, shell: shell) else {
                throw fail("array_update requires a copyable element type")
            }
        case let .arrayPopLast(elementResult, arrayResult, array):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Array.popLast requires \(Core.Capability.collectionsV1)")
            }
            guard case let .array(element) = type(array),
                  type(arrayResult) == type(array),
                  type(elementResult) == .optional(element)
            else {
                throw fail("array_pop_last results must match Array.Element")
            }
            guard isCopyable(element, shell: shell) else {
                throw fail("array_pop_last requires a copyable element type")
            }
        case let .collectionMaterialize(result, collection):
            guard capabilities.contains(.collectionsV1) else {
                throw fail(
                    "Collection materialization requires \(Core.Capability.collectionsV1)"
                )
            }
            guard let element = type(collection).managedCollectionElement,
                  type(result) == .array(element)
            else {
                throw fail(
                    "collection_materialize requires an Array, Dictionary, or Set and its matching element Array"
                )
            }
            guard isCopyable(element, shell: shell) else {
                throw fail(
                    "collection_materialize requires a copyable element type"
                )
            }
        case let .collectionNext(result, collection, indexSlot, direction):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Collection iteration requires \(Core.Capability.collectionsV1)")
            }
            let element: Bytecode.ValueType
            switch type(collection) {
            case let .array(value):
                element = value
            case let .dictionary(key, value):
                guard direction == .forward else {
                    throw fail("reverse collection iteration requires an Array")
                }
                element = .tuple([key, value])
            case let .set(value):
                guard direction == .forward else {
                    throw fail("reverse collection iteration requires an Array")
                }
                element = value
            default:
                throw fail("collection_next requires an Array, Dictionary, or Set")
            }
            guard type(result) == .optional(element),
                  function.type(of: indexSlot) == .int64
            else {
                throw fail(
                    "collection_next result and Int64 cursor must match Collection.Element"
                )
            }
            guard isCopyable(element, shell: shell) else {
                throw fail("collection_next requires a copyable element type")
            }
        case let .progressionNext(result, cursorSlot, end, stride, _):
            guard capabilities.contains(.collectionsV1) else {
                throw fail(
                    "Progression iteration requires \(Core.Capability.collectionsV1)"
                )
            }
            guard case let .optional(element) = type(result),
                  function.type(of: cursorSlot) == .optional(element),
                  type(end) == element
            else {
                throw fail(
                    "progression_next needs Optional<T> result/cursor and a matching end"
                )
            }
            let expectedStride: Bytecode.ValueType
            switch element {
            case .integer:
                expectedStride = .int64
            case .float:
                expectedStride = element
            default:
                throw fail(
                    "progression_next supports only fixed-width integer and floating elements"
                )
            }
            guard type(stride) == expectedStride else {
                throw fail(
                    "progression_next stride does not match the element's Stride type"
                )
            }
        case let .makeDictionary(result, pairs):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("make_dictionary requires \(Core.Capability.collectionsV1)")
            }
            guard case let .dictionary(key, value) = type(result),
                  type(pairs) == .array(.tuple([key, value])),
                  key.isVMHashable
            else {
                throw fail("make_dictionary needs Array<(Key, Value)> and Dictionary<Key, Value>")
            }
            guard isCopyable(key, shell: shell), isCopyable(value, shell: shell) else {
                throw fail("make_dictionary requires copyable key and value types")
            }
        case let .dictionaryCount(result, dictionary):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Dictionary.count requires \(Core.Capability.collectionsV1)")
            }
            guard type(result) == .int64, case .dictionary = type(dictionary) else {
                throw fail("dictionary_count needs a Dictionary operand and Int64 result")
            }
        case let .dictionaryIsEmpty(result, dictionary):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Dictionary.isEmpty requires \(Core.Capability.collectionsV1)")
            }
            guard type(result) == .bool, case .dictionary = type(dictionary) else {
                throw fail("dictionary_is_empty needs a Dictionary operand and Bool result")
            }
        case let .dictionaryGet(result, dictionary, key):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Dictionary subscript requires \(Core.Capability.collectionsV1)")
            }
            guard case let .dictionary(keyType, valueType) = type(dictionary),
                  type(key) == keyType,
                  type(result) == .optional(valueType)
            else {
                throw fail("dictionary_get key and result must match Dictionary types")
            }
            guard isCopyable(valueType, shell: shell) else {
                throw fail("dictionary_get requires a copyable value type")
            }
        case let .dictionarySet(
            previousValueResult,
            dictionaryResult,
            dictionary,
            key,
            value
        ):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Dictionary update requires \(Core.Capability.collectionsV1)")
            }
            guard case let .dictionary(keyType, valueType) = type(dictionary),
                  type(previousValueResult) == .optional(valueType),
                  type(dictionaryResult) == type(dictionary),
                  type(key) == keyType,
                  type(value) == .optional(valueType)
            else {
                throw fail("dictionary_set operands and results must match Dictionary types")
            }
            guard isCopyable(keyType, shell: shell), isCopyable(valueType, shell: shell) else {
                throw fail("dictionary_set requires copyable key and value types")
            }
        case let .dictionaryProject(result, dictionary, projection):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Dictionary projection requires \(Core.Capability.collectionsV1)")
            }
            guard case let .dictionary(keyType, valueType) = type(dictionary),
                  type(result) == .array(
                    projection == .keys ? keyType : valueType
                  )
            else {
                throw fail("dictionary_project result must match its selected element type")
            }
            let projectedType = projection == .keys ? keyType : valueType
            guard isCopyable(projectedType, shell: shell) else {
                throw fail("dictionary_project requires a copyable projected type")
            }
        case let .makeSet(result, source):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("make_set requires \(Core.Capability.collectionsV1)")
            }
            guard case let .set(element) = type(result),
                  element.isVMHashable,
                  type(source) == .array(element) || type(source) == .set(element)
            else {
                throw fail("make_set needs Array<T> or Set<T> and a matching Set<T> result")
            }
            guard isCopyable(element, shell: shell) else {
                throw fail("make_set requires a copyable element type")
            }
        case let .setCount(result, set):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Set.count requires \(Core.Capability.collectionsV1)")
            }
            guard type(result) == .int64, case .set = type(set) else {
                throw fail("set_count needs a Set operand and Int64 result")
            }
        case let .setIsEmpty(result, set):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Set.isEmpty requires \(Core.Capability.collectionsV1)")
            }
            guard type(result) == .bool, case .set = type(set) else {
                throw fail("set_is_empty needs a Set operand and Bool result")
            }
        case let .setContains(result, set, element):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Set.contains requires \(Core.Capability.collectionsV1)")
            }
            guard case let .set(elementType) = type(set),
                  type(element) == elementType,
                  type(result) == .bool
            else {
                throw fail("set_contains operands must match Set.Element and return Bool")
            }
        case let .setInsert(inserted, member, updated, set, element):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Set.insert requires \(Core.Capability.collectionsV1)")
            }
            guard case let .set(elementType) = type(set),
                  type(element) == elementType,
                  type(inserted) == .bool,
                  type(member) == elementType,
                  type(updated) == type(set)
            else {
                throw fail("set_insert results and operands must match Set.Element")
            }
        case let .setUpdate(oldMember, updated, set, element):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Set.update requires \(Core.Capability.collectionsV1)")
            }
            guard case let .set(elementType) = type(set),
                  type(element) == elementType,
                  type(oldMember) == .optional(elementType),
                  type(updated) == type(set)
            else {
                throw fail("set_update results and operands must match Set.Element")
            }
        case let .setRemove(removed, updated, set, element):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Set.remove requires \(Core.Capability.collectionsV1)")
            }
            guard case let .set(elementType) = type(set),
                  type(element) == elementType,
                  type(removed) == .optional(elementType),
                  type(updated) == type(set)
            else {
                throw fail("set_remove results and operands must match Set.Element")
            }
        case let .setPopFirst(element, updated, set):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Set.popFirst requires \(Core.Capability.collectionsV1)")
            }
            guard case let .set(elementType) = type(set),
                  type(element) == .optional(elementType),
                  type(updated) == type(set)
            else {
                throw fail("set_pop_first results must match Set.Element")
            }
        case let .setAlgebra(result, _, lhs, rhs):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Set algebra requires \(Core.Capability.collectionsV1)")
            }
            guard case .set = type(lhs),
                  type(rhs) == type(lhs),
                  type(result) == type(lhs)
            else {
                throw fail("set algebra needs three matching Set operands/results")
            }
        case let .setRelation(result, _, lhs, rhs):
            guard capabilities.contains(.collectionsV1) else {
                throw fail("Set relation requires \(Core.Capability.collectionsV1)")
            }
            guard case .set = type(lhs),
                  type(rhs) == type(lhs),
                  type(result) == .bool
            else {
                throw fail("set relation needs matching Set operands and Bool result")
            }
        case let .compare(result, predicate, lhs, rhs):
            guard type(result) == .bool, type(lhs) == type(rhs) else {
                throw fail("comparison needs matching operands and Bool result")
            }
            let supported = switch predicate {
            case .equal, .notEqual:
                type(lhs).isVMEquatable
            case .lessThan, .lessThanOrEqual,
                 .greaterThan, .greaterThanOrEqual:
                type(lhs).isVMComparable
            }
            guard supported else {
                throw fail(
                    "comparison predicate is unavailable for \(type(lhs))"
                )
            }
        case let .branch(target, arguments):
            try verifyBranchArguments(arguments, target: target, function: function, block: block, offset: offset, blocks: blocks)
        case let .conditionalBranch(condition, trueTarget, trueArguments, falseTarget, falseArguments):
            guard type(condition) == .bool else { throw fail("cond_br condition must be Bool") }
            try verifyBranchArguments(trueArguments, target: trueTarget, function: function, block: block, offset: offset, blocks: blocks)
            try verifyBranchArguments(falseArguments, target: falseTarget, function: function, block: block, offset: offset, blocks: blocks)
        case let .apply(result, calleeID, arguments):
            guard let callee = functions[calleeID] else { throw fail("unknown HLBC function \(calleeID)") }
            try verifyEffects(
                callee.effects,
                allowedBy: function.effects,
                operation: "hlbc_apply",
                fail: fail
            )
            try verifyExactErrorPropagation(
                from: callee.thrownType,
                ifThrowing: callee.effects.mayThrow,
                to: function,
                operation: "hlbc_apply",
                fail: fail
            )
            try verifyCall(
                arguments: arguments,
                result: result,
                parameterTypes: try parameterTypes(of: callee),
                resultType: callee.resultType,
                function: function,
                block: block,
                offset: offset
            )
        case let .entryApply(result, entry, arguments):
            guard let descriptor = shell.entries[entry] else { throw fail("unknown Shell entry \(entry)") }
            try verifyBorrowedCallCapability(
                descriptor.parameterConventions,
                capabilities: capabilities
            )
            try verifyEffects(
                descriptor.effects,
                allowedBy: function.effects,
                operation: "entry_apply",
                fail: fail
            )
            try verifyBoundaryErrorPropagation(
                ifThrowing: descriptor.effects.mayThrow,
                to: function,
                operation: "entry_apply",
                fail: fail
            )
            try verifyCall(
                arguments: arguments,
                result: result,
                parameterTypes: descriptor.parameterTypes,
                resultType: descriptor.resultType,
                function: function,
                block: block,
                offset: offset
            )
        case let .nativeApply(result, importID, arguments):
            guard let requirement = declaredImports[importID] else {
                throw fail("native import \(importID) is used but not declared")
            }
            guard capabilities.contains(requirement.requiredCapability) else {
                throw fail("native import capability is not declared")
            }
            guard let descriptor = shell.imports[importID] else { throw fail("unknown native import \(importID)") }
            try verifyEffects(
                descriptor.effects,
                allowedBy: function.effects,
                operation: "native_apply",
                fail: fail
            )
            try verifyBoundaryErrorPropagation(
                ifThrowing: descriptor.effects.mayThrow,
                to: function,
                operation: "native_apply",
                fail: fail
            )
            try verifyCall(
                arguments: arguments,
                result: result,
                parameterTypes: descriptor.parameterTypes,
                resultType: descriptor.resultType,
                function: function,
                block: block,
                offset: offset
            )
        case let .makeClosure(result, target, captures, _):
            guard capabilities.contains(.closureValuesV1) else {
                throw fail("make_closure requires \(Core.Capability.closureValuesV1)")
            }
            guard case let .closure(signature) = type(result) else {
                throw fail("make_closure result must have a closure type")
            }
            let constructionTarget: ClosureConstructionTarget
            let targetParameterTypes: [Bytecode.ValueType]
            let targetParameterConventions: [Bytecode.ParameterConvention]
            let targetResultType: Bytecode.ValueType
            let targetEffects: Core.Effects
            switch target {
            case let .image(calleeID):
                guard let callee = functions[calleeID] else {
                    throw fail("unknown closure body \(calleeID)")
                }
                guard callee.kind == .closureBody else {
                    throw fail("make_closure image target must be a closure body")
                }
                constructionTarget = .imageBody(
                    thrownType: callee.thrownType
                )
                targetParameterTypes = try parameterTypes(of: callee)
                targetParameterConventions = callee.parameterConventions
                targetResultType = callee.resultType
                targetEffects = callee.effects
            case let .entry(entry):
                guard let descriptor = shell.entries[entry] else {
                    throw fail("unknown Shell entry \(entry)")
                }
                constructionTarget = .shellEntry
                targetParameterTypes = descriptor.parameterTypes
                targetParameterConventions = descriptor.parameterConventions
                targetResultType = descriptor.resultType
                targetEffects = descriptor.effects
            case let .nativeImport(importID):
                guard let requirement = declaredImports[importID] else {
                    throw fail("native import \(importID) is used but not declared")
                }
                guard capabilities.contains(requirement.requiredCapability)
                else {
                    throw fail("native import capability is not declared")
                }
                guard let descriptor = shell.imports[importID] else {
                    throw fail("unknown native import \(importID)")
                }
                constructionTarget = .nativeImport
                targetParameterTypes = descriptor.parameterTypes
                targetParameterConventions = descriptor.parameterConventions
                targetResultType = descriptor.resultType
                targetEffects = descriptor.effects
            }
            try verifyClosureConstruction(
                target: constructionTarget,
                signature: signature,
                captureTypes: captures.map(type),
                targetParameterTypes: targetParameterTypes,
                targetParameterConventions: targetParameterConventions,
                targetResultType: targetResultType,
                targetEffects: targetEffects,
                creatorEffects: function.effects,
                shell: shell,
                capabilities: capabilities,
                fail: fail
            )
        case let .beginClosureScope(result, closure):
            guard capabilities.contains(.closureValuesV1) else {
                throw fail(
                    "begin_closure_scope requires \(Core.Capability.closureValuesV1)"
                )
            }
            guard case .closure = type(closure), type(result) == type(closure)
            else {
                throw fail(
                    "begin_closure_scope requires matching closure operands"
                )
            }
        case let .endClosureScope(closure):
            guard capabilities.contains(.closureValuesV1) else {
                throw fail(
                    "end_closure_scope requires \(Core.Capability.closureValuesV1)"
                )
            }
            guard case .closure = type(closure) else {
                throw fail("end_closure_scope operand must be a closure")
            }
        case let .closureApply(result, closure, arguments):
            guard capabilities.contains(.closureValuesV1) else {
                throw fail("closure_apply requires \(Core.Capability.closureValuesV1)")
            }
            guard case let .closure(signature) = type(closure) else {
                throw fail("closure_apply operand must have a closure type")
            }
            try verifyEffects(
                signature.effects,
                allowedBy: function.effects,
                operation: "closure_apply",
                fail: fail
            )
            try verifyExactErrorPropagation(
                from: signature.thrownType,
                ifThrowing: signature.effects.mayThrow,
                to: function,
                operation: "closure_apply",
                fail: fail
            )
            try verifyCall(
                arguments: arguments,
                result: result,
                parameterTypes: signature.parameters,
                resultType: signature.result,
                function: function,
                block: block,
                offset: offset
            )
        case let .closureTryApply(
            closure,
            arguments,
            normalTarget,
            errorTarget
        ):
            guard capabilities.contains(.closureValuesV1) else {
                throw fail(
                    "closure_try_apply requires \(Core.Capability.closureValuesV1)"
                )
            }
            guard capabilities.contains(.untypedThrowsV1)
                    || capabilities.contains(.structuredErrorsV1)
                    || capabilities.contains(.typedThrowsV1)
            else {
                throw fail("closure_try_apply requires an Error capability")
            }
            guard case let .closure(signature) = type(closure) else {
                throw fail("closure_try_apply operand must have a closure type")
            }
            guard signature.effects.mayThrow else {
                throw fail("closure_try_apply requires a throwing closure")
            }
            try verifyEffects(
                signature.effects,
                allowedBy: function.effects,
                operation: "closure_try_apply",
                catchesError: true,
                fail: fail
            )
            try verifyTryCall(
                arguments: arguments,
                parameterTypes: signature.parameters,
                resultType: signature.result,
                thrownType: signature.thrownType,
                normalTarget: normalTarget,
                errorTarget: errorTarget,
                function: function,
                block: block,
                offset: offset,
                blocks: blocks,
                capabilities: capabilities
            )
        case let .tryApply(calleeID, arguments, normalTarget, errorTarget):
            guard capabilities.contains(.untypedThrowsV1)
                    || capabilities.contains(.structuredErrorsV1)
                    || capabilities.contains(.typedThrowsV1)
            else {
                throw fail("try_apply requires an Error capability")
            }
            guard let callee = functions[calleeID] else {
                throw fail("unknown HLBC function \(calleeID)")
            }
            guard callee.effects.mayThrow else {
                throw fail("try_apply requires a throwing callee")
            }
            try verifyEffects(
                callee.effects,
                allowedBy: function.effects,
                operation: "try_apply",
                catchesError: true,
                fail: fail
            )
            try verifyTryCall(
                arguments: arguments,
                parameterTypes: try parameterTypes(of: callee),
                resultType: callee.resultType,
                thrownType: callee.thrownType,
                normalTarget: normalTarget,
                errorTarget: errorTarget,
                function: function,
                block: block,
                offset: offset,
                blocks: blocks,
                capabilities: capabilities
            )
        case let .entryTryApply(entry, arguments, normalTarget, errorTarget):
            guard capabilities.contains(.untypedThrowsV1)
                    || capabilities.contains(.structuredErrorsV1)
            else {
                throw fail("entry_try_apply requires an Error capability")
            }
            guard let descriptor = shell.entries[entry] else {
                throw fail("unknown Shell entry \(entry)")
            }
            try verifyBorrowedCallCapability(
                descriptor.parameterConventions,
                capabilities: capabilities
            )
            guard descriptor.effects.mayThrow else {
                throw fail("entry_try_apply requires a throwing Shell entry")
            }
            try verifyEffects(
                descriptor.effects,
                allowedBy: function.effects,
                operation: "entry_try_apply",
                catchesError: true,
                fail: fail
            )
            try verifyTryCall(
                arguments: arguments,
                parameterTypes: descriptor.parameterTypes,
                resultType: descriptor.resultType,
                thrownType: nil,
                normalTarget: normalTarget,
                errorTarget: errorTarget,
                function: function,
                block: block,
                offset: offset,
                blocks: blocks,
                capabilities: capabilities
            )
        case let .nativeTryApply(importID, arguments, normalTarget, errorTarget):
            guard capabilities.contains(.untypedThrowsV1)
                    || capabilities.contains(.structuredErrorsV1)
            else {
                throw fail("native_try_apply requires an Error capability")
            }
            guard let requirement = declaredImports[importID] else {
                throw fail("native import \(importID) is used but not declared")
            }
            guard capabilities.contains(requirement.requiredCapability) else {
                throw fail("native import capability is not declared")
            }
            guard let descriptor = shell.imports[importID] else {
                throw fail("unknown native import \(importID)")
            }
            guard descriptor.effects.mayThrow else {
                throw fail("native_try_apply requires a throwing native import")
            }
            try verifyEffects(
                descriptor.effects,
                allowedBy: function.effects,
                operation: "native_try_apply",
                catchesError: true,
                fail: fail
            )
            try verifyTryCall(
                arguments: arguments,
                parameterTypes: descriptor.parameterTypes,
                resultType: descriptor.resultType,
                thrownType: nil,
                normalTarget: normalTarget,
                errorTarget: errorTarget,
                function: function,
                block: block,
                offset: offset,
                blocks: blocks,
                capabilities: capabilities
            )
        case let .returnValue(value):
            if function.resultType == .void {
                guard value == nil else { throw fail("Void function cannot return a value") }
            } else {
                guard let value, type(value) == function.resultType else {
                    throw fail("return type does not match function result")
                }
            }
        case let .throwError(error):
            guard function.effects.mayThrow,
                  type(error) == function.thrownType else {
                throw fail(
                    "throw_error payload does not match the function's thrown type"
                )
            }
        case let .sourceFailure(prefix, detail):
            guard !prefix.isEmpty else {
                throw fail("source_failure requires a nonempty prefix")
            }
            let detailIsRepresentedError: Bool = switch type(detail) {
            case .string, .error:
                true
            case let .local(key):
                localTypes[key]?.conformsToError == true
            default:
                false
            }
            guard detailIsRepresentedError else {
                throw fail(
                    "source_failure detail must be String or represented Error"
                )
            }
        case .trap:
            break
        }
    }

    private func isCopyable(
        _ type: Bytecode.ValueType,
        shell: Verification.ShellInterface
    ) -> Bool {
        switch type {
        case let .native(id):
            shell.types[id]?.isCopyable == true
        case .closure, .mutableCell, .nonOwningReference:
            true
        case .arrayState, .dictionaryState:
            false
        case let .tuple(elements):
            elements.allSatisfy { isCopyable($0, shell: shell) }
        case let .optional(wrapped):
            isCopyable(wrapped, shell: shell)
        case let .array(element):
            isCopyable(element, shell: shell)
        case let .dictionary(key, value):
            isCopyable(key, shell: shell) && isCopyable(value, shell: shell)
        case let .set(element):
            isCopyable(element, shell: shell)
        case .void, .never, .address:
            false
        case .bool, .integer, .float, .string, .any, .local, .error:
            true
        }
    }

    private func isValidNonOwningReference(
        kind: Bytecode.NonOwningReferenceKind,
        pointee: Bytecode.ValueType,
        shell: Verification.ShellInterface,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) -> Bool {
        let strongType: Bytecode.ValueType
        if case let .optional(wrapped) = pointee {
            strongType = wrapped
        } else {
            guard kind == .unowned else { return false }
            strongType = pointee
        }
        switch strongType {
        case let .local(key):
            guard let definition = localTypes[key],
                  case .class = definition.kind
            else { return false }
            return true
        case let .native(id):
            return shell.types[id]?.kind == .reference
        default:
            return false
        }
    }

    private func mutableCellFieldType(
        _ aggregate: Bytecode.ValueType,
        fieldIndex: UInt32,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) -> Bytecode.ValueType? {
        guard let index = Int(exactly: fieldIndex) else { return nil }
        switch aggregate {
        case let .tuple(elements):
            guard elements.indices.contains(index) else { return nil }
            return elements[index]
        case let .local(key):
            guard let definition = localTypes[key],
                  case let .structure(fields) = definition.kind,
                  fields.indices.contains(index)
            else { return nil }
            return fields[index].type
        default:
            return nil
        }
    }

    private func verifyEffects(
        _ callee: Core.Effects,
        allowedBy caller: Core.Effects,
        operation: String,
        catchesError: Bool = false,
        fail: (String) -> Verification.Error
    ) throws {
        if callee.isAsync {
            throw fail("\(operation) calls an async entry without a suspension contract")
        }
        if callee.mayThrow, !caller.mayThrow, !catchesError {
            throw fail("\(operation) calls a throwing operation from a nonthrowing function")
        }
        if callee.mayAllocate, !caller.mayAllocate {
            throw fail("\(operation) calls an allocating operation from a nonallocating function")
        }
        if callee.hasExternalSideEffects, !caller.hasExternalSideEffects {
            throw fail("\(operation) calls an externally side-effecting operation from a pure function")
        }
        if callee.requiresMainActor, !caller.requiresMainActor {
            throw fail("\(operation) crosses into MainActor from a nonisolated function")
        }
    }

    private func verifyExactErrorPropagation(
        from calleeThrownType: Bytecode.ValueType?,
        ifThrowing mayThrow: Bool,
        to caller: Bytecode.Function,
        operation: String,
        fail: (String) -> Verification.Error
    ) throws {
        guard mayThrow else { return }
        guard calleeThrownType != nil,
              calleeThrownType == caller.thrownType
        else {
            throw fail(
                "\(operation) changes the propagated Error type without a concrete reabstraction"
            )
        }
    }

    private func verifyBoundaryErrorPropagation(
        ifThrowing mayThrow: Bool,
        to caller: Bytecode.Function,
        operation: String,
        fail: (String) -> Verification.Error
    ) throws {
        guard mayThrow else { return }
        guard caller.thrownType == .string || caller.thrownType == .error else {
            throw fail(
                "\(operation) cannot propagate a boundary error through a typed-throws function"
            )
        }
    }

    private enum ClosureConstructionTarget {
        case imageBody(thrownType: Bytecode.ValueType?)
        case shellEntry
        case nativeImport

        var operation: String {
            switch self {
            case .imageBody, .shellEntry, .nativeImport: "make_closure"
            }
        }

        var parameterSubject: String {
            switch self {
            case .imageBody: "closure body"
            case .shellEntry: "Shell entry closure target"
            case .nativeImport: "NativeImport closure target"
            }
        }

        var signatureMismatchReason: String {
            switch self {
            case .imageBody:
                "closure body result, thrown type, or callable effects do not "
                    + "match its closure signature"
            case .shellEntry:
                "Shell entry closure target result, boundary error type, or "
                    + "callable effects do not match its closure signature"
            case .nativeImport:
                "NativeImport closure target result, boundary error type, or "
                    + "callable effects do not match its closure signature"
            }
        }

        func accepts(
            thrownType: Bytecode.ValueType?,
            effects: Core.Effects
        ) -> Bool {
            switch self {
            case let .imageBody(targetThrownType):
                targetThrownType == thrownType
            case .shellEntry, .nativeImport:
                !effects.mayThrow
                    || thrownType == .string
                    || thrownType == .error
            }
        }
    }

    private func verifyClosureConstruction(
        target: ClosureConstructionTarget,
        signature: Bytecode.ClosureSignature,
        captureTypes: [Bytecode.ValueType],
        targetParameterTypes: [Bytecode.ValueType],
        targetParameterConventions: [Bytecode.ParameterConvention],
        targetResultType: Bytecode.ValueType,
        targetEffects: Core.Effects,
        creatorEffects: Core.Effects,
        shell: Verification.ShellInterface,
        capabilities: Set<Core.Capability>,
        fail: (String) -> Verification.Error
    ) throws {
        try verifyBorrowedCallCapability(
            targetParameterConventions,
            capabilities: capabilities
        )
        guard targetResultType == signature.result,
              signature.hasCanonicalCallableEffects,
              signature.hasCanonicalThrownType,
              target.accepts(
                thrownType: signature.thrownType,
                effects: targetEffects
              ),
              signature.safelyRestricts(targetEffects: targetEffects)
        else {
            throw fail(target.signatureMismatchReason)
        }
        try verifyClosureTargetAuthority(
            targetEffects,
            allowedBy: creatorEffects,
            operation: target.operation,
            fail: fail
        )
        guard targetParameterConventions.count
                == targetParameterTypes.count,
              targetParameterTypes
                == signature.parameters + captureTypes
        else {
            throw fail(
                "\(target.parameterSubject) parameters must equal invocation parameters "
                    + "followed by captures"
            )
        }
        guard Array(
            targetParameterConventions.prefix(signature.parameters.count)
        ) == signature.parameterConventions else {
            throw fail(
                "\(target.parameterSubject) invocation ownership does not match its closure signature"
            )
        }
        let captureConventions = Array(
            targetParameterConventions.suffix(captureTypes.count)
        )
        guard captureConventions.allSatisfy({ $0 != .inout }) else {
            throw fail("closure captures cannot carry inout parameters")
        }
        for captureType in captureTypes {
            if case .address = captureType {
                throw fail("closure captures cannot contain address values")
            }
            if case .closure = captureType,
               !capabilities.contains(.escapingClosureValuesV1) {
                throw Verification.Error.capabilityDenied(
                    .escapingClosureValuesV1
                )
            }
            guard isCopyable(captureType, shell: shell) else {
                throw fail("closure captures must be copyable")
            }
        }
    }

    private func verifyBorrowedCallCapability(
        _ conventions: [Bytecode.ParameterConvention],
        capabilities: Set<Core.Capability>
    ) throws {
        if conventions.contains(.borrowed),
           !capabilities.contains(.borrowCallsV1) {
            throw Verification.Error.capabilityDenied(.borrowCallsV1)
        }
    }

    /// A closure is a capability for its concrete image, frozen Shell entry, or
    /// declared NativeImport target. Swift's function type carries callable ABI
    /// only, so target resource authority is checked at construction.
    private func verifyClosureTargetAuthority(
        _ target: Core.Effects,
        allowedBy creator: Core.Effects,
        operation: String,
        fail: (String) -> Verification.Error
    ) throws {
        if target.mayAllocate, !creator.mayAllocate {
            throw fail(
                "\(operation) captures allocating target authority in a nonallocating function"
            )
        }
        if target.hasExternalSideEffects,
           !creator.hasExternalSideEffects {
            throw fail(
                "\(operation) captures external-side-effect authority in a pure function"
            )
        }
    }

    private func verifyTryCall(
        arguments: [Bytecode.Register],
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        thrownType: Bytecode.ValueType?,
        normalTarget: Bytecode.BlockID,
        errorTarget: Bytecode.BlockID,
        function: Bytecode.Function,
        block: Bytecode.Block,
        offset: Int,
        blocks: [Bytecode.BlockID: Bytecode.Block],
        capabilities: Set<Core.Capability>
    ) throws {
        let fail: (String) -> Verification.Error = {
            .invalidInstruction(function: function.id, block: block.id, offset: offset, reason: $0)
        }
        guard normalTarget != errorTarget else {
            throw fail("try_apply normal and error targets must differ")
        }
        guard arguments.count == parameterTypes.count else {
            throw fail("try_apply argument count mismatch")
        }
        for (argument, expected) in zip(arguments, parameterTypes)
        where function.type(of: argument) != expected {
            throw fail("try_apply argument type mismatch")
        }
        guard let normal = blocks[normalTarget] else {
            throw fail("unknown try_apply normal target \(normalTarget)")
        }
        if resultType == .void || resultType == .never {
            guard normal.parameters.isEmpty else {
                throw fail(
                    "Void/Never try_apply normal target must not accept a result"
                )
            }
        } else {
            guard normal.parameters.count == 1,
                  normal.parameters.first.flatMap({ function.type(of: $0) }) == resultType
            else {
                throw fail("try_apply normal target must accept the callee result")
            }
        }
        guard let failure = blocks[errorTarget], failure.parameters.count == 1,
              let errorType = failure.parameters.first.flatMap({ function.type(of: $0) })
        else {
            throw fail("try_apply error target must accept one Error value")
        }
        if let thrownType {
            guard errorType == thrownType else {
                throw fail("try_apply error target does not match the callee's thrown type")
            }
            return
        }
        switch errorType {
        case .string where capabilities.contains(.untypedThrowsV1):
            break
        case .error where capabilities.contains(.structuredErrorsV1):
            break
        default:
            if capabilities.contains(.untypedThrowsV1),
               !capabilities.contains(.structuredErrorsV1) {
                throw fail("try_apply error target must accept one untyped String error")
            }
            throw fail("try_apply error target does not match its Error capability")
        }
    }

    private func verifyBranchArguments(
        _ arguments: [Bytecode.Register],
        target: Bytecode.BlockID,
        function: Bytecode.Function,
        block: Bytecode.Block,
        offset: Int,
        blocks: [Bytecode.BlockID: Bytecode.Block]
    ) throws {
        guard let targetBlock = blocks[target] else {
            throw Verification.Error.invalidInstruction(
                function: function.id, block: block.id, offset: offset, reason: "unknown target \(target)"
            )
        }
        guard arguments.count == targetBlock.parameters.count else {
            throw Verification.Error.invalidInstruction(
                function: function.id, block: block.id, offset: offset, reason: "branch argument count mismatch"
            )
        }
        for (argument, parameter) in zip(arguments, targetBlock.parameters) {
            guard function.type(of: argument) == function.type(of: parameter) else {
                throw Verification.Error.invalidInstruction(
                    function: function.id, block: block.id, offset: offset, reason: "branch argument type mismatch"
                )
            }
        }
    }

    private func verifyCall(
        arguments: [Bytecode.Register],
        result: Bytecode.Register?,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        function: Bytecode.Function,
        block: Bytecode.Block,
        offset: Int
    ) throws {
        let fail: (String) -> Verification.Error = {
            .invalidInstruction(function: function.id, block: block.id, offset: offset, reason: $0)
        }
        guard arguments.count == parameterTypes.count else { throw fail("call argument count mismatch") }
        for (argument, expected) in zip(arguments, parameterTypes)
        where function.type(of: argument) != expected {
            throw fail("call argument type mismatch")
        }
        if resultType == .void {
            guard result == nil else { throw fail("Void call must not define a result") }
        } else {
            guard let result, function.type(of: result) == resultType else { throw fail("call result type mismatch") }
        }
    }

    private func verifyOwnership(
        function: Bytecode.Function,
        blocks: [Bytecode.BlockID: Bytecode.Block],
        functions: [Bytecode.FunctionID: Bytecode.Function],
        shell: Verification.ShellInterface
    ) throws {
        let borrowedParameters = Set(zip(
            function.parameterRegisters,
            function.parameterConventions
        ).compactMap { register, convention in
            convention == .borrowed ? register : nil
        })
        let entryLive = Set(zip(
            function.parameterRegisters,
            function.parameterConventions
        ).compactMap { register, convention in
            convention == .owned
                && function.type(of: register)?.requiresLinearOwnership == true
                ? register : nil
        })
        // VM registers survive control-flow transfers. Track linear values at
        // function scope so dominated native handles may cross a branch while
        // every merge still requires one exact, path-independent live set.
        var incoming: [Bytecode.BlockID: Set<Bytecode.Register>] = [
            function.entryBlock: entryLive,
        ]
        var worklist = [function.entryBlock]

        while let blockID = worklist.popLast() {
            guard let block = blocks[blockID], var live = incoming[blockID] else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "ownership dataflow references an unknown block"
                )
            }
            var outgoing: [(target: Bytecode.BlockID, live: Set<Bytecode.Register>)] = []
            func forward(
                _ state: Set<Bytecode.Register>,
                to target: Bytecode.BlockID
            ) throws {
                outgoing.append((
                    target,
                    try ownershipState(
                        state,
                        entering: target,
                        function: function,
                        blocks: blocks
                    )
                ))
            }
            for (offset, instruction) in block.instructions.enumerated() {
                func fail(_ reason: String) -> Verification.Error {
                    .invalidInstruction(
                        function: function.id,
                        block: block.id,
                        offset: offset,
                        reason: reason
                    )
                }
                for operand in instruction.operandRegisters
                where function.type(of: operand)?.requiresLinearOwnership == true {
                    guard live.contains(operand) || borrowedParameters.contains(operand) else {
                        throw fail("instruction uses a consumed owned value")
                    }
                }
                switch instruction {
                case let .copyValue(result, source),
                     let .convertClosure(result, source):
                    if function.type(of: source)?.requiresLinearOwnership == true {
                        guard live.contains(source) || borrowedParameters.contains(source) else {
                            throw fail("copying conversion uses a consumed value")
                        }
                        live.insert(result)
                    }
                case let .moveValue(result, source):
                    if function.type(of: source)?.requiresLinearOwnership == true {
                        guard live.remove(source) != nil else { throw fail("move_value uses a consumed value") }
                        live.insert(result)
                    }
                case let .destroyValue(register):
                    if function.type(of: register)?.requiresLinearOwnership == true,
                       live.remove(register) == nil {
                        throw fail("destroy_value uses a consumed value")
                    }
                case let .makeTuple(result, elements):
                    for element in elements
                    where function.type(of: element)?.requiresLinearOwnership == true {
                        guard live.remove(element) != nil else {
                            throw fail("make_tuple consumes a non-live element")
                        }
                    }
                    if function.type(of: result)?.requiresLinearOwnership == true { live.insert(result) }
                case let .unpackTuple(results, tuple):
                    if function.type(of: tuple)?.requiresLinearOwnership == true,
                       live.remove(tuple) == nil {
                        throw fail("unpack_tuple consumes a non-live tuple")
                    }
                    for result in results
                    where function.type(of: result)?.requiresLinearOwnership == true {
                        live.insert(result)
                    }
                case .makeStruct, .structExtract, .makeEnum, .makeError, .castError,
                     .eraseToAny, .checkedCastAny, .forceCastAny, .stackAddress,
                     .projectAggregateAddress, .projectMutableCell, .allocateObject,
                     .projectObjectAddress, .hostedSuperApply, .beginAccess,
                     .endAccess, .makeNonOwningReference,
                     .storeNonOwningReference,
                     .beginClosureScope, .endClosureScope:
                    // Allocation and address projection do not transfer a
                    // native handle. A local class field load/store is tracked
                    // by the corresponding address instruction instead.
                    break
                case let .projectHostedObject(result, _):
                    live.insert(result)
                case let .switchEnum(_, cases, defaultTarget):
                    let targets = cases.map(\.target) + (defaultTarget.map { [$0] } ?? [])
                    for target in targets {
                        try forward(live, to: target)
                    }
                case let .makeOptionalSome(result, value):
                    if function.type(of: value)?.requiresLinearOwnership == true,
                       live.remove(value) == nil {
                        throw fail("optional_some consumes a non-live payload")
                    }
                    if function.type(of: result)?.requiresLinearOwnership == true { live.insert(result) }
                case let .makeOptionalNone(result):
                    if function.type(of: result)?.requiresLinearOwnership == true { live.insert(result) }
                case .optionalIsSome:
                    break
                case let .unwrapOptional(result, optional):
                    if function.type(of: optional)?.requiresLinearOwnership == true,
                       live.remove(optional) == nil {
                        throw fail("optional_unwrap consumes a non-live Optional")
                    }
                    if function.type(of: result)?.requiresLinearOwnership == true { live.insert(result) }
                case let .switchOptional(optional, someTarget, noneTarget):
                    if function.type(of: optional)?.requiresLinearOwnership == true,
                       live.remove(optional) == nil {
                        throw fail("switch_optional consumes a non-live Optional")
                    }
                    try forward(live, to: someTarget)
                    try forward(live, to: noneTarget)
                case let .storeStack(_, source, _):
                    if function.type(of: source)?.requiresLinearOwnership == true,
                       live.remove(source) == nil {
                        throw fail("store_stack consumes a non-live value")
                    }
                case let .loadStack(result, _, _):
                    if function.type(of: result)?.requiresLinearOwnership == true { live.insert(result) }
                case .destroyStack, .destroyStackIfInitialized,
                     .destroyAddress, .destroyAddressIfInitialized:
                    break
                case let .makeArrayBuilder(result):
                    live.insert(result)
                case .arrayBuilderAppend, .arrayBuilderAppendContents:
                    break
                case let .finishArrayBuilder(result, builder):
                    guard live.remove(builder) != nil else {
                        throw fail(
                            "finish_array_builder consumes a non-live builder"
                        )
                    }
                    if function.type(of: result)?.requiresLinearOwnership
                        == true {
                        live.insert(result)
                    }
                case let .makeArrayMutationState(result, _):
                    live.insert(result)
                case let .arrayMutationGet(result, _, _):
                    if function.type(of: result)?.requiresLinearOwnership
                        == true {
                        live.insert(result)
                    }
                case .arrayMutationSwap:
                    break
                case let .finishArrayMutation(result, state):
                    guard live.remove(state) != nil else {
                        throw fail(
                            "finish_array_mutation consumes a non-live state"
                        )
                    }
                    if function.type(of: result)?.requiresLinearOwnership
                        == true {
                        live.insert(result)
                    }
                case let .makeDictionaryBuilder(result, _):
                    live.insert(result)
                case let .dictionaryBuilderGet(result, _, _):
                    if function.type(of: result)?.requiresLinearOwnership
                        == true {
                        live.insert(result)
                    }
                case .dictionaryBuilderSet:
                    break
                case .dictionaryBuilderAppendArrayElement:
                    break
                case let .finishDictionaryBuilder(result, builder):
                    guard live.remove(builder) != nil else {
                        throw fail(
                            "finish_dictionary_builder consumes a non-live builder"
                        )
                    }
                    if function.type(of: result)?.requiresLinearOwnership
                        == true {
                        live.insert(result)
                    }
                case let .makeArraySortState(result, _):
                    live.insert(result)
                case .arraySortAcceptComparison:
                    break
                case let .finishArraySort(result, state):
                    guard live.remove(state) != nil else {
                        throw fail(
                            "finish_array_sort consumes a non-live state"
                        )
                    }
                    if function.type(of: result)?.requiresLinearOwnership
                        == true {
                        live.insert(result)
                    }
                case let .makeArraySplitState(result, _, _, _):
                    live.insert(result)
                case .arraySplitAcceptElement:
                    break
                case let .finishArraySplit(result, state):
                    guard live.remove(state) != nil else {
                        throw fail(
                            "finish_array_split consumes a non-live state"
                        )
                    }
                    if function.type(of: result)?.requiresLinearOwnership
                        == true {
                        live.insert(result)
                    }
                case let .loadAddress(result, _, _):
                    if function.type(of: result)?.requiresLinearOwnership == true {
                        live.insert(result)
                    }
                case let .makeMutableCell(_, initialValue):
                    if let initialValue,
                       function.type(of: initialValue)?.requiresLinearOwnership
                        == true,
                       live.remove(initialValue) == nil {
                        throw fail(
                            "make_mutable_cell consumes a non-live value"
                        )
                    }
                case .borrowMutableCell:
                    break
                case let .loadMutableCell(result, _):
                    if function.type(of: result)?.requiresLinearOwnership == true {
                        live.insert(result)
                    }
                case let .loadNonOwningReference(result, _, _):
                    if function.type(of: result)?.requiresLinearOwnership == true {
                        live.insert(result)
                    }
                case let .storeMutableCell(_, source, _):
                    if function.type(of: source)?.requiresLinearOwnership == true,
                       live.remove(source) == nil {
                        throw fail(
                            "store_mutable_cell consumes a non-live value"
                        )
                    }
                case let .storeAddress(_, source, _):
                    if function.type(of: source)?.requiresLinearOwnership == true {
                        guard live.remove(source) != nil else {
                            throw fail("store_address consumes a non-live value")
                        }
                    }
                case let .makeArray(result, elements):
                    for element in elements
                    where function.type(of: element)?.requiresLinearOwnership == true {
                        guard live.remove(element) != nil else {
                            throw fail("make_array consumes a non-live element")
                        }
                    }
                    if function.type(of: result)?.requiresLinearOwnership == true { live.insert(result) }
                case let .arrayRebase(result, array, _):
                    if function.type(of: array)?.requiresLinearOwnership
                        == true,
                       live.remove(array) == nil {
                        throw fail(
                            "array_rebase consumes a non-live Array"
                        )
                    }
                    if function.type(of: result)?.requiresLinearOwnership
                        == true {
                        live.insert(result)
                    }
                case let .select(result, _, _, _),
                     let .arrayGet(result, _, _),
                     let .arrayBoundary(result, _, _),
                     let .arrayAdapter(result, _, _),
                     let .arrayRepeat(result, _, _),
                     let .arraySubsequence(result, _, _, _),
                     let .arrayRangeSlice(result, _, _, _),
                     let .arrayZip(result, _, _),
                     let .arrayJoined(result, _, _),
                     let .arrayReplaceSubrange(result, _, _, _, _),
                     let .arraySwap(result, _, _, _),
                     let .arraySorted(result, _),
                     let .arraySortNextComparison(result, _),
                     let .arraySplitSeparator(result, _, _, _, _),
                     let .arraySplitNextElement(result, _),
                     let .arrayAppend(result, _, _), let .arrayUpdate(result, _, _, _),
                     let .collectionMaterialize(result, _),
                     let .collectionNext(result, _, _, _),
                     let .progressionNext(result, _, _, _, _),
                     let .makeDictionary(result, _), let .dictionaryGet(result, _, _),
                     let .dictionaryProject(result, _, _),
                     let .makeSet(result, _),
                     let .setAlgebra(result, _, _, _):
                    if function.type(of: result)?.requiresLinearOwnership == true { live.insert(result) }
                case let .arrayPopLast(elementResult, arrayResult, _):
                    for result in [elementResult, arrayResult]
                    where function.type(of: result)?.requiresLinearOwnership == true {
                        live.insert(result)
                    }
                case let .dictionarySet(
                    previousValueResult,
                    dictionaryResult,
                    _,
                    _,
                    _
                ):
                    for result in [previousValueResult, dictionaryResult]
                    where function.type(of: result)?.requiresLinearOwnership == true {
                        live.insert(result)
                    }
                case let .setInsert(inserted, member, updated, _, _):
                    for result in [inserted, member, updated]
                    where function.type(of: result)?.requiresLinearOwnership == true {
                        live.insert(result)
                    }
                case let .setUpdate(oldMember, updated, _, _),
                     let .setRemove(oldMember, updated, _, _),
                     let .setPopFirst(oldMember, updated, _):
                    for result in [oldMember, updated]
                    where function.type(of: result)?.requiresLinearOwnership == true {
                        live.insert(result)
                    }
                case .constantString:
                    break
                case let .apply(result, callee, arguments):
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: functions[callee]?.parameterConventions
                            ?? Array(repeating: .owned, count: arguments.count),
                        live: &live,
                        function: function,
                        fail: fail
                    )
                    if let result,
                       let target = functions[callee]?.resultType,
                       target.requiresLinearOwnership {
                        live.insert(result)
                    }
                case let .entryApply(result, entry, arguments):
                    guard let descriptor = shell.entries[entry] else {
                        throw fail("unknown Shell entry \(entry)")
                    }
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: descriptor.parameterConventions,
                        live: &live,
                        function: function,
                        fail: fail
                    )
                    if let result,
                       descriptor.resultType.requiresLinearOwnership {
                        live.insert(result)
                    }
                case let .nativeApply(result, importID, arguments):
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: shell.imports[importID]?.parameterConventions
                            ?? Array(repeating: .owned, count: arguments.count),
                        live: &live,
                        function: function,
                        fail: fail
                    )
                    if let result,
                       let type = shell.imports[importID]?.resultType,
                       type.requiresLinearOwnership {
                        live.insert(result)
                    }
                case .makeClosure:
                    // Captures are copied into a VM-managed closure context.
                    // Type validation rejects addresses and noncopyable values.
                    break
                case let .closureApply(result, closure, arguments):
                    let signature: Bytecode.ClosureSignature? = if case let .closure(value)
                        = function.type(of: closure) { value } else { nil }
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: signature?.parameterConventions
                            ?? Array(repeating: .owned, count: arguments.count),
                        live: &live,
                        function: function,
                        fail: fail
                    )
                    if let result,
                       signature?.result.requiresLinearOwnership == true {
                        live.insert(result)
                    }
                case let .closureTryApply(
                    closure,
                    arguments,
                    normalTarget,
                    errorTarget
                ):
                    let signature: Bytecode.ClosureSignature? = if case let .closure(value)
                        = function.type(of: closure) { value } else { nil }
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: signature?.parameterConventions
                            ?? Array(repeating: .owned, count: arguments.count),
                        live: &live,
                        function: function,
                        fail: fail
                    )
                    try forward(live, to: normalTarget)
                    try forward(live, to: errorTarget)
                case let .tryApply(callee, arguments, normalTarget, errorTarget):
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: functions[callee]?.parameterConventions
                            ?? Array(repeating: .owned, count: arguments.count),
                        live: &live,
                        function: function,
                        fail: fail
                    )
                    try forward(live, to: normalTarget)
                    try forward(live, to: errorTarget)
                case let .entryTryApply(entry, arguments, normalTarget, errorTarget):
                    guard let descriptor = shell.entries[entry] else {
                        throw fail("unknown Shell entry \(entry)")
                    }
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: descriptor.parameterConventions,
                        live: &live,
                        function: function,
                        fail: fail
                    )
                    try forward(live, to: normalTarget)
                    try forward(live, to: errorTarget)
                case let .nativeTryApply(importID, arguments, normalTarget, errorTarget):
                    try consumeOwnedCallArguments(
                        arguments,
                        conventions: shell.imports[importID]?.parameterConventions
                            ?? Array(repeating: .owned, count: arguments.count),
                        live: &live,
                        function: function,
                        fail: fail
                    )
                    try forward(live, to: normalTarget)
                    try forward(live, to: errorTarget)
                case let .branch(target, arguments):
                    try consumeForwarded(
                        arguments,
                        target: target,
                        live: &live,
                        function: function,
                        blocks: blocks,
                        fail: fail
                    )
                    try forward(live, to: target)
                case let .conditionalBranch(_, trueTarget, trueArguments, falseTarget, falseArguments):
                    var trueLive = live
                    var falseLive = live
                    try consumeForwarded(
                        trueArguments,
                        target: trueTarget,
                        live: &trueLive,
                        function: function,
                        blocks: blocks,
                        fail: fail
                    )
                    try consumeForwarded(
                        falseArguments,
                        target: falseTarget,
                        live: &falseLive,
                        function: function,
                        blocks: blocks,
                        fail: fail
                    )
                    try forward(trueLive, to: trueTarget)
                    try forward(falseLive, to: falseTarget)
                case let .returnValue(result):
                    if let result,
                       function.type(of: result)?.requiresLinearOwnership == true {
                        guard live.remove(result) != nil else { throw fail("return consumes a non-live value") }
                    }
                    guard live.isEmpty else { throw fail("owned values remain live at return") }
                case let .throwError(error):
                    if function.type(of: error)?.requiresLinearOwnership == true,
                       live.remove(error) == nil {
                        throw fail("throw_error consumes a non-live error payload")
                    }
                    guard live.isEmpty else {
                        throw fail("owned values remain live at throw")
                    }
                case .sourceFailure, .trap:
                    live.removeAll()
                case .constantInteger, .constantBool, .constantFloat, .checkedBinary,
                     .floatingBinary, .floatingUnary, .floatingPredicate,
                     .floatingBinaryPredicate, .floatingTernary,
                     .floatingIntegerProperty, .integerUnary,
                     .integerFullWidthMultiply, .integerFullWidthDivide,
                     .scalarBitCast, .integerConvert,
                     .floatingConvert,
                     .booleanBinary, .stringConcat, .stringCount, .stringIsEmpty,
                     .stringPredicate, .stringTransform, .stringCharacters,
                     .stringJoin, .scalarFromString, .integerToString,
                     .stringify,
                     .arrayCount, .arrayIsEmpty, .arrayIndexBase,
                     .arraySearch,
                     .dictionaryCount, .dictionaryIsEmpty,
                     .setCount, .setIsEmpty, .setContains, .setRelation,
                     .compare:
                    break
                }
            }

            for edge in outgoing {
                if let existing = incoming[edge.target] {
                    guard existing == edge.live else {
                        throw Verification.Error.invalidBlock(
                            function: function.id,
                            block: edge.target,
                            reason: "incoming owned-value states disagree"
                        )
                    }
                } else {
                    incoming[edge.target] = edge.live
                    worklist.append(edge.target)
                }
            }
        }
    }

    private func ownershipState(
        _ live: Set<Bytecode.Register>,
        entering target: Bytecode.BlockID,
        function: Bytecode.Function,
        blocks: [Bytecode.BlockID: Bytecode.Block]
    ) throws -> Set<Bytecode.Register> {
        guard let targetBlock = blocks[target] else {
            throw Verification.Error.invalidFunction(
                function: function.id,
                reason: "ownership dataflow references an unknown block"
            )
        }
        var result = live
        for (index, parameter) in targetBlock.parameters.enumerated()
        where function.type(of: parameter)?.requiresLinearOwnership == true {
            if target == function.entryBlock,
               function.parameterConventions[index] != .owned {
                continue
            }
            guard result.insert(parameter).inserted else {
                throw Verification.Error.invalidBlock(
                    function: function.id,
                    block: target,
                    reason: "owned block parameter is already live on entry"
                )
            }
        }
        return result
    }

    private func consumeForwarded(
        _ arguments: [Bytecode.Register],
        target: Bytecode.BlockID,
        live: inout Set<Bytecode.Register>,
        function: Bytecode.Function,
        blocks: [Bytecode.BlockID: Bytecode.Block],
        fail: (String) -> Verification.Error
    ) throws {
        guard let targetBlock = blocks[target] else { return }
        for (index, pair) in zip(arguments, targetBlock.parameters).enumerated() {
            let (argument, parameter) = pair
            guard function.type(of: parameter)?.requiresLinearOwnership == true else {
                continue
            }
            if target == function.entryBlock,
               function.parameterConventions[index] != .owned {
                continue
            }
            guard live.remove(argument) != nil else { throw fail("branch forwards a consumed owned value") }
        }
    }

    /// The callee signature owns the call convention. Owned linear arguments
    /// transfer into the callee; borrowed arguments remain live in the caller
    /// and are constrained separately by the verifier's borrow rules.
    private func consumeOwnedCallArguments(
        _ arguments: [Bytecode.Register],
        conventions: [Bytecode.ParameterConvention],
        live: inout Set<Bytecode.Register>,
        function: Bytecode.Function,
        fail: (String) -> Verification.Error
    ) throws {
        for (argument, convention) in zip(arguments, conventions)
        where convention == .owned
            && function.type(of: argument)?.requiresLinearOwnership == true {
            guard live.remove(argument) != nil else {
                throw fail("call consumes a non-live owned argument")
            }
        }
    }

    private enum AddressRoot: Hashable {
        case stack(Bytecode.StackSlot)
        case parameter(Bytecode.Register)
        case object(Bytecode.Register)
    }

    private enum AddressScope: Hashable {
        case parameter(Bytecode.Register)
        case local(Bytecode.Register)
    }

    private struct AddressProvenance: Hashable {
        var root: AddressRoot
        var path: [UInt32]
        var scope: AddressScope?

        func overlaps(_ other: Self) -> Bool {
            guard root == other.root else { return false }
            let shared = min(path.count, other.path.count)
            return Array(path.prefix(shared)) == Array(other.path.prefix(shared))
        }
    }

    private struct ActiveAddressAccess: Hashable {
        var provenance: AddressProvenance
        var kind: Bytecode.AccessKind
    }

    private func addressProvenance(
        function: Bytecode.Function
    ) throws -> [Bytecode.Register: AddressProvenance] {
        var definitions: [Bytecode.Register: Bytecode.Instruction] = [:]
        for block in function.blocks {
            for instruction in block.instructions {
                for result in instruction.resultRegisters {
                    definitions[result] = instruction
                }
            }
        }
        let inoutParameters = Dictionary(uniqueKeysWithValues: zip(
            function.parameterRegisters,
            function.parameterConventions
        ).compactMap { register, convention -> (Bytecode.Register, AddressProvenance)? in
            guard convention == .inout else { return nil }
            return (
                register,
                .init(root: .parameter(register), path: [], scope: .parameter(register))
            )
        })
        var result = inoutParameters
        var visiting = Set<Bytecode.Register>()

        func resolve(_ register: Bytecode.Register) throws -> AddressProvenance {
            if let known = result[register] { return known }
            guard visiting.insert(register).inserted else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "address provenance is recursive"
                )
            }
            defer { visiting.remove(register) }
            guard let instruction = definitions[register] else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "address register \(register) has no supported origin"
                )
            }
            let provenance: AddressProvenance
            switch instruction {
            case let .stackAddress(_, slot):
                provenance = .init(root: .stack(slot), path: [], scope: nil)
            case let .projectAggregateAddress(_, base, fieldIndex):
                var base = try resolve(base)
                base.path.append(fieldIndex)
                provenance = base
            case let .projectObjectAddress(_, object, fieldIndex):
                provenance = .init(
                    root: .object(object),
                    path: [fieldIndex],
                    scope: nil
                )
            case let .beginAccess(result, address, _):
                var base = try resolve(address)
                guard base.scope == nil else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "begin_access cannot nest an already-scoped address"
                    )
                }
                base.scope = .local(result)
                provenance = base
            default:
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "address register \(register) is defined by an unsupported instruction"
                )
            }
            result[register] = provenance
            return provenance
        }

        for register in function.registerTypes.indices.compactMap({ index -> Bytecode.Register? in
            guard case .address = function.registerTypes[index],
                  let raw = UInt32(exactly: index)
            else { return nil }
            return .init(rawValue: raw)
        }) {
            _ = try resolve(register)
        }
        return result
    }

    /// Tracks access scopes across the CFG. Canonical SIL may keep a modify
    /// access open across an overflow check, so every incoming edge must carry
    /// one identical active-scope set. Terminal traps may abandon scopes;
    /// ordinary returns and throws must close them explicitly.
    private func verifyAddressLifecycle(
        function: Bytecode.Function,
        functions: [Bytecode.FunctionID: Bytecode.Function],
        borrowedMutableCells: BorrowedMutableCellFacts
    ) throws {
        guard function.registerTypes.contains(where: {
            if case .address = $0 { return true }
            return false
        }) else { return }
        let provenance = try addressProvenance(function: function)
        let blocks = Dictionary(uniqueKeysWithValues: function.blocks.map { ($0.id, $0) })
        var incoming: [Bytecode.BlockID: [Bytecode.Register: ActiveAddressAccess]] = [
            function.entryBlock: [:],
        ]
        var pending = [function.entryBlock]
        var processed = Set<Bytecode.BlockID>()

        while !pending.isEmpty {
            let blockID = pending.removeFirst()
            guard processed.insert(blockID).inserted,
                  let block = blocks[blockID],
                  var active = incoming[blockID]
            else { continue }
            for (offset, instruction) in block.instructions.enumerated() {
                func fail(_ reason: String) -> Verification.Error {
                    .invalidInstruction(
                        function: function.id,
                        block: block.id,
                        offset: offset,
                        reason: reason
                    )
                }
                func checked(_ register: Bytecode.Register) throws -> AddressProvenance {
                    guard let value = provenance[register] else {
                        throw fail("address operand has no verified provenance")
                    }
                    return value
                }
                func requireScoped(
                    _ register: Bytecode.Register,
                    modify: Bool = false
                ) throws -> AddressProvenance {
                    let value = try checked(register)
                    guard let scope = value.scope else {
                        throw fail("address operation requires an active access scope")
                    }
                    if case let .local(scopeRegister) = scope {
                        guard let access = active[scopeRegister] else {
                            throw fail("address access scope is not active on this path")
                        }
                        if modify, access.kind != .modify {
                            throw fail("write requires a modify access")
                        }
                    }
                    return value
                }
                func verifyCallAddresses(
                    arguments: [Bytecode.Register],
                    conventions: [Bytecode.ParameterConvention]
                ) throws {
                    guard arguments.count == conventions.count else {
                        throw fail("call address convention count mismatch")
                    }
                    var inoutValues: [AddressProvenance] = []
                    for (argument, convention) in zip(
                        arguments,
                        conventions
                    ) {
                        if convention == .inout {
                            inoutValues.append(
                                try requireScoped(argument, modify: true)
                            )
                        } else if case .address = function.type(of: argument) {
                            throw fail(
                                "address argument requires an inout callee parameter"
                            )
                        }
                    }
                    for left in inoutValues.indices {
                        for right in inoutValues.indices where right > left {
                            guard !inoutValues[left].overlaps(
                                inoutValues[right]
                            ) else {
                                throw fail(
                                    "call has overlapping inout arguments"
                                )
                            }
                        }
                    }
                }

                var borrowedSources = Set<Bytecode.Register>()
                for operand in instruction.operandRegisters {
                    if let address = borrowedMutableCells
                        .sourceAddressByCell[operand] {
                        borrowedSources.insert(address)
                    }
                    borrowedSources.formUnion(
                        borrowedMutableCells.sourceAddressesByClosure[operand]
                            ?? []
                    )
                }
                for address in borrowedSources {
                    _ = try requireScoped(address, modify: true)
                }

                switch instruction {
                case let .beginAccess(result, address, kind):
                    let base = try checked(address)
                    guard base.scope == nil else {
                        throw fail("begin_access cannot nest an active address")
                    }
                    guard active.values.allSatisfy({ existing in
                        !base.overlaps(existing.provenance)
                            || (kind == .read && existing.kind == .read)
                    }) else {
                        throw fail("begin_access violates exclusive access")
                    }
                    guard let resultProvenance = provenance[result] else {
                        throw fail("begin_access result has no verified provenance")
                    }
                    active[result] = .init(provenance: resultProvenance, kind: kind)
                case let .endAccess(address):
                    guard case let .local(scope)? = try checked(address).scope,
                          scope == address,
                          active.removeValue(forKey: scope) != nil
                    else {
                        throw fail("end_access must close its matching begin_access result")
                    }
                case let .loadAddress(_, address, mode):
                    let source = try requireScoped(
                        address,
                        modify: mode == .take
                    )
                    if mode == .take,
                       case .stack = source.root {
                        break
                    } else if mode == .take {
                        throw fail(
                            "load_address.take requires frame-owned stack storage"
                        )
                    }
                case let .borrowMutableCell(_, address):
                    _ = try requireScoped(address, modify: true)
                case let .storeAddress(address, _, mode):
                    let destination = try requireScoped(address, modify: true)
                    if mode == .initialize {
                        switch destination.root {
                        case .object, .stack:
                            break
                        case .parameter:
                            throw fail(
                                "initialize store cannot target caller-owned inout storage"
                            )
                        }
                    }
                case let .destroyAddress(address),
                     let .destroyAddressIfInitialized(address):
                    let destination = try requireScoped(address, modify: true)
                    guard case .stack = destination.root else {
                        throw fail(
                            "destroy_address requires frame-owned stack storage"
                        )
                    }
                case let .projectAggregateAddress(_, base, _):
                    let baseProvenance = try checked(base)
                    if baseProvenance.scope != nil {
                        _ = try requireScoped(base)
                    }
                case .projectObjectAddress:
                    break
                case let .apply(_, calleeID, arguments):
                    guard let callee = functions[calleeID] else { break }
                    try verifyCallAddresses(
                        arguments: arguments,
                        conventions: callee.parameterConventions
                    )
                case let .tryApply(calleeID, arguments, _, _):
                    guard let callee = functions[calleeID] else { break }
                    try verifyCallAddresses(
                        arguments: arguments,
                        conventions: callee.parameterConventions
                    )
                case let .closureApply(_, closure, arguments),
                     let .closureTryApply(closure, arguments, _, _):
                    guard case let .closure(signature)? = function.type(
                        of: closure
                    ) else { break }
                    try verifyCallAddresses(
                        arguments: arguments,
                        conventions: signature.parameterConventions
                    )
                case let .storeStack(slot, _, _), let .loadStack(_, slot, _),
                     let .destroyStack(slot):
                    let root = AddressProvenance(root: .stack(slot), path: [], scope: nil)
                    guard active.values.allSatisfy({ !$0.provenance.overlaps(root) }) else {
                        throw fail("direct stack access overlaps an active address access")
                    }
                case let .destroyStackIfInitialized(slot):
                    let root = AddressProvenance(
                        root: .stack(slot),
                        path: [],
                        scope: nil
                    )
                    guard active.values.allSatisfy({
                        !$0.provenance.overlaps(root)
                            || ($0.kind == .modify
                                && $0.provenance.root == root.root
                                && $0.provenance.path.isEmpty)
                    }) else {
                        throw fail(
                            "conditional stack destroy requires a root modify access"
                        )
                    }
                case .entryApply, .nativeApply, .entryTryApply, .nativeTryApply:
                    for operand in instruction.operandRegisters
                    where function.type(of: operand).map({ type in
                        if case .address = type { return true }
                        return false
                    }) == true {
                        throw fail("address values cannot cross Shell or NativeImport boundaries")
                    }
                default:
                    for operand in instruction.operandRegisters
                    where function.type(of: operand).map({ type in
                        if case .address = type { return true }
                        return false
                    }) == true {
                        throw fail("instruction cannot consume or escape an address value")
                    }
                }
            }

            let targets = block.instructions.last.map(successors) ?? []
            if targets.isEmpty {
                let abandonsScopes: Bool = switch block.instructions.last {
                case .sourceFailure?, .trap?: true
                default: false
                }
                guard active.isEmpty || abandonsScopes else {
                    throw Verification.Error.invalidBlock(
                        function: function.id,
                        block: block.id,
                        reason: "active begin_access scope escapes a non-trapping exit"
                    )
                }
                continue
            }
            for target in targets {
                if let existing = incoming[target] {
                    guard existing == active else {
                        throw Verification.Error.invalidBlock(
                            function: function.id,
                            block: target,
                            reason: "incoming edges disagree on active begin_access scopes"
                        )
                    }
                } else {
                    incoming[target] = active
                    pending.append(target)
                }
            }
        }
    }

    private struct LeafInitializationState: Equatable {
        var definitelyInitialized: Set<[UInt32]>
        var possiblyInitialized: Set<[UInt32]>

        static let empty = Self(
            definitelyInitialized: [],
            possiblyInitialized: []
        )

        mutating func markInitialized(_ leaves: Set<[UInt32]>) {
            definitelyInitialized.formUnion(leaves)
            possiblyInitialized.formUnion(leaves)
        }

        mutating func markUninitialized(_ leaves: Set<[UInt32]>) {
            definitelyInitialized.subtract(leaves)
            possiblyInitialized.subtract(leaves)
        }

        func merged(with other: Self) -> Self {
            .init(
                definitelyInitialized: definitelyInitialized.intersection(
                    other.definitelyInitialized
                ),
                possiblyInitialized: possiblyInitialized.union(
                    other.possiblyInitialized
                )
            )
        }
    }

    private func storageLeafPaths(
        of type: Bytecode.ValueType,
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition],
        function: Bytecode.FunctionID,
        path: [UInt32] = [],
        depth: Int = 0,
        visiting: Set<Bytecode.LocalTypeKey> = []
    ) throws -> Set<[UInt32]> {
        guard depth <= 32 else {
            throw Verification.Error.invalidFunction(
                function: function,
                reason: "storage aggregate nesting exceeds 32 levels"
            )
        }
        let children: [Bytecode.ValueType]?
        var nextVisiting = visiting
        switch type {
        case let .tuple(elements):
            children = elements
        case let .local(key):
            guard !visiting.contains(key),
                  let definition = localTypes[key]
            else {
                throw Verification.Error.invalidFunction(
                    function: function,
                    reason: "storage references an invalid local value type"
                )
            }
            switch definition.kind {
            case let .structure(fields):
                nextVisiting.insert(key)
                children = fields.map(\.type)
            case .enumeration, .class:
                children = nil
            }
        default:
            children = nil
        }
        guard let children, !children.isEmpty else { return [path] }

        var result = Set<[UInt32]>()
        for (index, child) in children.enumerated() {
            guard let field = UInt32(exactly: index) else {
                throw Verification.Error.invalidFunction(
                    function: function,
                    reason: "storage aggregate field count exceeds UInt32"
                )
            }
            result.formUnion(
                try storageLeafPaths(
                    of: child,
                    localTypes: localTypes,
                    function: function,
                    path: path + [field],
                    depth: depth + 1,
                    visiting: nextVisiting
                )
            )
        }
        return result
    }

    /// Proves field-sensitive initialization for shared closure cells. A cell
    /// identity may be projected before its payload is complete, which is how
    /// Swift initializes tuples and local structs field-by-field. Reads,
    /// captures, calls, and assignments still require every leaf beneath the
    /// referenced projection to be initialized on every incoming edge.
    private func verifyMutableCellLifecycle(
        function: Bytecode.Function,
        blocks: [Bytecode.BlockID: Bytecode.Block],
        dominators: [Bytecode.BlockID: Set<Bytecode.BlockID>],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) throws {
        let cellRegisters = Set(
            function.registerTypes.indices.compactMap { index -> Bytecode.Register? in
                guard case .mutableCell = function.registerTypes[index],
                      let raw = UInt32(exactly: index)
                else { return nil }
                return .init(rawValue: raw)
            }
        )
        guard !cellRegisters.isEmpty else { return }
        let predecessors = try buildPredecessors(
            function: function,
            blocks: blocks
        )

        struct Provenance: Equatable {
            var root: Bytecode.Register
            var path: [UInt32]
        }

        var definingInstruction: [Bytecode.Register: Bytecode.Instruction] = [:]
        for block in function.blocks {
            for instruction in block.instructions {
                for result in instruction.resultRegisters
                where cellRegisters.contains(result) {
                    definingInstruction[result] = instruction
                }
            }
        }
        let parameters = Set(
            function.parameterRegisters.filter(cellRegisters.contains)
        )
        var provenanceCache: [Bytecode.Register: Provenance] = [:]
        var resolving = Set<Bytecode.Register>()

        func provenance(
            of register: Bytecode.Register
        ) throws -> Provenance {
            if let cached = provenanceCache[register] { return cached }
            guard resolving.insert(register).inserted else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "mutable-cell provenance contains a cycle"
                )
            }
            defer { resolving.remove(register) }

            let result: Provenance
            if parameters.contains(register) {
                result = .init(root: register, path: [])
            } else {
                guard let instruction = definingInstruction[register] else {
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "mutable-cell register has no supported definition"
                    )
                }
                switch instruction {
                case let .makeMutableCell(defined, _) where defined == register:
                    result = .init(root: register, path: [])
                case let .borrowMutableCell(defined, _)
                    where defined == register:
                    result = .init(root: register, path: [])
                case let .copyValue(defined, source) where defined == register:
                    result = try provenance(of: source)
                case let .moveValue(defined, source) where defined == register:
                    result = try provenance(of: source)
                case let .projectMutableCell(defined, cell, fieldIndex)
                    where defined == register:
                    let parent = try provenance(of: cell)
                    result = .init(
                        root: parent.root,
                        path: parent.path + [fieldIndex]
                    )
                default:
                    throw Verification.Error.invalidFunction(
                        function: function.id,
                        reason: "mutable-cell register has an invalid defining instruction"
                    )
                }
            }
            provenanceCache[register] = result
            return result
        }

        var leavesByRoot: [Bytecode.Register: Set<[UInt32]>] = [:]
        for register in cellRegisters {
            let origin = try provenance(of: register)
            guard leavesByRoot[origin.root] == nil,
                  case let .mutableCell(pointee) = function.type(of: origin.root)
            else { continue }
            leavesByRoot[origin.root] = try storageLeafPaths(
                of: pointee,
                localTypes: localTypes,
                function: function.id
            )
        }

        func targetLeaves(
            for register: Bytecode.Register
        ) throws -> (root: Bytecode.Register, leaves: Set<[UInt32]>) {
            let origin = try provenance(of: register)
            let leaves = Set((leavesByRoot[origin.root] ?? []).filter {
                $0.starts(with: origin.path)
            })
            guard !leaves.isEmpty else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "mutable-cell projection has no valid aggregate field"
                )
            }
            return (origin.root, leaves)
        }

        var definitionBlock: [Bytecode.Register: Bytecode.BlockID] = [:]
        for block in function.blocks {
            for parameter in block.parameters where cellRegisters.contains(parameter) {
                definitionBlock[parameter] = block.id
            }
            for instruction in block.instructions {
                for result in instruction.resultRegisters
                where cellRegisters.contains(result) {
                    definitionBlock[result] = block.id
                }
            }
        }

        typealias State = [
            Bytecode.Register: LeafInitializationState
        ]
        var parameterState: State = [:]
        for parameter in parameters {
            let target = try targetLeaves(for: parameter)
            parameterState[target.root, default: .empty]
                .markInitialized(target.leaves)
        }

        func merge(_ lhs: State, _ rhs: State) -> State {
            var result: State = [:]
            for root in Set(lhs.keys).union(rhs.keys) {
                result[root] = (lhs[root] ?? .empty).merged(
                    with: rhs[root] ?? .empty
                )
            }
            return result
        }

        var incoming: [Bytecode.BlockID: State] = [
            function.entryBlock: parameterState,
        ]
        var outgoing: [Bytecode.BlockID: State] = [:]
        var worklist = [function.entryBlock]
        var queued: Set<Bytecode.BlockID> = [function.entryBlock]

        while let blockID = worklist.popLast() {
            queued.remove(blockID)
            guard let block = blocks[blockID],
                  var initialized = incoming[blockID]
            else { continue }
            for (offset, instruction) in block.instructions.enumerated() {
                func fail(_ reason: String) -> Verification.Error {
                    .invalidInstruction(
                        function: function.id,
                        block: block.id,
                        offset: offset,
                        reason: reason
                    )
                }
                func requireInitialized(_ cell: Bytecode.Register) throws {
                    let target = try targetLeaves(for: cell)
                    guard target.leaves.isSubset(
                        of: initialized[target.root]?
                            .definitelyInitialized ?? []
                    ) else {
                        throw fail("mutable cell is used before initialization")
                    }
                }

                switch instruction {
                case let .makeMutableCell(result, initialValue):
                    let target = try targetLeaves(for: result)
                    initialized[target.root] = initialValue == nil
                        ? .empty
                        : .init(
                            definitelyInitialized: target.leaves,
                            possiblyInitialized: target.leaves
                        )
                    if let initialValue,
                       cellRegisters.contains(initialValue) {
                        try requireInitialized(initialValue)
                    }
                case let .borrowMutableCell(result, _):
                    let target = try targetLeaves(for: result)
                    initialized[target.root] = .init(
                        definitelyInitialized: target.leaves,
                        possiblyInitialized: target.leaves
                    )
                case let .copyValue(result, _)
                    where cellRegisters.contains(result):
                    break
                case let .moveValue(result, _)
                    where cellRegisters.contains(result):
                    break
                case .projectMutableCell:
                    break
                case let .loadMutableCell(_, cell):
                    try requireInitialized(cell)
                case let .storeMutableCell(cell, source, mode):
                    if cellRegisters.contains(source) {
                        try requireInitialized(source)
                    }
                    let target = try targetLeaves(for: cell)
                    let current = initialized[target.root] ?? .empty
                    switch mode {
                    case .initialize:
                        guard target.leaves.isDisjoint(
                            with: current.possiblyInitialized
                        ) else {
                            throw fail(
                                "store_mutable_cell.initialize targets an initialized cell"
                            )
                        }
                    case .assign:
                        try requireInitialized(cell)
                    case .replace:
                        break
                    }
                    initialized[target.root, default: .empty]
                        .markInitialized(target.leaves)
                case let .destroyValue(register)
                    where cellRegisters.contains(register):
                    break
                default:
                    for operand in instruction.operandRegisters
                    where cellRegisters.contains(operand) {
                        try requireInitialized(operand)
                    }
                }
            }

            guard let terminator = block.instructions.last else { continue }
            guard outgoing[blockID] != initialized else { continue }
            outgoing[blockID] = initialized
            for successor in successors(of: terminator) {
                let edgeStates = (predecessors[successor] ?? []).compactMap {
                    predecessor -> State? in
                    outgoing[predecessor].map { state in
                        state.filter { root, _ in
                            guard let definition = definitionBlock[root] else {
                                return false
                            }
                            return definition == successor
                                || dominators[successor]?.contains(definition)
                                    == true
                        }
                    }
                }
                guard var next = edgeStates.first else { continue }
                for state in edgeStates.dropFirst() {
                    next = merge(next, state)
                }
                guard incoming[successor] != next else { continue }
                incoming[successor] = next
                if queued.insert(successor).inserted {
                    worklist.append(successor)
                }
            }
        }
    }

    /// Stack slots never escape an HLBC frame. CFG joins retain the intersection
    /// of definitely initialized leaves and the union of possibly initialized
    /// leaves. Only explicit replace/conditional-destroy operations may resolve
    /// the latter; reads and assignments still require definite initialization.
    private func verifyStackLifecycle(
        function: Bytecode.Function,
        blocks: [Bytecode.BlockID: Bytecode.Block],
        localTypes: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition]
    ) throws {
        guard !function.stackSlotTypes.isEmpty else { return }
        let addresses = try addressProvenance(function: function)
        let predecessors = try buildPredecessors(
            function: function,
            blocks: blocks
        )

        var leavesBySlot: [Bytecode.StackSlot: Set<[UInt32]>] = [:]
        for (index, type) in function.stackSlotTypes.enumerated() {
            guard let raw = UInt32(exactly: index) else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "stack-slot table exceeds UInt32"
                )
            }
            leavesBySlot[.init(rawValue: raw)] = try storageLeafPaths(
                of: type,
                localTypes: localTypes,
                function: function.id
            )
        }
        typealias State = [
            Bytecode.StackSlot: LeafInitializationState
        ]
        let emptyState = leavesBySlot.mapValues { _ in
            LeafInitializationState.empty
        }

        func merge(_ lhs: State, _ rhs: State) -> State {
            var result: State = [:]
            for slot in Set(lhs.keys).union(rhs.keys) {
                result[slot] = (lhs[slot] ?? .empty).merged(
                    with: rhs[slot] ?? .empty
                )
            }
            return result
        }

        var incoming: [Bytecode.BlockID: State] = [
            function.entryBlock: emptyState,
        ]
        var outgoing: [Bytecode.BlockID: State] = [:]
        var worklist = [function.entryBlock]
        var queued: Set<Bytecode.BlockID> = [function.entryBlock]

        while let blockID = worklist.popLast() {
            queued.remove(blockID)
            guard let block = blocks[blockID],
                  var initialized = incoming[blockID]
            else {
                throw Verification.Error.invalidFunction(
                    function: function.id,
                    reason: "stack-state analysis reached an unknown block"
                )
            }
            for (offset, instruction) in block.instructions.enumerated() {
                func fail(_ reason: String) -> Verification.Error {
                    .invalidInstruction(
                        function: function.id,
                        block: block.id,
                        offset: offset,
                        reason: reason
                    )
                }
                func targetLeaves(
                    slot: Bytecode.StackSlot,
                    path: [UInt32] = []
                ) throws -> Set<[UInt32]> {
                    let result = Set((leavesBySlot[slot] ?? []).filter {
                        $0.starts(with: path)
                    })
                    guard !result.isEmpty else {
                        throw fail(
                            "stack address projection has no valid aggregate field"
                        )
                    }
                    return result
                }
                func requireInitialized(
                    slot: Bytecode.StackSlot,
                    path: [UInt32] = []
                ) throws {
                    let target = try targetLeaves(slot: slot, path: path)
                    guard target.isSubset(
                        of: initialized[slot]?.definitelyInitialized ?? []
                    ) else {
                        throw fail(
                            "stack storage \(slot) is used before initialization"
                        )
                    }
                }
                func store(
                    _ target: Set<[UInt32]>,
                    in slot: Bytecode.StackSlot,
                    mode: Bytecode.StackStoreMode,
                    operation: String
                ) throws {
                    let current = initialized[slot] ?? .empty
                    switch mode {
                    case .initialize:
                        guard target.isDisjoint(
                            with: current.possiblyInitialized
                        ) else {
                            throw fail(
                                "\(operation).initialize targets initialized stack storage"
                            )
                        }
                    case .assign:
                        guard target.isSubset(
                            of: current.definitelyInitialized
                        ) else {
                            throw fail(
                                "\(operation).assign targets uninitialized stack storage"
                            )
                        }
                    case .replace:
                        break
                    }
                    initialized[slot, default: .empty]
                        .markInitialized(target)
                }

                switch instruction {
                case let .storeStack(slot, _, mode):
                    try store(
                        targetLeaves(slot: slot),
                        in: slot,
                        mode: mode,
                        operation: "store_stack"
                    )
                case let .loadStack(_, slot, mode):
                    let target = try targetLeaves(slot: slot)
                    try requireInitialized(slot: slot)
                    if mode == .take {
                        initialized[slot, default: .empty]
                            .markUninitialized(target)
                    }
                case let .destroyStack(slot):
                    let target = try targetLeaves(slot: slot)
                    guard target.isSubset(
                        of: initialized[slot]?.definitelyInitialized ?? []
                    ) else {
                        throw fail(
                            "destroy_stack targets uninitialized stack storage"
                        )
                    }
                    initialized[slot, default: .empty]
                        .markUninitialized(target)
                case let .destroyStackIfInitialized(slot):
                    initialized[slot, default: .empty].markUninitialized(
                        try targetLeaves(slot: slot)
                    )
                case let .loadAddress(_, address, mode):
                    if let provenance = addresses[address],
                       case let .stack(slot) = provenance.root {
                        try requireInitialized(
                            slot: slot,
                            path: provenance.path
                        )
                        if mode == .take {
                            initialized[slot, default: .empty]
                                .markUninitialized(
                                    try targetLeaves(
                                        slot: slot,
                                        path: provenance.path
                                    )
                                )
                        }
                    }
                case let .storeAddress(address, _, mode):
                    if let provenance = addresses[address],
                       case let .stack(slot) = provenance.root {
                        try store(
                            targetLeaves(
                                slot: slot,
                                path: provenance.path
                            ),
                            in: slot,
                            mode: mode,
                            operation: "store_address"
                        )
                    }
                case let .destroyAddress(address):
                    if let provenance = addresses[address],
                       case let .stack(slot) = provenance.root {
                        let target = try targetLeaves(
                            slot: slot,
                            path: provenance.path
                        )
                        guard target.isSubset(
                            of: initialized[slot]?.definitelyInitialized ?? []
                        ) else {
                            throw fail(
                                "destroy_address targets uninitialized stack storage"
                            )
                        }
                        initialized[slot, default: .empty]
                            .markUninitialized(target)
                    }
                case let .destroyAddressIfInitialized(address):
                    if let provenance = addresses[address],
                       case let .stack(slot) = provenance.root {
                        initialized[slot, default: .empty]
                            .markUninitialized(
                                try targetLeaves(
                                    slot: slot,
                                    path: provenance.path
                                )
                            )
                    }
                case let .collectionNext(_, _, slot, _):
                    try requireInitialized(slot: slot)
                case let .progressionNext(_, slot, _, _, _):
                    try requireInitialized(slot: slot)
                case .returnValue, .throwError:
                    guard initialized.values.allSatisfy({
                        $0.possiblyInitialized.isEmpty
                    }) else {
                        throw fail("initialized stack slots remain at function exit")
                    }
                case .sourceFailure, .trap:
                    // Runtime unwinding releases the entire verified frame.
                    initialized = emptyState
                default:
                    break
                }
            }

            guard let terminator = block.instructions.last else { continue }
            guard outgoing[blockID] != initialized else { continue }
            outgoing[blockID] = initialized
            for successor in successors(of: terminator) {
                let edgeStates = (predecessors[successor] ?? []).compactMap {
                    outgoing[$0]
                }
                guard var next = edgeStates.first else { continue }
                for state in edgeStates.dropFirst() {
                    next = merge(next, state)
                }
                guard incoming[successor] != next else { continue }
                incoming[successor] = next
                if queued.insert(successor).inserted {
                    worklist.append(successor)
                }
            }
        }
    }

    private func requireRegister(
        _ register: Bytecode.Register,
        function: Bytecode.Function,
        block: Bytecode.BlockID,
        offset: Int
    ) throws {
        guard function.type(of: register) != nil else {
            throw Verification.Error.invalidInstruction(
                function: function.id,
                block: block,
                offset: offset,
                reason: "register \(register) is out of range"
            )
        }
    }
}
}
