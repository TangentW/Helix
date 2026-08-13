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
}
}
