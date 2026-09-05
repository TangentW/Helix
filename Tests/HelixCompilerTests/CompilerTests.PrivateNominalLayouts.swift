import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Private nominal SIL layout ambiguity")
struct PrivateNominalLayouts {
    @Test("Private duplicate layouts stay unavailable without blocking unrelated types")
    func ambiguousLayouts() throws {
        let file = try CanonicalSIL.File(text: """
        sil_stage canonical
        private struct Key {
          @_hasStorage var value: Int { get set }
          struct Child {
            @_hasStorage var value: Int { get set }
          }
        }
        private struct Key {
          @_hasStorage var value: Bool { get set }
        }
        struct Safe {
          @_hasStorage var value: Int { get set }
        }
        """)
        #expect(throws: CanonicalSIL.LoweringError.self) { try file.typeEnvironment.resolve("Key") }
        #expect(throws: CanonicalSIL.LoweringError.self) { try file.typeEnvironment.resolve("Key.Child") }
        #expect(try file.typeEnvironment.resolve("Safe") == .local(.init(rawValue: "Safe")))
    }

    @Test("A public or internal duplicate remains a malformed SIL error")
    func invalidDuplicates() throws {
        for prefix in ["", "public ", "internal "] {
            #expect(throws: CanonicalSIL.LoweringError.self) {
                try CanonicalSIL.File(text: """
                sil_stage canonical
                private struct Key {
                }
                \(prefix)struct Key {
                }
                """)
            }
        }
    }
}
}
