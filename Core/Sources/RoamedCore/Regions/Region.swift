import Foundation

/**
 What kind of thing a ``Region`` is. They form a strict hierarchy, each one inside the last.

 The first three come from `regions.bin`, which the Android build reads byte for byte and whose
 reader rejects kinds it does not know. So the last two never appear in that file: counties and
 cities ship as their own atlases, at their own resolutions, and are joined to a state by its
 code rather than by a region number.
 */
public enum RegionKind: Int, CaseIterable, Sendable {
    case continent = 0
    case country = 1
    case subdivision = 2
    case county = 3
    case city = 4

    /// True for the tiers that live in a detail atlas rather than in `regions.bin`.
    public var isLocality: Bool { self == .county || self == .city }
}

/**
 One named piece of the world.

 `areaSquareMeters` is the true geodesic area of the region's boundary, not the area of the
 squares the mask happens to give it. That distinction matters: the mask is several kilometres
 across, so measuring a small region against its own squares would call it fully explored the
 moment you clipped a corner of it.
 */
public struct Region: Equatable, Sendable, Identifiable {
    public static let none = -1

    public let id: Int
    public let kind: RegionKind
    /// The country a subdivision belongs to, the continent a country belongs to, else ``none``.
    public let parentId: Int
    /// ISO code where one exists (`US-PA`, `FR`), otherwise the region's own name.
    public let code: String
    public let name: String
    public let areaSquareMeters: Double

    public init(
        id: Int,
        kind: RegionKind,
        parentId: Int,
        code: String,
        name: String,
        areaSquareMeters: Double
    ) {
        self.id = id
        self.kind = kind
        self.parentId = parentId
        self.code = code
        self.name = name
        self.areaSquareMeters = areaSquareMeters
    }
}
