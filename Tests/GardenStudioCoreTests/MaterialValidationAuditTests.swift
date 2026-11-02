import XCTest
import ImageIO
@testable import GardenStudioCore
final class MaterialValidationAuditTests:XCTestCase {
    func testCorruptPNGWithoutDecodablePixelsCannotBecomeAnEmbeddedTexture() throws {
        let valid=try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try SurfaceMaterial(textureData:valid).validate()
        var corrupt=valid
        for index in 41..<52 {corrupt[index]=0}
        let source=try XCTUnwrap(CGImageSourceCreateWithData(corrupt as CFData,nil))
        XCTAssertNotNil(CGImageSourceCopyPropertiesAtIndex(source,0,nil))
        XCTAssertEqual(CGImageSourceGetCount(source),1)
        let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary))
        XCTAssertNil(image.dataProvider?.data)
        XCTAssertThrowsError(try SurfaceMaterial(textureData:corrupt).validate())
    }
}
