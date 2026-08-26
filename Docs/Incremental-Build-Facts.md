# Incremental Build Facts and Publication

[简体中文](Incremental-Build-Facts.zh-CN.md)

Helix keeps native API coverage and build cost as separate concerns. Prepare
still asks the captured Swift frontend to prove the complete callable surface;
it now reuses previously proved facts when every semantic input is identical.
A cache hit is an optimization, never authority and never a capability grant.

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
| Managed probe | Zero or more uniquely measured operations for one candidate | Compiler fingerprint, transform pipeline, SDK/frontend invocation, minimum OS, normalized candidate, and imported boundary types |
| Hot Patch Prepare | Complete generated Shell tree and function counts | Exact Prepare identity plus exact paths, bytes, modes, and absence of unexpected entries |
| Bridge | Validated Swift Bridge and C bootstrap Mach-O objects | Toolchain, Xcode/SDK builds, profile, transform pipeline, normalized compiler arguments, generated sources, module maps, and bootstrap source |

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
Directory traversal stops as soon as its entry bound is reached, and structured
overlay parsing is iterative and size-bounded.

The module receipt is the broad fast path. On a partial miss, the authoritative
frontend can still reuse symbol graphs and individual declaration probes. This
matters after an ordinary source edit: Helix does not need to rediscover an
unchanged UIKit or Foundation surface merely because the module receipt
changed.

Only deterministic singleton probe rejections are cached. A transient compiler
failure is not converted into a permanent rejection. Probe batches are split
as before, and the final per-candidate result is cached only after the normal
validation path has established it.

## Validation and failure behavior

Every cached value is decoded and semantically validated by its consumer:

- canonical encoding, schema, key and payload SHA-256 must match;
- receipts must pass their full structural validation and match current source,
  metadata and toolchain identities;
- symbol graphs and measured operations pass the same checks as fresh output;
- Prepare state compares the entire generated tree, including permissions;
- Bridge state revalidates architecture/platform and hashes the published
  objects before reuse.

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

Bridge compilation has a separate exact state. A matching state reuses both
published object files; any source, module-map, toolchain, compiler-argument,
SDK, platform or object drift recompiles and revalidates them. Later fixed
native invokers and descriptor-driven adapters can make this compilation input
smaller, but the state identity does not assume that later architecture.
Today a Live Reload reservation changes the small generated development
contract, so its exact Bridge key intentionally misses even when the business
source is unchanged. Hot Patch already exercises the Bridge hit path. Moving
the remaining large fixed wrapper surface behind invokers and adapter packs is
the later-stage fix; weakening this input identity would only create a stale
session contract.

## Observability

Schema-1 build-performance reports expose the decision without recording full
paths or compiler arguments. Relevant counters include:

- `frontend_cache.module_hit_count`, `module_miss_count`,
  `module_repair_count`, and `module_bypass_count`;
- `managed_debug.symbol_graph_cache_hit_count` and `_miss_count`;
- `managed_debug.probe_cache_hit_count`, `_miss_count`, and
  `cached_rejection_count`;
- `prepare.state_hit_count`, `state_miss_count`, reused/written artifact counts,
  and `noop_publication_count`;
- `bridge.state_hit_count` and `state_miss_count`.

Measured before/after Demo evidence is maintained in
[Build performance observability and baseline](Build-Performance-Baseline.md).
All cache, state, telemetry, protocol, artifact, and product schema versions
remain `1`; this optimization introduces no compatibility branch.
