# Garden Studio 0.6.8

This update fixes four issues found in the source review:

- Entering a depth during an inward Push/Pull drag now applies that exact depth and commits the cut once.
- Hidden objects no longer respond to geometry-edit commands while hidden; Show All and visibility controls still restore them.
- A Layers panel opened for an earlier model cannot change layers in a newly opened model, even when layer IDs match.
- Failed textured COLLADA exports clean up newly created sidecars and preserve the previous DAE.

Download `GardenStudio-macOS.zip`, unzip it, and open `Garden Studio.app`. The app requires Apple Silicon and macOS 13 or later. See the [user guide](USER_GUIDE.md) for installation and modeling controls. `SHA256SUMS.txt` contains the app ZIP checksum.

Validation: all 442 tests passed, including new regressions for each fix.
