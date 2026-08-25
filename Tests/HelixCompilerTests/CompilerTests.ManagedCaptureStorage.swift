import HelixBytecode
import HelixCore
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Canonical SIL managed-capture storage ABI normalization")
struct ManagedCaptureStorage {
    @Test("Only mutable address captures become VM-managed cells")
    func normalizesPhysicalCaptureABI() throws {
        let normalized = try CanonicalSIL.ManagedCaptureStorage.normalize(
            body: """
            bb0(%0 : $*String, %1 : $*Bool, %2 : $*any Error, %3 : $*Int, \
            %4 : $@thin String.Type, %5 : @closureCapture $*String):
            """,
            role: .closureBody,
            parameters: [.int64, .address(.string)],
            parameterConventions: [.owned, .inout],
            erasedPhysicalIndices: [1],
            indirectResultCount: 2,
            hasIndirectError: true
        )

        #expect(normalized.parameters == [.int64, .mutableCell(.string)])
        #expect(normalized.parameterConventions == [.owned, .owned])
        #expect(normalized.logicalIndices == [1])
    }

    @Test("Immutable captures and ordinary inout parameters keep their ABI")
    func preservesNonmutableCaptureABI() throws {
        let immutable = try CanonicalSIL.ManagedCaptureStorage.normalize(
            body: "bb0(%0 : @closureCapture $Int):",
            role: .closureBody,
            parameters: [.int64],
            parameterConventions: [.owned],
            erasedPhysicalIndices: [],
            indirectResultCount: 0,
            hasIndirectError: false
        )
        #expect(immutable.parameters == [.int64])
        #expect(immutable.parameterConventions == [.owned])
        #expect(immutable.logicalIndices.isEmpty)

        let inoutParameter = try CanonicalSIL.ManagedCaptureStorage.normalize(
            body: "bb0(%0 : $*Int):",
            role: .closureBody,
            parameters: [.address(.int64)],
            parameterConventions: [.inout],
            erasedPhysicalIndices: [],
            indirectResultCount: 0,
            hasIndirectError: false
        )
        #expect(inoutParameter.parameters == [.address(.int64)])
        #expect(inoutParameter.parameterConventions == [.inout])
        #expect(inoutParameter.logicalIndices.isEmpty)

        let directHelper = try CanonicalSIL.ManagedCaptureStorage.normalize(
            body: "bb0(%0 : @closureCapture $*Int):",
            role: .ordinary,
            parameters: [.address(.int64)],
            parameterConventions: [.inout],
            erasedPhysicalIndices: [],
            indirectResultCount: 0,
            hasIndirectError: false
        )
        #expect(directHelper.parameters == [.address(.int64)])
        #expect(directHelper.parameterConventions == [.inout])
        #expect(directHelper.logicalIndices.isEmpty)
    }

    @Test("An inconsistent mutable-capture convention fails closed")
    func rejectsMalformedCaptureABI() {
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.ManagedCaptureStorage.normalize(
                body: "bb0(%0 : @closureCapture $*Int):",
                role: .closureBody,
                parameters: [.address(.int64)],
                parameterConventions: [.owned],
                erasedPhysicalIndices: [],
                indirectResultCount: 0,
                hasIndirectError: false
            )
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.ManagedCaptureStorage.normalize(
                body: "bb0(%0 : @closureCapture $*Int)):",
                role: .closureBody,
                parameters: [.address(.int64)],
                parameterConventions: [.inout],
                erasedPhysicalIndices: [],
                indirectResultCount: 0,
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
        let normalized = try CanonicalSIL.ManagedCaptureStorage.normalize(
            body: """
            bb0(%0 : @guaranteed $@callee_guaranteed (Int, String) -> Bool, \
            %1 : @closureCapture $*Int):
            """,
            role: .closureBody,
            parameters: [.closure(callback), .address(.int64)],
            parameterConventions: [.owned, .inout],
            erasedPhysicalIndices: [],
            indirectResultCount: 0,
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

        let normalized = try CanonicalSIL.ManagedCaptureStorage.normalize(
            body: "bb0(%0 : @closureCapture ${ var String }):",
            role: .closureBody,
            parameters: signature.parameters,
            parameterConventions: signature.parameterConventions,
            erasedPhysicalIndices: [],
            indirectResultCount: 0,
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

    @Test("Weak and unowned address captures become shared VM handles")
    func normalizesNonOwningCaptureABI() throws {
        let owner = Bytecode.LocalTypeKey(rawValue: "Fixture.Owner")
        let weakType = Bytecode.ValueType.nonOwningReference(
            kind: .weak,
            pointee: .optional(.local(owner))
        )
        let weak = try CanonicalSIL.ManagedCaptureStorage.normalize(
            body: "bb0(%0 : @closureCapture $*@sil_weak Optional<Fixture.Owner>):",
            role: .ordinary,
            parameters: [.address(weakType)],
            parameterConventions: [.inout],
            erasedPhysicalIndices: [],
            indirectResultCount: 0,
            hasIndirectError: false
        )
        #expect(weak.parameters == [weakType])
        #expect(weak.parameterConventions == [.owned])
        #expect(weak.logicalIndices == [0])

        let unownedType = Bytecode.ValueType.nonOwningReference(
            kind: .unowned,
            pointee: .local(owner)
        )
        let unowned = try CanonicalSIL.ManagedCaptureStorage.normalize(
            body: "bb0(%0 : @closureCapture $*@sil_unowned Fixture.Owner):",
            role: .closureBody,
            parameters: [.address(unownedType)],
            parameterConventions: [.inout],
            erasedPhysicalIndices: [],
            indirectResultCount: 0,
            hasIndirectError: false
        )
        #expect(unowned.parameters == [unownedType])
        #expect(unowned.parameterConventions == [.owned])
        #expect(unowned.logicalIndices == [0])
    }

    @Test("Inferred-immutable weak boxes retain ordinary weak semantics")
    func lowersInferredImmutableWeakBox() throws {
        let owner = Core.TypeID(rawValue: .sha256("Fixture.Owner"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["Fixture.Owner": owner],
                kinds: [owner: .reference]
            )
        let weakCapture = Bytecode.ValueType.nonOwningReference(
            kind: .weak,
            pointee: .optional(.native(owner))
        )
        let captureSignature = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).parseFunctionType(
            "$@convention(thin) "
                + "(@inferredImmutable ${ var @sil_weak Optional<Fixture.Owner> }) "
                + "-> ()"
        )
        #expect(captureSignature.parameters == [weakCapture])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture15captureWeakSelfyyAA5OwnerCF",
            loweredType: "@convention(thin) (@guaranteed Fixture.Owner) -> ()",
            body: """
            bb0(%0 : @guaranteed $Fixture.Owner):
              %1 = alloc_box [inferred_immutable] ${ var @sil_weak Optional<Fixture.Owner> }
              %2 = project_box %1, 0
              %3 = enum $Optional<Fixture.Owner>, #Optional.some!enumelt, %0
              store_weak %3 to [init] %2
              release_value %3
              destroy_value %1
              %4 = tuple ()
              return %4
            """
        )

        let lowered = try CanonicalSIL.Lowerer(
            typeEnvironment: environment
        ).lower(function, displayName: "Fixture.captureWeakSelf")
        #expect(lowered.blocks.flatMap(\.instructions).contains {
            guard case .makeNonOwningReference = $0 else { return false }
            return true
        })

        var unknownDecoration = function
        unknownDecoration.body = function.body.replacingOccurrences(
            of: "[inferred_immutable]",
            with: "[unknown_semantics]"
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer(typeEnvironment: environment).lower(
                unknownDecoration,
                displayName: "Fixture.unknownWeakBox"
            )
        }
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.Lowerer(
                typeEnvironment: environment
            ).parseFunctionType(
                "$@convention(thin) "
                    + "(@unknownCapture ${ var @sil_weak Optional<Fixture.Owner> }) "
                    + "-> ()"
            )
        }
    }

    @Test("Non-owning capture ABI rejects mismatched ownership markers")
    func rejectsMalformedNonOwningCaptureABI() {
        let owner = Bytecode.LocalTypeKey(rawValue: "Fixture.Owner")
        let weakType = Bytecode.ValueType.nonOwningReference(
            kind: .weak,
            pointee: .optional(.local(owner))
        )
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.ManagedCaptureStorage.normalize(
                body: "bb0(%0 : @closureCapture $*@sil_unowned Fixture.Owner):",
                role: .ordinary,
                parameters: [.address(weakType)],
                parameterConventions: [.inout],
                erasedPhysicalIndices: [],
                indirectResultCount: 0,
                hasIndirectError: false
            )
        }
    }
}
}
