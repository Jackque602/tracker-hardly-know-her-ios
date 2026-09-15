import XCTest
@testable import RoamedCore

final class FogEngineTests: XCTestCase {

    private let engine = FogEngine()

    func testAFixAlwaysUncoversTheCellItStandsIn() {
        let lat = 51.5074
        let lon = -0.1278
        let cells = engine.cellsWithinRadius(lat, lon, 1.0)
        let expected = CellKey.pack(TileMath.cellX(lon, RevealZoom.z), TileMath.cellY(lat, RevealZoom.z))
        XCTAssertTrue(cells.contains(expected), "the containing cell must be uncovered")
    }

    func testALargerRadiusNeverUncoversFewerCells() {
        var previous = 0
        for radius in [10.0, 100.0, 250.0, 600.0, 1500.0] {
            let count = engine.cellsWithinRadius(48.8566, 2.3522, radius).count
            XCTAssertGreaterThanOrEqual(count, previous, "radius \(radius) uncovered \(count), was \(previous)")
            previous = count
        }
        XCTAssertGreaterThan(previous, 20, "a 1.5 km radius should cover a good handful of cells")
    }

    func testUncoveredCellsAllLieWithinTheRadiusPlusOneCellDiagonal() {
        let lat = 40.7128
        let lon = -74.0060
        let radius = 400.0
        let cells = engine.cellsWithinRadius(lat, lon, radius)
        let z = RevealZoom.z
        for key in cells {
            let centreLat = (TileMath.tileYToLat(Double(CellKey.y(key)), z)
                + TileMath.tileYToLat(Double(CellKey.y(key) + 1), z)) / 2.0
            let centreLon = (TileMath.tileXToLon(Double(CellKey.x(key)), z)
                + TileMath.tileXToLon(Double(CellKey.x(key) + 1), z)) / 2.0
            let d = Geo.distanceMeters(lat, lon, centreLat, centreLon)
            let diagonal = TileMath.cellWidthMeters(CellKey.y(key), z) * 1.5
            XCTAssertLessThanOrEqual(d, radius + diagonal, "cell centre \(d) m away exceeds \(radius) + \(diagonal)")
        }
    }

    func testAStraightDriveLeavesNoGapsInTheTrail() {
        // ~2.2 km due east along the equator, with a reveal radius smaller than a cell.
        let cells = engine.cellsAlongSegment(0.0, 0.0, 0.0, 0.02, radiusMeters: 60.0)
        let z = RevealZoom.z
        let columns = Set(cells.map { CellKey.x($0) })
        for x in TileMath.cellX(0.0, z)...TileMath.cellX(0.02, z) {
            XCTAssertTrue(columns.contains(x), "column \(x) is missing from the trail")
        }
    }

    func testAMotorwayDropoutIsBridgedRatherThanLeftAsAHole() {
        // Ten km between fixes is what a tunnel or a stretch of dead zone leaves behind. The old
        // three-kilometre limit refused to fill this in, so a lapse of signal became a permanent
        // hole in the map.
        let cells = engine.cellsAlongSegment(40.20, -76.80, 40.20, -76.68, radiusMeters: 120.0)
        let z = RevealZoom.z
        let columns = Set(cells.map { CellKey.x($0) })
        for x in TileMath.cellX(-76.80, z)...TileMath.cellX(-76.68, z) {
            XCTAssertTrue(columns.contains(x), "column \(x) is missing from the bridged gap")
        }
    }

    func testAnImplausibleGapIsNotPaintedIn() {
        // London to New York in one step: nothing between them should be uncovered.
        let cells = engine.cellsAlongSegment(51.5074, -0.1278, 40.7128, -74.0060, radiusMeters: 100.0)
        XCTAssertTrue(cells.isEmpty, "a transatlantic jump must not draw a line")
    }

    func testBothEndpointsAreUncoveredForAShortSegment() {
        let cells = engine.cellsAlongSegment(51.5, -0.1, 51.5005, -0.1, radiusMeters: 50.0)
        let z = RevealZoom.z
        XCTAssertTrue(cells.contains(CellKey.pack(TileMath.cellX(-0.1, z), TileMath.cellY(51.5, z))))
        XCTAssertTrue(cells.contains(CellKey.pack(TileMath.cellX(-0.1, z), TileMath.cellY(51.5005, z))))
    }

    func testAFixOnTheAntimeridianUncoversCellsOnBothSides() {
        let cells = engine.cellsWithinRadius(0.0, 179.999, 800.0)
        let z = RevealZoom.z
        let maxX = TileMath.gridSize(z) - 1
        let columns = Set(cells.map { CellKey.x($0) })
        XCTAssertTrue(columns.contains { $0 > maxX - 10 }, "expected cells just west of the antimeridian")
        XCTAssertTrue(columns.contains { $0 < 10 }, "expected cells wrapped to the eastern edge")
        XCTAssertTrue(columns.allSatisfy { $0 >= 0 && $0 <= maxX }, "every column must stay inside the grid")
    }

    func testAFixNearThePoleStaysBounded() {
        let cells = engine.cellsWithinRadius(84.9, 10.0, 500.0)
        XCTAssertFalse(cells.isEmpty)
        XCTAssertLessThan(cells.count, 20_000, "polar reveals must not explode, got \(cells.count)")
    }

    func testAccumulatingIntoASharedSetDeduplicates() {
        var shared = Set<CellKeyValue>()
        engine.cellsWithinRadius(51.5, -0.1, 200.0, into: &shared)
        let afterFirst = shared.count
        engine.cellsWithinRadius(51.5, -0.1, 200.0, into: &shared)
        XCTAssertEqual(shared.count, afterFirst)
    }

    func testGlitchDetectionIgnoresPlausibleTravel() {
        XCTAssertFalse(isImplausibleJump(30_000.0, 600.0))    // 180 km/h
        XCTAssertFalse(isImplausibleJump(900_000.0, 3_600.0)) // a plausible flight leg
        XCTAssertTrue(isImplausibleJump(500_000.0, 60.0))     // 30,000 km/h
        XCTAssertFalse(isImplausibleJump(50.0, 0.01))         // tiny hops are noise, not jumps
    }

    func testOneLegMeansNearEnoughAndSoonEnough() {
        XCTAssertTrue(isOneLeg(1_500.0, 30.0), "a normal step between two fixes")
        XCTAssertTrue(isOneLeg(20_000.0, 590.0), "a long motorway stretch through a dead zone")

        XCTAssertFalse(isOneLeg(30_000.0, 60.0), "further than the engine will ever bridge")
        // The case that leaves a hole in a drive: only eleven km apart, but the tracker was silent
        // for half an hour, and half an hour is long enough to have gone somewhere else and back.
        XCTAssertFalse(isOneLeg(11_000.0, 1_800.0), "close by, but far too long ago")
    }

    func testTheFogAndTheTrailBreakAtExactlyTheSamePlaces() {
        // The trail overlay draws a line only where this says the ground may be uncovered. If the
        // two ever disagreed, the map would draw a route across ground it had left fogged.
        for (metres, seconds) in [(1_000.0, 30.0), (11_000.0, 1_800.0), (30_000.0, 60.0), (24_000.0, 599.0)] {
            let bridged = !engine.cellsAlongSegment(
                39.9626, -76.7277,
                39.9626 + metres / 111_320.0, -76.7277,
                radiusMeters: 120.0
            ).isEmpty
            if isOneLeg(metres, seconds) {
                XCTAssertTrue(bridged, "the trail would draw \(metres)m but the fog would not fill it")
            }
        }
    }
}
