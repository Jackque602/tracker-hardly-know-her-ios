import SwiftUI
import UniformTypeIdentifiers
import RoamedCore

@MainActor
struct SettingsScreen: View {

    @EnvironmentObject private var settingsStore: SettingsStore
    @StateObject private var viewModel: SettingsViewModel
    @State private var confirmingErase = false

    private let appVersion: String

    init(container: AppContainer) {
        self.appVersion = container.appVersion
        _viewModel = StateObject(
            wrappedValue: SettingsViewModel(
                exploration: container.exploration,
                settingsStore: container.settings,
                appVersion: container.appVersion
            )
        )
    }

    private var settings: RoamedSettings { settingsStore.settings }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.busy {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }

                recording
                uncovering
                map
                data

                Section {
                    Text("Roamed \(appVersion)\nMap data © Apple and its data providers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileExporter(
            isPresented: Binding(
                get: { viewModel.pendingExport != nil },
                set: { if !$0 { viewModel.pendingExport = nil } }
            ),
            document: viewModel.pendingExport?.document,
            contentType: viewModel.pendingExport?.contentType ?? .data,
            defaultFilename: viewModel.pendingExport?.filename
        ) { result in
            viewModel.exportFinished(result)
        }
        .fileImporter(
            isPresented: Binding(
                get: { viewModel.importing != nil },
                set: { if !$0 { viewModel.importing = nil } }
            ),
            allowedContentTypes: viewModel.importing?.contentTypes ?? [.data],
            allowsMultipleSelection: false
        ) { result in
            if let kind = viewModel.importing {
                viewModel.importFinished(kind, result)
            }
        }
        .alert(
            "Erase everything?",
            isPresented: $confirmingErase,
            actions: {
                Button("Erase", role: .destructive) { viewModel.eraseEverything() }
                Button("Keep it", role: .cancel) {}
            },
            message: {
                Text(
                    "This deletes every uncovered square, every recorded fix and every statistic. "
                        + "It cannot be undone - export a backup first if you might want it back."
                )
            }
        )
        .alert(
            "Roamed",
            isPresented: Binding(
                get: { viewModel.message != nil },
                set: { if !$0 { viewModel.message = nil } }
            ),
            actions: { Button("OK", role: .cancel) { viewModel.message = nil } },
            message: { Text(viewModel.message ?? "") }
        )
    }

    private var recording: some View {
        Section("Recording") {
            SliderRow(
                label: "Check position every",
                display: "\(settings.updateIntervalSeconds) s",
                value: Double(settings.updateIntervalSeconds),
                range: 5...300,
                step: 1
            ) { settingsStore.setUpdateInterval(Int($0.rounded())) }

            SliderRow(
                label: "Only after moving",
                display: "\(settings.minDisplacementMeters) m",
                value: Double(settings.minDisplacementMeters),
                range: 0...200,
                step: 1
            ) { settingsStore.setMinDisplacement(Int($0.rounded())) }

            SwitchRow(
                label: "Use GPS",
                description: "On, positions come from GPS. Off saves battery by leaning on WiFi and "
                    + "cell towers instead, which is only accurate near towns - away from them the "
                    + "fixes get too vague to record and your trip goes missing.",
                isOn: settings.highAccuracyMode,
                onChange: settingsStore.setHighAccuracyMode
            )

            SwitchRow(
                label: "Join up the dots",
                description: "Fills the gap between two fixes so driving leaves a continuous trail.",
                isOn: settings.connectTheDots,
                onChange: settingsStore.setConnectTheDots
            )

            SwitchRow(
                label: "Uncover flight paths",
                description: "Two fixes far apart and fast enough to have been a flight uncover the "
                    + "great circle between them, tinted blue so you can tell it from ground you "
                    + "actually travelled. It counts towards every figure the same as driven ground.",
                isOn: settings.uncoverFlightPaths,
                onChange: settingsStore.setUncoverFlightPaths
            )
        }
    }

    private var uncovering: some View {
        Section("Uncovering") {
            SliderRow(
                label: "Reveal radius",
                display: "\(settings.revealRadiusMeters) m",
                value: Double(settings.revealRadiusMeters),
                range: 25...500,
                step: 5
            ) { settingsStore.setRevealRadius(Int($0.rounded())) }

            SliderRow(
                label: "Ignore fixes worse than",
                display: "\(settings.maxAccuracyMeters) m",
                value: Double(settings.maxAccuracyMeters),
                range: 10...300,
                step: 5
            ) { settingsStore.setMaxAccuracy(Int($0.rounded())) }

            SliderRow(
                label: "Fog thickness",
                display: "\(Int((settings.fogOpacity * 100).rounded()))%",
                value: settings.fogOpacity,
                range: 0.2...1.0,
                step: 0.01
            ) { settingsStore.setFogOpacity($0) }
        }
    }

    private var map: some View {
        Section("Map") {
            Picker("Style", selection: Binding(
                get: { settings.mapStyle },
                set: { settingsStore.setMapStyle($0) }
            )) {
                ForEach(RoamedMapStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)

            SwitchRow(
                label: "Show today's trail",
                description: "Draws the last 24 hours of fixes on top of the fog.",
                isOn: settings.showTrail,
                onChange: settingsStore.setShowTrail
            )

            SwitchRow(
                label: "Name countries and regions",
                description: "Looks up new areas so the stats screen can count countries. Needs a "
                    + "connection, and the lookup is the one thing here that leaves the phone.",
                isOn: settings.resolvePlaces,
                onChange: settingsStore.setResolvePlaces
            )
        }
    }

    private var data: some View {
        Section {
            SliderRow(
                label: "Keep raw fixes for",
                display: settings.keepRawFixesDays == 0 ? "don't store" : "\(settings.keepRawFixesDays) days",
                value: Double(settings.keepRawFixesDays),
                range: 0...1_095,
                step: 1
            ) { settingsStore.setKeepRawFixesDays(Int($0.rounded())) }

            Text(
                "The uncovered map is kept forever either way - this only affects the raw trail "
                    + "used for the overlay and GPX export."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button("Export backup") { viewModel.exportBackup() }
            Button("Import backup") { viewModel.importing = .backup }
            Button("Uncover a trip from Timeline or GPX") { viewModel.importing = .tracks }
            Text(
                "Fills in a journey this app missed, from a Google Maps Timeline export or a GPX "
                    + "file from any other tracker."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button("Export uncovered area as GeoJSON") { viewModel.exportGeoJson() }
            Button("Export trail as GPX") { viewModel.exportGpx() }

            Button("Erase everything", role: .destructive) { confirmingErase = true }
        } header: {
            Text("Your data")
        } footer: {
            Text("Everything stays on this phone. Nothing is uploaded anywhere.")
        }
    }
}

private struct SliderRow: View {
    let label: String
    let display: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(display).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(
                value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: onChange),
                in: range,
                step: step
            )
        }
        .padding(.vertical, 2)
    }
}

private struct SwitchRow: View {
    let label: String
    let description: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: onChange)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
