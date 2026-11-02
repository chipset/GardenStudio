import XCTest
@testable import GardenStudioUI
final class MaterialEditorPrecisionTests:XCTestCase {
    func testReadingAnUnchangedRepeatSizeDoesNotRoundItsPhysicalScale() throws {
        for scale in [0.123456789012345,0.000123456789012345,12345.6789012345] {
            let text=MaterialsPanelController.numberForEditing(scale)
            XCTAssertEqual(try XCTUnwrap(Double(text)),scale)
        }
    }
    func testReadingUnchangedTextureDegreesPreservesRotation() throws {
        let radians=0.123456789012345
        let text=MaterialsPanelController.numberForEditing(radians*180 / .pi)
        let readBack=try XCTUnwrap(Double(text)) * .pi / 180
        XCTAssertEqual(readBack,radians,accuracy:1e-15)
    }
}
