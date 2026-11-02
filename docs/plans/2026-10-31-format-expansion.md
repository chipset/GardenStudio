# Compatible import/export modes

User goal: add all compatible import/export modes, centered on SketchUp Make, VCarve and common local geometry/image workflows.

Approach: retain validated DAE/DXF/STL/project support; add native OBJ/MTL, PLY/OFF, SVG, PDF vectors, EPS/legacy AI, reference images, image/view exports, KMZ, and Apple ModelIO formats detected at runtime. Add glTF/GLB and optional 3DS/FBX conversion through the already-installed Assimp tool; never install it automatically or claim it exists on another Mac. No new external package dependencies. Registry/UI reports each direction, mode, units, materials, scope and support bounds. Proprietary SKP/SKM workflows remain Make bridge; CRV/DWG/other closed formats are not falsely advertised.

Model extension: optional MeshData.textureCoordinates:[TextureCoordinate]? (u/v Double) with legacy JSON defaults. Surface material scale1 uses explicit normalized mesh UVs. Native geometry remains meters/Y-up; readers/writers explicitly convert unitless formats. All imports validate before committing, add in one undoable transaction and preserve existing content. Errors reject whole malformed files; unsupported features produce clear messages.

Parallel units:
1. OBJ+MTL import/export, ASCII/binary PLY and OFF import/export.
2. Shared VectorProfiles helper + SVG and bounded legacy EPS/AI path IO.
3. PDF vector IO + bitmap/reference import and image encoding using system ImageIO.
4. KMZ + runtime-capability Apple ModelIO 3D formats (USD/ABC).
5. glTF/GLB + optional existing Assimp converter modes.
6. DXF 3D mesh mode/common entities, ASCII/binary STL choices.
Leader integrates format registry/options/native dialogs, UV rendering, project merge, subset/visibility/projection options, capability list, packaging and end-to-end validation.

Tests first for each format; roundtrip actual asymmetric coordinates, units, transforms, materials/UVs where supported; malformed bounds/resource paths/archives reject. Preserve existing159tests. Verify generated artifacts through independent/native readers where available; show native dialog/registry. Stop only when advertised modes are functional, tested, packaged and limitations accurate.
