# Fixes in 0.6.4

- Match corresponding populated nested component groups by linked part identities instead of UUID sort order. Empty same-named groups have no linked contents to distinguish them, so match by sibling order.
- Propagate the corresponding group reassignment when an existing part is grouped inside one component instance.
- Update the README and modeling guide to reflect component topology synchronization and the current SDK-backed SKP/SKM workflow.
- Correct the README's descriptions of face paint and the exchange menu.
- Persist an orthonormal drawing frame in the editable project and expose a dialog for origin, X direction and plane normal.
- Allow Ctrl-drag to move selected mesh vertices while preserving face indices, UV coordinates and entity placement.
- Generate explicit dominant-plane UVs for selected meshes with bounded corner duplication at face seams.

Regression coverage includes same-named nested groups whose UUID order is reversed between component instances. All component topology tests and the full test suite must pass before packaging.
