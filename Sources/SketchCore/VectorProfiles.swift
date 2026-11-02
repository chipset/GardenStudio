import Foundation

public struct VectorPoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct VectorPath: Codable, Equatable {
    public var points: [VectorPoint]
    public var closed: Bool
    public var name: String
    public var colorHex: String
    public init(points: [VectorPoint], closed: Bool, name: String = "Path", colorHex: String = "#353B3C") {
        self.points = points; self.closed = closed; self.name = name; self.colorHex = colorHex
    }
}

/// Explicit top-view outlines, in meters, with model X/−Z as drawing X/Y.
public enum VectorProfiles {
    public static func paths(document: ModelDocument) throws -> [VectorPath] {
        try document.validate()
        var result: [VectorPath] = []
        for entity in document.entities {
            func world(_ p: Vec3) -> VectorPoint {
                let c = cos(entity.rotation), s = sin(entity.rotation)
                return VectorPoint(x:entity.origin.x+c*p.x+s*p.z,y: -(entity.origin.z-s*p.x+c*p.z))
            }
            func append(_ points: [VectorPoint], closed: Bool) throws {
                let p = VectorPath(points:points,closed:closed,name:entity.name,colorHex:entity.colorHex)
                try validate(p); result.append(p)
            }
            switch entity.kind {
            case .line: try append([world(Vec3(0,0,0)),world(Vec3(entity.width,entity.height,entity.depth))],closed:false)
            case .rectangle:
                try append([Vec3(-entity.width/2,0,-entity.depth/2),Vec3(entity.width/2,0,-entity.depth/2),Vec3(entity.width/2,0,entity.depth/2),Vec3(-entity.width/2,0,entity.depth/2)].map(world),closed:true)
            case .circle:
                try append((0..<144).map { let a = Double($0)*2*Double.pi/144; return world(Vec3(cos(a)*entity.width/2,0,sin(a)*entity.depth/2)) },closed:true)
            case .mesh:
                if entity.profile != nil {
                    let p = try GeometryTools.worldProfile(of:entity)
                    for ring in [p.outer]+p.holes { try append(ring.map { VectorPoint(x:$0.x,y: -$0.z) },closed:true) }
                } else {
                    guard let mesh = entity.mesh, mesh.triangles.isEmpty, !mesh.lineIndices.isEmpty else { throw GeometryIOError.invalid("\(entity.name) is a surface mesh. Use STL; vector export requires explicit profile edges.") }
                    // Preserve connected ordered wire chains, splitting at discontinuities.
                    var chain: [Int] = []
                    func flush() throws {
                        guard chain.count >= 2 else { return }
                        let closed = chain.first == chain.last
                        try append((closed ? Array(chain.dropLast()) : chain).map { world(mesh.vertices[$0]) },closed:closed)
                        chain.removeAll(keepingCapacity:true)
                    }
                    for i in stride(from:0,to:mesh.lineIndices.count,by:2) {
                        let a = mesh.lineIndices[i], b = mesh.lineIndices[i+1]
                        if chain.last != a { try flush(); chain = [a] }
                        chain.append(b)
                        if chain.first == chain.last { try flush() }
                    }
                    try flush()
                }
            }
        }
        guard !result.isEmpty else { throw GeometryIOError.invalid("The model contains no vector profiles.") }
        return result
    }

    public static func document(paths: [VectorPath], name: String) throws -> ModelDocument {
        guard !paths.isEmpty, paths.count <= 50_000 else { throw GeometryIOError.invalid("Vector files need 1–50,000 paths.") }
        let entities = try paths.map { p -> SketchEntity in
            try validate(p)
            let vertices = p.points.map { Vec3($0.x,0,-$0.y) }
            var indices: [Int] = []
            for i in 1..<vertices.count { indices += [i-1,i] }
            if p.closed { indices += [vertices.count-1,0] }
            return SketchEntity(name:p.name,kind:.mesh,origin:Vec3(0,0,0),width:p.points.map(\.x).max()!-p.points.map(\.x).min()!,depth:p.points.map(\.y).max()!-p.points.map(\.y).min()!,colorHex:p.colorHex,mesh:MeshData(vertices:vertices,triangles:[],lineIndices:indices))
        }
        let doc = ModelDocument(entities:entities,name:name)
        try doc.validate(); return doc
    }

    private static func validate(_ p: VectorPath) throws {
        guard p.points.count >= (p.closed ? 3 : 2), p.points.count <= 250_000, p.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1e12 && abs($0.y) <= 1e12 }) else { throw GeometryIOError.invalid("A vector path contains missing, invalid or excessive points.") }
        for i in 1..<(p.points.count + (p.closed ? 1 : 0)) {
            let a = p.points[i-1], b = p.points[i % p.points.count]
            guard hypot(a.x-b.x,a.y-b.y) > 1e-12 else { throw GeometryIOError.invalid("A vector path has a zero-length edge or is edge-on in the top view.") }
        }
        if p.closed {
            var area = 0.0
            for i in p.points.indices { let a=p.points[i],b=p.points[(i+1)%p.points.count]; area += a.x*b.y-b.x*a.y }
            guard abs(area) > 1e-18 else { throw GeometryIOError.invalid("A closed profile has no area in the top view. Use STL for 3D geometry.") }
        }
    }
}
