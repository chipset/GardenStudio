import XCTest
import SketchCore
import CryptoKit
@testable import SketchIO

final class WoodworkFormatTests:XCTestCase {
    private func directory()throws->URL {
        guard WoodworkFormat.isAvailable else {throw XCTSkip("Woodwork exchange helper unavailable")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("woodwork-format-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    private func nativeBoard(id:UUID=UUID(),name:String="Part",x:Double=0)->[String:Any] {
        ["id":id.uuidString,"name":name,"material":"Walnut","width":6.0,"thickness":0.75,"length":12.0,"x":x,"y":3.0,"z":-4.0,"rotation":27.0,"rotationX":16.0,"rotationZ":-11.0]
    }
    private func writeNative(_ boards:[[String:Any]],assemblies:[[String:Any]]=[],to url:URL)throws {
        try JSONSerialization.data(withJSONObject:["schemaVersion":9,"title":"Items","boards":boards,"assemblies":assemblies],options:.sortedKeys).write(to:url)
    }
    private func root(_ url:URL)throws->[String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])}
    func testNewStockExportsAsIndependentNativeItemsWithPhysicalDimensions()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let a=SketchEntity(name:"Shelf",kind:.rectangle,origin:Vec3(1,2,-3),width:0.5,depth:0.3,height:0.02,rotation:0.43)
        let b=SketchEntity(name:"Side",kind:.rectangle,origin:Vec3(-1,0,1),width:0.4,depth:0.2,height:0.04)
        let document=ModelDocument(entities:[a,b],name:"Separate items"),file=dir.appendingPathComponent("items.woodwork")
        try WoodworkFormat.write(document,to:file)
        let json=try root(file),boards=try XCTUnwrap(json["boards"] as? [[String:Any]])
        XCTAssertEqual(boards.count,2)
        XCTAssertEqual((json["assemblies"] as? [Any])?.count,0)
        XCTAssertEqual(Set(boards.compactMap{$0["id"] as? String}.map{$0.lowercased()}),Set([a.id,b.id].map{$0.uuidString.lowercased()}))
        XCTAssertTrue(boards.allSatisfy{$0["assemblyID"]==nil && $0["componentID"]==nil})
        let first=try XCTUnwrap(boards.first{$0["name"] as? String=="Shelf"})
        XCTAssertEqual(try XCTUnwrap(first["width"] as? Double)*0.0254,a.width,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(first["thickness"] as? Double)*0.0254,a.height,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(first["length"] as? Double)*0.0254,a.depth,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(first["y"] as? Double)*0.0254,a.origin.y+a.height/2,accuracy:1e-10)
        let imported=try WoodworkFormat.read(url:file)
        XCTAssertEqual(imported.entities.count,2)
        XCTAssertTrue(imported.entities.allSatisfy{$0.metadata?.groupID==nil && $0.metadata?.componentPartID==nil})
        for source in document.entities {
            let actual=try XCTUnwrap(imported.entities.first{$0.id==source.id})
            try assertBounds(actual.triangulatedMesh().vertices,source.triangulatedMesh().vertices)
        }
    }
    func testNativeAssemblyMembersImportAsSeparateItemsWithEffectiveFlags()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let group=UUID(),idA=UUID(),idB=UUID(),input=dir.appendingPathComponent("source.woodwork")
        var a=nativeBoard(id:idA,name:"A"),b=nativeBoard(id:idB,name:"B",x:10)
        a["assemblyID"]=group.uuidString;b["assemblyID"]=group.uuidString
        try writeNative([a,b],assemblies:[["id":group.uuidString,"name":"Existing assembly","hidden":true,"locked":true]],to:input)
        let model=try WoodworkFormat.read(url:input)
        XCTAssertEqual(Set(model.entities.map(\.id)),[idA,idB])
        XCTAssertTrue(model.editor?.groups.isEmpty ?? true)
        XCTAssertTrue(model.entities.allSatisfy{$0.metadata?.groupID==nil && $0.metadata?.isHidden==true && $0.metadata?.isLocked==true})
        XCTAssertEqual(model.effectiveSelection([idA]),[idA])
        let output=dir.appendingPathComponent("separate.woodwork")
        try WoodworkFormat.write(model,to:output)
        let json=try root(output),boards=try XCTUnwrap(json["boards"] as? [[String:Any]])
        XCTAssertEqual((json["assemblies"] as? [Any])?.count,0)
        XCTAssertTrue(boards.allSatisfy{$0["assemblyID"]==nil && $0["hidden"] as? Bool==true && $0["locked"] as? Bool==true})
    }
    func testDetailedItemMetadataSurvivesProjectSaveDuplicateAndNativeRoundtrip()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        var board=nativeBoard(name:"Drilled shelf")
        board["features"]=[["id":UUID().uuidString,"kind":"hole","u":0.0,"v":0.0,"width":0.5,"length":0.5,"depth":0.25]]
        let file=dir.appendingPathComponent("drilled.woodwork")
        try writeNative([board],to:file)
        let imported=try WoodworkFormat.read(url:file)
        var model=try JSONDecoder().decode(ModelDocument.self,from:JSONEncoder().encode(imported))
        XCTAssertNotNil(model.entities[0].woodworkItem)
        model.entities[0].origin=Vec3(2,3,-4);model.entities[0].rotation=0.7
        var duplicate=model.entities[0];duplicate.id=UUID();duplicate.name="Drilled shelf copy";duplicate.origin.x+=1
        model.entities.append(duplicate)
        let output=dir.appendingPathComponent("moved.woodwork")
        try WoodworkFormat.write(model,to:output)
        let boards=try XCTUnwrap(try root(output)["boards"] as? [[String:Any]])
        XCTAssertEqual(Set(boards.compactMap{$0["id"] as? String}).count,2)
        XCTAssertTrue(boards.allSatisfy{($0["features"] as? [Any])?.count==1 && $0["assemblyID"]==nil})
        let reread=try WoodworkFormat.read(url:output)
        XCTAssertEqual(reread.entities.count,2)
        for entity in model.entities {
            let roundtripped=try XCTUnwrap(reread.entities.first{$0.id==entity.id})
            let expected=try entity.triangulatedMesh(),actual=try roundtripped.triangulatedMesh()
            XCTAssertEqual(actual.triangles,expected.triangles,"Detailed native topology must survive placement and duplication")
            XCTAssertEqual(actual.vertices.count,expected.vertices.count)
            for (actualPoint,expectedPoint) in zip(actual.vertices,expected.vertices) {
                XCTAssertEqual(actualPoint.x,expectedPoint.x,accuracy:1e-8)
                XCTAssertEqual(actualPoint.y,expectedPoint.y,accuracy:1e-8)
                XCTAssertEqual(actualPoint.z,expectedPoint.z,accuracy:1e-8)
            }
            try assertBounds(actual.vertices,expected.vertices)
        }
    }
    func testUnsupportedOrEditedShapesDoNotReplaceTheDestination()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let output=dir.appendingPathComponent("keep.woodwork"),original=Data("original".utf8)
        try original.write(to:output)
        let ellipse=SketchEntity(kind:.circle,origin:Vec3(0,0,0),width:1,depth:2,height:1)
        XCTAssertThrowsError(try WoodworkFormat.write(ModelDocument(entities:[ellipse]),to:output))
        XCTAssertEqual(try Data(contentsOf:output),original)
        let source=dir.appendingPathComponent("native.woodwork")
        try writeNative([nativeBoard()],to:source)
        var model=try WoodworkFormat.read(url:source)
        model.entities[0].mesh!.vertices[0].x+=0.01
        XCTAssertThrowsError(try WoodworkFormat.write(model,to:output))
        XCTAssertEqual(try Data(contentsOf:output),original)
        let stock=SketchEntity(kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:1,height:1,surface:SurfaceMaterial(faceOverrides:[FaceSurface(triangleIndices:[0],colorHex:"#FF0000")]))
        XCTAssertThrowsError(try WoodworkFormat.write(ModelDocument(entities:[stock]),to:output))
        XCTAssertEqual(try Data(contentsOf:output),original)
    }
    func testCircularStockRemainsOneNativeItemWithCircularProfile()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let circle=SketchEntity(name:"Round top",kind:.circle,origin:Vec3(1,2,3),width:0.8,depth:0.8,height:0.03)
        let output=dir.appendingPathComponent("round.woodwork")
        try WoodworkFormat.write(ModelDocument(entities:[circle]),to:output)
        let json=try root(output),boards=try XCTUnwrap(json["boards"] as? [[String:Any]])
        XCTAssertEqual(boards.count,1)
        let profile=try XCTUnwrap(boards[0]["profile"] as? [String:Any])
        XCTAssertEqual(profile["kind"] as? String,"roundedCorners")
        XCTAssertEqual(try XCTUnwrap(profile["amount"] as? Double)*0.0254,0.4,accuracy:1e-10)
        let restored=try WoodworkFormat.read(url:output)
        XCTAssertEqual(restored.entities.count,1)
        let mesh=try restored.entities[0].triangulatedMesh()
        XCTAssertGreaterThan(mesh.triangles.count,12*3,"A circular profile cannot become rectangular stock")
        try assertBounds(mesh.vertices,circle.triangulatedMesh().vertices)
    }
    func testForgingTheMeshDigestCannotReplaceNativeShapeWithModifiedGeometry()throws {
        let dir=try directory();defer{try? FileManager.default.removeItem(at:dir)}
        let input=dir.appendingPathComponent("native.woodwork"),output=dir.appendingPathComponent("keep.woodwork")
        try writeNative([nativeBoard()],to:input)
        var model=try WoodworkFormat.read(url:input)
        model.entities[0].mesh!.vertices[0].x+=0.01
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let forged=SHA256.hash(data:try encoder.encode(model.entities[0].mesh!)).map{String(format:"%02x",$0)}.joined()
        model.entities[0].woodworkItem!.meshSignature=forged
        let original=Data("Existing destination".utf8);try original.write(to:output)
        XCTAssertThrowsError(try WoodworkFormat.write(model,to:output))
        XCTAssertEqual(try Data(contentsOf:output),original)
    }
    private func assertBounds(_ actual:[Vec3],_ expected:[Vec3],file:StaticString=#filePath,line:UInt=#line)throws {
        for key in [\Vec3.x,\Vec3.y,\Vec3.z] {
            XCTAssertEqual(try XCTUnwrap(actual.map{$0[keyPath:key]}.min()),try XCTUnwrap(expected.map{$0[keyPath:key]}.min()),accuracy:1e-8,file:file,line:line)
            XCTAssertEqual(try XCTUnwrap(actual.map{$0[keyPath:key]}.max()),try XCTUnwrap(expected.map{$0[keyPath:key]}.max()),accuracy:1e-8,file:file,line:line)
        }
    }
}
