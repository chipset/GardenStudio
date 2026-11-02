import Foundation

public enum GeometryIOError: Error, LocalizedError, Equatable {
    case invalid(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self { case let .invalid(message), let .unsupported(message): return message }
    }
}

/// Normalized texture coordinates in the renderer/glTF convention (V=0 at the image top).
public struct TextureCoordinate: Codable, Equatable {
    public var u: Double
    public var v: Double
    public init(u: Double, v: Double) { self.u = u; self.v = v }
}

public struct MeshData: Codable, Equatable {
    public var vertices: [Vec3]
    public var triangles: [Int]
    public var lineIndices: [Int]
    public var textureCoordinates: [TextureCoordinate]?

    public init(vertices: [Vec3] = [], triangles: [Int] = [], lineIndices: [Int] = [], textureCoordinates: [TextureCoordinate]? = nil) {
        self.vertices = vertices; self.triangles = triangles; self.lineIndices = lineIndices; self.textureCoordinates = textureCoordinates
    }

    public func validate() throws {
        guard !vertices.isEmpty, vertices.count <= 250_000,
              triangles.count <= 1_500_000, lineIndices.count <= 1_000_000 else {
            throw GeometryIOError.invalid("Mesh is empty or exceeds the supported geometry size.")
        }
        guard triangles.count % 3 == 0, lineIndices.count % 2 == 0,
              !triangles.isEmpty || !lineIndices.isEmpty else {
            throw GeometryIOError.invalid("Mesh must contain complete triangles or line pairs.")
        }
        if let textureCoordinates {
            guard textureCoordinates.count == vertices.count,
                  textureCoordinates.allSatisfy({ $0.u.isFinite && $0.v.isFinite && Float($0.u).isFinite && Float($0.v).isFinite }) else {
                throw GeometryIOError.invalid("Mesh texture coordinates must be finite and match the vertex count.")
            }
        }
        guard vertices.allSatisfy(\.isRendererRepresentable),
              triangles.allSatisfy({ vertices.indices.contains($0) }),
              lineIndices.allSatisfy({ vertices.indices.contains($0) }) else {
            throw GeometryIOError.invalid("Mesh contains invalid coordinates or vertex indices.")
        }
    }
}

public enum TextureTools {
    /// Generates box-projected per-face UVs while duplicating triangle corners at seams.
    public static func generatePlanarUVs(_ source:MeshData)throws->MeshData {
        try source.validate()
        let expanded=source.vertices.count+source.triangles.count
        guard expanded<=250_000 else{throw GeometryIOError.invalid("Planar UV generation would exceed the 250,000 vertex limit; unwrap a smaller selection.")}
        var vertices=source.vertices
        var coordinates=source.vertices.map{TextureCoordinate(u:$0.x,v:$0.z)}
        var triangles:[Int]=[];triangles.reserveCapacity(source.triangles.count)
        for start in stride(from:0,to:source.triangles.count,by:3) {
            let indices=Array(source.triangles[start..<(start+3)])
            let a=source.vertices[indices[0]],b=source.vertices[indices[1]],c=source.vertices[indices[2]]
            let ab=Vec3(b.x-a.x,b.y-a.y,b.z-a.z),ac=Vec3(c.x-a.x,c.y-a.y,c.z-a.z)
            let normal=Vec3(ab.y*ac.z-ab.z*ac.y,ab.z*ac.x-ab.x*ac.z,ab.x*ac.y-ab.y*ac.x)
            let absolute=[abs(normal.x),abs(normal.y),abs(normal.z)]
            let axis=absolute[0]>absolute[1] && absolute[0]>absolute[2] ? 0:(absolute[1]>absolute[2] ? 1:2)
            for sourceIndex in indices {
                let point=source.vertices[sourceIndex],index=vertices.count
                vertices.append(point)
                let uv:TextureCoordinate
                switch axis {
                case 0:uv=TextureCoordinate(u:point.z,v:point.y)
                case 1:uv=TextureCoordinate(u:point.x,v:point.z)
                default:uv=TextureCoordinate(u:point.x,v:point.y)
                }
                coordinates.append(uv);triangles.append(index)
            }
        }
        let result=MeshData(vertices:vertices,triangles:triangles,lineIndices:source.lineIndices,textureCoordinates:coordinates)
        try result.validate();return result
    }
}

extension SketchEntity {
    /// Shared primitive vertices keep the document's range validation identical
    /// to the geometry actually emitted for rendering and interchange.
    private var primitiveBaseVertices: [Vec3] {
        if kind == .rectangle {
            return [Vec3(-width/2,0,-depth/2),Vec3(width/2,0,-depth/2),Vec3(width/2,0,depth/2),Vec3(-width/2,0,depth/2)]
        }
        return (0..<48).map { index in
            let angle = Double(index) * .pi * 2 / 48
            return Vec3(cos(angle)*width/2,0,sin(angle)*depth/2)
        }
    }

    func validateRenderCoordinates() throws {
        guard origin.isRendererRepresentable else {
            throw ModelValidationError.invalidEntity(id,"Object placement exceeds the renderer's finite coordinate range.")
        }
        let points: [Vec3]
        switch kind {
        case .mesh: points=mesh?.vertices ?? []
        case .line: points=[Vec3(0,0,0),Vec3(width,height,depth)]
        case .rectangle,.circle:
            let base=primitiveBaseVertices
            points=height>0 ? base+base.map{Vec3($0.x,height,$0.z)}:base
        }
        let cosine=cos(rotation),sine=sin(rotation)
        guard points.allSatisfy({ point in
            guard point.isRendererRepresentable else{return false}
            // A final Double coordinate can be representable even when rotation
            // already overflowed in Float32 and translation only cancels it later.
            let rotated=Vec3(cosine*point.x+sine*point.z,point.y,-sine*point.x+cosine*point.z)
            guard rotated.isRendererRepresentable,
                  Vec3(origin.x+rotated.x,origin.y+rotated.y,origin.z+rotated.z).isRendererRepresentable else{return false}
            let x=Float(point.x),y=Float(point.y),z=Float(point.z),c=Float(cosine),s=Float(sine)
            let rotatedX=c*x+s*z,rotatedZ = -s*x+c*z
            return [rotatedX,rotatedZ,Float(origin.x)+rotatedX,Float(origin.y)+y,Float(origin.z)+rotatedZ].allSatisfy(\.isFinite)
        }) else {
            throw ModelValidationError.invalidEntity(id,"Object geometry exceeds the renderer's finite coordinate range while rotating or placing it.")
        }
    }

    /// Builds the same untransformed geometry used for drawing and UV projection
    /// without calling document validation recursively.
    private func localMeshData() throws -> MeshData {
        var result = MeshData()
        switch kind {
        case .mesh:
            guard let mesh else { throw GeometryIOError.invalid("The imported object has no mesh data.") }
            try mesh.validate()
            result = mesh
        case .line:
            result = MeshData(vertices: [Vec3(0,0,0),Vec3(width,height,depth)], lineIndices: [0,1])
        case .rectangle, .circle:
            let base=primitiveBaseVertices
            let n = base.count
            result.vertices = base
            if height > 0 {
                result.vertices += base.map { Vec3($0.x,height,$0.z) }
                for index in 1..<(n-1) {
                    result.triangles += [0,index,index+1,n,n+index+1,n+index]
                }
                for index in 0..<n {
                    let next = (index + 1) % n
                    result.triangles += [index,index+n,next+n,index,next+n,next]
                }
            } else {
                for index in 1..<(n-1) { result.triangles += [0,index+1,index] }
            }
        }
        try result.validate()
        return result
    }

    /// Checks only textured triangles with their actual paint assignment. A
    /// finite raw UV can overflow after the material's repeat/rotation matrix.
    func validateTextureTransformCoordinates() throws {
        guard let surface,
              surface.textureData != nil || surface.faceOverrides.contains(where:{$0.textureData != nil}) else{return}
        let local=try localMeshData(),count=local.triangles.count/3
        func coefficients(_ texture:Data?,_ scale:Double,_ angle:Double)->(Float,Float)? {
            guard texture != nil else{return nil}
            return (Float(cos(angle)/scale),Float(sin(angle)/scale))
        }
        let transforms=[coefficients(surface.textureData,surface.textureScale,surface.textureRotation)] +
            surface.faceOverrides.map{coefficients($0.textureData,$0.textureScale,$0.textureRotation)}
        // Most models are far inside the Float32 range. A conservative global
        // bound avoids per-triangle assignment/projection work in that case.
        // A large untextured region only disables this shortcut; it never fails it.
        let coefficientBound=transforms.compactMap{$0}.map{Double(abs($0.0))+Double(abs($0.1))}.max() ?? 0
        let coordinateBound:Double
        if let uv=local.textureCoordinates {
            coordinateBound=uv.reduce(0){max($0,max(abs($1.u),abs($1.v)))}
        } else {
            coordinateBound=local.vertices.reduce(0){max($0,max(abs($1.x),max(abs($1.y),abs($1.z))))}
        }
        if coordinateBound*coefficientBound<Double(Float.greatestFiniteMagnitude)/2 {return}
        var assignments=Array(repeating:0,count:count)
        for (index,face) in surface.faceOverrides.enumerated() {
            for triangle in face.triangleIndices {assignments[triangle]=index+1}
        }
        for triangle in 0..<count {
            guard let (cosine,sine)=transforms[assignments[triangle]] else{continue}
            let start=triangle*3
            let a=local.vertices[local.triangles[start]],b=local.vertices[local.triangles[start+1]],c=local.vertices[local.triangles[start+2]]
            let ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z
            let nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx
            for corner in 0..<3 {
                let index=local.triangles[start+corner],point=local.vertices[index]
                let u:Float,v:Float
                if let uv=local.textureCoordinates {u=Float(uv[index].u);v=Float(uv[index].v)}
                else if abs(nx)>=abs(ny) && abs(nx)>=abs(nz) {u=Float(point.z);v=Float(point.y)}
                else if abs(ny)>=abs(nz) {u=Float(point.x);v=Float(point.z)}
                else {u=Float(point.x);v=Float(point.y)}
                guard (cosine*u-sine*v).isFinite,(sine*u+cosine*v).isFinite else {
                    throw ModelValidationError.invalidEntity(id,"Texture size and rotation exceed the renderer's finite UV range.")
                }
            }
        }
    }

    /// Retains the original local-meter paint projection when an edit bakes the
    /// object's rotation into its vertices. UV seams keep face-specific axes
    /// distinct; the paint's own size/rotation remains on the surface material.
    func meshForTransformBaking() throws -> MeshData {
        let world=try triangulatedMesh()
        guard world.textureCoordinates == nil,
              surface?.textureData != nil || surface?.faceOverrides.contains(where:{$0.textureData != nil}) == true else{return world}
        let local=try localMeshData()
        struct ProjectedVertex:Hashable {let source:Int;let u:Double;let v:Double}
        var result=MeshData(textureCoordinates:[]),mapped:[ProjectedVertex:Int]=[:]
        func vertex(_ source:Int,_ u:Double,_ v:Double)throws->Int {
            let key=ProjectedVertex(source:source,u:u,v:v)
            if let known=mapped[key] {return known}
            guard result.vertices.count<250_000 else {throw GeometryIOError.invalid("Texture seams expand this edit beyond the 250,000 vertex limit.")}
            let index=result.vertices.count
            result.vertices.append(world.vertices[source])
            result.textureCoordinates!.append(TextureCoordinate(u:u,v:v))
            mapped[key]=index
            return index
        }
        for start in stride(from:0,to:local.triangles.count,by:3) {
            let a=local.vertices[local.triangles[start]],b=local.vertices[local.triangles[start+1]],c=local.vertices[local.triangles[start+2]]
            let ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z
            let nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx
            for corner in 0..<3 {
                let source=local.triangles[start+corner],point=local.vertices[source]
                let u:Double,v:Double
                if abs(nx)>=abs(ny) && abs(nx)>=abs(nz) {u=point.z;v=point.y}
                else if abs(ny)>=abs(nz) {u=point.x;v=point.z}
                else {u=point.x;v=point.y}
                result.triangles.append(try vertex(source,u,v))
            }
        }
        for source in local.lineIndices {
            let point=local.vertices[source]
            result.lineIndices.append(try vertex(source,point.x,point.z))
        }
        try result.validate()
        return result
    }

    /// Returns real geometry in world coordinates (meters, Y up).
    public func triangulatedMesh() throws -> MeshData {
        var geometryOnly = self; geometryOnly.metadata = nil
        try ModelDocument(entities: [geometryOnly]).validate()
        var result=try localMeshData()
        let cosine = cos(rotation), sine = sin(rotation)
        result.vertices = result.vertices.map {
            Vec3(origin.x + cosine*$0.x + sine*$0.z, origin.y + $0.y, origin.z - sine*$0.x + cosine*$0.z)
        }
        try result.validate()
        return result
    }
}
