import Foundation
import HelixBytecode
import HelixCore
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
        let fields = try file.typeEnvironment.structFields(
            for: .init(rawValue: "Callbacks")
        )

        #expect(fields.count == 2)
        #expect(file.typeEnvironment.isStructFactory(symbol))
    }

    @Test("Only pure opaque struct factories are compiler-elided")
    func recognizesOpaqueStructFactoryBoundaries() {
        let pure = CanonicalSIL.Function(
            mangledName: "$s7Fixture6HiddenV5valueACSi_tcfC",
            loweredType: "@convention(method) (Int, @thin Hidden.Type) -> Hidden",
            body: """
            bb0(%0 : $Int, %1 : $@thin Hidden.Type):
              %2 = struct $Hidden (%0)
              return %2
            """
        )
        let custom = CanonicalSIL.Function(
            mangledName: "$s7Fixture6HiddenVyACSi_tcfC",
            loweredType: "@convention(method) (Int, @thin Hidden.Type) -> Hidden",
            body: """
            bb0(%0 : $Int, %1 : $@thin Hidden.Type):
              %2 = integer_literal $Builtin.Int64, 1
              %3 = struct_extract %0, #Int._value
              %4 = builtin "sadd_with_overflow_Int64"(%3, %2, %2) : $(Builtin.Int64, Builtin.Int1)
              %5 = tuple_extract %4, 0
              %6 = struct $Int (%5)
              %7 = struct $Hidden (%6)
              return %7
            """
        )

        #expect(CanonicalSIL.TypeEnvironment.empty.isOpaqueStructFactory(pure))
        #expect(!CanonicalSIL.TypeEnvironment.empty.isOpaqueStructFactory(custom))
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

    @Test("Nested noescape scopes preserve the outer callback lifetime")
    func lowersNestedWithoutActuallyEscaping() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            @inline(never)
            func nestedScope(_ callback: () -> Int) -> (Int, Int) {
                let first = withoutActuallyEscaping(callback) { outer in
                    withoutActuallyEscaping(outer) { inner in
                        inner()
                    }
                }
                return (first, callback())
            }

            public func nestedScopedClosure(_ value: Int) -> (Int, Int) {
                nestedScope { value + 2 }
            }
            """,
            functionName: "nestedScopedClosure",
            moduleName: "HelixNestedScopedClosureFixture"
        )

        #expect(
            try invoke(fixture, [integer(5)])
                == .tuple([try integer(7), try integer(7)])
        )
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

    @Test("Weak capture lists preserve live references and zero dead references")
    func lowersWeakReferenceCaptures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }

                func callback() -> () -> Int {
                    { [weak self] in self?.value ?? -1 }
                }
            }

            @inline(never)
            private func makeExpiredCallback(_ value: Int) -> () -> Int {
                let owner = Owner(value)
                return owner.callback()
            }

            public func weakReferenceCapture(
                _ value: Int,
                _ keepAlive: Bool
            ) -> Int {
                if keepAlive {
                    let owner = Owner(value)
                    let callback = owner.callback()
                    return callback()
                }
                return makeExpiredCallback(value)()
            }
            """,
            functionName: "weakReferenceCapture",
            moduleName: "HelixWeakReferenceCaptureFixture"
        )

        #expect(try invoke(fixture, [integer(9), .bool(true)]) == integer(9))
        #expect(try invoke(fixture, [integer(9), .bool(false)]) == integer(-1))
    }

    @Test("Weak captures zero when the final strong value dies in the same frame")
    func releasesWeakCaptureReferentsWithinFrame() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            public func weakReferenceClearsInFrame(_ value: Int) -> Int {
                var owner: Owner? = Owner(value)
                let callback = { [weak owner] in owner?.value ?? -1 }
                owner = nil
                return callback()
            }
            """,
            functionName: "weakReferenceClearsInFrame",
            moduleName: "HelixWeakReferenceLifetimeFixture"
        )

        #expect(try invoke(fixture, [integer(13)]) == integer(-1))
    }

    @Test("Destroyed escaping closure values release strong captures in-frame")
    func releasesStrongCapturesAtClosureLifetimeEnd() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            @inline(never)
            private func invokeEscaping(_ callback: @escaping () -> Int) -> Int {
                callback()
            }

            @inline(never)
            private func makeObserver(_ owner: Owner) -> () -> Int {
                { [weak owner] in owner?.value ?? -1 }
            }

            public func closureCaptureDiesInFrame(_ value: Int) -> Int {
                let observe: () -> Int
                do {
                    let owner = Owner(value)
                    observe = makeObserver(owner)
                    let retaining = { owner.value }
                    _ = invokeEscaping(retaining)
                }
                return observe()
            }
            """,
            functionName: "closureCaptureDiesInFrame",
            moduleName: "HelixClosureCaptureLifetimeFixture"
        )

        #expect(try invoke(fixture, [integer(17)]) == integer(-1))
    }

    @Test("Aggregate capture temporaries release their reference roots in-frame")
    func releasesAggregateCaptureTemporaries() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            @inline(never)
            private func invokeEscaping(_ callback: @escaping () -> Int) -> Int {
                callback()
            }

            @inline(never)
            private func makeObserver(_ owner: Owner) -> () -> Int {
                { [weak owner] in owner?.value ?? -1 }
            }

            public func aggregateCaptureDiesInFrame(_ value: Int) -> Int {
                let observe: () -> Int
                do {
                    let owner = Owner(value)
                    observe = makeObserver(owner)
                    let retaining = {
                        [captured = Optional(owner)] in
                        captured?.value ?? -2
                    }
                    _ = invokeEscaping(retaining)
                }
                return observe()
            }
            """,
            functionName: "aggregateCaptureDiesInFrame",
            moduleName: "HelixAggregateCaptureLifetimeFixture"
        )

        #expect(try invoke(fixture, [integer(19)]) == integer(-1))
    }

    @Test("Weak captures observe release through patch-local value aggregates")
    func releasesWeakCaptureReferentsFromStructStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            private struct Holder {
                var owner: Owner?
            }

            public func weakReferenceInStruct(_ value: Int) -> Int {
                var holder = Holder(owner: Owner(value))
                let callback = { [weak captured = holder.owner] in
                    captured?.value ?? -1
                }
                holder.owner = nil
                return callback()
            }
            """,
            functionName: "weakReferenceInStruct",
            moduleName: "HelixWeakReferenceStructLifetimeFixture"
        )

        #expect(try invoke(fixture, [integer(29)]) == integer(-1))
    }

    @Test("Aggregate snapshots keep weak capture referents alive independently")
    func preservesIndependentStructOwners() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            private struct Holder {
                var owner: Owner?
            }

            public func weakReferenceWithSnapshot(_ value: Int) -> Int {
                var holder = Holder(owner: Owner(value))
                let snapshot = holder
                let callback = { [weak captured = holder.owner] in
                    captured?.value ?? -100
                }
                holder.owner = nil
                return callback() + (snapshot.owner?.value ?? -1)
            }
            """,
            functionName: "weakReferenceWithSnapshot",
            moduleName: "HelixWeakReferenceStructSnapshotFixture"
        )

        #expect(try invoke(fixture, [integer(37)]) == integer(74))
    }

    @Test("Tuple snapshots keep weak capture referents alive independently")
    func preservesIndependentTupleOwners() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            public func weakReferenceWithTupleSnapshot(_ value: Int) -> Int {
                var holder: (Owner?, Int) = (Owner(value), 1)
                let snapshot = holder
                let callback = { [weak captured = holder.0] in
                    captured?.value ?? -100
                }
                holder.0 = nil
                return callback() + (snapshot.0?.value ?? -1) + snapshot.1
            }
            """,
            functionName: "weakReferenceWithTupleSnapshot",
            moduleName: "HelixWeakReferenceTupleSnapshotFixture"
        )

        #expect(try invoke(fixture, [integer(43)]) == integer(87))
    }

    @Test("Weak captures observe release through patch-local enum payloads")
    func releasesWeakCaptureReferentsFromEnumStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            private enum Holder {
                case owner(Owner)
                case empty
            }

            @inline(never)
            private func observe(_ holder: Holder) -> () -> Int {
                switch holder {
                case .owner(let owner):
                    return { [weak owner] in owner?.value ?? -1 }
                case .empty:
                    return { -2 }
                }
            }

            public func weakReferenceInEnum(_ value: Int) -> Int {
                var holder = Holder.owner(Owner(value))
                let callback = observe(holder)
                holder = .empty
                return callback()
            }
            """,
            functionName: "weakReferenceInEnum",
            moduleName: "HelixWeakReferenceEnumLifetimeFixture"
        )

        #expect(try invoke(fixture, [integer(41)]) == integer(-1))
    }

    @Test("Weak captures observe release through represented Array storage")
    func releasesWeakCaptureReferentsFromArrayStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            public func weakReferenceInArray(_ value: Int) -> Int {
                var owners = [Owner(value)]
                let callback = { [weak captured = owners[0]] in
                    captured?.value ?? -1
                }
                owners.removeAll()
                return callback()
            }
            """,
            functionName: "weakReferenceInArray",
            moduleName: "HelixWeakReferenceArrayLifetimeFixture"
        )

        #expect(try invoke(fixture, [integer(31)]) == integer(-1))
    }

    @Test("Weak captures observe release through represented Dictionary values")
    func releasesWeakCaptureReferentsFromDictionaryStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            public func weakReferenceInDictionary(_ value: Int) -> Int {
                var owners = ["owner": Owner(value)]
                let callback = { [weak captured = owners["owner"]] in
                    captured?.value ?? -1
                }
                owners.removeAll()
                return callback()
            }
            """,
            functionName: "weakReferenceInDictionary",
            moduleName: "HelixWeakReferenceDictionaryLifetimeFixture"
        )

        #expect(try invoke(fixture, [integer(47)]) == integer(-1))
    }

    @Test("Weak captures observe release through VM-owned Any storage")
    func releasesWeakCaptureReferentsFromAnyStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            public func weakReferenceInAny(_ value: Int) -> Int {
                var erased: Any = Owner(value)
                let callback = { [weak captured = erased as? Owner] in
                    captured?.value ?? -1
                }
                erased = value
                return callback()
            }
            """,
            functionName: "weakReferenceInAny",
            moduleName: "HelixWeakReferenceAnyLifetimeFixture"
        )

        #expect(try invoke(fixture, [integer(53)]) == integer(-1))
    }

    @Test("Weak captures observe release through structured Error storage")
    func releasesWeakCaptureReferentsFromErrorStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            private struct Failure: Error {
                let owner: Owner
            }

            private enum EmptyFailure: Error {
                case empty
            }

            public func weakReferenceInError(_ value: Int) -> Int {
                var failure: any Error = Failure(owner: Owner(value))
                let callback = {
                    [weak captured = (failure as? Failure)?.owner] in
                    captured?.value ?? -1
                }
                failure = EmptyFailure.empty
                return callback()
            }
            """,
            functionName: "weakReferenceInError",
            moduleName: "HelixWeakReferenceErrorLifetimeFixture"
        )

        #expect(try invoke(fixture, [integer(59)]) == integer(-1))
    }

    @Test("Unowned captures load live references and trap safely after death")
    func lowersUnownedReferenceCaptures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }

                func callback() -> () -> Int {
                    { [unowned self] in self.value }
                }
            }

            @inline(never)
            private func makeExpiredCallback(_ value: Int) -> () -> Int {
                let owner = Owner(value)
                return owner.callback()
            }

            public func unownedReferenceCapture(
                _ value: Int,
                _ keepAlive: Bool
            ) -> Int {
                if keepAlive {
                    let owner = Owner(value)
                    let callback = owner.callback()
                    return callback()
                }
                return makeExpiredCallback(value)()
            }
            """,
            functionName: "unownedReferenceCapture",
            moduleName: "HelixUnownedReferenceCaptureFixture"
        )

        #expect(try invoke(fixture, [integer(11), .bool(true)]) == integer(11))
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(11), .bool(false)]
            ) == .trapped(.danglingUnownedReference)
        )
    }

    @Test("Unowned captures trap when the final strong value dies in the same frame")
    func trapsUnownedCaptureAfterInFrameRelease() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            public func unownedReferenceDiesInFrame(_ value: Int) -> Int {
                var owner: Owner? = Owner(value)
                let callback = { [unowned captured = owner!] in
                    captured.value
                }
                owner = nil
                return callback()
            }
            """,
            functionName: "unownedReferenceDiesInFrame",
            moduleName: "HelixUnownedReferenceLifetimeFixture"
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(17)]
            ) == .trapped(.danglingUnownedReference)
        )
    }

    @Test("Optional unowned captures distinguish explicit nil from a dead referent")
    func lowersOptionalUnownedCaptures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            public func optionalUnownedCapture(
                _ value: Int,
                _ createOwner: Bool
            ) -> Int {
                var owner: Owner? = createOwner ? Owner(value) : nil
                let callback = { [unowned captured = owner] in
                    captured?.value ?? -1
                }
                if createOwner {
                    owner = nil
                }
                return callback()
            }
            """,
            functionName: "optionalUnownedCapture",
            moduleName: "HelixOptionalUnownedCaptureFixture"
        )

        #expect(
            try invoke(fixture, [integer(23), .bool(false)]) == integer(-1)
        )
        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [try integer(23), .bool(true)]
            ) == .trapped(.danglingUnownedReference)
        )
    }

    @Test("Unsafe unowned captures fail closed instead of exposing raw references")
    func rejectsUnsafeUnownedCaptures() {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                private final class Owner {
                    let value: Int

                    init(_ value: Int) {
                        self.value = value
                    }
                }

                public func unsafeUnownedCapture(_ value: Int) -> Int {
                    let owner = Owner(value)
                    return { [unowned(unsafe) owner] in owner.value }()
                }
                """,
                functionName: "unsafeUnownedCapture",
                moduleName: "HelixUnsafeUnownedCaptureFixture"
            )
            Issue.record("unsafe unowned capture unexpectedly compiled")
        } catch let error as PatchCompiler.CompilationError {
            guard case let .generatedFunctionUnsupported(_, reason) = error else {
                Issue.record("unexpected unsafe-unowned diagnostic: \(error)")
                return
            }
            #expect(reason.contains("unmanaged reference storage"))
        } catch {
            Issue.record("unexpected unsafe-unowned error: \(error)")
        }
    }

    @Test("Capture lists compose weak and unowned storage generically")
    func lowersMixedNonOwningCaptureLists() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            public func mixedNonOwningCaptures(_ value: Int) -> Int {
                let first = Owner(value)
                let second = Owner(value + 1)
                let callback = { [weak first, unowned second] in
                    (first?.value ?? -100) + second.value
                }
                return callback()
            }
            """,
            functionName: "mixedNonOwningCaptures",
            moduleName: "HelixMixedNonOwningCapturesFixture"
        )

        #expect(try invoke(fixture, [integer(8)]) == integer(17))
    }

    @Test("Weak local variables remain zeroing when captured by a closure")
    func lowersCapturedWeakLocalVariables() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            public func capturedWeakLocal(_ value: Int) -> Int {
                var strong: Owner? = Owner(value)
                weak var observed = strong
                let callback = { observed?.value ?? -1 }
                strong = nil
                return callback()
            }
            """,
            functionName: "capturedWeakLocal",
            moduleName: "HelixCapturedWeakLocalFixture"
        )

        #expect(try invoke(fixture, [integer(19)]) == integer(-1))
    }

    @Test("Captured weak local variables share reassignment with their closure")
    func reassignsCapturedWeakLocalVariables() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private final class Owner {
                let value: Int

                init(_ value: Int) {
                    self.value = value
                }
            }

            public func reassignCapturedWeakLocal(
                _ firstValue: Int,
                _ secondValue: Int,
                _ clear: Bool
            ) -> Int {
                let first = Owner(firstValue)
                let second = Owner(secondValue)
                weak var observed = first
                let callback = {
                    if clear {
                        observed = nil
                    } else {
                        observed = second
                    }
                }
                callback()
                return observed?.value ?? -1
            }
            """,
            functionName: "reassignCapturedWeakLocal",
            moduleName: "HelixReassignedWeakLocalFixture"
        )

        #expect(
            try invoke(fixture, [integer(5), integer(27), .bool(false)])
                == integer(27)
        )
        #expect(
            try invoke(fixture, [integer(5), integer(27), .bool(true)])
                == integer(-1)
        )
    }

    @Test("Weak captures preserve frozen native reference identity end to end")
    func lowersWeakNativeReferenceCaptures() throws {
        let typeID = Core.TypeID(rawValue: .sha256("Foundation.NSObject"))
        let layout = Core.Digest.sha256("Foundation.NSObject.layout.v1")
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            import Foundation

            public func weakNativeReferenceCapture(_ object: NSObject) -> Bool {
                let callback = { [weak object] in
                    switch object {
                    case .some: true
                    case .none: false
                    }
                }
                return callback()
            }
            """,
            functionName: "weakNativeReferenceCapture",
            moduleName: "HelixWeakNativeReferenceCaptureFixture",
            nativeTypes: [
                .init(
                    id: typeID,
                    canonicalName: "Foundation.NSObject",
                    kind: .reference,
                    layoutFingerprint: layout,
                    isCopyable: true,
                    isEmittedToDevice: true,
                    estimatedSize: 8
                ),
            ]
        )
        let operations = VM.NativeTypeOperations.reference(
            id: typeID,
            canonicalName: "Foundation.NSObject",
            layoutFingerprint: layout,
            estimatedSize: 8,
            estimatedByteCount: { (_: NSObject) in 8 }
        )
        let object = NSObject()
        let boxed = try operations.box(object)

        #expect(
            VM.Interpreter(
                nativeTypeCatalog: try VM.NativeTypeCatalog([operations])
            ).invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [.native(boxed)]
            ) == .returned(.bool(true))
        )
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
