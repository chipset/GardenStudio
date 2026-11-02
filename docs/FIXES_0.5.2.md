# Follow-up correctness audit — 0.5.2

| Area | Confirmed failure | Repair |
| --- | --- | --- |
| Follow Me | An off-center section was recentered onto the path, losing its placement. | Preserve the section about the path origin; reject starts outside the section plane. |
| Group hierarchy | Extremely deep JSON group chains caused excessive ancestor traversal. | Validate a maximum of 256 nesting levels, in either storage order. |
| Line rendering | Primitive lines ignored their stored paint color. | Use the same stored line paint as mesh line geometry. |
| Line dimensions | Editing forced signed/zero components positive and reported success for a rejected zero-length line. | Preserve endpoint components; validate before commit and report failures correctly. |
| Face picking | Clicking one face selected disconnected islands on the same plane. | Flood-fill the picked connected face across physical shared edges, including UV seams. |
| Material application | Empty or fully locked selections reported successful painting. | Propagate a clear error without mutating the model; preserve normal editable-object painting. |
| USD/PLY appearance | Translucent scalar USD materials and PLY vertex alpha silently became opaque. | Reject unrepresentable opacity while preserving opaque inputs. |
| USD conversion | Cached file sizes and fast process exits bypassed the expanded-output cap. | Fresh size polling, final output check and bounded process cleanup. |
| Native SKP texture | Projective STQ mappings were flattened into affine UVs and distorted. | Reject nonconstant Q with bake guidance; retain affine positioned textures. |
| Native SKP export | Compact input could expand beyond the reader's vertex limit and replace a destination with an unreopenable file. | Preflight expanded face/line vertices before writing or replacing output. |

Each change has regression coverage, with actual native SDK/native USD-reader evidence where relevant. The combined suite passes 314 tests with zero failures and no native-test skips. Make 2017 SDK reads remain green. Release build succeeds. Native UI checks confirm empty-selection material errors, signed line dimensions (-2, 0, -1), zero-length rejection without mutation and saved endpoint/color values. The extracted v0.5.2 ZIP passes strict deep code-signature verification; its included helper passes actual SDK capability roundtrips.

Remaining format and feature limits are in [FORMAT_MODES.md](FORMAT_MODES.md). Scalar transparency, projective textures without baking, native CRV/DWG jobs and full SketchUp authoring-state preservation remain outside the supported subset.

Full suite: /private/tmp/sketchmake-052-full-tests.log. Release build: /private/tmp/sketchmake-052-build.log. Native UI fixture: artifacts/exports/Audit 0.5.2 line.sketchmake.json.
