#if canImport(HelixCore)
import HelixCore
#endif

extension Bytecode {
/// Native imports supplied by Helix itself rather than by App configuration.
public enum StandardLibraryImports {
    /// Complete frozen identity shared by Shell generation and Runtime binding.
    public struct Descriptor: Hashable, Sendable {
        /// Single source of truth for native identity, logical behavior, and
        /// the exact builtin adapter boundary.
        public var nativeCall: Core.NativeCall.Descriptor
        /// Exact canonical-SIL symbols accepted for this operation.
        public var silMangledNames: [String]
        /// VM types presented to the signed native implementation.
        public var parameterTypes: [Bytecode.ValueType]
        /// VM type returned by the signed native implementation.
        public var resultType: Bytecode.ValueType
        /// Scheduling, policy-domain, and state-access contract.
        public var contract: Core.NativeImportContract
        /// Runtime capability required to dispatch this import.
        public var capability: Core.Capability

        /// Creates a complete standard-library NativeImport descriptor.
        fileprivate init(
            canonicalCallee: String,
            silMangledNames: [String],
            parameterTypes: [Bytecode.ValueType],
            resultType: Bytecode.ValueType,
            signature: Core.LoweredSignature,
            effects: Core.Effects,
            contract: Core.NativeImportContract,
            capability: Core.Capability = .nativeImportsV1
        ) {
            do {
                nativeCall = try Core.NativeCall.Descriptor.swiftAdapter(
                    canonicalCallee: canonicalCallee,
                    signature: signature,
                    effects: effects,
                    contract: contract,
                    backend: .builtin
                )
            } catch {
                // These are hard-coded protocol fixtures. Failure means the
                // source definition is internally inconsistent.
                preconditionFailure(
                    "invalid standard-library native call: \(error)"
                )
            }
            self.silMangledNames = silMangledNames.sorted()
            self.parameterTypes = parameterTypes
            self.resultType = resultType
            self.contract = contract
            self.capability = capability
        }

        public var canonicalCallee: String { nativeCall.canonicalCallee }
        public var signature: Core.LoweredSignature {
            nativeCall.loweredSignature
        }
        public var effects: Core.Effects { nativeCall.effects }
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

    /// Swift's variadic debug-print ABI after SIL has materialized `[Any]`.
    public static let swiftDebugPrint = Descriptor(
        canonicalCallee: "Swift.debugPrint(_:separator:terminator:)",
        silMangledNames: ["$ss10debugPrint_9separator10terminatoryypd_S2StF"],
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

    /// A fixed `Any -> String` bridge for Swift's generic describing entry.
    /// Compiler lowering proves and records the concrete source identity before
    /// this NativeImport is invoked; Swift generic metadata never enters HLBC.
    public static let swiftStringDescribing = textRendering(
        canonicalCallee: "Swift.String.init(describing:)",
        silMangledName: "$sSS10describingSSx_tclufC"
    )

    /// A fixed `Any -> String` bridge for Swift's generic reflecting entry.
    public static let swiftStringReflecting = textRendering(
        canonicalCallee: "Swift.String.init(reflecting:)",
        silMangledName: "$sSS10reflectingSSx_tclufC"
    )

    private static func textRendering(
        canonicalCallee: String,
        silMangledName: String
    ) -> Descriptor {
        Descriptor(
            canonicalCallee: canonicalCallee,
            silMangledNames: [silMangledName],
            parameterTypes: [.any],
            resultType: .string,
            signature: .init(
                parameters: ["Swift.Any"],
                result: "Swift.String"
            ),
            effects: .init(mayAllocate: true),
            contract: .cooperative(
                kind: .initializer,
                domain: .swift,
                access: .pure,
                maximumDurationMicroseconds: 16_000,
                allowsMainThread: true
            )
        )
    }
}
}
