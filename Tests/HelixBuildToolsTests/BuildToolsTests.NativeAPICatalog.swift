import Foundation
import HelixBuildTools
import HelixCore
import Testing

extension BuildToolsTests {
@Suite("Native API Catalog")
struct NativeAPICatalogTests {
    @Test("Catalog codec is canonical and validates stable keys")
    func canonicalCodec() throws {
        let entry = try swiftEntry()
        let document = NativeAPICatalog.Document(
            identity: identity(module: "Fixture"),
            entries: [entry]
        )
        let bytes = try NativeAPICatalog.Codec.encode(document)

        #expect(try NativeAPICatalog.Codec.decode(bytes) == document)

        let object = try JSONSerialization.jsonObject(with: bytes)
        let pretty = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        #expect(throws: NativeAPICatalog.Error.nonCanonical) {
            try NativeAPICatalog.Codec.decode(pretty)
        }

        var forged = entry
        forged.key = .init(rawValue: .sha256("forged"))
        #expect(throws: NativeAPICatalog.Error.self) {
            try NativeAPICatalog.Document(
                identity: identity(module: "Fixture"),
                entries: [forged]
            ).validate()
        }
    }

    @Test("Registry resolves key, Swift spelling, and native entry point")
    func registryIndexes() throws {
        let swift = try swiftEntry()
        let objectiveC = try objectiveCEntry()
        let registry = try NativeAPICatalog.Registry(documents: [
            .init(identity: identity(module: "Fixture"), entries: [swift]),
            .init(identity: identity(module: "UIKit"), entries: [objectiveC]),
        ])

        #expect(registry.count == 2)
        #expect(registry[swift.key] == swift)
        #expect(registry.entries(swiftName: "Fixture.increment(_:)") == [swift])
        #expect(registry.entries(
            compilerSymbol: "$s7Fixture9incrementyS2iF"
        ) == [swift])
        #expect(registry.entries(
            backend: .objectiveCMessage,
            module: "UIKit",
            owner: "UIViewController",
            entryPoint: "presentViewController:animated:completion:"
        ) == [objectiveC])
        #expect(try registry.resolve(descriptor: objectiveC.descriptor) == objectiveC)
    }

    @Test("Registry rejects two catalogs that disagree outside a stable key")
    func rejectsConflictingRecords() throws {
        let original = try swiftEntry()
        var conflicting = original
        conflicting.swiftNames.append("Fixture.alternateName(_:)")
        conflicting.swiftNames.sort()

        #expect(throws: NativeAPICatalog.Error.conflictingEntry(original.key)) {
            try NativeAPICatalog.Registry(documents: [
                .init(
                    identity: identity(module: "Fixture", content: "first"),
                    entries: [original]
                ),
                .init(
                    identity: identity(module: "Fixture", content: "second"),
                    entries: [conflicting]
                ),
            ])
        }
    }

    @Test("Registry loading is idempotent but one identity cannot name two snapshots")
    func registryIdentityConsistency() throws {
        let original = try swiftEntry()
        let document = NativeAPICatalog.Document(
            identity: identity(module: "Fixture"),
            entries: [original]
        )
        let registry = try NativeAPICatalog.Registry(documents: [
            document, document,
        ])
        #expect(registry.count == 1)

        var different = original
        different.compilerSymbols.append("$s7Fixture9alternateyS2iF")
        different.compilerSymbols.sort()
        let conflicting = NativeAPICatalog.Document(
            identity: document.identity,
            entries: [different]
        )
        #expect(throws: NativeAPICatalog.Error.conflictingDocumentIdentity(
            document.identity.cacheKey
        )) {
            try NativeAPICatalog.Registry(documents: [document, conflicting])
        }
    }

    @Test("Unsupported APIs carry a precise reason and no executable binding")
    func unsupportedEntry() throws {
        let base = try swiftEntry()
        let unsupported = try NativeAPICatalog.Entry(
            descriptor: base.descriptor,
            contract: base.contract,
            support: .unsupported(
                code: "NATIVE-GENERIC-ABI",
                explanation: "The unspecialized generic Swift ABI cannot be invoked safely."
            ),
            binding: nil
        )
        let document = NativeAPICatalog.Document(
            identity: identity(module: "Fixture"),
            entries: [unsupported]
        )
        try document.validate()

        var invalid = unsupported
        invalid.binding = .init(
            strategy: .swiftAdapter,
            adapterID: "Fixture.unsupported"
        )
        #expect(throws: NativeAPICatalog.Error.self) {
            try NativeAPICatalog.Document(
                identity: identity(module: "Fixture"),
                entries: [invalid]
            ).validate()
        }
    }

    @Test("Contracts and executable bindings are validated at the catalog boundary")
    func validatesContractAndBindingAuthority() throws {
        let entry = try swiftEntry()

        var mismatchedContract = entry
        mismatchedContract.contract.callbacks = [
            .init(parameterIndex: 0, lifetime: .escaping),
        ]
        #expect(throws: NativeAPICatalog.Error.self) {
            try NativeAPICatalog.Document(
                identity: identity(module: "Fixture"),
                entries: [mismatchedContract]
            ).validate()
        }

        var missingTargetModule = entry
        missingTargetModule.binding?.importedModules = ["Foundation"]
        #expect(throws: NativeAPICatalog.Error.self) {
            try NativeAPICatalog.Document(
                identity: identity(module: "Fixture"),
                entries: [missingTargetModule]
            ).validate()
        }
    }

    @Test("Catalog cache identity includes toolchain, target, and module content")
    func cacheIdentity() {
        let base = identity(module: "Fixture", content: "one")
        var changedContent = base
        changedContent.moduleContentHash = .sha256("two")
        var changedTarget = base
        changedTarget.targetTriple = "arm64-apple-ios18.0-simulator"
        var changedSearchPath = base
        changedSearchPath.moduleSearchPathHash = .sha256("other-search-path")

        #expect(base.cacheKey != changedContent.cacheKey)
        #expect(base.cacheKey != changedTarget.cacheKey)
        #expect(base.cacheKey != changedSearchPath.cacheKey)
    }

    private func swiftEntry() throws -> NativeAPICatalog.Entry {
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.increment(_:)",
            signature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int"
            ),
            effects: .init(),
            contract: contract
        )
        return try .init(
            descriptor: descriptor,
            contract: contract,
            compilerSymbols: ["$s7Fixture9incrementyS2iF"],
            binding: .init(
                strategy: .swiftAdapter,
                adapterID: "Fixture.increment.Int",
                importedModules: ["Fixture"]
            )
        )
    }

    private func objectiveCEntry() throws -> NativeAPICatalog.Entry {
        let contract = Core.NativeImportContract.bounded(
            kind: .instanceMethod,
            domain: .uiKit,
            access: .write,
            maximumDurationMicroseconds: 1_000,
            allowsMainThread: true,
            callbacks: [
                .init(parameterIndex: 3, lifetime: .escaping),
            ]
        )
        let descriptor = try Core.NativeCall.Descriptor(
            target: .init(
                backend: .objectiveCMessage,
                module: "UIKit",
                owner: "UIViewController",
                member: "present(_:animated:completion:)",
                entryPoint: "presentViewController:animated:completion:",
                dispatch: .instance,
                receiverArgumentIndex: 0
            ),
            logicalSignature: .init(
                parameters: [
                    .init(type: "UIKit.UIViewController"),
                    .init(type: "UIKit.UIViewController"),
                    .init(type: "Swift.Bool"),
                    .init(
                        type: "(() -> Swift.Void)?",
                        callbackLifetime: .escaping
                    ),
                ],
                result: .init(type: "Swift.Void"),
                isolation: "MainActor"
            ),
            physicalSignature: .init(
                callingConvention: .objectiveC,
                parameters: [
                    .init(
                        type: .init(
                            kind: .object,
                            canonicalName: "UIKit.UIViewController",
                            encoding: "@"
                        ),
                        source: .argument(1)
                    ),
                    .init(
                        type: .init(
                            kind: .boolean,
                            canonicalName: "ObjectiveC.BOOL",
                            size: 1,
                            alignment: 1,
                            encoding: "B"
                        ),
                        source: .argument(2)
                    ),
                    .init(
                        type: .init(
                            kind: .block,
                            canonicalName: "ObjectiveC.Block",
                            encoding: "@?",
                            isNullable: true
                        ),
                        source: .argument(3)
                    ),
                ],
                result: .void
            ),
            effects: .init(
                mayAllocate: true,
                hasExternalSideEffects: true,
                requiresMainActor: true
            ),
            availability: [
                .init(platform: "iOS", introduced: .init(5)),
            ]
        )
        return try .init(
            descriptor: descriptor,
            contract: contract,
            compilerSymbols: ["c:objc(cs)UIViewController(im)presentViewController:animated:completion:"],
            binding: .init(
                strategy: .objectiveCInvoker,
                importedModules: ["UIKit"]
            )
        )
    }

    private func identity(
        module: String,
        content: String = "module-content"
    ) -> NativeAPICatalog.Identity {
        .init(
            provenance: module == "UIKit" ? .systemSDK : .applicationModule,
            xcodeProductBuild: "17A400",
            sdkProductBuild: "23A340",
            compilerFingerprint: "swiftlang-6.2.0.1",
            targetTriple: "arm64-apple-ios18.0",
            minimumDeployment: .init(15),
            swiftLanguageMode: "6",
            moduleName: module,
            moduleContentHash: .sha256(content),
            moduleSearchPathHash: .sha256("search-path"),
            dependencyGraphHash: .sha256("dependencies")
        )
    }
}
}
