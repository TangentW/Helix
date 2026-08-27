import Foundation
import HelixCore
import HelixVerifier
import HelixVM
import Testing
@testable import HelixRuntime

extension RuntimeTests {
@Suite("Data-driven Objective-C TypeOps")
struct ObjectiveCTypeOperations {
    @Test("Shell runtime identity accepts subclasses and rejects other objects")
    func buildsCheckedReferenceOperations() throws {
        let typeID = Core.TypeID(rawValue: .sha256("NSString.TypeID"))
        let shellType = Verification.ResolvedNativeType(
            id: typeID,
            canonicalName: "Foundation.NSString",
            kind: .reference,
            layoutFingerprint: .sha256("NSString.layout"),
            objectiveCRuntimeName: "NSString",
            isCopyable: true,
            estimatedSize: 8
        )
        let operations = try Runtime.ObjectiveCTypeOperations.make(
            shellType: shellType
        )
        let string = NSMutableString(string: "value")
        let boxed = try operations.box(string)
        let decoded: NSMutableString? = boxed.value()

        #expect(decoded === string)
        #expect(operations.referenceClass?.metatype === NSString.self)
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try operations.box(NSObject())
        }
    }

    @Test("Unavailable and non-reference Shell identities fail closed")
    func rejectsInvalidMetadata() {
        let typeID = Core.TypeID(rawValue: .sha256("Missing.TypeID"))
        for shellType in [
            Verification.ResolvedNativeType(
                id: typeID,
                canonicalName: "Missing.Type",
                kind: .reference,
                layoutFingerprint: .sha256("Missing.layout"),
                objectiveCRuntimeName: "HelixDefinitelyMissingClass",
                isCopyable: true,
                estimatedSize: 8
            ),
            Verification.ResolvedNativeType(
                id: typeID,
                canonicalName: "Foundation.NSString",
                kind: .value,
                layoutFingerprint: .sha256("NSString.layout"),
                objectiveCRuntimeName: "NSString",
                isCopyable: true,
                estimatedSize: 8
            ),
        ] {
            #expect(throws: VM.RuntimeTrap.self) {
                _ = try Runtime.ObjectiveCTypeOperations.make(
                    shellType: shellType
                )
            }
        }
    }
}
}
