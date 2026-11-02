import XCTest
import AppKit
import GardenStudioCore
@testable import GardenStudioIO

final class NativeModelTests: XCTestCase {
    private func directory() throws -> URL {
        guard NativeModelFormat.isAvailable else { throw XCTSkip("Installed native SketchUp SDK/helper unavailable") }
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("native-model-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    private func texturedDocument() throws -> ModelDocument {
        let image=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:8,bitsPerPixel:32))
        let pixels=try XCTUnwrap(image.bitmapData)
        let rgba:[UInt8]=[255,0,0,255,255,0,0,255,0,0,255,255,0,0,255,255]
        for (i,value) in rgba.enumerated(){pixels[i]=value}
        let data=try XCTUnwrap(image.representation(using:.png,properties:[:]))
        let mesh=MeshData(vertices:[Vec3(1,2,3),Vec3(4,2,3),Vec3(1,7,3),Vec3(-3,-1,2),Vec3(8,-1,2)],triangles:[0,1,2],lineIndices:[3,4],textureCoordinates:[.init(u:0.2,v:0.3),.init(u:1.4,v:0.3),.init(u:0.2,v:2.5),.init(u:0,v:0),.init(u:0,v:0)])
        let surface=SurfaceMaterial(name:"Stripes",colorHex:"#AB3412",textureData:data,textureScale:0.7,textureRotation:0.21)
        return ModelDocument(entities:[GardenEntity(name:"Asymmetric",kind:.mesh,origin:Vec3(2,0,-1),width:11,depth:1,height:8,colorHex:"#AB3412",rotation:0.38,mesh:mesh,surface:surface)],name:"Native fixture")
    }
    func testTexturedSKPPreservesWorldGeometryUVAndLooseEdges() throws {
        let dir=try directory();defer {try? FileManager.default.removeItem(at:dir)}
        let source=try texturedDocument(), normalized=try NativeModelFormat.normalized(source)
        let file=dir.appendingPathComponent("textured.skp")
        try NativeModelFormat.write(source,to:file)
        let result=try NativeModelFormat.read(url:file)
        try result.validate()
        XCTAssertEqual(result.entities.count,2)
        let faceEntity=try XCTUnwrap(result.entities.first{!($0.mesh?.triangles.isEmpty ?? true)})
        let lineEntity=try XCTUnwrap(result.entities.first{!($0.mesh?.lineIndices.isEmpty ?? true)})
        XCTAssertEqual(faceEntity.name,"Asymmetric")
        let expected=try XCTUnwrap(normalized.entities.first?.mesh)
        let actual=try XCTUnwrap(faceEntity.mesh)
        XCTAssertEqual(actual.vertices.count,3)
        XCTAssertEqual(faceEntity.width,actual.vertices.map(\.x).max()!-actual.vertices.map(\.x).min()!,accuracy:1e-8)
        XCTAssertEqual(faceEntity.height,5,accuracy:1e-8)
        XCTAssertEqual(actual.triangles.count,3)
        XCTAssertEqual(lineEntity.mesh?.lineIndices.count,2)
        XCTAssertEqual(lineEntity.colorHex,"#AB3412")
        XCTAssertEqual(faceEntity.surface?.name,"Stripes")
        XCTAssertNotNil(faceEntity.surface?.textureData)
        let uv=try XCTUnwrap(actual.textureCoordinates),expectedUV=try XCTUnwrap(expected.textureCoordinates)
        for (i,v) in expected.vertices.prefix(3).enumerated() {
            let j=try XCTUnwrap(actual.vertices.firstIndex { abs($0.x-v.x)<1e-7 && abs($0.y-v.y)<1e-7 && abs($0.z-v.z)<1e-7 })
            if i < 3 {
                XCTAssertEqual(uv[j].u,expectedUV[i].u,accuracy:1e-6)
                XCTAssertEqual(uv[j].v,expectedUV[i].v,accuracy:1e-6)
            }
        }
    }
    func testLooseLinePreservesOpaqueColor() throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let source=ModelDocument(entities:[GardenEntity(name:"Colored line",kind:.line,origin:Vec3(1,2,3),width:4,depth:5,height:6,colorHex:"#AB3412")])
        let file=dir.appendingPathComponent("line.skp")
        try NativeModelFormat.write(source,to:file)
        let result=try NativeModelFormat.read(url:file)
        XCTAssertEqual(result.entities.first?.colorHex,"#AB3412")
        XCTAssertEqual(result.entities.first?.mesh?.lineIndices.count,2)
        XCTAssertEqual(result.entities.first?.name,"Colored line")
    }
    func testNestedMirroredAndRepeatedComponentsHaveCorrectWorldWinding() throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let headers="/Applications/Maxon Cinema 4D 2026/resource/modules/io_skp/Framework/SketchUpAPI.framework/Versions/A/Headers"
        guard FileManager.default.fileExists(atPath:headers+"/sketchup.h") else{throw XCTSkip("Public SDK headers unavailable for independent fixture author")}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at:dir.appendingPathComponent("SketchUpAPI"),withDestinationURL:URL(fileURLWithPath:headers))
        let source=dir.appendingPathComponent("fixture.mm"),binary=dir.appendingPathComponent("fixture"),file=dir.appendingPathComponent("hierarchy.skp")
        let code="""
        #include "NativeSDKDynamic.hpp"
        void* gSDK;
        int main(int argc,char**argv){@autoreleasepool{try{
          gSDK=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!gSDK)return 2;SUCALL(SUInitialize);
          SUModelRef m=SU_INVALID;SKCheck(SUCALL(SUModelCreate,&m),"model");
          SUEntitiesRef root=SU_INVALID;SKCheck(SUCALL(SUModelGetEntities,m,&root),"root");
          SUGroupRef group=SU_INVALID;SKCheck(SUCALL(SUGroupCreate,&group),"group");SKCheck(SUCALL(SUEntitiesAddGroup,root,group),"group add");
          SUTransformation outer={{0,1,0,0,-1,0,0,0,0,0,1,0,100,200,300,1}};
          SKCheck(SUCALL(SUGroupSetTransform,group,&outer),"group transform");
          SUEntitiesRef children=SU_INVALID;SKCheck(SUCALL(SUGroupGetEntities,group,&children),"children");
          SUComponentDefinitionRef def=SU_INVALID;SKCheck(SUCALL(SUComponentDefinitionCreate,&def),"definition");SKCheck(SUCALL(SUModelAddComponentDefinitions,m,1,&def),"definition add");
          SUEntitiesRef geometry=SU_INVALID;SKCheck(SUCALL(SUComponentDefinitionGetEntities,def,&geometry),"geometry");
          SUPoint3D vertices[3]={{0,0,0},{2,0,0},{0,3,0}};SUFaceRef face=SU_INVALID;
          SKCheck(SUCALL(SUFaceCreateSimple,&face,vertices,3),"face");SKCheck(SUCALL(SUEntitiesAddFaces,geometry,1,&face),"face add");
          for(int i=0;i<2;i++){
            SUComponentInstanceRef instance=SU_INVALID;SKCheck(SUCALL(SUComponentDefinitionCreateInstance,def,&instance),"instance");
            SUTransformation tr={{i==0?-1.0:1.0,0,0,0,0,1,0,0,0,0,1,0,i==0?10.0:20.0,0,0,1}};
            SKCheck(SUCALL(SUComponentInstanceSetTransform,instance,&tr),"instance transform");
            SKCheck(SUCALL(SUComponentInstanceSetName,instance,i==0?"Mirrored":"Repeated"),"instance name");
            SKCheck(SUCALL(SUEntitiesAddInstance,children,instance,nullptr),"instance add");
          }
          SKCheck(SUCALL(SUModelSaveToFileWithVersion,m,argv[2],SUModelVersion_SU2017),"save");SUCALL(SUModelRelease,&m);SUCALL(SUTerminate);return 0;
        }catch(const std::exception&e){fprintf(stderr,"%s\\n",e.what());return 1;}}}
        """
        try code.write(to:source,atomically:true,encoding:.utf8)
        let compiler=Process();compiler.executableURL=URL(fileURLWithPath:"/usr/bin/clang++")
        compiler.arguments=["-std=c++17","-fobjc-arc","-framework","Foundation","-I"+dir.path,"-I"+root.appendingPathComponent("native").path,source.path,"-o",binary.path]
        try compiler.run();compiler.waitUntilExit();XCTAssertEqual(compiler.terminationStatus,0)
        guard compiler.terminationStatus==0 else{return}
        let author=Process();author.executableURL=binary;author.arguments=[try XCTUnwrap(NativeModelFormat.sdkPath),file.path];author.environment=["PATH":"/usr/bin:/bin","TMPDIR":dir.path+"/"]
        try author.run();author.waitUntilExit();XCTAssertEqual(author.terminationStatus,0)
        guard author.terminationStatus==0 else{return}
        let doc=try NativeModelFormat.read(url:file)
        XCTAssertEqual(doc.entities.count,2)
        let mirrored=try XCTUnwrap(doc.entities.first{$0.name=="Mirrored"}.flatMap(\.mesh))
        let repeated=try XCTUnwrap(doc.entities.first{$0.name=="Repeated"}.flatMap(\.mesh))
        for (mesh,inchCoordinates) in [(mirrored,[(100.0,300.0,-210.0),(100,300,-208),(97,300,-210)]),(repeated,[(100.0,300.0,-220.0),(100,300,-222),(97,300,-220)])] {
            for (x,y,z) in inchCoordinates {
                XCTAssertTrue(mesh.vertices.contains{abs($0.x-x*0.0254)<1e-8 && abs($0.y-y*0.0254)<1e-8 && abs($0.z-z*0.0254)<1e-8})
            }
            let a=mesh.vertices[mesh.triangles[0]],b=mesh.vertices[mesh.triangles[1]],c=mesh.vertices[mesh.triangles[2]]
            let normalY=(b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z)
            XCTAssertGreaterThan(normalY,0)
        }
    }
    func testSKP2017ExportCanBeReadByOriginalMakeSDK() throws {
        let dir=try directory();defer {try? FileManager.default.removeItem(at:dir)}
        let legacy="/private/tmp/sketchup-make-original/SketchUp 2017/SketchUp.app/Contents/Frameworks/SketchUpAPI.framework/Versions/A/SketchUpAPI"
        guard FileManager.default.isReadableFile(atPath:legacy) else {throw XCTSkip("Original SketchUp Make 2017 SDK not mounted")}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper=root.appendingPathComponent("artifacts/native/GardenStudioNativeWorker")
        let file=dir.appendingPathComponent("legacy.skp"),output=dir.appendingPathComponent("legacy.json")
        try NativeModelFormat.write(try texturedDocument(),to:file)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/arch")
        process.arguments=["-x86_64","-e","DYLD_LIBRARY_PATH="+URL(fileURLWithPath:legacy).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path,helper.path,legacy,"read-skp",file.path,output.path,dir.path]
        process.environment=["PATH":"/usr/bin:/bin","TMPDIR":dir.path+"/"]
        let log=dir.appendingPathComponent("legacy.log");FileManager.default.createFile(atPath:log.path,contents:nil)
        let handle=try FileHandle(forWritingTo:log);defer{try? handle.close()}
        process.standardOutput=handle;process.standardError=handle
        try process.run();process.waitUntilExit()
        let diagnostic=String(decoding:try Data(contentsOf:log),as:UTF8.self)
        XCTAssertEqual(process.terminationStatus,0,diagnostic)
        guard process.terminationStatus==0 else{return}
        let result=try JSONDecoder().decode(ModelDocument.self,from:Data(contentsOf:output));try result.validate()
        XCTAssertEqual(result.entities.flatMap{$0.mesh?.triangles ?? []}.count,3)
        XCTAssertEqual(result.entities.flatMap{$0.mesh?.lineIndices ?? []}.count,2)
        XCTAssertTrue(result.entities.contains{$0.surface?.textureData != nil})
    }
}
