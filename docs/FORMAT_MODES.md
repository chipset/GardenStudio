# Import/export modes — 0.5

The File → Import/Export Compatibility window is the authoritative directional catalog for the current Mac. It distinguishes built-in codecs, native system codecs, optional installed SDKs/converters, reference images and unsupported native containers. Compatibility means supported geometry exchange, not preservation of every feature of the originating application.

## Mode matrix

| Format/mode | Import | Export | Content and bounds |
| --- | --- | --- | --- |
| Sketch Make JSON | Yes | Yes | Full editable project with profiles, materials/UVs, groups/layers and presentation. Open restores everything; Import merges geometry/organization. |
| Woodwork Studio `.woodwork` | Yes, bundled helper | Yes, bundled helper | Separate items, not assemblies. Native detailed parts import and return while geometry is unchanged; new rectangular/circular stock exports. Inch/meter conversion, native names and placement. [Guide and limits](WOODWORK_STUDIO.md). |
| COLLADA 1.4.1 DAE | Yes | Yes | Static triangles/lines, transforms, colors, face materials, PNG/JPEG textures and UVs. Meter/Y-up metadata. Keep generated texture folder beside file. |
| KMZ | Yes | Yes | KML + COLLADA + texture package. Geometry exchange; georeferenced placement is not applied. Nonidentity local Scale/Orientation reject with flattening guidance. |
| OBJ + MTL | Yes | Yes | Polygons, lines, diffuse colors, PNG/JPEG, UV seams and safe sidecars. Negative indices and concave polygons supported. Diffuse colors/images are the supported appearance subset. Nonopaque d/Tr values and map_d opacity maps reject; specular and refractive properties are not preserved. |
| STL binary / ASCII | Both | Both | Triangles only, no lines/colors/textures. Default mm/Z-up; unit and Y/Z-up choices. |
| PLY ASCII / binary | Both, both endiannesses | ASCII / little-endian binary | Geometry/RGB colors; nonopaque alpha rejects. Differing vertex colors become flat corner regions rather than gradients. Textures unsupported. |
| OFF | ASCII | ASCII | Geometry only; COFF and advanced attributes reject. |
| glTF 2 JSON / GLB 2 binary | Both | Both | Static transforms, surfaces/lines, basic colors, PNG/JPEG and UVs. Texture tiling/rotation bakes into UVs. JSON assets are embedded; GLB is self-contained. Skins/animation/morphs/extensions reject. Scene nodes must form a bounded forest; distinct nodes may instance a mesh. Clamp/mirror wrapping and some opacity/high-bit-depth alpha layouts reject rather than lose appearance. |
| USD / USDA / USDC | Where native codec works | Where native codec works | Flattened static triangle meshes, declared units/up-axis, transforms, diffuse colors and UVs. Contained PNG/JPEG texture import; scalar material opacity rejects. Textured export rejects instead of losing images. |
| USDZ | Where native USD reader works | Where native USDC writer works | Stored ZIP with the default USD layer first and every file payload aligned to 64 bytes. Static meshes, colors and UVs; contained PNG/JPEG texture import. Textured export rejects. |
| 3MF | Yes | Yes | Core OPC package with triangle meshes, build/component transforms, declared physical units and opaque base/flat face colors. Export mm/Z-up. Textures, gradients, production/beam/slice extensions and slicer project data reject. |
| AMF | XML or single-member ZIP | XML | Static triangle volumes, declared physical units, opaque flat colors and nested constellation transforms. Export mm/Z-up. Curves, textures, gradients, composite/formula materials and transparency reject. |
| VRML 2 / WRL | Yes | Yes | UTF-8 static indexed faces/lines, nested transforms, DEF/USE, diffuse and flat face colors, explicit UVs. Default meters/Y-up. Texture resources, scripts, animation and authored smoothing/normal arrays reject. |
| X3D XML | Yes | Yes | Static indexed scene subset shared with VRML, including transforms, diffuse colors, lines and UVs. Length declarations supported; default meters/Y-up. No scripts, routes, external resources, texture images or custom normals. |
| DXF profiles | Yes | Yes | mm top contours/holes. LINE/CIRCLE/ARC, 2D/3D polylines, bulges, ellipse arcs and supported rational control-point splines. Blocks and binary DXF reject. |
| DXF triangle mesh | Auto-detected | Yes | 3DFACE surfaces/polyfaces/3D polylines and edges; export mm/Z-up 3DFACE + LINE. |
| SVG profiles | Yes | Yes | Physical-size top outlines; paths including curves/arcs, shapes and transforms. Tessellated geometry; no text, CSS/effects, scripts or external resources. |
| PDF vector profiles | Selected page | Yes | Physical-point paths and form transforms. Text must be outlined. Images, clipping and shading require reference-image mode. |
| PDF reference | Selected page | Current-view image PDF | Scaled embedded page image; no geometry tracing. Current-view PDF is raster, distinct from vector PDF profiles. |
| EPS / legacy AI paths | Restricted | Yes | Plain physical-point paths. No executable PostScript prologs/procedures. PDF-based AI can use PDF vector/reference modes; modern editable Illustrator structure is not preserved. |
| PNG/JPEG/TIFF/BMP/GIF/JPEG2000/TGA/PSD/HEIC/AVIF/EXR/WebP | Where ImageIO reader works | Only verified working ImageIO writer | Import static selected frame as embedded reference; export current view. HEIC and other service-backed encoders may be unavailable in restricted environments. |
| ICO / ICNS | Where ImageIO reader works | Where writer works | Current view letterboxed into a supported256 × 256 icon canvas. |
| Other ImageIO types, including supported RAW | Conditional reference import | Not implied | Selected frame, orientation normalized, chosen physical width, bounded dimensions/embedded PNG size. Not vector tracing or animation. |
| 3DS / ASCII FBX / DirectX X | Optional, sandbox required | Optional installed Assimp | Static triangle surfaces/basic colors. Export parses only app-authored self-contained GLB and validates the tool's generated result. No automatic installation; no texture/animation support. |
| SketchUp SKP | Installed compatible SDK/helper | Installed compatible SDK/helper | Native static faces/lines, transforms, basic colors and supported diffuse textures/UVs. Export SketchUp 2017. Group names/material buckets transfer as flattened geometry, using front-face appearance. Projective texture Q mappings reject with bake guidance; exports preflight the reader's 250,000 expanded-vertex limit. Separate back-face paint, hidden/tag visibility, editing hierarchy, cameras, history and extension data do not transfer. |
| SketchUp SKM material | Materials panel, SDK/helper | Materials panel, SDK/helper | One material, with opaque PNG/JPEG texture support and a single equal-axis physical repeat size. Rotation and per-face assignments reject; this is a material workflow, not model geometry import. |
| CRV, V3M/V3D/PVC jobs/toolpaths, DWG | No direct codec | No direct codec | Use the originating application to produce a compatible exchange format. |
| Alembic ABC | Not offered here | Not offered here | Native capability flags existed but actual roundtrip failed, so the mode is not advertised. |

## Controls

Import adds data in one undoable operation and leaves existing content intact if decoding fails. Unit override applies to unitless meshes and supported vector inputs; declared DAE/glTF/metadata formats normally use their own units. Pick Y-up or Z-up for unitless meshes. PDF page/image frame is 1-based. Reference width accepts units, for example 100mm.

Export scope is whole model, visible objects or selected objects. Scoped projects retain their project name, units, snapping and presentation settings while including only the chosen geometry and relevant organization. Disable materials/textures for explicit geometry-only exchange. Image modes capture the current viewport, including presentation, and ignore geometry scope. Lossy image quality is adjustable.

Default OBJ/PLY/OFF coordinates are meters/Y-up. Default STL is mm/Z-up. DXF output is declared mm with model (x,y,z) mapped to(x,-z,y); profiles flatten height. glTF is meters/Y-up. SVG has physical-mm dimensions; PDF/EPS use physical points. Use the target application's unit setting when reading unitless files.

Explicit model UVs use the renderer/glTF top-origin convention. OBJ and COLLADA conversions repair their V-axis convention; texture repeat/rotation is baked where needed. Unsupported material features fail or are restricted as listed, rather than claiming full PBR/CAD semantics.

## Reliability and portability

Referenced resources must be bounded and local. Malformed mesh/accessor/index data rejects before native decoders can silently discard an object. Archives validate member paths, sizes, duplicates and symlinks before bounded extraction. USDZ/3MF/AMF packages also validate CRCs and reject path-changing ZIP metadata. Parsers do not execute SVG scripts or PostScript programs.

Apple USD modes also require the installed system usdcat utility. USDZ uses the bounded archive reader and a stored, 64-byte-aligned package writer; generated packages are checked with independent OpenUSD tools.

Native SKP/SKM modes require the app helper plus a compatible separately installed SketchUpAPI framework. Discovery checks Cinema 4D 2026/2024/2023 and Adobe Dimension installations; SKETCHUP_SDK_PATH can select a framework binary. Only the app helper is shipped, with no vendor SDK libraries. See [native setup and fallback bridge](SKETCHUP_BRIDGE.md).

Optional Assimp imports remain disabled when its required resource sandbox cannot be created. Optional exports can still work because their only input is the app's private, self-contained GLB; generated output is reconverted and checked before the destination is committed.

Native project compatibility does not imply that every exchange mode is accepted by Make or VCarve. For Make 2017 use native SKP when the compatible SDK is available, or DAE/KMZ as a fallback; for VCarve choose SVG/DXF/PDF vectors or STL/OBJ/triangle DXF/3DS models. [SketchUp DAE documentation](https://help.sketchup.com/en/sketchup/importing-and-exporting-collada-files), [VCarve vector formats](https://docs.vectric.com/docs/V12.0/VCarveDesktop/ENU/Help/form/file-types/index.html), [Vectric 3D import formats](https://vectric.zendesk.com/hc/en-us/articles/31400661924125-What-3D-File-Formats-does-Vectric-Support).

Validation covers asymmetric dimensions, transforms, units, binary layouts, colors/UVs, image pixels, contained resources and malformed sibling rejection. Native SKP tests compare actual SDK roundtrip geometry bounds and colors; SKM tests compare color, texture pixels and a 0.375 m repeat size. USDZ tests check every payload alignment, native roundtrips, contained textures, CRC/path rejection and independent usdcat/usdchecker results. Native QA covers reference-image sizing, exchange controls, current-view output and validated optional exports. Examples are in artifacts/exports. An independent read through the original Make 2017 Intel SDK under Rosetta also passes. Actual SketchUp Make and Windows VCarve application sessions remain unverified.

Editable JSON group nesting is limited to 256 levels to bound hierarchy processing.
