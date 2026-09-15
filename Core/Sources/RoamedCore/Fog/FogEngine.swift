import Foundation

/**
 Turns raw GPS fixes into the set of grid cells they uncover.

 Two things happen here:
  - a fix uncovers every cell that its accuracy circle actually touches, not just the cell the
    point falls in, so standing still still clears a believable blob;
  - consecutive fixes are joined, so driving at 100 km/h with a fix every 20 s leaves a continuous
    ribbon instead of a dotted line.
 */
public struct FogEngine: Sendable {

    private let zoom: Int

    public init(zoom: Int = RevealZoom.z) {
        self.zoom = zoom
    }

    /// Metres per degree of latitude; the equirectangular approximation is exact enough at cell scale.
    private let metersPerDegreeLat = 111_320.0

    /**
     Every cell whose square overlaps the circle of `radiusMeters` around the fix.

     Results are added to `into` so callers can accumulate a whole segment without garbage.
     */
    public func cellsWithinRadius(
        _ lat: Double,
        _ lon: Double,
        _ radiusMeters: Double,
        into: inout Set<CellKeyValue>
    ) {
        let radius = max(1.0, radiusMeters)
        let centerLat = TileMath.clampLatitude(lat)
        let grid = TileMath.gridSize(zoom)

        let dLatDeg = radius / metersPerDegreeLat
        let cosLat = max(cos(TileMath.degToRad(centerLat)), 1e-6)
        let dLonDeg = min(180.0, radius / (metersPerDegreeLat * cosLat))

        // y grows southwards, so the northern edge yields the smaller row index.
        let yFrom = TileMath.cellY(centerLat + dLatDeg, zoom)
        let yTo = TileMath.cellY(centerLat - dLatDeg, zoom)

        let centerX = TileMath.lonToTileX(lon, zoom)
        let spanX = dLonDeg / 360.0 * Double(grid)
        var xFrom = Int((centerX - spanX).rounded(.down))
        var xTo = Int((centerX + spanX).rounded(.down))
        // Near the poles a modest radius spans an absurd number of columns; cap it.
        if xTo - xFrom > FogEngine.maxColumns {
            xFrom = Int(centerX.rounded(.down)) - FogEngine.maxColumns / 2
            xTo = xFrom + FogEngine.maxColumns
        }

        if yFrom <= yTo && xFrom <= xTo {
            let cellWidthDeg = 360.0 / Double(grid)
            for y in yFrom...yTo {
                if y < 0 || y >= grid { continue }
                let latNorth = TileMath.tileYToLat(Double(y), zoom)
                let latSouth = TileMath.tileYToLat(Double(y + 1), zoom)
                let dLatMeters: Double
                if lat > latNorth {
                    dLatMeters = (lat - latNorth) * metersPerDegreeLat
                } else if lat < latSouth {
                    dLatMeters = (latSouth - lat) * metersPerDegreeLat
                } else {
                    dLatMeters = 0.0
                }
                if dLatMeters > radius { continue }

                let nearestLat = min(max(lat, latSouth), latNorth)
                let metersPerDegreeLon =
                    metersPerDegreeLat * max(cos(TileMath.degToRad(nearestLat)), 1e-6)

                for x in xFrom...xTo {
                    let lonWest = TileMath.tileXToLon(Double(x), zoom)
                    let offset = FogEngine.signedLonDelta(lonWest, lon)
                    let dLonDegOff: Double
                    if offset < 0.0 {
                        dLonDegOff = -offset
                    } else if offset > cellWidthDeg {
                        dLonDegOff = offset - cellWidthDeg
                    } else {
                        dLonDegOff = 0.0
                    }
                    let dLonMeters = dLonDegOff * metersPerDegreeLon
                    if dLonMeters > radius { continue }
                    if (dLatMeters * dLatMeters + dLonMeters * dLonMeters).squareRoot() > radius {
                        continue
                    }
                    into.insert(CellKey.pack(TileMath.wrapX(x, zoom), y))
                }
            }
        }
        // A fix always uncovers at least the cell it sits in.
        if into.isEmpty {
            into.insert(CellKey.pack(TileMath.cellX(lon, zoom), TileMath.cellY(centerLat, zoom)))
        }
    }

    /// Convenience for callers with nothing to accumulate into.
    public func cellsWithinRadius(
        _ lat: Double, _ lon: Double, _ radiusMeters: Double
    ) -> Set<CellKeyValue> {
        var cells = Set<CellKeyValue>()
        cellsWithinRadius(lat, lon, radiusMeters, into: &cells)
        return cells
    }

    /**
     Cells uncovered by travelling in a straight line between two fixes.

     Adds nothing when the gap is longer than `maxGapMeters` - a jump that big is a flight, a
     tunnel or a GPS glitch, and painting a line across it would be a lie.
     */
    public func cellsAlongSegment(
        _ lat1: Double,
        _ lon1: Double,
        _ lat2: Double,
        _ lon2: Double,
        radiusMeters: Double,
        maxGapMeters: Double = FogEngine.defaultMaxGapMeters,
        into: inout Set<CellKeyValue>
    ) {
        let distance = Geo.distanceMeters(lat1, lon1, lat2, lon2)
        if distance > maxGapMeters { return }

        // Step at half the smaller of the reveal radius and the cell size so nothing is skipped.
        let cellWidth = TileMath.cellWidthMeters(TileMath.cellY(lat1, zoom), zoom)
        let step = max(5.0, min(radiusMeters, cellWidth) / 2.0)
        trace(
            lat1, lon1, lat2, lon2,
            radiusMeters: radiusMeters,
            stepMeters: step,
            maxSteps: FogEngine.maxInterpolationSteps,
            into: &into
        )
    }

    public func cellsAlongSegment(
        _ lat1: Double,
        _ lon1: Double,
        _ lat2: Double,
        _ lon2: Double,
        radiusMeters: Double,
        maxGapMeters: Double = FogEngine.defaultMaxGapMeters
    ) -> Set<CellKeyValue> {
        var cells = Set<CellKeyValue>()
        cellsAlongSegment(
            lat1, lon1, lat2, lon2,
            radiusMeters: radiusMeters, maxGapMeters: maxGapMeters, into: &cells
        )
        return cells
    }

    /**
     Cells uncovered by flying between two points.

     Separate from ``cellsAlongSegment(_:_:_:_:radiusMeters:maxGapMeters:into:)`` for two reasons.
     The obvious one is the limit: a flight is exactly the case that method refuses, and there is
     no useful cap short of half the planet. The other is the step. A ground segment steps every
     sixty metres, which is right for a road and would be a hundred thousand steps across the
     Atlantic; a flight steps by the reveal radius instead, so consecutive discs still overlap -
     the ribbon has no holes - at a fraction of the cost.

     ``Geo/interpolate(_:_:_:_:_:)`` walks the great circle, so the path bends the way a flight
     actually goes rather than running straight across the map: London to Los Angeles passes over
     Greenland, not over Newfoundland.
     */
    public func cellsAlongFlight(
        _ lat1: Double,
        _ lon1: Double,
        _ lat2: Double,
        _ lon2: Double,
        radiusMeters: Double,
        into: inout Set<CellKeyValue>
    ) {
        let step = max(25.0, radiusMeters)
        trace(
            lat1, lon1, lat2, lon2,
            radiusMeters: radiusMeters,
            stepMeters: step,
            maxSteps: FogEngine.maxFlightSteps,
            into: &into
        )
    }

    public func cellsAlongFlight(
        _ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double, radiusMeters: Double
    ) -> Set<CellKeyValue> {
        var cells = Set<CellKeyValue>()
        cellsAlongFlight(lat1, lon1, lat2, lon2, radiusMeters: radiusMeters, into: &cells)
        return cells
    }

    private func trace(
        _ lat1: Double,
        _ lon1: Double,
        _ lat2: Double,
        _ lon2: Double,
        radiusMeters: Double,
        stepMeters: Double,
        maxSteps: Int,
        into: inout Set<CellKeyValue>
    ) {
        cellsWithinRadius(lat1, lon1, radiusMeters, into: &into)
        cellsWithinRadius(lat2, lon2, radiusMeters, into: &into)
        let distance = Geo.distanceMeters(lat1, lon1, lat2, lon2)
        if distance < 1.0 { return }

        let steps = min(maxSteps, Int((distance / stepMeters).rounded(.up)))
        if steps < 2 { return }
        for i in 1..<steps {
            let p = Geo.interpolate(lat1, lon1, lat2, lon2, Double(i) / Double(steps))
            cellsWithinRadius(p.latitude, p.longitude, radiusMeters, into: &into)
        }
    }

    /// Signed shortest angular difference `to - from`, in degrees, within (-180, 180].
    private static func signedLonDelta(_ from: Double, _ to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360.0)
        if d > 180.0 { d -= 360.0 }
        if d < -180.0 { d += 360.0 }
        return d
    }

    /**
     Furthest apart two fixes can be and still have the road between them filled in.

     Three kilometres was far too tight: any dropout - a tunnel, a dead zone, a stretch where the
     fixes were too vague to keep - leaves a bigger hole than that, and refusing to bridge it turns
     a momentary lapse into a permanent gap in the map. Twenty-five km covers a realistic dropout
     while staying far below any flight, which shows up as a gap of hundreds of km and is still
     refused.
     */
    public static let defaultMaxGapMeters = 25_000.0
    private static let maxColumns = 4_096
    private static let maxInterpolationSteps = 4_000

    /// Enough for an antipodal flight at a 120 m reveal radius, with room to spare.
    private static let maxFlightSteps = 200_000
}

/// Speed above which a pair of fixes is treated as a glitch rather than travel (m/s ~ 1100 km/h).
public let implausibleSpeedMps = 305.0

/// True when moving between two fixes in `seconds` would be physically implausible.
public func isImplausibleJump(_ distanceMeters: Double, _ seconds: Double) -> Bool {
    seconds > 0.0 && distanceMeters / seconds > implausibleSpeedMps && abs(distanceMeters) > 1_000.0
}

/**
 Slowest a flight averages door to door, m/s (~324 km/h).

 The average has to survive taxiing, holding and the walk to baggage reclaim, so it sits far below
 cruising speed. It is still above every scheduled train on earth - the fastest average about
 270 km/h - which is what matters, because the alternative explanation for two distant fixes is
 always surface travel the tracker slept through.
 */
public let minFlightSpeedMps = 90.0

/// Below this, a fast surface journey is the likelier story whatever the arithmetic says.
public let minFlightDistanceMeters = 150_000.0

/**
 True when the only sane explanation for two consecutive fixes is that you flew between them.

 Deliberately hard to trigger. The cost of a false positive is high and permanent: it uncovers a
 great-circle ribbon hundreds of kilometres long across ground that was never visited. The
 ordinary competing explanation - the tracker was killed for an hour while you drove - fails the
 speed test comfortably, because an hour of driving covers a hundred kilometres, not a thousand.
 */
public func isFlight(_ distanceMeters: Double, _ seconds: Double) -> Bool {
    distanceMeters >= minFlightDistanceMeters
        && seconds > 0.0
        && !isImplausibleJump(distanceMeters, seconds)
        && distanceMeters / seconds >= minFlightSpeedMps
}

/**
 Ten minutes: long enough for a tunnel or a dead zone, short enough to still be one leg.

 Distance alone is not enough to decide. A gap can be short in kilometres and hours long, and over
 those hours the route between the two ends is anyone's guess - quite possibly a long way round
 that comes back.
 */
public let maxGapSeconds = 600.0

/**
 Whether two consecutive fixes are near enough, and soon enough, to be one unbroken leg.

 This is the single rule for "did we watch the whole way between these two points". The fog uses
 it to decide whether to uncover the ground between them, and the trail uses it to decide whether
 to draw a line between them - and those two must agree. A trail that draws a straight line across
 a gap the fog would not fill claims a route that was never recorded.
 */
public func isOneLeg(_ distanceMeters: Double, _ seconds: Double) -> Bool {
    distanceMeters <= FogEngine.defaultMaxGapMeters && seconds <= maxGapSeconds
}
