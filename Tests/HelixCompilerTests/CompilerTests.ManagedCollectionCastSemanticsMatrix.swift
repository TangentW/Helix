import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Managed Collection cast normalization")
struct ManagedCollectionCastSemanticsMatrix {
    @Test("Tuple labels normalize through representation-identical Collection casts")
    func normalizesTupleLabelsAcrossManagedCollections() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func normalizesTupleLabelsAcrossManagedCollections(
                _ pairs: [(key: String, value: Int)],
                _ nested: [[(key: String, value: Int)]],
                _ keyed: [Int: (key: String, value: Int)]
            ) -> (
                [(String, Int)],
                [[(String, Int)]],
                [Int: (String, Int)]
            ) {
                (pairs, nested, keyed)
            }
            """,
            functionName: "normalizesTupleLabelsAcrossManagedCollections",
            moduleName: "HelixManagedCollectionLabelNormalization"
        )
        let pairType = Bytecode.ValueType.tuple([.string, .int64])
        let pairs = try pairArray([("a", 1), ("b", 2)])
        let nested = VM.Value.array(
            [pairs, try pairArray([("c", 3)])],
            elementType: .array(pairType)
        )
        let keyed = VM.Value.dictionary(
            [
                .init(
                    key: try integer(7),
                    value: .tuple([.string("seven"), try integer(70)])
                ),
            ],
            keyType: .int64,
            valueType: pairType
        )

        #expect(
            VM.Interpreter().invoke(
                entry: fixture.entry,
                image: fixture.image,
                arguments: [pairs, nested, keyed]
            ) == .returned(.tuple([pairs, nested, keyed]))
        )
        #expect(fixture.image.module.imports.isEmpty)
    }

    @Test("Managed Collection casts reject real element conversions")
    func rejectsRepresentationallyDifferentCollectionCasts() {
        let cases = [
            (
                module: "HelixManagedCollectionRealCast",
                source: """
                public func rejectsRepresentationallyDifferentCollectionCasts(
                    _ values: [Any]
                ) -> [String] {
                    values as! [String]
                }
                """
            ),
            (
                module: "HelixManagedCollectionCollapsedCast",
                source: """
                import Foundation

                public func rejectsRepresentationallyDifferentCollectionCasts(
                    _ values: [CGFloat]
                ) -> [Double] {
                    values as! [Double]
                }
                """
            ),
        ]
        for testCase in cases {
            do {
                _ = try FrontendExecutionHarness.compile(
                    source: testCase.source,
                    functionName: "rejectsRepresentationallyDifferentCollectionCasts",
                    moduleName: testCase.module
                )
                Issue.record("real Collection element cast unexpectedly compiled")
            } catch let error as CanonicalSIL.LoweringError {
                guard case let .unsupportedType(detail) = error else {
                    Issue.record("unexpected Collection cast diagnostic: \(error)")
                    continue
                }
                #expect(detail.contains("Tuple-label erasure"))
            } catch {
                Issue.record("unexpected Collection cast diagnostic: \(error)")
            }
        }
    }

    private func pairArray(
        _ pairs: [(String, Int64)]
    ) throws -> VM.Value {
        let pairType = Bytecode.ValueType.tuple([.string, .int64])
        return .array(
            try pairs.map {
                .tuple([.string($0.0), try integer($0.1)])
            },
            elementType: pairType
        )
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
