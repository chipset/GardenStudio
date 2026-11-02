import XCTest
import AppKit
@testable import SketchUI
final class MaterialColorTests:XCTestCase {
    func testEditingMaterialPreservesSRGBHexColors() {
        for value in ["#E7DCC8","#AA3300","#7FABB5","#010203","#FFFFFF"] {
            XCTAssertEqual(MaterialManager.hex(MaterialManager.color(value)),value)
        }
    }
}
