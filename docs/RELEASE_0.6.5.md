# Version 0.6.5

This release publishes the Garden Studio source in GardenStudio, adds an installation and user guide, and removes SketchUp from project-owned source filenames and identifiers.

## Changes

- Renamed native exchange implementation to `NativeModelFormat`, its dynamic SDK header to `NativeSDKDynamic.hpp`, and Ruby bridge implementation to `ModelScriptBridge`.
- Renamed bridge resources and related tests and updated callers, packaging, and documentation paths.
- Preserved external SDK headers, library names, Ruby APIs and existing SDK environment variables for compatibility. Documentation and format descriptions retain the SketchUp name where it identifies the supported application or format.
- Added [installation, controls, import/export and build instructions](USER_GUIDE.md).

## Download

Download `GardenStudio-macOS.zip`, unzip it, and open `Garden Studio.app`. The main application requires Apple Silicon and macOS 13 or later. It is ad-hoc signed and is not notarized; see the user guide for macOS first-launch instructions.

Native SKP/SKM exchange requires a separately installed compatible SDK. Vendor SDK libraries are not bundled. Built-in exchange codecs work without it. Refer to the [format matrix](FORMAT_MODES.md) for supported directions and limitations.

`SHA256SUMS.txt` contains the checksum of the app ZIP. GitHub's source archives contain the source for building the application.

## Validation

- All 408 existing tests passed after the source renames, including native model/material exchange and the Ruby bridge.
- Build-script and Ruby syntax checks passed.
