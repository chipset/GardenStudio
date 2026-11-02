# Native SketchUp exchange, bridge and local Ruby scripting

## Native SKP / SKM exchange

Sketch Make reads and writes native SKP/SKM files through a compatible **separately installed SketchUp SDK** in its disposable SketchNativeWorker helper process. The app ships its helper, without copying or redistributing vendor framework libraries. The Compatibility window reports native SKP availability after the helper probes the installed SDK.

SDK discovery checks the SketchUpAPI framework in Cinema 4D 2026, 2024 and 2023, then Adobe Dimension. To prefer another compatible installation, set SKETCHUP_SDK_PATH to the **framework binary**, for example `/path/to/SketchUpAPI.framework/Versions/A/SketchUpAPI`, before launching the app. Restart after changing SDK configuration. An incompatible or missing SDK/helper leaves the Ruby bridge available as a fallback.

Use model Import/Export for SKP. Exports target the SketchUp 2017 file version. This exchanges static faces, loose edges, world transforms, basic face/inherited colors and supported diffuse texture/UV data. Group names and material buckets become flattened geometry; editing hierarchy, linked component definitions, cameras, tags, undo history and extension data are not recreated. Native files and worker responses are bounded, validated and processed in a private temporary workspace.

Use the **Materials panel** for SKM Import/Export. SKM stores a material, not model geometry. Import loads the material for editing; Apply Material applies it to the current selection. The supported subset is one opaque color/PNG/JPEG material with a single physical repeat size. Unequal-axis repeat sizes, texture rotation and per-face assignments reject rather than silently changing appearance.

Automated SDK roundtrips verify actual SKP physical geometry bounds and colors, and SKM color, texture pixels and a 0.375 m repeat size. This does not establish preservation of every third-party SKP/SKM feature or a complete original SketchUp project.

## Optional Make-side Ruby bridge

The included bridge runs inside an existing SketchUp Make 2017 (or newer desktop SketchUp) installation, so SketchUp performs native file reading/writing. Use it when the local SDK/helper is unavailable or the workflow should run inside SketchUp. Installing the bridge does not grant an external service access to your model.

In Sketch Make, use **Install SketchUp Bridge…** to save the included `model_script_bridge.rb` to a location you select. To load it for a session in SketchUp, open **Window → Ruby Console** and run:

```ruby
load '/absolute/path/to/model_script_bridge.rb'
```

Alternatively copy the file to your user SketchUp Plugins directory and restart SketchUp. The app does not silently modify your Plugins directory or settings. SketchUp's own extension loading policy still applies.

The **Extensions → Sketch Make Bridge** menu provides:

- **Import Sketch Make JSON**: adds a group containing the JSON model's shapes to the current SketchUp model. Then use SketchUp **File → Save As** to write a native `.skp` file.
- **Export Sketch Make JSON**: flattens visible SketchUp faces and loose edges, honoring nested group/component transforms and basic face/inherited colors. Open the output JSON through Sketch Make **File → Open**. To read a `.skp` file, first open it in SketchUp and use this bridge export.
- **Import SketchUp Material (.skm)**: loads a native SKM into SketchUp and makes it the current material. Apply it in SketchUp before bridge JSON export; only its base RGB color transfers to Sketch Make.
- **Export Current Material (.skm)**: saves SketchUp's current material as native SKM, including SketchUp-managed texture data when present. This material stays in the SketchUp workflow; the bridge JSON does not transport texture images.

Coordinate conversion: SketchUp inches/Z-up become Sketch Make meters/Y-up: `(x,y,z) → (x,z,−y) × 0.0254`. Reverse conversion is applied on import. Entity rotations and nested SketchUp transforms are applied to geometry.

Limits: 16 MB bridge JSON; 50,000 objects; at most 250,000 vertices per exported face/mesh. Exported face meshes are independent objects; group names transfer, but hierarchy, linked component definitions, editing history, dimensions, guides, scenes, face-specific texture UVs and materials beyond base RGB do not. Imported Sketch Make objects become groups, not native parametric SketchUp equivalents. Hidden entities/layers are skipped. Very small faces remain subject to SketchUp's modeling tolerance. Unsupported/malformed import aborts its SketchUp undo operation rather than leaving a partial group.

## Local Ruby procedural scripts

**Run Ruby Script…** executes an explicitly selected trusted local Ruby file using `/usr/bin/ruby`. It provides a small creation API for procedural model building, **not the SketchUp Ruby runtime**. Existing third-party SketchUp extensions are not compatible merely because they use `.rb`.

Supported subset:

- `Sketchup.active_model.entities.add_line([x,y,z], [x,y,z])`
- `entities.add_face([[x,y,z], ...])` for convex, coplanar polygons
- `face.pushpull(distance)` along the polygon's winding normal
- `face.material = '#RRGGBB'`
- `entities.add_group`, `group.name = 'Name'`, `group.entities`, `group.move!([x,y,z])` (absolute translation)
- Length helpers: `10.inches`, `2.feet`, `30.mm`, `20.cm`, `1.m`
- `model.start_operation(...)` / `commit_operation` accepted as no-ops
- `SketchMake.document` exposes the input JSON object for explicit custom workflows; the returned document is validated by Swift.

Creation API coordinates and distances are **inches/Z-up**, consistent with SketchUp Ruby geometry. Existing input document entities remain unchanged, and created geometry is appended as mesh objects. `puts` output is routed to diagnostics, preserving the JSON response.

Example:

```ruby
model = Sketchup.active_model
part = model.entities.add_group
part.name = 'Ten by twenty inch block'
face = part.entities.add_face([[0,0,0],[10,0,0],[10,20,0],[0,20,0]])
face.material = '#A27650'
face.pushpull(3)
```

Scripts have normal local Ruby file/network/process access. Run only scripts you trust. The app passes a minimal environment rather than inheriting credentials. Execution defaults to 10 seconds (configurable 0.1–60 seconds via the Swift API), with 16 MB response/256 KB diagnostics limits. The runner process is terminated on timeout/overflow. These limits are not an OS sandbox and do not supervise arbitrary subprocesses created by a script. Scripts run in a disposable temporary working directory; absolute file paths should be used for intentional external writes.

## SDK inspection and evidence

The originally inspected Make 2017 SketchUpAPI framework is x86_64-only. The current direct route instead discovers a compatible separately installed SDK and tests it through the helper; the inspected 2017 framework is not bundled as an Apple Silicon reader. The [official C API documentation](https://extensions.sketchup.com/developers/sketchup_c_api/sketchup/index.html) describes native SDK access. Native SDK availability depends on the installed framework and helper, not merely the presence of a .skp filename or an older SketchUp application.

The fallback bridge uses documented [Entities methods](https://ruby.sketchup.com/Sketchup/Entities.html), [Face mesh/pushpull APIs](https://ruby.sketchup.com/Sketchup/Face.html), [Materials.load](https://ruby.sketchup.com/Sketchup/Materials.html#load-instance_method), and [Material.save_as](https://ruby.sketchup.com/Sketchup/Material.html#save_as-instance_method), which is available starting in SketchUp 2017.

Validation includes native SDK SKP/SKM roundtrips and Ruby syntax/procedural-runner tests for extrusion, units, input-document preservation, groups/lines, diagnostics, errors and timeouts. Native SketchUp-hosted Ruby bridge operations still require a working desktop SketchUp installation and have not been runtime-tested here.
