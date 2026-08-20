import HelixBytecode
import HelixCore
import HelixVM
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

    @Test("A conditional projected lifetime lowers to address-local cleanup")
    func lowersConditionalProjectedDestroy() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let body = """
        bb0(%0 : @owned $NSObject, %1 : $Bool):
          %2 = alloc_stack $(NSObject, Int)
          %3 = tuple_element_addr %2, 0
          cond_br %1, bb1, bb2
        bb1:
          store %0 to [init] %3
          br bb3
        bb2:
          destroy_value %0
          br bb3
        bb3:
          destroy_addr %3
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
        #expect(plan.conditionalDestroyLines.count == 1)

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture27conditionalProjectedStorageyySo8NSObjectC_SbtF",
                loweredType: "@convention(thin) (@owned NSObject, Bool) -> ()",
                body: body
            ),
            displayName: "conditionalProjectedStorage"
        )
        #expect(lowered.blocks.flatMap(\.instructions).contains {
            if case .destroyAddressIfInitialized = $0 { return true }
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

    @Test("Canonical unqualified loads recover erased take ownership")
    func recoversForwardingUnqualifiedLoads() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let body = """
        bb0(%0 : @owned $NSObject):
          %1 = alloc_stack $NSObject
          store %0 to %1
          %2 = load %1
          dealloc_stack %1
          return %2
        """
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: body,
            directCalls: .empty,
            typeEnvironment: environment
        )

        #expect(plan.forwardingLoadLines.count == 1)
        #expect(Set(plan.deallocationModes.values) == [.none])

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture7forwardySo8NSObjectCADF",
                loweredType: "@convention(thin) (@owned NSObject) -> @owned NSObject",
                body: body
            ),
            displayName: "forward"
        )
        #expect(!lowered.blocks.flatMap(\.instructions).contains {
            if case .copyValue = $0 { return true }
            return false
        })
        #expect(!lowered.blocks.flatMap(\.instructions).contains {
            if case .destroyValue = $0 { return true }
            return false
        })
    }

    @Test("Address use prevents unqualified load forwarding")
    func preservesReadOnlyUnqualifiedLoads() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let body = """
        bb0(%0 : @owned $NSObject):
          %1 = alloc_stack $NSObject
          store %0 to %1
          %2 = load %1
          strong_retain %2
          destroy_addr %1
          dealloc_stack %1
          return %2
        """
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: body,
            directCalls: .empty,
            typeEnvironment: environment
        )

        #expect(plan.forwardingLoadLines.isEmpty)
        #expect(Set(plan.deallocationModes.values) == [.none])

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture4copyySo8NSObjectCADF",
                loweredType: "@convention(thin) (@owned NSObject) "
                    + "-> @owned NSObject",
                body: body
            ),
            displayName: "copy"
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        #expect(instructions.filter { instruction in
            if case .copyValue = instruction { return true }
            return false
        }.count == 1)
        #expect(instructions.filter { instruction in
            if case .destroyValue = instruction { return true }
            return false
        }.count == 1)
    }

    @Test("Compiler-only assignment releases the replaced linear owner")
    func releasesReplacedCompilerStorage() throws {
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
                mangledName: "$s7Fixture7replaceySo8NSObjectCAD_ADtF",
                loweredType: "@convention(thin) (@owned NSObject, @owned NSObject) -> @owned NSObject",
                body: """
                bb0(%0 : @owned $NSObject, %1 : @owned $NSObject):
                  %2 = alloc_stack $NSObject
                  store %0 to %2
                  store %1 to %2
                  %3 = load [take] %2
                  dealloc_stack %2
                  return %3
                """
            ),
            displayName: "replace"
        )
        let destroyed = lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> Bytecode.Register? in
            if case let .destroyValue(value) = instruction { return value }
            return nil
        }

        #expect(destroyed == [.init(rawValue: 0)])
    }

    @Test("Nested tuple storage materializes projections formed before initialization")
    func materializesEarlyNestedTupleProjection() throws {
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
                mangledName: "$s7Fixture6nestedSo8NSObjectCAD_SitF",
                loweredType: "@convention(thin) (@owned NSObject, Int) "
                    + "-> @owned NSObject",
                body: """
                bb0(%0 : @owned $NSObject, %1 : $Int):
                  %2 = alloc_stack $((Int, NSObject), Int)
                  %3 = tuple_element_addr %2, 0
                  %4 = tuple_element_addr %3, 1
                  %5 = tuple_element_addr %3, 0
                  %6 = tuple_element_addr %2, 1
                  %7 = tuple (%1, %0)
                  %8 = tuple (%7, %1)
                  store %8 to %2
                  %9 = load [take] %4
                  %10 = load [take] %5
                  %11 = load [take] %6
                  dealloc_stack %2
                  return %9
                """
            ),
            displayName: "nested"
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let unpacks = instructions.compactMap { instruction
            -> (results: [Bytecode.Register], tuple: Bytecode.Register)? in
            guard case let .unpackTuple(results, tuple) = instruction else {
                return nil
            }
            return (results, tuple)
        }
        let outer = try #require(unpacks.first)
        let inner = try #require(unpacks.dropFirst().first)
        let returned = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .returnValue(value) = instruction else { return nil }
            return value
        }.first)

        #expect(unpacks.count == 2)
        #expect(inner.tuple == outer.results[0])
        #expect(returned == inner.results[1])
        #expect(!instructions.contains { instruction in
            guard case let .destroyValue(value) = instruction else {
                return false
            }
            return value == inner.tuple
        })
    }

    @Test("Aggregate assignment destroys a recursively rebuilt prior owner")
    func releasesRebuiltTupleStorageOnAssignment() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let nativeType = Bytecode.ValueType.native(objectType)
        let tupleType = Bytecode.ValueType.tuple([nativeType, nativeType])
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            .init(
                mangledName: "$s7Fixture7replaceSo8NSObjectC_ADtAF_AFtF",
                loweredType: "@convention(thin) "
                    + "(@owned NSObject, @owned NSObject, "
                    + "@owned NSObject, @owned NSObject) "
                    + "-> @owned (NSObject, NSObject)",
                body: """
                bb0(%0 : @owned $NSObject, %1 : @owned $NSObject, %2 : @owned $NSObject, %3 : @owned $NSObject):
                  %4 = alloc_stack $(NSObject, NSObject)
                  %5 = tuple_element_addr %4, 0
                  %6 = tuple_element_addr %4, 1
                  store %0 to %5
                  store %1 to %6
                  %7 = tuple (%2, %3)
                  store %7 to [assign] %4
                  %8 = load [take] %4
                  dealloc_stack %4
                  return %8
                """
            ),
            displayName: "replace"
        )
        let destroyed = lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> Bytecode.Register? in
            guard case let .destroyValue(value) = instruction else { return nil }
            return value
        }

        #expect(destroyed.count == 1)
        let priorOwner = try #require(destroyed.first)
        #expect(lowered.registerTypes[Int(priorOwner.rawValue)] == tupleType)
        #expect(!lowered.parameterRegisters.contains(priorOwner))
    }

    @Test("Nested tuple mutable captures share recursive storage reconstruction")
    func executesNestedTupleMutableCapture() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func updateNestedCapture(_ value: String) -> String {
                var state = ((1, value), 2)
                let update = {
                    state.0.1 += "!"
                }
                update()
                return state.0.1
            }
            """,
            functionName: "updateNestedCapture",
            moduleName: "HelixNestedTupleCapture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.string("value")]
            ) == .returned(.string("value!"))
        )
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

    @Test("Indirect tuple output fields share field-sensitive initialization")
    func classifiesIndirectTupleOutputFields() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : $*(Int, String), %1 : $Int, %2 : $Int, %3 : $String):
              %4 = tuple_element_addr %0, 0
              %5 = tuple_element_addr %0, 1
              store %1 to [init] %4
              store %2 to [assign] %4
              store %3 to [init] %5
              %6 = tuple ()
              return %6
            """,
            directCalls: .empty,
            typeEnvironment: .empty,
            indirectResultType: .tuple([.int64, .string])
        )

        let writes = plan.storeModes.sorted { $0.key < $1.key }
        let firstFieldModes = writes.compactMap { item in
            item.value.first { $0.key.path == [0] }?.value
        }
        let secondFieldModes = writes.compactMap { item in
            item.value.first { $0.key.path == [1] }?.value
        }
        #expect(firstFieldModes == [.initialize, .assign])
        #expect(secondFieldModes == [.initialize])
        #expect(plan.addressTargets["%4"]?.root == "%0")
        #expect(plan.addressTargets["%5"]?.root == "%0")
    }

    @Test("Malformed indirect output parameters fail closed")
    func rejectsMalformedIndirectOutputParameters() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.StorageInitialization.analyze(
                body: """
                bb0(invalid, %0 : $Int):
                  return %0
                """,
                directCalls: .empty,
                typeEnvironment: .empty,
                indirectResultType: .int64
            )
        }
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

    @Test("An inout application preserves initialized local storage")
    func tracksInitializedInoutApplicationArguments() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : $Int):
              %1 = alloc_stack $Int
              store %0 to %1
              %2 = function_ref @$s7Fixture6modifyyySizF : $@convention(thin) (@inout_aliasable Int) -> ()
              %3 = apply %2(%1) : $@convention(thin) (@inout_aliasable Int) -> ()
              %4 = load [take] %1
              dealloc_stack %1
              return %4
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        #expect(plan.runtimeStorageRoots.isEmpty)
    }

    @Test("An inout application rejects uninitialized local storage")
    func rejectsUninitializedInoutApplicationArguments() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.StorageInitialization.analyze(
                body: """
                bb0:
                  %0 = alloc_stack $Int
                  %1 = function_ref @$s7Fixture6modifyyySizF : $@convention(thin) (@inout Int) -> ()
                  %2 = apply %1(%0) : $@convention(thin) (@inout Int) -> ()
                  dealloc_stack %0
                  %3 = tuple ()
                  return %3
                """,
                directCalls: .empty,
                typeEnvironment: .empty
            )
        }
    }

    @Test("Direct calls reject overlapping inout storage")
    func rejectsOverlappingInoutApplicationArguments() throws {
        let symbol = "$s7Fixture6mutateyySiz_SiztF"
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.address(.int64), .address(.int64)],
                resultType: .void,
                target: .function(.init(rawValue: 1))
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyS2iF",
            loweredType: "@convention(thin) (Int) -> Int",
            body: """
            bb0(%0 : $Int):
              %1 = alloc_stack $Int
              store %0 to %1
              %2 = function_ref @\(symbol) : $@convention(thin) (@inout Int, @inout Int) -> ()
              %3 = apply %2(%1, %1) : $@convention(thin) (@inout Int, @inout Int) -> ()
              %4 = load [take] %1
              dealloc_stack %1
              return %4
            """
        )

        do {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.run",
                directCalls: calls
            )
            Issue.record("overlapping inout arguments unexpectedly lowered")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains("overlapping inout arguments"))
        }
    }

    @Test("An inout mutation reconstructs a destructively projected enum")
    func tracksInoutDetachedEnumPayloadWriteback() throws {
        let plan = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : @owned $Optional<Int>):
              %1 = alloc_stack $Optional<Int>
              store %0 to %1
              %2 = unchecked_take_enum_data_addr %1, #Optional.some!enumelt
              %3 = function_ref @$s7Fixture6modifyyySizF : $@convention(thin) (@inout Int) -> ()
              %4 = apply %3(%2) : $@convention(thin) (@inout Int) -> ()
              %5 = load [take] %1
              dealloc_stack %1
              return %5
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        #expect(plan.detachedPayloadUses["%2"] == .modify)
    }

    @Test("Detached enum payload effects follow their physical consumers")
    func classifiesDetachedEnumPayloadConsumers() throws {
        let read = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : @owned $Optional<Int>):
              %1 = alloc_stack $Optional<Int>
              store %0 to %1
              %2 = unchecked_take_enum_data_addr %1, #Optional.some!enumelt
              %3 = load [trivial] %2
              %4 = load [take] %1
              dealloc_stack %1
              return %4
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )
        let take = try CanonicalSIL.StorageInitialization.analyze(
            body: """
            bb0(%0 : @owned $Optional<Int>):
              %1 = alloc_stack $Optional<Int>
              store %0 to %1
              %2 = unchecked_take_enum_data_addr %1, #Optional.some!enumelt
              %3 = load [take] %2
              dealloc_stack %1
              return %3
            """,
            directCalls: .empty,
            typeEnvironment: .empty
        )

        #expect(read.detachedPayloadUses["%2"] == .read)
        #expect(take.detachedPayloadUses["%2"] == .take)
    }

    @Test("Detached payloads reject mixed take and modify lifetimes")
    func rejectsMixedDetachedEnumPayloadConsumers() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.StorageInitialization.analyze(
                body: """
                bb0(%0 : @owned $Optional<Int>, %1 : $Int):
                  %2 = alloc_stack $Optional<Int>
                  store %0 to %2
                  %3 = unchecked_take_enum_data_addr %2, #Optional.some!enumelt
                  store %1 to %3
                  %4 = load [take] %3
                  dealloc_stack %2
                  return %4
                """,
                directCalls: .empty,
                typeEnvironment: .empty
            )
        }
    }

    @Test("Projected Optional writes rebuild nested patch-local aggregates")
    func executesProjectedOptionalAggregateWriteback() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            struct Leaf {
                var value: Int
            }

            struct Payload {
                var value: Int
                var leaf: Leaf
            }

            public func updateOptional(
                _ seed: Int,
                present: Bool
            ) -> (Int?, Int?) {
                var payload = present
                    ? Payload(value: seed, leaf: Leaf(value: seed))
                    : nil
                payload?.value = 7
                payload?.leaf.value = 8
                return (payload?.value, payload?.leaf.value)
            }
            """,
            functionName: "updateOptional",
            moduleName: "HelixAggregateWriteback"
        )
        let seed = VM.Value.integer(
            try .init(signed: 3, bitWidth: 64, isSigned: true)
        )
        let seven = VM.Value.integer(
            try .init(signed: 7, bitWidth: 64, isSigned: true)
        )
        let eight = VM.Value.integer(
            try .init(signed: 8, bitWidth: 64, isSigned: true)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [seed, .bool(true)]
            ) == .returned(
                .tuple([.optional(seven), .optional(eight)])
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [seed, .bool(false)]
            ) == .returned(
                .tuple([.optional(nil), .optional(nil)])
            )
        )
    }

    @Test("Nested Optional fields support ordinary mutating helpers")
    func executesProjectedOptionalMutatingHelpers() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            struct Counter {
                var value: Int

                mutating func add(_ delta: Int) {
                    value += delta
                }
            }

            struct Payload {
                var first: Counter
                var second: Counter
            }

            public func mutateOptional(
                _ seed: Int,
                present: Bool
            ) -> (Int?, Int?) {
                var payload = present
                    ? Payload(
                        first: Counter(value: seed),
                        second: Counter(value: seed)
                    )
                    : nil
                payload?.first.add(2)
                payload?.second.add(3)
                return (payload?.first.value, payload?.second.value)
            }
            """,
            functionName: "mutateOptional",
            moduleName: "HelixMutatingHelpers"
        )
        let seed = VM.Value.integer(
            try .init(signed: 5, bitWidth: 64, isSigned: true)
        )
        let seven = VM.Value.integer(
            try .init(signed: 7, bitWidth: 64, isSigned: true)
        )
        let eight = VM.Value.integer(
            try .init(signed: 8, bitWidth: 64, isSigned: true)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [seed, .bool(true)]
            ) == .returned(
                .tuple([.optional(seven), .optional(eight)])
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [seed, .bool(false)]
            ) == .returned(
                .tuple([.optional(nil), .optional(nil)])
            )
        )
    }

    @Test("Disjoint inout fields rebuild their ordinary aggregate")
    func executesDisjointCompilerInoutWriteback() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            struct Counter {
                var value: Int
            }

            struct Payload {
                var first: Counter
                var second: Counter
            }

            private func update(
                _ first: inout Counter,
                _ second: inout Counter
            ) {
                first.value += 2
                second.value += 3
            }

            public func mutateFields(_ seed: Int) -> (Int, Int) {
                var payload = Payload(
                    first: Counter(value: seed),
                    second: Counter(value: seed)
                )
                update(&payload.first, &payload.second)
                let snapshot = payload
                return (snapshot.first.value, snapshot.second.value)
            }
            """,
            functionName: "mutateFields",
            moduleName: "HelixDisjointInoutWriteback"
        )
        let seed = VM.Value.integer(
            try .init(signed: 5, bitWidth: 64, isSigned: true)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [seed]
            ) == .returned(
                .tuple([
                    .integer(
                        try .init(signed: 7, bitWidth: 64, isSigned: true)
                    ),
                    .integer(
                        try .init(signed: 8, bitWidth: 64, isSigned: true)
                    ),
                ])
            )
        )
    }

    @Test("Only the first local-class field write initializes storage")
    func keepsPostInitializationMutationAsAssignment() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Box {
                var value: Int
                init(value: Int) {
                    self.value = value
                    self.value += 1
                }
            }
            public func initializedThenMutated(_ value: Int) -> Int {
                Box(value: value).value
            }
            """,
            functionName: "initializedThenMutated"
        )
        let result = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [try integer(23)]
        )
        #expect(result == .returned(try integer(24)))
        let modes = fixture.image.module.functions.flatMap(\.blocks)
            .flatMap(\.instructions)
            .compactMap { instruction -> Bytecode.StackStoreMode? in
                guard case let .storeAddress(_, _, mode) = instruction else {
                    return nil
                }
                return mode
            }
        #expect(modes.contains(.initialize))
        #expect(modes.contains(.assign))
    }

    @Test("A default-initialized class field is assigned rather than initialized twice")
    func assignsDefaultInitializedClassField() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Box {
                var value = 1
                init(value: Int) { self.value = value }
            }
            public func replaceDefaultValue(_ value: Int) -> Int {
                Box(value: value).value
            }
            """,
            functionName: "replaceDefaultValue"
        )
        let result = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [try integer(31)]
        )
        #expect(result == .returned(try integer(31)))
    }

    @Test("Class field initialization is definite across control-flow branches")
    func initializesClassFieldAcrossBranches() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Box {
                let value: Int
                init(first: Int, second: Int, chooseFirst: Bool) {
                    if chooseFirst {
                        value = first
                    } else {
                        value = second
                    }
                }
            }
            public func chooseInitializedValue(
                _ first: Int,
                _ second: Int,
                _ chooseFirst: Bool
            ) -> Int {
                Box(
                    first: first,
                    second: second,
                    chooseFirst: chooseFirst
                ).value
            }
            """,
            functionName: "chooseInitializedValue"
        )
        let interpreter = VM.Interpreter()
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(7), try integer(19), .bool(true)]
            ) == .returned(try integer(7))
        )
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(7), try integer(19), .bool(false)]
            ) == .returned(try integer(19))
        )
        let modes = fixture.image.module.functions.flatMap(\.blocks)
            .flatMap(\.instructions)
            .compactMap { instruction -> Bytecode.StackStoreMode? in
                guard case let .storeAddress(_, _, mode) = instruction else {
                    return nil
                }
                return mode
            }
        #expect(modes.filter { $0 == .initialize }.count == 2)
        #expect(!modes.contains(.assign))
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

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
