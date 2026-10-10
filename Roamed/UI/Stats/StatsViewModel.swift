import Foundation
import Combine
import RoamedCore

/**
 The counties and cities you have been in, filed under the state they belong to.

 Keyed by the state's `US-PA`-style code rather than its name, because that code is the only thing
 the three atlas files share - each numbers its own regions from zero.
 */
struct LocalityIndex: Equatable {
    var counties: [String: [RegionProgress]] = [:]
    var cities: [String: [RegionProgress]] = [:]

    var isEmpty: Bool { counties.isEmpty && cities.isEmpty }

    func forState(_ code: String) -> StateDetail {
        StateDetail(counties: counties[code] ?? [], cities: cities[code] ?? [])
    }
}

/// What sits under one state row when it is opened.
struct StateDetail: Equatable {
    let counties: [RegionProgress]
    let cities: [RegionProgress]

    var isEmpty: Bool { counties.isEmpty && cities.isEmpty }
}

@MainActor
final class StatsViewModel: ObservableObject {

    @Published private(set) var loading = true
    @Published private(set) var summary = ExplorationSummary()
    /// Nil until the region atlas has been read, or for good if it could not be.
    @Published private(set) var regions: RegionTally?
    /// The tiers below a state. Empty until they are read, and wherever they do not reach.
    @Published private(set) var localities = LocalityIndex()

    private let exploration: ExplorationRepository
    private let atlas: (RegionMask.Bundled) async -> RegionMask?
    private var cancellables = Set<AnyCancellable>()
    private var work: Task<Void, Never>?

    init(
        exploration: ExplorationRepository,
        atlas: @escaping (RegionMask.Bundled) async -> RegionMask?
    ) {
        self.exploration = exploration
        self.atlas = atlas

        exploration.state.publisher
            .map(\.version)
            .removeDuplicates()
            // Recompute when the fog actually changes rather than on a timer, but not on every
            // single cell: a drive adds a version per fix and the atlas walk is not free.
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    func refresh() {
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            await self.exploration.load()
            let summary = await self.exploration.summary()
            guard !Task.isCancelled else { return }
            // Show the cheap numbers straight away; the breakdowns walk every uncovered square
            // and read a megabyte of borders the first time, which is not worth blocking on.
            self.summary = summary
            self.loading = false

            let cells = self.exploration.index.snapshotKeys()
            if let world = await self.tally(.regions, cells) {
                guard !Task.isCancelled else { return }
                self.regions = world
            }
            var index = LocalityIndex()
            if let counties = await self.tally(.counties, cells) {
                index.counties = counties.localities(of: .county)
            }
            if let cities = await self.tally(.cities, cells) {
                index.cities = cities.localities(of: .city)
            }
            guard !Task.isCancelled else { return }
            self.localities = index
        }
    }

    /**
     One atlas's worth of figures, counted off the main thread.

     Every uncovered square is walked, flown or driven. Flown ground used to be left out, on the
     argument that passing over a country is not being there. It is counted now because that was a
     judgement about what the numbers ought to mean, imposed on someone else's map - and uncovered
     is uncovered. The blue tint and the separate flown-over figure are still there to tell the two
     apart, which is what they are for.
     */
    private func tally(_ which: RegionMask.Bundled, _ cells: [CellKeyValue]) async -> RegionTally? {
        guard let mask = await atlas(which) else { return nil }
        return await Task.detached(priority: .utility) {
            RegionBreakdown.of(mask: mask, cells: cells)
        }.value
    }
}
