import HelixCore
import HelixInterface

extension NativeAPICatalog {
/// Stable implementation identity included in project-level incremental keys.
/// It changes whenever cached Catalog compiler facts or projection semantics
/// change, without requiring callers to decode a complete Catalog artifact.
public static let currentPipelineIdentity: Core.Digest = {
    var hasher = Core.StableHasher(
        domain: "HLX.NativeAPICatalog.CurrentPipeline.v1"
    )
    hasher.append(NativeAPICatalog.Pipeline.compilerProbePipelineHash)
    hasher.append(NativeAPICatalog.Pipeline.catalogProjectionPipelineHash)
    return hasher.finalize()
}()

/// Independent identities for the expensive compiler facts and the cheaper
/// Catalog projection. A projection-only change must not discard SDK probes.
enum Pipeline {
    private struct CompilerInput: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var identity: NativeAPICatalog.Identity
        var invocation: InterfaceArchive.FrontendInvocation
    }

    private struct CatalogOutput: Codable, Sendable {
        var schemaVersion: UInt16 = 1
        var identity: NativeAPICatalog.Identity
        var invocation: InterfaceArchive.FrontendInvocation
        var projectionPipelineHash: Core.Digest
    }

    /// Raw Symbol Graph bytes depend on extractor argument projection and
    /// decoding, but not on later candidate or Catalog rules.
    static let symbolGraphPipelineHash = Core.Digest.sha256(
        "Helix.NativeAPICatalog.SymbolGraphPipeline.v1:"
            + "semantic-argument-projection:canonical-document-decoding:explicit-working-directory"
    )

    /// Bump only when candidate nomination, generated probe source, compiler
    /// measurement, or cached probe payload semantics change.
    static let compilerProbePipelineHash: Core.Digest = {
        var hasher = Core.StableHasher(
            domain: "HLX.NativeAPICatalog.CompilerProbePipeline.v1"
        )
        hasher.append(symbolGraphPipelineHash)
        hasher.append(
            "public-symbol-candidates:concrete-owner-specialization:"
                + "inhabited-storable-boundaries:managed-inout-filter:"
                + "compiler-measured-callback-lifetimes:signature-imports:"
                + "deterministic-rejection-bisection:invalid-owner-recovery:"
                + "synthesized-objective-c-initializers:"
                + "objective-c-protocol-anyobject-surface:"
                + "swift-overlay-extension-module-ownership:"
                + "canonical-declaration-owner-aliases:"
                + "inherited-main-actor-symbol-graph-closure:"
                + "compiler-inferred-main-actor-probes:"
                + "line-bound-main-actor-diagnostics:"
                + "compiler-wide-deprecation-filter:concrete-nominal-observations-v2:"
                + "runtime-proven-ns-aliases-v3:exact-clang-nominals:"
                + "clang-member-physical-argument-order-v2:measured-candidate-rejections-v2:actor-selector-rejections:merged-probe-aliases:target-os-imports:clang-typedef-layout-evidence:related-decl-filter:unique-probe-aliases:clang-constructor-usr-boundary"
        )
        return hasher.finalize()
    }()

    /// Bump for the inexpensive merge, alias, descriptor, support, or binding
    /// projection. It includes probe semantics because the final Catalog is a
    /// validated materialization of those facts.
    static let catalogProjectionPipelineHash: Core.Digest = {
        var hasher = Core.StableHasher(
            domain: "HLX.NativeAPICatalog.ProjectionPipeline.v1"
        )
        hasher.append(compilerProbePipelineHash)
        hasher.append(
            "exact-alias-identity-fixed-point:module-global-operation-aliases:"
                + "candidate-logical-signature-projection:"
                + "c-compiler-logical-signature:"
                + "invocation-erasure-preservation:"
                + "unsupported-logical-alias-fallback:"
                + "structural-module-relative-type-comparison:"
                + "bridge-alias-logical-identity-separation:"
                + "module-scoped-clang-value-type-identity:"
                + "precise-imported-enum-kind:"
                + "catalog-authority-weak-observation-reconciliation:"
                + "compiler-proven-initializer-nominal-aliases:"
                + "pure-swift-reference-alias-identity:"
                + "logical-physical-signature-projection:"
                + "native-call-descriptor-v1:binding-classification:"
                + "complete-catalog-publication:compiler-projection-v1:"
                + "published-operation-entry-index:"
                + "published-native-capability-projection:"
                + "declaration-missing-objective-c-implementation-lookup:"
                + "vm-native-operation-precedence:binary-cache-payload:clang-declaration-module-adapters"
        )
        return hasher.finalize()
    }()

    /// Semantic compiler/module inputs shared by Symbol Graph and probe
    /// caches. Deliberately excludes every post-probe projection rule.
    static func compilerInputHash(
        identity: NativeAPICatalog.Identity,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> Core.Digest {
        try BuildCache.key(
            domain: "HLX.BuildCache.NativeAPICatalogCompilerInput.v1",
            value: CompilerInput(identity: identity, invocation: invocation)
        )
    }

    static func catalogCacheKey(
        identity: NativeAPICatalog.Identity,
        invocation: InterfaceArchive.FrontendInvocation,
        projectionPipelineHash: Core.Digest = catalogProjectionPipelineHash
    ) throws -> Core.Digest {
        try BuildCache.key(
            domain: "HLX.BuildCache.NativeAPICatalog.v1",
            value: CatalogOutput(
                identity: identity,
                invocation: invocation,
                projectionPipelineHash: projectionPipelineHash
            )
        )
    }
}
}
