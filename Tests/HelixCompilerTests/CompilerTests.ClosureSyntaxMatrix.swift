import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Common Swift closure syntax matrix")
struct ClosureSyntaxMatrix {
    @Test("Closure-valued default arguments retain explicit and generated paths")
    func lowersClosureDefaultArguments() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func apply(
                _ value: Int,
                transform: @escaping (Int) -> Int = { $0 + 1 }
            ) -> Int {
                transform(value)
            }

            public func closureDefaultArgument(
                _ value: Int,
                _ useExplicit: Bool
            ) -> Int {
                if useExplicit {
                    return apply(value, transform: { $0 * 3 })
                }
                return apply(value)
            }
            """,
            functionName: "closureDefaultArgument",
            moduleName: "HelixClosureDefaultArgumentFixture"
        )

        #expect(try invoke(fixture, [integer(4), .bool(false)]) == integer(5))
        #expect(try invoke(fixture, [integer(4), .bool(true)]) == integer(12))
    }

    @Test("Capture-list expressions compose closure and scalar snapshots")
    func lowersCaptureListExpressions() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func captureListExpressions(
                _ seed: Int,
                _ value: Int
            ) -> Int {
                let increment = { (input: Int) in input + seed }
                let callback = {
                    [transform = increment, offset = seed * 2] input in
                    transform(input) + offset
                }
                return callback(value)
            }
            """,
            functionName: "captureListExpressions",
            moduleName: "HelixCaptureListExpressionFixture"
        )

        #expect(try invoke(fixture, [integer(4), integer(3)]) == integer(15))
    }

    @Test("Mutually recursive closure variables share initialized cells")
    func lowersMutuallyRecursiveClosures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func mutuallyRecursiveClosures(_ value: Int) -> Bool {
                var isEven: ((Int) -> Bool)!
                var isOdd: ((Int) -> Bool)!
                isEven = { input in
                    input == 0 ? true : isOdd(input - 1)
                }
                isOdd = { input in
                    input == 0 ? false : isEven(input - 1)
                }
                return isEven(value)
            }
            """,
            functionName: "mutuallyRecursiveClosures",
            moduleName: "HelixMutuallyRecursiveClosureFixture"
        )

        #expect(try invoke(fixture, [integer(8)]) == .bool(true))
        #expect(try invoke(fixture, [integer(7)]) == .bool(false))
    }

    @Test("Escaping closures forward through multiple returning helpers")
    func lowersLayeredEscapingForwarding() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func store(_ callback: @escaping (Int) -> Int) -> () -> Int {
                { callback(3) }
            }

            @inline(never)
            func forward(_ callback: @escaping (Int) -> Int) -> () -> Int {
                let stored = store(callback)
                return { stored() + 2 }
            }

            public func layeredEscapingForwarding(_ seed: Int) -> Int {
                let callback = { (input: Int) in input + seed }
                return forward(callback)()
            }
            """,
            functionName: "layeredEscapingForwarding",
            moduleName: "HelixLayeredEscapingForwardingFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(9))
    }

    @Test("Optional callback defaults preserve nil and supplied branches")
    func lowersOptionalClosureDefaults() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func invoke(
                _ value: Int,
                callback: ((Int) -> Int)? = nil
            ) -> Int {
                callback?(value) ?? value
            }

            public func optionalClosureDefault(
                _ value: Int,
                _ supplyCallback: Bool
            ) -> Int {
                if supplyCallback {
                    return invoke(value, callback: { $0 * 2 })
                }
                return invoke(value)
            }
            """,
            functionName: "optionalClosureDefault",
            moduleName: "HelixOptionalClosureDefaultFixture"
        )

        #expect(try invoke(fixture, [integer(5), .bool(false)]) == integer(5))
        #expect(try invoke(fixture, [integer(5), .bool(true)]) == integer(10))
    }

    @Test("Throwing autoclosures preserve lazy error propagation")
    func lowersThrowingAutoclosures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error { case expected }

            @inline(never)
            func produce(_ value: Int, shouldThrow: Bool) throws -> Int {
                if shouldThrow { throw Failure.expected }
                return value + 2
            }

            @inline(never)
            func evaluate(
                _ value: @autoclosure () throws -> Int
            ) rethrows -> Int {
                try value()
            }

            public func throwingAutoclosure(
                _ value: Int,
                _ shouldThrow: Bool
            ) -> Int {
                do {
                    return try evaluate(
                        try produce(value, shouldThrow: shouldThrow)
                    )
                } catch {
                    return -1
                }
            }
            """,
            functionName: "throwingAutoclosure",
            moduleName: "HelixThrowingAutoclosureFixture"
        )

        #expect(try invoke(fixture, [integer(5), .bool(false)]) == integer(7))
        #expect(try invoke(fixture, [integer(5), .bool(true)]) == integer(-1))
    }

    @Test("Bound methods specialize through generic closure forwarding")
    func lowersGenericBoundMethodForwarding() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Offset {
                let value: Int

                func apply(_ input: Int) -> Int {
                    input + value
                }
            }

            @inline(never)
            func genericApply<Value>(
                _ value: Value,
                transform: (Value) -> Value
            ) -> Value {
                transform(value)
            }

            public func genericBoundMethodForwarding(
                _ value: Int,
                _ offset: Int
            ) -> Int {
                genericApply(value, transform: Offset(value: offset).apply)
            }
            """,
            functionName: "genericBoundMethodForwarding",
            moduleName: "HelixGenericBoundMethodForwardingFixture"
        )

        #expect(try invoke(fixture, [integer(5), integer(4)]) == integer(9))
    }

    @Test("One generic closure helper materializes independent concrete call targets")
    func lowersMultipleGenericClosureSpecializations() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func apply<Value>(
                _ value: Value,
                transform: (Value) -> Value
            ) -> Value {
                transform(value)
            }

            public func multipleGenericClosureSpecializations(
                _ value: Int,
                _ flag: Bool
            ) -> Int {
                let integer = apply(value) { $0 + 2 }
                let boolean = apply(flag) { !$0 }
                return boolean ? integer : -integer
            }
            """,
            functionName: "multipleGenericClosureSpecializations",
            moduleName: "HelixMultipleGenericClosureSpecializationsFixture"
        )

        #expect(try invoke(fixture, [integer(5), .bool(false)]) == integer(7))
        #expect(try invoke(fixture, [integer(5), .bool(true)]) == integer(-7))
    }

    @Test("Generic functions can be specialized into escaping closure values")
    func lowersEscapingGenericFunctionReferences() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func identity<Value>(_ value: Value) -> Value {
                value
            }

            @inline(never)
            func store(_ transform: @escaping (Int) -> Int) -> () -> Int {
                { transform(4) }
            }

            public func escapingGenericFunctionReference() -> Int {
                let stored = store(identity)
                return stored()
            }
            """,
            functionName: "escapingGenericFunctionReference",
            moduleName: "HelixEscapingGenericFunctionReferenceFixture"
        )

        #expect(try invoke(fixture, []) == integer(4))
    }

    @Test("Generic helpers can return escaping closures without erasing ownership")
    func lowersGenericReturningClosure() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func forward<Value>(
                _ transform: @escaping (Value) -> Value
            ) -> (Value) -> Value {
                transform
            }

            public func genericReturningClosure(_ value: Int) -> Int {
                let transform = forward { $0 + 3 }
                return transform(value)
            }
            """,
            functionName: "genericReturningClosure",
            moduleName: "HelixGenericReturningClosureFixture"
        )

        #expect(try invoke(fixture, [integer(6)]) == integer(9))
    }

    @Test("Generic rethrows helpers preserve closure errors")
    func lowersGenericRethrowsClosureForwarding() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error { case expected }

            @inline(never)
            func apply<Value>(
                _ value: Value,
                transform: (Value) throws -> Value
            ) rethrows -> Value {
                try transform(value)
            }

            public func genericRethrowsClosureForwarding(
                _ value: Int,
                _ shouldThrow: Bool
            ) -> Int {
                do {
                    return try apply(value) { input in
                        if shouldThrow { throw Failure.expected }
                        return input + 1
                    }
                } catch {
                    return -1
                }
            }
            """,
            functionName: "genericRethrowsClosureForwarding",
            moduleName: "HelixGenericRethrowsClosureForwardingFixture"
        )

        #expect(try invoke(fixture, [integer(8), .bool(false)]) == integer(9))
        #expect(try invoke(fixture, [integer(8), .bool(true)]) == integer(-1))
    }

    @Test("Generic closure helpers support distinct input and output types")
    func lowersMultiParameterGenericClosureForwarding() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func map<Input, Output>(
                _ input: Input,
                transform: (Input) -> Output
            ) -> Output {
                transform(input)
            }

            public func multiParameterGenericClosureForwarding(
                _ value: Int
            ) -> Bool {
                map(value) { $0 > 3 }
            }
            """,
            functionName: "multiParameterGenericClosureForwarding",
            moduleName: "HelixMultiParameterGenericClosureForwardingFixture"
        )

        #expect(try invoke(fixture, [integer(5)]) == .bool(true))
        #expect(try invoke(fixture, [integer(2)]) == .bool(false))
    }

    @Test("Constrained generic helpers retain concrete closure forwarding")
    func lowersConstrainedGenericClosureForwarding() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func forward<Value: Equatable>(
                _ value: Value,
                transform: (Value) -> Value
            ) -> Value {
                transform(value)
            }

            public func constrainedGenericClosureForwarding(
                _ value: Int
            ) -> Int {
                forward(value) { $0 + 2 }
            }
            """,
            functionName: "constrainedGenericClosureForwarding",
            moduleName: "HelixConstrainedGenericClosureFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(6))
    }

    @Test("Recursive generic helpers reuse one concrete closure specialization")
    func lowersRecursiveGenericClosureForwarding() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func repeatApply<Value>(
                _ value: Value,
                count: Int,
                transform: (Value) -> Value
            ) -> Value {
                if count == 0 { return value }
                return repeatApply(
                    transform(value),
                    count: count - 1,
                    transform: transform
                )
            }

            public func recursiveGenericClosureForwarding(_ value: Int) -> Int {
                repeatApply(value, count: 3) { $0 + 2 }
            }
            """,
            functionName: "recursiveGenericClosureForwarding",
            moduleName: "HelixRecursiveGenericClosureFixture"
        )

        #expect(try invoke(fixture, [integer(5)]) == integer(11))
    }

    @Test("Generic specialization never rewrites user string literals")
    func preservesGenericParameterNamesInsideStrings() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func apply<Value>(
                _ value: Value,
                transform: (Value) -> Int
            ) -> Int {
                "Value".count + transform(value)
            }

            public func genericParameterNameInsideString(_ value: Int) -> Int {
                apply(value) { $0 }
            }
            """,
            functionName: "genericParameterNameInsideString",
            moduleName: "HelixGenericParameterStringFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(9))
    }

    @Test("One specialization supports both direct and closure-value uses")
    func lowersMixedGenericFunctionUses() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func identity<Value>(_ value: Value) -> Value {
                value
            }

            public func mixedGenericFunctionUses(_ value: Int) -> Int {
                let transform: (Int) -> Int = identity
                return identity(value) + transform(value)
            }
            """,
            functionName: "mixedGenericFunctionUses",
            moduleName: "HelixMixedGenericFunctionUseFixture"
        )

        #expect(try invoke(fixture, [integer(6)]) == integer(12))
    }

    @Test("Image generic helpers do not capture standard-library intrinsics")
    func preservesGenericStandardLibraryIntrinsicRouting() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func apply<Value>(
                _ value: Value,
                transform: (Value) -> Value
            ) -> Value {
                transform(value)
            }

            public func genericAndArrayIntrinsic(_ value: Int) -> Int {
                let values = [value, value + 1].map { $0 + 1 }
                return apply(values[0]) { $0 + values.count }
            }
            """,
            functionName: "genericAndArrayIntrinsic",
            moduleName: "HelixGenericArrayIntrinsicFixture"
        )

        #expect(try invoke(fixture, [integer(5)]) == integer(8))
    }

    @Test("Recursive local functions can also form closure values")
    func lowersRecursiveLocalFunctionReferences() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func recursiveLocalFunctionReference(
                _ value: Int,
                _ seed: Int
            ) -> Int {
                var total = seed
                func accumulate(_ remaining: Int) -> Int {
                    total += remaining
                    if remaining == 0 { return total }
                    return accumulate(remaining - 1)
                }
                let transform: (Int) -> Int = accumulate
                return accumulate(1) + transform(value) + total
            }
            """,
            functionName: "recursiveLocalFunctionReference",
            moduleName: "HelixRecursiveLocalFunctionReferenceFixture"
        )

        #expect(
            try invoke(fixture, [integer(3), integer(2)]) == integer(21)
        )
    }

    @Test("Synchronous MainActor closure values retain their isolation")
    @MainActor
    func lowersMainActorClosureValues() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @MainActor
            public func mainActorClosureValue(_ value: Int) -> Int {
                let transform: @MainActor (Int) -> Int = { $0 + 1 }
                return transform(value)
            }
            """,
            functionName: "mainActorClosureValue",
            moduleName: "HelixMainActorClosureValueFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(5))
    }

    @Test("Operators and overloads form contextually typed closure values")
    func lowersOperatorAndOverloadedFunctionReferences() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private func convert(_ value: Int) -> Int { value + 2 }
            private func convert(_ value: String) -> String { value + "!" }

            public func operatorAndOverloadedReferences(
                _ value: Int,
                _ flag: Bool
            ) -> Int {
                let add: (Int, Int) -> Int = (+)
                let negate: (Bool) -> Bool = (!)
                let maximum: (Int, Int) -> Int = Swift.max
                let transform: (Int) -> Int = convert
                return add(transform(value), maximum(2, 3))
                    + (negate(flag) ? 1 : 0)
            }
            """,
            functionName: "operatorAndOverloadedReferences",
            moduleName: "HelixOperatorFunctionReferenceFixture"
        )

        #expect(
            try invoke(fixture, [integer(4), .bool(false)]) == integer(10)
        )
        #expect(
            try invoke(fixture, [integer(4), .bool(true)]) == integer(9)
        )
    }

    @Test("Lazy, inout, conditional, and if-expression closure variables compose")
    func lowersClosureVariableForms() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            private func replace(_ body: inout (Int) -> Int) {
                body = { $0 * 2 }
            }

            public func closureVariableForms(
                _ value: Int,
                _ useIncrement: Bool
            ) -> Int {
                var seed = 2
                lazy var lazyTransform: (Int) -> Int = { $0 + seed }
                seed = 3

                var mutable = { (input: Int) in input + 1 }
                replace(&mutable)

                let conditional: (Int) -> Int = useIncrement
                    ? { $0 + 1 }
                    : { $0 * 3 }
                let expression: (Int) -> Int = if useIncrement {
                    { $0 + 2 }
                } else {
                    { $0 - 2 }
                }
                return lazyTransform(value)
                    + mutable(value)
                    + conditional(value)
                    + expression(value)
            }
            """,
            functionName: "closureVariableForms",
            moduleName: "HelixClosureVariableFormsFixture"
        )

        #expect(
            try invoke(fixture, [integer(4), .bool(true)]) == integer(26)
        )
        #expect(
            try invoke(fixture, [integer(4), .bool(false)]) == integer(29)
        )
    }

    @Test("Unbound instance methods retain curried receiver semantics")
    func lowersUnboundMethodReferences() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Adder {
                let offset: Int
                func apply(_ value: Int) -> Int { value + offset }
            }

            public func unboundMethodReference(
                _ value: Int,
                _ offset: Int
            ) -> Int {
                let method: (Adder) -> (Int) -> Int = Adder.apply
                return method(Adder(offset: offset))(value)
            }
            """,
            functionName: "unboundMethodReference",
            moduleName: "HelixUnboundMethodReferenceFixture"
        )

        #expect(
            try invoke(fixture, [integer(3), integer(2)]) == integer(5)
        )
    }

    @Test("Pure file and static closure constants retain callable identity")
    func lowersImmutableClosureConstants() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private let fileTransform: (Int) -> Int = { $0 + 2 }

            private enum Routes {
                static let transform: (Int) -> Int = { $0 * 3 }
            }

            public func immutableClosureConstants(_ value: Int) -> Int {
                fileTransform(value) + Routes.transform(value)
            }
            """,
            functionName: "immutableClosureConstants",
            moduleName: "HelixImmutableClosureConstantsFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(18))
    }

    @Test("Lazy unowned closure properties follow native Swift lifetime semantics")
    func lowersLazyUnownedClosureProperties() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Counter {
                let offset: Int

                init(offset: Int) {
                    self.offset = offset
                }

                lazy var transform: (Int) -> Int = { [unowned self] in
                    $0 + self.offset
                }
            }

            public func lazyUnownedClosureProperty(
                _ value: Int,
                _ retainOwner: Bool
            ) -> Int {
                if retainOwner {
                    let counter = Counter(offset: 2)
                    let result = counter.transform(value)
                    return result + counter.offset - counter.offset
                }
                return Counter(offset: 2).transform(value)
            }
            """,
            functionName: "lazyUnownedClosureProperty",
            moduleName: "HelixLazyUnownedClosurePropertyFixture"
        )

        #expect(
            try invoke(fixture, [integer(3), .bool(true)]) == integer(5)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(3), .bool(false)]
            ) == .trapped(.danglingUnownedReference)
        )
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
