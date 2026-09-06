import Foundation
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Canonical SIL debug identity")
struct DebugIdentity {
    @Test("Debug-only parent spellings keep distinct scope locations without inventing functions")
    func debugOnlyParents() throws {
        // A grammar fixture for reported compiler output. The minimal Swift
        // source/configuration that emits this placeholder is not established.
        let scopes = """
        sil_scope 1 { loc "/tmp/MacroA.swift":1:1 parent @__unknown_macro__ : $@convention(thin) () -> () }
        sil_scope 2 { loc "/tmp/MacroB.swift":1:1 parent @__unknown_macro__ : $@convention(thin) () -> () }
        sil_scope 3 { parent 2 }
        sil_scope 4 { loc "/tmp/OtherA.swift":2:3 parent @debug_only_parent : $@convention(thin) () -> () }
        sil_scope 5 { loc "/tmp/OtherB.swift":4:5 parent @debug_only_parent : $@convention(thin) () -> () }
        """
        let file = try CanonicalSIL.File(text: scopes + "\n" + function("one", scope: 1) + "\n" + function("two", scope: 3))
        #expect(file.functions.count == 2)
        #expect(file.functions.allSatisfy { $0.declarationLocation == nil })
        #expect(file.function(mangledName: "one")?.sourceLocation(atBodyLine: 2)?.file == "/tmp/MacroA.swift")
        #expect(file.function(mangledName: "two")?.sourceLocation(atBodyLine: 2)?.file == "/tmp/MacroB.swift")
        #expect(file.function(mangledName: "two")?.sourceLocation(atBodyLine: 2)?.line == 1)
    }

    @Test("Real function conflicts include both scopes and locations, even for a placeholder-looking name")
    func rejectsConflictingDefinitions() throws {
        for name in ["actual_function", "__unknown_macro__"] {
            let text = """
            sil_scope 1 { loc "/tmp/A.swift":11:12 parent @\(name) : $@convention(thin) () -> () }
            sil_scope 2 { loc "/tmp/B.swift":21:22 parent @\(name) : $@convention(thin) () -> () }
            """ + "\n" + function(name, scope: 1)
            expectFailure(text, containing: ["@\(name)", "scope 1", "scope 2", "/tmp/A.swift:11:12", "/tmp/B.swift:21:22"])
        }
    }

    @Test("Repeated identical declaration locations remain valid")
    func equivalentScopes() throws {
        let text = """
        sil_scope 1 { loc "/tmp/A.swift":11:12 parent @actual_function : $@convention(thin) () -> () }
        sil_scope 2 { loc "/tmp/A.swift":11:12 parent @actual_function : $@convention(thin) () -> () }
        """ + "\n" + function("actual_function", scope: 2)
        let file = try CanonicalSIL.File(text: text)
        #expect(file.functions.first?.declarationLocation?.line == 11)
        #expect(file.functions.first?.declarationLocation?.column == 12)
    }

    @Test("Duplicate definitions cannot silently select the first function")
    func duplicateFunction() {
        let first = function("repeated", scope: 1)
        let second = first.replacingOccurrences(of: "() -> ()", with: "(Builtin.Int64) -> ()")
        expectFailure(first + "\n" + second,
            containing: ["@repeated", "defined more than once", "SIL line 1", "SIL line 5", "Builtin.Int64", "() -> ()"])
    }

    @Test("Duplicate scope IDs and conflicting source modules report both facts")
    func metadataConflicts() {
        expectFailure("""
        sil_scope 1 { loc "/tmp/A.swift":11:12 parent @one : $@convention(thin) () -> () }
        sil_scope 1 { loc "/tmp/B.swift":21:22 parent @two : $@convention(thin) () -> () }
        """, containing: ["scope 1", "SIL line 1", "SIL line 2", "A.swift", "B.swift", "@one", "@two"])
        expectFailure("""
        // 'First/A.swift' => '/tmp/A.swift'
        // 'Second/A.swift' => '/tmp/A.swift'
        """, containing: ["/tmp/A.swift", "First", "Second"])
    }

    private func function(_ name: String, scope: Int) -> String {
        """
        sil hidden @\(name) : $@convention(thin) () -> () {
        bb0:
          unreachable, scope \(scope)
        } // end sil function '\(name)'
        """
    }

    private func expectFailure(_ text: String, containing facts: [String]) {
        do {
            _ = try CanonicalSIL.File(text: text)
            Issue.record("Expected malformed SIL")
        } catch {
            let message = String(describing: error)
            for fact in facts { #expect(message.contains(fact), "\(message)") }
        }
    }
}
}
