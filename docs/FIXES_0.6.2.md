# Correctness audit — 0.6.2

- Ordinary rotation edits could vanish after very large stored angles. Angle composition and linked-component relative frames now use equivalent bounded phases.
- Duplicating an ordinary subgroup within a component could reuse component-part identities and fail or alias linked geometry. New local parts get fresh identities; copied component instances retain legitimate links.
- Panning could exceed the saved-camera target range and make the view unsaveable. Invalid candidate movement preserves the prior valid camera and reports the range.
- Switching views could accumulate unintended camera roll because SceneKit reused the previous up vector. Camera updates now use an explicit stable world-up reference, with a vertical-view fallback.
- Horizontal or zero-motion orbit gestures tilted Front/Right views despite no vertical input. They now preserve pitch; existing vertical drag limits are unchanged.
- Orbit gestures could disappear at very large saved yaw values. Small pointer deltas now compose with the correct trigonometric phase.
- EPS/SVG exports could emit converted coordinates outside their own reader's bounds. They now preflight emitted values before replacing output.
- PDF transparency, masks or blending could silently become ordinary CNC cut paths. Unsupported graphics states reject; opaque inputs remain supported.
- Finite raw UVs could overflow after material size/rotation. Validation checks actual per-triangle paint transforms, including implicit planar projection, while leaving large untextured regions supported.

Each retained defect has regression evidence. The combined checks include real SceneKit transform and camera-up regressions, material overflow controls and actual PDF graphics-state input. Final full-suite/native verification is recorded below. Prior separate-item Woodwork behavior remains required; supported format limits are in FORMAT_MODES.md.

Final suite: 382 tests pass with zero failures and no native-test skips (`/private/tmp/sketchmake-062-verified-tests.log`). The native texture-rejection check left the existing ten-object model intact. Native camera QA now shows an upright Front view, followed by a horizontal orbit that saves yaw -0.4 and preserves pitch 0.001. The saved ten-object project is in artifacts/exports/Camera audit 0.6.2.sketchmake.json. The release build succeeds; the extracted v0.6.2 ZIP passes strict deep code-signature verification, and both bundled native helpers pass actual file operations.

Delivery build log: /private/tmp/sketchmake-062-delivery-build.log. Woodwork separate-item and native SketchUp compatibility regressions remain green in the full suite.
