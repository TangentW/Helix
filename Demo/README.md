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
  same callback Helix invalidates after activation. The managed Debug Shell
  also measures the public synchronous SDK-member surface whose boundary types
  are already frozen, including concrete generic owners and supported callback
  parameters. Adding `view.backgroundColor = .black`, UIKit animation calls,
  or another eligible measured member therefore exercises first-use framework
  code without rebuilding the App.

The checked-in Xcode integration under `.helix/xcode` is owned by Helix Hub.
The canonical plan is `.helix/xcode/HostPlan.json`; developers do not maintain a
separate input plan or compiler-policy file. Helix derives source and API
eligibility automatically; `Configurations/Helix` contains only the editable
Hot Patch recipe. Local signing material, build products, sessions, and patch
outputs are ignored. The shared schemes use the exact helper published by the
running Helix service, so normal use needs no `HELIX_EXECUTABLE`, shell `PATH`,
custom LLDB init, host, or port setting. Neither App imports generated Swift,
and the project contains no Bridge target or generated source reference.
Live Reload also has no UIKit type registry or page-owned reload hook; Helix
finds the displayed controller from the compiler-emitted nominal identity and
invalidates it in place.

The Live Reload Demo keeps one `DevRuntime.ApplicationSession` for the process
and exposes a **Helix** button in its navigation bar. A normal Xcode debugger
launch connects automatically. If the same build is opened directly, the page
keeps networking off until the four-character code shown by the Mac Helix app
is entered and confirmed.

See [Getting Started](../Docs/Getting-Started.md) for the complete existing-App
integration, target/Scheme wiring, runtime bootstrap, and first-run checklist.
[Development Live Reload](../Docs/Development-Live-Reload.md) explains the
runtime model, supported edits, UI refresh behavior, and current limitations.
The root [Xcode Run E2E cases](../Xcode-Run-E2E-Test-Cases.md) record the manual
GUI sequence, evidence requirements, negative cases, and cleanup checks.
