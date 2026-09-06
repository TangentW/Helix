import Foundation

extension MixedFixture {
    enum SecondaryContext {}
    fileprivate struct PrivateState { let value: Int }
    static func secondContextValue() -> Int { SecondaryContext.value + PrivateState(value: 2).value }
    static func qualifiedProgress(_ value: Foundation.Progress) -> Int64 { value.completedUnitCount }
}

extension MixedFixture.SecondaryContext {
    @TaskLocal static var value: Int = 2
}
