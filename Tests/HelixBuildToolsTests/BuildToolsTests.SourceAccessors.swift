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
    @Test("Accessor source lexing ignores declaration-shaped trivia")
    func lexesAccessorDeclarationSourceFailClosed() throws {
        let source = #"""
            static /* class /* subscript */ */ #"subscript"# `class`
            // static class subscript
            subscript
            """#
        let data = Data(source.utf8)
        let words = try #require(
            FrontendReceipt.Adapter().accessorSourceWords(
                matching: ["class", "static", "subscript"],
                in: data.indices,
                contents: data
            ))
        #expect(words.map(\.value) == ["static", "subscript"])

        let trivia = Data(" /* outer /* inner */ */ // line\n (".utf8)
        #expect(
            FrontendReceipt.Adapter().sourceTriviaEnd(
                from: 0,
                through: trivia.count,
                contents: trivia
            ) == trivia.count - 1)

        let interpolation = Data("\"\\(value)\" static".utf8)
        #expect(
            FrontendReceipt.Adapter().accessorSourceWords(
                matching: ["static"],
                in: interpolation.indices,
                contents: interpolation
            )?.map(\.value) == ["static"])
        let nestedInterpolation = Data(##""\#(render("\(value)"))" class"##.utf8)
        #expect(
            FrontendReceipt.Adapter().accessorSourceWords(
                matching: ["class"],
                in: nestedInterpolation.indices,
                contents: nestedInterpolation
            )?.map(\.value) == ["class"])
        let unsupportedInterpolation = Data("\"\\(value / 2)\" static".utf8)
        #expect(
            FrontendReceipt.Adapter().accessorSourceWords(
                matching: ["static"],
                in: unsupportedInterpolation.indices,
                contents: unsupportedInterpolation
            ) == nil)
        let unterminatedInterpolation = Data("\"\\(value\" static".utf8)
        #expect(
            FrontendReceipt.Adapter().accessorSourceWords(
                matching: ["static"],
                in: unterminatedInterpolation.indices,
                contents: unterminatedInterpolation
            ) == nil)
        let unterminatedComment = Data("static /* class".utf8)
        #expect(
            FrontendReceipt.Adapter().accessorSourceWords(
                matching: ["class", "static"],
                in: unterminatedComment.indices,
                contents: unterminatedComment
            ) == nil)
        let oversizedRawDelimiter = Data(
            (String(repeating: "#", count: 65) + "\"static\""
                + String(repeating: "#", count: 65)).utf8
        )
        #expect(
            FrontendReceipt.Adapter().accessorSourceWords(
                matching: ["static"],
                in: oversizedRawDelimiter.indices,
                contents: oversizedRawDelimiter
            ) == nil)

        let attributedParameter: FrontendReceipt.TypedAST.Object = [
            "params": [
                "params": [
                    [
                        "name": ["base_name": ["name": "value"]],
                        "interface_type": "$sSiD",
                        "attrs": [["_kind": "autoclosure_attr"]],
                    ] as FrontendReceipt.TypedAST.Object
                ]
            ] as FrontendReceipt.TypedAST.Object
        ]
        #expect(
            try FrontendReceipt.Adapter().sourceAccessorParameters(
                attributedParameter,
                demangled: ["$sSiD": "Swift.Int"],
                importedSwiftTypeAliases: [:]
            ) == nil)
    }

    @Test("Existing computed properties and subscripts reload through exact accessor roots")
    func reloadsExistingComputedAccessors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-source-accessors-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = sourceDirectory.appendingPathComponent("Accessors.swift")
        let baseline = """
            public enum AccessorFailure: Error {
                case rejected
            }

            public var globalScore: Int {
                get { 13 }
                set(`in`) { _ = `in` }
            }

            public struct AccessorBox {
                public var raw: Int

                public var adjusted: Int {
                    get { raw + 1 }
                    set { raw = newValue - 1 }
                }

                public var doubled: Int { raw * 2 }

                public var advanced: Int {
                    mutating get {
                        raw += 1
                        return raw
                    }
                }

                public var checked: Int {
                    mutating get throws {
                        raw += 1
                        if raw < 0 { throw AccessorFailure.rejected }
                        return raw
                    }
                }

                public var accepted: Int {
                    get { 3 }
                    nonmutating set { _ = newValue }
                }

                public private(set) var guarded: Int {
                    get { raw + 5 }
                    set { raw = newValue - 5 }
                }

                public var /* declaration trivia */ `default`: Int {
                    get { raw + 4 }
                    set(custom) { raw = custom - 4 }
                }

                public var asynchronous: Int {
                    get async { raw }
                }

                public var typedFailure: Int {
                    get throws(AccessorFailure) { throw .rejected }
                }

                public var streamed: Int {
                    _read { yield raw }
                }

                public var explicitlyModified: Int {
                    get { raw }
                    _modify { yield &raw }
                }

                @available(iOS 99, *)
                public var future: Int { raw }

                public subscript(offset index: Int) -> Int {
                    get { raw + index }
                    set { raw = newValue - index }
                }

                public subscript(`repeat` value: Int, _ other: Int) -> Int {
                    raw + value + other
                }

                public subscript(_: Bool) -> Int { 42 }

                public subscript<Element>(generic value: Element) -> Element { value }

                public static var magic: Int {
                    get { 7 }
                    set(magicValue) { _ = magicValue }
                }

                public static /* subscript(decoy:) */ subscript(seed value: Int) -> Int {
                    get {
                        _ = "\\(value / 2)"
                        return value + 6
                    }
                    set { _ = newValue + value }
                }
            }

            public class ReferenceBox {
                private var storage: Int

                public init(_ storage: Int) {
                    self.storage = storage
                    _ = "\\(storage)"
                }

                public var value: Int {
                    get { storage }
                    set { storage = newValue }
                }

                public /* static decoy */ class
                var shared: Int { 11 }

                public /* class decoy */ static
                var fixed: Int { 21 }

                @available(iOS 99, *)
                public var unavailableReferenceValue: Int { storage }

                @available(iOS 99, *)
                public static var unavailableReferenceStaticValue: Int { 31 }
            }

            @available(iOS 99, *)
            public struct FutureBox {
                public var futureBoxValue: Int { 1 }
            }

            public struct GenericAccessorBox<Element> {
                public var genericValue: Element { fatalError() }
            }

            public final class GenericReferenceAccessorBox<Element> {
                public static var genericReferenceStaticValue: Int { 1 }
            }

            public struct PrivateAccessorContainer {
                private struct Hidden {
                    var hiddenValue: Int { 1 }
                }

                private final class HiddenReference {
                    static var hiddenReferenceStaticValue: Int { 1 }
                }
            }

            extension AccessorBox {
                public var fromExtension: Int { raw + 9 }
            }

            @available(iOS 99, *)
            extension AccessorBox {
                public var extensionFuture: Int { raw }
            }

            extension String {
                public var helixWordCount: Int { count + 1 }
            }
            """
        let baselineData = Data(baseline.utf8)
        try baselineData.write(to: sourceURL)

        let compilerURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        let frontend = SwiftFrontend.Driver(compilerURL: compilerURL)
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let moduleName = "FrontendAccessorFixture"
        let target = "arm64-apple-ios15.0-simulator"
        let configuration = try PatchConfiguration.Document.parse(
            yaml: """
                schema: 1
                modules:
                  \(moduleName):
                    include:
                      - Sources/**/*.swift
                """)
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.source-accessors",
            buildNumber: "1",
            shellNamespaceID: .derive(
                bundleID: "dev.helix.source-accessors",
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
                    .init(logicalPath: "Sources/Accessors.swift", url: sourceURL)
                ],
                compilerURL: compilerURL
            )
        )
        let receipt = output.receipt
        #expect(receipt.schemaVersion == 1)
        #expect(receipt.declarations.count == 28)
        #expect(receipt.roots.count == 26)
        #expect(receipt.roots.compactMap(\.bridge).count == 25)
        #expect(receipt.roots.compactMap(\.nativeReplacement).count == 26)
        #expect(Set(receipt.roots.map(\.sourceDeclaration.identity)).count == 18)
        #expect(receipt.frozenValueTypes.map(\.key.rawValue) == ["AccessorBox"])
        #expect(
            receipt.nativeTypes.contains {
                $0.canonicalName == "\(moduleName).ReferenceBox"
            })
        let importedExtension = try #require(
            receipt.roots.first {
                $0.sourceDeclaration.originalReference == "helixWordCount"
            })
        #expect(importedExtension.bridge == nil)
        #expect(importedExtension.nominalType == nil)
        let importedExtensionDeclaration = try #require(
            receipt.declarations.first {
                $0.mangledName == importedExtension.declarationMangledName
            })
        #expect(importedExtensionDeclaration.forcedPatchability?.reasonCode == "HLXIDX020")
        let asynchronous = try #require(
            receipt.declarations.first {
                $0.interface.baseName == "asynchronous"
            }
        )
        #expect(asynchronous.effects.isAsync)
        #expect(asynchronous.forcedPatchability?.reasonCode == "HLXIDX005")
        #expect(
            !receipt.roots.contains {
                $0.declarationMangledName == asynchronous.mangledName
            }
        )
        let unsupportedNames: Set<String> = [
            "typedFailure", "streamed", "explicitlyModified", "future",
            "futureBoxValue", "extensionFuture", "genericValue",
            "genericReferenceStaticValue", "hiddenValue",
            "hiddenReferenceStaticValue", "unavailableReferenceValue",
            "unavailableReferenceStaticValue",
        ]
        #expect(
            receipt.declarations.allSatisfy {
                !unsupportedNames.contains($0.interface.baseName)
            })

        let adjustedRoots = receipt.roots.filter {
            $0.sourceDeclaration.originalReference == "adjusted"
        }
        #expect(adjustedRoots.count == 2)
        #expect(Set(adjustedRoots.map(\.memberRole)) == [.getter, .setter])
        #expect(Set(adjustedRoots.map(\.declarationUTF8Offset)).count == 1)
        #expect(
            Set(
                adjustedRoots.compactMap {
                    $0.nativeReplacement?.declarationAnchorUTF8Offset
                }
            ).count == 2)
        let subscriptRoots = receipt.roots.filter {
            $0.sourceDeclaration.kind == .subscriptDeclaration
        }
        #expect(subscriptRoots.count == 6)
        let offsetSubscriptRoots = subscriptRoots.filter {
            $0.sourceDeclaration.originalReference == "subscript(offset:)"
        }
        #expect(offsetSubscriptRoots.count == 2)
        #expect(
            offsetSubscriptRoots.allSatisfy {
                $0.sourceDeclaration.originalReference == "subscript(offset:)"
                    && $0.sourceDeclaration.replacementHeader.contains("helixReload_")
            })
        let escapedPropertyRoots = receipt.roots.filter {
            $0.sourceDeclaration.originalReference == "`default`"
        }
        #expect(escapedPropertyRoots.count == 2)
        #expect(
            escapedPropertyRoots.first?.expectedDeclarationPrefix
                == "var /* declaration trivia */ `default`")
        #expect(
            escapedPropertyRoots.first?.sourceDeclaration.member(.setter)?.header
                == "set(custom)")
        #expect(
            receipt.roots.contains {
                $0.sourceDeclaration.originalReference == "subscript(repeat:_:)"
            })
        #expect(
            !receipt.roots.contains {
                $0.sourceDeclaration.originalReference == "subscript(generic:)"
            })
        #expect(
            receipt.roots.first {
                $0.sourceDeclaration.originalReference == "advanced"
            }?.sourceDeclaration.member(.getter)?.header == "mutating get")
        #expect(
            receipt.roots.filter {
                $0.sourceDeclaration.originalReference == "globalScore"
            }.count == 2)
        #expect(
            receipt.roots.filter {
                $0.sourceDeclaration.originalReference == "magic"
            }.count == 2)
        let acceptedSetter = try #require(
            receipt.roots.first {
                $0.sourceDeclaration.originalReference == "accepted"
                    && $0.memberRole == .setter
            })
        #expect(acceptedSetter.sourceDeclaration.member(.setter)?.header == "nonmutating set")
        let acceptedSetterDeclaration = try #require(
            receipt.declarations.first {
                $0.mangledName == acceptedSetter.declarationMangledName
            })
        #expect(!acceptedSetterDeclaration.parameterConventions.contains(.inout))
        let guardedDeclarations = receipt.declarations.filter {
            $0.interface.baseName == "guarded"
        }
        #expect(guardedDeclarations.count == 2)
        #expect(Set(guardedDeclarations.map(\.interface.accessLevel)) == ["public", "private"])
        let guardedRoots = receipt.roots.filter {
            $0.sourceDeclaration.originalReference == "guarded"
        }
        #expect(guardedRoots.count == 1)
        #expect(guardedRoots.first?.memberRole == .getter)
        #expect(guardedRoots.first?.sourceDeclaration.member(.setter) != nil)

        let shell = try ShellBuild.Materializer().materialize(
            receipt: receipt,
            sourceRoot: directory
        )
        let transformed = String(
            decoding: try #require(shell.transformedSources["Sources/Accessors.swift"]),
            as: UTF8.self
        )
        #expect(transformed.contains("public dynamic var adjusted"))
        #expect(transformed.contains("public dynamic var globalScore"))
        #expect(transformed.contains("public dynamic var doubled"))
        #expect(transformed.contains("public dynamic var advanced"))
        #expect(transformed.contains("public dynamic var checked"))
        #expect(transformed.contains("public dynamic var accepted"))
        #expect(transformed.contains("public private(set) dynamic var guarded"))
        #expect(
            transformed.contains(
                "public dynamic var /* declaration trivia */ `default`"
            ))
        #expect(transformed.contains("public dynamic subscript(offset index: Int)"))
        #expect(transformed.contains("public static dynamic var magic"))
        #expect(
            transformed.contains(
                "public static /* subscript(decoy:) */ dynamic subscript(seed value: Int)"
            ))
        #expect(transformed.contains("public dynamic var value"))
        #expect(transformed.contains("public /* static decoy */ class\n    dynamic var shared"))
        #expect(transformed.contains("public /* class decoy */ static\n    dynamic var fixed"))
        #expect(transformed.contains("public dynamic var fromExtension"))
        #expect(transformed.contains("public dynamic var helixWordCount"))
        for name in unsupportedNames {
            #expect(!transformed.contains("dynamic var \(name)"))
        }
        #expect(transformed.components(separatedBy: "dynamic var adjusted").count == 2)
        #expect(transformed.components(separatedBy: "dynamic subscript").count == 5)

        try typeCheckNativeReplacements(
            receipt: receipt,
            shell: shell,
            originalSource: baselineData,
            directory: directory,
            compilerURL: compilerURL,
            sdkPath: sdk.path,
            target: target,
            moduleName: moduleName,
            logicalPath: "Sources/Accessors.swift"
        )
        try typeCheckGeneratedBridge(
            shell: shell,
            directory: directory,
            moduleName: moduleName
        )

        let patched =
            baseline
            .replacingOccurrences(of: "raw + 1", with: "raw + 10")
            .replacingOccurrences(of: "get { 13 }", with: "get { 14 }")
            .replacingOccurrences(
                of: "set(`in`) { _ = `in` }",
                with: "set(`in`) { _ = `in` + 1 }"
            )
            .replacingOccurrences(of: "newValue - 1", with: "newValue - 10")
            .replacingOccurrences(of: "raw * 2", with: "raw * 3")
            .replacingOccurrences(of: "raw += 1", with: "raw += 10")
            .replacingOccurrences(of: "get { 3 }", with: "get { 4 }")
            .replacingOccurrences(
                of: "nonmutating set { _ = newValue }",
                with: "nonmutating set { _ = newValue + 1 }"
            )
            .replacingOccurrences(of: "raw + 5", with: "raw + 50")
            .replacingOccurrences(of: "newValue - 5", with: "newValue - 50")
            .replacingOccurrences(of: "raw + 4", with: "raw + 40")
            .replacingOccurrences(of: "custom - 4", with: "custom - 40")
            .replacingOccurrences(of: "raw + index", with: "raw + index + 20")
            .replacingOccurrences(
                of: "raw = newValue - index",
                with: "raw = newValue - index - 20"
            )
            .replacingOccurrences(
                of: "raw + value + other",
                with: "raw + value + other + 30"
            )
            .replacingOccurrences(of: "(_: Bool) -> Int { 42 }", with: "(_: Bool) -> Int { 43 }")
            .replacingOccurrences(of: "get { 7 }", with: "get { 8 }")
            .replacingOccurrences(
                of: "set(magicValue) { _ = magicValue }",
                with: "set(magicValue) { _ = magicValue + 1 }"
            )
            .replacingOccurrences(of: "value + 6", with: "value + 60")
            .replacingOccurrences(
                of: "set { _ = newValue + value }",
                with: "set { _ = newValue + value + 1 }"
            )
            .replacingOccurrences(of: "shared: Int { 11 }", with: "shared: Int { 12 }")
            .replacingOccurrences(of: "fixed: Int { 21 }", with: "fixed: Int { 22 }")
            .replacingOccurrences(of: "raw + 9", with: "raw + 90")
            .replacingOccurrences(of: "count + 1", with: "count + 10")
        #expect(patched != baseline)
        try Data(patched.utf8).write(to: sourceURL)
        let selected = Set(
            shell.archive.functions.compactMap { record -> Core.FunctionKey? in
                guard record.patchability.isEligible,
                    let declaration = receipt.declarations.first(where: {
                        $0.mangledName == record.mangledName
                    }), declaration.interface.baseName != "value"
                else { return nil }
                return record.key
            })
        #expect(selected.count == 23)
        let patch = try ReleaseCompiler.Driver().build(
            .init(
                archive: shell.archive,
                sourceFiles: [sourceURL],
                selectedFunctionKeys: selected,
                compilerURL: compilerURL,
                enforceToolchainFingerprint: false
            )
        )
        #expect(patch.changedFunctions.count == 23)
        let image = try Verification.Engine().verify(
            bytes: patch.bytecode,
            shell: .init(archive: shell.archive),
            policy: .init(acceptedCapabilities: Set(shell.archive.capabilities))
        )

        func integer(_ value: Int64) throws -> VM.Value {
            .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
        }
        func entry(
            named name: String,
            role: Core.FunctionRole,
            labels: [String]? = nil
        ) throws -> Core.EntryIndex {
            let declaration = try #require(
                receipt.declarations.first {
                    $0.interface.baseName == name && $0.role == role
                        && (labels == nil || $0.interface.argumentLabels == labels)
                })
            return try #require(
                shell.archive.functions.first {
                    $0.mangledName == declaration.mangledName
                }?.entryIndex)
        }
        let box = VM.Value.structure(
            type: .init(rawValue: "AccessorBox"),
            fields: [try integer(5)]
        )

        let adjusted = VM.Interpreter().invokeEntry(
            entry: try entry(named: "adjusted", role: .getter),
            image: image,
            arguments: [box]
        )
        #expect(adjusted.outcome == .returned(try integer(15)))
        #expect(adjusted.writebacks.isEmpty)

        let adjustedSet = VM.Interpreter().invokeEntry(
            entry: try entry(named: "adjusted", role: .setter),
            image: image,
            arguments: [try integer(30), box]
        )
        #expect(adjustedSet.outcome == .returned(nil))
        #expect(
            adjustedSet.writebacks == [
                .init(
                    parameterIndex: 1,
                    value: .structure(
                        type: .init(rawValue: "AccessorBox"),
                        fields: [try integer(20)]
                    )
                )
            ])

        let subscriptGet = VM.Interpreter().invokeEntry(
            entry: try entry(named: "subscript", role: .getter, labels: ["offset"]),
            image: image,
            arguments: [try integer(2), box]
        )
        #expect(subscriptGet.outcome == .returned(try integer(27)))

        let subscriptSet = VM.Interpreter().invokeEntry(
            entry: try entry(
                named: "subscript",
                role: .setter,
                labels: ["_", "offset"]
            ),
            image: image,
            arguments: [try integer(40), try integer(2), box]
        )
        #expect(subscriptSet.outcome == .returned(nil))
        #expect(
            subscriptSet.writebacks == [
                .init(
                    parameterIndex: 2,
                    value: .structure(
                        type: .init(rawValue: "AccessorBox"),
                        fields: [try integer(18)]
                    )
                )
            ])

        let advanced = VM.Interpreter().invokeEntry(
            entry: try entry(named: "advanced", role: .getter),
            image: image,
            arguments: [box]
        )
        #expect(advanced.outcome == .returned(try integer(15)))
        #expect(
            advanced.writebacks == [
                .init(
                    parameterIndex: 0,
                    value: .structure(
                        type: .init(rawValue: "AccessorBox"),
                        fields: [try integer(15)]
                    )
                )
            ])

        let accepted = VM.Interpreter().invokeEntry(
            entry: try entry(named: "accepted", role: .setter),
            image: image,
            arguments: [try integer(7), box]
        )
        #expect(accepted.outcome == .returned(nil))
        #expect(accepted.writebacks.isEmpty)
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "guarded", role: .getter),
                image: image,
                arguments: [box]
            ).outcome == .returned(try integer(55)))

        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "default", role: .getter),
                image: image,
                arguments: [box]
            ).outcome == .returned(try integer(45)))
        let escapedSet = VM.Interpreter().invokeEntry(
            entry: try entry(named: "default", role: .setter),
            image: image,
            arguments: [try integer(50), box]
        )
        #expect(escapedSet.outcome == .returned(nil))
        #expect(
            escapedSet.writebacks == [
                .init(
                    parameterIndex: 1,
                    value: .structure(
                        type: .init(rawValue: "AccessorBox"),
                        fields: [try integer(10)]
                    )
                )
            ])
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(
                    named: "subscript",
                    role: .getter,
                    labels: ["repeat", "_"]
                ),
                image: image,
                arguments: [try integer(2), try integer(3), box]
            ).outcome == .returned(try integer(40)))
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "subscript", role: .getter, labels: ["_"]),
                image: image,
                arguments: [.bool(true), box]
            ).outcome == .returned(try integer(43)))

        let checked = VM.Interpreter().invokeEntry(
            entry: try entry(named: "checked", role: .getter),
            image: image,
            arguments: [box]
        )
        #expect(checked.outcome == .returned(try integer(15)))
        #expect(
            checked.writebacks == [
                .init(
                    parameterIndex: 0,
                    value: .structure(
                        type: .init(rawValue: "AccessorBox"),
                        fields: [try integer(15)]
                    )
                )
            ])

        let negativeBox = VM.Value.structure(
            type: .init(rawValue: "AccessorBox"),
            fields: [try integer(-20)]
        )
        let rejected = VM.Interpreter().invokeEntry(
            entry: try entry(named: "checked", role: .getter),
            image: image,
            arguments: [negativeBox]
        )
        #expect(rejected.outcome == .businessError("AccessorFailure.rejected"))
        #expect(
            rejected.writebacks == [
                .init(
                    parameterIndex: 0,
                    value: .structure(
                        type: .init(rawValue: "AccessorBox"),
                        fields: [try integer(-10)]
                    )
                )
            ])

        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "doubled", role: .getter),
                image: image,
                arguments: [box]
            ).outcome == .returned(try integer(15)))
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "magic", role: .getter),
                image: image,
                arguments: []
            ).outcome == .returned(try integer(8)))
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "magic", role: .setter),
                image: image,
                arguments: [try integer(1)]
            ).outcome == .returned(nil))
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "globalScore", role: .getter),
                image: image,
                arguments: []
            ).outcome == .returned(try integer(14)))
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "globalScore", role: .setter),
                image: image,
                arguments: [try integer(1)]
            ).outcome == .returned(nil))
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "shared", role: .getter),
                image: image,
                arguments: []
            ).outcome == .returned(try integer(12)))
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "fixed", role: .getter),
                image: image,
                arguments: []
            ).outcome == .returned(try integer(22)))
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "subscript", role: .getter, labels: ["seed"]),
                image: image,
                arguments: [try integer(2)]
            ).outcome == .returned(try integer(62)))
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(
                    named: "subscript",
                    role: .setter,
                    labels: ["_", "seed"]
                ),
                image: image,
                arguments: [try integer(5), try integer(2)]
            ).outcome == .returned(nil))
        #expect(
            VM.Interpreter().invokeEntry(
                entry: try entry(named: "fromExtension", role: .getter),
                image: image,
                arguments: [box]
            ).outcome == .returned(try integer(95)))
    }
}
