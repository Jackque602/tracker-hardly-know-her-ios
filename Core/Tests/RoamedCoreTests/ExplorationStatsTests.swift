import XCTest
@testable import RoamedCore

final class ExplorationStatsTests: XCTestCase {

    func testTheWholePlanetIsAHundredPercent() {
        XCTAssertEqual(
            ExplorationStats.percentOfEarthSurface(TileMath.earthSurfaceAreaM2), 100.0, accuracy: 1e-9
        )
        XCTAssertEqual(
            ExplorationStats.percentOfEarthLand(TileMath.earthLandAreaM2), 100.0, accuracy: 1e-9
        )
    }

    func testLandPercentageIsLargerThanSurfacePercentageForTheSameArea() {
        let area = 1e10
        XCTAssertGreaterThan(
            ExplorationStats.percentOfEarthLand(area),
            ExplorationStats.percentOfEarthSurface(area)
        )
    }

    func testTinyPercentagesKeepMeaningfulDigitsInsteadOfRoundingToZero() {
        XCTAssertEqual(ExplorationStats.formatPercent(0.001234), "0.00123%")
        XCTAssertEqual(ExplorationStats.formatPercent(0.0000123), "0.0000123%")
        XCTAssertEqual(ExplorationStats.formatPercent(0.00000001), "<0.000001%")
        XCTAssertEqual(ExplorationStats.formatPercent(0.0), "0%")
        XCTAssertEqual(ExplorationStats.formatPercent(12.34), "12.3%")
        XCTAssertEqual(ExplorationStats.formatPercent(0.001), "0.001%", "trailing zeros should be trimmed")
    }

    func testAreasAreFormattedWithASensibleUnit() {
        XCTAssertEqual(ExplorationStats.formatArea(2.5e9), "2,500 km²")
        XCTAssertEqual(ExplorationStats.formatArea(1.25e7), "12.5 km²")
        XCTAssertEqual(ExplorationStats.formatArea(5_000.0), "0.5 ha")
    }

    func testDistancesSwitchFromMetresToKilometres() {
        XCTAssertEqual(ExplorationStats.formatDistance(450.0), "450 m")
        XCTAssertEqual(ExplorationStats.formatDistance(4_500.0), "4.5 km")
        XCTAssertEqual(ExplorationStats.formatDistance(1_234_000.0), "1,234 km")
    }
}
