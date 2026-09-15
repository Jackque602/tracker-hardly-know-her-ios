import SwiftUI
import RoamedCore

@MainActor
struct StatsScreen: View {

    @StateObject private var viewModel: StatsViewModel

    init(container: AppContainer) {
        _viewModel = StateObject(
            wrappedValue: StatsViewModel(
                exploration: container.exploration,
                regionMask: { await container.regionMask() }
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var content: some View {
        List {
            Section { HeadlineCard(summary: viewModel.summary).listRowInsets(EdgeInsets()) }

            Section {
                ForEach(statRows, id: \.0) { label, value in
                    LabeledContent(label) { Text(value).monospacedDigit() }
                }
            }

            if let regions = viewModel.regions {
                RegionSection(title: "Continents", entries: regions.continents)
                RegionSection(title: "Countries", entries: regions.countries)
                RegionSection(title: "States and provinces", entries: regions.subdivisions)
            }

            if !viewModel.summary.newCellsPerYear.isEmpty {
                Section("New ground each year") {
                    let busiest = max(1, viewModel.summary.newCellsPerYear.map(\.count).max() ?? 1)
                    ForEach(viewModel.summary.newCellsPerYear) { year in
                        HStack(spacing: 12) {
                            Text(year.year).frame(width: 52, alignment: .leading).monospacedDigit()
                            ProgressView(value: Double(year.count) / Double(busiest))
                                .tint(RoamedTheme.accent)
                            Text("\(year.count)")
                                .frame(width: 72, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }
                }
            }

            if !viewModel.summary.places.isEmpty {
                Section("Where you have been") {
                    ForEach(viewModel.summary.places) { place in
                        LabeledContent(
                            place.adminArea.isEmpty
                                ? place.countryName
                                : "\(place.adminArea), \(place.countryName)"
                        ) {
                            Text(place.countryCode).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { viewModel.refresh() }
    }

    private var statRows: [(String, String)] {
        let summary = viewModel.summary
        var rows: [(String, String)] = [
            ("Squares uncovered", "\(summary.cellCount)"),
            ("Distance travelled", ExplorationStats.formatDistance(summary.totalDistanceMeters)),
            ("This year", ExplorationStats.formatDistance(summary.distanceThisYearMeters)),
            ("Days out and about", "\(summary.activeDays)"),
        ]
        if summary.flownSquareMeters > 0 {
            rows.append(("Flown over", ExplorationStats.formatArea(summary.flownSquareMeters)))
        }
        if let regions = viewModel.regions {
            rows.append(("Continents", StatsScreen.outOf(regions.continents.count, regions.continentsInAtlas)))
            rows.append(("Countries", StatsScreen.outOf(regions.countries.count, regions.countriesInAtlas)))
            rows.append(("States and provinces", "\(regions.subdivisions.count)"))
        } else {
            rows.append(("Countries", "\(summary.countryCount)"))
        }
        rows.append(("Tracking since", summary.firstDate ?? "—"))
        return rows
    }

    private static func outOf(_ visited: Int, _ total: Int) -> String {
        total > 0 ? "\(visited) of \(total)" : "\(visited)"
    }

    private var footnote: String {
        var text = "Area counts every grid square you have been seen inside, and a square is about "
            + "300 m across at the equator - so a short walk still uncovers a whole one. "
            + "\(viewModel.summary.rawFixCount) raw fixes are stored for the trail and GPX export."
        if viewModel.summary.flownSquareMeters > 0 {
            text += "\n\nThe blue ground is flown over rather than travelled - uncovered, but seen "
                + "from ten kilometres up. It counts everywhere the rest does, the continent, "
                + "country and state figures included; the tint and the flown-over total above are "
                + "there so you can still tell which is which."
        }
        if let regions = viewModel.regions {
            text += "\n\nBorders are matched on a grid about 10 km across, so somewhere within a "
                + "few kilometres of a border can be credited to the wrong side of it. The atlas "
                + "counts territories and dependencies as their own countries, and states are "
                + "whatever each country calls its first-level divisions - so a country may be "
                + "split into fifty of them or into two hundred."
            if regions.unplacedSquareMeters > 0 {
                text += " \(ExplorationStats.formatArea(regions.unplacedSquareMeters)) of what you "
                    + "have uncovered fell outside every border, at sea or just off a coastline."
            }
        }
        return text
    }
}

private struct HeadlineCard: View {
    let summary: ExplorationSummary

    var body: some View {
        VStack(spacing: 6) {
            Text(ExplorationStats.formatPercent(summary.percentOfLand))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(RoamedTheme.accent)
                .monospacedDigit()
            Text("of Earth's land uncovered").font(.subheadline)
            Divider().padding(.vertical, 8)
            Text(
                "\(ExplorationStats.formatArea(summary.areaSquareMeters)) · "
                    + "\(ExplorationStats.formatPercent(summary.percentOfSurface)) of the whole planet"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/**
 One ranked list of regions - continents, countries or states - as its own section.

 Long lists are cut short until asked, because a well-travelled map can name hundreds of states and
 nobody opens this screen to scroll past all of them.
 */
private struct RegionSection: View {

    let title: String
    let entries: [RegionProgress]

    @State private var expanded = false

    private static let collapsedRows = 8

    var body: some View {
        if !entries.isEmpty {
            Section {
                ForEach(expanded ? entries : Array(entries.prefix(RegionSection.collapsedRows))) { entry in
                    RegionRow(entry: entry)
                }
                if entries.count > RegionSection.collapsedRows {
                    Button(expanded ? "Show fewer" : "Show all \(entries.count)") {
                        expanded.toggle()
                    }
                }
            } header: {
                Text("\(title) · \(entries.count)")
            } footer: {
                Text("Most covered first.")
            }
        }
    }
}

/**
 One region: what it is, how much of it you have covered, and what share that is.

 There is deliberately no progress bar. A bar scaled to the biggest row would say the top of every
 list is finished - a single-entry list would be permanently full - and a bar scaled to the true
 share is under a pixel wide at the fractions of a percent this app deals in. Either way it would
 be a picture that disagreed with the number printed beside it.
 */
private struct RegionRow: View {
    let entry: RegionProgress

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.region.name).lineLimit(2)
                if let parent = entry.parentName {
                    Text(parent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ExplorationStats.formatPercent(entry.percentExplored))
                    .font(.headline)
                    .monospacedDigit()
                Text(
                    "\(ExplorationStats.formatArea(entry.exploredSquareMeters)) of "
                        + ExplorationStats.formatArea(entry.region.areaSquareMeters)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
