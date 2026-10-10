import XCTest
@testable import RoamedCore

/**
 The two atlases that sit underneath a state.

 Like `RegionMaskTests`, this reads the bytes that actually ship rather than a fixture: the files
 are written by a Python script and read by Swift, and nothing short of decoding the real thing
 proves the two agree about the format or that the boundaries landed where they should.
 */
final class LocalityMaskTests: XCTestCase {

    private var counties: RegionMask!
    private var cities: RegionMask!
    private var world: RegionMask!

    override func setUpWithError() throws {
        counties = try RegionMask.bundled(.counties)
        cities = try RegionMask.bundled(.cities)
        world = try RegionMask.bundled(.regions)
    }

    private func names(_ mask: RegionMask, _ latitude: Double, _ longitude: Double) -> [String] {
        mask.lineage(mask.regionAt(latitude: latitude, longitude: longitude)).map { $0.name }
    }

    func testEachTierIsDrawnAtTheResolutionItNeeds() {
        // A county is big enough for the main atlas's own grid. A city is not: the median
        // footprint is 30 km2 against a z12 square's 56, so it gets a finer one of its own.
        XCTAssertEqual(counties.zoom, RegionMask.maskZoom)
        XCTAssertGreaterThan(cities.zoom, RegionMask.maskZoom)
    }

    func testPlacesResolveToTheirCountyAndCity() {
        XCTAssertEqual(names(counties, 39.9626, -76.7277), ["York County", "Pennsylvania"])
        XCTAssertEqual(names(counties, 39.6639, -75.6093), ["New Castle County", "Delaware"])
        XCTAssertEqual(names(counties, 39.9526, -75.1652), ["Philadelphia County", "Pennsylvania"])
        XCTAssertEqual(names(cities, 39.9626, -76.7277), ["York", "Pennsylvania"])
        XCTAssertEqual(names(cities, 39.9526, -75.1652), ["Philadelphia", "Pennsylvania"])
    }

    /**
     The bug this tier was nearly shipped with.

     Natural Earth draws Philadelphia as the whole metropolitan footprint, which reaches into
     Delaware. Unclipped, standing in Christiana was credited to a Pennsylvania city - the same
     ground counted under two places that do not contain one another.
     */
    func testGroundInOneStateIsNeverCreditedToAnotherStatesCity() {
        XCTAssertEqual(
            cities.regionAt(latitude: 39.6639, longitude: -75.6093), Region.none,
            "Christiana is in Delaware, so no Pennsylvania city may claim it"
        )
    }

    func testOpenCountrysideBelongsToNoCity() {
        // Carlisle is a real town, but not one Natural Earth names, so it has no footprint.
        XCTAssertEqual(cities.regionAt(latitude: 40.1295, longitude: -77.0155), Region.none)
    }

    func testEveryLocalityHangsOffAStateTheMainAtlasKnows() throws {
        let worldCodes = Set(world.regions(of: .subdivision).map { $0.code })
        for mask in [counties!, cities!] {
            let localities = mask.regions.filter { $0.kind.isLocality }
            XCTAssertFalse(localities.isEmpty)
            for locality in localities {
                let parent = try XCTUnwrap(mask.region(locality.parentId), locality.name)
                XCTAssertEqual(parent.kind, .subdivision, "\(locality.name) must sit in a state")
                XCTAssertTrue(
                    parent.code.hasPrefix("US-"), "\(locality.name) sits in \(parent.code)"
                )
                XCTAssertTrue(
                    worldCodes.contains(parent.code),
                    "\(parent.code) is not a state the main atlas has"
                )
                XCTAssertFalse(locality.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    func testTheAtlasesCoverTheStatesAndCountiesYouWouldExpect() {
        let allCounties = counties.regions.filter { $0.kind == .county }
        let allCities = cities.regions.filter { $0.kind == .city }
        XCTAssertGreaterThan(allCounties.count, 3_000, "got \(allCounties.count) counties")
        XCTAssertGreaterThan(allCities.count, 300, "got \(allCities.count) cities")
        XCTAssertEqual(counties.regions(of: .subdivision).count, 51, "fifty states and DC")
    }

    func testADriveIsCountedUnderTheCountiesItActuallyCrossed() {
        let fog = FogEngine()
        var cells = Set<CellKeyValue>()
        // Christiana, then York, then Carlisle: Delaware into Pennsylvania.
        fog.cellsWithinRadius(39.6639, -75.6093, 200.0, into: &cells)
        fog.cellsWithinRadius(39.9626, -76.7277, 200.0, into: &cells)
        fog.cellsWithinRadius(40.1295, -77.0155, 200.0, into: &cells)

        let tally = RegionBreakdown.of(mask: counties, cells: Array(cells))
        XCTAssertEqual(
            Set(tally.counties.map { $0.region.name }),
            ["New Castle County", "York County", "Cumberland County"]
        )
        XCTAssertTrue(tally.cities.isEmpty, "the county atlas holds no cities")
        // Ranked by share, as every other list in the app is.
        XCTAssertEqual(
            tally.counties.map(\.percentExplored),
            tally.counties.map(\.percentExplored).sorted(by: >)
        )
    }

    func testLocalitiesAreGroupedByTheStateTheyBelongTo() {
        let fog = FogEngine()
        var cells = Set<CellKeyValue>()
        fog.cellsWithinRadius(39.6639, -75.6093, 200.0, into: &cells)
        fog.cellsWithinRadius(39.9626, -76.7277, 200.0, into: &cells)

        let grouped = RegionBreakdown.of(mask: counties, cells: Array(cells))
            .localities(of: .county)
        XCTAssertEqual(grouped["US-DE"]?.map { $0.region.name }, ["New Castle County"])
        XCTAssertEqual(grouped["US-PA"]?.map { $0.region.name }, ["York County"])
        XCTAssertNil(grouped["US-CA"])
    }

    func testACountyIsPartOfItsStateAndNeverMoreThanAllOfItself() {
        let fog = FogEngine()
        var cells = Set<CellKeyValue>()
        for (latitude, longitude) in [(39.9626, -76.7277), (40.2732, -76.8867), (39.9526, -75.1652)] {
            fog.cellsWithinRadius(latitude, longitude, 400.0, into: &cells)
        }
        let tally = RegionBreakdown.of(mask: counties, cells: Array(cells))
        let inCounties = tally.counties.reduce(0.0) { $0 + $1.exploredSquareMeters }
        let inStates = tally.subdivisions.reduce(0.0) { $0 + $1.exploredSquareMeters }
        XCTAssertEqual(inCounties, inStates, accuracy: 1.0, "a county's ground is its state's too")
        for county in tally.counties {
            XCTAssertLessThanOrEqual(county.percentExplored, 100.0, county.region.name)
            XCTAssertGreaterThan(county.percentExplored, 0.0, county.region.name)
        }
    }

    func testWalkingACityWholeNeverReadsAsMoreThanAllOfIt() throws {
        // Every square the atlas gives Harrisburg, which is the most that can ever be explored.
        let harrisburg = try XCTUnwrap(cities.regions.first { $0.name == "Harrisburg" })
        let shift = RevealZoom.z - cities.zoom
        var cells: [CellKeyValue] = []
        let centreX = TileMath.cellX(-76.8867, cities.zoom)
        let centreY = TileMath.cellY(40.2732, cities.zoom)
        for maskY in (centreY - 60)...(centreY + 60) {
            for maskX in (centreX - 60)...(centreX + 60) {
                guard cities.regionAt(maskX: maskX, maskY: maskY) == harrisburg.id else { continue }
                cells.append(CellKey.pack(maskX << shift, maskY << shift))
                cells.append(CellKey.pack((maskX << shift) + 1, (maskY << shift) + 1))
            }
        }
        XCTAssertFalse(cells.isEmpty, "Harrisburg should own some squares")

        let tally = RegionBreakdown.of(mask: cities, cells: cells)
        let progress = try XCTUnwrap(tally.cities.first { $0.region.name == "Harrisburg" })
        XCTAssertGreaterThan(progress.percentExplored, 0.0)
        XCTAssertLessThanOrEqual(progress.percentExplored, 100.0)
    }
}
