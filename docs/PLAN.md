# Sketch Make — native recreation

Goal: deliver a runnable native macOS modeler inspired by SketchUp Make 2017, informed by REA inspection of its downloaded package. Use original Swift/AppKit/SceneKit code, no external dependencies or copied proprietary assets.

Architecture: SketchCore contains Codable geometry, units and snapshot history. SketchMake is an AppKit application with a SceneKit modeling viewport, compact toolbars, inspector and native file dialogs. Native JSON project format and OBJ export; SKP compatibility and full SketchUp parity are outside this first implementation.

Success criteria: rectangles/circles/lines on ground plane, extrusion into solids, selection/deletion/move/paint, orbit/pan/zoom and standard views, dimension entry, undo/redo, save/open/export, packaged .app, passing core tests and build plus native launch smoke verification.

Tasks:
1. Download 2017 macOS DMG, record source/hash, inspect with REA, retain evidence and separate static facts from implementation choices.
2. Test then implement SketchCore geometry/document/history and round-trip validation.
3. Implement native AppKit shell + SceneKit viewport with direct modeling interactions and inspector.
4. Build app bundle, run unit tests, launch, inspect screenshot and fix visible or functional defects. Document controls and limits.

Ownership: core/model and test files may be delegated independently of viewport/shell. Main agent integrates, packages, inspects original and verifies.
