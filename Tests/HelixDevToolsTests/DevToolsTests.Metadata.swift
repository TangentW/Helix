import Testing
@testable import HelixDevTools

extension DevToolsTests {
@Suite("Development tools metadata")
struct Metadata {
    @Test func moduleHasVersion() {
        #expect(DevTools.Metadata.version.major == 0)
    }
}
}
