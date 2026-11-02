import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import GardenStudioCore

/// Bounded XML and static mesh utilities shared by the native manufacturing formats.
enum ManufacturingMesh {
    static let core = "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
    static func xml(_ data: Data) throws -> XMLElement {
        guard data.count <= 64*1024*1024, let text=String(data:data,encoding:.utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw GeometryIOError.invalid("Manufacturing XML must be UTF-8, at most 64 MB, without entity declarations.") }
        let document=try XMLDocument(data:data,options:[])
        guard let root=document.rootElement() else {throw GeometryIOError.invalid("Missing manufacturing XML root.")}; return root
    }
    static func kids(_ e:XMLElement,_ name:String?=nil)->[XMLElement] { (e.children ?? []).compactMap{$0 as? XMLElement}.filter{name == nil || ($0.localName ?? $0.name) == name} }
    static func attr(_ e:XMLElement,_ name:String)->String? { e.attribute(forName:name)?.stringValue }
    static func name(_ e:XMLElement)->String { e.localName ?? e.name ?? "" }
    static func check(_ e:XMLElement,children:Set<String>,attributes:Set<String>=[],namespace:String?=nil) throws {
        if let namespace, let uri=e.uri, !uri.isEmpty, uri != namespace {throw GeometryIOError.unsupported("Unsupported manufacturing XML extension namespace: \(uri)")}
        for child in kids(e) {
            guard children.contains(name(child)), namespace == nil || child.uri == nil || child.uri == "" || child.uri == namespace else {throw GeometryIOError.unsupported("Unsupported manufacturing element: \(child.name ?? "unknown"). Textures, curved geometry and extension data require another format.")}
        }
        for a in e.attributes ?? [] {guard attributes.contains(a.name ?? "") else {throw GeometryIOError.unsupported("Unsupported manufacturing attribute: \(a.name ?? "unknown")")}}
    }
    static func one(_ e:XMLElement,_ name:String,required:Bool=true) throws -> XMLElement? {let list=kids(e,name);guard list.count <= 1,!required || list.count == 1 else {throw GeometryIOError.invalid("Missing or repeated \(name) element.")};return list.first}
    static func integer(_ text:String?)throws->Int {guard let text else{throw GeometryIOError.invalid("Missing manufacturing integer.")};return try PlainMesh.integer(text)}
    static func positive(_ text:String?)throws->Int {let v=try integer(text);guard v>0, v<=Int(Int32.max) else{throw GeometryIOError.invalid("Manufacturing identifiers must be positive 32-bit integers.")};return v}
    static func number(_ text:String?)throws->Double {guard let text else{throw GeometryIOError.invalid("Missing manufacturing coordinate.")};return try PlainMesh.number(text.trimmingCharacters(in:.whitespacesAndNewlines))}
    static func units(_ text:String?,amf:Bool=false)throws->Double {
        let units=["micron":0.000001,"millimeter":0.001,"centimeter":0.01,"inch":0.0254,"foot":0.3048,"meter":1.0]
        guard let result=units[text ?? "millimeter"] else{throw GeometryIOError.unsupported("Unsupported manufacturing unit.")};return result
    }
    static func escape(_ text:String)->String {text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&apos;")}
    static func paints(_ e:GardenEntity,count:Int)throws->[String] {
        guard e.surface?.textureData == nil, e.surface?.faceOverrides.allSatisfy({$0.textureData == nil}) ?? true else{throw GeometryIOError.unsupported("Manufacturing mesh export does not support textures. Use COLLADA or GLB.")}
        var colors=Array(repeating:e.surface?.colorHex ?? e.colorHex,count:count)
        for f in e.surface?.faceOverrides ?? [] {for i in f.triangleIndices {colors[i]=f.colorHex}}
        return colors
    }
    static func exportMeshes(_ document:ModelDocument)throws->[(GardenEntity,MeshData,[String])] {
        try document.validate();var totalV=0,totalT=0,result:[(GardenEntity,MeshData,[String])]=[]
        for e in document.entities {
            let mesh=try e.triangulatedMesh()
            guard mesh.lineIndices.isEmpty else{throw GeometryIOError.unsupported("Manufacturing mesh formats contain triangle surfaces; line geometry is unsupported.")}
            totalV += mesh.vertices.count;totalT += mesh.triangles.count/3
            guard totalV<=250_000,totalT<=500_000 else{throw GeometryIOError.invalid("Manufacturing export exceeds 250,000 vertices or 500,000 triangles.")}
            result.append((e,mesh,try paints(e,count:mesh.triangles.count/3)))
        }
        guard !result.isEmpty else{throw GeometryIOError.invalid("No triangle meshes to export.")};return result
    }
    static func entity(_ mesh:MeshData,colors:[String],name:String,chain:[ManufacturingTransform],unit:Double,zUp:Bool)throws->GardenEntity {
        var result=mesh
        result.vertices=try mesh.vertices.map { v in var p=v;for t in chain {p=t.apply(p)};let decoded=PlainMesh.decode(p,unit,zUp);guard [decoded.x,decoded.y,decoded.z].allSatisfy(\.isFinite) else{throw GeometryIOError.invalid("Manufacturing transforms overflow coordinates.")};return decoded }
        if chain.filter({$0.determinant<0}).count % 2 == 1 {for i in stride(from:0,to:result.triangles.count,by:3){result.triangles.swapAt(i+1,i+2)}}
        return try PlainMesh.colored(result,colors:colors,name:name).entities[0]
    }
}

struct ManufacturingTransform {
    let values:[Double]
    static let identity=ManufacturingTransform(values:[1,0,0,0,1,0,0,0,1,0,0,0])
    var determinant:Double {let m=values;return m[0]*(m[4]*m[8]-m[5]*m[7])-m[1]*(m[3]*m[8]-m[5]*m[6])+m[2]*(m[3]*m[7]-m[4]*m[6])}
    func apply(_ p:Vec3)->Vec3 {let m=values;return Vec3(p.x*m[0]+p.y*m[3]+p.z*m[6]+m[9],p.x*m[1]+p.y*m[4]+p.z*m[7]+m[10],p.x*m[2]+p.y*m[5]+p.z*m[8]+m[11])}
    static func parse(_ text:String?)throws->ManufacturingTransform {
        guard let text else{return .identity};let tokens=text.split(whereSeparator:{$0.isWhitespace});guard tokens.count==12 else{throw GeometryIOError.invalid("3MF transforms require twelve matrix values.")}
        let result=ManufacturingTransform(values:try tokens.map{try PlainMesh.number(String($0))})
        guard result.determinant.isFinite,abs(result.determinant)>1e-15 else{throw GeometryIOError.unsupported("Singular or nearly singular manufacturing transforms are unsupported.")};return result
    }
}

/// Native 3MF core OPC packages: static meshes, components/build matrices and opaque base materials.
/// Production, texture, color-gradient, beam, slice and printer-specific extensions are rejected.
public enum ThreeMFFormat {
    private struct Object {var name:String;var mesh:MeshData?;var colors:[String];var components:[(Int,ManufacturingTransform)]}
    public static func read(url:URL,metersPerUnit:Double?=nil,zUp:Bool?=nil)throws->ModelDocument {
        try AssetArchive.withExtracted(url:url) {directory in
            let relURL=directory.appendingPathComponent("_rels/.rels")
            let rel=try ManufacturingMesh.xml(PlainMesh.data(relURL))
            guard ManufacturingMesh.name(rel)=="Relationships" else{throw GeometryIOError.invalid("3MF package lacks OPC relationships.")}
            try ManufacturingMesh.check(rel,children:["Relationship"],namespace:"http://schemas.openxmlformats.org/package/2006/relationships")
            var models:[URL]=[],modelPaths:[String]=[],allowedParts:Set<String>=["[Content_Types].xml","_rels/.rels"]
            for r in ManufacturingMesh.kids(rel) {
                try ManufacturingMesh.check(r,children:[],attributes:["Id","Type","Target","TargetMode"])
                guard ManufacturingMesh.attr(r,"TargetMode") != "External" else{throw GeometryIOError.unsupported("External 3MF package relationships are unsupported.")}
                let type=ManufacturingMesh.attr(r,"Type") ?? "",target=ManufacturingMesh.attr(r,"Target") ?? ""
                let path=target.hasPrefix("/") ? String(target.dropFirst()):target
                guard !path.isEmpty,!path.contains(":"),!path.contains("%"),!path.contains("\\"),!path.split(separator:"/").contains("..") else{throw GeometryIOError.invalid("Unsafe 3MF relationship target.")}
                allowedParts.insert(path)
                let resource=directory.appendingPathComponent(path).standardizedFileURL
                guard resource.path.hasPrefix(directory.standardizedFileURL.path+"/"),FileManager.default.fileExists(atPath:resource.path) else{throw GeometryIOError.invalid("Missing 3MF package relationship target.")}
                if type=="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel" {models.append(resource);modelPaths.append(path)}
                else if type != "http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail" {throw GeometryIOError.unsupported("Unsupported 3MF package relationship: \(type)")}
            }
            guard models.count==1 else{throw GeometryIOError.invalid("3MF requires one root model relationship.")}
            let content=try ManufacturingMesh.xml(PlainMesh.data(directory.appendingPathComponent("[Content_Types].xml")))
            try validateContentTypes(content,modelPath:modelPaths[0])
            // Part relationships may contain texture/production references; do not silently omit them.
            let parts=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []
            guard !parts.contains(where:{$0.pathExtension=="rels" && $0.standardizedFileURL != relURL.standardizedFileURL}) else{throw GeometryIOError.unsupported("3MF model-part relationships and external production resources are unsupported.")}
            for part in parts where (try part.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile==true {
                let relative=String(part.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count+1))
                guard allowedParts.contains(relative) else{throw GeometryIOError.unsupported("Unsupported 3MF package part: \(relative). Slicer project data and extension resources require their originating application.")}
            }
            return try readModel(ManufacturingMesh.xml(PlainMesh.data(models[0])),name:url.deletingPathExtension().lastPathComponent,metersPerUnit:metersPerUnit,zUp:zUp)
        }
    }
    private static func validateContentTypes(_ root:XMLElement,modelPath:String)throws {
        let h=ManufacturingMesh.self,namespace="http://schemas.openxmlformats.org/package/2006/content-types"
        guard h.name(root)=="Types",root.uri==namespace else{throw GeometryIOError.invalid("Invalid OPC content-type manifest.")}
        try h.check(root,children:["Default","Override"],namespace:namespace)
        var defaults:[String:String]=[:],overrides:[String:String]=[:]
        for type in h.kids(root) {
            let isDefault=h.name(type)=="Default"
            try h.check(type,children:[],attributes:isDefault ? ["Extension","ContentType"]:["PartName","ContentType"],namespace:namespace)
            guard let key=h.attr(type,isDefault ? "Extension":"PartName"),!key.isEmpty,let value=h.attr(type,"ContentType"),!value.isEmpty else{throw GeometryIOError.invalid("Missing OPC content-type declaration.")}
            if isDefault {guard defaults[key.lowercased()]==nil else{throw GeometryIOError.invalid("Duplicate OPC content type.")};defaults[key.lowercased()]=value}
            else {guard overrides[key]==nil,key.hasPrefix("/"),!key.contains(".."),!key.contains(":"),!key.contains("%"),!key.contains("\\") else{throw GeometryIOError.invalid("Invalid OPC part content type.")};overrides[key]=value}
        }
        let modelType=overrides["/"+modelPath] ?? defaults[URL(fileURLWithPath:modelPath).pathExtension.lowercased()]
        guard modelType=="application/vnd.ms-package.3dmanufacturing-3dmodel+xml",defaults["rels"]=="application/vnd.openxmlformats-package.relationships+xml" else{throw GeometryIOError.invalid("3MF model or relationship content type is missing.")}
    }
    private static func readModel(_ root:XMLElement,name:String,metersPerUnit:Double?,zUp:Bool?)throws->ModelDocument {
        let h=ManufacturingMesh.self
        guard h.name(root)=="model",root.uri==h.core else{throw GeometryIOError.invalid("Missing 3MF core model namespace.")}
        try h.check(root,children:["metadata","resources","build"],attributes:["unit","xml:lang","requiredextensions"],namespace:h.core)
        guard (h.attr(root,"requiredextensions") ?? "").isEmpty else{throw GeometryIOError.unsupported("Required 3MF extensions are unsupported.")}
        let unit=try metersPerUnit ?? h.units(h.attr(root,"unit"));try PlainMesh.units(unit)
        for metadata in h.kids(root,"metadata") {try h.check(metadata,children:[],attributes:["name","preserve"],namespace:h.core)}
        let resources=try h.one(root,"resources")!,build=try h.one(root,"build")!
        try h.check(resources,children:["object","basematerials"],namespace:h.core);try h.check(build,children:["item"],namespace:h.core)
        var identifiers=Set<Int>(),materials:[Int:[String]]=[:],objects:[Int:Object]=[:],rawVertices=0,rawTriangles=0
        for group in h.kids(resources,"basematerials") {
            try h.check(group,children:["base"],attributes:["id"],namespace:h.core);let id=try h.positive(h.attr(group,"id"))
            guard identifiers.insert(id).inserted,materials.count<10_000 else{throw GeometryIOError.invalid("Duplicate or excessive 3MF resource identifiers.")}
            let bases=h.kids(group,"base");guard !bases.isEmpty,bases.count<=10_000 else{throw GeometryIOError.invalid("Invalid 3MF material count.")}
            materials[id]=try bases.map {base in
                try h.check(base,children:[],attributes:["name","displaycolor"],namespace:h.core)
                guard let color=h.attr(base,"displaycolor"),color.range(of:"^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$",options:.regularExpression) != nil else{throw GeometryIOError.invalid("Invalid 3MF display color.")}
                guard color.count==7 || color.suffix(2).uppercased()=="FF" else{throw GeometryIOError.unsupported("Transparent 3MF base materials are unsupported.")};return String(color.prefix(7)).uppercased()
            }
        }
        func color(pid:Int?,index:Int?=nil)throws->String {
            guard let pid else {guard index==nil else{throw GeometryIOError.invalid("3MF material index lacks a property group.")};return "#E7DCC8"}
            guard let list=materials[pid],let index,list.indices.contains(index) else{throw GeometryIOError.invalid("Invalid 3MF base-material reference.")};return list[index]
        }
        for node in h.kids(resources,"object") {
            try h.check(node,children:["mesh","components","metadata"],attributes:["id","type","name","partnumber","pid","pindex","thumbnail"],namespace:h.core)
            for metadata in h.kids(node,"metadata") {try h.check(metadata,children:[],attributes:["name","preserve"],namespace:h.core)}
            guard h.attr(node,"thumbnail")==nil else{throw GeometryIOError.unsupported("Per-object 3MF thumbnail relationships are unsupported.")}
            let id=try h.positive(h.attr(node,"id"));guard identifiers.insert(id).inserted,objects.count<50_000,(h.attr(node,"type") ?? "model")=="model" else{throw GeometryIOError.unsupported("Duplicate, excessive or non-model 3MF objects are unsupported.")}
            let pid=try h.attr(node,"pid").map{try h.positive($0)},pindex=try h.attr(node,"pindex").map{try h.integer($0)},base=try color(pid:pid,index:pindex)
            let meshNode=try h.one(node,"mesh",required:false),components=try h.one(node,"components",required:false)
            guard (meshNode==nil) != (components==nil) else{throw GeometryIOError.invalid("3MF objects require exactly one mesh or component collection.")}
            var object=Object(name:h.attr(node,"name") ?? "3MF object \(id)",mesh:nil,colors:[],components:[])
            if let meshNode {
                try h.check(meshNode,children:["vertices","triangles"],namespace:h.core);let vertices=try h.one(meshNode,"vertices")!,triangles=try h.one(meshNode,"triangles")!
                try h.check(vertices,children:["vertex"],namespace:h.core);try h.check(triangles,children:["triangle"],namespace:h.core)
                let rawV=h.kids(vertices),rawT=h.kids(triangles);rawVertices += rawV.count;rawTriangles += rawT.count
                guard rawVertices<=250_000,rawTriangles<=500_000 else{throw GeometryIOError.invalid("3MF exceeds raw geometry limits.")}
                var mesh=MeshData()
                mesh.vertices=try rawV.map {v in try h.check(v,children:[],attributes:["x","y","z"],namespace:h.core);return try Vec3(h.number(h.attr(v,"x")),h.number(h.attr(v,"y")),h.number(h.attr(v,"z")))}
                for t in rawT {
                    try h.check(t,children:[],attributes:["v1","v2","v3","pid","p1","p2","p3"],namespace:h.core)
                    mesh.triangles += try ["v1","v2","v3"].map{try h.integer(h.attr(t,$0))}
                    let tpid=try h.attr(t,"pid").map{try h.positive($0)} ?? pid
                    let p1=try h.attr(t,"p1").map{try h.integer($0)} ?? pindex
                    let p2=try h.attr(t,"p2").map{try h.integer($0)} ?? p1,p3=try h.attr(t,"p3").map{try h.integer($0)} ?? p1
                    guard p1==p2,p1==p3 else{throw GeometryIOError.unsupported("3MF gradient triangle properties are unsupported.")}
                    object.colors.append(tpid==nil && p1==nil ? base:try color(pid:tpid,index:p1))
                }
                try mesh.validate();object.mesh=mesh
            } else if let components {
                guard pid==nil,pindex==nil else{throw GeometryIOError.unsupported("Properties on composite 3MF objects are unsupported.")}
                try h.check(components,children:["component"],namespace:h.core)
                guard !h.kids(components).isEmpty,h.kids(components).count<=50_000 else{throw GeometryIOError.invalid("Invalid 3MF component count.")}
                object.components=try h.kids(components).map {c in try h.check(c,children:[],attributes:["objectid","transform"],namespace:h.core);return try (h.positive(h.attr(c,"objectid")),ManufacturingTransform.parse(h.attr(c,"transform")))}
            }
            objects[id]=object
        }
        var heights:[Int:Int]=[:]
        func validateGraph(_ id:Int,path:Set<Int>)throws->Int {
            guard path.count<64,!path.contains(id),let object=objects[id] else{throw GeometryIOError.invalid("3MF components contain a cycle, missing object or excessive depth.")}
            if let height=heights[id] {return height}
            var height=1
            for child in object.components {height=max(height,try validateGraph(child.0,path:path.union([id]))+1)}
            guard height<=64 else{throw GeometryIOError.invalid("3MF components exceed the supported hierarchy depth.")};heights[id]=height;return height
        }
        for id in objects.keys {_ = try validateGraph(id,path:[])}
        var entities:[GardenEntity]=[],expandedVertices=0,expandedTriangles=0
        func emit(_ id:Int,chain:[ManufacturingTransform])throws {
            let object=objects[id]!
            if let mesh=object.mesh {
                expandedVertices += mesh.vertices.count;expandedTriangles += mesh.triangles.count/3
                guard expandedVertices<=250_000,expandedTriangles<=500_000,entities.count<50_000 else{throw GeometryIOError.invalid("Expanded 3MF build exceeds geometry limits.")}
                entities.append(try h.entity(mesh,colors:object.colors,name:object.name,chain:chain,unit:unit,zUp:zUp ?? true))
            }
            for child in object.components {try emit(child.0,chain:[child.1]+chain)}
        }
        for item in h.kids(build) {
            try h.check(item,children:[],attributes:["objectid","transform","partnumber","printable"],namespace:h.core)
            guard [nil,"1","true"].contains(h.attr(item,"printable")) else{throw GeometryIOError.unsupported("Non-printable 3MF build items are unsupported.")}
            let id=try h.positive(h.attr(item,"objectid"));guard objects[id] != nil else{throw GeometryIOError.invalid("3MF build references a missing object.")};try emit(id,chain:[ManufacturingTransform.parse(h.attr(item,"transform"))])
        }
        guard !entities.isEmpty else{throw GeometryIOError.invalid("3MF build contains no triangle geometry.")};let result=ModelDocument(entities:entities,name:name);try result.validate();return result
    }
    public static func write(_ document:ModelDocument,to url:URL)throws {
        let parts=try ManufacturingMesh.exportMeshes(document),colors=Set(parts.flatMap{$0.2}).sorted();guard colors.count<=10_000 else{throw GeometryIOError.invalid("3MF exceeds 10,000 base colors.")}
        let colorIndex=Dictionary(uniqueKeysWithValues:colors.enumerated().map{($0.element,$0.offset)})
        var model="<?xml version=\"1.0\" encoding=\"UTF-8\"?><model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"\(ManufacturingMesh.core)\"><resources><basematerials id=\"1\">"
        for (i,color) in colors.enumerated(){model += "<base name=\"Color \(i)\" displaycolor=\"\(color)FF\"/>"};model += "</basematerials>"
        for (i,part) in parts.enumerated(){model += "<object id=\"\(i+2)\" type=\"model\" name=\"\(ManufacturingMesh.escape(part.0.name))\"><mesh><vertices>"
            for v in part.1.vertices{let p=try PlainMesh.encode(v,0.001,true);model += "<vertex x=\"\(p.x)\" y=\"\(p.y)\" z=\"\(p.z)\"/>"};model += "</vertices><triangles>"
            for t in stride(from:0,to:part.1.triangles.count,by:3){let ids=part.1.triangles;model += "<triangle v1=\"\(ids[t])\" v2=\"\(ids[t+1])\" v3=\"\(ids[t+2])\" pid=\"1\" p1=\"\(colorIndex[part.2[t/3]]!)\"/>"};model += "</triangles></mesh></object>"
        }
        model += "</resources><build>";for i in parts.indices{model += "<item objectid=\"\(i+2)\"/>"};model += "</build></model>"
        let types="<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/></Types>"
        let rel="<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/></Relationships>"
        try AssetArchive.writeStored(files:["[Content_Types].xml":Data(types.utf8),"_rels/.rels":Data(rel.utf8),"3D/3dmodel.model":Data(model.utf8)],to:url)
    }
}
