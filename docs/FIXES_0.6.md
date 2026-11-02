# Audit fixes included with 0.6

The audit running before the Woodwork exchange request also repaired these confirmed defects:

- 2D DXF limits now check emitted millimeter coordinates. Both DXF modes preflight their reader's 50,000 emitted-object limit.
- Failed OBJ exports preserve existing mesh/material/texture resources. Unsafe filename aliases no longer overwrite another model's material files; private file permissions remain private.
- SVG fill and stroke inherit independently, including explicit `stroke="none"`.
- Applying unchanged model settings preserves exact snap spacing. New dimensions in legacy files inherit the document's display units.
- Box selection cannot be seeded by fully section-clipped geometry or clipped endpoints.
- Project export enforces the same 100 MB limit as project open/save before replacing a destination.
- Saved-scene restoration uses set membership to avoid repeated full hidden/layer-list scans.

Targeted regressions and existing workflow tests cover these changes. The [Woodwork exchange guide](WOODWORK_STUDIO.md) documents the new separate-item format and its bounds. The integrated suite passes 336 tests with zero failures. Release build, native Woodwork/Garden Studio roundtrip and extracted-app signature checks pass; see the exchange guide for the concrete evidence.
