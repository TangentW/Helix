import XCTest

#if canImport(HelixDevProtocol)
#error("CocoaPods must expose the Dev runtime through its aggregate module")
#elseif canImport(HelixDevAppRuntime)
import HelixDevAppRuntime
#else
#error("HelixDevAppRuntime is unavailable to its CocoaPods consumer test")
#endif

final class HelixDevAppRuntimeConsumerTests: XCTestCase {
    func testDevelopmentNamespacesAreExported() {
        XCTAssertEqual(Core.Versions.runtime, Core.SemanticVersion(0, 1, 0))
        XCTAssertEqual(DevRuntime.Metadata.version, Core.SemanticVersion(1, 0, 0))
        XCTAssertEqual(DevProtocol.Metadata.currentProtocolVersion, 3)
        XCTAssertNotNil(try? Pairing.Code("AB2C"))
        let bridgeTypes: [Any.Type] = [
            Bytecode.Module.self,
            Runtime.Engine.self,
            Verification.Engine.self,
            VM.NativeTypeCatalog.self,
        ]
        XCTAssertEqual(bridgeTypes.count, 4)
    }
}
