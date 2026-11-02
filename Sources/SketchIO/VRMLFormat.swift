import Foundation
import simd
import SketchCore

/// Static VRML 2.0 geometry. No scene code, external resources or browser execution.
public enum VRMLFormat {
    public static func read(url: URL, metersPerUnit: Double? = nil, zUp: Bool? = nil) throws -> ModelDocument {
        let text=try StaticScene.text(url)
        guard text.components(separatedBy:.newlines).first?.trimmingCharacters(in:.whitespaces) == "#VRML V2.0 utf8" else {throw GeometryIOError.unsupported("Only VRML 2.0 UTF-8 static scenes are supported.")}
        let parser=try VRParser(text)
        return try StaticScene.document(nodes:parser.parse(),name:url.deletingPathExtension().lastPathComponent,scale:metersPerUnit ?? 1,zUp:zUp ?? false)
    }
    public static func write(_ document:ModelDocument,to url:URL) throws {
        let nodes=try StaticScene.nodes(document)
        let text="#VRML V2.0 utf8\n# Static geometry in meters, Y up.\n"+nodes.map { $0.vrml() }.joined(separator:"\n")+"\n"
        guard text.utf8.count<=64*1024*1024 else {throw GeometryIOError.invalid("VRML output exceeds the 64 MB scene limit.")}
        try text.write(to:url,atomically:true,encoding:.utf8)
    }
}

indirect enum VRValue {
    case numbers([Double]), strings([String]), nodes([VRNode]), boolean(Bool)
}
final class VRNode {
    let type:String
    var definition:String?,use:String?,fields:[String:VRValue]=[:]
    init(_ type:String,_ fields:[String:VRValue]=[:]) {self.type=type;self.fields=fields}
    func vrml()->String {
        if let use {return "USE "+use}
        let prefix=definition.map {"DEF \($0) "} ?? ""
        let content=fields.keys.sorted().map {key->String in
            let value:String
            switch fields[key]! {
            case let .numbers(ns): value=ns.count == (VRSchema.fields[type]?[key]?.count ?? -1) ? ns.map(StaticScene.number).joined(separator:" "):"[ "+ns.map(StaticScene.number).joined(separator:" ")+" ]"
            case let .boolean(b):value=b ? "TRUE":"FALSE"
            case let .strings(ss):value="[ "+ss.map {"\""+$0.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""}.joined(separator:" ")+" ]"
            case let .nodes(nodes):value=(VRSchema.fields[type]?[key] == .node) ? (nodes.first?.vrml() ?? "NULL"):"[ "+nodes.map {$0.vrml()}.joined(separator:" ")+" ]"
            }
            return "\(key) \(value)"
        }.joined(separator:"\n")
        return prefix+type+" {\n"+content+"\n}"
    }
}
enum VRKind:Equatable {
    case fixed(Int),numbers,strings,node,nodes,bool
    var count:Int? {if case let .fixed(n)=self {return n};return nil}
}
enum VRSchema {
    static let fields:[String:[String:VRKind]] = [
        "Group":["children":.nodes,"bboxCenter":.fixed(3),"bboxSize":.fixed(3)],
        "Transform":["children":.nodes,"translation":.fixed(3),"rotation":.fixed(4),"scale":.fixed(3),"center":.fixed(3),"scaleOrientation":.fixed(4),"bboxCenter":.fixed(3),"bboxSize":.fixed(3)],
        "Shape":["appearance":.node,"geometry":.node],
        "Appearance":["material":.node,"texture":.node,"textureTransform":.node],
        "Material":["diffuseColor":.fixed(3),"transparency":.fixed(1),"ambientIntensity":.fixed(1),"emissiveColor":.fixed(3),"specularColor":.fixed(3),"shininess":.fixed(1)],
        "IndexedFaceSet":["coord":.node,"coordIndex":.numbers,"color":.node,"colorIndex":.numbers,"colorPerVertex":.bool,"texCoord":.node,"texCoordIndex":.numbers,"ccw":.bool,"convex":.bool,"solid":.bool,"creaseAngle":.fixed(1),"normalPerVertex":.bool,"normal":.node,"normalIndex":.numbers],
        "IndexedLineSet":["coord":.node,"coordIndex":.numbers,"color":.node,"colorIndex":.numbers,"colorPerVertex":.bool],
        "Normal":["vector":.numbers],"Coordinate":["point":.numbers],"Color":["color":.numbers],"TextureCoordinate":["point":.numbers],
        "WorldInfo":["title":.strings,"info":.strings]
    ]
}

private final class VRParser {
    let tokens:[String];var i=0,count=0
    init(_ text:String) throws {
        // Strings and # comments are tokenized, never evaluated as programs.
        let regex=try NSRegularExpression(pattern:"#[^\\r\\n]*|\"(?:[^\"\\\\]|\\\\.)*\"|[{}\\[\\],]|[^\\s{}\\[\\],\"#]+")
        let ns=text as NSString;var end=0,result:[String]=[]
        for match in regex.matches(in:text,range:NSRange(location:0,length:ns.length)) {
            guard ns.substring(with:NSRange(location:end,length:match.range.location-end)).allSatisfy(\.isWhitespace) else {throw GeometryIOError.invalid("Malformed VRML string or token.")}
            let token=ns.substring(with:match.range)
            if !token.hasPrefix("#"),token != "," {result.append(token)}
            end=NSMaxRange(match.range)
        }
        guard ns.substring(from:end).allSatisfy(\.isWhitespace),result.count<=4_000_000 else {throw GeometryIOError.invalid("Malformed or excessive VRML tokens.")};tokens=result
    }
    func next() throws -> String {guard i<tokens.count else {throw GeometryIOError.invalid("Truncated VRML node.")};defer{i+=1};return tokens[i]}
    func expect(_ s:String) throws {guard try next()==s else {throw GeometryIOError.invalid("Expected VRML \(s).")}}
    func parse() throws ->[VRNode] {var nodes:[VRNode]=[];while i<tokens.count {nodes.append(try node(0))};return nodes}
    func node(_ depth:Int) throws ->VRNode {
        count+=1;guard depth<128,count<=150_000 else {throw GeometryIOError.invalid("VRML nesting/node count limit exceeded.")}
        var type=try next(),definition:String?
        if type=="USE" {let n=VRNode("USE");n.use=try next();return n}
        if type=="DEF" {definition=try next();type=try next()}
        guard let schema=VRSchema.fields[type] else {throw GeometryIOError.unsupported("Unsupported VRML node \(type). Only static groups, transforms, materials, indexed faces and lines are supported.")}
        let n=VRNode(type);n.definition=definition;try expect("{")
        while i<tokens.count,tokens[i] != "}" {
            let key=try next();guard let kind=schema[key],n.fields[key]==nil else {throw GeometryIOError.unsupported("Unknown or duplicate \(type).\(key); scripts, textures and animated scene fields are unsupported.")}
            switch kind {
            case let .fixed(count):n.fields[key] = .numbers(try (0..<count).map {_ in try numeric(next())})
            case .bool:let b=try next();guard b=="TRUE" || b=="FALSE" else {throw GeometryIOError.invalid("VRML boolean must be TRUE or FALSE.")};n.fields[key] = .boolean(b=="TRUE")
            case .numbers:
                try expect("[");var ns:[Double]=[]
                while i<tokens.count,tokens[i] != "]" {ns.append(try numeric(next()));guard ns.count<=1_500_000 else {throw GeometryIOError.invalid("VRML numeric array exceeds limits.")}}
                try expect("]");n.fields[key] = .numbers(ns)
            case .strings:
                var strings:[String]=[];let many=i<tokens.count && tokens[i]=="[";if many {i+=1}
                repeat {
                    if many,i<tokens.count,tokens[i]=="]" {break}
                    let s=try next();guard s.hasPrefix("\""),s.hasSuffix("\"") else {throw GeometryIOError.invalid("VRML metadata needs quoted strings.")};strings.append(String(s.dropFirst().dropLast()))
                } while many && i<tokens.count
                if many {try expect("]")};n.fields[key] = .strings(strings)
            case .node:
                if i<tokens.count,tokens[i]=="NULL" {i+=1;n.fields[key] = .nodes([])} else {n.fields[key] = .nodes([try node(depth+1)])}
            case .nodes:
                var ns:[VRNode]=[]
                if i<tokens.count,tokens[i]=="[" {i+=1;while i<tokens.count,tokens[i] != "]" {ns.append(try node(depth+1))};try expect("]")} else {ns=[try node(depth+1)]}
                n.fields[key] = .nodes(ns)
            }
        }
        try expect("}");return n
    }
    func numeric(_ s:String) throws ->Double {guard let n=Double(s),n.isFinite,abs(n)<=1e12 else {throw GeometryIOError.invalid("VRML numbers must be finite and within supported bounds.")};return n}
}

/// Shared semantic validation for classic VRML and XML X3D; both are non-executing AST readers.
enum StaticScene {
    static func number(_ n:Double)->String {String(format:"%.15g",locale:Locale(identifier:"en_US_POSIX"),n)}
    static func text(_ url:URL) throws ->String {
        guard url.isFileURL,let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=64*1024*1024 else {throw GeometryIOError.invalid("Static scenes must be local files under 64 MB.")}
        let data=try Data(contentsOf:url);guard data.count<=64*1024*1024,let s=String(data:data,encoding:.utf8) else {throw GeometryIOError.invalid("Static scenes must be UTF-8 under 64 MB.")};return s
    }
    static func values(_ n:VRNode,_ key:String,_ fallback:[Double]=[])->[Double] {if case let .numbers(v)=n.fields[key] {return v};return fallback}
    static func flag(_ n:VRNode,_ key:String,_ fallback:Bool)->Bool {if case let .boolean(v)=n.fields[key] {return v};return fallback}
    static func children(_ n:VRNode,_ key:String)->[VRNode] {if case let .nodes(v)=n.fields[key] {return v};return []}
    static func rgb(_ c:[Double]) throws ->String {guard c.count==3,c.allSatisfy({$0.isFinite && $0>=0 && $0<=1}) else {throw GeometryIOError.invalid("Scene RGB values must be between zero and one.")};return "#"+c.map {String(format:"%02X",Int(($0*255).rounded()))}.joined()}
    static func indices(_ values:[Double]) throws ->[Int] {try values.map {guard $0.rounded()==$0,$0 >= -1,$0<=250_000 else {throw GeometryIOError.invalid("Scene contains a noninteger or out-of-range index.")};return Int($0)}}
    static func rings(_ values:[Double],minimum:Int) throws ->[[Int]] {
        let ns=try indices(values);var rings:[[Int]]=[],ring:[Int]=[]
        for i in ns {if i == -1 {guard ring.count>=minimum,ring.count<=10_000 else {throw GeometryIOError.invalid("Indexed geometry has an empty, short or excessive face/path.")};rings.append(ring);ring=[]} else {ring.append(i)}}
        // The final -1 separator is optional in the Web3D indexed-geometry specification.
        if !ring.isEmpty {guard ring.count>=minimum,ring.count<=10_000 else {throw GeometryIOError.invalid("Indexed geometry ends with a short or excessive face/path.")};rings.append(ring)}
        guard !rings.isEmpty,rings.count<=500_000 else {throw GeometryIOError.invalid("Indexed geometry needs bounded nonempty faces/paths.")};return rings
    }
    static func translation(_ v:[Double])->simd_double4x4 {var m=matrix_identity_double4x4;m.columns.3=SIMD4(v[0],v[1],v[2],1);return m}
    static func rotation(_ v:[Double]) throws ->simd_double4x4 {
        let axis=SIMD3(v[0],v[1],v[2]),length=simd_length(axis)
        guard v.count==4,length>1e-14 || v[3]==0 else {throw GeometryIOError.invalid("Axis-angle rotations need a nonzero axis.")}
        return v[3]==0 ? matrix_identity_double4x4:simd_double4x4(simd_quatd(angle:v[3],axis:axis/length))
    }
    static func transform(_ n:VRNode) throws ->simd_double4x4 {
        let t=values(n,"translation",[0,0,0]),c=values(n,"center",[0,0,0]),s=values(n,"scale",[1,1,1]),r=try rotation(values(n,"rotation",[0,0,1,0])),sr=try rotation(values(n,"scaleOrientation",[0,0,1,0]))
        guard s.allSatisfy({abs($0)>1e-14}) else {throw GeometryIOError.unsupported("Singular scene scales would collapse geometry.")}
        var sm=matrix_identity_double4x4;sm.columns.0.x=s[0];sm.columns.1.y=s[1];sm.columns.2.z=s[2]
        return translation(t)*translation(c)*r*sr*sm*sr.inverse*translation(c.map {-$0})
    }
    static func document(nodes:[VRNode],name:String,scale:Double,zUp:Bool) throws ->ModelDocument {
        try PlainMesh.units(scale)
        var definitions:[String:VRNode]=[:],scanSeen=Set<ObjectIdentifier>()
        func collect(_ n:VRNode,_ depth:Int) throws {
            guard depth<128,scanSeen.insert(ObjectIdentifier(n)).inserted else {throw GeometryIOError.invalid("Scene node cycle or nesting limit exceeded.")}
            if let d=n.definition {guard !d.isEmpty,definitions[d]==nil else {throw GeometryIOError.invalid("Duplicate scene DEF identity.")};definitions[d]=n}
            for value in n.fields.values {if case let .nodes(children)=value {for child in children {try collect(child,depth+1)}}}
        }
        for node in nodes {try collect(node,0)}
        func resolved(_ node:VRNode,_ stack:Set<ObjectIdentifier>=[]) throws ->VRNode {
            guard stack.count<128,!stack.contains(ObjectIdentifier(node)) else {throw GeometryIOError.invalid("Cyclic scene USE reference.")}
            if let use=node.use {guard let target=definitions[use] else {throw GeometryIOError.invalid("Undefined scene USE \(use).")};return try resolved(target,stack.union([ObjectIdentifier(node)]))};return node
        }
        func child(_ n:VRNode,_ key:String,_ expected:String) throws ->VRNode? {
            let ns=children(n,key);guard ns.count<=1 else {throw GeometryIOError.invalid("Scene field \(key) needs a single node.")};guard let first=ns.first else {return nil};let result=try resolved(first);guard result.type==expected else {throw GeometryIOError.invalid("Expected \(expected) in \(n.type).\(key).")};return result
        }
        var entities:[SketchEntity]=[],totalVertices=0,totalTriangles=0,totalLines=0,visits=0
        func append(_ mesh:MeshData,_ color:String,_ name:String,_ faceColors:[String]=[]) throws {
            totalVertices+=mesh.vertices.count;totalTriangles+=mesh.triangles.count;totalLines+=mesh.lineIndices.count
            guard totalVertices<=250_000,totalTriangles<=1_500_000,totalLines<=1_000_000,entities.count<50_000 else {throw GeometryIOError.invalid("Expanded static scene exceeds geometry limits.")}
            var surface=SurfaceMaterial(colorHex:color)
            var assignments:[String:[Int]]=[:]
            for (i,c) in faceColors.enumerated() where c != color {assignments[c,default:[]].append(i)}
            guard assignments.count<=10_000 else {throw GeometryIOError.invalid("The scene exceeds the 10,000 face-material limit.")}
            for c in assignments.keys.sorted() {surface.faceOverrides.append(FaceSurface(triangleIndices:assignments[c]!,colorHex:c))}
            entities.append(try PlainMesh.entity(mesh,name:name,surface:surface))
        }
        func geometry(_ g:VRNode,_ m:simd_double4x4,_ color:String,_ label:String) throws {
            guard ["IndexedFaceSet","IndexedLineSet"].contains(g.type),let coord=try child(g,"coord","Coordinate") else {throw GeometryIOError.unsupported("Shapes require IndexedFaceSet or IndexedLineSet with Coordinate points.")}
            let raw=values(coord,"point")
            guard raw.count%3==0,raw.count>=6,raw.count<=750_000 else {throw GeometryIOError.invalid("Coordinate needs bounded XYZ triplets.")}
            let vertices=stride(from:0,to:raw.count,by:3).map {i->Vec3 in let p=m*SIMD4(raw[i],raw[i+1],raw[i+2],1);return PlainMesh.decode(Vec3(p.x,p.y,p.z),scale,zUp)}
            guard vertices.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy({$0.isFinite && abs($0)<=1e12})}) else {throw GeometryIOError.invalid("Scene transforms produce invalid coordinates.")}
            let faces=try rings(values(g,"coordIndex"),minimum:g.type=="IndexedFaceSet" ? 3:2)
            guard faces.flatMap({$0}).allSatisfy({vertices.indices.contains($0)}) else {throw GeometryIOError.invalid("Scene coordinate index is outside its array.")}
            var colors:[String]=[]
            if let colorNode=try child(g,"color","Color") {
                let raw=values(colorNode,"color");guard raw.count%3==0,!raw.isEmpty,raw.count<=750_000 else {throw GeometryIOError.invalid("Color needs RGB triplets.")}
                colors=try stride(from:0,to:raw.count,by:3).map {try rgb(Array(raw[$0..<$0+3]))}
            }
            let colorValues=values(g,"colorIndex"),perVertex=flag(g,"colorPerVertex",true)
            var faceColors=Array(repeating:color,count:faces.count)
            if !colors.isEmpty {
                if perVertex {
                    let ci=colorValues.isEmpty ? faces:try rings(colorValues,minimum:g.type=="IndexedFaceSet" ? 3:2)
                    guard ci.count==faces.count,zip(ci,faces).allSatisfy({$0.count==$1.count}) else {throw GeometryIOError.invalid("Per-vertex color indices must match coordinate paths.")}
                    for f in faces.indices {
                        guard ci[f].allSatisfy({colors.indices.contains($0)}) else {throw GeometryIOError.invalid("Scene color index is outside its array.")}
                        let cs=Set(ci[f].map {colors[$0]});guard cs.count==1 else {throw GeometryIOError.unsupported("Interpolated vertex colors are unsupported. Use a uniform color per face/path.")};faceColors[f]=cs.first!
                    }
                } else {
                    let ci=colorValues.isEmpty ? Array(faces.indices):try indices(colorValues)
                    guard ci.count==faces.count,ci.allSatisfy({colors.indices.contains($0)}) else {throw GeometryIOError.invalid("Per-face color indices must match face/path count.")}
                    faceColors=ci.map {colors[$0]}
                }
            } else if !colorValues.isEmpty {throw GeometryIOError.invalid("Color indices require a Color node.")}
            if g.type=="IndexedLineSet" {
                for (f,ring) in faces.enumerated() {
                    let vs=ring.map {vertices[$0]};var ls:[Int]=[]
                    for i in 1..<vs.count {
                        let a=vs[i-1],b=vs[i]
                        guard hypot(hypot(a.x-b.x,a.y-b.y),a.z-b.z)>1e-15 else {throw GeometryIOError.invalid("Scene line paths contain coincident endpoints.")}
                        ls += [i-1,i]
                    }
                    try append(MeshData(vertices:vs,lineIndices:ls),faceColors[f],label)
                };return
            }
            guard children(g,"normal").isEmpty,values(g,"normalIndex").isEmpty else {throw GeometryIOError.unsupported("Authored scene normals are unsupported; export coordinate faces without normal arrays.")}
            guard values(g,"creaseAngle",[0])==[0] else {throw GeometryIOError.unsupported("Custom smoothing normals/crease angles are unsupported.")}
            var uv:[TextureCoordinate]=[],uvFaces:[[Int]]=[]
            if let tex=try child(g,"texCoord","TextureCoordinate") {
                let raw=values(tex,"point");guard raw.count%2==0,!raw.isEmpty,raw.count<=500_000 else {throw GeometryIOError.invalid("Texture coordinates need bounded UV pairs.")}
                uv=stride(from:0,to:raw.count,by:2).map {TextureCoordinate(u:raw[$0],v:1-raw[$0+1])}
                uvFaces=values(g,"texCoordIndex").isEmpty ? faces:try rings(values(g,"texCoordIndex"),minimum:3)
                guard uvFaces.count==faces.count,zip(uvFaces,faces).allSatisfy({$0.count==$1.count}),uvFaces.flatMap({$0}).allSatisfy({uv.indices.contains($0)}) else {throw GeometryIOError.invalid("Texture indices must match coordinate faces and valid UVs.")}
            } else if !values(g,"texCoordIndex").isEmpty {throw GeometryIOError.invalid("Texture indices require TextureCoordinate.")}
            var mesh=MeshData(),triangleColors:[String]=[]
            if !uv.isEmpty {mesh.textureCoordinates=[]}
            let reverse=flag(g,"ccw",true) != (simd_determinant(m)>=0)
            for (f,face) in faces.enumerated() {
                let base=mesh.vertices.count,local=face.map {vertices[$0]}
                var tri=try PlainMesh.polygon(Array(local.indices),vertices:local)
                for i in stride(from:0,to:tri.count,by:3) {
                    let a=local[tri[i]],b=local[tri[i+1]],c=local[tri[i+2]]
                    let ab=SIMD3(b.x-a.x,b.y-a.y,b.z-a.z),ac=SIMD3(c.x-a.x,c.y-a.y,c.z-a.z)
                    guard simd_length_squared(simd_cross(ab,ac))>1e-30 else {throw GeometryIOError.invalid("Scene polygon contains coincident or collinear vertices.")}
                }
                if reverse {for i in stride(from:0,to:tri.count,by:3) {tri.swapAt(i+1,i+2)}}
                mesh.vertices += local;mesh.triangles += tri.map {$0+base};triangleColors += Array(repeating:faceColors[f],count:tri.count/3)
                if !uv.isEmpty {mesh.textureCoordinates! += uvFaces[f].map {uv[$0]}}
                guard mesh.vertices.count<=250_000,mesh.triangles.count<=1_500_000 else {throw GeometryIOError.invalid("Expanded scene geometry exceeds limits.")}
            }
            try append(mesh,color,label,triangleColors)
        }
        func visit(_ raw:VRNode,_ m:simd_double4x4,_ active:Set<ObjectIdentifier>) throws {
            visits+=1;guard visits<=150_000 else {throw GeometryIOError.invalid("Expanded scene hierarchy exceeds 150,000 nodes.")}
            let n=try resolved(raw),id=ObjectIdentifier(n)
            guard active.count<128,!active.contains(id) else {throw GeometryIOError.invalid("Cyclic scene hierarchy or nesting limit exceeded.")}
            let next=active.union([id])
            switch n.type {
            case "WorldInfo":return
            case "Group","Transform":let local=try n.type=="Transform" ? transform(n):matrix_identity_double4x4;for c in children(n,"children") {try visit(c,m*local,next)}
            case "Shape":
                var color="#CCCCCC"
                let appearance=try child(n,"appearance","Appearance")
                if let appearance {guard children(appearance,"texture").isEmpty,children(appearance,"textureTransform").isEmpty else {throw GeometryIOError.unsupported("Scene textures and texture transforms are unsupported.")}}
                if let appearance,let material=try child(appearance,"material","Material") {
                    for key in ["transparency","ambientIntensity","shininess"] {guard values(material,key).allSatisfy({$0>=0 && $0<=1}) else {throw GeometryIOError.invalid("Scene material scalars must be between zero and one.")}}
                    guard values(material,"ambientIntensity",[0.2])==[0.2] else {throw GeometryIOError.unsupported("Custom ambient scene lighting is unsupported; use diffuse colors.")}
                    guard values(material,"transparency",[0])==[0] else {throw GeometryIOError.unsupported("Transparent scene materials cannot be represented; use opaque diffuse colors.")}
                    guard values(material,"emissiveColor",[0,0,0])==[0,0,0],values(material,"specularColor",[0,0,0])==[0,0,0] else {throw GeometryIOError.unsupported("Emissive/specular scene materials are unsupported; use diffuse colors.")}
                    color=try rgb(values(material,"diffuseColor",[0.8,0.8,0.8]))
                }
                guard let rawGeometry=children(n,"geometry").first else {throw GeometryIOError.invalid("Scene Shape has no geometry.")};let g=try resolved(rawGeometry)
                try geometry(g,m,color,n.definition ?? name)
            default:throw GeometryIOError.unsupported("\(n.type) is not a supported static scene root/child.")
            }
        }
        for n in nodes {try visit(n,matrix_identity_double4x4,[])}
        guard !entities.isEmpty else {throw GeometryIOError.invalid("Scene has no supported geometry.")}
        let doc=ModelDocument(entities:entities,name:name);try doc.validate();return doc
    }
    static func nodes(_ document:ModelDocument) throws ->[VRNode] {
        try document.validate();guard !document.entities.isEmpty else {throw GeometryIOError.invalid("The document has no geometry.")}
        var result:[VRNode]=[],vertexCount=0,indexCount=0
        func shape(_ mesh:MeshData,_ entity:SketchEntity,_ lines:Bool)->VRNode {
            let color=entity.surface?.colorHex ?? entity.colorHex,material=VRNode("Material",["diffuseColor":.numbers(PlainMesh.rgb(color).map {Double($0)/255})])
            let appearance=VRNode("Appearance",["material":.nodes([material])]),coord=VRNode("Coordinate",["point":.numbers(mesh.vertices.flatMap {[$0.x,$0.y,$0.z]})])
            let rawIndices=lines ? mesh.lineIndices:mesh.triangles,step=lines ? 2:3
            var indices:[Double]=[];for i in stride(from:0,to:rawIndices.count,by:step) {indices += rawIndices[i..<i+step].map(Double.init)+[-1]}
            let geo=VRNode(lines ? "IndexedLineSet":"IndexedFaceSet",["coord":.nodes([coord]),"coordIndex":.numbers(indices)])
            if !lines {
                geo.fields["solid"] = .boolean(false)
                if let uv=mesh.textureCoordinates {geo.fields["texCoord"] = .nodes([VRNode("TextureCoordinate",["point":.numbers(uv.flatMap {[$0.u,1-$0.v]})])])}
                if let surface=entity.surface,!surface.faceOverrides.isEmpty {
                    var colors=Array(repeating:color,count:mesh.triangles.count/3)
                    for face in surface.faceOverrides {for i in face.triangleIndices {colors[i]=face.colorHex}}
                    let palette=Array(Set(colors)).sorted(),lookup=Dictionary(uniqueKeysWithValues:palette.enumerated().map {($0.element,$0.offset)})
                    geo.fields["color"] = .nodes([VRNode("Color",["color":.numbers(palette.flatMap {PlainMesh.rgb($0).map {Double($0)/255}})])]);geo.fields["colorPerVertex"] = .boolean(false);geo.fields["colorIndex"] = .numbers(colors.map {Double(lookup[$0]!)})
                }
            }
            return VRNode("Shape",["appearance":.nodes([appearance]),"geometry":.nodes([geo])])
        }
        for entity in document.entities {
            guard entity.surface?.textureData==nil,!(entity.surface?.faceOverrides.contains {$0.textureData != nil} ?? false) else {throw GeometryIOError.unsupported("VRML/X3D texture resources are unsupported. Export untextured diffuse geometry.")}
            let mesh=try entity.triangulatedMesh();vertexCount+=mesh.vertices.count;indexCount+=mesh.triangles.count+mesh.lineIndices.count
            guard vertexCount<=250_000,indexCount<=2_500_000 else {throw GeometryIOError.invalid("Static scene export exceeds aggregate geometry limits.")}
            if !mesh.triangles.isEmpty {result.append(shape(mesh,entity,false))}
            if !mesh.lineIndices.isEmpty {result.append(shape(mesh,entity,true))}
        }
        return result
    }
}
