import Foundation

/**
 A lat/lon rectangle.

 `east` is allowed to be numerically smaller than `west`: that is how a box which runs off the
 eastern edge of the map and back in from the west is expressed, and it is the correct shape for
 anyone who has been to both sides of the Pacific.
 */
public struct GeoBounds: Equatable, Sendable {
    public let north: Double
    public let south: Double
    public let west: Double
    public let east: Double

    public init(north: Double, south: Double, west: Double, east: Double) {
        self.north = north
        self.south = south
        self.west = west
        self.east = east
    }

    /// True when the box wraps past +180 and continues from -180.
    public var crossesAntimeridian: Bool { east < west }

    /// Width in degrees, measured the way the box actually runs.
    public var longitudeSpan: Double {
        crossesAntimeridian ? (east + 360.0) - west : east - west
    }

    public var latitudeSpan: Double { north - south }

    public var centerLatitude: Double { (north + south) / 2.0 }

    /// Middle of the box the way the box actually runs, so a wrapped box centres on the Pacific.
    public var centerLongitude: Double {
        TileMath.normalizeLongitude(west + longitudeSpan / 2.0)
    }
}
