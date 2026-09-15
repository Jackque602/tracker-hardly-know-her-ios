import Foundation
import Combine

enum RoamedMapStyle: String, CaseIterable, Identifiable, Sendable {
    case standard
    case satellite
    case hybrid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        }
    }
}

/**
 Everything the user can tune.

 Defaults are chosen for "leave it on all day and forget about it": a fix every 25 seconds only
 when you have actually moved 20 metres costs very little battery, and a 120 m reveal radius is
 generous enough that a walk clears a satisfying stripe without inventing coverage.

 `highAccuracyMode` defaults on because the lower-power accuracy classes target roughly
 block-level accuracy, which they can only reach where there is WiFi to lean on. Out on a rural
 road they fall back to cell towers and return fixes hundreds of metres wide, and an app whose
 entire job is recording where you went cannot do that job on fixes like those.
 */
struct RoamedSettings: Equatable, Sendable {
    var trackingEnabled = false
    var updateIntervalSeconds = 25
    var minDisplacementMeters = 20
    var revealRadiusMeters = 120
    var maxAccuracyMeters = 150
    var connectTheDots = true
    var uncoverFlightPaths = true
    var highAccuracyMode = true
    var fogOpacity = 0.85
    var showTrail = false
    var keepRawFixesDays = 365
    var resolvePlaces = true
    var mapStyle: RoamedMapStyle = .standard
}

/**
 Settings, kept in `UserDefaults`.

 There are a dozen scalars here and they are read on every fix, so a preferences file is the right
 size of tool - the same call the Android build makes with DataStore rather than a database table.
 */
@MainActor
final class SettingsStore: ObservableObject {

    @Published private(set) var settings: RoamedSettings

    /// Explicit, because `$settings` on a `private(set)` property is not something to lean on.
    var changes: AnyPublisher<RoamedSettings, Never> { $settings.eraseToAnyPublisher() }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = SettingsStore.load(from: defaults)
    }

    func setTrackingEnabled(_ enabled: Bool) { update { $0.trackingEnabled = enabled } }

    func setUpdateInterval(_ seconds: Int) {
        update { $0.updateIntervalSeconds = seconds.clamped(to: 5...600) }
    }

    func setMinDisplacement(_ meters: Int) {
        update { $0.minDisplacementMeters = meters.clamped(to: 0...500) }
    }

    func setRevealRadius(_ meters: Int) {
        update { $0.revealRadiusMeters = meters.clamped(to: 25...1_000) }
    }

    func setMaxAccuracy(_ meters: Int) {
        update { $0.maxAccuracyMeters = meters.clamped(to: 10...500) }
    }

    func setConnectTheDots(_ enabled: Bool) { update { $0.connectTheDots = enabled } }
    func setUncoverFlightPaths(_ enabled: Bool) { update { $0.uncoverFlightPaths = enabled } }
    func setHighAccuracyMode(_ enabled: Bool) { update { $0.highAccuracyMode = enabled } }

    func setFogOpacity(_ opacity: Double) {
        update { $0.fogOpacity = min(max(opacity, 0.2), 1.0) }
    }

    func setShowTrail(_ enabled: Bool) { update { $0.showTrail = enabled } }

    func setKeepRawFixesDays(_ days: Int) {
        update { $0.keepRawFixesDays = days.clamped(to: 0...3_650) }
    }

    func setResolvePlaces(_ enabled: Bool) { update { $0.resolvePlaces = enabled } }
    func setMapStyle(_ style: RoamedMapStyle) { update { $0.mapStyle = style } }

    private func update(_ change: (inout RoamedSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        save(next)
    }

    private func save(_ settings: RoamedSettings) {
        defaults.set(settings.trackingEnabled, forKey: Keys.tracking)
        defaults.set(settings.updateIntervalSeconds, forKey: Keys.interval)
        defaults.set(settings.minDisplacementMeters, forKey: Keys.displacement)
        defaults.set(settings.revealRadiusMeters, forKey: Keys.radius)
        defaults.set(settings.maxAccuracyMeters, forKey: Keys.accuracy)
        defaults.set(settings.connectTheDots, forKey: Keys.connect)
        defaults.set(settings.uncoverFlightPaths, forKey: Keys.flights)
        defaults.set(settings.highAccuracyMode, forKey: Keys.highAccuracy)
        defaults.set(settings.fogOpacity, forKey: Keys.opacity)
        defaults.set(settings.showTrail, forKey: Keys.trail)
        defaults.set(settings.keepRawFixesDays, forKey: Keys.keepDays)
        defaults.set(settings.resolvePlaces, forKey: Keys.places)
        defaults.set(settings.mapStyle.rawValue, forKey: Keys.mapStyle)
    }

    private static func load(from defaults: UserDefaults) -> RoamedSettings {
        var settings = RoamedSettings()
        // `object(forKey:)` rather than `bool(forKey:)`, because the latter cannot tell an absent
        // key from a stored false - which would turn every defaulted-on switch off on first run.
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            (defaults.object(forKey: key) as? Bool) ?? fallback
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            (defaults.object(forKey: key) as? Int) ?? fallback
        }
        settings.trackingEnabled = bool(Keys.tracking, settings.trackingEnabled)
        settings.updateIntervalSeconds = int(Keys.interval, settings.updateIntervalSeconds)
        settings.minDisplacementMeters = int(Keys.displacement, settings.minDisplacementMeters)
        settings.revealRadiusMeters = int(Keys.radius, settings.revealRadiusMeters)
        settings.maxAccuracyMeters = int(Keys.accuracy, settings.maxAccuracyMeters)
        settings.connectTheDots = bool(Keys.connect, settings.connectTheDots)
        settings.uncoverFlightPaths = bool(Keys.flights, settings.uncoverFlightPaths)
        settings.highAccuracyMode = bool(Keys.highAccuracy, settings.highAccuracyMode)
        settings.fogOpacity = (defaults.object(forKey: Keys.opacity) as? Double) ?? settings.fogOpacity
        settings.showTrail = bool(Keys.trail, settings.showTrail)
        settings.keepRawFixesDays = int(Keys.keepDays, settings.keepRawFixesDays)
        settings.resolvePlaces = bool(Keys.places, settings.resolvePlaces)
        if let raw = defaults.string(forKey: Keys.mapStyle), let style = RoamedMapStyle(rawValue: raw) {
            settings.mapStyle = style
        }
        return settings
    }

    private enum Keys {
        static let tracking = "tracking_enabled"
        static let interval = "update_interval_seconds"
        static let displacement = "min_displacement_meters"
        static let radius = "reveal_radius_meters"
        static let accuracy = "max_accuracy_meters"
        static let connect = "connect_the_dots"
        static let flights = "uncover_flight_paths"
        static let highAccuracy = "high_accuracy_mode"
        static let opacity = "fog_opacity"
        static let trail = "show_trail"
        static let keepDays = "keep_raw_fixes_days"
        static let places = "resolve_places"
        static let mapStyle = "map_style"
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
