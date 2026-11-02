# SketchUp Make 2017 inspection

## Artifact and acquisition

The vendor no longer distributes Make (https://help.sketchup.com/en/make-access). Direct vendor URL returned HTTP 403. Downloaded the 141,362,672-byte macOS installer from the legacy mirror linked at https://www.av8rdas.com/sketchup-resources.html:

https://www.av8rdas.com/uploads/1/0/3/2/103277290/sketchupmake-2017-3-116-90851-en_1.dmg

Retained original: `artifacts/sketchupmake-2017-original.dmg` (working copy `/private/tmp/sketchupmake-2017.dmg`).
REA `open_binary` identified DMG archive, SHA-256 `a534d77d1ea9622b19463258abf21768cb8bb8126734bd40329dd4088b04d79f`. Hash identifies downloaded bytes; it does not authenticate the mirror.

`inspect_artifact` failed while enumerating protected `.Trashes`; `extract_artifact` does not support DMG in this connected version. REA `capture_process_scenario` mounted read-only using hdiutil at `/private/tmp/sketchup-make-original`. Mount evidence: `ev_7abce4cf3af954bbe8bf66bafb4e14b32f23f9cc5a25973b6df3f4f444849124`.

## Observed resource facts

REA `open_bundle_resources` + `inspect_plist` inspected original SketchUp.app. Evidence `ev_7e3989ea47ccf59d2a8c388fb526eac077bcc4b744362714387c0656bdcbb976` reports:

- Bundle `com.sketchup.SketchUp.2017`, version **17.3.116**, minimum OS **10.10**.
- `SketchUpApplication` principal class, `MainMenu` main nib, `SketchUpDocument` document class.
- SKP model editor, SKM material viewer and RBZ plugin declarations.

Broad bounded Interface Builder inspection hit framework resources before the app menu. To focus the question, copied only original Info.plist and English MainMenu.nib into `/private/tmp/sketchup-focused` (no executable and no changed resource bytes), opened this resource root in REA, and decoded it.

MainMenu keyed archive SHA-256: `311a310baf0d729170ae67c9933efd3ce994545749eddfc8ac3c679a5b60736a`.
Evidence `ev_3dfdc85ca56c77942c5f1e6158f016925b64296a542d229f6ecdac1e55a928e2`: 491 archive objects, 174 connections, 166 action nodes. Observed selectors include `editUndo:`, `selectOrbitTool:`, `selectPushPullTool:`, `selectPaintTool:`, `viewZoomExtents:`, `selectRectangleTool:` and `selectCircleTool:`. These declarations support the recreation's core tool inventory.

The companion designable.nib was unsupported by the plist decoder. Hierarchy, dynamic visibility, selector implementations, runtime geometry behavior and original pixel layout remain unknown. Static menu declarations do not prove actual execution. No original executable was launched or decompiled; full computational geometry behavior was not recovered.

## Recreation decisions and validation

AppKit/SceneKit, primitive-based geometry, simplified inspector, JSON persistence and OBJ export are independent implementation decisions. No claim of recovered original source, binary equivalence, pixel identity or full feature parity is made.

`rea-evidence.json` retains original-resource and mount evidence. `rea-mainmenu-evidence.json` also retains the focused menu graph. Resource sessions were closed after exporting evidence.

Native UI showed the demo geometry rendering with grid/axes, clean tool rails and inspector. Selected Studio through outliner, used Push/Pull + Measurements to set 3.5 m, then Command-Z restored 2.9 m. Native Save produced a decodable 10-object JSON model, copied to `artifacts/Garden Studio.sketchmake.json`. A save-dialog automation selected text incorrectly, leaving a redundant test file in Documents named `Garden Studio.ske:Users:thomas:Documents:source:sketch-clone:artifacts:Garden Studio.sketchmake.jsontchmake.json`; no pre-existing file was overwritten. Standard Cut/Copy/Paste/Select All responder menu items were subsequently added to support native text editing shortcuts.
