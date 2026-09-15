import Foundation

/**
 Reads a Google Maps Timeline export.

 Google has changed this file's shape several times - `locations` full of `latitudeE7` in the old
 Takeout dumps, `timelineObjects` in Semantic Location History, `semanticSegments` with `geo:`
 strings in the on-device export - and will change it again. So rather than binding to one schema
 this walks the tree looking for anything shaped like a coordinate, and treats any array holding
 two or more of them as a path. That reads all the known layouts and stands a fair chance with the
 next one.
 */
public enum GoogleTimelineParser {

    private static let latitudeKeys = ["latitudeE7", "latE7"]
    private static let longitudeKeys = ["longitudeE7", "lngE7", "lonE7"]
    private static let plainLatitudeKeys = ["latitude", "lat"]
    private static let plainLongitudeKeys = ["longitude", "lng", "lon"]
    private static let coordinateStringKeys = ["latLng", "latlng", "point", "location", "geo"]
    private static let timeKeys = ["timestamp", "timestampMs", "time", "startTime", "startTimestamp"]

    public static func parse(_ text: String) throws -> [ImportedTrack] {
        let root: JSONValue
        do {
            root = try JSONParser.parse(text)
        } catch {
            throw ImportError("This does not look like a Timeline export (\(error)).")
        }
        var tracks: [ImportedTrack] = []
        walk(root, into: &tracks)
        return tracks.filter { !$0.isEmpty }
    }

    private static func walk(_ element: JSONValue, into tracks: inout [ImportedTrack]) {
        switch element {
        case .array(let items):
            let points = items.compactMap { point(of: $0) }
            if points.count >= 2 {
                tracks.append(ImportedTrack(points: ordered(points)))
                // Children that were points are accounted for; anything else may still nest a path.
                for child in items where point(of: child) == nil { walk(child, into: &tracks) }
            } else {
                for child in items { walk(child, into: &tracks) }
            }

        case .object(let entries):
            if let pair = startEndPair(element) {
                // An activity records only where it began and ended; that is still a journey.
                tracks.append(ImportedTrack(points: pair))
            } else if let here = point(of: element) {
                // A visit is a single place, which uncovers where you stood.
                tracks.append(ImportedTrack(points: [here]))
            } else {
                for entry in entries { walk(entry.value, into: &tracks) }
            }

        default:
            break
        }
    }

    /// Points sort by time where every one of them has a time; otherwise file order is all there is.
    private static func ordered(_ points: [ImportedFix]) -> [ImportedFix] {
        guard points.allSatisfy({ $0.timestamp != nil }) else { return points }
        return points.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }

    private static func startEndPair(_ object: JSONValue) -> [ImportedFix]? {
        guard let startValue = object["start"], let start = point(of: startValue) else { return nil }
        guard let endValue = object["end"], let end = point(of: endValue) else { return nil }
        return [start, end]
    }

    private static func point(of element: JSONValue) -> ImportedFix? {
        if element.isString, let content = element.content {
            return Coordinates.fromString(content, timestamp: nil)
        }
        guard case .object = element else { return nil }

        let time = Coordinates.timestamp(firstContent(element, timeKeys))

        let latitudeE7 = firstLong(element, latitudeKeys)
        let longitudeE7 = firstLong(element, longitudeKeys)
        if let latitudeE7, let longitudeE7 {
            return Coordinates.fromE7(latitudeE7: latitudeE7, longitudeE7: longitudeE7, timestamp: time)
        }

        let latitude = firstDouble(element, plainLatitudeKeys)
        let longitude = firstDouble(element, plainLongitudeKeys)
        if let latitude, let longitude {
            return Coordinates.fix(latitude: latitude, longitude: longitude, timestamp: time)
        }

        // A nested coordinate string, which is how the on-device export writes every position.
        for key in coordinateStringKeys {
            guard let nested = element[key] else { continue }
            if nested.isString, let content = nested.content,
               let fix = Coordinates.fromString(content, timestamp: time) {
                return fix
            }
            if case .object = nested, let fix = point(of: nested) {
                return fix
            }
        }
        return nil
    }

    private static func firstContent(_ object: JSONValue, _ keys: [String]) -> String? {
        for key in keys {
            if let value = object[key], let content = value.content, !content.isEmpty { return content }
        }
        return nil
    }

    private static func firstLong(_ object: JSONValue, _ keys: [String]) -> Int64? {
        for key in keys {
            if let value = object[key]?.longValue { return value }
        }
        return nil
    }

    private static func firstDouble(_ object: JSONValue, _ keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key]?.doubleValue { return value }
        }
        return nil
    }
}
