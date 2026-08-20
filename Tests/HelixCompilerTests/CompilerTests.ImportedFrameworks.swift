import HelixBytecode
import HelixCore
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Imported framework SIL lowering")
struct ImportedFrameworks {
    @Test("Ordinary Objective-C methods use their frozen logical NativeImport ABI")
    func lowersOrdinaryForeignMethod() throws {
        let viewType = Core.TypeID(rawValue: .sha256("UIKit.UIView"))
        let loweredType = "@convention(objc_method) (UIView) -> ()"
        let symbol = CanonicalSIL.NativeBridgeSymbols.foreignCall(
            reference: "#UIView.setNeedsLayout!foreign",
            loweredType: loweredType
        )
        let requirement = importRequirement(id: 4)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.native(viewType)],
                resultType: .void,
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["UIView": viewType],
            kinds: [viewType: .reference]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture6updateyySo6UIViewCF",
            loweredType: "@convention(thin) (@guaranteed UIView) -> ()",
            body: """
            bb0(%0 : @guaranteed $UIView):
              %1 = objc_method %0, #UIView.setNeedsLayout!foreign : (UIView) -> () -> (), $\(loweredType)
              %2 = apply %1(%0) : $\(loweredType)
              %3 = tuple ()
              return %3
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.update",
            directCalls: calls
        )
        let invocations = lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> (Core.NativeImportID, [Bytecode.Register])? in
            guard case let .nativeApply(_, id, arguments) = instruction else { return nil }
            return (id, arguments)
        }
        let invocation = try #require(invocations.first)
        #expect(invocations.count == 1)
        #expect(invocation.0 == requirement.id)
        #expect(invocation.1.count == 1)
        let parameter = try #require(lowered.parameterRegisters.first)
        let argument = try #require(invocation.1.first)
        #expect(argument != parameter)
        #expect(lowered.blocks.flatMap(\.instructions).contains { instruction in
            guard case let .copyValue(result, source) = instruction else { return false }
            return result == argument && source == parameter
        })
    }

    @Test("Borrowed linear results acquire ownership at the HLBC return boundary")
    func ownsBorrowedNativeReturn() throws {
        let viewType = Core.TypeID(rawValue: .sha256("UIKit.UIView"))
        let loweredType = "@convention(objc_method) (UIView) -> ()"
        let requirement = importRequirement(id: 27)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.foreignCall(
                    reference: "#UIView.setNeedsLayout!foreign",
                    loweredType: loweredType
                ),
                parameterTypes: [.native(viewType)],
                resultType: .void,
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["UIView": viewType],
            kinds: [viewType: .reference]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture6updateySo6UIViewCAF",
            loweredType: "@convention(thin) (@guaranteed UIView) -> @owned UIView",
            body: """
            bb0(%0 : @guaranteed $UIView):
              %1 = objc_method %0, #UIView.setNeedsLayout!foreign : (UIView) -> () -> (), $\(loweredType)
              %2 = apply %1(%0) : $\(loweredType)
              return %0
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.update",
            directCalls: calls
        )
        let parameter = try #require(lowered.parameterRegisters.first)
        let returned = try #require(lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> Bytecode.Register? in
            guard case let .returnValue(value) = instruction else { return nil }
            return value
        }.first)
        #expect(returned != parameter)
        #expect(lowered.blocks.flatMap(\.instructions).contains { instruction in
            guard case let .copyValue(result, source) = instruction else { return false }
            return result == returned && source == parameter
        })
    }

    @Test("Runtime stack borrows retain one native owner through both try continuations")
    func ownsRuntimeStackBorrowAcrossTryApply() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let callee = Bytecode.FunctionID(rawValue: 1)
        let effects = Core.Effects(mayThrow: true)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: "$s7Fixture7inspectyySo8NSObjectCKF",
                parameterTypes: [.native(objectType)],
                parameterConventions: [.borrowed],
                resultType: .void,
                effects: effects,
                target: .function(callee)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["NSObject": objectType],
            kinds: [objectType: .reference]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture11inspectOnceyySo8NSObjectC_SbtF",
            loweredType: "@convention(thin) (@owned NSObject, Bool) -> ()",
            body: """
            bb0(%0 : @owned $NSObject, %1 : $Bool):
              %2 = alloc_stack $NSObject
              store %0 to [init] %2
              cond_br %1, bb1, bb2
            bb1:
              br bb3
            bb2:
              br bb3
            bb3:
              %3 = function_ref @$s7Fixture7inspectyySo8NSObjectCKF : $@convention(thin) (@in_guaranteed NSObject) -> @error any Error
              try_apply %3(%2) : $@convention(thin) (@in_guaranteed NSObject) -> @error any Error, normal bb4, error bb5
            bb4:
              destroy_addr %2
              dealloc_stack %2
              %4 = tuple ()
              return %4
            bb5(%5 : $any Error):
              destroy_addr %2
              dealloc_stack %2
              %6 = tuple ()
              return %6
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.inspectOnce",
            directCalls: calls
        )
        let invocation = try #require(lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> (Bytecode.Register, Bytecode.BlockID, Bytecode.BlockID)? in
            guard case let .tryApply(id, arguments, normal, error) = instruction,
                  id == callee,
                  let argument = arguments.first,
                  arguments.count == 1
            else { return nil }
            return (argument, normal, error)
        }.first)
        let temporaryOwner = invocation.0
        #expect(
            lowered.registerTypes[Int(temporaryOwner.rawValue)]
                == Bytecode.ValueType.native(objectType)
        )
        #expect(lowered.blocks.flatMap(\.instructions).contains { instruction in
            guard case let .loadAddress(result, _, mode) = instruction else {
                return false
            }
            return result == temporaryOwner && mode == .copy
        })
        for target in [invocation.1, invocation.2] {
            let block = try #require(lowered.blocks.first { $0.id == target })
            guard case let .destroyValue(value) = block.instructions.first else {
                Issue.record("try continuation does not begin by releasing its borrowed owner")
                continue
            }
            #expect(value == temporaryOwner)
        }
    }

    @Test("NSError-backed Objective-C throws use the logical NativeImport ABI")
    func lowersNSErrorBackedThrowingMethod() throws {
        let fixture = try nsErrorFixture()

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: fixture.environment
        ).lower(
            fixture.function,
            displayName: "Fixture.removeItem",
            directCalls: fixture.calls,
            expectedEffects: fixture.effects
        )
        let invocation = try #require(lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> (Core.NativeImportID, [Bytecode.Register], Bytecode.BlockID,
                Bytecode.BlockID)? in
            guard case let .nativeTryApply(id, arguments, normal, error) = instruction
            else { return nil }
            return (id, arguments, normal, error)
        }.first)
        #expect(invocation.0 == fixture.requirement.id)
        let argumentTypes = invocation.1.map {
            lowered.registerTypes[Int($0.rawValue)]
        }
        #expect(argumentTypes == [
            .string,
            .native(fixture.managerType),
        ])
        #expect(invocation.2 == .init(rawValue: 1))
        #expect(invocation.3 == .init(rawValue: 2))
        let errorBlock = try #require(lowered.blocks.first { $0.id == invocation.3 })
        #expect(errorBlock.parameters.count == 1)
        let errorParameter = try #require(errorBlock.parameters.first)
        #expect(lowered.registerTypes[Int(errorParameter.rawValue)] == .string)
        #expect(errorBlock.instructions.contains { instruction in
            guard case let .throwError(error) = instruction else { return false }
            return error == errorParameter
        })
    }

    @Test("NSError bridge rejects unexpected post-call instructions")
    func rejectsNSErrorBridgeWithEscapingCompilerState() throws {
        let fixture = try nsErrorFixture(
            unexpectedPostCallInstruction: "%99 = integer_literal $Builtin.Int64, 7"
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer(
                typeEnvironment: fixture.environment
            ).lower(
                fixture.function,
                displayName: "Fixture.removeItem",
                directCalls: fixture.calls,
                expectedEffects: fixture.effects
            )
        }
    }

    @Test("Throwing Void SIL cannot impersonate a non-Void logical result")
    func rejectsNonVoidExpectationForStandaloneErrorResult() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().parseFunctionType(
                "@convention(thin) () -> @error any Error",
                bridgingTo: (parameters: [], result: .int64)
            )
        }
    }

    @Test("Same-type reference casts support Objective-C superclass lookup")
    func lowersSameTypeReceiverCast() throws {
        let controllerType = Core.TypeID(rawValue: .sha256("Fixture.Controller"))
        let viewControllerType = Core.TypeID(rawValue: .sha256("UIKit.UIViewController"))
        let upcastRequirement = importRequirement(id: 5)
        let superRequirement = importRequirement(id: 6)
        let loweredSuperType = "@convention(objc_method) (UIViewController) -> ()"
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.upcast(
                    from: controllerType,
                    to: viewControllerType
                ),
                parameterTypes: [.native(controllerType)],
                resultType: .native(viewControllerType),
                target: .nativeImport(upcastRequirement)
            ),
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.foreignCall(
                    reference: "#UIViewController.viewDidLayoutSubviews!foreign",
                    loweredType: loweredSuperType
                ),
                parameterTypes: [.native(viewControllerType)],
                resultType: .void,
                target: .nativeImport(superRequirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            [
                "Fixture.Controller": controllerType,
                "UIViewController": viewControllerType,
            ],
            kinds: [
                controllerType: .reference,
                viewControllerType: .reference,
            ]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture10ControlleryyF",
            loweredType: "@convention(thin) (@guaranteed Fixture.Controller) -> ()",
            body: """
            bb0(%0 : @guaranteed $Fixture.Controller):
              %1 = upcast %0 to $UIViewController
              %2 = unchecked_ref_cast %0 to $Fixture.Controller
              %3 = objc_super_method %2, #UIViewController.viewDidLayoutSubviews!foreign : (UIViewController) -> () -> (), $\(loweredSuperType)
              %4 = apply %3(%1) : $\(loweredSuperType)
              %5 = tuple ()
              return %5
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.Controller.layout",
            directCalls: calls
        )
        let imports = lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> Core.NativeImportID? in
            guard case let .nativeApply(_, id, _) = instruction else { return nil }
            return id
        }
        #expect(imports == [upcastRequirement.id, superRequirement.id])
    }

    @Test("Reference casts between distinct frozen types remain rejected")
    func rejectsDifferentTypeReceiverCast() throws {
        let controllerType = Core.TypeID(rawValue: .sha256("Fixture.Controller"))
        let viewControllerType = Core.TypeID(rawValue: .sha256("UIKit.UIViewController"))
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            [
                "Fixture.Controller": controllerType,
                "UIViewController": viewControllerType,
            ],
            kinds: [
                controllerType: .reference,
                viewControllerType: .reference,
            ]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture10ControlleryyF",
            loweredType: "@convention(thin) (@guaranteed Fixture.Controller) -> ()",
            body: """
            bb0(%0 : @guaranteed $Fixture.Controller):
              %1 = unchecked_ref_cast %0 to $UIViewController
              %2 = tuple ()
              return %2
            """
        )

        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
                function,
                displayName: "Fixture.Controller.invalidCast",
                directCalls: .empty
            )
        }
    }

    @Test("Borrowed native upcasts release their temporary after the final use")
    func balancesBorrowedNativeUpcast() throws {
        let labelType = Core.TypeID(rawValue: .sha256("UIKit.UILabel"))
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let upcastSymbol = CanonicalSIL.NativeBridgeSymbols.upcast(
            from: labelType,
            to: objectType
        )
        let upcastRequirement = importRequirement(id: 6)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: upcastSymbol,
                parameterTypes: [.native(labelType)],
                resultType: .native(objectType),
                target: .nativeImport(upcastRequirement)
            ),
            .init(
                mangledName: "$s7Fixture7inspectyySo8NSObjectCF",
                parameterTypes: [.native(objectType)],
                parameterConventions: [.borrowed],
                resultType: .void,
                target: .function(.init(rawValue: 1))
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["UILabel": labelType, "NSObject": objectType],
            kinds: [labelType: .reference, objectType: .reference]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7inspectyySo7UILabelCF",
            loweredType: "@convention(thin) (@guaranteed UILabel) -> ()",
            body: """
            bb0(%0 : @guaranteed $UILabel):
              %1 = upcast %0 to $NSObject
              %2 = function_ref @$s7Fixture7inspectyySo8NSObjectCF : $@convention(thin) (@guaranteed NSObject) -> ()
              %3 = apply %2(%1) : $@convention(thin) (@guaranteed NSObject) -> ()
              %4 = tuple ()
              return %4
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.inspect",
            directCalls: calls
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let parameter = try #require(lowered.parameterRegisters.first)
        let upcast = try #require(instructions.enumerated().first { _, instruction in
            guard case let .nativeApply(_, id, _) = instruction else { return false }
            return id == upcastRequirement.id
        })
        guard case let .nativeApply(result, _, arguments) = upcast.element else {
            Issue.record("expected native upcast")
            return
        }
        let converted = try #require(result)
        let argument = try #require(arguments.first)
        #expect(argument != parameter)
        let borrowedCall = try #require(instructions.enumerated().first { _, instruction in
            guard case let .apply(_, id, values) = instruction else { return false }
            return id.rawValue == 1 && values == [converted]
        })
        let cleanup = try #require(instructions.enumerated().first { _, instruction in
            guard case let .destroyValue(value) = instruction else { return false }
            return value == converted
        })
        #expect(upcast.offset < borrowedCall.offset)
        #expect(borrowedCall.offset < cleanup.offset)
    }

    @Test("Owned native upcasts preserve a source that remains live")
    func preservesOwnedNativeUpcastSourceAcrossLaterUses() throws {
        let stackType = Core.TypeID(rawValue: .sha256("UIKit.UIStackView"))
        let viewType = Core.TypeID(rawValue: .sha256("UIKit.UIView"))
        let requirement = importRequirement(id: 26)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.upcast(
                    from: stackType,
                    to: viewType
                ),
                parameterTypes: [.native(stackType)],
                resultType: .native(viewType),
                target: .nativeImport(requirement)
            ),
            .init(
                mangledName: "$s7Fixture11inspectViewyySo6UIViewCF",
                parameterTypes: [.native(viewType)],
                parameterConventions: [.borrowed],
                resultType: .void,
                target: .function(.init(rawValue: 1))
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["UIStackView": stackType, "UIView": viewType],
            kinds: [stackType: .reference, viewType: .reference]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7inspectyySo11UIStackViewCnF",
            loweredType: "@convention(thin) (@owned UIStackView) -> ()",
            body: """
            bb0(%0 : @owned $UIStackView):
              %1 = upcast %0 to $UIView
              %2 = function_ref @$s7Fixture11inspectViewyySo6UIViewCF : $@convention(thin) (@guaranteed UIView) -> ()
              %3 = apply %2(%1) : $@convention(thin) (@guaranteed UIView) -> ()
              %4 = upcast %0 to $UIView
              %5 = apply %2(%4) : $@convention(thin) (@guaranteed UIView) -> ()
              strong_release %0
              %6 = tuple ()
              return %6
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.inspect",
            directCalls: calls
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let parameter = try #require(lowered.parameterRegisters.first)
        let conversions = instructions.compactMap { instruction
            -> (Bytecode.Register, Bytecode.Register)? in
            guard case let .nativeApply(result, id, values) = instruction,
                  let result,
                  id == requirement.id
            else { return nil }
            guard let argument = values.first else { return nil }
            return (result, argument)
        }

        #expect(conversions.count == 2)
        #expect(conversions.allSatisfy { $0.1 != parameter })
        for (result, argument) in conversions {
            #expect(instructions.contains { instruction in
                guard case let .copyValue(result, source) = instruction else {
                    return false
                }
                return result == argument && source == parameter
            })
            #expect(instructions.count { instruction in
                guard case let .destroyValue(value) = instruction else {
                    return false
                }
                return value == result
            } == 1)
        }
        #expect(instructions.count { instruction in
            guard case let .destroyValue(value) = instruction else { return false }
            return value == parameter
        } == 1)
    }

    @Test("Explicit SIL release closes a borrowed native upcast lifetime")
    func balancesExplicitlyReleasedBorrowedNativeUpcast() throws {
        let labelType = Core.TypeID(rawValue: .sha256("UIKit.UILabel"))
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let upcastSymbol = CanonicalSIL.NativeBridgeSymbols.upcast(
            from: labelType,
            to: objectType
        )
        let upcastRequirement = importRequirement(id: 7)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: upcastSymbol,
                parameterTypes: [.native(labelType)],
                resultType: .native(objectType),
                target: .nativeImport(upcastRequirement)
            ),
            .init(
                mangledName: "$s7Fixture7inspectyySo8NSObjectCF",
                parameterTypes: [.native(objectType)],
                parameterConventions: [.borrowed],
                resultType: .void,
                target: .function(.init(rawValue: 1))
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["UILabel": labelType, "NSObject": objectType],
            kinds: [labelType: .reference, objectType: .reference]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7inspectyySo7UILabelCF",
            loweredType: "@convention(thin) (@guaranteed UILabel) -> ()",
            body: """
            bb0(%0 : @guaranteed $UILabel):
              %1 = upcast %0 to $NSObject
              %2 = function_ref @$s7Fixture7inspectyySo8NSObjectCF : $@convention(thin) (@guaranteed NSObject) -> ()
              %3 = apply %2(%1) : $@convention(thin) (@guaranteed NSObject) -> ()
              strong_release %1
              %4 = tuple ()
              return %4
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.inspect",
            directCalls: calls
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let convertedValues: [Bytecode.Register] = instructions.compactMap {
            instruction -> Bytecode.Register? in
            guard case let .nativeApply(result, id, _) = instruction,
                  id == upcastRequirement.id
            else { return nil }
            return result
        }
        let converted = try #require(convertedValues.first)
        #expect(instructions.count { instruction in
            guard case let .destroyValue(value) = instruction else { return false }
            return value == converted
        } == 1)
    }

    @Test("Explicit retain owners follow native reference conversion aliases")
    func forwardsRetainedOwnersAcrossNativeUpcastAliases() throws {
        let labelType = Core.TypeID(rawValue: .sha256("UIKit.UILabel"))
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let requirement = importRequirement(id: 27)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.upcast(
                    from: labelType,
                    to: objectType
                ),
                parameterTypes: [.native(labelType)],
                resultType: .native(objectType),
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["UILabel": labelType, "NSObject": objectType],
            kinds: [labelType: .reference, objectType: .reference]
        )
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture7inspectyySo7UILabelCF",
                loweredType: "@convention(thin) (@guaranteed UILabel) -> ()",
                body: """
                bb0(%0 : @guaranteed $UILabel):
                  strong_retain %0
                  strong_retain %0
                  %1 = upcast %0 to $NSObject
                  strong_release %1
                  strong_release %0
                  %2 = tuple ()
                  return %2
                """
            ),
            displayName: "Fixture.inspect",
            directCalls: calls
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let parameter = try #require(lowered.parameterRegisters.first)
        let conversion = try #require(instructions.compactMap { instruction
            -> (result: Bytecode.Register, argument: Bytecode.Register)? in
            guard case let .nativeApply(result, id, arguments) = instruction,
                  let result,
                  id == requirement.id,
                  let argument = arguments.first
            else { return nil }
            return (result, argument)
        }.first)
        let retainedCopies = instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .copyValue(result, source) = instruction,
                  source == parameter
            else { return nil }
            return result
        }
        let destroyed = instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .destroyValue(value) = instruction else { return nil }
            return value
        }

        #expect(retainedCopies.count == 2)
        #expect(retainedCopies.contains(conversion.argument))
        #expect(destroyed.contains(conversion.result))
        #expect(destroyed.contains { retainedCopies.contains($0) })
        #expect(!destroyed.contains(parameter))
    }

    @Test("Explicit retain owners follow same-type reference aliases")
    func forwardsRetainedOwnersAcrossSameTypeReferenceAliases() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["NSObject": objectType],
            kinds: [objectType: .reference]
        )
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture7inspectyySo8NSObjectCF",
                loweredType: "@convention(thin) (@guaranteed NSObject) -> ()",
                body: """
                bb0(%0 : @guaranteed $NSObject):
                  strong_retain %0
                  %1 = unchecked_ref_cast %0 to $NSObject
                  strong_release %1
                  %2 = tuple ()
                  return %2
                """
            ),
            displayName: "Fixture.inspect"
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let parameter = try #require(lowered.parameterRegisters.first)
        let retained = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .copyValue(result, source) = instruction,
                  source == parameter
            else { return nil }
            return result
        }.first)

        #expect(instructions.contains(.destroyValue(retained)))
        #expect(!instructions.contains(.destroyValue(parameter)))
    }

    @Test("Unqualified imported reference loads promote retained owners")
    func promotesRetainedImportedGlobalLoad() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let globalSymbol = "$s7Fixture12sharedObjectSo8NSObjectCvp"
        let loweredGlobalType = "NSObject"
        let requirement = importRequirement(id: 28)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.importedGlobal(
                    symbol: globalSymbol,
                    loweredType: loweredGlobalType
                ),
                parameterTypes: [],
                resultType: .native(objectType),
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["NSObject": objectType],
            kinds: [objectType: .reference]
        )
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture6sharedSo8NSObjectCyF",
                loweredType: "@convention(thin) () -> @owned NSObject",
                body: """
                bb0:
                  %0 = global_addr @\(globalSymbol) : $*NSObject
                  %1 = load %0
                  strong_retain %1
                  return %1
                """
            ),
            displayName: "Fixture.shared",
            directCalls: calls
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let loaded = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .nativeApply(result, id, _) = instruction,
                  id == requirement.id
            else { return nil }
            return result
        }.first)
        let retained = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .copyValue(result, source) = instruction,
                  source == loaded
            else { return nil }
            return result
        }.first)

        #expect(instructions.contains(.destroyValue(loaded)))
        #expect(instructions.contains(.returnValue(retained)))
    }

    @Test("Unqualified imported reference loads clean up after borrowed calls")
    func cleansBorrowedImportedGlobalLoadAfterCall() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let globalSymbol = "$s7Fixture12sharedObjectSo8NSObjectCvp"
        let loweredGlobalType = "NSObject"
        let inspectSymbol = "$s7Fixture7inspectyySo8NSObjectCF"
        let requirement = importRequirement(id: 29)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.importedGlobal(
                    symbol: globalSymbol,
                    loweredType: loweredGlobalType
                ),
                parameterTypes: [],
                resultType: .native(objectType),
                target: .nativeImport(requirement)
            ),
            .init(
                mangledName: inspectSymbol,
                parameterTypes: [.native(objectType)],
                parameterConventions: [.borrowed],
                resultType: .void,
                target: .function(.init(rawValue: 1))
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["NSObject": objectType],
            kinds: [objectType: .reference]
        )
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture3runyyF",
                loweredType: "@convention(thin) () -> ()",
                body: """
                bb0:
                  %0 = global_addr @\(globalSymbol) : $*NSObject
                  %1 = load %0
                  %2 = unchecked_ref_cast %1 to $NSObject
                  %3 = function_ref @\(inspectSymbol) : $@convention(thin) (@guaranteed NSObject) -> ()
                  %4 = apply %3(%2) : $@convention(thin) (@guaranteed NSObject) -> ()
                  %5 = tuple ()
                  return %5
                """
            ),
            displayName: "Fixture.run",
            directCalls: calls
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let loaded = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .nativeApply(result, id, _) = instruction,
                  id == requirement.id
            else { return nil }
            return result
        }.first)
        let callIndex = try #require(instructions.firstIndex { instruction in
            guard case let .apply(_, function, arguments) = instruction else {
                return false
            }
            return function.rawValue == 1 && arguments == [loaded]
        })
        let cleanupIndex = try #require(
            instructions.firstIndex(of: .destroyValue(loaded))
        )

        #expect(callIndex < cleanupIndex)
    }

    @Test("Optional.some assumes ownership of a borrowed native conversion")
    func transfersBorrowedNativeUpcastIntoOptional() throws {
        let labelType = Core.TypeID(rawValue: .sha256("UIKit.UILabel"))
        let objectType = Core.TypeID(rawValue: .sha256("Swift.AnyObject"))
        let requirement = importRequirement(id: 8)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.upcast(
                    from: labelType,
                    to: objectType
                ),
                parameterTypes: [.native(labelType)],
                resultType: .native(objectType),
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["UILabel": labelType, "Swift.AnyObject": objectType],
            kinds: [labelType: .reference, objectType: .reference]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture5eraseyySo7UILabelCF",
            loweredType: "@convention(thin) (@guaranteed UILabel) -> ()",
            body: """
            bb0(%0 : @guaranteed $UILabel):
              strong_retain %0
              %1 = init_existential_ref %0 : $UILabel : $UILabel, $AnyObject
              %2 = enum $Optional<AnyObject>, #Optional.some!enumelt, %1
              release_value %2
              %3 = tuple ()
              return %3
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.erase",
            directCalls: calls
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let optional = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .makeOptionalSome(result, _) = instruction else {
                return nil
            }
            return result
        }.first)
        #expect(instructions.count { instruction in
            guard case let .destroyValue(value) = instruction else { return false }
            return value == optional
        } == 1)
    }

    @Test("Optional.some materializes one owner for a borrowed linear payload")
    func ownsBorrowedOptionalPayload() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture8optionalySo8NSObjectCSgADF",
                loweredType: "@convention(thin) (@guaranteed NSObject) -> @owned Optional<NSObject>",
                body: """
                bb0(%0 : @guaranteed $NSObject):
                  strong_retain %0
                  %1 = enum $Optional<NSObject>, #Optional.some!enumelt, %0
                  return %1
                """
            ),
            displayName: "Fixture.optional"
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let copy = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .copyValue(result, source) = instruction,
                  source.rawValue == 0
            else { return nil }
            return result
        }.first)

        #expect(instructions.contains { instruction in
            guard case let .makeOptionalSome(_, payload) = instruction else {
                return false
            }
            return payload == copy
        })
    }

    @Test("Optional switch materializes one owner for a borrowed linear value")
    func ownsBorrowedOptionalSwitch() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture8identityySo8NSObjectCSgAEF",
                loweredType: "@convention(thin) (@guaranteed Optional<NSObject>) "
                    + "-> @owned Optional<NSObject>",
                body: """
                bb0(%0 : @guaranteed $Optional<NSObject>):
                  switch_enum %0, case #Optional.some!enumelt: bb1, case #Optional.none!enumelt: bb2
                bb1(%1 : @owned $NSObject):
                  %2 = unchecked_enum_data %0, #Optional.some!enumelt
                  %3 = enum $Optional<NSObject>, #Optional.some!enumelt, %2
                  return %3
                bb2:
                  %4 = enum $Optional<NSObject>, #Optional.none!enumelt
                  return %4
                """
            ),
            displayName: "Fixture.identity"
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let copy = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .copyValue(result, source) = instruction,
                  source.rawValue == 0
            else { return nil }
            return result
        }.first)

        #expect(instructions.contains { instruction in
            guard case let .switchOptional(optional, _, _) = instruction else {
                return false
            }
            return optional == copy
        })
    }

    @Test("Optional default cases discard unbound linear payloads exactly once")
    func ownsDefaultOptionalSwitch() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture6isNilySbSo8NSObjectCSgF",
                loweredType: "@convention(thin) "
                    + "(@guaranteed Optional<NSObject>) -> Int",
                body: """
                bb0(%0 : @guaranteed $Optional<NSObject>):
                  switch_enum %0, case #Optional.none!enumelt: bb1, default bb2
                bb1:
                  %1 = integer_literal $Builtin.Int64, 1
                  return %1
                bb2:
                  %2 = integer_literal $Builtin.Int64, 0
                  return %2
                """
            ),
            displayName: "Fixture.isNil"
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let copy = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .copyValue(result, source) = instruction,
                  source.rawValue == 0
            else { return nil }
            return result
        }.first)
        let selectionIndex = try #require(
            instructions.firstIndex { instruction in
                guard case let .optionalIsSome(_, optional) = instruction
                else { return false }
                return optional == copy
            }
        )
        let destructionIndex = try #require(
            instructions.firstIndex(of: .destroyValue(copy))
        )
        let branchIndex = try #require(
            instructions.firstIndex { instruction in
                if case .conditionalBranch = instruction { return true }
                return false
            }
        )

        #expect(selectionIndex < destructionIndex)
        #expect(destructionIndex < branchIndex)
        #expect(!instructions.contains { instruction in
            if case .switchOptional = instruction { return true }
            return false
        })
    }

    @Test("Optional address switches accept Swift-qualified default coverage")
    func lowersDefaultOptionalAddressSwitch() throws {
        let lowered = try CanonicalSIL.Lowerer().lower(
            .init(
                mangledName: "$s7Fixture6isSomeySiSiSgF",
                loweredType: "@convention(thin) (Optional<Int>) -> Int",
                body: """
                bb0(%0 : $Optional<Int>):
                  %1 = alloc_stack $Optional<Int>
                  store %0 to %1
                  switch_enum_addr %1, case #Swift.Optional.some!enumelt: bb1, default bb2
                bb1:
                  destroy_addr %1
                  dealloc_stack %1
                  %2 = integer_literal $Builtin.Int64, 1
                  return %2
                bb2:
                  destroy_addr %1
                  dealloc_stack %1
                  %3 = integer_literal $Builtin.Int64, 0
                  return %3
                """
            ),
            displayName: "Fixture.isSome"
        )
        let branch = try #require(
            lowered.blocks.flatMap(\.instructions).compactMap { instruction
                -> (Bytecode.BlockID, Bytecode.BlockID)? in
                guard case let .conditionalBranch(
                    _,
                    trueTarget,
                    trueArguments,
                    falseTarget,
                    falseArguments
                ) = instruction,
                    trueArguments.isEmpty,
                    falseArguments.isEmpty
                else { return nil }
                return (trueTarget, falseTarget)
            }.first
        )

        #expect(branch.0 == .init(rawValue: 1))
        #expect(branch.1 == .init(rawValue: 2))
    }

    @Test("Malformed Optional default coverage fails closed")
    func rejectsMalformedOptionalSwitchDefaults() throws {
        for clauses in [
            "case #Optional.some!enumelt: bb1, default bb2, default bb3",
            "case #Optional.some!enumelt: bb1, case #Optional.none!enumelt: bb2, default bb3",
            "case #Optional.some!enumelt: bb1, case #Optional.some!enumelt: bb2",
        ] {
            do {
                _ = try CanonicalSIL.Lowerer().lower(
                    .init(
                        mangledName: "$s7Fixture7invalidySiSiSgF",
                        loweredType: "@convention(thin) (Optional<Int>) -> Int",
                        body: """
                        bb0(%0 : $Optional<Int>):
                          switch_enum %0, \(clauses)
                        bb1(%1 : $Int):
                          return %1
                        bb2:
                          %2 = integer_literal $Builtin.Int64, 0
                          return %2
                        bb3:
                          %3 = integer_literal $Builtin.Int64, 1
                          return %3
                        """
                    ),
                    displayName: "Fixture.invalid"
                )
                Issue.record("malformed Optional switch was accepted: \(clauses)")
            } catch let error as CanonicalSIL.LoweringError {
                #expect(error.description.contains("Optional switch"))
            }
        }
    }

    @Test("Owned direct-call edges consume a retained borrowed owner")
    func ownsBorrowedDirectCallArgument() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let symbol = "$s7Fixture7consumeyySo8NSObjectCF"
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.native(objectType)],
                parameterConventions: [.owned],
                resultType: .void,
                target: .function(.init(rawValue: 1))
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture3runyySo8NSObjectCF",
                loweredType: "@convention(thin) (@guaranteed NSObject) -> ()",
                body: """
                bb0(%0 : @guaranteed $NSObject):
                  strong_retain %0
                  %1 = function_ref @\(symbol) : $@convention(thin) (@owned NSObject) -> ()
                  %2 = apply %1(%0) : $@convention(thin) (@owned NSObject) -> ()
                  %3 = tuple ()
                  return %3
                """
            ),
            displayName: "Fixture.run",
            directCalls: calls
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let copy = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .copyValue(result, source) = instruction,
                  source.rawValue == 0
            else { return nil }
            return result
        }.first)

        #expect(instructions.contains { instruction in
            guard case let .apply(_, _, arguments) = instruction else {
                return false
            }
            return arguments == [copy]
        })
    }

    @Test("Objective-C pseudogenerics bridge to one frozen concrete specialization")
    func lowersPseudogenericForeignMethod() throws {
        let anchorType = Core.TypeID(
            rawValue: .sha256("UIKit.NSLayoutAnchor<UIKit.NSLayoutXAxisAnchor>")
        )
        let constraintType = Core.TypeID(rawValue: .sha256("UIKit.NSLayoutConstraint"))
        let loweredType = "@convention(objc_method) @pseudogeneric <τ_0_0 where τ_0_0 : AnyObject> (NSLayoutAnchor<τ_0_0>, NSLayoutAnchor<τ_0_0>) -> @autoreleased NSLayoutConstraint"
        let reference = "#NSLayoutAnchor.constraint!foreign"
        let symbol = CanonicalSIL.NativeBridgeSymbols.foreignCall(
            reference: reference,
            loweredType: loweredType,
            genericArguments: ["NSLayoutXAxisAnchor"]
        )
        let requirement = importRequirement(id: 5)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.native(anchorType), .native(anchorType)],
                resultType: .native(constraintType),
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            [
                "NSLayoutAnchor<NSLayoutXAxisAnchor>": anchorType,
                "NSLayoutConstraint": constraintType,
            ],
            kinds: [anchorType: .reference, constraintType: .reference]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture9constraintySo18NSLayoutConstraintCSo15NSLayoutXAxisAnchorC_AHtF",
            loweredType: "@convention(thin) (@guaranteed NSLayoutAnchor<NSLayoutXAxisAnchor>, @guaranteed NSLayoutAnchor<NSLayoutXAxisAnchor>) -> @owned NSLayoutConstraint",
            body: """
            bb0(%0 : @guaranteed $NSLayoutAnchor<NSLayoutXAxisAnchor>, %1 : @guaranteed $NSLayoutAnchor<NSLayoutXAxisAnchor>):
              %2 = objc_method %1, \(reference) : <AnchorType where AnchorType : AnyObject> (NSLayoutAnchor<AnchorType>) -> (NSLayoutAnchor<AnchorType>) -> NSLayoutConstraint, $\(loweredType)
              %3 = apply %2<NSLayoutXAxisAnchor>(%0, %1) : $\(loweredType)
              return %3
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.constraint",
            directCalls: calls
        )
        #expect(lowered.resultType == .native(constraintType))
        #expect(lowered.blocks.flatMap(\.instructions).contains { instruction in
            guard case let .nativeApply(_, id, arguments) = instruction else { return false }
            return id == requirement.id && arguments.count == 2
        })
    }

    @Test("Pseudogeneric calls select distinct concrete NativeImports")
    func selectsConcretePseudogenericImports() throws {
        let xType = Core.TypeID(rawValue: .sha256("UIKit.NSLayoutAnchor<X>"))
        let yType = Core.TypeID(rawValue: .sha256("UIKit.NSLayoutAnchor<Y>"))
        let constraintType = Core.TypeID(rawValue: .sha256("UIKit.NSLayoutConstraint"))
        let loweredType = "@convention(objc_method) @pseudogeneric "
            + "<τ_0_0 where τ_0_0 : AnyObject> "
            + "(NSLayoutAnchor<τ_0_0>, NSLayoutAnchor<τ_0_0>) "
            + "-> @autoreleased NSLayoutConstraint"
        let reference = "#NSLayoutAnchor.constraint!foreign"
        let xRequirement = importRequirement(id: 13)
        let yRequirement = importRequirement(id: 14)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.foreignCall(
                    reference: reference,
                    loweredType: loweredType,
                    genericArguments: ["NSLayoutXAxisAnchor"]
                ),
                parameterTypes: [.native(xType), .native(xType)],
                resultType: .native(constraintType),
                target: .nativeImport(xRequirement)
            ),
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.foreignCall(
                    reference: reference,
                    loweredType: loweredType,
                    genericArguments: ["NSLayoutYAxisAnchor"]
                ),
                parameterTypes: [.native(yType), .native(yType)],
                resultType: .native(constraintType),
                target: .nativeImport(yRequirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            [
                "NSLayoutAnchor<NSLayoutXAxisAnchor>": xType,
                "NSLayoutAnchor<NSLayoutYAxisAnchor>": yType,
                "NSLayoutConstraint": constraintType,
            ],
            kinds: [xType: .reference, yType: .reference, constraintType: .reference]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture11constraintsyyF",
            loweredType: "@convention(thin) (@guaranteed NSLayoutAnchor<NSLayoutXAxisAnchor>, @guaranteed NSLayoutAnchor<NSLayoutXAxisAnchor>, @guaranteed NSLayoutAnchor<NSLayoutYAxisAnchor>, @guaranteed NSLayoutAnchor<NSLayoutYAxisAnchor>) -> ()",
            body: """
            bb0(%0 : @guaranteed $NSLayoutAnchor<NSLayoutXAxisAnchor>, %1 : @guaranteed $NSLayoutAnchor<NSLayoutXAxisAnchor>, %2 : @guaranteed $NSLayoutAnchor<NSLayoutYAxisAnchor>, %3 : @guaranteed $NSLayoutAnchor<NSLayoutYAxisAnchor>):
              %4 = objc_method %1, \(reference) : <Anchor where Anchor : AnyObject> (NSLayoutAnchor<Anchor>) -> (NSLayoutAnchor<Anchor>) -> NSLayoutConstraint, $\(loweredType)
              %5 = apply %4<NSLayoutXAxisAnchor>(%0, %1) : $\(loweredType)
              strong_release %5
              %6 = objc_method %3, \(reference) : <Anchor where Anchor : AnyObject> (NSLayoutAnchor<Anchor>) -> (NSLayoutAnchor<Anchor>) -> NSLayoutConstraint, $\(loweredType)
              %7 = apply %6<NSLayoutYAxisAnchor>(%2, %3) : $\(loweredType)
              strong_release %7
              %8 = tuple ()
              return %8
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.constraints",
            directCalls: calls
        )
        let importIDs: Set<Core.NativeImportID> = Set(
            lowered.blocks.flatMap(\.instructions).compactMap { instruction
                -> Core.NativeImportID? in
                guard case let .nativeApply(_, id, _) = instruction else { return nil }
                return id
            }
        )
        #expect(importIDs == [xRequirement.id, yRequirement.id])
    }

    @Test("Owned indirect native arguments transfer compiler address storage")
    func transfersOwnedIndirectNativeArgument() throws {
        let configurationType = Core.TypeID(
            rawValue: .sha256("UIKit.UIButton.Configuration")
        )
        let buttonType = Core.TypeID(rawValue: .sha256("UIKit.UIButton"))
        let filled = importRequirement(id: 15)
        let setter = importRequirement(id: 16)
        let filledSymbol = "$sSo8UIButtonC5UIKitE13ConfigurationV6filledAEyFZ"
        let setterSymbol = "$sSo8UIButtonC5UIKitE13configurationAbCE13ConfigurationVSgvs"
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: filledSymbol,
                parameterTypes: [],
                resultType: .native(configurationType),
                target: .nativeImport(filled)
            ),
            .init(
                mangledName: setterSymbol,
                parameterTypes: [
                    .optional(.native(configurationType)),
                    .native(buttonType),
                ],
                resultType: .void,
                target: .nativeImport(setter)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            [
                "UIButton.Configuration": configurationType,
                "UIButton": buttonType,
            ],
            kinds: [
                configurationType: .value,
                buttonType: .reference,
            ]
        )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture9configureyySo8UIButtonCF",
            loweredType: "@convention(thin) (@guaranteed UIButton) -> ()",
            body: """
            bb0(%0 : @guaranteed $UIButton):
              %1 = alloc_stack $Optional<UIButton.Configuration>
              %2 = init_enum_data_addr %1, #Optional.some!enumelt
              %3 = metatype $@thin UIButton.Configuration.Type
              %4 = function_ref @\(filledSymbol) : $@convention(method) (@thin UIButton.Configuration.Type) -> @out UIButton.Configuration
              %5 = apply %4(%2, %3) : $@convention(method) (@thin UIButton.Configuration.Type) -> @out UIButton.Configuration
              inject_enum_addr %1, #Optional.some!enumelt
              %6 = function_ref @\(setterSymbol) : $@convention(method) (@in Optional<UIButton.Configuration>, @guaranteed UIButton) -> ()
              %7 = apply %6(%1, %0) : $@convention(method) (@in Optional<UIButton.Configuration>, @guaranteed UIButton) -> ()
              dealloc_stack %1
              %8 = tuple ()
              return %8
            """
        )

        let lowered = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            function,
            displayName: "Fixture.configure",
            directCalls: calls
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let setterCall = try #require(instructions.first { instruction in
            guard case let .nativeApply(_, id, _) = instruction else { return false }
            return id == setter.id
        })
        guard case let .nativeApply(_, _, arguments) = setterCall,
              let transferred = arguments.first
        else {
            Issue.record("expected the configuration setter NativeImport")
            return
        }
        #expect(!instructions.contains { instruction in
            guard case let .destroyValue(value) = instruction else { return false }
            return value == transferred
        })
    }

    @Test("Optional address state is restored independently for sibling successors")
    func preservesOptionalAddressAcrossSiblingBlocks() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7consume_ys6StringVSgF",
            loweredType: "@convention(thin) (@owned Optional<String>) -> ()",
            body: """
            bb0(%0 : @owned $Optional<String>):
              %1 = alloc_stack $Optional<String>
              store %0 to %1
              %2 = integer_literal $Builtin.Int1, -1
              %3 = integer_literal $Builtin.Int1, 0
              %4 = select_enum_addr %1, case #Optional.some!enumelt: %2, default %3 : $Builtin.Int1
              cond_br %4, bb1, bb3
            bb1:
              %5 = unchecked_take_enum_data_addr %1, #Optional.some!enumelt
              %6 = load [take] %5
              destroy_value %6
              dealloc_stack %1
              br bb2
            bb2:
              %7 = tuple ()
              return %7
            bb3:
              %8 = alloc_stack $Optional<String>
              copy_addr %1 to [init] %8
              destroy_addr %8
              dealloc_stack %8
              destroy_addr %1
              dealloc_stack %1
              br bb2
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "Fixture.consume"
        )
        #expect(Set(lowered.blocks.map(\.id.rawValue)).isSuperset(of: [0, 1, 2, 3]))
        let someInstructions = try #require(
            lowered.blocks.first { $0.id.rawValue == 1 }?.instructions
        )
        let noneInstructions = try #require(
            lowered.blocks.first { $0.id.rawValue == 3 }?.instructions
        )
        #expect(someInstructions.contains { instruction in
            guard case .unwrapOptional = instruction else { return false }
            return true
        })
        #expect(noneInstructions.contains { instruction in
            guard case .loadAddress(_, _, .copy) = instruction else {
                return false
            }
            return true
        })
        #expect(!lowered.blocks.flatMap(\.instructions).contains { instruction in
            guard case .switchOptional = instruction else { return false }
            return true
        })
    }

    @Test("Optional address copies preserve some-case dominance and ownership")
    func lowersTakenOptionalAddressCopyWithinSomeCase() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7consume_ys6StringVSgF",
            loweredType: "@convention(thin) (@owned Optional<String>) -> ()",
            body: """
            bb0(%0 : @owned $Optional<String>):
              %1 = alloc_stack $Optional<String>
              store %0 to %1
              switch_enum_addr %1, case #Optional.some!enumelt: bb1, case #Optional.none!enumelt: bb2
            bb1:
              %2 = alloc_stack $Optional<String>
              copy_addr %1 to [init] %2
              %3 = unchecked_take_enum_data_addr %2, #Optional.some!enumelt
              %4 = load [take] %3
              destroy_value %4
              dealloc_stack %2
              destroy_addr %1
              dealloc_stack %1
              br bb3
            bb2:
              destroy_addr %1
              dealloc_stack %1
              br bb3
            bb3:
              %5 = tuple ()
              return %5
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "Fixture.consume"
        )
        let entry = try #require(
            lowered.blocks.first { $0.id.rawValue == 0 }?.instructions
        )
        let some = try #require(
            lowered.blocks.first { $0.id.rawValue == 1 }?.instructions
        )
        #expect(entry.contains { instruction in
            guard case .optionalIsSome = instruction else { return false }
            return true
        })
        let copiedOptional = try #require(some.compactMap {
            instruction -> Bytecode.Register? in
            guard case let .loadAddress(result, _, .copy) = instruction else {
                return nil
            }
            return result
        }.first)
        #expect(some.contains { instruction in
            guard case let .unwrapOptional(_, optional) = instruction else { return false }
            return optional == copiedOptional
        })
        #expect(!some.contains { instruction in
            guard case let .destroyValue(value) = instruction else { return false }
            return value == copiedOptional
        })
    }

    @Test("Optional address payload takes require a proven some edge")
    func rejectsUnprovenOptionalAddressTake() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7consume_ys6StringVSgF",
            loweredType: "@convention(thin) (@owned Optional<String>) -> ()",
            body: """
            bb0(%0 : @owned $Optional<String>):
              %1 = alloc_stack $Optional<String>
              store %0 to %1
              %2 = unchecked_take_enum_data_addr %1, #Optional.some!enumelt
              %3 = load [take] %2
              destroy_value %3
              dealloc_stack %1
              %4 = tuple ()
              return %4
            """
        )

        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.consume"
            )
        }
    }

    @Test("Optional case facts remain field-sensitive across tuple projections")
    func rejectsSiblingOptionalCaseLeakage() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7consumeyySiSg_AEtF",
            loweredType: "@convention(thin) (Optional<Int>, Optional<Int>) -> ()",
            body: """
            bb0(%0 : $Optional<Int>, %1 : $Optional<Int>):
              %2 = alloc_stack $(Optional<Int>, Optional<Int>)
              %3 = tuple_element_addr %2, 0
              %4 = tuple_element_addr %2, 1
              store %0 to %3
              store %1 to %4
              switch_enum_addr %3, case #Optional.some!enumelt: bb1, case #Optional.none!enumelt: bb2
            bb1:
              %5 = unchecked_take_enum_data_addr %4, #Optional.some!enumelt
              %6 = load [take] %5
              dealloc_stack %2
              %7 = tuple ()
              return %7
            bb2:
              destroy_addr %3
              destroy_addr %4
              dealloc_stack %2
              %8 = tuple ()
              return %8
            """
        )

        do {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.consume"
            )
            Issue.record("a sibling Optional inherited the wrong case fact")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains("not dominated by its some edge"))
        }
    }

    @Test("Aggregate writes invalidate projected Optional case evidence")
    func rejectsStaleOptionalCaseAfterAggregateWrite() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7consumeyySiSg_AEtF",
            loweredType: "@convention(thin) (Optional<Int>, Optional<Int>) -> ()",
            body: """
            bb0(%0 : $Optional<Int>, %1 : $Optional<Int>):
              %2 = alloc_stack $(Optional<Int>, Optional<Int>)
              %3 = tuple_element_addr %2, 0
              %4 = tuple_element_addr %2, 1
              store %0 to %3
              store %1 to %4
              switch_enum_addr %3, case #Optional.some!enumelt: bb1, case #Optional.none!enumelt: bb2
            bb1:
              %5 = enum $Optional<Int>, #Optional.none!enumelt
              %6 = tuple (%5, %1)
              store %6 to [assign] %2
              %7 = unchecked_take_enum_data_addr %3, #Optional.some!enumelt
              %8 = load [take] %7
              dealloc_stack %2
              %9 = tuple ()
              return %9
            bb2:
              destroy_addr %3
              destroy_addr %4
              dealloc_stack %2
              %10 = tuple ()
              return %10
            """
        )

        do {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.consume"
            )
            Issue.record("an aggregate overwrite retained a stale case fact")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains("not dominated by its some edge"))
        }
    }

    @Test("Sibling writes preserve an independent Optional case proof")
    func preservesOptionalCaseAcrossSiblingWrite() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7consumeyySiSg_AEtF",
            loweredType: "@convention(thin) (Optional<Int>, Optional<Int>) -> ()",
            body: """
            bb0(%0 : $Optional<Int>, %1 : $Optional<Int>):
              %2 = alloc_stack $(Optional<Int>, Optional<Int>)
              %3 = tuple_element_addr %2, 0
              %4 = tuple_element_addr %2, 1
              store %0 to %3
              store %1 to %4
              switch_enum_addr %3, case #Optional.some!enumelt: bb1, case #Optional.none!enumelt: bb2
            bb1:
              store %1 to [assign] %4
              %5 = unchecked_take_enum_data_addr %3, #Optional.some!enumelt
              %6 = load [take] %5
              destroy_value %6
              destroy_addr %4
              dealloc_stack %2
              %7 = tuple ()
              return %7
            bb2:
              destroy_addr %3
              destroy_addr %4
              dealloc_stack %2
              %8 = tuple ()
              return %8
            """
        )

        _ = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "Fixture.consume"
        )
    }

    @Test("Patch-local struct fields keep independent Optional case facts")
    func isolatesOptionalCaseFactsAcrossLocalStructFields() throws {
        let file = try CanonicalSIL.File(text: """
        struct Pair {
          @_hasStorage var first: Optional<Int>
          @_hasStorage var second: Optional<Int>
        }

        sil @$s7Fixture3badyySiSg_AEtF : $@convention(thin) (Optional<Int>, Optional<Int>) -> () {
        bb0(%0 : $Optional<Int>, %1 : $Optional<Int>):
          %2 = alloc_stack $Pair
          %3 = struct_element_addr %2, #Pair.first
          %4 = struct_element_addr %2, #Pair.second
          store %0 to %3
          store %1 to %4
          switch_enum_addr %3, case #Optional.some!enumelt: bb1, case #Optional.none!enumelt: bb2
        bb1:
          %5 = unchecked_take_enum_data_addr %4, #Optional.some!enumelt
          %6 = load [take] %5
          destroy_value %6
          destroy_addr %3
          dealloc_stack %2
          %7 = tuple ()
          return %7
        bb2:
          destroy_addr %3
          destroy_addr %4
          dealloc_stack %2
          %8 = tuple ()
          return %8
        } // end sil function '$s7Fixture3badyySiSg_AEtF'

        sil @$s7Fixture4goodyySiSg_AEtF : $@convention(thin) (Optional<Int>, Optional<Int>) -> () {
        bb0(%0 : $Optional<Int>, %1 : $Optional<Int>):
          %2 = alloc_stack $Pair
          %3 = struct_element_addr %2, #Pair.first
          %4 = struct_element_addr %2, #Pair.second
          store %0 to %3
          store %1 to %4
          switch_enum_addr %3, case #Optional.some!enumelt: bb1, case #Optional.none!enumelt: bb2
        bb1:
          store %1 to [assign] %4
          %5 = unchecked_take_enum_data_addr %3, #Optional.some!enumelt
          %6 = load [take] %5
          destroy_value %6
          destroy_addr %4
          dealloc_stack %2
          %7 = tuple ()
          return %7
        bb2:
          destroy_addr %3
          destroy_addr %4
          dealloc_stack %2
          %8 = tuple ()
          return %8
        } // end sil function '$s7Fixture4goodyySiSg_AEtF'
        """)
        let bad = try file.uniqueFunction(mangledNameContaining: "3bad")
        let good = try file.uniqueFunction(mangledNameContaining: "4good")
        let lowerer = CanonicalSIL.Lowerer(
            typeEnvironment: file.typeEnvironment
        )

        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try lowerer.lower(bad, displayName: "Fixture.bad")
        }
        _ = try lowerer.lower(good, displayName: "Fixture.good")
    }

    @Test("Frozen bridge pseudo-symbols include the exact physical ABI")
    func derivesStableExactForeignSymbols() {
        let reference = "#UILabel.text!setter.foreign"
        let first = CanonicalSIL.NativeBridgeSymbols.foreignCall(
            reference: reference,
            loweredType: "@convention(objc_method) (Optional<NSString>, UILabel) -> ()"
        )
        let repeated = CanonicalSIL.NativeBridgeSymbols.foreignCall(
            reference: reference,
            loweredType: "@convention(objc_method) (Optional<NSString>, UILabel) -> ()"
        )
        let overload = CanonicalSIL.NativeBridgeSymbols.foreignCall(
            reference: reference,
            loweredType: "@convention(objc_method) (NSString, UILabel) -> ()"
        )

        let specialized = CanonicalSIL.NativeBridgeSymbols.foreignCall(
            reference: reference,
            loweredType: "@convention(objc_method) @pseudogeneric <τ_0_0> "
                + "(NSLayoutAnchor<τ_0_0>) -> ()",
            genericArguments: ["NSLayoutXAxisAnchor"]
        )
        let otherSpecialization = CanonicalSIL.NativeBridgeSymbols.foreignCall(
            reference: reference,
            loweredType: "@convention(objc_method) @pseudogeneric <τ_0_0> "
                + "(NSLayoutAnchor<τ_0_0>) -> ()",
            genericArguments: ["NSLayoutYAxisAnchor"]
        )

        #expect(first == repeated)
        #expect(first != overload)
        #expect(specialized != otherSpecialization)
        #expect(first.hasPrefix("$hlx_native_foreign_"))
    }

    private struct NSErrorFixture {
        var managerType: Core.TypeID
        var effects: Core.Effects
        var requirement: Bytecode.ImportRequirement
        var calls: CanonicalSIL.DirectCallTable
        var environment: CanonicalSIL.TypeEnvironment
        var function: CanonicalSIL.Function
    }

    private func nsErrorFixture(
        unexpectedPostCallInstruction: String? = nil
    ) throws -> NSErrorFixture {
        let managerType = Core.TypeID(rawValue: .sha256("Foundation.FileManager"))
        let effects = Core.Effects(
            mayThrow: true,
            mayAllocate: true,
            hasExternalSideEffects: true
        )
        let physicalType = "@convention(objc_method) "
            + "(NSString, Optional<AutoreleasingUnsafeMutablePointer<Optional<NSError>>>, "
            + "FileManager) -> ObjCBool"
        let symbol = CanonicalSIL.NativeBridgeSymbols.foreignCall(
            reference: "#FileManager.removeItem!foreign",
            loweredType: physicalType
        )
        let requirement = importRequirement(
            id: 28,
            effects: effects,
            kind: .instanceMethod
        )
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.string, .native(managerType)],
                resultType: .void,
                effects: effects,
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes(
            ["FileManager": managerType],
            kinds: [managerType: .reference]
        )
        let postCallInstruction = unexpectedPostCallInstruction.map {
            "\n  \($0)"
        } ?? ""
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture10removeItemyySo13NSFileManagerC_SStKF",
            loweredType: "@convention(thin) (@guaranteed FileManager, "
                + "@guaranteed String) -> @error any Error",
            body: """
            bb0(%0 : $FileManager, %1 : $String):
              %2 = alloc_stack [dynamic_lifetime] $Optional<NSError>
              inject_enum_addr %2, #Optional.none!enumelt
              retain_value %1
              %3 = function_ref @$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF : $@convention(method) (@guaranteed String) -> @owned NSString
              %4 = apply %3(%1) : $@convention(method) (@guaranteed String) -> @owned NSString
              release_value %1
              %5 = objc_method %0, #FileManager.removeItem!foreign : (FileManager) -> (String) throws -> (), $\(physicalType)
              %6 = alloc_stack $@sil_unmanaged Optional<NSError>
              %7 = load %2
              %8 = ref_to_unmanaged %7 to $@sil_unmanaged Optional<NSError>
              store %8 to %6
              %9 = address_to_pointer [stack_protection] %6 to $Builtin.RawPointer
              %10 = struct $AutoreleasingUnsafeMutablePointer<Optional<NSError>> (%9)
              %11 = enum $Optional<AutoreleasingUnsafeMutablePointer<Optional<NSError>>>, #Optional.some!enumelt, %10
              %12 = apply %5(%4, %11, %0) : $\(physicalType)\(postCallInstruction)
              strong_release %4
              %13 = load %6
              %14 = unmanaged_to_ref %13 to $Optional<NSError>
              retain_value %14
              %15 = mark_dependence %14 on %2
              %16 = load %2
              store %15 to %2
              release_value %16
              dealloc_stack %6
              %17 = struct_extract %12, #ObjCBool._value
              %18 = struct_extract %17, #Bool._value
              cond_br %18, bb1, bb2
            bb1:
              dealloc_stack %2
              %19 = tuple ()
              return %19
            bb2:
              %20 = load %2
              %21 = function_ref @$s10Foundation22_convertNSErrorToErrorys0E0_pSo0C0CSgF : $@convention(thin) (@guaranteed Optional<NSError>) -> @owned any Error
              %22 = apply %21(%20) : $@convention(thin) (@guaranteed Optional<NSError>) -> @owned any Error
              release_value %20
              %23 = builtin "willThrow"(%22) : $()
              dealloc_stack %2
              throw %22
            """
        )
        return .init(
            managerType: managerType,
            effects: effects,
            requirement: requirement,
            calls: calls,
            environment: environment,
            function: function
        )
    }

    private func importRequirement(
        id: UInt32,
        effects: Core.Effects = .init(),
        kind: Core.NativeImportKind = .globalFunction
    ) -> Bytecode.ImportRequirement {
        .init(
            id: .init(rawValue: id),
            key: .init(rawValue: .sha256("import-\(id)")),
            signature: .init(parameters: [], result: "Swift.Void"),
            effects: effects,
            contract: .bounded(
                kind: kind,
                domain: .application,
                access: .pure,
                maximumDurationMicroseconds: 500,
                allowsMainThread: true
            )
        )
    }
}
}
