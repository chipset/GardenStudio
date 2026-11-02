import Foundation

/// Boundary loops in the entity's local coordinates. Outer winding defines the face normal.
public struct FaceProfile: Codable, Equatable {
    public var outer: [Vec3]
    public var holes: [[Vec3]]
    public init(outer: [Vec3], holes: [[Vec3]] = []) { self.outer = outer; self.holes = holes }
    public func validate() throws { _ = try PGSurface(self) }
}

public enum GeometryTools {
    /// Adds a connected edge, automatically closes simple planar loops, and splits crossed faces.
    public static func connectLine(document: ModelDocument, start: Vec3, end: Vec3, tolerance: Double = 1e-6, editingGroupID: UUID? = nil) throws -> ModelDocument {
        try document.validate()
        guard tolerance.isFinite,tolerance>0,tolerance<=0.1,
              [start,end].allSatisfy({[$0.x,$0.y,$0.z].allSatisfy(\.isFinite)}),pgLength(pgSub(end,start))>tolerance else {
            throw GeometryIOError.invalid("A connected line needs two distinct finite endpoints and a valid tolerance.")
        }
        if let group=editingGroupID,document.editor?.groups.contains(where:{$0.id==group}) != true {throw GeometryIOError.invalid("The editing group no longer exists.")}
        let sourceLines=document.entities.filter{$0.kind == .line && $0.metadata?.groupID == editingGroupID && $0.isEditable(in:document) && $0.isVisible(in:document)}
        guard sourceLines.count<=8000 else {throw GeometryIOError.unsupported("Automatic face connection is limited to 8,000 edges in one editing context.")}
        let sourceGeometry=try sourceLines.map {line->(GardenEntity,Vec3,Vec3) in let mesh=try line.triangulatedMesh();return(line,mesh.vertices[0],mesh.vertices[1])}
        func snapToEdge(_ point:Vec3)->Vec3 {
            var nearest=point,best=tolerance
            for (_,a,b) in sourceGeometry {let edge=pgSub(b,a),length=pgDot(edge,edge);guard length>0 else{continue};let t=max(0,min(1,pgDot(pgSub(point,a),edge)/length)),candidate=pgAdd(a,pgMul(edge,t)),distance=pgLength(pgSub(candidate,point));if distance<=best{nearest=candidate;best=distance}}
            return nearest
        }
        let snappedStart=snapToEdge(start),snappedEnd=snapToEdge(end)
        var replacements:[UUID:[GardenEntity]]=[:],existing:[GardenEntity]=[]
        for (source,a,b) in sourceGeometry {
            let edge=pgSub(b,a),length=pgDot(edge,edge)
            var parameters=[0.0,1.0]
            for endpoint in [snappedStart,snappedEnd] {
                let t=pgDot(pgSub(endpoint,a),edge)/length
                if t>0,t<1,pgLength(pgSub(pgAdd(a,pgMul(edge,t)),endpoint))<=tolerance,parameters.allSatisfy({abs($0-t)*sqrt(length)>tolerance}) {parameters.append(t)}
            }
            if parameters.count==2 {replacements[source.id]=[source];existing.append(source);continue}
            parameters.sort();var parts:[GardenEntity]=[]
            for i in 0..<(parameters.count-1) {
                let p=pgAdd(a,pgMul(edge,parameters[i])),q=pgAdd(a,pgMul(edge,parameters[i+1])),delta=pgSub(q,p)
                var part=source;part.id=i==0 ? source.id:UUID();part.origin=p;part.rotation=0;part.width=delta.x;part.height=delta.y;part.depth=delta.z
                if i>0,part.metadata?.componentPartID != nil {part.metadata?.componentPartID=UUID()}
                parts.append(part)
            }
            replacements[source.id]=parts;existing += parts
        }
        var vertices:[Vec3]=[],adjacency:[Int:Set<Int>]=[:]
        func node(_ point:Vec3)->Int {
            if let index=vertices.firstIndex(where:{pgLength(pgSub($0,point))<=tolerance}) {return index}
            vertices.append(point);return vertices.count-1
        }
        for line in existing {
            let mesh=try line.triangulatedMesh(),a=node(mesh.vertices[0]),b=node(mesh.vertices[1])
            guard a != b else {continue}
            adjacency[a,default:[]].insert(b);adjacency[b,default:[]].insert(a)
        }
        let aIndex=node(snappedStart),bIndex=node(snappedEnd)
        guard aIndex != bIndex,adjacency[aIndex]?.contains(bIndex) != true else {throw GeometryIOError.invalid("That edge already exists or its endpoints coincide.")}
        let a=vertices[aIndex],b=vertices[bIndex]
        var result=document
        result.entities=document.entities.flatMap{replacements[$0.id] ?? [$0]}
        let delta=pgSub(b,a)
        let line=GardenEntity(name:"Line \(existing.count+1)",kind:.line,origin:a,width:delta.x,depth:delta.z,height:delta.y,colorHex:"#353B3C",metadata:editingGroupID.map{EntityMetadata(groupID:$0)})
        result.entities.append(line)
        var didSplit=false
        for entity in document.entities where entity.metadata?.groupID == editingGroupID && entity.isEditable(in:document) && entity.isVisible(in:document) {
            guard let profile=try? worldProfile(of:entity),let surface=try? PGSurface(profile),let cut=try? pgBasePoints([a,b],entity:entity,plane:surface.plane) else {continue}
            let plane=surface.plane,p=plane.project(cut[0]),q=plane.project(cut[1]),direction=q-p,e=max(tolerance,plane.epsilon)
            let ring=profile.outer.map(plane.project)
            var intersections:[PGPoint]=[],overlap=false
            for i in ring.indices {
                let edgeStart=ring[i],edgeEnd=ring[(i+1)%ring.count],edge=edgeEnd-edgeStart,denominator=pgCross2(direction,edge)
                if abs(denominator)<=e*max(direction.length,edge.length) {
                    if pgDistance(edgeStart,p,q)<=e || pgDistance(edgeEnd,p,q)<=e {overlap=true}
                    continue
                }
                let t=pgCross2(edgeStart-p,edge)/denominator,u=pgCross2(edgeStart-p,direction)/denominator
                if t>=(-e/direction.length),t<=1+e/direction.length,u>=(-e/edge.length),u<=1+e/edge.length {
                    let point=p+direction*max(0,min(1,t))
                    if !intersections.contains(where:{($0-point).length<=e}) {intersections.append(point)}
                }
            }
            if overlap {continue}
            if intersections.count>2 {throw GeometryIOError.unsupported("This line crosses multiple regions of a concave face. Use shorter, simpler cuts.")}
            if intersections.count==2,pgInside((intersections[0]+intersections[1])*0.5,ring) {
                let pieces=try split(entity:entity,lineStart:plane.lift(intersections[0]),lineEnd:plane.lift(intersections[1]))
                result.entities.removeAll{$0.id==entity.id};result.entities += pieces;didSplit=true
            }
        }
        if !didSplit {
            for points in try pgClosingLoops(vertices:vertices,adjacency:adjacency,start:aIndex,end:bIndex,tolerance:tolerance) {
                let candidate = try PGSurface(FaceProfile(outer:points))
                let existingProfiles = document.entities.filter { $0.metadata?.groupID == editingGroupID && $0.isVisible(in:document) }.compactMap { try? worldProfile(of:$0) }
                if existingProfiles.contains(where:{pgSameBoundary($0.outer,candidate.profile.outer,tolerance:tolerance)}) {continue}
                // Existing interior regions keep their identity and material. Exclude only
                // their outermost contours, so an existing ring and its inner face do not
                // become nested holes in the newly drawn enclosing region.
                let plane=candidate.plane,boundary=candidate.profile.outer.map(candidate.plane.project)
                let epsilon=max(tolerance,plane.epsilon)
                var interiors:[[Vec3]]=[]
                for existing in document.entities where existing.metadata?.groupID == editingGroupID && existing.isVisible(in:document) {
                    guard let profile=try? worldProfile(of:existing),
                          let mesh=try? existing.triangulatedMesh(),
                          mesh.vertices.allSatisfy({abs(pgDot(pgSub($0,plane.origin),plane.n))<=epsilon}) else {continue}
                    let ring=profile.outer.map(plane.project)
                    guard ring.allSatisfy({point in pgInside(point,boundary) && boundary.indices.allSatisfy{pgDistance(point,boundary[$0],boundary[($0+1)%boundary.count])>epsilon}}) else {continue}
                    // Vertex containment alone is insufficient for a concave outer contour.
                    guard !ring.indices.contains(where:{i in boundary.indices.contains{j in pgIntersects(ring[i],ring[(i+1)%ring.count],boundary[j],boundary[(j+1)%boundary.count],epsilon:epsilon)}}) else {
                        throw GeometryIOError.unsupported("An enclosed profile crosses the new face boundary. Use simpler, separate contours.")
                    }
                    if !interiors.contains(where:{pgSameBoundary($0,profile.outer,tolerance:epsilon)}) {interiors.append(profile.outer)}
                }
                let holes=interiors.enumerated().filter { index,ring in
                    let projected=ring.map(plane.project)
                    return !interiors.enumerated().contains { otherIndex,other in
                        guard otherIndex != index else {return false}
                        let enclosing=other.map(plane.project)
                        return projected.allSatisfy{pgInside($0,enclosing)} && !projected.indices.contains {i in
                            enclosing.indices.contains {j in pgIntersects(projected[i],projected[(i+1)%projected.count],enclosing[j],enclosing[(j+1)%enclosing.count],epsilon:epsilon)}
                        }
                    }
                }.map(\.element)
                // Touching or overlapping interior contours reject atomically through face
                // validation; merging arbitrary existing regions needs a full topology kernel.
                var newFace=try face(points:points,holes:holes,name:"Connected face",colorHex:"#E7DCC8")
                newFace.metadata=editingGroupID.map{EntityMetadata(groupID:$0)}
                // A closed inner contour divides a planar face into a ring and an inner region.
                for outer in document.entities where outer.metadata?.groupID == editingGroupID && outer.isEditable(in:document) && outer.isVisible(in:document) {
                    guard let profile=try? worldProfile(of:outer),let surface=try? PGSurface(profile),let base=try? pgBasePoints(points,entity:outer,plane:surface.plane) else {continue}
                    let projected=base.map(surface.plane.project),boundary=profile.outer.map(surface.plane.project)
                    let strictlyInside=projected.allSatisfy {point in
                        pgInside(point,boundary) && boundary.indices.allSatisfy{pgDistance(point,boundary[$0],boundary[($0+1)%boundary.count])>max(tolerance,surface.plane.epsilon)} && !profile.holes.contains{pgInside(point,$0.map(surface.plane.project))}
                    }
                    if strictlyInside {
                        let ring=try addHole(entity:outer,points:points)
                        result.entities.removeAll{$0.id==outer.id};result.entities.append(ring)
                    }
                }
                result.entities.append(newFace)
            }
        }
        try result.validate()
        return result
    }

    public static func face(points: [Vec3], holes: [[Vec3]] = [], name: String = "Face", colorHex: String = "#E7DCC8") throws -> GardenEntity {
        let surface = try PGSurface(FaceProfile(outer: points, holes: holes))
        return try pgEntity(mesh: surface.mesh, profile: surface.profile, name: name, color: colorHex)
    }

    public static func worldProfile(of entity: GardenEntity) throws -> FaceProfile {
        let local: FaceProfile
        if let profile = entity.profile { local = profile }
        else if entity.kind == .rectangle || entity.kind == .circle {
            let points: [Vec3]
            if entity.kind == .rectangle {
                points = [Vec3(-entity.width/2,0,-entity.depth/2),Vec3(-entity.width/2,0,entity.depth/2),Vec3(entity.width/2,0,entity.depth/2),Vec3(entity.width/2,0,-entity.depth/2)]
            } else {
                points = (0..<48).map { let a = -Double($0) * 2 * .pi / 48; return Vec3(cos(a)*entity.width/2,0,sin(a)*entity.depth/2) }
            }
            local = FaceProfile(outer: points)
        } else { throw GeometryIOError.unsupported("Select a face profile, or convert a closed wire to a face first.") }
        let c = cos(entity.rotation), s = sin(entity.rotation)
        func transform(_ p: Vec3) -> Vec3 { Vec3(entity.origin.x+c*p.x+s*p.z, entity.origin.y+p.y, entity.origin.z-s*p.x+c*p.z) }
        let result = FaceProfile(outer: local.outer.map(transform), holes: local.holes.map { $0.map(transform) })
        try result.validate()
        return result
    }

    public static func normal(of entity: GardenEntity) throws -> Vec3 { try PGPlane(outer: worldProfile(of: entity).outer).n }

    /// Absolute signed extrusion from the retained footprint, not an incremental height edit.
    public static func extrude(entity: GardenEntity, distance: Double) throws -> GardenEntity {
        guard distance.isFinite, abs(distance) <= 1_000_000 else { throw GeometryIOError.invalid("Extrusion distance must be finite and no greater than 1,000,000 meters.") }
        let surface = try PGSurface(worldProfile(of: entity))
        if abs(distance) < surface.plane.epsilon { return pgPreserve(try pgEntity(mesh: surface.mesh, profile: surface.profile, name: entity.name, color: entity.colorHex, identity: entity.id, extrusion: 0),from:entity) }
        let n = surface.mesh.vertices.count
        var mesh = MeshData(vertices: surface.mesh.vertices + surface.mesh.vertices.map { pgAdd($0,pgMul(surface.plane.n,distance)) })
        for i in stride(from:0,to:surface.mesh.triangles.count,by:3) {
            let a = surface.mesh.triangles[i], b = surface.mesh.triangles[i+1], c = surface.mesh.triangles[i+2]
            mesh.triangles += distance > 0 ? [a,c,b,a+n,b+n,c+n] : [a,b,c,a+n,c+n,b+n]
        }
        for ring in surface.loops {
            for i in ring.indices {
                let a = ring[i], b = ring[(i+1)%ring.count]
                mesh.triangles += distance > 0 ? [a,b,b+n,a,b+n,a+n] : [a,b+n,b,a,a+n,b+n]
            }
        }
        return pgPreserve(try pgEntity(mesh: mesh, profile: surface.profile, name: entity.name, color: entity.colorHex, identity: entity.id, extrusion: distance),from:entity)
    }

    /// Positive distances expand the filled region; negative distances inset it. Miter joins.
    public static func offset(entity: GardenEntity, distance: Double) throws -> GardenEntity {
        guard distance.isFinite, abs(distance) <= 1_000_000 else { throw GeometryIOError.invalid("Offset distance must be finite and no greater than 1,000,000 meters.") }
        let surface = try PGSurface(worldProfile(of: entity))
        let plane = surface.plane
        func shifted(_ ring: [Vec3], hole: Bool) throws -> [Vec3] {
            let input = ring.map(plane.project)
            var output: [PGPoint] = []
            for i in input.indices {
                let a = input[(i+input.count-1)%input.count], b = input[i], c = input[(i+1)%input.count]
                let e = b-a, f = c-b
                let en = e.length, fn = f.length
                guard en > plane.epsilon, fn > plane.epsilon else { throw GeometryIOError.invalid("Offset profile contains a zero-length edge.") }
                let p = b + PGPoint(e.y/en,-e.x/en)*distance
                let q = b + PGPoint(f.y/fn,-f.x/fn)*distance
                let denominator = pgCross2(e,f)
                if abs(denominator) <= plane.epsilon*max(en,fn) { output.append((p+q)*0.5) }
                else { output.append(p+e*(pgCross2(q-p,f)/denominator)) }
            }
            let oldArea = pgArea(input), newArea = pgArea(output)
            guard oldArea*newArea > 0 else { throw GeometryIOError.invalid("This offset collapses or reverses a boundary.") }
            if (!hole && distance < 0) || (hole && distance > 0) {
                for point in output {
                    guard pgInside(point,input), input.indices.map({ pgDistance(point,input[$0],input[($0+1)%input.count]) }).min()! >= abs(distance)-plane.epsilon*10 else {
                        throw GeometryIOError.invalid("This offset is wider than the boundary can contain.")
                    }
                }
            }
            return output.map(plane.lift)
        }
        let profile = FaceProfile(outer: try shifted(surface.profile.outer,hole:false), holes: try surface.profile.holes.map { try shifted($0,hole:true) })
        let next = try PGSurface(profile)
        var result = try pgEntity(mesh:next.mesh,profile:next.profile,name:entity.name,color:entity.colorHex,identity:entity.id)
        if let distance = pgExtrusion(entity), abs(distance)>plane.epsilon { result = try extrude(entity:result,distance:distance) }
        return pgPreserve(result,from:entity)
    }

    /// Cuts along an infinite coplanar line. Complex multi-crossing cuts are rejected explicitly.
    public static func split(entity: GardenEntity, lineStart: Vec3, lineEnd: Vec3) throws -> [GardenEntity] {
        let surface = try PGSurface(worldProfile(of:entity)), plane = surface.plane
        let cut=try pgBasePoints([lineStart,lineEnd],entity:entity,plane:plane)
        let a = plane.project(cut[0]), b = plane.project(cut[1]), direction = b-a
        guard direction.length > plane.epsilon else { throw GeometryIOError.invalid("Choose two distinct split points.") }
        let ring = surface.profile.outer.map(plane.project)
        func side(_ p:PGPoint)->Double { pgCross2(direction,p-a)/direction.length }
        let signs = ring.map(side)
        guard signs.contains(where:{$0>plane.epsilon}), signs.contains(where:{$0 < -plane.epsilon}) else { throw GeometryIOError.invalid("The line does not cross the face interior.") }
        var intersections: [PGPoint] = []
        for i in ring.indices {
            let p=ring[i],q=ring[(i+1)%ring.count],sp=side(p),sq=side(q)
            if abs(sp)<=plane.epsilon { if !intersections.contains(where:{($0-p).length<=plane.epsilon}) { intersections.append(p) } }
            if sp*sq < -plane.epsilon*plane.epsilon { let r=p+(q-p)*(sp/(sp-sq)); if !intersections.contains(where:{($0-r).length<=plane.epsilon}) { intersections.append(r) } }
        }
        guard intersections.count == 2 else { throw GeometryIOError.unsupported("This concave cut crosses more than one region. Split it with a simpler line first.") }
        for hole in surface.profile.holes {
            let signs = hole.map(plane.project).map(side)
            guard !signs.contains(where:{abs($0)<=plane.epsilon}), !(signs.contains(where:{$0>0}) && signs.contains(where:{$0<0})) else { throw GeometryIOError.unsupported("Splitting through a hole is not supported. Choose a line that avoids its boundary.") }
        }
        func clipped(_ positive: Bool) -> [PGPoint] {
            var result:[PGPoint]=[]
            for i in ring.indices {
                let p=ring[i],q=ring[(i+1)%ring.count],sp=side(p),sq=side(q)
                let pin=positive ? sp >= -plane.epsilon : sp <= plane.epsilon
                let qin=positive ? sq >= -plane.epsilon : sq <= plane.epsilon
                if pin { result.append(p) }
                if pin != qin, abs(sp-sq)>plane.epsilon { result.append(p+(q-p)*(sp/(sp-sq))) }
            }
            return result
        }
        return try [true,false].map { positive in
            let holes = surface.profile.holes.filter { positive ? side(plane.project($0[0]))>0 : side(plane.project($0[0]))<0 }
            var result = try face(points:clipped(positive).map(plane.lift),holes:holes,name:entity.name+" split",colorHex:entity.colorHex)
            if let distance=pgExtrusion(entity), abs(distance)>plane.epsilon { result=try extrude(entity:result,distance:distance) }
            return pgPreserve(result,from:entity,identity:false)
        }
    }

    public static func addHole(entity: GardenEntity, points: [Vec3]) throws -> GardenEntity {
        var profile = try worldProfile(of:entity)
        let plane=try PGPlane(outer:profile.outer)
        profile.holes.append(try pgBasePoints(points,entity:entity,plane:plane))
        var result = try face(points:profile.outer,holes:profile.holes,name:entity.name,colorHex:entity.colorHex)
        result.id=entity.id
        if let distance=pgExtrusion(entity), abs(distance)>1e-9 { result=try extrude(entity:result,distance:distance) }
        return pgPreserve(result,from:entity)
    }

    /// A capped polyline sweep using parallel-transport frames and mitered corner sections.
    public static func sweep(profile entity: GardenEntity, path: [Vec3]) throws -> GardenEntity {
        guard path.count>=2, path.count<=512, path.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy(\.isFinite)}) else { throw GeometryIOError.invalid("Follow Me needs 2–512 finite path points.") }
        var profile = try worldProfile(of:entity)
        var surface = try PGSurface(profile)
        let epsilon=surface.plane.epsilon
        let segments=try (0..<(path.count-1)).map { try pgUnit(pgSub(path[$0+1],path[$0]),epsilon:epsilon) }
        guard pgLength(pgSub(path[0],path.last!))>epsilon else {throw GeometryIOError.unsupported("Closed Follow Me paths are not yet supported. Use an open path.")}
        for i in 0..<(path.count-1) {for j in 0..<(path.count-1) where j>=i+2 {
            if pgSegmentDistance(path[i],path[i+1],path[j],path[j+1])<=epsilon {throw GeometryIOError.invalid("Follow Me path crosses or touches itself.")}
        }}
        guard abs(pgDot(surface.plane.n,segments[0]))>0.999 else { throw GeometryIOError.unsupported("The profile plane must be perpendicular to the first path segment.") }
        guard abs(pgDot(pgSub(path[0],surface.plane.origin),surface.plane.n))<=max(epsilon*10,1e-6) else {
            throw GeometryIOError.unsupported("The Follow Me path must start in the profile plane. Move the profile or path before sweeping.")
        }
        if pgDot(surface.plane.n,segments[0])<0 { profile.outer.reverse(); profile.holes=profile.holes.map{Array($0.reversed())};surface=try PGSurface(profile) }
        var tangents=[segments[0]]
        if path.count>2 { for i in 1..<(path.count-1) { guard pgDot(segments[i-1],segments[i]) > -0.999 else { throw GeometryIOError.unsupported("Follow Me cannot reverse direction at a path corner.") }; tangents.append(try pgUnit(pgAdd(segments[i-1],segments[i]),epsilon:epsilon)) } }
        tangents.append(segments.last!)
        // Transport the section about the path, retaining its original offset.
        // Recentring on the profile centroid silently relocates the starting face.
        let local=surface.mesh.vertices.map{p->PGPoint in let d=pgSub(p,path[0]);return PGPoint(pgDot(d,surface.plane.u),pgDot(d,surface.plane.v))}
        guard local.count*path.count<=250_000 else { throw GeometryIOError.invalid("Follow Me exceeds the supported vertex count.") }
        var segmentFrames:[(u:Vec3,v:Vec3)]=[],u=surface.plane.u,previous=surface.plane.n
        for tangent in segments {
            u=try pgTransport(u,from:previous,to:tangent,epsilon:epsilon)
            segmentFrames.append((u,pgCross(tangent,u)));previous=tangent
        }
        var mesh=MeshData()
        for i in path.indices {
            let segmentIndex=max(0,i-1),frame=segmentFrames[segmentIndex]
            for point in local {
                var displacement=pgAdd(pgMul(frame.u,point.x),pgMul(frame.v,point.y))
                if i>0 && i<path.count-1 {
                    let denominator=pgDot(tangents[i],segments[i-1])
                    guard denominator>0.05 else {throw GeometryIOError.unsupported("This Follow Me corner is too sharp for a safe miter joint.")}
                    let extensionDistance = -pgDot(tangents[i],displacement)/denominator
                    let available=min(pgLength(pgSub(path[i],path[i-1])),pgLength(pgSub(path[i+1],path[i])))/2
                    guard abs(extensionDistance)<available-epsilon else {throw GeometryIOError.unsupported("The profile is too wide for this short path corner. Use a smaller profile or longer segments.")}
                    displacement=pgAdd(displacement,pgMul(segments[i-1],extensionDistance))
                }
                mesh.vertices.append(pgAdd(path[i],displacement))
            }
        }
        let n=local.count
        for i in stride(from:0,to:surface.mesh.triangles.count,by:3) {let a=surface.mesh.triangles[i],b=surface.mesh.triangles[i+1],c=surface.mesh.triangles[i+2],last=(path.count-1)*n;mesh.triangles += [a,c,b,a+last,b+last,c+last]}
        for step in 0..<(path.count-1) {for loop in surface.loops {for i in loop.indices {let a=loop[i]+step*n,b=loop[(i+1)%loop.count]+step*n;mesh.triangles += [a,b,b+n,a,b+n,a+n]}}}
        return pgPreserve(try pgEntity(mesh:mesh,profile:nil,name:entity.name+" Follow Me",color:entity.colorHex),from:entity,identity:false)
    }

    public static func arc(center: Vec3, start: Vec3, end: Vec3, segments: Int = 24) throws -> GardenEntity {
        guard segments>=2,segments<=4096,[center,start,end].allSatisfy({[$0.x,$0.y,$0.z].allSatisfy(\.isFinite)}) else { throw GeometryIOError.invalid("Arc requires finite points and 2–4096 segments.") }
        let a=pgSub(start,center),b=pgSub(end,center),radius=pgLength(a)
        guard radius>1e-9,abs(pgLength(b)-radius)<=max(1e-8,radius*1e-6) else { throw GeometryIOError.invalid("Arc endpoints must lie on the same nonzero-radius circle.") }
        let n=try pgUnit(pgCross(a,b),epsilon:1e-10),u=pgMul(a,1/radius),v=pgCross(n,u)
        let angle=acos(max(-1,min(1,pgDot(u,pgMul(b,1/radius)))))
        var points=(0...segments).map{index->Vec3 in let t=Double(index)*angle/Double(segments);return pgAdd(center,pgAdd(pgMul(u,cos(t)*radius),pgMul(v,sin(t)*radius)))}
        points[0]=start;points[segments]=end
        var edges:[Int]=[];for i in 0..<segments {edges += [i,i+1]}
        return try pgEntity(mesh:MeshData(vertices:points,lineIndices:edges),profile:nil,name:"Arc",color:"#353B3C")
    }

    public static func polygon(center: Vec3, radius: Double, sides: Int, normal: Vec3) throws -> GardenEntity {
        guard radius.isFinite,radius>0,sides>=3,sides<=4096, [center.x,center.y,center.z].allSatisfy(\.isFinite) else { throw GeometryIOError.invalid("Polygon needs a positive radius, finite center and 3–4096 sides.") }
        let n=try pgUnit(normal,epsilon:1e-10)
        let helper=abs(n.x)<0.8 ? Vec3(1,0,0):Vec3(0,1,0)
        let u=try pgUnit(pgCross(helper,n),epsilon:1e-10),v=pgCross(n,u)
        let points=(0..<sides).map{index->Vec3 in let a=Double(index)*2 * .pi/Double(sides);return pgAdd(center,pgAdd(pgMul(u,cos(a)*radius),pgMul(v,sin(a)*radius)))}
        return try face(points:points,name:"Polygon")
    }

    public static func faceFromWire(entity: GardenEntity) throws -> GardenEntity {
        guard entity.profile == nil else { throw GeometryIOError.unsupported("Select a closed wire profile without existing surfaces.") }
        let mesh=try entity.triangulatedMesh()
        guard mesh.triangles.isEmpty,!mesh.lineIndices.isEmpty else { throw GeometryIOError.unsupported("Select a closed wire profile without existing surfaces.") }
        let welded=pgWeld(mesh)
        var neighbors:[Int:[Int]]=[:]
        for i in stride(from:0,to:welded.lineIndices.count,by:2) {let a=welded.lineIndices[i],b=welded.lineIndices[i+1];guard a != b else {throw GeometryIOError.invalid("Wire contains a zero-length edge.")};neighbors[a,default:[]].append(b);neighbors[b,default:[]].append(a)}
        guard neighbors.values.allSatisfy({$0.count==2 && Set($0).count==2}) else { throw GeometryIOError.invalid("Every wire vertex must meet exactly two edges in a closed profile.") }
        var unused=Set(neighbors.keys),loops:[[Vec3]]=[]
        while let start=unused.min() {
            var ring:[Vec3]=[],current=start,previous = -1
            repeat {guard unused.remove(current) != nil else {throw GeometryIOError.invalid("Wire loops overlap or repeat an edge.")};ring.append(welded.vertices[current]);let choices=neighbors[current]!;let next=choices.first(where:{$0 != previous})!;previous=current;current=next} while current != start
            loops.append(ring)
        }
        guard let biggest=loops.max(by:{pgLoopMagnitude($0)<pgLoopMagnitude($1)}) else {throw GeometryIOError.invalid("Wire contains no closed loop.")}
        let index=loops.firstIndex(of:biggest)!
        let holes=loops.enumerated().filter{$0.offset != index}.map(\.element)
        return pgPreserve(try face(points:biggest,holes:holes,name:entity.name,colorHex:entity.colorHex),from:entity)
    }
}

/// Finds the bounded planar regions beside the new edge. A face walk follows angularly
/// adjacent edges, so unrelated cycles cannot replace the newly closed region's boundary.
private func pgClosingLoops(vertices:[Vec3],adjacency:[Int:Set<Int>],start:Int,end:Int,tolerance:Double) throws -> [[Vec3]] {
    var connected:Set<Int>=[start],queue=[start],cursor=0
    while cursor<queue.count {
        let current=queue[cursor];cursor+=1
        for next in (adjacency[current] ?? []).sorted() where connected.insert(next).inserted {queue.append(next)}
    }
    guard connected.contains(end) else {return []}
    let a=vertices[start],b=vertices[end],edge=pgSub(b,a)
    var planes:[PGPlane]=[]
    for index in queue {
        let cross=pgCross(edge,pgSub(vertices[index],a))
        guard pgLength(cross)>tolerance*pgLength(edge),let plane=try? PGPlane(outer:[a,b,vertices[index]]) else {continue}
        if planes.contains(where:{pgLength(pgCross($0.n,plane.n))<=1e-10}) {continue}
        guard planes.count<128 else {throw GeometryIOError.unsupported("Automatic face connection is limited to 128 planes around one edge.")}
        planes.append(plane)
    }
    var loops:[[Vec3]]=[]
    for plane in planes {
        let epsilon=max(tolerance,plane.epsilon)
        let coplanar=Set(connected.filter{abs(pgDot(pgSub(vertices[$0],a),plane.n))<=epsilon})
        var neighbors:[Int:Set<Int>]=[:]
        for index in coplanar {neighbors[index]=(adjacency[index] ?? []).intersection(coplanar)}
        neighbors[start,default:[]].insert(end);neighbors[end,default:[]].insert(start)
        // Remove dangling branches before walking, including branches inside the new region.
        var leaves=neighbors.keys.filter{neighbors[$0]!.count<2},position=0
        while position<leaves.count {
            let leaf=leaves[position];position+=1
            guard let adjacent=neighbors.removeValue(forKey:leaf) else {continue}
            for next in adjacent {
                neighbors[next]?.remove(leaf)
                if neighbors[next]?.count==1 {leaves.append(next)}
            }
        }
        guard neighbors[start] != nil,neighbors[end] != nil else {continue}
        let points=vertices.map(plane.project)
        var ordered:[Int:[Int]]=[:]
        for (index,adjacent) in neighbors {
            ordered[index]=adjacent.sorted {
                let p=points[$0]-points[index],q=points[$1]-points[index]
                let first=atan2(p.y,p.x),second=atan2(q.y,q.x)
                return first==second ? $0<$1:first<second
            }
        }
        for initial in [(start,end),(end,start)] {
            var previous=initial.0,current=initial.1,route=[initial.0],seen:Set<Int>=[initial.0]
            var closed=false
            for _ in 0...neighbors.count {
                guard let adjacent=ordered[current],let incoming=adjacent.firstIndex(of:previous) else {break}
                let next=adjacent[(incoming+adjacent.count-1)%adjacent.count]
                if current==initial.0,next==initial.1 {closed=true;break}
                guard seen.insert(current).inserted else {break}
                route.append(current);previous=current;current=next
            }
            guard closed,route.count>=3,pgArea(route.map{points[$0]})>epsilon*epsilon else {continue}
            let loop=route.map{vertices[$0]}
            // Crossing edges, overlapping segments and degenerate loops remain wires.
            guard (try? PGSurface(FaceProfile(outer:loop))) != nil else {continue}
            if !loops.contains(where:{pgSameBoundary($0,loop,tolerance:epsilon)}) {loops.append(loop)}
        }
    }
    return loops
}

private func pgSameBoundary(_ first:[Vec3],_ second:[Vec3],tolerance:Double)->Bool {
    guard let a=try? PGSurface(FaceProfile(outer:first)).profile.outer,
          let b=try? PGSurface(FaceProfile(outer:second)).profile.outer,a.count==b.count else {return false}
    for start in b.indices where pgLength(pgSub(a[0],b[start]))<=tolerance {
        for direction in [-1,1] {
            if a.indices.allSatisfy({pgLength(pgSub(a[$0],b[(start+direction*$0+b.count)%b.count]))<=tolerance}) {return true}
        }
    }
    return false
}

private func pgBasePoints(_ points:[Vec3],entity:GardenEntity,plane:PGPlane) throws ->[Vec3] {
    guard points.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy(\.isFinite)}) else {throw GeometryIOError.invalid("Face edit points must be finite.")}
    let offsets=points.map{pgDot(pgSub($0,plane.origin),plane.n)}
    if offsets.allSatisfy({abs($0)<=plane.epsilon}) {return points}
    if let distance=pgExtrusion(entity),offsets.allSatisfy({abs($0-distance)<=plane.epsilon}) {return points.map{pgSub($0,pgMul(plane.n,distance))}}
    throw GeometryIOError.invalid("Edit points must lie in the face plane or its extruded end cap.")
}

private func pgExtrusion(_ entity:GardenEntity)->Double? {
    if let distance=entity.profileExtrusion {return distance}
    return entity.kind == .rectangle || entity.kind == .circle ? entity.height:nil
}

private func pgPreserve(_ result:GardenEntity,from source:GardenEntity,identity:Bool=true)->GardenEntity {
    var next=result
    if identity {next.id=source.id}
    next.metadata=source.metadata
    // New topology is a new component part. Reusing the source's identity would
    // make a retained sweep or either split piece overwrite that source's peers.
    if !identity, next.metadata?.componentPartID != nil {next.metadata?.componentPartID=UUID()}
    next.surface=source.surface
    // Triangle ordinals change after topology edits; retain the global material, not stale face assignments.
    next.surface?.faceOverrides=[]
    return next
}

private func pgEntity(mesh:MeshData,profile:FaceProfile?,name:String,color:String,identity:UUID=UUID(),extrusion:Double?=nil) throws -> GardenEntity {
    let welded=pgWeld(mesh)
    try welded.validate()
    let xs=welded.vertices.map(\.x),ys=welded.vertices.map(\.y),zs=welded.vertices.map(\.z)
    var entity=GardenEntity(id:identity,name:name,kind:.mesh,origin:Vec3(0,0,0),width:xs.max()!-xs.min()!,depth:zs.max()!-zs.min()!,height:ys.max()!-ys.min()!,colorHex:color,mesh:welded)
    entity.profile=profile;entity.profileExtrusion=extrusion
    try ModelDocument(entities:[entity]).validate()
    return entity
}

private struct PGPoint: Equatable {
    var x:Double;var y:Double
    init(_ x:Double,_ y:Double){self.x=x;self.y=y}
    static func + (a:Self,b:Self)->Self{Self(a.x+b.x,a.y+b.y)}
    static func - (a:Self,b:Self)->Self{Self(a.x-b.x,a.y-b.y)}
    static func * (a:Self,b:Double)->Self{Self(a.x*b,a.y*b)}
    var length:Double{hypot(x,y)}
}
private struct PGPlane {
    let origin:Vec3,u:Vec3,v:Vec3,n:Vec3,epsilon:Double
    init(outer:[Vec3]) throws {
        guard outer.count>=3,outer.count<=4096,outer.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy(\.isFinite)}) else {throw GeometryIOError.invalid("A face needs 3–4096 finite boundary points.")}
        let first=outer[0]
        let scale=outer.map{pgLength(pgSub($0,first))}.max()!
        let epsilon=max(1e-9,scale*1e-8)
        self.epsilon=epsilon
        var normal=Vec3(0,0,0)
        for i in outer.indices {normal=pgAdd(normal,pgCross(pgSub(outer[i],first),pgSub(outer[(i+1)%outer.count],first)))}
        n=try pgUnit(normal,epsilon:epsilon*epsilon)
        guard let edge=outer.dropFirst().map({pgSub($0,first)}).first(where:{pgLength($0)>epsilon}) else {throw GeometryIOError.invalid("Face boundary is degenerate.")}
        u=try pgUnit(edge,epsilon:epsilon);v=pgCross(n,u);origin=first
    }
    func project(_ p:Vec3)->PGPoint{let d=pgSub(p,origin);return PGPoint(pgDot(d,u),pgDot(d,v))}
    func lift(_ p:PGPoint)->Vec3{pgAdd(origin,pgAdd(pgMul(u,p.x),pgMul(v,p.y)))}
}

private struct PGSurface {
    let profile:FaceProfile,plane:PGPlane,mesh:MeshData,loops:[[Int]]
    init(_ input:FaceProfile) throws {
        let plane=try PGPlane(outer:input.outer)
        self.plane=plane
        guard input.holes.count<=128,input.outer.count+input.holes.reduce(0,{$0+$1.count})<=4096 else {throw GeometryIOError.invalid("A face exceeds 4096 boundary points or 128 holes.")}
        let e=plane.epsilon
        func clean(_ original:[Vec3])->[Vec3] {
            var result:[Vec3]=[]
            for p in original {if result.last.map({pgLength(pgSub(p,$0))>e}) ?? true {result.append(p)}}
            if result.count>1,pgLength(pgSub(result[0],result.last!))<=e {result.removeLast()}
            var changed=true
            while changed && result.count>3 {changed=false;for i in result.indices {let a=result[(i+result.count-1)%result.count],b=result[i],c=result[(i+1)%result.count];if pgLength(pgCross(pgSub(b,a),pgSub(c,b)))<=e*max(pgLength(pgSub(b,a)),pgLength(pgSub(c,b))),pgDot(pgSub(b,a),pgSub(c,b))>=0 {result.remove(at:i);changed=true;break}}}
            return result
        }
        var rings=([input.outer]+input.holes).map(clean)
        for ring in rings {
            guard ring.count>=3,ring.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy(\.isFinite) && abs(pgDot(pgSub($0,plane.origin),plane.n))<=e}) else {throw GeometryIOError.invalid("Face loops must contain at least three finite coplanar points.")}
            let points=ring.map(plane.project)
            guard abs(pgArea(points))>e*e else {throw GeometryIOError.invalid("Face boundary has no area.")}
            for i in points.indices {for j in points.indices where j>i && j != (i+1)%points.count && i != (j+1)%points.count {if pgIntersects(points[i],points[(i+1)%points.count],points[j],points[(j+1)%points.count],epsilon:e){throw GeometryIOError.invalid("Face boundary crosses or touches itself.")}}}
        }
        for i in 1..<rings.count {if pgArea(rings[i].map(plane.project))>0 {rings[i].reverse()}}
        let projected=rings.map{$0.map(plane.project)}
        if rings.count>1 {
            for i in 1..<rings.count {
                guard pgInside(projected[i][0],projected[0]) else {throw GeometryIOError.invalid("A hole lies outside the outer face boundary.")}
                for j in 0..<i {
                    for a in projected[i].indices {for b in projected[j].indices {if pgIntersects(projected[i][a],projected[i][(a+1)%projected[i].count],projected[j][b],projected[j][(b+1)%projected[j].count],epsilon:e){throw GeometryIOError.invalid("Face holes touch or overlap another boundary.")}}}
                    if j>0 && (pgInside(projected[i][0],projected[j]) || pgInside(projected[j][0],projected[i])) {throw GeometryIOError.invalid("Nested or overlapping holes are not supported.")}
                }
            }
        }
        profile=FaceProfile(outer:rings[0],holes:Array(rings.dropFirst()))
        var joined=rings[0]
        let ordered=(1..<rings.count).sorted{projected[$0].map(\.x).max()!>projected[$1].map(\.x).max()!}
        for holeIndex in ordered {
            let hole=rings[holeIndex],hIndex=projected[holeIndex].indices.max(by:{projected[holeIndex][$0].x<projected[holeIndex][$1].x})!,h=projected[holeIndex][hIndex]
            let candidates=joined.indices.sorted{(plane.project(joined[$0])-h).length<(plane.project(joined[$1])-h).length}
            let current=joined.map(plane.project)
            let bridge=candidates.first { candidate in
                let p=current[candidate],mid=(p+h)*0.5
                guard (p-h).length>e,pgInside(mid,projected[0]),!projected.dropFirst().contains(where:{pgInside(mid,$0)}) else{return false}
                for ring in [current]+projected.dropFirst() {for i in ring.indices {let a=ring[i],b=ring[(i+1)%ring.count];if (a-p).length<=e || (b-p).length<=e || (a-h).length<=e || (b-h).length<=e {continue};if pgIntersects(p,h,a,b,epsilon:e){return false}}}
                return true
            }
            guard let bridge else {throw GeometryIOError.unsupported("This hole cannot be connected safely for triangulation.")}
            let route=(0..<hole.count).map{hole[(hIndex+$0)%hole.count]}
            joined=Array(joined[...bridge])+route+[hole[hIndex],joined[bridge]]+Array(joined.dropFirst(bridge+1))
        }
        let points=joined.map(plane.project)
        var remaining=Array(points.indices),triangles:[Int]=[]
        while remaining.count>3 {
            var found=false
            for position in remaining.indices {
                let a=remaining[(position+remaining.count-1)%remaining.count],b=remaining[position],c=remaining[(position+1)%remaining.count]
                guard pgCross2(points[b]-points[a],points[c]-points[b])>e*e else {continue}
                var blocked=false
                for p in remaining where p != a && p != b && p != c {
                    if (points[p]-points[a]).length<=e || (points[p]-points[b]).length<=e || (points[p]-points[c]).length<=e {continue}
                    if pgTriangleContains(points[p],points[a],points[b],points[c],epsilon:e*e){blocked=true;break}
                }
                if !blocked {triangles += [a,b,c];remaining.remove(at:position);found=true;break}
            }
            guard found else {throw GeometryIOError.unsupported("The face could not be triangulated without crossing its boundaries.")}
        }
        if remaining.count==3 {guard pgCross2(points[remaining[1]]-points[remaining[0]],points[remaining[2]]-points[remaining[0]])>e*e else {throw GeometryIOError.invalid("Face triangulation ended in a degenerate triangle.")};triangles += remaining}
        let result=pgWeld(MeshData(vertices:joined,triangles:triangles))
        let expected=abs(pgArea(projected[0]))-projected.dropFirst().reduce(0,{$0+abs(pgArea($1))})
        let actual=stride(from:0,to:result.triangles.count,by:3).reduce(0.0){sum,i in let a=plane.project(result.vertices[result.triangles[i]]),b=plane.project(result.vertices[result.triangles[i+1]]),c=plane.project(result.vertices[result.triangles[i+2]]);return sum+abs(pgCross2(b-a,c-a))/2}
        guard expected>e*e,abs(actual-expected)<=max(expected*1e-7,e*e*10) else {throw GeometryIOError.invalid("Triangulation did not preserve the face area.")}
        mesh=result
        loops=try rings.map {ring in try ring.map{p in guard let index=result.vertices.firstIndex(of:p) else {throw GeometryIOError.invalid("Triangulation lost a boundary vertex.")};return index}}
    }
}

private struct PGVertexKey:Hashable {let x:UInt64,y:UInt64,z:UInt64;init(_ p:Vec3){x=(p.x==0 ? 0:p.x).bitPattern;y=(p.y==0 ? 0:p.y).bitPattern;z=(p.z==0 ? 0:p.z).bitPattern}}
private func pgWeld(_ mesh:MeshData)->MeshData {
    var map:[PGVertexKey:Int]=[:],indices:[Int]=[],vertices:[Vec3]=[]
    for p in mesh.vertices {let key=PGVertexKey(p);if let index=map[key]{indices.append(index)}else{map[key]=vertices.count;indices.append(vertices.count);vertices.append(p)}}
    return MeshData(vertices:vertices,triangles:mesh.triangles.map{indices[$0]},lineIndices:mesh.lineIndices.map{indices[$0]})
}
private func pgSub(_ a:Vec3,_ b:Vec3)->Vec3{Vec3(a.x-b.x,a.y-b.y,a.z-b.z)}
private func pgAdd(_ a:Vec3,_ b:Vec3)->Vec3{Vec3(a.x+b.x,a.y+b.y,a.z+b.z)}
private func pgMul(_ a:Vec3,_ s:Double)->Vec3{Vec3(a.x*s,a.y*s,a.z*s)}
private func pgDot(_ a:Vec3,_ b:Vec3)->Double{a.x*b.x+a.y*b.y+a.z*b.z}
private func pgCross(_ a:Vec3,_ b:Vec3)->Vec3{Vec3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)}
private func pgLength(_ p:Vec3)->Double{sqrt(pgDot(p,p))}
private func pgUnit(_ p:Vec3,epsilon:Double) throws ->Vec3{let length=pgLength(p);guard length.isFinite,length>epsilon else{throw GeometryIOError.invalid("Geometry contains a degenerate edge or normal.")};return pgMul(p,1/length)}
private func pgCross2(_ a:PGPoint,_ b:PGPoint)->Double{a.x*b.y-a.y*b.x}
private func pgArea(_ points:[PGPoint])->Double{points.indices.reduce(0){$0+pgCross2(points[$1],points[($1+1)%points.count])}/2}
private func pgTriangleContains(_ p:PGPoint,_ a:PGPoint,_ b:PGPoint,_ c:PGPoint,epsilon:Double)->Bool{pgCross2(b-a,p-a)>=(-epsilon) && pgCross2(c-b,p-b)>=(-epsilon) && pgCross2(a-c,p-c)>=(-epsilon)}
private func pgInside(_ p:PGPoint,_ ring:[PGPoint])->Bool{var inside=false;for i in ring.indices{let a=ring[i],b=ring[(i+1)%ring.count];if (a.y>p.y) != (b.y>p.y),p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x{inside.toggle()}};return inside}
private func pgDistance(_ p:PGPoint,_ a:PGPoint,_ b:PGPoint)->Double{let d=b-a;let length=d.x*d.x+d.y*d.y;if length==0{return(p-a).length};let t=max(0,min(1,((p.x-a.x)*d.x+(p.y-a.y)*d.y)/length));return(p-(a+d*t)).length}
private func pgIntersects(_ a:PGPoint,_ b:PGPoint,_ c:PGPoint,_ d:PGPoint,epsilon:Double)->Bool{
    let ab=b-a,cd=d-c,scale=max(ab.length,cd.length),e=epsilon*max(scale,epsilon)
    let x=pgCross2(ab,c-a),y=pgCross2(ab,d-a),z=pgCross2(cd,a-c),w=pgCross2(cd,b-c)
    if ((x>e && y < -e)||(x < -e && y>e)) && ((z>e && w < -e)||(z < -e && w>e)){return true}
    return (abs(x)<=e && pgDistance(c,a,b)<=epsilon)||(abs(y)<=e && pgDistance(d,a,b)<=epsilon)||(abs(z)<=e && pgDistance(a,c,d)<=epsilon)||(abs(w)<=e && pgDistance(b,c,d)<=epsilon)
}
private func pgLoopMagnitude(_ ring:[Vec3])->Double{guard let first=ring.first else{return 0};var n=Vec3(0,0,0);for i in ring.indices{n=pgAdd(n,pgCross(pgSub(ring[i],first),pgSub(ring[(i+1)%ring.count],first)))};return pgLength(n)}
private func pgTransport(_ vector:Vec3,from a:Vec3,to b:Vec3,epsilon:Double) throws ->Vec3{
    let axis=pgCross(a,b),s=pgLength(axis),c=pgDot(a,b)
    if s<=epsilon {guard c>0 else{throw GeometryIOError.unsupported("Follow Me cannot reverse its frame.")};return vector}
    let k=pgMul(axis,1/s)
    return try pgUnit(pgAdd(pgAdd(pgMul(vector,c),pgMul(pgCross(k,vector),s)),pgMul(k,pgDot(k,vector)*(1-c))),epsilon:epsilon)
}

private func pgSegmentDistance(_ p:Vec3,_ q:Vec3,_ r:Vec3,_ s:Vec3)->Double {
    let u=pgSub(q,p),v=pgSub(s,r),w=pgSub(p,r)
    let a=pgDot(u,u),b=pgDot(u,v),c=pgDot(v,v),d=pgDot(u,w),e=pgDot(v,w),denominator=a*c-b*b
    var sn=denominator,sd=denominator,tn=denominator,td=denominator
    if denominator<1e-20 {sn=0;sd=1;tn=e;td=c}
    else {sn=b*e-c*d;tn=a*e-b*d;if sn<0 {sn=0;tn=e;td=c}else if sn>sd {sn=sd;tn=e+b;td=c}}
    if tn<0 {tn=0;if -d<0 {sn=0}else if -d>a {sn=sd}else {sn = -d;sd=a}}
    else if tn>td {tn=td;if -d+b<0 {sn=0}else if -d+b>a {sn=sd}else {sn = -d+b;sd=a}}
    let sc=abs(sn)<1e-20 ? 0:sn/sd,tc=abs(tn)<1e-20 ? 0:tn/td
    return pgLength(pgSub(pgAdd(w,pgMul(u,sc)),pgMul(v,tc)))
}
