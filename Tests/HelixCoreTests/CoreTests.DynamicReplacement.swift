import HelixCore
import Testing

extension CoreTests {
@Suite("Swift dynamic replacement declarations")
struct DynamicReplacementDeclarations {
    @Test("Closed declaration shapes validate by Swift replacement granularity")
    func validatesClosedShapes() {
        let function = Core.DynamicReplacement.Declaration(
            identity: "s:7Feature5valueyS2iF",
            kind: .function,
            originalReference: "value(_:)",
            replacementHeader: "func replacementValue(_ value: Int) -> Int",
            members: [
                .init(
                    role: .functionBody,
                    fallbackBody: "return value(value)"
                ),
            ]
        )
        #expect(function.isWellFormed)

        let property = Core.DynamicReplacement.Declaration(
            identity: "s:7Feature5valueSivp",
            kind: .property,
            originalReference: "value",
            replacementHeader: "var replacementValue: Int",
            members: [
                .init(role: .setter, header: "set", fallbackBody: "value = newValue"),
                .init(role: .getter, header: "get", fallbackBody: "return value"),
            ]
        )
        #expect(property.isWellFormed)
        #expect(property.members.map(\.role) == [.getter, .setter])

        let subscriptDeclaration = Core.DynamicReplacement.Declaration(
            identity: "s:7FeatureVyS2icip",
            kind: .subscriptDeclaration,
            originalReference: "subscript(_:)",
            replacementHeader: "subscript(replacement index: Int) -> Int",
            members: [
                .init(role: .getter, header: "get", fallbackBody: "return self[index]"),
                .init(
                    role: .setter,
                    header: "nonmutating set",
                    fallbackBody: "self[index] = newValue"
                ),
            ]
        )
        #expect(subscriptDeclaration.isWellFormed)

        let observers = Core.DynamicReplacement.Declaration(
            identity: "s:7Feature5valueSivp",
            kind: .propertyObservers,
            originalReference: "value",
            replacementHeader: "var replacementValue: Int",
            members: [
                .init(
                    role: .willSet,
                    header: "willSet(incoming)",
                    fallbackBody: "originalWillSet(incoming)"
                ),
                .init(
                    role: .didSet,
                    header: "didSet(previous)",
                    fallbackBody: "originalDidSet(previous)"
                ),
            ]
        )
        #expect(observers.isWellFormed)
    }

    @Test("Malformed declaration/member combinations fail closed")
    func rejectsMalformedShapes() {
        #expect(!Core.DynamicReplacement.Declaration(
            identity: "s:setter-only",
            kind: .property,
            originalReference: "value",
            replacementHeader: "var replacementValue: Int",
            members: [
                .init(role: .setter, header: "set", fallbackBody: "value = newValue"),
            ]
        ).isWellFormed)
        #expect(!Core.DynamicReplacement.Declaration(
            identity: "s:empty-fallback",
            kind: .property,
            originalReference: "value",
            replacementHeader: "var replacementValue: Int",
            members: [
                .init(role: .getter, header: "get", fallbackBody: ""),
            ]
        ).isWellFormed)
        #expect(!Core.DynamicReplacement.Declaration(
            identity: "s:wrong-kind",
            kind: .function,
            originalReference: "value",
            replacementHeader: "var replacementValue: Int",
            members: [
                .init(role: .functionBody, fallbackBody: "return value"),
            ]
        ).isWellFormed)
        #expect(!Core.DynamicReplacement.Declaration(
            identity: "s:duplicate-member",
            kind: .propertyObservers,
            originalReference: "value",
            replacementHeader: "var replacementValue: Int",
            members: [
                .init(role: .didSet, header: "didSet", fallbackBody: "first()"),
                .init(role: .didSet, header: "didSet", fallbackBody: "second()"),
            ]
        ).isWellFormed)
    }
}
}
