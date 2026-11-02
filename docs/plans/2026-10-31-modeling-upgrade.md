# Native modeling upgrade

User authorization: implement the missing Make 2017 feature categories listed in the preceding answer, excluding Pro-only features. Execute local reversible edits and verification autonomously.

Architecture: preserve primitive/mesh model and existing JSON compatibility. Extend entities with optional profile/material/organization metadata; documents gain optional editor state. Build geometry operations as tested core functions, viewport interactions as native controls, and shell commands as undoable edits. Existing DAE/DXF/STL/OBJ exchange remains intact. No new external dependencies.

Delivery lanes:
1. Core planar geometry: arbitrary-plane polygons, arcs/freehand profiles, holes, split faces, profile extrusion, offset and classic Follow Me sweep; robust malformed/self-intersection checks.
2. Editor model/operations: rotate/scale/mirror/arrays; multi-selection transform behavior; groups, linked component instances, layers, visibility/locking; backward-compatible JSON and command history.
3. Viewport: endpoint/midpoint/center/axis snapping, guides, configurable snap, arbitrary drawing plane/face picking, richer drawing tools, subface/profile selection and extrusion, box/multi-selection, drag transforms.
4. Presentation: scenes/cameras, orthographic view, section cut, shadows/styles, walkthrough, dimensions/text/3D text; image export/printing.
5. Materials/automation/file fidelity: texture assets and per-face materials/material library, native SKP feasibility and a tested Make-side bridge if native SDK requirements cannot be met, Ruby automation/extension compatibility boundary.
6. Integrate native shell panels/menus, add tutorials/controls documentation, compile/test, native smoke, code review, fix issues, package.

Validation: focused failing tests before new core behavior; property/roundtrip tests for profiles/transform/component state; preserve exchange tests. Build and native GUI verify representative new workflows. Clearly distinguish fully implemented features, bounded support and remaining native-format/runtime compatibility gaps; never claim complete Make parity from basic implementations.

Stop condition: requested categories have concrete implemented usable workflows, tests/build/signature/GUI evidence, and any unavoidable external-runtime blocker is explicit. Work remains active while recoverable required work exists.
