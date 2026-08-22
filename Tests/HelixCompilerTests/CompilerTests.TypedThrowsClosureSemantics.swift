import HelixBytecode
import HelixCore
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift typed-throws closure semantics")
struct TypedThrowsClosureSemantics {
    @Test("Nonescaping and generic closures preserve their concrete Failure channel")
    func lowersConcreteTypedThrowsFlow() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error {
                case rejected(Int)
                case stopped
            }

            @inline(never)
            private func reject(_ value: Int) throws(Failure) -> Never {
                throw .rejected(value)
            }

            @inline(never)
            private func invoke(
                _ body: () throws(Failure) -> Int
            ) throws(Failure) -> Int {
                try body()
            }

            @inline(never)
            private func forward<Value>(
                _ value: Value,
                transform: (Value) throws(Failure) -> Int
            ) throws(Failure) -> Int {
                try transform(value)
            }

            public func concreteTypedThrows(
                _ value: Int,
                _ shouldFail: Bool
            ) -> Int {
                let body: () throws(Failure) -> Int = {
                    if shouldFail { try reject(value) }
                    return try forward(value) { $0 + 1 }
                }
                do {
                    return try invoke(body)
                } catch .rejected(let payload) {
                    return -payload
                } catch .stopped {
                    return -2
                } catch {
                    return -100
                }
            }
            """,
            functionName: "concreteTypedThrows",
            moduleName: "HelixConcreteTypedThrowsFixture"
        )

        let failure = Bytecode.LocalTypeKey(
            rawValue: "Failure"
        )
        #expect(fixture.image.module.capabilities.contains(.typedThrowsV1))
        #expect(fixture.image.module.localTypes.contains {
            $0.key.rawValue.hasSuffix(failure.rawValue) && $0.conformsToError
        })
        #expect(fixture.image.module.functions.contains {
            $0.thrownType.map {
                guard case let .local(key) = $0 else { return false }
                return key.rawValue.hasSuffix(failure.rawValue)
            } == true
        })
        #expect(
            try invoke(fixture, [integer(4), .bool(false)]) == integer(5)
        )
        #expect(
            try invoke(fixture, [integer(4), .bool(true)]) == integer(-4)
        )
    }

    @Test("Escaping typed closures retain Failure through aggregate storage")
    func lowersEscapingTypedThrowsStorage() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error {
                case rejected(Int)
            }

            private struct Handler {
                let run: (Int) throws(Failure) -> Int
            }

            @inline(never)
            private func reject(_ value: Int) throws(Failure) -> Never {
                throw .rejected(value)
            }

            @inline(never)
            private func makeHandler(_ offset: Int) -> Handler {
                let run: (Int) throws(Failure) -> Int = { value in
                    if value < 0 { try reject(value) }
                    return value + offset
                }
                return Handler(run: run)
            }

            public func storedTypedThrows(_ value: Int) -> Int {
                let handlers = [makeHandler(2), makeHandler(5)]
                do {
                    return try handlers[1].run(value)
                } catch .rejected(let payload) {
                    return payload - 1
                } catch {
                    return -100
                }
            }
            """,
            functionName: "storedTypedThrows",
            moduleName: "HelixStoredTypedThrowsFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(9))
        #expect(try invoke(fixture, [integer(-3)]) == integer(-4))
    }

    @Test("Typed closures erase to any Error only through a Swift thunk")
    func lowersTypedToExistentialThrowingConversion() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error {
                case rejected(Int)
            }

            @inline(never)
            private func reject(_ value: Int) throws(Failure) -> Never {
                throw .rejected(value)
            }

            public func erasedTypedThrows(_ value: Int) -> Int {
                let typed: (Int) throws(Failure) -> Int = { input in
                    if input < 0 { try reject(input) }
                    return input + 3
                }
                let erased: (Int) throws -> Int = typed
                do {
                    return try erased(value)
                } catch let failure as Failure {
                    switch failure {
                    case .rejected(let payload): return payload - 2
                    }
                } catch {
                    return -100
                }
            }
            """,
            functionName: "erasedTypedThrows",
            moduleName: "HelixErasedTypedThrowsFixture"
        )

        #expect(fixture.image.module.capabilities.contains(.structuredErrorsV1))
        #expect(fixture.image.module.capabilities.contains(.typedThrowsV1))
        #expect(try invoke(fixture, [integer(4)]) == integer(7))
        #expect(try invoke(fixture, [integer(-3)]) == integer(-5))
    }

    @Test("Typed closures traverse standard higher-order APIs through proven error ABIs")
    func lowersTypedSequenceHigherOrderClosures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error {
                case rejected(Int)
            }

            @inline(never)
            private func reject(_ value: Int) throws(Failure) -> Never {
                throw .rejected(value)
            }

            public func typedSequenceHigherOrder(
                _ value: Int,
                _ shouldFail: Bool
            ) -> Int {
                let transform: (Int) throws(Failure) -> Int = { input in
                    if shouldFail && input == value + 1 {
                        try reject(input)
                    }
                    return input * 2
                }
                let predicate: (Int) throws(Failure) -> Bool = { input in
                    if shouldFail && input == value + 2 {
                        try reject(input)
                    }
                    return input % 2 == 0
                }
                let combine: (Int, Int) throws(Failure) -> Int = {
                    partial, input in
                    if shouldFail && input == value + 3 {
                        try reject(input)
                    }
                    return partial + input
                }
                do {
                    let mapped = try [value, value + 1, value + 2]
                        .map(transform)
                    let filtered = try mapped.filter(predicate)
                    return try filtered.reduce(0, combine)
                } catch let failure as Failure {
                    switch failure {
                    case .rejected(let payload): return -payload
                    }
                } catch {
                    return -100
                }
            }
            """,
            functionName: "typedSequenceHigherOrder",
            moduleName: "HelixTypedSequenceHigherOrderFixture"
        )

        #expect(try invoke(fixture, [integer(2), .bool(false)]) == integer(18))
        #expect(try invoke(fixture, [integer(2), .bool(true)]) == integer(-3))
    }

    @Test("Typed-throws standard-library specializations keep Failure concrete")
    func lowersTypedStandardLibrarySpecializations() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error {
                case rejected(Int)
            }

            @inline(never)
            private func reject(_ value: Int) throws(Failure) -> Never {
                throw .rejected(value)
            }

            public func typedStandardLibraryMap(
                _ value: Int,
                _ shouldFail: Bool
            ) -> Int {
                let transform: (Int) throws(Failure) -> Int = { input in
                    if shouldFail && input == value + 1 {
                        try reject(input)
                    }
                    return input * 3
                }
                do {
                    return try [value, value + 1].map(transform)[1]
                } catch .rejected(let payload) {
                    return -payload
                } catch {
                    return -100
                }
            }
            """,
            functionName: "typedStandardLibraryMap",
            moduleName: "HelixTypedStandardLibraryMapFixture"
        )

        #expect(fixture.image.module.functions.contains { function in
            function.registerTypes.contains { type in
                guard case let .closure(signature) = type,
                      case .local? = signature.thrownType
                else { return false }
                return true
            }
        })
        #expect(try invoke(fixture, [integer(2), .bool(false)]) == integer(9))
        #expect(try invoke(fixture, [integer(2), .bool(true)]) == integer(-3))
    }

    @Test("Typed closures cross Optional and Result error projections through concrete thunks")
    func lowersTypedAlgebraicClosureConversions() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error {
                case rejected(Int)
            }

            @inline(never)
            private func reject(_ value: Int) throws(Failure) -> Never {
                throw .rejected(value)
            }

            public func typedAlgebraicClosures(
                _ value: Int,
                _ mode: Int
            ) -> Int {
                let transform: (Int) throws(Failure) -> Int = { input in
                    if mode == 1 { try reject(input) }
                    return input + 4
                }
                if mode <= 1 {
                    do {
                        return try Optional(value).map(transform) ?? -1
                    } catch let failure as Failure {
                        switch failure {
                        case .rejected(let payload): return -payload
                        }
                    } catch {
                        return -100
                    }
                }

                let work: () throws(Failure) -> Int = {
                    if mode == 3 { try reject(value) }
                    return value + 7
                }
                let result = Result<Int, any Error>(catching: work)
                switch result {
                case .success(let output):
                    return output
                case .failure(let error):
                    guard let failure = error as? Failure else { return -100 }
                    switch failure {
                    case .rejected(let payload): return payload - 10
                    }
                }
            }
            """,
            functionName: "typedAlgebraicClosures",
            moduleName: "HelixTypedAlgebraicClosuresFixture"
        )

        #expect(try invoke(fixture, [integer(3), integer(0)]) == integer(7))
        #expect(try invoke(fixture, [integer(3), integer(1)]) == integer(-3))
        #expect(try invoke(fixture, [integer(3), integer(2)]) == integer(10))
        #expect(try invoke(fixture, [integer(3), integer(3)]) == integer(-7))
    }

    @Test("Typed closures preserve error ABI through mutating and comparator adapters")
    func lowersTypedMutatingHigherOrderClosures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error {
                case rejected(Int)
            }

            @inline(never)
            private func reject(_ value: Int) throws(Failure) -> Never {
                throw .rejected(value)
            }

            public func typedMutatingHigherOrder(
                _ value: Int,
                _ mode: Int
            ) -> Int {
                var values = [value + 2, value, value + 1]
                let remove: (Int) throws(Failure) -> Bool = { _ in
                    if mode == 1 { try reject(value) }
                    return false
                }
                let compare: (Int, Int) throws(Failure) -> Bool = { left, right in
                    if mode == 2 { try reject(value) }
                    return left < right
                }
                let accumulate: (inout Int, Int) throws(Failure) -> Void = {
                    total, input in
                    if mode == 3 { try reject(value) }
                    total += input
                }
                do {
                    try values.removeAll(where: remove)
                    let sorted = try values.sorted(by: compare)
                    return try sorted.reduce(into: 0, accumulate)
                } catch let failure as Failure {
                    switch failure {
                    case .rejected(let payload): return -payload
                    }
                } catch {
                    return -100
                }
            }
            """,
            functionName: "typedMutatingHigherOrder",
            moduleName: "HelixTypedMutatingHigherOrderFixture"
        )

        #expect(try invoke(fixture, [integer(3), integer(0)]) == integer(12))
        #expect(try invoke(fixture, [integer(3), integer(1)]) == integer(-3))
        #expect(try invoke(fixture, [integer(3), integer(2)]) == integer(-3))
        #expect(try invoke(fixture, [integer(3), integer(3)]) == integer(-3))
    }

    @Test("Typed closures preserve error ABI through split and Dictionary accumulation")
    func lowersTypedSplitAndDictionaryClosures() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error {
                case rejected(Int)
            }

            @inline(never)
            private func reject(_ value: Int) throws(Failure) -> Never {
                throw .rejected(value)
            }

            public func typedSplitAndDictionary(
                _ value: Int,
                _ mode: Int
            ) -> Int {
                let separator: (Int) throws(Failure) -> Bool = { input in
                    if mode == 1 { try reject(value) }
                    return input == 0
                }
                let combine: (Int, Int) throws(Failure) -> Int = { left, right in
                    if mode == 2 { try reject(value) }
                    return left + right
                }
                do {
                    let pieces = try [value, 0, value + 1]
                        .split(whereSeparator: separator)
                    let merged = try Dictionary(
                        [(0, value), (0, value + 1)],
                        uniquingKeysWith: combine
                    )
                    return pieces.count + (merged[0] ?? 0)
                } catch let failure as Failure {
                    switch failure {
                    case .rejected(let payload): return -payload
                    }
                } catch {
                    return -100
                }
            }
            """,
            functionName: "typedSplitAndDictionary",
            moduleName: "HelixTypedSplitAndDictionaryFixture"
        )

        #expect(try invoke(fixture, [integer(3), integer(0)]) == integer(9))
        #expect(try invoke(fixture, [integer(3), integer(1)]) == integer(-3))
        #expect(try invoke(fixture, [integer(3), integer(2)]) == integer(-3))
    }

    @Test("A failed forced try preserves a concrete closure error diagnostic")
    func lowersTypedClosureForcedTry() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error {
                case rejected(Int)
            }

            @inline(never)
            private func reject(_ value: Int) throws(Failure) -> Never {
                throw .rejected(value)
            }

            public func typedClosureForcedTry(_ value: Int) -> Int {
                let operation: () throws(Failure) -> Int = {
                    if value < 0 { try reject(value) }
                    return value + 1
                }
                return try! operation()
            }
            """,
            functionName: "typedClosureForcedTry",
            moduleName: "HelixTypedClosureForcedTryFixture"
        )

        #expect(try invoke(fixture, [integer(3)]) == integer(4))
        let failed = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: [try integer(-3)]
        )
        guard case let .trapped(.sourceFailure(prefix, detail)) = failed else {
            Issue.record("typed try! did not preserve a source failure: \(failed)")
            return
        }
        #expect(prefix == "try! expression unexpectedly raised an error")
        #expect(detail.contains("Failure"))
        #expect(detail.hasSuffix(".rejected"))
    }

    @Test("Optional try discards a concrete closure error without erasing its ABI")
    func lowersTypedClosureOptionalTry() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error {
                case rejected(Int)
            }

            @inline(never)
            private func reject(_ value: Int) throws(Failure) -> Never {
                throw .rejected(value)
            }

            public func typedClosureOptionalTry(_ value: Int) -> Int {
                let operation: () throws(Failure) -> Int = {
                    if value < 0 { try reject(value) }
                    return value + 2
                }
                return (try? operation()) ?? -1
            }
            """,
            functionName: "typedClosureOptionalTry",
            moduleName: "HelixTypedClosureOptionalTryFixture"
        )

        #expect(try invoke(fixture, [integer(3)]) == integer(5))
        #expect(try invoke(fixture, [integer(-3)]) == integer(-1))
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
