import XCTest
import GardenStudioCore
@testable import GardenStudioIO

final class AppearanceAudit4Tests:XCTestCase {
    private func temporary(_ ext:String)->URL {FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"."+ext)}
    func testUSDRejectsUnrepresentableScalarOpacity()throws {
        guard AppleAssetFormat.supportedImportExtensions.contains("usda") else {throw XCTSkip("Native USD codec unavailable")}
        let file=temporary("usda");defer{try? FileManager.default.removeItem(at:file)}
        for opacity in [0.25,1.0] {
            let source="""
            #usda 1.0
            (metersPerUnit=1
            upAxis="Y")
            def Material "Paint" {
                token outputs:surface.connect = </Paint/Shader.outputs:surface>
                def Shader "Shader" {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (1,0,0)
                    float inputs:opacity = \(opacity)
                    token outputs:surface
                }
            }
            def Mesh "Triangle" {
                point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0,1,2]
                uniform token subdivisionScheme = "none"
                rel material:binding = </Paint>
            }
            """
            try source.write(to:file,atomically:true,encoding:.utf8)
            if opacity<1 {XCTAssertThrowsError(try AppleAssetFormat.read(url:file))}
            else {XCTAssertEqual(try AppleAssetFormat.read(url:file).entities.count,1)}
        }
    }
    func testPLYRejectsNonopaqueAlphaButAcceptsOpaqueAlpha()throws {
        let file=temporary("ply");defer{try? FileManager.default.removeItem(at:file)}
        for alpha in [128,255] {
            let source="""
            ply
            format ascii 1.0
            element vertex 3
            property float x
            property float y
            property float z
            property uchar red
            property uchar green
            property uchar blue
            property uchar alpha
            element face 1
            property list uchar int vertex_indices
            end_header
            0 0 0 255 0 0 \(alpha)
            1 0 0 255 0 0 \(alpha)
            0 1 0 255 0 0 \(alpha)
            3 0 1 2
            """+"\n"
            try source.write(to:file,atomically:true,encoding:.utf8)
            if alpha<255 {XCTAssertThrowsError(try PLYFormat.read(url:file))}
            else {XCTAssertEqual(try PLYFormat.read(url:file).entities.count,1)}
        }
    }
    func testNativeUSDConversionChecksFinalOutputSizeEvenForFastExit()throws {
        guard FileManager.default.isExecutableFile(atPath:"/usr/bin/usdcat") else {throw XCTSkip("Native converter unavailable")}
        let file=temporary("usda"),output=temporary("usda")
        defer{try? FileManager.default.removeItem(at:file);try? FileManager.default.removeItem(at:output)}
        try "#usda 1.0\ndef Xform \"Root\" {}\n".write(to:file,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try AppleAssetFormat.convertUSD(file,to:output,maximumOutputBytes:1))
    }

    func testUSDDisplayOpacityRejectsTransparencyAndAcceptsOpaqueValues()throws {
        guard AppleAssetFormat.supportedImportExtensions.contains("usda") else {throw XCTSkip("Native USD codec unavailable")}
        let file=temporary("usda");defer{try? FileManager.default.removeItem(at:file)}
        for opacity in [0.5,1.0] {
            let source="""
            #usda 1.0
            (metersPerUnit=1)
            def Mesh "Triangle" {
                point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0,1,2]
                uniform token subdivisionScheme = "none"
                float[] primvars:displayOpacity = [\(opacity)] (interpolation="constant")
            }
            """
            try source.write(to:file,atomically:true,encoding:.utf8)
            if opacity<1 {XCTAssertThrowsError(try AppleAssetFormat.read(url:file))}
            else {XCTAssertEqual(try AppleAssetFormat.read(url:file).entities.count,1)}
        }
    }
    func testPLYFloatAndFaceAlphaUseTheirDeclaredOpaqueRange()throws {
        let file=temporary("ply");defer{try? FileManager.default.removeItem(at:file)}
        for (type,alpha,opaque) in [("float",0.5,false),("float",1.0,true),("ushort",32768.0,false),("ushort",65535.0,true)] {
            let source="""
            ply
            format ascii 1.0
            element vertex 3
            property float x
            property float y
            property float z
            element face 1
            property list uchar int vertex_indices
            property \(type) alpha
            end_header
            0 0 0
            1 0 0
            0 1 0
            3 0 1 2 \(alpha)
            """+"\n"
            try source.write(to:file,atomically:true,encoding:.utf8)
            if opaque {XCTAssertEqual(try PLYFormat.read(url:file).entities.count,1)}
            else {XCTAssertThrowsError(try PLYFormat.read(url:file))}
        }
    }

}
