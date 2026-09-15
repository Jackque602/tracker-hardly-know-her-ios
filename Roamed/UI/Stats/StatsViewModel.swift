import Foundation
import Combine
import RoamedCore

@MainActor
final class StatsViewModel: ObservableObject {

    @Published private(set) var loading = true
    @Published private(set) var summary = ExplorationSummary()
    /// Nil until the region atlas has been read, or for good if it could not be.
    @Published private(set) var regions: RegionTally?

    private let exploration: ExplorationRepository
    private let regionMask: () async -> RegionMask?
    private var cancellables = Set<AnyCancellable>()
    private var work: Task<Void, Never>?

    init(exploration: ExplorationRepository, regionMask: @escaping () async -> RegionMask?) {
        self.exploration = exploration
        self.regionMask = regionMask

        exploration.state
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
            // Show the cheap numbers straight away; the region breakdown walks every uncovered
            // square and reads a megabyte of borders the first time, which is not worth blocking
            // the screen on.
            self.summary = summary
            self.loading = false
            let tally = await self.breakdown()
            guard !Task.isCancelled else { return }
            self.regions = tally
        }
    }

    /**
     Every uncovered square, flown or driven.

     Flown ground used to be left out of this, on the argument that passing over a country is not
     being there. It is counted now because that was a judgement about what the numbers ought to
     mean, imposed on someone else's map - and uncovered is uncovered. The blue tint and the
     separate flown-over figure are still there to tell the two apart, which is what they are for.
     */
    private func breakdown() async -> RegionTally? {
        guard let mask = await regionMask() else { return nil }
        let cells = exploration.index.snapshotKeys()
        return await Task.detached(priority: .utility) {
            RegionBreakdown.of(mask: mask, cells: cells)
        }.value
    }
}
