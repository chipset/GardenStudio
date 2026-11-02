# Native SketchUp exchange

User priority: native macOS SKP and SKM read/write. Use an installed SketchUp C SDK dynamically from an isolated helper; never redistribute vendor SDK libraries. Retain Ruby bridge fallback. Default native SKP output targets Make 2017. Static scene geometry is exchanged; authoring topology, scenes and extension data are outside this mode.

1. Establish worker JSON protocol, compile own universal helper against locally installed public headers, prove SDK load.
2. Native geometry lane: bounded recursive group/component read, triangulated write, physical units, names, colors and UVs, Make2017 save version.
3. Native material lane: actual SKM load/write, colors and embedded texture repeat, explicit unsupported material rejection.
4. Parent Swift process client: discover SDK/helper, private work directory, input/output limits, timeout, validate decoded models/materials. Normalize export geometry and UV/material assignments.
5. UI: SKP catalog entry; SKM material controls. Test actual native roundtrips, malformed files, coordinate/UV/material fidelity and legacy reader compatibility.
6. Integrate already completed open-format codecs; full tests, signed local app/ZIP, native UI smoke test and honest capability documentation.
