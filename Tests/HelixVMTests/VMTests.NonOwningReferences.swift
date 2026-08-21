import Foundation
import HelixBytecode
import HelixCore
import Testing
@testable import HelixVM

extension VMTests {
@Suite("HLVM non-owning reference storage")
struct NonOwningReferences {
    @Test("Weak native references follow the concrete object across value-box copies")
    func weakNativeReferenceUsesConcreteIdentity() throws {
        let typeID = Core.TypeID(rawValue: .sha256("Fixture.ReferenceToken"))
        let operations = VM.NativeTypeOperations.reference(
            id: typeID,
            canonicalName: "Fixture.ReferenceToken",
            layoutFingerprint: .sha256("Fixture.ReferenceToken.layout.v1"),
            describe: { (token: ReferenceToken) in token.label }
        )
        let catalog = try VM.NativeTypeCatalog([operations])
        var token: ReferenceToken? = .init(label: "shared")
        var first: VM.NativeValue? = try catalog.box(token!, as: typeID)
        var second: VM.NativeValue? = try catalog.copy(first!)
        let reference = VM.NonOwningReference(
            kind: .weak,
            pointee: .optional(.native(typeID)),
            target: .native(typeID)
        )
        try reference.store(
            object: catalog.referencedObject(in: first!),
            mode: .initialize
        )

        first = nil
        #expect(try catalog.referencedObject(in: second!) === token)
        #expect(try reference.loadObject(mode: .copy) === token)

        second = nil
        token = nil
        #expect(try reference.loadObject(mode: .copy) == nil)
    }

    @Test("Dangling unowned native references become controlled traps")
    func trapsDanglingUnownedNativeReference() throws {
        let typeID = Core.TypeID(rawValue: .sha256("Fixture.UnownedToken"))
        let operations = VM.NativeTypeOperations.reference(
            id: typeID,
            canonicalName: "Fixture.UnownedToken",
            layoutFingerprint: .sha256("Fixture.UnownedToken.layout.v1"),
            describe: { (token: ReferenceToken) in token.label }
        )
        let catalog = try VM.NativeTypeCatalog([operations])
        var token: ReferenceToken? = .init(label: "temporary")
        var boxed: VM.NativeValue? = try catalog.box(token!, as: typeID)
        let reference = VM.NonOwningReference(
            kind: .unowned,
            pointee: .native(typeID),
            target: .native(typeID)
        )
        try reference.store(
            object: catalog.referencedObject(in: boxed!),
            mode: .initialize
        )

        boxed = nil
        token = nil
        #expect(throws: VM.RuntimeTrap.danglingUnownedReference) {
            try reference.loadObject(mode: .copy)
        }
    }

    @Test("Optional unowned nil and take preserve storage state semantics")
    func optionalUnownedNilAndTake() throws {
        let typeID = Core.TypeID(rawValue: .sha256("Fixture.OptionalToken"))
        let reference = VM.NonOwningReference(
            kind: .unowned,
            pointee: .optional(.native(typeID)),
            target: .native(typeID)
        )
        try reference.store(object: nil, mode: .initialize)

        #expect(try reference.loadObject(mode: .take) == nil)
        #expect(throws: VM.RuntimeTrap.uninitializedAddress) {
            try reference.loadObject(mode: .copy)
        }
        #expect(throws: VM.RuntimeTrap.uninitializedAddress) {
            try reference.store(object: nil, mode: .assign)
        }
    }

    private final class ReferenceToken: @unchecked Sendable {
        let label: String

        init(label: String) {
            self.label = label
        }
    }
}
}
