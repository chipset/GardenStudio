# Ordinary-workflow audit — 0.6.3

- Identity scale converted editable primitives/profiles into baked meshes and discarded editing metadata. Scale 1 now leaves the document unchanged.
- Scaling rotated textured geometry changed its implicit paint projection. Transform baking now retains original local UV mapping, including face overrides, UV seams and mirrored geometry.
- Completed/cancelled drawing previews could steer the next numeric line. New drawing operations reset direction state; zero-motion previews use the active plane direction.
- Face selections survived geometry replacement or switching away and back, allowing stale triangle indices to paint the wrong face. Picks now invalidate on relevant geometry/selection changes while paint-only updates and rigid moves preserve valid indices.
- Valid long PNG filenames and PDF page labels exceeded the paint editor's name limit and blocked reference import. Paint labels are bounded while full object/document names remain intact.
- SVG geometry with both fill and stroke set to none became unintended black CNC paths. Unpainted geometry is skipped; explicitly painted child overrides still work.

Changes have red/green regressions, including the actual renderer UV source before/after scaling. The combined suite passes 399 tests with zero failures and no native-test skips. Native UI verified scale1 keeps an editable rotated rectangle; scale2 saves explicit UVs with unchanged paint parameters; a mixed SVG adds only its visible contour; and a206-character image label imports with its full object name and a bounded200-character paint label. The saved3-object result is artifacts/exports/Workflow audit 0.6.3.sketchmake.json. Release build and extracted ZIP strict deep code-signature verification pass; both bundled native helpers pass actual file operations. Existing format limits remain in FORMAT_MODES.md; Woodwork objects remain separate individual items.

Full suite: /private/tmp/sketchmake-063-full-tests.log. Release build: /private/tmp/sketchmake-063-build.log.
