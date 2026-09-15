import Foundation
import CoreLocation
import Combine
import RoamedCore

/**
 Keeps a location subscription alive for as long as tracking is on.

 The Android original runs a foreground service with a permanent notification, because that is the
 only way that platform will let an app watch your position for hours. iOS makes the same bargain
 differently: "Always" authorisation plus the `location` background mode, and a blue indicator in
 the status bar whenever the app is reading your position with the screen off. Either way the
 arrangement is the same one - it is always visible that the app is recording.

 Two subscriptions run rather than one. Standard updates are the real tracker. Significant-change
 monitoring is the resurrection: if iOS terminates the app to reclaim memory, a significant change
 relaunches it in the background, and tracking picks up where it left off. Without it a tracker
 that is killed overnight simply stops, and the owner finds out days later.
 */
@MainActor
final class LocationTracker: NSObject, ObservableObject {

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastRejection: String?

    /// Enough authorisation to record anything at all.
    var canTrack: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    /// Enough to keep recording with the app closed, which is the whole point of the thing.
    var canTrackInBackground: Bool { authorizationStatus == .authorizedAlways }

    var isDetermined: Bool { authorizationStatus != .notDetermined }

    private let manager = CLLocationManager()
    private let repository: ExplorationRepository
    private let placeResolver: PlaceResolver
    private var settings = RoamedSettings()
    private var running = false
    private var activeRequestSignature: String?
    private var lastAcceptedAt: Int64 = 0
    private var lastPruneAt: Int64 = 0
    private var cancellables = Set<AnyCancellable>()

    init(repository: ExplorationRepository, settingsStore: SettingsStore) {
        self.repository = repository
        self.placeResolver = PlaceResolver()
        self.authorizationStatus = manager.authorizationStatus
        super.init()

        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other

        settingsStore.changes
            .sink { [weak self] latest in
                guard let self else { return }
                self.settings = latest
                if latest.trackingEnabled {
                    self.start()
                } else {
                    self.stop()
                }
            }
            .store(in: &cancellables)
    }

    /// Asks for foreground location. iOS insists this comes first and on its own.
    func requestForegroundAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /**
     Asks to keep going in the background.

     Deliberately only offered once foreground access is granted: iOS will silently ignore the
     always-prompt otherwise, and the user would be left tapping a button that does nothing.
     */
    func requestBackgroundAuthorization() {
        guard canTrack else {
            requestForegroundAuthorization()
            return
        }
        manager.requestAlwaysAuthorization()
    }

    private func start() {
        guard canTrack else { return }
        let signature = "\(settings.minDisplacementMeters)/\(settings.highAccuracyMode)"
        if running && signature == activeRequestSignature { return }

        manager.desiredAccuracy = settings.highAccuracyMode
            ? kCLLocationAccuracyBest
            : kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = settings.minDisplacementMeters > 0
            ? CLLocationDistance(settings.minDisplacementMeters)
            : kCLDistanceFilterNone

        if LocationTracker.backgroundLocationDeclared && canTrackInBackground {
            // Setting this without the background mode in Info.plist is a hard crash, so it is
            // gated on the declaration actually being there.
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }

        manager.startUpdatingLocation()
        if canTrackInBackground {
            manager.startMonitoringSignificantLocationChanges()
        }
        running = true
        activeRequestSignature = signature
    }

    private func stop() {
        guard running else { return }
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        if LocationTracker.backgroundLocationDeclared {
            manager.allowsBackgroundLocationUpdates = false
        }
        running = false
        activeRequestSignature = nil
    }

    private func handle(_ locations: [CLLocation]) {
        let current = settings
        for location in locations {
            let timestamp = Int64(location.timestamp.timeIntervalSince1970 * 1000)

            // CoreLocation pushes as fast as the hardware manages; the interval setting is what
            // turns that into "check my position every N seconds" without a polling timer.
            let sinceLast = Double(timestamp - lastAcceptedAt) / 1000.0
            if lastAcceptedAt > 0 && sinceLast < Double(current.updateIntervalSeconds) { continue }

            let fix = Fix(
                timestamp: timestamp,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                speed: location.speed >= 0 ? location.speed : nil
            )
            lastAcceptedAt = timestamp

            Task { @MainActor [repository, placeResolver] in
                await repository.load()
                let outcome = await repository.recordFix(fix, settings: current)
                if case .rejected(let reason) = outcome {
                    self.lastRejection = reason
                    return
                }
                self.lastRejection = nil

                if current.resolvePlaces, let place = await placeResolver.resolve(fix) {
                    await repository.recordPlace(place)
                }
                await self.maybePrune(keepDays: current.keepRawFixesDays)
            }
        }
    }

    /// Retention housekeeping, at most once every six hours while tracking.
    private func maybePrune(keepDays: Int) async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if now - lastPruneAt < LocationTracker.pruneIntervalMillis { return }
        lastPruneAt = now
        await repository.pruneRawFixes(keepDays: keepDays)
    }

    /// Whether the app actually declares the background mode this needs.
    private static let backgroundLocationDeclared: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") ?? false
    }()

    private static let pruneIntervalMillis: Int64 = 6 * 60 * 60 * 1_000
}

extension LocationTracker: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor in self.handle(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if self.settings.trackingEnabled && self.canTrack {
                // Authorisation just widened or narrowed; rebuild the subscription either way.
                self.activeRequestSignature = nil
                self.start()
            } else if !self.canTrack {
                self.stop()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        RoamedLog.warn("location updates failed", error)
    }
}
