# SketchUp Make and VCarve exchange

Goal: bidirectional file workflows that retain geometry and scale, exposed through native Import and export format choices. No new external dependencies.

Formats: DAE for SketchUp Make 3D import/export; ASCII DXF for VCarve 2D vector import/export; STL for VCarve 3D model import/export; existing OBJ export retained. Proprietary SKP/CRV container support is not claimed.

Model: optional MeshData(vertices [Vec3], triangles [Int], lineIndices [Int]) and ShapeKind.mesh added backward-compatibly to JSON. Mesh vertices are local entity coordinates; entity origin/rotation apply as before. Primitive entities provide common triangulated geometry for exporters. Imported mesh dimensions describe local bounding extents, origin at zero; viewport uses real mesh vertices, not bounding boxes. Push/pull and dimension resizing disabled for arbitrary meshes; selection, translation, paint, deletion, duplicate, undo and save remain usable.

Tasks:
1. Tests first for backward-compatible JSON and mesh validation; implement core model/render support.
2. Independent STL mesh conversion and binary/ASCII IO; reject malformed indices/nonfinite data/oversized files and test round-trips.
3. Independent ASCII DXF profiles IO: LINE/CIRCLE/ARC/LWPOLYLINE/POLYLINE, units and closed paths, reject unsupported destructive conversions, verify fixtures.
4. Independent SceneKit-backed DAE import/export, flatten transformed node geometry with explicit Y-up/meter unit conversion, preserve basic diffuse colors; own interoperability tests.
5. Wire Import… with filter and units; export menu format chooser. Import merges as single undoable change, unique IDs and size limits, displays warnings instead of silently discarding unsupported contents.
6. Test/build/package; verify native UI controls and generate sample exports validated by independent parser/SceneKit reimport. Document steps, limits and vendor source references.

Stop condition: passing core/IO tests, packaged signed app, real native Import/export UI accessible, round-trip fixture checks; explicitly report inability to validate inside Windows VCarve or original SketchUp if not run.
