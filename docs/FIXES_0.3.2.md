# Audit fixes — 0.3.2

This patch addresses the seven additional defects reproduced in the v0.3.1 audit.

1. **Outliner clipboard routing.** The geometry outliner forwards Copy, Cut, Paste and Select All to the viewport's geometry responder. Selecting a row no longer disconnects the commands. Geometry Select All respects visibility and editing context; measurement-field text editing remains standard.
2. **Drawing-order-independent nested profiles.** A newly enclosing planar face subtracts existing coplanar interior regions, preserving their identities, appearances and holes. Inner-first and outer-first squares now give the same total area 16, without overlapping faces. Disjoint interior regions, nested contours, hidden objects and editing groups have regressions. Touching/overlapping contours that require merging reject atomically.
3. **Action-specific component synchronization.** Material and geometry edits propagate independently of the currently selected Move/Rotate/Scale tool. Explicit instance transform transactions retain independent transforms, and baked scale retains its unique-definition behavior.
4. **Explicit camera-history intent.** Each undo/redo transition records whether the action changed the view. Multiple geometry undos/redos preserve the current live camera; explicit scene/camera/projection actions restore their captured views. Tests cover interleaved geometry, navigation and camera edits.
5. **Atomic malformed COLLADA import.** Referenced raw meshes are validated before SceneKit can silently discard them. Float tables, accessor ranges, tuple offsets, position/normal/UV indices, primitive counts and polygon counts are checked. The malformed two-object/index 999 fixture rejects as a whole instead of importing only its valid sibling. Unsupported primitive/layout forms that native SceneKit silently drops now produce errors.
6. **Nonzero small dimensions.** Values below 0.01 in the selected display unit retain three significant digits, with a scientific fallback for extreme small values. A 1 mm dimension in meter units displays 0.00100 m rather than 0.00 m; ordinary two-decimal formatting remains.
7. **Scale-aware clipping.** The far plane follows cached visible-model bounds and camera distance. A 10 km model remains inside the depth range after Fit; scrolling no longer jumps the fit distance to 1500 m. Translated models, manual views, invalid camera input and millimeter models are covered.

## Validation

The complete suite has 159 tests, all passing. Native packaged-app verification left focus in the outliner: Cut/Copy/Paste stayed enabled, Copy/Paste changed 10→11 objects, Cut 11→10, and Undo 10→11; accessibility confirmed table focus throughout. New tests were first observed failing against the original behavior. Coverage includes outliner focus and text editing, multiple mixed undo/redo transitions, material synchronization across tools, planar drawing order, malformed DAE streams, units and camera depth ranges.

The patch preserves project JSON compatibility and existing exchange workflows. Original SketchUp Make and Windows VCarve runtime integration remain outside local verification; the feature boundaries in MODELING_UPGRADE.md still apply.
