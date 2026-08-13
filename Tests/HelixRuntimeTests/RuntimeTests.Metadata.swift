import Testing
@testable import HelixRuntime

extension RuntimeTests {
@Suite("Runtime metadata")
struct Metadata {
    @Test func moduleHasVersion() {
        #expect(Runtime.Metadata.version == .init(1, 0, 0))
    }
}
}
