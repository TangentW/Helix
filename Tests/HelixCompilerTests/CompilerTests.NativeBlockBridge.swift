import HelixBytecode
import HelixCore
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Native block bridge recognition")
struct NativeBlockBridge {
    @Test("Recognizes only compiler block-storage and noescape thunks")
    func recognizesCompilerThunks() {
        let storage = "$@convention(c) "
            + "(@inout_aliasable @block_storage @callee_guaranteed "
            + "(Swift.Bool) -> (), Swift.Bool) -> ()"
        #expect(CanonicalSIL.ClosureReabstraction.compilerThunkKind(
            symbol: "$s7FixtureyySbXEfU_ToTR",
            loweredType: storage
        ) == .storageInvoke)
        #expect(CanonicalSIL.ClosureReabstraction.compilerThunkKind(
            symbol: "$s7FixtureyySbXEfU_To",
            loweredType: storage
        ) == nil)

        let adapter = "$@convention(thin) "
            + "(@guaranteed @noescape @callee_guaranteed @Sendable "
            + "@MainActor (Swift.Bool) -> ()) -> ()"
        #expect(CanonicalSIL.ClosureReabstraction.compilerThunkKind(
            symbol: "$s7FixtureyySbXEfU_TR",
            loweredType: adapter
        ) == .nonescapingAdapter)
        #expect(CanonicalSIL.ClosureReabstraction
            .nonescapingAdapterClosureType(in: adapter)
            == "@MainActor (Swift.Bool) -> ()")

        let higherOrderAdapter = "$@convention(thin) "
            + "(@guaranteed @noescape @callee_guaranteed (Swift.Int) "
            + "-> @owned @callee_guaranteed (Swift.String) -> Swift.Bool) "
            + "-> @owned @callee_guaranteed (Swift.String) -> Swift.Bool"
        #expect(
            CanonicalSIL.ClosureReabstraction.nonescapingAdapterClosureType(
                in: higherOrderAdapter
            ) == "(Swift.Int) -> @owned @callee_guaranteed (Swift.String) "
                + "-> Swift.Bool"
        )
    }

    @Test("Rejects malformed or semantically different noescape adapters")
    func rejectsInvalidAdapters() {
        let invalid = [
            "$@convention(thin) (@callee_guaranteed (Swift.Bool) -> ()) -> ()",
            "$@convention(thin) (@noescape @callee_guaranteed (Swift.Bool) -> (), Swift.Int) -> ()",
            "$@convention(thin) (@noescape @callee_guaranteed (Swift.Bool) -> Swift.Int) -> ()",
            "$@convention(method) (@noescape @callee_guaranteed () -> ()) -> ()",
            "$@convention(thin) (@noescape @callee_guaranteed (Swift.Bool -> ()) -> ()",
            "$@convention(thin) (@noescape @callee_guaranteed @Fixture.CustomActor () -> ()) -> ()",
        ]
        for type in invalid {
            #expect(CanonicalSIL.ClosureReabstraction
                .nonescapingAdapterClosureType(in: type) == nil)
            #expect(CanonicalSIL.ClosureReabstraction.compilerThunkKind(
                symbol: "$s7FixtureyyFTR",
                loweredType: type
            ) == nil)
        }
    }

    @Test("Swift callback ABI accepts actor erasure without weakening isolation")
    func normalizesSwiftCallbackActorErasure() throws {
        let mainActorSignature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void,
            effects: .init(requiresMainActor: true)
        )
        let mainActorClosure = Bytecode.ValueType.closure(mainActorSignature)
        let parsed = try CanonicalSIL.Lowerer().parseFunctionType(
            "@convention(thin) (@callee_guaranteed () -> ()) -> ()",
            bridgingTo: ([mainActorClosure], .void),
            preservingClosureOwnership: true
        )
        #expect(parsed.parameters == [mainActorClosure])

        let unisolatedClosure = Bytecode.ValueType.closure(.init(
            parameters: [],
            parameterConventions: [],
            result: .void
        ))
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().parseFunctionType(
                "@convention(thin) "
                    + "(@callee_guaranteed @MainActor () -> ()) -> ()",
                bridgingTo: ([unisolatedClosure], .void),
                preservingClosureOwnership: true
            )
        }
    }

    @Test("Unmarked imported value callback parameters are borrowed")
    func borrowsUnmarkedImportedValueParameters() throws {
        let position = Core.TypeID(rawValue: .sha256("UIViewAnimatingPosition"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["UIViewAnimatingPosition": position],
                kinds: [position: .enumeration]
            )
        let parsed = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).parseFunctionType(
            "@convention(thin) (UIViewAnimatingPosition) -> ()"
        )
        #expect(parsed.parameters == [.native(position)])
        #expect(parsed.parameterConventions == [.borrowed])
        let resolved = try environment.resolve(
            "@callee_guaranteed (UIViewAnimatingPosition) -> ()"
        )
        #expect(resolved.directClosureShape?.signature.parameterConventions
            == [.borrowed])
    }

    @Test("Objective-C protocol existentials erase only at a foreign ABI")
    func normalizesObjectiveCProtocolExistentials() throws {
        let object = Core.TypeID(rawValue: .sha256("Swift.AnyObject"))
        let date = Core.TypeID(rawValue: .sha256("Foundation.Date"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                [
                    "Swift.AnyObject": object,
                    "Foundation.Date": date,
                ],
                kinds: [object: .reference, date: .value]
            )
        let lowerer = CanonicalSIL.Lowerer(typeEnvironment: environment)
        let type = "@convention(objc_method) () -> "
            + "@autoreleased any NSObjectProtocol"
        let parsed = try lowerer.parseFunctionType(
            type,
            bridgingTo: ([], .native(object)),
            allowingForeignABIRepresentation: true
        )
        #expect(parsed.result == .native(object))

        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try lowerer.parseFunctionType(
                type,
                bridgingTo: ([], .native(object))
            )
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try lowerer.parseFunctionType(
                "@convention(objc_method) () -> @autoreleased any Error",
                bridgingTo: ([], .native(object)),
                allowingForeignABIRepresentation: true
            )
        }

        let bridgedError = "@convention(block) (@guaranteed NSError) -> ()"
        #expect(try lowerer.parseFunctionType(
            bridgedError,
            bridgingTo: ([.error], .void),
            allowingForeignABIRepresentation: true
        ).parameters == [.error])
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try lowerer.parseFunctionType(
                bridgedError,
                bridgingTo: ([.error], .void)
            )
        }

        let bridgedDate = "@convention(block) (@guaranteed NSDate) -> ()"
        #expect(try lowerer.parseFunctionType(
            bridgedDate,
            bridgingTo: ([.native(date)], .void),
            allowingForeignABIRepresentation: true
        ).parameters == [.native(date)])
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try lowerer.parseFunctionType(
                bridgedDate,
                bridgingTo: ([.native(date)], .void)
            )
        }
        let appValue = Core.TypeID(rawValue: .sha256("Fixture.Widget"))
        let appLowerer = CanonicalSIL.Lowerer(
            typeEnvironment: try CanonicalSIL.TypeEnvironment.empty
                .includingNativeTypes(
                    ["Fixture.Widget": appValue],
                    kinds: [appValue: .value]
                )
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try appLowerer.parseFunctionType(
                "@convention(block) (@guaranteed NSWidget) -> ()",
                bridgingTo: ([.native(appValue)], .void),
                allowingForeignABIRepresentation: true
            )
        }

        let measurement = Core.TypeID(rawValue: .sha256(
            "Foundation.Measurement<Foundation.UnitLength>"
        ))
        let measurementLowerer = CanonicalSIL.Lowerer(
            typeEnvironment: try CanonicalSIL.TypeEnvironment.empty
                .includingNativeTypes(
                    [
                        "Foundation.Measurement<Foundation.UnitLength>":
                            measurement,
                    ],
                    kinds: [measurement: .value]
                )
        )
        #expect(try measurementLowerer.parseFunctionType(
            "@convention(block) (@guaranteed NSMeasurement) -> ()",
            bridgingTo: ([.native(measurement)], .void),
            allowingForeignABIRepresentation: true
        ).parameters == [.native(measurement)])
    }

    @Test("Block headers cannot substitute a different invoke thunk ABI")
    func rejectsMismatchedBlockHeaderThunk() {
        let referenced = "@convention(c) "
            + "(@inout_aliasable @block_storage @callee_guaranteed () -> ()) -> ()"
        let substituted = "@convention(c) "
            + "(@inout_aliasable @block_storage @callee_guaranteed "
            + "(Swift.Bool) -> (), Swift.Bool) -> ()"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyyyyXEF",
            loweredType: "@convention(thin) "
                + "(@owned @callee_guaranteed () -> ()) -> ()",
            body: """
            bb0(%0 : $@owned @callee_guaranteed () -> ()):
              %1 = alloc_stack $@block_storage @callee_guaranteed () -> ()
              %2 = function_ref @$s7Fixture3runyyyyXEFU_ToTR : $\(referenced)
              %3 = init_block_storage_header %1, invoke %2 : $\(substituted), type $@convention(block) () -> ()
              %4 = tuple ()
              return %4
            """
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.run"
            )
        }
    }

    @Test("Foundation callback thunks preserve logical value and Error parameters")
    func recognizesFoundationCallbackParameterBridges() throws {
        let boundaryEnvironment = try CanonicalSIL.TypeEnvironment(
            text: "$@callee_guaranteed (Optional<any Error>) -> ()",
            functions: []
        )
        #expect(try boundaryEnvironment.resolve("Optional<any Error>")
            == .optional(.error))

        let data = Core.TypeID(rawValue: .sha256("Foundation.Data"))
        let response = Core.TypeID(rawValue: .sha256("Foundation.URLResponse"))
        let environment = try boundaryEnvironment
            .includingNativeTypes(
                [
                    "Data": data,
                    "Foundation.Data": data,
                    "URLResponse": response,
                ],
                kinds: [data: .value, response: .reference]
            )
        let thunkType = "@convention(c) ("
            + "@inout_aliasable @block_storage @Sendable @callee_guaranteed "
            + "(@guaranteed Optional<Data>, @guaranteed Optional<URLResponse>, "
            + "@guaranteed Optional<any Error>) -> (), Optional<NSData>, "
            + "Optional<URLResponse>, Optional<NSError>) -> ()"
        let logicalClosure = "@Sendable @callee_guaranteed "
            + "(@guaranteed Optional<Data>, @guaranteed Optional<URLResponse>, "
            + "@guaranteed Optional<any Error>) -> ()"
        let physicalBlock = "@convention(block) @Sendable "
            + "(Optional<NSData>, Optional<URLResponse>, Optional<NSError>) -> ()"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyyF",
            loweredType: "@convention(thin) (@owned \(logicalClosure)) -> ()",
            body: """
            bb0(%0 : $@owned \(logicalClosure)):
              %1 = alloc_stack $@block_storage \(logicalClosure)
              %2 = project_block_storage %1
              store %0 to %2
              %3 = function_ref @$s7Fixture3runyyFy10Foundation4DataVSg_So13NSURLResponseCSgs5Error_pSgtYbcfU_ToTR : $\(thunkType)
              %4 = init_block_storage_header %1, invoke %3 : $\(thunkType), type $\(physicalBlock)
              %5 = copy_block %4
              strong_release %5
              dealloc_stack %1
              %6 = tuple ()
              return %6
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "Fixture.run"
        )
        #expect(lowered.blocks.flatMap(\.instructions).contains(where: {
            if case .returnValue(nil) = $0 { return true }
            return false
        }))

        let boolThunk = "@convention(c) ("
            + "@inout_aliasable @block_storage @callee_guaranteed (Bool) -> (), "
            + "Bool) -> ()"
        let boolFunction = CanonicalSIL.Function(
            mangledName: "$s7Fixture7animateyySbcF",
            loweredType: "@convention(thin) ("
                + "@owned @callee_guaranteed (Bool) -> ()) -> ()",
            body: """
            bb0(%0 : $@owned @callee_guaranteed (Bool) -> ()):
              %1 = alloc_stack $@block_storage @callee_guaranteed (Bool) -> ()
              %2 = project_block_storage %1
              store %0 to %2
              %3 = function_ref @$sSbIegy_SbIeyBy_TR : $\(boolThunk)
              %4 = init_block_storage_header %1, invoke %3 : $\(boolThunk), type $@convention(block) (Bool) -> ()
              %5 = copy_block %4
              %6 = enum $Optional<@convention(block) (Bool) -> ()>, #Optional.some!enumelt, %5
              release_value %6
              dealloc_stack %1
              %7 = tuple ()
              return %7
            """
        )
        _ = try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
            boolFunction,
            displayName: "Fixture.animate"
        )

        let callbackSignature = Bytecode.ClosureSignature(
            parameters: [.bool],
            parameterConventions: [.owned],
            result: .void
        )
        let optionalCallback = Bytecode.ValueType.optional(
            .closure(callbackSignature)
        )
        let acceptSymbol = "$s7Fixture6acceptyyyySbcSgF"
        let acceptType = "@convention(thin) ("
            + "@owned Optional<@convention(block) (Bool) -> ()>) -> ()"
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: acceptSymbol,
                parameterTypes: [optionalCallback],
                resultType: .void,
                target: .function(.init(rawValue: 12))
            ),
        ])
        let nilFunction = CanonicalSIL.Function(
            mangledName: "$s7Fixture7runNilyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = enum $Optional<@convention(block) (Bool) -> ()>, #Optional.none!enumelt
              %1 = function_ref @\(acceptSymbol) : $\(acceptType)
              %2 = apply %1(%0) : $\(acceptType)
              %3 = tuple ()
              return %3
            """
        )
        let nilLowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            nilFunction,
            displayName: "Fixture.runNil",
            directCalls: calls
        )
        #expect(nilLowered.registerTypes.contains(optionalCallback))

        let mismatchedNilFunction = CanonicalSIL.Function(
            mangledName: "$s7Fixture16runMismatchedNilyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = enum $Optional<@convention(block) (String) -> ()>, #Optional.none!enumelt
              %1 = function_ref @\(acceptSymbol) : $\(acceptType)
              %2 = apply %1(%0) : $\(acceptType)
              %3 = tuple ()
              return %3
            """
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer(
                typeEnvironment: environment
            ).lower(
                mismatchedNilFunction,
                displayName: "Fixture.runMismatchedNil",
                directCalls: calls
            )
        }
    }

    @Test("Payload-free native block defaults are projected by exact physical type")
    func projectsNativeBlockOptionalNoneDefault() throws {
        let symbol = "$s7Fixture7presentyySbcSgF"
        let importID = Core.NativeImportID(rawValue: 0)
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.present(_:)",
            signature: .init(parameters: [], result: "Swift.Void"),
            effects: .init(),
            contract: contract,
            physicalParameterTypes: [
                "Swift.Optional<(Swift.Bool) -> Swift.Void>",
            ],
            physicalArgumentSources: [.optionalNone]
        )
        let requirement = Bytecode.ImportRequirement(
            id: importID,
            key: try .derive(descriptor: descriptor),
            descriptor: descriptor,
            contract: contract
        )
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [],
                parameterProjection: .init(
                    physicalParameterCount: 1,
                    logicalParameterIndices: [],
                    defaultArguments: [
                        .optionalNone(physicalParameterIndex: 0),
                    ]
                ),
                resultType: .void,
                target: .nativeImport(requirement)
            ),
        ])
        let physicalType = "@convention(thin) ("
            + "@owned Optional<@convention(block) (Bool) -> ()>) -> ()"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = enum $Optional<@convention(block) (Bool) -> ()>, #Optional.none!enumelt
              %1 = function_ref @\(symbol) : $\(physicalType)
              %2 = apply %1(%0) : $\(physicalType)
              %3 = tuple ()
              return %3
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "Fixture.run",
            directCalls: calls
        )
        #expect(lowered.blocks.flatMap(\.instructions).contains {
            guard case let .nativeApply(_, id, arguments) = $0 else {
                return false
            }
            return id == importID && arguments.isEmpty
        })

        var mismatched = function
        mismatched.body = function.body.replacingOccurrences(
            of: "enum $Optional<@convention(block) (Bool) -> ()>",
            with: "enum $Optional<@convention(block) (String) -> ()>"
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer().lower(
                mismatched,
                displayName: "Fixture.mismatched",
                directCalls: calls
            )
        }
    }

    @Test("Native block thunks preserve bridgeable callback results")
    func recognizesNativeBlockResults() throws {
        let logicalPredicate = "@callee_guaranteed ("
            + "@in_guaranteed Optional<Any>, "
            + "@guaranteed Optional<Dictionary<String, Any>>) -> Bool"
        let predicateThunk = "@convention(c) ("
            + "@inout_aliasable @block_storage \(logicalPredicate), "
            + "Optional<AnyObject>, Optional<NSDictionary>) -> Bool"
        let predicateBlock = "@convention(block) ("
            + "Optional<AnyObject>, Optional<NSDictionary>) -> Bool"
        let predicate = CanonicalSIL.Function(
            mangledName: "$s7Fixture9predicateyySbypSg_SDySSypGSgtccF",
            loweredType: "$@convention(thin) (@owned \(logicalPredicate)) -> ()",
            body: """
            bb0(%0 : $@owned \(logicalPredicate)):
              %1 = alloc_stack $@block_storage \(logicalPredicate)
              %2 = project_block_storage %1
              store %0 to %2
              %3 = function_ref @$sPredicateThunkTR : $\(predicateThunk)
              %4 = init_block_storage_header %1, invoke %3 : $\(predicateThunk), type $\(predicateBlock)
              %5 = copy_block %4
              strong_release %5
              dealloc_stack %1
              %6 = tuple ()
              return %6
            """
        )
        _ = try CanonicalSIL.Lowerer().lower(
            predicate,
            displayName: "Fixture.predicate"
        )

        let logicalString = "@callee_guaranteed () -> @owned String"
        let stringThunk = "@convention(c) ("
            + "@inout_aliasable @block_storage \(logicalString)) "
            + "-> @autoreleased NSString"
        let stringBlock = "@convention(block) () -> @autoreleased NSString"
        let stringProvider = CanonicalSIL.Function(
            mangledName: "$s7Fixture14stringProvideryySSyccF",
            loweredType: "$@convention(thin) (@owned \(logicalString)) -> ()",
            body: """
            bb0(%0 : $@owned \(logicalString)):
              %1 = alloc_stack $@block_storage \(logicalString)
              %2 = project_block_storage %1
              store %0 to %2
              %3 = function_ref @$sStringThunkTR : $\(stringThunk)
              %4 = init_block_storage_header %1, invoke %3 : $\(stringThunk), type $\(stringBlock)
              %5 = copy_block %4
              strong_release %5
              dealloc_stack %1
              %6 = tuple ()
              return %6
            """
        )
        _ = try CanonicalSIL.Lowerer().lower(
            stringProvider,
            displayName: "Fixture.stringProvider"
        )

        let mismatchedThunk = "@convention(c) ("
            + "@inout_aliasable @block_storage \(logicalPredicate), "
            + "Optional<AnyObject>, Optional<NSDictionary>) -> Int"
        let mismatch = CanonicalSIL.Function(
            mangledName: "$s7Fixture8mismatchyySbypSg_SDySSypGSgtccF",
            loweredType: "$@convention(thin) (@owned \(logicalPredicate)) -> ()",
            body: """
            bb0(%0 : $@owned \(logicalPredicate)):
              %1 = alloc_stack $@block_storage \(logicalPredicate)
              %2 = project_block_storage %1
              store %0 to %2
              %3 = function_ref @$sMismatchedThunkTR : $\(mismatchedThunk)
              %4 = init_block_storage_header %1, invoke %3 : $\(mismatchedThunk), type $\(predicateBlock)
              %5 = tuple ()
              return %5
            """
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer().lower(
                mismatch,
                displayName: "Fixture.mismatch"
            )
        }
    }

    @Test("Read-only indirect callback parameters use one logical borrowed ABI")
    func normalizesIndirectCallbackParameters() throws {
        let notification = Core.TypeID(
            rawValue: .sha256("Foundation.Notification")
        )
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["Notification": notification],
                kinds: [notification: .value]
            )
        let callee = Bytecode.FunctionID(rawValue: 7)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: "$s7Fixture7inspectyy10Foundation12NotificationVF",
                parameterTypes: [.native(notification)],
                parameterConventions: [.borrowed],
                resultType: .void,
                target: .function(callee)
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyy10Foundation12NotificationVYbcfU_",
            loweredType: "$@convention(thin) @Sendable "
                + "(@in_guaranteed Notification) -> ()",
            body: """
            bb0(%0 : $*Notification):
              %1 = function_ref @$s7Fixture7inspectyy10Foundation12NotificationVF : $@convention(thin) (@in_guaranteed Notification) -> ()
              %2 = apply %1(%0) : $@convention(thin) (@in_guaranteed Notification) -> ()
              %3 = tuple ()
              return %3
            """
        )

        let discovered = try CanonicalSIL.ImageFunctions.signature(
            of: function,
            environment: environment,
            symbol: function.mangledName,
            kind: .closureBody
        )
        #expect(discovered.parameters == [.native(notification)])
        #expect(discovered.parameterConventions == [.borrowed])

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "Fixture.run callback",
            kind: .closureBody,
            directCalls: calls
        )
        let parameter = try #require(lowered.parameterRegisters.first)
        #expect(lowered.parameterConventions == [.borrowed])
        #expect(lowered.registerTypes[Int(parameter.rawValue)]
            == .native(notification))
        #expect(lowered.blocks.flatMap(\.instructions).contains { instruction in
            guard case let .apply(_, function, arguments) = instruction else {
                return false
            }
            return function == callee && arguments == [parameter]
        })
    }

    @Test("Type-erased callback payloads preserve borrowed ownership recursively")
    func borrowsTypeErasedCallbackPayloads() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyyypSayypGSScfU_",
            loweredType: "$@convention(thin) "
                + "(@in_guaranteed Any, @guaranteed Array<Any>, "
                + "@guaranteed String) -> ()",
            body: """
            bb0(%0 : $*Any, %1 : @guaranteed $Array<Any>, %2 : @guaranteed $String):
              %3 = tuple ()
              return %3
            """
        )

        let signature = try CanonicalSIL.ImageFunctions.signature(
            of: function,
            environment: .empty,
            symbol: function.mangledName,
            kind: .closureBody
        )
        #expect(signature.parameters == [
            .any, .array(.any), .string,
        ])
        #expect(signature.parameterConventions == [
            .borrowed, .borrowed, .owned,
        ])
        var callback = Bytecode.ClosureSignature(
            parameters: signature.parameters,
            parameterConventions: signature.parameterConventions,
            result: signature.result,
            effects: Bytecode.ClosureSignature.callableEffects(
                from: signature.effects
            )
        )
        #expect(callback.isNativeBridgeCallback)
        callback.thrownType = .error
        #expect(!callback.isNativeBridgeCallback)
    }

    @Test("Native callback ownership does not rewrite image-local higher-order ABI")
    func keepsImageHigherOrderOwnershipIndependent() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture9transformyySbcXEfU_",
            loweredType: "$@convention(thin) "
                + "(@guaranteed @callee_guaranteed (Bool) -> (), Int) -> ()",
            body: """
            bb0(%0 : @guaranteed $@callee_guaranteed (Bool) -> (), %1 : @closureCapture $Int):
              %2 = tuple ()
              return %2
            """
        )

        let signature = try CanonicalSIL.ImageFunctions.signature(
            of: function,
            environment: .empty,
            symbol: function.mangledName,
            kind: .closureBody
        )
        #expect(signature.parameters.count == 2)
        #expect(signature.parameterConventions == [.owned, .owned])
        guard case let .closure(completion) = signature.parameters.first else {
            Issue.record("expected a callable closure-body parameter")
            return
        }
        #expect(completion.parameters == [.bool])
        #expect(completion.parameterConventions == [.owned])

        let aggregate = try CanonicalSIL.Lowerer().parseFunctionType(
            "@convention(thin) (@guaranteed Array<"
                + "@callee_guaranteed (Bool) -> ()>) -> ()",
            preservingClosureOwnership: true
        )
        #expect(aggregate.parameterConventions == [.owned])
        #expect(aggregate.parameters.first?.containsClosureValue == true)
    }

    @Test("Static-method metatypes do not shift closure lifetime indices")
    func erasesStaticMethodMetatype() throws {
        let signature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void
        )
        let loweredType = "$@convention(method) "
            + "(@guaranteed @noescape @callee_guaranteed () -> (), "
            + "@thin Fixture.Type) -> ()"
        #expect(try CanonicalSIL.Lowerer().parseParameterConventions(
            loweredType,
            parameterTypes: [.closure(signature)],
            preservingClosureOwnership: true
        ) == [.borrowed])
        #expect(try CanonicalSIL.Lowerer().parseNativeCallbackLifetimes(
            loweredType,
            parameterTypes: [.closure(signature)]
        ) == [0: .nonescaping])
    }

    @Test("Declaration ownership removes only implicit Swift method receivers")
    func parsesDeclarationMethodReceivers() throws {
        let lowerer = CanonicalSIL.Lowerer()
        #expect(try lowerer.parseParameterConventions(
            "@convention(method) (Int, Counter) -> Int",
            parameterTypes: [.int64]
        ) == [.owned])
        #expect(try lowerer.parseParameterConventions(
            "@convention(method) (Int, @thin Counter.Type) -> Int",
            parameterTypes: [.int64]
        ) == [.owned])
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try lowerer.parseParameterConventions(
                "@convention(thin) (Int, String) -> Int",
                parameterTypes: [.int64]
            )
        }
    }

    @Test("SIL ownership remains authoritative for erased value parameters")
    func parsesErasedValueParameterOwnership() throws {
        let lowerer = CanonicalSIL.Lowerer()
        #expect(try lowerer.parseParameterConventions(
            "$@convention(thin) (@in_guaranteed Any, "
                + "@guaranteed Optional<any Error>, @guaranteed String) -> ()",
            parameterTypes: [.any, .optional(.error), .string]
        ) == [.borrowed, .borrowed, .owned])
        #expect(try lowerer.parseParameterConventions(
            "$@convention(thin) (@owned Any, @owned any Error) -> ()",
            parameterTypes: [.any, .error]
        ) == [.owned, .owned])
    }

    @Test("Nonescaping callbacks reject a consuming physical parameter ABI")
    func rejectsOwnedPhysicalNonescapingCallback() throws {
        let callbackSignature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void
        )
        let effects = Core.Effects()
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false,
            callbacks: [
                .init(parameterIndex: 0, lifetime: .nonescaping),
            ]
        )
        let loweredSignature = Core.LoweredSignature(
            parameters: ["() -> Swift.Void"],
            result: "Swift.Void"
        )
        var descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.invokeNow(_:)",
            signature: loweredSignature,
            effects: effects,
            contract: contract
        )
        descriptor.physicalSignature.parameters[0].ownership = .borrowed
        let key = try Core.NativeCall.Key.derive(descriptor: descriptor)
        let symbol = "$s7Fixture9invokeNowyyyyXEF"
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.closure(callbackSignature)],
                parameterConventions: [.borrowed],
                resultType: .void,
                target: .nativeImport(.init(
                    id: .init(rawValue: 0),
                    key: key,
                    descriptor: descriptor,
                    contract: contract
                ))
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyyF",
            loweredType: "$@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = function_ref @\(symbol) : $@convention(thin) (@owned @noescape @callee_guaranteed () -> ()) -> ()
              %1 = tuple ()
              return %1
            """
        )

        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.run",
                directCalls: calls
            )
        }
    }

    @Test("Rejects malformed callback binding metadata before lowering")
    func rejectsMalformedCallbackBindings() throws {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.DirectCallTable([
                .init(
                    mangledName: "$s7Fixture3runyySiF",
                    parameterTypes: [.int64],
                    parameterConventions: [],
                    resultType: .void,
                    target: .function(.init(rawValue: 0))
                ),
            ])
        }

        let signature = Bytecode.ClosureSignature(
            parameters: [],
            parameterConventions: [],
            result: .void
        )
        let effects = Core.Effects()
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false,
            callbacks: [
                .init(parameterIndex: 1, lifetime: .escaping),
            ]
        )
        let malformedDescriptor = try Core.NativeCall.Descriptor(
            target: .init(
                backend: .swiftAdapter,
                module: "Fixture",
                member: "run(_:)",
                entryPoint: "Fixture.run(_:)",
                dispatch: .global
            ),
            logicalSignature: .init(
                parameters: [.init(type: "() -> Swift.Void")],
                result: .init(type: "Swift.Void")
            ),
            physicalSignature: .init(
                callingConvention: .swiftAdapter,
                parameters: [
                    .init(
                        type: .bridgeValue("() -> Swift.Void"),
                        source: .argument(0)
                    ),
                ],
                result: .void
            ),
            effects: effects
        )
        let key = try Core.NativeCall.Key.derive(
            descriptor: malformedDescriptor
        )
        let requirement = Bytecode.ImportRequirement(
            id: .init(rawValue: 0),
            key: key,
            descriptor: malformedDescriptor,
            contract: contract
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.DirectCallTable([
                .init(
                    mangledName: "$s7Fixture3runyyyyXEF",
                    parameterTypes: [.closure(signature)],
                    resultType: .void,
                    target: .nativeImport(requirement)
                ),
            ])
        }

        for (lifetime, invalidConvention) in [
            (
                Core.NativeImportCallbackLifetime.nonescaping,
                Bytecode.ParameterConvention.owned
            ),
            (
                Core.NativeImportCallbackLifetime.escaping,
                Bytecode.ParameterConvention.borrowed
            ),
        ] {
            let lifetimeContract = Core.NativeImportContract.bounded(
                kind: .globalFunction,
                domain: .application,
                access: .pure,
                maximumDurationMicroseconds: 500,
                allowsMainThread: false,
                callbacks: [
                    .init(parameterIndex: 0, lifetime: lifetime),
                ]
            )
            let lifetimeSignature = Core.LoweredSignature(
                parameters: [
                    lifetime == .escaping
                        ? "@escaping () -> Swift.Void"
                        : "() -> Swift.Void",
                ],
                result: "Swift.Void"
            )
            var lifetimeDescriptor = try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.run(_:)",
                signature: lifetimeSignature,
                effects: effects,
                contract: lifetimeContract
            )
            lifetimeDescriptor.physicalSignature.parameters[0].ownership =
                lifetime == .nonescaping ? .borrowed : .owned
            let lifetimeKey = try Core.NativeCall.Key.derive(
                descriptor: lifetimeDescriptor
            )
            let lifetimeRequirement = Bytecode.ImportRequirement(
                id: .init(rawValue: 0),
                key: lifetimeKey,
                descriptor: lifetimeDescriptor,
                contract: lifetimeContract
            )
            #expect(throws: CanonicalSIL.LoweringError.self) {
                try CanonicalSIL.DirectCallTable([
                    .init(
                        mangledName: "$s7Fixture3runyyyyXEF",
                        parameterTypes: [.closure(signature)],
                        parameterConventions: [invalidConvention],
                        resultType: .void,
                        target: .nativeImport(lifetimeRequirement)
                    ),
                ])
            }
        }
    }
}
}
