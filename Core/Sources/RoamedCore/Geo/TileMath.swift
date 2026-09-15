import Foundation

/**
 Web-Mercator ("slippy tile") maths.

 The fog of war is stored as a set of square cells taken from the standard tile grid at
 ``RevealZoom/z``. Everything the app knows about "where you have been" is expressed in that grid,
 so all conversions live here and nowhere else.
 */
public enum TileMath {

    /// Latitude beyond which Web Mercator is undefined.
    public static let maxLatitude = 85.05112877980659

    /// Mean Earth radius (IUGG), metres.
    public static let earthRadiusMeters = 6_371_008.8

    /// Total surface of the Earth, m^2.
    public static let earthSurfaceAreaM2 = 5.10072e14

    /// Land surface of the Earth (148.94 million km^2), m^2.
    public static let earthLandAreaM2 = 1.4894e14

    @inlinable
    public static func degToRad(_ deg: Double) -> Double { deg * .pi / 180.0 }

    @inlinable
    public static func radToDeg(_ rad: Double) -> Double { rad * 180.0 / .pi }

    @inlinable
    public static func clampLatitude(_ lat: Double) -> Double {
        min(max(lat, -maxLatitude), maxLatitude)
    }

    /// Wraps a longitude into [-180, 180).
    public static func normalizeLongitude(_ lon: Double) -> Double {
        if lon >= -180.0 && lon < 180.0 { return lon }
        var l = (lon + 180.0).truncatingRemainder(dividingBy: 360.0)
        if l < 0 { l += 360.0 }
        return l - 180.0
    }

    /// Number of cells along one axis at `zoom`.
    @inlinable
    public static func gridSize(_ zoom: Int) -> Int { 1 << zoom }

    public static func lonToTileX(_ lon: Double, _ zoom: Int) -> Double {
        (normalizeLongitude(lon) + 180.0) / 360.0 * Double(gridSize(zoom))
    }

    public static func latToTileY(_ lat: Double, _ zoom: Int) -> Double {
        let rad = degToRad(clampLatitude(lat))
        let y = log(tan(rad) + 1.0 / cos(rad))
        return (1.0 - y / .pi) / 2.0 * Double(gridSize(zoom))
    }

    public static func tileXToLon(_ x: Double, _ zoom: Int) -> Double {
        x / Double(gridSize(zoom)) * 360.0 - 180.0
    }

    public static func tileYToLat(_ y: Double, _ zoom: Int) -> Double {
        let n = Double.pi * (1.0 - 2.0 * y / Double(gridSize(zoom)))
        return radToDeg(atan(sinh(n)))
    }

    /// Column of the cell containing `lon`; always inside the grid.
    public static func cellX(_ lon: Double, _ zoom: Int) -> Int {
        let maxIndex = gridSize(zoom) - 1
        return min(max(Int(lonToTileX(lon, zoom).rounded(.down)), 0), maxIndex)
    }

    /// Row of the cell containing `lat`; always inside the grid.
    public static func cellY(_ lat: Double, _ zoom: Int) -> Int {
        let maxIndex = gridSize(zoom) - 1
        return min(max(Int(latToTileY(lat, zoom).rounded(.down)), 0), maxIndex)
    }

    /// Wraps a column index around the antimeridian instead of clamping it.
    public static func wrapX(_ x: Int, _ zoom: Int) -> Int {
        let n = gridSize(zoom)
        let m = x % n
        return m < 0 ? m + n : m
    }

    /**
     Exact spherical area of a single cell, m^2.

     A Mercator cell is a lat/lon rectangle, so its area on a sphere is
     `dLon * R^2 * (sin(latNorth) - sin(latSouth))`. Cells only vary with their row, which is what
     makes ``areaOfRow(_:_:)`` cheap to memoise.
     */
    public static func areaOfRow(_ y: Int, _ zoom: Int) -> Double {
        let latNorth = degToRad(tileYToLat(Double(y), zoom))
        let latSouth = degToRad(tileYToLat(Double(y + 1), zoom))
        let dLon = 2.0 * Double.pi / Double(gridSize(zoom))
        return abs(dLon * earthRadiusMeters * earthRadiusMeters * (sin(latNorth) - sin(latSouth)))
    }

    /// Approximate east-west size of a cell in that row, metres.
    public static func cellWidthMeters(_ y: Int, _ zoom: Int) -> Double {
        let latCenter = (tileYToLat(Double(y), zoom) + tileYToLat(Double(y + 1), zoom)) / 2.0
        return 2.0 * Double.pi * earthRadiusMeters * cos(degToRad(latCenter)) / Double(gridSize(zoom))
    }
}

/**
 The zoom level the fog grid is stored at.

 At z17 a cell is roughly 305 m across at the equator and 195 m at 50 deg latitude - fine enough
 that a walk around a neighbourhood carves a recognisable shape, coarse enough that a decade of
 tracking stays in the low hundreds of thousands of rows.

 Changing this invalidates every stored cell, so it is a constant rather than a setting.
 */
public enum RevealZoom {
    public static let z = 17
}
