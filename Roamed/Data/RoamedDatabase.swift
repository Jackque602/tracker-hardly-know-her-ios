import Foundation
import RoamedCore

/// One uncovered square of the world, as it sits in the database.
struct ExploredCellRow: Sendable {
    let x: Int
    let y: Int
    let firstSeen: Int64
    let lastSeen: Int64
    let visits: Int
    let source: Int
}

/// A raw GPS fix. Kept for the trail overlay and GPX export; prunable without losing the fog.
struct TrackPointRow: Sendable {
    let timestamp: Int64
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let accuracy: Double?
    let speed: Double?
}

/**
 Per-day totals.

 These are the durable record: raw fixes get pruned, but distance travelled and places discovered
 are rolled up here first, so the lifetime numbers never quietly shrink.
 */
struct DailyStatRow: Identifiable, Sendable {
    /// Local date, ISO-8601 (`2026-09-01`).
    let date: String
    let distanceMeters: Double
    let newCells: Int

    var id: String { date }
}

/// A country or region that has been entered at least once.
struct VisitedPlaceRow: Identifiable, Sendable {
    let countryCode: String
    let countryName: String
    let adminArea: String
    let firstSeen: Int64
    let lastSeen: Int64

    var id: String { countryCode + "/" + adminArea }
}

struct YearCount: Identifiable, Sendable {
    let year: String
    let count: Int

    var id: String { year }
}

/**
 The store, and every query the app asks of it.

 The schema is the Android build's, column for column, so a backup written by either app restores
 into the other. `user_version` carries the same numbering, which is why it starts at 2: version 1
 is the schema before flights were told apart from ground travel, and the migration to add that
 column is written out rather than dropping the table - the fog is the whole of what this app is.
 */
final class RoamedDatabase: @unchecked Sendable {

    static let name = "roamed.sqlite"
    private static let schemaVersion = 2

    private let db: SQLiteDatabase

    init(url: URL) throws {
        db = try SQLiteDatabase(url: url)
        try migrate()
    }

    /// A store that lives only as long as the app does. The fallback when the real one will not open.
    init(inMemory: Bool) throws {
        db = try SQLiteDatabase(path: ":memory:")
        try migrate()
    }

    static func defaultURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return directory.appendingPathComponent(name)
    }

    private func migrate() throws {
        let existing = db.userVersion
        if existing == 0 {
            try db.execute(
                """
                CREATE TABLE IF NOT EXISTS explored_cell (
                    x INTEGER NOT NULL,
                    y INTEGER NOT NULL,
                    firstSeen INTEGER NOT NULL,
                    lastSeen INTEGER NOT NULL,
                    visits INTEGER NOT NULL,
                    source INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (x, y)
                );
                CREATE INDEX IF NOT EXISTS index_explored_cell_firstSeen ON explored_cell (firstSeen);
                CREATE INDEX IF NOT EXISTS index_explored_cell_source ON explored_cell (source);

                CREATE TABLE IF NOT EXISTS track_point (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp INTEGER NOT NULL,
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL,
                    altitude REAL,
                    accuracy REAL,
                    speed REAL
                );
                CREATE INDEX IF NOT EXISTS index_track_point_timestamp ON track_point (timestamp);

                CREATE TABLE IF NOT EXISTS daily_stat (
                    date TEXT NOT NULL PRIMARY KEY,
                    distanceMeters REAL NOT NULL,
                    newCells INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS visited_place (
                    countryCode TEXT NOT NULL,
                    countryName TEXT NOT NULL,
                    adminArea TEXT NOT NULL,
                    firstSeen INTEGER NOT NULL,
                    lastSeen INTEGER NOT NULL,
                    PRIMARY KEY (countryCode, adminArea)
                );
                """
            )
            try db.setUserVersion(RoamedDatabase.schemaVersion)
            return
        }
        if existing < 2 {
            // Adds the column that says whether a cell was travelled or flown over. Written out
            // rather than recreating the table, because that would delete every square uncovered.
            try db.execute("ALTER TABLE explored_cell ADD COLUMN source INTEGER NOT NULL DEFAULT 0")
            try db.execute(
                "CREATE INDEX IF NOT EXISTS index_explored_cell_source ON explored_cell (source)"
            )
            try db.setUserVersion(2)
        }
    }

    // MARK: - Explored cells

    func loadAllCells() throws -> [ExploredCellRow] {
        var rows: [ExploredCellRow] = []
        try db.query("SELECT x, y, firstSeen, lastSeen, visits, source FROM explored_cell") { row in
            rows.append(
                ExploredCellRow(
                    x: row.int(0), y: row.int(1), firstSeen: row.int64(2),
                    lastSeen: row.int64(3), visits: row.int(4), source: row.int(5)
                )
            )
        }
        return rows
    }

    func cellCount() throws -> Int {
        try db.scalar("SELECT COUNT(*) FROM explored_cell")?.intValue ?? 0
    }

    /// New cells only; an existing cell keeps its original firstSeen.
    func insertNewCells(_ cells: [ExploredCellRow]) throws {
        guard !cells.isEmpty else { return }
        try db.transaction {
            for cell in cells {
                try db.run(
                    """
                    INSERT OR IGNORE INTO explored_cell (x, y, firstSeen, lastSeen, visits, source)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .int(cell.x), .int(cell.y), .integer(cell.firstSeen),
                        .integer(cell.lastSeen), .int(cell.visits), .int(cell.source),
                    ]
                )
            }
        }
    }

    func markVisited(x: Int, y: Int, now: Int64) throws {
        try db.run(
            "UPDATE explored_cell SET lastSeen = ?, visits = visits + 1 WHERE x = ? AND y = ?",
            [.integer(now), .int(x), .int(y)]
        )
    }

    /**
     Reclassifies cells.

     Used to promote squares from flown-over to travelled the first time you actually go there.
     The reverse never happens: flying over somewhere you have already walked tells you nothing new
     about it, and must not take the credit for it away.
     */
    func setSource(_ source: Int, for keys: [CellKeyValue]) throws {
        guard !keys.isEmpty else { return }
        try db.transaction {
            for key in keys {
                try db.run(
                    "UPDATE explored_cell SET source = ? WHERE x = ? AND y = ?",
                    [.int(source), .int(CellKey.x(key)), .int(CellKey.y(key))]
                )
            }
        }
    }

    func newCellsPerYear() throws -> [YearCount] {
        var rows: [YearCount] = []
        try db.query(
            """
            SELECT strftime('%Y', firstSeen / 1000, 'unixepoch', 'localtime') AS year, COUNT(*) AS count
            FROM explored_cell
            WHERE firstSeen > 0
            GROUP BY year
            ORDER BY year DESC
            """
        ) { row in
            rows.append(YearCount(year: row.text(0), count: row.int(1)))
        }
        return rows
    }

    func cellPage(limit: Int, offset: Int) throws -> [ExploredCellRow] {
        var rows: [ExploredCellRow] = []
        try db.query(
            "SELECT x, y, firstSeen, lastSeen, visits, source FROM explored_cell ORDER BY y, x LIMIT ? OFFSET ?",
            [.int(limit), .int(offset)]
        ) { row in
            rows.append(
                ExploredCellRow(
                    x: row.int(0), y: row.int(1), firstSeen: row.int64(2),
                    lastSeen: row.int64(3), visits: row.int(4), source: row.int(5)
                )
            )
        }
        return rows
    }

    // MARK: - Track points

    func insertTrackPoint(_ point: TrackPointRow) throws {
        try db.run(
            """
            INSERT INTO track_point (timestamp, latitude, longitude, altitude, accuracy, speed)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .integer(point.timestamp), .real(point.latitude), .real(point.longitude),
                .optionalReal(point.altitude), .optionalReal(point.accuracy), .optionalReal(point.speed),
            ]
        )
    }

    /// Newest first, so a limit keeps the most recent fixes rather than the oldest ones.
    func newestTrackPoints(since: Int64, limit: Int) throws -> [TrackPointRow] {
        var rows: [TrackPointRow] = []
        try db.query(
            """
            SELECT timestamp, latitude, longitude, altitude, accuracy, speed FROM track_point
            WHERE timestamp >= ? ORDER BY timestamp DESC LIMIT ?
            """,
            [.integer(since), .int(limit)]
        ) { row in
            rows.append(
                TrackPointRow(
                    timestamp: row.int64(0), latitude: row.double(1), longitude: row.double(2),
                    altitude: row.optionalDouble(3), accuracy: row.optionalDouble(4),
                    speed: row.optionalDouble(5)
                )
            )
        }
        return rows
    }

    func trackPointPage(limit: Int, offset: Int) throws -> [TrackPointRow] {
        var rows: [TrackPointRow] = []
        try db.query(
            """
            SELECT timestamp, latitude, longitude, altitude, accuracy, speed FROM track_point
            ORDER BY timestamp ASC LIMIT ? OFFSET ?
            """,
            [.int(limit), .int(offset)]
        ) { row in
            rows.append(
                TrackPointRow(
                    timestamp: row.int64(0), latitude: row.double(1), longitude: row.double(2),
                    altitude: row.optionalDouble(3), accuracy: row.optionalDouble(4),
                    speed: row.optionalDouble(5)
                )
            )
        }
        return rows
    }

    func trackPointCount() throws -> Int {
        try db.scalar("SELECT COUNT(*) FROM track_point")?.intValue ?? 0
    }

    @discardableResult
    func deleteTrackPointsOlderThan(_ cutoff: Int64) throws -> Int {
        try db.run("DELETE FROM track_point WHERE timestamp < ?", [.integer(cutoff)])
    }

    // MARK: - Daily stats

    /// Update-then-insert inside one transaction, so no other writer can slip a row in between.
    func addToDay(_ date: String, distanceMeters: Double, newCells: Int) throws {
        try db.transaction {
            let updated = try db.run(
                """
                UPDATE daily_stat
                SET distanceMeters = distanceMeters + ?, newCells = newCells + ?
                WHERE date = ?
                """,
                [.real(distanceMeters), .int(newCells), .text(date)]
            )
            if updated == 0 {
                try db.run(
                    "INSERT OR IGNORE INTO daily_stat (date, distanceMeters, newCells) VALUES (?, ?, ?)",
                    [.text(date), .real(distanceMeters), .int(newCells)]
                )
            }
        }
    }

    func totalDistance() throws -> Double {
        try db.scalar("SELECT COALESCE(SUM(distanceMeters), 0) FROM daily_stat")?.doubleValue ?? 0
    }

    func distanceSince(_ fromDate: String) throws -> Double {
        try db.scalar(
            "SELECT COALESCE(SUM(distanceMeters), 0) FROM daily_stat WHERE date >= ?",
            [.text(fromDate)]
        )?.doubleValue ?? 0
    }

    func activeDays() throws -> Int {
        try db.scalar(
            "SELECT COUNT(*) FROM daily_stat WHERE distanceMeters > 0 OR newCells > 0"
        )?.intValue ?? 0
    }

    func recentDays(limit: Int) throws -> [DailyStatRow] {
        var rows: [DailyStatRow] = []
        try db.query(
            "SELECT date, distanceMeters, newCells FROM daily_stat ORDER BY date DESC LIMIT ?",
            [.int(limit)]
        ) { row in
            rows.append(DailyStatRow(date: row.text(0), distanceMeters: row.double(1), newCells: row.int(2)))
        }
        return rows
    }

    func firstDate() throws -> String? {
        try db.scalar("SELECT MIN(date) FROM daily_stat")?.textValue
    }

    // MARK: - Visited places

    func recordPlace(_ place: VisitedPlaceRow) throws {
        try db.transaction {
            let touched = try db.run(
                "UPDATE visited_place SET lastSeen = ? WHERE countryCode = ? AND adminArea = ?",
                [.integer(place.lastSeen), .text(place.countryCode), .text(place.adminArea)]
            )
            if touched == 0 {
                try db.run(
                    """
                    INSERT OR IGNORE INTO visited_place
                        (countryCode, countryName, adminArea, firstSeen, lastSeen)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .text(place.countryCode), .text(place.countryName), .text(place.adminArea),
                        .integer(place.firstSeen), .integer(place.lastSeen),
                    ]
                )
            }
        }
    }

    func allPlaces() throws -> [VisitedPlaceRow] {
        var rows: [VisitedPlaceRow] = []
        try db.query(
            """
            SELECT countryCode, countryName, adminArea, firstSeen, lastSeen FROM visited_place
            ORDER BY countryName, adminArea
            """
        ) { row in
            rows.append(
                VisitedPlaceRow(
                    countryCode: row.text(0), countryName: row.text(1), adminArea: row.text(2),
                    firstSeen: row.int64(3), lastSeen: row.int64(4)
                )
            )
        }
        return rows
    }

    func countryCount() throws -> Int {
        try db.scalar("SELECT COUNT(DISTINCT countryCode) FROM visited_place")?.intValue ?? 0
    }

    // MARK: - Wholesale

    func deleteEverything() throws {
        try db.transaction {
            try db.execute("DELETE FROM explored_cell")
            try db.execute("DELETE FROM track_point")
            try db.execute("DELETE FROM daily_stat")
            try db.execute("DELETE FROM visited_place")
        }
    }
}

extension RoamedDatabase {
    /**
     Last resort when even an in-memory store will not open.

     SQLite failing to create a database in RAM means something is very wrong with the process, but
     crashing on launch tells the owner nothing useful. This keeps the app up so the message about
     storage can actually be read.
     */
    static func unusable() -> RoamedDatabase {
        // A second attempt on a private temporary file; if that fails too there is nowhere left to go.
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("roamed-fallback-\(UUID().uuidString).sqlite")
        return try! RoamedDatabase(url: fallback)
    }
}
