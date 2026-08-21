import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift closure value semantics matrix")
struct ClosureValueSemanticsMatrix {
    @Test("Closure-valued synthesized struct initializers remain proven factories")
    func recognizesClosureValuedStructFactory() throws {
        let symbol = "$s7Fixture9CallbacksV9increment5scaleACS2ic_S2ictcfC"
        let file = try CanonicalSIL.File(text: """
        sil_stage canonical

        import Builtin
        import Swift

        private struct Callbacks {
          @_hasStorage let increment: (Int) -> Int { get }
          @_hasStorage let scale: (Int) -> Int { get }
          init(increment: @escaping (Int) -> Int, scale: @escaping (Int) -> Int)
        }

        sil private @\(symbol) : $@convention(method) (@owned @callee_guaranteed (Int) -> Int, @owned @callee_guaranteed (Int) -> Int, @thin Callbacks.Type) -> @owned Callbacks {
        bb0(%0 : $@callee_guaranteed (Int) -> Int, %1 : $@callee_guaranteed (Int) -> Int, %2 : $@thin Callbacks.Type):
          %3 = struct $Callbacks (%0, %1)
          return %3
        } // end sil function '\(symbol)'
        """)
        let function = try #require(file.function(mangledName: symbol))
        let fields = try file.typeEnvironment.structFields(
            for: .init(rawValue: "Callbacks")
        )

        #expect(fields.count == 2)
        #expect(file.typeEnvironment.hasStructFactorySignature(function))
        #expect(file.typeEnvironment.isStructFactory(symbol))
    }

    @Test("Optional closures preserve invocation and nil semantics")
    func lowersOptionalClosures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func optionalClosure(
                _ value: Int,
                _ hasCallback: Bool
            ) -> Int {
                let callback: ((Int) -> Int)? = hasCallback
                    ? { $0 + 3 }
                    : nil
                return callback?(value) ?? -1
            }
            """,
            functionName: "optionalClosure",
            moduleName: "HelixOptionalClosureFixture"
        )

        #expect(try invoke(fixture, [integer(4), .bool(true)]) == integer(7))
        #expect(try invoke(fixture, [integer(4), .bool(false)]) == integer(-1))
    }

    @Test("Higher-order closures accept and return closure values")
    func lowersNestedClosureSignatures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func applyFactory(
                _ seed: Int,
                _ consume: ((Int) -> Int) -> Int,
                _ make: (Int) -> (Int) -> Int
            ) -> Int {
                let base = { (value: Int) in value + seed }
                return consume(base) + make(seed)(2)
            }

            public func nestedClosureSignature(_ seed: Int) -> Int {
                applyFactory(
                    seed,
                    { transform in transform(2) * 3 },
                    { offset in { value in value + offset } }
                )
            }
            """,
            functionName: "nestedClosureSignature",
            moduleName: "HelixNestedClosureSignatureFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(24))
    }

    @Test("Closures remain first-class inside tuples, structs, and arrays")
    func lowersAggregateClosureStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Callbacks {
                let increment: (Int) -> Int
                let scale: (Int) -> Int
            }

            public func aggregateClosureStorage(
                _ value: Int,
                _ useScale: Bool
            ) -> Int {
                let callbacks = Callbacks(
                    increment: { $0 + 2 },
                    scale: { $0 * 3 }
                )
                let pair = (callbacks.increment, callbacks.scale)
                let ordered = [pair.0, pair.1]
                let named = ["increment": ordered[0], "scale": ordered[1]]
                let name = useScale ? "scale" : "increment"
                return named[name]!(value)
            }
            """,
            functionName: "aggregateClosureStorage",
            moduleName: "HelixAggregateClosureStorageFixture"
        )

        #expect(try invoke(fixture, [integer(4), .bool(false)]) == integer(6))
        #expect(try invoke(fixture, [integer(4), .bool(true)]) == integer(12))
    }

    @Test("Capture lists snapshot values independently of later mutation")
    func lowersCaptureLists() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func closureCaptureList(_ seed: Int) -> (Int, Int) {
                var offset = seed
                let snapshot = { [offset] (value: Int) in value + offset }
                let shared = { (value: Int) in value + offset }
                offset += 5
                return (snapshot(2), shared(2))
            }
            """,
            functionName: "closureCaptureList",
            moduleName: "HelixClosureCaptureListFixture"
        )

        #expect(
            try invoke(fixture, [integer(4)])
                == .tuple([try integer(6), try integer(11)])
        )
    }

    @Test("Recursive closure variables retain one shared callback cell")
    func lowersRecursiveClosureVariables() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func recursiveClosureVariable(_ value: Int) -> Int {
                var factorial: ((Int) -> Int)!
                factorial = { input in
                    input <= 1 ? 1 : input * factorial(input - 1)
                }
                return factorial(value)
            }
            """,
            functionName: "recursiveClosureVariable",
            moduleName: "HelixRecursiveClosureVariableFixture"
        )

        #expect(try invoke(fixture, [integer(5)]) == integer(120))
    }

    @Test("Local function references form ordinary closure values")
    func lowersLocalFunctionReferences() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func localFunctionReference(_ seed: Int) -> Int {
                func addSeed(_ value: Int) -> Int { value + seed }
                let callback: (Int) -> Int = addSeed
                return callback(3)
            }
            """,
            functionName: "localFunctionReference",
            moduleName: "HelixLocalFunctionReferenceFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(7))
    }

    @Test("Multiple trailing closures preserve lazy branch selection")
    func lowersMultipleTrailingClosures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func choose(
                _ condition: Bool,
                success: () -> Int,
                failure: () -> Int
            ) -> Int {
                condition ? success() : failure()
            }

            public func multipleTrailingClosures(
                _ value: Int,
                _ condition: Bool
            ) -> Int {
                choose(condition) {
                    value + 2
                } failure: {
                    value - 3
                }
            }
            """,
            functionName: "multipleTrailingClosures",
            moduleName: "HelixMultipleTrailingClosuresFixture"
        )

        #expect(try invoke(fixture, [integer(5), .bool(true)]) == integer(7))
        #expect(try invoke(fixture, [integer(5), .bool(false)]) == integer(2))
    }

    @Test("Escaping autoclosures can be forwarded and invoked later")
    func lowersEscapingAutoclosures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func deferred(
                _ value: @autoclosure @escaping () -> Int
            ) -> () -> Int {
                value
            }

            public func escapingAutoclosure(_ value: Int) -> Int {
                let callback = deferred(value + 4)
                return callback()
            }
            """,
            functionName: "escapingAutoclosure",
            moduleName: "HelixEscapingAutoclosureFixture"
        )

        #expect(try invoke(fixture, [integer(5)]) == integer(9))
    }

    @Test("Enum payloads retain closure values and case selection")
    func lowersClosureEnumPayloads() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Handler {
                case active((Int) -> Int)
                case inactive
            }

            public func closureEnumPayload(
                _ value: Int,
                _ active: Bool
            ) -> Int {
                let handler: Handler = active
                    ? .active { $0 * 2 }
                    : .inactive
                return switch handler {
                case let .active(callback): callback(value)
                case .inactive: -1
                }
            }
            """,
            functionName: "closureEnumPayload",
            moduleName: "HelixClosureEnumPayloadFixture"
        )

        #expect(try invoke(fixture, [integer(5), .bool(true)]) == integer(10))
        #expect(try invoke(fixture, [integer(5), .bool(false)]) == integer(-1))
    }

    @Test("Patch-local classes retain replaceable closure properties")
    func lowersClosureValuedClassProperties() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class CallbackBox {
                var callback: (Int) -> Int

                init(callback: @escaping (Int) -> Int) {
                    self.callback = callback
                }
            }

            public func closureValuedClassProperty(
                _ value: Int,
                _ replace: Bool
            ) -> Int {
                let box = CallbackBox(callback: { $0 + 2 })
                if replace {
                    box.callback = { $0 * 3 }
                }
                return box.callback(value)
            }
            """,
            functionName: "closureValuedClassProperty",
            moduleName: "HelixClosureClassPropertyFixture"
        )

        #expect(
            try invoke(fixture, [integer(4), .bool(false)]) == integer(6)
        )
        #expect(
            try invoke(fixture, [integer(4), .bool(true)]) == integer(12)
        )
    }

    @Test("Bound instance and static methods form closure values")
    func lowersMethodReferences() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Calculator {
                let offset: Int

                func add(_ value: Int) -> Int { value + offset }
                static func doubled(_ value: Int) -> Int { value * 2 }
            }

            public func methodReferences(_ value: Int) -> Int {
                let calculator = Calculator(offset: 3)
                let callbacks: [(Int) -> Int] = [
                    calculator.add,
                    Calculator.doubled,
                ]
                return callbacks[0](value) + callbacks[1](value)
            }
            """,
            functionName: "methodReferences",
            moduleName: "HelixMethodReferencesFixture"
        )

        #expect(try invoke(fixture, [integer(5)]) == integer(18))
    }

    @Test("Escaping closures strongly capture and mutate their local-class owner")
    func lowersStrongSelfCaptures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Counter {
                var total: Int

                init(total: Int) {
                    self.total = total
                }

                func makeAdder() -> (Int) -> Int {
                    { [self] value in
                        total += value
                        return total
                    }
                }
            }

            public func strongSelfCapture(_ seed: Int) -> Int {
                let counter = Counter(total: seed)
                let add = counter.makeAdder()
                return add(2) + add(3)
            }
            """,
            functionName: "strongSelfCapture",
            moduleName: "HelixStrongSelfCaptureFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(15))
    }

    @Test("defer bodies preserve mutable capture writeback inside closures")
    func lowersDeferredClosureCleanup() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func deferredClosureCleanup(_ seed: Int) -> Int {
                var value = seed
                let update = {
                    defer { value += 2 }
                    value += 1
                }
                update()
                return value
            }
            """,
            functionName: "deferredClosureCleanup",
            moduleName: "HelixDeferredClosureCleanupFixture"
        )

        #expect(fixture.image.module.functions.contains {
            $0.kind == .concreteSpecialization && $0.name.contains("$defer")
        })
        #expect(try invoke(fixture, [integer(4)]) == integer(7))
    }

    @Test("Nonthrowing closures adapt to a throwing function value")
    func lowersNonthrowingToThrowingConversions() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func invokeThrowing(
                _ value: Int,
                _ callback: (Int) throws -> Int
            ) rethrows -> Int {
                try callback(value)
            }

            public func closureEffectConversion(_ value: Int) -> Int {
                let callback: (Int) throws -> Int = { $0 + 3 }
                return try! invokeThrowing(value, callback)
            }
            """,
            functionName: "closureEffectConversion",
            moduleName: "HelixClosureEffectConversionFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(7))
    }

    @Test("withoutActuallyEscaping scopes temporary escaping storage")
    func lowersWithoutActuallyEscaping() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func temporarilyStore(_ callback: () -> Int) -> Int {
                withoutActuallyEscaping(callback) { escapable in
                    let callbacks = [escapable]
                    return callbacks[0]()
                }
            }

            public func scopedEscapingClosure(_ value: Int) -> Int {
                temporarilyStore { value + 2 }
            }
            """,
            functionName: "scopedEscapingClosure",
            moduleName: "HelixScopedEscapingClosureFixture"
        )

        #expect(try invoke(fixture, [integer(5)]) == integer(7))
    }

    @Test("Dead aliases do not look like dynamically scoped closure escape")
    func releasesWithoutActuallyEscapingAliases() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func invokeAlias(_ callback: () -> Int) -> Int {
                withoutActuallyEscaping(callback) { escapable in
                    let alias = escapable
                    return alias()
                }
            }

            public func scopedClosureAlias(_ value: Int) -> Int {
                invokeAlias { value + 2 }
            }
            """,
            functionName: "scopedClosureAlias",
            moduleName: "HelixScopedClosureAliasFixture"
        )

        #expect(try invoke(fixture, [integer(5)]) == integer(7))
    }

    @Test("Throwing withoutActuallyEscaping closes both continuations")
    func lowersThrowingWithoutActuallyEscaping() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum CallbackFailure: Error {
                case expected
            }

            @inline(never)
            func temporarilyInvoke(
                _ callback: () throws -> Int
            ) rethrows -> Int {
                try withoutActuallyEscaping(callback) { escapable in
                    try escapable()
                }
            }

            public func throwingScopedClosure(
                _ value: Int,
                _ shouldThrow: Bool
            ) -> Int {
                do {
                    return try temporarilyInvoke {
                        if shouldThrow { throw CallbackFailure.expected }
                        return value + 2
                    }
                } catch {
                    return -1
                }
            }
            """,
            functionName: "throwingScopedClosure",
            moduleName: "HelixThrowingScopedClosureFixture"
        )

        #expect(
            try invoke(fixture, [integer(5), .bool(false)]) == integer(7)
        )
        #expect(
            try invoke(fixture, [integer(5), .bool(true)]) == integer(-1)
        )
    }

    @Test("Mutable captured closure variables share their current value")
    func lowersMutableClosureCaptures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func mutableClosureCapture(
                _ value: Int,
                _ replace: Bool
            ) -> Int {
                var callback = { (input: Int) in input + 1 }
                let invoke = { (input: Int) in callback(input) }
                if replace {
                    callback = { input in input * 3 }
                }
                return invoke(value)
            }
            """,
            functionName: "mutableClosureCapture",
            moduleName: "HelixMutableClosureCaptureFixture"
        )

        #expect(try invoke(fixture, [integer(4), .bool(false)]) == integer(5))
        #expect(try invoke(fixture, [integer(4), .bool(true)]) == integer(12))
    }

    @Test("Nonescaping closures may capture caller-scoped inout storage")
    func lowersNonescapingInoutCaptures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func invokeImmediately(_ callback: () -> Void) {
                callback()
            }

            @inline(never)
            func incrementThroughCapture(_ value: inout Int) {
                invokeImmediately {
                    value += 1
                }
            }

            public func nonescapingInoutCapture(_ seed: Int) -> Int {
                var value = seed
                incrementThroughCapture(&value)
                return value
            }
            """,
            functionName: "nonescapingInoutCapture",
            moduleName: "HelixNonescapingInoutCaptureFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(5))
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
