import Testing
@testable import HelixDevRuntime

extension DevRuntimeTests {
@Suite("Development runtime metadata")
struct Metadata {
    @Test func moduleHasVersion() {
        #expect(DevRuntime.Metadata.version.major == 1)
    }
}
}
