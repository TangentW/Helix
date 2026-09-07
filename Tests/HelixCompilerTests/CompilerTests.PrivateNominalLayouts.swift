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

    @Test("Extension defaults and owner visibility have distinct inheritance rules")
    func extensionAccessDefaults() throws {
        for access in ["private", "fileprivate"] {
            let file = try CanonicalSIL.File(text: """
            sil_stage canonical
            public enum Scope {
            }
            \(access) extension Scope {
              class Nested {
                struct Child {
                }
              }
            }
            \(access) extension Scope {
              class Nested {
              }
            }
            extension Scope {
              struct Safe {
              }
            }
            """)
            #expect(throws: CanonicalSIL.LoweringError.self) { try file.typeEnvironment.resolve("Scope.Nested") }
            #expect(throws: CanonicalSIL.LoweringError.self) { try file.typeEnvironment.resolve("Scope.Nested.Child") }
            #expect(try file.typeEnvironment.resolve("Scope.Safe") == .local(.init(rawValue: "Scope.Safe")))
        }
        for second in ["fileprivate extension Scope {\n  internal struct Key {",
                       "extension Scope {\n  struct Key {"] {
            do {
                _ = try CanonicalSIL.File(text: """
                sil_stage canonical
                fileprivate extension Scope {
                  struct Key {
                  }
                }
                \(second)
                  }
                }
                """)
                Issue.record("Nonprivate duplicate was accepted")
            } catch {
                let message = String(describing: error)
                #expect(message.contains("SIL line 3"))
                #expect(message.contains("SIL line 7"))
                #expect(message.contains("parent=Scope"))
                #expect(message.contains("effectiveFileScoped=true"))
                #expect(message.contains("effectiveFileScoped=false"))
            }
        }
    }
}
}
