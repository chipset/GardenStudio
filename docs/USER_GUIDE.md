# GardenStudio / Garden Studio user guide

**Garden Studio** is an independent native macOS 3D modeling application. It uses AppKit and SceneKit and requires macOS 13 or later. The main app is built for Apple Silicon; the native exchange helpers contain Apple Silicon and Intel code.

## Install and start

1. Open the [Releases page](https://github.com/chipset/GardenStudio/releases/latest) and download `GardenStudio-macOS.zip` from **Assets**. GitHub's automatically generated source archives contain source code, not the application.
2. Unzip the download. Move `Garden Studio.app` to Applications or another folder you own.
3. Open the app. This release is ad-hoc signed, not Developer ID signed or notarized. If macOS blocks it, attempt to open it, then use **System Settings → Privacy & Security → Open Anyway** for this app if you trust the download. Managed Macs may restrict this option.

## Make your first model

1. Press **R**, then click two points on the ground to draw a rectangle. Alternatively click once and enter `4, 3` in Measurements for a 4 m × 3 m rectangle.
2. Press **P** to Push/Pull and drag the face upward. You can also select the object and enter a height such as `250cm` in Measurements.
3. Press **Space** to select. Press **M** to move, **B** to paint, or **E** to erase. Use the outliner to select objects by name.
4. Right-drag to orbit, Shift-right-drag to pan, and scroll or pinch to zoom. **Command-0** fits the model; **Command-1** through **Command-4** select camera views.
5. Save with **Command-S**. Projects use editable Garden Studio JSON; reopening a project restores its model. Keep this project file as your editable original when exporting meshes or vectors.

Existing `.sketchmake.json` projects still open normally. New saves default to `.gardenstudio.json`; the project JSON schema is unchanged. Older SVG origin and OBJ material metadata are also supported.

## Everyday controls

| Action | Control |
| --- | --- |
| Select | Space |
| Rectangle / circle / line | R / C / L |
| Push/Pull / move / paint / erase | P / M / B / E |
| Orbit / pan | O / H |
| Cancel the current drawing or edit | Escape |
| Delete selection / duplicate | Delete / Command-D |
| Undo / redo | Command-Z / Shift-Command-Z |
| Import / export | Command-I / Command-E |

Measurements accept meters, cm, mm, ft and inches. Rectangle input is width and depth; solid input can be `4, 3, 2.5`. Circle drawing input is radius; selected-circle input is diameter. Snap spacing is configurable in Settings. Additional modeling tools, groups, components, layers, scenes and presentation options are described in [Modeling upgrade](MODELING_UPGRADE.md).

## Import and export

Use **File → Import/Export Compatibility** to see which directions are usable on this Mac. Import merges compatible geometry into the current model; Open restores a saved project. Export offers scope, material and coordinate/unit choices where supported.

- **Meshes:** use formats such as OBJ or STL. Keep OBJ/DAE texture sidecars beside the model. STL defaults to millimeters and Z-up.
- **Cutting profiles:** use DXF, SVG or vector PDF for top-view paths. These do not contain toolpaths or 3D height.
- **Native SKP/SKM:** requires a separately installed compatible SketchUp SDK. Vendor SDK libraries are not distributed with the app. Use Materials & Textures for SKM paint; the optional Ruby bridge is a fallback. See [bridge setup](MODEL_SCRIPT_BRIDGE.md) and [format limits](FORMAT_MODES.md).
- **Woodwork Studio:** use its exchange format to preserve supported independent items. See [Woodwork exchange](WOODWORK_STUDIO.md).

Native SKP exchange preserves supported static geometry and appearance and flattens hierarchy. Full SketchUp editing state, third-party Ruby extensions, native VCarve CRV jobs and CNC toolpaths are unsupported. See [interoperability](INTEROPERABILITY.md) for detailed limits.

## Cut an opening

Draw a smaller closed rectangle, circle or polygon directly on a solid face, then use **P — Push/Pull** on that shape. An inward push now removes material from the supporting solid. A shallow push makes a recess; reaching or exceeding the solid's thickness makes a through-hole without leaving a closing face at the far side.

For an exact depth, select the newly drawn shape, choose Push/Pull and enter a negative measurement such as `-100mm`. Immediately typing another depth replaces that same cut, so you can deepen a recess into a through-hole after dragging. Undo restores the solid and drawn shape together; Escape cancels an uncommitted drag.

This operation supports retained extrusion end faces and rectangular-block side faces, within the same editing group. Locked or ambiguous overlapping targets reject the edit. Arbitrary imported meshes and additional independent cuts into a blind-pocket mesh require more general solid modeling and remain unsupported; the app reports this instead of silently adding an overlapping solid. Through-hole results retain their extrusion profile and can accept further non-overlapping holes on the same end face.

## Build from source

Install Xcode with its command-line tools and select its developer directory. The package uses Swift tools 5.9 or later and macOS 13 or later. No external Swift packages are required for the built-in codecs.

```sh
git clone https://github.com/chipset/GardenStudio.git
cd GardenStudio
./scripts/build.sh
open "artifacts/Garden Studio.app"
```

The script builds the release executable, creates an ad-hoc signed app, and writes `artifacts/GardenStudio-macOS.zip`. On this release the executable targets the build Mac's architecture; use an Apple Silicon Mac to reproduce the published main app.

Native exchange is optional. If you have a compatible locally installed SDK, set `SKETCHUP_SDK_HEADERS` to its header directory when building. Set `SKETCHUP_SDK_PATH` to the SDK library path when running if it is outside the app's discovery locations. Build with `./scripts/build-native.sh` to diagnose SDK setup separately. These SDK/API names remain unchanged for compatibility.

The optional Woodwork worker builds automatically when its source is found at the configured local path. Set `WCORE_SOURCE_ROOT` to your WoodworkCore source directory if needed. Neither optional integration is required to build the main application.

Run the test suite:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/gardenstudio-clang-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/gardenstudio-swift-cache \
swift test --disable-sandbox --build-system native
```

Tests requiring optional SDKs or external converters may skip when those tools are unavailable. See [source provenance](REVERSE_ENGINEERING.md) for inspection background and limitations.
