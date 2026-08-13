import XCTest

#if canImport(HelixCore)
#error("CocoaPods must expose the App runtime through its aggregate module")
#elseif canImport(HelixAppRuntime)
import HelixAppRuntime
#else
#error("HelixAppRuntime is unavailable to its CocoaPods consumer test")
#endif

final class HelixAppRuntimeConsumerTests: XCTestCase {
    func testProductionNamespacesAreExported() {
        XCTAssertEqual(Core.Versions.runtime, Core.SemanticVersion(0, 1, 0))
        XCTAssertEqual(PatchPackage.Metadata.version, Core.SemanticVersion(1, 0, 0))
        let bridgeTypes: [Any.Type] = [
            Bytecode.Module.self,
            Runtime.Engine.self,
            Verification.Engine.self,
            VM.NativeTypeCatalog.self,
        ]
        XCTAssertEqual(bridgeTypes.count, 4)
    }
}
