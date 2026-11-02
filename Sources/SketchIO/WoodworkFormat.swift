import Foundation
import CryptoKit
import Darwin
import SketchCore

/// Native Woodwork Studio part exchange. Every item is a separate stock part;
/// assembly/component membership and project-level design automation are omitted.
public enum WoodworkFormat {
    private static let maximumBytes=100_000_000
    private static let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var helper:URL {
        Bundle.main.url(forResource:"WoodworkWorker",withExtension:nil) ?? root.appendingPathComponent("artifacts/native/WoodworkWorker")
    }
    public static var isAvailable:Bool {FileManager.default.isExecutableFile(atPath:helper.path)}

    public static func read(url:URL)throws->ModelDocument {
        let data=try boundedData(url)
        return try workspace { directory in
            let input=directory.appendingPathComponent("source.woodwork"),output=directory.appendingPathComponent("items.json")
            try data.write(to:input)
            try invoke("read",input:input,output:output,directory:directory)
            let raw=try JSONSerialization.jsonObject(with:boundedData(output))
            guard let document=raw as? [String:Any],document["version"] as? Int==1,
                  let title=document["title"] as? String,let items=document["items"] as? [[String:Any]],items.count<=10_000 else {
                throw invalid("The native Woodwork reader returned an invalid item document.")
            }
            var entities:[SketchEntity]=[],vertexCount=0,triangleCount=0
            for item in items {
                guard let board=item["board"] as? [String:Any],let textID=board["id"] as? String,let id=UUID(uuidString:textID),
                      let name=board["name"] as? String,let material=board["material"] as? String,
                      let rawMesh=item["mesh"] as? [String:Any],let origin=item["origin"] as? [String:Any],
                      let hidden=item["hidden"] as? Bool,let locked=item["locked"] as? Bool else {
                    throw invalid("The native Woodwork reader returned an incomplete part.")
                }
                let mesh=try JSONDecoder().decode(MeshData.self,from:JSONSerialization.data(withJSONObject:rawMesh))
                try mesh.validate()
                guard mesh.lineIndices.isEmpty else {throw invalid("Native Woodwork parts must contain solid faces.")}
                vertexCount+=mesh.vertices.count;triangleCount+=mesh.triangles.count/3
                guard vertexCount<=250_000,triangleCount<=500_000 else {throw invalid("Woodwork items exceed the expanded geometry limit.")}
                let center=try JSONDecoder().decode(Vec3.self,from:JSONSerialization.data(withJSONObject:origin))
                let color=material=="Walnut" ? "#996633":"#CCA064"
                let surface=SurfaceMaterial(name:materialLabel(material),colorHex:color)
                let native=WoodworkItemRecord(boardData:try JSONSerialization.data(withJSONObject:board,options:.sortedKeys),meshSignature:try signature(mesh))
                let entity=SketchEntity(id:id,name:name,kind:.mesh,origin:center,
                    width:try extent(mesh.vertices.map(\.x)),depth:try extent(mesh.vertices.map(\.z)),height:try extent(mesh.vertices.map(\.y)),
                    colorHex:color,mesh:mesh,metadata:EntityMetadata(isHidden:hidden,isLocked:locked),surface:surface,woodworkItem:native)
                entities.append(entity)
            }
            let result=ModelDocument(entities:entities,name:title)
            try result.validate()
            return result
        }
    }

    public static func write(_ document:ModelDocument,to url:URL)throws {
        guard document.entities.count<=10_000 else {throw invalid("Woodwork Studio supports at most 10,000 individual parts.")}
        // Native meshes can share storage after duplication. Check their total
        // expansion before signatures and JSON materialize every copy in memory.
        var vertices=0,triangles=0
        for entity in document.entities where entity.woodworkItem != nil {
            guard let mesh=entity.mesh else {continue}
            guard mesh.vertices.count<=250_000-vertices,mesh.triangles.count/3<=500_000-triangles else {
                throw invalid("Woodwork items exceed the expanded geometry limit.")
            }
            vertices+=mesh.vertices.count;triangles+=mesh.triangles.count/3
        }
        try document.validate()
        var items:[[String:Any]]=[]
        for entity in document.entities {
            guard entity.surface?.textureData==nil,entity.surface?.faceOverrides.isEmpty ?? true else {
                throw unsupported("\(entity.name): Woodwork Studio stock items support material names, not embedded textures or per-face paint.")
            }
            let material=entity.surface?.name ?? "Wood"
            var item:[String:Any]=["id":entity.id.uuidString,"name":entity.name,"material":material,
                "hidden":!entity.isVisible(in:document),"locked":!entity.isEditable(in:document),"yaw":entity.rotation]
            if let native=entity.woodworkItem {
                guard entity.kind == .mesh,let mesh=entity.mesh,try signature(mesh)==native.meshSignature,
                      entity.profile==nil,entity.profileExtrusion==nil else {
                    throw unsupported("\(entity.name): this imported Woodwork item's shape was changed. Its native stock details cannot be replaced by a bounding box; export a supported stock solid instead.")
                }
                let source=try JSONSerialization.jsonObject(with:native.boardData)
                guard let source=source as? [String:Any] else {throw invalid("The saved native item record is invalid.")}
                // Native material labels have no 200-character editor limit.
                // Keep the exact original value unless the user edits its label.
                if let original=source["material"] as? String,let surface=entity.surface,
                   surface.name==materialLabel(original) {item["material"]=original}
                item["sourceBoard"]=source
                item["mesh"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(mesh))
                item["origin"]=try object(entity.origin)
            } else {
                let circular=entity.kind == .circle && abs(entity.width-entity.depth)<=1e-9*max(1,max(entity.width,entity.depth))
                guard entity.kind == .rectangle || circular,entity.height>0,entity.profile==nil,entity.profileExtrusion==nil else {
                    throw unsupported("\(entity.name): export rectangular or circular stock solids to Woodwork Studio. Arbitrary meshes, ellipses, lines and zero-thickness faces are not converted into bounding boxes.")
                }
                item["width"]=entity.width;item["depth"]=entity.depth;item["height"]=entity.height
                item["origin"]=try object(Vec3(entity.origin.x,entity.origin.y+entity.height/2,entity.origin.z))
                if circular {item["circular"]=true}
            }
            items.append(item)
        }
        let data=try JSONSerialization.data(withJSONObject:["title":document.name,"items":items],options:.sortedKeys)
        guard data.count<=maximumBytes else {throw invalid("Woodwork export exceeds 100 MB.")}
        try workspace { directory in
            let input=directory.appendingPathComponent("items.json"),output=directory.appendingPathComponent("project.woodwork")
            try data.write(to:input)
            try invoke("write",input:input,output:output,directory:directory)
            let native=try boundedData(output)
            guard let result=try JSONSerialization.jsonObject(with:native) as? [String:Any],
                  result["schemaVersion"] as? Int==9,let boards=result["boards"] as? [[String:Any]],
                  boards.count==document.entities.count,(result["assemblies"] as? [Any])?.isEmpty==true,
                  boards.allSatisfy({$0["assemblyID"]==nil && $0["componentID"]==nil}),
                  Set(boards.compactMap{$0["id"] as? String}.compactMap(UUID.init(uuidString:)))==Set(document.entities.map(\.id)) else {
                throw invalid("The Woodwork writer did not preserve independent part identities.")
            }
            try native.write(to:url,options:.atomic)
        }
    }
    private static func signature(_ mesh:MeshData)throws->String {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data:try encoder.encode(mesh)).map{String(format:"%02x",$0)}.joined()
    }
    private static func materialLabel(_ native:String)->String {
        let trimmed=native.trimmingCharacters(in:.whitespacesAndNewlines)
        return trimmed.isEmpty ? "Wood":String(trimmed.prefix(200))
    }
    private static func extent(_ values:[Double])throws->Double {
        guard let low=values.min(),let high=values.max(),(high-low).isFinite else {throw invalid("The Woodwork part bounds are invalid.")}
        return high-low
    }
    private static func object<T:Encodable>(_ value:T)throws->Any {try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))}
    private static func invalid(_ text:String)->GeometryIOError {.invalid(text)}
    private static func unsupported(_ text:String)->GeometryIOError {.unsupported(text)}
    private static func workspace<T>(_ body:(URL)throws->T)throws->T {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("sketchmake-woodwork-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:url)}
        return try body(url)
    }
    private static func size(_ url:URL)->Int {((try? FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber)?.intValue ?? 0}
    private static func boundedData(_ url:URL)throws->Data {
        guard url.isFileURL else {throw invalid("Choose a local Woodwork file.")}
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let count=attributes[.size] as? NSNumber,count.intValue>0,count.intValue<=maximumBytes else {throw invalid("Choose a regular Woodwork file between 1 byte and 100 MB.")}
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
        let data=try file.read(upToCount:maximumBytes+1) ?? Data()
        guard data.count<=maximumBytes else {throw invalid("The Woodwork file exceeds 100 MB.")}
        return data
    }
    private static func invoke(_ operation:String,input:URL,output:URL,directory:URL)throws {
        guard isAvailable else {throw unsupported("The native Woodwork exchange helper is missing. Rebuild the app with the Woodwork helper included.")}
        let log=directory.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath:log.path,contents:nil)
        let handle=try FileHandle(forWritingTo:log);defer{try? handle.close()}
        let process=Process();process.executableURL=helper;process.arguments=[operation,input.path,output.path]
        process.currentDirectoryURL=directory;process.standardOutput=handle;process.standardError=handle
        process.environment=["PATH":"/usr/bin:/bin","TMPDIR":directory.path+"/","LANG":"en_US.UTF-8"]
        try process.run()
        let deadline=Date().addingTimeInterval(60)
        while process.isRunning {
            if Date()>deadline || size(log)>1_000_000 || size(output)>maximumBytes {
                process.terminate();Thread.sleep(forTimeInterval:0.1)
                if process.isRunning {Darwin.kill(process.processIdentifier,SIGKILL)}
                process.waitUntilExit()
                throw invalid("Native Woodwork operation exceeded its time or output limit.")
            }
            Thread.sleep(forTimeInterval:0.025)
        }
        process.waitUntilExit()
        guard process.terminationStatus==0 else {
            let reader=try FileHandle(forReadingFrom:log);defer{try? reader.close()}
            let data=(try? reader.read(upToCount:2000)) ?? Data()
            throw invalid("Native Woodwork operation failed: "+String(decoding:data,as:UTF8.self))
        }
        let attributes=try FileManager.default.attributesOfItem(atPath:output.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,size(output)<=maximumBytes else {throw invalid("Native Woodwork output is invalid or exceeds 100 MB.")}
    }
}
