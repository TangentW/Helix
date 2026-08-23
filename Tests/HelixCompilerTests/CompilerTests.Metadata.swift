import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Compiler metadata")
struct Metadata {
    @Test func moduleHasVersion() {
        #expect(Compiler.Metadata.version == .init(1, 0, 0))
    }

    @Test("Swift symbol module identity is bounded and fail-closed")
    func parsesMangledModuleIdentity() {
        #expect(
            CanonicalSIL.SymbolIdentity.moduleName(
                of: "$s20ReleaseDriverFixture9transformyS2iF"
            ) == "ReleaseDriverFixture"
        )
        #expect(CanonicalSIL.SymbolIdentity.moduleName(of: "$ss5print") == nil)
        #expect(CanonicalSIL.SymbolIdentity.moduleName(of: "not-a-swift-symbol") == nil)
        #expect(
            CanonicalSIL.SymbolIdentity.moduleName(
                of: "$s9999999999999999999999999999999TooShort"
            ) == nil
        )
    }

    @Test("Foreign-type extensions use bounded source ownership evidence")
    func recognizesCurrentModuleExtensionDefinitions() throws {
        let local = "$sSi7FixtureE5localyyF"
        let imported = "$sSi1poiyS2i_SitFZ"
        let file = try CanonicalSIL.File(
            text: """
            sil_scope 1 { loc "/tmp/Fixture.swift":1:1 parent @\(local) : $@convention(thin) () -> () }
            sil hidden @\(local) : $@convention(thin) () -> () {
            bb0:
              unreachable, scope 1
            } // end sil function '\(local)'

            sil_scope 2 { loc "/tmp/Fixture.swift":2:1 parent @\(imported) : $@convention(thin) () -> () }
            sil public_external @\(imported) : $@convention(thin) () -> () {
            bb0:
              unreachable, scope 2
            } // end sil function '\(imported)'

            // Mappings from '#fileID' to '#filePath':
            //   'Fixture/Fixture.swift' => '/tmp/Fixture.swift'
            """
        )

        #expect(file.isCurrentModuleDefinition(
            mangledName: local,
            moduleName: "Fixture"
        ))
        #expect(file.function(mangledName: local).flatMap(file.owningModule) == "Fixture")
        #expect(!file.isCurrentModuleDefinition(
            mangledName: imported,
            moduleName: "Fixture"
        ))
    }
}
}
