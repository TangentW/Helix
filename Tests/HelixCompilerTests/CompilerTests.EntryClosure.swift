import HelixBytecode
import HelixCore
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Canonical SIL frozen-entry closures")
struct EntryClosure {
    @Test("Partial application binds the suffix of a frozen Shell entry ABI")
    func lowersCapturedEntryClosure() throws {
        let symbol = "$s7Fixture6offsetyS2i_SitF"
        let entry = Core.EntryIndex(rawValue: 7)
        let directCalls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64, .int64],
                parameterConventions: [.owned, .owned],
                resultType: .int64,
                target: .entry(entry)
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture4makeyS2icS2iF",
            loweredType: "@convention(thin) (Int) -> "
                + "@owned @callee_guaranteed (Int) -> Int",
            body: """
            bb0(%0 : $Int):
              %1 = function_ref @\(symbol) : $@convention(thin) (Int, Int) -> Int
              %2 = partial_apply [callee_guaranteed] %1(%0) : $@convention(thin) (Int, Int) -> Int
              return %2
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "make",
            directCalls: directCalls
        )
        let parameter = try #require(lowered.parameterRegisters.first)
        let construction = try #require(
            lowered.blocks.flatMap(\.instructions).first { instruction in
                if case .makeEntryClosure = instruction { return true }
                return false
            }
        )

        guard case let .makeEntryClosure(
            result,
            targetEntry,
            captures,
            lifetime
        ) = construction else {
            Issue.record("expected a frozen-entry closure construction")
            return
        }
        #expect(targetEntry == entry)
        #expect(captures == [parameter])
        #expect(lifetime == .invocation)
        #expect(
            lowered.registerTypes[Int(result.rawValue)] == .closure(
                .init(
                    parameters: [.int64],
                    parameterConventions: [.owned],
                    result: .int64
                )
            )
        )
        let borrowedEntryBindings = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64, .int64],
                parameterConventions: [.owned, .borrowed],
                resultType: .int64,
                target: .entry(entry)
            ),
        ])
        let entryConventions = try borrowedEntryBindings
            .entryParameterConventions(referencedBy: [lowered])
        let capabilities = CompilerCapabilities.infer(
            for: [lowered],
            entryParameterConventions: entryConventions
        )
        #expect(entryConventions == [entry: [.owned, .borrowed]])
        #expect(capabilities.contains(.borrowCallsV1))
    }
}
}
