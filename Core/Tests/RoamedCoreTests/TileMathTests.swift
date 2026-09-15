import XCTest
@testable import RoamedCore

final class TileMathTests: XCTestCase {

    func testZoomZeroIsOneTileCoveringTheWorld() {
        XCTAssertEqual(TileMath.gridSize(0), 1)
        XCTAssertEqual(TileMath.cellX(-179.9, 0), 0)
        XCTAssertEqual(TileMath.cellX(179.9, 0), 0)
        XCTAssertEqual(TileMath.cellY(0.0, 0), 0)
    }

    func testNullIslandSitsAtTheCentreOfTheGrid() {
        let z = 10
        XCTAssertEqual(TileMath.cellX(0.0, z), TileMath.gridSize(z) / 2)
        XCTAssertEqual(TileMath.cellY(0.0, z), TileMath.gridSize(z) / 2)
    }

    func testLatLonRoundTripsThroughTileCoordinates() {
        let samples: [(Double, Double)] = [
            (0.0, 0.0),
            (51.5074, -0.1278),    // London
            (-33.8688, 151.2093),  // Sydney
            (64.1466, -21.9426),   // Reykjavik
            (-54.8019, -68.3030),  // Ushuaia
        ]
        for (lat, lon) in samples {
            let x = TileMath.lonToTileX(lon, RevealZoom.z)
            let y = TileMath.latToTileY(lat, RevealZoom.z)
            XCTAssertEqual(TileMath.tileXToLon(x, RevealZoom.z), lon, accuracy: 1e-9, "lon \(lon)")
            XCTAssertEqual(TileMath.tileYToLat(y, RevealZoom.z), lat, accuracy: 1e-9, "lat \(lat)")
        }
    }

    func testLongitudeNormalisationWrapsAroundTheAntimeridian() {
        XCTAssertEqual(TileMath.normalizeLongitude(181.0), -179.0, accuracy: 1e-9)
        XCTAssertEqual(TileMath.normalizeLongitude(-181.0), 179.0, accuracy: 1e-9)
        XCTAssertEqual(TileMath.normalizeLongitude(360.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(TileMath.normalizeLongitude(180.0), -180.0, accuracy: 1e-9)
    }

    func testLatitudeIsClampedToTheMercatorLimit() {
        XCTAssertEqual(TileMath.clampLatitude(89.0), TileMath.maxLatitude, accuracy: 1e-9)
        XCTAssertEqual(TileMath.clampLatitude(-90.0), -TileMath.maxLatitude, accuracy: 1e-9)
        let z = 8
        XCTAssertTrue((0..<TileMath.gridSize(z)).contains(TileMath.cellY(90.0, z)))
        XCTAssertTrue((0..<TileMath.gridSize(z)).contains(TileMath.cellY(-90.0, z)))
    }

    func testCellsAreWiderAtTheEquatorThanNearThePoles() {
        let z = RevealZoom.z
        let equator = TileMath.cellWidthMeters(TileMath.cellY(0.0, z), z)
        let high = TileMath.cellWidthMeters(TileMath.cellY(70.0, z), z)
        XCTAssertEqual(equator, 305.7, accuracy: 1.0, "z17 cell at the equator should be about 306 m across")
        XCTAssertLessThan(high, equator / 2, "a cell at 70N should be less than half as wide")
    }

    func testSummedCellAreasReconstructTheMercatorVisibleSphere() {
        // Every cell in the grid, added up, must equal the spherical zone between +-85.05 degrees.
        let z = 6
        let grid = TileMath.gridSize(z)
        var total = 0.0
        for y in 0..<grid { total += TileMath.areaOfRow(y, z) * Double(grid) }

        let maxLatRad = TileMath.degToRad(TileMath.maxLatitude)
        let expected = 4.0 * Double.pi * TileMath.earthRadiusMeters * TileMath.earthRadiusMeters
            * sin(maxLatRad)
        XCTAssertLessThan(
            abs(total - expected) / expected, 1e-9,
            "summed area \(total) should match the zone area \(expected)"
        )
        // Sanity against the published figure for the whole planet.
        XCTAssertLessThan(total, TileMath.earthSurfaceAreaM2)
        XCTAssertGreaterThan(total, TileMath.earthSurfaceAreaM2 * 0.99)
    }

    func testCellAreaIsIndependentOfTheColumn() {
        let z = RevealZoom.z
        let area = TileMath.areaOfRow(TileMath.cellY(48.85, z), z)
        XCTAssertGreaterThan(area, 0.0)
        // Mercator cells are square on the ground: ~201 m a side in Paris, so ~0.0405 km2.
        XCTAssertEqual(area / 1_000_000.0, 0.0405, accuracy: 0.001)
    }

    func testColumnWrappingIsStableInBothDirections() {
        let z = 4
        let n = TileMath.gridSize(z)
        XCTAssertEqual(TileMath.wrapX(0, z), 0)
        XCTAssertEqual(TileMath.wrapX(n, z), 0)
        XCTAssertEqual(TileMath.wrapX(-1, z), n - 1)
        XCTAssertEqual(TileMath.wrapX(n + 1, z), 1)
    }
}
