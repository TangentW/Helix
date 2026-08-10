# Helix repository conventions

## Swift naming and file layout

- Group Swift types under a small, empty enum namespace and add
  the related declarations in extensions. Call sites should read
  `Namespace.Type`.
- Name namespaced files `Namespace.Type.swift`, for example
  `ReleaseCompiler.Driver.swift`.
- Do not use `HLX`, `HLBC`, `HLXI`, or similar prefixes for Swift type
  declarations or handwritten Swift file names. Serialized models follow the
  same namespace rule; their Swift spelling is not their wire identity.
- Keep those abbreviations only in protocol-level identifiers such as magic
  bytes, artifact names, hash domains, diagnostic codes, and generated ABI/C
  symbols whose spelling is part of the runtime contract.
- Once a public Swift API or persisted protocol identifier has shipped, change
  it only through an explicit API or schema migration.

## Engineering quality and stage gates

- Favor clear module boundaries, small focused abstractions, and code that is
  easy to review. Correctness and completeness come first, but do not add
  speculative fallback paths or abstractions without a concrete requirement.
- Add concise English comments for non-obvious invariants, ABI or wire-format
  constraints, concurrency behavior, and security decisions. Do not narrate
  self-explanatory code.
- Every feature or refactor must include tests proportional to its risk,
  including negative and boundary cases where relevant.
- Work in explicit stages. Before starting the next stage, review the current
  one for architecture, correctness, concurrency, security, performance, and
  maintainability; fix every known issue and rerun the relevant and full test
  suites.
- A stage is not complete merely because it compiles or its happy-path test
  passes. It is complete only after review findings are resolved and regression
  tests are green.

## Living technical baseline

- Treat the technical documentation as a current, reviewable baseline, not as
  an immutable specification. Helix must improve as implementation, compiler
  behavior, tests, benchmarks, simulator runs, and device evidence reveal
  better or narrower designs.
- Never describe the overall Helix architecture as permanently frozen. Only a
  named, versioned ABI, wire contract, identity, artifact format, or acceptance
  decision may be stable within its declared compatibility range.
- Every code change that alters architecture, behavior, integration, a public
  contract, capability, limitation, or acceptance evidence must update all
  affected documentation in the same change and stage. When evidence shows a
  documented approach is infeasible, incomplete, or inferior, implement the
  best supported design and rewrite obsolete conclusions instead of leaving
  contradictory guidance for future work.
- A document's use of “frozen” means that the named ABI, wire contract, release
  identity, or currently accepted product decision must remain internally
  consistent for that version. It does not make the overall Helix architecture
  permanently immune to evidence-based revision. Shipped contracts still
  require an explicit schema/API migration and compatibility review.
- Review documentation against executable code and test evidence at every stage
  gate. Do not claim support, safety, performance, or platform coverage that has
  not been demonstrated by the corresponding implementation and validation.
