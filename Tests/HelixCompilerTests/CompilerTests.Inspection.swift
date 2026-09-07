import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Independent canonical SIL inspection")
struct InspectionTests {
    @Test("Independent malformed components are all reported without a substitute File")
    func independentFailures() throws {
        let inspection = try CanonicalSIL.Inspection(text: """
        sil_stage canonical
        struct Duplicate {
        }
        struct Duplicate {
        }
        sil_scope 1 { loc "Feature.swift":1:1 parent @value : $@convention(thin) () -> () }
        sil_scope 1 { loc "Other.swift":2:2 parent @value : $@convention(thin) () -> () }
        sil @value : $@convention(thin) () -> () {
        bb0:
          %0 = tuple ()
          return %0
        } // end sil function 'value'
        sil_witness_table Value: Feature module Fixture {
          associated_type Item: Int
          associated_type Item: String
        }
        // 'First/File.swift' => 'Feature.swift'
        // 'Second/File.swift' => 'Feature.swift'
        """)
        #expect(Set(inspection.checks.filter { $0.status == .failed }.map(\.component))
            == [.nominalDeclarations, .debugScopes, .sourceModules, .conformances])
        #expect(inspection.checks.contains { $0.component == .functionDefinitions && $0.status == .passed })
        #expect(inspection.checks.contains { $0.component == .functionLocations && $0.status == .blocked })
        #expect(inspection.functions == nil)
        #expect(inspection.file == nil)
        #expect(throws: CanonicalSIL.LoweringError.self) { try inspection.requireFile() }
    }

    @Test("Validated function locations remain available when unrelated layout evidence fails")
    func preservesIndependentFunctions() throws {
        let text = """
        struct Duplicate {
        }
        struct Duplicate {
        }
        sil_scope 1 { loc "Feature.swift":3:13 parent @value : $@convention(thin) () -> () }
        sil @value : $@convention(thin) () -> () {
        bb0:
          %0 = tuple ()
          return %0
        } // end sil function 'value'
        """
        let inspection = try CanonicalSIL.Inspection(text: text)
        #expect(inspection.functions?.first?.mangledName == "value")
        #expect(inspection.functions?.first?.declarationLocation?.line == 3)
        #expect(inspection.file == nil)
        #expect(inspection.checks.contains { $0.component == .typeEnvironment && $0.status == .blocked })
        #expect(throws: CanonicalSIL.LoweringError.self) { try CanonicalSIL.File(text: text) }
    }

    @Test("Complete inspection and normal parsing share exactly the same function facts")
    func completeInspection() throws {
        let text = """
        struct Safe {
          @_hasStorage var value: Int { get set }
        }
        sil @value : $@convention(thin) () -> () {
        bb0:
          %0 = tuple ()
          return %0
        } // end sil function 'value'
        """
        let inspection = try CanonicalSIL.Inspection(text: text)
        #expect(inspection.checks.allSatisfy { $0.status == .passed })
        #expect(try inspection.requireFile().functions == CanonicalSIL.File(text: text).functions)
        #expect(try inspection.requireFile().typeEnvironment.resolve("Safe") == .local(.init(rawValue: "Safe")))
    }

    @Test("Invalid function definitions block locations but not independent declaration checks")
    func definitionFailure() throws {
        let function = """
        sil @duplicate : $@convention(thin) () -> () {
        bb0:
          %0 = tuple ()
          return %0
        } // end sil function 'duplicate'
        """
        let inspection = try CanonicalSIL.Inspection(text: function + "\n" + function)
        #expect(inspection.checks.contains { $0.component == .functionDefinitions && $0.status == .failed })
        #expect(inspection.checks.contains { $0.component == .nominalDeclarations && $0.status == .passed })
        #expect(inspection.checks.contains { $0.component == .functionLocations && $0.status == .blocked })
        #expect(inspection.functions == nil)
        #expect(inspection.file == nil)
    }
}
}
