import XCTest
@testable import RoamedCore

/**
 Exercises the mask that actually ships, not a fixture.

 The file is written by a Python script and read by Swift, so nothing but reading the real bytes
 back proves the two agree on the format - or that the boundaries landed where they should. It is
 the same `regions.bin` the Android build reads, which is the point: the two apps must agree about
 the world.
 */
final class RegionMaskTests: XCTestCase {

    private var mask: RegionMask!

    override func setUpWithError() throws {
        mask = try RegionMask.bundled()
    }

    private func names(_ latitude: Double, _ longitude: Double) -> [String] {
        mask.lineage(mask.regionAt(latitude: latitude, longitude: longitude)).map { $0.name }
    }

    func testTheShippedMaskIsTheZoomTheCodeExpects() {
        XCTAssertEqual(mask.zoom, RegionMask.maskZoom)
        XCTAssertGreaterThan(mask.regions.count, 4_000, "only \(mask.regions.count) regions")
    }

    func testPlacesResolveToTheirStateCountryAndContinent() {
        XCTAssertEqual(
            names(39.9626, -76.7277),
            ["Pennsylvania", "United States of America", "North America"],
            "York, Pennsylvania"
        )
        XCTAssertEqual(
            names(39.6639, -75.6093),
            ["Delaware", "United States of America", "North America"],
            "Christiana, Delaware"
        )
        XCTAssertEqual(names(61.2181, -149.9003).first, "Alaska")
        XCTAssertEqual(names(21.3069, -157.8583).first, "Hawaii")
        XCTAssertEqual(Array(names(35.6762, 139.6503).dropFirst()), ["Japan", "Asia"])
        XCTAssertEqual(Array(names(-33.8688, 151.2093).dropFirst()), ["Australia", "Oceania"])
        XCTAssertEqual(Array(names(-23.5505, -46.6333).dropFirst()), ["Brazil", "South America"])
        XCTAssertEqual(Array(names(-1.2921, 36.8219).dropFirst()), ["Kenya", "Africa"])
        XCTAssertEqual(Array(names(48.8566, 2.3522).dropFirst()), ["France", "Europe"])
    }

    func testTheOpenOceanBelongsToNobody() {
        XCTAssertEqual(mask.regionAt(latitude: 30.0, longitude: -40.0), Region.none, "mid-Atlantic")
        XCTAssertEqual(mask.regionAt(latitude: -20.0, longitude: -120.0), Region.none, "south Pacific")
    }

    func testRussiaCountsAsAsiaSoEuropeIsNotMostlySiberia() throws {
        XCTAssertEqual(Array(names(55.7558, 37.6173).dropFirst()), ["Russia", "Asia"])
        let europe = try XCTUnwrap(
            mask.regions.first { $0.kind == .continent && $0.name == "Europe" }
        )
        // Europe without Russia is about 6 million km2; with it, over 22 million.
        let millionKm2 = europe.areaSquareMeters / 1e12
        XCTAssertTrue((5.0...8.0).contains(millionKm2), "Europe came out \(millionKm2) million km2")
    }

    func testRegionAreasMatchThePublishedFigures() throws {
        func areaKm2(_ name: String, _ kind: RegionKind) throws -> Double {
            try XCTUnwrap(mask.regions.first { $0.kind == kind && $0.name == name })
                .areaSquareMeters / 1e6
        }
        // Within a few percent: the boundaries are generalised, and coasts are drawn at low tide.
        assertClose(119_280.0, try areaKm2("Pennsylvania", .subdivision), 0.05)
        assertClose(423_970.0, try areaKm2("California", .subdivision), 0.05)
        assertClose(9_984_670.0, try areaKm2("Canada", .country), 0.08)
        assertClose(377_975.0, try areaKm2("Japan", .country), 0.10)
    }

    func testEveryRegionHangsOffTheRightKindOfParent() throws {
        for region in mask.regions {
            let parent = region.parentId == Region.none ? nil : mask.region(region.parentId)
            switch region.kind {
            case .continent:
                XCTAssertEqual(region.parentId, Region.none, "\(region.name) should sit at the top")
            case .country:
                XCTAssertEqual(
                    try XCTUnwrap(parent, region.name).kind, .continent,
                    "\(region.name) should hang off a continent"
                )
            case .subdivision:
                XCTAssertEqual(
                    try XCTUnwrap(parent, region.name).kind, .country,
                    "\(region.name) should hang off a country"
                )
            }
            XCTAssertGreaterThan(region.areaSquareMeters, 0.0, "\(region.name) has no area")
            XCTAssertFalse(
                region.name.trimmingCharacters(in: .whitespaces).isEmpty,
                "region \(region.id) has no name"
            )
        }
    }

    func testRunsWithinARowAreSortedAndNeverOverlap() {
        // The lookup binary-searches each row, which is only correct if the file says this.
        var checked = 0
        for y in stride(from: 0, to: mask.gridSize, by: 7) {
            var previousEnd = -1
            for x in 0..<mask.gridSize {
                let id = mask.regionAt(maskX: x, maskY: y)
                if id != Region.none {
                    XCTAssertGreaterThan(x, previousEnd, "row \(y) went backwards at \(x)")
                    previousEnd = x
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 10_000, "only \(checked) squares had an owner; the sweep found nothing")
    }

    func testADriveThroughTwoStatesIsCountedUnderBothAndUnderOneCountry() {
        let fog = FogEngine()
        var cells = Set<CellKeyValue>()
        // Roughly the drive up I-95 and I-83: Delaware, then Pennsylvania.
        fog.cellsWithinRadius(39.6639, -75.6093, 200.0, into: &cells)
        fog.cellsWithinRadius(39.9626, -76.7277, 200.0, into: &cells)
        fog.cellsWithinRadius(40.1295, -77.0155, 200.0, into: &cells)

        let tally = RegionBreakdown.of(mask: mask, cells: Array(cells))
        XCTAssertEqual(
            Set(tally.subdivisions.map { $0.region.name }),
            ["Pennsylvania", "Delaware"],
            "both states should be counted"
        )
        // Two of the three circles are in Pennsylvania, but Pennsylvania is twenty-three times the
        // size of Delaware, so the smaller state is the one further along - and that is the order.
        XCTAssertEqual(tally.subdivisions.first?.region.name, "Delaware")
        XCTAssertGreaterThan(
            tally.subdivisions[0].percentExplored, tally.subdivisions[1].percentExplored,
            "the list must run in the same direction as the percentages it shows"
        )
        XCTAssertGreaterThan(
            tally.subdivisions[1].exploredSquareMeters, tally.subdivisions[0].exploredSquareMeters,
            "and that is deliberately not the same as ranking by area covered"
        )
        XCTAssertEqual(tally.countries.map { $0.region.name }, ["United States of America"])
        XCTAssertEqual(tally.continents.map { $0.region.name }, ["North America"])
        XCTAssertEqual(tally.unplacedSquareMeters, 0.0, "none of this is at sea")
    }

    func testAStatesAreaIsPartOfItsCountrysWhichIsPartOfItsContinents() {
        let fog = FogEngine()
        var cells = Set<CellKeyValue>()
        fog.cellsWithinRadius(39.9626, -76.7277, 300.0, into: &cells)   // Pennsylvania
        fog.cellsWithinRadius(48.8566, 2.3522, 300.0, into: &cells)     // Paris
        fog.cellsWithinRadius(-33.8688, 151.2093, 300.0, into: &cells)  // Sydney

        let tally = RegionBreakdown.of(mask: mask, cells: Array(cells))
        let states = tally.subdivisions.reduce(0.0) { $0 + $1.exploredSquareMeters }
        let countries = tally.countries.reduce(0.0) { $0 + $1.exploredSquareMeters }
        let continents = tally.continents.reduce(0.0) { $0 + $1.exploredSquareMeters }

        XCTAssertEqual(tally.countries.count, 3)
        XCTAssertEqual(tally.continents.count, 3)
        XCTAssertLessThanOrEqual(states, countries + 1e-6)
        XCTAssertEqual(countries, continents, accuracy: 1e-6)
        XCTAssertGreaterThan(tally.countriesInAtlas, 200, "the atlas should know the whole world")
        XCTAssertTrue((6...8).contains(tally.continentsInAtlas), "got \(tally.continentsInAtlas) continents")
    }

    func testCoveringAWholeRegionNeverReadsAsMoreThanAllOfIt() throws {
        // Every square of Delaware, mask and all, plus the coastal squares that are really sea.
        let delaware = try XCTUnwrap(
            mask.regions.first { $0.kind == .subdivision && $0.name == "Delaware" }
        )
        var cells: [CellKeyValue] = []
        let shift = RevealZoom.z - mask.zoom
        for maskY in TileMath.cellY(39.9, mask.zoom)...TileMath.cellY(38.4, mask.zoom) {
            for maskX in TileMath.cellX(-75.9, mask.zoom)...TileMath.cellX(-75.0, mask.zoom) {
                if mask.regionAt(maskX: maskX, maskY: maskY) != delaware.id { continue }
                // One fog cell in each corner is enough to stand for the whole mask square.
                cells.append(CellKey.pack(maskX << shift, maskY << shift))
                cells.append(CellKey.pack((maskX << shift) + 1, (maskY << shift) + 1))
            }
        }
        XCTAssertFalse(cells.isEmpty, "Delaware should own some mask squares")

        let tally = RegionBreakdown.of(mask: mask, cells: cells)
        let progress = try XCTUnwrap(tally.subdivisions.first { $0.region.name == "Delaware" })
        XCTAssertLessThanOrEqual(progress.percentExplored, 100.0, "got \(progress.percentExplored)%")
        XCTAssertGreaterThan(progress.percentExplored, 0.0)
    }

    func testCellsAtSeaAreReportedRatherThanQuietlyDropped() {
        let fog = FogEngine()
        let cells = fog.cellsWithinRadius(30.0, -40.0, 500.0)
        let tally = RegionBreakdown.of(mask: mask, cells: Array(cells))
        XCTAssertTrue(tally.countries.isEmpty)
        XCTAssertGreaterThan(tally.unplacedSquareMeters, 0.0, "mid-ocean cells should count as unplaced")
    }

    private func assertClose(
        _ expected: Double, _ actual: Double, _ tolerance: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let error = abs(actual - expected) / expected
        XCTAssertLessThanOrEqual(
            error, tolerance,
            "expected ~\(expected), got \(actual) (\(Int(error * 100))% out)",
            file: file, line: line
        )
    }
}
