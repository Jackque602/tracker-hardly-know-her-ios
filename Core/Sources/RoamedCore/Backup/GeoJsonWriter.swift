import Foundation

/**
 Streams the uncovered cells out as a GeoJSON MultiPolygon, so the same fog can be dropped into
 QGIS, geojson.io or anything else without re-implementing the tile maths.
 */
public final class GeoJsonSink {

    private let out: TextSink
    private let zoom: Int
    private var firstCell = true

    public init(_ out: TextSink, zoom: Int = RevealZoom.z) {
        self.out = out
        self.zoom = zoom
    }

    public func begin() {
        out.write(
            "{\"type\":\"Feature\",\"properties\":{\"name\":\"Roamed explored area\",\"zoom\":\(zoom)},"
                + "\"geometry\":{\"type\":\"MultiPolygon\",\"coordinates\":["
        )
    }

    public func add(_ cell: CellRecord) {
        if !firstCell { out.write(",") }
        firstCell = false
        let west = TileMath.tileXToLon(Double(cell.x), zoom)
        let east = TileMath.tileXToLon(Double(cell.x + 1), zoom)
        let north = TileMath.tileYToLat(Double(cell.y), zoom)
        let south = TileMath.tileYToLat(Double(cell.y + 1), zoom)
        out.write("[[")
        appendPosition(west, north); out.write(",")
        appendPosition(east, north); out.write(",")
        appendPosition(east, south); out.write(",")
        appendPosition(west, south); out.write(",")
        appendPosition(west, north)
        out.write("]]")
    }

    public func end() {
        out.write("]}}")
    }

    private func appendPosition(_ lon: Double, _ lat: Double) {
        out.write("[" + GeoJsonSink.format(lon) + "," + GeoJsonSink.format(lat) + "]")
    }

    /// Six decimals is ~11 cm; more would just bloat the file.
    private static func format(_ value: Double) -> String {
        String((value * 1_000_000.0).rounded() / 1_000_000.0)
    }
}

public enum GeoJsonWriter {
    public static func write<S: Sequence>(
        _ out: TextSink, cells: S, zoom: Int = RevealZoom.z
    ) where S.Element == CellRecord {
        let sink = GeoJsonSink(out, zoom: zoom)
        sink.begin()
        for cell in cells { sink.add(cell) }
        sink.end()
    }
}
