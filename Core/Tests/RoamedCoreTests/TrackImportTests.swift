import XCTest
@testable import RoamedCore

final class TrackImportTests: XCTestCase {

    private func allPoints(_ text: String) throws -> [ImportedFix] {
        try TrackImport.parse(text).flatMap { $0.points }
    }

    func testReadsTheOnDeviceExportWithGeoStrings() throws {
        // The shape Google Maps writes today: segments, each holding an ordered path.
        let text = """
            {"semanticSegments":[
              {"startTime":"2026-09-01T13:00:00.000-04:00",
               "endTime":"2026-09-01T14:00:00.000-04:00",
               "timelinePath":[
                 {"point":"geo:39.7391,-75.5398","time":"2026-09-01T13:00:00.000-04:00"},
                 {"point":"geo:39.8000,-75.7000","time":"2026-09-01T13:20:00.000-04:00"},
                 {"point":"geo:40.0379,-76.3055","time":"2026-09-01T13:50:00.000-04:00"}
               ]}
            ]}
            """
        let tracks = try TrackImport.parse(text)
        XCTAssertEqual(tracks.count, 1, "one segment should give one path")
        XCTAssertEqual(tracks[0].points.count, 3)
        XCTAssertEqual(tracks[0].points[0].latitude, 39.7391, accuracy: 1e-9)
        XCTAssertEqual(tracks[0].points[0].longitude, -75.5398, accuracy: 1e-9)
        XCTAssertTrue(tracks[0].points.allSatisfy { $0.timestamp != nil }, "times should be carried across")
    }

    func testReadsTheOldTakeoutRecordsWithE7Integers() throws {
        let text = """
            {"locations":[
              {"latitudeE7":397391000,"longitudeE7":-755398000,"timestampMs":"1788267600000","accuracy":12},
              {"latitudeE7":400379000,"longitudeE7":-763055000,"timestampMs":"1788271200000","accuracy":18}
            ]}
            """
        let points = try allPoints(text)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].latitude, 39.7391, accuracy: 1e-6)
        XCTAssertEqual(points[0].longitude, -75.5398, accuracy: 1e-6)
        XCTAssertEqual(points[0].timestamp, 1_788_267_600_000)
    }

    func testReadsSemanticHistoryWithDegreeStringLatLngs() throws {
        let text = """
            {"timelineObjects":[
              {"activitySegment":{
                 "startLocation":{"latitudeE7":397391000,"longitudeE7":-755398000},
                 "endLocation":{"latitudeE7":400379000,"longitudeE7":-763055000}}},
              {"placeVisit":{"location":{"latLng":"40.2732°, -76.8867°"}}}
            ]}
            """
        let points = try allPoints(text)
        XCTAssertGreaterThanOrEqual(points.count, 3, "two endpoints and a visit, got \(points.count)")
        XCTAssertTrue(points.contains { abs($0.latitude - 40.2732) < 1e-4 }, "the visit should be read")
    }

    func testAnActivityStartAndEndBecomeOneJourney() throws {
        let text = """
            {"semanticSegments":[
              {"activity":{
                "start":{"latLng":"39.7391°, -75.5398°"},
                "end":{"latLng":"40.2732°, -76.8867°"},
                "distanceMeters":"120000"}}
            ]}
            """
        let tracks = try TrackImport.parse(text)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].points.count, 2, "start and end belong to the same track")
    }

    func testSeparateSegmentsStaySeparateSoNoLineIsDrawnBetweenThem() throws {
        // Two paths a continent apart. Joining them would invent a drive across the country.
        let text = """
            {"semanticSegments":[
              {"timelinePath":[{"point":"geo:39.73,-75.53"},{"point":"geo:39.74,-75.54"}]},
              {"timelinePath":[{"point":"geo:37.77,-122.41"},{"point":"geo:37.78,-122.42"}]}
            ]}
            """
        XCTAssertEqual(try TrackImport.parse(text).count, 2, "each path must stay its own track")
    }

    func testPointsArePutBackInTimeOrder() throws {
        let text = """
            {"locations":[
              {"latitudeE7":400000000,"longitudeE7":-760000000,"timestamp":"2026-09-01T14:00:00Z"},
              {"latitudeE7":399000000,"longitudeE7":-759000000,"timestamp":"2026-09-01T13:00:00Z"}
            ]}
            """
        let points = try allPoints(text)
        XCTAssertEqual(points.count, 2)
        let first = try XCTUnwrap(points[0].timestamp)
        let second = try XCTUnwrap(points[1].timestamp)
        XCTAssertLessThan(first, second, "out-of-order entries should be sorted")
    }

    func testMissingAndImpossibleCoordinatesAreDropped() throws {
        let text = """
            {"locations":[
              {"latitudeE7":0,"longitudeE7":0},
              {"latitudeE7":1000000000,"longitudeE7":-760000000},
              {"latitudeE7":397391000,"longitudeE7":-755398000}
            ]}
            """
        let points = try allPoints(text)
        XCTAssertEqual(points.count, 1, "null island and out-of-range points must not be imported")
        XCTAssertEqual(points[0].latitude, 39.7391, accuracy: 1e-6)
    }

    func testReadsGpxWithOneTrackPerSegment() throws {
        let text = """
            <?xml version="1.0"?>
            <gpx version="1.1"><trk><name>Drive</name>
              <trkseg>
                <trkpt lat="39.7391" lon="-75.5398"><ele>30</ele><time>2026-09-01T17:00:00Z</time></trkpt>
                <trkpt lat="40.0379" lon="-76.3055"><time>2026-09-01T17:50:00Z</time></trkpt>
              </trkseg>
              <trkseg>
                <trkpt lat="40.2732" lon="-76.8867"/>
              </trkseg>
            </trk></gpx>
            """
        let tracks = try TrackImport.parse(text)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].points.count, 2)
        XCTAssertEqual(tracks[1].points.count, 1, "a self-closing trkpt should still be read")
        XCTAssertEqual(tracks[0].points[0].timestamp, 1_788_282_000_000)
    }

    func testAGpxRoundTripThroughOurOwnExporterReadsBack() throws {
        let exported = StringSink()
        GpxWriter.write(
            exported,
            trackName: "Roamed track",
            points: [
                TrackPointRecord(
                    timestamp: 1_788_282_000_000, latitude: 39.7391, longitude: -75.5398,
                    altitude: 30.0, accuracy: 8, speed: 1
                ),
                TrackPointRecord(
                    timestamp: 1_788_285_000_000, latitude: 40.0379, longitude: -76.3055,
                    altitude: nil, accuracy: 6, speed: 1
                ),
            ]
        )
        let points = try allPoints(exported.text)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].latitude, 39.7391, accuracy: 1e-9)
        XCTAssertEqual(points[0].timestamp, 1_788_282_000_000)
    }

    func testEpochsInSecondsAreNotReadAs1970() throws {
        // Life360 and many others count in seconds. Taken at face value the whole trip lands in
        // 1970 and every imported cell falls outside the years the stats screen knows about.
        let text = """
            {"locations":[
              {"latitude":"39.6639","longitude":"-75.6093","startTimestamp":"1788267600"},
              {"latitude":"40.1295","longitude":"-77.0155","startTimestamp":"1788271200"}
            ]}
            """
        let points = try allPoints(text)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].timestamp, 1_788_267_600_000)
        XCTAssertEqual(points[1].timestamp, 1_788_271_200_000)
    }

    func testMillisecondsAndMicrosecondsAreBothUnderstood() throws {
        let millis = """
            {"locations":[
            {"latitude":39.66,"longitude":-75.60,"timestamp":"1788267600000"},
            {"latitude":40.12,"longitude":-77.01,"timestamp":"1788271200000"}]}
            """
        XCTAssertEqual(try allPoints(millis)[0].timestamp, 1_788_267_600_000)

        let micros = """
            {"locations":[
            {"latitude":39.66,"longitude":-75.60,"timestamp":"1788267600000000"},
            {"latitude":40.12,"longitude":-77.01,"timestamp":"1788271200000000"}]}
            """
        XCTAssertEqual(try allPoints(micros)[0].timestamp, 1_788_267_600_000)
    }

    func testStringEncodedCoordinatesAreReadAsNumbers() throws {
        // Life360 quotes its numbers; a strict number-only reader would find nothing here.
        let text = """
            {"locations":[
            {"latitude":"39.6639","longitude":"-75.6093"},
            {"latitude":"40.1295","longitude":"-77.0155"}]}
            """
        let points = try allPoints(text)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].latitude, 39.6639, accuracy: 1e-9)
        XCTAssertEqual(points[0].longitude, -75.6093, accuracy: 1e-9)
    }

    func testGpxSegmentsDeclareThemselvesContiguousTimelineGroupingsDoNot() throws {
        // A turn-by-turn route export can leave fifty km of motorway between two waypoints. GPX
        // says a segment is one path, so those must still join; a heuristically grouped JSON array
        // carries no such promise and keeps the cautious distance rule.
        let gpx = """
            <gpx version="1.1"><trk><trkseg>
              <trkpt lat="39.7391" lon="-75.5398"/>
              <trkpt lat="40.0379" lon="-76.3055"/>
            </trkseg></trk></gpx>
            """
        XCTAssertTrue(try TrackImport.parse(gpx).allSatisfy { $0.contiguous }, "a GPX segment is a declared path")

        let json = """
            {"locations":[
            {"latitude":39.7391,"longitude":-75.5398},
            {"latitude":40.0379,"longitude":-76.3055}]}
            """
        XCTAssertTrue(try TrackImport.parse(json).allSatisfy { !$0.contiguous }, "grouped history is only a guess")
    }

    func testUnreadableFilesAreRefusedClearly() {
        XCTAssertThrowsError(try TrackImport.parse("this is not a track"))
        XCTAssertThrowsError(try GoogleTimelineParser.parse("{ broken"))
        XCTAssertThrowsError(try GpxParser.parse("<html><body>nope</body></html>"))
    }

    func testATimelineExportWithNothingLocatableYieldsNoTracks() throws {
        let tracks = try TrackImport.parse(#"{"semanticSegments":[{"startTime":"2026-09-01T13:00:00Z"}]}"#)
        XCTAssertTrue(tracks.isEmpty)
    }
}
