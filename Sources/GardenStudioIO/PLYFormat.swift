import Foundation
import GardenStudioCore

/// PLY geometry/RGB exchange. Textures are not part of this bounded PLY profile.
/// Varying vertex RGB becomes flat corner regions, preserving colors without interpolation.
public enum PLYFormat {
    private struct Property { var name: String; var type: String; var countType: String? }
    private struct Element { var name: String; var count: Int; var properties: [Property] }
    private static let sizes = ["char":1,"int8":1,"uchar":1,"uint8":1,"short":2,"int16":2,"ushort":2,"uint16":2,"int":4,"int32":4,"uint":4,"uint32":4,"float":4,"float32":4,"double":8,"float64":8]
    public static func read(url: URL, metersPerUnit: Double = 1, zUp: Bool = false) throws -> ModelDocument {
        try PlainMesh.units(metersPerUnit); let data = try PlainMesh.data(url)
        let prefix = data.prefix(65_536)
        guard let range = prefix.range(of:Data("end_header\n".utf8)) ?? prefix.range(of:Data("end_header\r\n".utf8)), let header = String(data:data[..<range.upperBound],encoding:.ascii) else { throw GeometryIOError.invalid("PLY header is missing or exceeds 64 KB.") }
        var elements: [Element] = [], format = ""
        let lines = header.components(separatedBy:.newlines)
        guard lines.first == "ply" || lines.first == "ply\r" else { throw GeometryIOError.invalid("Missing PLY signature.") }
        for line in lines.dropFirst() {
            let f = line.split(whereSeparator:{$0.isWhitespace}).map(String.init); guard let op = f.first else { continue }
            switch op {
            case "format": guard f.count == 3, f[2] == "1.0", ["ascii","binary_little_endian","binary_big_endian"].contains(f[1]), format.isEmpty else { throw GeometryIOError.unsupported("Unsupported PLY encoding/version.") }; format = f[1]
            case "element": guard f.count == 3, elements.count < 32 else { throw GeometryIOError.invalid("Invalid PLY element.") }; let n = try PlainMesh.integer(f[2]); guard n >= 0, n <= 500_000, f[1] != "vertex" || n <= 250_000, !elements.contains(where:{$0.name == f[1]}) else { throw GeometryIOError.invalid("Invalid PLY element count.") }; elements.append(Element(name:f[1],count:n,properties:[]))
            case "property":
                guard !elements.isEmpty, elements[elements.count-1].properties.count < 64 else { throw GeometryIOError.invalid("Invalid PLY property.") }
                let p: Property
                if f.count == 3 { p = Property(name:f[2],type:f[1]) }
                else if f.count == 5, f[1] == "list" { p = Property(name:f[4],type:f[3],countType:f[2]) }
                else { throw GeometryIOError.invalid("Invalid PLY property declaration.") }
                guard sizes[p.type] != nil, p.countType.map({ sizes[$0] != nil && !$0.contains("float") && $0 != "double" }) ?? true, !elements[elements.count-1].properties.contains(where:{$0.name == p.name}) else { throw GeometryIOError.unsupported("Unsupported PLY scalar type or duplicate property.") }
                if ["vertex","face"].contains(elements[elements.count-1].name),["red","green","blue","alpha"].contains(p.name),p.countType != nil {throw GeometryIOError.unsupported("PLY RGB/alpha channels must use scalar properties.")}
                elements[elements.count-1].properties.append(p)
            case "comment", "obj_info", "end_header": break
            default: throw GeometryIOError.unsupported("Unsupported PLY header directive: \(op)")
            }
        }
        guard !format.isEmpty, elements.contains(where:{$0.name == "vertex"}), elements.contains(where:{$0.name == "face"}) else { throw GeometryIOError.invalid("PLY needs vertex and face elements.") }
        let body = data[range.upperBound...]
        var ascii: [Substring] = [], cursor = range.upperBound, token = 0
        if format == "ascii" { guard let s = String(data:body,encoding:.ascii) else { throw GeometryIOError.invalid("Invalid ASCII PLY body.") }; ascii = s.split(whereSeparator:{$0.isWhitespace}) }
        func scalar(_ type: String) throws -> Double {
            let value: Double
            if format == "ascii" { guard token < ascii.count else { throw GeometryIOError.invalid("Truncated PLY body.") }; value = try PlainMesh.number(String(ascii[token])); token += 1 }
            else {
                let size = sizes[type]!; guard cursor <= data.count-size else { throw GeometryIOError.invalid("Truncated binary PLY body.") }
                var bits: UInt64 = 0
                for i in 0..<size { let shift = format == "binary_little_endian" ? i*8 : (size-1-i)*8; bits |= UInt64(data[cursor+i]) << shift }; cursor += size
                switch type {
                case "float","float32": value = Double(Float(bitPattern:UInt32(bits)))
                case "double","float64": value = Double(bitPattern:bits)
                case "char","int8": value = Double(Int8(bitPattern:UInt8(bits)))
                case "short","int16": value = Double(Int16(bitPattern:UInt16(bits)))
                case "int","int32": value = Double(Int32(bitPattern:UInt32(bits)))
                default: value = Double(bits)
                }
            }
            guard value.isFinite else { throw GeometryIOError.invalid("PLY contains non-finite coordinates/properties.") }
            if !["float","float32","double","float64"].contains(type) {
                let bounds: (Double,Double)
                switch type { case "char","int8": bounds = (-128,127); case "uchar","uint8": bounds = (0,255); case "short","int16": bounds = (-32768,32767); case "ushort","uint16": bounds = (0,65535); case "int","int32": bounds = (-2147483648,2147483647); default: bounds = (0,4294967295) }
                guard value.rounded() == value, value >= bounds.0, value <= bounds.1 else { throw GeometryIOError.invalid("PLY scalar is outside its declared integer type.") }
            }
            return value
        }
        var mesh = MeshData(), vertexColors: [String?] = [], polygons: [[Int]] = [], faceColors: [String?] = []
        for e in elements {
            for _ in 0..<e.count {
                var values: [String:Double] = [:], lists: [String:[Double]] = [:]
                for p in e.properties {
                    if let countType = p.countType { let count = try scalar(countType); guard count >= 0, count <= 10_000, count.rounded() == count else { throw GeometryIOError.invalid("Invalid PLY list size.") }; lists[p.name] = try (0..<Int(count)).map { _ in try scalar(p.type) } }
                    else { values[p.name] = try scalar(p.type) }
                }
                if ["vertex","face"].contains(e.name),let alpha=values["alpha"] {
                    let type=e.properties.first(where:{$0.name=="alpha"})!.type
                    let opaque:Double
                    switch type {
                    case "float","float32","double","float64":opaque=1
                    case "char","int8":opaque=127
                    case "uchar","uint8":opaque=255
                    case "short","int16":opaque=32767
                    case "ushort","uint16":opaque=65535
                    case "int","int32":opaque=2147483647
                    default:opaque=4294967295
                    }
                    guard alpha == opaque else {throw GeometryIOError.unsupported("PLY alpha transparency cannot be preserved; use opaque RGB colors.")}
                }
                func color() throws -> String? { let rgb = [values["red"],values["green"],values["blue"]]; if rgb.allSatisfy({$0 == nil}) { return nil }; guard rgb.allSatisfy({$0 != nil}) else { throw GeometryIOError.invalid("Incomplete PLY RGB color.") }; return try PlainMesh.hex(rgb.map {$0!}) }
                if e.name == "vertex" { guard let x = values["x"], let y = values["y"], let z = values["z"] else { throw GeometryIOError.invalid("PLY vertex lacks x/y/z.") }; mesh.vertices.append(PlainMesh.decode(Vec3(x,y,z),metersPerUnit,zUp)); vertexColors.append(try color()) }
                if e.name == "face" {
                    guard let list = lists["vertex_indices"] ?? lists["vertex_index"], list.count >= 3, list.allSatisfy({$0 >= 0 && $0 <= 250_000 && $0.rounded() == $0}) else { throw GeometryIOError.invalid("Invalid PLY face index list.") }
                    polygons.append(list.map(Int.init)); faceColors.append(try color())
                }
            }
        }
        guard format == "ascii" ? token == ascii.count : cursor == data.count else { throw GeometryIOError.invalid("Unexpected trailing PLY data.") }
        var colors: [String] = []
        for (i,p) in polygons.enumerated() {
            let tri = try PlainMesh.polygon(p,vertices:mesh.vertices)
            for j in stride(from:0,to:tri.count,by:3) {
                let ids = Array(tri[j..<j+3]), cornerColors = ids.map { vertexColors[$0] ?? "#E7DCC8" }
                if let face = faceColors[i] { mesh.triangles += ids; colors.append(face) }
                else if Set(cornerColors).count == 1 { mesh.triangles += ids; colors.append(cornerColors[0]) }
                else {
                    // Preserve the three corner color assignments as flat corner regions.
                    let a = mesh.vertices[ids[0]], b = mesh.vertices[ids[1]], c = mesh.vertices[ids[2]], start = mesh.vertices.count
                    func midpoint(_ a: Vec3,_ b: Vec3) -> Vec3 { Vec3((a.x+b.x)/2,(a.y+b.y)/2,(a.z+b.z)/2) }
                    mesh.vertices += [midpoint(a,b),midpoint(b,c),midpoint(c,a),Vec3((a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3,(a.z+b.z+c.z)/3)]
                    for k in 0..<3 { mesh.triangles += [ids[k],start+k,start+3,ids[k],start+3,start+(k+2)%3]; colors += [cornerColors[k],cornerColors[k]] }
                }
                guard mesh.vertices.count <= 250_000, mesh.triangles.count <= 1_500_000 else { throw GeometryIOError.invalid("PLY expanded mesh exceeds geometry limits.") }
            }
        }
        return try PlainMesh.colored(mesh,colors:colors,name:url.deletingPathExtension().lastPathComponent)
    }
    public static func write(_ document: ModelDocument, to url: URL, binary: Bool = false, metersPerUnit: Double = 1, zUp: Bool = false) throws {
        try PlainMesh.units(metersPerUnit); let (mesh,colors) = try PlainMesh.flattened(document)
        let header = "ply\nformat \(binary ? "binary_little_endian" : "ascii") 1.0\ncomment GardenStudio geometry and RGB; textures omitted\nelement vertex \(mesh.vertices.count)\nproperty double x\nproperty double y\nproperty double z\nelement face \(mesh.triangles.count/3)\nproperty list uchar int vertex_indices\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
        var data = Data(header.utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        for v in mesh.vertices {
            let p = try PlainMesh.encode(v,metersPerUnit,zUp)
            if binary { append(p.x.bitPattern); append(p.y.bitPattern); append(p.z.bitPattern) }
            else { data.append(Data("\(p.x) \(p.y) \(p.z)\n".utf8)) }
        }
        for i in stride(from:0,to:mesh.triangles.count,by:3) {
            let rgb = PlainMesh.rgb(colors[i/3])
            if binary { data.append(3); for j in 0..<3 { append(Int32(mesh.triangles[i+j])) }; data.append(contentsOf:rgb) }
            else { data.append(Data("3 \(mesh.triangles[i]) \(mesh.triangles[i+1]) \(mesh.triangles[i+2]) \(rgb[0]) \(rgb[1]) \(rgb[2])\n".utf8)) }
        }
        try data.write(to:url,options:.atomic)
    }
}
