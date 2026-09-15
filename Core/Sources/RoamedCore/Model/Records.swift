import Foundation

/// One uncovered cell, as it travels between the database, backups and the map.
public struct CellRecord: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let firstSeen: Int64
    public let lastSeen: Int64
    public let visits: Int
    public let source: CellSource

    public init(
        x: Int,
        y: Int,
        firstSeen: Int64,
        lastSeen: Int64,
        visits: Int,
        source: CellSource = .ground
    ) {
        self.x = x
        self.y = y
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.visits = visits
        self.source = source
    }
}

/// One recorded GPS fix.
public struct TrackPointRecord: Equatable, Sendable {
    public let timestamp: Int64
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let accuracy: Double?
    public let speed: Double?

    public init(
        timestamp: Int64,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        accuracy: Double? = nil,
        speed: Double? = nil
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.speed = speed
    }
}
