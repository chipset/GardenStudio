import Foundation
import GardenStudioCore

/// Optional, separately installed Assimp. No downloads or shell command parsing.
/// Conversion is restricted to static geometry; material fidelity varies by exporter.
/// Untrusted imports require a functioning sandbox. Exports parse only app-generated,
/// self-contained GLB and tool-generated output in a private temporary directory.
public enum OptionalAssetConverter {
    private static var executable:URL? {
        ["/opt/homebrew/bin/assimp","/usr/local/bin/assimp","/usr/bin/assimp"].first(where:{FileManager.default.isExecutableFile(atPath:$0)}).map{URL(fileURLWithPath:$0).resolvingSymlinksInPath()}
    }
    private static let importCandidates=["3ds","fbx","x","x3d"]
    // Conservative validated export set. Some Assimp builds emit broken binary FBX.
    private static let exportCandidates=["3ds","fbxa","x","x3d"]
    static func availableDirections(imports:[String],exports:[String],importSandboxAvailable:Bool) -> (imports:[String],exports:[String]) {
        (importSandboxAvailable ? imports : [], exports)
    }
    private static let capabilities:(imports:[String],exports:[String]) = {
        guard executable != nil else {return ([],[])}
        do {
            // Metadata contains no supplied asset and may be queried directly.
            let imports=try run(["listext"],folder:nil,sandboxed:false)
            let exports=try run(["listexport"],folder:nil,sandboxed:false)
            let sandboxAvailable=(try? run(["listext"],folder:nil,sandboxed:true)) != nil
            return availableDirections(imports:importCandidates.filter{imports.contains("*."+$0+";") || imports.hasSuffix("*."+$0+"\n")},exports:exportCandidates.filter{exports.components(separatedBy:.whitespacesAndNewlines).contains($0)},importSandboxAvailable:sandboxAvailable)
        } catch {return ([],[])}
    }()
    public static var isAvailable:Bool {!capabilities.imports.isEmpty || !capabilities.exports.isEmpty}
    public static var supportedImportExtensions:[String] {capabilities.imports}
    /// Values are Assimp CLI format IDs (fbxa writes ASCII .fbx).
    public static var supportedExportExtensions:[String] {capabilities.exports}
    private static func temporary() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("GardenStudio-convert-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);return root
    }
    private static func quote(_ value:String) -> String {"\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""}
    private static func run(_ args:[String],folder:URL?,sandboxed:Bool) throws -> String {
        guard let tool=executable else {throw GeometryIOError.unsupported("Install Assimp separately to enable optional conversion.")}
        guard !sandboxed || FileManager.default.isExecutableFile(atPath:"/usr/bin/sandbox-exec") else {throw GeometryIOError.unsupported("Optional asset imports require the local-resource sandbox.")}
        let temp=try temporary();defer{try? FileManager.default.removeItem(at:temp)}
        let log=temp.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath:log.path,contents:nil)
        let handle=try FileHandle(forWritingTo:log);defer{try? handle.close()}
        var profile="(version 1)(deny default)(allow process*)(allow sysctl-read)(allow mach-lookup)(allow file-read-metadata)(allow file-read* (subpath \"/System\") (subpath \"/usr/lib\") (subpath \"/private/var/db\") (subpath \"/opt/homebrew/lib\") (subpath \"/opt/homebrew/Cellar\") (subpath \"/usr/local/lib\") (literal \"/dev/null\") (literal \"/dev/urandom\") (literal \(quote(tool.path))))"
        profile += "(allow file-read* file-write* (subpath \(quote(temp.resolvingSymlinksInPath().path))))"
        if let folder {profile += "(allow file-read* file-write* (subpath \(quote(folder.resolvingSymlinksInPath().path))))"}
        let process=Process()
        process.executableURL=sandboxed ? URL(fileURLWithPath:"/usr/bin/sandbox-exec") : tool
        process.arguments=sandboxed ? ["-p",profile,tool.path]+args : args
        process.currentDirectoryURL=folder ?? temp;process.standardOutput=handle;process.standardError=handle
        process.environment=["PATH":"/usr/bin:/bin","HOME":temp.path,"TMPDIR":temp.path]
        try process.run();let deadline=Date().addingTimeInterval(15)
        while process.isRunning {
            let bytes=(try? log.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            var outputBytes=0
            if let folder,let files=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.fileSizeKey]) {for case let url as URL in files {outputBytes += (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0;if outputBytes>128*1024*1024 {break}}}
            if Date()>deadline || bytes>1024*1024 || outputBytes>128*1024*1024 {
                process.terminate();Thread.sleep(forTimeInterval:0.05)
                if process.isRunning {kill(process.processIdentifier,SIGKILL)}
                process.waitUntilExit();throw GeometryIOError.invalid("Assimp conversion exceeded its time or output limit.")
            }
            Thread.sleep(forTimeInterval:0.02)
        }
        process.waitUntilExit()
        let data=try Data(contentsOf:log)
        guard data.count<=1024*1024,process.terminationStatus==0 else {throw GeometryIOError.unsupported("Assimp conversion or its required local-resource sandbox is unavailable for this file.")}
        return String(data:data,encoding:.utf8) ?? ""
    }
    public static func read(url:URL,metersPerUnit:Double=1,zUp:Bool=false) throws -> ModelDocument {
        let ext=url.pathExtension.lowercased()=="fbxa" ? "fbx":url.pathExtension.lowercased()
        guard supportedImportExtensions.contains(ext),metersPerUnit.isFinite,metersPerUnit>0 else {throw GeometryIOError.unsupported("This optional static-mesh import is unavailable, or the unit scale is invalid.")}
        let size=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        guard size.isRegularFile==true,let bytes=size.fileSize,bytes<=64*1024*1024 else {throw GeometryIOError.invalid("Optional input must be a regular file under 64 MB.")}
        let temp=try temporary();defer{try? FileManager.default.removeItem(at:temp)}
        // Stage only the selected source. External texture/scene references are not
        // granted read access; unsupported missing dependencies fail conversion.
        let input=temp.appendingPathComponent("input."+ext);try FileManager.default.copyItem(at:url,to:input)
        let info=try run(["info",input.path],folder:temp,sandboxed:true)
        for label in ["Animations","Bones","Animation Channels"] {
            if info.range(of:"(?m)^\\s*"+label+":\\s*[1-9][0-9]*",options:.regularExpression) != nil {throw GeometryIOError.unsupported("Animated or skinned assets cannot be converted without loss.")}
        }
        guard info.range(of:"(?m)^\\s*Meshes:\\s*[1-9]",options:.regularExpression) != nil else {throw GeometryIOError.invalid("Assimp found no supported static meshes.")}
        let output=temp.appendingPathComponent("converted.glb")
        _=try run(["export",input.path,output.path,"-fglb2","-tri"],folder:temp,sandboxed:true)
        var document=try GLTFFormat.read(url:output)
        for i in document.entities.indices {
            guard var mesh=document.entities[i].mesh else {continue}
            mesh.vertices=mesh.vertices.map {v in zUp ? Vec3(v.x*metersPerUnit,v.z*metersPerUnit,-v.y*metersPerUnit):Vec3(v.x*metersPerUnit,v.y*metersPerUnit,v.z*metersPerUnit)}
            document.entities[i].mesh=mesh
            document.entities[i].width=mesh.vertices.map(\.x).max()!-mesh.vertices.map(\.x).min()!
            document.entities[i].height=mesh.vertices.map(\.y).max()!-mesh.vertices.map(\.y).min()!
            document.entities[i].depth=mesh.vertices.map(\.z).max()!-mesh.vertices.map(\.z).min()!
        }
        document.name=url.deletingPathExtension().lastPathComponent;try document.validate();return document
    }
    public static func write(_ document:ModelDocument,to url:URL,format:String) throws {
        guard supportedExportExtensions.contains(format) else {throw GeometryIOError.unsupported("This optional exporter is unavailable.")}
        // Portable converter formats are geometry/basic color only. Refuse texture
        // loss rather than silently flattening a textured model.
        guard document.entities.allSatisfy({$0.surface?.textureData==nil && $0.surface?.faceOverrides.allSatisfy{$0.textureData==nil} != false}) else {throw GeometryIOError.unsupported("Optional conversion exports geometry and basic colors only; use GLB or COLLADA for textures.")}
        let worldMeshes=try document.entities.map{try $0.triangulatedMesh()}
        guard worldMeshes.allSatisfy({$0.lineIndices.isEmpty}) else {throw GeometryIOError.unsupported("Optional export supports triangle surfaces only; use GLB for lines.")}
        if format=="3ds" {
            guard worldMeshes.allSatisfy({$0.vertices.count<=65535 && $0.triangles.count/3<=65535}) else {throw GeometryIOError.unsupported("3DS meshes are limited to 65,535 vertices and faces.")}
        }
        let temp=try temporary();defer{try? FileManager.default.removeItem(at:temp)}
        let input=temp.appendingPathComponent("input.glb"),output=temp.appendingPathComponent("output."+(format=="fbxa" ? "fbx":format))
        var prepared=document
        if format=="3ds" {
            // Assimp's 3DS exporter writes coordinates verbatim while its reader
            // applies the format's Z-up basis. Supply that basis explicitly.
            for i in prepared.entities.indices {
                var mesh=try prepared.entities[i].triangulatedMesh()
                mesh.vertices=mesh.vertices.map{Vec3($0.x,-$0.z,$0.y)}
                prepared.entities[i].kind = .mesh;prepared.entities[i].origin=Vec3(0,0,0);prepared.entities[i].rotation=0;prepared.entities[i].mesh=mesh
                prepared.entities[i].profile=nil;prepared.entities[i].profileExtrusion=nil
            }
        }
        try GLTFFormat.write(prepared,to:input,binary:true)
        try verifyOwnedGLB(input)
        _=try run(["export",input.path,output.path,"-f"+format],folder:temp,sandboxed:false)
        let contents=try Data(contentsOf:output)
        guard !contents.isEmpty,contents.count<=64*1024*1024 else {throw GeometryIOError.invalid("Converted output is empty or exceeds 64 MB.")}
        // Static self-contained target formats only; no generated companion files.
        let others=try FileManager.default.contentsOfDirectory(at:temp,includingPropertiesForKeys:nil).filter{![input.lastPathComponent,output.lastPathComponent].contains($0.lastPathComponent)}
        guard others.isEmpty else {throw GeometryIOError.unsupported("The converter emitted unsupported companion resources: " + others.map(\.lastPathComponent).joined(separator:","))}
        // This input is the trusted tool's own output, never a caller-supplied
        // asset. Round-trip it before exposing the destination file.
        let info=try run(["info",output.path],folder:temp,sandboxed:false)
        guard info.range(of:"(?m)^\\s*Meshes:\\s*[1-9]",options:.regularExpression) != nil else {throw GeometryIOError.invalid("Converted output contains no meshes.")}
        let verified=temp.appendingPathComponent("verified.glb")
        _=try run(["export",output.path,verified.path,"-fglb2","-tri"],folder:temp,sandboxed:false)
        try verifyOwnedGLB(verified)
        let restored=try GLTFFormat.read(url:verified)
        let originalBounds=try bounds(document),restoredBounds=try bounds(restored)
        for (a,b) in zip(originalBounds,restoredBounds) {
            guard abs(a-b)<=max(1,abs(a),abs(b))*0.0001 else {throw GeometryIOError.invalid("The optional exporter changed geometry bounds.")}
        }
        let generated=try FileManager.default.contentsOfDirectory(at:temp,includingPropertiesForKeys:nil)
        guard generated.allSatisfy({[input.lastPathComponent,output.lastPathComponent,verified.lastPathComponent].contains($0.lastPathComponent)}) else {throw GeometryIOError.unsupported("The converter emitted unsupported companion resources.")}
        try contents.write(to:url,options:.atomic)
    }
    /// Accept only bounded GLB containers without any external resource URI.
    /// Called exclusively on this process's freshly generated private files.
    private static func verifyOwnedGLB(_ url:URL) throws {
        let data=try Data(contentsOf:url)
        func uint32(_ offset:Int)->Int {(0..<4).reduce(0){$0 | Int(data[offset+$1]) << ($1*8)}}
        guard data.count>=20,data.count<=64*1024*1024,Array(data.prefix(4))==[103,108,84,70],uint32(4)==2,uint32(8)==data.count else {throw GeometryIOError.invalid("Converter GLB is malformed or too large.")}
        let jsonCount=uint32(12)
        guard jsonCount<=data.count-20,uint32(16)==0x4e4f534a,
              let json=try JSONSerialization.jsonObject(with:data.subdata(in:20..<(20+jsonCount))) as? [String:Any] else {throw GeometryIOError.invalid("Converter GLB has no valid JSON chunk.")}
        func localOnly(_ value:Any)->Bool {
            if let dictionary=value as? [String:Any] {
                if dictionary["uri"] != nil {return false}
                return dictionary.values.allSatisfy(localOnly)
            }
            if let array=value as? [Any] {return array.allSatisfy(localOnly)}
            return true
        }
        guard localOnly(json) else {throw GeometryIOError.unsupported("Optional conversion requires a self-contained GLB without resource URIs.")}
    }
    private static func bounds(_ document:ModelDocument) throws -> [Double] {
        let vertices=try document.entities.flatMap{try $0.triangulatedMesh().vertices}
        guard !vertices.isEmpty else {throw GeometryIOError.invalid("Converted geometry is empty.")}
        return [vertices.map(\.x).min()!,vertices.map(\.x).max()!,vertices.map(\.y).min()!,vertices.map(\.y).max()!,vertices.map(\.z).min()!,vertices.map(\.z).max()!]
    }

}
