import Foundation
import Combine
import RoamedCore

/// A single GPS fix, stripped of CoreLocation types so the pipeline stays testable.
struct Fix: Equatable, Sendable {
    let timestamp: Int64
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let altitude: Double?
    let speed: Double?
}

/// What the map needs to know, recomputed whenever the fog changes.
struct FogState: Equatable, Sendable {
    var loaded = false
    var version: Int64 = 0
    var cellCount = 0
    var areaSquareMeters = 0.0
    var lastFix: Fix?
}

/// What an import of someone else's track file actually added.
struct TrackImportResult: Sendable {
    let trackCount: Int
    let pointCount: Int
    let newCells: Int
}

enum RecordOutcome: Sendable {
    /// The fix was too vague to trust.
    case rejected(reason: String)
    case recorded(newCells: Int, distanceMeters: Double)
}

struct ExplorationSummary: Sendable {
    var cellCount = 0
    var areaSquareMeters = 0.0
    /// Of `areaSquareMeters`, the part only ever flown over.
    var flownSquareMeters = 0.0
    var percentOfSurface = 0.0
    var percentOfLand = 0.0
    var totalDistanceMeters = 0.0
    var distanceThisYearMeters = 0.0
    var activeDays = 0
    var firstDate: String?
    var countryCount = 0
    var places: [VisitedPlaceRow] = []
    var newCellsPerYear: [YearCount] = []
    var recentDays: [DailyStatRow] = []
    var rawFixCount = 0
}

/**
 The single place where "a GPS fix arrived" turns into "more of the world is uncovered".

 Holds the authoritative in-memory ``ExploredIndex`` and keeps the database in step with it. An
 actor rather than a lock: fixes arrive from CoreLocation while the map reads the index and the
 stats screen recomputes, and serialising every mutation through one place is what keeps the two
 indexes and the database telling the same story. The indexes themselves are thread-safe and
 handed out directly, because the map overlay reads them sixty times a second and must not have to
 wait on an import.
 */
actor ExplorationRepository {

    nonisolated let index = ExploredIndex()

    /**
     The subset of ``index`` that has only ever been flown over.

     A separate index rather than a flag on each cell, because everything that reads the fog - the
     overlay's viewport query, the running area, the fit-to-explored box - already works on an
     ExploredIndex, and a second one gets all of that for free. Flown cells live in both: the map
     still uncovers them, this just knows which ones to tint.
     */
    nonisolated let airIndex = ExploredIndex()

    /// The map and the stats screen watch this rather than polling the indexes.
    nonisolated let state = CurrentValueSubject<FogState, Never>(FogState())

    private let database: RoamedDatabase
    private let fog = FogEngine()
    private let clock: @Sendable () -> Int64

    /// The last fix used as the anchor for distance and for joining up the trail.
    private var anchor: Fix?

    init(database: RoamedDatabase, clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.database = database
        self.clock = clock
    }

    /// Loads the stored fog into memory. Safe to call more than once.
    func load() async {
        if state.value.loaded { return }
        do {
            let cells = try database.loadAllCells()
            index.addAll(cells.map { CellKey.pack($0.x, $0.y) })
            airIndex.addAll(
                cells.filter { $0.source == CellSource.air.id }.map { CellKey.pack($0.x, $0.y) }
            )
        } catch {
            RoamedLog.warn("could not read the stored fog", error)
        }
        publish()
    }

    func recordFix(_ fix: Fix, settings: RoamedSettings) -> RecordOutcome {
        if let accuracy = fix.accuracy, accuracy > Double(settings.maxAccuracyMeters) {
            return .rejected(reason: "accuracy \(Int(accuracy)) m")
        }

        let previous = anchor
        var distance = 0.0
        var joinToPrevious = false
        var flew = false

        if let previous {
            let moved = Geo.distanceMeters(
                previous.latitude, previous.longitude, fix.latitude, fix.longitude
            )
            let elapsedSeconds = Double(fix.timestamp - previous.timestamp) / 1000.0
            if isImplausibleJump(moved, elapsedSeconds) {
                // Teleport: reveal where we are, but do not join a line to where we were.
            } else if settings.uncoverFlightPaths && isFlight(moved, elapsedSeconds) {
                distance = moved
                flew = true
            } else if moved < jitterThreshold(fix.accuracy) {
                // Standing still. Keep the old anchor so GPS noise cannot fake a walk.
                return recordStationary(fix, settings: settings)
            } else {
                distance = moved
                joinToPrevious = settings.connectTheDots && isOneLeg(moved, elapsedSeconds)
            }
        }

        let radius = Double(settings.revealRadiusMeters)
        var cells = Set<CellKeyValue>()
        if flew, let previous {
            fog.cellsAlongFlight(
                previous.latitude, previous.longitude, fix.latitude, fix.longitude,
                radiusMeters: radius, into: &cells
            )
        } else if joinToPrevious, let previous {
            fog.cellsAlongSegment(
                previous.latitude, previous.longitude, fix.latitude, fix.longitude,
                radiusMeters: radius, into: &cells
            )
        } else {
            fog.cellsWithinRadius(fix.latitude, fix.longitude, radius, into: &cells)
        }

        let source: CellSource = flew ? .air : .ground
        let fresh = index.addAll(cells)
        if flew {
            airIndex.addAll(fresh)
        } else {
            promoteToGround(cells)
        }
        persist(fix: fix, freshKeys: fresh, distanceMeters: distance, settings: settings, source: source)
        anchor = fix
        publish(fix)
        return .recorded(newCells: fresh.count, distanceMeters: distance)
    }

    /// A fix that did not move far enough to count as travel still refreshes the fog around you.
    private func recordStationary(_ fix: Fix, settings: RoamedSettings) -> RecordOutcome {
        let cells = fog.cellsWithinRadius(
            fix.latitude, fix.longitude, Double(settings.revealRadiusMeters)
        )
        let fresh = index.addAll(cells)
        promoteToGround(cells)
        persist(fix: fix, freshKeys: fresh, distanceMeters: 0.0, settings: settings, source: .ground)
        publish(fix)
        return .recorded(newCells: fresh.count, distanceMeters: 0.0)
    }

    /**
     Reclassifies squares that were only ever flown over and have now actually been visited.

     Every landing does this: the flight ribbon covers the airport it ends at, and the first fix on
     the ground there is standing in squares currently marked as flown.
     */
    private func promoteToGround<S: Sequence>(_ cells: S) where S.Element == CellKeyValue {
        if airIndex.size == 0 { return }
        let promoted = airIndex.removeAll(cells)
        guard !promoted.isEmpty else { return }
        do {
            try database.setSource(CellSource.ground.id, for: promoted)
        } catch {
            RoamedLog.warn("could not reclassify flown ground", error)
        }
    }

    private func persist(
        fix: Fix,
        freshKeys: [CellKeyValue],
        distanceMeters: Double,
        settings: RoamedSettings,
        source: CellSource
    ) {
        let now = fix.timestamp
        do {
            if !freshKeys.isEmpty {
                for chunk in freshKeys.chunked(into: ExplorationRepository.importChunk) {
                    try database.insertNewCells(
                        chunk.map { key in
                            ExploredCellRow(
                                x: CellKey.x(key), y: CellKey.y(key), firstSeen: now,
                                lastSeen: now, visits: 1, source: source.id
                            )
                        }
                    )
                }
            }
            // Bump the visit counter for the cell you are actually standing in - but not if it was
            // only just created, which already counts as visit one.
            let hereX = TileMath.cellX(fix.longitude, RevealZoom.z)
            let hereY = TileMath.cellY(fix.latitude, RevealZoom.z)
            if !freshKeys.contains(CellKey.pack(hereX, hereY)) {
                try database.markVisited(x: hereX, y: hereY, now: now)
            }

            if settings.keepRawFixesDays > 0 {
                try database.insertTrackPoint(
                    TrackPointRow(
                        timestamp: now, latitude: fix.latitude, longitude: fix.longitude,
                        altitude: fix.altitude, accuracy: fix.accuracy, speed: fix.speed
                    )
                )
            }
            try database.addToDay(
                LocalDate.of(epochMillis: now), distanceMeters: distanceMeters, newCells: freshKeys.count
            )
        } catch {
            RoamedLog.warn("could not write a fix", error)
        }
    }

    /**
     Uncovers the ground covered by tracks imported from elsewhere - a Google Timeline export, a
     GPX from another app - so a trip the tracker missed can still be put on the map.
     */
    func importTracks(_ tracks: [ImportedTrack], settings: RoamedSettings) throws -> TrackImportResult {
        let radius = Double(settings.revealRadiusMeters)
        var pointCount = 0
        // Earliest timestamp wins, so an imported cell is dated when it was actually first crossed.
        var discovered: [CellKeyValue: Int64] = [:]
        // A cell reached both ways is ground: having flown over somewhere you also walked adds
        // nothing to what you know of it, and must not take the credit away.
        var walked = Set<CellKeyValue>()
        var flown = Set<CellKeyValue>()

        for track in tracks {
            var previous: ImportedFix?
            for point in track.points {
                pointCount += 1
                var cells = Set<CellKeyValue>()
                let flightLeg = previous.map { settings.uncoverFlightPaths && flownBetween($0, point) } ?? false
                if let from = previous, flightLeg {
                    fog.cellsAlongFlight(
                        from.latitude, from.longitude, point.latitude, point.longitude,
                        radiusMeters: radius, into: &cells
                    )
                } else if let from = previous, joinable(from, point, contiguous: track.contiguous) {
                    fog.cellsAlongSegment(
                        from.latitude, from.longitude, point.latitude, point.longitude,
                        radiusMeters: radius, into: &cells
                    )
                } else {
                    fog.cellsWithinRadius(point.latitude, point.longitude, radius, into: &cells)
                }
                let stamp = point.timestamp ?? 0
                for cell in cells {
                    if let existing = discovered[cell] {
                        if stamp >= 1 && stamp < existing { discovered[cell] = stamp }
                    } else {
                        discovered[cell] = stamp
                    }
                }
                if flightLeg { flown.formUnion(cells) } else { walked.formUnion(cells) }
                previous = point
            }
        }

        let fresh = discovered.filter { !index.contains($0.key) }
        for chunk in Array(fresh).chunked(into: ExplorationRepository.importChunk) {
            try database.insertNewCells(
                chunk.map { (key, stamp) in
                    let source: CellSource =
                        (flown.contains(key) && !walked.contains(key)) ? .air : .ground
                    return ExploredCellRow(
                        x: CellKey.x(key), y: CellKey.y(key), firstSeen: stamp,
                        lastSeen: stamp, visits: 1, source: source.id
                    )
                }
            )
        }
        index.addAll(fresh.keys)
        airIndex.addAll(fresh.keys.filter { flown.contains($0) && !walked.contains($0) })
        // Ground in this import beats a flight recorded over the same square earlier.
        promoteToGround(walked)
        publish(state.value.lastFix)
        return TrackImportResult(trackCount: tracks.count, pointCount: pointCount, newCells: fresh.count)
    }

    /**
     Whether an imported leg was flown.

     Timestamps are required rather than guessed at: the only evidence separating a flight from a
     tracker that slept through a drive is the speed, and without two times there is no speed.
     */
    private func flownBetween(_ from: ImportedFix, _ to: ImportedFix) -> Bool {
        guard let start = from.timestamp, let end = to.timestamp else { return false }
        let moved = Geo.distanceMeters(from.latitude, from.longitude, to.latitude, to.longitude)
        return isFlight(moved, Double(end - start) / 1000.0)
    }

    /**
     Whether the road between two imported points may be filled in.

     For recorded history this is the same rule live tracking uses: near enough, and soon enough,
     to be one continuous leg. A file that declares its points to be a single path is taken at its
     word instead, subject only to a sanity limit, because a turn-by-turn route can put fifty
     kilometres of motorway between two waypoints and still be one unbroken drive.
     */
    private func joinable(_ from: ImportedFix, _ to: ImportedFix, contiguous: Bool) -> Bool {
        let moved = Geo.distanceMeters(from.latitude, from.longitude, to.latitude, to.longitude)
        if contiguous { return moved <= ExplorationRepository.contiguousSanityLimitMeters }
        if moved > FogEngine.defaultMaxGapMeters { return false }
        // Without timestamps the file's own ordering is the only evidence there is.
        guard let start = from.timestamp, let end = to.timestamp else { return true }
        return isOneLeg(moved, Double(end - start) / 1000.0)
    }

    /// Drops raw fixes older than the retention window. The fog itself is never pruned.
    @discardableResult
    func pruneRawFixes(keepDays: Int) -> Int {
        guard keepDays > 0 else { return 0 }
        let cutoff = clock() - Int64(keepDays) * ExplorationRepository.millisPerDay
        return (try? database.deleteTrackPointsOlderThan(cutoff)) ?? 0
    }

    /**
     The most recent fixes within the window, oldest first.

     The limit takes the *newest* rows and they are turned back round here. Taking the oldest
     instead would mean that on a busy day the trail stopped partway through it and never showed
     where you had just been, which is the half anyone looking at a trail actually wants.
     */
    func recentTrail(since: Int64, limit: Int = 2_000) -> [TrackPointRow] {
        Array(((try? database.newestTrackPoints(since: since, limit: limit)) ?? []).reversed())
    }

    func recordPlace(_ place: VisitedPlaceRow) {
        do {
            try database.recordPlace(place)
        } catch {
            RoamedLog.warn("could not record a place", error)
        }
    }

    func summary() -> ExplorationSummary {
        let area = index.areaSquareMeters
        var summary = ExplorationSummary()
        summary.cellCount = index.size
        summary.areaSquareMeters = area
        summary.flownSquareMeters = airIndex.areaSquareMeters
        summary.percentOfSurface = ExplorationStats.percentOfEarthSurface(area)
        summary.percentOfLand = ExplorationStats.percentOfEarthLand(area)
        summary.totalDistanceMeters = (try? database.totalDistance()) ?? 0
        summary.distanceThisYearMeters = (try? database.distanceSince(LocalDate.startOfYear())) ?? 0
        summary.activeDays = (try? database.activeDays()) ?? 0
        summary.firstDate = try? database.firstDate()
        summary.countryCount = (try? database.countryCount()) ?? 0
        summary.places = (try? database.allPlaces()) ?? []
        summary.newCellsPerYear = (try? database.newCellsPerYear()) ?? []
        summary.recentDays = (try? database.recentDays(limit: ExplorationRepository.recentDays)) ?? []
        summary.rawFixCount = (try? database.trackPointCount()) ?? 0
        return summary
    }

    func clearEverything() throws {
        try database.deleteEverything()
        index.clear()
        airIndex.clear()
        anchor = nil
        publish(nil)
    }

    func writeBackup(to out: TextSink, appVersion: String) throws {
        let cellCount = try database.cellCount()
        let sink = BackupSink(out)
        try sink.begin(exportedAt: clock(), appVersion: appVersion, cellCount: cellCount)
        try forEachCellPage { try sink.add($0) }
        try sink.end()
    }

    func writeGeoJson(to out: TextSink) throws {
        let sink = GeoJsonSink(out)
        sink.begin()
        try forEachCellPage { sink.add($0) }
        sink.end()
    }

    func writeGpx(to out: TextSink) throws {
        let sink = GpxSink(out)
        sink.begin(trackName: "Roamed track")
        var offset = 0
        while true {
            let page = try database.trackPointPage(limit: ExplorationRepository.pageSize, offset: offset)
            for point in page {
                sink.add(
                    TrackPointRecord(
                        timestamp: point.timestamp, latitude: point.latitude,
                        longitude: point.longitude, altitude: point.altitude,
                        accuracy: point.accuracy, speed: point.speed
                    )
                )
            }
            if page.count < ExplorationRepository.pageSize { break }
            offset += ExplorationRepository.pageSize
        }
        sink.end()
    }

    /**
     Merges a backup into whatever is already recorded.

     Merging rather than replacing is deliberate: importing a backup from an old phone should add
     to the map, not wipe the last month off it.
     */
    func importBackup(_ text: String) throws -> Int {
        let records = try BackupReader.read(text)
        var added = 0
        for chunk in records.chunked(into: ExplorationRepository.importChunk) {
            let fresh = chunk.filter { !index.contains(CellKey.pack($0.x, $0.y)) }
            guard !fresh.isEmpty else { continue }
            try database.insertNewCells(
                fresh.map {
                    ExploredCellRow(
                        x: $0.x, y: $0.y, firstSeen: $0.firstSeen, lastSeen: $0.lastSeen,
                        visits: $0.visits, source: $0.source.id
                    )
                }
            )
            index.addAll(fresh.map { CellKey.pack($0.x, $0.y) })
            airIndex.addAll(fresh.filter { $0.source == .air }.map { CellKey.pack($0.x, $0.y) })
            added += fresh.count
        }
        publish(state.value.lastFix)
        return added
    }

    /// Walks every stored cell a page at a time, so an export never holds the lot in memory.
    private func forEachCellPage(_ action: (CellRecord) throws -> Void) throws {
        var offset = 0
        while true {
            let page = try database.cellPage(limit: ExplorationRepository.pageSize, offset: offset)
            for cell in page {
                try action(
                    CellRecord(
                        x: cell.x, y: cell.y, firstSeen: cell.firstSeen, lastSeen: cell.lastSeen,
                        visits: cell.visits, source: CellSource.of(cell.source)
                    )
                )
            }
            if page.count < ExplorationRepository.pageSize { break }
            offset += ExplorationRepository.pageSize
        }
    }

    private func publish(_ fix: Fix? = nil) {
        state.value = FogState(
            loaded: true,
            version: index.version,
            cellCount: index.size,
            areaSquareMeters: index.areaSquareMeters,
            lastFix: fix ?? state.value.lastFix
        )
    }

    /**
     How far a fix has to move before it counts as movement rather than noise.

     A stationary phone with a 30 m fix will wander tens of metres between readings; without this
     the odometer would climb all night.
     */
    private func jitterThreshold(_ accuracy: Double?) -> Double {
        max(ExplorationRepository.minJitterMeters, (accuracy ?? 0) * 0.6)
    }

    private static let pageSize = 5_000
    private static let importChunk = 2_000
    private static let recentDays = 30
    private static let minJitterMeters = 10.0

    /// Only a guard against a corrupt file; a declared path is otherwise trusted.
    private static let contiguousSanityLimitMeters = 500_000.0
    private static let millisPerDay: Int64 = 24 * 60 * 60 * 1_000
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
