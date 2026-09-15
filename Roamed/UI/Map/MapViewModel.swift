import Foundation
import Combine
import CoreLocation
import RoamedCore

/**
 A point on the recorded trail, in the form the map wants to draw it.

 The timestamp is what lets the trail tell a journey from a gap.
 */
struct TrailPoint: Equatable {
    let latitude: Double
    let longitude: Double
    let timestamp: Int64
}

@MainActor
final class MapViewModel: ObservableObject {

    @Published private(set) var fogState = FogState()
    @Published private(set) var trail: [[TrailPoint]] = []

    /// The overlay reads these directly; they are the single authoritative copy of the fog.
    let index: ExploredIndex
    let airIndex: ExploredIndex

    private let exploration: ExplorationRepository
    private var cancellables = Set<AnyCancellable>()
    private var trailTask: Task<Void, Never>?

    init(exploration: ExplorationRepository, settingsStore: SettingsStore) {
        self.exploration = exploration
        self.index = exploration.index
        self.airIndex = exploration.airIndex

        exploration.state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.fogState = state }
            .store(in: &cancellables)

        settingsStore.changes
            .map(\.showTrail)
            .removeDuplicates()
            .sink { [weak self] show in self?.watchTrail(show) }
            .store(in: &cancellables)

        Task { await exploration.load() }
    }

    /**
     The box enclosing everything uncovered, for the fit-to-explored button.

     Off the main thread because it walks every stored cell, and someone with years of tracking has
     hundreds of thousands of them - not slow, but not worth a dropped frame either.
     */
    func exploredBounds() async -> GeoBounds? {
        let index = self.index
        return await Task.detached(priority: .userInitiated) { index.bounds() }.value
    }

    private func watchTrail(_ show: Bool) {
        trailTask?.cancel()
        guard show else {
            trail = []
            return
        }
        trailTask = Task { [weak self] in
            // Refresh periodically rather than per fix: the trail is context, not data. The loop
            // ends when the screen does - either cancelled, or because the view model has gone.
            while !Task.isCancelled {
                guard let self else { return }
                await self.reloadTrail()
                try? await Task.sleep(nanoseconds: UInt64(MapViewModel.trailRefreshSeconds) * 1_000_000_000)
            }
        }
    }

    private func reloadTrail() async {
        let since = Int64(Date().timeIntervalSince1970 * 1000) - MapViewModel.trailWindowMillis
        let points = await exploration.recentTrail(since: since)
            .map { TrailPoint(latitude: $0.latitude, longitude: $0.longitude, timestamp: $0.timestamp) }
        trail = MapViewModel.split(points)
    }

    /**
     Breaks the trail wherever the record is broken.

     Joining every stored fix to the next one regardless would draw a straight line across a stretch
     where nothing was recorded at all - and that line is a claim about a route that was never
     watched. It reads as "the app followed me here", when the truth is the opposite: two fixes, and
     no idea what happened between them. So the line breaks on exactly the gaps the fog refuses to
     fill, and the trail and the fog then tell the same story.
     */
    static func split(_ points: [TrailPoint]) -> [[TrailPoint]] {
        var runs: [[TrailPoint]] = []
        var current: [TrailPoint] = []
        var previous: TrailPoint?
        for point in points {
            if let from = previous, !continuous(from, point) {
                if current.count >= 2 { runs.append(current) }
                current = []
            }
            current.append(point)
            previous = point
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    private static func continuous(_ from: TrailPoint, _ to: TrailPoint) -> Bool {
        // Without times there is nothing to judge a gap by, so the stored order is all there is.
        if from.timestamp <= 0 || to.timestamp <= 0 { return true }
        let moved = Geo.distanceMeters(from.latitude, from.longitude, to.latitude, to.longitude)
        return isOneLeg(moved, Double(to.timestamp - from.timestamp) / 1000.0)
    }

    private static let trailRefreshSeconds = 30
    private static let trailWindowMillis: Int64 = 24 * 60 * 60 * 1_000
}
