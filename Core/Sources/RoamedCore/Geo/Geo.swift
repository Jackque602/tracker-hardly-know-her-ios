import Foundation

/// Great-circle helpers shared by the tracker and the stats screen.
public enum Geo {

    /// Great-circle distance between two points, metres.
    public static func distanceMeters(
        _ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double
    ) -> Double {
        let dLat = TileMath.degToRad(lat2 - lat1)
        let dLon = TileMath.degToRad(lon2 - lon1)
        let sinLat = sin(dLat / 2)
        let sinLon = sin(dLon / 2)
        let a = sinLat * sinLat
            + cos(TileMath.degToRad(lat1)) * cos(TileMath.degToRad(lat2)) * sinLon * sinLon
        return 2.0 * TileMath.earthRadiusMeters * asin(min(1.0, a.squareRoot()))
    }

    /// Point `fraction` of the way along the great circle from point 1 to point 2.
    public static func interpolate(
        _ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double, _ fraction: Double
    ) -> (latitude: Double, longitude: Double) {
        let phi1 = TileMath.degToRad(lat1)
        let lambda1 = TileMath.degToRad(lon1)
        let phi2 = TileMath.degToRad(lat2)
        let lambda2 = TileMath.degToRad(lon2)

        let d = distanceMeters(lat1, lon1, lat2, lon2) / TileMath.earthRadiusMeters
        if d < 1e-12 { return (lat1, lon1) }

        let a = sin((1 - fraction) * d) / sin(d)
        let b = sin(fraction * d) / sin(d)
        let x = a * cos(phi1) * cos(lambda1) + b * cos(phi2) * cos(lambda2)
        let y = a * cos(phi1) * sin(lambda1) + b * cos(phi2) * sin(lambda2)
        let z = a * sin(phi1) + b * sin(phi2)
        return (
            TileMath.radToDeg(atan2(z, (x * x + y * y).squareRoot())),
            TileMath.radToDeg(atan2(y, x))
        )
    }
}
