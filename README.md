# Garden Studio

Native macOS 3D modeling for designing studios, buildings and other models.

[Download the latest release](https://github.com/chipset/GardenStudio/releases/latest) · [Installation and user guide](docs/USER_GUIDE.md) · [Release notes](docs/RELEASE_0.6.6.md)

Version 0.6.6 completes the Garden Studio naming across the app, source modules, exported metadata and release package.

Version 0.6.5 renames project-owned source files and identifiers, and adds installation, usage and build documentation.

Version 0.6.4 fixes linked-component topology matching and updates the current feature limits. [Audit details](docs/FIXES_0.6.4.md).

Version 0.6.3 fixes scale/texture preservation, numeric drawing state, face-paint state and reference/vector import defects. [Audit details](docs/FIXES_0.6.3.md).

Version 0.6.2 repairs rotation/component edits, camera gestures, texture transforms and vector-file boundaries. [Audit details](docs/FIXES_0.6.2.md).

Version 0.6.1 fixes edit cancellation, renderer numerics, SVG/glTF input validation and Woodwork exchange edge cases. [Audit details](docs/FIXES_0.6.1.md).

Version 0.6 adds [Woodwork Studio import/export](docs/WOODWORK_STUDIO.md), preserving each object as an independent native item without forced assemblies. [Included audit fixes](docs/FIXES_0.6.md).

Version 0.5.2 fixes Follow Me placement, line editing/rendering, connected face picking, material application errors and additional file-exchange defects. [Follow-up audit](docs/FIXES_0.5.2.md).

Version 0.5.1 repairs modeling, project lifecycle, material precision and native/exchange-file correctness defects. [Audit fixes and verification](docs/FIXES_0.5.1.md).

Version 0.5 adds native SketchUp SKP/SKM exchange through a separately installed compatible SDK, 3MF/AMF and VRML/X3D codecs, and aligned USDZ package export. The format catalog reports the directions usable on this Mac. [Format matrix and limits](docs/FORMAT_MODES.md) · [Previous audit fixes](docs/FIXES_0.3.2.md).

An independent native macOS 3D modeling app inspired by SketchUp Make 2017, built with Swift/AppKit/SceneKit. Built-in exchange codecs need no external packages. Native SketchUp exchange uses a separately installed SDK; optional static-format conversion uses a separately installed Assimp tool. Apple Silicon build: artifacts/Garden Studio.app, macOS 13+.

Launch by opening `artifacts/Garden Studio.app`. A clean distributable ZIP is also available at `artifacts/GardenStudio-macOS.zip` (unzip before launching). Build with `./scripts/build.sh` using Xcode's Swift toolchain. Source code is in `Sources/GardenStudioApp`; geometry, documents and OBJ export are in `Sources/GardenStudioCore`.

## Modeling

- **R** rectangle, **C** circle, **L** line: click start and end on the ground. Live preview; Escape cancels. Alternatively click once and enter dimensions in Measurements.
- **P** push/pull: drag an object vertically, or select it and enter a height.
- **M** move, **B** paint, **E** erase, **Space** select. Materials apply to objects or selected faces. The outliner selects objects; Delete removes selection and Command-D duplicates.
- **O** orbit, **H** pan. Right-drag orbits; Shift-right-drag pans. Scroll or pinch zooms. Command-1 through Command-4 switch camera views; Command-0 fits.
- Measurements accept meters, cm, mm, ft and inches. Rectangle dimensions: `4, 3`; selected solid dimensions: `4, 3, 2.5`; push/pull height: `250cm`. Circle drawing input is radius; selected circle input is diameter. Snap spacing is configurable in Settings (default 1 mm), with point/axis inference.
- Command-Z / Shift-Command-Z undo/redo. File supports New/Open/Save/Save As and the exchange modes listed in Import/Export Compatibility. Unsaved changes prompt before closing/replacing a model.

Projects use editable Garden Studio JSON. Open restores the full project; Import merges geometry/organization in one undoable step. OBJ now imports and exports diffuse materials, images, colored lines and UVs.

## Exchange with SketchUp Make and VCarve

Use **Import** (Command-I) for compatible meshes, vectors, archives, projects and scaled reference images. **Export** (Command-E) offers encodings, whole/visible/selected scope, material choices, and units/up-axis for unitless meshes. **File → Import/Export Compatibility** shows the directions available on this Mac.

- **SketchUp Make:** import/export native SKP static geometry when the compatible SDK/helper is available; exports target SketchUp 2017. Import/export SKM materials in the Materials panel. DAE/KMZ and the Make-side Ruby bridge remain fallback routes. Keep DAE/OBJ texture sidecars together. Explicit UVs survive supported formats.
- **VCarve vectors:** use DXF profiles, SVG, vector PDF or supported plain EPS/legacy AI paths. These contain top-view paths, without height or toolpaths.
- **VCarve 3D:** use binary/ASCII STL, OBJ, triangle DXF or optional 3DS. STL defaults to millimeters/Z-up. VCarve is not claimed to export general 3D meshes; return vectors through DXF/SVG/PDF.

[Detailed exchange guide and limits](docs/INTEROPERABILITY.md). Native SKP exchange preserves supported static geometry and appearance; editable Garden Studio projects remain JSON. Native `.crv` jobs and CNC toolpaths remain unsupported.

## Modeling upgrade (0.3)

The app now includes polygon/arc/freehand/rotated rectangles, connected profile faces, cuts/holes, arbitrary-plane extrusion, snapping/guides, rotate/scale/mirror/arrays, multi-selection, nested groups, linked components, layers/locking, Offset and Follow Me. Materials include embedded textures and face assignments. Scenes, projections, styles, shadows, section cuts, dimensions/text, exportable 3D text, PNG output and native printing are available.

[Full controls, feature bounds and validation](docs/MODELING_UPGRADE.md). [Native-file bridge and Ruby automation](docs/MODEL_SCRIPT_BRIDGE.md).

This remains an independent implementation. Native SKP/SKM files are read and written by a compatible locally installed SketchUp SDK in a helper process; vendor libraries are not bundled. SKP exchange flattens hierarchy and does not preserve editing state, cameras, tags or extension data. Linked component part additions and deletions synchronize inside the app. Mesh vertex dragging is available, but full solid/face deformation, full affine component frames and third-party SketchUp Ruby extensions remain unsupported.

Run tests:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/gardenstudio-clang-cache SWIFT_MODULECACHE_PATH=/private/tmp/gardenstudio-swift-cache swift test --disable-sandbox --build-system native
```

REA inspection details, original-app source provenance and limitations are in `docs/REVERSE_ENGINEERING.md`; portable evidence bundles are alongside it.
