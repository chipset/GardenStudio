import XCTest
import CoreGraphics
import ImageIO
import SketchCore
@testable import SketchIO

final class NativeMaterialTests: XCTestCase {
    private func stripedPNG() throws -> Data {
        var pixels: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255]
        return try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try XCTUnwrap(context.makeImage())
            let output = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return output as Data
        }
    }
    func testTexturedSKMRoundTripPreservesRepeatSizeAndPixels() throws {
        guard NativeModelFormat.isAvailable else { throw XCTSkip("Installed native SketchUp SDK/helper unavailable") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".skm")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = SurfaceMaterial(name: "Striped paint", colorHex: "#FFFFFF", textureData: try stripedPNG(), textureScale: 0.375)
        try NativeModelFormat.writeMaterial(source, to: url)
        XCTAssertTrue(try Data(contentsOf: url).starts(with: [0x50, 0x4b]))
        let restored = try NativeModelFormat.readMaterial(url: url)
        try restored.validate()
        XCTAssertEqual(restored.name, source.name)
        XCTAssertEqual(restored.textureScale, 0.375, accuracy: 1e-7)
        let imageData = try XCTUnwrap(restored.textureData)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        // Compare decoded RGBA bytes; PNG encoding details may change in the SDK.
        func rgba(_ image: CGImage) throws -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 16)
            try data.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            return data
        }
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(source.textureData) as CFData, nil))
        XCTAssertEqual(try rgba(image), try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(originalSource, 0, nil))))
    }
    func testSKMRejectsFaceAssignmentsAndTextureRotation() throws {
        guard NativeModelFormat.isAvailable else { throw XCTSkip("Installed native SketchUp SDK/helper unavailable") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".skm")
        defer { try? FileManager.default.removeItem(at: url) }
        let rotated = SurfaceMaterial(name: "Rotated", colorHex: "#FFFFFF", textureData: try stripedPNG(), textureRotation: 0.3)
        XCTAssertThrowsError(try NativeModelFormat.writeMaterial(rotated, to: url))
        let assigned = SurfaceMaterial(name: "Assigned", faceOverrides: [FaceSurface(triangleIndices: [0], colorHex: "#FF0000")])
        XCTAssertThrowsError(try NativeModelFormat.writeMaterial(assigned, to: url))
    }
}
