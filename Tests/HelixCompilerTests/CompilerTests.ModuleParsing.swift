import HelixBytecode
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Module parsing reuse")
struct ModuleParsing {
    @Test("Rewritten factory candidates replace stale factories without changing layouts")
    func refreshesFactoryBodies() throws {
        let text = """
        sil_stage canonical
        struct Value {
          @_hasStorage var value: Int { get set }
        }
        sil @makeValue : $@convention(thin) (Int, @thin Value.Type) -> Value {
        bb0(%0 : $Int, %1 : $@thin Value.Type):
          %2 = struct $Value (%0 : $Int)
          return %2
        } // end sil function 'makeValue'
        """
        let original = try CanonicalSIL.File(text: text)
        #expect(original.typeEnvironment.isStructFactory("makeValue"))
        var changed = original.functions
        changed[0].body = "bb0(%0 : $Int, %1 : $@thin Value.Type):\n  unreachable"
        let refreshed = try original.typeEnvironment.replacingFactoryCandidates(changed)
        let reparsed = try CanonicalSIL.TypeEnvironment(text: text, functions: changed)
        #expect(!refreshed.isStructFactory("makeValue"))
        #expect(original.typeEnvironment.isStructFactory("makeValue"))
        let key = Bytecode.LocalTypeKey(rawValue: "Value")
        #expect(try refreshed.definition(for: key) == reparsed.definition(for: key))
        let restored = try refreshed.replacingFactoryCandidates(original.functions)
        #expect(restored.isStructFactory("makeValue"))
    }

    @Test("Concurrent modules share grammar without sharing declaration state")
    func parsesIndependentModules() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let scalar = index.isMultiple(of: 2) ? "Int" : "Bool"
                    let file = try CanonicalSIL.File(text: """
                    sil_stage canonical
                    struct Shared {
                      @_hasStorage var value: \(scalar) { get set }
                    }
                    extension Shared {
                      struct Nested {
                        @_hasStorage var flag: Bool { get set }
                      }
                    }
                    """)
                    let definition = try file.typeEnvironment.definition(for: .init(rawValue: "Shared"))
                    guard case let .structure(fields) = definition.kind else {
                        Issue.record("Expected struct layout")
                        return
                    }
                    #expect(fields.count == 1)
                    #expect(fields.first?.type == (try file.typeEnvironment.resolve(scalar)))
                    #expect(try file.typeEnvironment.resolve("Shared.Nested") == .local(.init(rawValue: "Shared.Nested")))
                }
            }
            try await group.waitForAll()
        }
    }
}
}
