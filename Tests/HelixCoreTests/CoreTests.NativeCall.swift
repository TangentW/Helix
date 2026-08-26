import Foundation
import HelixCore
import Testing

extension CoreTests {
@Suite("Stable native call descriptors")
struct NativeCall {
    @Test("Equivalent Swift spelling produces one project-independent key")
    func canonicalIdentity() throws {
        let effects = Core.Effects(requiresMainActor: true)
        let contract = Core.NativeImportContract.bounded(
            kind: .instanceMethod,
            domain: .uiKit,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let first = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: " UIKit.UIView.alphaValue() ",
            signature: .init(
                parameters: [" UIKit . UIView "],
                result: " Swift . Double ",
                isolation: "Swift.MainActor"
            ),
            effects: effects,
            contract: contract
        )
        let second = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "UIKit.UIView.alphaValue()",
            signature: .init(
                parameters: ["UIKit.UIView"],
                result: "Swift.Double",
                isolation: "MainActor"
            ),
            effects: effects,
            contract: contract
        )

        #expect(first == second)
        #expect(try Core.NativeCall.Key.derive(descriptor: first)
            == Core.NativeCall.Key.derive(descriptor: second))
        #expect(first.target.receiverArgumentIndex == 0)
        #expect(first.canonicalCallee == "UIKit.UIView.alphaValue()")
    }

    @Test("Physical ABI, route, callback lifetime, and availability are identity")
    func identityDimensions() throws {
        let callback = Core.NativeImportCallback(
            parameterIndex: 0,
            lifetime: .escaping
        )
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false,
            callbacks: [callback]
        )
        let signature = Core.LoweredSignature(
            parameters: ["(() -> Swift.Void)?"],
            result: "Swift.Bool"
        )
        let base = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.observe(_:)",
            signature: signature,
            effects: .init(),
            contract: contract,
            availability: [
                .init(platform: "iOS", introduced: .init(15)),
            ]
        )
        let baseKey = try Core.NativeCall.Key.derive(descriptor: base)

        var changedLifetime = base
        changedLifetime.logicalSignature.parameters[0].callbackLifetime = .nonescaping
        #expect(try Core.NativeCall.Key.derive(descriptor: changedLifetime) != baseKey)

        var changedAvailability = base
        changedAvailability.availability[0].introduced = .init(16)
        #expect(try Core.NativeCall.Key.derive(descriptor: changedAvailability) != baseKey)

        var changedEntryPoint = base
        changedEntryPoint.target.entryPoint = "Fixture.observeAlternate(_:)"
        #expect(try Core.NativeCall.Key.derive(descriptor: changedEntryPoint) != baseKey)

        var changedPhysicalType = base
        changedPhysicalType.physicalSignature.parameters[0].type = .bridgeValue(
            "Swift.Any"
        )
        #expect(try Core.NativeCall.Key.derive(descriptor: changedPhysicalType) != baseKey)

        var changedPhysicalConvention = base
        changedPhysicalConvention.physicalSignature.parameters[0].convention =
            .directGuaranteed
        #expect(
            try Core.NativeCall.Key.derive(descriptor: changedPhysicalConvention)
                != baseKey
        )
    }

    @Test("Swift ABI conventions are separate from canonical type spellings")
    func separatesSwiftABIConventions() throws {
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.combine(_:_:_:)",
            signature: .init(
                parameters: [
                    "Foundation.URL", "Swift.String", "Fixture.Token",
                ],
                result: "Swift.String"
            ),
            effects: .init(),
            contract: contract,
            physicalParameterTypes: [
                "@in_guaranteed $Foundation.URL",
                "@guaranteed Swift.String",
                "@owned Fixture.Token",
            ],
            physicalResultType: "@owned Swift.String"
        )

        #expect(
            descriptor.physicalSignature.parameters.compactMap {
                $0.type.canonicalName
            } == ["Foundation.URL", "Swift.String", "Fixture.Token"]
        )
        #expect(
            descriptor.physicalSignature.parameters.map(\.convention) == [
                .indirectInGuaranteed, .directGuaranteed, .directOwned,
            ]
        )
        #expect(
            descriptor.physicalSignature.result.canonicalName == "Swift.String"
        )
        #expect(
            descriptor.physicalSignature.resultConvention == .directOwned
        )
    }

    @Test("Execution deadlines are policy rather than API identity")
    func policyIsSeparateFromIdentity() throws {
        let signature = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let short = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 100,
            allowsMainThread: false
        )
        let long = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 1_500,
            allowsMainThread: false
        )
        let first = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.increment(_:)",
            signature: signature,
            effects: .init(),
            contract: short
        )
        let second = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.increment(_:)",
            signature: signature,
            effects: .init(),
            contract: long
        )

        #expect(first == second)
        #expect(try Core.NativeCall.Key.derive(descriptor: first)
            == Core.NativeCall.Key.derive(descriptor: second))
    }

    @Test("Descriptors reject ambiguous receivers and incomplete projections")
    func rejectsAmbiguousABI() throws {
        let instanceContract = Core.NativeImportContract.bounded(
            kind: .instanceMethod,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        #expect(throws: Core.NativeCall.DescriptorError.self) {
            try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.Widget.read()",
                signature: .init(parameters: [], result: "Swift.Int"),
                effects: .init(),
                contract: instanceContract
            )
        }

        let explicitReceiver = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.Widget.compare(to:)",
            signature: .init(
                parameters: ["Fixture.Widget", "Fixture.Widget"],
                result: "Swift.Bool"
            ),
            effects: .init(),
            contract: instanceContract,
            receiverArgumentIndex: 0
        )
        #expect(explicitReceiver.target.receiverArgumentIndex == 0)

        let globalContract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        #expect(throws: Core.NativeCall.DescriptorError.self) {
            try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.sum(_:_:)",
                signature: .init(
                    parameters: ["Swift.Int", "Swift.Int"],
                    result: "Swift.Int"
                ),
                effects: .init(),
                contract: globalContract,
                physicalParameterTypes: ["Swift.Int"],
                physicalArgumentSources: [.argument(0)]
            )
        }
    }

    @Test("Qualified types inside member arguments do not corrupt owner parsing")
    func parsesNestedMemberSpellings() throws {
        let contract = Core.NativeImportContract.bounded(
            kind: .staticMethod,
            domain: .application,
            access: .pure,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee:
                "Fixture.HelixExternal.Swift.AnyObject.bridge(from:Swift.Any)",
            signature: .init(
                parameters: ["Swift.Any"],
                result: "Swift.AnyObject"
            ),
            effects: .init(),
            contract: contract
        )

        #expect(descriptor.target.owner == "HelixExternal.Swift.AnyObject")
        #expect(descriptor.target.member == "bridge(from:Swift.Any)")

        let genericOwner = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee:
                "Fixture.HelixExternal.Swift.Array<Swift.Int>.count.get",
            signature: .init(
                parameters: [],
                result: "Swift.Int"
            ),
            effects: .init(),
            contract: .bounded(
                kind: .staticGetter,
                domain: .application,
                access: .read,
                maximumDurationMicroseconds: 500,
                allowsMainThread: false
            )
        )
        #expect(
            genericOwner.target.owner
                == "HelixExternal.Swift.Array<Swift.Int>"
        )
        #expect(genericOwner.target.member == "count.get")
    }

    @Test("Callback authority is complete, in range, and reflected in ownership")
    func validatesCallbackAuthority() throws {
        let signature = Core.LoweredSignature(
            parameters: ["@autoclosure () -> Swift.Int"],
            result: "Swift.Int"
        )
        let nonescaping = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false,
            callbacks: [
                .init(parameterIndex: 0, lifetime: .nonescaping),
            ]
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.evaluate(_:)",
            signature: signature,
            effects: .init(),
            contract: nonescaping
        )
        #expect(descriptor.logicalSignature.parameters[0].isAutoclosure)
        #expect(descriptor.physicalSignature.parameters[0].ownership == .borrowed)

        let missing = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        #expect(throws: Core.NativeCall.DescriptorError.self) {
            try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.evaluate(_:)",
                signature: signature,
                effects: .init(),
                contract: missing
            )
        }

        let outOfRange = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false,
            callbacks: [
                .init(parameterIndex: 1, lifetime: .escaping),
            ]
        )
        #expect(throws: Core.NativeCall.DescriptorError.self) {
            try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.evaluate(_:)",
                signature: signature,
                effects: .init(),
                contract: outOfRange
            )
        }

        var duplicate = nonescaping
        duplicate.callbacks.append(
            .init(parameterIndex: 0, lifetime: .escaping)
        )
        #expect(throws: Core.NativeImportContractError.self) {
            try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.evaluate(_:)",
                signature: signature,
                effects: .init(),
                contract: duplicate
            )
        }
        var duplicateDescriptor = descriptor
        duplicateDescriptor.replaceCallbackLifetimes(duplicate.callbacks)
        #expect(throws: Core.NativeImportContractError.self) {
            try duplicateDescriptor.validate(contract: duplicate)
        }

        let tupleValue = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.store(_:)",
            signature: .init(
                parameters: ["(Swift.Int, () -> Swift.Void)"],
                result: "Swift.Void"
            ),
            effects: .init(),
            contract: missing
        )
        #expect(tupleValue.logicalSignature.parameters[0].callbackLifetime == nil)
    }

    @Test("Malformed type syntax and impossible optional defaults are rejected")
    func rejectsMalformedSwiftABI() throws {
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        #expect(throws: Core.NativeCall.DescriptorError.self) {
            try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.consume(_:)",
                signature: .init(
                    parameters: ["Swift.Array<Swift.Int"],
                    result: "Swift.Void"
                ),
                effects: .init(),
                contract: contract
            )
        }
        #expect(throws: Core.NativeCall.DescriptorError.self) {
            try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.consume(_:)",
                signature: .init(
                    parameters: ["Swift.String\u{7f}"],
                    result: "Swift.Void"
                ),
                effects: .init(),
                contract: contract
            )
        }
        #expect(throws: Core.NativeCall.DescriptorError.self) {
            try Core.NativeCall.Descriptor.swiftAdapter(
                canonicalCallee: "Fixture.consume(_:)",
                signature: .init(parameters: [], result: "Swift.Void"),
                effects: .init(),
                contract: contract,
                physicalParameterTypes: ["Swift.Int"],
                physicalArgumentSources: [.optionalNone]
            )
        }
    }

    @Test("Backends reject incompatible error and physical ABI conventions")
    func validatesBackendABI() throws {
        let throwingEffects = Core.Effects(mayThrow: true)
        #expect(throws: Core.NativeCall.DescriptorError.self) {
            try Core.NativeCall.Descriptor(
                target: .init(
                    backend: .cFunction,
                    module: "Darwin",
                    member: "readValue()",
                    entryPoint: "read_value",
                    dispatch: .global
                ),
                logicalSignature: .init(
                    parameters: [],
                    result: .init(type: "Swift.Int"),
                    isThrowing: true
                ),
                physicalSignature: .init(
                    callingConvention: .c,
                    parameters: [],
                    result: .init(
                        kind: .signedInteger,
                        canonicalName: "C.int64_t",
                        size: 8,
                        alignment: 8,
                        encoding: "q"
                    ),
                    errorConvention: .swiftThrows
                ),
                effects: throwingEffects
            )
        }

        #expect(throws: Core.NativeCall.DescriptorError.self) {
            try Core.NativeCall.Descriptor(
                target: .init(
                    backend: .objectiveCMessage,
                    module: "UIKit",
                    owner: "UIView",
                    member: "hidden.getter",
                    entryPoint: "isHidden",
                    dispatch: .instance,
                    receiverArgumentIndex: 0
                ),
                logicalSignature: .init(
                    parameters: [.init(type: "UIKit.UIView")],
                    result: .init(type: "Swift.Bool")
                ),
                physicalSignature: .init(
                    callingConvention: .objectiveC,
                    parameters: [
                        .init(
                            type: .init(
                                kind: .object,
                                canonicalName: "UIKit.UIView",
                                encoding: "@"
                            ),
                            source: .argument(0)
                        ),
                    ],
                    result: .init(
                        kind: .boolean,
                        canonicalName: "ObjectiveC.BOOL",
                        size: 1,
                        alignment: 1,
                        encoding: "B"
                    )
                ),
                effects: .init()
            )
        }
    }

    @Test("Canonical descriptors round-trip without changing their key")
    func canonicalRoundTrip() throws {
        let contract = Core.NativeImportContract.bounded(
            kind: .globalFunction,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: false
        )
        let descriptor = try Core.NativeCall.Descriptor.swiftAdapter(
            canonicalCallee: "Fixture.pair(_:_:)",
            signature: .init(
                parameters: ["Swift.Int", "Swift.String"],
                result: "(Swift.Int, Swift.String)"
            ),
            effects: .init(),
            contract: contract,
            argumentLabels: ["lhs", "rhs"]
        )
        let bytes = try Core.CanonicalJSON.encode(descriptor)
        let decoded = try JSONDecoder().decode(
            Core.NativeCall.Descriptor.self,
            from: bytes
        )

        try decoded.validate(contract: contract)
        #expect(decoded == descriptor)
        #expect(try Core.NativeCall.Key.derive(descriptor: decoded)
            == Core.NativeCall.Key.derive(descriptor: descriptor))
    }
}
}
