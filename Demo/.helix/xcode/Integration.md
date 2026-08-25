# Helix Xcode integration

This directory is owned by Helix Hub and generated automatically. It is
an implementation record, not a setup checklist. Reapply integration
from Helix instead of editing these files.

## `hot` (`hotPatch`)

- App target: `HotPatchDemo`
- Source target: `HotPatchFeature`
- Scheme and configuration: `Helix Hot Patch Demo` / `Release`
- App product: `HelixAppIntegration` (linked automatically)

Hub owns the target wrapper, compiler capture, generated trigger, runtime
bootstrap, and Scheme action. Swift source membership is read from the successful
Xcode compile, so adding, moving, deleting, or generating a source needs no Helix
file list or policy update. Generated Bridge code remains in DerivedData.
Build or archive the selected App configuration once. The installed Scheme
action records the compiler, SDK, App identity, and generated interface for
that build automatically. Build Scheme `Helix Build Patch` when creating a
signed patch for it; no second App target or copied build settings are needed.

## `live` (`liveReload`)

- App target: `LiveReloadDemo`
- Source target: `LiveReloadFeature`
- Scheme and configuration: `Helix Live Reload Demo` / `Debug`
- App product: `HelixAppIntegration` (linked automatically)

Hub owns the target wrapper, compiler capture, generated trigger, runtime
bootstrap, and Scheme action. Swift source membership is read from the successful
Xcode compile, so adding, moving, deleting, or generating a source needs no Helix
file list or policy update. Generated Bridge code remains in DerivedData.
Keep Helix open and use Xcode Run. The installed Scheme action registers the
finished App, while the automatic runtime discovers and authenticates the local
Hub. No LLDB file, launch variable, host address, pairing secret, runtime import,
or initialization call is required.

Project: `HelixDemo.xcodeproj`
