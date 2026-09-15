import Foundation

/// Derived numbers for the stats screen. Pure functions, so they are easy to trust and to test.
public enum ExplorationStats {

    public static func percentOfEarthSurface(_ areaSquareMeters: Double) -> Double {
        areaSquareMeters / TileMath.earthSurfaceAreaM2 * 100.0
    }

    public static func percentOfEarthLand(_ areaSquareMeters: Double) -> Double {
        areaSquareMeters / TileMath.earthLandAreaM2 * 100.0
    }

    public static func squareKilometers(_ areaSquareMeters: Double) -> Double {
        areaSquareMeters / 1_000_000.0
    }

    /**
     Renders a percentage that is usually tiny without collapsing it to "0%".

     A lifetime of travel covers a rounding error of the planet, and showing that as zero is the
     fastest way to make the number feel broken - so the precision grows as the value shrinks.
     */
    public static func formatPercent(_ percent: Double) -> String {
        switch percent {
        case ...0.0: return "0%"
        case 10.0...: return fixed(percent, 1) + "%"
        case 1.0...: return fixed(percent, 2) + "%"
        case 0.01...: return fixed(percent, 3) + "%"
        case 0.0001...: return fixed(percent, 5) + "%"
        case 0.000001...: return fixed(percent, 7) + "%"
        default: return "<0.000001%"
        }
    }

    public static func formatArea(_ areaSquareMeters: Double) -> String {
        let km2 = squareKilometers(areaSquareMeters)
        if km2 >= 1_000.0 { return fixed(km2, 0) + " km²" }
        if km2 >= 10.0 { return fixed(km2, 1) + " km²" }
        if km2 >= 0.01 { return fixed(km2, 2) + " km²" }
        return fixed(areaSquareMeters / 10_000.0, 2) + " ha"
    }

    public static func formatDistance(_ meters: Double) -> String {
        if meters >= 100_000 { return fixed(meters / 1_000.0, 0) + " km" }
        if meters >= 1_000 { return fixed(meters / 1_000.0, 1) + " km" }
        return fixed(meters, 0) + " m"
    }

    /**
     Fixed-point with trailing zeros trimmed, so "0.00100" reads as "0.001", and thousands grouped,
     because a continent measured in square kilometres is otherwise eight bare digits.

     Grouping is inserted by hand rather than through a `NumberFormatter`: these strings are part
     of what the tests pin down, and a formatter would quietly re-punctuate them in a French or
     German locale. The numbers are not prose - "1,234 km" stays "1,234 km".
     */
    private static func fixed(_ value: Double, _ decimals: Int) -> String {
        // String(format:) is deliberately locale-independent, so "." is always the point.
        var text = String(format: "%.\(decimals)f", value)

        var sign = ""
        if text.hasPrefix("-") {
            sign = "-"
            text.removeFirst()
        }

        let pieces = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerDigits = Array(pieces[0])
        let fraction = pieces.count > 1 ? String(pieces[1]) : ""

        var grouped = ""
        for (offset, character) in integerDigits.reversed().enumerated() {
            if offset > 0 && offset % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        var result = sign + String(grouped.reversed())

        if !fraction.isEmpty {
            result += "." + fraction
            while result.hasSuffix("0") { result.removeLast() }
            if result.hasSuffix(".") { result.removeLast() }
        }
        return result
    }
}
