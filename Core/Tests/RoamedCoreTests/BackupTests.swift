import XCTest
@testable import RoamedCore

final class BackupTests: XCTestCase {

    private let cells = [
        CellRecord(x: 70_000, y: 45_000, firstSeen: 1_700_000_000_000, lastSeen: 1_700_000_600_000, visits: 3),
        CellRecord(x: 70_001, y: 45_000, firstSeen: 1_700_000_100_000, lastSeen: 1_700_000_100_000, visits: 1),
        CellRecord(x: 0, y: 0, firstSeen: 1, lastSeen: 2, visits: 7),
    ]

    func testABackupRoundTripsWithoutLosingACell() throws {
        let out = StringSink()
        try BackupWriter.write(out, cells: cells, exportedAt: 42, appVersion: "1.0", cellCount: cells.count)
        XCTAssertEqual(try BackupReader.read(out.text), cells)
    }

    func testAnEmptyBackupRoundTrips() throws {
        let out = StringSink()
        try BackupWriter.write(out, cells: [CellRecord](), exportedAt: 0, appVersion: "1.0", cellCount: 0)
        XCTAssertEqual(try BackupReader.read(out.text), [])
    }

    func testTheHeaderRecordsTheGridZoomTheCellsWereWrittenAt() throws {
        let out = StringSink()
        try BackupWriter.write(out, cells: cells, exportedAt: 42, appVersion: "1.2.3", cellCount: cells.count)
        XCTAssertTrue(out.text.contains("\"revealZoom\":\(RevealZoom.z)"))
        XCTAssertTrue(out.text.contains("\"cellCount\":3"))
        XCTAssertTrue(out.text.contains("\"appVersion\":\"1.2.3\""))
    }

    func testABackupFromADifferentGridZoomIsRefused() {
        let text = #"{"format":"roamed-backup","version":1,"revealZoom":12,"cells":[[1,2,3,4,5]]}"#
        XCTAssertThrowsError(try BackupReader.read(text)) { error in
            XCTAssertTrue("\(error)".contains("grid zoom 12"), "got \(error)")
        }
    }

    func testABackupFromANewerAppVersionIsRefused() {
        let text = #"{"format":"roamed-backup","version":99,"revealZoom":17,"cells":[]}"#
        XCTAssertThrowsError(try BackupReader.read(text))
    }

    func testAnUnrelatedFileIsRefused() {
        XCTAssertThrowsError(try BackupReader.read(#"{"hello":"world"}"#))
        XCTAssertThrowsError(try BackupReader.read("not json at all"))
    }

    func testShortCellRowsFallBackToSensibleDefaults() throws {
        let text = #"{"format":"roamed-backup","version":1,"revealZoom":17,"cells":[[5,6]]}"#
        let restored = try BackupReader.read(text)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first, CellRecord(x: 5, y: 6, firstSeen: 0, lastSeen: 0, visits: 1))
    }

    func testAppVersionStringsAreEscaped() throws {
        let out = StringSink()
        try BackupWriter.write(
            out, cells: [CellRecord](), exportedAt: 0, appVersion: "quote\" and \\ backslash", cellCount: 0
        )
        XCTAssertEqual(try BackupReader.read(out.text), [])
    }

    func testGpxExportIsWellFormed() {
        let out = StringSink()
        GpxWriter.write(
            out,
            trackName: "Roamed track",
            points: [
                TrackPointRecord(
                    timestamp: 1_700_000_000_000, latitude: 51.5, longitude: -0.12,
                    altitude: 35.0, accuracy: 8, speed: 1.2
                ),
                TrackPointRecord(
                    timestamp: 1_700_000_020_000, latitude: 51.5001, longitude: -0.1201,
                    altitude: nil, accuracy: 6, speed: 1.4
                ),
            ]
        )
        let gpx = out.text
        XCTAssertTrue(gpx.hasPrefix("<?xml"))
        XCTAssertTrue(gpx.contains("<trkpt lat=\"51.5\" lon=\"-0.12\">"))
        XCTAssertTrue(gpx.contains("<ele>35.0</ele>"))
        XCTAssertTrue(gpx.contains("2023-11-14T22:13:20Z"))
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt").count - 1, 2)
        XCTAssertTrue(gpx.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("</gpx>"))
    }

    func testGeoJsonExportClosesEveryRing() {
        let out = StringSink()
        GeoJsonWriter.write(out, cells: cells)
        let geojson = out.text
        XCTAssertTrue(geojson.hasPrefix("{\"type\":\"Feature\""))
        XCTAssertTrue(geojson.contains("\"MultiPolygon\""))
        XCTAssertEqual(geojson.filter { $0 == "[" }.count, geojson.filter { $0 == "]" }.count)
        XCTAssertEqual(geojson.filter { $0 == "{" }.count, geojson.filter { $0 == "}" }.count)
    }

    func testWritingInPagesMatchesWritingInOneGo() throws {
        let streamed = StringSink()
        let sink = BackupSink(streamed)
        try sink.begin(exportedAt: 42, appVersion: "1.0", cellCount: cells.count)
        // Deliberately fed in two batches, the way a paged database read would.
        for cell in cells.prefix(2) { try sink.add(cell) }
        for cell in cells.dropFirst(2) { try sink.add(cell) }
        try sink.end()

        let whole = StringSink()
        try BackupWriter.write(whole, cells: cells, exportedAt: 42, appVersion: "1.0", cellCount: cells.count)
        XCTAssertEqual(streamed.text, whole.text)
        XCTAssertEqual(try BackupReader.read(streamed.text), cells)
    }

    func testASinkRefusesToBeUsedOutOfOrder() throws {
        let sink = BackupSink(StringSink())
        XCTAssertThrowsError(try sink.add(cells[0]))
        try sink.begin(exportedAt: 0, appVersion: "1.0", cellCount: 0)
        XCTAssertThrowsError(try sink.begin(exportedAt: 0, appVersion: "1.0", cellCount: 0))
    }

    func testPagedGpxAndGeoJsonSinksProduceTheSameBytesAsTheOneShotWriters() {
        let points = [
            TrackPointRecord(
                timestamp: 1_700_000_000_000, latitude: 51.5, longitude: -0.12,
                altitude: 35.0, accuracy: 8, speed: 1.2
            ),
            TrackPointRecord(
                timestamp: 1_700_000_020_000, latitude: 51.5001, longitude: -0.1201,
                altitude: nil, accuracy: 6, speed: 1.4
            ),
        ]
        let streamedGpx = StringSink()
        let gpxSink = GpxSink(streamedGpx)
        gpxSink.begin(trackName: "Roamed track")
        points.forEach(gpxSink.add)
        gpxSink.end()
        let wholeGpx = StringSink()
        GpxWriter.write(wholeGpx, trackName: "Roamed track", points: points)
        XCTAssertEqual(streamedGpx.text, wholeGpx.text)

        let streamedJson = StringSink()
        let jsonSink = GeoJsonSink(streamedJson)
        jsonSink.begin()
        cells.forEach(jsonSink.add)
        jsonSink.end()
        let wholeJson = StringSink()
        GeoJsonWriter.write(wholeJson, cells: cells)
        XCTAssertEqual(streamedJson.text, wholeJson.text)
    }

    func testWhetherACellWasFlownOverSurvivesARoundTrip() throws {
        let out = StringSink()
        try BackupWriter.write(
            out,
            cells: [
                CellRecord(x: 1, y: 2, firstSeen: 100, lastSeen: 200, visits: 3),
                CellRecord(x: 4, y: 5, firstSeen: 300, lastSeen: 400, visits: 1, source: .air),
            ],
            exportedAt: 1,
            appVersion: "test",
            cellCount: 2
        )
        let restored = try BackupReader.read(out.text)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].source, .ground)
        XCTAssertEqual(restored[1].source, .air)
    }

    func testABackupWrittenBeforeFlightsExistedReadsAsAllGround() throws {
        // Five elements per row, no source. Every one of those squares was walked or driven.
        let text = """
            {"format":"roamed-backup","version":1,"revealZoom":17,
            "cells":[[1,2,100,200,3],[4,5,300,400,1]]}
            """
        let restored = try BackupReader.read(text)
        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored.allSatisfy { $0.source == .ground })
    }
}
