# Helix Hub

`Hub/` contains the thin macOS experience shipped to developers under the visible name **Helix**. It is deliberately not a framework source directory: project discovery, Xcode integration, signing validation, persistence, pairing, transport, compilation, and session orchestration all live in reusable modules under `Sources/`.

The app provides:

- a menu-bar service with one four-character, case-insensitive manual pairing code;
- automatic adoption of an already-running `helix hub run` service, or an embedded service otherwise;
- project/workspace discovery and a SwiftUI onboarding flow for Hot Patch and Live Reload;
- transactional PBX project, package, configuration, and shared-scheme setup without adding generated Bridge Swift to the Xcode navigator;
- a signed, bundled build-tool helper whose exact path is published by the
  running service, so generated Xcode phases need no PATH or project
  environment setting;
- project-scoped Build Context, connection, diagnostic, and code-level follow-up status.

## Use it

1. Open Helix and choose an Xcode project, workspace, or source directory.
2. Leave Hot Patch and Live Reload selected, or turn off the workflow that this
   project does not need yet.
3. Review the App target, source target, scheme, and configuration detected by
   Helix. A normal single-target App needs no choices; Helix creates a shared
   scheme when one does not exist.
4. Click **Enable Helix**. Package linkage, configuration wrappers, compiler
   capture, hidden Bridge/bootstrap objects, build-product network setup, Patch
   action, and Scheme lifecycle changes commit as one transaction. No application
   source import or runtime initialization is required.
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

The same App target can host Debug Live Reload and Release Hot Patch. Hub links
the production-safe `HelixAppIntegration` once, while dynamic
`HelixDevSupport` is linked and embedded only by the Live Reload configuration.
The compiler, SDK, sources, native adapters, and executable identity are
captured automatically from ordinary Xcode builds; users do not maintain a
Helix source list, API allowlist, or manual freeze step.

Configured mappings remain editable. **Apply Changes** automatically restores
the original PBX configuration references and removes obsolete target, scheme,
phase, product, and compiler-trigger state before applying the new mapping.
Turning off both workflows exposes **Remove Helix**, which transactionally
restores the Xcode project while preserving application source, recipes, and
signing material. A generated-file ownership manifest removes obsolete files
on reconfiguration and all owned files on removal without claiming unknown
files. The owner-only registry retains a non-editable last-applied plan solely
as removal recovery state; builds and reconfiguration always use the generated
Host Plan.

The local Dev Protocol and service-rendezvous schema are both version 1. Helix
accepts exactly that version and fails closed on every other value. It does not
migrate, reinterpret, or selectively delete local state based on historical
version numbers. Invalid pre-release artifacts must be removed and regenerated
by the configured Xcode build.

Recoverable service and pairing failures appear inside the status-bar panel
instead of in a separate modal alert. The panel stays open while the message is
read or its Retry action is used. Retrying replaces the GUI controller and its
embedded service when necessary, but never terminates an external service.

Build a runnable app bundle from the repository root:

```sh
Hub/Scripts/build-app.sh release
open Hub/.build/Helix.app
```

The bundle is ad-hoc signed for local development. Distribution signing and notarization belong to the release pipeline and must replace that local signature.

The app icon and menu-bar glyph share the checked-in vector geometry under
`Assets/Brand/`. `Hub/SupportingFiles/Helix.icns` is the packaged macOS icon;
the menu-bar representation is rendered into an AppKit template image before
it reaches `MenuBarExtra`, so macOS can reliably adapt its alpha mask to the
active appearance.

After editing the app-icon master, regenerate the packaged icon with:

```sh
Assets/Brand/generate-app-icon.sh
```

The bundle's visible name, executable, and service-facing product name are all
`Helix`. `Helix Hub` is the architecture and code name used for this thin
developer-experience layer.
