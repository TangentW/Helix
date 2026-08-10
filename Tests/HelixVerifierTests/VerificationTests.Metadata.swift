import Testing
@testable import HelixVerifier

extension VerificationTests {
@Suite("Verifier metadata")
struct Metadata {
    @Test func moduleHasVersion() {
        #expect(Verification.Metadata.version.major == 0)
    }
}
}
