import Foundation
import GardenStudioCore

/// ASCII OFF face geometry. COFF colors and texture extensions are unsupported.
public enum OFFFormat {
    public static func read(url: URL, metersPerUnit: Double = 1, zUp: Bool = false) throws -> ModelDocument {
        try PlainMesh.units(metersPerUnit)
        guard let text = String(data:try PlainMesh.data(url),encoding:.utf8) else { throw GeometryIOError.invalid("OFF must be ASCII/UTF-8 text.") }
        let lines = text.components(separatedBy:.newlines).map { $0.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0] }.filter { !$0.trimmingCharacters(in:.whitespaces).isEmpty }
        var tokens = lines.flatMap { $0.split(whereSeparator:{$0.isWhitespace}).map(String.init) }, cursor = 0
        func next() throws -> String { guard cursor < tokens.count else { throw GeometryIOError.invalid("Truncated OFF file.") }; defer { cursor += 1 }; return tokens[cursor] }
        guard try next() == "OFF" else { throw GeometryIOError.unsupported("Only ASCII OFF geometry is supported; COFF and binary extensions are unsupported.") }
        let vertexCount = try PlainMesh.integer(next()), faceCount = try PlainMesh.integer(next()), edges = try PlainMesh.integer(next())
        guard vertexCount > 0, vertexCount <= 250_000, faceCount > 0, faceCount <= 500_000, edges >= 0 else { throw GeometryIOError.invalid("OFF geometry count exceeds supported limits.") }
        var mesh = MeshData()
        for _ in 0..<vertexCount { let p = try Vec3(PlainMesh.number(next()),PlainMesh.number(next()),PlainMesh.number(next())); mesh.vertices.append(PlainMesh.decode(p,metersPerUnit,zUp)) }
        for _ in 0..<faceCount {
            let count = try PlainMesh.integer(next()); guard count >= 3, count <= 10_000 else { throw GeometryIOError.invalid("Invalid OFF polygon size.") }
            let indices = try (0..<count).map { _ in try PlainMesh.integer(next()) }
            mesh.triangles += try PlainMesh.polygon(indices,vertices:mesh.vertices)
            guard mesh.triangles.count <= 1_500_000 else { throw GeometryIOError.invalid("OFF exceeds 500,000 triangles.") }
        }
        guard cursor == tokens.count else { throw GeometryIOError.unsupported("OFF trailing color/texture data is unsupported.") }
        tokens.removeAll()
        let doc = ModelDocument(entities:[try PlainMesh.entity(mesh,name:url.deletingPathExtension().lastPathComponent)]); try doc.validate(); return doc
    }
    public static func write(_ document: ModelDocument, to url: URL, metersPerUnit: Double = 1, zUp: Bool = false) throws {
        try PlainMesh.units(metersPerUnit); let (mesh,_) = try PlainMesh.flattened(document)
        var text = "OFF\n\(mesh.vertices.count) \(mesh.triangles.count/3) 0\n"
        for v in mesh.vertices { let p = try PlainMesh.encode(v,metersPerUnit,zUp); text += "\(p.x) \(p.y) \(p.z)\n" }
        for i in stride(from:0,to:mesh.triangles.count,by:3) { text += "3 \(mesh.triangles[i]) \(mesh.triangles[i+1]) \(mesh.triangles[i+2])\n" }
        try text.write(to:url,atomically:true,encoding:.utf8)
    }
}
