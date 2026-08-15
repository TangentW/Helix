import Foundation
import HelixInterface
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Captured SDK symbol graphs")
struct SymbolGraph {
    @Test("Partial SDK versions normalize omitted components")
    func normalizesPartialVersions() throws {
        let version = try JSONDecoder().decode(
            SwiftFrontend.SymbolGraph.Version.self,
            from: Data(#"{"major":15}"#.utf8)
        )

        #expect(version == .init(major: 15, minor: 0, patch: 0))
    }

    @Test("UIKit and Foundation expose common Swift API shapes deterministically")
    func extractsCommonSDKSurface() throws {
        let frontend = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
        )
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: "SymbolGraphFixture",
            targetTriple: "arm64-apple-ios15.0-simulator",
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion,
            optimization: "-Onone",
            semanticArguments: ["-parse-as-library"]
        )

        let uikit = try frontend.emitSymbolGraph(
            moduleName: "UIKit",
            invocation: invocation
        )
        let foundation = try frontend.emitSymbolGraph(
            moduleName: "Foundation",
            invocation: invocation
        )

        #expect(uikit.module.name == "UIKit")
        #expect(foundation.module.name == "Foundation")
        #expect(uikit.metadata.generator == foundation.metadata.generator)
        #expect(uikit.symbols.count > 1_000)
        #expect(foundation.symbols.count > 1_000)

        let uikitProperties = Set(uikit.symbols.compactMap { symbol in
            symbol.kind.identifier == "swift.type.property"
                ? symbol.pathComponents.joined(separator: ".") : nil
        })
        for property in [
            "UIColor.black",
            "UIScreen.main",
            "UIDevice.current",
            "UIApplication.shared",
            "UIView.areAnimationsEnabled",
        ] {
            #expect(uikitProperties.contains(property))
        }

        let foundationProperties = Set(foundation.symbols.compactMap { symbol in
            symbol.kind.identifier == "swift.type.property"
                ? symbol.pathComponents.joined(separator: ".") : nil
        })
        for property in [
            "Bundle.main",
            "Calendar.current",
            "FileManager.default",
            "Locale.current",
            "NotificationCenter.default",
            "ProcessInfo.processInfo",
        ] {
            #expect(foundationProperties.contains(property))
        }

        let view = try #require(uikit.symbols.first { symbol in
            symbol.kind.identifier == "swift.class"
                && symbol.pathComponents == ["UIView"]
        })
        #expect(view.declarationFragments.contains {
            $0.preciseIdentifier == "s:ScM" && $0.spelling == "MainActor"
        })

        let animation = try #require(uikit.symbols.first { symbol in
            symbol.kind.identifier == "swift.type.method"
                && symbol.pathComponents == [
                    "UIView", "animate(withDuration:animations:)",
                ]
        })
        let parameters = try #require(animation.functionSignature?.parameters)
        #expect(parameters.count == 2)
        #expect(parameters[1].declarationFragments.contains {
            $0.spelling.contains("->")
        })
    }

    @Test("Symbol graph module names are code-generation safe")
    func rejectsUnsafeModuleNames() throws {
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: "SymbolGraphFixture",
            targetTriple: "arm64-apple-ios15.0-simulator",
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion
        )

        #expect(throws: SwiftFrontend.Error.invalidSymbolGraph(
            "module name is not a Swift identifier"
        )) {
            _ = try frontend.emitSymbolGraph(
                moduleName: "UIKit; fatalError()",
                invocation: invocation
            )
        }
        #expect(throws: SwiftFrontend.Error.invalidSymbolGraph(
            "module name is not a Swift identifier"
        )) {
            _ = try frontend.emitSymbolGraph(
                moduleName: String(repeating: "A", count: 513),
                invocation: invocation
            )
        }
        let unmatchedToolchain = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/tmp/helix-missing-toolchain/swiftc")
        )
        #expect(throws: SwiftFrontend.Error.launchFailed(
            "captured Swift toolchain has no swift-symbolgraph-extract sibling"
        )) {
            _ = try unmatchedToolchain.emitSymbolGraph(
                moduleName: "UIKit",
                invocation: invocation
            )
        }
    }
}
}
