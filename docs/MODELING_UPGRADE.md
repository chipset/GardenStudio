# Modeling upgrade — version 0.3

This release adds usable workflows across the Make 2017 feature categories discussed in the task. It is an independent implementation with the bounds below, not complete SketchUp parity.

## Drawing and connected profiles

Use Draw or the scrollable tool rail. Polygon closes with Return, a double-click or a click near its start. Freehand samples a drag and closes on release. Rotated Rectangle uses three points: corner, baseline end, width. Arc uses center, start and end; it creates a tessellated wire.

Drawing begins on a picked face or the Ground/Front/Right plane. Endpoint, midpoint, center and axis inference operate in screen space; X/Y/Z constrain an axis, Shift holds alignment. Settings changes snap spacing and display units; lengths accept mm, cm, m, ft and in.

Connected line loops create faces. Lines crossing a planar profile split it; nested closed loops partition a face into an inner face and surrounding hole. Endpoints weld within tolerance and can split an existing edge. These are bounded planar topology operations rather than a full global boundary-representation kernel.

Push/Pull works on retained profiles, including concave polygons, holes, arbitrary planes and negative distances. A picked side or imported coplanar region produces an additive extrusion retaining the original source. Ctrl-drag with Move edits a flat profile vertex and matching vertices of connected flat profiles, or a selected mesh vertex while preserving face indices and UVs. Moving mesh vertices can create open or self-intersecting solids; face/edge deformation and solid validation are not implemented.

Modify → Create Face from Closed Profile turns an imported closed wire into a face. Split Face with Selected Line and Cut Hole with Selected Profile require editable targets. Complex cuts crossing a concave contour more than twice or through an existing hole reject with a message.

## Transform and organize

Shift-click toggles selection; drag empty space for box selection. The outliner supports multiple selection.

Move Precisely, Rotate, Scale, Mirror X/Y/Z and Array Copies operate on the effective selection. Rotation uses global Y and the collective center. Numeric XYZ scaling is available; drag scaling is uniform.

Make Group supports nesting. Double-click enters a group; Escape exits. Organize also has Edit Selected Group and Exit Group. Make Component links matching existing parts across copied instances. Geometry/material edits and part additions/deletions synchronize across matching instances, including nested ordinary groups; translations/rotations of whole instances stay independent. Same-named populated groups match by linked part membership; empty groups use sibling order because they have no linked contents to distinguish them.

Nonuniform scale/mirror bake geometry, clear retained parametric profiles and create unique whole-component definitions, preventing later linked edits from overwriting transformed instances. Full affine linked instance frames remain unavailable.

Layers provide visibility and assignment. Hidden/locked entities are indicated in the outliner; locked geometry resists edits. Show All respects locks. Reverse Faces handles primitives and meshes.

Offset uses planar miter joins and preserves holes/known extrusion depth. Follow Me sweeps a profile along a connected open path with transported frames and miter joints. Closed, self-crossing, doubled-back or excessively tight paths reject rather than creating overlapping solids.

## Materials and presentation

Materials & Textures opens a native library/editor: color, embedded PNG/JPEG, repeat size in meters, rotation and per-face assignment. Pick a face and select only its owner for face-only paint. Save/load reusable .sketchmaterial JSON libraries. Topology edits preserve global material but clear invalidated face overrides. Modify → Generate Planar UVs creates dominant-plane per-face coordinates and duplicates triangle corners at seams. User-authored UV islands and seam packing are unavailable.

COLLADA exchanges local texture sidecars, UVs and per-face bindings. Keep its generated texture folder beside the DAE. Imports accept bounded PNG/JPEG files below the DAE directory; network/absolute/traversal/symlink-escape resources, scripts and rigs reject.

Scenes save/restore camera, projection, explicit hidden objects and layer visibility. Parallel projection, perspective, Solid/Monochrome/Wireframe/X-Ray styles, shadows and section clipping are available. Sections clip positive plane distance; they do not change exports or generate caps.

Walk / Position Camera accepts target, yaw, pitch and distance, then Orbit/Pan navigate that viewpoint. A collision-aware first-person walk tool is unavailable.

Tape Measure creates guides. Dimension creates formatted 3D distance labels; Text creates view labels. Add 3D Text creates real tessellated glyph meshes with holes and depth, exportable to STL/DAE. PNG export and native printing capture the current view. Guides, dimensions and view labels are presentation metadata.

Drawing Axes relocates the origin. View → Set Drawing Axes accepts an origin, X direction and plane normal; the resulting orthonormal drawing frame persists with the project, not per scene.

## Files and automation

Old project JSON still opens. New JSON preserves editor state, groups/layers, profiles, materials, scenes and annotations. DXF exports retained polygon outlines and holes without triangle edges. Arbitrary surface meshes without a retained profile still require STL/DAE; the app does not infer CNC contours/toolpaths.

Native SKP/SKM workflows use a separately installed compatible SketchUp SDK in a helper process. Extensions → Install SketchUp Make Bridge saves an optional .rb script to a chosen location for Make-hosted fallback workflows. See [bridge instructions](MODEL_SCRIPT_BRIDGE.md).

Run Ruby Script supports a limited creation API for trusted local scripts. It runs asynchronously with time/output limits and undoable results, using account file/network permissions. It is not a full SketchUp Ruby extension runtime; third-party extensions still require SketchUp.

## Verification

**109 automated tests pass with zero failures.** Tests cover topology, holes, winding/volume, transforms/locks, nested selection, component safety, project compatibility, scene snapshots, material repainting, texture containment, actual text meshes, exchange formats and Ruby limits. Native checks verified expanded menus, material panel, section cuts/shadows/dimensions and a 100 mm offset changing a 5.4 × 3.8 m profile to 5.6 × 4.0 m.

The example project is artifacts/Modeling Upgrade Showcase.gardenstudio.json. Make-hosted bridge actions and Windows VCarve runtime round-trips remain unverified; those external-runtime gaps are separate from local tests/native app checks.
