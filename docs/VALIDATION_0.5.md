# Version 0.5 verification

271 tests pass with zero failures on this Mac, including real installed-SDK operations (no skipped native tests). Release app and extracted ZIP have valid ad hoc code signatures; the own universal helper is included, vendor libraries are absent.

Native SKP tests cover physical bounds, names/colors, loose edges, textures/UVs, nested rotations, repeated and mirrored components, and reading exported files with the original Make 2017 Intel SDK under Rosetta. Native SKM tests cover color, decoded PNG pixels, physical repeat size, and explicit unsupported material rejection.

Native UI smoke tests exported Garden Studio as SKP, imported its ten objects, and imported/exported SKM paint. Final material export preserves #AB8764. Fixed the discovered material color-space drift and a macOS file-type registration conflict that disabled valid SKP selection. Imported model inspector dimensions and worker output-size enforcement also have corrections.

Additional format coverage: 3MF/AMF, static VRML/X3D, aligned USDZ packages, contained texture import, independent Assimp reads and USD checker validation. Capability and scope details are in FORMAT_MODES.md. Static exchange does not preserve full SketchUp authoring state. Native CRV/DWG jobs and Windows VCarve application runtime remain outside this verification.
