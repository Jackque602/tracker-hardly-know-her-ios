import XCTest
@testable import RoamedCore

final class CellKeyTests: XCTestCase {

    func testPackingRoundTripsAcrossTheWholeGrid() {
        let maxIndex = (1 << RevealZoom.z) - 1
        let samples = [(0, 0), (1, 2), (maxIndex, maxIndex), (maxIndex, 0), (0, maxIndex), (65_535, 65_536)]
        for (x, y) in samples {
            let key = CellKey.pack(x, y)
            XCTAssertEqual(CellKey.x(key), x, "x for (\(x),\(y))")
            XCTAssertEqual(CellKey.y(key), y, "y for (\(x),\(y))")
        }
    }

    func testXAndYAreNotInterchangeable() {
        XCTAssertNotEqual(CellKey.pack(3, 7), CellKey.pack(7, 3))
    }

    func testReKeyingToACoarserZoomHalvesCoordinatesPerLevel() {
        let key = CellKey.pack(70_000, 45_000)
        let coarse = CellKey.toZoom(key, 17, 15)
        XCTAssertEqual(CellKey.x(coarse), 70_000 >> 2)
        XCTAssertEqual(CellKey.y(coarse), 45_000 >> 2)
    }

    func testReKeyingToTheSameZoomIsIdentity() {
        let key = CellKey.pack(12, 34)
        XCTAssertEqual(CellKey.toZoom(key, 17, 17), key)
    }

    func testNeighbouringCellsCollapseTogetherWhenZoomedOutFarEnough() {
        let a = CellKey.toZoom(CellKey.pack(1000, 2000), 17, 5)
        let b = CellKey.toZoom(CellKey.pack(1001, 2001), 17, 5)
        XCTAssertEqual(a, b)
    }
}
