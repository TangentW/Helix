import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Remaining common Swift closure scenarios")
struct ClosureAuditMatrix {
    @Test("Closure-scope recognition excludes implementation helpers")
    func recognizesOnlySemanticClosureScopeEntries() {
        let symbol = "$ss20withExtendedLifetimeyq0_x_q0_yq_YKXEtq_YKs5ErrorR_Ri_zRi0_zRi_0_r1_lF"
        #expect(
            CanonicalSIL.SynchronousClosureScopeIntrinsic(
                mangledName: symbol
            ) == .extendedLifetime
        )
        #expect(
            CanonicalSIL.SynchronousClosureScopeIntrinsic(
                mangledName: symbol + "6$deferL_yyF"
            ) == nil
        )
    }

    @Test("Dictionary, Result, Optional, and fallback closure storage compose")
    func lowersNestedClosureStorageSelection() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error { case missing }

            public func nestedClosureStorageSelection(
                _ value: Int,
                _ succeeds: Bool
            ) -> Int {
                let transforms: [String: (Int) -> Int] = [
                    "increment": { $0 + 1 },
                    "double": { $0 * 2 },
                ]
                let selected: Result<(Int) -> Int, Failure> = succeeds
                    ? .success(transforms["increment"]!)
                    : .failure(.missing)
                let optional: ((Int) -> Int)?
                switch selected {
                case let .success(transform): optional = transform
                case .failure: optional = nil
                }
                return (optional ?? { $0 - 10 })(value)
            }
            """,
            functionName: "nestedClosureStorageSelection",
            moduleName: "HelixNestedClosureStorageSelectionFixture"
        )

        #expect(
            try invoke(fixture, [integer(4), .bool(true)]) == integer(5)
        )
        #expect(
            try invoke(fixture, [integer(4), .bool(false)]) == integer(-6)
        )
    }

    @Test("Weak-self factories preserve live and released owner semantics")
    func lowersWeakSelfClosureFactories() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let offset: Int

                init(offset: Int) {
                    self.offset = offset
                }

                func makeTransform() -> (Int) -> Int {
                    { [weak self] value in
                        value + (self?.offset ?? -100)
                    }
                }
            }

            public func weakSelfClosureFactory(
                _ value: Int,
                _ retainOwner: Bool
            ) -> Int {
                if retainOwner {
                    let owner = Owner(offset: 3)
                    let transform = owner.makeTransform()
                    return transform(value) + owner.offset - owner.offset
                }
                return Owner(offset: 3).makeTransform()(value)
            }
            """,
            functionName: "weakSelfClosureFactory",
            moduleName: "HelixWeakSelfClosureFactoryFixture"
        )

        #expect(
            try invoke(fixture, [integer(4), .bool(true)]) == integer(7)
        )
        #expect(
            try invoke(fixture, [integer(4), .bool(false)]) == integer(-96)
        )
    }

    @Test("withExtendedLifetime composes with a weak closure capture")
    func lowersExtendedLifetimeClosureScopes() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let offset: Int

                init(offset: Int) {
                    self.offset = offset
                }
            }

            public func extendedLifetimeClosureScope(_ value: Int) -> Int {
                let owner = Owner(offset: 3)
                let transform = { [weak owner] in
                    value + (owner?.offset ?? -100)
                }
                return withExtendedLifetime(owner) {
                    transform()
                }
            }
            """,
            functionName: "extendedLifetimeClosureScope",
            moduleName: "HelixExtendedLifetimeClosureScopeFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(7))
    }

    @Test("Throwing withExtendedLifetime preserves both continuations")
    func lowersThrowingExtendedLifetimeClosureScopes() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum LifetimeFailure: Error {
                case missing
                case observed(Int)
            }

            private final class Owner {
                let offset: Int

                init(offset: Int) {
                    self.offset = offset
                }
            }

            public func throwingExtendedLifetimeClosureScope(
                _ value: Int,
                _ shouldThrow: Bool
            ) -> Int {
                let owner = Owner(offset: 3)
                do {
                    return try withExtendedLifetime(owner) { [weak owner]
                        () throws(LifetimeFailure) -> Int in
                        guard let owner else { throw .missing }
                        let result = value + owner.offset
                        if shouldThrow { throw .observed(result) }
                        return result
                    }
                } catch {
                    switch error {
                    case .missing: return -100
                    case .observed(let result): return result
                    }
                }
            }
            """,
            functionName: "throwingExtendedLifetimeClosureScope",
            moduleName: "HelixThrowingExtendedLifetimeClosureScopeFixture"
        )

        #expect(
            try invoke(fixture, [integer(4), .bool(false)]) == integer(7)
        )
        #expect(
            try invoke(fixture, [integer(4), .bool(true)]) == integer(7)
        )
    }

    @Test("withExtendedLifetime may return a closure without extending its anchor")
    func lowersClosureValuedExtendedLifetimeResults() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let offset: Int

                init(offset: Int) {
                    self.offset = offset
                }
            }

            private func makeWeakTransform() -> () -> Int {
                let owner = Owner(offset: 3)
                return withExtendedLifetime(owner) {
                    { [weak owner] in owner?.offset ?? -100 }
                }
            }

            public func closureValuedExtendedLifetimeResult() -> Int {
                makeWeakTransform()()
            }
            """,
            functionName: "closureValuedExtendedLifetimeResult",
            moduleName: "HelixClosureValuedExtendedLifetimeFixture"
        )

        #expect(try invoke(fixture, []) == integer(-100))
    }

    private func invoke(
        _ fixture: FrontendExecutionHarness.Fixture,
        _ arguments: [VM.Value]
    ) throws -> VM.Value {
        let outcome = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: arguments
        )
        guard case let .returned(value) = outcome else {
            Issue.record("expected returned value, got \(outcome)")
            return try integer(0)
        }
        return try #require(value)
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
