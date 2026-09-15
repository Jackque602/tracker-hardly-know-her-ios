import Foundation
import os

/// One place for the handful of things worth knowing went wrong, and nothing that leaves the phone.
enum RoamedLog {
    private static let logger = Logger(subsystem: "dev.jackque.roamed", category: "roamed")

    static func warn(_ message: String, _ error: Error? = nil) {
        if let error {
            logger.warning("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            logger.warning("\(message, privacy: .public)")
        }
    }
}

/**
 Local calendar dates, as the `daily_stat` table keys them.

 Deliberately the device's own time zone rather than UTC: "days out and about" means days as you
 lived them, and a 9pm walk in California is not the next day.
 */
enum LocalDate {

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let lock = NSLock()

    static func of(epochMillis: Int64) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: Date(timeIntervalSince1970: Double(epochMillis) / 1000.0))
    }

    static func today() -> String {
        of(epochMillis: Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// The first of January, as a key the `date >= ?` query can compare against.
    static func startOfYear(_ now: Date = Date()) -> String {
        let year = Calendar.current.component(.year, from: now)
        return String(format: "%04d-01-01", year)
    }
}
