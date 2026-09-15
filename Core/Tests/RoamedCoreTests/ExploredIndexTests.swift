import XCTest
@testable import RoamedCore

final class ExploredIndexTests: XCTestCase {

    func testAddingTheSameCellTwiceOnlyCountsOnce() {
        let index = ExploredIndex()
        let key = CellKey.pack(100, 200)
        XCTAssertTrue(index.add(key))
        XCTAssertFalse(index.add(key))
        XCTAssertEqual(index.size, 1)
    }

    func testAddAllReportsOnlyTheGenuinelyNewCells() {
        let index = ExploredIndex()
        index.add(CellKey.pack(1, 1))
        let fresh = index.addAll([CellKey.pack(1, 1), CellKey.pack(2, 2), CellKey.pack(3, 3)])
        XCTAssertEqual(fresh.count, 2)
        XCTAssertEqual(index.size, 3)
    }

    func testAreaAccumulatesAsCellsAreAddedAndResetsOnClear() {
        let index = ExploredIndex()
        XCTAssertEqual(index.areaSquareMeters, 0.0, accuracy: 1e-9)
        let row = TileMath.cellY(51.5, RevealZoom.z)
        index.add(CellKey.pack(10, row))
        let one = index.areaSquareMeters
        XCTAssertGreaterThan(one, 0.0)
        index.add(CellKey.pack(11, row))
        XCTAssertEqual(index.areaSquareMeters, one * 2, accuracy: one * 1e-9)
        index.clear()
        XCTAssertEqual(index.areaSquareMeters, 0.0, accuracy: 1e-9)
        XCTAssertEqual(index.size, 0)
    }

    func testVersionChangesOnlyWhenSomethingIsActuallyAdded() {
        let index = ExploredIndex()
        let start = index.version
        index.add(CellKey.pack(5, 5))
        let afterAdd = index.version
        XCTAssertGreaterThan(afterAdd, start)
        index.add(CellKey.pack(5, 5))
        XCTAssertEqual(index.version, afterAdd)
    }

    func testADetailedQueryReturnsExactlyTheCellsInsideTheWindow() {
        let index = ExploredIndex()
        let inside = CellKey.pack(70_000, 45_000)
        let outside = CellKey.pack(70_500, 45_000)
        index.addAll([inside, outside])
        let found = index.cellsIn(RevealZoom.z, 69_990, 70_010, 44_990, 45_010)
        XCTAssertEqual(found, [inside])
    }

    func testACoarseQueryCollapsesNeighboursIntoASingleCell() {
        let index = ExploredIndex()
        index.addAll((0..<64).map { CellKey.pack(70_000 + $0, 45_000) })
        let renderZoom = 8
        let shift = RevealZoom.z - renderZoom
        let grid = TileMath.gridSize(renderZoom)
        let found = index.cellsIn(renderZoom, 0, grid - 1, 0, grid - 1)
        let expected = Set((0..<64).map { CellKey.pack((70_000 + $0) >> shift, 45_000 >> shift) })
        XCTAssertEqual(Set(found), expected)
        XCTAssertLessThan(found.count, 64, "64 adjacent z17 cells should collapse at z8")
    }

    func testCoarseQueriesStayCorrectWhenCellsAreAddedAfterTheCacheIsBuilt() {
        let index = ExploredIndex()
        index.add(CellKey.pack(1000, 1000))
        let renderZoom = 6
        let grid = TileMath.gridSize(renderZoom)
        _ = index.cellsIn(renderZoom, 0, grid - 1, 0, grid - 1) // primes the cache
        index.add(CellKey.pack(120_000, 90_000))
        let found = index.cellsIn(renderZoom, 0, grid - 1, 0, grid - 1)
        XCTAssertEqual(found.count, 2, "a cell added after the cache was built must still show up")
    }

    func testAWindowStraddlingTheAntimeridianFindsCellsOnBothSides() {
        let index = ExploredIndex()
        let z = RevealZoom.z
        let maxX = TileMath.gridSize(z) - 1
        let west = CellKey.pack(maxX, 1000)
        let east = CellKey.pack(0, 1000)
        index.addAll([west, east])
        let found = Set(index.cellsIn(z, maxX - 5, maxX + 5, 990, 1010))
        XCTAssertTrue(found.contains(west), "cell at the eastern grid edge should be found")
        XCTAssertTrue(found.contains(east), "wrapped cell should be found")
    }

    func testAnEmptyWindowReturnsNothing() {
        let index = ExploredIndex()
        index.add(CellKey.pack(70_000, 45_000))
        XCTAssertEqual(index.cellsIn(RevealZoom.z, 10, 20, 10, 20).count, 0)
        XCTAssertEqual(ExploredIndex().cellsIn(RevealZoom.z, 0, 100, 0, 100).count, 0)
    }

    func testRowsOutsideTheGridAreIgnoredRatherThanCrashing() {
        let index = ExploredIndex()
        index.add(CellKey.pack(70_000, 45_000))
        let grid = TileMath.gridSize(RevealZoom.z)
        XCTAssertEqual(index.cellsIn(RevealZoom.z, 0, grid - 1, -500, -1).count, 0)
    }

    func testAWholeWorldQueryReturnsEveryCell() {
        let index = ExploredIndex()
        index.addAll([
            CellKey.pack(0, 0),
            CellKey.pack(70_000, 45_000),
            CellKey.pack(131_071, 131_071),
        ])
        let grid = TileMath.gridSize(4)
        XCTAssertEqual(index.cellsIn(4, 0, grid - 1, 0, grid - 1).count, 3)
    }
}
