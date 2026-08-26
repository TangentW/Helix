import Foundation
import HelixBytecode
import HelixCore
import HelixInterface
import HelixVerifier
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Default argument lowering")
struct DefaultArguments {
    @Test("One physical native symbol selects default-argument variants per call")
    func selectsPhysicalSymbolVariants() throws {
        let symbol = "$s7Fixture6invokeyySi_SitF"
        let helper = symbol + "fA_"
        let effects = Core.Effects()
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        func requirement(
            id: UInt32,
            parameters: [String],
            physicalTypes: [String],
            sources: [Core.NativeCall.ArgumentSource]
        ) throws -> Bytecode.ImportRequirement {
            try nativeRequirement(
                id: .init(rawValue: id),
                canonicalCallee: "Fixture.invoke(_:_:)",
                signature: .init(
                    parameters: parameters,
                    result: "Swift.Void"
                ),
                effects: effects,
                contract: contract,
                physicalParameterTypes: physicalTypes,
                physicalArgumentSources: sources
            )
        }
        let omittedID = Core.NativeImportID(rawValue: 0)
        let explicitID = Core.NativeImportID(rawValue: 1)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64],
                parameterProjection: .init(
                    physicalParameterCount: 2,
                    logicalParameterIndices: [1],
                    defaultArguments: [
                        .externalGenerator(
                            physicalParameterIndex: 0,
                            symbol: helper
                        ),
                    ]
                ),
                resultType: .void,
                target: .nativeImport(try requirement(
                    id: omittedID.rawValue,
                    parameters: ["Swift.Int"],
                    physicalTypes: ["Swift.Int", "Swift.Int"],
                    sources: [.defaultGenerator(helper), .argument(0)]
                ))
            ),
            .init(
                mangledName: symbol,
                parameterTypes: [.int64, .int64],
                resultType: .void,
                target: .nativeImport(try requirement(
                    id: explicitID.rawValue,
                    parameters: ["Swift.Int", "Swift.Int"],
                    physicalTypes: ["Swift.Int", "Swift.Int"],
                    sources: [.argument(0), .argument(1)]
                ))
            ),
        ])
        let ownerType = "@convention(thin) (Swift.Int, Swift.Int) -> ()"
        let helperType = "@convention(thin) () -> Swift.Int"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyySi_SitF",
            loweredType: "@convention(thin) (Swift.Int, Swift.Int) -> ()",
            body: """
            bb0(%0 : $Swift.Int, %1 : $Swift.Int):
              %2 = function_ref @\(helper) : $\(helperType)
              %3 = apply %2() : $\(helperType)
              %4 = function_ref @\(symbol) : $\(ownerType)
              %5 = apply %4(%3, %0) : $\(ownerType)
              %6 = function_ref @\(symbol) : $\(ownerType)
              %7 = apply %6(%1, %0) : $\(ownerType)
              %8 = tuple ()
              return %8
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "root",
            directCalls: calls
        )
        let imports = lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> Core.NativeImportID? in
            guard case let .nativeApply(_, id, _) = instruction else {
                return nil
            }
            return id
        }
        #expect(imports == [omittedID, explicitID])
    }

    @Test("Projected indirect SDK defaults retain exact storage provenance")
    func projectsIndirectExternalDefault() throws {
        let payloadID = Core.TypeID(rawValue: .sha256("Fixture.Payload"))
        let symbol = "$s7Fixture6invokeyyAA7PayloadV_SitF"
        let helper = symbol + "fA_"
        let importID = Core.NativeImportID(rawValue: 0)
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let requirement = try nativeRequirement(
            id: importID,
            canonicalCallee: "Fixture.invoke(_:_:)",
            signature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Void"
            ),
            effects: .init(),
            contract: contract,
            physicalParameterTypes: ["Fixture.Payload", "Swift.Int"],
            physicalArgumentSources: [
                .defaultGenerator(helper), .argument(0),
            ]
        )
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64],
                parameterProjection: .init(
                    physicalParameterCount: 2,
                    logicalParameterIndices: [1],
                    defaultArguments: [
                        .externalGenerator(
                            physicalParameterIndex: 0,
                            symbol: helper
                        ),
                    ]
                ),
                resultType: .void,
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["Payload": payloadID],
                kinds: [payloadID: .value]
            )
        let ownerType = "@convention(thin) "
            + "(@in_guaranteed Payload, Swift.Int) -> ()"
        let helperType = "@convention(thin) () -> @out Payload"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyySiF",
            loweredType: "@convention(thin) (Swift.Int) -> ()",
            body: """
            bb0(%0 : $Swift.Int):
              %1 = alloc_stack $Payload
              %2 = function_ref @\(helper) : $\(helperType)
              %3 = apply %2(%1) : $\(helperType)
              %4 = function_ref @\(symbol) : $\(ownerType)
              %5 = apply %4(%1, %0) : $\(ownerType)
              destroy_addr %1
              dealloc_stack %1
              %6 = tuple ()
              return %6
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "root",
            directCalls: calls
        )
        let invocation = try #require(
            lowered.blocks.flatMap(\.instructions).compactMap {
                instruction -> [Bytecode.Register]? in
                guard case let .nativeApply(_, id, arguments) = instruction,
                      id == importID
                else { return nil }
                return arguments
            }.first
        )
        #expect(invocation.count == 1)
        #expect(lowered.registerTypes[Int(invocation[0].rawValue)] == .int64)
    }

    @Test("Projected borrowed defaults retire value and closure releases")
    func retiresBorrowedExternalDefaultValues() throws {
        let stringOwner = "$s7Fixture13acceptStringyySSF"
        let closureOwner = "$s7Fixture14acceptClosureyyyycF"
        let stringHelper = stringOwner + "fA_"
        let closureHelper = closureOwner + "fA_"
        let effects = Core.Effects(mayAllocate: true)
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        func requirement(
            _ rawID: UInt32,
            helper: String,
            physicalType: String
        ) throws -> Bytecode.ImportRequirement {
            try nativeRequirement(
                id: .init(rawValue: rawID),
                canonicalCallee: "Fixture.acceptDefault\(rawID)()",
                signature: .init(parameters: [], result: "Swift.Void"),
                effects: effects,
                contract: contract,
                physicalParameterTypes: [physicalType],
                physicalArgumentSources: [.defaultGenerator(helper)]
            )
        }
        func binding(
            owner: String,
            helper: String,
            id: UInt32,
            physicalType: String
        ) throws -> CanonicalSIL.DirectCallBinding {
            .init(
                mangledName: owner,
                parameterTypes: [],
                parameterConventions: [],
                parameterProjection: .init(
                    physicalParameterCount: 1,
                    logicalParameterIndices: [],
                    defaultArguments: [
                        .externalGenerator(
                            physicalParameterIndex: 0,
                            symbol: helper
                        ),
                    ]
                ),
                resultType: .void,
                effects: effects,
                target: .nativeImport(try requirement(
                    id,
                    helper: helper,
                    physicalType: physicalType
                ))
            )
        }
        let calls = try CanonicalSIL.DirectCallTable([
            try binding(
                owner: stringOwner,
                helper: stringHelper,
                id: 0,
                physicalType: "Swift.String"
            ),
            try binding(
                owner: closureOwner,
                helper: closureHelper,
                id: 1,
                physicalType: "() -> Swift.Void"
            ),
        ])
        let stringHelperType = "@convention(thin) () -> @owned String"
        let stringOwnerType = "@convention(thin) (@guaranteed String) -> ()"
        let closureHelperType = "@convention(thin) "
            + "() -> @owned @callee_guaranteed () -> ()"
        let closureOwnerType = "@convention(thin) "
            + "(@guaranteed @callee_guaranteed () -> ()) -> ()"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = function_ref @\(stringHelper) : $\(stringHelperType)
              %1 = apply %0() : $\(stringHelperType)
              %2 = function_ref @\(stringOwner) : $\(stringOwnerType)
              %3 = apply %2(%1) : $\(stringOwnerType)
              release_value %1
              %4 = function_ref @\(closureHelper) : $\(closureHelperType)
              %5 = apply %4() : $\(closureHelperType)
              %6 = function_ref @\(closureOwner) : $\(closureOwnerType)
              %7 = apply %6(%5) : $\(closureOwnerType)
              strong_release %5
              %8 = tuple ()
              return %8
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "root",
            directCalls: calls,
            expectedEffects: effects
        )
        let invocations = lowered.blocks.flatMap(\.instructions).compactMap {
            instruction -> (Core.NativeImportID, [Bytecode.Register])? in
            guard case let .nativeApply(_, id, arguments) = instruction else {
                return nil
            }
            return (id, arguments)
        }
        #expect(invocations.map(\.0) == [
            .init(rawValue: 0), .init(rawValue: 1),
        ])
        #expect(invocations.allSatisfy { $0.1.isEmpty })
    }

    @Test("Projected native Optional.none defaults close their erased owner")
    func projectsInlineNativeOptionalDefault() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let symbol = "$s7Fixture6invokeyySo8NSObjectCSg_AEtF"
        let importID = Core.NativeImportID(rawValue: 0)
        let explicitImportID = Core.NativeImportID(rawValue: 1)
        let effects = Core.Effects(mayAllocate: true)
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let requirement = try nativeRequirement(
            id: importID,
            canonicalCallee: "Fixture.invoke(_:_:)",
            signature: .init(
                parameters: ["Foundation.NSObject"],
                result: "Swift.Void"
            ),
            effects: effects,
            contract: contract,
            physicalParameterTypes: [
                "Swift.Optional<Foundation.NSObject>",
                "Foundation.NSObject",
            ],
            physicalArgumentSources: [.optionalNone, .argument(0)]
        )
        let explicitRequirement = try nativeRequirement(
            id: explicitImportID,
            canonicalCallee: "Fixture.invoke(_:_:)",
            signature: .init(
                parameters: [
                    "Swift.Optional<Foundation.NSObject>",
                    "Foundation.NSObject",
                ],
                result: "Swift.Void"
            ),
            effects: effects,
            contract: contract
        )
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.native(objectType)],
                parameterConventions: [.owned],
                parameterProjection: .init(
                    physicalParameterCount: 2,
                    logicalParameterIndices: [1],
                    defaultArguments: [
                        .optionalNone(physicalParameterIndex: 0),
                    ]
                ),
                resultType: .void,
                effects: effects,
                target: .nativeImport(requirement)
            ),
            .init(
                mangledName: symbol,
                parameterTypes: [
                    .optional(.native(objectType)),
                    .native(objectType),
                ],
                parameterConventions: [.owned, .owned],
                resultType: .void,
                effects: effects,
                target: .nativeImport(explicitRequirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let physicalType = "@convention(thin) "
            + "(@owned Optional<NSObject>, @owned NSObject) -> ()"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyySo8NSObjectCF",
            loweredType: "@convention(thin) (@owned NSObject) -> ()",
            body: """
            bb0(%0 : @owned $NSObject):
              %1 = enum $Optional<NSObject>, #Optional.none!enumelt
              %2 = copy_value %1
              %3 = function_ref @\(symbol) : $\(physicalType)
              %4 = apply %3(%2, %0) : $\(physicalType)
              destroy_value %1
              %5 = tuple ()
              return %5
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "root",
            directCalls: calls,
            expectedEffects: effects
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let none = try #require(instructions.firstIndex {
            if case .makeOptionalNone = $0 { true } else { false }
        })
        let destroy = try #require(instructions.firstIndex {
            if case .destroyValue = $0 { true } else { false }
        })
        let apply = try #require(instructions.firstIndex {
            if case let .nativeApply(_, id, _) = $0 { id == importID }
            else { false }
        })
        #expect(none < destroy)
        #expect(destroy < apply)

        let mismatched = CanonicalSIL.Function(
            mangledName: "$s7Fixture8mismatchyySo8NSObjectCF",
            loweredType: "@convention(thin) (@owned NSObject) -> ()",
            body: """
            bb0(%0 : @owned $NSObject):
              %1 = enum $Optional<String>, #Optional.none!enumelt
              %2 = function_ref @\(symbol) : $\(physicalType)
              %3 = apply %2(%1, %0) : $\(physicalType)
              %4 = tuple ()
              return %4
            """
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
                mismatched,
                displayName: "mismatch",
                directCalls: calls,
                expectedEffects: effects
            )
        }
    }

    @Test("Projected borrowed Optional.none defaults retire one erased owner")
    func retiresBorrowedInlineNativeOptionalDefault() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let symbol = "$s7Fixture6invokeyySo8NSObjectCSg_AEtF"
        let importID = Core.NativeImportID(rawValue: 0)
        let effects = Core.Effects(mayAllocate: true)
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let requirement = try nativeRequirement(
            id: importID,
            canonicalCallee: "Fixture.invoke(_:_:)",
            signature: .init(
                parameters: ["Foundation.NSObject"],
                result: "Swift.Void"
            ),
            effects: effects,
            contract: contract,
            physicalParameterTypes: [
                "Swift.Optional<Foundation.NSObject>",
                "Foundation.NSObject",
            ],
            physicalArgumentSources: [.optionalNone, .argument(0)]
        )
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.native(objectType)],
                parameterConventions: [.owned],
                parameterProjection: .init(
                    physicalParameterCount: 2,
                    logicalParameterIndices: [1],
                    defaultArguments: [
                        .optionalNone(physicalParameterIndex: 0),
                    ]
                ),
                resultType: .void,
                effects: effects,
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let physicalType = "@convention(thin) "
            + "(@guaranteed Optional<NSObject>, @owned NSObject) -> ()"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyySo8NSObjectCF",
            loweredType: "@convention(thin) (@owned NSObject) -> ()",
            body: """
            bb0(%0 : @owned $NSObject):
              %1 = enum $Optional<NSObject>, #Optional.none!enumelt
              %2 = begin_borrow %1
              %3 = function_ref @\(symbol) : $\(physicalType)
              %4 = apply %3(%2, %0) : $\(physicalType)
              end_borrow %2
              destroy_value %1
              %5 = tuple ()
              return %5
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "root",
            directCalls: calls,
            expectedEffects: effects
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let apply = try #require(instructions.firstIndex {
            if case let .nativeApply(_, id, _) = $0 { id == importID }
            else { false }
        })
        let destroys = instructions.indices.filter {
            if case .destroyValue = instructions[$0] { true } else { false }
        }
        #expect(destroys.count == 1)
        #expect(destroys[0] < apply)
    }

    @Test("Borrowed explicit Optional.none closes its synthetic linear owner")
    func retiresBorrowedExplicitLinearOptionalNone() throws {
        let keyType = Core.TypeID(
            rawValue: .sha256("Foundation.URLResourceKey")
        )
        let symbol = "$s7Fixture6invokeyySaySo16NSURLResourceKeyaGSgF"
        let importID = Core.NativeImportID(rawValue: 0)
        let effects = Core.Effects(mayAllocate: true)
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let requirement = try nativeRequirement(
            id: importID,
            canonicalCallee: "Fixture.invoke(_:)",
            signature: .init(
                parameters: [
                    "Swift.Optional<Swift.Array<Foundation.URLResourceKey>>",
                ],
                result: "Swift.Void"
            ),
            effects: effects,
            contract: contract
        )
        let logicalType = Bytecode.ValueType.optional(
            .array(.native(keyType))
        )
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [logicalType],
                parameterConventions: [.owned],
                resultType: .void,
                effects: effects,
                target: .nativeImport(requirement)
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["URLResourceKey": keyType],
                kinds: [keyType: .value]
            )
        let physicalType = "@convention(thin) "
            + "(@guaranteed Optional<Array<URLResourceKey>>) -> ()"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = enum $Optional<Array<URLResourceKey>>, #Optional.none!enumelt
              %1 = function_ref @\(symbol) : $\(physicalType)
              %2 = apply %1(%0) : $\(physicalType)
              %3 = tuple ()
              return %3
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "root",
            directCalls: calls,
            expectedEffects: effects
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let none = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .makeOptionalNone(result) = instruction else {
                return nil
            }
            return result
        }.first)
        let boundaryCopy = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .copyValue(result, source) = instruction,
                  source == none
            else { return nil }
            return result
        }.first)
        let applyIndex = try #require(instructions.firstIndex { instruction in
            guard case let .nativeApply(_, id, arguments) = instruction else {
                return false
            }
            return id == importID && arguments == [boundaryCopy]
        })
        let destroyIndex = try #require(
            instructions.firstIndex(of: .destroyValue(none))
        )
        #expect(applyIndex < destroyIndex)
        #expect(instructions.count { $0 == .destroyValue(none) } == 1)
    }

    @Test("Payload-free linear Optional copies and moves retain exact lifetimes")
    func tracksCopiedAndMovedLinearOptionalNone() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = enum $Optional<NSObject>, #Optional.none!enumelt
              %1 = copy_value %0
              %2 = move_value %1
              %3 = tuple ()
              return %3
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(function, displayName: "root")
        let instructions = lowered.blocks.flatMap(\.instructions)
        let none = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .makeOptionalNone(result) = instruction else {
                return nil
            }
            return result
        }.first)
        let copied = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .copyValue(result, source) = instruction,
                  source == none
            else { return nil }
            return result
        }.first)
        let moved = try #require(instructions.compactMap { instruction
            -> Bytecode.Register? in
            guard case let .moveValue(result, source) = instruction,
                  source == copied
            else { return nil }
            return result
        }.first)
        #expect(instructions.count { $0 == .destroyValue(none) } == 1)
        #expect(instructions.count { $0 == .destroyValue(copied) } == 0)
        #expect(instructions.count { $0 == .destroyValue(moved) } == 1)
    }

    @Test("Payload-free linear Optional ownership transfers through block arguments")
    func transfersLinearOptionalNoneThroughBranch() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = enum $Optional<NSObject>, #Optional.none!enumelt
              br bb1(%0 : $Optional<NSObject>)
            bb1(%1 : $Optional<NSObject>):
              release_value %1
              %2 = tuple ()
              return %2
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(function, displayName: "root")
        let instructions = lowered.blocks.flatMap(\.instructions)
        let blockParameter = try #require(lowered.blocks.first {
            $0.id == .init(rawValue: 1)
        }?.parameters.first)
        #expect(instructions.contains(.destroyValue(blockParameter)))
    }

    @Test("Payload-free linear Optional ownership follows either conditional edge")
    func transfersLinearOptionalNoneThroughConditionalBranch() throws {
        let objectType = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["NSObject": objectType],
                kinds: [objectType: .reference]
            )
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4rootyySbF",
            loweredType: "@convention(thin) (Bool) -> ()",
            body: """
            bb0(%0 : $Bool):
              %1 = enum $Optional<NSObject>, #Optional.none!enumelt
              cond_br %0, bb1(%1 : $Optional<NSObject>), bb2(%1 : $Optional<NSObject>)
            bb1(%2 : $Optional<NSObject>):
              release_value %2
              %3 = tuple ()
              return %3
            bb2(%4 : $Optional<NSObject>):
              release_value %4
              %5 = tuple ()
              return %5
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(function, displayName: "root")
        for blockID: Bytecode.BlockID in [
            .init(rawValue: 1), .init(rawValue: 2),
        ] {
            let block = try #require(lowered.blocks.first { $0.id == blockID })
            let parameter = try #require(block.parameters.first)
            #expect(block.instructions.contains(.destroyValue(parameter)))
        }
    }

    @Test("PatchCompiler links a reachable default argument generator into HLBC")
    func linksDefaultArgumentGenerator() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-default-argument-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            @inline(never) public func supplied(_ value: Int = 7) -> Int { value }
            @inline(never) public func transform(_ value: Int) -> Int { value + supplied() }
            """.utf8
        ).write(to: sourceURL)

        let canonicalSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "DefaultArgumentFixture",
            purpose: .implementationIdentity
        )
        let file = try CanonicalSIL.File(text: canonicalSIL)
        let transform = try #require(file.functions.first {
            $0.mangledName.contains("transform")
                && !ReleaseCompiler.ImplementationFingerprint
                    .isCompilerGeneratedSymbol($0.mangledName)
        })
        let supplied = try #require(file.functions.first {
            $0.mangledName.contains("supplied")
                && !ReleaseCompiler.ImplementationFingerprint
                    .isCompilerGeneratedSymbol($0.mangledName)
        })
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.default-argument",
            buildNumber: "1",
            seed: "fixture"
        )
        let rootEntry = Core.EntryIndex(rawValue: 0)
        let suppliedEntry = Core.EntryIndex(rawValue: 1)
        let rootKey = try functionKey(
            namespace: namespace,
            declaration: "func transform(_: Int) -> Int"
        )
        let suppliedKey = try functionKey(
            namespace: namespace,
            declaration: "func supplied(_: Int) -> Int"
        )
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: supplied.mangledName,
                parameterTypes: [.int64],
                resultType: .int64,
                target: .entry(suppliedEntry)
            ),
        ])
        let shellHash = Core.Digest.sha256("helix-default-argument-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-default-argument-fixture"
        )
        let compiled = try PatchCompiler.Driver().compile(
            .init(
                canonicalSIL: canonicalSIL,
                mangledName: transform.mangledName,
                displayName: "transform",
                functionKey: rootKey,
                entryIndex: rootEntry,
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                directCalls: directCalls,
                sourceFileLogicalID: "Patch.swift"
            )
        )

        let generated = try #require(compiled.module.functions.first {
            $0.kind == .concreteSpecialization && $0.name.contains("fA")
        })
        #expect(compiled.module.functions.count == 2)
        #expect(generated.parameterRegisters.isEmpty)
        #expect(generated.resultType == .int64)
        #expect(compiled.disassembly.contains("entry_apply #\(suppliedEntry.rawValue)"))

        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: compiled.module.capabilities,
            entries: [
                .init(
                    index: rootEntry,
                    key: rootKey,
                    parameterTypes: [.int64],
                    parameterConventions: [.owned],
                    resultType: .int64
                ),
                .init(
                    index: suppliedEntry,
                    key: suppliedKey,
                    parameterTypes: [.int64],
                    parameterConventions: [.owned],
                    resultType: .int64
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: compiled.bytecode,
            shell: shell,
            policy: .init(acceptedCapabilities: compiled.module.capabilities)
        )
        let interpreter = VM.Interpreter(entryInvocation: { entry, arguments, _ in
            guard entry == suppliedEntry, arguments.count == 1 else {
                return .trapped(.unknownEntry(entry))
            }
            return .returned(arguments[0])
        })
        #expect(
            interpreter.invoke(
                entry: rootEntry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 10, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Swift generator classification covers functions, methods, and initializers")
    func classifiesCommonDefaultArgumentOwners() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-default-owner-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Defaults.swift")
        try Data(
            """
            public struct Counter {
                public var value: Int

                public init(seed: Int, step: Int = 1) {
                    value = seed + step
                }

                public func adding(_ input: Int, offset: Int = 2) -> Int {
                    value + input + offset
                }

                public static func scaled(_ input: Int, factor: Int = 3) -> Int {
                    input * factor
                }
            }

            public func adjusted(_ input: Int, delta: Int = 4) -> Int {
                input + delta
            }
            """.utf8
        ).write(to: sourceURL)

        let canonicalSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "DefaultOwnerFixture",
            purpose: .implementationIdentity
        )
        let silFile = try CanonicalSIL.File(text: canonicalSIL)
        let generators = silFile.functions.filter {
            ReleaseCompiler.ImplementationFingerprint
                .isDefaultArgumentGenerator($0.mangledName)
        }

        #expect(generators.count == 4)
        #expect(generators.allSatisfy { $0.mangledName.last == "_" })
        #expect(generators.allSatisfy { !$0.body.isEmpty })
        #expect(generators.allSatisfy { generator in
            ReleaseCompiler.ImplementationFingerprint
                .defaultArgumentOwners(of: generator.mangledName)
                .contains { silFile.function(mangledName: $0) != nil }
        })
    }

    private func functionKey(
        namespace: Core.ShellNamespaceID,
        declaration: String
    ) throws -> Core.FunctionKey {
        try Core.FunctionKey.derive(
            namespace: namespace,
            module: "DefaultArgumentFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: declaration,
            loweredSignature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int"
            ),
            role: .function
        )
    }

    private func nativeRequirement(
        id: Core.NativeImportID,
        canonicalCallee: String,
        signature: Core.LoweredSignature,
        effects: Core.Effects,
        contract: Core.NativeImportContract,
        physicalParameterTypes: [String]? = nil,
        physicalArgumentSources: [Core.NativeCall.ArgumentSource]? = nil
    ) throws -> Bytecode.ImportRequirement {
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: canonicalCallee,
            signature: signature,
            effects: effects,
            contract: contract,
            physicalParameterTypes: physicalParameterTypes,
            physicalArgumentSources: physicalArgumentSources
        )
        return .init(
            id: id,
            key: try Core.NativeCall.Key.derive(descriptor: descriptor),
            descriptor: descriptor,
            contract: contract
        )
    }
}
}
