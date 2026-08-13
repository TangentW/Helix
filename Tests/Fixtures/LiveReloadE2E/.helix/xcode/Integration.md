# Helix Xcode integration

This directory is owned by Helix Hub and generated from `HostPlan.json`.
Reconfigure the project from Helix; do not edit individual files.

The following target and Scheme edits are one-time project setup. After
setup, developers use Xcode Run, Build, Archive, and the shared Patch
scheme; no Helix command needs to be typed during ordinary work.

## `live` (`liveReload`)

- Link `HelixDevAppRuntime` and the Feature framework into the App.
- Use `Profiles/live/Feature.xcconfig` as the Feature target base configuration.
  Keep the Feature's ordinary Swift files in its Sources phase; never add Helix
  DerivedData output to the project.
- Use `Profiles/live/Application.xcconfig` as the App target base configuration.
- Add one Run Script phase before the App's Sources phase:
  `exec /bin/sh "${HELIX_INTEGRATION_ROOT:?}/Profiles/live/bridge.sh"`.
  Declare `$(HELIX_BRIDGE_OBJECT)` as its output. The script compiles the generated
  Bridge privately in DerivedData before the App links.
  Disable "Based on dependency analysis" for this phase: every Xcode Run must
  embed the fresh one-time invitation reserved by the Build pre-action, even
  when no project source changed.
- Run `Profiles/live/prepare.sh` as the first Scheme Build
  pre-action, with build settings supplied by the Feature target.
- Keep the Helix status-bar app open. The Build pre-action reserves a one-time
  code and compiles only its code plus the persistent Host Identity pin into the
  hidden Bridge in DerivedData.
- Run `Profiles/live/live-register.sh` as the Scheme Run
  pre-action, with build settings supplied by the App target. It verifies the
  exact final executable, persists its Build Context in Helix, and activates the
  pre-link reservation before Xcode launches the App.
- Do not configure a custom LLDB init file, launch environment, service
  post-action, host address, or session secret. A debugger-launched App detects
  that launch once, discovers the single `_helix._tcp` service, pins the
  generated Host Identity, and redeems the compiled invitation automatically.
  Opening the same installed App later does not reuse Xcode mode; it remains
  offline until a developer enters the current four-character Hub code.

The application target must link exactly the runtime product recorded
above. Release and Dev runtime products must never be linked together.

Project: `LiveReloadE2EHost.xcodeproj`
