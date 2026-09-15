import XCTest
@testable import RoamedCore

final class FlightTests: XCTestCase {

    private let engine = FogEngine()
    private let z = RevealZoom.z

    private func cellAt(_ lat: Double, _ lon: Double) -> CellKeyValue {
        CellKey.pack(TileMath.cellX(lon, z), TileMath.cellY(lat, z))
    }

    func testARealFlightIsRecognised() {
        // London to Los Angeles, eleven hours gate to gate.
        XCTAssertTrue(isFlight(8_750_000.0, 11 * 3_600.0))
        // Philadelphia to Boston, a short hop, still comfortably over the bar.
        XCTAssertTrue(isFlight(430_000.0, 1.2 * 3_600.0))
    }

    func testATrackerThatSleptThroughADriveIsNotAFlight() {
        // The failure this must never mistake for flying: the service is killed, and hours later
        // the app wakes up somewhere else. Uncovering a great circle across that would be a lie.
        XCTAssertFalse(isFlight(200_000.0, 2 * 3_600.0), "200 km in two hours is a drive")
        XCTAssertFalse(isFlight(500_000.0, 6 * 3_600.0), "500 km in six hours is a long drive")
        XCTAssertFalse(isFlight(11_000.0, 1_800.0), "the gap that started all this")
        XCTAssertFalse(isFlight(660_000.0, 3 * 3_600.0), "Paris to Marseille by train, 61 m/s")
    }

    func testAShortHopAndAGlitchAreBothRefused() {
        XCTAssertFalse(isFlight(100_000.0, 600.0), "under the distance floor, whatever the speed")
        XCTAssertFalse(isFlight(5_000_000.0, 60.0), "83 km/s is a broken fix, not a flight")
        XCTAssertFalse(isFlight(1_000_000.0, 0.0), "no elapsed time means no speed to judge")
    }

    func testAFlightPathFollowsTheGreatCircleNotALineDrawnOnTheMap() throws {
        // London to Los Angeles goes over Greenland. Interpolating in flat lat/lon instead would
        // never leave the latitudes of its endpoints, so this is what tells the two apart.
        let cells = engine.cellsAlongFlight(51.5074, -0.1278, 34.0522, -118.2437, radiusMeters: 500.0)
        let northernmost = try XCTUnwrap(cells.map { CellKey.y($0) }.min())
        let peakLatitude = TileMath.tileYToLat(Double(northernmost), z)

        XCTAssertGreaterThan(peakLatitude, 60.0, "the route should arc up over the Arctic")
        XCTAssertLessThan(peakLatitude, 80.0, "and not over the pole itself")
    }

    func testTheFlightRibbonHasNoHolesInIt() {
        let from = (40.6413, -73.7781)  // New York
        let to = (51.4700, -0.4543)     // London
        let cells = engine.cellsAlongFlight(from.0, from.1, to.0, to.1, radiusMeters: 120.0)

        // Walk the same great circle far more finely than the tracer did. Every point along it has
        // to land in a cell the tracer uncovered, or the ribbon is dotted.
        var missing = 0
        for i in 0...5_000 {
            let p = Geo.interpolate(from.0, from.1, to.0, to.1, Double(i) / 5_000.0)
            if !cells.contains(cellAt(p.latitude, p.longitude)) { missing += 1 }
        }
        XCTAssertEqual(missing, 0, "\(missing) of 5001 points along the route were left fogged")
    }

    func testFlyingSomewhereThenWalkingItHandsTheGroundBack() {
        let index = ExploredIndex()
        let air = ExploredIndex()

        let flown = engine.cellsAlongFlight(40.64, -73.78, 40.70, -73.90, radiusMeters: 120.0)
        index.addAll(flown)
        air.addAll(flown)
        let flownArea = air.areaSquareMeters
        XCTAssertGreaterThan(flownArea, 0.0)

        // Land and walk about. Those squares stop being flown-over and become travelled.
        let walked = engine.cellsWithinRadius(40.64, -73.78, 200.0)
        let promoted = air.removeAll(walked)

        XCTAssertFalse(promoted.isEmpty, "landing should reclaim the squares around the airport")
        XCTAssertLessThan(air.areaSquareMeters, flownArea, "the flown area must shrink as it is reclaimed")
        for key in promoted {
            XCTAssertTrue(index.contains(key), "a reclaimed square is still uncovered")
            XCTAssertFalse(air.contains(key), "but no longer counted as flown")
        }
    }

    func testRemovingEverythingLeavesAnEmptyIndexNotANegativeOne() {
        let index = ExploredIndex()
        let cells = engine.cellsWithinRadius(51.5, -0.12, 300.0)
        index.addAll(cells)
        let before = index.version

        XCTAssertEqual(index.removeAll(cells).count, cells.count)
        XCTAssertEqual(index.size, 0)
        XCTAssertEqual(index.areaSquareMeters, 0.0)
        XCTAssertGreaterThan(index.version, before, "a removal is a change the map has to redraw for")
        XCTAssertNil(index.bounds())
        XCTAssertTrue(index.removeAll(cells).isEmpty, "removing twice removes nothing")
    }

    func testRemovalKeepsTheCoarseViewHonest() {
        // The zoomed-out view is memoised, so a removal that forgot to drop it would leave squares
        // on the map that no longer exist.
        let index = ExploredIndex()
        let keep = cellAt(51.5, -0.12)
        let drop = cellAt(48.85, 2.35)
        index.addAll([keep, drop])
        XCTAssertEqual(index.cellsIn(z, 0, TileMath.gridSize(z) - 1, 0, TileMath.gridSize(z) - 1).count, 2)
        let coarseBefore = index.cellsIn(6, 0, TileMath.gridSize(6) - 1, 0, TileMath.gridSize(6) - 1)
        XCTAssertEqual(coarseBefore.count, 2, "London and Paris are separate cells even at z6")

        index.removeAll([drop])
        let coarseAfter = index.cellsIn(6, 0, TileMath.gridSize(6) - 1, 0, TileMath.gridSize(6) - 1)
        XCTAssertEqual(coarseAfter.count, 1, "the coarse view still shows a removed cell")
    }
}
