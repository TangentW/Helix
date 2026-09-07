import Foundation
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Runtime package requirement contract")
struct RuntimePackageRequirementTests {
    @Test("Exact remote pins validate and require Host Plan schema 2")
    func validatesPinMigration() throws {
        var plan = XcodeIntegration.HostPlan(projectPath: "Example.xcodeproj",
            features: [.init(id: "app", targetName: "Example", moduleName: "Example")],
            profiles: [.init(id: "live", workflow: .liveReload, schemeName: "Example", applicationTargetName: "Example",
                configurationName: "Debug", bundleIdentifier: "dev.example.app", namespaceSeed: "fixture", featureID: "app")])
        let legacy = try XcodeIntegration.HostPlanCodec.encode(plan)
        for requirement in [XcodeIntegration.RuntimePackageRequirement(kind: .revision, value: String(repeating: "a", count: 40)),
                            .init(kind: .exactVersion, value: "1.2.3")] {
            plan.runtimePackageRequirement = requirement
            let bytes = try XcodeIntegration.HostPlanCodec.encode(plan)
            #expect(try XcodeIntegration.HostPlanCodec.decode(bytes) == plan)
            plan.schemaVersion = 1
            #expect(throws: XcodeIntegration.Error.self) { try plan.validate() }
            plan.schemaVersion = 2
        }
        plan.runtimePackageRequirement = nil
        #expect(try XcodeIntegration.HostPlanCodec.encode(plan) == legacy)
        for value in ["main", "abc", String(repeating: "A", count: 40), String(repeating: "a", count: 41)] {
            #expect(throws: XcodeIntegration.Error.self) {
                try XcodeIntegration.RuntimePackageRequirement(kind: .revision, value: value).validate()
            }
        }
        for value in ["", "v1.2.3", "1.2", "01.2.3", "1.2.3-beta", "1.2.3\n"] {
            #expect(throws: XcodeIntegration.Error.self) {
                try XcodeIntegration.RuntimePackageRequirement(kind: .exactVersion, value: value).validate()
            }
        }
    }
}
}
