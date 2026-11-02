import XCTest
@testable import SketchUI
final class ExchangeImportFilterTests:XCTestCase {
    func testCodecExtensionsRemainSelectableWithoutRegisteredUTIs() {
        let filter=ExchangeImportFilter(extensions:["skp","obj","3mf"])
        XCTAssertTrue(filter.panel(self,shouldEnable:URL(fileURLWithPath:"/tmp/model.SKP")))
        XCTAssertTrue(filter.panel(self,shouldEnable:URL(fileURLWithPath:"/tmp/model.3mf")))
        XCTAssertTrue(filter.panel(self,shouldEnable:URL(fileURLWithPath:"/tmp/folder",isDirectory:true)))
        XCTAssertFalse(filter.panel(self,shouldEnable:URL(fileURLWithPath:"/tmp/model.crv")))
    }
}
