import HelixBytecode
import HelixCore
import HelixInterface
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Canonical SIL static-target closures")
struct EntryClosure {
    @Test("Partial application binds the suffix of a frozen Shell entry ABI")
    func lowersCapturedEntryClosure() throws {
        let symbol = "$s7Fixture6offsetyS2i_SitF"
        let entry = Core.EntryIndex(rawValue: 7)
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64, .int64],
                parameterConventions: [.owned, .owned],
                resultType: .int64,
                target: .entry(entry)
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4makeyS2icS2iF",
            loweredType: "@convention(thin) (Int) -> "
                + "@owned @callee_guaranteed (Int) -> Int",
            body: """
            bb0(%0 : $Int):
              %1 = function_ref @\(symbol) : $@convention(thin) (Int, Int) -> Int
              %2 = partial_apply [callee_guaranteed] %1(%0) : $@convention(thin) (Int, Int) -> Int
              return %2
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "make",
            directCalls: directCalls
        )
        let parameter = try #require(lowered.parameterRegisters.first)
        let construction = try #require(
            lowered.blocks.flatMap(\.instructions).first { instruction in
                if case .makeClosure(_, .entry, _, _) = instruction {
                    return true
                }
                return false
            }
        )

        guard case let .makeClosure(
            result,
            .entry(targetEntry),
            captures,
            lifetime
        ) = construction else {
            Issue.record("expected a frozen-entry closure construction")
            return
        }
        #expect(targetEntry == entry)
        #expect(captures == [parameter])
        #expect(lifetime == .invocation)
        #expect(
            lowered.registerTypes[Int(result.rawValue)] == .closure(
                .init(
                    parameters: [.int64],
                    parameterConventions: [.owned],
                    result: .int64
                )
            )
        )
        let borrowedEntryBindings = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64, .int64],
                parameterConventions: [.owned, .borrowed],
                resultType: .int64,
                target: .entry(entry)
            ),
        ])
        let entryConventions = try borrowedEntryBindings
            .entryParameterConventions(referencedBy: [lowered])
        let capabilities = CompilerCapabilities.infer(
            for: [lowered],
            entryParameterConventions: entryConventions
        )
        #expect(entryConventions == [entry: [.owned, .borrowed]])
        #expect(capabilities.contains(.borrowCallsV1))
    }

    @Test("Imported free-function references form ordinary Swift closures")
    func lowersNativeImportFunctionReference() throws {
        let symbol = "$s6Darwin3sinyS2dF"
        let requirement = try nativeRequirement(
            id: 11,
            parameters: ["Swift.Double"],
            result: "Swift.Double",
            canonicalCallee: "Darwin.sin(_:)"
        )
        let float64 = Bytecode.ValueType.float(bitWidth: 64)
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [float64],
                resultType: float64,
                target: .nativeImport(requirement)
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7factoryS2dcSgyF",
            loweredType: "@convention(thin) () -> "
                + "@owned @callee_guaranteed (Double) -> Double",
            body: """
            bb0:
              %0 = function_ref @\(symbol) : $@convention(thin) (Double) -> Double
              %1 = thin_to_thick_function %0 to $@callee_guaranteed (Double) -> Double
              return %1
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "factory",
            directCalls: directCalls
        )
        let construction = try #require(
            lowered.blocks.flatMap(\.instructions).first { instruction in
                if case .makeClosure(_, .nativeImport, _, _) = instruction {
                    return true
                }
                return false
            }
        )
        guard case let .makeClosure(
            result,
            .nativeImport(importID),
            captures,
            lifetime
        ) = construction else {
            Issue.record("expected a NativeImport closure construction")
            return
        }
        #expect(importID == requirement.id)
        #expect(captures.isEmpty)
        #expect(lifetime == .invocation)
        #expect(
            lowered.registerTypes[Int(result.rawValue)] == .closure(
                .init(
                    parameters: [float64],
                    parameterConventions: [.owned],
                    result: float64
                )
            )
        )
        let imports = try directCalls.importRequirements(
            referencedBy: [lowered]
        )
        #expect(imports == [requirement])
        let capabilities = CompilerCapabilities.infer(
            for: [lowered],
            imports: imports
        )
        #expect(capabilities.contains(.closureValuesV1))
        #expect(capabilities.contains(.nativeImportsV1))
    }

    @Test("Partial application binds a NativeImport suffix generically")
    func lowersCapturedNativeImportClosure() throws {
        let symbol = "$s7Fixture6offsetyS2i_SitF"
        let requirement = try nativeRequirement(id: 12)
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64, .int64],
                parameterConventions: [.owned, .owned],
                resultType: .int64,
                target: .nativeImport(requirement)
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4makeyS2icS2iF",
            loweredType: "@convention(thin) (Int) -> "
                + "@owned @callee_guaranteed (Int) -> Int",
            body: """
            bb0(%0 : $Int):
              %1 = function_ref @\(symbol) : $@convention(thin) (Int, Int) -> Int
              %2 = partial_apply [callee_guaranteed] %1(%0) : $@convention(thin) (Int, Int) -> Int
              return %2
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "makeImportedOffset",
            directCalls: directCalls
        )
        let parameter = try #require(lowered.parameterRegisters.first)
        #expect(lowered.blocks.flatMap(\.instructions).contains {
            guard case let .makeClosure(
                _,
                .nativeImport(importID),
                captures,
                .invocation
            ) = $0 else { return false }
            return importID == requirement.id && captures == [parameter]
        })
        #expect(
            try directCalls.importRequirements(referencedBy: [lowered])
                == [requirement]
        )
    }

    @Test("Imported instance-method references bind native receivers")
    func lowersBoundNativeMethodReference() throws {
        let widgetType = Core.TypeID(rawValue: .sha256("Fixture.Widget"))
        let physicalType = "@convention(objc_method) "
            + "(Int, @guaranteed Widget) -> Int"
        let symbol = CanonicalSIL.NativeBridgeSymbols.foreignCall(
            reference: "#Widget.transform!foreign",
            loweredType: physicalType
        )
        let contract = Core.NativeImportContract.bounded(
            kind: .instanceMethod,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let requirement = try nativeRequirement(
            id: 14,
            parameters: ["Swift.Int", "Fixture.Widget"],
            result: "Swift.Int",
            canonicalCallee: "Fixture.Widget.transform(_:)",
            contract: contract
        )
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64, .native(widgetType)],
                resultType: .int64,
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["Widget": widgetType],
                kinds: [widgetType: .reference]
            )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture11bindMethodyS2icSo6WidgetCF",
            loweredType: "@convention(thin) (@guaranteed Widget) -> "
                + "@owned @callee_guaranteed (Int) -> Int",
            body: """
            bb0(%0 : @guaranteed $Widget):
              %1 = objc_method %0, #Widget.transform!foreign : (Widget) -> (Int) -> Int, $\(physicalType)
              %2 = partial_apply [callee_guaranteed] %1(%0) : $\(physicalType)
              return %2
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "bindNativeMethod",
            directCalls: directCalls
        )
        let parameter = try #require(lowered.parameterRegisters.first)
        #expect(lowered.parameterConventions == [.borrowed])
        #expect(lowered.blocks.flatMap(\.instructions).contains {
            guard case let .makeClosure(
                result,
                .nativeImport(importID),
                captures,
                .invocation
            ) = $0 else { return false }
            return importID == requirement.id
                && captures == [parameter]
                && lowered.registerTypes[Int(result.rawValue)] == .closure(
                    .init(
                        parameters: [.int64],
                        parameterConventions: [.owned],
                        result: .int64
                    )
                )
        })
    }

    @Test("Imported initializer references erase static metatypes")
    func lowersNativeInitializerReference() throws {
        let widgetType = Core.TypeID(rawValue: .sha256("Fixture.Widget"))
        let symbol = "$s7Fixture6WidgetC5valueACSi_tcfC"
        let contract = Core.NativeImportContract.bounded(
            kind: .initializer,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let requirement = try nativeRequirement(
            id: 15,
            parameters: ["Swift.Int"],
            result: "Fixture.Widget",
            canonicalCallee: "Fixture.Widget.init(value:)",
            effects: .init(mayAllocate: true),
            contract: contract
        )
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64],
                resultType: .native(widgetType),
                effects: requirement.effects,
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["Widget": widgetType],
                kinds: [widgetType: .reference]
            )
        let physicalType = "@convention(method) "
            + "(Int, @thick Widget.Type) -> @owned Widget"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture17initializerFactorySo6WidgetCSicSgyF",
            loweredType: "@convention(thin) () -> "
                + "@owned @callee_guaranteed (Int) -> @owned Widget",
            body: """
            bb0:
              %0 = metatype $@thick Widget.Type
              %1 = function_ref @\(symbol) : $\(physicalType)
              %2 = partial_apply [callee_guaranteed] %1(%0) : $\(physicalType)
              return %2
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "nativeInitializerFactory",
            directCalls: directCalls
        )
        #expect(lowered.blocks.flatMap(\.instructions).contains {
            guard case let .makeClosure(
                result,
                .nativeImport(importID),
                captures,
                .invocation
            ) = $0 else { return false }
            return importID == requirement.id
                && captures.isEmpty
                && lowered.registerTypes[Int(result.rawValue)] == .closure(
                    .init(
                        parameters: [.int64],
                        parameterConventions: [.owned],
                        result: .native(widgetType)
                    )
                )
        })
    }

    @Test("Call-site argument projections cannot masquerade as function values")
    func rejectsProjectedNativeImportFunctionReference() throws {
        let symbol = "$s7Fixture9defaultedyS2i_SiSgtF"
        let requirement = try nativeRequirement(
            id: 13,
            parameters: ["Swift.Int"]
        )
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64],
                parameterProjection: .init(
                    physicalParameterCount: 2,
                    logicalParameterIndices: [0],
                    defaultArguments: [
                        .optionalNone(physicalParameterIndex: 1),
                    ]
                ),
                resultType: .int64,
                target: .nativeImport(requirement)
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7factoryS2icSgyF",
            loweredType: "@convention(thin) () -> "
                + "@owned @callee_guaranteed (Int) -> Int",
            body: """
            bb0:
              %0 = function_ref @\(symbol) : $@convention(thin) (Int, Optional<Int>) -> Int
              %1 = thin_to_thick_function %0 to $@callee_guaranteed (Int) -> Int
              return %1
            """
        )

        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "projectedNativeFunctionValue",
                directCalls: directCalls
            )
        }
    }

    private func nativeRequirement(
        id: UInt32,
        parameters: [String] = ["Swift.Int", "Swift.Int"],
        result: String = "Swift.Int",
        canonicalCallee: String = "Fixture.offset(_:_:)",
        effects: Core.Effects = .init(),
        contract: Core.NativeImportContract? = nil
    ) throws -> Bytecode.ImportRequirement {
        let resolvedContract = contract ?? .bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: canonicalCallee,
            signature: .init(parameters: parameters, result: result),
            effects: effects,
            contract: resolvedContract
        )
        return .init(
            id: .init(rawValue: id),
            key: try Core.NativeCall.Key.derive(descriptor: descriptor),
            descriptor: descriptor,
            contract: resolvedContract
        )
    }
}
}
