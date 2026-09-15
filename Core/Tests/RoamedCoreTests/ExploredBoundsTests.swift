import XCTest
@testable import RoamedCore

final class ExploredBoundsTests: XCTestCase {

    private let z = RevealZoom.z
    private var grid: Int { TileMath.gridSize(z) }

    private func indexOf(_ points: (Double, Double)...) -> ExploredIndex {
        let index = ExploredIndex()
        index.addAll(points.map { CellKey.pack(TileMath.cellX($0.1, z), TileMath.cellY($0.0, z)) })
        return index
    }

    func testAnEmptyMapHasNoBoundsToFit() {
        XCTAssertNil(ExploredIndex().bounds())
    }

    func testASingleCellYieldsABoxContainingThatCell() throws {
        let lat = 51.5074
        let lon = -0.1278
        let bounds = try XCTUnwrap(indexOf((lat, lon)).bounds())

        XCTAssertTrue(bounds.north >= lat && bounds.south <= lat, "the point must be inside vertically")
        XCTAssertTrue(bounds.west <= lon && bounds.east >= lon, "the point must be inside horizontally")
        XCTAssertFalse(bounds.crossesAntimeridian)
        // One z17 cell is a few hundred metres, so well under a hundredth of a degree.
        XCTAssertLessThan(bounds.latitudeSpan, 0.01)
        XCTAssertLessThan(bounds.longitudeSpan, 0.01)
    }

    func testABoxOverTwoCitiesContainsBoth() throws {
        let london = (51.5074, -0.1278)
        let paris = (48.8566, 2.3522)
        let bounds = try XCTUnwrap(indexOf(london, paris).bounds())

        XCTAssertFalse(bounds.crossesAntimeridian, "western Europe does not wrap")
        for (lat, lon) in [london, paris] {
            XCTAssertTrue(lat >= bounds.south && lat <= bounds.north, "latitude \(lat) outside the box")
            XCTAssertTrue(lon >= bounds.west && lon <= bounds.east, "longitude \(lon) outside the box")
        }
    }

    func testNorthIsAlwaysAboveSouth() throws {
        let bounds = try XCTUnwrap(indexOf((-33.8688, 151.2093), (64.1466, -21.9426)).bounds())
        XCTAssertGreaterThan(bounds.north, bounds.south)
        XCTAssertGreaterThan(bounds.latitudeSpan, 0)
    }

    func testTravelAcrossThePacificWrapsInsteadOfSpanningTheWholePlanet() throws {
        // Tokyo and San Francisco sit either side of the antimeridian. Taking the smallest and
        // largest columns would produce a box covering almost every longitude on Earth, the long
        // way round through Europe.
        let tokyo = (35.6762, 139.6503)
        let sanFrancisco = (37.7749, -122.4194)
        let bounds = try XCTUnwrap(indexOf(tokyo, sanFrancisco).bounds())

        XCTAssertTrue(bounds.crossesAntimeridian, "the box should wrap across the Pacific")
        XCTAssertLessThan(bounds.longitudeSpan, 180.0, "the wrapped span should be the short way round")
        // ~98 degrees the Pacific way, versus ~262 the wrong way.
        XCTAssertEqual(bounds.longitudeSpan, 98.0, accuracy: 2.0)

        // Both cities must still fall inside, remembering the box runs west -> +180 -> east.
        for (_, lon) in [tokyo, sanFrancisco] {
            XCTAssertTrue(lon >= bounds.west || lon <= bounds.east, "longitude \(lon) fell outside")
        }
    }

    func testCellsHuggingBothSidesOfTheAntimeridianWrapTightly() throws {
        let index = ExploredIndex()
        index.addAll([
            CellKey.pack(grid - 2, 1000),
            CellKey.pack(grid - 1, 1000),
            CellKey.pack(0, 1000),
            CellKey.pack(1, 1000),
        ])
        let bounds = try XCTUnwrap(index.bounds())
        XCTAssertTrue(bounds.crossesAntimeridian)
        // Four adjacent cells at z17 are about a kilometre across, nothing like a world span.
        XCTAssertLessThan(bounds.longitudeSpan, 0.02)
    }

    func testAnEvenlySpreadMapDoesNotWrap() throws {
        // Cells in Europe and the Americas: the widest gap is a real ocean, but no pair is close
        // enough across the antimeridian to make wrapping the tighter fit.
        let bounds = try XCTUnwrap(indexOf((51.5, -0.12), (40.7, -74.0), (48.85, 2.35)).bounds())
        XCTAssertFalse(bounds.crossesAntimeridian)
        XCTAssertLessThanOrEqual(bounds.west, -74.0)
        XCTAssertGreaterThanOrEqual(bounds.east, 2.35)
    }

    func testAFullRingOfColumnsSpansTheWorldWithoutWrapping() throws {
        let index = ExploredIndex()
        index.addAll((0..<grid).map { CellKey.pack($0, 1000) })
        let bounds = try XCTUnwrap(index.bounds())
        XCTAssertFalse(bounds.crossesAntimeridian)
        XCTAssertEqual(bounds.west, -180.0, accuracy: 1e-9)
        XCTAssertEqual(bounds.east, 180.0, accuracy: 1e-9)
    }

    func testBoundsTrackCellsAsTheyAreAdded() throws {
        let index = ExploredIndex()
        index.add(CellKey.pack(TileMath.cellX(0.0, z), TileMath.cellY(0.0, z)))
        let first = try XCTUnwrap(index.bounds())
        index.add(CellKey.pack(TileMath.cellX(10.0, z), TileMath.cellY(10.0, z)))
        let second = try XCTUnwrap(index.bounds())
        XCTAssertGreaterThan(second.latitudeSpan, first.latitudeSpan)
        XCTAssertGreaterThan(second.longitudeSpan, first.longitudeSpan)
    }

    func testTheCentreOfABoxIsInsideIt() throws {
        let bounds = try XCTUnwrap(indexOf((51.5074, -0.1278), (48.8566, 2.3522)).bounds())
        XCTAssertTrue(bounds.centerLatitude >= bounds.south && bounds.centerLatitude <= bounds.north)
        XCTAssertTrue(bounds.centerLongitude >= bounds.west && bounds.centerLongitude <= bounds.east)
        XCTAssertEqual(bounds.centerLatitude, 50.18, accuracy: 0.05)
        XCTAssertEqual(bounds.centerLongitude, 1.11, accuracy: 0.05)
    }

    func testTheCentreOfAWrappedBoxLandsInThePacificNotInAfrica() throws {
        // Tokyo and San Francisco. Averaging the two longitudes naively gives about 8 degrees,
        // which is the Gulf of Guinea - the wrong side of the planet entirely.
        let bounds = try XCTUnwrap(indexOf((35.6762, 139.6503), (37.7749, -122.4194)).bounds())
        XCTAssertTrue(bounds.crossesAntimeridian)
        let center = bounds.centerLongitude
        XCTAssertTrue(center > 170.0 || center < -170.0, "the middle of that pair is the date line, got \(center)")
    }

    func testClearingRemovesTheBounds() {
        let index = indexOf((51.5, -0.12))
        XCTAssertNotNil(index.bounds())
        index.clear()
        XCTAssertNil(index.bounds())
    }
}
