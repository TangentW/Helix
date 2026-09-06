# Compiler identity and diagnostic evidence

[简体中文](Compiler-Identity.zh-CN.md)

A name printed by the compiler is a lookup hint until its authority and scope
are established. This inventory covers the source-to-receipt pipeline and its
SIL, Catalog, cache, and project-installation boundaries. It is a review baseline;
new compiler output and integration evidence can require narrower rules.

| Key family | Authority and disambiguation | Rejection and consumers |
| --- | --- | --- |
| Source membership | Canonical physical path identifies a compiler input within one invocation; logical path plus content hash identifies a source in the receipt | Request validation rejects duplicate logical paths and physical aliases; typed AST must cover exactly the requested files |
| Source nominal declaration | Compiler USR, with logical file scope for private declarations; qualified spelling is a scoped lookup | `SourceNominalIndex` resolves file-local names separately. Conflicting USRs and same-scope names report both declarations. Ambiguous printed private layouts cannot become frozen value layouts |
| Imported nominal | Established runtime/ABI identity precedes normalization of qualified/relative Swift spelling using proven module roots | `ImportedNominalIdentity` is shared by discovery, merge, aliases and bindings. Conflicting module, representation or isolation facts remain errors; normalization does not merge unrelated nested names |
| Imported operation and selector | Declaration USR/descriptor, signature, owner, dispatch, accessor and measured ABI; selector probes also include their imported-module context | A common implementation symbol does not equate API declarations. Candidate sets are deduplicated before disjoint probe batches; generated probe indices only identify members of that exact batch |
| SIL function | A concrete `sil @symbol : $type { ... }` definition establishes symbol identity within that SIL file | Repeated definitions reject with both SIL lines and types. The derived function index refreshes on public array mutation and excludes duplicates. Typed-AST resolution uses exact symbols or a unique source location; ambiguous candidates are never selected by order |
| SIL debug scope | Numeric scope ID within one SIL document; an inherited scope keeps its own identity even when locations coincide | Duplicate IDs reject with both source records. `parent @name` supplies declaration location only for a concrete function definition. Debug-only names such as `__unknown_macro__` are not function identities; their locations remain available by scope ID |
| SIL printed type and member aliases | Unique compiler-proven nominal/type aliases within the relevant module and source scope | `TypeEnvironment` excludes ambiguous private type summaries and fails when a required layout or dispatch cannot be proven; short names never grant a layout by themselves |
| SIL source-module map | Explicit compiler `#fileID` to path mapping | A path mapped to conflicting modules rejects with the path and both module values; debug coordinates are provenance, not persisted identity |
| Native Catalog and receipt keys | Validated versioned artifact identity, exact compiler/toolchain/SDK/target and canonical descriptor or TypeID | Snapshot/receipt validation precedes unique-key maps. Hash equality is useful only with the corresponding authenticated or validated record; runtime lookup by display name is not a fallback |
| Compiler facts and caches | Exact toolchain, invocation, source/dependency content and transform identity; checkpoints also bind physical paths | `CachedAdapter` validates request/source uniqueness before maps, then confirms inputs again. Checkpoint hits are reparsed. Changing frontend identity interpretation changes the transform hash so old module receipts cannot bypass the new checks |
| PBX objects and configurations | Object ID within the root `objects` dictionary; configuration name within its owning configuration list | Duplicate dictionary keys and repeated configuration names reject with their scope and object IDs. Nested `TargetAttributes` keys do not identify top-level target records |

The current debug-scope change does not alter a shipped wire schema, nominal ID,
or public symbol spelling. It changes the local transform identity and therefore
requires rebuilding affected cached Shell facts. Equal locations for the same
real function remain valid. A placeholder-looking name that actually has a SIL
function definition must still satisfy the function uniqueness rules.

Fail-closed messages must include the observed competing values, their origin,
and a locatable example for each distinct fact already available at the decision
point. For example, a declaration-location conflict includes the function symbol,
both scope IDs and both file/line/column positions; a source nominal conflict
includes USR, qualified spelling, logical source, UTF-8 offset, kind and scope.
Keep this evidence in diagnostics rather than extending persisted identity with
debug-only details. Repository review rules enforce the same requirement.

The debug-only parent regression is a SIL grammar fixture based on reported
compiler output. The real system-framework integration test separately enables
`-g` and verifies that the replay emits debug scopes, alongside Objective-C bridging, C++ interoperability, standard-library macros and
explicit module compilation. That test exercises the configuration combination;
it does not establish the minimal Swift program that emits `__unknown_macro__`.
Replay preserves `-g`, `-gline-tables-only`, and `-gnone` in their captured order;
argument-selection tests cover those levels independently.
