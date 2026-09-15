import Foundation

/// One position from an imported file. Timestamps are optional; plenty of exports omit them.
public struct ImportedFix: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Int64?

    public init(latitude: Double, longitude: Double, timestamp: Int64?) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }
}

/**
 An ordered run of positions that belong together.

 Tracks matter because only points *within* one may be joined up. Two consecutive entries in a year
 of location history can be a continent apart; drawing a line between them would invent a journey
 that never happened.
 */
public struct ImportedTrack: Equatable, Sendable {
    public let points: [ImportedFix]
    /**
     True when the source states these points form one continuous path, as a GPX track segment or
     route does. Recorded history carries no such promise - consecutive entries there can be hours
     and continents apart - so points from those sources are only joined when they are near enough
     in time and space to have plausibly been travelled straight through.

     It matters most for a route exported turn-by-turn: two waypoints either end of a long motorway
     stretch can be fifty kilometres apart and still be one unbroken drive.
     */
    public let contiguous: Bool

    public init(points: [ImportedFix], contiguous: Bool = false) {
        self.points = points
        self.contiguous = contiguous
    }

    public var isEmpty: Bool { points.isEmpty }
}

public struct ImportError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var localizedDescription: String { message }
}
