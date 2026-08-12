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
        #expect(lowered.blocks.first { $0.id.rawValue == 3 }?.instructions.contains {
            if case .copyValue = $0 { return true }
            return false
        } == true)
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

    private func importRequirement(id: UInt32) -> Bytecode.ImportRequirement {
        .init(
            id: .init(rawValue: id),
            key: .init(rawValue: .sha256("import-\(id)")),
            signature: .init(parameters: [], result: "Swift.Void"),
            effects: .init(),
            contract: nil
        )
    }
}
}
