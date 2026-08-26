import Foundation
import HelixBytecode
import HelixCore
import HelixInterface
import HelixVerifier
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Static KeyPath lowering")
struct StaticKeyPath {
    @Test("Static property paths become typed zero-capture functions")
    func erasesKeyPathRuntimeRepresentation() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func projectedCount(_ value: String) -> Int {
                [value].map(\\.count)[0]
            }
            """,
            functionName: "projectedCount"
        )
        let root = try #require(fixture.image.function(entry: fixture.entry))
        let closures = root.blocks.flatMap(\.instructions).compactMap {
            instruction -> [Bytecode.Register]? in
            guard case let .makeClosure(_, _, captures, _) = instruction else {
                return nil
            }
            return captures
        }
        #expect(!closures.isEmpty)
        #expect(closures.allSatisfy { $0.isEmpty })
        #expect(fixture.image.module.functions.contains { function in
            function.kind == .closureBody
                && function.blocks.flatMap(\.instructions).contains { instruction in
                    if case .stringCount = instruction { return true }
                    return false
                }
        })
    }

    @Test("Composed local paths lower to declaration-checked field projections")
    func lowersComposedStoredPath() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Leaf { let value: Int }
            private struct Container { let leaf: Leaf }
            public func composedProjection(_ value: Int) -> Int {
                [Container(leaf: Leaf(value: value))].map(\\.leaf.value)[0]
            }
            """,
            functionName: "composedProjection"
        )
        let projection = try #require(
            fixture.image.module.functions.first { function in
                function.kind == .closureBody
            }
        )
        let extracts = projection.blocks.flatMap(\.instructions).filter {
            if case .structExtract = $0 { return true }
            return false
        }
        #expect(extracts.count == 2)
        #expect(projection.blocks.flatMap(\.instructions).allSatisfy {
            if case let .makeClosure(_, _, captures, _) = $0 {
                return captures.isEmpty
            }
            return true
        })
    }

    @Test("Distinct static paths may share one concrete Root and Value type")
    func distinguishesPathsWithMatchingEndpoints() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Pair {
                let left: Int
                let right: Int
            }
            public func sumDistinctPaths(_ left: Int, _ right: Int) -> Int {
                let values = [Pair(left: left, right: right)]
                return values.map(\\.left)[0] + values.map(\\.right)[0]
            }
            """,
            functionName: "sumDistinctPaths"
        )
        let result = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [try integer(5), try integer(8)]
        )
        #expect(result == .returned(try integer(13)))
        let projections = fixture.image.module.functions.filter {
            $0.kind == .closureBody
        }
        #expect(projections.count == 2)
        #expect(projections.allSatisfy { function in
            function.blocks.flatMap(\.instructions).contains {
                if case .structExtract = $0 { return true }
                return false
            }
        })
    }

    @Test("Stored projections preserve nontrivial field ownership")
    func projectsOwnedStoredField() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Person { let name: String }
            public func projectedName(_ value: String) -> String {
                [Person(name: value)].map(\\.name)[0]
            }
            """,
            functionName: "projectedName"
        )
        let result = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [.string("Helix")]
        )
        #expect(result == .returned(.string("Helix")))
    }

    @Test("Composed stored projections preserve nontrivial intermediate values")
    func projectsThroughOwnedStoredAggregate() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Name { let text: String }
            private struct Person { let name: Name }
            public func projectedNestedName(_ value: String) -> String {
                [Person(name: Name(text: value))].map(\\.name.text)[0]
            }
            """,
            functionName: "projectedNestedName"
        )
        let result = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [.string("Helix")]
        )
        #expect(result == .returned(.string("Helix")))
    }

    @Test("Optional KeyPath chains lower to explicit typed control flow")
    func lowersOptionalChainComponents() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Leaf {
                let value: Int
                let optionalValue: Int?
            }
            private struct Middle { let leaf: Leaf? }
            private struct Box { let middle: Middle? }
            public func optionalPaths(_ value: Int, _ present: Bool) -> Int {
                let leaf = Leaf(value: value, optionalValue: value + 1)
                let box = Box(
                    middle: present ? Middle(leaf: leaf) : nil
                )
                let values = [box]
                let wrapped = values.map(\\.middle?.leaf?.value)[0] ?? -1
                let flattened = values.map(
                    \\.middle?.leaf?.optionalValue
                )[0] ?? -2
                return wrapped * 100 + flattened
            }
            """,
            functionName: "optionalPaths"
        )
        let interpreter = VM.Interpreter()
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(7), .bool(true)]
            ) == .returned(try integer(708))
        )
        let absentResult = interpreter.invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [try integer(7), .bool(false)]
        )
        let expectedAbsent = VM.ExecutionResult.returned(try integer(-102))
        if absentResult != expectedAbsent {
            Issue.record(
                "optional nil paths: expected \(expectedAbsent), got \(absentResult)"
            )
        }
        let projections = fixture.image.module.functions.filter {
            $0.kind == .closureBody
                && $0.blocks.flatMap(\.instructions).contains {
                    if case .switchOptional = $0 { return true }
                    return false
                }
        }
        #expect(projections.count == 2)
        #expect(projections.allSatisfy { function in
            function.blocks.flatMap(\.instructions).allSatisfy {
                if case let .makeClosure(_, _, captures, _) = $0 {
                    return captures.isEmpty
                }
                return true
            }
        })
    }

    @Test("Optional KeyPath chains preserve owned payloads and flattening")
    func lowersOwnedOptionalChainComponents() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Leaf {
                let name: String
                let nickname: String?
            }
            private struct Box { let leaf: Leaf? }
            public func ownedOptionalPaths(
                _ value: String,
                _ leafPresent: Bool,
                _ nicknamePresent: Bool
            ) -> (String?, String?) {
                let leaf = Leaf(
                    name: value,
                    nickname: nicknamePresent ? value + "!" : nil
                )
                let box = Box(leaf: leafPresent ? leaf : nil)
                let values = [box]
                return (
                    values.map(\\.leaf?.name)[0],
                    values.map(\\.leaf?.nickname)[0]
                )
            }
            """,
            functionName: "ownedOptionalPaths"
        )
        let interpreter = VM.Interpreter()
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.string("Helix"), .bool(true), .bool(true)]
            ) == .returned(.tuple([
                .optional(.string("Helix")),
                .optional(.string("Helix!")),
            ]))
        )
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.string("Helix"), .bool(true), .bool(false)]
            ) == .returned(.tuple([
                .optional(.string("Helix")),
                .optional(nil),
            ]))
        )
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.string("Helix"), .bool(false), .bool(true)]
            ) == .returned(.tuple([
                .optional(nil),
                .optional(nil),
            ]))
        )
    }

    @Test("Optional-force KeyPath components preserve nil trapping")
    func lowersOptionalForceComponent() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Leaf { let value: String }
            private struct Box { let leaf: Leaf? }
            public func forcedPath(_ value: String, _ present: Bool) -> String {
                let box = Box(leaf: present ? Leaf(value: value) : nil)
                return [box].map(\\.leaf!.value)[0]
            }
            """,
            functionName: "forcedPath"
        )
        let interpreter = VM.Interpreter()
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.string("owned"), .bool(true)]
            ) == .returned(.string("owned"))
        )
        #expect(
            interpreter.invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.string("owned"), .bool(false)]
            ) == .trapped(.optionalUnwrapOfNil)
        )
    }

    @Test("Class stored projections preserve imported-reference ownership")
    func projectsNativeClassField() throws {
        let typeID = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let nativeType = InterfaceArchive.TypeRecord(
            id: typeID,
            canonicalName: "Foundation.NSObject",
            kind: .reference,
            layoutFingerprint: .sha256("Foundation.NSObject.layout.v1"),
            isCopyable: true,
            isEmittedToDevice: true,
            estimatedSize: 8
        )
        _ = try FrontendExecutionHarness.compile(
            source: """
            import Foundation
            private final class Holder {
                let object: NSObject
                init(object: NSObject) { self.object = object }
            }
            public func projectedObject(_ object: NSObject) -> NSObject {
                [Holder(object: object)].map(\\.object)[0]
            }
            """,
            functionName: "projectedObject",
            nativeTypes: [nativeType]
        )
    }

    @Test("Static SDK getter paths accept a borrowed native root")
    func validatesNativeRootThunkOwnership() throws {
        let sil = try canonicalSIL(
            source: """
            import Foundation
            public func projectedDescriptions(_ values: [NSObject]) -> [String] {
                values.map(\\.description)
            }
            """,
            moduleName: "HelixNativeKeyPathFixture"
        )
        let file = try CanonicalSIL.File(text: sil)
        let typeID = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let environment = try file.typeEnvironment.includingNativeTypes(
            ["Foundation.NSObject": typeID],
            kinds: [typeID: .reference],
            requiresMainActor: []
        )
        let root = try #require(
            file.functions.first {
                $0.mangledName.contains("projectedDescriptions")
            }
        )
        let rewrites = try CanonicalSIL.StaticKeyPath.rewrites(
            in: root,
            file: file,
            environment: environment
        )
        #expect(rewrites.count == 1)
        #expect(rewrites.values.allSatisfy {
            $0.function.loweredType.contains("@guaranteed NSObject")
                && $0.function.body.contains(
                    "@convention(keypath_accessor_getter)"
                )
                && !$0.function.body.contains("swift_getAtKeyPath")
        })

        let nativeMethodType =
            "@convention(objc_method) (NSObject) "
            + "-> @autoreleased Optional<NSString>"
        let contract = Core.NativeImportContract.bounded(
            kind: .instanceGetter,
            domain: .foundation,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let callDescriptor = try Core.NativeCall.Descriptor(
            target: .init(
                backend: .objectiveCMessage,
                module: "Foundation",
                owner: "NSObject",
                member: "description.getter",
                entryPoint: "description",
                dispatch: .instance,
                receiverArgumentIndex: 0
            ),
            logicalSignature: .init(
                parameters: [.init(type: "Foundation.NSObject")],
                result: .init(type: "Swift.String")
            ),
            physicalSignature: .init(
                callingConvention: .objectiveC,
                parameters: [],
                result: .init(
                    kind: .object,
                    canonicalName: "Foundation.NSString",
                    encoding: "@",
                    isNullable: true
                )
            ),
            effects: .init()
        )
        let requirement = Bytecode.ImportRequirement(
            id: .init(rawValue: 91),
            key: try .derive(descriptor: callDescriptor),
            descriptor: callDescriptor,
            contract: contract
        )
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: CanonicalSIL.NativeBridgeSymbols.foreignCall(
                    reference: "#NSObject.description!getter.foreign",
                    loweredType: nativeMethodType
                ),
                parameterTypes: [.native(typeID)],
                resultType: .string,
                effects: requirement.effects,
                target: .nativeImport(requirement)
            ),
        ])
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.static-keypath",
            buildNumber: "1",
            seed: "native-getter"
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "HelixNativeKeyPathFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration:
                "func projectedDescriptions(_: [NSObject]) -> [String]",
            loweredSignature: .init(
                parameters: ["Swift.Array<Foundation.NSObject>"],
                result: "Swift.Array<Swift.String>"
            ),
            role: .function
        )
        let entry = Core.EntryIndex(rawValue: 0)
        let shellHash = Core.Digest.sha256("native-keypath-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "native-keypath-fixture"
        )
        let compiled = try PatchCompiler.Driver().compile(
            .init(
                canonicalSIL: sil,
                mangledName: root.mangledName,
                displayName: "projectedDescriptions",
                functionKey: key,
                entryIndex: entry,
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                directCalls: directCalls,
                nativeTypes: ["Foundation.NSObject": typeID],
                nativeTypeKinds: [typeID: .reference]
            )
        )
        #expect(compiled.module.imports == [requirement])
        #expect(compiled.module.functions.flatMap(\.blocks)
            .flatMap(\.instructions).contains {
                if case let .nativeApply(_, id, _) = $0 {
                    return id == requirement.id
                }
                return false
            })
        let compiledEntry = try #require(compiled.module.entries.first)
        let compiledRoot = try #require(
            compiled.module.functions.first {
                $0.id == compiledEntry.functionID
            }
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: compiled.module.capabilities,
            entries: [
                .init(
                    index: entry,
                    key: key,
                    parameterTypes: [.array(.native(typeID))],
                    parameterConventions: compiledRoot.parameterConventions,
                    resultType: .array(.string),
                    effects: .init()
                ),
            ],
            imports: [
                .init(
                    id: requirement.id,
                    key: requirement.key,
                    descriptor: requirement.descriptor,
                    parameterTypes: [.native(typeID)],
                    resultType: .string,
                    contract: requirement.contract
                ),
            ],
            types: [
                .init(
                    id: typeID,
                    canonicalName: "Foundation.NSObject",
                    kind: .reference,
                    layoutFingerprint: .sha256(
                        "Foundation.NSObject.layout.v1"
                    ),
                    isCopyable: true,
                    estimatedSize: 8
                ),
            ]
        )
        _ = try Verification.Engine().verify(
            bytes: compiled.bytecode,
            shell: shell,
            policy: .init(
                acceptedCapabilities: compiled.module.capabilities,
                allowedNativeCalls: [requirement.key]
            )
        )
    }

    @Test("A Swift-typed Objective-C result bridge requires frozen provenance")
    func rejectsForgedObjectiveCStringBridge() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture12forgedBridgeyS2SF",
            loweredType: "@convention(thin) (@guaranteed String) -> @owned String",
            body: """
            bb0(%0 : $String):
              %1 = function_ref @$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ : $@convention(method) (@guaranteed Optional<NSString>, @thin String.Type) -> @owned String
              %2 = metatype $@thin String.Type
              %3 = apply %1(%0, %2) : $@convention(method) (@guaranteed Optional<NSString>, @thin String.Type) -> @owned String
              return %3
            """
        )
        do {
            _ = try CanonicalSIL.Lowerer(
                typeEnvironment: .empty
            ).lower(
                function,
                displayName: "Fixture.forgedBridge"
            )
            Issue.record("an unfrozen Objective-C bridge was trusted")
        } catch {
            #expect(
                String(describing: error).contains(
                    "not proven by its captured boundary"
                )
            )
        }
    }

    @Test("Dynamic KeyPath values remain outside the HLBC type system")
    func rejectsDynamicKeyPathParameter() throws {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                public func dynamicProjection(
                    _ value: String,
                    _ path: KeyPath<String, Int>
                ) -> Int {
                    value[keyPath: path]
                }
                """,
                functionName: "dynamicProjection"
            )
            Issue.record("dynamic KeyPath unexpectedly entered HLBC")
        } catch {
            #expect(String(describing: error).contains("KeyPath"))
        }
    }

    @Test("Captured KeyPath components remain explicit and fail closed")
    func rejectsCapturedSubscriptComponent() throws {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                private struct Box { let values: [Int] }
                public func capturedPath(_ value: Int, _ index: Int) -> Int {
                    [Box(values: [value, value + 1])].map(
                        \\.values[index]
                    )[0]
                }
                """,
                functionName: "capturedPath"
            )
            Issue.record("a captured KeyPath index entered HLBC without a capture ABI")
        } catch {
            #expect(
                String(describing: error).contains(
                    "static KeyPath components with captured values"
                )
            )
        }
    }

    @Test("Optional KeyPath descriptors validate each unwrap type")
    func rejectsMalformedOptionalComponent() throws {
        let sil = try canonicalSIL(
            source: """
            struct Leaf { let value: Int }
            struct Box { let leaf: Leaf? }
            func optionalPath(_ values: [Box]) -> [Int?] {
                values.map(\\.leaf?.value)
            }
            """,
            moduleName: "HelixMalformedOptionalKeyPathFixture"
        )
        let modified = sil.replacingOccurrences(
            of: "optional_chain : $Leaf",
            with: "optional_chain : $Int"
        )
        #expect(modified != sil)
        let file = try CanonicalSIL.File(text: modified)
        let root = try #require(
            file.functions.first { $0.body.contains("optional_chain : $Int") }
        )
        do {
            _ = try CanonicalSIL.ImageFunctions.discover(
                in: file,
                startingAt: [root.mangledName],
                excluding: [],
                environment: file.typeEnvironment,
                kindForSymbol: { _ in .ordinary }
            )
            Issue.record("a malformed Optional KeyPath descriptor was trusted")
        } catch {
            #expect(
                String(describing: error).contains(
                    "does not unwrap its input"
                )
            )
        }
    }

    @Test("Static projection adapter binds one exact path identity")
    func rejectsMismatchedStaticCapture() throws {
        let sil = try canonicalSIL(
            source: """
            private struct Pair {
                let left: Int
                let right: Int
            }
            public func selectLeft(_ left: Int, _ right: Int) -> Int {
                [Pair(left: left, right: right)].map(\\.left)[0]
            }
            """,
            moduleName: "HelixKeyPathIdentityFixture"
        )
        let file = try CanonicalSIL.File(text: sil)
        let root = try #require(
            file.functions.first { $0.mangledName.contains("selectLeft") }
        )
        let thunk = try #require(
            file.functions.first { $0.mangledName.contains("cfu_") }
        )
        let literalLine = try #require(
            root.body.split(separator: "\n").map(String.init).first {
                $0.contains(" = keypath $")
            }
        )
        let normalized = CanonicalSIL.DebugMetadata.strippingComment(
            from: literalLine
        ).trimmingCharacters(in: .whitespaces)
        let left = try #require(
            CanonicalSIL.StaticKeyPath.capture(
                in: normalized,
                environment: file.typeEnvironment
            )?.value
        )
        let right = try #require(
            CanonicalSIL.StaticKeyPath.capture(
                in: normalized.replacingOccurrences(
                    of: ".left :",
                    with: ".right :"
                ),
                environment: file.typeEnvironment
            )?.value
        )
        #expect(left.identity != right.identity)
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: thunk.mangledName,
                parameterTypes: [left.rootType],
                parameterConventions: [.owned],
                resultType: left.valueType,
                target: .function(.init(rawValue: 1)),
                abiAdapter: .staticKeyPathProjection(identity: right.identity)
            ),
        ])
        do {
            _ = try CanonicalSIL.Lowerer(
                typeEnvironment: file.typeEnvironment
            ).lower(
                root,
                displayName: "selectLeft",
                directCalls: calls
            )
            Issue.record("a different static path satisfied the adapter")
        } catch {
            #expect(
                String(describing: error).contains(
                    "capture does not match its proven projection"
                )
            )
        }
    }

    @Test("Thunk normalization rejects extra semantic operations")
    func rejectsModifiedCompilerThunk() throws {
        let sil = try canonicalSIL(
            source: """
            public func projectedCount(_ values: [String]) -> [Int] {
                values.map(\\.count)
            }
            """,
            moduleName: "HelixKeyPathThunkFixture"
        )
        let injected = sil.replacingOccurrences(
            of: "  strong_retain %3",
            with: "  strong_retain %3\n  %999 = integer_literal $Builtin.Int64, 0"
        )
        #expect(injected != sil)
        let file = try CanonicalSIL.File(text: injected)
        let root = try #require(
            file.functions.first { $0.mangledName.contains("projectedCount") }
        )
        do {
            _ = try CanonicalSIL.ImageFunctions.discover(
                in: file,
                startingAt: [root.mangledName],
                excluding: [],
                environment: file.typeEnvironment,
                kindForSymbol: { _ in .ordinary }
            )
            Issue.record("modified compiler thunk was trusted")
        } catch {
            #expect(String(describing: error).contains("unproven operation"))
        }
    }

    @Test("The erased KeyPath parameter must remain a guaranteed capture")
    func rejectsOwnedPhysicalKeyPathCapture() throws {
        let sil = try canonicalSIL(
            source: """
            public func projectedCount(_ values: [String]) -> [Int] {
                values.map(\\.count)
            }
            """,
            moduleName: "HelixKeyPathConventionFixture"
        )
        let modified = sil.replacingOccurrences(
            of: "@guaranteed KeyPath<String, Int>",
            with: "@owned KeyPath<String, Int>"
        )
        #expect(modified != sil)
        let file = try CanonicalSIL.File(text: modified)
        let root = try #require(
            file.functions.first { $0.mangledName.contains("projectedCount") }
        )
        do {
            _ = try CanonicalSIL.ImageFunctions.discover(
                in: file,
                startingAt: [root.mangledName],
                excluding: [],
                environment: file.typeEnvironment,
                kindForSymbol: { _ in .ordinary }
            )
            Issue.record("an owned physical KeyPath capture was erased")
        } catch {
            #expect(
                String(describing: error).contains(
                    "invalid physical function type"
                )
            )
        }
    }

    @Test("The compiler thunk cannot destroy its root before projection")
    func rejectsEarlyThunkRootDestruction() throws {
        let sil = try canonicalSIL(
            source: """
            public func projectedCount(_ values: [String]) -> [Int] {
                values.map(\\.count)
            }
            """,
            moduleName: "HelixKeyPathLifetimeFixture"
        )
        var file = try CanonicalSIL.File(text: sil)
        let thunk = try #require(
            file.functions.first { $0.mangledName.contains("cfu_") }
        )
        var lines = thunk.body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let applyIndex = try #require(lines.firstIndex {
            $0.contains(" = apply ") && $0.contains("swift_getAtKeyPath") == false
        })
        let destroyIndex = try #require(lines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("destroy_addr ")
        })
        let destroy = lines.remove(at: destroyIndex)
        let insertion = destroyIndex < applyIndex ? applyIndex - 1 : applyIndex
        lines.insert(destroy, at: insertion)
        let modifiedBody = lines.joined(separator: "\n")
        let thunkIndex = try #require(
            file.functions.firstIndex {
                $0.mangledName == thunk.mangledName
            }
        )
        file.functions[thunkIndex].body = modifiedBody
        #expect(file.functions[thunkIndex].body != thunk.body)
        let root = try #require(
            file.functions.first { $0.mangledName.contains("projectedCount") }
        )
        do {
            _ = try CanonicalSIL.ImageFunctions.discover(
                in: file,
                startingAt: [root.mangledName],
                excluding: [],
                environment: file.typeEnvironment,
                kindForSymbol: { _ in .ordinary }
            )
            Issue.record("a root destroyed before projection was trusted")
        } catch {
            #expect(
                String(describing: error).contains(
                    "proven ownership skeleton"
                )
            )
        }
    }

    @Test("Fresh local class fields are initialized before projection reads")
    func initializesLocalClassField() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Box {
                let value: Int
                init(value: Int) { self.value = value }
            }
            public func classProjection(_ value: Int) -> Int {
                [Box(value: value)].map(\\.value)[0]
            }
            """,
            functionName: "classProjection"
        )
        let result = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [try integer(23)]
        )
        #expect(result == .returned(try integer(23)))
        #expect(fixture.image.module.functions.contains { function in
            function.blocks.flatMap(\.instructions).contains { instruction in
                guard case let .storeAddress(_, _, mode) = instruction else {
                    return false
                }
                return mode == .initialize
            }
        })
    }

    private func canonicalSIL(
        source: String,
        moduleName: String
    ) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-static-keypath-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data((source + "\n").utf8).write(to: sourceURL)
        return try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: moduleName,
            optimization: "-Onone",
            additionalArguments: ["-Xfrontend", "-disable-sil-perf-optzns"],
            purpose: .semanticLowering
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
