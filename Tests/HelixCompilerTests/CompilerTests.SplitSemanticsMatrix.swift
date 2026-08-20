import HelixBytecode
import HelixCore
import HelixInterface
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Collection split semantics")
struct SplitSemanticsMatrix {
    private struct Scenario: Sendable {
        var arguments: [VM.Value]
        var expected: VM.ExecutionResult
    }

    @Test("Separator split preserves Swift boundary semantics")
    func lowersSeparatorSplit() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func separatorSplit(
                _ values: [Int],
                separator: Int,
                maximum: Int,
                omitEmpty: Bool
            ) -> [[Int]] {
                values.split(
                    separator: separator,
                    maxSplits: maximum,
                    omittingEmptySubsequences: omitEmpty
                ).map(Array.init)
            }
            """,
            functionName: "separatorSplit",
            moduleName: "HelixSeparatorSplitFixture"
        )
        let scenarios = [
            Scenario(
                arguments: [
                    try integers([0, 1, 0, 2, 0]),
                    try integer(0),
                    try integer(2),
                    .bool(true),
                ],
                expected: .returned(try nestedIntegers([[1], [2]]))
            ),
            Scenario(
                arguments: [
                    try integers([0, 0]),
                    try integer(0),
                    try integer(1),
                    .bool(false),
                ],
                expected: .returned(try nestedIntegers([[], [0]]))
            ),
            Scenario(
                arguments: [
                    try integers([]),
                    try integer(0),
                    try integer(0),
                    .bool(false),
                ],
                expected: .returned(try nestedIntegers([[]]))
            ),
            Scenario(
                arguments: [
                    try integers([1, 0, 2]),
                    try integer(0),
                    try integer(0),
                    .bool(true),
                ],
                expected: .returned(try nestedIntegers([[1, 0, 2]]))
            ),
            Scenario(
                arguments: [
                    try integers([1]),
                    try integer(0),
                    try integer(-1),
                    .bool(true),
                ],
                expected: .trapped(
                    .explicit("maximum split count cannot be negative")
                )
            ),
        ]
        for scenario in scenarios {
            #expect(
                VM.Interpreter().invoke(
                    entry: fixture.entry,
                    image: fixture.image,
                    arguments: scenario.arguments
                ) == scenario.expected
            )
        }

        let recursive = try FrontendExecutionHarness.compile(
            source: """
            public func recursiveSeparatorSplit(
                _ values: [[Int]],
                separator: [Int]
            ) -> [[[Int]]] {
                values.split(separator: separator).map(Array.init)
            }
            """,
            functionName: "recursiveSeparatorSplit",
            moduleName: "HelixRecursiveSeparatorSplitFixture"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: recursive.entry,
                image: recursive.image,
                arguments: [
                    try nestedIntegers([[1], [0], [2], [0], [3]]),
                    try integers([0]),
                ]
            ) == .returned(
                try splitNestedIntegers([[[1]], [[2]], [[3]]])
            )
        )
    }

    @Test("Predicate split supports captures, throws, and exact early stop")
    func lowersPredicateSplit() throws {
        let captured = try FrontendExecutionHarness.compile(
            source: """
            public func capturedSplit(
                _ values: [Int],
                divisor: Int,
                maximum: Int,
                omitEmpty: Bool
            ) -> [[Int]] {
                values.split(
                    maxSplits: maximum,
                    omittingEmptySubsequences: omitEmpty
                ) { value in
                    value % divisor == 0
                }.map(Array.init)
            }
            """,
            functionName: "capturedSplit",
            moduleName: "HelixCapturedSplitFixture"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: captured.entry,
                image: captured.image,
                arguments: [
                    try integers([0, 0, 1, 0, 2]),
                    try integer(3),
                    try integer(1),
                    .bool(true),
                ]
            ) == .returned(try nestedIntegers([[1], [2]]))
        )

        let throwing = try FrontendExecutionHarness.compile(
            source: """
            enum SplitFailure: Error { case rejected }

            public func throwingSplit(_ values: [Int]) -> Int {
                do {
                    return try values.split { value in
                        if value < 0 { throw SplitFailure.rejected }
                        return value == 0
                    }.count
                } catch {
                    return -1
                }
            }
            """,
            functionName: "throwingSplit",
            moduleName: "HelixThrowingSplitFixture"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: throwing.entry,
                image: throwing.image,
                arguments: [try integers([1, 0, 2])]
            ) == .returned(try integer(2))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: throwing.entry,
                image: throwing.image,
                arguments: [try integers([1, -1, 0])]
            ) == .returned(try integer(-1))
        )
    }

    @Test("Split accepts local value elements and Array-backed adapters")
    func lowersGenericElementsAndAdapters() throws {
        let localValues = try FrontendExecutionHarness.compile(
            source: """
            struct Sample { var value: Int }

            public func localValueSplit(_ threshold: Int) -> Int {
                let values = [
                    Sample(value: 1),
                    Sample(value: 5),
                    Sample(value: 2),
                ]
                return values.split { $0.value >= threshold }.count
            }
            """,
            functionName: "localValueSplit",
            moduleName: "HelixLocalValueSplitFixture"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: localValues.entry,
                image: localValues.image,
                arguments: [try integer(4)]
            ) == .returned(try integer(2))
        )

        let adapted = try FrontendExecutionHarness.compile(
            source: """
            public func adaptedSplit(_ values: [Int]) -> [[Int]] {
                values.dropFirst().split(separator: 0).map(Array.init)
            }
            """,
            functionName: "adaptedSplit",
            moduleName: "HelixAdaptedSplitFixture"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: adapted.entry,
                image: adapted.image,
                arguments: [try integers([9, 1, 0, 2])]
            ) == .returned(try nestedIntegers([[1], [2]]))
        )

        let reversed = try FrontendExecutionHarness.compile(
            source: """
            public func reversedSplit(_ values: [Int]) -> [[Int]] {
                values.reversed().split(separator: 0).map(Array.init)
            }
            """,
            functionName: "reversedSplit",
            moduleName: "HelixReversedSplitFixture"
        )
        #expect(
            VM.Interpreter().invoke(
                entry: reversed.entry,
                image: reversed.image,
                arguments: [try integers([2, 0, 1, 9])]
            ) == .returned(try nestedIntegers([[9, 1], [2]]))
        )
    }

    @Test("Predicate split preserves imported reference ownership")
    func verifiesLinearImportedElements() throws {
        let objectType = Core.TypeID(
            rawValue: .sha256("Foundation.NSObject")
        )
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            import Foundation

            public func splitObjects(
                _ values: [NSObject]
            ) -> [[NSObject]] {
                values.split { _ in false }.map(Array.init)
            }
            """,
            functionName: "splitObjects",
            moduleName: "HelixLinearSplitFixture",
            nativeTypes: [
                .init(
                    id: objectType,
                    canonicalName: "Foundation.NSObject",
                    kind: .reference,
                    layoutFingerprint: .sha256(
                        "Foundation.NSObject.layout"
                    ),
                    isCopyable: true,
                    isEmittedToDevice: true,
                    estimatedSize: 8
                ),
            ]
        )
        let instructions = fixture.image.module.functions.flatMap(\.blocks)
            .flatMap(\.instructions)
        #expect(instructions.contains { instruction in
            if case .makeArraySplitState = instruction { return true }
            return false
        })
        #expect(instructions.contains { instruction in
            if case .finishArraySplit = instruction { return true }
            return false
        })
    }

    @Test("Separator split fails closed for user equality witnesses")
    func rejectsCustomSeparatorEquality() {
        do {
            _ = try FrontendExecutionHarness.compile(
                source: """
                struct Sample: Equatable {
                    var value: Int

                    static func == (left: Sample, right: Sample) -> Bool {
                        left.value % 10 == right.value % 10
                    }
                }

                public func customSeparatorSplit(
                    _ values: [Int],
                    separator: Int
                ) -> Int {
                    let samples = values.map { Sample(value: $0) }
                    return samples.split(
                        separator: Sample(value: separator)
                    ).count
                }
                """,
                functionName: "customSeparatorSplit",
                moduleName: "HelixCustomSeparatorSplitFixture"
            )
            Issue.record(
                "custom equality witness unexpectedly became VM-defined"
            )
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unsupportedType(detail) = error else {
                Issue.record("unexpected split diagnostic: \(error)")
                return
            }
            #expect(detail.contains("VM-defined Equatable semantics"))
        } catch {
            Issue.record("unexpected split diagnostic: \(error)")
        }
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(
            try .init(signed: value, bitWidth: 64, isSigned: true)
        )
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func nestedIntegers(_ values: [[Int64]]) throws -> VM.Value {
        .array(
            try values.map(integers),
            elementType: .array(.int64)
        )
    }

    private func splitNestedIntegers(
        _ values: [[[Int64]]]
    ) throws -> VM.Value {
        .array(
            try values.map(nestedIntegers),
            elementType: .array(.array(.int64))
        )
    }
}
}
