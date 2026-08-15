import HelixBytecode
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Canonical SIL mutable-capture ABI normalization")
struct MutableCaptures {
    @Test("Only mutable address captures become VM-managed cells")
    func normalizesPhysicalCaptureABI() throws {
        let normalized = try CanonicalSIL.MutableCaptures.normalize(
            body: """
            bb0(%0 : $*String, %1 : $*any Error, %2 : $*Int, \
            %3 : $@thin String.Type, %4 : @closureCapture $*String):
            """,
            role: .closureBody,
            parameters: [.int64, .address(.string)],
            parameterConventions: [.owned, .inout],
            erasedPhysicalIndices: [1],
            hasIndirectResult: true,
            hasIndirectError: true
        )

        #expect(normalized.parameters == [.int64, .mutableCell(.string)])
        #expect(normalized.parameterConventions == [.owned, .owned])
        #expect(normalized.logicalIndices == [1])
    }

    @Test("Immutable captures and ordinary inout parameters keep their ABI")
    func preservesNonmutableCaptureABI() throws {
        let immutable = try CanonicalSIL.MutableCaptures.normalize(
            body: "bb0(%0 : @closureCapture $Int):",
            role: .closureBody,
            parameters: [.int64],
            parameterConventions: [.owned],
            erasedPhysicalIndices: [],
            hasIndirectResult: false,
            hasIndirectError: false
        )
        #expect(immutable.parameters == [.int64])
        #expect(immutable.parameterConventions == [.owned])
        #expect(immutable.logicalIndices.isEmpty)

        let inoutParameter = try CanonicalSIL.MutableCaptures.normalize(
            body: "bb0(%0 : $*Int):",
            role: .closureBody,
            parameters: [.address(.int64)],
            parameterConventions: [.inout],
            erasedPhysicalIndices: [],
            hasIndirectResult: false,
            hasIndirectError: false
        )
        #expect(inoutParameter.parameters == [.address(.int64)])
        #expect(inoutParameter.parameterConventions == [.inout])
        #expect(inoutParameter.logicalIndices.isEmpty)

        let directHelper = try CanonicalSIL.MutableCaptures.normalize(
            body: "bb0(%0 : @closureCapture $*Int):",
            role: .ordinary,
            parameters: [.address(.int64)],
            parameterConventions: [.inout],
            erasedPhysicalIndices: [],
            hasIndirectResult: false,
            hasIndirectError: false
        )
        #expect(directHelper.parameters == [.address(.int64)])
        #expect(directHelper.parameterConventions == [.inout])
        #expect(directHelper.logicalIndices.isEmpty)
    }

    @Test("An inconsistent mutable-capture convention fails closed")
    func rejectsMalformedCaptureABI() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.MutableCaptures.normalize(
                body: "bb0(%0 : @closureCapture $*Int):",
                role: .closureBody,
                parameters: [.address(.int64)],
                parameterConventions: [.owned],
                erasedPhysicalIndices: [],
                hasIndirectResult: false,
                hasIndirectError: false
            )
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.MutableCaptures.normalize(
                body: "bb0(%0 : @closureCapture $*Int)):",
                role: .closureBody,
                parameters: [.address(.int64)],
                parameterConventions: [.inout],
                erasedPhysicalIndices: [],
                hasIndirectResult: false,
                hasIndirectError: false
            )
        }
    }

    @Test("Closure arrows do not merge adjacent physical parameters")
    func splitsClosureTypedEntryParameters() throws {
        let callback = Bytecode.ClosureSignature(
            parameters: [.int64, .string],
            parameterConventions: [.owned, .owned],
            result: .bool
        )
        let normalized = try CanonicalSIL.MutableCaptures.normalize(
            body: """
            bb0(%0 : @guaranteed $@callee_guaranteed (Int, String) -> Bool, \
            %1 : @closureCapture $*Int):
            """,
            role: .closureBody,
            parameters: [.closure(callback), .address(.int64)],
            parameterConventions: [.owned, .inout],
            erasedPhysicalIndices: [],
            hasIndirectResult: false,
            hasIndirectError: false
        )

        #expect(normalized.parameters == [
            .closure(callback),
            .mutableCell(.int64),
        ])
        #expect(normalized.logicalIndices == [1])
    }

    @Test("Escaping Swift var boxes use the same managed-cell ABI")
    func normalizesEscapingBoxABI() throws {
        let signature = try CanonicalSIL.Lowerer().parseFunctionType(
            "$@convention(thin) (@guaranteed { var String }) -> Int"
        )
        #expect(signature.parameters == [.mutableCell(.string)])
        #expect(signature.parameterConventions == [.owned])

        let normalized = try CanonicalSIL.MutableCaptures.normalize(
            body: "bb0(%0 : @closureCapture ${ var String }):",
            role: .closureBody,
            parameters: signature.parameters,
            parameterConventions: signature.parameterConventions,
            erasedPhysicalIndices: [],
            hasIndirectResult: false,
            hasIndirectError: false
        )
        #expect(normalized.parameters == [.mutableCell(.string)])
        #expect(normalized.logicalIndices.isEmpty)

        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().parseFunctionType(
                "$@convention(thin) (@guaranteed { let String }) -> Int"
            )
        }
    }
}
}
