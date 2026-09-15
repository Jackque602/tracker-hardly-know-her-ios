import Foundation
import SwiftUI
import UniformTypeIdentifiers
import RoamedCore

/**
 A finished export, waiting for the user to say where it should go.

 The file is written to the app's own temporary directory first and only then handed to the
 document picker. A backup of half a million cells is tens of megabytes of text, and building it
 in memory to satisfy a `FileDocument` would be a spike this app has no reason to take.
 */
struct ExportedFile: FileDocument {

    static var readableContentTypes: [UTType] { [.json, .xml, .data] }
    static var writableContentTypes: [UTType] { [.json, .xml, .data] }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: [])
    }
}

struct ExportRequest: Identifiable {
    let id = UUID()
    let document: ExportedFile
    let filename: String
    let contentType: UTType
}

enum ImportKind {
    case backup
    case tracks

    var contentTypes: [UTType] {
        switch self {
        case .backup: return [.json, .data]
        case .tracks: return [.json, .xml, .data]
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {

    @Published var message: String?
    @Published private(set) var busy = false
    @Published var pendingExport: ExportRequest?
    @Published var importing: ImportKind?

    private let exploration: ExplorationRepository
    private let settingsStore: SettingsStore
    private let appVersion: String

    init(exploration: ExplorationRepository, settingsStore: SettingsStore, appVersion: String) {
        self.exploration = exploration
        self.settingsStore = settingsStore
        self.appVersion = appVersion
    }

    // MARK: - Exports

    func exportBackup() {
        export(filename: "roamed-backup.json", contentType: .json) { sink in
            try await self.exploration.writeBackup(to: sink, appVersion: self.appVersion)
        }
    }

    func exportGeoJson() {
        export(filename: "roamed-explored.geojson", contentType: .json) { sink in
            try await self.exploration.writeGeoJson(to: sink)
        }
    }

    func exportGpx() {
        export(filename: "roamed-track.gpx", contentType: .xml) { sink in
            try await self.exploration.writeGpx(to: sink)
        }
    }

    private func export(
        filename: String,
        contentType: UTType,
        write: @escaping (FileTextSink) async throws -> Void
    ) {
        Task {
            busy = true
            defer { busy = false }
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString)-\(filename)")
                let sink = try FileTextSink(url: url)
                try await write(sink)
                try sink.close()
                pendingExport = ExportRequest(
                    document: ExportedFile(url: url), filename: filename, contentType: contentType
                )
            } catch {
                message = "Export failed: \(error)"
            }
        }
    }

    func exportFinished(_ result: Result<URL, Error>) {
        switch result {
        case .success: message = "Saved."
        case .failure(let error):
            // Cancelling the picker reports as an error, and "you cancelled" is not news.
            if (error as NSError).code != NSUserCancelledError {
                message = "Export failed: \(error.localizedDescription)"
            }
        }
        pendingExport = nil
    }

    // MARK: - Imports

    func importFinished(_ kind: ImportKind, _ result: Result<[URL], Error>) {
        importing = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        switch kind {
        case .backup: importBackup(from: url)
        case .tracks: importTracks(from: url)
        }
    }

    private func importBackup(from url: URL) {
        Task {
            busy = true
            defer { busy = false }
            do {
                let text = try SettingsViewModel.readText(at: url)
                let added = try await exploration.importBackup(text)
                message = added == 0
                    ? "Nothing new in that backup - the map already had all of it."
                    : "Added \(added) squares from the backup."
            } catch {
                message = "Import failed: \(error)"
            }
        }
    }

    /**
     Uncovers a trip recorded by something else - a Google Timeline export, or a GPX from any other
     tracker - so a journey this app missed is not lost for good.
     */
    private func importTracks(from url: URL) {
        Task {
            busy = true
            defer { busy = false }
            do {
                let text = try SettingsViewModel.readText(at: url)
                let settings = settingsStore.settings
                let tracks = try await Task.detached(priority: .userInitiated) {
                    try TrackImport.parse(text)
                }.value
                guard !tracks.isEmpty else {
                    message = "No positions found in that file."
                    return
                }
                let imported = try await exploration.importTracks(tracks, settings: settings)
                message = imported.newCells == 0
                    ? "Read \(imported.pointCount) positions, but that ground was already uncovered."
                    : "Uncovered \(imported.newCells) new squares from \(imported.pointCount) "
                        + "positions across \(imported.trackCount) trips."
            } catch {
                message = "Import failed: \(error)"
            }
        }
    }

    /// Files chosen through the picker live outside the sandbox and have to be unlocked first.
    private static func readText(at url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Erase

    func eraseEverything() {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await exploration.clearEverything()
                message = "Everything erased. The map is fogged over again."
            } catch {
                message = "Could not erase everything: \(error)"
            }
        }
    }
}
