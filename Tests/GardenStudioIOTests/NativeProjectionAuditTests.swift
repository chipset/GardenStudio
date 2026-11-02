import XCTest
import GardenStudioCore
@testable import GardenStudioIO

final class NativeProjectionAuditTests:XCTestCase {
    private func fixture(projective:Bool)throws->(URL,URL) {
        guard NativeModelFormat.isAvailable else {throw XCTSkip("Native SDK unavailable")}
        let headers="/Applications/Maxon Cinema 4D 2026/resource/modules/io_skp/Framework/SketchUpAPI.framework/Versions/A/Headers"
        guard FileManager.default.fileExists(atPath:headers+"/sketchup.h") else {throw XCTSkip("SDK headers unavailable for independent fixture author")}
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at:dir.appendingPathComponent("SketchUpAPI"),withDestinationURL:URL(fileURLWithPath:headers))
        let image=dir.appendingPathComponent("texture.png")
        try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")).write(to:image)
        let code="""
        #include "NativeSDKDynamic.hpp"
        #include <cmath>
        void* gSDK;
        int main(int argc,char**argv){@autoreleasepool{try{
          gSDK=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!gSDK)throw std::runtime_error(dlerror());SUCALL(SUInitialize);
          SUModelRef model=SU_INVALID;SKCheck(SUCALL(SUModelCreate,&model),"model");SUEntitiesRef entities=SU_INVALID;SKCheck(SUCALL(SUModelGetEntities,model,&entities),"entities");
          SUMaterialRef mat=SU_INVALID;SKCheck(SUCALL(SUMaterialCreate,&mat),"material");SKCheck(SUCALL(SUMaterialSetName,mat,"Positioned"),"name");SUTextureRef tex=SU_INVALID;SKCheck(SUCALL(SUTextureCreateFromFile,&tex,argv[3],2,2),"texture");SKCheck(SUCALL(SUMaterialSetTexture,mat,tex),"attach");SKCheck(SUCALL(SUModelAddMaterials,model,1,&mat),"addmat");
          SUPoint3D points[4]={{0,0,0},{10,0,0},{10,10,0},{0,10,0}};SUFaceRef face=SU_INVALID;SKCheck(SUCALL(SUFaceCreateSimple,&face,points,4),"face");SKCheck(SUCALL(SUEntitiesAddFaces,entities,1,&face),"addface");
          bool projective=argv[4][0]=='1';SUMaterialPositionInput map={};map.num_uv_coords=4;map.material=mat;
          SUPoint2D coords[4]={{0,0},{1,0},{projective?.75:1,1},{projective?.25:0,1}};
          for(int i=0;i<4;i++){map.points[i]=points[i];map.uv_coords[i]=coords[i];}
          SKCheck(SUCALL(SUFacePositionMaterial,face,true,&map),"position");
          SUMeshHelperRef mesh=SU_INVALID;SKCheck(SUCALL(SUMeshHelperCreate,&mesh,face),"mesh");size_t n=0;SUPoint3D uv[20];SKCheck(SUCALL(SUMeshHelperGetFrontSTQCoords,mesh,20,uv,&n),"uv");
          bool varied=false;for(size_t i=1;i<n;i++)varied|=fabs(uv[i].z-uv[0].z)>1e-7;
          if(varied!=projective)throw std::runtime_error("Fixture did not produce expected homogeneous UVs");
          SKCheck(SUCALL(SUModelSaveToFileWithVersion,model,argv[2],SUModelVersion_SU2017),"save");SUCALL(SUMeshHelperRelease,&mesh);SUCALL(SUModelRelease,&model);SUCALL(SUTerminate);return 0;
        }catch(const std::exception&e){fprintf(stderr,"%s\\n",e.what());return 1;}}}
        """
        let source=dir.appendingPathComponent("fixture.mm"),binary=dir.appendingPathComponent("fixture"),output=dir.appendingPathComponent("positioned.skp")
        try code.write(to:source,atomically:true,encoding:.utf8)
        let compiler=Process();compiler.executableURL=URL(fileURLWithPath:"/usr/bin/clang++")
        compiler.arguments=["-std=c++17","-fobjc-arc","-framework","Foundation","-I"+dir.path,"-I"+root.appendingPathComponent("native").path,source.path,"-o",binary.path]
        try compiler.run();compiler.waitUntilExit();XCTAssertEqual(compiler.terminationStatus,0)
        let author=Process();author.executableURL=binary;author.arguments=[try XCTUnwrap(NativeModelFormat.sdkPath),output.path,image.path,projective ? "1":"0"]
        author.environment=["PATH":"/usr/bin:/bin","TMPDIR":dir.path+"/"]
        try author.run();author.waitUntilExit();XCTAssertEqual(author.terminationStatus,0)
        return (dir,output)
    }
    func testNativeProjectiveTextureRejectsInsteadOfChangingItsMapping()throws {
        let (dir,file)=try fixture(projective:true);defer{try? FileManager.default.removeItem(at:dir)}
        let original=try Data(contentsOf:file)
        XCTAssertThrowsError(try NativeModelFormat.read(url:file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("projective"),error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf:file),original)
    }
    func testNativeAffinePositionedTextureStillImports()throws {
        let (dir,file)=try fixture(projective:false);defer{try? FileManager.default.removeItem(at:dir)}
        let doc=try NativeModelFormat.read(url:file)
        XCTAssertEqual(doc.entities.flatMap{$0.mesh?.triangles ?? []}.count,6)
        XCTAssertNotNil(doc.entities.first?.surface?.textureData)
        let uv=try XCTUnwrap(doc.entities.first?.mesh?.textureCoordinates)
        XCTAssertTrue(uv.allSatisfy{(-1.0e-7...1.0000001).contains($0.u) && (-1.0e-7...1.0000001).contains($0.v)})
    }
}
