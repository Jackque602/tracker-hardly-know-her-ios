import Foundation

/**
 Reads GPX, which is what every other tracker in the world exports.

 A regular expression rather than a full XML parser: the shape being looked for is exactly one
 attribute pair on one element name, GPX files run to hundreds of thousands of points, and this
 avoids pulling a parser into a module that otherwise has no dependencies.
 */
public enum GpxParser {

    private static let segment = try! NSRegularExpression(
        pattern: #"<trkseg[^>]*>(.*?)</trkseg>"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let trackPoint = try! NSRegularExpression(
        pattern: #"<(?:trkpt|rtept|wpt)[^>]*?\blat\s*=\s*"(-?\d+(?:\.\d+)?)"[^>]*?\blon\s*=\s*"(-?\d+(?:\.\d+)?)"[^>]*?(?:/>|>(.*?)</(?:trkpt|rtept|wpt)>)"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let time = try! NSRegularExpression(pattern: #"<time>\s*([^<]+?)\s*</time>"#)

    public static func parse(_ text: String) throws -> [ImportedTrack] {
        guard text.range(of: "<gpx", options: .caseInsensitive) != nil else {
            throw ImportError("This does not look like a GPX file.")
        }
        let wholeRange = NSRange(text.startIndex..., in: text)
        let segments = segment.matches(in: text, range: wholeRange)
            .compactMap { Coordinates.capture($0, 1, in: text) }
        // A file with no <trkseg> can still hold loose waypoints; treat the whole thing as one run.
        let bodies = segments.isEmpty ? [text] : segments
        return bodies
            // GPX says outright that a segment is one path, so its points may always be joined.
            .map { ImportedTrack(points: points(in: $0), contiguous: true) }
            .filter { !$0.isEmpty }
    }

    private static func points(in body: String) -> [ImportedFix] {
        let range = NSRange(body.startIndex..., in: body)
        return trackPoint.matches(in: body, range: range).compactMap { match in
            guard let latitude = Coordinates.capture(match, 1, in: body).flatMap(Double.init),
                  let longitude = Coordinates.capture(match, 2, in: body).flatMap(Double.init)
            else { return nil }
            let inner = Coordinates.capture(match, 3, in: body) ?? ""
            let innerRange = NSRange(inner.startIndex..., in: inner)
            let stamp = time.firstMatch(in: inner, range: innerRange)
                .flatMap { Coordinates.capture($0, 1, in: inner) }
            return Coordinates.fix(
                latitude: latitude,
                longitude: longitude,
                timestamp: Coordinates.timestamp(stamp)
            )
        }
    }
}

/// Picks the reader by looking at the file rather than trusting its name.
public enum TrackImport {
    public static func parse(_ text: String) throws -> [ImportedTrack] {
        let head = String(text.drop(while: { $0.isWhitespace }).prefix(200))
        if head.hasPrefix("{") || head.hasPrefix("[") {
            return try GoogleTimelineParser.parse(text)
        }
        if head.contains("<") {
            return try GpxParser.parse(text)
        }
        throw ImportError("Unrecognised file: expected a Timeline export or a GPX file.")
    }
}
