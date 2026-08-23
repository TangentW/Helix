import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift-to-HLBC pipeline")
struct Pipeline {
    @Test("A changed Swift function compiles, verifies, and executes without rebuilding the app")
    func compilesRealSwiftSourceEndToEnd() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("Patch.swift")
        try Data("public func transform(_ x: Int) -> Int { x + 27 }\n".utf8).write(to: source)
        let canonicalSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [source],
            moduleName: "HelixPipelineFixture"
        )
        let selected = try CanonicalSIL.File(text: canonicalSIL)
            .uniqueFunction(mangledNameContaining: "transform")

        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.pipeline",
            buildNumber: "1",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "HelixPipelineFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func transform(_: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let shellHash = Core.Digest.sha256("helix-pipeline-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-pipeline-fixture"
        )
        let entry = Core.EntryIndex(rawValue: 0)
        let compiled = try PatchCompiler.Driver().compile(
            .init(
                canonicalSIL: canonicalSIL,
                mangledName: selected.mangledName,
                displayName: "transform",
                functionKey: key,
                entryIndex: entry,
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                sourceFileLogicalID: "Patch.swift"
            )
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            entries: [
                .init(
                    index: entry,
                    key: key,
                    parameterTypes: [.int64],
                    parameterConventions: compiled.module.functions[0]
                        .parameterConventions,
                    resultType: .int64
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: compiled.bytecode,
            shell: shell,
            policy: .init()
        )
        let input = try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)

        switch VM.Interpreter().invoke(entry: entry, image: image, arguments: [.integer(input)]) {
        case let .returned(result):
            let value = try #require(result)
            guard case let .integer(integer) = value else {
                Issue.record("expected an Int result, got \(value)")
                return
            }
            #expect(integer.signedValue == 30)
        case let .businessError(message):
            Issue.record("unexpected business error: \(message)")
        case let .trapped(trap):
            Issue.record("unexpected VM trap: \(trap)")
        }

        #expect(compiled.disassembly.contains("checked_add"))
        #expect(compiled.disassembly.contains("cond_br"))
        #expect(!compiled.module.sourceMap.isEmpty)
        #expect(compiled.module.sourceMap.allSatisfy { $0.location.file == "Patch.swift" })
        #expect(compiled.module.sourceMap.allSatisfy { $0.location.line == 1 })
        #expect(compiled.disassembly.contains("Patch.swift:1:"))
        var trapCount = 0
        var allTrapsMapped = true
        for function in compiled.module.functions {
            for block in function.blocks {
                for (rawOffset, instruction) in block.instructions.enumerated() {
                    guard case .trap = instruction else { continue }
                    trapCount += 1
                    guard let offset = UInt32(exactly: rawOffset) else {
                        allTrapsMapped = false
                        continue
                    }
                    if !compiled.module.sourceMap.contains(where: {
                        $0.functionID == function.id
                            && $0.blockID == block.id
                            && $0.instructionOffset == offset
                            && $0.location.file == "Patch.swift"
                    }) {
                        allTrapsMapped = false
                    }
                }
            }
        }
        #expect(trapCount > 0)
        #expect(allTrapsMapped)
    }

    @Test("Source maps retain only unambiguous logical paths")
    func sourceMapLogicalPathPolicy() {
        let absolute = Core.SourceLocation(
            file: "/private/build/Feature/Sources/Feature.swift",
            line: 10,
            column: 7
        )
        let function = IntermediateRepresentation.Function(
            name: "sourceMapFixture",
            parameterRegisters: [],
            resultType: .int64,
            registerTypes: [.int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [],
                    instructions: [
                        .constantInteger(result: .init(rawValue: 0), bitPattern: 1),
                        .returnValue(.init(rawValue: 0)),
                    ]
                ),
            ],
            sourceLocation: absolute,
            sourceMap: [
                .init(
                    blockID: .init(rawValue: 0),
                    instructionOffset: 0,
                    location: absolute
                ),
                .init(
                    blockID: .init(rawValue: 0),
                    instructionOffset: 1,
                    location: absolute
                ),
            ]
        )

        let normalized = IntermediateRepresentation.SourceMapping.retainingLogicalPaths(
            function,
            logicalPaths: ["Sources/Feature.swift"]
        )
        #expect(
            normalized.sourceMap.map(\.location.file)
                == ["Sources/Feature.swift", "Sources/Feature.swift"]
        )
        #expect(normalized.sourceLocation?.file == "Sources/Feature.swift")

        let ambiguous = IntermediateRepresentation.SourceMapping.retainingLogicalPaths(
            function,
            logicalPaths: ["Feature.swift", "Sources/Feature.swift"]
        )
        #expect(ambiguous.sourceMap.isEmpty)
        #expect(ambiguous.sourceLocation == nil)

        let redacted = IntermediateRepresentation.SourceMapping.retainingLogicalPaths(
            function,
            logicalPaths: []
        )
        #expect(redacted.sourceMap.isEmpty)
        #expect(redacted.sourceLocation == nil)
    }

    @Test("Unsupported Swift constructs produce a stable lowering diagnostic")
    func rejectsUnsupportedCall() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-unsupported-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            @inline(never) public func helper(_ x: Int) -> Int { x }
            public func transform(_ x: Int) -> Int { helper(x) }
            """.utf8
        ).write(to: source)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [source],
            moduleName: "HelixUnsupportedFixture"
        )
        let function = try CanonicalSIL.File(text: sil)
            .uniqueFunction(mangledNameContaining: "transform")

        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().lower(function, displayName: "transform")
        }
    }

    @Test("Dynamic function references resolve only through the frozen direct-call table")
    func lowersDynamicFunctionReference() throws {
        let helper = "$s14DynamicFixture6helperyS2iF"
        let function = CanonicalSIL.Function(
            mangledName: "$s14DynamicFixture9transformyS2iF",
            loweredType: "@convention(thin) (Int) -> Int",
            body: """
            bb0(%0 : $Int):
              %1 = dynamic_function_ref @\(helper) : $@convention(thin) (Int) -> Int
              %2 = apply %1(%0) : $@convention(thin) (Int) -> Int
              return %2
            """
        )
        let table = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: helper,
                parameterTypes: [.int64],
                resultType: .int64,
                target: .entry(.init(rawValue: 7))
            ),
        ])

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "transform",
            directCalls: table
        )
        #expect(lowered.blocks.flatMap(\.instructions).contains { instruction in
            guard case let .entryApply(_, entry, _) = instruction else { return false }
            return entry.rawValue == 7
        })
    }

    @Test("Owned device boundaries copy a guaranteed native receiver")
    func adaptsBorrowedNativeReceiver() throws {
        let receiverID = Core.TypeID(rawValue: .sha256("Fixture.Receiver"))
        let helper = "$s7Fixture8ReceiverC6helperyyF"
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture8ReceiverC4rootyyF",
            loweredType: "@convention(method) (@guaranteed Fixture.Receiver) -> ()",
            body: """
            bb0(%0 : @guaranteed $Fixture.Receiver):
              %1 = function_ref @\(helper) : $@convention(method) (@guaranteed Fixture.Receiver) -> ()
              %2 = apply %1(%0) : $@convention(method) (@guaranteed Fixture.Receiver) -> ()
              return %2
            """
        )
        let table = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: helper,
                parameterTypes: [.native(receiverID)],
                resultType: .void,
                target: .entry(.init(rawValue: 3))
            ),
        ])
        let environment = try CanonicalSIL.TypeEnvironment.empty.includingNativeTypes([
            "Fixture.Receiver": receiverID,
        ])

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(
            function,
            displayName: "Fixture.Receiver.root",
            directCalls: table
        )
        let instructions = lowered.blocks.flatMap(\.instructions)
        let copies: [(Bytecode.Register, Bytecode.Register)] = instructions.compactMap {
            instruction in
            guard case let .copyValue(result, source) = instruction else { return nil }
            return (result, source)
        }
        let calls: [(Core.EntryIndex, [Bytecode.Register])] = instructions.compactMap {
            instruction in
            guard case let .entryApply(_, entry, arguments) = instruction else {
                return nil
            }
            return (entry, arguments)
        }
        let copy = try #require(copies.first)
        let call = try #require(calls.first)

        #expect(copy.1 == lowered.parameterRegisters[0])
        #expect(call.0.rawValue == 3)
        #expect(call.1 == [copy.0])
    }

    @Test("Non-suspending async Swift entries retain their ABI and execute through an async Bridge context")
    func lowersAsyncLeafEntry() throws {
        let effects = Core.Effects(isAsync: true)
        let fixture = try compileFixture(
            source: "public func asyncLeaf(_ value: Int) async -> Int { value + 9 }",
            functionName: "asyncLeaf",
            signature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int",
                isAsync: true
            ),
            parameterTypes: [.int64],
            resultType: .int64,
            effects: effects
        )
        #expect(fixture.compiled.module.capabilities.contains(.asyncLeafEntriesV1))
        #expect(fixture.compiled.module.functions[0].effects.isAsync)

        let input = try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [.integer(input)]
            ) == .trapped(.explicit(
                "async HLBC entry requires its generated Swift async Bridge"
            ))
        )
        let result = VM.Interpreter().invoke(
            entry: .init(rawValue: 0),
            image: fixture.image,
            arguments: [.integer(input)],
            rootContext: .generatedAsyncBridge
        )
        guard case let .returned(.some(.integer(value))) = result else {
            Issue.record("unexpected async leaf result: \(result)")
            return
        }
        #expect(value.signedValue == 13)
    }

    @Test("Async throwing leaves preserve both return and business-error paths")
    func lowersAsyncThrowingLeafEntry() throws {
        let fixture = try compileFixture(
            source: """
            public enum AsyncFailure: Error { case rejected }
            public func asyncChecked(_ value: Int) async throws -> Int {
                guard value >= 0 else { throw AsyncFailure.rejected }
                return value + 2
            }
            """,
            functionName: "asyncChecked",
            signature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int",
                isThrowing: true,
                isAsync: true
            ),
            parameterTypes: [.int64],
            resultType: .int64,
            effects: .init(mayThrow: true, isAsync: true)
        )
        #expect(fixture.compiled.module.capabilities.contains(.asyncLeafEntriesV1))
        #expect(fixture.compiled.module.capabilities.contains(.untypedThrowsV1))

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [.integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true))],
                rootContext: .generatedAsyncBridge
            ) == .returned(
                .integer(try VM.Integer(signed: 6, bitWidth: 64, isSigned: true))
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [.integer(try VM.Integer(signed: -1, bitWidth: 64, isSigned: true))],
                rootContext: .generatedAsyncBridge
            ) == .businessError("AsyncFailure.rejected")
        )
    }

    @Test("An async await remains a stable suspension-profile rejection")
    func rejectsSuspendingAsyncEntry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-async-reject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            @inline(never) public func helper(_ value: Int) async -> Int { value + 1 }
            public func caller(_ value: Int) async -> Int { await helper(value) }
            """.utf8
        ).write(to: source)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [source],
            moduleName: "HelixAsyncRejectFixture"
        )
        let function = try CanonicalSIL.File(text: sil)
            .uniqueFunction(mangledNameContaining: "caller")

        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "caller",
                expectedEffects: .init(isAsync: true)
            )
        }
    }

    @Test("A real async escaping closure is rejected before HLBC packaging")
    func rejectsAsyncEscapingClosure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-async-closure-reject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            public func asyncClosureRoot(
                _ transform: @escaping (Int) async -> Int
            ) async -> Int {
                await transform(1)
            }
            """.utf8
        ).write(to: source)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [source],
            moduleName: "HelixAsyncClosureRejectFixture"
        )
        let file = try CanonicalSIL.File(text: sil)
        let function = try #require(file.functions.first {
            $0.loweredType.contains("@async @callee_guaranteed")
        })

        do {
            _ = try CanonicalSIL.Lowerer(
                typeEnvironment: file.typeEnvironment
            ).lower(
                function,
                displayName: "asyncClosureRoot",
                expectedEffects: .init(isAsync: true)
            )
            Issue.record("expected an async closure type rejection")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unsupportedType(type) = error else {
                Issue.record("unexpected lowering error: \(error)")
                return
            }
            #expect(type.contains("@async"))
        }
    }

    @Test("A MainActor async leaf uses the same synchronous VM segment after its Swift executor prologue")
    func lowersMainActorAsyncLeafEntry() throws {
        let effects = Core.Effects(requiresMainActor: true, isAsync: true)
        let fixture = try compileFixture(
            source: "@MainActor public func mainLeaf(_ value: Int) async -> Int { value + 5 }",
            functionName: "mainLeaf",
            signature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int",
                isAsync: true,
                isolation: "MainActor"
            ),
            parameterTypes: [.int64],
            resultType: .int64,
            effects: effects
        )

        #expect(fixture.compiled.module.capabilities.contains(.asyncLeafEntriesV1))
        #expect(fixture.compiled.module.capabilities.contains(.mainActorSyncV1))
        #expect(!fixture.compiled.disassembly.contains("hop_to_executor"))
    }

    @Test("A cataloged but unshipped call reports the Swift callee and remediation")
    func diagnosesUnavailableNativeImport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-unavailable-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            @inline(never) public func dormant(_ value: Int) -> Int { value }
            public func transform(_ value: Int) -> Int { dormant(value) }
            """.utf8
        ).write(to: source)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [source],
            moduleName: "UnavailableImportFixture"
        )
        let file = try CanonicalSIL.File(text: sil)
        let dormant = try file.uniqueFunction(mangledNameContaining: "dormant")
        let transform = try file.uniqueFunction(mangledNameContaining: "transform")
        let table = try CanonicalSIL.DirectCallTable(
            [],
            unavailable: [
                .init(
                    mangledName: dormant.mangledName,
                    canonicalCallee: "UnavailableImportFixture.dormant(_:)",
                    reason: "not allowlisted into this Shell; ship a new Shell"
                ),
            ]
        )

        do {
            _ = try CanonicalSIL.Lowerer().lower(
                transform,
                displayName: "transform",
                directCalls: table
            )
            Issue.record("unavailable native import unexpectedly lowered")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unavailableNativeImport(
                _, mangledName, canonicalCallee, reason
            ) = error else {
                Issue.record("unexpected lowering diagnostic: \(error)")
                return
            }
            #expect(mangledName == dormant.mangledName)
            #expect(canonicalCallee == "UnavailableImportFixture.dormant(_:)")
            #expect(reason.contains("ship a new Shell"))
            #expect(error.description.contains("UnavailableImportFixture.dormant(_:)"))
        }
    }

    @Test("Malformed SIL numbers fail as diagnostics instead of process traps")
    func malformedSILNumbersFailStably() {
        let oversizedBlock = CanonicalSIL.Function(
            mangledName: "$sFixture",
            loweredType: "@convention(thin) () -> ()",
            body: "bb4294967296:"
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().lower(
                oversizedBlock,
                displayName: "oversizedBlock"
            )
        }

        let oversizedInteger = CanonicalSIL.Function(
            mangledName: "$sFixture",
            loweredType: "@convention(thin) () -> Int64",
            body: """
            bb0:
              %0 = integer_literal $Builtin.Int64, 18446744073709551616
              return %0
            """
        )
        do {
            _ = try CanonicalSIL.Lowerer().lower(
                oversizedInteger,
                displayName: "oversizedInteger"
            )
            Issue.record("oversized SIL integer unexpectedly lowered")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains("integer literal"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("SIL scalar literals retain APInt and IEEE payload bits")
    func scalarLiteralBitsAreExact() throws {
        let integer = try CanonicalSIL.Lowerer().lower(
            .init(
                mangledName: "$sIntegerBits",
                loweredType: "@convention(thin) () -> UInt64",
                body: """
                bb0:
                  %0 = integer_literal $Builtin.Int64, 18446744073709551615
                  return %0
                """
            ),
            displayName: "integerBits"
        )
        #expect(
            integer.blocks.flatMap(\.instructions).contains {
                guard case let .constantInteger(_, bitPattern) = $0 else {
                    return false
                }
                return bitPattern == UInt64.max
            }
        )

        let floating = try CanonicalSIL.Lowerer().lower(
            .init(
                mangledName: "$sFloatingBits",
                loweredType: "@convention(thin) () -> Float",
                body: """
                bb0:
                  %0 = float_literal $Builtin.FPIEEE32, 0x7FA12345
                  return %0
                """
            ),
            displayName: "floatingBits"
        )
        #expect(
            floating.blocks.flatMap(\.instructions).contains {
                guard case let .constantFloat(_, bitPattern) = $0 else {
                    return false
                }
                return bitPattern == 0x7FA1_2345
            }
        )

        let frontend = try compileFixture(
            source: """
            @inline(never)
            public func uint64Literal() -> UInt64 {
                18_446_744_073_709_551_615
            }
            """,
            functionName: "uint64Literal",
            signature: .init(parameters: [], result: "Swift.UInt64"),
            parameterTypes: [],
            resultType: .integer(bitWidth: 64, signed: false)
        )
        let maximum = try VM.Integer(
            rawBits: .max,
            bitWidth: 64,
            isSigned: false
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: frontend.image,
                arguments: []
            ) == .returned(.integer(maximum))
        )
    }

    @Test("Real Swift Optional control flow and construction execute as HLBC")
    func compilesOptionalControlFlow() throws {
        let source = """
        @inline(never)
        public func optionalDefault(_ value: Int?) -> Int { value ?? 7 }

        @inline(never)
        public func optionalMap(_ value: Int?) -> Int? {
            guard let value else { return nil }
            return value + 1
        }
        """
        let optionalInt = Bytecode.ValueType.optional(.int64)
        let defaultFixture = try compileFixture(
            source: source,
            functionName: "optionalDefault",
            signature: .init(parameters: ["Swift.Optional<Swift.Int>"], result: "Swift.Int"),
            parameterTypes: [optionalInt],
            resultType: .int64
        )
        let three = try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)
        let seven = try VM.Integer(signed: 7, bitWidth: 64, isSigned: true)
        #expect(defaultFixture.compiled.disassembly.contains("switch_optional"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: defaultFixture.image,
                arguments: [.optional(.integer(three))]
            ) == .returned(.integer(three))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: defaultFixture.image,
                arguments: [.optional(nil)]
            ) == .returned(.integer(seven))
        )

        let mapFixture = try compileFixture(
            source: source,
            functionName: "optionalMap",
            signature: .init(
                parameters: ["Swift.Optional<Swift.Int>"],
                result: "Swift.Optional<Swift.Int>"
            ),
            parameterTypes: [optionalInt],
            resultType: optionalInt
        )
        let four = try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)
        #expect(mapFixture.compiled.disassembly.contains("optional_some"))
        #expect(mapFixture.compiled.disassembly.contains("optional_none"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: mapFixture.image,
                arguments: [.optional(.integer(three))]
            ) == .returned(.optional(.integer(four)))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: mapFixture.image,
                arguments: [.optional(nil)]
            ) == .returned(.optional(nil))
        )
    }

    @Test("Real Swift tuple and Void results lower without native code loading")
    func compilesTupleAndVoidResults() throws {
        let tupleType = Bytecode.ValueType.tuple([.int64, .int64])
        let tupleFixture = try compileFixture(
            source: "@inline(never) public func makePair(_ a: Int, _ b: Int) -> (Int, Int) { (a, b) }",
            functionName: "makePair",
            signature: .init(
                parameters: ["Swift.Int", "Swift.Int"],
                result: "(Swift.Int, Swift.Int)"
            ),
            parameterTypes: [.int64, .int64],
            resultType: tupleType
        )
        let first = try VM.Integer(signed: 2, bitWidth: 64, isSigned: true)
        let second = try VM.Integer(signed: 9, bitWidth: 64, isSigned: true)
        #expect(tupleFixture.compiled.disassembly.contains("make_tuple"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: tupleFixture.image,
                arguments: [.integer(first), .integer(second)]
            ) == .returned(.tuple([.integer(first), .integer(second)]))
        )

        let voidFixture = try compileFixture(
            source: "@inline(never) public func accept(_ value: Int) { _ = value }",
            functionName: "accept",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Void"),
            parameterTypes: [.int64],
            resultType: .void
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: voidFixture.image,
                arguments: [.integer(first)]
            ) == .returned(nil)
        )
    }

    @Test("A no-payload Swift Error case becomes a deterministic VM business error")
    func compilesThrowingFunction() throws {
        let fixture = try compileFixture(
            source: """
            public enum FixtureError: Error { case failed }
            @inline(never)
            public func throwing(_ shouldFail: Bool) throws -> Int {
                if shouldFail { throw FixtureError.failed }
                return 7
            }
            """,
            functionName: "throwing",
            signature: .init(
                parameters: ["Swift.Bool"],
                result: "Swift.Int",
                isThrowing: true
            ),
            parameterTypes: [.bool],
            resultType: .int64,
            effects: .init(mayThrow: true)
        )

        #expect(fixture.compiled.module.capabilities.contains(.stringsV1))
        #expect(fixture.compiled.module.capabilities.contains(.untypedThrowsV1))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [.bool(true)]
            ) == .businessError("FixtureError.failed")
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [.bool(false)]
            ) == .returned(.integer(try VM.Integer(signed: 7, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("Local structs and associated-value enums preserve Swift value semantics")
    func compilesLocalNominalValues() throws {
        let fixture = try compileFixture(
            source: """
            @frozen public struct Point {
                public let x: Int
                public let y: Int
                public let label: String
            }
            enum Adjustment {
                case add(Int)
                case subtract(Int)
                case unchanged
            }
            @inline(never)
            public func localNominals(_ value: Int) -> Int {
                let point = Point(x: value, y: 2, label: "ok")
                let adjustment: Adjustment = value >= 0
                    ? .add(point.y)
                    : .subtract(point.y)
                switch adjustment {
                case let .add(amount):
                    return point.x + amount + point.label.count
                case let .subtract(amount):
                    return point.x - amount + point.label.count
                case .unchanged:
                    return point.x + point.label.count
                }
            }
            """,
            functionName: "localNominals",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64],
            resultType: .int64,
            additionalFrontendArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
        )

        #expect(fixture.compiled.module.capabilities.contains(.localNominalsV1))
        #expect(fixture.compiled.module.capabilities.contains(.stringsV1))
        #expect(fixture.compiled.module.localTypes.map(\.key.rawValue) == [
            "Adjustment", "Point",
        ])
        #expect(fixture.compiled.disassembly.contains("make_struct"))
        #expect(fixture.compiled.disassembly.contains("struct_extract"))
        #expect(fixture.compiled.disassembly.contains("make_enum"))
        #expect(fixture.compiled.disassembly.contains("switch_enum"))

        for raw in -32...32 {
            let expected = raw >= 0 ? raw + 4 : raw
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: fixture.image,
                    arguments: [
                        .integer(
                            try VM.Integer(
                                signed: Int64(raw),
                                bitWidth: 64,
                                isSigned: true
                            )
                        ),
                    ]
                ) == .returned(
                    .integer(
                        try VM.Integer(
                            signed: Int64(expected),
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            )
        }
    }

    @Test("Namespace-qualified local types keep sibling short names unambiguous")
    func compilesNamespacedLocalNominals() throws {
        let fixture = try compileFixture(
            source: """
            enum First {
                struct Value { let number: Int }
                enum Outcome {
                    case value(Value)
                    case none
                }
            }

            enum Second {
                struct Value { let number: Int }
                enum Outcome {
                    case value(Value)
                    case none
                }
            }

            @inline(never)
            public func namespacedNominal(_ input: Int) -> Int {
                let outcome = First.Outcome.value(First.Value(number: input))
                switch outcome {
                case let .value(value): return value.number
                case .none: return -1
                }
            }
            """,
            functionName: "namespacedNominal",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64],
            resultType: .int64,
            additionalFrontendArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
        )

        #expect(fixture.compiled.module.localTypes.map(\.key.rawValue) == [
            "First.Outcome", "First.Value",
        ])
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [
                    .integer(try VM.Integer(signed: 9, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 9, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Patch-local raw enums support construction, rawValue, and switching")
    func compilesLocalRawEnums() throws {
        let fixture = try compileFixture(
            source: """
            private enum Status: Int {
                case idle = 0
                case ready = 1
                case failed = 2
            }

            @inline(never)
            public func rawEnum(_ input: Int) -> Int {
                guard let status = Status(rawValue: input) else { return -1 }
                switch status {
                case .idle: return status.rawValue + 10
                case .ready: return status.rawValue + 20
                case .failed: return status.rawValue + 30
                }
            }
            """,
            functionName: "rawEnum",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64],
            resultType: .int64,
            additionalFrontendArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
        )

        for (input, expected) in [(0, 10), (1, 21), (2, 32), (3, -1)] {
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: fixture.image,
                    arguments: [
                        .integer(
                            try VM.Integer(
                                signed: Int64(input),
                                bitWidth: 64,
                                isSigned: true
                            )
                        ),
                    ]
                ) == .returned(
                    .integer(
                        try VM.Integer(
                            signed: Int64(expected),
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            )
        }
    }

    @Test("Function-local nominal declarations fail with an exact type diagnostic")
    func rejectsFunctionLocalNominal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-function-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            @inline(never)
            public func localDecision(_ value: Int) -> Int {
                enum Decision {
                    case accepted(Int)
                    case blocked
                }
                let decision: Decision = value >= 0 ? .accepted(value) : .blocked
                switch decision {
                case let .accepted(output): return output
                case .blocked: return -1
                }
            }
            """.utf8
        ).write(to: sourceURL)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "FunctionLocalFixture",
            purpose: .semanticLowering
        )
        let file = try CanonicalSIL.File(text: sil)
        let function = try file.uniqueFunction(mangledNameContaining: "localDecision")

        #expect(throws: CanonicalSIL.LoweringError.unsupportedType("Decision")) {
            _ = try CanonicalSIL.Lowerer(
                typeEnvironment: file.typeEnvironment
            ).lower(function, displayName: "localDecision")
        }
    }

    @Test("Concrete Result and nested associated values execute without native layout")
    func compilesConcreteResult() throws {
        let fixture = try compileFixture(
            source: """
            enum DetailedFailure: Error {
                case invalid(code: Int, message: String)
                case unavailable
            }
            @inline(never)
            public func localResult(_ value: Int) -> Int {
                let result: Result<Int, DetailedFailure> = value >= 0
                    ? .success(value + 1)
                    : .failure(.invalid(code: value, message: "negative"))
                switch result {
                case let .success(output):
                    return output
                case let .failure(.invalid(code, message)):
                    return code + message.count
                case .failure(.unavailable):
                    return -1
                }
            }
            """,
            functionName: "localResult",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64],
            resultType: .int64,
            additionalFrontendArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
        )

        #expect(fixture.compiled.module.capabilities.contains(.localNominalsV1))
        #expect(fixture.compiled.module.capabilities.contains(.stringsV1))
        #expect(fixture.compiled.module.localTypes.contains {
            $0.key.rawValue.hasPrefix("Swift.Result<")
        })
        #expect(
            fixture.compiled.disassembly.components(separatedBy: "switch_enum").count == 3
        )

        let positive = try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)
        let negative = try VM.Integer(signed: -3, bitWidth: 64, isSigned: true)
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [.integer(positive)]
            ) == .returned(.integer(try VM.Integer(signed: 5, bitWidth: 64, isSigned: true)))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [.integer(negative)]
            ) == .returned(.integer(try VM.Integer(signed: 5, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("Associated Swift errors retain payloads through throw and typed catch")
    func compilesTypedAssociatedErrors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-typed-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            enum DetailedError: Error {
                case invalid(code: Int, message: String)
                case unavailable
            }
            @inline(never)
            public func throwingValue(_ value: Int) throws -> Int {
                guard value >= 0 else {
                    throw DetailedError.invalid(code: value, message: "negative")
                }
                guard value != 13 else { throw DetailedError.unavailable }
                return value + 1
            }
            @inline(never)
            public func catchAssociated(_ value: Int) -> Int {
                do {
                    return try throwingValue(value)
                } catch let DetailedError.invalid(code, message) {
                    return code + message.count
                } catch DetailedError.unavailable {
                    return -1
                } catch {
                    return -2
                }
            }
            """.utf8
        ).write(to: sourceURL)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "TypedErrorFixture",
            additionalArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
        )
        let file = try CanonicalSIL.File(text: sil)
        let throwing = try file.uniqueFunction(mangledNameContaining: "throwingValue")
        let catching = try file.uniqueFunction(mangledNameContaining: "catchAssociated")
        let table = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: throwing.mangledName,
                parameterTypes: [.int64],
                resultType: .int64,
                effects: .init(mayThrow: true),
                target: .function(.init(rawValue: 1))
            ),
        ])
        let lowerer = CanonicalSIL.Lowerer(typeEnvironment: file.typeEnvironment)
        let catchingIR = try lowerer.lower(
            catching,
            displayName: "catchAssociated",
            directCalls: table
        )
        let throwingIR = try lowerer.lower(
            throwing,
            displayName: "throwingValue"
        )
        let localTypes = try file.typeEnvironment.definitions(
            referencedBy: [catchingIR, throwingIR]
        )
        let shellHash = Core.Digest.sha256("typed-error-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "typed-error-fixture"
        )
        let entry = Core.EntryIndex(rawValue: 0)
        let functionKey = try Core.FunctionKey.derive(
            namespace: .derive(
                bundleID: "dev.helix.typed-error",
                buildNumber: "1",
                seed: "fixture"
            ),
            module: "TypedErrorFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func catchAssociated(_: Int) -> Int",
            loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            role: .function
        )
        let module = Bytecode.Module(
            name: "TypedErrorFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: CompilerCapabilities.infer(
                for: [catchingIR, throwingIR],
                localTypes: localTypes
            ),
            localTypes: localTypes,
            functions: [
                IntermediateRepresentation.ToBytecode.lower(
                    catchingIR,
                    id: .init(rawValue: 0)
                ),
                IntermediateRepresentation.ToBytecode.lower(
                    throwingIR,
                    id: .init(rawValue: 1)
                ),
            ],
            entries: [
                .init(entryIndex: entry, functionKey: functionKey, functionID: .init(rawValue: 0)),
            ]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: module.capabilities,
            entries: [
                .init(
                    index: entry,
                    key: functionKey,
                    parameterTypes: [.int64],
                    parameterConventions: module.functions[0]
                        .parameterConventions,
                    resultType: .int64
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(acceptedCapabilities: module.capabilities)
        )

        #expect(module.capabilities.contains(.structuredErrorsV1))
        #expect(Bytecode.Disassembler.disassemble(module).contains("cast_error"))
        for (input, expected) in [(4, 5), (-3, 5), (13, -1)] {
            #expect(
                VM.Interpreter().invoke(
                    entry: entry,
                    image: image,
                    arguments: [
                        .integer(
                            try VM.Integer(
                                signed: Int64(input),
                                bitWidth: 64,
                                isSigned: true
                            )
                        ),
                    ]
                ) == .returned(
                    .integer(
                        try VM.Integer(
                            signed: Int64(expected),
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            )
        }
    }

    @Test("Local type declarations close capabilities over unused members")
    func localTypeDefinitionsContributeCapabilities() {
        let definition = Bytecode.LocalTypeDefinition(
            key: .init(rawValue: "Diagnostic"),
            kind: .enumeration(
                cases: [
                    .init(name: "code", payloadType: .int64),
                    .init(name: "message", payloadType: .string),
                ]
            )
        )

        let capabilities = CompilerCapabilities.infer(
            for: [],
            localTypes: [definition]
        )

        #expect(capabilities.contains(.localNominalsV1))
        #expect(capabilities.contains(.stringsV1))
    }

    @Test("Recursive local enums are rejected before packaging")
    func rejectsRecursiveLocalNominals() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-recursive-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            indirect enum RecursiveValue {
                case leaf(Int)
                case next(RecursiveValue)
            }
            @inline(never)
            public func recursiveLocal(_ value: Int) -> Int {
                let item: RecursiveValue = .leaf(value)
                switch item {
                case let .leaf(output): return output
                case .next: return -1
                }
            }
            """.utf8
        ).write(to: sourceURL)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "RecursiveLocalFixture",
            additionalArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
        )
        let file = try CanonicalSIL.File(text: sil)
        let key = Bytecode.LocalTypeKey(rawValue: "RecursiveValue")
        let reference = IntermediateRepresentation.Function(
            name: "recursiveLocal",
            parameterRegisters: [],
            resultType: .void,
            registerTypes: [.local(key)],
            entryBlock: .init(rawValue: 0),
            blocks: []
        )

        #expect(
            throws: CanonicalSIL.LoweringError.unsupportedType(
                "recursive local nominal type RecursiveValue"
            )
        ) {
            try file.typeEnvironment.definitions(referencedBy: [reference])
        }
    }

    @Test("Common integer operators, comparisons, switch, and mutable locals execute as Swift")
    func compilesCommonIntegerSyntax() throws {
        let source = """
        @inline(never)
        public func intOperators(_ a: Int, _ b: Int) -> Int {
            let quotient = a / b
            let remainder = a % b
            return (quotient << 2) ^ (remainder & 7)
        }

        @inline(never)
        public func intRelations(_ a: Int, _ b: Int) -> Bool {
            a >= b && a != 0
        }

        @inline(never)
        public func choose(_ value: Int) -> Int {
            switch value {
            case 0: 10
            case 1, 2: 20
            default: 30
            }
        }

        @inline(never)
        public func mutableLocal(_ value: Int) -> Int {
            var result = value
            result += 2
            if result > 10 { result -= 1 }
            return result
        }
        """
        let integerFunctions: [(String, [Int64], Int64)] = [
            ("intOperators", [29, 5], 16),
            ("choose", [0], 10),
            ("choose", [2], 20),
            ("choose", [8], 30),
            ("mutableLocal", [7], 9),
            ("mutableLocal", [10], 11),
        ]
        for (name, inputs, expected) in integerFunctions {
            let fixture = try compileFixture(
                source: source,
                functionName: name,
                signature: .init(
                    parameters: Array(repeating: "Swift.Int", count: inputs.count),
                    result: "Swift.Int"
                ),
                parameterTypes: Array(repeating: .int64, count: inputs.count),
                resultType: .int64
            )
            let arguments = try inputs.map {
                VM.Value.integer(
                    try VM.Integer(signed: $0, bitWidth: 64, isSigned: true)
                )
            }
            let expectedValue = try VM.Integer(signed: expected, bitWidth: 64, isSigned: true)
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: fixture.image,
                    arguments: arguments
                ) == .returned(.integer(expectedValue))
            )
        }

        let relation = try compileFixture(
            source: source,
            functionName: "intRelations",
            signature: .init(parameters: ["Swift.Int", "Swift.Int"], result: "Swift.Bool"),
            parameterTypes: [.int64, .int64],
            resultType: .bool
        )
        let three = try VM.Value.integer(
            VM.Integer(signed: 3, bitWidth: 64, isSigned: true)
        )
        let four = try VM.Value.integer(
            VM.Integer(signed: 4, bitWidth: 64, isSigned: true)
        )
        let zero = try VM.Value.integer(
            VM.Integer(signed: 0, bitWidth: 64, isSigned: true)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: relation.image,
                arguments: [four, three]
            ) == .returned(.bool(true))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: relation.image,
                arguments: [zero, zero]
            ) == .returned(.bool(false))
        )

        let operators = try compileFixture(
            source: source,
            functionName: "intOperators",
            signature: .init(parameters: ["Swift.Int", "Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64, .int64],
            resultType: .int64
        )
        let one = try VM.Value.integer(
            VM.Integer(signed: 1, bitWidth: 64, isSigned: true)
        )
        let negativeOne = try VM.Value.integer(
            VM.Integer(signed: -1, bitWidth: 64, isSigned: true)
        )
        let minimum = try VM.Value.integer(
            VM.Integer(signed: .min, bitWidth: 64, isSigned: true)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: operators.image,
                arguments: [one, zero]
            ) == .trapped(.divisionByZero)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: operators.image,
                arguments: [minimum, negativeOne]
            ) == .trapped(.integerOverflow)
        )
    }

    @Test("Range for-in, break, continue, and defer lower to typed CFG")
    func compilesCommonStructuredControlFlow() throws {
        let source = """
        @inline(never)
        public func rangeLoop(_ count: Int) -> Int {
            var total = 0
            for value in 0..<count {
                if value == 2 { continue }
                total += value
                if total > 100 { break }
            }
            return total
        }

        @inline(never)
        public func deferred(_ value: Int) -> Int {
            var result = value
            do {
                defer { result += 3 }
                result *= 2
            }
            return result
        }
        """
        let loop = try compileFixture(
            source: source,
            functionName: "rangeLoop",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64],
            resultType: .int64,
            purpose: .semanticLowering
        )
        #expect(loop.compiled.disassembly.contains("load_stack.copy"))
        #expect(loop.compiled.disassembly.contains("checked_add"))
        #expect(loop.compiled.disassembly.contains("cond_br"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: loop.image,
                arguments: [
                    .integer(
                        try VM.Integer(signed: -3, bitWidth: 64, isSigned: true)
                    ),
                ]
            ) == .trapped(.explicit("Range requires lowerBound <= upperBound"))
        )
        for (count, expected) in [(0, 0), (6, 13), (30, 103)] {
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: loop.image,
                    arguments: [
                        .integer(
                            try VM.Integer(
                                signed: Int64(count),
                                bitWidth: 64,
                                isSigned: true
                            )
                        ),
                    ]
                ) == .returned(
                    .integer(
                        try VM.Integer(
                            signed: Int64(expected),
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            )
        }

        let deferred = try compileFixture(
            source: source,
            functionName: "deferred",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64],
            resultType: .int64
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: deferred.image,
                arguments: [
                    .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 11, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Fixed-width signed integers preserve Swift wrapping, bitwise, shift, and relation semantics")
    func compilesFixedWidthSignedIntegers() throws {
        let source = """
        @inline(never)
        public func int8Math(_ a: Int8, _ b: Int8) -> Int8 {
            (a &+ b) ^ (a | b)
        }

        @inline(never)
        public func int16Math(_ a: Int16, _ b: Int16) -> Int16 {
            (a &- b) & (a >> 2)
        }

        @inline(never)
        public func int32Relation(_ a: Int32, _ b: Int32) -> Bool {
            a < b || a == 7
        }

        @inline(never)
        public func int64Unary(_ value: Int64) -> Int64 {
            ~value
        }
        """

        let int8 = try compileFixture(
            source: source,
            functionName: "int8Math",
            signature: .init(parameters: ["Swift.Int8", "Swift.Int8"], result: "Swift.Int8"),
            parameterTypes: [.integer(bitWidth: 8, signed: true), .integer(bitWidth: 8, signed: true)],
            resultType: .integer(bitWidth: 8, signed: true)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: int8.image,
                arguments: [
                    .integer(try VM.Integer(signed: 120, bitWidth: 8, isSigned: true)),
                    .integer(try VM.Integer(signed: 10, bitWidth: 8, isSigned: true)),
                ]
            ) == .returned(.integer(try VM.Integer(signed: -8, bitWidth: 8, isSigned: true)))
        )

        let int16 = try compileFixture(
            source: source,
            functionName: "int16Math",
            signature: .init(parameters: ["Swift.Int16", "Swift.Int16"], result: "Swift.Int16"),
            parameterTypes: [.integer(bitWidth: 16, signed: true), .integer(bitWidth: 16, signed: true)],
            resultType: .integer(bitWidth: 16, signed: true)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: int16.image,
                arguments: [
                    .integer(try VM.Integer(signed: -64, bitWidth: 16, isSigned: true)),
                    .integer(try VM.Integer(signed: 5, bitWidth: 16, isSigned: true)),
                ]
            ) == .returned(.integer(try VM.Integer(signed: -80, bitWidth: 16, isSigned: true)))
        )

        let int32 = try compileFixture(
            source: source,
            functionName: "int32Relation",
            signature: .init(parameters: ["Swift.Int32", "Swift.Int32"], result: "Swift.Bool"),
            parameterTypes: [.integer(bitWidth: 32, signed: true), .integer(bitWidth: 32, signed: true)],
            resultType: .bool
        )
        for (lhs, rhs, expected) in [(4, 9, true), (7, 1, true), (8, 1, false)] {
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: int32.image,
                    arguments: [
                        .integer(try VM.Integer(signed: Int64(lhs), bitWidth: 32, isSigned: true)),
                        .integer(try VM.Integer(signed: Int64(rhs), bitWidth: 32, isSigned: true)),
                    ]
                ) == .returned(.bool(expected))
            )
        }

        let int64 = try compileFixture(
            source: source,
            functionName: "int64Unary",
            signature: .init(parameters: ["Swift.Int64"], result: "Swift.Int64"),
            parameterTypes: [.int64],
            resultType: .int64
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: int64.image,
                arguments: [.integer(try VM.Integer(signed: 0, bitWidth: 64, isSigned: true))]
            ) == .returned(.integer(try VM.Integer(signed: -1, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("UInt families preserve unsigned arithmetic, literals, shifts, and comparisons")
    func compilesUnsignedIntegers() throws {
        let source = """
        @inline(never)
        public func uintMath(_ a: UInt, _ b: UInt) -> UInt {
            ((a &+ b) ^ 3) >> 1
        }

        @inline(never)
        public func uint8Relation(_ a: UInt8, _ b: UInt8) -> Bool {
            a > b && (a & 1) == 0
        }

        @inline(never)
        public func uint16Division(_ value: UInt16) -> UInt16 {
            value / 3 + 2
        }
        """

        let uint64 = Bytecode.ValueType.integer(bitWidth: 64, signed: false)
        let uint = try compileFixture(
            source: source,
            functionName: "uintMath",
            signature: .init(
                parameters: ["Swift.UInt", "Swift.UInt"],
                result: "Swift.UInt"
            ),
            parameterTypes: [uint64, uint64],
            resultType: uint64
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: uint.image,
                arguments: [
                    .integer(try VM.Integer(rawBits: 20, bitWidth: 64, isSigned: false)),
                    .integer(try VM.Integer(rawBits: 7, bitWidth: 64, isSigned: false)),
                ]
            ) == .returned(
                .integer(try VM.Integer(rawBits: 12, bitWidth: 64, isSigned: false))
            )
        )

        let uint8 = Bytecode.ValueType.integer(bitWidth: 8, signed: false)
        let relation = try compileFixture(
            source: source,
            functionName: "uint8Relation",
            signature: .init(
                parameters: ["Swift.UInt8", "Swift.UInt8"],
                result: "Swift.Bool"
            ),
            parameterTypes: [uint8, uint8],
            resultType: .bool
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: relation.image,
                arguments: [
                    .integer(try VM.Integer(rawBits: 8, bitWidth: 8, isSigned: false)),
                    .integer(try VM.Integer(rawBits: 3, bitWidth: 8, isSigned: false)),
                ]
            ) == .returned(.bool(true))
        )

        let uint16 = Bytecode.ValueType.integer(bitWidth: 16, signed: false)
        let division = try compileFixture(
            source: source,
            functionName: "uint16Division",
            signature: .init(parameters: ["Swift.UInt16"], result: "Swift.UInt16"),
            parameterTypes: [uint16],
            resultType: uint16
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: division.image,
                arguments: [
                    .integer(try VM.Integer(rawBits: 30, bitWidth: 16, isSigned: false)),
                ]
            ) == .returned(
                .integer(try VM.Integer(rawBits: 12, bitWidth: 16, isSigned: false))
            )
        )
    }

    @Test("Bool negation and while loops lower through verified CFG")
    func compilesBoolNegationAndWhileLoop() throws {
        let source = """
        @inline(never)
        public func boolNot(_ value: Bool) -> Bool {
            !value
        }

        @inline(never)
        public func whileSum(_ value: Int) -> Int {
            var index = 0
            var result = 0
            while index < value {
                result += index
                index += 1
            }
            return result
        }
        """

        let boolNot = try compileFixture(
            source: source,
            functionName: "boolNot",
            signature: .init(parameters: ["Swift.Bool"], result: "Swift.Bool"),
            parameterTypes: [.bool],
            resultType: .bool
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: boolNot.image,
                arguments: [.bool(true)]
            ) == .returned(.bool(false))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: boolNot.image,
                arguments: [.bool(false)]
            ) == .returned(.bool(true))
        )

        let whileSum = try compileFixture(
            source: source,
            functionName: "whileSum",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64],
            resultType: .int64
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: whileSum.image,
                arguments: [.integer(try VM.Integer(signed: 5, bitWidth: 64, isSigned: true))]
            ) == .returned(.integer(try VM.Integer(signed: 10, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("Float and Double arithmetic, literals, comparison, and negation execute with Swift semantics")
    func compilesFloatingPointSyntax() throws {
        let source = """
        @inline(never)
        public func floatMath(_ a: Float, _ b: Float) -> Float {
            ((a + b) - 1.5) * (a / b)
        }

        @inline(never)
        public func doubleMath(_ a: Double, _ b: Double) -> Double {
            (a * b) + (a / b)
        }

        @inline(never)
        public func doubleLiteral(_ flag: Bool) -> Double {
            flag ? -2.25 : 0.125
        }

        @inline(never)
        public func floatEqual(_ a: Float, _ b: Float) -> Bool { a == b }

        @inline(never)
        public func floatNotEqual(_ a: Float, _ b: Float) -> Bool { a != b }

        @inline(never)
        public func floatLess(_ a: Float, _ b: Float) -> Bool { a < b }

        @inline(never)
        public func floatNegate(_ value: Float) -> Float { -value }

        @inline(never)
        public func floatDivide(_ a: Float, _ b: Float) -> Float { a / b }
        """

        let floatType = Bytecode.ValueType.float(bitWidth: 32)
        let floatMath = try compileFixture(
            source: source,
            functionName: "floatMath",
            signature: .init(parameters: ["Swift.Float", "Swift.Float"], result: "Swift.Float"),
            parameterTypes: [floatType, floatType],
            resultType: floatType
        )
        let lhs = Float(3.25)
        let rhs = Float(2)
        let expected = ((lhs + rhs) - 1.5) * (lhs / rhs)
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: floatMath.image,
                arguments: [
                    .float32(lhs),
                    .float32(rhs),
                ]
            ) == .returned(.float32(expected))
        )
        #expect(floatMath.compiled.disassembly.contains("float_add"))
        #expect(floatMath.compiled.disassembly.contains("float_divide"))

        let doubleType = Bytecode.ValueType.float(bitWidth: 64)
        let doubleMath = try compileFixture(
            source: source,
            functionName: "doubleMath",
            signature: .init(parameters: ["Swift.Double", "Swift.Double"], result: "Swift.Double"),
            parameterTypes: [doubleType, doubleType],
            resultType: doubleType
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: doubleMath.image,
                arguments: [.float64(4), .float64(2)]
            ) == .returned(.float64(10))
        )

        let doubleLiteral = try compileFixture(
            source: source,
            functionName: "doubleLiteral",
            signature: .init(parameters: ["Swift.Bool"], result: "Swift.Double"),
            parameterTypes: [.bool],
            resultType: doubleType
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: doubleLiteral.image,
                arguments: [.bool(true)]
            ) == .returned(.float64(-2.25))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: doubleLiteral.image,
                arguments: [.bool(false)]
            ) == .returned(.float64(0.125))
        )

        for (name, expected) in [
            ("floatEqual", false),
            ("floatNotEqual", true),
            ("floatLess", false),
        ] {
            let comparison = try compileFixture(
                source: source,
                functionName: name,
                signature: .init(parameters: ["Swift.Float", "Swift.Float"], result: "Swift.Bool"),
                parameterTypes: [floatType, floatType],
                resultType: .bool
            )
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: comparison.image,
                    arguments: [.float32(.nan), .float32(1)]
                ) == .returned(.bool(expected))
            )
        }

        let negate = try compileFixture(
            source: source,
            functionName: "floatNegate",
            signature: .init(parameters: ["Swift.Float"], result: "Swift.Float"),
            parameterTypes: [floatType],
            resultType: floatType
        )
        guard case let .returned(.some(.float(negatedZero))) = VM.Interpreter().invoke(
            entry: .init(rawValue: 0),
            image: negate.image,
            arguments: [.float32(-0.0)]
        ), negatedZero.bitWidth == 32 else {
            Issue.record("Float negation did not return Float32")
            return
        }
        #expect(negatedZero.floatValue == 0)
        #expect(negatedZero.floatValue.sign == .plus)

        let divide = try compileFixture(
            source: source,
            functionName: "floatDivide",
            signature: .init(parameters: ["Swift.Float", "Swift.Float"], result: "Swift.Float"),
            parameterTypes: [floatType, floatType],
            resultType: floatType
        )
        guard case let .returned(.some(.float(infinity))) = VM.Interpreter().invoke(
            entry: .init(rawValue: 0),
            image: divide.image,
            arguments: [.float32(1), .float32(0)]
        ), infinity.bitWidth == 32 else {
            Issue.record("Float division did not return Float32")
            return
        }
        #expect(infinity.floatValue == .infinity)
    }

    @Test("Common integer and floating-point conversions preserve Swift semantics")
    func compilesNumericConversions() throws {
        let source = """
        @inline(never)
        public func checkedInt32(_ value: Int) -> Int32 { Int32(value) }

        @inline(never)
        public func truncatingInt8(_ value: Int) -> Int8 { Int8(truncatingIfNeeded: value) }

        @inline(never)
        public func clampingInt8(_ value: Int) -> Int8 { Int8(clamping: value) }

        @inline(never)
        public func exactlyInt8(_ value: Int) -> Int8? { Int8(exactly: value) }

        @inline(never)
        public func widenInt32(_ value: Int32) -> Int { Int(value) }

        @inline(never)
        public func widenUInt8(_ value: UInt8) -> UInt64 { UInt64(value) }

        @inline(never)
        public func floatFromDouble(_ value: Double) -> Float { Float(value) }

        @inline(never)
        public func doubleFromFloat(_ value: Float) -> Double { Double(value) }

        @inline(never)
        public func doubleFromInt(_ value: Int) -> Double { Double(value) }

        @inline(never)
        public func doubleFromUInt(_ value: UInt64) -> Double { Double(value) }
        """

        func integer(
            _ functionName: String,
            parameterType: Bytecode.ValueType,
            resultType: Bytecode.ValueType,
            input: VM.Integer
        ) throws -> VM.ExecutionResult {
            let fixture = try compileFixture(
                source: source,
                functionName: functionName,
                signature: .init(parameters: [parameterType.description], result: resultType.description),
                parameterTypes: [parameterType],
                resultType: resultType
            )
            #expect(fixture.compiled.disassembly.contains("integer_convert"))
            return VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [.integer(input)]
            )
        }

        #expect(
            try integer(
                "checkedInt32",
                parameterType: .int64,
                resultType: .integer(bitWidth: 32, signed: true),
                input: .init(signed: 123_456, bitWidth: 64, isSigned: true)
            ) == .returned(
                .integer(try .init(signed: 123_456, bitWidth: 32, isSigned: true))
            )
        )
        #expect(
            try integer(
                "checkedInt32",
                parameterType: .int64,
                resultType: .integer(bitWidth: 32, signed: true),
                input: .init(signed: Int64(Int32.max) + 1, bitWidth: 64, isSigned: true)
            ) == .trapped(.integerOverflow)
        )
        #expect(
            try integer(
                "truncatingInt8",
                parameterType: .int64,
                resultType: .integer(bitWidth: 8, signed: true),
                input: .init(signed: 255, bitWidth: 64, isSigned: true)
            ) == .returned(.integer(try .init(signed: -1, bitWidth: 8, isSigned: true)))
        )
        #expect(
            try integer(
                "clampingInt8",
                parameterType: .int64,
                resultType: .integer(bitWidth: 8, signed: true),
                input: .init(signed: 1_000, bitWidth: 64, isSigned: true)
            ) == .returned(.integer(try .init(signed: 127, bitWidth: 8, isSigned: true)))
        )

        let exactly = try compileFixture(
            source: source,
            functionName: "exactlyInt8",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Optional<Swift.Int8>"),
            parameterTypes: [.int64],
            resultType: .optional(.integer(bitWidth: 8, signed: true))
        )
        for (raw, expected) in [(Int64(42), Int64?.some(42)), (128, nil)] {
            let result = VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: exactly.image,
                arguments: [.integer(try .init(signed: raw, bitWidth: 64, isSigned: true))]
            )
            let value = try expected.map {
                VM.Value.integer(try .init(signed: $0, bitWidth: 8, isSigned: true))
            }
            #expect(result == .returned(.optional(value)))
        }

        #expect(
            try integer(
                "widenInt32",
                parameterType: .integer(bitWidth: 32, signed: true),
                resultType: .int64,
                input: .init(signed: -17, bitWidth: 32, isSigned: true)
            ) == .returned(.integer(try .init(signed: -17, bitWidth: 64, isSigned: true)))
        )
        #expect(
            try integer(
                "widenUInt8",
                parameterType: .integer(bitWidth: 8, signed: false),
                resultType: .integer(bitWidth: 64, signed: false),
                input: .init(rawBits: 255, bitWidth: 8, isSigned: false)
            ) == .returned(.integer(try .init(rawBits: 255, bitWidth: 64, isSigned: false)))
        )

        let doubleType = Bytecode.ValueType.float(bitWidth: 64)
        let floatType = Bytecode.ValueType.float(bitWidth: 32)
        let truncate = try compileFixture(
            source: source,
            functionName: "floatFromDouble",
            signature: .init(parameters: ["Swift.Double"], result: "Swift.Float"),
            parameterTypes: [doubleType],
            resultType: floatType
        )
        let unrepresentable = 16_777_217.0
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: truncate.image,
                arguments: [.float64(unrepresentable)]
            ) == .returned(.float32(Float(unrepresentable)))
        )

        let extend = try compileFixture(
            source: source,
            functionName: "doubleFromFloat",
            signature: .init(parameters: ["Swift.Float"], result: "Swift.Double"),
            parameterTypes: [floatType],
            resultType: doubleType
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: extend.image,
                arguments: [.float32(.pi)]
            ) == .returned(.float64(Double(Float.pi)))
        )

        let signedInteger = try VM.Integer(
            signed: -9_007_199_254_740_993,
            bitWidth: 64,
            isSigned: true
        )
        let unsignedInteger = try VM.Integer(
            rawBits: UInt64.max,
            bitWidth: 64,
            isSigned: false
        )
        let integerToFloatCases: [(
            name: String,
            type: Bytecode.ValueType,
            argument: VM.Integer,
            expected: Double
        )] = [
            (
                "doubleFromInt",
                Bytecode.ValueType.int64,
                signedInteger,
                Double(Int64(-9_007_199_254_740_993))
            ),
            (
                "doubleFromUInt",
                Bytecode.ValueType.integer(bitWidth: 64, signed: false),
                unsignedInteger,
                Double(UInt64.max)
            ),
        ]
        for (name, type, argument, expected) in integerToFloatCases {
            let fixture = try compileFixture(
                source: source,
                functionName: name,
                signature: .init(parameters: [type.description], result: "Swift.Double"),
                parameterTypes: [type],
                resultType: doubleType
            )
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: fixture.image,
                    arguments: [.integer(argument)]
                ) == .returned(.float64(expected))
            )
        }
    }

    @Test("String literals, comparison, concatenation, and properties preserve Swift semantics")
    func compilesCommonStringSyntax() throws {
        let source = """
        @inline(never)
        public func stringLiteral(_ first: Bool) -> String {
            first ? "你好\\n" : "https://example.test/path"
        }

        @inline(never)
        public func stringEqual(_ lhs: String, _ rhs: String) -> Bool { lhs == rhs }

        @inline(never)
        public func stringNotEqual(_ lhs: String, _ rhs: String) -> Bool { lhs != rhs }

        @inline(never)
        public func stringLess(_ lhs: String, _ rhs: String) -> Bool { lhs < rhs }

        @inline(never)
        public func stringConcat(_ lhs: String, _ rhs: String) -> String { lhs + rhs }

        @inline(never)
        public func stringCount(_ value: String) -> Int { value.count }

        @inline(never)
        public func stringIsEmpty(_ value: String) -> Bool { value.isEmpty }

        @inline(never)
        public func stringHasPrefix(_ value: String, _ pattern: String) -> Bool {
            value.hasPrefix(pattern)
        }

        @inline(never)
        public func stringHasSuffix(_ value: String, _ pattern: String) -> Bool {
            value.hasSuffix(pattern)
        }

        @inline(never)
        public func stringContains(_ value: String, _ pattern: String) -> Bool {
            value.contains(pattern)
        }

        @inline(never)
        public func containsFamilyEmoji(_ value: String) -> Bool {
            value.contains("👨‍👩‍👧‍👦")
        }
        """
        let semanticSILArguments = ["-Xfrontend", "-disable-sil-perf-optzns"]
        let stringParameters = Core.LoweredSignature(
            parameters: ["Swift.String", "Swift.String"],
            result: "Swift.Bool"
        )

        let literal = try compileFixture(
            source: source,
            functionName: "stringLiteral",
            signature: .init(parameters: ["Swift.Bool"], result: "Swift.String"),
            parameterTypes: [.bool],
            resultType: .string,
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(literal.compiled.module.capabilities.contains(.stringsV1))
        #expect(literal.compiled.disassembly.contains("const_string"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: literal.image,
                arguments: [.bool(true)]
            ) == .returned(.string("你好\n"))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: literal.image,
                arguments: [.bool(false)]
            ) == .returned(.string("https://example.test/path"))
        )

        for (name, lhs, rhs, expected) in [
            ("stringEqual", "café", "café", true),
            ("stringNotEqual", "café", "cafe", true),
            ("stringLess", "apple", "banana", true),
        ] {
            let fixture = try compileFixture(
                source: source,
                functionName: name,
                signature: stringParameters,
                parameterTypes: [.string, .string],
                resultType: .bool,
                additionalFrontendArguments: semanticSILArguments
            )
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: fixture.image,
                    arguments: [.string(lhs), .string(rhs)]
                ) == .returned(.bool(expected))
            )
        }

        let concatenation = try compileFixture(
            source: source,
            functionName: "stringConcat",
            signature: .init(
                parameters: ["Swift.String", "Swift.String"],
                result: "Swift.String"
            ),
            parameterTypes: [.string, .string],
            resultType: .string,
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(concatenation.compiled.disassembly.contains("string_concat"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: concatenation.image,
                arguments: [.string("Hel"), .string("ix🧬")]
            ) == .returned(.string("Helix🧬"))
        )

        let count = try compileFixture(
            source: source,
            functionName: "stringCount",
            signature: .init(parameters: ["Swift.String"], result: "Swift.Int"),
            parameterTypes: [.string],
            resultType: .int64,
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(count.compiled.disassembly.contains("string_count"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: count.image,
                arguments: [.string("👨‍👩‍👧‍👦")]
            ) == .returned(.integer(try VM.Integer(signed: 1, bitWidth: 64, isSigned: true)))
        )

        let isEmpty = try compileFixture(
            source: source,
            functionName: "stringIsEmpty",
            signature: .init(parameters: ["Swift.String"], result: "Swift.Bool"),
            parameterTypes: [.string],
            resultType: .bool,
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: isEmpty.image,
                arguments: [.string("")]
            ) == .returned(.bool(true))
        )

        let value = "Cafe\u{301} · Helix🧬"
        for (name, pattern, expected) in [
            ("stringHasPrefix", "Café", value.hasPrefix("Café")),
            ("stringHasSuffix", "Helix🧬", value.hasSuffix("Helix🧬")),
            ("stringContains", "é · H", value.contains("é · H")),
            ("stringContains", "missing", value.contains("missing")),
        ] {
            let fixture = try compileFixture(
                source: source,
                functionName: name,
                signature: stringParameters,
                parameterTypes: [.string, .string],
                resultType: .bool,
                additionalFrontendArguments: semanticSILArguments
            )
            #expect(fixture.compiled.disassembly.contains("string_"))
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: fixture.image,
                    arguments: [.string(value), .string(pattern)]
                ) == .returned(.bool(expected))
            )
        }

        let character = try compileFixture(
            source: source,
            functionName: "containsFamilyEmoji",
            signature: .init(parameters: ["Swift.String"], result: "Swift.Bool"),
            parameterTypes: [.string],
            resultType: .bool,
            purpose: .semanticLowering
        )
        #expect(character.compiled.disassembly.contains("string_contains"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: character.image,
                arguments: [.string("Team 👨‍👩‍👧‍👦")]
            ) == .returned(.bool(true))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: character.image,
                arguments: [.string("Team 👨‍👩‍👧")]
            ) == .returned(.bool(false))
        )
    }

    @Test("String interpolation supports frozen scalar payload semantics")
    func compilesScalarStringInterpolation() throws {
        let source = """
        @inline(never)
        public func interpolate(
            _ text: String,
            _ integer: Int,
            _ boolean: Bool,
            _ floating: Double
        ) -> String {
            "\\(text):\\(integer):\\(boolean):\\(floating)"
        }
        """
        let fixture = try compileFixture(
            source: source,
            functionName: "interpolate",
            signature: .init(
                parameters: ["Swift.String", "Swift.Int", "Swift.Bool", "Swift.Double"],
                result: "Swift.String"
            ),
            parameterTypes: [.string, .int64, .bool, .float(bitWidth: 64)],
            resultType: .string,
            additionalFrontendArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
        )
        #expect(fixture.compiled.disassembly.contains("stringify"))
        #expect(fixture.compiled.disassembly.contains("string_concat"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [
                    .string("Helix🧬"),
                    .integer(try VM.Integer(signed: -7, bitWidth: 64, isSigned: true)),
                    .bool(true),
                    .float64(1.25),
                ]
            ) == .returned(.string("Helix🧬:-7:true:1.25"))
        )
        let texts = ["", "ASCII", "🧬", "e\u{301}", "👨‍👩‍👧‍👦"]
        for caseID in 0..<100 {
            let text = texts[caseID % texts.count]
            let integer = Int64((caseID * 7_919) % 2_000 - 1_000)
            let boolean = caseID.isMultiple(of: 2)
            let floating = Double((caseID * 104_729) % 20_000 - 10_000) / 16
            let expected = "\(text):\(integer):\(boolean):\(floating)"
            #expect(
                VM.Interpreter().invoke(
                    entry: .init(rawValue: 0),
                    image: fixture.image,
                    arguments: [
                        .string(text),
                        .integer(
                            try VM.Integer(
                                signed: integer,
                                bitWidth: 64,
                                isSigned: true
                            )
                        ),
                        .bool(boolean),
                        .float64(floating),
                    ]
                ) == .returned(.string(expected)),
                Comment(rawValue: "String interpolation mismatch for case \(caseID)")
            )
        }
    }

    @Test("Unoptimized String interpolation accepts copy-then-destroy SIL ownership")
    func compilesUnoptimizedStringInterpolation() throws {
        let fixture = try compileFixture(
            source: "public func interpolate(_ value: Int) -> String { \"value: \\(value)\" }",
            functionName: "interpolate",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.String"),
            parameterTypes: [.int64],
            resultType: .string,
            purpose: .semanticLowering,
            optimization: "-Onone"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: fixture.image,
                arguments: [
                    .integer(try VM.Integer(signed: 42, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(.string("value: 42"))
        )
    }

    @Test("Custom String interpolation overloads remain a stable rejection")
    func rejectsCustomStringInterpolation() throws {
        let source = """
        struct Label: CustomStringConvertible {
            var value: Int
            var description: String { String(value) }
        }
        @inline(never)
        public func interpolateCustom(_ value: Int) -> String {
            "\\(Label(value: value))"
        }
        """
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try compileFixture(
                source: source,
                functionName: "interpolateCustom",
                signature: .init(parameters: ["Swift.Int"], result: "Swift.String"),
                parameterTypes: [.int64],
                resultType: .string,
                additionalFrontendArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
            )
        }
    }

    @Test("Locale-dependent String transforms remain a stable compile-time rejection")
    func rejectsLocaleDependentStringTransform() throws {
        let source = """
        import Foundation
        @inline(never)
        public func localeUpper(_ value: String) -> String {
            value.uppercased(with: Locale(identifier: "tr_TR"))
        }
        """
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try compileFixture(
                source: source,
                functionName: "localeUpper",
                signature: .init(parameters: ["Swift.String"], result: "Swift.String"),
                parameterTypes: [.string],
                resultType: .string,
                additionalFrontendArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
            )
        }
    }

    @Test("Array count, emptiness, subscript, first, and contains preserve Swift semantics")
    func compilesCommonArrayReads() throws {
        let source = """
        @inline(never)
        public func arrayCount(_ values: [Int]) -> Int { values.count }

        @inline(never)
        public func arrayIsEmpty(_ values: [Int]) -> Bool { values.isEmpty }

        @inline(never)
        public func arrayGet(_ values: [Int], _ index: Int) -> Int { values[index] }

        @inline(never)
        public func arrayFirst(_ values: [Int]) -> Int? { values.first }

        @inline(never)
        public func arrayContains(_ values: [Int], _ value: Int) -> Bool {
            values.contains(value)
        }
        """
        let semanticSILArguments = ["-Xfrontend", "-disable-sil-perf-optzns"]
        let arrayType = Bytecode.ValueType.array(.int64)
        let integers = try [3, 5, 8].map {
            VM.Value.integer(
                try VM.Integer(signed: Int64($0), bitWidth: 64, isSigned: true)
            )
        }
        let array = VM.Value.array(integers, elementType: .int64)

        let count = try compileFixture(
            source: source,
            functionName: "arrayCount",
            signature: .init(parameters: ["Swift.Array<Swift.Int>"], result: "Swift.Int"),
            parameterTypes: [arrayType],
            resultType: .int64,
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(count.compiled.module.capabilities.contains(.collectionsV1))
        #expect(count.compiled.disassembly.contains("array_count"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: count.image,
                arguments: [array]
            ) == .returned(.integer(try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)))
        )

        let isEmpty = try compileFixture(
            source: source,
            functionName: "arrayIsEmpty",
            signature: .init(parameters: ["Swift.Array<Swift.Int>"], result: "Swift.Bool"),
            parameterTypes: [arrayType],
            resultType: .bool,
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: isEmpty.image,
                arguments: [.array([], elementType: .int64)]
            ) == .returned(.bool(true))
        )

        let get = try compileFixture(
            source: source,
            functionName: "arrayGet",
            signature: .init(
                parameters: ["Swift.Array<Swift.Int>", "Swift.Int"],
                result: "Swift.Int"
            ),
            parameterTypes: [arrayType, .int64],
            resultType: .int64,
            additionalFrontendArguments: semanticSILArguments
        )
        let index = try VM.Value.integer(
            VM.Integer(signed: 1, bitWidth: 64, isSigned: true)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: get.image,
                arguments: [array, index]
            ) == .returned(integers[1])
        )
        let invalidIndex = try VM.Value.integer(
            VM.Integer(signed: -1, bitWidth: 64, isSigned: true)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: get.image,
                arguments: [array, invalidIndex]
            ) == .trapped(.arrayIndexOutOfBounds(index: -1, count: 3))
        )

        let first = try compileFixture(
            source: source,
            functionName: "arrayFirst",
            signature: .init(
                parameters: ["Swift.Array<Swift.Int>"],
                result: "Swift.Optional<Swift.Int>"
            ),
            parameterTypes: [arrayType],
            resultType: .optional(.int64),
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: first.image,
                arguments: [array]
            ) == .returned(.optional(integers[0]))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: first.image,
                arguments: [.array([], elementType: .int64)]
            ) == .returned(.optional(nil))
        )

        let contains = try compileFixture(
            source: source,
            functionName: "arrayContains",
            signature: .init(
                parameters: ["Swift.Array<Swift.Int>", "Swift.Int"],
                result: "Swift.Bool"
            ),
            parameterTypes: [arrayType, .int64],
            resultType: .bool,
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: contains.image,
                arguments: [array, integers[1]]
            ) == .returned(.bool(true))
        )
    }

    @Test("Array append and for-in preserve value and iteration semantics")
    func compilesArrayMutationAndIteration() throws {
        let source = """
        @inline(never)
        public func arrayAppend(_ values: [Int], _ value: Int) -> [Int] {
            var result = values
            result.append(value)
            return result
        }

        @inline(never)
        public func arraySet(_ values: [Int], _ index: Int, _ value: Int) -> [Int] {
            var result = values
            result[index] = value
            return result
        }

        @inline(never)
        public func arrayLoop(_ values: [Int]) -> Int {
            var total = 0
            for value in values { total += value }
            return total
        }
        """
        let semanticSILArguments = ["-Xfrontend", "-disable-sil-perf-optzns"]
        let arrayType = Bytecode.ValueType.array(.int64)
        let values = try [2, 5, 9].map {
            VM.Value.integer(
                try VM.Integer(signed: Int64($0), bitWidth: 64, isSigned: true)
            )
        }
        let array = VM.Value.array(Array(values.prefix(2)), elementType: .int64)

        let append = try compileFixture(
            source: source,
            functionName: "arrayAppend",
            signature: .init(
                parameters: ["Swift.Array<Swift.Int>", "Swift.Int"],
                result: "Swift.Array<Swift.Int>"
            ),
            parameterTypes: [arrayType, .int64],
            resultType: arrayType,
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(append.compiled.disassembly.contains("array_append"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: append.image,
                arguments: [array, values[2]]
            ) == .returned(.array(values, elementType: .int64))
        )

        let set = try compileFixture(
            source: source,
            functionName: "arraySet",
            signature: .init(
                parameters: ["Swift.Array<Swift.Int>", "Swift.Int", "Swift.Int"],
                result: "Swift.Array<Swift.Int>"
            ),
            parameterTypes: [arrayType, .int64, .int64],
            resultType: arrayType,
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(set.compiled.disassembly.contains("array_update"))
        let one = try VM.Value.integer(
            VM.Integer(signed: 1, bitWidth: 64, isSigned: true)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: set.image,
                arguments: [array, one, values[2]]
            ) == .returned(.array([values[0], values[2]], elementType: .int64))
        )
        let minusOne = try VM.Value.integer(
            VM.Integer(signed: -1, bitWidth: 64, isSigned: true)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: set.image,
                arguments: [array, minusOne, values[2]]
            ) == .trapped(.arrayIndexOutOfBounds(index: -1, count: 2))
        )

        let loop = try compileFixture(
            source: source,
            functionName: "arrayLoop",
            signature: .init(
                parameters: ["Swift.Array<Swift.Int>"],
                result: "Swift.Int"
            ),
            parameterTypes: [arrayType],
            resultType: .int64,
            additionalFrontendArguments: semanticSILArguments
        )
        #expect(loop.compiled.disassembly.contains("collection_next_forward"))
        #expect(loop.compiled.disassembly.contains("destroy_stack"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: loop.image,
                arguments: [.array(values, elementType: .int64)]
            ) == .returned(.integer(try VM.Integer(signed: 16, bitWidth: 64, isSigned: true)))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: loop.image,
                arguments: [.array([], elementType: .int64)]
            ) == .returned(.integer(try VM.Integer(signed: 0, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("Array literals are reconstructed without interpreting standard-library storage")
    func compilesArrayLiterals() throws {
        let source = """
        @inline(never)
        public func arrayLiteral(_ first: Int, _ second: Int) -> [Int] {
            [first, second, 3]
        }

        @inline(never)
        public func emptyArray() -> [Int] { [] }
        """
        let arguments = ["-Xfrontend", "-disable-sil-perf-optzns"]
        let arrayType = Bytecode.ValueType.array(.int64)
        let literal = try compileFixture(
            source: source,
            functionName: "arrayLiteral",
            signature: .init(
                parameters: ["Swift.Int", "Swift.Int"],
                result: "Swift.Array<Swift.Int>"
            ),
            parameterTypes: [.int64, .int64],
            resultType: arrayType,
            additionalFrontendArguments: arguments
        )
        let first = try VM.Value.integer(
            VM.Integer(signed: 7, bitWidth: 64, isSigned: true)
        )
        let second = try VM.Value.integer(
            VM.Integer(signed: 11, bitWidth: 64, isSigned: true)
        )
        let third = try VM.Value.integer(
            VM.Integer(signed: 3, bitWidth: 64, isSigned: true)
        )
        #expect(literal.compiled.disassembly.contains("make_array"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: literal.image,
                arguments: [first, second]
            ) == .returned(.array([first, second, third], elementType: .int64))
        )

        let empty = try compileFixture(
            source: source,
            functionName: "emptyArray",
            signature: .init(parameters: [], result: "Swift.Array<Swift.Int>"),
            parameterTypes: [],
            resultType: arrayType,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: empty.image,
                arguments: []
            ) == .returned(.array([], elementType: .int64))
        )
    }

    @Test("Swift Any erasure, dynamic casts, and type tests lower to verified HLBC")
    func compilesCommonAnySyntax() throws {
        let source = """
        @inline(never)
        public func eraseInt(_ value: Int) -> Any { value }

        @inline(never)
        public func eraseOptional(_ value: Int?) -> Any { value as Any }

        @inline(never)
        public func roundTripAny(_ value: Any) -> Any {
            let copy: Any = value
            return copy
        }

        @inline(never)
        public func someErased(_ value: Int) -> Any? { value }

        @inline(never)
        public func noErased() -> Any? { nil }

        @inline(never)
        public func copyErasedOptional(_ value: Any?) -> Any? { value }

        @inline(never)
        public func unwrapErasedOptional(_ value: Any?) -> Int? {
            guard let value else { return nil }
            return value as? Int
        }

        public enum FixtureFailure: Error { case rejected }

        public struct Payload {
            public let value: Int
        }

        public struct Envelope {
            public let payload: Any
        }

        @inline(never)
        public func maybeBox(_ value: Int) throws -> Any {
            if value < 0 { throw FixtureFailure.rejected }
            return value
        }

        @inline(never)
        public func checkedInt(_ value: Any) -> Int? { value as? Int }

        @inline(never)
        public func checkedOptional(_ value: Any) -> Int?? { value as? Int? }

        @inline(never)
        public func forcedInt(_ value: Any) -> Int { value as! Int }

        @inline(never)
        public func isInt(_ value: Any) -> Bool { value is Int }

        @inline(never)
        public func checkedArray(_ value: Any) -> [Int]? { value as? [Int] }

        @inline(never)
        public func boxTuple(_ value: Int, _ text: String) -> Any {
            (value, text)
        }

        @inline(never)
        public func checkedTuple(_ value: Any) -> (Int, String)? {
            value as? (Int, String)
        }

        @inline(never)
        public func boxPayload(_ value: Int) -> Any {
            Payload(value: value)
        }

        @inline(never)
        public func payloadValue(_ value: Any) -> Int? {
            (value as? Payload)?.value
        }

        @inline(never)
        public func envelopeValue(_ value: Int) -> Int {
            let envelope = Envelope(payload: value)
            return envelope.payload as! Int
        }

        @inline(never)
        public func boxEnvelope(_ value: Int) -> Any {
            Envelope(payload: value)
        }

        @inline(never)
        public func envelopePayload(_ value: Any) -> Int? {
            guard let envelope = value as? Envelope else { return nil }
            return envelope.payload as? Int
        }

        @inline(never)
        public func dictionaryValue(
            _ values: [String: Any],
            _ key: String
        ) -> Int? {
            guard let value = values[key] else { return nil }
            return value as? Int
        }

        @inline(never)
        public func conditionalInt(_ value: Any) -> Int {
            if let integer = value as? Int { return integer }
            return 0
        }

        @inline(never)
        public func firstInt(_ values: [Any]) -> Int { values[0] as! Int }

        @inline(never)
        public func makeAnyArray(_ integer: Int, _ string: String) -> [Any] {
            [integer, string]
        }

        @inline(never)
        public func makeAnyDictionary(
            _ integer: Int,
            _ string: String
        ) -> [String: Any] {
            ["integer": integer, "string": string]
        }
        """
        let arguments = ["-Xfrontend", "-disable-sil-perf-optzns"]
        let int = VM.Value.integer(
            try VM.Integer(signed: 7, bitWidth: 64, isSigned: true)
        )
        let boxedInt = VM.Value.any(
            .init(dynamicType: .integer(.int), payload: int)
        )
        let boxedString = VM.Value.any(
            .init(dynamicType: .string, payload: .string("seven"))
        )

        let erasure = try compileFixture(
            source: source,
            functionName: "eraseInt",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Any"),
            parameterTypes: [.int64],
            resultType: .any,
            additionalFrontendArguments: arguments
        )
        #expect(erasure.compiled.disassembly.contains("erase_to_any"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: erasure.image,
                arguments: [int]
            ) == .returned(boxedInt)
        )

        let optionalIntType = Bytecode.ValueType.optional(.int64)
        let nilInt = VM.Value.optional(nil)
        let erasedOptional = try compileFixture(
            source: source,
            functionName: "eraseOptional",
            signature: .init(
                parameters: ["Swift.Optional<Swift.Int>"],
                result: "Swift.Any"
            ),
            parameterTypes: [optionalIntType],
            resultType: .any,
            additionalFrontendArguments: arguments
        )
        let boxedNilInt = VM.Value.any(
            .init(
                dynamicType: .optional(.integer(.int)),
                payload: nilInt
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: erasedOptional.image,
                arguments: [nilInt]
            ) == .returned(boxedNilInt)
        )

        let roundTrip = try compileFixture(
            source: source,
            functionName: "roundTripAny",
            signature: .init(parameters: ["Swift.Any"], result: "Swift.Any"),
            parameterTypes: [.any],
            resultType: .any,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: roundTrip.image,
                arguments: [boxedString]
            ) == .returned(boxedString)
        )

        let optionalAnyType = Bytecode.ValueType.optional(.any)
        let someErased = try compileFixture(
            source: source,
            functionName: "someErased",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Any?"),
            parameterTypes: [.int64],
            resultType: optionalAnyType,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: someErased.image,
                arguments: [int]
            ) == .returned(.optional(boxedInt))
        )
        let noErased = try compileFixture(
            source: source,
            functionName: "noErased",
            signature: .init(parameters: [], result: "Swift.Any?"),
            parameterTypes: [],
            resultType: optionalAnyType,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: noErased.image,
                arguments: []
            ) == .returned(.optional(nil))
        )
        let copiedErased = try compileFixture(
            source: source,
            functionName: "copyErasedOptional",
            signature: .init(parameters: ["Swift.Any?"], result: "Swift.Any?"),
            parameterTypes: [optionalAnyType],
            resultType: optionalAnyType,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: copiedErased.image,
                arguments: [.optional(boxedString)]
            ) == .returned(.optional(boxedString))
        )
        let unwrappedErased = try compileFixture(
            source: source,
            functionName: "unwrapErasedOptional",
            signature: .init(
                parameters: ["Swift.Any?"],
                result: "Swift.Optional<Swift.Int>"
            ),
            parameterTypes: [optionalAnyType],
            resultType: .optional(.int64),
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: unwrappedErased.image,
                arguments: [.optional(boxedInt)]
            ) == .returned(.optional(int))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: unwrappedErased.image,
                arguments: [.optional(nil)]
            ) == .returned(.optional(nil))
        )

        let throwingErasure = try compileFixture(
            source: source,
            functionName: "maybeBox",
            signature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Any",
                isThrowing: true
            ),
            parameterTypes: [.int64],
            resultType: .any,
            effects: .init(mayThrow: true),
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: throwingErasure.image,
                arguments: [int]
            ) == .returned(boxedInt)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: throwingErasure.image,
                arguments: [
                    .integer(
                        try VM.Integer(signed: -1, bitWidth: 64, isSigned: true)
                    ),
                ]
            ) == .businessError("FixtureFailure.rejected")
        )

        let checked = try compileFixture(
            source: source,
            functionName: "checkedInt",
            signature: .init(
                parameters: ["Swift.Any"],
                result: "Swift.Optional<Swift.Int>"
            ),
            parameterTypes: [.any],
            resultType: .optional(.int64),
            additionalFrontendArguments: arguments
        )
        #expect(checked.compiled.disassembly.contains("checked_cast_any"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: checked.image,
                arguments: [boxedInt]
            ) == .returned(.optional(int))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: checked.image,
                arguments: [boxedString]
            ) == .returned(.optional(nil))
        )

        let checkedOptional = try compileFixture(
            source: source,
            functionName: "checkedOptional",
            signature: .init(
                parameters: ["Swift.Any"],
                result: "Swift.Optional<Swift.Optional<Swift.Int>>"
            ),
            parameterTypes: [.any],
            resultType: .optional(optionalIntType),
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: checkedOptional.image,
                arguments: [boxedNilInt]
            ) == .returned(.optional(nilInt))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: checkedOptional.image,
                arguments: [boxedString]
            ) == .returned(.optional(nil))
        )

        let forced = try compileFixture(
            source: source,
            functionName: "forcedInt",
            signature: .init(parameters: ["Swift.Any"], result: "Swift.Int"),
            parameterTypes: [.any],
            resultType: .int64,
            additionalFrontendArguments: arguments
        )
        #expect(forced.compiled.disassembly.contains("force_cast_any"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: forced.image,
                arguments: [boxedInt]
            ) == .returned(int)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: forced.image,
                arguments: [boxedString]
            ) == .trapped(
                .dynamicCastFailure(
                    actual: .string,
                    expected: .integer(.int)
                )
            )
        )

        let typeTest = try compileFixture(
            source: source,
            functionName: "isInt",
            signature: .init(parameters: ["Swift.Any"], result: "Swift.Bool"),
            parameterTypes: [.any],
            resultType: .bool,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: typeTest.image,
                arguments: [boxedInt]
            ) == .returned(.bool(true))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: typeTest.image,
                arguments: [boxedString]
            ) == .returned(.bool(false))
        )

        let unwrapped = try compileFixture(
            source: source,
            functionName: "conditionalInt",
            signature: .init(parameters: ["Swift.Any"], result: "Swift.Int"),
            parameterTypes: [.any],
            resultType: .int64,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: unwrapped.image,
                arguments: [boxedInt]
            ) == .returned(int)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: unwrapped.image,
                arguments: [boxedString]
            ) == .returned(
                .integer(try VM.Integer(signed: 0, bitWidth: 64, isSigned: true))
            )
        )

        let firstInt = try compileFixture(
            source: source,
            functionName: "firstInt",
            signature: .init(
                parameters: ["Swift.Array<Swift.Any>"],
                result: "Swift.Int"
            ),
            parameterTypes: [.array(.any)],
            resultType: .int64,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: firstInt.image,
                arguments: [.array([boxedInt], elementType: .any)]
            ) == .returned(int)
        )

        let checkedArray = try compileFixture(
            source: source,
            functionName: "checkedArray",
            signature: .init(
                parameters: ["Swift.Any"],
                result: "Swift.Optional<Swift.Array<Swift.Int>>"
            ),
            parameterTypes: [.any],
            resultType: .optional(.array(.int64)),
            additionalFrontendArguments: arguments
        )
        let boxedArray = VM.Value.any(
            .init(
                dynamicType: .array(.any),
                payload: .array([boxedInt], elementType: .any)
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: checkedArray.image,
                arguments: [boxedArray]
            ) == .returned(
                .optional(.array([int], elementType: .int64))
            )
        )

        let tupleType = Bytecode.ValueType.tuple([.int64, .string])
        let tuple = VM.Value.tuple([int, .string("seven")])
        let boxedTuple = VM.Value.any(
            .init(
                dynamicType: .tuple([
                    .init(type: .integer(.int)),
                    .init(type: .string),
                ]),
                payload: tuple
            )
        )
        let tupleErasure = try compileFixture(
            source: source,
            functionName: "boxTuple",
            signature: .init(
                parameters: ["Swift.Int", "Swift.String"],
                result: "Swift.Any"
            ),
            parameterTypes: [.int64, .string],
            resultType: .any,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: tupleErasure.image,
                arguments: [int, .string("seven")]
            ) == .returned(boxedTuple)
        )
        let tupleCast = try compileFixture(
            source: source,
            functionName: "checkedTuple",
            signature: .init(
                parameters: ["Swift.Any"],
                result: "Swift.Optional<(Swift.Int, Swift.String)>"
            ),
            parameterTypes: [.any],
            resultType: .optional(tupleType),
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: tupleCast.image,
                arguments: [boxedTuple]
            ) == .returned(.optional(tuple))
        )

        let payloadErasure = try compileFixture(
            source: source,
            functionName: "boxPayload",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Any"),
            parameterTypes: [.int64],
            resultType: .any,
            additionalFrontendArguments: arguments
        )
        let payloadExecution = VM.Interpreter().invoke(
            entry: .init(rawValue: 0),
            image: payloadErasure.image,
            arguments: [int]
        )
        guard case let .returned(boxedPayload?) = payloadExecution else {
            Issue.record("local nominal Any erasure did not return a value")
            return
        }
        let payloadCast = try compileFixture(
            source: source,
            functionName: "payloadValue",
            signature: .init(
                parameters: ["Swift.Any"],
                result: "Swift.Optional<Swift.Int>"
            ),
            parameterTypes: [.any],
            resultType: .optional(.int64),
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: payloadCast.image,
                arguments: [boxedPayload]
            ) == .returned(.optional(int))
        )

        let envelopeValue = try compileFixture(
            source: source,
            functionName: "envelopeValue",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            parameterTypes: [.int64],
            resultType: .int64,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: envelopeValue.image,
                arguments: [int]
            ) == .returned(int)
        )
        let envelopeErasure = try compileFixture(
            source: source,
            functionName: "boxEnvelope",
            signature: .init(parameters: ["Swift.Int"], result: "Swift.Any"),
            parameterTypes: [.int64],
            resultType: .any,
            additionalFrontendArguments: arguments
        )
        let envelopeExecution = VM.Interpreter().invoke(
            entry: .init(rawValue: 0),
            image: envelopeErasure.image,
            arguments: [int]
        )
        guard case let .returned(boxedEnvelope?) = envelopeExecution else {
            Issue.record("Any-bearing local nominal did not erase to Any")
            return
        }
        let envelopePayload = try compileFixture(
            source: source,
            functionName: "envelopePayload",
            signature: .init(
                parameters: ["Swift.Any"],
                result: "Swift.Optional<Swift.Int>"
            ),
            parameterTypes: [.any],
            resultType: .optional(.int64),
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: envelopePayload.image,
                arguments: [boxedEnvelope]
            ) == .returned(.optional(int))
        )

        let anyArrayType = Bytecode.ValueType.array(.any)
        let arrayLiteral = try compileFixture(
            source: source,
            functionName: "makeAnyArray",
            signature: .init(
                parameters: ["Swift.Int", "Swift.String"],
                result: "Swift.Array<Swift.Any>"
            ),
            parameterTypes: [.int64, .string],
            resultType: anyArrayType,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: arrayLiteral.image,
                arguments: [int, .string("seven")]
            ) == .returned(
                .array([boxedInt, boxedString], elementType: .any)
            )
        )

        let anyDictionaryType = Bytecode.ValueType.dictionary(
            key: .string,
            value: .any
        )
        let dictionaryLiteral = try compileFixture(
            source: source,
            functionName: "makeAnyDictionary",
            signature: .init(
                parameters: ["Swift.Int", "Swift.String"],
                result: "Swift.Dictionary<Swift.String, Swift.Any>"
            ),
            parameterTypes: [.int64, .string],
            resultType: anyDictionaryType,
            additionalFrontendArguments: arguments
        )
        let anyDictionary = VM.Value.dictionary(
            [
                .init(key: .string("integer"), value: boxedInt),
                .init(key: .string("string"), value: boxedString),
            ],
            keyType: .string,
            valueType: .any
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: dictionaryLiteral.image,
                arguments: [int, .string("seven")]
            ) == .returned(anyDictionary)
        )

        let dictionaryValue = try compileFixture(
            source: source,
            functionName: "dictionaryValue",
            signature: .init(
                parameters: [
                    "Swift.Dictionary<Swift.String, Swift.Any>",
                    "Swift.String",
                ],
                result: "Swift.Optional<Swift.Int>"
            ),
            parameterTypes: [anyDictionaryType, .string],
            resultType: .optional(.int64),
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: dictionaryValue.image,
                arguments: [anyDictionary, .string("integer")]
            ) == .returned(.optional(int))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: dictionaryValue.image,
                arguments: [anyDictionary, .string("string")]
            ) == .returned(.optional(nil))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: dictionaryValue.image,
                arguments: [anyDictionary, .string("missing")]
            ) == .returned(.optional(nil))
        )
    }

    @Test("Unsupported Any payloads fail with a focused type diagnostic")
    func rejectsClosureErasedToAny() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-any-rejection-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            @inline(never)
            public func boxClosure(
                _ transform: @escaping (Int) -> Int
            ) -> Any {
                transform
            }
            """.utf8
        ).write(to: sourceURL)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "HelixAnyRejectionFixture",
            additionalArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
        )
        let file = try CanonicalSIL.File(text: sil)
        let function = try file.uniqueFunction(
            mangledNameContaining: "boxClosure"
        )

        do {
            _ = try CanonicalSIL.Lowerer(
                typeEnvironment: file.typeEnvironment
            ).lower(function, displayName: "boxClosure")
            Issue.record("closure erased to Any unexpectedly lowered")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unsupportedType(detail) = error else {
                Issue.record("unexpected Any rejection: \(error)")
                return
            }
            #expect(detail.contains("VM-owned Any"))
            #expect(detail.contains("closure"))
        }
    }

    @Test("Same-image functions pass and return Any through Swift's indirect ABI")
    func lowersAnyAcrossDirectCalls() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-any-call-sil-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            @inline(never)
            func makeAny(_ value: Int) -> Any { value }

            @inline(never)
            func echoAny(_ value: Any) -> Any { value }

            enum CallFailure: Error { case rejected }

            @inline(never)
            func maybeAny(_ value: Int) throws -> Any {
                if value < 0 { throw CallFailure.rejected }
                return value
            }

            @inline(never)
            func optionalErased(_ value: Int) -> Any? {
                value == 0 ? nil : value
            }

            @inline(never)
            public func callAny(_ value: Int) -> Int {
                let first: Any = makeAny(value)
                let second: Any = echoAny(first)
                guard let optional = optionalErased(value) else { return -2 }
                do {
                    let third: Any = try maybeAny(value)
                    return (second as! Int)
                        + (third as! Int)
                        + (optional as! Int)
                } catch {
                    return -1
                }
            }
            """.utf8
        ).write(to: sourceURL)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "HelixAnyCallFixture",
            optimization: "-Onone",
            additionalArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
        )
        let file = try CanonicalSIL.File(text: sil)
        let root = try file.uniqueFunction(mangledNameContaining: "callB0")
        let makeAny = try file.uniqueFunction(mangledNameContaining: "makeB0")
        let echoAny = try file.uniqueFunction(mangledNameContaining: "echoB0")
        let maybeAny = try file.uniqueFunction(mangledNameContaining: "maybeB0")
        let optionalErased = try file.uniqueFunction(
            mangledNameContaining: "optionalErased"
        )
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: makeAny.mangledName,
                parameterTypes: [.int64],
                resultType: .any,
                target: .function(.init(rawValue: 1))
            ),
            .init(
                mangledName: echoAny.mangledName,
                parameterTypes: [.any],
                parameterConventions: [.borrowed],
                resultType: .any,
                target: .function(.init(rawValue: 2))
            ),
            .init(
                mangledName: maybeAny.mangledName,
                parameterTypes: [.int64],
                resultType: .any,
                effects: .init(mayThrow: true),
                target: .function(.init(rawValue: 3))
            ),
            .init(
                mangledName: optionalErased.mangledName,
                parameterTypes: [.int64],
                resultType: .optional(.any),
                target: .function(.init(rawValue: 4))
            ),
        ])
        let lowerer = CanonicalSIL.Lowerer(typeEnvironment: file.typeEnvironment)
        let lowered = [
            try lowerer.lower(
                root,
                displayName: "callAny",
                directCalls: directCalls
            ),
            try lowerer.lower(
                makeAny,
                displayName: "makeAny",
                directCalls: directCalls
            ),
            try lowerer.lower(
                echoAny,
                displayName: "echoAny",
                directCalls: directCalls
            ),
            try lowerer.lower(
                maybeAny,
                displayName: "maybeAny",
                directCalls: directCalls
            ),
            try lowerer.lower(
                optionalErased,
                displayName: "optionalErased",
                directCalls: directCalls
            ),
        ]
        let shellHash = Core.Digest.sha256("helix-any-call-sil-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-any-call-sil-fixture"
        )
        let functionKey = try Core.FunctionKey.derive(
            namespace: .derive(
                bundleID: "dev.helix.any-call",
                buildNumber: "1",
                seed: "fixture"
            ),
            module: "HelixAnyCallFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func callAny(_: Int) -> Int",
            loweredSignature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int"
            ),
            role: .function
        )
        let capabilities = CompilerCapabilities.infer(for: lowered)
        let module = Bytecode.Module(
            name: "HelixAnyCallFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            functions: lowered.enumerated().map { index, function in
                IntermediateRepresentation.ToBytecode.lower(
                    function,
                    id: .init(rawValue: UInt32(index))
                )
            },
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: functionKey,
                    functionID: .init(rawValue: 0)
                ),
            ]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: functionKey,
                    parameterTypes: [.int64],
                    parameterConventions: module.functions[0]
                        .parameterConventions,
                    resultType: .int64
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(acceptedCapabilities: capabilities)
        )
        let input = VM.Value.integer(
            try VM.Integer(signed: 42, bitWidth: 64, isSigned: true)
        )
        let tripled = VM.Value.integer(
            try VM.Integer(signed: 126, bitWidth: 64, isSigned: true)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [input]
            ) == .returned(tripled)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [
                    .integer(
                        try VM.Integer(signed: -2, bitWidth: 64, isSigned: true)
                    ),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: -1, bitWidth: 64, isSigned: true))
            )
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 0, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: -2, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Escaping synchronous closures return Any through Swift's indirect ABI")
    func lowersAnyReturnedFromEscapingClosure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-any-closure-sil-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            @inline(never)
            public func invokeAny(_ body: @escaping () -> Any) -> Any {
                body()
            }
            """.utf8
        ).write(to: sourceURL)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "HelixAnyClosureFixture",
            additionalArguments: [
                "-Xfrontend",
                "-disable-sil-perf-optzns",
            ]
        )
        let file = try CanonicalSIL.File(text: sil)
        let function = try file.uniqueFunction(mangledNameContaining: "invokeB0")
        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: file.typeEnvironment
        ).lower(function, displayName: "invokeAny")

        let instructions = lowered.blocks.flatMap(\.instructions)
        let results = instructions.compactMap { instruction -> Bytecode.Register? in
            guard case let .closureApply(result, _, _) = instruction else {
                return nil
            }
            return result
        }
        #expect(lowered.resultType == .any)
        #expect(results.count == 1)
        if let result = results.first {
            #expect(lowered.registerTypes[Int(result.rawValue)] == .any)
        }
        #expect(instructions.contains { instruction in
            if case .storeStack = instruction { return true }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .loadStack = instruction { return true }
            return false
        })
    }

    @Test("Dictionary literals, lookup, mutation, properties, and iteration preserve value semantics")
    func compilesCommonDictionarySyntax() throws {
        let source = """
        @inline(never)
        public func dictionaryLookup(_ values: [String: Int], _ key: String) -> Int? {
            values[key]
        }

        @inline(never)
        public func dictionaryLiteral(_ value: Int) -> [String: Int] {
            ["value": value, "fixed": 3]
        }

        @inline(never)
        public func dictionaryProperties(_ values: [String: Int]) -> Int {
            values.isEmpty ? 0 : values.count
        }

        @inline(never)
        public func dictionarySet(
            _ values: [String: Int],
            _ key: String,
            _ value: Int
        ) -> [String: Int] {
            var result = values
            result[key] = value
            return result
        }

        @inline(never)
        public func dictionaryRemove(
            _ values: [String: Int],
            _ key: String
        ) -> [String: Int] {
            var result = values
            result[key] = nil
            return result
        }

        @inline(never)
        public func dictionaryLoop(_ values: [String: Int]) -> Int {
            var total = 0
            for (key, value) in values {
                total += key.count + value
            }
            return total
        }
        """
        let arguments = ["-Xfrontend", "-disable-sil-perf-optzns"]
        let dictionaryType = Bytecode.ValueType.dictionary(key: .string, value: .int64)
        let two = VM.Value.integer(
            try VM.Integer(signed: 2, bitWidth: 64, isSigned: true)
        )
        let five = VM.Value.integer(
            try VM.Integer(signed: 5, bitWidth: 64, isSigned: true)
        )
        let nine = VM.Value.integer(
            try VM.Integer(signed: 9, bitWidth: 64, isSigned: true)
        )
        let dictionary = VM.Value.dictionary(
            [
                .init(key: .string("a"), value: two),
                .init(key: .string("beta"), value: five),
            ],
            keyType: .string,
            valueType: .int64
        )
        let dictionarySignature = "Swift.Dictionary<Swift.String, Swift.Int>"

        let lookup = try compileFixture(
            source: source,
            functionName: "dictionaryLookup",
            signature: .init(
                parameters: [dictionarySignature, "Swift.String"],
                result: "Swift.Optional<Swift.Int>"
            ),
            parameterTypes: [dictionaryType, .string],
            resultType: .optional(.int64),
            additionalFrontendArguments: arguments
        )
        #expect(lookup.compiled.disassembly.contains("dictionary_get"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: lookup.image,
                arguments: [dictionary, .string("beta")]
            ) == .returned(.optional(five))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: lookup.image,
                arguments: [dictionary, .string("missing")]
            ) == .returned(.optional(nil))
        )

        let literal = try compileFixture(
            source: source,
            functionName: "dictionaryLiteral",
            signature: .init(parameters: ["Swift.Int"], result: dictionarySignature),
            parameterTypes: [.int64],
            resultType: dictionaryType,
            additionalFrontendArguments: arguments
        )
        #expect(literal.compiled.disassembly.contains("make_dictionary"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: literal.image,
                arguments: [nine]
            ) == .returned(
                .dictionary(
                    [
                        .init(key: .string("value"), value: nine),
                        .init(
                            key: .string("fixed"),
                            value: .integer(
                                try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)
                            )
                        ),
                    ],
                    keyType: .string,
                    valueType: .int64
                )
            )
        )

        let properties = try compileFixture(
            source: source,
            functionName: "dictionaryProperties",
            signature: .init(parameters: [dictionarySignature], result: "Swift.Int"),
            parameterTypes: [dictionaryType],
            resultType: .int64,
            additionalFrontendArguments: arguments
        )
        #expect(properties.compiled.disassembly.contains("dictionary_is_empty"))
        #expect(properties.compiled.disassembly.contains("dictionary_count"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: properties.image,
                arguments: [dictionary]
            ) == .returned(
                .integer(try VM.Integer(signed: 2, bitWidth: 64, isSigned: true))
            )
        )

        let set = try compileFixture(
            source: source,
            functionName: "dictionarySet",
            signature: .init(
                parameters: [dictionarySignature, "Swift.String", "Swift.Int"],
                result: dictionarySignature
            ),
            parameterTypes: [dictionaryType, .string, .int64],
            resultType: dictionaryType,
            additionalFrontendArguments: arguments
        )
        #expect(set.compiled.disassembly.contains("dictionary_set"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: set.image,
                arguments: [dictionary, .string("a"), nine]
            ) == .returned(
                .dictionary(
                    [
                        .init(key: .string("a"), value: nine),
                        .init(key: .string("beta"), value: five),
                    ],
                    keyType: .string,
                    valueType: .int64
                )
            )
        )

        let remove = try compileFixture(
            source: source,
            functionName: "dictionaryRemove",
            signature: .init(
                parameters: [dictionarySignature, "Swift.String"],
                result: dictionarySignature
            ),
            parameterTypes: [dictionaryType, .string],
            resultType: dictionaryType,
            additionalFrontendArguments: arguments
        )
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: remove.image,
                arguments: [dictionary, .string("a")]
            ) == .returned(
                .dictionary(
                    [.init(key: .string("beta"), value: five)],
                    keyType: .string,
                    valueType: .int64
                )
            )
        )

        let loop = try compileFixture(
            source: source,
            functionName: "dictionaryLoop",
            signature: .init(parameters: [dictionarySignature], result: "Swift.Int"),
            parameterTypes: [dictionaryType],
            resultType: .int64,
            additionalFrontendArguments: arguments
        )
        #expect(loop.compiled.disassembly.contains("collection_next_forward"))
        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: loop.image,
                arguments: [dictionary]
            ) == .returned(
                .integer(try VM.Integer(signed: 12, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("User-defined Hashable semantics remain a stable compile-time rejection")
    func rejectsUnsupportedCollectionSurfaces() throws {
        let setSource = """
        public struct Key: Hashable { public var raw: Int }
        @inline(never)
        public func setCount(_ raw: Int) -> Int { Set([Key(raw: raw)]).count }
        """
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try compileFixture(
                source: setSource,
                functionName: "setCount",
                signature: .init(
                    parameters: ["Swift.Int"],
                    result: "Swift.Int"
                ),
                parameterTypes: [.int64],
                resultType: .int64,
                additionalFrontendArguments: ["-Xfrontend", "-disable-sil-perf-optzns"]
            )
        }
    }

    @Test("Real Swift nonescaping closures lower and execute as HLBC values")
    func lowersRealNonescapingClosureSIL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-closure-sil-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            @inline(never)
            func applyTwice(_ value: Int, _ transform: (Int) -> Int) -> Int {
                transform(transform(value))
            }

            @inline(never)
            public func closureRoot(_ value: Int) -> Int {
                let offset = 3
                let transform = { (input: Int) in input + offset }
                return applyTwice(value, transform)
            }
            """.utf8
        ).write(to: sourceURL)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "HelixClosureFixture",
            optimization: "-Onone"
        )
        let file = try CanonicalSIL.File(text: sil)
        let root = try #require(file.functions.first {
            $0.mangledName.contains("closureRooty") && !$0.mangledName.contains("cfU_")
        })
        let applyTwice = try file.uniqueFunction(mangledNameContaining: "applyTwice")
        let closureBody = try file.uniqueFunction(mangledNameContaining: "cfU_")
        let signature = Bytecode.ClosureSignature(
            parameters: [.int64],
            parameterConventions: [.owned],
            result: .int64
        )
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: applyTwice.mangledName,
                parameterTypes: [.int64, .closure(signature)],
                resultType: .int64,
                target: .function(.init(rawValue: 1))
            ),
            .init(
                mangledName: closureBody.mangledName,
                parameterTypes: [.int64, .int64],
                resultType: .int64,
                target: .function(.init(rawValue: 2))
            ),
        ])
        let lowerer = CanonicalSIL.Lowerer(typeEnvironment: file.typeEnvironment)
        let loweredRoot = try lowerer.lower(
            root,
            displayName: "closureRoot",
            directCalls: directCalls
        )
        let loweredApplyTwice = try lowerer.lower(
            applyTwice,
            displayName: "applyTwice",
            directCalls: directCalls
        )
        let loweredClosureBody = try lowerer.lower(
            closureBody,
            displayName: "closure body",
            kind: .closureBody,
            directCalls: directCalls
        )
        let loweredFunctions = [
            loweredRoot,
            loweredApplyTwice,
            loweredClosureBody,
        ]
        #expect(loweredRoot.blocks.flatMap(\.instructions).contains { instruction in
            if case .makeClosure = instruction { return true }
            return false
        })
        #expect(loweredApplyTwice.blocks.flatMap(\.instructions).filter { instruction in
            if case .closureApply = instruction { return true }
            return false
        }.count == 2)
        #expect(loweredClosureBody.kind == .closureBody)

        let shellHash = Core.Digest.sha256("helix-closure-sil-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-closure-sil-fixture"
        )
        let functionKey = try Core.FunctionKey.derive(
            namespace: .derive(
                bundleID: "dev.helix.closure",
                buildNumber: "1",
                seed: "fixture"
            ),
            module: "HelixClosureFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func closureRoot(_: Int) -> Int",
            loweredSignature: .init(parameters: ["Swift.Int"], result: "Swift.Int"),
            role: .function
        )
        let capabilities = CompilerCapabilities.infer(for: loweredFunctions)
        let module = Bytecode.Module(
            name: "HelixClosureFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            functions: [
                IntermediateRepresentation.ToBytecode.lower(
                    loweredRoot,
                    id: .init(rawValue: 0)
                ),
                IntermediateRepresentation.ToBytecode.lower(
                    loweredApplyTwice,
                    id: .init(rawValue: 1)
                ),
                IntermediateRepresentation.ToBytecode.lower(
                    loweredClosureBody,
                    id: .init(rawValue: 2)
                ),
            ],
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: functionKey,
                    functionID: .init(rawValue: 0)
                ),
            ]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: .init(rawValue: 0),
                    key: functionKey,
                    parameterTypes: [.int64],
                    parameterConventions: module.functions[0]
                        .parameterConventions,
                    resultType: .int64
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: shell,
            policy: .init(acceptedCapabilities: capabilities)
        )

        #expect(
            VM.Interpreter().invoke(
                entry: .init(rawValue: 0),
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 10, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Unoptimized frontend SIL lowers inout reborrows and mutating self")
    func lowersRealInoutAndMutatingSIL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-inout-sil-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            public struct Counter {
                public var value: Int

                @inline(never)
                public mutating func bump(by amount: Int) {
                    value += amount
                }
            }

            @inline(never)
            public func increment(_ value: inout Int, by amount: Int) {
                value += amount
            }

            @inline(never)
            public func updateField(_ counter: inout Counter, by amount: Int) {
                increment(&counter.value, by: amount)
            }
            """.utf8
        ).write(to: sourceURL)
        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "HelixInoutFixture",
            optimization: "-Onone"
        )
        let file = try CanonicalSIL.File(text: sil)
        let increment = try file.uniqueFunction(mangledNameContaining: "increment")
        let update = try file.uniqueFunction(mangledNameContaining: "updateField")
        let bump = try file.uniqueFunction(mangledNameContaining: "bump2by")
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: increment.mangledName,
                parameterTypes: [.address(.int64), .int64],
                parameterConventions: [.inout, .owned],
                resultType: .void,
                target: .function(.init(rawValue: 1))
            ),
        ])
        let lowerer = CanonicalSIL.Lowerer(typeEnvironment: file.typeEnvironment)
        let loweredUpdate = try lowerer.lower(
            update,
            displayName: "updateField",
            directCalls: directCalls
        )
        let loweredIncrement = try lowerer.lower(
            increment,
            displayName: "increment",
            directCalls: directCalls
        )
        let loweredBump = try lowerer.lower(
            bump,
            displayName: "Counter.bump",
            directCalls: directCalls
        )
        let updateInstructions = loweredUpdate.blocks.flatMap(\.instructions)
        let bumpInstructions = loweredBump.blocks.flatMap(\.instructions)

        #expect(loweredUpdate.parameterConventions == [.inout, .owned])
        #expect(loweredIncrement.parameterConventions == [.inout, .owned])
        #expect(loweredBump.parameterConventions == [.owned, .inout])
        #expect(updateInstructions.contains { instruction in
            if case .projectAggregateAddress = instruction { return true }
            return false
        })
        #expect(updateInstructions.contains { instruction in
            if case .apply = instruction { return true }
            return false
        })
        #expect(!updateInstructions.contains { instruction in
            if case .beginAccess = instruction { return true }
            return false
        })
        #expect(bumpInstructions.contains { instruction in
            if case .loadAddress = instruction { return true }
            return false
        })
        #expect(bumpInstructions.contains { instruction in
            if case .storeAddress = instruction { return true }
            return false
        })

        let functions = [
            IntermediateRepresentation.ToBytecode.lower(
                loweredUpdate,
                id: .init(rawValue: 0)
            ),
            IntermediateRepresentation.ToBytecode.lower(
                loweredIncrement,
                id: .init(rawValue: 1)
            ),
            IntermediateRepresentation.ToBytecode.lower(
                loweredBump,
                id: .init(rawValue: 2)
            ),
        ]
        let loweredFunctions = [loweredUpdate, loweredIncrement, loweredBump]
        let localTypes = try file.typeEnvironment.definitions(
            referencedBy: loweredFunctions
        )
        let capabilities = CompilerCapabilities.infer(
            for: loweredFunctions,
            imports: [],
            localTypes: localTypes
        )
        let shellHash = Core.Digest.sha256("helix-inout-sil-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-inout-sil-fixture"
        )
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.inout-sil",
            buildNumber: "1",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "HelixInoutFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func fixtureEntry(_: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let entryFunction = Bytecode.Function(
            id: .init(rawValue: 3),
            name: "fixtureEntry",
            parameterRegisters: [.init(rawValue: 0)],
            resultType: .int64,
            registerTypes: [.int64],
            entryBlock: .init(rawValue: 0),
            blocks: [
                .init(
                    id: .init(rawValue: 0),
                    parameters: [.init(rawValue: 0)],
                    instructions: [.returnValue(.init(rawValue: 0))]
                ),
            ]
        )
        let module = Bytecode.Module(
            name: "InoutSILFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            localTypes: localTypes,
            functions: functions + [entryFunction],
            entries: [
                .init(
                    entryIndex: .init(rawValue: 0),
                    functionKey: key,
                    functionID: entryFunction.id
                ),
            ]
        )
        _ = try Verification.Engine().verify(
            bytes: Bytecode.Encoder.encode(module),
            shell: Verification.ShellInterface(
                interfaceHash: shellHash,
                compatibility: compatibility,
                capabilities: capabilities,
                entries: [
                    .init(
                        index: .init(rawValue: 0),
                        key: key,
                        parameterTypes: [.int64],
                        parameterConventions: entryFunction
                            .parameterConventions,
                        resultType: .int64
                    ),
                ]
            ),
            policy: .init(acceptedCapabilities: capabilities)
        )
    }

    private struct CompiledFixture {
        var compiled: PatchCompiler.Result
        var image: Verification.Image
    }

    private func compileFixture(
        source: String,
        functionName: String,
        signature: Core.LoweredSignature,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        effects: Core.Effects = .init(),
        purpose: SwiftFrontend.CanonicalSILPurpose = .implementationIdentity,
        optimization: String = "-O",
        additionalFrontendArguments: [String] = []
    ) throws -> CompiledFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-language-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data((source + "\n").utf8).write(to: sourceURL)
        let canonicalSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "HelixLanguageFixture",
            optimization: optimization,
            additionalArguments: additionalFrontendArguments,
            purpose: purpose
        )
        let function = try CanonicalSIL.File(text: canonicalSIL)
            .uniqueFunction(mangledNameContaining: functionName)
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.language",
            buildNumber: "1",
            seed: "fixture"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "HelixLanguageFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func \(functionName)",
            loweredSignature: signature,
            role: .function
        )
        let shellHash = Core.Digest.sha256("helix-language-shell-\(functionName)")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-language-fixture"
        )
        let entry = Core.EntryIndex(rawValue: 0)
        let compiled = try PatchCompiler.Driver().compile(
            .init(
                canonicalSIL: canonicalSIL,
                mangledName: function.mangledName,
                displayName: functionName,
                functionKey: key,
                entryIndex: entry,
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                effects: effects
            )
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: compiled.module.capabilities,
            entries: [
                .init(
                    index: entry,
                    key: key,
                    parameterTypes: parameterTypes,
                    parameterConventions: compiled.module.functions[0]
                        .parameterConventions,
                    resultType: resultType,
                    effects: effects
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: compiled.bytecode,
            shell: shell,
            policy: .init(
                acceptedCapabilities: compiled.module.capabilities,
                allowMainActorSynchronousEntries: effects.requiresMainActor
            )
        )
        return .init(compiled: compiled, image: image)
    }
}
}
