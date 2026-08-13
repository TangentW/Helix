// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Helix",
    platforms: [
        .macOS(.v14),
        .iOS(.v15),
    ],
    products: [
        // Release targets link only this aggregate product. Dev transport,
        // dynamic loading, and the debug overlay are intentionally absent.
        .library(
            name: "HelixAppRuntime",
            targets: [
                "HelixCore", "HelixBytecode", "HelixInterface", "HelixVerifier",
                "HelixVM", "HelixRuntimeSupport", "HelixRuntime",
                "HelixPatch",
            ]
        ),
        // A dedicated Debug/Dev target links this product instead of combining
        // HelixAppRuntime with leaf products that repeat the same Swift modules.
        .library(
            name: "HelixDevAppRuntime",
            targets: [
                "HelixCore", "HelixBytecode", "HelixInterface", "HelixVerifier",
                "HelixVM", "HelixRuntimeSupport", "HelixRuntime", "HelixPatch",
                "HelixLiveReloadAPI", "HelixDevProtocol",
                "HelixDevRuntime",
            ]
        ),
        .library(name: "HelixCore", targets: ["HelixCore"]),
        .library(name: "HelixBytecode", targets: ["HelixBytecode"]),
        .library(name: "HelixInterface", targets: ["HelixInterface"]),
        .library(name: "HelixVerifier", targets: ["HelixVerifier"]),
        .library(name: "HelixVM", targets: ["HelixVM"]),
        .library(name: "HelixRuntime", targets: ["HelixRuntime"]),
        .library(name: "HelixCompiler", targets: ["HelixCompiler"]),
        .library(name: "HelixPatch", targets: ["HelixPatch"]),
        .library(name: "HelixReleaseTools", targets: ["HelixReleaseTools"]),
        .library(name: "HelixBuildTools", targets: ["HelixBuildTools"]),
        .library(name: "HelixDevProtocol", targets: ["HelixDevProtocol"]),
        .library(name: "HelixDevTools", targets: ["HelixDevTools"]),
        .library(name: "HelixDevRuntime", targets: ["HelixDevRuntime"]),
        .library(name: "HelixHubCore", targets: ["HelixHubCore"]),
        .executable(name: "helix", targets: ["HelixCLI"]),
        .executable(name: "helix-benchmark", targets: ["HelixBenchmarkCLI"]),
    ],
    targets: [
        .target(name: "HelixCore"),
        .target(name: "HelixBytecode", dependencies: ["HelixCore"]),
        .target(name: "HelixInterface", dependencies: ["HelixCore", "HelixBytecode"]),
        .target(name: "HelixVerifier", dependencies: ["HelixCore", "HelixBytecode", "HelixInterface"]),
        .target(name: "HelixVM", dependencies: ["HelixCore", "HelixBytecode", "HelixVerifier"]),
        .target(
            name: "HelixRuntimeSupport",
            path: "Sources/HelixRuntimeSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "HelixRuntime",
            dependencies: [
                "HelixCore", "HelixBytecode", "HelixVerifier", "HelixVM",
                "HelixRuntimeSupport",
            ]
        ),
        .target(name: "HelixCompiler", dependencies: ["HelixCore", "HelixBytecode", "HelixInterface"]),
        .target(name: "HelixPatch", dependencies: ["HelixCore", "HelixBytecode", "HelixVerifier", "HelixRuntime"]),
        .target(
            name: "HelixReleaseTools",
            dependencies: [
                "HelixCore", "HelixBytecode", "HelixInterface",
                "HelixCompiler", "HelixVerifier", "HelixPatch",
            ]
        ),
        // Shared only inside the Dev graph. It is intentionally not a
        // standalone product and must never enter HelixAppRuntime.
        .target(name: "HelixLiveReloadAPI", dependencies: ["HelixCore"]),
        .target(name: "HelixDevProtocol", dependencies: ["HelixCore", "HelixLiveReloadAPI"]),
        .target(
            name: "HelixBuildTools",
            dependencies: [
                "HelixCore", "HelixBytecode", "HelixInterface", "HelixCompiler",
                "HelixDevProtocol", "HelixLiveReloadAPI",
            ]
        ),
        .target(
            name: "HelixDevTools",
            dependencies: [
                "HelixCore", "HelixCompiler", "HelixInterface", "HelixPatch", "HelixRuntime",
                "HelixDevProtocol", "HelixLiveReloadAPI",
            ]
        ),
        .target(
            name: "HelixDevRuntime",
            dependencies: [
                "HelixCore", "HelixBytecode", "HelixVerifier", "HelixVM", "HelixRuntime",
                "HelixDevProtocol", "HelixLiveReloadAPI",
            ]
        ),
        .target(
            name: "HelixHubCore",
            dependencies: [
                "HelixCore", "HelixBuildTools", "HelixDevProtocol",
                "HelixDevTools", "HelixPatch", "HelixReleaseTools",
            ]
        ),
        .target(
            name: "HelixBenchmarks",
            dependencies: [
                "HelixCore", "HelixBytecode", "HelixVerifier", "HelixVM", "HelixRuntime",
            ]
        ),
        .target(
            name: "HelixCLIKit",
            dependencies: [
                "HelixCore", "HelixBytecode", "HelixInterface", "HelixCompiler",
                "HelixPatch", "HelixReleaseTools", "HelixDevProtocol", "HelixDevTools",
                "HelixBuildTools",
            ]
        ),
        .executableTarget(
            name: "HelixCLI",
            dependencies: ["HelixCLIKit"]
        ),
        .executableTarget(
            name: "HelixBenchmarkCLI",
            dependencies: ["HelixBenchmarks", "HelixCore"]
        ),
        .testTarget(name: "HelixCoreTests", dependencies: ["HelixCore"]),
        .testTarget(name: "HelixBytecodeTests", dependencies: ["HelixBytecode"]),
        .testTarget(name: "HelixInterfaceTests", dependencies: ["HelixInterface"]),
        .testTarget(name: "HelixVerifierTests", dependencies: ["HelixVerifier", "HelixBytecode"]),
        .testTarget(name: "HelixVMTests", dependencies: ["HelixVM", "HelixVerifier", "HelixBytecode"]),
        .testTarget(name: "HelixRuntimeTests", dependencies: ["HelixRuntime", "HelixVM", "HelixVerifier", "HelixBytecode"]),
        .testTarget(
            name: "HelixCompilerTests",
            dependencies: [
                "HelixCompiler", "HelixBytecode", "HelixInterface",
                "HelixVerifier", "HelixVM", "HelixCore",
            ]
        ),
        .testTarget(
            name: "HelixPatchTests",
            dependencies: [
                "HelixPatch", "HelixRuntime", "HelixVM", "HelixVerifier",
                "HelixBytecode", "HelixCore",
            ]
        ),
        .testTarget(
            name: "HelixBuildToolsTests",
            dependencies: [
                "HelixBuildTools", "HelixCompiler", "HelixInterface",
                "HelixDevProtocol", "HelixLiveReloadAPI", "HelixBytecode", "HelixCore",
                "HelixCLIKit", "HelixDevTools", "HelixVerifier",
            ]
        ),
        .testTarget(
            name: "HelixDevProtocolTests",
            dependencies: ["HelixDevProtocol", "HelixLiveReloadAPI", "HelixCore"]
        ),
        .testTarget(
            name: "HelixDevToolsTests",
            dependencies: [
                "HelixDevTools", "HelixDevProtocol", "HelixLiveReloadAPI",
                "HelixCompiler", "HelixInterface", "HelixBytecode", "HelixCore",
            ]
        ),
        .testTarget(
            name: "HelixDevRuntimeTests",
            dependencies: [
                "HelixDevRuntime", "HelixDevTools", "HelixDevProtocol", "HelixLiveReloadAPI",
                "HelixBytecode", "HelixVerifier", "HelixVM", "HelixRuntime", "HelixCore",
            ]
        ),
        .testTarget(
            name: "HelixHubCoreTests",
            dependencies: [
                "HelixHubCore", "HelixBuildTools", "HelixDevProtocol",
                "HelixDevTools", "HelixCore", "HelixPatch", "HelixReleaseTools",
            ]
        ),
        .testTarget(
            name: "HelixDevRuntimeIOSTests",
            dependencies: [
                "HelixDevRuntime", "HelixDevProtocol", "HelixLiveReloadAPI",
                "HelixBytecode", "HelixCore", "HelixRuntime", "HelixVerifier", "HelixVM",
            ]
        ),
        .testTarget(
            name: "HelixReleaseToolsTests",
            dependencies: [
                "HelixReleaseTools", "HelixCompiler", "HelixInterface",
                "HelixPatch", "HelixRuntime", "HelixVM", "HelixVerifier",
                "HelixBytecode", "HelixCore", "HelixCLIKit",
            ]
        ),
        .testTarget(
            name: "HelixCLIKitTests",
            dependencies: [
                "HelixCLIKit", "HelixBuildTools", "HelixReleaseTools", "HelixInterface",
                "HelixBytecode", "HelixPatch", "HelixCore",
            ]
        ),
        .testTarget(
            name: "HelixBenchmarksTests",
            dependencies: ["HelixBenchmarks", "HelixCore"]
        ),
    ]
)
