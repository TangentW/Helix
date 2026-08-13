# Helix Hub

`Hub/` contains the thin macOS experience shipped to developers under the visible name **Helix**. It is deliberately not a framework source directory: project discovery, Xcode integration, signing validation, persistence, pairing, transport, compilation, and session orchestration all live in reusable modules under `Sources/`.

The app provides:

- a menu-bar service with one four-character, case-insensitive manual pairing code;
- automatic adoption of an already-running `helix hub run` service, or an embedded service otherwise;
- project/workspace discovery and a SwiftUI onboarding flow for Hot Patch and Live Reload;
- transactional PBX project and shared-scheme configuration without adding generated Swift to the Xcode navigator;
- project-scoped Build Context, connection, diagnostic, and code-level follow-up status.

Build a runnable app bundle from the repository root:

```sh
Hub/Scripts/build-app.sh release
open Hub/.build/Helix.app
```

The bundle is ad-hoc signed for local development. Distribution signing and notarization belong to the release pipeline and must replace that local signature.
