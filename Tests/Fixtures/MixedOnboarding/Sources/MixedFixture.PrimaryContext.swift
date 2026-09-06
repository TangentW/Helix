import Foundation

extension MixedFixture {
    enum PrimaryContext {}
    fileprivate struct PrivateState { let value: Int }
    static func firstContextValue() -> Int { PrimaryContext.value + PrivateState(value: 1).value }
}

extension MixedFixture.PrimaryContext {
    @TaskLocal static var value: Int = 1
}
