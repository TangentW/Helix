import Foundation
import HelixCore
import Testing
@testable import HelixCompiler

enum CompilerTests {}

extension CompilerTests {
@Suite("Patch configuration and fingerprints")
struct Foundation {
    @Test("The documented default-deny YAML subset parses without an external YAML runtime")
    func parsesConfiguration() throws {
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          CheckoutFeature:
            include:
              - Sources/Checkout/**/*.swift
            exclude:
              - Sources/Checkout/Generated/**
              - "**/*Benchmark.swift"
            nativeImports:
              candidateIndex: explicit-catalog
              emit: allowlisted
              allow:
                - StoreCore.CurrencyFormatter.format
        language:
          async: reject
          genericRoot: reject
        """)

        let module = try #require(configuration.modules["CheckoutFeature"])
        #expect(module.includes(logicalPath: "Sources/Checkout/UI/CheckoutView.swift"))
        #expect(module.includes(logicalPath: "Sources/Checkout/CheckoutView.swift"))
        #expect(!module.includes(logicalPath: "Sources/Checkout/Generated/API.swift"))
        #expect(!module.includes(logicalPath: "Sources/Checkout/UI/RenderBenchmark.swift"))
        #expect(module.nativeImports.allow == ["StoreCore.CurrencyFormatter.format"])
        #expect(module.nativeImports.candidateIndex == .explicitCatalog)
        #expect(module.nativeImports.emit == .allowlisted)
        #expect(configuration.language["async"] == "reject")
    }

    @Test("A module without an explicit include remains denied")
    func rejectsImplicitAllModule() {
        #expect(throws: PatchConfiguration.Error.missingInclude("UnsafeModule")) {
            try PatchConfiguration.Document.parse(yaml: """
            schema: 1
            modules:
              UnsafeModule:
                exclude:
                  - Generated/**
            """)
        }
    }

    @Test("Schema 1 models a bounded source NativeImport range")
    func parsesNativeImportSourceScope() throws {
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          CheckoutFeature:
            include:
              - Sources/Checkout/**/*.swift
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              allow:
                - SharedSupport.clock()
              sourceScope:
                include:
                  - Sources/Checkout/Services/**
                exclude:
                  - "**/*Unsafe.swift"
                declarations:
                  - CheckoutFeature.*
                visibility: public
                profile: bounded-read
                maximumDurationMicroseconds: 750
                allowsMainThread: false
        """)

        let imports = try #require(
            configuration.modules["CheckoutFeature"]?.nativeImports
        )
        #expect(imports.candidateIndex == .sourceAndCatalog)
        #expect(imports.emit == .scoped)
        #expect(imports.allow == ["SharedSupport.clock()"])
        let scope = try #require(imports.sourceScope)
        #expect(scope.profile == .boundedRead)
        #expect(scope.maximumDurationMicroseconds == 750)
        #expect(!scope.allowsMainThread)
        #expect(scope.includes(
            logicalPath: "Sources/Checkout/Services/Pricing.swift",
            canonicalCallee: "CheckoutFeature.price(_:)",
            accessLevel: "public"
        ))
        #expect(!scope.includes(
            logicalPath: "Sources/Checkout/Services/PricingUnsafe.swift",
            canonicalCallee: "CheckoutFeature.price(_:)",
            accessLevel: "public"
        ))
        #expect(!scope.includes(
            logicalPath: "Sources/Checkout/Services/Pricing.swift",
            canonicalCallee: "CheckoutFeature.price(_:)",
            accessLevel: "internal"
        ))
        var moduleVisible = scope
        moduleVisible.visibility = .publicAndInternal
        #expect(moduleVisible.includes(
            logicalPath: "Sources/Checkout/Services/Pricing.swift",
            canonicalCallee: "CheckoutFeature.price(_:)",
            accessLevel: "internal"
        ))
        #expect(!moduleVisible.includes(
            logicalPath: "Sources/Checkout/Services/Pricing.swift",
            canonicalCallee: "CheckoutFeature.price(_:)",
            accessLevel: "private"
        ))
        var allVisible = scope
        allVisible.visibility = .all
        #expect(allVisible.includes(
            logicalPath: "Sources/Checkout/Services/Pricing.swift",
            canonicalCallee: "CheckoutFeature.price(_:)",
            accessLevel: "private"
        ))
        #expect(
            PatchConfiguration.NativeImportSourceScope(
                include: ["Sources/**"],
                profile: .boundedPure
            ).visibility == .publicOnly
        )
    }

    @Test("Source discovery requires an explicit profile and bounded deadline")
    func rejectsIncompleteNativeImportSourceScope() {
        #expect(throws: PatchConfiguration.Error.self) {
            try PatchConfiguration.Document.parse(yaml: """
            schema: 1
            modules:
              UnsafeModule:
                include:
                  - Sources/**
                nativeImports:
                  candidateIndex: source-and-catalog
                  emit: scoped
                  sourceScope:
                    include:
                      - Sources/**
            """)
        }
        #expect(throws: PatchConfiguration.Error.self) {
            try PatchConfiguration.Document.parse(yaml: """
            schema: 1
            modules:
              InvalidModule:
                include:
                  - Sources/**
                nativeImports:
                  candidateIndex: source-and-catalog
                  emit: scoped
                  sourceScope:
                    include:
                      - Sources/**
                    profile: bounded-pure
                    maximumDurationMicroseconds: 2001
            """)
        }
    }

    @Test("NativeImport configuration requires an explicit mode")
    func rejectsAllowOnlyShorthand() {
        let configuration = PatchConfiguration.Document(
            modules: [
                "Fixture": .init(
                    include: ["Sources/**"],
                    nativeImports: .init(allow: ["Fixture.value()"])
                ),
            ]
        )

        #expect(throws: PatchConfiguration.Error.invalid(
            "module Fixture has an incomplete or incompatible NativeImport mode"
        )) {
            try configuration.validate()
        }
    }

    @Test("SIL SSA and block numbering do not affect a body fingerprint")
    func normalizesSILNumbering() {
        let first = """
        bb0(%0 : $Builtin.Int64):
          %1 = integer_literal $Builtin.Int64, 27 // source noise
          %2 = builtin "sadd_with_overflow_Int64"(%0, %1)
          return %2
        """
        let second = """
        bb9(%40 : $Builtin.Int64):
          %99 = integer_literal $Builtin.Int64, 27
          %101 = builtin "sadd_with_overflow_Int64"(%40, %99)
          return %101
        """
        #expect(ReleaseCompiler.BodyFingerprint.compute(first) == ReleaseCompiler.BodyFingerprint.compute(second))
    }

    @Test("SIL comments are ignored without truncating string literal contents")
    func preservesCommentMarkersInsideStringLiterals() {
        let first = """
        %0 = string_literal utf8 "https://one.example/path" // source noise
        return %0
        """
        let equivalent = """
        %42 = string_literal utf8 "https://one.example/path" // different source noise
        return %42
        """
        let changed = """
        %99 = string_literal utf8 "https://two.example/path" // source noise
        return %99
        """

        #expect(ReleaseCompiler.BodyFingerprint.compute(first) == ReleaseCompiler.BodyFingerprint.compute(equivalent))
        #expect(ReleaseCompiler.BodyFingerprint.compute(first) != ReleaseCompiler.BodyFingerprint.compute(changed))
    }

    @Test("Canonical numbering follows first occurrence, not reverse replacement order")
    func canonicalNumberingUsesSourceOrder() {
        let equivalentA = """
        bb0(%10 : $Builtin.Int64, %20 : $Builtin.Int64):
          %30 = tuple (%10, %20)
          return %30
        """
        let equivalentB = """
        bb7(%900 : $Builtin.Int64, %100 : $Builtin.Int64):
          %42 = tuple (%900, %100)
          return %42
        """
        let operandsSwapped = """
        bb7(%900 : $Builtin.Int64, %100 : $Builtin.Int64):
          %42 = tuple (%100, %900)
          return %42
        """
        #expect(ReleaseCompiler.BodyFingerprint.compute(equivalentA) == ReleaseCompiler.BodyFingerprint.compute(equivalentB))
        #expect(ReleaseCompiler.BodyFingerprint.compute(equivalentA) != ReleaseCompiler.BodyFingerprint.compute(operandsSwapped))
    }

    @Test("Interface changes are distinguished from body-only changes")
    func classifiesDiff() throws {
        let namespace = Core.ShellNamespaceID.derive(bundleID: "dev.helix.compiler", buildNumber: "1", seed: "fixture")
        let signature = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func transform(_: Int) -> Int",
            loweredSignature: signature,
            role: .function
        )
        let interface = ReleaseCompiler.DeclarationInterface(
            declarationKind: "function",
            baseName: "transform",
            argumentLabels: ["_"],
            accessLevel: "internal",
            canonicalFormalType: "(Swift.Int) -> Swift.Int",
            loweredSILType: "@convention(thin) (Int) -> Int"
        )
        let baseline = try ReleaseCompiler.FunctionSnapshot(key: key, interface: interface, canonicalSILBody: "return %0")
        let changedBody = try ReleaseCompiler.FunctionSnapshot(key: key, interface: interface, canonicalSILBody: "%1 = integer_literal $Builtin.Int64, 1\nreturn %1")
        var changedInterface = interface
        changedInterface.canonicalFormalType = "(Swift.Int, Swift.Int) -> Swift.Int"
        let incompatible = try ReleaseCompiler.FunctionSnapshot(key: key, interface: changedInterface, canonicalSILBody: "return %0")

        guard case .bodyChanged = changedBody.difference(from: baseline) else {
            Issue.record("expected a body-only change")
            return
        }
        guard case .interfaceChanged = incompatible.difference(from: baseline) else {
            Issue.record("expected an interface change")
            return
        }
    }
}

@Suite("Real Swift frontend adapter")
struct Frontend {
    @Test("Semantic lowering arguments are explicit, executable-aware, and idempotent")
    func semanticLoweringArguments() {
        let profile = SwiftFrontend.CanonicalSILPurpose.semanticLowering
        let option = SwiftFrontend.CanonicalSILPurpose.semanticPreservationOption

        #expect(
            profile.applying(
                to: ["-parse-as-library"],
                compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
            ) == ["-parse-as-library", "-Xfrontend", option]
        )
        #expect(
            profile.applying(
                to: [option],
                compilerURL: URL(fileURLWithPath: "/toolchain/usr/bin/swift-frontend")
            ) == [option]
        )
        #expect(
            profile.applying(
                to: ["-Xfrontend=\(option)"],
                compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
            ) == ["-Xfrontend=\(option)"]
        )
        #expect(
            SwiftFrontend.CanonicalSILPurpose.implementationIdentity.applying(
                to: ["-parse-as-library"],
                compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
            ) == ["-parse-as-library"]
        )
    }

    @Test("A normal Swift file is compiled to canonical SIL")
    func emitsCanonicalSIL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-frontend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Patch.swift")
        try Data("public func transform(_ x: Int) -> Int { x + 27 }\n".utf8).write(to: source)

        let sil = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [source],
            moduleName: "HelixFrontendFixture"
        )
        #expect(sil.contains("sil_stage canonical"))
        #expect(sil.contains("sadd_with_overflow_Int64"))
        #expect(sil.contains("transform"))
    }
}
}
