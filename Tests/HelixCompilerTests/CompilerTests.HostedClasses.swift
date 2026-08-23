import Foundation
import HelixBytecode
import HelixCore
import HelixInterface
import HelixVerifier
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Objective-C hosted patch-local classes")
struct HostedClasses {
    #if os(macOS)
    @Test("A new UIViewController subclass becomes a verified hosted HLBC class")
    func compilesUIViewControllerSubclass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-hosted-uiviewcontroller-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            import UIKit

            final class EmergencyViewController: UIViewController {
                override func viewDidLoad() {
                    super.viewDidLoad()
                }
            }

            @inline(never)
            func makeController() -> UIViewController {
                EmergencyViewController()
            }
            """.utf8
        ).write(to: source)

        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let sil = try frontend.emitCanonicalSIL(
            sourceFiles: [source],
            moduleName: "HostedClassFixture",
            optimization: "-Onone",
            additionalArguments: [
                "-sdk", sdk.path,
                "-target", "arm64-apple-ios15.0-simulator",
                "-module-cache-path", directory.appendingPathComponent("ModuleCache").path,
            ]
        )
        let file = try CanonicalSIL.File(text: sil)
        let root = try file.uniqueFunction(mangledNameContaining: "makeController")
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.hosted-class",
            buildNumber: "1",
            seed: "fixture"
        )
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "HostedClassFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func makeController() -> UIViewController",
            loweredSignature: .init(
                parameters: [],
                result: "UIKit.UIViewController"
            ),
            role: .function
        )
        let controllerType = Core.TypeID.derive(
            namespace: namespace,
            canonicalType: "UIKit.UIViewController"
        )
        let shellHash = Core.Digest.sha256("hosted-class-shell")
        let entry = Core.EntryIndex(rawValue: 0)
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "hosted-class-fixture"
        )
        let result = try PatchCompiler.Driver().compile(
            .init(
                canonicalSIL: sil,
                mangledName: root.mangledName,
                displayName: "makeController",
                functionKey: functionKey,
                entryIndex: entry,
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                nativeTypes: ["UIKit.UIViewController": controllerType],
                nativeTypeKinds: [controllerType: .reference],
                mainActorNativeTypes: [controllerType],
                effects: .init(requiresMainActor: true),
                sourceFileLogicalID: "Patch.swift"
            )
        )

        let definition = try #require(result.module.localTypes.first)
        #expect(definition.key.rawValue == "EmergencyViewController")
        guard case let .class(fields, superclass, methods) = definition.kind else {
            Issue.record("expected one hosted local class")
            return
        }
        #expect(fields.isEmpty)
        #expect(superclass?.typeID == controllerType)
        #expect(methods.count == 1)
        #expect(methods.first?.selector == "viewDidLoad")
        #expect(methods.first?.abi == .voidNoArguments)
        #expect(result.module.capabilities.contains(.localClassesV1))
        #expect(result.module.capabilities.contains(.hostedObjectiveCClassesV1))
        #expect(result.module.capabilities.contains(.borrowCallsV1))
        #expect(result.disassembly.contains("allocate_object"))
        #expect(result.disassembly.contains("project_hosted_object"))
        #expect(result.disassembly.contains("hosted_super_apply"))

        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: [
                .baselineV1,
                .nativeTypesV1,
                .localNominalsV1,
                .localClassesV1,
                .hostedObjectiveCClassesV1,
                .mainActorSyncV1,
                .borrowCallsV1,
            ],
            entries: [
                .init(
                    index: entry,
                    key: functionKey,
                    parameterTypes: [],
                    parameterConventions: [],
                    resultType: .native(controllerType),
                    effects: .init(requiresMainActor: true)
                ),
            ],
            types: [
                .init(
                    id: controllerType,
                    canonicalName: "UIKit.UIViewController",
                    kind: .reference,
                    layoutFingerprint: .sha256("UIViewController-layout"),
                    isCopyable: true,
                    requiresMainActor: true,
                    estimatedSize: 8
                ),
            ]
        )
        _ = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: shell,
            policy: .init(
                acceptedCapabilities: shell.capabilities,
                allowMainActorSynchronousEntries: true
            )
        )

        var nonisolated = result.module
        let hostedFunctionID = try #require(methods.first?.functionID)
        let hostedFunctionIndex = try #require(
            nonisolated.functions.firstIndex { $0.id == hostedFunctionID }
        )
        nonisolated.functions[hostedFunctionIndex].effects.requiresMainActor = false
        #expect(throws: Verification.Error.self) {
            _ = try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(nonisolated),
                shell: shell,
                policy: .init(
                    acceptedCapabilities: shell.capabilities,
                    allowMainActorSynchronousEntries: true
                )
            )
        }

        var storedField = result.module
        let definitionIndex = try #require(
            storedField.localTypes.firstIndex { $0.key == definition.key }
        )
        storedField.localTypes[definitionIndex].kind = .class(
            fields: [.init(name: "premature", type: .bool)],
            hostedSuperclass: superclass,
            hostedMethods: methods
        )
        #expect(throws: Verification.Error.self) {
            _ = try Verification.Engine().verify(
                bytes: Bytecode.Encoder.encode(storedField),
                shell: shell,
                policy: .init(
                    acceptedCapabilities: shell.capabilities,
                    allowMainActorSynchronousEntries: true
                )
            )
        }
    }

    @Test("A new class can inherit and override a frozen project class")
    func compilesProjectClassSubclass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-hosted-project-class-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Patch.swift")
        try Data(
            """
            import Foundation

            class ExistingBase: NSObject {
                @objc dynamic func refresh(_ enabled: Bool) {}
            }

            final class ExistingChild: ExistingBase {
                override func refresh(_ enabled: Bool) {
                    super.refresh(enabled)
                }
            }

            final class PatchChild: ExistingBase {
                private var shouldRefresh: Bool { check() }

                @inline(never)
                private func check() -> Bool { true }

                override func refresh(_ enabled: Bool) {
                    if shouldRefresh {
                        super.refresh(enabled)
                    }
                }
            }

            @inline(never)
            func makeChild() -> ExistingBase {
                PatchChild()
            }
            """.utf8
        ).write(to: source)

        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let sil = try frontend.emitCanonicalSIL(
            sourceFiles: [source],
            moduleName: "HostedProjectFixture",
            optimization: "-Onone",
            additionalArguments: [
                "-sdk", sdk.path,
                "-target", "arm64-apple-ios15.0-simulator",
                "-module-cache-path", directory.appendingPathComponent("ModuleCache").path,
            ]
        )
        let file = try CanonicalSIL.File(text: sil)
        let root = try file.uniqueFunction(mangledNameContaining: "makeChild")
        let existingOverride = try #require(
            file.functions.first {
                $0.mangledName.contains("ExistingChild")
                    && $0.mangledName.contains("refresh")
                    && $0.loweredType.contains("@convention(method)")
            }
        )
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.hosted-project-class",
            buildNumber: "1",
            seed: "fixture"
        )
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "HostedProjectFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func makeChild() -> ExistingBase",
            loweredSignature: .init(
                parameters: [],
                result: "HostedProjectFixture.ExistingBase"
            ),
            role: .function
        )
        let baseType = Core.TypeID.derive(
            namespace: namespace,
            canonicalType: "HostedProjectFixture.ExistingBase"
        )
        let shellHash = Core.Digest.sha256("hosted-project-class-shell")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "hosted-project-class-fixture"
        )
        let entry = Core.EntryIndex(rawValue: 0)
        let result = try PatchCompiler.Driver().compile(
            .init(
                canonicalSIL: sil,
                mangledName: root.mangledName,
                displayName: "makeChild",
                functionKey: functionKey,
                entryIndex: entry,
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                nativeTypes: [
                    "HostedProjectFixture.ExistingBase": baseType,
                ],
                nativeTypeKinds: [baseType: .reference],
                shellDeclarationSymbols: [existingOverride.mangledName],
                sourceFileLogicalID: "Patch.swift"
            )
        )
        let definition = try #require(
            result.module.localTypes.first { $0.key.rawValue == "PatchChild" }
        )
        guard case let .class(fields, superclass, methods) = definition.kind else {
            Issue.record("expected one hosted project class")
            return
        }
        #expect(fields.isEmpty)
        #expect(superclass?.typeID == baseType)
        #expect(methods.map(\.selector) == ["refresh:"])
        #expect(methods.map(\.abi) == [.voidBool])
        #expect(!result.module.localTypes.contains {
            $0.key.rawValue == "ExistingChild"
        })
        #expect(result.module.functions.count >= 4)
        #expect(result.disassembly.contains("hosted_super_apply"))

        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: result.module.capabilities,
            entries: [
                .init(
                    index: entry,
                    key: functionKey,
                    parameterTypes: [],
                    parameterConventions: [],
                    resultType: .native(baseType)
                ),
            ],
            types: [
                .init(
                    id: baseType,
                    canonicalName: "HostedProjectFixture.ExistingBase",
                    kind: .reference,
                    layoutFingerprint: .sha256("ExistingBase-layout"),
                    isCopyable: true,
                    estimatedSize: 8
                ),
            ]
        )
        _ = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: shell,
            policy: .init(acceptedCapabilities: result.module.capabilities)
        )
    }
    #endif
}
}
