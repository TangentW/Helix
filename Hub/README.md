# Helix Hub

`Hub/` contains the thin macOS experience shipped to developers under the visible name **Helix**. It is deliberately not a framework source directory: project discovery, Xcode integration, signing validation, persistence, pairing, transport, compilation, and session orchestration all live in reusable modules under `Sources/`.

The app provides:

- a menu-bar service with one four-character, case-insensitive manual pairing code;
- automatic adoption of an already-running `helix hub run` service, or an embedded service otherwise;
- project/workspace discovery and a SwiftUI onboarding flow for Hot Patch and Live Reload;
- transactional PBX project and shared-scheme configuration without adding generated Swift to the Xcode navigator;
- a signed, bundled build-tool helper whose exact path is published by the
  running service, so generated Xcode phases need no PATH or project
  environment setting;
- project-scoped Build Context, connection, diagnostic, and code-level follow-up status.

## Use it

1. Open Helix and choose an Xcode project, workspace, or source directory.
2. Leave Hot Patch and Live Reload selected, or turn off the workflow that this
   project does not need yet.
3. For each workflow, choose an App target, Swift Feature target, shared Scheme,
   and configuration. Helix resolves the module and bundle identity from
   Xcode's real build settings.
4. Apply the configuration. PBX, shared-Scheme, xcconfig, public configuration,
   local-network plist, Patch action, and Integration Kit changes commit as one
   transaction. Package linkage and runtime startup remain visible code-level
   actions.
5. Keep Helix open while using Live Reload. A normal Xcode debugger launch
   connects automatically. A directly opened test build stays offline until its
   debug page submits the four-character code shown by Helix.

Helix publishes a single `_helix._tcp` service. Xcode carries a build-scoped
invitation and persistent Host Identity pin in the hidden DerivedData Bridge;
it does not carry a host, port, environment credential, or custom LLDB script.
Manual codes are case-insensitive, short-lived, single-use, and still require
the exact registered Build Context and pinned TLS identity.

The GUI embeds the service when none is running. If `helix hub run` already owns
it, the GUI adopts the same control plane and never terminates that external
process. Generated Xcode phases discover the exact CLI through an owner-only
rendezvous record; normal projects do not configure `HELIX_EXECUTABLE` or
depend on shell `PATH`.

Build a runnable app bundle from the repository root:

```sh
Hub/Scripts/build-app.sh release
open Hub/.build/Helix.app
```

The bundle is ad-hoc signed for local development. Distribution signing and notarization belong to the release pipeline and must replace that local signature.

The bundle's visible name, executable, and service-facing product name are all
`Helix`. `Helix Hub` is the architecture and code name used for this thin
developer-experience layer.
