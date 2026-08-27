import HelixBytecode
import HelixCore
import HelixInterface
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Generic native import lowering")
struct GenericNativeImport {
    @Test("Apply substitutions select one Catalog binding for a shared symbol")
    func selectsConcreteCatalogBinding() throws {
        let firstID = Core.TypeID(rawValue: .sha256("Fixture.First"))
        let secondID = Core.TypeID(rawValue: .sha256("Fixture.Second"))
        let thirdID = Core.TypeID(rawValue: .sha256("Fixture.Third"))
        let environment = try CanonicalSIL.TypeEnvironment.empty
            .includingNativeTypes(
                ["First": firstID, "Second": secondID, "Third": thirdID],
                kinds: [
                    firstID: .value, secondID: .value, thirdID: .value,
                ]
            )
        let symbol = "$s7Fixture10ProbeValuePAAE7payloadSivg"
        let genericType = "@convention(method) "
            + "<τ_0_0 where τ_0_0 : ProbeValue> "
            + "(@in_guaranteed τ_0_0) -> Swift.Int"
        let contract = Core.NativeImportContract.bounded(
            kind: .instanceGetter,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        func requirement(
            id: UInt32,
            owner: String
        ) throws -> Bytecode.ImportRequirement {
            let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.\(owner).payload.get",
                signature: .init(
                    parameters: ["Fixture.\(owner)"],
                    result: "Swift.Int"
                ),
                effects: .init(),
                contract: contract,
                argumentLabels: [],
                receiverArgumentIndex: 0
            )
            return .init(
                id: .init(rawValue: id),
                key: try Core.NativeCall.Key.derive(descriptor: descriptor),
                descriptor: descriptor,
                contract: contract
            )
        }
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.native(firstID)],
                resultType: .int64,
                target: .nativeImport(try requirement(id: 0, owner: "First"))
            ),
            .init(
                mangledName: symbol,
                parameterTypes: [.native(secondID)],
                resultType: .int64,
                target: .nativeImport(try requirement(id: 1, owner: "Second"))
            ),
        ])

        func loweredImportID(
            owner: String
        ) throws -> Core.NativeImportID {
            let function = CanonicalSIL.Function(
                mangledName: "$s7Fixture4read\(owner)",
                loweredType: "@convention(thin) (\(owner)) -> Swift.Int",
                body: """
                bb0(%0 : $\(owner)):
                  %1 = alloc_stack $\(owner)
                  store %0 to %1
                  %2 = function_ref @\(symbol) : $\(genericType)
                  %3 = apply %2<\(owner)>(%1) : $\(genericType)
                  dealloc_stack %1
                  return %3
                """
            )
            let lowered = try CanonicalSIL.Lowerer(
                typeEnvironment: environment
            ).lower(
                function,
                displayName: "read\(owner)",
                directCalls: calls
            )
            return try #require(lowered.blocks.flatMap(\.instructions)
                .compactMap { instruction -> Core.NativeImportID? in
                    guard case let .nativeApply(_, id, _) = instruction else {
                        return nil
                    }
                    return id
                }.only)
        }

        #expect(try loweredImportID(owner: "First").rawValue == 0)
        #expect(try loweredImportID(owner: "Second").rawValue == 1)
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try loweredImportID(owner: "Third")
        }
    }
}
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
