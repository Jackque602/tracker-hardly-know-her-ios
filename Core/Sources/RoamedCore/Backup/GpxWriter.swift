import Foundation

/// Streams recorded fixes out as GPX 1.1, readable by every mapping tool worth the name.
public final class GpxSink {

    private let out: TextSink

    public init(_ out: TextSink) {
        self.out = out
    }

    public func begin(trackName: String) {
        out.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        out.write("<gpx version=\"1.1\" creator=\"Roamed\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n")
        out.write("  <trk>\n    <name>" + GpxSink.escapeXml(trackName) + "</name>\n    <trkseg>\n")
    }

    public func add(_ point: TrackPointRecord) {
        out.write("      <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">")
        if let altitude = point.altitude {
            out.write("<ele>\(altitude)</ele>")
        }
        out.write("<time>" + Instant.iso8601(epochMillis: point.timestamp) + "</time>")
        out.write("</trkpt>\n")
    }

    public func end() {
        out.write("    </trkseg>\n  </trk>\n</gpx>\n")
    }

    private static func escapeXml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum GpxWriter {
    public static func write<S: Sequence>(
        _ out: TextSink, trackName: String, points: S
    ) where S.Element == TrackPointRecord {
        let sink = GpxSink(out)
        sink.begin(trackName: trackName)
        for point in points { sink.add(point) }
        sink.end()
    }
}
