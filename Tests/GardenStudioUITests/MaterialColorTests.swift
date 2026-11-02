import XCTest
import AppKit
@testable import GardenStudioUI
final class MaterialColorTests:XCTestCase {
    func testEditingMaterialPreservesSRGBHexColors() {
        for value in ["#E7DCC8","#AA3300","#7FABB5","#010203","#FFFFFF"] {
            XCTAssertEqual(MaterialManager.hex(MaterialManager.color(value)),value)
        }
    }
}
