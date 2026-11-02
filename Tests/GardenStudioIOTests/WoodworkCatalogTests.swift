import XCTest
import GardenStudioCore
@testable import GardenStudioIO
final class WoodworkCatalogTests:XCTestCase {
    func testCatalogExchangesSeparatePartsWithSelectionScope() throws {
        guard WoodworkFormat.isAvailable else {throw XCTSkip("Woodwork helper unavailable")}
        let first=GardenEntity(name:"Shelf",kind:.rectangle,origin:Vec3(0,0,0),width:1,depth:0.5,height:0.02)
        let second=GardenEntity(name:"Leg",kind:.rectangle,origin:Vec3(2,0,0),width:0.04,depth:0.04,height:0.7)
        let document=ModelDocument(entities:[first,second],name:"Separate items")
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".woodwork")
        defer{try? FileManager.default.removeItem(at:url)}
        XCTAssertTrue(ExchangeCatalog.importExtensions.contains("woodwork"))
        try ExchangeCatalog.write(document,to:url,formatID:"woodwork",options:ExchangeExportOptions(scope:.selection,selectedIDs:[second.id]))
        let imported=try ExchangeCatalog.read(url:url)
        XCTAssertEqual(imported.entities.count,1)
        XCTAssertEqual(imported.entities[0].name,"Leg")
        XCTAssertEqual(imported.entities[0].id,second.id)
        XCTAssertNil(imported.entities[0].metadata?.groupID)
    }
}
