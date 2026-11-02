# Garden Studio 0.6.6

This release completes the product rename to **Garden Studio** across the application, source tree and downloadable package.

## Changes

- The application is `Garden Studio.app`, its executable is `GardenStudio`, and its bundle identifier is `local.gardenstudio.app`.
- Swift source and test modules use `GardenStudioCore`, `GardenStudioIO` and `GardenStudioUI`; the app and launcher directories use Garden Studio names.
- Native helper executables, Ruby modules, the bundled `garden_studio_bridge.rb`, menus, window titles, exported format headers and documentation use Garden Studio names.
- New project saves default to `.gardenstudio.json`. Existing project JSON files, including `.sketchmake.json`, still open with the same editable model schema.
- New SVG and OBJ exports use Garden Studio metadata. Import retains support for older origin and material-color metadata.

## Install

Download **GardenStudio-macOS.zip** from this release, unzip it, and move **Garden Studio.app** to Applications or another folder you own. The main app requires Apple Silicon and macOS 13 or later. The optional native exchange helpers include Apple Silicon and Intel code.

The application is ad-hoc signed, not Developer ID signed or notarized. If macOS blocks the app, see the first-launch instructions in the [installation and user guide](USER_GUIDE.md). The guide also explains drawing, camera controls, saving, import/export and building from source.

Optional SKP/SKM interoperability still requires a separately installed compatible SketchUp SDK. External SDK and API spellings remain unchanged. Vendor SDK libraries are not distributed with the application.

The release includes `SHA256SUMS.txt` for checking the app ZIP. GitHub's source archives contain the complete source for this version.

## Validation

All 412 tests passed, including four branding and legacy-file compatibility checks. Build scripts and bundled Ruby scripts passed syntax checks.
