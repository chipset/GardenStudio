import Foundation
import Darwin
import SketchCore

/// Uses a separately installed SDK in a disposable helper process. Vendor libraries
/// are never copied into this app. Static geometry exchange is not a project clone.
public enum NativeModelFormat {
    private static let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var helper:URL {
        if let value=Bundle.main.url(forResource:"SketchNativeWorker",withExtension:nil) {return value}
        return root.appendingPathComponent("artifacts/native/SketchNativeWorker")
    }
    public static var sdkPath:String? {
        let configured=ProcessInfo.processInfo.environment["SKETCHUP_SDK_PATH"]
        let paths=[configured].compactMap{$0} + [
            "/Applications/Maxon Cinema 4D 2026/resource/modules/io_skp/Framework/SketchUpAPI.framework/Versions/A/SketchUpAPI",
            "/Applications/Maxon Cinema 4D 2024/resource/modules/io_skp/Framework/SketchUpAPI.framework/Versions/A/SketchUpAPI",
            "/Applications/Maxon Cinema 4D 2023/resource/modules/i_skp/Framework/SketchUpAPI.framework/Versions/A/SketchUpAPI",
            "/Applications/Adobe Dimension/Adobe Dimension.app/Contents/Frameworks/SketchUpAPI.framework/Versions/A/SketchUpAPI"]
        return paths.first{FileManager.default.isReadableFile(atPath:$0)}
    }
    private static let availability:Bool = {
        guard sdkPath != nil,FileManager.default.isExecutableFile(atPath:helper.path) else{return false}
        return (try? workspace { dir in
            let output=dir.appendingPathComponent("probe.json")
            try invoke("probe",input:output,output:output,directory:dir)
            return try Data(contentsOf:output).count>0
        }) ?? false
    }()
    public static var isAvailable:Bool {availability}
    private static func workspace<T>(_ body:(URL)throws->T)throws->T {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("sketchmake-native-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:directory)}
        return try body(directory)
    }
    private static func invoke(_ operation:String,input:URL,output:URL,directory:URL)throws {
        guard let sdk=sdkPath,FileManager.default.isExecutableFile(atPath:helper.path) else {
            throw GeometryIOError.unsupported("Native SketchUp exchange requires the helper and a separately installed compatible SketchUp SDK. The Ruby bridge remains available.")
        }
        let log=directory.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath:log.path,contents:nil)
        let handle=try FileHandle(forWritingTo:log);defer{try? handle.close()}
        let process=Process(); process.executableURL=helper
        process.arguments=[sdk,operation,input.path,output.path,directory.path]
        process.currentDirectoryURL=directory
        process.standardOutput=handle;process.standardError=handle
        // The SDK concatenates temporary filenames directly onto TMPDIR.
        process.environment=["PATH":"/usr/bin:/bin","TMPDIR":directory.path+"/","LANG":"en_US.UTF-8"]
        try process.run()
        let deadline=Date().addingTimeInterval(60)
        func fileSize(_ url:URL)->Int {
            ((try? FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber)?.intValue ?? 0
        }
        while process.isRunning {
            let logSize=fileSize(log)
            let outputSize=fileSize(output)
            if Date()>deadline || logSize>1_000_000 || outputSize>100_000_000 {
                process.terminate();Thread.sleep(forTimeInterval:0.1)
                if process.isRunning {Darwin.kill(process.processIdentifier,SIGKILL)}
                process.waitUntilExit()
                throw GeometryIOError.invalid("Native SketchUp operation exceeded its time or output limit.")
            }
            Thread.sleep(forTimeInterval:0.025)
        }
        process.waitUntilExit()
        guard process.terminationStatus==0 else {
            let reader=try FileHandle(forReadingFrom:log);defer{try? reader.close()}
            let data=(try? reader.read(upToCount:2000)) ?? Data()
            let message=String(decoding:data,as:UTF8.self)
            throw GeometryIOError.invalid("Native SketchUp operation failed: "+message)
        }
        guard FileManager.default.fileExists(atPath:output.path),fileSize(output)<=100_000_000 else{throw GeometryIOError.invalid("Native output is missing or exceeds 100 MB.")}
    }
    private static func checkInput(_ url:URL)throws {
        // NSURL resource values may retain the size from a previous import even
        // after the same path is replaced or grown by another application.
        let values=try FileManager.default.attributesOfItem(atPath:url.path)
        let size=(values[.size] as? NSNumber)?.intValue ?? 0
        guard url.isFileURL,values[.type] as? FileAttributeType == .typeRegular,size>0,size<=100_000_000 else{throw GeometryIOError.invalid("Choose a regular native file between 1 byte and 100 MB.")}
    }
    public static func read(url:URL)throws->ModelDocument {
        try checkInput(url)
        return try workspace { directory in
            let output=directory.appendingPathComponent("model.json")
            try invoke("read-skp",input:url,output:output,directory:directory)
            var document=try JSONDecoder().decode(ModelDocument.self,from:Data(contentsOf:output))
            document.name=url.deletingPathExtension().lastPathComponent
            try document.validate();return document
        }
    }
    public static func write(_ document:ModelDocument,to url:URL)throws {
        try document.validate()
        let normalized=try normalized(document)
        // Native faces are serialized independently. The reader expands each
        // triangle to three vertices and each loose edge to two, even when the
        // source mesh shares indexed vertices. Do not create an export that the
        // same codec cannot reopen or replace an existing file with one.
        let expandedVertices=normalized.entities.reduce(0) {
            $0 + ($1.mesh?.triangles.count ?? 0) + ($1.mesh?.lineIndices.count ?? 0)
        }
        guard expandedVertices<=250_000 else {
            throw GeometryIOError.invalid("Native export exceeds the 250,000 expanded-vertex import limit; export a smaller selection.")
        }
        try workspace { directory in
            let input=directory.appendingPathComponent("model.json"),output=directory.appendingPathComponent("model.skp")
            let data=try JSONEncoder().encode(normalized)
            guard data.count<=100_000_000 else{throw GeometryIOError.invalid("Native export exceeds 100 MB.")}
            try data.write(to:input)
            try invoke("write-skp",input:input,output:output,directory:directory)
            try Data(contentsOf:output).write(to:url,options:.atomic)
        }
    }
    public static func readMaterial(url:URL)throws->SurfaceMaterial {
        try checkInput(url)
        return try workspace { directory in
            let output=directory.appendingPathComponent("material.json")
            try invoke("read-skm",input:url,output:output,directory:directory)
            let material=try JSONDecoder().decode(SurfaceMaterial.self,from:Data(contentsOf:output))
            try material.validate();return material
        }
    }
    public static func writeMaterial(_ material:SurfaceMaterial,to url:URL)throws {
        try material.validate()
        guard material.faceOverrides.isEmpty else{throw GeometryIOError.unsupported("SKM contains one material; remove face assignments before exporting a material.")}
        try workspace { directory in
            let input=directory.appendingPathComponent("material.json"),output=directory.appendingPathComponent("material.skm")
            try JSONEncoder().encode(material).write(to:input)
            try invoke("write-skm",input:input,output:output,directory:directory)
            try Data(contentsOf:output).write(to:url,options:.atomic)
        }
    }
    static func normalized(_ document:ModelDocument)throws->ModelDocument {
        var entities:[SketchEntity]=[]
        for entity in document.entities {
            var mesh=try entity.triangulatedMesh()
            var surface=entity.surface ?? SurfaceMaterial(colorHex:entity.colorHex)
            if surface.textureData != nil || surface.faceOverrides.contains(where:{$0.textureData != nil}) {
                mesh=try GLTFFormat.bakingTextureCoordinates(mesh,entity:entity,surface:surface)
            }
            var assigned=Set<Int>()
            func append(_ triangles:[Int],_ lines:[Int],_ appearance:SurfaceMaterial)throws {
                guard !triangles.isEmpty || !lines.isEmpty else{return}
                let used=Set(triangles+lines).sorted()
                let map=Dictionary(uniqueKeysWithValues:used.enumerated().map{($0.element,$0.offset)})
                let compact=MeshData(vertices:used.map{mesh.vertices[$0]},triangles:triangles.map{map[$0]!},lineIndices:lines.map{map[$0]!},textureCoordinates:mesh.textureCoordinates.map{uv in used.map{uv[$0]}})
                var paint=appearance;paint.faceOverrides=[];paint.textureScale=1;paint.textureRotation=0
                entities.append(try PlainMesh.entity(compact,name:entity.name,surface:paint))
            }
            for face in surface.faceOverrides {
                assigned.formUnion(face.triangleIndices)
                try append(face.triangleIndices.flatMap{Array(mesh.triangles[($0*3)..<($0*3+3)])},[],SurfaceMaterial(name:surface.name,colorHex:face.colorHex,textureData:face.textureData))
            }
            surface.faceOverrides=[]
            try append((0..<(mesh.triangles.count/3)).filter{!assigned.contains($0)}.flatMap{Array(mesh.triangles[($0*3)..<($0*3+3)])},mesh.lineIndices,surface)
        }
        let result=ModelDocument(entities:entities,name:document.name)
        try result.validate();return result
    }
}
