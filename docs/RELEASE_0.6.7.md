# Garden Studio 0.6.7

Inward Push/Pull on a separately drawn outline now cuts material from a supporting solid, instead of creating an overlapping extrusion and leaving the original face intact.

## Use it

Draw a smaller rectangle, circle or polygon on a solid face. Select the shape, press **P**, then push inward or enter a negative depth such as `-100mm`. A shallow push creates a recess. Reaching or exceeding the solid thickness creates a through-hole with no closing face at the opposite end. Immediately typing another depth replaces the same cut, including after a drag.

The edit preserves the supporting object's identity and overall material, selects the resulting solid, and is undoable. Escape restores the original geometry during a drag. Coplanar picking prefers the selected drawn profile, and vertical/underside drawing keeps the intended face direction.

## Supported geometry

Cutting supports retained extrusion end faces and rectangular-block sides, with a fully contained single closed outline in the same editing context. Through-hole results retain their profile for further non-overlapping holes. Locked, ambiguous and unsupported targets reject the edit atomically.

This is bounded profile cutting, not a general mesh Boolean engine. Arbitrary imported mesh cuts, cylinder side cuts and additional independent cuts into a blind-pocket mesh remain unsupported. Immediate replacement of the last cut depth remains available for a pocket.

## Download and installation

Download `GardenStudio-macOS.zip`, unzip it, and open `Garden Studio.app`. The main app requires Apple Silicon and macOS 13 or later. It is ad-hoc signed and is not notarized. See the [user guide](USER_GUIDE.md) for installation, controls, exact measurements and build instructions. `SHA256SUMS.txt` contains the app ZIP checksum.

## Validation

All 433 tests passed, including added geometry and interaction regressions for cut volume, watertight edges, hole depth, sides, bottom faces, rotated blocks, repeated holes, undo/cancel, face direction, locked targets and unsupported cuts. The release build succeeded. Actual native mouse picking was not exercised by the automated interaction tests; they exercise the shared edit entry point and drag handlers.
