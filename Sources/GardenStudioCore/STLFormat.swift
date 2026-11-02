import Foundation

extension ModelDocument {
    /// Binary or ASCII STL with explicit units and up axis; defaults to millimeters, Z up.
    /// STL does not encode units, materials or texture coordinates.
    public func stlData(binary: Bool = true, metersPerUnit: Double = 0.001, zUp: Bool = true) throws -> Data {
        guard metersPerUnit.isFinite, metersPerUnit > 0 else { throw GeometryIOError.invalid("STL unit scale must be a finite positive number.") }
        try validate()
        var meshes: [MeshData] = []
        var facetCount = 0
        for entity in entities {
            let mesh = try entity.triangulatedMesh()
            guard !mesh.triangles.isEmpty, mesh.lineIndices.isEmpty else {
                throw GeometryIOError.unsupported("STL contains surfaces only. Use DXF or COLLADA to retain lines.")
            }
            facetCount += mesh.triangles.count / 3
            guard facetCount <= 500_000 else { throw GeometryIOError.invalid("STL export exceeds 500,000 triangles.") }
            meshes.append(mesh)
        }
        guard facetCount > 0 else { throw GeometryIOError.invalid("There are no surfaces to export.") }
        var ascii = "solid GardenStudio\n"
        var data = Data("Garden Studio | unit scale \(metersPerUnit) m | \(zUp ? "Z" : "Y") up".utf8)
        data.append(Data(repeating: 0, count: 80-data.count))
        func appendUInt32(_ value: UInt32) { data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0*8)) }) }
        func appendFloat(_ value: Double) throws {
            let single = Float(value)
            guard single.isFinite else { throw GeometryIOError.invalid("Coordinates exceed STL floating-point range.") }
            appendUInt32(single.bitPattern)
        }
        appendUInt32(UInt32(facetCount))
        for mesh in meshes {
            for index in stride(from: 0, to: mesh.triangles.count, by: 3) {
                let vertices = (0..<3).map { offset -> Vec3 in
                    let v = mesh.vertices[mesh.triangles[index+offset]]
                    let mapped = zUp ? Vec3(v.x/metersPerUnit,-v.z/metersPerUnit,v.y/metersPerUnit) : Vec3(v.x/metersPerUnit,v.y/metersPerUnit,v.z/metersPerUnit)
                    return binary ? Vec3(Double(Float(mapped.x)), Double(Float(mapped.y)), Double(Float(mapped.z))) : mapped
                }
                let normal = try stlNormal(vertices[0],vertices[1],vertices[2])
                if binary {
                    for v in [normal] + vertices { try appendFloat(v.x); try appendFloat(v.y); try appendFloat(v.z) }
                    data.append(contentsOf: [0,0])
                } else {
                    ascii += "  facet normal \(normal.x) \(normal.y) \(normal.z)\n    outer loop\n"
                    for v in vertices { ascii += "      vertex \(v.x) \(v.y) \(v.z)\n" }
                    ascii += "    endloop\n  endfacet\n"
                }
            }
        }
        return binary ? data : Data((ascii + "endsolid GardenStudio\n").utf8)
    }

    /// Imports binary or ASCII STL. Default source units: millimeters; source Z becomes model Y.
    /// Pass zUp: false to retain a Y-up coordinate frame.
    public static func importSTL(_ data: Data, name: String, metersPerUnit: Double = 0.001, zUp: Bool = true) throws -> ModelDocument {
        guard metersPerUnit.isFinite, metersPerUnit > 0 else { throw GeometryIOError.invalid("STL unit scale must be a finite positive number.") }
        guard !data.isEmpty, data.count <= 100_000_000 else { throw GeometryIOError.invalid("STL is empty or larger than the 100 MB import limit.") }
        var vertices: [Vec3] = []
        var triangles: [Int] = []
        var vertexIndices: [STLVertexKey: Int] = [:]
        func addTriangle(_ input: [Vec3]) throws {
            guard triangles.count < 1_500_000 else { throw GeometryIOError.invalid("STL exceeds 500,000 triangles.") }
            let converted = input.map { zUp ? Vec3($0.x*metersPerUnit,$0.z*metersPerUnit,-$0.y*metersPerUnit) : Vec3($0.x*metersPerUnit,$0.y*metersPerUnit,$0.z*metersPerUnit) }
            guard converted.allSatisfy({ [$0.x,$0.y,$0.z].allSatisfy(\.isFinite) }) else { throw GeometryIOError.invalid("STL contains non-finite coordinates.") }
            _ = try stlNormal(converted[0],converted[1],converted[2])
            for vertex in converted {
                let key = STLVertexKey(vertex)
                if let existing = vertexIndices[key] { triangles.append(existing) }
                else {
                    guard vertices.count < 250_000 else { throw GeometryIOError.invalid("STL exceeds 250,000 unique vertices.") }
                    vertexIndices[key] = vertices.count
                    triangles.append(vertices.count)
                    vertices.append(vertex)
                }
            }
        }
        func uint32(at offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex+offset+$1]) << ($1*8) }
        }
        let declared = data.count >= 84 ? Int(uint32(at: 80)) : -1
        if declared >= 0, declared <= 500_000, data.count == 84 + declared * 50 {
            guard declared > 0 else { throw GeometryIOError.invalid("STL contains no triangles.") }
            for facet in 0..<declared {
                let offset = 84 + facet * 50 + 12
                let input = (0..<3).map { vertex -> Vec3 in
                    let base = offset + vertex * 12
                    return Vec3(Double(Float(bitPattern: uint32(at: base))),Double(Float(bitPattern: uint32(at: base+4))),Double(Float(bitPattern: uint32(at: base+8))))
                }
                try addTriangle(input)
            }
        } else {
            guard let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("solid") else {
                throw GeometryIOError.invalid("STL has a truncated or invalid binary triangle table.")
            }
            var state = 0
            var facet: [Vec3] = []
            var opened = false, ended = false
            for raw in text.components(separatedBy: .newlines) {
                let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let first = tokens.first?.lowercased() else { continue }
                let lower = tokens.map { $0.lowercased() }
                switch state {
                case 0:
                    if first == "solid", !opened { opened = true }
                    else if first == "facet", opened, !ended, lower.count == 5, lower[1] == "normal", lower.dropFirst(2).allSatisfy({ Double($0)?.isFinite == true }) { state = 1; facet = [] }
                    else if first == "endsolid", opened, !ended { ended = true }
                    else { throw GeometryIOError.invalid("STL has an invalid facet declaration.") }
                case 1:
                    guard lower == ["outer","loop"] else { throw GeometryIOError.invalid("STL facet is missing its outer loop.") }; state = 2
                case 2:
                    guard first == "vertex", tokens.count == 4, let x = Double(tokens[1]), let y = Double(tokens[2]), let z = Double(tokens[3]) else { throw GeometryIOError.invalid("STL triangle contains an invalid vertex.") }
                    facet.append(Vec3(x,y,z)); if facet.count == 3 { state = 3 }
                case 3:
                    guard lower == ["endloop"] else { throw GeometryIOError.invalid("STL triangle needs exactly three vertices.") }; state = 4
                default:
                    guard lower == ["endfacet"] else { throw GeometryIOError.invalid("STL facet is incomplete.") }; try addTriangle(facet); state = 0
                }
            }
            guard state == 0, ended, !vertices.isEmpty else { throw GeometryIOError.invalid("STL contains no complete triangles or is missing endsolid.") }
        }
        let mesh = MeshData(vertices: vertices, triangles: triangles)
        try mesh.validate()
        let width = vertices.map(\.x).max()! - vertices.map(\.x).min()!
        let height = vertices.map(\.y).max()! - vertices.map(\.y).min()!
        let depth = vertices.map(\.z).max()! - vertices.map(\.z).min()!
        let entity = GardenEntity(name: name, kind: .mesh, origin: Vec3(0,0,0), width: width, depth: depth, height: height, mesh: mesh)
        let document = ModelDocument(entities: [entity], name: name)
        try document.validate()
        return document
    }
}

private func stlNormal(_ a: Vec3,_ b: Vec3,_ c: Vec3) throws -> Vec3 {
    let u = Vec3(b.x-a.x,b.y-a.y,b.z-a.z), v = Vec3(c.x-a.x,c.y-a.y,c.z-a.z)
    let normal = Vec3(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
    let length = sqrt(normal.x*normal.x+normal.y*normal.y+normal.z*normal.z)
    guard length.isFinite, length > 0 else { throw GeometryIOError.invalid("STL contains a degenerate triangle or coordinates outside the supported range.") }
    return Vec3(normal.x/length,normal.y/length,normal.z/length)
}

private struct STLVertexKey: Hashable {
    let x: UInt64, y: UInt64, z: UInt64
    init(_ vertex: Vec3) {
        x = (vertex.x == 0 ? 0 : vertex.x).bitPattern
        y = (vertex.y == 0 ? 0 : vertex.y).bitPattern
        z = (vertex.z == 0 ? 0 : vertex.z).bitPattern
    }
}
