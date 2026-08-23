import Foundation
import HelixBytecode
import HelixCore
import HelixInterface
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift protocol existential lowering")
struct ProtocolExistentialTests {
    @Test("Protocol identities normalize bounded compositions and function results")
    func parsesProtocolExistentialIdentities() throws {
        let identity = try #require(
            CanonicalSIL.ProtocolExistential.Identity(
                spelling: "$@guaranteed any Fixture.Tagged & AnyObject & Fixture.Named"
            )
        )
        #expect(identity.protocols == ["Fixture.Named", "Fixture.Tagged"])
        #expect(identity.requiresClass)
        #expect(identity.description == "any Fixture.Named & Fixture.Tagged & AnyObject")
        #expect(
            CanonicalSIL.ProtocolExistential.Identity.functionResult(
                spelling: "$@convention(thin) (Int) -> @owned any Fixture.Named"
            )?.description == "any Fixture.Named"
        )
        #expect(
            CanonicalSIL.ProtocolExistential.Identity.functionResult(
                spelling: "$@convention(thin) (Int) -> @callee_guaranteed () -> any Fixture.Named"
            ) == nil
        )
        #expect(
            CanonicalSIL.ProtocolExistential.Identity(
                spelling: "any Fixture.Named & Fixture.Named"
            ) == nil
        )
        #expect(
            CanonicalSIL.ProtocolExistential.Identity(
                spelling: "any Error"
            ) == nil
        )
        #expect(
            CanonicalSIL.ProtocolExistential.Identity.identities(
                in: "$@convention(thin) (Array<any Fixture.Named>, (any Fixture.Tagged & AnyObject)?) -> any Error"
            ).map(\.description) == [
                "any Fixture.Named",
                "any Fixture.Tagged & AnyObject",
            ]
        )
        #expect(
            CanonicalSIL.ProtocolExistential.Identity
                .containsProtocolExistential(in: "Array<any Sendable>")
        )
        #expect(
            CanonicalSIL.ProtocolExistential.Identity
                .containsProtocolExistential(in: "any Error & Fixture.Named")
        )
        #expect(
            !CanonicalSIL.ProtocolExistential.Identity
                .containsProtocolExistential(in: "(any Swift.Error)?")
        )
    }

    @Test("Closure results retain their protocol identity")
    func dispatchesExistentialReturnedByClosure() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Named: AnyObject {
                func value() -> Int
            }

            private final class Reference: Named {
                var amount: Int
                init(amount: Int) { self.amount = amount }
                func value() -> Int { amount + 1 }
            }

            @inline(never)
            private func invoke(
                _ factory: (Int) -> any Named,
                _ amount: Int
            ) -> Int {
                factory(amount).value()
            }

            public func closureExistential(_ amount: Int) -> Int {
                invoke({ Reference(amount: $0) }, amount)
            }
            """,
            functionName: "closureExistential",
            moduleName: "HelixClosureExistentialFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(9)]
            ) == .returned(try integer(10))
        )
        #expect(fixture.image.module.capabilities.contains(.closureValuesV1))
    }

    @Test("Protocol existential values cannot cross the Shell root")
    func rejectsExistentialShellBoundary() {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                public protocol Named {
                    func value() -> Int
                }

                public struct Value: Named {
                    public var amount: Int
                    public init(amount: Int) { self.amount = amount }
                    public func value() -> Int { amount }
                }

                public func existentialRoot(_ value: any Named) -> Int {
                    value.value()
                }
                """,
                functionName: "existentialRoot",
                moduleName: "HelixExistentialBoundaryFixture"
            )
            Issue.record("protocol existential Shell root unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unsupportedType(detail) = error else {
                Issue.record("unexpected Shell-boundary error: \(error)")
                return
            }
            #expect(detail.contains("protocol existential Shell root"))
        } catch {
            Issue.record("unexpected Shell-boundary error: \(error)")
        }
    }

    @Test("Release indexing marks protocol existential roots ineligible")
    func rejectsExistentialRootDuringIndexing() throws {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.existential-index",
            buildNumber: "1",
            seed: "fixture"
        )
        let loweredType = "@convention(thin) (@in_guaranteed any Fixture.Named) -> Int64"
        let candidate = ReleaseCompiler.DeclarationCandidate(
            moduleName: "Fixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func read(_: any Named) -> Int",
            mangledName: "$s7Fixture4readySiAA5Named_pF",
            role: .function,
            loweredSignature: .init(
                parameters: ["any Fixture.Named"],
                result: "Swift.Int"
            ),
            parameterTypes: [.any],
            resultType: .int64,
            interface: .init(
                declarationKind: "function",
                baseName: "read",
                argumentLabels: ["_"],
                accessLevel: "public",
                canonicalFormalType: "(any Fixture.Named) -> Swift.Int",
                loweredSILType: loweredType
            ),
            canonicalSILBody: "bb0:\n  unreachable",
            forcedPatchability: .eligible
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.existential-index",
            buildNumber: "1",
            shellNamespaceID: namespace,
            machOUUIDs: [
                try #require(
                    UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
                ),
            ],
            targetTriple: "arm64-apple-ios15.0",
            minimumOS: .init(15),
            xcodeBuild: "fixture",
            sdkBuild: "fixture",
            frontendInvocation: .init(
                moduleName: "Fixture",
                targetTriple: "arm64-apple-ios15.0",
                sdkName: "iphoneos",
                sdkBuild: "fixture"
            ),
            transformPipelineHash: .sha256("existential-index-transform"),
            sourceBaselineHash: .sha256("existential-index-source")
        )
        let report = try ReleaseCompiler.Indexer().index(
            .init(
                metadata: metadata,
                compatibility: .init(
                    runtime: Core.Versions.runtime,
                    bytecode: Core.Versions.bytecode,
                    interfaceArchive: Core.Versions.interfaceArchive,
                    compilerFingerprint: "swift-existential-index"
                ),
                configuration: .init(
                    modules: ["Fixture": .init(include: ["Patch.swift"])]
                ),
                sources: [
                    .init(
                        logicalPath: "Patch.swift",
                        contentHash: .sha256("existential-index-source")
                    ),
                ],
                declarations: [candidate],
                capabilities: [.baselineV1, .anyValuesV1]
            )
        )

        #expect(report.eligibleCount == 0)
        #expect(report.rejectedCount == 1)
        #expect(report.archive.functions.first?.patchability.reasonCode == "HLXIDX023")
    }

    @Test("Protocol existential calls cannot cross NativeImport")
    func rejectsExistentialNativeBoundary() throws {
        let symbol = "$s7Fixture7consumeyyAA5Named_pF"
        let requirement = Bytecode.ImportRequirement(
            id: .init(rawValue: 0),
            key: .init(rawValue: .sha256("existential-native-import")),
            signature: .init(
                parameters: ["Swift.Any"],
                result: "Swift.Void"
            ),
            effects: .init(),
            contract: .bounded(
                kind: .globalFunction,
                domain: .application,
                access: .pure,
                maximumDurationMicroseconds: 500,
                allowsMainThread: true
            )
        )
        let functionType = "@convention(thin) (@guaranteed any Fixture.Named & AnyObject) -> ()"
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.any],
                parameterConventions: [.owned],
                resultType: .void,
                target: .nativeImport(requirement)
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4testyyAA5Named_pF",
            loweredType: functionType,
            body: """
            bb0(%0 : @guaranteed $any Fixture.Named & AnyObject):
              %1 = function_ref @\(symbol) : $\(functionType)
              %2 = apply %1(%0) : $\(functionType)
              %3 = tuple ()
              return %3
            """
        )

        do {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "Fixture.test",
                directCalls: calls
            )
            Issue.record("protocol existential NativeImport unexpectedly lowered")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unsupportedType(detail) = error else {
                Issue.record("unexpected NativeImport-boundary error: \(error)")
                return
            }
            #expect(detail.contains("crosses a Shell or NativeImport boundary"))
        } catch {
            Issue.record("unexpected NativeImport-boundary error: \(error)")
        }
    }

    @Test("Local any P dispatch selects the exact concrete witness")
    func dispatchesLocalExistential() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Valued {
                func value() -> Int
            }

            private struct First: Valued {
                var amount: Int
                func value() -> Int { amount + 1 }
            }

            private struct Second: Valued {
                var amount: Int
                func value() -> Int { amount * 2 }
            }

            @inline(never)
            private func make(_ first: Bool, _ amount: Int) -> any Valued {
                first ? First(amount: amount) : Second(amount: amount)
            }

            @inline(never)
            private func read(_ value: any Valued) -> Int {
                value.value()
            }

            public func localExistential(_ first: Bool, _ amount: Int) -> Int {
                read(make(first, amount))
            }
            """,
            functionName: "localExistential",
            moduleName: "HelixLocalExistentialFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.bool(true), try integer(4)]
            ) == .returned(try integer(5))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.bool(false), try integer(4)]
            ) == .returned(try integer(8))
        )
        #expect(fixture.image.module.functions.contains { function in
            function.blocks.contains { block in
                block.instructions.contains {
                    if case .existentialApply = $0 { true } else { false }
                }
            }
        })
    }

    @Test("Compositions, classes, arrays, narrowing, and bound methods compose")
    func composesCommonExistentialUses() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Named {
                var value: Int { get }
                func adding(_ amount: Int) -> Int
            }

            private protocol Tagged {
                var tag: Int { get }
            }

            private struct Item: Named, Tagged {
                var value: Int
                var tag: Int
                func adding(_ amount: Int) -> Int { value + amount }
            }

            private final class Reference: Named, Tagged {
                var value: Int
                var tag: Int

                init(value: Int, tag: Int) {
                    self.value = value
                    self.tag = tag
                }

                func adding(_ amount: Int) -> Int { value * amount }
            }

            @inline(never)
            private func make(
                _ useItem: Bool,
                _ value: Int
            ) -> any Named & Tagged {
                useItem
                    ? Item(value: value, tag: 10)
                    : Reference(value: value, tag: 20)
            }

            @inline(never)
            private func narrow(_ value: any Named & Tagged) -> any Named {
                value
            }

            @inline(never)
            private func invokeBound(_ value: any Named) -> Int {
                let operation = value.adding
                return operation(3)
            }

            public func composedExistential(_ useItem: Bool, _ value: Int) -> Int {
                let composed = make(useItem, value)
                let values: [any Named] = [narrow(composed)]
                return invokeBound(values[0]) + composed.tag
            }
            """,
            functionName: "composedExistential",
            moduleName: "HelixComposedExistentialFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.bool(true), try integer(4)]
            ) == .returned(try integer(17))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.bool(false), try integer(4)]
            ) == .returned(try integer(32))
        )
        #expect(fixture.image.module.capabilities.contains(.closureValuesV1))
    }

    @Test("Concrete and protocol existential casts preserve exact identity")
    func castsExistentials() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Named {
                var value: Int { get }
            }

            private protocol Tagged {
                var tag: Int { get }
            }

            private struct First: Named, Tagged {
                var value: Int
                var tag: Int
            }

            private struct Second: Named {
                var value: Int
            }

            @inline(never)
            private func make(_ first: Bool, _ value: Int) -> any Named {
                first
                    ? First(value: value, tag: value + 10)
                    : Second(value: value)
            }

            @inline(never)
            private func concrete(_ value: any Named) -> Int {
                (value as? First)?.tag ?? -1
            }

            @inline(never)
            private func protocolValue(_ value: any Named) -> Int {
                (value as? any Tagged)?.tag ?? -2
            }

            @inline(never)
            private func forced(_ value: any Named) -> Int {
                (value as! any Tagged).tag
            }

            public func existentialCasts(_ first: Bool, _ value: Int) -> Int {
                let item = make(first, value)
                let base = concrete(item) + protocolValue(item)
                return first ? base + forced(item) : base
            }
            """,
            functionName: "existentialCasts",
            moduleName: "HelixExistentialCastFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.bool(true), try integer(5)]
            ) == .returned(try integer(45))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.bool(false), try integer(5)]
            ) == .returned(try integer(-3))
        )
    }

    @Test("Throwing existential witnesses retain both continuations")
    func dispatchesThrowingExistential() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error { case rejected }

            private protocol Checked {
                func checked(_ reject: Bool) throws -> Int
            }

            private struct Value: Checked {
                var amount: Int

                func checked(_ reject: Bool) throws -> Int {
                    if reject { throw Failure.rejected }
                    return amount + 1
                }
            }

            @inline(never)
            private func erase(_ amount: Int) -> any Checked {
                Value(amount: amount)
            }

            @inline(never)
            private func read(
                _ value: any Checked,
                _ reject: Bool
            ) throws -> Int {
                try value.checked(reject)
            }

            public func throwingExistential(_ amount: Int) throws -> Int {
                try read(erase(amount), false)
            }
            """,
            functionName: "throwingExistential",
            moduleName: "HelixThrowingExistentialFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(7)]
            ) == .returned(try integer(8))
        )
        #expect(fixture.image.module.functions.contains { function in
            function.blocks.contains { block in
                block.instructions.contains {
                    if case .existentialTryApply = $0 { true } else { false }
                }
            }
        })
    }

    @Test("Inherited and class-bound protocols retain their closed conformer sets")
    func dispatchesInheritedAndClassBoundExistentials() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private protocol Parent {
                func parent() -> Int
            }

            private protocol Child: Parent {
                func child() -> Int
            }

            private struct Value: Child {
                var amount: Int
                func parent() -> Int { amount + 1 }
                func child() -> Int { amount + 2 }
            }

            private final class Reference: Child {
                var amount: Int
                init(amount: Int) { self.amount = amount }
                func parent() -> Int { amount * 2 }
                func child() -> Int { amount * 3 }
            }

            @inline(never)
            private func eraseParent(
                _ reference: Bool,
                _ amount: Int
            ) -> any Parent {
                reference
                    ? Reference(amount: amount)
                    : Value(amount: amount)
            }

            @inline(never)
            private func eraseReference(
                _ amount: Int
            ) -> any Child & AnyObject {
                Reference(amount: amount)
            }

            @inline(never)
            private func readParent(_ value: any Parent) -> Int {
                value.parent()
            }

            @inline(never)
            private func readReference(
                _ value: any Child & AnyObject
            ) -> Int {
                value.parent() + value.child()
            }

            @inline(never)
            private func widenReference(
                _ value: any Child & AnyObject
            ) -> any Parent {
                value
            }

            @inline(never)
            private func widenClassReference(
                _ value: any Child & AnyObject
            ) -> any Parent & AnyObject {
                value
            }

            public func inheritedExistential(
                _ reference: Bool,
                _ amount: Int
            ) -> Int {
                readParent(eraseParent(reference, amount))
                    + readReference(eraseReference(amount))
                    + readParent(widenReference(eraseReference(amount)))
                    + readParent(widenClassReference(eraseReference(amount)))
            }
            """,
            functionName: "inheritedExistential",
            moduleName: "HelixInheritedExistentialFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.bool(false), try integer(4)]
            ) == .returned(try integer(41))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.bool(true), try integer(4)]
            ) == .returned(try integer(44))
        )
    }

    @Test("Mutable existential opening remains fail-closed until writeback support")
    func rejectsMutableExistentialOpening() {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                private protocol Counter {
                    var value: Int { get }
                    mutating func increment()
                }

                private struct Value: Counter {
                    var value: Int
                    mutating func increment() { value += 1 }
                }

                @inline(never)
                private func mutate(_ value: inout any Counter) {
                    value.increment()
                }

                public func mutableExistential(_ amount: Int) -> Int {
                    var value: any Counter = Value(value: amount)
                    mutate(&value)
                    return value.value
                }
                """,
                functionName: "mutableExistential",
                moduleName: "HelixMutableExistentialFixture"
            )
            Issue.record("mutable existential opening unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unsupportedInstruction(_, text) = error else {
                Issue.record("unexpected mutable-existential error: \(error)")
                return
            }
            #expect(text.contains("open_existential_addr mutable_access"))
        } catch {
            Issue.record("unexpected mutable-existential error: \(error)")
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
