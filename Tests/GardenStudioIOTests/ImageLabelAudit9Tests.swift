import XCTest
import CoreGraphics
import GardenStudioCore
@testable import GardenStudioIO
final class ImageLabelAudit9Tests:XCTestCase {
    private func directory() throws ->URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:url)}
        return url
    }
    func testLongPNGFilenameImportsWithFullObjectNameAndBoundedPaintLabel() throws {
        let dir=try directory(),name=String(repeating:"a",count:205),file=dir.appendingPathComponent(name+".png")
        let context=try XCTUnwrap(CGContext(data:nil,width:4,height:2,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));context.fill(CGRect(x:0,y:0,width:4,height:2))
        try ImageFormat.encode(XCTUnwrap(context.makeImage()),typeIdentifier:"public.png").write(to:file)
        let doc=try ImageFormat.read(url:file,widthMeters:0.2)
        XCTAssertEqual(doc.entities.first?.name,name)
        XCTAssertEqual(doc.name,name)
        XCTAssertLessThanOrEqual(try XCTUnwrap(doc.entities.first?.surface?.name.count),200)
        XCTAssertEqual(try XCTUnwrap(doc.entities.first?.depth),0.1,accuracy:1e-10)
    }
    func testLongPDFPageLabelImportsWithoutLosingTheObjectLabel() throws {
        let dir=try directory(),name=String(repeating:"p",count:200),file=dir.appendingPathComponent(name+".pdf")
        var media=CGRect(x:0,y:0,width:72,height:36)
        let context=try XCTUnwrap(CGContext(file as CFURL,mediaBox:&media,nil))
        context.beginPDFPage(nil);context.setFillColor(CGColor(gray:0.2,alpha:1));context.fill(media);context.endPDFPage();context.closePDF()
        let doc=try ImageFormat.readPDFReference(url:file,widthMeters:0.2)
        XCTAssertEqual(doc.entities.first?.name,name+" page 1")
        XCTAssertLessThanOrEqual(try XCTUnwrap(doc.entities.first?.surface?.name.count),200)
    }
}
