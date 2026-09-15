import Foundation

/// Shared coordinate and timestamp parsing for the import formats.
enum Coordinates {

    private static let geoUri = try! NSRegularExpression(
        pattern: #"geo:\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)"#
    )
    private static let degreePair = try! NSRegularExpression(
        pattern: #"(-?\d+(?:\.\d+)?)\s*°?\s*,\s*(-?\d+(?:\.\d+)?)\s*°?"#
    )

    /**
     Builds a fix, rejecting anything off the globe.

     Exactly (0, 0) is refused too: it is in the Atlantic where nobody has been, and it is what
     every one of these formats leaves behind when a coordinate is missing.
     */
    static func fix(latitude: Double, longitude: Double, timestamp: Int64?) -> ImportedFix? {
        if latitude.isNaN || longitude.isNaN { return nil }
        if latitude < -90.0 || latitude > 90.0 { return nil }
        if longitude < -180.0 || longitude > 180.0 { return nil }
        if latitude == 0.0 && longitude == 0.0 { return nil }
        return ImportedFix(latitude: latitude, longitude: longitude, timestamp: timestamp)
    }

    /// Google stores degrees as integers scaled by ten million.
    static func fromE7(latitudeE7: Int64, longitudeE7: Int64, timestamp: Int64?) -> ImportedFix? {
        fix(latitude: Double(latitudeE7) / 1e7, longitude: Double(longitudeE7) / 1e7, timestamp: timestamp)
    }

    /// Handles both `geo:40.1,-75.2` and `40.1°, -75.2°`, the two shapes Timeline uses.
    static func fromString(_ value: String, timestamp: Int64?) -> ImportedFix? {
        for expression in [geoUri, degreePair] {
            let range = NSRange(value.startIndex..., in: value)
            guard let match = expression.firstMatch(in: value, range: range),
                  let latitude = capture(match, 1, in: value).flatMap(Double.init),
                  let longitude = capture(match, 2, in: value).flatMap(Double.init)
            else { continue }
            return fix(latitude: latitude, longitude: longitude, timestamp: timestamp)
        }
        return nil
    }

    static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    /**
     Rescales a bare epoch to milliseconds.

     Exports disagree about the unit - Life360 and plenty of others count in seconds, Google in
     milliseconds - and taking seconds at face value dates the whole trip to 1970, which silently
     lands every imported cell outside the years the stats screen knows about. The magnitudes are
     far enough apart to tell without ambiguity: a present-day epoch is ~1.8e9 in seconds, ~1.8e12
     in milliseconds and ~1.8e15 in microseconds.
     */
    private static func normaliseEpoch(_ raw: Int64) -> Int64 {
        if abs(raw) < 100_000_000_000 { return raw * 1_000 }
        if abs(raw) > 100_000_000_000_000 { return raw / 1_000 }
        return raw
    }

    /// ISO-8601 in any of its offsets, or a bare epoch in seconds, milliseconds or microseconds.
    static func timestamp(_ value: String?) -> Int64? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let raw = Int64(value) { return normaliseEpoch(raw) }
        return IsoDate.parse(value)
    }
}

/// ISO-8601 with or without fractional seconds, and with any offset, including `Z`.
enum IsoDate {

    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let lock = NSLock()

    static func parse(_ value: String) -> Int64? {
        // ISO8601DateFormatter is not documented as thread-safe, and imports run off the main
        // actor alongside live tracking, so the two shared formatters are guarded.
        lock.lock()
        defer { lock.unlock() }
        if let date = withFraction.date(from: value) ?? withoutFraction.date(from: value) {
            return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
        }
        return nil
    }
}
