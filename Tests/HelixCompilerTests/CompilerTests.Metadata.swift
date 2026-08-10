import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Compiler metadata")
struct Metadata {
    @Test func moduleHasVersion() {
        #expect(Compiler.Metadata.version.major == 0)
    }
}
}
