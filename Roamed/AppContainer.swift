import Foundation
import RoamedCore

/**
 Hand-rolled dependency container.

 The graph is four objects deep, so a framework would cost more in build complexity than it would
 save. Everything is built once at launch and handed down through the environment.
 */
@MainActor
final class AppContainer: ObservableObject {

    let database: RoamedDatabase
    let exploration: ExplorationRepository
    let settings: SettingsStore
    let tracker: LocationTracker

    /// Nil only if the store could not be opened at all, which the map reports rather than hides.
    let storageFailure: String?

    private var regionMaskTask: Task<RegionMask?, Never>?

    init() {
        let settings = SettingsStore()
        self.settings = settings

        var failure: String?
        let database: RoamedDatabase
        do {
            database = try RoamedDatabase(url: try RoamedDatabase.defaultURL())
        } catch {
            // An in-memory store keeps the app usable and honest: the map still works for this
            // session, and the message below says plainly that nothing will be kept.
            failure = "Could not open the map store, so nothing will be saved: \(error)"
            RoamedLog.warn("falling back to an in-memory store", error)
            database = (try? RoamedDatabase(inMemory: true)) ?? RoamedDatabase.unusable()
        }
        self.storageFailure = failure
        self.database = database

        let exploration = ExplorationRepository(database: database)
        self.exploration = exploration
        self.tracker = LocationTracker(repository: exploration, settingsStore: settings)

        // Warm the fog into memory so the map has something to draw the moment it appears.
        Task { await exploration.load() }
    }

    /**
     The world's borders, read from the packaged atlas the first time the stats screen asks and
     shared from then on.

     About a megabyte, so it is decoded off the main thread and only if something actually wants it
     - the map and the tracker never do.
     */
    func regionMask() async -> RegionMask? {
        if let existing = regionMaskTask { return await existing.value }
        let task = Task.detached(priority: .utility) { () -> RegionMask? in
            do {
                return try RegionMask.bundled()
            } catch {
                // Worth knowing about, but every other stat still works without it.
                RoamedLog.warn("region mask unavailable; per-country stats will be hidden", error)
                return nil
            }
        }
        regionMaskTask = task
        return await task.value
    }

    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
