import XCTest
import CoreGraphics
import ImageIO
import CoreText
import SketchCore
@testable import SketchIO

final class PDFImageFormatTests: XCTestCase {
    private func url(_ ext: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("exchange-\(UUID()).\(ext)") }
    private func pdf(_ body: (CGContext) -> Void) throws -> URL {
        let output = url("pdf")
        var box = CGRect(x: 0, y: 0, width: 144, height: 72)
        let context = try XCTUnwrap(CGContext(output as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); body(context); context.endPDFPage(); context.closePDF()
        return output
    }
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        return try XCTUnwrap(context.makeImage())
    }
    private func rawPDF(content: String, form: String? = nil) throws -> URL {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /XObject << /Fm1 5 0 R >> >> /Contents 4 0 R >>", "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"]
        if let form { objects.append("<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [2 0 0 3 10 20] /Resources << >> /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream") }
        var result="%PDF-1.4\n", offsets=[0]
        for (index,object) in objects.enumerated() { offsets.append(result.utf8.count); result += "\(index+1) 0 obj\n\(object)\nendobj\n" }
        let xref=result.utf8.count
        result += "xref\n0 \(objects.count+1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { result += String(format:"%010d 00000 n \n",offset) }
        result += "trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let file=url("pdf");try Data(result.utf8).write(to:file);return file
    }
    func testPDFFormMatrixAndCubicPreserveGeometry() throws {
        let file=try rawPDF(content:"q 1 0 0 1 5 7 cm /Fm1 Do Q",form:"0 0 m 20 0 l S")
        defer { try? FileManager.default.removeItem(at:file) }
        let points=try VectorProfiles.paths(document:PDFFormat.read(url:file)).flatMap(\.points)
        XCTAssertEqual(points.map(\.x).min()!,15 * 0.0254/72,accuracy:1e-8)
        XCTAssertEqual(points.map(\.x).max()!,55 * 0.0254/72,accuracy:1e-8)
        XCTAssertEqual(points.map(\.y).min()!,27 * 0.0254/72,accuracy:1e-8)
        let curved=try rawPDF(content:"0 0 m 200 0 -100 0 100 0 c S")
        defer { try? FileManager.default.removeItem(at:curved) }
        let curvePoints=try VectorProfiles.paths(document:PDFFormat.read(url:curved)).flatMap(\.points)
        XCTAssertGreaterThan(curvePoints.count,2)
        let clipped=try rawPDF(content:"0 0 20 20 re W n 0 0 m 20 20 l S")
        defer { try? FileManager.default.removeItem(at:clipped) }
        XCTAssertThrowsError(try PDFFormat.read(url:clipped))
    }
    func testPDFPhysicalPointsAndGraphicsTransform() throws {
        let file = try pdf { context in
            context.translateBy(x: 10, y: 20); context.scaleBy(x: 2, y: 3)
            context.move(to: CGPoint(x: 0, y: 0)); context.addLine(to: CGPoint(x: 72, y: 0)); context.strokePath()
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let doc = try PDFFormat.read(url: file)
        let points = try VectorProfiles.paths(document: doc).flatMap(\.points)
        XCTAssertEqual(points.map(\.x).min()!, 10 * 0.0254 / 72, accuracy: 1e-8)
        XCTAssertEqual(points.map(\.x).max()!, 154 * 0.0254 / 72, accuracy: 1e-8)
        XCTAssertThrowsError(try PDFFormat.read(url: file, page: 2))
    }
    func testVectorExportRoundTripAndImagePDFRejection() throws {
        let source = ModelDocument(entities: [SketchEntity(kind: .rectangle, origin: Vec3(0,0,0), width: 0.0254, depth: 0.0508)])
        let file = url("pdf"); defer { try? FileManager.default.removeItem(at: file) }
        try PDFFormat.write(source, to: file)
        XCTAssertEqual(try XCTUnwrap(CGPDFDocument(file as CFURL)).numberOfPages, 1)
        let imported = try PDFFormat.read(url: file)
        let points = try VectorProfiles.paths(document: imported).flatMap(\.points)
        XCTAssertEqual(points.map(\.x).max()! - points.map(\.x).min()!, 0.0254, accuracy: 1e-7)
        let bitmap = try image()
        let imagePDF = try pdf { $0.draw(bitmap, in: CGRect(x: 0, y: 0, width: 80, height: 40)) }
        defer { try? FileManager.default.removeItem(at: imagePDF) }
        XCTAssertThrowsError(try PDFFormat.read(url: imagePDF)) { XCTAssertTrue($0.localizedDescription.lowercased().contains("image")) }
        XCTAssertNoThrow(try ImageFormat.readPDFReference(url: imagePDF))
    }
    func testUnoutlinedTextPDFRejectsAndReferenceModeWorks() throws {
        let file = try pdf { context in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Text", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)]))
            context.textPosition = CGPoint(x: 10, y: 10)
            CTLineDraw(line, context)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try PDFFormat.read(url: file)) { XCTAssertTrue($0.localizedDescription.contains("unoutlined text")) }
        XCTAssertNoThrow(try ImageFormat.readPDFReference(url: file))
    }
    func testJPEGEncodingAndEXIFOrientation() throws {
        let bitmap = try image()
        let jpeg = try ImageFormat.encode(bitmap, typeIdentifier: "public.jpeg")
        XCTAssertEqual(Array(jpeg.prefix(2)), [255,216])
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let file=url("jpg"); defer { try? FileManager.default.removeItem(at:file) }
        try (data as Data).write(to:file)
        let doc=try ImageFormat.read(url:file,widthMeters:2)
        XCTAssertEqual(doc.entities[0].depth,4,accuracy:1e-8)
        let missing=url("unknown"); try Data("invalid".utf8).write(to:missing)
        defer { try? FileManager.default.removeItem(at:missing) }
        XCTAssertThrowsError(try ImageFormat.read(url:missing))
    }
    func testImageAspectUVsAndRuntimeCapabilities() throws {
        let file = url("png"); defer { try? FileManager.default.removeItem(at: file) }
        try ImageFormat.encode(image(), typeIdentifier: "public.png").write(to: file)
        let doc = try ImageFormat.read(url: file, widthMeters: 2)
        try doc.validate()
        let entity = try XCTUnwrap(doc.entities.first)
        XCTAssertEqual(entity.width, 2); XCTAssertEqual(entity.depth, 1)
        XCTAssertEqual(entity.mesh?.textureCoordinates?.count, 4)
        // The first row of model vertices is the lower edge; normalized UV V=0
        // is the image top, matching glTF and the renderer's explicit UV convention.
        XCTAssertEqual(entity.mesh?.textureCoordinates?.first,TextureCoordinate(u:0,v:1))
        XCTAssertEqual(entity.mesh?.textureCoordinates?[2],TextureCoordinate(u:1,v:0))
        XCTAssertNotNil(entity.surface?.textureData)
        XCTAssertTrue(ImageFormat.supportedImportExtensions.contains("png"))
        XCTAssertTrue(ImageFormat.supportedExportExtensions.contains("jpg"))
        XCTAssertThrowsError(try ImageFormat.read(url: file, imageIndex: 1))
        XCTAssertThrowsError(try ImageFormat.read(url: file, widthMeters: -.infinity))
        XCTAssertThrowsError(try ImageFormat.encode(image(), typeIdentifier: "invalid.type"))
    }
    func testBMPUsesSystemCodecAndStableExtensionAlias() throws {
        let data=try ImageFormat.encode(image(),typeIdentifier:"com.microsoft.bmp")
        XCTAssertEqual(Array(data.prefix(2)),Array("BM".utf8))
        XCTAssertTrue(ImageFormat.supportedImportExtensions.contains("bmp"))
        XCTAssertTrue(ImageFormat.supportedExportExtensions.contains("bmp"))
    }

}
