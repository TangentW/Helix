# Helix brand assets

The Helix mark is a horizontal double helix that also reads as the `x` in the
project name. The longer coral segment represents a replacement patch fitted
into the rear strand.

The checked-in SVG files are the editable masters:

- `Helix.Mark.svg` is the primary project mark.
- `Helix.Mark.Monochrome.svg` preserves the two patch seams for one-color use.
- `Helix.AppIcon.svg` uses the same geometry for the Helix Hub macOS icon.

The Hub mirrors the monochrome geometry in `HubApplication.Brand.Mark` and
renders it into an AppKit template image for the menu bar. Keep both forms in
sync when the mark geometry changes; the template image is covered by a pixel
mask regression test.

Brand colors are `#071B3D` (midnight navy), `#176BFF` (azure), and `#FF6B57`
(coral). Run `Assets/Brand/generate-app-icon.sh` after changing the app-icon
master. It deterministically refreshes the checked-in
`Hub/SupportingFiles/Helix.icns` consumed by the Hub bundle build.
