# SketchUp Make and VCarve exchange

See the current [directional format matrix and controls](FORMAT_MODES.md) for all available modes and precise support bounds. File → Import/Export Compatibility reports the codecs/converters usable on this Mac.

## SketchUp Make 2017

When a compatible local SketchUp SDK and the app helper are available, use Import/Export for native SKP static geometry. SKP export targets the 2017 file version. Native exchange retains supported faces, loose edges, world transforms, basic colors and diffuse texture/UV data; group names/material buckets are flattened. SketchUp editing hierarchy, cameras, tags, undo state and extension data are not transferred. Save an editable Sketch Make JSON project to retain this app's project state.

For native SKM materials, open the Materials panel and use Import/Export SketchUp Material. Import loads a material into the editor; Apply Material paints the current selection. A single opaque PNG/JPEG texture and equal-axis physical repeat size are supported. Rotation, per-face overrides and unequal-axis texture sizes reject. SKM is not a 3D model file.

[SDK discovery and setup](SKETCHUP_BRIDGE.md) covers separately installed Cinema 4D/Adobe Dimension frameworks, the SKETCHUP_SDK_PATH override and the helper. No vendor libraries are shipped with Sketch Make.

COLLADA DAE remains a portable route for static geometry, diffuse colors, texture sidecars and UVs; enable triangulation in the source. Keep the generated texture folder beside a DAE. KMZ packages those resources into one file, with no claim of georeferenced placement. Nonidentity KML model scale/orientation must be flattened before import. In Make, use File → Export → 3D Model → COLLADA; import that file here. For the return route, export DAE/KMZ here and import it in Make.

The [Make-side Ruby bridge](SKETCHUP_BRIDGE.md) remains available when the compatible SDK/helper is missing or a SketchUp-hosted workflow is preferred. SketchUp itself then opens/saves SKP/SKM files and exchanges the supported geometry through bridge JSON.

Free desktop Make's formats differ from Pro and modern subscriptions. [Official SketchUp export API](https://ruby.sketchup.com/Sketchup/Model.html#export-instance_method), [COLLADA guide](https://help.sketchup.com/en/sketchup/importing-and-exporting-collada-files).

## VCarve vectors

Use SVG, supported ASCII DXF, vector PDF, or bounded plain EPS/legacy AI paths. These exports contain explicit top-view contours/holes, not solid height or CNC toolpaths. Convert text to paths/outlines in the originating application. Image/reference modes do not trace vectors.

DXF respects declared import units, with unitless files defaulting to mm; output is declared mm. Supported entities include 3D faces/polyfaces, ellipse arcs and rational control-point splines. Unsupported blocks, fit-only/discontinuous splines, binary DXF and DWG produce explicit errors.

[Official VCarve file formats](https://docs.vectric.com/docs/V12.0/VCarveDesktop/ENU/Help/form/file-types/index.html).

## VCarve 3D

Use binary/ASCII STL, OBJ, triangle DXF or optional 3DS. STL defaults to mm/Z-up; choose the same units in VCarve's Import Component / 3D Model dialog. OBJ defaults to meters/Y-up unless overridden. Optional converter files contain static surfaces/basic colors only.

VCarve's documented vector exports do not imply a general 3D mesh exporter. Native CRV/toolpath data are not recreated here. [Official Vectric 3D format list](https://vectric.zendesk.com/hc/en-us/articles/31400661924125-What-3D-File-Formats-does-Vectric-Support).

## Other static exchange routes

3MF and AMF carry static triangle geometry and opaque flat colors with physical units and supported build/component or constellation transforms. They do not recreate slicer jobs, printer settings or toolpaths. VRML 2/WRL and XML X3D support indexed static faces/lines, transforms, diffuse colors and UVs; scripts, animation and external texture resources reject. USDZ packages a native USD root layer with stored, 64-byte-aligned members; import supports contained PNG/JPEG textures, while textured export rejects. See the [format matrix](FORMAT_MODES.md) for the exact subset and runtime dependencies.

All imports validate before committing and are undoable. SDK SKP/SKM and native/local codec roundtrips are tested; original SketchUp Make and Windows VCarve application sessions remain unverified.
