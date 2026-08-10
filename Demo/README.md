# Helix UIKit Demo

`HelixDemo.xcodeproj` contains two independent UIKit applications:

- **Helix Hot Patch Demo** builds an audited Release Shell. Edit the marked
  delivery-fee function, then build **Helix Build Patch** to compile, sign, and
  stage an HLXP without rebuilding or reinstalling the App.
- **Helix Live Reload Demo** starts an authenticated Dev Session from the Xcode
  Run action. Edit the marked `viewDidLayoutSubviews` body and save; the running
  page refreshes in place while its counter state and process remain unchanged.
  Presentation values intentionally live in that re-entrant callback rather
  than one-shot hierarchy installation, so the visible test edit exercises the
  same callback Helix invalidates after activation.

The checked-in Xcode integration under `.helix/xcode` is generated from
`HelixXcode.json`. Local signing material, build products, sessions, and patch
outputs are ignored. The shared schemes bootstrap the local `helix` executable
and demo-only signing identity when required, so ordinary use stays inside
Xcode. Neither App imports generated Swift, and the project contains no Bridge
target or generated source reference. Live Reload also has no UIKit type
registry or page-owned reload hook; Helix finds the displayed controller from
the compiler-emitted nominal type identity and invalidates it in place.

See [Getting Started](../Docs/Getting-Started.md) for the complete existing-App
integration, target/Scheme wiring, runtime bootstrap, and first-run checklist.
[Development Live Reload](../Docs/Development-Live-Reload.md) explains the
runtime model, supported edits, UI refresh behavior, and current limitations.
The root [Xcode Run E2E cases](../Xcode-Run-E2E-Test-Cases.md) record the manual
GUI sequence, evidence requirements, negative cases, and cleanup checks.
