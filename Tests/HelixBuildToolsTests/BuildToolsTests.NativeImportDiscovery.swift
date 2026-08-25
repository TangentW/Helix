import Foundation
import HelixBytecode
import HelixCLIKit
import HelixCompiler
import HelixCore
import HelixInterface
import HelixVerifier
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Scoped NativeImport discovery")
struct NativeImportDiscoveryTests {
    @Test("Generated adapters preserve a namespace that matches the module name")
    func preservesModuleNamedSourceNamespace() throws {
        let metadata = makeMetadata(moduleName: "Collision")
        let hostID = Core.TypeID.derive(
            namespace: metadata.shellNamespaceID,
            canonicalType: "Collision.Collision.HostViewController"
        )
        let controllerID = Core.TypeID.derive(
            namespace: metadata.shellNamespaceID,
            canonicalType: "UIViewController"
        )
        let operation = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: [],
            sourceFileLogicalID: "Sources/Application.swift",
            importedModules: ["UIKit"],
            dispatch: .nativeUpcast,
            ownerType: "UIViewController",
            baseName: "upcast",
            argumentLabels: ["_"],
            parameterSwiftTypes: ["Collision.HostViewController"],
            resultSwiftType: "UIViewController",
            requiresMainActor: true,
            compilerOperation: .nativeUpcast
        )

        let declarations = try FrontendReceipt.Adapter()
            .makeImportedOperationDeclarations(
                [operation],
                moduleName: "Collision",
                nativeTypes: [
                    "Collision.Collision.HostViewController": hostID,
                    "Collision.HostViewController": hostID,
                    "UIViewController": controllerID,
                ]
            )
        #expect(declarations.count == 1)
        let declaration = try #require(declarations.first)
        #expect(declaration.parameterSwiftTypes == ["Collision.HostViewController"])
        #expect(declaration.resultSwiftType == "UIViewController")
        #expect(declaration.parameterTypes == [.native(hostID)])
        #expect(declaration.resultType == .native(controllerID))
    }

    @Test("Measured declarations refine contextual isolation without admitting symbol aliases")
    func refinesManagedOperationIsolation() {
        let symbol = "$hlx_native_foreign_shared"
        let contextual = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: [symbol],
            sourceFileLogicalID: "Sources/Fixture.swift",
            importedModules: ["UIKit"],
            dispatch: .staticGetter,
            ownerType: "UIColor",
            baseName: "systemBlue",
            argumentLabels: [],
            parameterSwiftTypes: [],
            resultSwiftType: "UIColor",
            requiresMainActor: true
        )
        var measured = contextual
        measured.requiresMainActor = false
        measured.isolationEvidence = .importedDeclaration
        var alias = measured
        alias.ownerType = "UnrelatedColor"
        alias.resultSwiftType = "UnrelatedColor"

        let retained = FrontendReceipt.Adapter()
            .unambiguousAdditiveImportedOperations(
                [measured, alias],
                authoritative: [contextual]
            )

        #expect(retained == [measured])
    }

    @Test("Generated Swift type syntax accepts nested collections and rejects code")
    func validatesGeneratedSwiftTypeSyntax() {
        #expect(FrontendReceipt.SwiftTypeSpelling.isGeneratedType("[Swift.String: [UIKit.UIView?]]"))
        #expect(FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
            "Swift.Dictionary<Swift.String, Swift.Array<Foundation.Date>>"
        ))
        #expect(FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
            "@escaping @MainActor @Sendable (Swift.Bool, UIKit.UIView?) -> Swift.Void"
        ))
        #expect(FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
            "Swift.Optional<@Sendable (Swift.Int) -> ()>"
        ))
        #expect(FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
            "Swift.Optional<any Swift.Error>"
        ))
        #expect(FrontendReceipt.SwiftTypeSpelling.isGeneratedType("UIKit.UIView!"))
        #expect(!FrontendReceipt.SwiftTypeSpelling.isGeneratedType("UIKit.UIView!!"))
        #expect(!FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
            "Swift.Array<UIKit.UIView!>"
        ))
        #expect(FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
            "(@escaping (Swift.Int) -> Swift.Void) -> Swift.Void"
        ))
        #expect(FrontendReceipt.SwiftTypeSpelling.isGeneratedType("(Foundation.Date, UIKit.UIView?)"))
        #expect(!FrontendReceipt.SwiftTypeSpelling.isGeneratedType("UIKit.UIView; fatalError()"))
        #expect(!FrontendReceipt.SwiftTypeSpelling.isGeneratedType("[Swift.String:]"))
        #expect(!FrontendReceipt.SwiftTypeSpelling.isGeneratedType("Swift.Array<UIKit.UIView"))
        #expect(!FrontendReceipt.SwiftTypeSpelling.isGeneratedType("() async -> Swift.Void"))
        #expect(!FrontendReceipt.SwiftTypeSpelling.isGeneratedType("() throws -> Swift.Void"))
        #expect(!FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
            "@convention(c) () -> Swift.Void"
        ))
        #expect(!FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
            "any Swift.Error; fatalError()"
        ))
        #expect(!FrontendReceipt.SwiftTypeSpelling.isGeneratedType(
            "any any Swift.Error"
        ))
        #expect(
            FrontendReceipt.FunctionTypeSpelling
                .applyingInheritedGlobalActor(
                    "MainActor",
                    to: "Swift.Optional<(UIKit.UIButton) -> Swift.Void>"
                )
                == "Swift.Optional<@MainActor (UIKit.UIButton) -> ()>"
        )
        #expect(
            FrontendReceipt.FunctionTypeSpelling
                .applyingInheritedGlobalActor(
                    "MainActor",
                    to: "@escaping @Sendable () -> Swift.Void"
                )
                == "@escaping @Sendable () -> ()"
        )
        let aliases = [
            "NSBundle": "Bundle",
            "NSProcessInfo": "ProcessInfo",
            "__C.NSBundle": "Bundle",
        ]
        #expect(FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
            in: "[Swift.String: Swift.Array<NSBundle?>]",
            aliases: aliases
        ) == "[Swift.String: Swift.Array<Bundle?>]")
        #expect(FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
            in: "(value: NSBundle, transform: (NSProcessInfo) -> NSBundle?)",
            aliases: aliases
        ) == "(value: Bundle, transform: (ProcessInfo) -> Bundle?)")
        #expect(FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
            in: "(__C.NSBundle.Type, NSBundle.Nested?)",
            aliases: aliases
        ) == "(Bundle.Type, Bundle.Nested?)")

        let sourceParameters = #"""
        (
            _ manager: Foundation.FileManager,
            completion: @escaping (Swift.Result<String, Error>) -> Void = { _ in },
            options: [String: (Int, Bool)] = /* outer, /* nested: */ */ ["value": (1, true)],
            message: String = """
            escaped terminator: \"""
            comma, colon:
            """,
            raw: String = #"comma, colon: value"#
        )
        """#
        #expect(FrontendReceipt.SourceParameterSpelling.types(
            in: sourceParameters
        ) == [
            "Foundation.FileManager",
            "@escaping (Swift.Result<String, Error>) -> Void",
            "[String: (Int, Bool)]",
            "String",
            "String",
        ])
        #expect(FrontendReceipt.SourceParameterSpelling.types(
            in: "(_ value: UIKit.UIView; fatalError())"
        ) == nil)
        #expect(FrontendReceipt.SourceParameterSpelling.types(
            in: "(_ value: String = \"\\(untrusted)\")"
        ) == nil)

        let nestedParameters = """
        (_ value: Mode = .idle, transform: @escaping (Mode) -> Mode)
        """
        let nestedDeclaration = "func map" + nestedParameters
            + " -> (Mode) -> Mode where Mode == Mode"
        let nestedParameterRange = Range(
            uncheckedBounds: (
                lower: "func map".utf8.count,
                upper: "func map".utf8.count + nestedParameters.utf8.count
            )
        )
        #expect(FrontendReceipt.SourceFunctionSpelling.replacingNominalAliases(
            in: nestedDeclaration,
            parameterUTF8Range: nestedParameterRange,
            aliases: ["Mode": "Values.Mode"]
        ) == "func map(_ value: Values.Mode = .idle, "
            + "transform: @escaping (Values.Mode) -> Values.Mode) "
            + "-> (Values.Mode) -> Values.Mode where Mode == Mode")
        #expect(FrontendReceipt.SourceFunctionSpelling.replacingNominalAliases(
            in: nestedDeclaration,
            parameterUTF8Range: 0..<1,
            aliases: ["Mode": "Values.Mode"]
        ) == nil)
    }

    @Test("Objective-C protocol manglings are distinguished from Any")
    func recognizesObjectiveCProtocolMangledTypes() {
        #expect(FrontendReceipt.Adapter.objectiveCProtocolNames(
            inMangledType: "$syySo13UIInteraction_pScMYccD"
        ) == ["UIInteraction"])
        #expect(FrontendReceipt.Adapter.objectiveCProtocolNames(
            inMangledType: "$sSo13UIInteraction_pSgD"
        ) == ["UIInteraction"])
        #expect(FrontendReceipt.Adapter.objectiveCProtocolNames(
            inMangledType: "$sypSgD"
        ).isEmpty)
        #expect(FrontendReceipt.Adapter.objectiveCProtocolNames(
            inMangledType: "$syXlSgD"
        ).isEmpty)
    }

    @Test("Managed SDK availability rejects unstable generated candidates")
    func filtersManagedSDKAvailability() throws {
        func availability(
            _ json: String
        ) throws -> [SwiftFrontend.SymbolGraph.Availability] {
            try JSONDecoder().decode(
                [SwiftFrontend.SymbolGraph.Availability].self,
                from: Data(json.utf8)
            )
        }

        let minimumOS = Core.SemanticVersion(15)
        #expect(FrontendReceipt.ManagedDebugSurface.supportsAvailability(
            [],
            minimumOS: minimumOS
        ))
        #expect(FrontendReceipt.ManagedDebugSurface.supportsAvailability(
            try availability(#"[{"domain":"iOS","introduced":{"major":15}}]"#),
            minimumOS: minimumOS
        ))
        #expect(!FrontendReceipt.ManagedDebugSurface.supportsAvailability(
            try availability(#"[{"domain":"iOS","introduced":{"major":16}}]"#),
            minimumOS: minimumOS
        ))
        #expect(!FrontendReceipt.ManagedDebugSurface.supportsAvailability(
            try availability(#"[{"domain":"iOS","deprecated":{"major":18}}]"#),
            minimumOS: minimumOS
        ))
        #expect(!FrontendReceipt.ManagedDebugSurface.supportsAvailability(
            try availability(#"[{"domain":"iOS","obsoleted":{"major":15}}]"#),
            minimumOS: minimumOS
        ))
        #expect(!FrontendReceipt.ManagedDebugSurface.supportsAvailability(
            try availability(#"[{"domain":"iOS","obsoleted":{"major":18}}]"#),
            minimumOS: minimumOS
        ))
        #expect(!FrontendReceipt.ManagedDebugSurface.supportsAvailability(
            try availability(
                #"[{"domain":"Swift","isUnconditionallyDeprecated":true}]"#
            ),
            minimumOS: minimumOS
        ))
        #expect(!FrontendReceipt.ManagedDebugSurface.supportsAvailability(
            try availability(
                #"[{"domain":"iOS","isUnconditionallyUnavailable":true}]"#
            ),
            minimumOS: minimumOS
        ))
        #expect(FrontendReceipt.ManagedDebugSurface.supportsAvailability(
            try availability(#"[{"domain":"macOS","deprecated":{"major":12}}]"#),
            minimumOS: minimumOS
        ))
    }

    @Test("Function spelling derives exact native callback lifetimes")
    func derivesNativeCallbackProfiles() throws {
        let direct = try #require(FrontendReceipt.ValueTypeParser.parse(
            "@MainActor @Sendable @convention(block) (Swift.Bool) -> Swift.Void",
            allowVoid: false
        ))
        let optional = try #require(FrontendReceipt.ValueTypeParser.parse(
            "((Swift.Int, Swift.String?) -> ())?",
            allowVoid: false
        ))
        #expect(direct.directClosureShape?.isOptional == false)
        #expect(optional.directClosureShape?.isOptional == true)
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: [
                "() -> Swift.Void",
                "@escaping @Sendable (Swift.Bool) -> Swift.Void",
                "((Swift.Int, Swift.String?) -> ())?",
            ],
            parameterTypes: [
                try #require(FrontendReceipt.ValueTypeParser.parse(
                    "() -> Swift.Void",
                    allowVoid: false
                )),
                direct,
                optional,
            ]
        ) == [
            .init(parameterIndex: 0, lifetime: .nonescaping),
            .init(parameterIndex: 1, lifetime: .escaping),
            .init(parameterIndex: 2, lifetime: .escaping),
        ])
        #expect(FrontendReceipt.ValueTypeParser.parse(
            "() async -> Swift.Void",
            allowVoid: false
        ) == nil)
        #expect(FrontendReceipt.ValueTypeParser.parse(
            "() throws -> Swift.Void",
            allowVoid: false
        ) == nil)
        #expect(FrontendReceipt.FunctionTypeSpelling.parse(
            "() async async -> Swift.Void"
        ) == nil)
        #expect(FrontendReceipt.FunctionTypeSpelling.parse(
            "() throws rethrows -> Swift.Void"
        ) == nil)
        #expect(FrontendReceipt.FunctionTypeSpelling.parse(
            "@Sendable @Sendable () -> Swift.Void"
        ) == nil)
        #expect(FrontendReceipt.FunctionTypeSpelling.parse(
            "@convention(swift) @convention(swift) () -> Swift.Void"
        ) == nil)
        #expect(FrontendReceipt.FunctionTypeSpelling.parse(
            "@convention(swift) @convention(block) () -> Swift.Void"
        ) == nil)
        let returning = try #require(FrontendReceipt.ValueTypeParser.parse(
            "(Swift.Int) -> Swift.Bool",
            allowVoid: false
        ))
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: ["(Swift.Int) -> Swift.Bool"],
            parameterTypes: [returning]
        ) == [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ])
        let textResults = try ["Swift.Character", "Swift.Substring"].map {
            try #require(FrontendReceipt.ValueTypeParser.parse(
                "() -> \($0)",
                allowVoid: false
            ))
        }
        #expect(textResults[0].directClosureShape?.signature.result == .string)
        #expect(textResults[1].directClosureShape?.signature.result
            == .array(.string))
        #expect(textResults.allSatisfy { $0.directClosureShape?
            .signature.isNativeBridgeCallback == true })
        let actorPredicateSpelling = "@escaping @Swift.MainActor "
            + "(Any?, [Swift.String : Any]?) -> Swift.Bool"
        let parsedActorPredicate = try #require(
            FrontendReceipt.FunctionTypeSpelling.parse(actorPredicateSpelling)
        )
        #expect(parsedActorPredicate.parameters == [
            "Any?", "[Swift.String : Any]?",
        ])
        #expect(parsedActorPredicate.attributes.globalActor == "Swift.MainActor")
        #expect(parsedActorPredicate.isSynchronousNonthrowing)
        #expect(FrontendReceipt.ValueTypeParser.parse(
            parsedActorPredicate.parameters[0],
            allowVoid: false
        ) == .optional(.any))
        #expect(FrontendReceipt.ValueTypeParser.parse(
            parsedActorPredicate.parameters[1],
            allowVoid: false
        ) == .optional(.dictionary(key: .string, value: .any)))
        #expect(FrontendReceipt.ValueTypeParser.parse(
            parsedActorPredicate.result,
            allowVoid: true
        ) == .bool)
        let actorPredicate = try #require(FrontendReceipt.ValueTypeParser.parse(
            actorPredicateSpelling,
            allowVoid: false
        ))
        #expect(actorPredicate.directClosureShape?.signature.result == .bool)
        let nativeResult = Core.TypeID(
            rawValue: .sha256("NativeCallbackResult")
        )
        let unsupportedResult = Bytecode.ValueType.closure(.init(
            parameters: [],
            parameterConventions: [],
            result: .native(nativeResult)
        ))
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: ["() -> NativeCallbackResult"],
            parameterTypes: [unsupportedResult]
        ) == nil)
        let higherOrder = try #require(FrontendReceipt.ValueTypeParser.parse(
            "(@escaping (Swift.Int) -> Swift.Void) -> Swift.Void",
            allowVoid: false
        ))
        #expect(higherOrder.directClosureShape?.signature.parameters.first?
            .directClosureShape != nil)
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: [
                "(@escaping (Swift.Int) -> Swift.Void) -> Swift.Void",
            ],
            parameterTypes: [higherOrder]
        ) == [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ])
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: [
                "((Swift.Int) -> Swift.Void) -> Swift.Void",
            ],
            parameterTypes: [higherOrder]
        ) == [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ])

        let view = Core.TypeID(rawValue: .sha256("UIKit.UIView"))
        let native = try #require(FrontendReceipt.ValueTypeParser.parse(
            "@Sendable (UIKit.UIView, [UIKit.UIView?]) -> Swift.Void",
            allowVoid: false,
            nativeTypes: ["UIKit.UIView": view]
        ))
        #expect(native.directClosureShape?.signature.parameterConventions
            == [.borrowed, .borrowed])
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: [
                "@escaping @Sendable (UIKit.UIView, [UIKit.UIView?]) -> Swift.Void",
            ],
            parameterTypes: [native]
        ) == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: [
                "@escaping @Sendable (UIKit.UIView, [UIKit.UIView?]) -> Swift.Void",
            ],
            parameterTypes: [native],
            authoritativeLifetimes: [:]
        ) == nil)
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: [
                "@escaping @Sendable (UIKit.UIView, [UIKit.UIView?]) -> Swift.Void",
            ],
            parameterTypes: [native],
            authoritativeLifetimes: [0: .nonescaping]
        ) == nil)
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: ["((Swift.Int, Swift.String?) -> ())?"],
            parameterTypes: [optional],
            authoritativeLifetimes: [0: .nonescaping]
        ) == nil)
        #expect(FrontendReceipt.NativeBridgeProfile.authoritativeLifetimes([
            .init(parameterIndex: 0, lifetime: .nonescaping),
            .init(parameterIndex: 0, lifetime: .escaping),
        ]) == nil)

        let erased = try #require(FrontendReceipt.ValueTypeParser.parse(
            "@escaping (Any, [Any]?, Swift.String, [Swift.Int]) -> Swift.Void",
            allowVoid: false
        ))
        #expect(erased.directClosureShape?.signature.parameterConventions == [
            .borrowed, .borrowed, .owned, .owned,
        ])
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: [
                "@escaping (Any, [Any]?, Swift.String, [Swift.Int]) -> Swift.Void",
            ],
            parameterTypes: [erased]
        ) == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])

        let error = try #require(FrontendReceipt.ValueTypeParser.parse(
            "@escaping (Swift.Optional<any Swift.Error>) -> Swift.Void",
            allowVoid: false
        ))
        #expect(error.directClosureShape?.signature.parameters == [
            .optional(.error),
        ])
        #expect(error.directClosureShape?.signature.parameterConventions == [
            .borrowed,
        ])
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: [
                "@escaping (Swift.Optional<any Swift.Error>) -> Swift.Void",
            ],
            parameterTypes: [error]
        ) == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(FrontendReceipt.NativeBridgeProfile.callbacks(
            parameterSpellings: ["any Swift.Error"],
            parameterTypes: [.error]
        ) == nil)
        #expect(!FrontendReceipt.NativeBridgeProfile.isResult(.error))
        #expect(!FrontendReceipt.NativeBridgeProfile.isResult(
            .optional(.error)
        ))
    }

    @Test("Swift type checking proves nested callable escaping authority")
    func provesNestedCallableEscapingAuthority() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-nested-callable-lifetime-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let safeURL = directory.appendingPathComponent("Safe.swift")
        let unsafeURL = directory.appendingPathComponent("Unsafe.swift")
        let wrapper = """
        let strengthened: (@escaping () -> Void) -> Void = { callback in
            callback()
        }
        """
        try Data("""
        func acceptsEscaping(_ body: (@escaping () -> Void) -> Void) {}
        func probe() {
            \(wrapper)
            acceptsEscaping(strengthened)
        }
        """.utf8).write(to: safeURL)
        try Data("""
        func acceptsNonescaping(_ body: (() -> Void) -> Void) {}
        func probe() {
            \(wrapper)
            acceptsNonescaping(strengthened)
        }
        """.utf8).write(to: unsafeURL)

        let frontend = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
        )
        let safe = try frontend.run(
            arguments: [safeURL.path, "-typecheck", "-parse-as-library"],
            workingDirectory: directory
        )
        let unsafe = try frontend.run(
            arguments: [unsafeURL.path, "-typecheck", "-parse-as-library"],
            workingDirectory: directory
        )
        #expect(safe.terminationStatus == 0)
        #expect(unsafe.terminationStatus != 0)
    }

    @Test("Closure values stored by setters always use escaping authority")
    func derivesStoredClosurePropertyLifetime() throws {
        let owner = Core.TypeID(rawValue: .sha256("CallbackStore"))
        let operation = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: ["$s13CallbackStore7handleryycvs"],
            sourceFileLogicalID: "Sources/Fixture.swift",
            importedModules: ["CallbackFramework"],
            dispatch: .instanceSetter,
            ownerType: "CallbackStore",
            baseName: "handler",
            argumentLabels: ["_"],
            parameterSwiftTypes: ["(Swift.Int) -> ()", "CallbackStore"],
            resultSwiftType: "()",
            requiresMainActor: false
        )

        let declaration = try #require(
            FrontendReceipt.Adapter().makeImportedOperationDeclarations(
                [operation],
                moduleName: "StoredCallbackFixture",
                nativeTypes: ["CallbackStore": owner]
            ).first
        )

        #expect(declaration.callbacks == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(declaration.parameterTypes[0].directClosureShape != nil)
    }

    @Test("Objective-C protocols keep an AnyObject ABI and typed invocation")
    func preservesObjectiveCProtocolInvocationType() throws {
        let interaction = Core.TypeID(rawValue: .sha256("Swift.AnyObject"))
        let view = Core.TypeID(rawValue: .sha256("UIKit.UIView"))
        let operation = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: ["$hlx_native_foreign_add_interaction"],
            sourceFileLogicalID: "Sources/Fixture.swift",
            importedModules: ["UIKit"],
            dispatch: .instanceMethod,
            ownerType: "UIView",
            baseName: "addInteraction",
            argumentLabels: ["_"],
            parameterSwiftTypes: ["Swift.AnyObject", "UIView"],
            invocationParameterSwiftTypes: ["any UIInteraction", "UIView"],
            resultSwiftType: "Swift.Void",
            requiresMainActor: true
        )

        let declaration = try #require(
            FrontendReceipt.Adapter().makeImportedOperationDeclarations(
                [operation],
                moduleName: "ProtocolInvocationFixture",
                nativeTypes: [
                    "Swift.AnyObject": interaction,
                    "UIView": view,
                ]
            ).first
        )

        #expect(declaration.parameterTypes == [
            .native(interaction), .native(view),
        ])
        #expect(declaration.parameterSwiftTypes == [
            "Swift.AnyObject", "UIView",
        ])
        #expect(declaration.invocationParameterSwiftTypes == [
            "any UIInteraction", "UIView",
        ])
    }

    @Test("Managed SDK probing preserves NSError-backed Swift throws")
    func discoversManagedSDKNSErrorThrowingMethod() throws {
        let frontend = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
        )
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let expansion = try FrontendReceipt.ManagedDebugSurface.expand(
            importedTypes: [
                .init(
                    canonicalName: "FileManager",
                    swiftType: "FileManager",
                    kind: .reference,
                    aliases: ["NSFileManager", "__C.NSFileManager"],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["Foundation"],
                    requiresMainActor: false
                ),
            ],
            minimumOS: .init(15),
            frontend: frontend,
            invocation: .init(
                moduleName: "ManagedSDKThrowingFixture",
                targetTriple: "arm64-apple-ios15.0-simulator",
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            )
        )
        let fileManagerOperations = expansion.operations.filter {
            $0.ownerType.contains("FileManager")
        }
        let operationNames = fileManagerOperations.map {
            "\($0.ownerType).\($0.baseName)(\($0.argumentLabels.joined(separator: ":")))"
        }
        #expect(operationNames.contains { $0.contains(".removeItem(atPath)") })
        let removals = fileManagerOperations.filter { $0.baseName == "removeItem" }
        #expect(removals.count == 1)
        #expect(removals.first?.dispatch == .instanceMethod)
        #expect(removals.first?.argumentLabels == ["atPath"])
        #expect(removals.first?.parameterSwiftTypes == ["Swift.String", "FileManager"])
        #expect(removals.first?.resultSwiftType == "()")
        #expect(removals.first?.mayThrow == true)
        #expect(removals.first?.parameterProjection == .identity(parameterCount: 2))
    }

    @Test("Managed SDK probing prefreezes native members used inside callbacks")
    func discoversManagedSDKTimerInvalidation() throws {
        let frontend = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
        )
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let expansion = try FrontendReceipt.ManagedDebugSurface.expand(
            importedTypes: [
                .init(
                    canonicalName: "Timer",
                    swiftType: "Timer",
                    kind: .reference,
                    aliases: ["NSTimer", "__C.NSTimer", "Foundation.Timer"],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["Foundation"],
                    requiresMainActor: false
                ),
            ],
            minimumOS: .init(15),
            frontend: frontend,
            invocation: .init(
                moduleName: "ManagedSDKTimerFixture",
                targetTriple: "arm64-apple-ios15.0-simulator",
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            )
        )

        let invalidation = try #require(expansion.operations.first {
            $0.ownerType == "Timer"
                && $0.baseName == "invalidate"
                && $0.dispatch == .instanceMethod
        })
        #expect(invalidation.parameterSwiftTypes == ["Timer"])
        #expect(invalidation.resultSwiftType == "Swift.Void")
    }

    @Test("Managed SDK probing admits only compiler-proven zero-argument construction")
    func discoversManagedSDKZeroArgumentConstruction() throws {
        let frontend = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
        )
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let expansion = try FrontendReceipt.ManagedDebugSurface.expand(
            importedTypes: [
                .init(
                    canonicalName: "UIViewController",
                    swiftType: "UIViewController",
                    kind: .reference,
                    aliases: ["__C.UIViewController", "UIKit.UIViewController"],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["UIKit"],
                    requiresMainActor: true
                ),
                .init(
                    canonicalName: "UIView",
                    swiftType: "UIView",
                    kind: .reference,
                    aliases: ["__C.UIView", "UIKit.UIView"],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["UIKit"],
                    requiresMainActor: true
                ),
                .init(
                    canonicalName: "UIButton",
                    swiftType: "UIButton",
                    kind: .reference,
                    aliases: ["__C.UIButton", "UIKit.UIButton"],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["UIKit"],
                    requiresMainActor: true
                ),
                .init(
                    canonicalName: "UIColor",
                    swiftType: "UIColor",
                    kind: .reference,
                    aliases: ["__C.UIColor", "UIKit.UIColor"],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["UIKit"],
                    requiresMainActor: false
                ),
                .init(
                    canonicalName: "UIUserInterfaceStyle",
                    swiftType: "UIUserInterfaceStyle",
                    kind: .value,
                    aliases: ["__C.UIUserInterfaceStyle", "UIKit.UIUserInterfaceStyle"],
                    representation: .rawRepresentable,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["UIKit"],
                    requiresMainActor: false
                ),
                .init(
                    canonicalName: "NSLayoutAnchor<NSLayoutXAxisAnchor>",
                    swiftType: "NSLayoutAnchor<NSLayoutXAxisAnchor>",
                    kind: .reference,
                    aliases: [
                        "UIKit.NSLayoutAnchor<UIKit.NSLayoutXAxisAnchor>",
                    ],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["UIKit"],
                    requiresMainActor: true
                ),
                .init(
                    canonicalName: "NSLayoutAnchor<NSLayoutYAxisAnchor>",
                    swiftType: "NSLayoutAnchor<NSLayoutYAxisAnchor>",
                    kind: .reference,
                    aliases: [
                        "UIKit.NSLayoutAnchor<UIKit.NSLayoutYAxisAnchor>",
                    ],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["UIKit"],
                    requiresMainActor: true
                ),
                .init(
                    canonicalName: "NSLayoutXAxisAnchor",
                    swiftType: "NSLayoutXAxisAnchor",
                    kind: .reference,
                    aliases: ["UIKit.NSLayoutXAxisAnchor"],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["UIKit"],
                    requiresMainActor: true
                ),
                .init(
                    canonicalName: "NSLayoutYAxisAnchor",
                    swiftType: "NSLayoutYAxisAnchor",
                    kind: .reference,
                    aliases: ["UIKit.NSLayoutYAxisAnchor"],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["UIKit"],
                    requiresMainActor: true
                ),
                .init(
                    canonicalName: "NSLayoutConstraint",
                    swiftType: "NSLayoutConstraint",
                    kind: .reference,
                    aliases: ["UIKit.NSLayoutConstraint"],
                    representation: .reference,
                    sourceFileLogicalID: "Sources/Fixture.swift",
                    importedModules: ["UIKit"],
                    requiresMainActor: true
                ),
            ],
            minimumOS: .init(15),
            frontend: frontend,
            invocation: .init(
                moduleName: "ManagedSDKConstructionFixture",
                targetTriple: "arm64-apple-ios15.0-simulator",
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            )
        )

        let controllerInitializer = try #require(expansion.operations.first {
            $0.ownerType == "UIViewController"
                && $0.baseName == "init"
                && $0.dispatch == .initializer
                && $0.argumentLabels.isEmpty
        })
        #expect(controllerInitializer.parameterSwiftTypes.isEmpty)
        #expect(controllerInitializer.resultSwiftType == "UIViewController")
        #expect(controllerInitializer.requiresMainActor)
        _ = try #require(expansion.operations.first {
            $0.ownerType == "UIViewController"
                && $0.baseName == "view"
                && $0.dispatch == .instanceGetter
        })
        _ = try #require(expansion.operations.first {
            $0.ownerType == "UIView"
                && $0.baseName == "backgroundColor"
                && $0.dispatch == .instanceSetter
        })
        _ = try #require(expansion.operations.first {
            $0.ownerType == "UIColor"
                && $0.baseName == "black"
                && $0.dispatch == .staticGetter
        })
        let configurationHandler = try #require(expansion.operations.first {
            $0.ownerType == "UIButton"
                && $0.baseName == "configurationUpdateHandler"
                && $0.dispatch == .instanceSetter
        })
        let configurationParameter = try #require(
            configurationHandler.parameterSwiftTypes.first
        )
        let configurationCallback = try #require(
            FrontendReceipt.FunctionTypeSpelling.callbackBoundary(
                in: configurationParameter
            )
        )
        #expect(configurationCallback.isOptional)
        #expect(configurationCallback.lifetime == .escaping)
        #expect(
            configurationCallback.function.attributes.globalActor
                == "MainActor"
        )
        let nonescapingAnimation = try #require(expansion.operations.first {
            $0.ownerType == "UIView"
                && $0.baseName == "performWithoutAnimation"
                && $0.dispatch == .staticMethod
                && $0.argumentLabels == ["_"]
        })
        let nonescapingBody = try #require(
            nonescapingAnimation.parameterSwiftTypes.first
        )
        #expect(
            FrontendReceipt.FunctionTypeSpelling.callbackBoundary(
                in: nonescapingBody
            )?.lifetime == .nonescaping
        )
        let animation = try #require(expansion.operations.first {
            $0.ownerType == "UIView"
                && $0.baseName == "animate"
                && $0.dispatch == .staticMethod
                && $0.argumentLabels == ["withDuration", "animations"]
        })
        #expect(animation.parameterSwiftTypes.count == 2)
        let animationBody = try #require(
            animation.parameterSwiftTypes.dropFirst().first
        )
        #expect(
            FrontendReceipt.FunctionTypeSpelling.callbackBoundary(
                in: animationBody
            )?.lifetime == .escaping
        )
        let animationWithCompletion = try #require(
            expansion.operations.first {
                $0.ownerType == "UIView"
                    && $0.baseName == "animate"
                    && $0.dispatch == .staticMethod
                    && $0.argumentLabels == [
                        "withDuration", "animations", "completion",
                    ]
            }
        )
        #expect(animationWithCompletion.parameterSwiftTypes.count == 3)
        let completionAnimationBody = try #require(
            animationWithCompletion.parameterSwiftTypes.dropFirst().first
        )
        let animationCompletion = try #require(
            animationWithCompletion.parameterSwiftTypes.dropFirst(2).first
        )
        #expect(
            FrontendReceipt.FunctionTypeSpelling.callbackBoundary(
                in: completionAnimationBody
            )?.lifetime == .escaping
        )
        #expect(
            FrontendReceipt.FunctionTypeSpelling.callbackBoundary(
                in: animationCompletion
            )?.lifetime == .escaping
        )
        for axis in ["NSLayoutXAxisAnchor", "NSLayoutYAxisAnchor"] {
            let owner = "NSLayoutAnchor<\(axis)>"
            let constraint = try #require(expansion.operations.first {
                $0.ownerType == owner
                    && $0.baseName == "constraint"
                    && $0.dispatch == .instanceMethod
                    && $0.argumentLabels == ["equalTo"]
            })
            #expect(constraint.parameterSwiftTypes == [owner, owner])
            let frozenType = try #require(expansion.importedTypes.first {
                $0.swiftType == owner
            })
            #expect(!frozenType.aliases.contains("NSLayoutAnchor"))
            #expect(!frozenType.aliases.contains("UIKit.NSLayoutAnchor"))
        }
        #expect(!expansion.operations.contains {
            $0.ownerType == "UIUserInterfaceStyle"
                && $0.dispatch == .initializer
                && $0.argumentLabels.isEmpty
        })
    }

    @Test("Re-exported imported calls retain Swift overlay and NSError ABI")
    func discoversNSErrorBackedImportedCall() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-nserror-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Fixture.swift")
        let source = """
        import UIKit

        public func remove(path: String) throws {
            try FileManager.default.removeItem(atPath: path)
        }
        """
        let contents = Data(source.utf8)
        try contents.write(to: sourceURL)

        let frontend = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
        )
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: "NSErrorImportFixture",
            targetTriple: "arm64-apple-ios15.0-simulator",
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion,
            optimization: "-Onone",
            semanticArguments: ["-parse-as-library"]
        )
        let ast = try frontend.emitTypedAST(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let documents = try FrontendReceipt.TypedAST.parseDocuments(ast)
        let demangled = try FrontendReceipt.Demangler(
            compilerURL: frontend.compilerURL
        ).demangle(FrontendReceipt.TypedAST.mangledTypes(in: documents))
        let sil = try CanonicalSIL.File(text: frontend.emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: invocation
        ))
        let state = FrontendReceipt.Adapter.SourceState(
            logicalPath: "Sources/Fixture.swift",
            url: sourceURL,
            contents: contents,
            contentHash: .sha256(contents)
        )
        let surface = try FrontendReceipt.Adapter().discoverImportedOperationSurface(
            documents: documents,
            sourcesByPhysicalPath: [
                sourceURL.resolvingSymlinksInPath().standardizedFileURL.path: state,
            ],
            moduleName: invocation.moduleName,
            demangled: demangled,
            silFile: sil
        )
        let operation = try #require(surface.operations.first {
            $0.baseName == "removeItem"
        })
        #expect(operation.dispatch == .instanceMethod)
        #expect(operation.argumentLabels == ["atPath"])
        #expect(operation.parameterSwiftTypes == ["Swift.String", "FileManager"])
        #expect(operation.resultSwiftType == "()")
        #expect(operation.mayThrow)
        #expect(operation.parameterProjection == .identity(parameterCount: 2))
        let defaultGetter = try #require(surface.operations.first {
            $0.ownerType == "FileManager"
                && $0.baseName == "default"
                && $0.dispatch == .staticGetter
        })
        #expect(defaultGetter.resultSwiftType == "FileManager")
        #expect(!surface.types.contains { $0.swiftType == "NSFileManager" })
    }

    @Test("Imported UIKit and Dispatch calls retain native callback boundaries")
    func discoversSDKCallbackCalls() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-sdk-callback-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Fixture.swift")
        let source = """
        import Dispatch
        import Foundation
        import UIKit

        public func consumeNotification(
            _ body: (Foundation.Notification) -> Void
        ) {}

        @MainActor
        public final class CallbackOwner {
            public func invokeCallbacks(
                _ view: UIView,
                controller: UIViewController,
                cell: UICollectionViewCell,
                url: URL,
                group: DispatchGroup,
                operations: OperationQueue,
                operation: Operation
            ) {
                consumeNotification { notification in
                    _ = notification.name
                }
                let withoutAnimation: @MainActor () -> Void = {
                    view.alpha = 0.5
                }
                UIView.performWithoutAnimation(withoutAnimation)
                nonisolated func unrestrictedAnimationBody() { _ = 1 }
                let unrestrictedAnimation: () -> Void =
                    unrestrictedAnimationBody
                let restrictedAnimation: @MainActor () -> Void =
                    unrestrictedAnimation
                UIView.performWithoutAnimation(restrictedAnimation)
                let animations: @MainActor () -> Void = view.layoutIfNeeded
                let animationCompletion: @MainActor (Bool) -> Void = { finished in
                    if finished { view.setNeedsDisplay() }
                }
                UIView.animate(
                    withDuration: 0.2,
                    animations: animations,
                    completion: animationCompletion
                )
                DispatchQueue.main.async { view.setNeedsLayout() }
                _ = Timer.scheduledTimer(
                    withTimeInterval: 1,
                    repeats: false
                ) { timer in
                    timer.invalidate()
                }
                operations.addOperation { _ = 1 }
                group.notify(queue: .main) { _ = 2 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    view.setNeedsLayout()
                }
                _ = URLSession.shared.dataTask(with: url) { data, response, error in
                    _ = data
                    _ = response
                    _ = error
                }
                UIView.transition(
                    with: view,
                    duration: 0.2,
                    options: .transitionCrossDissolve,
                    animations: { view.alpha = 0.75 },
                    completion: nil
                )
                UIView.animateKeyframes(
                    withDuration: 0.2,
                    delay: 0,
                    options: [],
                    animations: { view.alpha = 1 },
                    completion: nil
                )
                let animator = UIViewPropertyAnimator(
                    duration: 0.2,
                    curve: .linear
                ) { view.alpha = 0.5 }
                animator.addCompletion { position in
                    _ = position
                }
                cell.configurationUpdateHandler = { configuredCell, state in
                    _ = configuredCell
                    _ = state
                }
                let operationCompletion = {
                    _ = operation.isFinished
                }
                let aliasedOperationCompletion = operationCompletion
                operation.completionBlock = aliasedOperationCompletion
                func handleAction(_ action: UIAction) {
                    _ = action
                }
                _ = UIAction(handler: handleAction)
                _ = UIAlertAction(
                    title: "Run",
                    style: .default
                ) { action in
                    _ = action
                }
                func handleContextualAction(
                    _ action: UIContextualAction,
                    _ sourceView: UIView,
                    _ completion: @escaping (Bool) -> Void
                ) {
                    _ = action
                    _ = sourceView
                    completion(true)
                }
                _ = UIContextualAction(
                    style: .normal,
                    title: "Complete",
                    handler: handleContextualAction
                )
                controller.present(
                    UIViewController(),
                    animated: true
                ) {
                    view.setNeedsLayout()
                }
                _ = NotificationCenter.default.addObserver(
                    forName: nil,
                    object: nil,
                    queue: .main
                ) { notification in
                    _ = notification.name
                }
                func evaluatePredicate(
                    _ value: Any?,
                    _ bindings: [String: Any]?
                ) -> Bool {
                    _ = value
                    _ = bindings
                    return true
                }
                let predicate = NSPredicate(block: evaluatePredicate)
                _ = predicate
                let enumerationError: @MainActor (URL, any Error) -> Bool = {
                    failedURL, error in
                    _ = failedURL
                    _ = error
                    return false
                }
                _ = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    errorHandler: enumerationError
                )
            }
        }
        """
        let contents = Data(source.utf8)
        try contents.write(to: sourceURL)

        let frontend = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
        )
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: "SDKCallbackImportFixture",
            targetTriple: "arm64-apple-ios15.0-simulator",
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion,
            optimization: "-Onone",
            semanticArguments: ["-parse-as-library"]
        )
        let ast = try frontend.emitTypedAST(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let documents = try FrontendReceipt.TypedAST.parseDocuments(ast)
        let demangled = try FrontendReceipt.Demangler(
            compilerURL: frontend.compilerURL
        ).demangle(FrontendReceipt.TypedAST.mangledTypes(in: documents))
        let sil = try CanonicalSIL.File(text: frontend.emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: invocation
        ))
        let state = FrontendReceipt.Adapter.SourceState(
            logicalPath: "Sources/Fixture.swift",
            url: sourceURL,
            contents: contents,
            contentHash: .sha256(contents)
        )
        let surface = try FrontendReceipt.Adapter().discoverImportedOperationSurface(
            documents: documents,
            sourcesByPhysicalPath: [
                sourceURL.resolvingSymlinksInPath().standardizedFileURL.path: state,
            ],
            moduleName: invocation.moduleName,
            demangled: demangled,
            silFile: sil
        )
        let discoveredTypes = try FrontendReceipt.Adapter()
            .discoverImportedNativeTypes(
                documents: documents,
                sourcesByPhysicalPath: [
                    sourceURL.resolvingSymlinksInPath().standardizedFileURL.path: state,
                ],
                moduleName: invocation.moduleName,
                demangled: demangled
            )
        let notification = try #require(discoveredTypes.first {
            $0.canonicalName == "Foundation.Notification"
        })
        #expect(notification.kind == .value)
        #expect(notification.representation == .opaqueValue)
        #expect(!notification.requiresMainActor)
        let keyframeOptions = try #require(surface.types.first {
            $0.canonicalName == "UIView.KeyframeAnimationOptions"
        })
        #expect(keyframeOptions.swiftType == "UIView.KeyframeAnimationOptions")
        #expect(keyframeOptions.representation == .rawRepresentable)
        let notificationName = try #require(surface.types.first {
            $0.canonicalName == "NSNotification.Name"
        })
        #expect(notificationName.aliases.contains("NSNotificationName"))
        let resourceKey = try #require(surface.types.first {
            $0.canonicalName == "NSURLResourceKey"
                || $0.aliases.contains("NSURLResourceKey")
        })
        #expect(resourceKey.aliases.contains("__C.NSURLResourceKey"))
        #expect(resourceKey.representation == .opaqueValue)
        let dispatchTimeAddition = try #require(surface.operations.first {
            $0.baseName == "+"
        })
        #expect(dispatchTimeAddition.dispatch == .globalFunction)
        #expect(dispatchTimeAddition.parameterSwiftTypes.count == 2)
        let callbackNames: Set<String> = [
            "addCompletion", "addObserver", "addOperation", "animate",
            "animateKeyframes", "async", "asyncAfter", "dataTask", "notify",
            "performWithoutAnimation", "scheduledTimer", "transition",
        ]
        let callbacks = surface.operations.filter {
            callbackNames
                .contains($0.baseName)
        }.sorted { $0.baseName < $1.baseName }
        #expect(callbacks.map(\.baseName) == [
            "addCompletion", "addObserver", "addOperation", "animate",
            "animateKeyframes", "async", "asyncAfter", "dataTask", "notify",
            "performWithoutAnimation", "scheduledTimer", "transition",
        ])
        let callbacksByName = Dictionary(uniqueKeysWithValues: callbacks.map {
            ($0.baseName, $0)
        })
        #expect(callbacksByName["animate"]?.parameterSwiftTypes == [
            "Swift.Double",
            "@escaping @Swift.MainActor () -> ()",
            "Swift.Optional<@Swift.MainActor (Swift.Bool) -> ()>",
        ])
        #expect(callbacksByName["async"]?.parameterSwiftTypes == [
            "@escaping @Swift.MainActor @Sendable @convention(block) () -> ()",
            "DispatchQueue",
        ])
        let asyncProjection = try #require(
            callbacksByName["async"]?.parameterProjection
        )
        #expect(asyncProjection.physicalParameterCount == 5)
        #expect(asyncProjection.logicalParameterIndices == [3, 4])
        #expect(asyncProjection.defaultArguments.map(\.origin) == [
            .optionalNone, .externalGenerator, .externalGenerator,
        ])
        #expect(
            asyncProjection.defaultArguments[1].generatorSymbol?
                .hasSuffix("FfA0_") == true
        )
        #expect(
            asyncProjection.defaultArguments[2].generatorSymbol?
                .hasSuffix("FfA1_") == true
        )
        #expect(
            callbacksByName["performWithoutAnimation"]?.parameterSwiftTypes
                == ["@Swift.MainActor () -> ()"]
        )
        #expect(callbacksByName["scheduledTimer"]?.parameterSwiftTypes == [
            "Swift.Double",
            "Swift.Bool",
            "@escaping @Sendable (Timer) -> ()",
        ])
        #expect(callbacksByName["dataTask"]?.parameterSwiftTypes.contains(
            "@escaping @Sendable (Foundation.Data?, NSURLResponse?, Swift.Error?) -> ()"
        ) == true)
        #expect(callbacksByName["addObserver"]?.parameterSwiftTypes.first
            == "NSNotification.Name?")
        let configurationSetter = try #require(surface.operations.first {
            $0.baseName == "configurationUpdateHandler"
                && $0.dispatch == .instanceSetter
        })
        let operationCompletionSetter = try #require(surface.operations.first {
            $0.baseName == "completionBlock"
                && $0.dispatch == .instanceSetter
        })
        let presentation = try #require(surface.operations.first {
            $0.baseName == "present"
        })
        let actionInitializer = try #require(surface.operations.first {
            $0.baseName == "init"
                && $0.ownerType == "UIAction"
                && $0.parameterSwiftTypes.contains {
                    $0.contains("UIAction") && $0.contains("->")
                }
        })
        let alertInitializer = try #require(surface.operations.first {
            $0.baseName == "init"
                && $0.ownerType == "UIAlertAction"
                && $0.parameterSwiftTypes.contains { $0.contains("->") }
        })
        let contextualActionInitializer = try #require(
            surface.operations.first {
                $0.baseName == "init"
                    && $0.ownerType == "UIContextualAction"
                    && $0.parameterSwiftTypes.contains { spelling in
                        spelling.contains("UIContextualAction")
                            && spelling.contains("Bool")
                            && spelling.contains("->")
                    }
            }
        )
        #expect(surface.operations.contains {
            $0.baseName == "default"
                && $0.ownerType == "UIAlertAction.Style"
                && $0.dispatch == .staticGetter
        })
        #expect(surface.operations.contains {
            $0.baseName == "main" && $0.dispatch == .staticGetter
        })
        #expect(surface.operations.contains {
            $0.baseName == "default" && $0.dispatch == .staticGetter
        })
        let importedTypes = try FrontendReceipt.Adapter().mergeImportedNativeTypes(
            discoveredTypes: discoveredTypes,
            operationTypes: surface.types
        )
        var nativeTypes: [String: Core.TypeID] = [:]
        for type in importedTypes {
            let id = Core.TypeID(rawValue: .sha256(
                "sdk-callback-fixture:\(type.canonicalName)"
            ))
            for name in Set([type.canonicalName, type.swiftType] + type.aliases) {
                nativeTypes[name] = id
            }
        }
        let declarations = try FrontendReceipt.Adapter()
            .makeImportedOperationDeclarations(
                surface.operations,
                moduleName: invocation.moduleName,
                nativeTypes: nativeTypes
            )
        let declarationsByName = Dictionary(uniqueKeysWithValues:
            declarations.filter { callbackNames.contains($0.baseName) }.map {
                ($0.baseName, $0)
            }
        )
        #expect(declarations.contains {
            $0.baseName == "+" && $0.dispatch == .globalFunction
        })
        let asyncDeclaration = try #require(declarations.first {
            $0.baseName == "async"
        })
        #expect(asyncDeclaration.callbacks == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(asyncDeclaration.parameterProjection == asyncProjection)
        #expect(declarations.contains {
            $0.baseName == "main" && $0.dispatch == .staticGetter
        })
        #expect(declarations.contains {
            $0.baseName == "default" && $0.dispatch == .staticGetter
        })
        let timerDeclaration = try #require(declarations.first {
            $0.baseName == "scheduledTimer"
        })
        #expect(timerDeclaration.callbacks == [
            .init(parameterIndex: 2, lifetime: .escaping),
        ])
        #expect(timerDeclaration.parameterTypes[2].directClosureShape?
            .signature.parameterConventions == [.borrowed])
        #expect(declarationsByName["performWithoutAnimation"]?.callbacks == [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ])
        #expect(declarationsByName["animate"]?.callbacks == [
            .init(parameterIndex: 1, lifetime: .escaping),
            .init(parameterIndex: 2, lifetime: .escaping),
        ])
        #expect(declarationsByName["animateKeyframes"]?.callbacks == [
            .init(parameterIndex: 3, lifetime: .escaping),
            .init(parameterIndex: 4, lifetime: .escaping),
        ])
        #expect(declarationsByName["transition"]?.callbacks == [
            .init(parameterIndex: 3, lifetime: .escaping),
            .init(parameterIndex: 4, lifetime: .escaping),
        ])
        #expect(declarationsByName["asyncAfter"]?.callbacks == [
            .init(parameterIndex: 1, lifetime: .escaping),
        ])
        #expect(declarationsByName["notify"]?.callbacks == [
            .init(parameterIndex: 1, lifetime: .escaping),
        ])
        #expect(declarationsByName["addOperation"]?.callbacks == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(declarationsByName["addCompletion"]?.callbacks == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(declarationsByName["addCompletion"]?.parameterTypes[0]
            .directClosureShape?.signature.parameterConventions == [.borrowed])
        #expect(declarationsByName["addObserver"]?.callbacks == [
            .init(parameterIndex: 3, lifetime: .escaping),
        ])
        let dataTask = try #require(declarationsByName["dataTask"])
        #expect(dataTask.callbacks == [
            .init(parameterIndex: 1, lifetime: .escaping),
        ])
        let dataTaskCallback = try #require(
            dataTask.parameterTypes[1].directClosureShape?.signature
        )
        #expect(dataTaskCallback.parameters.count == 3)
        #expect(dataTaskCallback.parameters[2] == .optional(.error))
        #expect(dataTaskCallback.parameterConventions == [
            .borrowed, .borrowed, .borrowed,
        ])
        #expect(dataTaskCallback.isNativeBridgeCallback)
        let observer = try #require(declarationsByName["addObserver"])
        #expect(observer.resultSwiftType == "Swift.AnyObject")
        #expect(observer.resultType == nativeTypes["Swift.AnyObject"].map {
            .native($0)
        })

        let predicateOperation = try #require(surface.operations.first {
            $0.baseName == "init"
                && $0.ownerType.contains("NSPredicate")
                && $0.parameterSwiftTypes.contains { $0.contains("-> Swift.Bool") }
        })
        let enumeratorOperation = try #require(surface.operations.first {
            $0.baseName == "enumerator"
                && $0.ownerType.contains("FileManager")
        })
        let resultOperations = try FrontendReceipt.Adapter()
            .makeImportedOperationDeclarations(
                [
                    predicateOperation, enumeratorOperation,
                    configurationSetter, operationCompletionSetter,
                    presentation, actionInitializer, alertInitializer,
                    contextualActionInitializer,
                ],
                moduleName: invocation.moduleName,
                nativeTypes: nativeTypes
            )
        let predicateDeclaration = try #require(resultOperations.first {
            $0.baseName == "init"
                && $0.parameterTypes.contains { type in
                    type.directClosureShape?.signature.result == .bool
                }
        })
        #expect(predicateDeclaration.callbacks == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(predicateDeclaration.parameterTypes[0].directClosureShape?
            .signature.result == .bool)
        let enumeratorDeclaration = try #require(resultOperations.first {
            $0.baseName == "enumerator"
        })
        let errorHandlerIndex = try #require(
            enumeratorDeclaration.parameterTypes.firstIndex {
                $0.directClosureShape != nil
            }
        )
        #expect(enumeratorDeclaration.callbacks == [
            .init(
                parameterIndex: UInt16(errorHandlerIndex),
                lifetime: .escaping
            ),
        ])
        let errorHandler = try #require(
            enumeratorDeclaration.parameterTypes[errorHandlerIndex]
                .directClosureShape
        )
        #expect(errorHandler.isOptional)
        #expect(errorHandler.signature.parameters.last == .error)
        #expect(errorHandler.signature.result == .bool)
        #expect(errorHandler.signature.isNativeBridgeCallback)
        let configurationDeclaration = try #require(resultOperations.first {
            $0.baseName == "configurationUpdateHandler"
        })
        #expect(configurationDeclaration.callbacks == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(configurationDeclaration.parameterSwiftTypes[0]
            .contains("MainActor"))
        let operationCompletionDeclaration = try #require(
            resultOperations.first { $0.baseName == "completionBlock" }
        )
        #expect(operationCompletionDeclaration.callbacks == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(operationCompletionDeclaration.parameterSwiftTypes[0]
            .contains("@Sendable"))
        #expect(operationCompletionDeclaration.parameterSwiftTypes[0]
            .contains("MainActor"))
        let presentationDeclaration = try #require(resultOperations.first {
            $0.baseName == "present"
        })
        #expect(presentationDeclaration.callbacks == [
            .init(parameterIndex: 2, lifetime: .escaping),
        ])
        #expect(presentationDeclaration.parameterSwiftTypes[2]
            .contains("MainActor"))
        let initializerCallbacks = resultOperations.filter {
            $0.baseName == "init" && !$0.callbacks.isEmpty
        }
        #expect(initializerCallbacks.count == 4)
        #expect(initializerCallbacks.allSatisfy {
            $0.callbacks.count == 1
                && $0.callbacks[0].lifetime == .escaping
        })
        let higherOrderInitializer = try #require(
            initializerCallbacks.first { declaration in
                declaration.parameterTypes.contains { type in
                    type.directClosureShape?.signature.parameters.contains(
                        where: \.containsClosureValue
                    ) == true
                }
            }
        )
        let outerCallback = try #require(
            higherOrderInitializer.parameterTypes.compactMap(
                \.directClosureShape
            ).first
        )
        let completionSignatures = outerCallback.signature.parameters.compactMap {
            $0.directClosureShape?.signature
        }
        let completion = try #require(completionSignatures.first)
        #expect(outerCallback.signature.isNativeBridgeCallback)
        #expect(outerCallback.signature.parameterConventions.last == .owned)
        #expect(completion.parameters == [.bool])
        #expect(completion.parameterConventions == [.owned])
        #expect(completion.result == .void)
        #expect(completion.isNativeBridgeCallable)
    }

    @Test("Explicit closure actor erasure remains authoritative")
    func preservesExplicitClosureActorErasure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-callback-actor-erasure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Fixture.swift")
        let source = """
        import Foundation

        @MainActor
        public func install(_ operation: Operation) {
            let isolated: @MainActor @Sendable () -> Void = {
                _ = operation.isFinished
            }
            let erased: @Sendable () -> Void = isolated
            operation.completionBlock = erased
        }
        """
        let contents = Data(source.utf8)
        try contents.write(to: sourceURL)

        let frontend = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
        )
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: "CallbackActorErasureFixture",
            targetTriple: "arm64-apple-ios15.0-simulator",
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion,
            optimization: "-Onone",
            semanticArguments: ["-parse-as-library"]
        )
        let ast = try frontend.emitTypedAST(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let documents = try FrontendReceipt.TypedAST.parseDocuments(ast)
        let demangled = try FrontendReceipt.Demangler(
            compilerURL: frontend.compilerURL
        ).demangle(FrontendReceipt.TypedAST.mangledTypes(in: documents))
        let sil = try CanonicalSIL.File(text: frontend.emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: invocation
        ))
        let state = FrontendReceipt.Adapter.SourceState(
            logicalPath: "Sources/Fixture.swift",
            url: sourceURL,
            contents: contents,
            contentHash: .sha256(contents)
        )
        let surface = try FrontendReceipt.Adapter()
            .discoverImportedOperationSurface(
                documents: documents,
                sourcesByPhysicalPath: [
                    sourceURL.resolvingSymlinksInPath()
                        .standardizedFileURL.path: state,
                ],
                moduleName: invocation.moduleName,
                demangled: demangled,
                silFile: sil
            )
        let setter = try #require(surface.operations.first {
            $0.baseName == "completionBlock"
                && $0.dispatch == .instanceSetter
        })
        let callback = try #require(setter.parameterSwiftTypes.first)
        #expect(callback.contains("@Sendable"))
        #expect(!callback.contains("MainActor"))
    }

    @Test("Physical SIL aliases collapse to one deterministic logical import")
    func canonicalizesPhysicalOperationAliases() throws {
        func operation(
            baseName: String,
            label: String
        ) -> FrontendReceipt.Adapter.ImportedOperation {
            .init(
                silReferences: ["$s8Physical5aliasyS2iF"],
                sourceFileLogicalID: "Sources/Fixture.swift",
                importedModules: ["Foundation"],
                dispatch: .globalFunction,
                ownerType: "Foundation",
                baseName: baseName,
                argumentLabels: [label],
                parameterSwiftTypes: ["Swift.Int"],
                resultSwiftType: "Swift.Int",
                requiresMainActor: false
            )
        }

        let declarations = try FrontendReceipt.Adapter()
            .makeImportedOperationDeclarations(
                [
                    operation(baseName: "renamed", label: "value"),
                    operation(baseName: "alias", label: "_"),
                ],
                moduleName: "Fixture",
                nativeTypes: [:]
            )
        let declaration = try #require(declarations.first)
        #expect(declarations.count == 1)
        #expect(declaration.mangledName == "$s8Physical5aliasyS2iF")
        #expect(
            declaration.canonicalCallee
                == "Fixture.HelixExternal.Foundation.alias(_:).call"
        )
    }

    @Test("Unsupported incidental imports do not reject supported operations")
    func skipsUnbridgeableImportedOperations() throws {
        let supported = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: ["$s8Fixture9supportedyS2iF"],
            sourceFileLogicalID: "Sources/Fixture.swift",
            importedModules: ["Foundation"],
            dispatch: .globalFunction,
            ownerType: "Foundation",
            baseName: "supported",
            argumentLabels: ["_"],
            parameterSwiftTypes: ["Swift.Int"],
            resultSwiftType: "Swift.Int",
            requiresMainActor: false
        )
        let incidental = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: ["$sSnySiG12makeIterator"],
            sourceFileLogicalID: "Sources/Fixture.swift",
            importedModules: ["Swift"],
            dispatch: .instanceMethod,
            ownerType: "Swift.ClosedRange<Swift.Int>",
            baseName: "makeIterator",
            argumentLabels: [],
            parameterSwiftTypes: ["Swift.ClosedRange<Swift.Int>"],
            resultSwiftType: "Swift.IndexingIterator<Swift.ClosedRange<Swift.Int>>",
            requiresMainActor: false
        )

        let declarations = try FrontendReceipt.Adapter()
            .makeImportedOperationDeclarations(
                [supported, incidental],
                moduleName: "Fixture",
                nativeTypes: [:]
            )
        #expect(declarations.count == 1)
        #expect(declarations.first?.baseName == "supported")

        var required = incidental
        required.compilerOperation = .nativeUpcast
        #expect(throws: FrontendReceipt.Error.self) {
            _ = try FrontendReceipt.Adapter()
                .makeImportedOperationDeclarations(
                    [required],
                    moduleName: "Fixture",
                    nativeTypes: [:]
                )
        }
    }

    @Test("Physical SIL aliases reject conflicting logical ABIs")
    func rejectsConflictingPhysicalOperationAliases() {
        let common = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: ["$s8Physical5aliasyS2iF"],
            sourceFileLogicalID: "Sources/Fixture.swift",
            importedModules: ["Foundation"],
            dispatch: .globalFunction,
            ownerType: "Foundation",
            baseName: "alias",
            argumentLabels: ["_"],
            parameterSwiftTypes: ["Swift.Int"],
            parameterProjection: .identity(parameterCount: 1),
            resultSwiftType: "Swift.Int",
            requiresMainActor: false
        )
        var conflicting = common
        conflicting.baseName = "conflicting"
        conflicting.resultSwiftType = "Swift.Bool"

        #expect(throws: FrontendReceipt.Error.self) {
            _ = try FrontendReceipt.Adapter().makeImportedOperationDeclarations(
                [common, conflicting],
                moduleName: "Fixture",
                nativeTypes: [:]
            )
        }
    }

    @Test("Objective-C mangling distinguishes classes from imported C values")
    func distinguishesObjectiveCClassesFromCValues() {
        #expect(
            FrontendReceipt.Adapter.objectiveCClassNames(
                inMangledType: "$sSo7UILabelCD"
            ) == ["UILabel"]
        )
        #expect(
            FrontendReceipt.Adapter.objectiveCClassNames(
                inMangledType: "$sSaySo6UIViewCGD"
            ) == ["UIView"]
        )
        #expect(
            FrontendReceipt.Adapter.objectiveCClassNames(
                inMangledType: "$sSo8_NSRangeVD"
            ).isEmpty
        )
        #expect(
            FrontendReceipt.Adapter.objectiveCNominalIdentity(
                inMangledType: "$sSo30UIViewKeyframeAnimationOptionsVD"
            ) == "UIViewKeyframeAnimationOptions"
        )
        #expect(
            FrontendReceipt.Adapter.objectiveCNominalIdentity(
                inMangledType: "$sSo30UIViewKeyframeAnimationOptionsVSgD"
            ) == "UIViewKeyframeAnimationOptions"
        )
        #expect(
            FrontendReceipt.Adapter.objectiveCNominalIdentity(
                inMangledType: "$sSaySo30UIViewKeyframeAnimationOptionsVGD"
            ) == nil
        )
    }

    @Test("AnyObject boxing is discovered without explicit framework imports")
    func discoversAndGeneratesAnyObjectBoxing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-any-object-boxing-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = sourceDirectory.appendingPathComponent("Box.swift")
        let baseline = """
        public func box(_ value: Any) -> AnyObject {
            value as AnyObject
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "AnyObjectBoxingFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**
        """)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.any-object-boxing",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.any-object-boxing",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "integration-test",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(
                moduleName: moduleName,
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by indexer")
        )
        let output = try FrontendReceipt.Adapter().generate(
            .init(
                metadata: metadata,
                configuration: configuration,
                sources: [.init(logicalPath: "Sources/Box.swift", url: sourceURL)],
                compilerURL: compilerURL,
                callingSurfacePolicy: .managedDebugModule
            )
        )

        let binding = try #require(output.receipt.nativeImportBindings.first {
            $0.generated?.dispatch == .anyObjectBridge
        })
        #expect(binding.importedModules == ["Swift"])
        #expect(binding.generated?.ownerType == "Swift.AnyObject")
        #expect(binding.generated?.parameterSwiftTypes == ["Swift.Any"])
        let record = try #require(output.receipt.nativeImportCandidates.first {
            $0.key == binding.key
        })
        let importID = try #require(record.id)
        #expect(record.parameterTypes == [.any])
        #expect(record.resultType == output.receipt.nativeTypes.first {
            $0.canonicalName == "Swift.AnyObject"
        }.map { .native($0.id) })

        let shell = try ShellBuild.Materializer().materialize(
            receipt: output.receipt,
            sourceRoot: directory
        )
        let generated = shell.bridge.sourceFiles.values.joined(separator: "\n")
        #expect(generated.contains("import Swift"))
        #expect(generated.contains("argument0 as Swift.AnyObject"))
        try typeCheckGeneratedBridge(
            shell: shell,
            directory: directory,
            moduleName: moduleName
        )

        let changed = """
        public func box(_ value: Any) -> AnyObject {
            let result = value as AnyObject
            return result
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let patch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [sourceURL],
                compilerURL: compilerURL
            )
        )
        #expect(patch.module.imports.contains { $0.id == importID })
        #expect(patch.disassembly.contains("native_apply #\(importID.rawValue)"))
        _ = try Verification.Engine().verify(
            bytes: patch.bytecode,
            shell: Verification.ShellInterface(archive: shell.archive),
            policy: .init(
                acceptedCapabilities: Set(shell.archive.capabilities),
                allowedNativeImports: Set(shell.archive.nativeImports.compactMap(\.id))
            )
        )
    }

    @Test("Real module indexing generates exact invokers for a selected source range")
    func indexesAndMaterializesGeneratedInvokers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-native-import-discovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let patchDirectory = directory.appendingPathComponent("Patch", isDirectory: true)
        let nativeDirectory = directory.appendingPathComponent("Native", isDirectory: true)
        try FileManager.default.createDirectory(
            at: patchDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nativeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let patchURL = patchDirectory.appendingPathComponent("Feature.swift")
        let nativeURL = nativeDirectory.appendingPathComponent("Operations.swift")
        try Data(
            """
            public func transform(_ value: Int) -> Int { adjust(value, by: 1) }
            public func asyncTransform(_ value: Int) async -> Int {
                await asyncAdjust(value, by: 1)
            }
            """.utf8
        ).write(to: patchURL)
        try Data(
            """
            public enum SampleError: Error { case negative }
            public func adjust(_ value: Int, by amount: Int) -> Int { value + amount }
            public func asyncAdjust(_ value: Int, by amount: Int) async -> Int {
                value + amount
            }
            public func checked(_ value: Int) throws -> Int {
                if value < 0 { throw SampleError.negative }
                return value
            }
            @MainActor public func mainValue(_ value: Int) -> Int { value + 10 }
            @MainActor public func mainChecked(_ value: Int) async throws -> Int {
                if value < 0 { throw SampleError.negative }
                return value + 20
            }
            public func invalidAsyncCallback(_ body: () -> Void) async {
                body()
            }
            public func copy(_ values: [String: Int]?) -> [String: Int]? { values }
            public func echo(_ value: Any) -> Any { value }
            public func keyword(_ value: Int, `repeat` count: Int) -> Int { value + count }
            public func invokeNow(_ body: () -> Void) { body() }
            public func invokeError(_ body: @escaping ((any Error)?) -> Void) {
                body(SampleError.negative)
            }
            public func invokeLater(_ body: @escaping (Bool) -> Void) { body(true) }
            public func invokeOptional(_ body: ((Int) -> Void)?) { body?(1) }
            public func invokeSendable(_ body: @escaping @Sendable () -> Void) { body() }
            public func invokePredicate(_ value: Int, _ body: (Int) -> Bool) -> Bool {
                body(value)
            }
            public func invokeCharacter(_ body: () -> Character) -> Character {
                body()
            }
            public func invokeCompletion(
                _ body: (@escaping (Bool) -> Void) -> Void
            ) {
                body { _ in }
            }
            public func invokeCallableValues(
                _ body: (
                    @escaping (Bool) -> Bool,
                    ((Int) -> Int)?
                ) -> Bool
            ) -> Bool {
                body({ !$0 }, { $0 + 1 })
            }
            public func makeTransform(_ offset: Int) -> (Int) -> Int {
                { value in value + offset }
            }
            public func makeOptionalTransform(
                _ offset: Int?
            ) -> ((Int) -> Int)? {
                guard let offset else { return nil }
                return { value in value + offset }
            }
            public func makeMainTransform(
                _ offset: Int
            ) -> @MainActor (Int) -> Int {
                { value in value + offset }
            }
            public func invokeTuple(
                _ body: () -> (value: Int, accepted: Bool)
            ) -> (value: Int, accepted: Bool) {
                body()
            }
            public func invokeProvider(_ body: @escaping () -> Counter?) -> Counter? {
                body()
            }
            public enum Math {
                public static func doubled(_ value: Int) -> Int { value * 2 }
                public static var incrementer: (Int) -> Int {
                    { value in value + 1 }
                }
            }
            public final class Counter {
                public var value: Int = 0
                public init() {}
                public func increment(_ value: Int) -> Int { value + 1 }
            }
            """.utf8
        ).write(to: nativeURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "GeneratedImportFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configurationYAML = """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Patch/**
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Native/**
                declarations:
                  - \(moduleName).*
                visibility: public
                profile: pure
                maximumBoundedDurationMicroseconds: 500
                maximumSuspendingDurationMicroseconds: 5000000
                allowsMainThread: true
        """
        let configuration = try PatchConfiguration.Document.parse(yaml: configurationYAML)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.generated-import",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.generated-import",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "integration-test",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(
                moduleName: moduleName,
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by indexer")
        )
        let request = FrontendReceipt.Request(
            metadata: metadata,
            configuration: configuration,
            sources: [
                .init(logicalPath: "Native/Operations.swift", url: nativeURL),
                .init(logicalPath: "Patch/Feature.swift", url: patchURL),
            ],
            compilerURL: compilerURL
        )

        let output = try FrontendReceipt.Adapter().generate(request)
        #expect(output.receipt.nativeImportCandidates.map(\.canonicalCallee).sorted() == [
            "\(moduleName).Counter.increment(_:)",
            "\(moduleName).Counter.value.get",
            "\(moduleName).Counter.value.set",
            "\(moduleName).Math.doubled(_:)",
            "\(moduleName).Math.incrementer.get",
            "\(moduleName).adjust(_:by:)",
            "\(moduleName).asyncAdjust(_:by:)",
            "\(moduleName).checked(_:)",
            "\(moduleName).copy(_:)",
            "\(moduleName).echo(_:)",
            "\(moduleName).invokeCallableValues(_:)",
            "\(moduleName).invokeCharacter(_:)",
            "\(moduleName).invokeCompletion(_:)",
            "\(moduleName).invokeError(_:)",
            "\(moduleName).invokeLater(_:)",
            "\(moduleName).invokeNow(_:)",
            "\(moduleName).invokeOptional(_:)",
            "\(moduleName).invokePredicate(_:_:)",
            "\(moduleName).invokeProvider(_:)",
            "\(moduleName).invokeSendable(_:)",
            "\(moduleName).invokeTuple(_:)",
            "\(moduleName).keyword(_:repeat:)",
            "\(moduleName).mainChecked(_:)",
            "\(moduleName).mainValue(_:)",
            "\(moduleName).makeMainTransform(_:)",
            "\(moduleName).makeOptionalTransform(_:)",
            "\(moduleName).makeTransform(_:)",
            "Swift.String.init(describing:)",
            "Swift.String.init(reflecting:)",
            "Swift.debugPrint(_:separator:terminator:)",
            "Swift.print(_:separator:terminator:)",
        ])
        #expect(output.receipt.nativeImportCandidates.map(\.id) == (0...30).map {
            Core.NativeImportID(rawValue: UInt32($0))
        })
        let asyncImports = output.receipt.nativeImportCandidates.filter {
            $0.effects.isAsync
        }
        #expect(asyncImports.map(\.canonicalCallee).sorted() == [
            "\(moduleName).asyncAdjust(_:by:)",
            "\(moduleName).mainChecked(_:)",
        ])
        #expect(asyncImports.allSatisfy {
            $0.signature.isAsync
                && $0.contract.execution.deadlineMode == .suspending
                && $0.contract.execution.maximumDurationMicroseconds
                    == 5_000_000
                && $0.contract.callbacks.isEmpty
        })
        let asyncEntryDeclaration = try #require(
            output.receipt.declarations.first {
                $0.interface.baseName == "asyncTransform"
            }
        )
        let asyncEntryRoot = try #require(output.receipt.roots.first {
            $0.declarationMangledName == asyncEntryDeclaration.mangledName
        })
        #expect(
            asyncEntryRoot.sourceBodyTransform?.kind
                == .asynchronousFunction
        )
        #expect(asyncEntryRoot.declarationInsertion == nil)
        #expect(asyncEntryRoot.nativeReplacement == nil)
        #expect(
            asyncEntryRoot.bridge?.bridgeInvocation?.hasPrefix("helixReload_")
                == true
        )
        #expect(
            asyncEntryRoot.bridge?.bridgeInvocation?.hasSuffix("(argument0)")
                == true
        )
        #expect(asyncEntryRoot.bridge?.sourceSupplementalDeclaration?.contains(
            "exact async original thunk"
        ) == true)
        let asyncEntryRootIndex = try #require(output.receipt.roots.firstIndex {
            $0.declarationMangledName == asyncEntryDeclaration.mangledName
        })
        var missingAsyncTransform = output.receipt
        missingAsyncTransform.roots[asyncEntryRootIndex].sourceBodyTransform = nil
        #expect(throws: ShellBuildReceipt.Error.self) {
            try missingAsyncTransform.validate()
        }
        var oversizedAsyncTransform = output.receipt
        oversizedAsyncTransform.roots[asyncEntryRootIndex]
            .sourceBodyTransform?.openingBraceUTF8Offset = 0
        oversizedAsyncTransform.roots[asyncEntryRootIndex]
            .sourceBodyTransform?.closingBraceUTF8Offset = 64 * 1_024
        #expect(throws: ShellBuildReceipt.Error.self) {
            try oversizedAsyncTransform.validate()
        }
        var dynamicAsyncTransform = output.receipt
        dynamicAsyncTransform.roots[asyncEntryRootIndex].declarationInsertion =
            "dynamic "
        #expect(throws: ShellBuildReceipt.Error.self) {
            try dynamicAsyncTransform.validate()
        }
        var missingAsyncThunk = output.receipt
        missingAsyncThunk.roots[asyncEntryRootIndex].bridge?
            .sourceSupplementalDeclaration = nil
        #expect(throws: ShellBuildReceipt.Error.self) {
            try missingAsyncThunk.validate()
        }
        let synchronousRootIndex = try #require(output.receipt.roots.firstIndex {
            $0.bridge != nil && $0.sourceBodyTransform == nil
        })
        var injectedSynchronousSupplement = output.receipt
        injectedSynchronousSupplement.roots[synchronousRootIndex].bridge?
            .sourceSupplementalDeclaration = "func injected() {}"
        #expect(throws: ShellBuildReceipt.Error.self) {
            try injectedSynchronousSupplement.validate()
        }
        let callbacks = Dictionary(uniqueKeysWithValues: output.receipt
            .nativeImportCandidates.compactMap { record in
                record.canonicalCallee.contains(".invoke")
                    ? (record.canonicalCallee, record.contract.callbacks) : nil
            })
        #expect(callbacks["\(moduleName).invokeNow(_:)"] == [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ])
        #expect(callbacks["\(moduleName).invokeError(_:)"] == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(callbacks["\(moduleName).invokeLater(_:)"] == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(callbacks["\(moduleName).invokeOptional(_:)"] == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(callbacks["\(moduleName).invokeSendable(_:)"] == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        #expect(callbacks["\(moduleName).invokePredicate(_:_:)"] == [
            .init(parameterIndex: 1, lifetime: .nonescaping),
        ])
        #expect(callbacks["\(moduleName).invokeCharacter(_:)"] == [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ])
        #expect(callbacks["\(moduleName).invokeCompletion(_:)"] == [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ])
        #expect(callbacks["\(moduleName).invokeCallableValues(_:)"] == [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ])
        #expect(callbacks["\(moduleName).invokeTuple(_:)"] == [
            .init(parameterIndex: 0, lifetime: .nonescaping),
        ])
        #expect(callbacks["\(moduleName).invokeProvider(_:)"] == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        let callableResults = Dictionary(uniqueKeysWithValues: output.receipt
            .nativeImportCandidates.compactMap { record in
                record.resultType.directClosureShape.map {
                    (record.canonicalCallee, $0)
                }
            })
        #expect(callableResults.count == 4)
        #expect(
            callableResults["\(moduleName).Math.incrementer.get"]?.isOptional
                == false
        )
        #expect(
            callableResults["\(moduleName).makeMainTransform(_:)"]?
                .signature.effects.requiresMainActor == true
        )
        #expect(
            callableResults["\(moduleName).makeOptionalTransform(_:)"]?
                .isOptional == true
        )
        #expect(
            callableResults["\(moduleName).makeTransform(_:)"]?.isOptional
                == false
        )
        #expect(callableResults.values.allSatisfy {
            $0.signature.isNativeBridgeCallable
        })
        #expect(output.receipt.nativeImportBindings.count == 31)
        #expect(output.receipt.nativeImportBindings.filter {
            $0.generated != nil
        }.allSatisfy {
            $0.generated != nil && $0.importedModules.isEmpty
        })
        #expect(output.receipt.nativeImportBindings.filter {
            $0.generated != nil
        }.count == 27)
        #expect(output.receipt.nativeImportBindings.contains {
            $0.generated == nil && $0.importedModules == ["HelixRuntime"]
        })
        #expect(output.receipt.nativeImportBindings.filter {
            $0.generated == nil && $0.importedModules == ["HelixRuntime"]
        }.count == 4)
        #expect(output.receipt.configuration.modules[moduleName]?.nativeImports.allow.sorted() == [
            "\(moduleName).Counter.increment(_:)",
            "\(moduleName).Counter.value.get",
            "\(moduleName).Counter.value.set",
            "\(moduleName).Math.doubled(_:)",
            "\(moduleName).Math.incrementer.get",
            "\(moduleName).adjust(_:by:)",
            "\(moduleName).asyncAdjust(_:by:)",
            "\(moduleName).checked(_:)",
            "\(moduleName).copy(_:)",
            "\(moduleName).echo(_:)",
            "\(moduleName).invokeCallableValues(_:)",
            "\(moduleName).invokeCharacter(_:)",
            "\(moduleName).invokeCompletion(_:)",
            "\(moduleName).invokeError(_:)",
            "\(moduleName).invokeLater(_:)",
            "\(moduleName).invokeNow(_:)",
            "\(moduleName).invokeOptional(_:)",
            "\(moduleName).invokePredicate(_:_:)",
            "\(moduleName).invokeProvider(_:)",
            "\(moduleName).invokeSendable(_:)",
            "\(moduleName).invokeTuple(_:)",
            "\(moduleName).keyword(_:repeat:)",
            "\(moduleName).mainChecked(_:)",
            "\(moduleName).mainValue(_:)",
            "\(moduleName).makeMainTransform(_:)",
            "\(moduleName).makeOptionalTransform(_:)",
            "\(moduleName).makeTransform(_:)",
            "Swift.String.init(describing:)",
            "Swift.String.init(reflecting:)",
            "Swift.debugPrint(_:separator:terminator:)",
            "Swift.print(_:separator:terminator:)",
        ])
        #expect(output.diagnostics.contains {
            $0.code == "HLXNID002"
                && $0.message.contains("invalidAsyncCallback")
        })

        var redundantInvocationAdapter = output.receipt
        let invokeNowBindingIndex = try #require(
            redundantInvocationAdapter.nativeImportBindings.firstIndex {
                $0.generated?.baseName == "invokeNow"
            }
        )
        var invokeNowBinding = redundantInvocationAdapter
            .nativeImportBindings[invokeNowBindingIndex]
        var invokeNowGenerated = try #require(invokeNowBinding.generated)
        invokeNowGenerated.invocationParameterSwiftTypes =
            invokeNowGenerated.parameterSwiftTypes
        invokeNowBinding.generated = invokeNowGenerated
        redundantInvocationAdapter.nativeImportBindings[invokeNowBindingIndex] =
            invokeNowBinding
        #expect(throws: ShellBuildReceipt.Error.self) {
            try redundantInvocationAdapter.validate()
        }

        let adjustDeclaration = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "adjust"
        })
        var overrideRequest = request
        overrideRequest.nativeImportCatalog = NativeImportCatalog.Document(
            candidates: [
                .init(
                    canonicalCallee: "\(moduleName).overrideAdjust(_:by:)",
                    silMangledNames: [adjustDeclaration.mangledName],
                    signature: adjustDeclaration.loweredSignature,
                    effects: .init(mayAllocate: true),
                    contract: .bounded(
                        kind: .globalFunction,
                        domain: .application,
                        access: .pure,
                        maximumDurationMicroseconds: 500,
                        allowsMainThread: true
                    ),
                    factoryType: "OverrideSupport.AdjustFactory",
                    importedModules: ["OverrideSupport"]
                ),
            ]
        )
        let overridden = try FrontendReceipt.Adapter().generate(overrideRequest)
        let overriddenRecord = try #require(
            overridden.receipt.nativeImportCandidates.first {
                $0.canonicalCallee == "\(moduleName).overrideAdjust(_:by:)"
            }
        )
        #expect(overriddenRecord.isEmittedToDevice)
        let overriddenBinding = try #require(
            overridden.receipt.nativeImportBindings.first {
                $0.key == overriddenRecord.key
            }
        )
        #expect(overriddenBinding.generated == nil)
        #expect(overriddenBinding.importedModules == ["OverrideSupport"])
        #expect(overridden.diagnostics.contains { $0.code == "HLXNID008" })

        var tampered = output.receipt
        let tamperedID = try #require(tampered.nativeImportCandidates.first?.id)
        tampered.nativeImportBindings[0].invokerExpression += ".tampered"
        #expect(throws: BridgeGeneration.Error.generatedNativeImportBindingMismatch(
            tamperedID,
            "generated factory expression"
        )) {
            try ShellBuild.Materializer().materialize(
                receipt: tampered,
                sourceRoot: directory
            )
        }

        let shell = try ShellBuild.Materializer().materialize(
            receipt: output.receipt,
            sourceRoot: directory
        )
        let transform = try #require(shell.archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        #expect(transform.effects.mayAllocate)
        let transformedFeature = String(
            decoding: try #require(
                shell.transformedSources["Patch/Feature.swift"]
            ),
            as: UTF8.self
        )
        #expect(transformedFeature.contains("prepareAsyncDispatch"))
        #expect(transformedFeature.contains("dispatchAsync"))
        #expect(!transformedFeature.contains("dynamic func asyncTransform"))
        let generatedSources = shell.bridge.sourceFiles.filter {
            $0.key.contains("HelixBridge.NativeImport_")
        }
        #expect(generatedSources.count == 2)
        #expect(generatedSources.values.contains {
            $0.contains("No NativeImport adapters were required")
        })
        let generated = try #require(generatedSources.values.first {
            $0.contains("@_private(sourceFile: \"Operations.swift\")")
        })
        #expect(generated.contains("@_private(sourceFile: \"Operations.swift\")"))
        #expect(generated.contains("adjust(argument0, by: argument1)"))
        #expect(generated.contains("Math.doubled(argument0)"))
        #expect(generated.contains("argument1.increment(argument0)"))
        #expect(generated.contains("argument0.value"))
        #expect(generated.contains("argument1.value = argument0"))
        #expect(generated.contains("keyword(argument0, repeat: argument1)"))
        #expect(generated.contains("VM.ClosureNativeInvoker("))
        #expect(generated.contains("VM.ClosureAsyncNativeInvoker("))
        #expect(generated.contains("await asyncAdjust(argument0, by: argument1)"))
        #expect(generated.contains("try await mainChecked(argument0)"))
        #expect(generated.contains("catch let trap as VM.RuntimeTrap"))
        #expect(generated.contains("try context.withMainActor"))
        #expect(generated.contains("BridgeValueCodec.decodeDictionary"))
        #expect(generated.contains("BridgeValueCodec.decodeAny"))
        #expect(generated.contains("nativeResultEncoder.encodeAny"))
        #expect(generated.contains("encodeNativeImportResult("))
        #expect(generated.contains("context.makeCallback("))
        #expect(generated.contains("nativeCallback"))
        #expect(generated.contains("encodeNativeCallbackArguments("))
        #expect(generated.contains("encodeNativeClosure("))
        #expect(generated.contains("MainActor.assumeIsolated"))
        #expect(generated.contains("@escaping (Swift.Bool) ->"))
        #expect(generated.contains("(callbackArgument0)(nativeArgument0)"))
        #expect(generated.contains("(wrapped)(nativeArgument0)"))
        #expect(generated.contains("let nativeResult ="))
        #expect(generated.contains("callbackEncoder.encode("))
        #expect(generated.contains("callbackEncoder.encodeError("))
        #expect(generated.contains("BridgeValueCodec.decodeOptional"))
        #expect(generated.contains("@Sendable () -> ()"))
        #expect(generated.contains(".invokeResult("))
        #expect(generated.contains("failureResult: {"))
        #expect(generated.contains("Swift.Character(\"\\0\")"))
        #expect(shell.archive.capabilities.contains(.mainActorIsolationV1))
        #expect(generated.contains("(0, false)"))
        let bridge = try #require(
            shell.bridge.sourceFiles["Generated/\(moduleName)Bridge.swift"]
        )
        #expect(bridge.contains("HelixNativeImports_"))
        #expect(bridge.contains("makeAsyncNativeCatalog()"))
        #expect(bridge.contains("asyncNativeCatalog: asyncNativeCatalog"))
        try typeCheckGeneratedBridge(
            shell: shell,
            directory: directory,
            moduleName: moduleName
        )

        try Data(
            """
            public func transform(_ value: Int) -> Int {
                invokeCompletion { completion in
                    completion(value > 0)
                }
                let accepted = invokeCallableValues { predicate, transform in
                    let next = transform?(value) ?? value
                    return predicate(value <= 0) && next > value
                }
                let transformed = makeTransform(1)(value)
                let optionalTransform = makeOptionalTransform(2)
                let optionalValue = optionalTransform?(value) ?? value
                let incremented = Math.incrementer(value)
                return adjust(value, by: 1) + (accepted ? 3 : 4)
                    + transformed + optionalValue + incremented
            }
            public func asyncTransform(_ value: Int) async -> Int {
                let adjusted = await asyncAdjust(value, by: 2)
                return (try? await mainChecked(adjusted)) ?? -1
            }
            """.utf8
        ).write(to: patchURL)
        let patch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [nativeURL, patchURL],
                compilerURL: compilerURL
            )
        )
        #expect(patch.disassembly.contains("native_apply"))
        #expect(patch.disassembly.contains("closure_apply"))
        _ = try Verification.Engine().verify(
            bytes: patch.bytecode,
            shell: Verification.ShellInterface(archive: shell.archive),
            policy: .init(
                acceptedCapabilities: Set(shell.archive.capabilities),
                allowedNativeImports: Set(
                    shell.archive.nativeImports.compactMap(\.id)
                )
            )
        )

        // Restore the indexed baseline before comparing the independent CLI receipt.
        try Data(
            """
            public func transform(_ value: Int) -> Int { adjust(value, by: 1) }
            public func asyncTransform(_ value: Int) async -> Int {
                await asyncAdjust(value, by: 1)
            }
            """.utf8
        ).write(to: patchURL)

        let metadataURL = directory.appendingPathComponent("ReleaseMetadata.json")
        let configurationURL = directory.appendingPathComponent("Helix.yml")
        let receiptURL = directory.appendingPathComponent("CLIReceipt.json")
        try Core.CanonicalJSON.encode(metadata).write(to: metadataURL)
        try Data(configurationYAML.utf8).write(to: configurationURL)
        let cli = CLI.Application(currentDirectoryURL: directory).run([
            "shell", "index",
            "--metadata", metadataURL.path,
            "--configuration", configurationURL.path,
            "--source-map", "Native/Operations.swift=\(nativeURL.path)",
            "--source-map", "Patch/Feature.swift=\(patchURL.path)",
            "--compiler", compilerURL.path,
            "--output", receiptURL.path,
        ])
        #expect(cli.exitCode == 0)
        #expect(cli.standardError.isEmpty)
        #expect(
            try ShellBuildReceipt.Codec.decode(Data(contentsOf: receiptURL)) == output.receipt
        )
    }

    private func typeCheckGeneratedBridge(
        shell: ShellBuild.Output,
        directory: URL,
        moduleName: String
    ) throws {
        let output = directory.appendingPathComponent("GeneratedTypecheck", isDirectory: true)
        for (path, contents) in shell.transformedSources {
            let url = output.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url)
        }
        let sourcePaths = shell.transformedSources.keys.sorted()
        let frontend = SwiftFrontend.Driver()
        let modules = try swiftPMModulesDirectory()
        try requireFrontendSuccess(
            frontend.run(
                arguments: sourcePaths + [
                    "-emit-module", "-parse-as-library",
                    "-module-name", moduleName,
                    "-Xfrontend", "-enable-private-imports",
                    "-emit-module-path", "\(moduleName).swiftmodule",
                    "-I", modules.path,
                ] + (try runtimeSupportCompilerArguments(modules: modules)),
                workingDirectory: output
            )
        )
        let generatedURLs = try shell.bridge.sourceFiles.sorted(by: { $0.key < $1.key }).map {
            let url = output.appendingPathComponent(URL(fileURLWithPath: $0.key).lastPathComponent)
            try Data($0.value.utf8).write(to: url)
            return url
        }
        try requireFrontendSuccess(
            frontend.run(
                arguments: generatedURLs.map(\.path) + [
                    "-typecheck", "-parse-as-library",
                    "-module-name", "GeneratedImportBridgeProbe",
                    "-I", output.path,
                    "-I", modules.path,
                ] + (try runtimeSupportCompilerArguments(modules: modules)) + [
                    "-Xfrontend", "-enable-private-imports",
                    "-Xfrontend", "-enable-dynamic-replacement-chaining",
                    "-warnings-as-errors",
                ],
                workingDirectory: output
            )
        )
    }

    @Test("Generated async getter imports preserve await and throws")
    func generatesEffectfulAsyncGetterImports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-native-async-getters-\(UUID().uuidString)",
            isDirectory: true
        )
        let patchDirectory = directory.appendingPathComponent("Patch", isDirectory: true)
        let nativeDirectory = directory.appendingPathComponent("Native", isDirectory: true)
        try FileManager.default.createDirectory(
            at: patchDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nativeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let patchURL = patchDirectory.appendingPathComponent("Feature.swift")
        let nativeURL = nativeDirectory.appendingPathComponent("Values.swift")
        try Data("""
        @MainActor public func total(_ box: Box) async throws -> Int {
            let shared = await Values.number
            return shared + (try await box.number)
        }
        """.utf8).write(to: patchURL)
        try Data("""
        public enum Values {
            public static var number: Int {
                get async { 41 }
            }
        }

        @MainActor public final class Box {
            public var number: Int {
                get async throws { 42 }
            }
        }
        """.utf8).write(to: nativeURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "AsyncGetterFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - "**/*.swift"
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Native/**/*.swift
                declarations:
                  - \(moduleName).*
                visibility: public
                profile: pure
        """)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.async-getters",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.async-getters",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "integration-test",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(
                moduleName: moduleName,
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by the indexer")
        )
        let output = try FrontendReceipt.Adapter().generate(
            .init(
                metadata: metadata,
                configuration: configuration,
                sources: [
                    .init(logicalPath: "Patch/Feature.swift", url: patchURL),
                    .init(logicalPath: "Native/Values.swift", url: nativeURL),
                ],
                compilerURL: compilerURL
            )
        )
        let asyncGetters = output.receipt.nativeImportBindings.compactMap {
            binding -> ShellBuildReceipt.NativeImportBinding? in
            guard let generated = binding.generated,
                  [.staticGetter, .instanceGetter].contains(generated.dispatch)
            else { return nil }
            return binding
        }
        #expect(
            asyncGetters.count == 2,
            Comment(rawValue: String(describing: output.diagnostics))
        )
        #expect(asyncGetters.allSatisfy { binding in
            output.receipt.nativeImportCandidates.contains {
                $0.key == binding.key
                    && $0.effects.isAsync
                    && $0.contract.execution.deadlineMode == .suspending
            }
        })
        let staticGetter = try #require(asyncGetters.first {
            $0.generated?.dispatch == .staticGetter
        })
        let instanceGetter = try #require(asyncGetters.first {
            $0.generated?.dispatch == .instanceGetter
        })
        #expect(output.receipt.nativeImportCandidates.first {
            $0.key == staticGetter.key
        }?.effects.requiresMainActor == false)
        #expect(output.receipt.nativeImportCandidates.first {
            $0.key == instanceGetter.key
        }?.effects.requiresMainActor == true)
        let asyncAccessorDeclarations = output.receipt.declarations.filter {
            $0.role == .getter && $0.effects.isAsync
        }
        #expect(asyncAccessorDeclarations.count == 2)
        #expect(asyncAccessorDeclarations.allSatisfy { declaration in
            declaration.forcedPatchability?.reasonCode == "HLXIDX005"
                && !output.receipt.roots.contains(where: {
                    $0.declarationMangledName == declaration.mangledName
                })
        })

        let shell = try ShellBuild.Materializer().materialize(
            receipt: output.receipt,
            sourceRoot: directory
        )
        let generated = shell.bridge.sourceFiles.values.joined(separator: "\n")
        #expect(generated.contains("await Values.number"))
        #expect(generated.contains("try await argument0.number"))
        #expect(generated.contains("VM.ClosureAsyncNativeInvoker("))
        try typeCheckGeneratedBridge(
            shell: shell,
            directory: directory,
            moduleName: moduleName
        )
    }

    @Test("Managed Debug lowers source property accessors through exact imports")
    func lowersManagedStoredProperties() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-managed-properties-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = sourceDirectory.appendingPathComponent("Counter.swift")
        let baseline = """
        public final class Counter {
            private var value: Int = 1
            private var transform: ((Int) -> Int)?
            private var projector: (Int) -> Int {
                { input in input + self.value }
            }
            public static var incrementer: (Int) -> Int {
                { input in input + 1 }
            }
            public func configure(_ body: @escaping (Int) -> Int) {
                transform = body
            }
            public func increment(_ amount: Int) -> Int {
                value += amount
                let transformed = transform?(value) ?? value
                return Self.incrementer(projector(transformed))
            }
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "ManagedPropertyFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**
        """)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.managed-properties",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.managed-properties",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "integration-test",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(
                moduleName: moduleName,
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by indexer")
        )
        let output = try FrontendReceipt.Adapter().generate(
            .init(
                metadata: metadata,
                configuration: configuration,
                sources: [.init(logicalPath: "Sources/Counter.swift", url: sourceURL)],
                compilerURL: compilerURL,
                callingSurfacePolicy: .managedDebugModule
            )
        )
        #expect(output.receipt.nativeImportCandidates.map(\.canonicalCallee).sorted() == [
            "\(moduleName).Counter.configure(_:)",
            "\(moduleName).Counter.incrementer.get",
            "\(moduleName).Counter.projector.get",
            "\(moduleName).Counter.transform.get",
            "\(moduleName).Counter.transform.set",
            "\(moduleName).Counter.value.get",
            "\(moduleName).Counter.value.set",
            "Swift.String.init(describing:)",
            "Swift.String.init(reflecting:)",
            "Swift.debugPrint(_:separator:terminator:)",
            "Swift.print(_:separator:terminator:)",
        ])
        #expect(output.receipt.roots.compactMap(\.bridge).count == 1)
        #expect(output.receipt.nativeImportBindings.compactMap(\.generated?.dispatch).sorted {
            $0.rawValue < $1.rawValue
        } == [
            .instanceGetter, .instanceGetter, .instanceGetter,
            .instanceMethod,
            .instanceSetter, .instanceSetter,
            .staticGetter,
        ])
        let configure = try #require(
            output.receipt.nativeImportCandidates.first {
                $0.canonicalCallee == "\(moduleName).Counter.configure(_:)"
            }
        )
        #expect(configure.contract.callbacks == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        let transformSetter = try #require(
            output.receipt.nativeImportCandidates.first {
                $0.canonicalCallee == "\(moduleName).Counter.transform.set"
            }
        )
        #expect(transformSetter.contract.callbacks == [
            .init(parameterIndex: 0, lifetime: .escaping),
        ])
        let callablePropertyResults = output.receipt.nativeImportCandidates.filter {
            $0.canonicalCallee.hasSuffix("incrementer.get")
                || $0.canonicalCallee.hasSuffix("projector.get")
                || $0.canonicalCallee.hasSuffix("transform.get")
        }.compactMap { $0.resultType.directClosureShape }
        #expect(callablePropertyResults.count == 3)
        #expect(callablePropertyResults.filter(\.isOptional).count == 1)

        let shell = try ShellBuild.Materializer().materialize(
            receipt: output.receipt,
            sourceRoot: directory
        )
        let incrementerImportID = try #require(
            shell.archive.nativeImports.first {
                $0.canonicalCallee == "\(moduleName).Counter.incrementer.get"
            }?.id
        )
        let generated = try #require(shell.bridge.sourceFiles.values.first {
            $0.contains("argument1.value = argument0")
        })
        #expect(generated.contains("argument0.value"))
        #expect(generated.contains("argument1.transform = argument0"))
        #expect(generated.contains("Counter.incrementer"))
        #expect(generated.contains("encodeNativeClosure("))
        #expect(generated.contains("context.makeCallback("))
        try typeCheckGeneratedBridge(
            shell: shell,
            directory: directory,
            moduleName: moduleName
        )

        let changed = baseline.replacingOccurrences(
            of: "value += amount",
            with: "value += amount * 2"
        )
        try Data(changed.utf8).write(to: sourceURL)
        let patch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [sourceURL],
                compilerURL: compilerURL
            )
        )
        #expect(
            patch.disassembly.components(separatedBy: "native_apply").count - 1 >= 6
        )
        #expect(patch.module.imports.count == 4)
        #expect(!patch.module.imports.contains { $0.id == incrementerImportID })
        #expect(patch.disassembly.contains("hlbc_apply"))
        _ = try Verification.Engine().verify(
            bytes: patch.bytecode,
            shell: Verification.ShellInterface(archive: shell.archive),
            policy: .init(
                acceptedCapabilities: Set(shell.archive.capabilities),
                allowedNativeImports: Set(shell.archive.nativeImports.compactMap(\.id))
            )
        )
    }

    @Test("Managed Debug freezes UIKit and Foundation call surfaces end to end")
    func lowersImportedFrameworkOperations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-managed-uikit-reference-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = sourceDirectory.appendingPathComponent("Screen.swift")
        let baseline = """
        import Dispatch
        import Foundation
        import UIKit

        @MainActor
        public final class Screen: UIViewController {
            private var label = UILabel()

            public func selectedLabel(_ seed: Int) -> UILabel {
                _ = seed + 1
                return label
            }

            public func replaceLabel(_ next: UILabel, seed: Int) -> UILabel {
                label = next
                _ = seed + 3
                return label
            }

            public func configure(_ date: Date, interval: Double) -> Date {
                label.textAlignment = .center
                label.accessibilityTraits = [.button]
                label.font = UIFont.systemFont(ofSize: 17, weight: .bold)
                return date.addingTimeInterval(interval + 1)
            }

            public func configureButton(_ button: UIButton, seed: Int) {
                button.configuration = .filled()
                button.configuration?.title = "Updated"
                _ = seed + 1
            }

            public func maxRange(_ range: NSRange) -> Int {
                NSMaxRange(range) + 1
            }

            public func currentSubviews() -> [UIView] {
                if label.isHidden { return [] }
                return label.subviews
            }

            public func runAnimations(
                on view: UIView,
                cell: UICollectionViewCell,
                url: URL,
                group: DispatchGroup,
                operations: OperationQueue,
                operation: Operation,
                viewController: UIViewController,
                color: UIColor
            ) {
                let withoutAnimation: @MainActor () -> Void = {
                    view.alpha = 0.25
                }
                UIView.performWithoutAnimation(withoutAnimation)
                nonisolated func unrestrictedAnimationBody() { _ = 1 }
                let unrestrictedAnimation: () -> Void =
                    unrestrictedAnimationBody
                let restrictedAnimation: @MainActor () -> Void =
                    unrestrictedAnimation
                UIView.performWithoutAnimation(restrictedAnimation)
                let animations: @MainActor () -> Void = view.layoutIfNeeded
                let animationCompletion: @MainActor (Bool) -> Void = { finished in
                    if finished { view.setNeedsDisplay() }
                }
                UIView.animate(
                    withDuration: 0.2,
                    animations: animations,
                    completion: animationCompletion
                )
                DispatchQueue.main.async {
                    view.setNeedsLayout()
                }
                DispatchQueue.main.async(group: nil) {
                    view.setNeedsDisplay()
                }
                _ = Timer.scheduledTimer(
                    withTimeInterval: 1,
                    repeats: false
                ) { timer in
                    timer.invalidate()
                }
                operations.addOperation { _ = 1 }
                group.notify(queue: .main) { _ = 2 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    view.setNeedsLayout()
                }
                _ = URLSession.shared.dataTask(with: url) { data, response, error in
                    _ = data
                    _ = response
                    _ = error
                }
                UIView.transition(
                    with: view,
                    duration: 0.2,
                    options: .transitionCrossDissolve,
                    animations: { view.alpha = 0.75 },
                    completion: nil
                )
                UIView.animateKeyframes(
                    withDuration: 0.2,
                    delay: 0,
                    options: [],
                    animations: { view.alpha = 1 },
                    completion: nil
                )
                let animator = UIViewPropertyAnimator(
                    duration: 0.2,
                    curve: .linear
                ) { view.alpha = 0.5 }
                animator.addCompletion { position in
                    _ = position
                }
                cell.configurationUpdateHandler = { configuredCell, state in
                    _ = configuredCell
                    _ = state
                }
                let operationCompletion = {
                    _ = operation.isFinished
                }
                let aliasedOperationCompletion = operationCompletion
                operation.completionBlock = aliasedOperationCompletion
                func handleAction(_ action: UIAction) {
                    _ = action
                }
                _ = UIAction(handler: handleAction)
                _ = UIAlertAction(
                    title: "Run",
                    style: .default
                ) { action in
                    _ = action
                }
                func handleContextualAction(
                    _ action: UIContextualAction,
                    _ sourceView: UIView,
                    _ completion: @escaping (Bool) -> Void
                ) {
                    _ = action
                    _ = sourceView
                    completion(true)
                }
                _ = UIContextualAction(
                    style: .normal,
                    title: "Complete",
                    handler: handleContextualAction
                )
                _ = color
                present(viewController, animated: true)
                _ = NotificationCenter.default.addObserver(
                    forName: nil,
                    object: nil,
                    queue: .main
                ) { notification in
                    _ = notification.name
                }
                func evaluatePredicate(
                    _ value: Any?,
                    _ bindings: [String: Any]?
                ) -> Bool {
                    _ = value
                    _ = bindings
                    return true
                }
                let predicate = NSPredicate(block: evaluatePredicate)
                _ = predicate.evaluate(with: "value")
                let enumerationError: @MainActor (URL, any Error) -> Bool = {
                    failedURL, error in
                    _ = failedURL
                    _ = error
                    return false
                }
                _ = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    errorHandler: enumerationError
                )
            }

            public func constraints(
                x: NSLayoutXAxisAnchor,
                otherX: NSLayoutXAxisAnchor,
                y: NSLayoutYAxisAnchor,
                otherY: NSLayoutYAxisAnchor
            ) -> [NSLayoutConstraint] {
                [
                    x.constraint(equalTo: otherX),
                    y.constraint(equalTo: otherY),
                ]
            }
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "ManagedUIKitFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**
        """)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.managed-uikit",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.managed-uikit",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "integration-test",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: .init(
                moduleName: moduleName,
                targetTriple: target,
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by indexer")
        )
        let output = try FrontendReceipt.Adapter().generate(
            .init(
                metadata: metadata,
                configuration: configuration,
                sources: [.init(logicalPath: "Sources/Screen.swift", url: sourceURL)],
                compilerURL: compilerURL,
                callingSurfacePolicy: .managedDebugModule
            )
        )
        let labelType = try #require(output.receipt.nativeTypes.first {
            $0.canonicalName == "UILabel"
        })
        #expect(labelType.kind == .reference)
        #expect(labelType.requiresMainActor)
        let labelBinding = try #require(output.receipt.nativeTypeBindings.first {
            $0.canonicalName == "UILabel"
        })
        #expect(labelBinding.importedModules.contains("UIKit"))
        #expect(labelBinding.generated?.swiftType == "UILabel")
        let labelGetterBinding = try #require(output.receipt.nativeImportBindings.first {
            $0.generated?.dispatch == .instanceGetter
        })
        #expect(labelGetterBinding.importedModules.contains("UIKit"))
        let resourceKeyType = try #require(output.receipt.nativeTypes.first {
            $0.canonicalName == "URLResourceKey"
        })
        let resourceKeyBinding = try #require(
            output.receipt.nativeTypeBindings.first {
                $0.canonicalName == resourceKeyType.canonicalName
            }
        )
        #expect(resourceKeyBinding.generated?.swiftType == "URLResourceKey")

        var missingTypeImport = output.receipt
        let labelTypeBindingIndex = try #require(
            missingTypeImport.nativeTypeBindings.firstIndex {
                $0.canonicalName == "UILabel"
            }
        )
        missingTypeImport.nativeTypeBindings[labelTypeBindingIndex].importedModules = []
        #expect(throws: ShellBuildReceipt.Error.self) {
            try missingTypeImport.validate()
        }

        var missingGetterImport = output.receipt
        let labelGetterBindingIndex = try #require(
            missingGetterImport.nativeImportBindings.firstIndex {
                $0.generated?.dispatch == .instanceGetter
            }
        )
        missingGetterImport.nativeImportBindings[labelGetterBindingIndex].importedModules = []
        #expect(throws: ShellBuildReceipt.Error.self) {
            try missingGetterImport.validate()
        }
        let candidateNames = Set(
            output.receipt.nativeImportCandidates.map(\.canonicalCallee)
        )
        #expect(candidateNames.contains("\(moduleName).Screen.label.get"))
        #expect(candidateNames.contains("\(moduleName).Screen.label.set"))
        #expect(candidateNames.contains("Swift.String.init(describing:)"))
        #expect(candidateNames.contains("Swift.String.init(reflecting:)"))
        #expect(candidateNames.contains("Swift.debugPrint(_:separator:terminator:)"))
        #expect(candidateNames.contains("Swift.print(_:separator:terminator:)"))
        let generatedSymbols = Set(
            output.receipt.nativeImportCandidates.flatMap(\.silMangledNames)
        )
        #expect(generatedSymbols.contains { $0.hasPrefix("$hlx_native_foreign_") })
        #expect(!generatedSymbols.contains { $0.hasSuffix(".foreign") })
        let constraintImports = output.receipt.nativeImportCandidates.filter {
            $0.canonicalCallee.contains("NSLayoutAnchor")
                && $0.canonicalCallee.contains("constraint")
        }
        let constraintShapes = Set(
            output.receipt.nativeImportBindings.compactMap(\.generated)
                .filter { $0.baseName == "constraint" }
                .compactMap { operation in
                    operation.ownerType.map {
                        "\($0).\(operation.argumentLabels.joined(separator: ","))"
                    }
                }
        )
        #expect(constraintShapes == Set([
            "NSLayoutAnchor<NSLayoutXAxisAnchor>.equalTo",
            "NSLayoutAnchor<NSLayoutXAxisAnchor>.equalTo,constant",
            "NSLayoutAnchor<NSLayoutYAxisAnchor>.equalTo",
            "NSLayoutAnchor<NSLayoutYAxisAnchor>.equalTo,constant",
            "NSLayoutXAxisAnchor.equalToSystemSpacingAfter,multiplier",
            "NSLayoutYAxisAnchor.equalToSystemSpacingBelow,multiplier",
        ]))
        let genericConstraintShapeCount = constraintShapes.filter {
            $0.hasPrefix("NSLayoutAnchor<")
        }.count
        #expect(constraintImports.count == genericConstraintShapeCount)
        #expect(
            Set(constraintImports.flatMap(\.silMangledNames)).count
                == genericConstraintShapeCount
        )
        #expect(generatedSymbols.contains { $0.hasPrefix("$hlx_native_option_set_literal_") })
        #expect(generatedSymbols.contains { $0.hasPrefix("$hlx_native_global_") })
        #expect(generatedSymbols.contains { $0.hasPrefix("$s") })
        let globalFunction = try #require(
            output.receipt.nativeImportBindings.first {
                $0.generated?.baseName == "NSMaxRange"
            }
        )
        #expect(globalFunction.generated?.dispatch == .globalFunction)
        #expect(globalFunction.generated?.ownerType == nil)
        #expect(globalFunction.importedModules.contains("Foundation"))
        let importedNativeNames = Set(
            output.receipt.nativeTypes.map(\.canonicalName)
        )
        #expect(!importedNativeNames.contains("NSBundle"))
        #expect(!importedNativeNames.contains("NSCoder"))
        #expect(!importedNativeNames.contains("NSTimer"))
        #expect(!importedNativeNames.contains("NSFileManager"))
        #expect(importedNativeNames.contains("Timer"))
        #expect(importedNativeNames.contains("FileManager"))
        let generatedOperations = output.receipt.nativeImportBindings
            .compactMap(\.generated)
        let controllerInitializer = try #require(generatedOperations.first {
            $0.ownerType == "UIViewController"
                && $0.baseName == "init"
                && $0.dispatch == .initializer
                && $0.argumentLabels.isEmpty
        })
        #expect(controllerInitializer.parameterSwiftTypes.isEmpty)
        #expect(controllerInitializer.resultSwiftType == "UIViewController")
        let presentBinding = try #require(
            output.receipt.nativeImportBindings.first {
                $0.generated?.ownerType == "UIViewController"
                    && $0.generated?.baseName == "present"
                    && $0.generated?.dispatch == .instanceMethod
            }
        )
        let presentImport = try #require(
            output.receipt.nativeImportCandidates.first {
                $0.key == presentBinding.key
            }
        )
        #expect(presentImport.effects.requiresMainActor)
        #expect(
            presentImport.contract.execution.maximumDurationMicroseconds
                == 16_000
        )
        #expect(!generatedOperations.contains {
            [
                "commitAnimations",
                "setAnimationDidStopSelector",
                "groupTableViewBackgroundColor",
            ].contains($0.baseName)
        })
        let interaction = try #require(generatedOperations.first {
            $0.ownerType == "UIView" && $0.baseName == "addInteraction"
        })
        #expect(interaction.parameterSwiftTypes == [
            "Swift.AnyObject", "UIView",
        ])
        #expect(interaction.invocationParameterSwiftTypes == [
            "any UIInteraction", "UIView",
        ])

        let typeBindings = output.receipt.nativeTypeBindings.compactMap(\.generated)
        #expect(typeBindings.contains {
            $0.swiftType == "NSTextAlignment"
                && $0.representation == .rawRepresentable
        })
        #expect(typeBindings.contains {
            $0.swiftType == "UIAccessibilityTraits"
                && $0.representation == .rawRepresentable
        })
        #expect(typeBindings.contains {
            $0.swiftType.hasSuffix("Date")
                && $0.representation == .opaqueValue
        })
        #expect(typeBindings.contains {
            $0.swiftType == "_NSRange"
                && $0.representation == .opaqueValue
        })

        let selected = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "selectedLabel"
        })
        #expect(selected.resultType == .native(labelType.id))
        #expect(selected.parameterConventions == [.owned, .borrowed])
        let replacement = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "replaceLabel"
        })
        #expect(replacement.parameterConventions == [.borrowed, .owned, .borrowed])
        let maxRange = try #require(output.receipt.declarations.first {
            $0.interface.baseName == "maxRange"
        })
        #expect(maxRange.parameterConventions == [.borrowed, .borrowed])

        let shell = try ShellBuild.Materializer().materialize(
            receipt: output.receipt,
            sourceRoot: directory
        )
        let sessionTaskType = try #require(shell.archive.nativeTypes.first {
            Set([$0.canonicalName] + $0.swiftTypeAliases)
                .contains("URLSessionDataTask")
        })
        let sessionTaskSpellings = Set(
            [sessionTaskType.canonicalName] + sessionTaskType.swiftTypeAliases
        )
        #expect(sessionTaskSpellings.isSuperset(of: [
            "NSURLSessionDataTask", "URLSessionDataTask",
        ]))
        let generated = try #require(shell.bridge.sourceFiles.values.first {
            $0.contains("estimatedByteCount: { (_: UILabel)")
        })
        #expect(generated.contains("import UIKit"))
        #expect(shell.bridge.sourceFiles.values.contains {
            $0.contains("argument0.label")
        })
        let generatedBridge = shell.bridge.sourceFiles.values.joined(separator: "\n")
        #expect(generatedBridge.contains("import Foundation"))
        #expect(generatedBridge.contains(".textAlignment ="))
        #expect(generatedBridge.contains(".accessibilityTraits ="))
        #expect(generatedBridge.contains("UIColor.black"))
        #expect(generatedBridge.contains(".backgroundColor ="))
        #expect(generatedBridge.contains("UIFont.systemFont("))
        #expect(generatedBridge.contains(".addingTimeInterval("))
        #expect(generatedBridge.contains(".configuration ="))
        #expect(generatedBridge.contains(".title ="))
        #expect(generatedBridge.contains("NSMaxRange(argument0)"))
        #expect(generatedBridge.contains(".subviews"))
        #expect(generatedBridge.contains("scheduledTimer"))
        #expect(generatedBridge.contains("asyncAfter"))
        #expect(generatedBridge.contains("dataTask"))
        #expect(generatedBridge.contains("addObserver"))
        #expect(generatedBridge.contains("addOperation"))
        #expect(generatedBridge.contains("addCompletion"))
        #expect(generatedBridge.contains("animateKeyframes"))
        #expect(generatedBridge.contains(".configurationUpdateHandler ="))
        #expect(generatedBridge.contains(".completionBlock ="))
        #expect(generatedBridge.contains("UIAction("))
        #expect(generatedBridge.contains("UIAlertAction("))
        #expect(generatedBridge.contains("UIContextualAction("))
        #expect(generatedBridge.contains("UIViewController()"))
        #expect(generatedBridge.contains(".present("))
        #expect(generatedBridge.contains("encodeNativeClosure("))
        #expect(generatedBridge.contains("callbackEncoder.encodeError("))
        #expect(generatedBridge.contains("NSPredicate"))
        #expect(generatedBridge.contains("enumerator"))
        #expect(!generatedBridge.contains("NSTimer"))
        #expect(!generatedBridge.contains("NSFileManager"))
        #expect(generatedBridge.contains(".invokeResult("))
        #expect(generatedBridge.contains("failureResult: {"))
        #expect(generatedBridge.contains("let argument0: any UIInteraction"))
        #expect(generatedBridge.contains("as: (any UIInteraction).self"))
        #expect(generatedBridge.contains(
            "try context.withMainActor {\n"
                + "                            let argument0: any UIInteraction"
        ))
        #expect(!generatedBridge.contains("any Any"))
        #expect(generatedBridge.contains("makeResolvedNativeImports_0()"))
        #expect(generatedBridge.contains("makeSynchronousNativeInvokers_0()"))
        let changed = baseline
            .replacingOccurrences(of: "interval + 1", with: "interval + 2")
            .replacingOccurrences(of: "seed + 1", with: "seed + 2")
            .replacingOccurrences(
                of: "NSMaxRange(range) + 1",
                with: "NSMaxRange(range) + 2"
            )
            .replacingOccurrences(
                of: "if label.isHidden { return [] }",
                with: "if !label.isHidden { return [] }"
            )
            .replacingOccurrences(of: "view.alpha = 0.25", with: "view.alpha = 0.5")
            .replacingOccurrences(
                of: "if finished { view.setNeedsDisplay() }",
                with: "if finished { view.setNeedsLayout() }"
            )
            .replacingOccurrences(
                of: "withTimeInterval: 1",
                with: "withTimeInterval: 2"
            )
            .replacingOccurrences(
                of: "present(viewController, animated: true)",
                with: "let presentedController = UIViewController()\n"
                    + "                presentedController.view.backgroundColor = .black\n"
                    + "                present(presentedController, animated: true)\n"
                    + "                UIView.animate(withDuration: 0.1) {\n"
                    + "                    presentedController.view.alpha = 0.8\n"
                    + "                } completion: { [weak self] _ in\n"
                    + "                    self?.label.text = \"Presented\"\n"
                    + "                }"
            )
        try Data(changed.utf8).write(to: sourceURL)
        let patch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [sourceURL],
                compilerURL: compilerURL
            )
        )
        #expect(patch.changedFunctions.map(\.canonicalDeclaration).contains {
            $0.contains("configure")
        })
        #expect(patch.changedFunctions.map(\.canonicalDeclaration).contains {
            $0.contains("configureButton")
        })
        #expect(patch.changedFunctions.map(\.canonicalDeclaration).contains {
            $0.contains("currentSubviews")
        })
        #expect(patch.changedFunctions.map(\.canonicalDeclaration).contains {
            $0.contains("maxRange")
        })
        #expect(patch.changedFunctions.map(\.canonicalDeclaration).contains {
            $0.contains("runAnimations")
        })
        #expect(patch.module.imports.count >= 6)
        #expect(
            patch.disassembly.components(separatedBy: "native_apply").count - 1 >= 6
        )
        #expect(patch.disassembly.contains("convert_closure"))
        _ = try Verification.Engine().verify(
            bytes: patch.bytecode,
            shell: Verification.ShellInterface(archive: shell.archive),
            policy: .init(
                acceptedCapabilities: Set(shell.archive.capabilities),
                allowedNativeImports: Set(shell.archive.nativeImports.compactMap(\.id)),
                allowMainActorEntries: true
            )
        )
    }

    @Test("Managed Debug prefreezes measured SDK members generically")
    func prefreezesManagedSDKMembers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-managed-sdk-properties-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = sourceDirectory.appendingPathComponent("Color.swift")
        let baseline = """
        import UIKit
        import Foundation

        @MainActor
        public func selectedColor(_ preferred: Bool) -> UIColor {
            if preferred { return .systemBlue }
            return UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        }

        @MainActor
        public func selectedScreen(_ baselineScreen: UIScreen) -> UIScreen {
            return baselineScreen
        }

        @MainActor
        public func selectedDevice(_ baselineDevice: UIDevice) -> UIDevice {
            return baselineDevice
        }

        @MainActor
        public func selectedApplication(
            _ baselineApplication: UIApplication
        ) -> UIApplication {
            return baselineApplication
        }

        @MainActor
        public func animationsEnabled(_ baselineView: UIView) -> Bool {
            _ = baselineView
            return false
        }

        @MainActor
        public func updateAlpha(_ baselineView: UIView, value: CGFloat) -> CGFloat {
            _ = baselineView
            return value
        }

        @MainActor
        public func requestLayout(_ baselineView: UIView) -> UIView {
            return baselineView
        }

        @MainActor
        public func updateAnimations(_ enabled: Bool) -> Bool {
            return enabled
        }

        public func selectedBundle(_ baselineBundle: Bundle) -> Bundle {
            return baselineBundle
        }

        public func selectedProcessInfo(
            _ baselineProcessInfo: ProcessInfo
        ) -> ProcessInfo {
            return baselineProcessInfo
        }

        public func resourcePath(
            _ baselineBundle: Bundle,
            name: String
        ) -> String? {
            _ = baselineBundle
            _ = name
            return nil
        }

        public func selectedCache(_ baselineCache: URLCache) -> URLCache {
            return baselineCache
        }

        public func replaceSharedCache(_ baselineCache: URLCache) -> URLCache {
            return baselineCache
        }

        public func selectedFileManager(
            _ baselineManager: FileManager
        ) -> FileManager {
            return baselineManager
        }

        public func removeItem(
            _ baselineManager: FileManager,
            path: String
        ) throws -> String {
            _ = baselineManager
            return path
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "ManagedSDKPropertyFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          \(moduleName):
            include:
              - Sources/**
            entrypoints: all
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Sources/**
                declarations:
                  - \(moduleName).*
                visibility: all
                profile: read-write
                maximumBoundedDurationMicroseconds: 2000
                allowsMainThread: true
        """)
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: moduleName,
            targetTriple: target,
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion,
            optimization: "-Onone",
            semanticArguments: ["-parse-as-library"]
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.managed-sdk-properties",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.managed-sdk-properties",
                buildNumber: "1",
                seed: "fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "integration-test",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: invocation,
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("computed by indexer")
        )
        let request = FrontendReceipt.Request(
            metadata: metadata,
            configuration: configuration,
            sources: [.init(logicalPath: "Sources/Color.swift", url: sourceURL)],
            compilerURL: compilerURL
        )

        let configured = try FrontendReceipt.Adapter().generate(request)
        let configuredNames = Set(
            configured.receipt.nativeImportCandidates.map(\.canonicalCallee)
        )
        #expect(configuredNames.contains(
            "\(moduleName).HelixExternal.UIColor.systemBlue.get"
        ))
        #expect(!configuredNames.contains(
            "\(moduleName).HelixExternal.UIColor.black.get"
        ))
        #expect(!configuredNames.contains(
            "\(moduleName).HelixExternal.UIScreen.main.get"
        ))
        #expect(!configuredNames.contains(
            "\(moduleName).HelixExternal.Bundle.main.get"
        ))
        for name in [
            "\(moduleName).HelixExternal.UIView.isHidden.get",
            "\(moduleName).HelixExternal.UIView.alpha.set",
            "\(moduleName).HelixExternal.UIView.setNeedsLayout().call",
            "\(moduleName).HelixExternal.UIView.setAnimationsEnabled(_:).call",
            "\(moduleName).HelixExternal.UIColor.init(white:alpha:)",
            "\(moduleName).HelixExternal.Bundle.path(forResource:ofType:).call",
            "\(moduleName).HelixExternal.URLCache.shared.set",
            "\(moduleName).HelixExternal.FileManager.removeItem(atPath:).call",
        ] {
            #expect(!configuredNames.contains(name))
        }

        var managedRequest = request
        managedRequest.callingSurfacePolicy = .managedDebugModule
        let managed = try FrontendReceipt.Adapter().generate(managedRequest)
        let managedNames = Set(
            managed.receipt.nativeImportCandidates.map(\.canonicalCallee)
        )
        let deprecatedScreenMain =
            "\(moduleName).HelixExternal.UIScreen.main.get"
        #expect(!managedNames.contains(deprecatedScreenMain))
        let firstUseNames = [
            "\(moduleName).HelixExternal.UIColor.black.get",
            "\(moduleName).HelixExternal.UIDevice.current.get",
            "\(moduleName).HelixExternal.UIApplication.shared.get",
            "\(moduleName).HelixExternal.UIView.areAnimationsEnabled.get",
            "\(moduleName).HelixExternal.Bundle.main.get",
            "\(moduleName).HelixExternal.ProcessInfo.processInfo.get",
        ]
        for name in firstUseNames {
            #expect(managedNames.contains(name))
        }
        let callableNames = [
            "\(moduleName).HelixExternal.UIView.isHidden.get",
            "\(moduleName).HelixExternal.UIView.alpha.set",
            "\(moduleName).HelixExternal.UIView.setNeedsLayout().call",
            "\(moduleName).HelixExternal.UIView.setAnimationsEnabled(_:).call",
            "\(moduleName).HelixExternal.UIColor.init(white:alpha:)",
            "\(moduleName).HelixExternal.Bundle.path(forResource:ofType:).call",
            "\(moduleName).HelixExternal.URLCache.shared.set",
            "\(moduleName).HelixExternal.FileManager.removeItem(atPath:).call",
        ]
        for name in callableNames {
            #expect(managedNames.contains(name))
        }
        #expect(managedNames.contains(
            "\(moduleName).HelixExternal.UIColor.systemMint.get"
        ))
        #expect(!managedNames.contains(
            "\(moduleName).HelixExternal.UIApplication."
                + "openDefaultApplicationsSettingsURLString.get"
        ))
        let blackName = firstUseNames[0]
        let black = try #require(managed.receipt.nativeImportCandidates.first {
            $0.canonicalCallee == blackName
        })
        #expect(black.contract.kind == .staticGetter)
        #expect(!black.effects.requiresMainActor)
        #expect(
            black.contract.execution.maximumDurationMicroseconds == 2_000
        )
        let systemBlue = try #require(managed.receipt.nativeImportCandidates.first {
            $0.canonicalCallee
                == "\(moduleName).HelixExternal.UIColor.systemBlue.get"
        })
        #expect(!systemBlue.effects.requiresMainActor)
        let application = try #require(managed.receipt.nativeImportCandidates.first {
            $0.canonicalCallee == firstUseNames[2]
        })
        #expect(application.effects.requiresMainActor)
        #expect(
            application.contract.execution.maximumDurationMicroseconds
                == 16_000
        )
        let bundle = try #require(managed.receipt.nativeImportCandidates.first {
            $0.canonicalCallee == firstUseNames[4]
        })
        #expect(!bundle.effects.requiresMainActor)
        let throwingRemoval = try #require(
            managed.receipt.nativeImportCandidates.first {
                $0.canonicalCallee == callableNames[7]
            }
        )
        #expect(throwingRemoval.effects.mayThrow)
        #expect(throwingRemoval.contract.kind == .instanceMethod)

        let nativeTypes = Dictionary(uniqueKeysWithValues:
            managed.receipt.nativeTypes.map { ($0.canonicalName, $0) }
        )
        #expect(nativeTypes["UIColor"]?.requiresMainActor == false)
        #expect(nativeTypes["UIScreen"]?.requiresMainActor == true)
        let generatedTypes = managed.receipt.nativeTypeBindings.compactMap(\.generated)
        #expect(generatedTypes.contains { $0.swiftType == "Bundle" })
        #expect(generatedTypes.contains { $0.swiftType == "ProcessInfo" })
        #expect(!generatedTypes.contains {
            $0.swiftType == "NSBundle" || $0.swiftType == "NSProcessInfo"
        })

        let firstUseIDs = try Dictionary(uniqueKeysWithValues: firstUseNames.map { name in
            let candidate = try #require(
                managed.receipt.nativeImportCandidates.first {
                    $0.canonicalCallee == name
                }
            )
            return (name, try #require(candidate.id))
        })
        let callableIDs = try Dictionary(uniqueKeysWithValues: callableNames.map { name in
            let candidate = try #require(
                managed.receipt.nativeImportCandidates.first {
                    $0.canonicalCallee == name
                }
            )
            return (name, try #require(candidate.id))
        })

        let shell = try ShellBuild.Materializer().materialize(
            receipt: managed.receipt,
            sourceRoot: directory
        )
        let generated = shell.bridge.sourceFiles.values.joined(separator: "\n")
        #expect(!generated.contains("NSBundle"))
        #expect(!generated.contains("NSProcessInfo"))
        #expect(generated.contains("UIColor.black"))
        #expect(generated.contains("UIColor.systemMint"))
        #expect(!generated.contains("UIScreen.main"))
        #expect(generated.contains("UIDevice.current"))
        #expect(generated.contains("UIApplication.shared"))
        #expect(generated.contains("UIView.areAnimationsEnabled"))
        #expect(generated.contains("Bundle.main"))
        #expect(generated.contains("ProcessInfo.processInfo"))
        #expect(generated.contains("argument0.isHidden"))
        #expect(generated.contains("argument1.alpha = argument0"))
        #expect(generated.contains("argument0.setNeedsLayout()"))
        #expect(generated.contains("UIView.setAnimationsEnabled(argument0)"))
        #expect(generated.contains("UIColor(white: argument0, alpha: argument1)"))
        #expect(generated.contains("argument2.path(forResource: argument0, ofType: argument1)"))
        #expect(generated.contains("URLCache.shared = argument0"))
        #expect(generated.contains("try argument1.removeItem(atPath: argument0)"))

        let changed = baseline
            .replacingOccurrences(of: ".systemBlue", with: ".black")
            .replacingOccurrences(
                of: "UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)",
                with: "UIColor(white: 0.2, alpha: 1)"
            )
            .replacingOccurrences(of: "return baselineDevice", with: "return .current")
            .replacingOccurrences(
                of: "return baselineApplication",
                with: "return .shared"
            )
            .replacingOccurrences(
                of: "_ = baselineView\n    return false",
                with: "return baselineView.isHidden"
            )
            .replacingOccurrences(
                of: "_ = baselineView\n    return value",
                with: "baselineView.alpha = value\n    return value"
            )
            .replacingOccurrences(
                of: "public func requestLayout(_ baselineView: UIView) -> UIView {\n    return baselineView",
                with: "public func requestLayout(_ baselineView: UIView) -> UIView {\n    baselineView.setNeedsLayout()\n    return baselineView"
            )
            .replacingOccurrences(
                of: "public func updateAnimations(_ enabled: Bool) -> Bool {\n    return enabled",
                with: "public func updateAnimations(_ enabled: Bool) -> Bool {\n    UIView.setAnimationsEnabled(enabled)\n    return UIView.areAnimationsEnabled"
            )
            .replacingOccurrences(of: "return baselineBundle", with: "return .main")
            .replacingOccurrences(
                of: "return baselineProcessInfo",
                with: "return .processInfo"
            )
            .replacingOccurrences(
                of: "_ = baselineBundle\n    _ = name\n    return nil",
                with: "return baselineBundle.path(forResource: name, ofType: nil)"
            )
            .replacingOccurrences(
                of: "public func replaceSharedCache(_ baselineCache: URLCache) -> URLCache {\n    return baselineCache",
                with: "public func replaceSharedCache(_ baselineCache: URLCache) -> URLCache {\n    URLCache.shared = baselineCache\n    return baselineCache"
            )
            .replacingOccurrences(
                of: "_ = baselineManager\n    return path",
                with: "try baselineManager.removeItem(atPath: path)\n    return path"
            )
        for expectedUse in [
            "return baselineView.isHidden",
            "baselineView.alpha = value",
            "baselineView.setNeedsLayout()",
            "UIView.setAnimationsEnabled(enabled)",
            "return UIView.areAnimationsEnabled",
            "UIColor(white: 0.2, alpha: 1)",
            "return baselineBundle.path(forResource: name, ofType: nil)",
            "URLCache.shared = baselineCache",
            "try baselineManager.removeItem(atPath: path)",
        ] {
            #expect(changed.contains(expectedUse))
        }
        try Data(changed.utf8).write(to: sourceURL)
        let patch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [sourceURL],
                compilerURL: compilerURL
            )
        )
        for name in firstUseNames {
            let id = try #require(firstUseIDs[name])
            #expect(
                patch.module.imports.contains { $0.id == id },
                "patch omitted \(name) (#\(id.rawValue))"
            )
            #expect(
                patch.disassembly.contains("native_apply #\(id.rawValue)"),
                "patch did not call \(name) (#\(id.rawValue))"
            )
        }
        for name in callableNames {
            let id = try #require(callableIDs[name])
            #expect(
                patch.module.imports.contains { $0.id == id },
                "patch omitted \(name) (#\(id.rawValue))"
            )
            let opcode = name == callableNames[7]
                ? "native_try_apply" : "native_apply"
            #expect(
                patch.disassembly.contains("\(opcode) #\(id.rawValue)"),
                "patch did not call \(name) (#\(id.rawValue))"
            )
        }
        _ = try Verification.Engine().verify(
            bytes: patch.bytecode,
            shell: Verification.ShellInterface(archive: shell.archive),
            policy: .init(
                acceptedCapabilities: Set(shell.archive.capabilities),
                allowedNativeImports: Set(shell.archive.nativeImports.compactMap(\.id)),
                allowMainActorEntries: true
            )
        )
    }

    private func swiftPMModulesDirectory() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
        var candidates: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in enumerator
            where file.lastPathComponent == "HelixRuntime.swiftmodule" {
                candidates.append(file.deletingLastPathComponent())
            }
        }
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        if let matching = candidates.first(where: {
            $0.deletingLastPathComponent().lastPathComponent == configuration
        }) {
            return matching
        }
        guard let fallback = candidates.sorted(by: { $0.path < $1.path }).first else {
            throw FrontendReceipt.Error.invalidRequest("cannot locate SwiftPM module artifacts")
        }
        return fallback
    }

    private func runtimeSupportCompilerArguments(modules: URL) throws -> [String] {
        let supportDirectory = modules.deletingLastPathComponent()
            .appendingPathComponent("HelixRuntimeSupport.build", isDirectory: true)
        let moduleMap = supportDirectory.appendingPathComponent("module.modulemap")
        guard FileManager.default.fileExists(atPath: moduleMap.path) else {
            throw FrontendReceipt.Error.invalidRequest("missing HelixRuntimeSupport module map")
        }
        return ["-Xcc", "-fmodule-map-file=\(moduleMap.path)"]
    }

    private func requireFrontendSuccess(_ output: SwiftFrontend.Output) throws {
        guard output.terminationStatus == 0 else {
            throw FrontendReceipt.Error.frontendFailed(output.standardError)
        }
    }

    @Test("A source range expands deterministically into exact value-only operations")
    func discoversEligibleOperationsAndDiagnosesBoundaries() throws {
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          ScopeFixture:
            include:
              - Patchable/**
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Native/**
                declarations:
                  - ScopeFixture.*
                visibility: public
                profile: read
                maximumBoundedDurationMicroseconds: 750
                maximumSuspendingDurationMicroseconds: 5000000
                allowsMainThread: false
        """)
        let metadata = makeMetadata(moduleName: "ScopeFixture")
        let scalar = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let counterType = Core.TypeID.derive(
            namespace: metadata.shellNamespaceID,
            canonicalType: "ScopeFixture.Counter"
        )
        var instance = declaration(
            canonicalCallee: "ScopeFixture.Counter.increment(_:)",
            mangledName: "$s12ScopeFixture7CounterC9incrementyS2iF",
            dispatch: .instanceMethod,
            ownerType: "Counter",
            signature: .init(
                parameters: ["Swift.Int", "ScopeFixture.Counter"],
                result: "Swift.Int"
            )
        )
        instance.parameterSwiftTypes = ["Swift.Int", "Counter"]
        instance.parameterTypes = [.int64, .native(counterType)]
        instance.parameterProjection = .identity(parameterCount: 2)
        let declarations = [
            declaration(
                canonicalCallee: "ScopeFixture.compute(_:)",
                mangledName: "$s12ScopeFixture7computeyS2iF",
                signature: scalar
            ),
            declaration(
                canonicalCallee: "ScopeFixture.Math.double(_:)",
                mangledName: "$s12ScopeFixture4MathO6doubleyS2iFZ",
                dispatch: .staticMethod,
                ownerType: "Math",
                signature: scalar
            ),
            declaration(
                canonicalCallee: "ScopeFixture.hidden(_:)",
                mangledName: "$s12ScopeFixture6hiddenyS2iF",
                accessLevel: "internal",
                signature: scalar
            ),
            instance,
            declaration(
                canonicalCallee: "ScopeFixture.Counter.increment(_:)",
                mangledName: "$s12ScopeFixture7CounterC12malformedyS2iF",
                dispatch: .instanceMethod,
                ownerType: "Counter",
                signature: scalar
            ),
            declaration(
                canonicalCallee: "ScopeFixture.suspend(_:)",
                mangledName: "$s12ScopeFixture7suspendyS2iYaF",
                signature: .init(
                    parameters: ["Swift.Int"],
                    result: "Swift.Int",
                    isAsync: true
                ),
                effects: .init(isAsync: true)
            ),
        ]

        let output = try NativeImportDiscovery.Engine().discover(
            declarations: Array(declarations.reversed()),
            metadata: metadata,
            configuration: configuration
        )

        #expect(output.candidates.map(\.record.canonicalCallee).sorted() == [
            "ScopeFixture.Counter.increment(_:)",
            "ScopeFixture.Math.double(_:)",
            "ScopeFixture.compute(_:)",
            "ScopeFixture.suspend(_:)",
        ])
        #expect(output.candidates.allSatisfy {
            $0.record.contract.domain == .application
                && $0.record.contract.access == .read
                && $0.record.contract.execution.maximumDurationMicroseconds
                    == ($0.record.effects.isAsync ? 5_000_000 : 750)
                && $0.record.contract.execution.deadlineMode
                    == ($0.record.effects.isAsync ? .suspending : .bounded)
                && !$0.record.contract.execution.allowsMainThread
                && $0.record.effects.mayAllocate
                && !$0.record.effects.hasExternalSideEffects
                && $0.record.id == nil
        })
        #expect(Set(output.candidates.map(\.record.contract.kind)) == [
            .globalFunction, .instanceMethod, .staticMethod,
        ])
        #expect(output.diagnostics.map(\.code) == ["HLXNID001"])
        #expect(!output.candidates.contains {
            $0.record.canonicalCallee == "ScopeFixture.hidden(_:)"
        })

        let repeated = try NativeImportDiscovery.Engine().discover(
            declarations: declarations,
            metadata: metadata,
            configuration: configuration
        )
        #expect(repeated.candidates == output.candidates)
        #expect(repeated.diagnostics == output.diagnostics)

        var foreign = declarations[0]
        foreign.moduleName = "AnotherModule"
        #expect(throws: FrontendReceipt.Error.self) {
            try NativeImportDiscovery.Engine().discover(
                declarations: [foreign],
                metadata: metadata,
                configuration: configuration
            )
        }
    }

    @Test("Source discovery grants one frame only to exact MainActor bounded calls")
    func assignsActorSpecificBoundedDeadlines() throws {
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          ScopeFixture:
            include:
              - Patchable/**
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Native/**
                declarations:
                  - ScopeFixture.*
                visibility: public
                profile: read-write
                maximumBoundedDurationMicroseconds: 16000
                allowsMainThread: true
        """)
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let ordinary = declaration(
            canonicalCallee: "ScopeFixture.compute(_:)",
            mangledName: "$s12ScopeFixture7computeyS2iF",
            signature: signature
        )
        let actor = declaration(
            canonicalCallee: "ScopeFixture.render(_:)",
            mangledName: "$s12ScopeFixture6renderyS2iF",
            signature: signature,
            effects: .init(requiresMainActor: true)
        )

        let output = try NativeImportDiscovery.Engine().discover(
            declarations: [ordinary, actor],
            metadata: makeMetadata(moduleName: "ScopeFixture"),
            configuration: configuration
        )
        let durations = Dictionary(uniqueKeysWithValues:
            output.candidates.map {
                ($0.record.canonicalCallee,
                 $0.record.contract.execution.maximumDurationMicroseconds)
            }
        )
        #expect(durations["ScopeFixture.compute(_:)"] == 2_000)
        #expect(durations["ScopeFixture.render(_:)"] == 16_000)
    }

    @Test("Automatic discovery accepts frozen Native values but rejects address and closure boundaries")
    func rejectsUnsupportedBoundaryTypes() throws {
        let configuration = try PatchConfiguration.Document.parse(yaml: """
        schema: 1
        modules:
          ScopeFixture:
            include:
              - Sources/**
            nativeImports:
              candidateIndex: source-and-catalog
              emit: scoped
              sourceScope:
                include:
                  - Sources/**
                profile: pure
        """)
        let metadata = makeMetadata(moduleName: "ScopeFixture")
        let typeID = Core.TypeID.derive(
            namespace: metadata.shellNamespaceID,
            canonicalType: "ScopeFixture.Token"
        )
        var native = declaration(
            canonicalCallee: "ScopeFixture.consume(_:)",
            mangledName: "$s12ScopeFixture7consumeyAA5TokenCF",
            signature: .init(
                parameters: ["ScopeFixture.Token"],
                result: "Swift.Void"
            )
        )
        native.parameterSwiftTypes = ["ScopeFixture.Token"]
        native.parameterTypes = [.native(typeID)]
        native.resultSwiftType = "Swift.Void"
        native.resultType = .void
        native.sourceFileLogicalID = "Sources/Operations.swift"

        var address = native
        address.canonicalCallee = "ScopeFixture.mutate(_:)"
        address.mangledName = "$s12ScopeFixture6mutateyySizF"
        address.parameterTypes = [.address(.int64)]
        address.signature = .init(parameters: ["inout Swift.Int"], result: "Swift.Void")

        var closure = native
        closure.canonicalCallee = "ScopeFixture.invoke(_:)"
        closure.mangledName = "$s12ScopeFixture6invokeyyS2icF"
        closure.parameterTypes = [
            .closure(
                .init(
                    parameters: [.int64],
                    parameterConventions: [.owned],
                    result: .int64
                )
            ),
        ]
        closure.signature = .init(
            parameters: ["(Swift.Int) -> Swift.Int"],
            result: "Swift.Void"
        )

        let output = try NativeImportDiscovery.Engine().discover(
            declarations: [native, address, closure],
            metadata: metadata,
            configuration: configuration
        )
        #expect(output.candidates.map(\.record.canonicalCallee) == [
            "ScopeFixture.consume(_:)",
        ])
        #expect(output.diagnostics.map(\.code) == ["HLXNID005", "HLXNID005"])
    }

    private func declaration(
        canonicalCallee: String,
        mangledName: String,
        accessLevel: String = "public",
        dispatch: NativeImportDiscovery.Dispatch = .globalFunction,
        ownerType: String? = nil,
        signature: Core.LoweredSignature,
        effects: Core.Effects = .init()
    ) -> NativeImportDiscovery.Declaration {
        .init(
            moduleName: "ScopeFixture",
            sourceFileLogicalID: "Native/Operations.swift",
            mangledName: mangledName,
            canonicalCallee: canonicalCallee,
            accessLevel: accessLevel,
            dispatch: dispatch,
            ownerType: ownerType,
            baseName: canonicalCallee.contains("double") ? "double" :
                canonicalCallee.split(separator: ".").last.map {
                    String($0.split(separator: "(").first ?? $0)
                } ?? "operation",
            argumentLabels: ["_"],
            parameterSwiftTypes: ["Swift.Int"],
            parameterProjection: .identity(parameterCount: 1),
            resultSwiftType: "Swift.Int",
            parameterTypes: [.int64],
            resultType: .int64,
            signature: signature,
            inferredEffects: effects,
            isGeneric: false,
            hasInOut: false,
            hasTypedThrows: false,
            hasUnsupportedAttributes: false
        )
    }

    private func makeMetadata(moduleName: String) -> InterfaceArchive.ReleaseMetadata {
        let target = "arm64-apple-ios15.0-simulator"
        return .init(
            bundleID: "dev.helix.native-import-scope",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.native-import-scope",
                buildNumber: "1",
                seed: "scope-fixture"
            ),
            machOUUIDs: [],
            targetTriple: target,
            minimumOS: .init(15),
            xcodeBuild: "test",
            sdkBuild: "test",
            frontendInvocation: .init(
                moduleName: moduleName,
                targetTriple: target,
                sdkName: "iphonesimulator",
                sdkBuild: "test",
                optimization: "-Onone",
                semanticArguments: ["-parse-as-library"]
            ),
            transformPipelineHash: ShellBuild.transformPipelineHash,
            sourceBaselineHash: .sha256("test")
        )
    }
}
}
