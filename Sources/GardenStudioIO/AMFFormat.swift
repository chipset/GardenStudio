import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import GardenStudioCore

/// Native static AMF XML (and single-member ZIP) with opaque RGB materials and nested constellations.
/// Curves, gradients, textures, composite/formula materials and transparency are rejected.
public enum AMFFormat {
    private struct Object {var name:String;var mesh:MeshData;var colors:[String]}
    private struct Instance {var id:Int;var transform:[ManufacturingTransform]}
    private static func identifier(_ text:String?)throws->Int {let id=try ManufacturingMesh.integer(text);guard id>=0,id<=Int(Int32.max) else{throw GeometryIOError.invalid("AMF identifiers must be nonnegative 32-bit integers.")};return id}
    private static func color(_ node:XMLElement?)throws->String? {
        guard let node else{return nil};let h=ManufacturingMesh.self
        try h.check(node,children:["r","g","b","a"])
        let rgb=try ["r","g","b"].map{key->Double in let n=try h.one(node,key)!;try h.check(n,children:[]);return try h.number(n.stringValue)}
        let alphaNode=try h.one(node,"a",required:false)
        if let alphaNode {try h.check(alphaNode,children:[])}
        let alpha=try alphaNode.map{try h.number($0.stringValue)} ?? 1
        guard rgb.allSatisfy({$0>=0 && $0<=1}),alpha>=0,alpha<=1 else{throw GeometryIOError.invalid("AMF color channels must be between zero and one.")}
        guard alpha==1 else{throw GeometryIOError.unsupported("Transparent AMF materials are unsupported.")};return try PlainMesh.hex(rgb.map{($0*255).rounded()})
    }
    private static func title(_ node:XMLElement,fallback:String)->String {ManufacturingMesh.kids(node,"metadata").first(where:{ManufacturingMesh.attr($0,"type")=="name"})?.stringValue ?? fallback}
    private static func validateMetadata(_ root:XMLElement)throws {
        for child in ManufacturingMesh.kids(root) {
            if ManufacturingMesh.name(child)=="metadata" {
                try ManufacturingMesh.check(child,children:[],attributes:["type"])
                if ManufacturingMesh.attr(child,"type")=="colorprofile",!(child.stringValue ?? "").lowercased().contains("srgb") {throw GeometryIOError.unsupported("Custom AMF color profiles are unsupported.")}
            } else {try validateMetadata(child)}
        }
    }
    public static func read(url:URL,metersPerUnit:Double?=nil,zUp:Bool?=nil)throws->ModelDocument {
        let data=try PlainMesh.data(url)
        if data.starts(with:[0x50,0x4b]) {
            return try AssetArchive.withExtracted(url:url) {directory in
                let all=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey])?.allObjects as? [URL] ?? []
                let files=try all.filter{try $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true}
                guard files.count==1,files[0].pathExtension.lowercased()=="amf" else{throw GeometryIOError.unsupported("Compressed AMF must contain exactly one .amf XML member.")}
                return try readXML(ManufacturingMesh.xml(PlainMesh.data(files[0])),name:url.deletingPathExtension().lastPathComponent,metersPerUnit:metersPerUnit,zUp:zUp)
            }
        }
        return try readXML(ManufacturingMesh.xml(data),name:url.deletingPathExtension().lastPathComponent,metersPerUnit:metersPerUnit,zUp:zUp)
    }
    private static func readXML(_ root:XMLElement,name:String,metersPerUnit:Double?,zUp:Bool?)throws->ModelDocument {
        let h=ManufacturingMesh.self
        guard h.name(root)=="amf",root.uri==nil || root.uri=="" else{throw GeometryIOError.invalid("Missing supported AMF root.")}
        try h.check(root,children:["metadata","material","object","constellation"],attributes:["unit","version"])
        if let version=h.attr(root,"version"),!["1.0","1.1","1.2"].contains(version){throw GeometryIOError.unsupported("Unsupported AMF version.")}
        try validateMetadata(root)
        let unit=try metersPerUnit ?? h.units(h.attr(root,"unit"),amf:true);try PlainMesh.units(unit)
        var materials:[Int:String]=[:],objects:[Int:Object]=[:],constellations:[Int:[Instance]]=[:],rawV=0,rawT=0
        for material in h.kids(root,"material") {
            try h.check(material,children:["metadata","color"],attributes:["id"]);let id=try identifier(h.attr(material,"id"))
            guard materials[id]==nil,materials.count<10_000 else{throw GeometryIOError.invalid("Duplicate or excessive AMF material identifiers.")}
            materials[id]=try color(h.one(material,"color",required:false)) ?? "#E7DCC8"
        }
        for node in h.kids(root,"object") {
            try h.check(node,children:["metadata","color","mesh"],attributes:["id"]);let id=try identifier(h.attr(node,"id"))
            guard objects[id]==nil,objects.count<50_000 else{throw GeometryIOError.invalid("Duplicate or excessive AMF object identifiers.")}
            let objectColor=try color(h.one(node,"color",required:false)),meshNode=try h.one(node,"mesh")!
            try h.check(meshNode,children:["vertices","volume"])
            let vertices=try h.one(meshNode,"vertices")!;try h.check(vertices,children:["vertex"])
            var mesh=MeshData(),vertexColors:[String?]=[],colors:[String]=[]
            let vertexNodes=h.kids(vertices);rawV += vertexNodes.count
            guard rawV<=250_000 else{throw GeometryIOError.invalid("AMF exceeds 250,000 raw vertices.")}
            for vertex in vertexNodes {
                try h.check(vertex,children:["coordinates","color","metadata"])
                let coordinate=try h.one(vertex,"coordinates")!;try h.check(coordinate,children:["x","y","z"])
                let xyz=try ["x","y","z"].map{key->Double in let n=try h.one(coordinate,key)!;try h.check(n,children:[]);return try h.number(n.stringValue)}
                mesh.vertices.append(Vec3(xyz[0],xyz[1],xyz[2]));vertexColors.append(try color(h.one(vertex,"color",required:false)))
            }
            let volumes=h.kids(meshNode,"volume");guard !volumes.isEmpty else{throw GeometryIOError.invalid("AMF mesh has no volumes.")}
            for volume in volumes {
                try h.check(volume,children:["metadata","color","triangle"],attributes:["materialid"])
                var materialColor:String?
                if let ref=h.attr(volume,"materialid") {let material=try identifier(ref);guard let found=materials[material] else{throw GeometryIOError.invalid("AMF volume refers to a missing material.")};materialColor=found}
                let base=try color(h.one(volume,"color",required:false)) ?? objectColor ?? materialColor ?? "#E7DCC8"
                let triangles=h.kids(volume,"triangle");guard !triangles.isEmpty else{throw GeometryIOError.invalid("AMF volume has no triangles.")};rawT += triangles.count
                guard rawT<=500_000 else{throw GeometryIOError.invalid("AMF exceeds 500,000 raw triangles.")}
                for triangle in triangles {
                    try h.check(triangle,children:["v1","v2","v3","color"])
                    let indices=try ["v1","v2","v3"].map{key->Int in let n=try h.one(triangle,key)!;try h.check(n,children:[]);return try h.integer(n.stringValue?.trimmingCharacters(in:.whitespacesAndNewlines))}
                    guard indices.allSatisfy({mesh.vertices.indices.contains($0)}) else{throw GeometryIOError.invalid("AMF triangle refers to an invalid vertex.")}
                    let face=try color(h.one(triangle,"color",required:false))
                    let corners=indices.map{vertexColors[$0] ?? base}
                    guard face != nil || Set(corners).count==1 else{throw GeometryIOError.unsupported("AMF vertex color gradients are unsupported; use flat triangle colors.")}
                    mesh.triangles += indices;colors.append(face ?? corners[0])
                }
            }
            try mesh.validate();objects[id]=Object(name:title(node,fallback:"AMF object \(id)"),mesh:mesh,colors:colors)
        }
        for constellation in h.kids(root,"constellation") {
            try h.check(constellation,children:["metadata","instance"],attributes:["id"]);let id=try identifier(h.attr(constellation,"id"))
            guard objects[id]==nil,constellations[id]==nil,constellations.count<50_000 else{throw GeometryIOError.invalid("Duplicate or excessive AMF constellation identifier.")}
            let nodes=h.kids(constellation,"instance");guard !nodes.isEmpty,nodes.count<=50_000 else{throw GeometryIOError.invalid("AMF constellation requires bounded instances.")}
            constellations[id]=try nodes.map {instance in
                try h.check(instance,children:["deltax","deltay","deltaz","rx","ry","rz"],attributes:["objectid"])
                func value(_ key:String)throws->Double {guard let n=try h.one(instance,key,required:false) else{return 0};try h.check(n,children:[]);return try h.number(n.stringValue)}
                let rx=try value("rx") * .pi/180,ry=try value("ry") * .pi/180,rz=try value("rz") * .pi/180
                let dx=try value("deltax"),dy=try value("deltay"),dz=try value("deltaz")
                let x=ManufacturingTransform(values:[1,0,0,0,cos(rx),sin(rx),0,-sin(rx),cos(rx),0,0,0])
                let y=ManufacturingTransform(values:[cos(ry),0,-sin(ry),0,1,0,sin(ry),0,cos(ry),0,0,0])
                let z=ManufacturingTransform(values:[cos(rz),sin(rz),0,-sin(rz),cos(rz),0,0,0,1,dx,dy,dz])
                return try Instance(id:identifier(h.attr(instance,"objectid")),transform:[x,y,z])
            }
        }
        var heights:[Int:Int]=[:]
        func graph(_ id:Int,path:Set<Int>)throws->Int {
            guard path.count<64,!path.contains(id),objects[id] != nil || constellations[id] != nil else{throw GeometryIOError.invalid("AMF constellations contain a missing object, cycle or excessive depth.")}
            if let height=heights[id] {return height}
            var height=1
            for child in constellations[id] ?? [] {height=max(height,try graph(child.id,path:path.union([id]))+1)}
            guard height<=64 else{throw GeometryIOError.invalid("AMF constellations exceed the supported hierarchy depth.")};heights[id]=height;return height
        }
        for id in constellations.keys{_ = try graph(id,path:[])}
        let referenced=Set(constellations.values.flatMap{$0.map(\.id)}),roots=(Set(objects.keys).union(constellations.keys)).subtracting(referenced).sorted()
        var entities:[GardenEntity]=[],expandedV=0,expandedT=0
        func emit(_ id:Int,chain:[ManufacturingTransform])throws {
            if let object=objects[id] {
                expandedV += object.mesh.vertices.count;expandedT += object.mesh.triangles.count/3
                guard expandedV<=250_000,expandedT<=500_000,entities.count<50_000 else{throw GeometryIOError.invalid("Expanded AMF constellation exceeds geometry limits.")}
                entities.append(try h.entity(object.mesh,colors:object.colors,name:object.name,chain:chain,unit:unit,zUp:zUp ?? true))
            } else {for child in constellations[id] ?? [] {try emit(child.id,chain:child.transform+chain)}}
        }
        for id in roots {try emit(id,chain:[])}
        guard !entities.isEmpty else{throw GeometryIOError.invalid("AMF contains no triangle geometry.")};let result=ModelDocument(entities:entities,name:name);try result.validate();return result
    }
    public static func write(_ document:ModelDocument,to url:URL)throws {
        let parts=try ManufacturingMesh.exportMeshes(document),colors=Set(parts.flatMap{$0.2}).sorted()
        guard colors.count<=10_000 else{throw GeometryIOError.invalid("AMF exceeds 10,000 materials.")}
        let indices=Dictionary(uniqueKeysWithValues:colors.enumerated().map{($0.element,$0.offset)})
        var xml="<?xml version=\"1.0\" encoding=\"UTF-8\"?><amf unit=\"millimeter\" version=\"1.1\">"
        for (i,color) in colors.enumerated(){let rgb=PlainMesh.rgb(color);xml += "<material id=\"\(i)\"><color><r>\(Double(rgb[0])/255)</r><g>\(Double(rgb[1])/255)</g><b>\(Double(rgb[2])/255)</b><a>1</a></color></material>"}
        for (i,part) in parts.enumerated(){xml += "<object id=\"\(i)\"><metadata type=\"name\">\(ManufacturingMesh.escape(part.0.name))</metadata><mesh><vertices>"
            for v in part.1.vertices{let p=try PlainMesh.encode(v,0.001,true);xml += "<vertex><coordinates><x>\(p.x)</x><y>\(p.y)</y><z>\(p.z)</z></coordinates></vertex>"};xml += "</vertices>"
            for color in Set(part.2).sorted(){xml += "<volume materialid=\"\(indices[color]!)\">"
                for t in stride(from:0,to:part.1.triangles.count,by:3) where part.2[t/3]==color {let ids=part.1.triangles;xml += "<triangle><v1>\(ids[t])</v1><v2>\(ids[t+1])</v2><v3>\(ids[t+2])</v3></triangle>"};xml += "</volume>"
            };xml += "</mesh></object>"
        };xml += "</amf>";try Data(xml.utf8).write(to:url,options:.atomic)
    }
}
