#if canImport(HelixCore)
import HelixCore
#endif

extension Bytecode {
/// Native imports supplied by Helix itself rather than by App configuration.
public enum StandardLibraryImports {
    /// Complete frozen identity shared by Shell generation and Runtime binding.
    public struct Descriptor: Hashable, Sendable {
        /// Canonical source-level callee used to derive the NativeImport key.
        public var canonicalCallee: String
        /// Exact canonical-SIL symbols accepted for this operation.
        public var silMangledNames: [String]
        /// VM types presented to the signed native implementation.
        public var parameterTypes: [Bytecode.ValueType]
        /// VM type returned by the signed native implementation.
        public var resultType: Bytecode.ValueType
        /// Frozen Swift signature included in the NativeImport identity.
        public var signature: Core.LoweredSignature
        /// Effects authorized for callers and enforced by the verifier.
        public var effects: Core.Effects
        /// Scheduling, policy-domain, and state-access contract.
        public var contract: Core.NativeImportContract
        /// Runtime capability required to dispatch this import.
        public var capability: Core.Capability

        /// Creates a complete standard-library NativeImport descriptor.
        public init(
            canonicalCallee: String,
            silMangledNames: [String],
            parameterTypes: [Bytecode.ValueType],
            resultType: Bytecode.ValueType,
            signature: Core.LoweredSignature,
            effects: Core.Effects,
            contract: Core.NativeImportContract,
            capability: Core.Capability = .nativeImportsV2
        ) {
            self.canonicalCallee = canonicalCallee
            self.silMangledNames = silMangledNames.sorted()
            self.parameterTypes = parameterTypes
            self.resultType = resultType
            self.signature = signature
            self.effects = effects
            self.contract = contract
            self.capability = capability
        }
    }

    /// Swift's variadic print ABI after SIL has materialized `[Any]`.
    public static let swiftPrint = Descriptor(
        canonicalCallee: "Swift.print(_:separator:terminator:)",
        silMangledNames: ["$ss5print_9separator10terminatoryypd_S2StF"],
        parameterTypes: [.array(.any), .string, .string],
        resultType: .void,
        signature: .init(
            parameters: [
                "Swift.Array<Swift.Any>",
                "Swift.String",
                "Swift.String",
            ],
            result: "Swift.Void"
        ),
        effects: .init(
            mayAllocate: true,
            hasExternalSideEffects: true
        ),
        contract: .cooperative(
            kind: .globalFunction,
            domain: .swift,
            access: .io,
            maximumDurationMicroseconds: 16_000,
            allowsMainThread: true
        )
    )
}
}
