import Foundation

extension MixedFixture {
    enum SecondaryContext {}
    static func secondContextValue() -> Int {
        struct Local: MixedFixture.Numbered { func number() -> Int { 2 } }
        return SecondaryContext.value + PrivateState(value: Local().number()).value + PrivateOwner().value
    }
    static func qualifiedProgress(_ value: Foundation.Progress) -> Int64 { value.completedUnitCount }
}

fileprivate extension MixedFixture {
    struct PrivateState { let value: Int }
    class PrivateOwner { var value: Int { 2 } }
}

extension MixedFixture.SecondaryContext {
    @TaskLocal static var value: Int = 2
}
