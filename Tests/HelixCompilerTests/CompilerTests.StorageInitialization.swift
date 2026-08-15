import HelixBytecode
import HelixCore
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Canonical SIL local-storage initialization")
struct StorageInitialization {
    @Test("A write/destroy lifetime repeated in one loop block uses VM storage")
    func promotesSingleBlockLoopStorage() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0:
              %0 = alloc_stack $Int
              br bb1
            bb1:
              %1 = integer_literal $Builtin.Int64, 1
              store %1 to %0 : $*Int
              destroy_addr %0 : $*Int
              cond_br %2, bb1, bb2
            bb2:
              dealloc_stack %0 : $*Int
              return %3 : $()
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        #expect(plan.runtimeStorageRoots == ["%0"])
    }

    @Test("A conditionally initialized root emits conditional runtime cleanup")
    func promotesConditionalDeallocation() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let body = """
        bb0(%0 : @guaranteed $NSObject, %1 : $Bool):
          %2 = alloc_stack $NSObject
          cond_br %1, bb1, bb2
        bb1:
          store %0 to %2
          br bb3
        bb2:
          br bb3
        bb3:
          dealloc_stack %2
          %3 = tuple ()
          return %3
        """
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: body,
            directCalls: .empty,
            typeEnvironment: environment
        )
        #expect(plan.runtimeStorageRoots == ["%2"])
        #expect(plan.conditionalDestroyLines.count == 1)
        #expect(
            Set(plan.deallocationModes.values) == [.destroyIfInitialized]
        )

        let function = CanonicalSIL.Function(
            mangledName: "$sFixture18conditionalStorageyySbF",
            loweredType: "@convention(thin) (@guaranteed NSObject, Bool) -> ()",
            body: body
        )
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "conditionalStorage"
        )
        #expect(lowered.blocks.flatMap(\.instructions).contains {
            if case .destroyStackIfInitialized = $0 { return true }
            return false
        })
    }

    @Test("Branch-local deallocation shares one initialized runtime lifetime")
    func promotesBranchDeallocationCleanup() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let body = """
        bb0(%0 : @owned $NSObject, %1 : $Bool):
          %2 = alloc_stack $NSObject
          store %0 to %2
          cond_br %1, bb1, bb2
        bb1:
          dealloc_stack %2
          %3 = tuple ()
          return %3
        bb2:
          dealloc_stack %2
          %4 = tuple ()
          return %4
        """
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: body,
            directCalls: .empty,
            typeEnvironment: environment
        )
        #expect(plan.runtimeStorageRoots == ["%2"])
        #expect(Set(plan.deallocationModes.values) == [.destroy])

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture13branchCleanupyySb_SbtF",
                loweredType: "@convention(thin) (@owned NSObject, Bool) -> ()",
                body: body
            ),
            displayName: "branchCleanup",
            directCalls: .empty
        )
        let destroyCount = lowered.blocks
            .flatMap(\.instructions)
            .count { instruction in
                if case .destroyStack = instruction { return true }
                return false
            }
        #expect(destroyCount == 2)
    }

    @Test("An uninitialized deallocation-only cycle does not force runtime storage")
    func ignoresDeallocationOnlyCycles() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0:
              %0 = alloc_stack $Bool
              br bb1
            bb1:
              dealloc_stack %0 : $*Int
              cond_br %2, bb1, bb2
            bb2:
              return %3 : $()
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        #expect(plan.runtimeStorageRoots.isEmpty)
    }

    @Test("Deallocation distinguishes initialized and empty storage")
    func classifiesDeallocationCleanup() throws {
        let initialized = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : $Bool):
              %1 = alloc_stack $Bool
              store %0 to %1
              dealloc_stack %1
              return %2
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )
        #expect(Set(initialized.deallocationModes.values) == [.destroy])

        let empty = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : $Bool):
              %1 = alloc_stack $Bool
              store %0 to %1
              destroy_addr %1
              dealloc_stack %1
              return %2
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )
        #expect(Set(empty.deallocationModes.values) == [.none])
    }

    @Test("Duplicate CFG block identifiers fail as a stable diagnostic")
    func rejectsDuplicateBlockIdentifiers() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.StorageInitialization.analyze(
                body: """
                bb0:
                  %0 = alloc_stack $Bool
                  br bb1
                bb1:
                  store %1 to %0
                  br bb1
                bb1:
                  destroy_addr %0
                  return %2
                """,
                directCalls: .empty,
                typeEnvironment: .empty
            )
        }
    }

    @Test("Borrow-only loop temporaries do not become owned runtime storage")
    func ignoresCyclicStoreBorrow() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : $Bool):
              %1 = alloc_stack $Bool
              br bb1
            bb1:
              %2 = store_borrow %0 to %1
              end_borrow %2
              cond_br %0, bb1, bb2
            bb2:
              dealloc_stack %1
              return %3
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        #expect(plan.runtimeStorageRoots.isEmpty)
        #expect(plan.storeModes.isEmpty)
        #expect(plan.conditionalDestroyLines.isEmpty)
    }

    @Test("One apply can initialize multiple independent out addresses")
    func classifiesMultipleIndirectResultsPerCall() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : $*Int, %1 : $*Int):
              %2 = alloc_stack $Int
              %3 = alloc_stack $Int
              %4 = function_ref @$sSzsE20quotientAndRemainder10dividingByx0A0_x9remaindertx_tF : $@convention(method) <τ_0_0 where τ_0_0 : BinaryInteger> (@in_guaranteed τ_0_0, @in_guaranteed τ_0_0) -> (@out τ_0_0, @out τ_0_0)
              %5 = apply %4<Int>(%2, %3, %0, %1) : $@convention(method) <τ_0_0 where τ_0_0 : BinaryInteger> (@in_guaranteed τ_0_0, @in_guaranteed τ_0_0) -> (@out τ_0_0, @out τ_0_0)
              dealloc_stack %3
              dealloc_stack %2
              return %5
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        let call = try #require(
            plan.storeModes.first { $0.value.count == 2 }
        )
        #expect(call.value.values.allSatisfy { $0 == .initialize })
        #expect(plan.storeMode(at: call.key, address: "%2") == .initialize)
        #expect(plan.storeMode(at: call.key, address: "%3") == .initialize)
    }

    @Test("Store modes resolve through equivalent projected addresses")
    func resolvesProjectedStoreAliases() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : $Int):
              %1 = alloc_stack $Any
              %2 = init_existential_addr %1, $Int
              store %0 to %2
              destroy_addr %1
              dealloc_stack %1
              return %0
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        let storeLine = try #require(
            plan.storeModes.first { !$0.value.isEmpty }?.key
        )
        #expect(plan.storeMode(at: storeLine, address: "%1") == .initialize)
        #expect(plan.storeMode(at: storeLine, address: "%2") == .initialize)
    }

    @Test("Deep control-flow cycles are analyzed without recursive stack growth")
    func analyzesDeepCyclesIteratively() throws {
        let finalBlock = 4_096
        var lines = [
            "bb0:",
            "  %0 = alloc_stack $Bool",
            "  br bb1",
        ]
        for block in 1..<finalBlock {
            lines.append("bb\(block):")
            lines.append("  br bb\(block + 1)")
        }
        lines.append("bb\(finalBlock):")
        lines.append("  store %1 to %0")
        lines.append("  br bb1")

        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: lines.joined(separator: "\n"),
            directCalls: .empty,
            typeEnvironment: .empty
        )

        #expect(plan.runtimeStorageRoots == ["%0"])
    }

    @Test("Taking copy_addr reads promoted storage and ends its lifetime")
    func lowersRuntimeStorageTake() throws {
        let body = """
        bb0(%0 : $Int):
          %1 = alloc_stack $Int
          %2 = alloc_stack $Int
          store %0 to %1
          br bb1
        bb1:
          copy_addr [take] %1 to [init] %2
          dealloc_stack %1
          %3 = load [take] %2
          dealloc_stack %2
          return %3
        """
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: body,
            directCalls: .empty,
            typeEnvironment: .empty
        )
        #expect(plan.runtimeStorageRoots == ["%1"])
        #expect(plan.conditionalDestroyLines.isEmpty)

        let lowered = try CanonicalSIL.Lowerer().lower(
            .init(
                mangledName: "$s7Fixture11moveStorageyS2iF",
                loweredType: "@convention(thin) (Int) -> Int",
                body: body
            ),
            displayName: "moveStorage"
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        #expect(instructions.contains {
            if case .loadStack(_, _, .take) = $0 { return true }
            return false
        })
        #expect(!instructions.contains {
            if case let .destroyStack(slot) = $0 {
                return slot.rawValue == 0
            }
            return false
        })
    }

    @Test("A destructively projected Optional reinitializes runtime writeback")
    func reinitializesTakenOptionalPayloadWriteback() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7replaceySiSg_ACSitF",
            loweredType: "@convention(thin) (@owned Optional<Int>, Int) "
                + "-> @owned Optional<Int>",
            body: """
            bb0(%0 : @owned $Optional<Int>, %1 : $Int):
              %2 = alloc_stack $Optional<Int>
              store %0 to %2
              %3 = integer_literal $Builtin.Int1, -1
              %4 = integer_literal $Builtin.Int1, 0
              %5 = select_enum_addr %2, case #Optional.some!enumelt: %3, default %4 : $Builtin.Int1
              cond_br %5, bb1, bb2
            bb1:
              %6 = unchecked_take_enum_data_addr %2, #Optional.some!enumelt
              store %1 to %6
              store %1 to %6
              %7 = load [take] %2
              dealloc_stack %2
              return %7
            bb2:
              %8 = load [take] %2
              dealloc_stack %2
              return %8
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "Fixture.replace"
        )
        let some = try #require(
            lowered.blocks.first { $0.id.rawValue == 1 }
        )
        #expect(some.instructions.contains { instruction in
            if case .loadStack(_, _, .take) = instruction { return true }
            return false
        })
        let writebackModes: [Bytecode.StackStoreMode] = some.instructions
            .compactMap { instruction in
                guard case let .storeStack(_, _, mode) = instruction else {
                    return nil
                }
                return mode
            }
        #expect(writebackModes == [.initialize, .assign])
    }

    @Test("Indirect normal and error results initialize only their edges")
    func tracksIndirectApplicationResults() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0:
              %0 = alloc_stack $Any
              %1 = alloc_stack $Never
              try_apply %2(%0, %1) : $@convention(thin) () -> (@out Any, @error_indirect Never), normal bb1, error bb2
            bb1:
              destroy_addr %0
              dealloc_stack %1
              dealloc_stack %0
              return %3
            bb2:
              destroy_addr %1
              dealloc_stack %1
              dealloc_stack %0
              return %4
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        #expect(plan.runtimeStorageRoots.isEmpty)
        #expect(plan.conditionalDestroyLines.isEmpty)
    }

    @Test("Indirect results are discovered in every physical tuple position")
    func tracksNonleadingIndirectApplicationResults() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0:
              %0 = alloc_stack $Int
              %1 = apply %2(%0) : $@convention(thin) () -> (Bool, @out Int)
              destroy_addr %0
              dealloc_stack %0
              return %3
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        #expect(plan.runtimeStorageRoots.isEmpty)
        #expect(plan.conditionalDestroyLines.isEmpty)
    }

    @Test("Indirect call results bridge both continuations into value storage")
    func lowersIndirectCallDestinations() throws {
        let symbol = "$s7Fixture7forwardyypypKF"
        let callee = Bytecode.FunctionID(rawValue: 1)
        let effects = Core.Effects(mayThrow: true)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.any],
                resultType: .any,
                effects: effects,
                target: .function(callee)
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture11forwardOnceyypypKF",
            loweredType: "@convention(thin) (@owned Any) "
                + "-> (@out Any, @error any Error)",
            body: """
            bb0(%0 : $*Any, %1 : @owned $Any):
              %2 = alloc_stack $any Error
              %3 = function_ref @\(symbol) : $@convention(thin) (@owned Any) -> (@out Any, @error_indirect any Error)
              try_apply %3(%0, %2, %1) : $@convention(thin) (@owned Any) -> (@out Any, @error_indirect any Error), normal bb1, error bb2
            bb1(%4 : $()):
              dealloc_stack %2
              %5 = tuple ()
              return %5
            bb2:
              %6 = load [take] %2
              dealloc_stack %2
              throw %6
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "forwardOnce",
            directCalls: calls,
            expectedEffects: effects
        )
        let invocation = try #require(lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> (Bytecode.BlockID, Bytecode.BlockID)? in
            guard case let .tryApply(id, arguments, normal, error) = instruction,
                  id == callee,
                  arguments.count == 1
            else { return nil }
            return (normal, error)
        }.first)
        let normal = try #require(lowered.blocks.first { $0.id == invocation.0 })
        let error = try #require(lowered.blocks.first { $0.id == invocation.1 })
        #expect(normal.parameters.count == 1)
        #expect(error.parameters.count == 1)
        #expect(lowered.registerTypes[Int(normal.parameters[0].rawValue)] == .any)
        #expect(lowered.registerTypes[Int(error.parameters[0].rawValue)] == .string)
        #expect(normal.instructions.contains { instruction in
            guard case let .storeStack(_, source, mode) = instruction else {
                return false
            }
            return source == normal.parameters[0] && mode == .initialize
        })
        #expect(error.instructions.contains { instruction in
            guard case let .throwError(value) = instruction else { return false }
            return value == error.parameters[0]
        })
    }

    @Test("Indirect closure results use the same continuation storage bridge")
    func lowersIndirectClosureDestinations() throws {
        let symbol = "$s7Fixture11makeDynamicypKF"
        let callee = Bytecode.FunctionID(rawValue: 1)
        let effects = Core.Effects(mayThrow: true)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [],
                resultType: .any,
                effects: effects,
                target: .function(callee)
            ),
        ])
        let physicalClosure = "@callee_guaranteed () "
            + "-> (@out Any, @error_indirect any Error)"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture15runDynamicOnceypKF",
            loweredType: "@convention(thin) () "
                + "-> (@out Any, @error any Error)",
            body: """
            bb0(%0 : $*Any):
              %1 = alloc_stack $any Error
              %2 = function_ref @\(symbol) : $@convention(thin) () -> (@out Any, @error_indirect any Error)
              %3 = thin_to_thick_function %2 to $\(physicalClosure)
              try_apply %3(%0, %1) : $\(physicalClosure), normal bb1, error bb2
            bb1(%4 : $()):
              strong_release %3
              dealloc_stack %1
              %5 = tuple ()
              return %5
            bb2:
              strong_release %3
              %6 = load [take] %1
              dealloc_stack %1
              throw %6
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "runDynamicOnce",
            directCalls: calls,
            expectedEffects: effects
        )
        let invocation = try #require(lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> (Bytecode.BlockID, Bytecode.BlockID)? in
            guard case let .closureTryApply(_, arguments, normal, error)
                    = instruction,
                  arguments.isEmpty
            else { return nil }
            return (normal, error)
        }.first)
        let normal = try #require(lowered.blocks.first { $0.id == invocation.0 })
        let error = try #require(lowered.blocks.first { $0.id == invocation.1 })
        #expect(normal.parameters.count == 1)
        #expect(error.parameters.count == 1)
        #expect(lowered.registerTypes[Int(normal.parameters[0].rawValue)] == .any)
        #expect(lowered.registerTypes[Int(error.parameters[0].rawValue)] == .string)
        #expect(normal.instructions.contains { instruction in
            guard case let .storeStack(_, source, mode) = instruction else {
                return false
            }
            return source == normal.parameters[0] && mode == .initialize
        })
        #expect(error.instructions.contains { instruction in
            guard case let .throwError(value) = instruction else { return false }
            return value == error.parameters[0]
        })
    }

    @Test("An @in application argument ends its storage lifetime")
    func tracksOwnedApplicationArguments() throws {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.StorageInitialization.analyze(
                body: """
                bb0:
                  %0 = alloc_stack $Any
                  %1 = alloc_stack $Any
                  store %2 to %1
                  %3 = apply %4(%0, %1) : $@convention(thin) (@in Any) -> @out Any
                  destroy_addr %1
                  destroy_addr %0
                  dealloc_stack %1
                  dealloc_stack %0
                  return %5
                """,
                directCalls: .empty,
                typeEnvironment: .empty
            )
        }
    }

    @Test("A runtime-backed @in argument transfers with take semantics")
    func lowersRuntimeApplicationArgumentTake() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture7captureSbyShySiGzF",
            loweredType: "@convention(thin) (@inout_aliasable Set<Int>) -> Bool",
            body: """
            bb0(%0 : @closureCapture $*Set<Int>):
              %1 = alloc_stack $Int
              %2 = integer_literal $Builtin.Int64, 3
              %3 = struct $Int (%2)
              %4 = alloc_stack $Int
              store %3 to %4
              %5 = begin_access [modify] [static] %0
              %6 = function_ref @$sSh6insertySb8inserted_x17memberAfterInserttxnF : $@convention(method) <τ_0_0 where τ_0_0 : Hashable> (@in τ_0_0, @inout Set<τ_0_0>) -> (Bool, @out τ_0_0)
              %7 = apply %6<Int>(%1, %4, %5) : $@convention(method) <τ_0_0 where τ_0_0 : Hashable> (@in τ_0_0, @inout Set<τ_0_0>) -> (Bool, @out τ_0_0)
              end_access %5
              dealloc_stack %4
              dealloc_stack %1
              return %7
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "capture",
            kind: .concreteSpecialization
        )
        #expect(lowered.blocks.flatMap(\.instructions).contains { instruction in
            guard case let .loadStack(_, slot, mode) = instruction else {
                return false
            }
            return slot.rawValue == 1 && mode == .take
        })
    }

    @Test("A checked cast initializes its destination only on success")
    func tracksCheckedCastResultEdge() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : $*Any):
              %1 = alloc_stack $Int
              checked_cast_addr_br copy_on_success Any in %0 to Int in %1, bb1, bb2
            bb1:
              destroy_addr %1
              dealloc_stack %1
              return %2
            bb2:
              dealloc_stack %1
              return %3
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        #expect(plan.runtimeStorageRoots.isEmpty)
        #expect(plan.conditionalDestroyLines.isEmpty)
    }

    @Test("Malformed physical apply delimiters fail closed")
    func rejectsMalformedPhysicalApplicationType() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.StorageInitialization.analyze(
                body: """
                bb0:
                  %0 = alloc_stack $Any
                  %1 = apply %2(%0) : $@convention(thin) ((Int) -> @out Any
                  destroy_addr %0
                  dealloc_stack %0
                  return %3
                """,
                directCalls: .empty,
                typeEnvironment: .empty
            )
        }
    }
}
}
