import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift algebraic container semantics")
struct AlgebraicSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    private struct Probe: Sendable {
        var name: String
        var source: String
        var scenarios: [Scenario]
        var requiredDisassembly: [String] = []
        var forbiddenDisassembly: [String] = []
    }

    @Test("Optional map and flatMap share selected-case transformation")
    func lowersOptionalTransforms() throws {
        try run([
            Probe(
                name: "flatMappedOptional",
                source: """
                public func flatMappedOptional(_ value: Int) -> Int? {
                    let source: Int? = value == 0 ? nil : value
                    return source.flatMap { input in
                        input > 0 ? input * 2 : nil
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(3)],
                        expected: .returned(.optional(try integer(6)))
                    ),
                    .init(
                        arguments: [try integer(-2)],
                        expected: .returned(.optional(nil))
                    ),
                    .init(
                        arguments: [try integer(0)],
                        expected: .returned(.optional(nil))
                    ),
                ]
            ),
            Probe(
                name: "safelyFlatMappedOptional",
                source: """
                enum OptionalTransformFailure: Error { case negative }

                public func safelyFlatMappedOptional(_ value: Int) -> Int {
                    do {
                        let source: Int? = value == 0 ? nil : value
                        return try source.flatMap { input in
                            if input < 0 {
                                throw OptionalTransformFailure.negative
                            }
                            return input > 10 ? nil : input + 1
                        } ?? -1
                    } catch {
                        return -2
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(2)],
                        expected: .returned(try integer(3))
                    ),
                    .init(
                        arguments: [try integer(0)],
                        expected: .returned(try integer(-1))
                    ),
                    .init(
                        arguments: [try integer(11)],
                        expected: .returned(try integer(-1))
                    ),
                    .init(
                        arguments: [try integer(-1)],
                        expected: .returned(try integer(-2))
                    ),
                ]
            ),
            Probe(
                name: "flatMappedOptionalToVoid",
                source: """
                public func flatMappedOptionalToVoid(_ present: Bool) -> Bool {
                    let source: Int? = present ? 1 : nil
                    let mapped: Void? = source.flatMap { _ in () }
                    switch mapped {
                    case .some: return true
                    case .none: return false
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
        ])
    }

    @Test("Result transforms select either payload side and preserve the other")
    func lowersResultTransforms() throws {
        try run([
            Probe(
                name: "mappedResultError",
                source: """
                enum SourceMapFailure: Error { case rejected(Int) }
                enum NormalizedMapFailure: Error { case rejected(Int) }

                public func mappedResultError(_ value: Int) -> Int {
                    let source: Result<Int, SourceMapFailure> = value >= 0
                        ? .success(value)
                        : .failure(.rejected(-value))
                    let mapped = source.mapError { failure in
                        switch failure {
                        case let .rejected(code):
                            return NormalizedMapFailure.rejected(code + 10)
                        }
                    }
                    switch mapped {
                    case let .success(output): return output
                    case let .failure(.rejected(code)): return -code
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(3)],
                        expected: .returned(try integer(3))
                    ),
                    .init(
                        arguments: [try integer(-2)],
                        expected: .returned(try integer(-12))
                    ),
                ]
            ),
            Probe(
                name: "flatMappedResult",
                source: """
                enum FlatMapFailure: Error {
                    case upstream
                    case rejected
                }

                public func flatMappedResult(_ value: Int) -> Int {
                    let source: Result<Int, FlatMapFailure> = value < 0
                        ? .failure(.upstream)
                        : .success(value)
                    let mapped = source.flatMap { input in
                        input == 0
                            ? .failure(.rejected)
                            : .success(input * 2)
                    }
                    switch mapped {
                    case let .success(output): return output
                    case .failure(.upstream): return -10
                    case .failure(.rejected): return -20
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(3)],
                        expected: .returned(try integer(6))
                    ),
                    .init(
                        arguments: [try integer(0)],
                        expected: .returned(try integer(-20))
                    ),
                    .init(
                        arguments: [try integer(-1)],
                        expected: .returned(try integer(-10))
                    ),
                ]
            ),
            Probe(
                name: "flatMappedResultError",
                source: """
                enum RecoverableFailure: Error { case rejected(Int) }
                enum TerminalFailure: Error { case rejected(Int) }

                public func flatMappedResultError(_ value: Int) -> Int {
                    let source: Result<Int, RecoverableFailure> = value >= 0
                        ? .success(value)
                        : .failure(.rejected(-value))
                    let mapped: Result<Int, TerminalFailure> = source
                        .flatMapError { failure in
                            switch failure {
                            case .rejected(1): return .success(99)
                            case let .rejected(code):
                                return .failure(.rejected(code + 100))
                            }
                        }
                    switch mapped {
                    case let .success(output): return output
                    case let .failure(.rejected(code)): return -code
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(3)],
                        expected: .returned(try integer(3))
                    ),
                    .init(
                        arguments: [try integer(-1)],
                        expected: .returned(try integer(99))
                    ),
                    .init(
                        arguments: [try integer(-2)],
                        expected: .returned(try integer(-102))
                    ),
                ]
            ),
            Probe(
                name: "flatMappedResultToVoid",
                source: """
                enum UnitFlatMapFailure: Error { case rejected }

                public func flatMappedResultToVoid(_ succeeds: Bool) -> Bool {
                    let source: Result<Int, UnitFlatMapFailure> = succeeds
                        ? .success(1)
                        : .failure(.rejected)
                    let mapped: Result<Void, UnitFlatMapFailure> = source
                        .flatMap { _ in .success(()) }
                    switch mapped {
                    case .success: return true
                    case .failure: return false
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
        ])
    }

    @Test("Result(catching:) builds cases from verified closure continuations")
    func lowersResultCatching() throws {
        #expect(
            CanonicalSIL.SwiftCoreIntrinsic(
                mangledName:
                    "$ss6ResultOsRi_zrlE8catchingAByxq_Gxyq_YKXE_tcfC"
            ) == .algebraic(.resultCatching)
        )
        try run([
            Probe(
                name: "caughtIntegerResult",
                source: """
                enum IntegerCatchingFailure: Error { case rejected(Int) }

                func integerCatchingLeaf(_ value: Int) throws -> Int {
                    guard value >= 0 else {
                        throw IntegerCatchingFailure.rejected(value)
                    }
                    return value + 10
                }

                public func caughtIntegerResult(_ value: Int) -> (Int, Bool) {
                    var calls = 0
                    let result = Result {
                        calls += 1
                        return try integerCatchingLeaf(value)
                    }
                    return switch result {
                    case let .success(output): (output + calls, true)
                    case .failure: (calls, false)
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(2)],
                        expected: .returned(
                            .tuple([try integer(13), .bool(true)])
                        )
                    ),
                    .init(
                        arguments: [try integer(-2)],
                        expected: .returned(
                            .tuple([try integer(1), .bool(false)])
                        )
                    ),
                ],
                requiredDisassembly: ["closure_try_apply", "make_enum"],
                forbiddenDisassembly: ["native_apply"]
            ),
            Probe(
                name: "caughtStringResult",
                source: """
                enum StringCatchingFailure: Error { case rejected }

                func stringCatchingLeaf(
                    _ value: String,
                    _ fails: Bool
                ) throws -> String {
                    guard !fails else { throw StringCatchingFailure.rejected }
                    return value + "!"
                }

                public func caughtStringResult(
                    _ value: String,
                    _ fails: Bool
                ) -> String {
                    let result = Result {
                        try stringCatchingLeaf(value, fails)
                    }
                    return switch result {
                    case let .success(output): output
                    case .failure: "failed"
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.string("ok"), .bool(false)],
                        expected: .returned(.string("ok!"))
                    ),
                    .init(
                        arguments: [.string("ok"), .bool(true)],
                        expected: .returned(.string("failed"))
                    ),
                ]
            ),
            Probe(
                name: "caughtVoidResult",
                source: """
                enum VoidCatchingFailure: Error { case rejected }

                func voidCatchingLeaf(_ fails: Bool) throws {
                    guard !fails else { throw VoidCatchingFailure.rejected }
                }

                public func caughtVoidResult(_ fails: Bool) -> Bool {
                    let result = Result { try voidCatchingLeaf(fails) }
                    return switch result {
                    case .success: true
                    case .failure: false
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
            Probe(
                name: "caughtTupleResult",
                source: """
                enum TupleCatchingFailure: Error { case rejected }

                func tupleCatchingLeaf(
                    _ value: Int,
                    _ fails: Bool
                ) throws -> (Int, Bool) {
                    guard !fails else { throw TupleCatchingFailure.rejected }
                    return (value + 1, true)
                }

                public func caughtTupleResult(
                    _ value: Int,
                    _ fails: Bool
                ) -> Int {
                    let result = Result {
                        try tupleCatchingLeaf(value, fails)
                    }
                    return switch result {
                    case let .success((output, accepted)):
                        accepted ? output : -2
                    case .failure: -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(4), .bool(false)],
                        expected: .returned(try integer(5))
                    ),
                    .init(
                        arguments: [try integer(4), .bool(true)],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
            Probe(
                name: "caughtErrorPayload",
                source: """
                enum PayloadCatchingFailure: Error { case rejected(Int) }

                func payloadCatchingLeaf(_ value: Int) throws -> Int {
                    guard value >= 0 else {
                        throw PayloadCatchingFailure.rejected(-value)
                    }
                    return value
                }

                public func caughtErrorPayload(_ value: Int) -> Int {
                    let result = Result { try payloadCatchingLeaf(value) }
                    return switch result {
                    case let .success(output): output
                    case let .failure(error as PayloadCatchingFailure):
                        switch error {
                        case let .rejected(code): -code
                        }
                    case .failure: -999
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(3)],
                        expected: .returned(try integer(3))
                    ),
                    .init(
                        arguments: [try integer(-4)],
                        expected: .returned(try integer(-4))
                    ),
                ]
            ),
        ])
    }

    @Test("Patch-local aggregates store managed Error existentials generically")
    func storesErrorExistentialsInLocalAggregates() throws {
        try run([
            Probe(
                name: "localErrorAggregate",
                source: """
                enum AggregateFailure: Error { case rejected(Int) }

                struct ErrorEnvelope {
                    var failure: any Error
                }

                enum ErrorSlot {
                    case empty
                    case wrapped(any Error)
                }

                public func localErrorAggregate(_ value: Int) -> Int {
                    let envelope = ErrorEnvelope(
                        failure: AggregateFailure.rejected(value)
                    )
                    let slot: ErrorSlot = value == 0
                        ? .empty
                        : .wrapped(envelope.failure)
                    return switch slot {
                    case .empty: 0
                    case let .wrapped(error as AggregateFailure):
                        switch error {
                        case let .rejected(code): code + 1
                        }
                    case .wrapped: -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(0)],
                        expected: .returned(try integer(0))
                    ),
                    .init(
                        arguments: [try integer(4)],
                        expected: .returned(try integer(5))
                    ),
                ],
                requiredDisassembly: ["local_struct", "local_enum", "make_error"],
                forbiddenDisassembly: ["native_apply"]
            ),
        ])
    }

    @Test("Result.get projects success and failure to their exact CFG edges")
    func lowersResultGet() throws {
        try run([
            Probe(
                name: "unwrappedResult",
                source: """
                enum GetFailure: Error { case rejected }

                public func unwrappedResult(_ value: Int) throws -> Int {
                    let source: Result<Int, GetFailure> = value >= 0
                        ? .success(value + 1)
                        : .failure(.rejected)
                    return try source.get()
                }
                """,
                scenarios: [
                    .init(
                        arguments: [try integer(2)],
                        expected: .returned(try integer(3))
                    ),
                    .init(
                        arguments: [try integer(-1)],
                        expected: .businessError("GetFailure.rejected")
                    ),
                ]
            ),
            Probe(
                name: "caughtResultGet",
                source: """
                enum CaughtGetFailure: Error { case rejected }

                public func caughtResultGet(_ succeeds: Bool) -> Int {
                    let source: Result<Int, CaughtGetFailure> = succeeds
                        ? .success(7)
                        : .failure(.rejected)
                    do {
                        return try source.get()
                    } catch {
                        return -1
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(try integer(7))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(try integer(-1))
                    ),
                ]
            ),
            Probe(
                name: "unwrappedVoidResult",
                source: """
                enum VoidGetFailure: Error { case rejected }

                public func unwrappedVoidResult(_ succeeds: Bool) -> Bool {
                    let source: Result<Void, VoidGetFailure> = succeeds
                        ? .success(())
                        : .failure(.rejected)
                    do {
                        try source.get()
                        return true
                    } catch {
                        return false
                    }
                }
                """,
                scenarios: [
                    .init(
                        arguments: [.bool(true)],
                        expected: .returned(.bool(true))
                    ),
                    .init(
                        arguments: [.bool(false)],
                        expected: .returned(.bool(false))
                    ),
                ]
            ),
        ])
    }

    private func run(_ probes: [Probe]) throws {
        var failures: [String] = []
        for probe in probes {
            do {
                let fixture = try FrontendExecutionHarness.compile(
                    source: probe.source,
                    functionName: probe.name,
                    moduleName: "HelixAlgebraic_\(probe.name)"
                )
                let disassembly = Bytecode.Disassembler.disassemble(
                    fixture.image.module
                )
                for required in probe.requiredDisassembly
                    where !disassembly.contains(required) {
                    failures.append(
                        "\(probe.name): missing HLBC instruction \(required)"
                    )
                }
                for forbidden in probe.forbiddenDisassembly
                    where disassembly.contains(forbidden) {
                    failures.append(
                        "\(probe.name): unexpected HLBC instruction \(forbidden)"
                    )
                }
                for (index, scenario) in probe.scenarios.enumerated() {
                    let result = VM.Interpreter().invoke(
                        entry: fixture.entry,
                        image: fixture.image,
                        arguments: scenario.arguments
                    )
                    if result != scenario.expected {
                        failures.append(
                            "\(probe.name)[\(index)]: expected "
                                + "\(scenario.expected), got \(result)"
                        )
                    }
                }
            } catch {
                failures.append("\(probe.name): \(error)")
            }
        }
        if !failures.isEmpty {
            Issue.record(
                "algebraic semantic gaps:\n\(failures.joined(separator: "\n"))"
            )
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
