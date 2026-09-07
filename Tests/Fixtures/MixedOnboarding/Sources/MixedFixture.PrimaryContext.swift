import Foundation

extension MixedFixture {
    enum PrimaryContext {}
    static func firstContextValue() -> Int {
        struct Local: MixedFixture.Numbered { func number() -> Int { 1 } }
        return PrimaryContext.value + PrivateState(value: Local().number()).value + PrivateOwner().value
    }
}

fileprivate extension MixedFixture {
    struct PrivateState { let value: Int }
    class PrivateOwner { var value: Int { 1 } }
}

extension MixedFixture.PrimaryContext {
    @TaskLocal static var value: Int = 1
}
