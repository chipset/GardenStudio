# Woodwork Studio exchange

The local Woodwork Studio application uses `.woodwork` JSON projects (schemas 1–9). Garden Studio's Import and Export menus now include this format. The export mode is **Woodwork Studio • Individual parts**.

Every Garden Studio object becomes a separate native board/item with its own UUID and name. Exported `assemblies` is empty, and every item's assembly/component membership is unset. Import also creates separate, independently selectable objects; it does not wrap them in a group or merge meshes. Existing assembly visibility and locks flatten onto the individual items.

Physical dimensions and placement convert between Garden Studio meters and Woodwork Studio inches. Full native orientations import, and moved/world-Y-rotated imported parts export using the native rotation implementation. New rectangular solids and equal-diameter circular solids export as native stock and circular-profile items. Export scope can be Whole model, Visible objects, or Selected objects.

Detailed native parts use the actual Woodwork geometry code for machining, curves, edge treatments and sweeps. Each object's original native part data survives Garden Studio JSON save/open and duplicate/paste. Unchanged geometry can return to `.woodwork` with its native construction intact. The helper verifies the geometry again before reusing that data; changed detailed meshes reject instead of turning into bounding boxes. Newly created arbitrary meshes, ellipses, lines and zero-thickness faces are not native stock items and reject explicitly.

Native material names transfer. Woodwork Studio's current palette supplies display colors; arbitrary RGB colors, embedded textures and face paint are not a native stock-material interchange feature. Textures/per-face paint reject unless materials are excluded. Project-level cabinetry/furniture generators, assembly trees, linked components, parameters, dimensions, hardware, shopping plans and saved views are not included in this individual-item mode. Keep the original `.woodwork` project for those features.

The standalone `GardenStudioWoodworkWorker` is bundled with the app and needs no runtime source checkout or third-party packages. For rebuilding it, `scripts/build-woodwork.sh` compiles the existing user-owned WoodworkCore sources; set `WCORE_SOURCE_ROOT` if their location differs. The default local source is `/Users/thomas/Documents/source/woodworking-studio/Sources/WoodworkCore`. This source tree is read-only during the build.

Both sides validate before applying or replacing files. Limits include 10,000 items, 250,000 expanded vertices, 500,000 triangles, 100 MB files and a 60-second helper timeout. Unsupported geometry leaves an existing export destination untouched.

## Verification

336 combined tests pass with zero failures and no native-test skips. The six Woodwork codec tests include vertex-by-vertex and triangle-topology checks for moved/rotated detailed parts and duplicates, plus unit, identity, circular-stock and rejection controls. The independent worker harness also covers machining, curves, sweeps and inherited visibility/locks.

Native UI roundtrip verified against a separate copy of the installed Woodwork Studio 0.9.0 app: Garden Studio exported ten objects; Woodwork displayed ten separate parts, selecting Studio selected one item, renaming it to Studio from Woodwork and saving succeeded, and Garden Studio imported all ten parts with that edit. The returned part selected independently and retained its 5.40 × 3.80 × 2.90 m dimensions. The native saved file contains ten unique board IDs, empty assemblies, and no assembly/component IDs.

The v0.6.0 release build succeeds. The extracted app ZIP passes strict deep code-signature verification, and its bundled helper reads the file saved by the native Woodwork app. Example: artifacts/exports/Woodwork individual items.woodwork. Full suite: /private/tmp/gardenstudio-060-full-tests.log. Release build: /private/tmp/gardenstudio-060-build.log.
