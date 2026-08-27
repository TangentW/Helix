# Incremental Build Facts and Publication

[简体中文](Incremental-Build-Facts.zh-CN.md)

Helix keeps native API coverage and build cost as separate concerns. Prepare
first consumes compiler-derived module Catalogs and asks the source-rooted
frontend to prove only modules or concrete specializations that are not covered
by those snapshots. Every cached fact is revalidated against the current
semantic inputs before use. A cache hit is an optimization, never authority and
never a capability grant.

This document describes the schema-1 implementation used by both Xcode
workflows. No project API list, freeze step, or per-developer cache setup is
required. `HELIX_BUILD_CACHE_DIR` exists only as an optional diagnostic/test
override; the normal owner-local location is
`~/Library/Caches/Helix/BuildFacts`.

## Reuse layers

| Layer | Reused value | Exact invalidation boundary |
| --- | --- | --- |
| SDK identity | SDK path and build returned by `xcrun` | Swift driver instance, SDK name, `DEVELOPER_DIR`, and `TOOLCHAINS` |
| Module frontend | Validated receipt, diagnostics, and toolchain identity | Compiler-capture bytes, compiler fingerprint, non-SDK module/header interface snapshot, metadata, policy, catalog, configuration, and every logical/physical source identity and content hash |
| Symbol graph | Validated SDK module symbol graph | Compiler fingerprint, SDK/frontend invocation, and module |
| Managed probe | The uniquely measured operations and native signature types for one candidate | Compiler fingerprint, transform pipeline, SDK/frontend invocation, minimum OS, normalized candidate, and imported boundary types |
| Native API Catalog | Canonical module document plus the opaque compiler projection that deterministically reconstructs it | Xcode/SDK/compiler, target/deployment/language mode, module-content/search/dependency digests, normalized module-loading semantics, and transform pipeline |
| Hot Patch Prepare | Complete generated Shell tree and function counts | Exact Prepare identity plus exact paths, bytes, modes, and absence of unexpected entries |
| Release capability projection | Canonical schema-1 Native Capability Manifest and digest | Release/Shell identity, capabilities, and the complete ordered set of device-emitted Descriptor, Key, Contract, and capability records |
| Adapter Pack source | Deterministic Swift adapters grouped by native module | Compiler fingerprint, SDK/target/deployment, transform pipeline, module, ordered imported modules, and ordered stable call keys |
| Adapter Pack object | Validated Mach-O for one module Pack | Pack source identity plus toolchain, Xcode build, normalized compiler invocation, complete non-SDK compiler-input snapshot, and module maps |
| Development Adapter image | Signed Mach-O containing only first-used missing Swift Adapter bodies | Compiler/Xcode/SDK identities, target/deployment/platform/architecture, dependency graph, module, normalized semantic and preserved link arguments, exact generated sources, ordered Descriptor/Key/type/contract records |
| Application Bridge object | Stable validated Mach-O excluding the one-time Hub contract | Profile, toolchain, Xcode/SDK builds, transform pipeline, normalized compiler arguments, stable generated sources, compiler inputs, and module maps |
| Final Bridge state | Linked Bridge and C bootstrap Mach-O objects | Every generated source including the Hub contract, application/Pack inputs, Clang binary, and bootstrap source |

The persistent keys use canonical JSON and a versioned hash domain. Inputs do
not depend on modification times. Source content, compiler-capture content,
the compiler executable fingerprint, SDK build, target, minimum OS,
optimization and semantic frontend arguments are represented at the layer
where they can alter a result.

Helix lexes the source's actual Swift `import` declarations and checks that
result against the compiler's imported-module receipt. It fingerprints only
the directly imported non-SDK module interfaces found through Swift and common
Clang search arguments (`-I`, `-F`, `-Fsystem`, `-iquote`, `-isystem`, and
related forms), rather than every unrelated module that happens to share a
search root. The lexer understands common attributes, scoped imports,
conditional compilation, comments, raw and multiline strings, interpolation,
and extended regex literals. If lexical analysis is incomplete or does not cover the compiler's
result, the mismatch is rejected immediately after Typed AST and before any
symbol-graph or probe cache can consume the narrower identity. That run then
uses the authoritative uncached frontend.

Clang-forwarded roots and explicit inputs are handled separately. Module maps,
bridging headers, public headers, PCMs, VFS-overlay `external-contents`, and
Xcode binary header-map destinations receive a bounded content snapshot. SDK
and toolchain directories are bound by their separate build/fingerprint
identities instead of being rescanned. The current module's own output and
implementation objects are excluded to avoid a self-invalidating cache. If an
input cannot be resolved or read consistently, contains an uncertain symlinked
module tree, or exceeds its bounds, broad and partial frontend reuse are
disabled for that run; the build still follows the authoritative uncached path.
Directory traversal stops as soon as its entry bound is reached. Structured
overlay parsing is size-, node-, reference-, and depth-bounded. Physical paths
inside VFS overlays and binary header maps are replaced by structural roles in
the identity, while the bytes reached by each mapping are hashed under that
exact role; relocation is reusable, but changing which virtual name selects
which bytes is not.

The module receipt is the broad fast path. On a partial miss, the authoritative
frontend can still reuse symbol graphs and individual declaration probes. This
matters after an ordinary source edit: Helix does not need to rediscover an
unchanged UIKit or Foundation surface merely because the module receipt
changed.

Only deterministic singleton probe rejections are cached. A transient compiler
failure is not converted into a permanent rejection. Probe batches are split
as before, and the final per-candidate result is cached only after the normal
validation path has established it. Each entry also retains only the native
types actually named by that candidate's receiver, parameters, callbacks, or
result. This lets a previously unseen signature type survive a cache hit while
keeping the entry independent of whichever probe batch first produced it.

The module-level Catalog is a wider, separately keyed layer above those two
fine-grained caches. Its producer scans one module's concrete public surface
and reuses the same exact probe pipeline, then stores the canonical Catalog and
the compiler facts needed to reconstruct it. The whole-Catalog key contains no
consumer module name and normalizes physical Swift/Clang search roots, module
maps, PCM locations, resource roots, and module-cache directories. Their
ordered semantic roles remain in the key; module bytes, search-space meaning,
and dependencies are represented by the separately computed identity digests.
Non-path Clang options such as macros remain exact. This permits safe
cross-project reuse without treating a path spelling as API identity.

On a Catalog hit, no Symbol Graph or candidate probe process is launched. The
cached compiler projection is nevertheless normalized and reclassified, and
its reconstructed entries must exactly match the cached document. Prepare uses
those validated operations first and runs source-rooted framework expansion
only for the missing module set. Catalog-owned call identity is not rewritten
by the consuming project's source scope, aliases, or contextual SIL ownership.
Only logical parameter/result boundary types are retained for generated
external TypeOps.

Hot Patch synchronously resolves the complete reachable Catalog closure before
publishing a production capability baseline. Live Reload uses a nonblocking
shared-lock read: a missing entry or an entry currently being produced does not
stall Prepare. The current build uses the authoritative source-rooted fallback
and publishes an owner-private canonical prewarm job after the Shell succeeds.
A utility worker verifies that the job still matches the captured compiler,
SDK, plan, and module inputs, then builds the initial misses and recursively
follows referenced modules. The job file is atomically published with mode
`0600` inside a `0700` directory, opened with `O_NOFOLLOW`, size-bounded, and
locked so duplicate workers remain harmless.

Cold whole-module probing deliberately bypasses the per-candidate filesystem
cache: the enclosing Catalog key already names the exact module, while one
lock/manifest lookup per public API would add linear I/O without useful reuse.
Its independent 256-entry top-level batches use at most four workers. Results
and failures are joined in batch order, so concurrency changes elapsed time but
not bytes, diagnostics, metrics, or cache identity. Source-rooted expansion
continues to use the fine-grained probe cache because ordinary source edits can
reuse those candidates even when the broader module receipt changes.

## Validation and failure behavior

Every cached value is decoded and semantically validated by its consumer:

- canonical encoding, schema, key and payload SHA-256 must match;
- receipts must pass their full structural validation and match current source,
  metadata and toolchain identities;
- symbol graphs, measured operations, and their native signature types pass the
  same checks as fresh output;
- Prepare state compares the entire generated tree, including permissions;
- Adapter Pack, development Adapter, application Bridge, and final Bridge state
  revalidate Mach-O architecture/platform. A development Adapter additionally
  rechecks its deterministic install name, UUID, code-signature command, and
  dependency prefixes; final Bridge state also hashes the published objects
  before reuse.

Sources and compiler interfaces are confirmed again before newly produced
module, Prepare, or Bridge state is published. If an editor or another build
changes an input during analysis, Helix completes through the uncached path but
does not associate that output with the earlier identity. The Bridge identity
also hashes the actual Clang binary used for its C bootstrap, independently of
the Swift frontend fingerprint.

A missing entry runs the normal producer. A corrupt or semantically stale entry
is quarantined and rebuilt. If the local cache root is unsafe or unavailable,
Helix bypasses it and runs the authoritative path. A cache problem therefore
cannot silently widen capability or turn unsupported source into supported
source.

## Local security and concurrency

The build-fact store is owner-local and uses directories with mode `0700` and
files with mode `0600`. It rejects symbolic links, non-owned objects,
group/world-writable roots and unsafe writable ancestors; only root-owned
system aliases such as `/var` are admitted above the private root. Reads use
`O_NOFOLLOW`, bounded regular-file reads, and content hashes.

Writers take a per-key advisory lock. The producer runs once for concurrent
requests for the same key; other callers consume the published result after
validation. Entries are staged in a private directory and renamed into place.
The cache is not shipped in the App, included in a patch, or used as a trust
root.

Latency-sensitive readers use a separate read-only path. It never creates cache
directories, waits for a producer, repairs corruption, or starts work. It takes
a nonblocking shared lock and returns a miss whenever the immutable fact is not
immediately available and fully valid.

## Xcode publication behavior

Generated Shell files are published as one atomic directory transition. If the
new tree is byte-for-byte and mode-for-mode identical, publication is a no-op
and existing inode and modification times remain stable. For a partial change,
unchanged owner-generated regular files are hard-linked into the staged tree;
only changed files are written. Unexpected files and symbolic links are never
followed or preserved.

Hot Patch Prepare can return before frontend work when both its semantic input
identity and the exact output manifest still match. Live Reload intentionally
does not reuse its final Prepare state: a Hub invitation is single-use and a
new reservation is required. Live Reload still receives the expensive module,
symbol-graph and probe cache benefits, then rematerializes the small
session-bound contract.

Before frontend generation, Prepare derives module Catalog identities from the
captured compiler arguments and ordered module search semantics. Production
waits for all reachable snapshots; development reads only ready snapshots and
falls back without blocking. The frontend cache and Hot Patch Prepare identity
include both each canonical Catalog document and the digest of its opaque
compiler projection, so a changed module surface invalidates exactly the facts
that consumed it.

Bridge compilation has several exact layers. Objective-C and supported C calls
use fixed Runtime invokers. Remaining Swift calls are grouped into deterministic
per-module Adapter Packs whose source and Mach-O objects are cached separately.
The stable application Bridge is compiled without the one-time Hub contract
and has its own content-addressed Mach-O cache. A Live Reload build compiles the
small current Hub contract separately and relocatably links it with the stable
application object and Pack objects. Hot Patch has no Hub-contract source.

Hot Patch uses the managed production policy: every qualified candidate in the
proved imported-type boundary is device-emitted and included in canonical
`NativeCapabilities.json`. The generated Bridge derives the same table from its
Shell imports. Release audit compares both projections with the finalized
archive and pins the digest in `ReleaseBaseline.json`; a later patch repeats it
in the signed target. Consequently a Prepare cache hit can reuse the bytes, but
cannot change which calls the released App authorizes.

Unused managed-development candidates remain data-only receipt records and do not
inflate the stable Bridge or Pack objects. After HLBC is built, Helix inspects
its exact import table. Objective-C and supported C first uses need no new
machine code. Only newly referenced Swift Adapter keys are rendered into one
minimal development image; identical requests reuse the owner-local cache after
full Mach-O validation. The cache remains an optimization: the authenticated
payload carries the image and exact metadata, and the App independently
revalidates them before publishing a capability snapshot.

The patch compiler requests the additional typed-AST declaration map only when
the selected optimized or semantic SIL actually contains a foreign call. A
pure-Swift edit therefore does not pay another whole-module frontend launch just
because the Shell catalog happens to contain Objective-C candidates.

The final Bridge state remains stricter: it includes every generated source,
including the current invitation. A new Live Reload reservation therefore
intentionally misses final-state reuse, but it can still hit the independently
validated application and Pack object caches. Any source, module-map,
toolchain, compiler-argument, SDK, platform, or object drift invalidates the
layer it can affect. This keeps each invitation fresh without paying to
recompile the multi-megabyte stable Bridge.

## Observability

Schema-1 build-performance reports expose the decision without recording full
paths or compiler arguments. Relevant counters include:

- `frontend_cache.module_hit_count`, `module_miss_count`,
  `module_repair_count`, and `module_bypass_count`;
- `managed_native.symbol_graph_cache_hit_count` and `_miss_count`;
- `managed_native.probe_cache_hit_count`, `_miss_count`, and
  `cached_rejection_count`;
- `native_api_catalog.hit_module_count`, `miss_module_count`, and
  `entry_count` inside frontend generation;
- `prepare.catalog_planned_module_count`, `catalog_hit_module_count`,
  `catalog_generated_module_count`, `catalog_miss_module_count`,
  `catalog_unresolved_module_count`, `catalog_entry_count`, and the background
  prewarm scheduled/launch-failure counters;
- `prepare.state_hit_count`, `state_miss_count`, reused/written artifact counts,
  and `noop_publication_count`;
- `bridge.state_hit_count` and `state_miss_count`;
- `bridge.application_object_cache_hit_count`, `_generated_count`, and
  `_bypassed_count`;
- `bridge.adapter_object_cache_hit_count`, `_generated_count`, and
  `_bypassed_count`, plus Pack counts, entries, and object bytes.

Measured before/after Demo evidence is maintained in
[Build performance observability and baseline](Build-Performance-Baseline.md).
All cache, state, telemetry, protocol, artifact, and product schema versions
remain `1`; this optimization introduces no compatibility branch.
