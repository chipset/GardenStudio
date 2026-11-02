# Correctness audit — 0.6.1

Confirmed defects repaired:

- Closing an unsaved window could prompt again during automatic app termination. Close approval now applies once to the current document revision; changing the document or cancelling invalidates it.

- Deleting geometry during an active move and then cancelling could resurrect the old viewport snapshot. Edit commits now terminate old drags; parent-driven Delete and Undo have the same protection.
- Very large finite angles produced incorrect or NaN SceneKit transforms. Rendering and native Woodwork export now use the trigonometric phase used by core geometry instead of lossy angle conversion/remainders.
- Fit could create a camera outside the saved-camera contract and prevent saving. Out-of-range fits now preserve the prior valid view and report the limit.
- Double-finite coordinates and UVs could become infinite renderer buffers. Validation checks Float32 representation and actual placed primitive/mesh positions without adding a real-world-size cap.
- Duplicate component-part IDs within a single component instance allowed ambiguous linked updates. Such malformed identity data now rejects; shared IDs across linked instances remain supported.
- Tiny finite SVG arc radii caused a NaN-to-integer trap. Stable radius correction and finite checks prevent the crash while preserving representable arcs.
- glTF booleans/malformed optional numeric arrays were silently interpreted as indices, transforms or defaults. Numeric/boolean layouts now validate strictly.
- Duplicated native Woodwork meshes could expand into costly JSON before their global budget was checked. Aggregate geometry limits now run before signatures/serialization.
- Valid long native material names could prevent Woodwork import. The bounded editor label retains the exact native value for unchanged roundtrips, including JSON save/open.

Woodwork items remain independent, without forced assemblies or combined meshes. Its documented shape/material bounds remain in [WOODWORK_STUDIO.md](WOODWORK_STUDIO.md).

The final combined suite passes 363 tests with zero failures and no native-test skips. Native UI checks imported the formerly crashing SVG arc and roundtripped two independent Woodwork parts with exact 261-character material labels. The rebuilt native app closes after exactly one Discard click. The v0.6.1 release build and extracted ZIP strict deep code-signature check pass. Both bundled helpers pass actual native read/write checks; Woodwork separate-item identity and exact material names remain intact.

Final suite: /private/tmp/sketchmake-061-final-tests.log. Delivery build: /private/tmp/sketchmake-061-delivery-build.log. Native roundtrip example: artifacts/exports/Woodwork long labels 0.6.1.woodwork.
