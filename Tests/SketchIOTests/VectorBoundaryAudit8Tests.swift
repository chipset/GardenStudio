import XCTest
import CoreGraphics
import SketchCore
@testable import SketchIO
final class VectorBoundaryAudit8Tests:XCTestCase {
    func testScaledVectorExportCannotReplaceFileWithUnreadableCoordinates() throws {
        let document=ModelDocument(entities:[SketchEntity(kind:.rectangle,origin:Vec3(1e10,0,0),width:1,depth:1)])
        for ext in ["eps","svg"] {
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"."+ext)
            defer{try? FileManager.default.removeItem(at:url)}
            let original=Data("Existing vector file".utf8);try original.write(to:url)
            if ext=="eps" {XCTAssertThrowsError(try EPSFormat.write(document,to:url))}
            else {XCTAssertThrowsError(try SVGFormat.write(document,to:url))}
            XCTAssertEqual(try Data(contentsOf:url),original)
        }
    }
    func testNormalPhysicalVectorExportsRemainReadable() throws {
        let document=ModelDocument(entities:[SketchEntity(kind:.rectangle,origin:Vec3(1,0,-2),width:0.25,depth:0.5)])
        for ext in ["eps","svg"] {
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"."+ext)
            defer{try? FileManager.default.removeItem(at:url)}
            let result:ModelDocument
            if ext=="eps" {try EPSFormat.write(document,to:url);result=try EPSFormat.read(url:url)}
            else {try SVGFormat.write(document,to:url);result=try SVGFormat.read(url:url)}
            XCTAssertEqual(result.entities.count,1)
            XCTAssertEqual(result.entities[0].width,0.25,accuracy:1e-8)
            XCTAssertEqual(result.entities[0].depth,0.5,accuracy:1e-8)
        }
    }
    func testPDFNonopaqueGraphicsStateDoesNotBecomeOrdinaryCutGeometry() throws {
        for alpha in [0.25,1.0] {
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
            defer{try? FileManager.default.removeItem(at:url)}
            var box=CGRect(x:0,y:0,width:100,height:100)
            let context=try XCTUnwrap(CGContext(url as CFURL,mediaBox:&box,nil))
            context.beginPDFPage(nil);context.setAlpha(alpha)
            context.move(to:CGPoint(x:10,y:10));context.addLine(to:CGPoint(x:90,y:90));context.strokePath()
            context.endPDFPage();context.closePDF()
            if alpha<1 {XCTAssertThrowsError(try PDFFormat.read(url:url))}
            else {XCTAssertEqual(try PDFFormat.read(url:url).entities.count,1)}
        }
    }
    func testPDFExplicitOpaqueGraphicsStateRemainsSupported() throws {
        for state in ["/CA 1 /ca 1 /SMask /None /BM /Compatible","/CA 0","/CA true","/BM /Multiply","/SMask << /S /Alpha >>"] {
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
            defer{try? FileManager.default.removeItem(at:url)}
            let content="q /GS0 gs 10 10 m 90 90 l S Q\n"
            let objects=[
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /ExtGState << /GS0 5 0 R >> >> /Contents 4 0 R >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
                "<< /Type /ExtGState \(state) >>"
            ]
            var text="%PDF-1.4\n",offsets=[Int]()
            for (i,object) in objects.enumerated(){offsets.append(text.utf8.count);text+="\(i+1) 0 obj\n\(object)\nendobj\n"}
            let xref=text.utf8.count
            text+="xref\n0 \(objects.count+1)\n0000000000 65535 f \n"
            for offset in offsets{text+=String(format:"%010d 00000 n \n",offset)}
            text+="trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
            try text.write(to:url,atomically:true,encoding:.utf8)
            if state.hasPrefix("/CA 1 "){XCTAssertEqual(try PDFFormat.read(url:url).entities.count,1)}
            else{XCTAssertThrowsError(try PDFFormat.read(url:url))}
        }
    }
}
