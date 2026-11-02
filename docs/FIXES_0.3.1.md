# Audit fixes — 0.3.1

This patch addresses the defects reproduced in the audit. Existing projects and exchange formats remain supported.

- Primitive rendering now uses the same triangulated geometry as the model/exporters. A 1 mm primitive is 1 mm in the viewport; flat faces stay at their true plane. Picking no longer uses inflated cylinders or minimum-size boxes.
- Automatic face creation handles adjacent loops and shared edges even when the connected graph already contains cycles. Branches, vertical planes and nonplanar shortcuts are covered; duplicate boundaries do not add duplicate faces.
- Create Face from Closed Profile rejects existing faces and solids rather than flattening them.
- Group/component nesting and explode reconcile part identity against its nearest owning component. Existing component links survive unchanged ownership; changed ownership gets new identities, and leaving components clears them.
- Follow Me assembles every selected line/wire segment into one ordered open path, including reversed edges. Branches, loops, duplicate edges and disconnected selections reject atomically instead of silently dropping segments.
- Camera edits and scene restoration record the actual live view before the change. Undo/redo restores fresh-document and unsaved camera states; geometry undo preserves subsequent ordinary navigation.
- Geometry Cut/Copy/Paste and Select All now have native responder implementations. Paste creates fresh IDs and remaps layer/group/component structure; copied instances retain links within the pasted payload without linking accidentally to original objects. Cut respects locks; failed writes and malformed clipboard data leave the model unchanged. Current group editing context is preserved.
- Ruby negative extrusion produces outward-facing triangles. The Make bridge repairs mirrored winding using the full accumulated transform, including nested mirror cancellation.
- The local Ruby runner rejects self-intersecting multiple-winding faces, such as pentagrams, before generating output.
- Automatic line topology ignores hidden/layer-hidden geometry, preventing invisible snapping, cuts, hole creation or duplicate suppression.

## Regression coverage

**135 tests pass with zero failures.** The native UI implementation is now a testable GardenStudioUI module, with a small executable launcher. The normal SwiftPM test run covers native SceneKit bounds, camera history, clipboard responders and Follow Me integration in addition to core geometry and file exchange.

Tests use an in-memory clipboard transport because the sandbox test runner cannot write to the macOS pasteboard service. The packaged app uses NSPasteboard.general; native GUI clipboard transport was verified in the packaged release: Copy/Paste 2→3 objects, Cut 3→2, Undo 2→3, Select All selected all three, and undoing Paste restored two. The original pair of 1 mm objects also rendered at matching sizes.

Negative-volume checks, outward normals, nested component ownership, adjacent/branched line loops, group-aware clipboard mapping and malformed input all have regressions that failed before their fixes.

## Remaining scope

This patch does not remove the documented feature bounds in MODELING_UPGRADE.md. Direct SKP/SKM parsing and full SketchUp extension execution still use the Make-side bridge; an actual SketchUp 2017 runtime has not been used for native bridge validation. Transform/geometry doubles exercise the bridge's real mirror math.
