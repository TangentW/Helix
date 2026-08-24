import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface
import HelixVM
import HelixVerifier
import Testing

@testable import HelixBuildTools

extension BuildToolsTests.FrontendReceiptPipeline {
    @Test("Stored property observers reload as exact independent roots")
    func reloadsStoredPropertyObservers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-source-observers-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = sourceDirectory.appendingPathComponent("Observers.swift")
        let modelsURL = sourceDirectory.appendingPathComponent("Models.swift")
        let models = """
            public struct NestedValue {
                public var amount: Int

                public init(amount: Int) {
                    self.amount = amount
                }
            }
            """
        try Data(models.utf8).write(to: modelsURL)
        let baseline = """
            public var globalChanges: Int = 0
            public var globalValue: Int = 1 {
                willSet(incoming) { globalChanges += incoming + 9 }
                didSet(previous) { globalChanges += previous + 10 }
            }

            public struct ExecutionBox {
                public var changes: Int = 0
                public var value: Int = 1 {
                    willSet(incoming) { changes += incoming + 1 }
                    didSet(previous) { changes += previous + 2 }
                }
                public var nested = NestedValue(amount: 7)
            }

            public struct SelfReadBox {
                public var changes: Int = 0
                public var value: Int = 2 {
                    didSet { changes += value + 3 }
                }
            }

            public struct PartialBox {
                public var changes: Int = 0
                public var value: Int = 3 {
                    willSet { changes += newValue + 4 }
                    didSet {
                        if value < 0 { value = 0 }
                    }
                }
            }

            public struct MagicBox {
                public var changes: Int = 0
                public var value: Int = 4 {
                    willSet { changes += newValue + 5 }
                    didSet { print(#function) }
                }
            }

            public class ReferenceBox {
                public var changes: Int = 0
                public var value: Int = 5 {
                    willSet(incoming) { changes += incoming + 6 }
                    didSet(previous) { changes += previous + 7 }
                }
            }

            @MainActor
            public final class MainActorBox {
                public var changes: Int = 0
                public var value: Int = 6 {
                    didSet(previous) { changes += previous + 8 }
                }
            }

            public enum StaticBox {
                public static var changes: Int = 0
                public static var value: Int = 7 {
                    didSet { changes += oldValue }
                }
            }

            public class BaseBox {
                public var value: Int = 8
            }

            public final class ChildBox: BaseBox {
                public override var value: Int {
                    didSet { _ = oldValue }
                }
            }

            @propertyWrapper
            public struct Wrapped<Value> {
                public var wrappedValue: Value
                public init(wrappedValue: Value) {
                    self.wrappedValue = wrappedValue
                }
            }

            public struct UnsupportedBox {
                public lazy var lazyValue: Int = 9 {
                    didSet { _ = oldValue }
                }
                @Wrapped public var wrappedValue: Int = 10 {
                    didSet { _ = oldValue }
                }
            }

            @available(iOS 99, *)
            public struct FutureBox {
                public var value: Int = 11 {
                    didSet { _ = oldValue }
                }
            }

            public struct GenericBox<Element> {
                public var value: Element {
                    didSet { _ = oldValue }
                }
            }

            public final class ReferenceValue {}

            public final class WeakBox {
                public weak var value: ReferenceValue? {
                    didSet { _ = oldValue }
                }
            }
            """
        let baselineData = Data(baseline.utf8)
        try baselineData.write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "FrontendObserverFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(
            yaml: """
                schema: 1
                modules:
                  \(moduleName):
                    include:
                      - Sources/**/*.swift
                    nativeImports:
                      candidateIndex: source-and-catalog
                      emit: scoped
                      sourceScope:
                        include:
                          - Sources/Observers.swift
                        declarations:
                          - "*ReferenceBox*"
                        visibility: public
                        profile: bounded-read-write
                        maximumDurationMicroseconds: 500
                        allowsMainThread: true
                """
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.source-observers",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.source-observers",
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
                    .init(logicalPath: "Sources/Models.swift", url: modelsURL),
                    .init(logicalPath: "Sources/Observers.swift", url: sourceURL)
                ],
                compilerURL: compilerURL
            )
        )
        let receipt = output.receipt
        let observerDeclarations = receipt.declarations.filter {
            [.willSet, .didSet].contains($0.role)
        }
        let observerRoots = receipt.roots.filter {
            [.willSet, .didSet].contains($0.memberRole)
        }
        #expect(observerDeclarations.count == 10)
        #expect(observerRoots.count == 10)
        #expect(observerRoots.allSatisfy { $0.bridge?.bridgeInvocation == nil })
        #expect(observerRoots.allSatisfy { $0.nativeReplacement == nil })
        #expect(observerRoots.allSatisfy {
            $0.sourceBodyTransform != nil && $0.declarationInsertion == nil
        })
        #expect(observerRoots.allSatisfy {
            $0.sourceDeclaration.kind == .propertyObservers
        })

        var missingTransform = receipt
        missingTransform.roots[0].sourceBodyTransform = nil
        #expect(throws: ShellBuildReceipt.Error.self) {
            try missingTransform.validate()
        }
        var callableObserver = receipt
        var callableRoot = callableObserver.roots[0]
        var callableBridge = try #require(callableRoot.bridge)
        callableBridge.bridgeInvocation = "forgedObserverCall()"
        callableRoot.bridge = callableBridge
        callableObserver.roots[0] = callableRoot
        #expect(throws: ShellBuildReceipt.Error.self) {
            try callableObserver.validate()
        }
        var staleTransform = receipt
        staleTransform.roots[0].sourceBodyTransform?.expectedBodyHash = .sha256(
            "stale observer body"
        )
        #expect(throws: SourceTransform.Error.self) {
            try ShellBuild.Materializer().materialize(
                receipt: staleTransform,
                sourceRoot: directory
            )
        }

        let executionRoots = observerRoots.filter {
            $0.nominalType?.canonicalName == "ExecutionBox"
        }
        #expect(Set(executionRoots.map(\.memberRole)) == [.willSet, .didSet])
        #expect(
            executionRoots.first { $0.memberRole == .willSet }?
                .sourceDeclaration.member(.willSet)?.header == "willSet(incoming)"
        )
        #expect(
            executionRoots.first { $0.memberRole == .didSet }?
                .sourceDeclaration.member(.didSet)?.header == "didSet(previous)"
        )
        #expect(executionRoots.allSatisfy {
            $0.bridge?.parameterExpressions.last == "self"
        })

        let globalRoots = observerRoots.filter { $0.nominalType == nil }
        #expect(globalRoots.count == 2)
        #expect(globalRoots.allSatisfy {
            $0.sourceDeclaration.replacementHeader.contains(" = globalValue")
                && $0.bridge?.parameterExpressions.count == 1
        })

        let partialRoots = observerRoots.filter {
            $0.nominalType?.canonicalName == "PartialBox"
        }
        #expect(Set(partialRoots.map(\.memberRole)) == [.willSet, .didSet])
        let magicRoots = observerRoots.filter {
            $0.nominalType?.canonicalName == "MagicBox"
        }
        #expect(magicRoots.map(\.memberRole) == [.willSet])
        #expect(magicRoots[0].sourceDeclaration.member(.didSet) == nil)

        let unsupportedOwners: Set<String> = [
            "StaticBox", "ChildBox", "UnsupportedBox", "FutureBox", "GenericBox",
            "WeakBox", "MainActorBox",
        ]
        #expect(observerRoots.allSatisfy {
            guard let owner = $0.nominalType?.canonicalName else { return true }
            return !unsupportedOwners.contains(owner)
        })

        let shell = try ShellBuild.Materializer().materialize(
            receipt: receipt,
            sourceRoot: directory
        )
        let observerFunctions = shell.archive.functions.filter {
            $0.patchability.isEligible && [.willSet, .didSet].contains($0.role)
        }
        let observerFunctionKeys = Set(observerFunctions.map(\.key))
        #expect(observerFunctions.count == observerRoots.count)
        #expect(observerFunctions.allSatisfy { !$0.fallbackAllowed })
        #expect(observerFunctionKeys.isDisjoint(with: Set(
            shell.reloadIndex.nativeReplacements.map(\.functionKey)
        )))
        let transformed = String(
            decoding: try #require(shell.transformedSources["Sources/Observers.swift"]),
            as: UTF8.self
        )
        #expect(transformed.contains("public var globalValue"))
        #expect(transformed.contains("public var value: Int = 1"))
        #expect(transformed.contains("public var value: Int = 3"))
        #expect(!transformed.contains("public dynamic var globalValue"))
        #expect(!transformed.contains("public dynamic var value: Int = 1"))
        #expect(!transformed.contains("public static dynamic var value"))
        #expect(!transformed.contains("public override dynamic var value"))
        #expect(!transformed.contains("public lazy dynamic var lazyValue"))

        try typeCheckGeneratedBridge(
            shell: shell,
            directory: directory,
            moduleName: moduleName,
            emitEntryObjects: true
        )
        let generatedBridge = shell.bridge.sourceFiles.values.joined(separator: "\n")
        #expect(generatedBridge.contains("Swift property observer has no source-callable original entry"))
        #expect(!generatedBridge.contains("@_dynamicReplacement(for: value)"))
        #expect(transformed.contains("Generated by Helix inside the original module"))
        let transformedModels = String(
            decoding: try #require(shell.transformedSources["Sources/Models.swift"]),
            as: UTF8.self
        )
        #expect(transformedModels.contains("Generated by Helix inside the original module"))
        #expect(transformedModels.contains("static func encodeInput_"))
        #expect(
            transformed.components(separatedBy: "changes += incoming + 1").count == 2
        )
        #expect(
            transformed.components(separatedBy: "changes += previous + 2").count == 2
        )

        let patched = baseline
            .replacingOccurrences(
                of: "changes += incoming + 1",
                with: "changes += incoming + 10"
            )
            .replacingOccurrences(
                of: "changes += previous + 2",
                with: "changes += previous + 20"
            )
            .replacingOccurrences(
                of: "changes += value + 3",
                with: "changes += value + 30"
            )
            .replacingOccurrences(of: "value = 0", with: "value = 42")
            .replacingOccurrences(
                of: "changes += incoming + 6",
                with: "changes += incoming + 60"
            )
            .replacingOccurrences(
                of: "changes += previous + 7",
                with: "changes += previous + 70"
            )
        #expect(patched != baseline)
        try Data(patched.utf8).write(to: sourceURL)
        let selected = Set(
            shell.archive.functions.compactMap { record -> Core.FunctionKey? in
                guard record.patchability.isEligible,
                    [Core.FunctionRole.willSet, .didSet].contains(record.role),
                    ["ExecutionBox", "SelfReadBox", "PartialBox", "ReferenceBox"]
                        .contains(where: {
                            record.canonicalDeclaration.hasPrefix("\($0).value.")
                        })
                else { return nil }
                return record.key
            }
        )
        #expect(selected.count == 7)
        let patch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [modelsURL, sourceURL],
                selectedFunctionKeys: selected,
                compilerURL: compilerURL,
                enforceToolchainFingerprint: false
            )
        )
        #expect(patch.changedFunctions.count == 6)
        #expect(!patch.module.imports.isEmpty)
        _ = try Verification.Engine().verify(
            bytes: patch.bytecode,
            shell: .init(archive: shell.archive),
            policy: .init(
                acceptedCapabilities: Set(shell.archive.capabilities),
                allowedNativeImports: Set(shell.archive.nativeImports.compactMap(\.id))
            )
        )
        let executionSelected = Set(
            shell.archive.functions.compactMap { record -> Core.FunctionKey? in
                guard record.patchability.isEligible,
                    [Core.FunctionRole.willSet, .didSet].contains(record.role),
                    ["ExecutionBox", "SelfReadBox", "PartialBox"].contains(where: {
                        record.canonicalDeclaration.hasPrefix("\($0).value.")
                    })
                else { return nil }
                return record.key
            }
        )
        #expect(executionSelected.count == 5)
        let executionPatch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [modelsURL, sourceURL],
                selectedFunctionKeys: executionSelected,
                compilerURL: compilerURL,
                enforceToolchainFingerprint: false
            )
        )
        #expect(executionPatch.changedFunctions.count == 4)
        #expect(executionPatch.module.imports.isEmpty)
        let image = try Verification.Engine().verify(
            bytes: executionPatch.bytecode,
            shell: .init(archive: shell.archive),
            policy: .init(acceptedCapabilities: Set(shell.archive.capabilities))
        )

        func integer(_ value: Int64) throws -> VM.Value {
            .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
        }
        let nestedKey = try #require(
            shell.archive.frozenValueTypes.first {
                $0.canonicalName.hasSuffix(".NestedValue")
            }?.key
        )
        let nested = VM.Value.structure(
            type: nestedKey,
            fields: [try integer(7)]
        )
        let box = VM.Value.structure(
            type: .init(rawValue: "ExecutionBox"),
            fields: [try integer(0), try integer(1), nested]
        )
        func entry(
            _ owner: String,
            _ role: Core.FunctionRole
        ) throws -> Core.EntryIndex {
            try #require(
                shell.archive.functions.first {
                    $0.role == role
                        && $0.canonicalDeclaration.hasPrefix("\(owner).value.")
                }?.entryIndex
            )
        }
        let willSet = VM.Interpreter().invokeEntry(
            entry: try entry("ExecutionBox", .willSet),
            image: image,
            arguments: [try integer(2), box]
        )
        #expect(willSet.outcome == .returned(nil))
        #expect(willSet.writebacks == [
            .init(
                parameterIndex: 1,
                value: .structure(
                    type: .init(rawValue: "ExecutionBox"),
                    fields: [try integer(12), try integer(1), nested]
                )
            )
        ])
        let didSet = VM.Interpreter().invokeEntry(
            entry: try entry("ExecutionBox", .didSet),
            image: image,
            arguments: [try integer(1), box]
        )
        #expect(didSet.outcome == .returned(nil))
        #expect(didSet.writebacks == [
            .init(
                parameterIndex: 1,
                value: .structure(
                    type: .init(rawValue: "ExecutionBox"),
                    fields: [try integer(21), try integer(1), nested]
                )
            )
        ])

        let selfRead = VM.Interpreter().invokeEntry(
            entry: try entry("SelfReadBox", .didSet),
            image: image,
            arguments: [
                .structure(
                    type: .init(rawValue: "SelfReadBox"),
                    fields: [try integer(0), try integer(2)]
                )
            ]
        )
        #expect(selfRead.outcome == .returned(nil))
        #expect(selfRead.writebacks == [
            .init(
                parameterIndex: 0,
                value: .structure(
                    type: .init(rawValue: "SelfReadBox"),
                    fields: [try integer(32), try integer(2)]
                )
            )
        ])

        let partial = VM.Interpreter().invokeEntry(
            entry: try entry("PartialBox", .didSet),
            image: image,
            arguments: [
                .structure(
                    type: .init(rawValue: "PartialBox"),
                    fields: [try integer(0), try integer(-1)]
                )
            ]
        )
        #expect(partial.outcome == .returned(nil))
        #expect(partial.writebacks == [
            .init(
                parameterIndex: 0,
                value: .structure(
                    type: .init(rawValue: "PartialBox"),
                    fields: [try integer(0), try integer(42)]
                )
            )
        ])

        let selfAssigningReferencePatch = patched.replacingOccurrences(
            of: "changes += previous + 70",
            with: "changes += previous + 70; value = 42"
        )
        try Data(selfAssigningReferencePatch.utf8).write(to: sourceURL)
        let referenceDidSet = try #require(
            shell.archive.functions.first {
                $0.role == .didSet
                    && $0.canonicalDeclaration.hasPrefix("ReferenceBox.value.")
            }?.key
        )
        do {
            _ = try ReleaseCompiler.Driver().build(
                .init(
                    archive: shell.archive,
                    sourceFiles: [modelsURL, sourceURL],
                    selectedFunctionKeys: [referenceDidSet],
                    compilerURL: compilerURL,
                    enforceToolchainFingerprint: false
                )
            )
            Issue.record("reference observer self-assignment unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(String(describing: error).contains("lexical storage semantics"))
        }

        let changedObserverABIPatch = patched.replacingOccurrences(
            of: "changes += value + 30",
            with: "changes += oldValue + 30"
        )
        try Data(changedObserverABIPatch.utf8).write(to: sourceURL)
        let selfReadDidSet = try entry("SelfReadBox", .didSet)
        let selfReadKey = try #require(
            shell.archive.functions.first { $0.entryIndex == selfReadDidSet }?.key
        )
        do {
            _ = try ReleaseCompiler.Driver().build(
                .init(
                    archive: shell.archive,
                    sourceFiles: [modelsURL, sourceURL],
                    selectedFunctionKeys: [selfReadKey],
                    compilerURL: compilerURL,
                    enforceToolchainFingerprint: false
                )
            )
            Issue.record("observer old-value ABI change unexpectedly compiled")
        } catch let error as ReleaseCompiler.DriverError {
            #expect(String(describing: error).contains("signature"))
        }
    }
}
