import Foundation
@testable import HelixHubCore
import Testing

@Suite("Helix Hub CocoaPods discovery")
struct CocoaPodsDiscoveryTests {
    @Test("Nested xcconfig includes resolve only App-facing Helix Pods")
    func resolvesRuntimeProducts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-pods-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent(
            "Pods/Target Support Files/Pods-App",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(
            "#include? \"Pods/Target Support Files/Pods-App/Pods-App.debug.xcconfig\"\n".utf8
        ).write(to: root.appendingPathComponent("App.xcconfig"))
        try Data(
            """
            // OTHER_LDFLAGS = -framework "HelixAppRuntime"
            OTHER_LDFLAGS = $(inherited) -framework "Foundation" -framework "HelixDevAppRuntime"
            FRAMEWORK_SEARCH_PATHS = $(inherited) "${PODS_CONFIGURATION_BUILD_DIR}/HelixCompiler"
            """.utf8
        ).write(to: support.appendingPathComponent("Pods-App.debug.xcconfig"))

        let products = Hub.CocoaPodsRuntimeResolver(sourceRootURL: root).products(
            referencedBy: ["App.xcconfig"]
        )
        #expect(products == ["HelixDevAppRuntime"])
    }

    @Test("Static-library linker flags identify the aggregate Pod")
    func resolvesStaticLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-static-pod-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(
            "OTHER_LDFLAGS = $(inherited) -ObjC -l\"HelixAppRuntime\"\n".utf8
        ).write(to: root.appendingPathComponent("Pods-App.release.xcconfig"))

        #expect(Hub.CocoaPodsRuntimeResolver(sourceRootURL: root).products(
            referencedBy: ["Pods-App.release.xcconfig"]
        ) == ["HelixAppRuntime"])
    }

    @Test("Dependency-manager products share one target-level query")
    func combinesRuntimeProducts() {
        let target = Hub.XcodeTarget(
            id: "app",
            name: "App",
            productName: "App",
            buildableName: "App.app",
            productType: nil,
            kind: .application,
            configurationNames: ["Debug"],
            sourceFiles: [],
            packageProducts: ["HelixAppRuntime"],
            baseConfigurationPaths: [:],
            cocoaPodsProductsByConfiguration: [
                "Debug": ["HelixDevAppRuntime"],
            ]
        )
        #expect(target.linkedRuntimeProducts == [
            "HelixAppRuntime", "HelixDevAppRuntime",
        ])
        #expect(target.linksRuntimeProduct("HelixAppRuntime"))
        #expect(target.linksRuntimeProduct("HelixDevAppRuntime"))
        #expect(target.linksRuntimeProduct(
            "HelixDevAppRuntime",
            configurationName: "Debug"
        ))
        #expect(!target.linksRuntimeProduct(
            "HelixDevAppRuntime",
            configurationName: "Release"
        ))
        #expect(!target.linksRuntimeProduct("HelixCompiler"))
    }

    @Test("Includes cannot escape the selected project root")
    func confinesIncludes() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-pods-boundary-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = parent.appendingPathComponent("Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#include \"../External.xcconfig\"\n".utf8).write(
            to: root.appendingPathComponent("App.xcconfig")
        )
        try Data("OTHER_LDFLAGS = -framework \"HelixAppRuntime\"\n".utf8).write(
            to: parent.appendingPathComponent("External.xcconfig")
        )

        #expect(
            Hub.CocoaPodsRuntimeResolver(sourceRootURL: root).products(
                referencedBy: ["App.xcconfig"]
            ).isEmpty
        )
    }

    @Test("Similar xcconfig directives cannot spoof runtime linkage")
    func rejectsLookalikeDirectives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-hub-pods-lookalikes-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(
            """
            #included "Fake.xcconfig"
            OTHER_LDFLAGS_BACKUP = -framework "HelixAppRuntime"
            """.utf8
        ).write(to: root.appendingPathComponent("App.xcconfig"))
        try Data("OTHER_LDFLAGS = -framework \"HelixDevAppRuntime\"\n".utf8).write(
            to: root.appendingPathComponent("Fake.xcconfig")
        )

        #expect(
            Hub.CocoaPodsRuntimeResolver(sourceRootURL: root).products(
                referencedBy: ["App.xcconfig"]
            ).isEmpty
        )
    }
}
