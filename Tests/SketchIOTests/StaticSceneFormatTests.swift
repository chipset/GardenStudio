import XCTest
import Foundation
import SketchCore
@testable import SketchIO

final class StaticSceneFormatTests: XCTestCase {
    func file(_ text:String,_ ext:String="wrl") throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try text.write(to:url,atomically:true,encoding:.utf8)
        addTeardownBlock {try? FileManager.default.removeItem(at:url)};return url
    }
    let face="Shape { appearance Appearance { material Material { diffuseColor 0.2 0.4 0.6 } } geometry IndexedFaceSet { coord Coordinate { point [ 0 0 0, 2 0 0, 0 3 1 ] } coordIndex [ 0 1 2 -1 ] } }"
    func testWRLTransformMirrorUnitsAndDEFUSE() throws {
        let text="#VRML V2.0 utf8\nTransform { translation 10 20 30 scale -2 3 4 children [ DEF piece \(face) Transform { translation 1 2 3 children [USE piece] } ] }"
        let doc=try VRMLFormat.read(url:file(text),metersPerUnit:0.001)
        XCTAssertEqual(doc.entities.count,2)
        let first=doc.entities[0].mesh!,second=doc.entities[1].mesh!
        XCTAssertEqual(first.vertices[0],Vec3(0.01,0.02,0.03))
        XCTAssertEqual(first.vertices[1].x,0.006,accuracy:1e-12)
        XCTAssertEqual(first.vertices[2].y,0.029,accuracy:1e-12)
        XCTAssertEqual(second.vertices[0].x,0.008,accuracy:1e-12)
        XCTAssertEqual(second.vertices[0].y,0.026,accuracy:1e-12)
        XCTAssertEqual(first.triangles,[0,2,1])
        XCTAssertEqual(doc.entities[0].colorHex,"#336699")
    }
    func testWRLConcaveFaceColorsAndUVs() throws {
        let text="#VRML V2.0 utf8\nShape { geometry IndexedFaceSet { convex FALSE colorPerVertex FALSE coord Coordinate { point [0 0 0, 3 0 0, 3 0 3, 1 0 1, 0 0 3] } coordIndex [0 1 2 3 4 -1] color Color { color [1 0 0] } colorIndex [0] texCoord TextureCoordinate { point [0 0, 1 0, 1 1, 0.3 0.3, 0 1] } texCoordIndex [0 1 2 3 4 -1] } }"
        let mesh=try VRMLFormat.read(url:file(text)).entities[0].mesh!
        XCTAssertEqual(mesh.triangles.count,9)
        XCTAssertEqual(mesh.textureCoordinates?.count,5)
        XCTAssertEqual(mesh.textureCoordinates?[0],TextureCoordinate(u:0,v:1))
    }
    func testWRLAndX3DRoundTripMeshLinesAndFacePaint() throws {
        var entity=SketchEntity(name:"part",kind:.mesh,origin:Vec3(0.2,0.3,-0.1),width:2,depth:1,height:3,colorHex:"#123456",mesh:MeshData(vertices:[Vec3(0,0,0),Vec3(2,0,0),Vec3(0,3,1),Vec3(1,1,1)],triangles:[0,1,2,1,3,2],lineIndices:[0,3],textureCoordinates:[TextureCoordinate(u:0,v:0),TextureCoordinate(u:1,v:0),TextureCoordinate(u:0,v:1),TextureCoordinate(u:1,v:1)]))
        entity.surface=SurfaceMaterial(colorHex:"#123456",faceOverrides:[FaceSurface(triangleIndices:[1],colorHex:"#FF0000")])
        let doc=ModelDocument(entities:[entity])
        for ext in ["wrl","x3d"] {
            let url=try file("",ext)
            if ext=="wrl" {try VRMLFormat.write(doc,to:url)} else {try X3DFormat.write(doc,to:url)}
            let result=try ext=="wrl" ? VRMLFormat.read(url:url):X3DFormat.read(url:url)
            XCTAssertEqual(result.entities.reduce(0){$0+($1.mesh?.triangles.count ?? 0)},6)
            XCTAssertEqual(result.entities.reduce(0){$0+($1.mesh?.lineIndices.count ?? 0)},2)
            XCTAssertTrue(result.entities.contains {$0.surface?.faceOverrides.contains {$0.colorHex=="#FF0000"} == true})
            XCTAssertEqual(result.entities[0].mesh?.vertices.first,Vec3(0.2,0.3,-0.1))
        }
    }
    func testX3DTransformCenterRotationAndZUp() throws {
        let url=try file("<X3D profile='Interchange' version='3.3'><Scene><Transform translation='1 2 3' center='1 0 0' rotation='0 0 1 1.5707963267948966'><Shape><IndexedLineSet coordIndex='0 1 -1'><Coordinate point='1 0 0 2 0 0'/></IndexedLineSet></Shape></Transform></Scene></X3D>","x3d")
        let p=try X3DFormat.read(url:url,zUp:true).entities[0].mesh!.vertices
        XCTAssertEqual(p[0].x,2,accuracy:1e-12);XCTAssertEqual(p[0].y,3,accuracy:1e-12);XCTAssertEqual(p[0].z,-2,accuracy:1e-12)
        XCTAssertEqual(p[1].x,2,accuracy:1e-12);XCTAssertEqual(p[1].z,-3,accuracy:1e-12)
    }
    func testRejectsMalformedSiblingCyclesUnsupportedAndUnsafeXML() throws {
        for text in ["#VRML V2.0 utf8\n\(face) Script { }", "#VRML V2.0 utf8\nDEF A Transform { children [USE A] }", "#VRML V2.0 utf8\n\(face) Shape { geometry IndexedFaceSet { coordIndex [ 4 5 -1 ] } }", "#VRML V2.0 utf8\nShape { geometry Box {} appearance Appearance { material Material { transparency 0.5 } } }", "#VRML V2.0 utf8\nInline { url [\"https://example.org/a.wrl\"] }"] {
            XCTAssertThrowsError(try VRMLFormat.read(url:file(text)))
        }
        for text in ["<!DOCTYPE X3D [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><X3D><Scene>&x;</Scene></X3D>","<X3D><Scene><Script url='https://example.org/x'/></Scene></X3D>","<X3D><Scene><Shape><IndexedFaceSet coordIndex='0 1 2 -1'><Coordinate point='0 0 0 1 0 0 0 1 0'/></IndexedFaceSet></Shape><Inline url='x'/></Scene></X3D>"] {
            XCTAssertThrowsError(try X3DFormat.read(url:file(text,"x3d")))
        }
    }
    func testOptionalFinalSeparatorAndScaleOrientation() throws {
        let wrl="#VRML V2.0 utf8\nTransform { scale 2 3 4 scaleOrientation 0 0 1 1.5707963267948966 children [Shape { geometry IndexedLineSet { coord Coordinate { point [1 0 0 0 1 0] } coordIndex [0 1] } }] }"
        let points=try VRMLFormat.read(url:file(wrl)).entities[0].mesh!.vertices
        XCTAssertEqual(points[0].x,3,accuracy:1e-12)
        XCTAssertEqual(points[0].y,0,accuracy:1e-12)
        XCTAssertEqual(points[1].y,2,accuracy:1e-12)
        let xml="<X3D><Scene><Shape DEF='A'><IndexedFaceSet coordIndex='0 1 2'><Coordinate point='0 0 0 1 0 0 0 1 0'/></IndexedFaceSet></Shape><Transform translation='2 0 0'><Shape USE='A'/></Transform></Scene></X3D>"
        let doc=try X3DFormat.read(url:file(xml,"x3d"))
        XCTAssertEqual(doc.entities.count,2)
        XCTAssertEqual(doc.entities[1].mesh!.vertices[0].x,2,accuracy:1e-12)
    }
    func testRejectsDegenerateFacesAndMisplacedOrTranslucentMaterial() throws {
        for bad in ["Shape { geometry IndexedFaceSet { coord Coordinate {point [0 0 0 1 0 0 2 0 0]} coordIndex [0 1 2 -1] } }", "Shape { appearance Appearance { material Material {transparency 0.5} } geometry IndexedFaceSet { coord Coordinate {point [0 0 0 1 0 0 0 1 0]} coordIndex [0 1 2 -1] } }"] {
            XCTAssertThrowsError(try VRMLFormat.read(url:file("#VRML V2.0 utf8\n"+bad)))
        }
        XCTAssertThrowsError(try X3DFormat.read(url:file("<X3D><Scene><Shape><Appearance><Material/><Material/></Appearance><IndexedLineSet coordIndex='0 1'><Coordinate point='0 0 0 1 1 1'/></IndexedLineSet></Shape></Scene></X3D>","x3d")))
    }
    func testX3DDeclaredUnitsAndReferenceCyclesReject() throws {
        let scene="<Shape><IndexedLineSet coordIndex='0 1'><Coordinate point='0 0 0 25 50 75'/></IndexedLineSet></Shape>"
        let url=try file("<X3D><head><unit category='length' name='millimeter' conversionFactor='0.001'/></head><Scene>"+scene+"</Scene></X3D>","x3d")
        let p=try X3DFormat.read(url:url).entities[0].mesh!.vertices[1]
        XCTAssertEqual(p,Vec3(0.025,0.05,0.075))
        let overridden=try X3DFormat.read(url:url,metersPerUnit:1).entities[0].mesh!.vertices[1]
        XCTAssertEqual(overridden,Vec3(25,50,75))
        XCTAssertThrowsError(try X3DFormat.read(url:file("<X3D><Scene><Group DEF='A'><Group USE='A'/></Group></Scene></X3D>","x3d")))
    }
    func testIndependentAssimpReadsX3DWriter() throws {
        guard FileManager.default.isExecutableFile(atPath:"/opt/homebrew/bin/assimp") else {throw XCTSkip("Optional independent Assimp reader is unavailable.")}
        let url=try file("","x3d"),doc=try VRMLFormat.read(url:file("#VRML V2.0 utf8\n"+face))
        try X3DFormat.write(doc,to:url)
        let p=Process();p.executableURL=URL(fileURLWithPath:"/opt/homebrew/bin/assimp");p.arguments=["info",url.path];let output=Pipe();p.standardOutput=output;p.standardError=output;try p.run();let data=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus,0,String(decoding:data,as:UTF8.self))
    }
}
