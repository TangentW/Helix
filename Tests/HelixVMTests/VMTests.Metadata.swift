import Testing
@testable import HelixVM

extension VMTests {
@Suite("Virtual machine metadata")
struct Metadata {
    @Test func moduleMatchesRuntimeVersion() {
        #expect(VM.Metadata.version.major == 0)
    }
}
}
