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

    @Test("Debug metadata preserves Unicode, quoted comments and escaped paths")
    func lexicalBoundaries() throws {
        let line = #"  %0 = string_literal utf8 "a\"//中😀", loc "/tmp/\E4\B8\AD.swift":7:9, scope 1 // comment"#
        let parsed = try CanonicalSIL.DebugMetadata.parse(line, scopes: [:])
        #expect(parsed.instruction == #"%0 = string_literal utf8 "a\"//中😀""#)
        #expect(parsed.location?.file == "/tmp/中.swift")
        #expect(parsed.location?.line == 7 && parsed.location?.column == 9)
        #expect(CanonicalSIL.DebugMetadata.strippingComment(from: "注释😀 // 尾部") == "注释😀 ")
        let records = "\u{200B}\t// 'Feature/中.swift' => '/tmp/中.swift'\n"
            + "\u{200B}sil_scope 1 { loc \"/tmp/中.swift\":2:3 parent @f : $@convention(thin) () -> () }"
        #expect(try CanonicalSIL.DebugMetadata.sourceModules(in: records) == ["/tmp/中.swift": "Feature"])
        #expect(try CanonicalSIL.DebugMetadata.scopes(in: records).first?.location.file == "/tmp/中.swift")
        #expect(throws: CanonicalSIL.LoweringError.self) {
            try CanonicalSIL.DebugMetadata.parse(#"unreachable, loc "/tmp/\FF.swift":1:1"#, scopes: [:])
        }
    }

    @Test("Long scope chains memoize missing locations and resolve without recursive stack growth")
    func longScopeChains() throws {
        let count = 30_000
        let chain = (1..<count).map { "sil_scope \($0) { parent \($0 + 1) }" }.joined(separator: "\n")
        #expect(try CanonicalSIL.DebugMetadata.scopes(in: chain).isEmpty)
        let located = chain + "\nsil_scope \(count) { loc \"Feature.swift\":4:5 parent @f : $@convention(thin) () -> () }"
        let scopes = try CanonicalSIL.DebugMetadata.scopes(in: located)
        #expect(scopes.count == count)
        #expect(scopes.allSatisfy { $0.location.file == "Feature.swift" && $0.location.line == 4 })
        do {
            _ = try CanonicalSIL.DebugMetadata.scopes(in: "sil_scope 1 { parent 2 }\nsil_scope 2 { parent 1 }")
            Issue.record("Cycle must fail")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("cycle") && message.contains("scope 1") && message.contains("scope 2"))
            #expect(message.contains("SIL line 1") && message.contains("SIL line 2"))
        }
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
