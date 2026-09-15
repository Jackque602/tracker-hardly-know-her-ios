import Foundation

/**
 Epoch milliseconds to and from ISO-8601, done by hand.

 `DateFormatter` would do it, but building one costs more than the conversion and a GPX export
 runs to hundreds of thousands of points; and its answer depends on a locale and a calendar this
 has no business consulting. UTC civil dates are pure arithmetic, so here it is as arithmetic.
 */
public enum Instant {

    /// `2023-11-14T22:13:20Z`, with milliseconds only when there are any - matching ISO_INSTANT.
    public static func iso8601(epochMillis: Int64) -> String {
        var seconds = epochMillis / 1_000
        var millis = Int(epochMillis % 1_000)
        if millis < 0 {
            millis += 1_000
            seconds -= 1
        }
        var days = seconds / 86_400
        var secondOfDay = Int(seconds % 86_400)
        if secondOfDay < 0 {
            secondOfDay += 86_400
            days -= 1
        }
        let (year, month, day) = civilFromDays(days)
        let hour = secondOfDay / 3_600
        let minute = (secondOfDay % 3_600) / 60
        let second = secondOfDay % 60

        var text = pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
            + "T" + pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2)
        if millis != 0 { text += "." + pad(millis, 3) }
        return text + "Z"
    }

    /// Howard Hinnant's `civil_from_days`, which is exact for every date the Gregorian calendar has.
    static func civilFromDays(_ daysSinceEpoch: Int64) -> (year: Int, month: Int, day: Int) {
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return (Int(year + (month <= 2 ? 1 : 0)), Int(month), Int(day))
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(abs(value))
        let padding = String(repeating: "0", count: max(0, width - digits.count))
        return (value < 0 ? "-" : "") + padding + digits
    }
}
