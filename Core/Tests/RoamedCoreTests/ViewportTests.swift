import XCTest
@testable import RoamedCore

final class ViewportTests: XCTestCase {

    private func view(
        lat: Double = 40.1295,
        lon: Double = -77.0155,
        zoom: Int = 12,
        width: Double = 800.0,
        height: Double = 480.0
    ) -> Viewport {
        Viewport(centerLatitude: lat, centerLongitude: lon, zoom: zoom, widthPx: width, heightPx: height)
    }

    func testTheCentreOfTheViewIsTheMiddleOfTheCanvas() {
        let v = view()
        XCTAssertEqual(v.xOf(v.centerLongitude), 400.0, accuracy: 1e-6)
        XCTAssertEqual(v.yOf(v.centerLatitude), 240.0, accuracy: 1e-6)
    }

    func testNorthIsUpAndEastIsRight() {
        let v = view()
        XCTAssertLessThan(v.yOf(v.centerLatitude + 0.1), 240.0, "further north should sit higher")
        XCTAssertGreaterThan(v.xOf(v.centerLongitude + 0.1), 400.0, "further east should sit right")
    }

    func testAPointOneTileEastLandsOneTileWidthRight() {
        let v = view()
        let oneTileEast = TileMath.tileXToLon(TileMath.lonToTileX(v.centerLongitude, 12) + 1.0, 12)
        XCTAssertEqual(v.xOf(oneTileEast), 400.0 + v.tileSizePx, accuracy: 1e-6)
    }

    func testTheTileRangeCoversTheCanvasAndNoMore() {
        let v = view(width: 800.0, height: 480.0)
        let tiles = v.tileRange()
        // 800 px of 256 px tiles is 3.125 tiles wide, so four columns at most.
        XCTAssertTrue((4...5).contains(tiles.columns), "got \(tiles.columns) columns")
        XCTAssertTrue((2...4).contains(tiles.rows), "got \(tiles.rows) rows")

        // Every tile in the range must actually touch the canvas.
        for x in tiles.xFrom...tiles.xTo {
            let left = v.tileLeft(x)
            XCTAssertTrue(left < v.widthPx && left + v.tileSizePx > 0.0, "column \(x) is off-screen")
        }
        // And the range has to reach the edges: the first column must start at or before zero.
        XCTAssertLessThanOrEqual(v.tileLeft(tiles.xFrom), 0.0)
        XCTAssertGreaterThanOrEqual(v.tileLeft(tiles.xTo) + v.tileSizePx, v.widthPx)
    }

    func testCellsShrinkByHalfForEveryLevelFinerThanTheMap() {
        let v = view(zoom: 12)
        XCTAssertEqual(v.cellSizePx(12), 256.0, accuracy: 1e-9)
        XCTAssertEqual(v.cellSizePx(13), 128.0, accuracy: 1e-9)
        XCTAssertEqual(v.cellSizePx(19), 2.0, accuracy: 1e-9)
        // A z17 fog cell on a z12 map is a thirty-second of a tile.
        XCTAssertEqual(v.cellSizePx(17), 8.0, accuracy: 1e-9)
    }

    func testAFogCellLandsWhereItsOwnCornerSaysItShould() {
        let v = view(zoom: 14)
        let z = RevealZoom.z
        let cellX = TileMath.cellX(v.centerLongitude, z)
        let cellY = TileMath.cellY(v.centerLatitude, z)

        // The cell's west edge as a longitude, put through the point projection, must agree with
        // the cell placement used to draw the rectangles.
        let west = TileMath.tileXToLon(Double(cellX), z)
        let north = TileMath.tileYToLat(Double(cellY), z)
        XCTAssertEqual(v.cellLeft(cellX, z), v.xOf(west), accuracy: 1e-6)
        XCTAssertEqual(v.cellTop(cellY, z), v.yOf(north), accuracy: 1e-6)
    }

    func testTheCellRangeCoversEveryCellTouchingTheCanvas() {
        let v = view(zoom: 14)
        let z = RevealZoom.z
        let range = v.cellRange(z)
        let size = v.cellSizePx(z)
        for x in range.xFrom...range.xTo {
            let left = v.cellLeft(x, z)
            XCTAssertTrue(left < v.widthPx && left + size > 0.0, "cell column \(x) is off-screen")
        }
        XCTAssertLessThanOrEqual(v.cellLeft(range.xFrom, z), 0.0, "the range must reach the left edge")
        XCTAssertLessThanOrEqual(v.cellTop(range.yFrom, z), 0.0, "and the top edge")
    }

    func testPanningMovesTheGroundUnderYourFinger() {
        let v = view()
        // Dragging the map 256 px to the right brings ground one tile to the west into the middle.
        let panned = v.panBy(dxPx: 256.0, dyPx: 0.0)
        XCTAssertGreaterThan(panned.centerLongitude, v.centerLongitude, "panning east moves the centre east")
        XCTAssertEqual(
            panned.xOf(v.centerLongitude),
            v.xOf(v.centerLongitude) - 256.0,
            accuracy: 1e-3,
            "the old centre should now sit 256 px to the left"
        )
    }

    func testPanningCannotFallOffTheTopOrBottomOfTheWorld() {
        let v = view(lat: 84.0, zoom: 4)
        let up = v.panBy(dxPx: 0.0, dyPx: -100_000.0)
        XCTAssertLessThanOrEqual(up.centerLatitude, TileMath.maxLatitude + 1e-9)
        XCTAssertTrue(up.centerLatitude.isFinite)

        let down = view(lat: -84.0, zoom: 4).panBy(dxPx: 0.0, dyPx: 100_000.0)
        XCTAssertGreaterThanOrEqual(down.centerLatitude, -TileMath.maxLatitude - 1e-9)
        XCTAssertTrue(down.centerLatitude.isFinite)
    }

    func testAPointAcrossTheAntimeridianStaysNextDoor() {
        // Centred just west of the date line, with a point just east of it. Taken literally the
        // two are a whole world apart in tile coordinates; on screen they are neighbours.
        let v = Viewport(centerLatitude: 0.0, centerLongitude: 179.9, zoom: 8, widthPx: 800.0, heightPx: 480.0)
        let justOver = v.xOf(-179.9)
        XCTAssertLessThan(abs(justOver - 400.0), 200.0, "should be near the middle, was \(justOver)")
    }

    func testAWrappedCellColumnIsDrawnNextDoorNotAWorldAway() {
        // The explored index wraps columns into the grid, so a cell just east of the date line
        // comes back as column zero-something. Drawn literally it would be off the far side.
        let zoom = 8
        let v = Viewport(centerLatitude: 0.0, centerLongitude: 179.9, zoom: zoom, widthPx: 800.0, heightPx: 480.0)
        let grid = TileMath.gridSize(zoom)

        let westEdge = v.cellLeft(grid - 1, zoom)
        let eastEdge = v.cellLeft(0, zoom)
        XCTAssertEqual(
            eastEdge - westEdge,
            v.tileSizePx,
            accuracy: 1e-6,
            "the two columns either side of the date line must be adjacent on screen"
        )
        XCTAssertLessThan(abs(eastEdge - 400.0), 400.0, "and both near the middle, was \(eastEdge)")
    }
}
