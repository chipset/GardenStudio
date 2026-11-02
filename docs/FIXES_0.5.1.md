# Correctness audit — 0.5.1

Confirmed defects repaired:

| Area | Failure | Correction |
| --- | --- | --- |
| Linked components | Split/sweep topology reused component-part identities and could overwrite a source counterpart. | Newly created parts receive distinct identities; existing line identity stays with its original segment. |
| Visibility | Show All could leave hidden locked geometry hidden. | Reveal preserves the lock while restoring visibility. |
| Background work | Import/Ruby results could apply after resetting or undoing back to an equal document. | Document revision and editing context must still match. |
| Projects | Open loaded unbounded/nonregular files; Save could create files exceeding the supported open limit. | Bounded regular-file reads and matching 100 MB save/open limits. |
| Material editor | Merely applying an unchanged material rounded texture size/rotation to four significant digits. | Roundtrip-safe numeric editing values. |
| Texture validation | Metadata looked valid even when compressed pixels could not decode. | Force pixel validation; cache successful immutable payload checks with a 32 MB cost target and 64-entry limit. |
| Native Unicode | UTF-16 truncation could split emoji; valid composed names could exceed the material reader's byte cap. | Composed-character handling and a bounded 64 KB native-name read limit. |
| Native line colors | Loose lines sharing a textured object lost their fallback color. | Separate opaque native line paint and material buckets. |
| Native file size | Reusing cached URL metadata could bypass the 100 MB input limit. | Fresh filesystem attributes. |
| glTF hierarchy | A tiny shared-node DAG could cause excessive empty-node traversal. | Validate scene-tree uniqueness and bound total node visits. |
| glTF appearance | Clamp/mirror sampling silently rendered as repeating textures. | Explicit rejection of wrapping the renderer cannot preserve. |
| OBJ appearance | Translucent MTL opacity became opaque. | Explicit rejection of unsupported d/Tr/map_d values; opaque controls remain supported. |

The audit also checked About/Quit and import cancellation on a fresh native app. Those actions worked; no speculative menu change was made. The stricter pixel check exposed invalid PNG test fixtures (bad IDAT CRCs), which were replaced with valid images.

Validation includes focused red/green regressions, the combined suite, real SketchUp SDK roundtrips and original Make 2017 SDK reads. The combined suite passes 294 tests with zero failures and no native-test skips. Actual Make 2017 SDK reading and all five new native regressions pass. The release build succeeds. Native UI checks preserve a 0.123456789012345 m repeat size and 51.23456789012345 degree rotation through unchanged Apply, editor reopen and project save/reopen. The saved project retains ten objects and camera state. The extracted v0.5.1 ZIP passes strict deep code-signature verification, and its included helper passes a real SDK read/write capability probe.

Intentional format limits remain in [FORMAT_MODES.md](FORMAT_MODES.md). Native SKP exchange flattens static geometry and does not preserve full authoring state. Full third-party extensions, native CRV/DWG jobs and Windows VCarve runtime are outside this audit's verified support.

Verified project fixture: artifacts/exports/Audit 0.5.1.gardenstudio.json. Full test log: /private/tmp/gardenstudio-051-full-tests.log. Release build log: /private/tmp/gardenstudio-051-build.log.
