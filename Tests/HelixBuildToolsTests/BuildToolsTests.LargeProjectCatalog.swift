import Foundation
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Large-project Catalog rejection provenance")
struct LargeProjectCatalog {
    @Test("A superclass constructor USR cannot authenticate a subclass construction candidate")
    func rejectsAncestorConstructionIdentity() {
        let nominalUSR = "c:@M@Vendor@objc(cs)Child"
        let candidate = FrontendReceipt.ManagedNativeSurface.Candidate(preciseIdentifier: nominalUSR + "#zero-argument-construction",
            moduleName: "Vendor", probeOwnerType: "Vendor.Child", ownerType: "Vendor.Child", dispatch: .initializer,
            memberName: "init", argumentLabels: [], parameterTypes: [], resultType: "Vendor.Child", sourceFileLogicalID: "Vendor.swift",
            importedModules: ["Vendor", "UIKit"], requiresMainActor: true, allowsMainActorInference: false, mayThrow: false)
        var operation = FrontendReceipt.Adapter.ImportedOperation(silReferences: ["$sVendorChildInit"], sourceFileLogicalID: "Vendor.swift",
            importedModules: ["Vendor", "UIKit"], dispatch: .initializer, ownerType: "UIView", baseName: "init", argumentLabels: [],
            parameterSwiftTypes: [], resultSwiftType: "Vendor.Child", requiresMainActor: true,
            declarationUSR: "c:objc(cs)NSObject(im)init")
        let types = ["Vendor.Child", "UIView"].map { name in
            FrontendReceipt.ManagedNativeSurface.ProbeNativeType(.init(canonicalName: name, swiftType: name,
                kind: .reference, aliases: [], representation: .reference, sourceFileLogicalID: "Vendor.swift",
                importedModules: ["Vendor", "UIKit"], requiresMainActor: true))
        }
        #expect(!FrontendReceipt.ManagedNativeSurface.operation(operation, matches: candidate, probeTypes: types))
        operation.declarationUSR = nominalUSR + "Extra(im)init"
        #expect(!FrontendReceipt.ManagedNativeSurface.operation(operation, matches: candidate, probeTypes: types))
        operation.ownerType = "Vendor.Child"
        operation.declarationUSR = nominalUSR + "(im)init"
        #expect(FrontendReceipt.ManagedNativeSurface.operation(operation, matches: candidate, probeTypes: types))
    }

    @Test("Inherited construction and custom actors do not poison unrelated candidates or their cache")
    func isolatesMeasuredCandidates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helix-catalog-rejection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Data("""
        import Foundation
        public final class BorrowedInit: NSObject {}
        @globalActor public enum WorkerActor {
            public actor Worker {}
            public static let shared = Worker()
        }
        @WorkerActor public final class Isolated {
            public var value: Int = 1
            public init() {}
        }
        public func healthy(_ value: Int) -> Int { value + 1 }
        """.utf8)
        let sourceURL = directory.appendingPathComponent("Fixture.swift")
        try source.write(to: sourceURL)
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let toolchain = try ReleaseCompiler.Driver().toolchainIdentity()
        let target = "arm64-apple-ios17.0-simulator"
        let module = "RejectionFixture"
        let compilation = try frontend.run(arguments: ["-emit-module", "-parse-as-library", "-module-name", module,
            "-target", target, "-sdk", sdk.path, sourceURL.path, "-o", directory.appendingPathComponent(module + ".swiftmodule").path])
        try #require(compilation.terminationStatus == 0, "\(compilation.standardError)")
        let identity = NativeAPICatalog.Identity(provenance: .thirdPartyModule, xcodeProductBuild: "fixture",
            sdkProductBuild: sdk.buildVersion, compilerFingerprint: toolchain.fingerprint, targetTriple: target,
            minimumDeployment: .init(17), swiftLanguageMode: "5", moduleName: module, moduleContentHash: .sha256(source),
            moduleSearchPathHash: .sha256("fixture-search"), dependencyGraphHash: .sha256("Foundation"))
        let invocation = InterfaceArchive.FrontendInvocation(moduleName: "RejectionConsumer", targetTriple: target,
            sdkName: sdk.name, sdkBuild: sdk.buildVersion, optimization: "-Onone", semanticArguments: ["-parse-as-library", "-I", directory.path])
        let request = NativeAPICatalog.BuildRequest(identity: identity, frontendInvocation: invocation,
            precomputedToolchain: toolchain, precomputedSDK: sdk)
        let builder = try NativeAPICatalog.Builder(cache: .init(rootURL: directory.appendingPathComponent("Cache")))
        let cold = try builder.build(request)
        let warm = try builder.build(request)
        #expect(cold.snapshot.document.entries.contains { $0.swiftNames.contains { $0.contains("healthy") } })
        #expect(!cold.metrics.rejectionReasons.isEmpty)
        #expect(cold.metrics.rejectionReasons.contains { $0.contains("actor") && $0.contains("Isolated") })
        #expect(warm.metrics.rejectionReasons == cold.metrics.rejectionReasons)
        #expect(warm.metrics.cacheSource == .hit && warm.metrics.probeAttemptCount == 0)
        #expect(warm.snapshot.document == cold.snapshot.document)
        try cold.snapshot.document.validate()
        let header = """
        #import <UIKit/UIKit.h>
        @interface BorrowedParent : UIView
        @property(nonatomic) NSInteger parentValue;
        @end
        @interface BorrowedChild : BorrowedParent
        @property(nonatomic) NSInteger childValue;
        @end
        int healthyC(int value);
        """
        try Data(header.utf8).write(to: directory.appendingPathComponent("Borrowed.h"))
        try Data("module BorrowedFixture { header \"Borrowed.h\" export * }".utf8).write(to: directory.appendingPathComponent("module.modulemap"))
        var inheritedRequest = request
        inheritedRequest.identity.moduleName = "BorrowedFixture"
        inheritedRequest.identity.moduleContentHash = .sha256(header)
        let inherited = try builder.build(inheritedRequest)
        #expect(inherited.snapshot.document.entries.contains { $0.swiftNames.contains { $0.contains("healthyC") } })
        try inherited.snapshot.document.validate()
        let inheritedWarm = try builder.build(inheritedRequest)
        #expect(inheritedWarm.metrics.cacheSource == .hit && inheritedWarm.metrics.rejectionReasons == inherited.metrics.rejectionReasons)
    }
}
}
