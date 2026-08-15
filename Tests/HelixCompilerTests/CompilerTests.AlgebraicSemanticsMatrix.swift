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
