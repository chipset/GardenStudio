import XCTest
@testable import GardenStudioCore

final class SurfaceMaterialTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    func testMaterialRoundTripRetainsEmbeddedTextureAndOverrides() throws {
        let face = FaceSurface(triangleIndices: [0,1], colorHex: "#112233", textureData: png, textureScale: 2, textureRotation: .pi/4)
        let material = SurfaceMaterial(name: "Oak", colorHex: "#A27650", textureData: png, textureScale: 0.5, textureRotation: .pi/2, faceOverrides: [face])
        try material.validate(triangleCount: 12)
        XCTAssertEqual(try JSONDecoder().decode(SurfaceMaterial.self, from: JSONEncoder().encode(material)), material)
    }
    func testMinimalOlderMaterialGetsDefaultTransformAndNoOverrides() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Old\",\"colorHex\":\"#123456\"}".utf8)
        let material = try JSONDecoder().decode(SurfaceMaterial.self, from: data)
        XCTAssertEqual(material.textureScale, 1)
        XCTAssertEqual(material.textureRotation, 0)
        XCTAssertEqual(material.faceOverrides, [])
        XCTAssertNil(material.textureData)
    }
    func testValidationRejectsInvalidTextureTransformColorAndPayload() {
        for material in [SurfaceMaterial(colorHex: "red"), SurfaceMaterial(textureScale: 0), SurfaceMaterial(textureScale: .infinity), SurfaceMaterial(textureRotation: .nan), SurfaceMaterial(textureData: Data([0,1,2])), SurfaceMaterial(textureData: Data(repeating: 0, count: 10*1024*1024+1))] {
            XCTAssertThrowsError(try material.validate())
        }
    }
    func testFaceOverridesRejectOverlapAndOutOfBoundsIndices() {
        let overlap = SurfaceMaterial(faceOverrides: [FaceSurface(triangleIndices: [0,1],colorHex:"#112233"), FaceSurface(triangleIndices:[1],colorHex:"#445566")])
        XCTAssertThrowsError(try overlap.validate(triangleCount: 4))
        XCTAssertThrowsError(try SurfaceMaterial(faceOverrides:[FaceSurface(triangleIndices:[4],colorHex:"#112233")]).validate(triangleCount:4))
        XCTAssertThrowsError(try SurfaceMaterial(faceOverrides:[FaceSurface(triangleIndices:[-1],colorHex:"#112233")]).validate())
    }
    func testRepaintingFacesSplitsExistingAssignmentWithoutChangingOthers() throws {
        let original = SurfaceMaterial(name:"Base",colorHex:"#FFFFFF",faceOverrides:[FaceSurface(triangleIndices:[0,1,2],colorHex:"#112233")])
        let painted = try original.assigning(SurfaceMaterial(name:"Paint",colorHex:"#AABBCC",textureData:png),toTriangleIndices:[1,3],triangleCount:4)
        XCTAssertEqual(painted.colorHex,"#FFFFFF")
        XCTAssertEqual(painted.faceOverrides[0].triangleIndices,[0,2])
        XCTAssertEqual(painted.faceOverrides[1].triangleIndices,[1,3])
        XCTAssertEqual(painted.faceOverrides[1].colorHex,"#AABBCC")
        XCTAssertEqual(painted.faceOverrides[1].textureData,png)
        try painted.validate(triangleCount:4)
    }
    func testRepaintCannotChangeUnknownFacesOrUseEmptySelection() {
        XCTAssertThrowsError(try SurfaceMaterial().assigning(SurfaceMaterial(),toTriangleIndices:[],triangleCount:4))
        XCTAssertThrowsError(try SurfaceMaterial().assigning(SurfaceMaterial(),toTriangleIndices:[4],triangleCount:4))
    }
}
