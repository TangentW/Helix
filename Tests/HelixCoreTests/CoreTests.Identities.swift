import Foundation
import Testing
@testable import HelixCore

enum CoreTests {}

extension CoreTests {
@Suite("HelixCore stable identities")
struct Identities {
    @Test("SHA-256 and Codable use a stable lower-case representation")
    func digestRoundTrip() throws {
        let digest = Core.Digest.sha256("abc")
        #expect(digest.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let encoded = try JSONEncoder().encode(digest)
        let decoded = try JSONDecoder().decode(Core.Digest.self, from: encoded)
        #expect(decoded == digest)
        #expect(decoded.constantTimeEquals(digest))
    }

    @Test("Length prefixes prevent component ambiguity")
    func stableHasherSeparatesComponents() {
        var first = Core.StableHasher(domain: "HLX.Test.v1")
        first.append("ab")
        first.append("c")

        var second = Core.StableHasher(domain: "HLX.Test.v1")
        second.append("a")
        second.append("bc")

        #expect(first.finalize() != second.finalize())
    }

    @Test("Function identities are deterministic and domain separated")
    func identityDeterminism() throws {
        let namespace = Core.ShellNamespaceID.derive(bundleID: "dev.helix.fixture", buildNumber: "1", seed: "seed")
        let signature = Core.LoweredSignature(parameters: ["Swift.Int"], result: "Swift.Int")
        let first = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func transform(_: Swift.Int) -> Swift.Int",
            loweredSignature: signature,
            role: .function
        )
        let second = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Sources/Fixture.swift",
            canonicalDeclaration: "func transform(_: Swift.Int) -> Swift.Int",
            loweredSignature: signature,
            role: .function
        )
        let type = Core.TypeID.derive(namespace: namespace, canonicalType: "Swift.Int")

        #expect(first == second)
        #expect(first.rawValue != type.rawValue)
    }

    @Test("Async ABI metadata is identity-bound and required by the wire contract")
    func asyncIdentityAndCoding() throws {
        let synchronous = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        )
        let asynchronous = Core.LoweredSignature(
            parameters: ["Swift.Int"],
            result: "Swift.Int",
            isAsync: true
        )
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.async-identity",
            buildNumber: "1",
            seed: "fixture"
        )
        let syncKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func value(_: Int) -> Int",
            loweredSignature: synchronous,
            role: .function
        )
        let asyncKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "Fixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func value(_: Int) async -> Int",
            loweredSignature: asynchronous,
            role: .function
        )
        #expect(syncKey != asyncKey)

        let incompleteEffects = Data(
            """
            {"hasExternalSideEffects":false,"mayAllocate":false,"mayThrow":false,"requiresMainActor":false}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Core.Effects.self, from: incompleteEffects)
        }
        let incompleteSignature = Data(
            """
            {"isThrowing":false,"parameters":[],"result":"Swift.Void"}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                Core.LoweredSignature.self,
                from: incompleteSignature
            )
        }
        #expect(String(
            decoding: try Core.CanonicalJSON.encode(Core.Effects()),
            as: UTF8.self
        ).contains("\"isAsync\":false"))
        #expect(String(
            decoding: try Core.CanonicalJSON.encode(Core.Effects(isAsync: true)),
            as: UTF8.self
        ).contains("\"isAsync\":true"))
    }

    @Test("Native import contracts qualify synchronous execution and enter identity")
    func nativeImportContractIdentity() throws {
        let effects = Core.Effects(requiresMainActor: true)
        let getter = Core.NativeImportContract.bounded(
            kind: .instanceGetter,
            domain: .uiKit,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        try getter.validate(effects: effects)

        let method = Core.NativeImportContract.bounded(
            kind: .instanceMethod,
            domain: .uiKit,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.contract",
            buildNumber: "1",
            seed: "fixture"
        )
        let signature = Core.LoweredSignature(
            parameters: ["UIKit.UIView"],
            result: "Swift.Bool",
            isolation: "MainActor"
        )
        let getterKey = try Core.NativeImportKey.derive(
            namespace: namespace,
            canonicalCallee: "UIKit.UIView.isHidden.getter",
            signature: signature,
            effects: effects,
            contract: getter
        )
        let methodKey = try Core.NativeImportKey.derive(
            namespace: namespace,
            canonicalCallee: "UIKit.UIView.isHidden.getter",
            signature: signature,
            effects: effects,
            contract: method
        )
        #expect(getterKey != methodKey)

        #expect(throws: Core.NativeImportContractError.self) {
            try getter.validate(
                effects: .init(requiresMainActor: true, isAsync: true)
            )
        }
    }

    @Test("Synchronous native contracts enforce declared effects and deadlines")
    func validatesNativeImportContracts() throws {
        let io = Core.NativeImportContract.cooperative(
            kind: .serviceMethod,
            domain: .application,
            access: .io,
            maximumDurationMicroseconds: 10_000,
            allowsMainThread: false
        )
        try io.validate(effects: .init(hasExternalSideEffects: true))
        #expect(throws: Core.NativeImportContractError.self) {
            try io.validate(effects: .init(hasExternalSideEffects: false))
        }
        let nonCooperativeIO = Core.NativeImportContract.bounded(
            kind: .serviceMethod,
            domain: .application,
            access: .io,
            maximumDurationMicroseconds: 1_000,
            allowsMainThread: false
        )
        #expect(throws: Core.NativeImportContractError.self) {
            try nonCooperativeIO.validate(
                effects: .init(hasExternalSideEffects: true)
            )
        }

        let dishonestGetter = Core.NativeImportContract.bounded(
            kind: .instanceGetter,
            domain: .application,
            access: .write,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        #expect(throws: Core.NativeImportContractError.self) {
            try dishonestGetter.validate(effects: .init(hasExternalSideEffects: true))
        }

        let offActorUIKit = Core.NativeImportContract.bounded(
            kind: .instanceMethod,
            domain: .uiKit,
            access: .read,
            maximumDurationMicroseconds: 500,
            allowsMainThread: true
        )
        #expect(throws: Core.NativeImportContractError.self) {
            try offActorUIKit.validate(effects: .init())
        }

        let oversizedMainThreadWork = Core.NativeImportContract.cooperative(
            kind: .serviceMethod,
            domain: .application,
            access: .read,
            maximumDurationMicroseconds: 16_001,
            allowsMainThread: true
        )
        #expect(throws: Core.NativeImportContractError.self) {
            try oversizedMainThreadWork.validate(effects: .init())
        }
    }

    @Test("Requested quotas are intersected with the runtime ceiling")
    func resourceCeiling() {
        let request = Core.ResourceLimits(instructionFuelPerEntry: 1_000_000, maxCallDepth: 8)
        let ceiling = Core.ResourceLimits(instructionFuelPerEntry: 50_000, maxCallDepth: 64)
        let resolved = request.constrained(by: ceiling)
        #expect(resolved.instructionFuelPerEntry == 50_000)
        #expect(resolved.maxCallDepth == 8)
    }

    @Test("Semantic versions parse one to three bounded decimal components")
    func semanticVersionParsing() throws {
        #expect(try Core.SemanticVersion(parsing: "15") == .init(15, 0, 0))
        #expect(try Core.SemanticVersion(parsing: "15.2") == .init(15, 2, 0))
        #expect(try Core.SemanticVersion(parsing: "15.2.1") == .init(15, 2, 1))
        for invalid in ["", "15.", ".15", "15.2.1.0", "15.-1", "65536"] {
            #expect(throws: Core.Error.self) {
                try Core.SemanticVersion(parsing: invalid)
            }
        }
    }
}
}
