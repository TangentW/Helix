import Foundation
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Objective-C ABI classification")
struct ObjectiveCABI {
    @Test("Clang USRs preserve exact method and property runtime identities")
    func parsesClangIdentities() {
        #expect(
            FrontendReceipt.ObjectiveCABI.methodIdentity(
                usr: "c:objc(cs)NSFileManager(im)removeItemAtURL:error:"
            ) == .init(
                runtimeClassName: "NSFileManager",
                selector: "removeItemAtURL:error:",
                isClassMethod: false
            )
        )
        #expect(
            FrontendReceipt.ObjectiveCABI.methodIdentity(
                usr: "c:objc(cs)UIView(cm)setAnimationsEnabled:"
            )?.isClassMethod == true
        )
        #expect(
            FrontendReceipt.ObjectiveCABI.propertyIdentity(
                usr: "c:objc(cs)NSOperationQueue(py)suspended"
            ) == .init(
                runtimeClassName: "NSOperationQueue",
                name: "suspended",
                isClassProperty: false
            )
        )
        #expect(
            FrontendReceipt.ObjectiveCABI.defaultPropertySelector(
                name: "suspended",
                accessor: .getter,
                importedBaseName: "isSuspended"
            ) == "isSuspended"
        )
        #expect(
            FrontendReceipt.ObjectiveCABI.defaultPropertySelector(
                name: "suspended",
                accessor: .setter,
                importedBaseName: "isSuspended"
            ) == "setSuspended:"
        )
        #expect(
            FrontendReceipt.ObjectiveCABI.propertySelectorProbeSeed(
                name: "payload",
                accessor: .getter,
                importedBaseName: "currentPayload"
            ) == "payload"
        )
        #expect(FrontendReceipt.ObjectiveCABI.moduleName(
            ownerType: "UIKit.UIView",
            importedModules: ["Foundation", "UIKit"]
        ) == "UIKit")
        #expect(FrontendReceipt.ObjectiveCABI.moduleName(
            ownerType: "NSFileManager",
            importedModules: ["Foundation", "UIKit"]
        ) == nil)
        #expect(FrontendReceipt.ObjectiveCABI.moduleName(
            ownerType: "ThirdPartyWidget",
            importedModules: ["ThirdParty"]
        ) == nil)
        let selectorAST: FrontendReceipt.TypedAST.Object = [
            "_kind": "objc_selector_expr",
            "kind": "setter",
            "decl": [
                "decl_usr": "c:objc(cs)Widget(im)markEnabled:",
            ],
            "sub_expr": [
                "_kind": "member_ref_expr",
                "decl": [
                    "decl_usr": "c:objc(cs)Widget(py)enabled",
                ],
            ],
        ]
        #expect(FrontendReceipt.ObjectiveCABI.propertySelectors(
            in: selectorAST
        ) == [
            .init(
                declarationUSR: "c:objc(cs)Widget(py)enabled",
                accessor: .setter,
                selector: "markEnabled:"
            ),
        ])
        #expect(FrontendReceipt.ObjectiveCABI.methodFamily(
            selector: "copyItemAtPath:toPath:error:",
            dispatch: .instance,
            resultSwiftABIType: "ObjCBool"
        ) == .none)
        #expect(FrontendReceipt.ObjectiveCABI.methodFamily(
            selector: "copyObject",
            dispatch: .instance,
            resultSwiftABIType: "@owned NSObject"
        ) == .copy)
        #expect(FrontendReceipt.ObjectiveCABI.methodFamily(
            selector: "copyObject",
            dispatch: .instance,
            resultSwiftABIType: "@autoreleased NSObject"
        ) == .none)
        #expect(FrontendReceipt.ObjectiveCABI.methodFamily(
            selector: "__copyObject",
            dispatch: .instance,
            resultSwiftABIType: "@owned NSObject"
        ) == .copy)
        #expect(FrontendReceipt.ObjectiveCABI.methodFamily(
            selector: "_allocObject",
            dispatch: .static,
            resultSwiftABIType: "@owned NSObject"
        ) == .alloc)
        #expect(FrontendReceipt.ObjectiveCABI.methodFamily(
            selector: "newObject",
            dispatch: .instance,
            resultSwiftABIType: "@owned NSObject"
        ) == .new)
        let objectType = Core.TypeID(rawValue: .sha256("NSObject"))
        var notRetainedFamily = makeEvidence(
            parameters: [],
            result: "@autoreleased NSObject"
        )
        notRetainedFamily.selector = "copyObject"
        notRetainedFamily.resultConvention = .autoreleased
        #expect(FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: notRetainedFamily,
            logicalParameterTypes: [],
            logicalResultType: .native(objectType),
            nativeTypeKinds: [objectType: .reference],
            targetTriple: "arm64-apple-ios15.0-simulator"
        ) == nil)
    }

    @Test("Compiler selector probes preserve custom Objective-C property accessors")
    func resolvesCustomPropertyAccessors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-objective-c-selector-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        #import <Foundation/Foundation.h>
        @interface HelixSelectorFixture : NSObject
        @property(nonatomic, assign, getter=isEnabled, setter=markEnabled:) BOOL enabled;
        @property(nonatomic, readonly, getter=copyPayload) NSObject *payload;
        @end
        """.utf8).write(to: directory.appendingPathComponent("Fixture.h"))
        try Data("""
        module HelixSelectorFixture {
          header "Fixture.h"
          export *
        }
        """.utf8).write(to: directory.appendingPathComponent("module.modulemap"))

        let frontend = SwiftFrontend.Driver(
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
        )
        let sdk = try frontend.sdkIdentity(name: "iphonesimulator")
        let property = Core.NativeCall.ObjectiveCProperty(
            name: "enabled",
            accessor: .setter
        )
        let operation = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: [],
            sourceFileLogicalID: "Sources/Fixture.swift",
            importedModules: ["HelixSelectorFixture"],
            dispatch: .instanceSetter,
            ownerType: "HelixSelectorFixture",
            baseName: "isEnabled",
            argumentLabels: ["_"],
            parameterSwiftTypes: ["Swift.Bool", "HelixSelectorFixture"],
            resultSwiftType: "Swift.Void",
            requiresMainActor: false,
            objectiveC: .init(
                moduleName: "HelixSelectorFixture",
                declarationUSR: "c:objc(cs)HelixSelectorFixture(py)enabled",
                runtimeClassName: "HelixSelectorFixture",
                selector: "setEnabled:",
                selectorIsExact: false,
                lexicalSuperclassName: nil,
                methodFamily: .none,
                property: property,
                parameters: [],
                resultSwiftABIType: "()",
                resultConvention: .direct,
                errorConvention: .none,
                errorFailure: nil
            )
        )
        let payload = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: [],
            sourceFileLogicalID: "Sources/Fixture.swift",
            importedModules: ["HelixSelectorFixture"],
            dispatch: .instanceGetter,
            ownerType: "HelixSelectorFixture",
            baseName: "payload",
            argumentLabels: [],
            parameterSwiftTypes: ["HelixSelectorFixture"],
            resultSwiftType: "Foundation.NSObject",
            requiresMainActor: false,
            objectiveC: .init(
                moduleName: "HelixSelectorFixture",
                declarationUSR: "c:objc(cs)HelixSelectorFixture(py)payload",
                runtimeClassName: "HelixSelectorFixture",
                selector: "payload",
                selectorIsExact: false,
                lexicalSuperclassName: nil,
                methodFamily: .none,
                property: .init(name: "payload", accessor: .getter),
                parameters: [],
                resultSwiftABIType: "@owned NSObject",
                resultConvention: .directOwned,
                errorConvention: .none,
                errorFailure: nil
            )
        )
        let resolved = try FrontendReceipt.ObjectiveCSelectorResolver.resolve(
            operations: [operation, payload],
            frontend: frontend,
            invocation: .init(
                moduleName: "SelectorProbeHost",
                targetTriple: "arm64-apple-ios15.0-simulator",
                sdkName: sdk.name,
                sdkBuild: sdk.buildVersion,
                optimization: "-Onone",
                semanticArguments: [
                    "-parse-as-library", "-I", directory.path,
                ]
            )
        )
        #expect(resolved[0].objectiveC?.selector == "markEnabled:")
        #expect(resolved[0].objectiveC?.selectorIsExact == true)
        #expect(resolved[1].objectiveC?.selector == "copyPayload")
        #expect(resolved[1].objectiveC?.selectorIsExact == true)
        #expect(resolved[1].objectiveC?.methodFamily == .copy)
        #expect(resolved[1].objectiveC?.resultConvention == .directOwned)
    }

    @Test("Target ABI controls scalar encodings and rejects width mismatches")
    func classifiesTargetScalars() {
        let integer = signature(
            parameter: .init(
                swiftABIType: "Swift.Int",
                source: .argument(0)
            ),
            result: "Swift.Bool",
            logicalParameter: .int64,
            logicalResult: .bool,
            target: "arm64-apple-ios15.0-simulator"
        )
        #expect(integer?.parameters.first?.type.encoding == "q")
        #expect(integer?.result.encoding == "B")

        let armMac = signature(
            parameter: .init(
                swiftABIType: "Swift.Bool",
                source: .argument(0)
            ),
            result: "Swift.Bool",
            logicalParameter: .bool,
            logicalResult: .bool,
            target: "arm64-apple-macosx14.0"
        )
        #expect(armMac?.parameters.first?.type.encoding == "B")

        for target in [
            "x86_64-apple-macosx14.0",
            "x86_64-apple-ios15.0-macabi",
        ] {
            let intelMac = signature(
                parameter: .init(
                    swiftABIType: "Swift.Bool",
                    source: .argument(0)
                ),
                result: "Swift.Bool",
                logicalParameter: .bool,
                logicalResult: .bool,
                target: target
            )
            #expect(intelMac?.parameters.first?.type.encoding == "c")
        }

        #expect(signature(
            parameter: .init(
                swiftABIType: "Swift.Int32",
                source: .argument(0)
            ),
            result: "()",
            logicalParameter: .int64,
            logicalResult: .void
        ) == nil)
        #expect(signature(
            parameter: .init(
                swiftABIType: "Swift.Int",
                source: .argument(0)
            ),
            result: "()",
            logicalParameter: .int64,
            logicalResult: .void,
            target: "armv7-apple-ios12.0"
        ) == nil)
    }

    @Test("The common scalar and structure matrix preserves exact 64-bit ABI")
    func classifiesCommonABIMatrix() {
        let scalars: [(
            swiftABI: String,
            logical: Bytecode.ValueType,
            kind: Core.NativeCall.ABIValueKind,
            encoding: String,
            size: UInt16
        )] = [
            ("Swift.Int8", .integer(bitWidth: 8, signed: true), .signedInteger, "c", 1),
            ("Swift.UInt16", .integer(bitWidth: 16, signed: false), .unsignedInteger, "S", 2),
            ("Swift.Int32", .integer(bitWidth: 32, signed: true), .signedInteger, "i", 4),
            ("Swift.UInt", .integer(bitWidth: 64, signed: false), .unsignedInteger, "Q", 8),
            ("Swift.Float", .float(bitWidth: 32), .floatingPoint, "f", 4),
            ("Swift.Double", .float(bitWidth: 64), .floatingPoint, "d", 8),
        ]
        for scalar in scalars {
            let physical = signature(
                parameter: .init(
                    swiftABIType: scalar.swiftABI,
                    source: .argument(0)
                ),
                result: "()",
                logicalParameter: scalar.logical,
                logicalResult: .void
            )?.parameters.first?.type
            #expect(physical?.kind == scalar.kind)
            #expect(physical?.encoding == scalar.encoding)
            #expect(physical?.size == scalar.size)
            #expect(physical?.alignment == scalar.size)
        }

        let structures: [(
            name: String,
            size: UInt16,
            alignment: UInt16,
            encoding: String
        )] = [
            ("CGPoint", 16, 8, "{CGPoint=dd}"),
            ("CGSize", 16, 8, "{CGSize=dd}"),
            ("CGVector", 16, 8, "{CGVector=dd}"),
            ("CGRect", 32, 8, "{CGRect={CGPoint=dd}{CGSize=dd}}"),
            ("CGAffineTransform", 48, 8, "{CGAffineTransform=dddddd}"),
            ("UIEdgeInsets", 32, 8, "{UIEdgeInsets=dddd}"),
            ("NSDirectionalEdgeInsets", 32, 8, "{NSDirectionalEdgeInsets=dddd}"),
            ("UIOffset", 16, 8, "{UIOffset=dd}"),
            ("NSRange", 16, 8, "{_NSRange=QQ}"),
            ("_NSRange", 16, 8, "{_NSRange=QQ}"),
        ]
        for structure in structures {
            let physical = FrontendReceipt.ObjectiveCABI.structureType(
                swiftABIType: structure.name,
                targetTriple: "arm64-apple-ios15.0-simulator"
            )
            #expect(physical?.kind == .structure)
            #expect(physical?.size == structure.size)
            #expect(physical?.alignment == structure.alignment)
            #expect(physical?.encoding == structure.encoding)
        }
    }

    @Test("Objects, common structures, and reusable Blocks share generic shapes")
    func classifiesReusableShapes() {
        let view = Core.TypeID(rawValue: .sha256("UIView"))
        let point = Core.TypeID(rawValue: .sha256("CGPoint"))
        let callback = Bytecode.ValueType.closure(.init(
            parameters: [],
            parameterConventions: [],
            result: .void
        ))
        let evidence = makeEvidence(
            parameters: [
                .init(swiftABIType: "@guaranteed UIView", source: .argument(0)),
                .init(swiftABIType: "CGPoint", source: .argument(1)),
                .init(
                    swiftABIType: "@convention(block) @Sendable () -> ()",
                    source: .argument(2)
                ),
            ],
            result: "CGPoint"
        )
        let physical = FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: evidence,
            logicalParameterTypes: [.native(view), .native(point), callback],
            logicalResultType: .native(point),
            nativeTypeKinds: [view: .reference, point: .value],
            targetTriple: "arm64-apple-ios15.0-simulator"
        )
        #expect(physical?.parameters.map(\.type.kind) == [
            .object, .structure, .block,
        ])
        #expect(physical?.parameters[1].type.encoding == "{CGPoint=dd}")
        #expect(physical?.parameters[2].ownership == .owned)
        #expect(physical?.result.kind == .structure)

        let protocolObject = FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: makeEvidence(
                parameters: [
                    .init(
                        swiftABIType: "@guaranteed any UIInteraction",
                        source: .argument(0)
                    ),
                ],
                result: "()"
            ),
            logicalParameterTypes: [.native(view)],
            logicalResultType: .void,
            nativeTypeKinds: [view: .reference],
            targetTriple: "arm64-apple-ios15.0-simulator"
        )
        #expect(protocolObject?.parameters.first?.type.kind == .object)
        #expect(
            protocolObject?.parameters.first?.type.canonicalName
                == "any UIInteraction"
        )

        let optionalView = FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: makeEvidence(
                parameters: [
                    .init(
                        swiftABIType: "Optional<UIView>",
                        source: .argument(0)
                    ),
                ],
                result: "()"
            ),
            logicalParameterTypes: [.optional(.native(view))],
            logicalResultType: .void,
            nativeTypeKinds: [view: .reference],
            targetTriple: "arm64-apple-ios15.0-simulator"
        )
        #expect(optionalView?.parameters.first?.type.kind == .object)
        #expect(optionalView?.parameters.first?.type.isNullable == true)

        let genericObject = FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: makeEvidence(
                parameters: [
                    .init(
                        swiftABIType:
                            "@guaranteed __C.NSLayoutAnchor<τ_0_0>",
                        source: .argument(0)
                    ),
                ],
                result: "@autoreleased __C.NSArray<__C.NSString>"
            ),
            logicalParameterTypes: [.native(view)],
            logicalResultType: .native(view),
            nativeTypeKinds: [view: .reference],
            targetTriple: "arm64-apple-ios15.0-simulator"
        )
        #expect(
            genericObject?.parameters.first?.type.canonicalName
                == "NSLayoutAnchor"
        )
        #expect(genericObject?.result.canonicalName == "NSArray")

        let noescapeBlock = FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: makeEvidence(
                parameters: [
                    .init(
                        swiftABIType:
                            "@noescape @convention(block) @Sendable () -> ()",
                        source: .argument(0)
                    ),
                ],
                result: "()"
            ),
            logicalParameterTypes: [callback],
            logicalResultType: .void,
            nativeTypeKinds: [:],
            targetTriple: "arm64-apple-ios15.0-simulator"
        )
        #expect(noescapeBlock?.parameters.first?.type.kind == .block)
        #expect(noescapeBlock?.parameters.first?.ownership == .borrowed)

        let omittedOptionalBlock = FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: makeEvidence(
                parameters: [
                    .init(
                        swiftABIType:
                            "Optional<@convention(block) @Sendable () -> ()>",
                        source: .optionalNone
                    ),
                ],
                result: "()"
            ),
            logicalParameterTypes: [],
            logicalResultType: .void,
            nativeTypeKinds: [:],
            targetTriple: "arm64-apple-ios15.0-simulator"
        )
        #expect(omittedOptionalBlock?.parameters.first?.type.kind == .block)
        #expect(omittedOptionalBlock?.parameters.first?.type.isNullable == true)
        #expect(omittedOptionalBlock?.parameters.first?.source == .optionalNone)

        var returnedBlock = evidence
        returnedBlock.parameters = []
        returnedBlock.resultSwiftABIType = "@convention(block) @Sendable () -> ()"
        #expect(FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: returnedBlock,
            logicalParameterTypes: [],
            logicalResultType: callback,
            nativeTypeKinds: [:],
            targetTriple: "arm64-apple-ios15.0-simulator"
        ) == nil)
    }

    @Test("Exact declaration and initializer type evidence resolve modules")
    func appliesExactObjectiveCModuleProvenance() throws {
        var evidence = makeEvidence(parameters: [], result: "Swift.Void")
        evidence.moduleName = nil
        evidence.declarationUSR = "c:objc(cs)NSObject(im)init"
        evidence.runtimeClassName = "NSObject"
        evidence.dispatchClassName = "UIViewController"
        evidence.selector = "init"
        evidence.methodFamily = .initializer
        let operation = FrontendReceipt.Adapter.ImportedOperation(
            silReferences: ["$sObjectiveCModuleFixture"],
            sourceFileLogicalID: "Sources/Fixture.swift",
            importedModules: ["Foundation", "UIKit"],
            dispatch: .initializer,
            ownerType: "UIViewController",
            baseName: "init",
            argumentLabels: [],
            parameterSwiftTypes: [],
            resultSwiftType: "UIViewController",
            requiresMainActor: true,
            objectiveC: evidence
        )
        let exactType = FrontendReceipt.Adapter.ImportedNativeType(
            canonicalName: "UIViewController",
            swiftType: "UIViewController",
            kind: .reference,
            aliases: ["UIKit.UIViewController"],
            representation: .reference,
            sourceFileLogicalID: "Sources/Fixture.swift",
            importedModules: ["UIKit"],
            objectiveCModuleName: "UIKit",
            requiresMainActor: true
        )

        let refined = try FrontendReceipt.Adapter()
            .applyingObjectiveCInitializerTypeModules(
                to: [operation],
                importedTypes: [exactType]
            )
        #expect(refined.first?.objectiveC?.moduleName == "UIKit")

        var categoryOperation = operation
        categoryOperation.objectiveC?.methodFamily = .none
        categoryOperation.objectiveC?.declarationUSR =
            "c:objc(cs)UIViewController(im)categoryMethod"
        categoryOperation.objectiveC?.selector = "categoryMethod"
        let typeOnly = try FrontendReceipt.Adapter()
            .applyingObjectiveCInitializerTypeModules(
                to: [categoryOperation],
                importedTypes: [exactType]
            )
        #expect(typeOnly.first?.objectiveC?.moduleName == nil)
        let categoryRefined = FrontendReceipt.Adapter()
            .applyingObjectiveCDeclarationModules(
                to: typeOnly,
                modulesByUSR: [
                    "c:objc(cs)UIViewController(im)categoryMethod":
                        "CategoryFramework",
                ]
            )
        #expect(
            categoryRefined.first?.objectiveC?.moduleName
                == "CategoryFramework"
        )

        #expect(FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: evidence,
            logicalParameterTypes: [],
            logicalResultType: .void,
            nativeTypeKinds: [:],
            targetTriple: "arm64-apple-ios15.0-simulator"
        ) == nil)

        var conflictingType = exactType
        conflictingType.swiftType = "Foundation.UIViewController"
        conflictingType.objectiveCModuleName = "Foundation"
        #expect(throws: FrontendReceipt.Error.self) {
            _ = try FrontendReceipt.Adapter()
                .applyingObjectiveCInitializerTypeModules(
                to: [operation],
                importedTypes: [exactType, conflictingType]
            )
        }
    }

    @Test("NSError-out is explicit while Swift-only defaults fail closed")
    func classifiesNSErrorAndRejectsDefaults() {
        let evidence = makeEvidence(
            parameters: [
                .init(swiftABIType: "Swift.Bool", source: .argument(0)),
                .init(
                    swiftABIType:
                        "Optional<AutoreleasingUnsafeMutablePointer<Optional<NSError>>>",
                    source: .errorOut
                ),
            ],
            result: "ObjCBool",
            errorConvention: .nsErrorOut,
            errorFailure: .falseBoolean
        )
        let physical = FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: evidence,
            logicalParameterTypes: [.bool],
            logicalResultType: .void,
            nativeTypeKinds: [:],
            targetTriple: "arm64-apple-ios15.0-simulator"
        )
        #expect(physical?.parameters.last?.source == .errorOut)
        #expect(physical?.parameters.last?.type.encoding == "^@")
        #expect(physical?.result.kind == .boolean)

        var unsupported = evidence
        unsupported.parameters[0].source = .defaultGenerator("$sFixtureDefault")
        #expect(FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: unsupported,
            logicalParameterTypes: [.bool],
            logicalResultType: .void,
            nativeTypeKinds: [:],
            targetTriple: "arm64-apple-ios15.0-simulator"
        ) == nil)
    }

    private func signature(
        parameter: FrontendReceipt.ObjectiveCABI.Parameter,
        result: String,
        logicalParameter: Bytecode.ValueType,
        logicalResult: Bytecode.ValueType,
        target: String = "arm64-apple-ios15.0-simulator"
    ) -> Core.NativeCall.PhysicalSignature? {
        FrontendReceipt.ObjectiveCABI.physicalSignature(
            evidence: makeEvidence(parameters: [parameter], result: result),
            logicalParameterTypes: [logicalParameter],
            logicalResultType: logicalResult,
            nativeTypeKinds: [:],
            targetTriple: target
        )
    }

    private func makeEvidence(
        parameters: [FrontendReceipt.ObjectiveCABI.Parameter],
        result: String,
        errorConvention: Core.NativeCall.ErrorConvention = .none,
        errorFailure: Core.NativeCall.ObjectiveCErrorFailure? = nil
    ) -> FrontendReceipt.ObjectiveCABI.Evidence {
        .init(
            moduleName: "UIKit",
            declarationUSR: "c:objc(cs)UIView(im)perform:",
            runtimeClassName: "UIView",
            selector: "perform:",
            lexicalSuperclassName: nil,
            methodFamily: .none,
            property: nil,
            parameters: parameters,
            resultSwiftABIType: result,
            resultConvention: .direct,
            errorConvention: errorConvention,
            errorFailure: errorFailure
        )
    }
}
}
