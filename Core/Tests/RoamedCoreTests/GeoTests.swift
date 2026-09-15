import XCTest
@testable import RoamedCore

final class GeoTests: XCTestCase {

    func testOneDegreeOfLatitudeIsAboutOneHundredAndElevenKilometres() {
        XCTAssertEqual(Geo.distanceMeters(0.0, 0.0, 1.0, 0.0), 111_195.0, accuracy: 100.0)
    }

    func testLondonToParisIsAboutThreeHundredAndFortyFourKilometres() {
        let d = Geo.distanceMeters(51.5074, -0.1278, 48.8566, 2.3522)
        XCTAssertEqual(d, 343_500.0, accuracy: 3_000.0)
    }

    func testDistanceToSelfIsZero() {
        XCTAssertEqual(Geo.distanceMeters(12.3, 45.6, 12.3, 45.6), 0.0, accuracy: 1e-6)
    }

    func testMidpointIsHalfwayAlongTheGreatCircle() {
        let mid = Geo.interpolate(51.5, 0.0, 51.5, 1.0, 0.5)
        XCTAssertEqual(mid.longitude, 0.5, accuracy: 1e-6)
        let toMid = Geo.distanceMeters(51.5, 0.0, mid.latitude, mid.longitude)
        let fromMid = Geo.distanceMeters(mid.latitude, mid.longitude, 51.5, 1.0)
        XCTAssertEqual(toMid, fromMid, accuracy: 1.0)
    }

    func testInterpolatingADegenerateSegmentReturnsTheStart() {
        let p = Geo.interpolate(10.0, 20.0, 10.0, 20.0, 0.7)
        XCTAssertEqual(p.latitude, 10.0, accuracy: 1e-9)
        XCTAssertEqual(p.longitude, 20.0, accuracy: 1e-9)
    }

    func testFractionsStayOrderedAlongTheSegment() {
        var previous = 0.0
        for i in 1...10 {
            let p = Geo.interpolate(0.0, 0.0, 10.0, 0.0, Double(i) / 10.0)
            XCTAssertGreaterThan(p.latitude, previous)
            previous = p.latitude
        }
    }
}
