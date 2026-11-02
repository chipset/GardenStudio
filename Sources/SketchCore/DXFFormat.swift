import Foundation

public enum DXFError: Error, LocalizedError {
    case invalid(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self { case let .invalid(message), let .unsupported(message): return message }
    }
}

private struct DXFPair { let code: Int; let value: String }
private struct DXFRecord { let type: String; let pairs: [DXFPair] }
private struct DXFPoint { var x: Double; var y: Double; var z: Double = 0; var bulge: Double = 0 }

extension ModelDocument {
    /// ASCII DXF top-view profiles in millimeters. Height is intentionally projected away.
    /// Arbitrary surface meshes have no unambiguous CNC profile and must use STL instead.
    public func dxfString() throws -> String {
        try validate()
        guard entities.allSatisfy({ [$0.origin.x, $0.origin.y, $0.origin.z, $0.width, $0.depth, $0.height].allSatisfy({ abs($0) <= 1e12 }) && ($0.mesh?.vertices.allSatisfy({ [$0.x,$0.y,$0.z].allSatisfy({ abs($0) <= 1e12 }) }) ?? true) }) else { throw DXFError.invalid("Coordinates exceed the DXF export range.") }
        guard !entities.isEmpty else { throw DXFError.invalid("The model has no profiles to export.") }
        let recordCount = entities.reduce(0) { count, entity in
            guard entity.kind == .mesh else { return count + 1 }
            if let profile = entity.profile { return count + 1 + profile.holes.count }
            return count + (entity.mesh?.lineIndices.count ?? 0) / 2
        }
        guard recordCount <= 50_000 else { throw DXFError.invalid("DXF export exceeds the 50,000 imported-object limit.") }
        var result = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        func emit(_ code: Int, _ value: String) { result += "\(code)\n\(value)\n" }
        func number(_ value: Double) throws -> String {
            guard value.isFinite, abs(value) <= 1e12 else { throw DXFError.invalid("Coordinates exceed the DXF export range after conversion to millimeters.") }
            return String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), abs(value) < 0.0000000005 ? 0 : value)
        }
        func point(_ vertex: Vec3, entity: SketchEntity) -> Vec3 {
            let c = cos(entity.rotation), s = sin(entity.rotation)
            return Vec3(entity.origin.x + c * vertex.x + s * vertex.z, entity.origin.y + vertex.y, entity.origin.z - s * vertex.x + c * vertex.z)
        }
        func layer(_ entity: SketchEntity) -> String {
            let invalid = CharacterSet(charactersIn: "<>/\\\":;?*|=\r\n")
            let cleaned = entity.name.components(separatedBy: invalid).joined(separator: "_")
            return cleaned.isEmpty ? "0" : String(cleaned.prefix(200))
        }
        func line(_ a: Vec3, _ b: Vec3, entity: SketchEntity) throws {
            guard hypot(b.x - a.x, b.z - a.z) > 1e-10 else { throw DXFError.unsupported("\(entity.name) contains an edge perpendicular to the top view. Use STL for 3D geometry.") }
            emit(0, "LINE"); emit(100, "AcDbEntity"); emit(8, layer(entity)); emit(100, "AcDbLine")
            emit(10, try number(a.x * 1000)); emit(20, try number(-a.z * 1000)); emit(30, "0")
            emit(11, try number(b.x * 1000)); emit(21, try number(-b.z * 1000)); emit(31, "0")
        }
        func polyline(_ points: [Vec3], entity: SketchEntity) throws {
            emit(0, "LWPOLYLINE"); emit(100, "AcDbEntity"); emit(8, layer(entity)); emit(100, "AcDbPolyline"); emit(90, String(points.count)); emit(70, "1")
            for p in points { emit(10, try number(p.x * 1000)); emit(20, try number(-p.z * 1000)) }
        }
        for entity in entities {
            switch entity.kind {
            case .line:
                try line(entity.origin, point(Vec3(entity.width, entity.height, entity.depth), entity: entity), entity: entity)
            case .rectangle:
                try polyline([Vec3(-entity.width/2,0,-entity.depth/2), Vec3(entity.width/2,0,-entity.depth/2), Vec3(entity.width/2,0,entity.depth/2), Vec3(-entity.width/2,0,entity.depth/2)].map { point($0, entity: entity) }, entity: entity)
            case .circle:
                if abs(entity.width - entity.depth) < 1e-10 {
                    emit(0, "CIRCLE"); emit(100, "AcDbEntity"); emit(8, layer(entity)); emit(100, "AcDbCircle"); emit(10, try number(entity.origin.x * 1000)); emit(20, try number(-entity.origin.z * 1000)); emit(30, "0"); emit(40, try number(entity.width * 500))
                } else {
                    let points = (0..<72).map { i -> Vec3 in
                        let angle = Double(i) * .pi * 2 / 72
                        return point(Vec3(cos(angle) * entity.width / 2, 0, sin(angle) * entity.depth / 2), entity: entity)
                    }
                    try polyline(points, entity: entity)
                }
            case .mesh:
                if entity.profile != nil {
                    let profile = try GeometryTools.worldProfile(of: entity)
                    for ring in [profile.outer] + profile.holes {
                        var area = 0.0
                        for i in ring.indices { let a = ring[i], b = ring[(i+1) % ring.count]; area += a.x*b.z - b.x*a.z }
                        guard abs(area) > 1e-12 else { throw DXFError.unsupported("This profile is edge-on in the top view. Rotate it onto the ground plane before exporting DXF.") }
                        try polyline(ring, entity: entity)
                    }
                    continue
                }
                guard let mesh = entity.mesh, mesh.triangles.isEmpty, !mesh.lineIndices.isEmpty else { throw DXFError.unsupported("\(entity.name) is a surface mesh. Export it as STL; DXF export needs explicit 2D profile edges.") }
                for offset in stride(from: 0, to: mesh.lineIndices.count, by: 2) {
                    try line(point(mesh.vertices[mesh.lineIndices[offset]], entity: entity), point(mesh.vertices[mesh.lineIndices[offset + 1]], entity: entity), entity: entity)
                }
            }
        }
        result += "0\nENDSEC\n0\nEOF\n"
        return result
    }

    /// ASCII DXF surfaces and edges in millimeters, Z up. Unlike dxfString(), height is retained.
    public func dxf3DString() throws -> String {
        try validate()
        guard !entities.isEmpty else { throw DXFError.invalid("The model has no geometry to export.") }
        var result = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        func emit(_ code: Int, _ value: String) { result += "\(code)\n\(value)\n" }
        func point(_ v: Vec3, _ slot: Int) throws {
            let coords = [v.x * 1000, -v.z * 1000, v.y * 1000]
            guard coords.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }) else { throw DXFError.invalid("Coordinates exceed the DXF export range.") }
            for (axis, n) in coords.enumerated() { emit(10 + axis * 10 + slot, String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), n == 0 ? 0 : n)) }
        }
        var count = 0
        for entity in entities {
            let mesh = try entity.triangulatedMesh()
            // Each exported face/edge imports as one object. Match the editable
            // document limit before assembling an output our reader cannot open.
            guard count + mesh.triangles.count / 3 + mesh.lineIndices.count / 2 <= 50_000 else {
                throw DXFError.invalid("DXF export exceeds the 50,000 imported-object limit.")
            }
            let invalid = CharacterSet(charactersIn: "<>/\\\":;?*|=\r\n")
            let cleaned = entity.name.components(separatedBy: invalid).joined(separator: "_")
            let layer = cleaned.isEmpty ? "0" : String(cleaned.prefix(200))
            for i in stride(from: 0, to: mesh.triangles.count, by: 3) {
                let a = mesh.vertices[mesh.triangles[i]], b = mesh.vertices[mesh.triangles[i+1]], c = mesh.vertices[mesh.triangles[i+2]]
                try dxfValidateTriangle(a,b,c)
                emit(0,"3DFACE"); emit(8,layer)
                try point(a,0); try point(b,1); try point(c,2); try point(c,3)
                count += 1
            }
            for i in stride(from: 0, to: mesh.lineIndices.count, by: 2) {
                let a = mesh.vertices[mesh.lineIndices[i]], b = mesh.vertices[mesh.lineIndices[i+1]]
                guard a != b else { throw DXFError.invalid("DXF contains a zero-length edge.") }
                emit(0,"LINE"); emit(8,layer); try point(a,0); try point(b,1)
                count += 1
            }
        }
        return result + "0\nENDSEC\n0\nEOF\n"
    }

    /// Imports ASCII DXF vector geometry. Drawing X/Y/Z becomes model X/Z/−Y, preserving orientation with Z-up STL.
    /// `$INSUNITS` is respected unless overridden. Unitless files default to millimeters.
    public static func importDXF(_ text: String, name: String, metersPerUnit: Double? = nil) throws -> ModelDocument {
        guard text.utf8.count <= 32 * 1024 * 1024 else { throw DXFError.invalid("DXF exceeds the 32 MB import limit.") }
        guard !text.hasPrefix("AutoCAD Binary DXF") else { throw DXFError.unsupported("Binary DXF is not supported. Export an ASCII DXF from VCarve.") }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeLast() }
        guard lines.count % 2 == 0, lines.count >= 4, lines.count <= 2_000_000 else { throw DXFError.invalid("The DXF group-code/value pairs are incomplete or too numerous.") }
        var pairs: [DXFPair] = []
        pairs.reserveCapacity(lines.count / 2)
        for i in stride(from: 0, to: lines.count, by: 2) {
            guard let code = Int(lines[i].trimmingCharacters(in: .whitespaces)), code >= 0, code <= 1071 else { throw DXFError.invalid("Invalid DXF group code at line \(i + 1).") }
            if code != 999 { pairs.append(DXFPair(code: code, value: lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        var section: String?
        var rawRecords: [DXFRecord] = []
        var unitCode = 0
        var index = 0
        var foundEntities = false
        var foundEOF = false
        while index < pairs.count {
            let pair = pairs[index]
            if pair.code == 0 && pair.value == "SECTION" {
                guard section == nil, index + 1 < pairs.count, pairs[index + 1].code == 2 else { throw DXFError.invalid("Invalid DXF section header.") }
                section = pairs[index + 1].value; index += 2
                if section == "ENTITIES" { foundEntities = true }
                continue
            }
            if pair.code == 0 && pair.value == "ENDSEC" { guard section != nil else { throw DXFError.invalid("Unmatched DXF ENDSEC.") }; section = nil; index += 1; continue }
            if pair.code == 0 && pair.value == "EOF" { foundEOF = true; break }
            if section == "HEADER", pair.code == 9, pair.value == "$INSUNITS" {
                guard index + 1 < pairs.count, pairs[index + 1].code == 70, let value = Int(pairs[index + 1].value) else { throw DXFError.invalid("Invalid DXF $INSUNITS value.") }
                unitCode = value
            }
            if section == "ENTITIES" {
                guard pair.code == 0 else { throw DXFError.invalid("DXF entity is missing its type marker.") }
                var end = index + 1
                while end < pairs.count && pairs[end].code != 0 { end += 1 }
                rawRecords.append(DXFRecord(type: pair.value, pairs: Array(pairs[(index + 1)..<end])))
                guard rawRecords.count <= 100_000 else { throw DXFError.invalid("DXF exceeds the 100,000-entity import limit.") }
                index = end; continue
            }
            index += 1
        }
        guard section == nil, foundEOF, foundEntities else { throw DXFError.invalid("DXF must contain a complete ENTITIES section and EOF marker.") }
        let unitScales: [Int: Double] = [0:0.001,1:0.0254,2:0.3048,3:1609.344,4:0.001,5:0.01,6:1,7:1000,8:0.0000000254,9:0.0000254,10:0.9144,11:1e-10,12:1e-9,13:1e-6,14:0.1,15:10,16:100,17:1e9,18:149597870700,19:9.4607304725808e15,20:3.085677581491367e16,21:1200.0/3937.0,22:100.0/3937.0,23:3600.0/3937.0,24:6336000.0/3937.0]
        guard let scale = metersPerUnit ?? unitScales[unitCode], scale.isFinite, scale > 0 else { throw DXFError.invalid("DXF units are unsupported. Choose an explicit unit override.") }
        func value(_ record: DXFRecord, _ code: Int, default fallback: Double? = nil) throws -> Double {
            guard let pair = record.pairs.first(where: { $0.code == code }) else {
                if let fallback { return fallback }
                throw DXFError.invalid("\(record.type) is missing coordinate/value \(code).")
            }
            guard let n = Double(pair.value), n.isFinite, abs(n) <= 1e12 else { throw DXFError.invalid("\(record.type) contains a nonfinite, invalid or out-of-range number.") }
            return n
        }
        func flags(_ record: DXFRecord, _ code: Int = 70) throws -> Int {
            let n = try value(record, code, default: 0)
            guard n.rounded() == n, n >= 0, n <= Double(Int32.max) else { throw DXFError.invalid("\(record.type) has invalid flags/count.") }; return Int(n)
        }
        func checkPlane(_ record: DXFRecord) throws {
            let x = try value(record, 210, default: 0), y = try value(record, 220, default: 0), z = try value(record, 230, default: 1)
            guard abs(x) < 1e-10, abs(y) < 1e-10, abs(z - 1) < 1e-10 else { throw DXFError.unsupported("\(record.type) uses a tilted or reversed extrusion plane. Export flat XY profiles instead.") }
            guard try value(record, 39, default: 0) == 0 else { throw DXFError.unsupported("DXF entity thickness is not supported. Export flat profiles instead.") }
        }
        func nameFor(_ record: DXFRecord, _ serial: Int) -> String {
            let layer = record.pairs.first(where: { $0.code == 8 })?.value
            return layer == nil || layer == "0" || layer == "" ? "\(record.type.capitalized) \(serial)" : layer!
        }
        func vec(_ p: DXFPoint) -> Vec3 { Vec3(p.x * scale, p.z * scale, -p.y * scale) }
        func wireEntity(_ inputPoints: [DXFPoint], closed: Bool, name: String) throws -> SketchEntity {
            var points = inputPoints
            if closed, points.count > 2, let first = points.first, let last = points.last, abs(first.x-last.x) + abs(first.y-last.y) + abs(first.z-last.z) < 1e-12 { points.removeLast() }
            guard points.count >= 2, points.count <= 250_000 else { throw DXFError.invalid("A DXF path needs at least two points and at most 250,000 points.") }
            var vertices: [Vec3] = [vec(points[0])]
            let segmentCount = closed ? points.count : points.count - 1
            for i in 0..<segmentCount {
                let a = points[i], b = points[(i + 1) % points.count]
                let dx = b.x - a.x, dy = b.y - a.y
                let chord = hypot(dx, dy)
                if chord < 1e-12 && abs(b.z - a.z) < 1e-12 { throw DXFError.invalid("DXF path contains a zero-length edge.") }
                var additions: [DXFPoint] = []
                if abs(a.bulge) > 1e-12 {
                    guard chord > 1e-12, abs(a.z - b.z) < 1e-10 else { throw DXFError.unsupported("Bulged DXF paths must lie in a single XY plane.") }
                    let theta = 4 * atan(a.bulge)
                    let centerOffset = chord * (1 - a.bulge * a.bulge) / (4 * a.bulge)
                    let cx = (a.x + b.x) / 2 - dy / chord * centerOffset
                    let cy = (a.y + b.y) / 2 + dx / chord * centerOffset
                    let radius = hypot(a.x - cx, a.y - cy)
                    let start = atan2(a.y - cy, a.x - cx)
                    let steps = max(2, Int(ceil(abs(theta) / (.pi / 36))))
                    additions = (1...steps).map { step in
                        let angle = start + theta * Double(step) / Double(steps)
                        return step == steps ? b : DXFPoint(x: cx + radius * cos(angle), y: cy + radius * sin(angle), z: a.z)
                    }
                } else { additions = [b] }
                if closed && i == segmentCount - 1 { additions.removeLast() }
                vertices += additions.map(vec)
                guard vertices.count <= 250_000 else { throw DXFError.invalid("DXF tessellation exceeds the vertex import limit.") }
            }
            var indices: [Int] = []
            if vertices.count >= 2 { for i in 0..<(vertices.count - 1) { indices += [i, i + 1] } }
            if closed { indices += [vertices.count - 1, 0] }
            let xs = vertices.map(\.x), ys = vertices.map(\.y), zs = vertices.map(\.z)
            return SketchEntity(name: name, kind: .mesh, origin: Vec3(0,0,0), width: xs.max()! - xs.min()!, depth: zs.max()! - zs.min()!, height: ys.max()! - ys.min()!, colorHex: "#353B3C", mesh: MeshData(vertices: vertices, triangles: [], lineIndices: indices))
        }
        func surfaceEntity(_ vertices: [Vec3], _ triangles: [Int], name: String) throws -> SketchEntity {
            guard !vertices.isEmpty, !triangles.isEmpty, triangles.allSatisfy({ vertices.indices.contains($0) }) else { throw DXFError.invalid("DXF face indices are incomplete or out of range.") }
            for i in stride(from: 0, to: triangles.count, by: 3) { try dxfValidateTriangle(vertices[triangles[i]],vertices[triangles[i+1]],vertices[triangles[i+2]]) }
            return SketchEntity(name:name,kind:.mesh,origin:Vec3(0,0,0),width:vertices.map(\.x).max()! - vertices.map(\.x).min()!,depth:vertices.map(\.z).max()! - vertices.map(\.z).min()!,height:vertices.map(\.y).max()! - vertices.map(\.y).min()!,mesh:MeshData(vertices:vertices,triangles:triangles))
        }
        var entities: [SketchEntity] = []
        index = 0
        while index < rawRecords.count {
            let record = rawRecords[index]
            let entityName = nameFor(record, entities.count + 1)
            try checkPlane(record)
            switch record.type {
            case "3DFACE":
                var vertices: [Vec3] = []
                for slot in 0..<4 {
                    if slot == 3 && !record.pairs.contains(where: { $0.code == 13 }) { vertices.append(vertices[2]); continue }
                    vertices.append(vec(DXFPoint(x:try value(record,10+slot),y:try value(record,20+slot),z:try value(record,30+slot,default:0))))
                }
                let triangles = vertices[2] == vertices[3] ? [0,1,2] : [0,1,2,0,2,3]
                if vertices[2] == vertices[3] { vertices.removeLast() }
                entities.append(try surfaceEntity(vertices,triangles,name:entityName))
            case "SPLINE":
                let state = try flags(record), degree = try flags(record,71)
                guard state & ~31 == 0, degree >= 1, degree <= 16 else { throw DXFError.unsupported("Unsupported DXF spline degree or flags.") }
                func numbers(_ code: Int) throws -> [Double] {
                    try record.pairs.filter { $0.code == code }.map { pair in
                        guard let n = Double(pair.value), n.isFinite, abs(n) <= 1e12 else { throw DXFError.invalid("Invalid DXF spline number.") }
                        return n
                    }
                }
                let knots = try numbers(40), xs = try numbers(10), ys = try numbers(20), zs = try numbers(30)
                var weights = try numbers(41)
                guard xs.count > degree, xs.count <= 100_000, xs.count == ys.count, zs.isEmpty || zs.count == xs.count,
                      try flags(record,72) == knots.count, try flags(record,73) == xs.count,
                      knots.count == xs.count + degree + 1, zip(knots,knots.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw DXFError.invalid("DXF spline control points or knot vector are incomplete.") }
                if weights.isEmpty { weights = Array(repeating:1,count:xs.count) }
                guard weights.count == xs.count, weights.allSatisfy({ $0 > 0 }) else { throw DXFError.invalid("DXF spline weights must be positive and match the control points.") }
                let lower = knots[degree], upper = knots[xs.count]
                guard lower < upper else { throw DXFError.invalid("DXF spline has an empty parameter domain.") }
                // Discontinuous knot vectors cannot be represented by one connected wire.
                var multiplicity = 0, previous: Double?
                for knot in knots {
                    multiplicity = knot == previous ? multiplicity + 1 : 1; previous = knot
                    guard knot <= lower || knot >= upper || multiplicity <= degree else { throw DXFError.unsupported("Discontinuous DXF splines must be split into separate curves.") }
                }
                let controls = xs.indices.map { i in [xs[i]*weights[i],ys[i]*weights[i],(zs.isEmpty ? 0 : zs[i])*weights[i],weights[i]] }
                func evaluate(_ t: Double, span: Int) throws -> DXFPoint {
                    var d = (0...degree).map { controls[span-degree+$0] }
                    for r in 1...degree {
                        for j in stride(from:degree,through:r,by:-1) {
                            let k = span-degree+j, divisor = knots[k+degree-r+1]-knots[k]
                            let alpha = divisor == 0 ? 0 : (t-knots[k])/divisor
                            for axis in 0..<4 { d[j][axis] = (1-alpha)*d[j-1][axis] + alpha*d[j][axis] }
                        }
                    }
                    let v = d[degree]
                    guard v.allSatisfy(\.isFinite), v[3] > 0 else { throw DXFError.invalid("DXF spline evaluation exceeded supported range.") }
                    return DXFPoint(x:v[0]/v[3],y:v[1]/v[3],z:v[2]/v[3])
                }
                var points: [DXFPoint] = []
                for span in degree..<xs.count where knots[span] < knots[span+1] {
                    guard points.count + 73 <= 250_000 else { throw DXFError.invalid("DXF spline tessellation exceeds the vertex limit.") }
                    for step in 0...72 where points.isEmpty || step != 0 {
                        let t = knots[span] + (knots[span+1]-knots[span])*Double(step)/72
                        points.append(try evaluate(t,span:span))
                    }
                }
                let closed = state & 3 != 0
                if closed, let first = points.first, let last = points.last {
                    guard hypot(hypot(first.x-last.x,first.y-last.y),first.z-last.z) <= 1e-8 * max(1,abs(first.x),abs(first.y),abs(first.z)) else { throw DXFError.unsupported("Closed DXF spline control points do not define a closed curve.") }
                    points[points.count-1] = first
                }
                entities.append(try wireEntity(points,closed:closed,name:entityName))
            case "ELLIPSE":
                let cx = try value(record,10), cy = try value(record,20), z = try value(record,30,default:0)
                let ax = try value(record,11), ay = try value(record,21), az = try value(record,31,default:0)
                let ratio = try value(record,40), start = try value(record,41,default:0), end = try value(record,42,default:2 * .pi)
                guard abs(az) < 1e-10 else { throw DXFError.unsupported("Tilted DXF ellipses are not supported.") }
                guard hypot(ax,ay) > 0, ratio > 0, ratio <= 1, start >= 0, start < 2 * .pi, end > 0, end <= 2 * .pi else { throw DXFError.invalid("Invalid DXF ellipse axes, ratio or parameter interval.") }
                var sweep = end - start
                if sweep <= 0 { sweep += 2 * .pi }
                let closed = abs(sweep - 2 * .pi) < 1e-10
                let steps = max(2,Int(ceil(sweep / (.pi/36))))
                let points = (0...(closed ? steps-1 : steps)).map { i -> DXFPoint in
                    let t = start + sweep * Double(i)/Double(steps)
                    return DXFPoint(x:cx + ax*cos(t) - ay*ratio*sin(t), y:cy + ay*cos(t) + ax*ratio*sin(t),z:z)
                }
                entities.append(try wireEntity(points,closed:closed,name:entityName))
            case "LINE":
                let a = DXFPoint(x: try value(record,10), y: try value(record,20), z: try value(record,30,default:0))
                let b = DXFPoint(x: try value(record,11), y: try value(record,21), z: try value(record,31,default:0))
                let start = vec(a), end = vec(b)
                entities.append(SketchEntity(name: entityName, kind: .line, origin: start, width: end.x-start.x, depth: end.z-start.z, height: end.y-start.y, colorHex: "#353B3C"))
            case "CIRCLE", "ARC":
                let cx = try value(record,10), cy = try value(record,20), z = try value(record,30,default:0), radius = try value(record,40)
                guard radius > 0 else { throw DXFError.invalid("DXF circle/arc radius must be positive.") }
                if record.type == "CIRCLE" {
                    entities.append(SketchEntity(name: entityName, kind: .circle, origin: vec(DXFPoint(x:cx,y:cy,z:z)), width: radius*2*scale, depth: radius*2*scale, colorHex: "#353B3C"))
                } else {
                    let start = try value(record,50) * .pi / 180, end = try value(record,51) * .pi / 180
                    var sweep = (end-start).truncatingRemainder(dividingBy: .pi*2)
                    if sweep < 0 { sweep += .pi*2 }
                    guard sweep > 1e-12 else { throw DXFError.invalid("DXF arc must have a nonzero sweep.") }
                    let steps = max(2,Int(ceil(sweep / (.pi/36))))
                    let points = (0...steps).map { i in DXFPoint(x:cx+radius*cos(start+sweep*Double(i)/Double(steps)),y:cy+radius*sin(start+sweep*Double(i)/Double(steps)),z:z) }
                    entities.append(try wireEntity(points, closed: false, name: entityName))
                }
            case "LWPOLYLINE":
                let count = try flags(record,90), state = try flags(record)
                guard state & ~129 == 0 else { throw DXFError.unsupported("Unsupported LWPOLYLINE flags.") }
                let elevation = try value(record,38,default:0)
                guard try value(record,43,default:0) == 0 else { throw DXFError.unsupported("Wide DXF polylines are not supported. Export centerline profiles.") }
                var points: [DXFPoint] = []
                var hasY: [Bool] = []
                for pair in record.pairs {
                    if pair.code == 10 {
                        guard let n = Double(pair.value), n.isFinite else { throw DXFError.invalid("Invalid polyline X coordinate.") }
                        points.append(DXFPoint(x:n,y:0,z:elevation)); hasY.append(false)
                    } else if [20,42,40,41].contains(pair.code) {
                        guard !points.isEmpty, let n = Double(pair.value), n.isFinite else { throw DXFError.invalid("Invalid polyline vertex.") }
                        if pair.code == 20 { points[points.count-1].y = n; hasY[hasY.count-1] = true }
                        if pair.code == 42 { points[points.count-1].bulge = n }
                        if (pair.code == 40 || pair.code == 41) && n != 0 { throw DXFError.unsupported("Wide DXF polyline vertices are not supported.") }
                    }
                }
                guard points.count == count, hasY.allSatisfy({$0}) else { throw DXFError.invalid("LWPOLYLINE vertex count or coordinates are incomplete.") }
                entities.append(try wireEntity(points,closed:state & 1 != 0,name:entityName))
            case "POLYLINE":
                let state = try flags(record)
                if state & 64 != 0 {
                    guard state & ~65 == 0 else { throw DXFError.unsupported("Unsupported polyface POLYLINE flags.") }
                    var vertices: [Vec3] = [], faces: [[Int]] = []
                    index += 1
                    while index < rawRecords.count && rawRecords[index].type == "VERTEX" {
                        let vertex = rawRecords[index], vertexFlags = try flags(vertex)
                        try checkPlane(vertex)
                        if vertexFlags == 192 {
                            guard faces.isEmpty else { throw DXFError.invalid("Polyface coordinates must precede face records.") }
                            vertices.append(vec(DXFPoint(x:try value(vertex,10),y:try value(vertex,20),z:try value(vertex,30,default:0))))
                        } else if vertexFlags == 128 {
                            var face: [Int] = []
                            for code in 71...74 {
                                let n = try value(vertex,code,default:0)
                                guard n.rounded() == n, abs(n) <= 250_000 else { throw DXFError.invalid("Invalid polyface index.") }
                                if n == 0 { if code < 74 { throw DXFError.invalid("Incomplete polyface triangle.") }; continue }
                                face.append(Int(abs(n))-1)
                            }
                            guard face.count >= 3 else { throw DXFError.invalid("Incomplete polyface face.") }
                            faces.append(face)
                        } else { throw DXFError.unsupported("Unsupported polyface vertex flags.") }
                        index += 1
                    }
                    guard index < rawRecords.count, rawRecords[index].type == "SEQEND" else { throw DXFError.invalid("POLYLINE is missing SEQEND.") }
                    let triangles = faces.flatMap { $0.count == 3 ? $0 : [$0[0],$0[1],$0[2],$0[0],$0[2],$0[3]] }
                    entities.append(try surfaceEntity(vertices,triangles,name:entityName))
                    break
                }
                guard state & ~137 == 0 else { throw DXFError.unsupported("Fitted or polygon-mesh POLYLINE is not supported.") }
                guard try value(record,40,default:0) == 0, try value(record,41,default:0) == 0 else { throw DXFError.unsupported("Wide DXF polylines are not supported.") }
                let elevation = try value(record,30,default:0)
                var points: [DXFPoint] = []
                index += 1
                while index < rawRecords.count && rawRecords[index].type == "VERTEX" {
                    let vertex = rawRecords[index]; try checkPlane(vertex)
                    guard try flags(vertex) == (state & 8 != 0 ? 32 : 0) else { throw DXFError.unsupported("Fitted or invalid DXF vertices are not supported.") }
                    guard try value(vertex,40,default:0) == 0, try value(vertex,41,default:0) == 0 else { throw DXFError.unsupported("Wide DXF vertices are not supported.") }
                    points.append(DXFPoint(x:try value(vertex,10),y:try value(vertex,20),z:state & 8 != 0 ? try value(vertex,30,default:0) : elevation,bulge:try value(vertex,42,default:0)))
                    index += 1
                }
                guard index < rawRecords.count, rawRecords[index].type == "SEQEND" else { throw DXFError.invalid("POLYLINE is missing SEQEND.") }
                entities.append(try wireEntity(points,closed:state & 1 != 0,name:entityName))
            default: throw DXFError.unsupported("Unsupported DXF entity \(record.type). Export supported curves, 3DFACE or POLYLINE geometry; explode blocks and convert text first.")
            }
            index += 1
        }
        guard !entities.isEmpty else { throw DXFError.invalid("The DXF contains no supported vector geometry.") }
        let model = ModelDocument(entities: entities,name:name)
        try model.validate()
        return model
    }
}

private func dxfValidateTriangle(_ a: Vec3, _ b: Vec3, _ c: Vec3) throws {
    let u = Vec3(b.x-a.x,b.y-a.y,b.z-a.z), v = Vec3(c.x-a.x,c.y-a.y,c.z-a.z)
    let n = Vec3(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
    let size = hypot(hypot(n.x,n.y),n.z)
    guard size.isFinite, size > 0 else { throw DXFError.invalid("DXF contains a degenerate face.") }
}
