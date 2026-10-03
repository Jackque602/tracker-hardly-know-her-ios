import SwiftUI
import MapKit
import RoamedCore

@MainActor
struct MapScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var tracker: LocationTracker
    @StateObject private var viewModel: MapViewModel

    @State private var command: MapCommand?
    @State private var followMe = true

    init(container: AppContainer) {
        _viewModel = StateObject(
            wrappedValue: MapViewModel(
                exploration: container.exploration,
                settingsStore: container.settings
            )
        )
    }

    private var settings: RoamedSettings { settingsStore.settings }

    var body: some View {
        ZStack {
            FogMapView(
                index: viewModel.index,
                airIndex: viewModel.airIndex,
                settings: settings,
                trail: viewModel.trail,
                lastFix: viewModel.fogState.lastFix,
                fogVersion: viewModel.fogState.version,
                followMe: $followMe,
                command: $command
            )
            .ignoresSafeArea(edges: .top)

            VStack {
                FogSummaryCard(
                    cellCount: viewModel.fogState.cellCount,
                    areaSquareMeters: viewModel.fogState.areaSquareMeters
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                notice
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    controls.padding(16)
                }
            }
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let failure = container.storageFailure {
            NoticeCard(
                title: "Nothing is being saved",
                message: failure,
                actionLabel: nil,
                onAction: nil
            )
            .padding(16)
        } else if !tracker.canTrack {
            NoticeCard(
                title: "Roamed needs your location",
                message: "Nothing gets uncovered until the app can see where you are. Your "
                    + "positions stay on this phone.",
                actionLabel: "Allow location",
                onAction: tracker.requestForegroundAuthorization
            )
            .padding(16)
        } else if !tracker.canTrackInBackground {
            NoticeCard(
                title: "Keep uncovering in the background",
                message: "Right now the map only fills in while Roamed is open. Choose \"Always\" "
                    + "to have it keep up with you.",
                actionLabel: "Allow always",
                onAction: tracker.requestBackgroundAuthorization
            )
            .padding(16)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            // Nothing uncovered means nothing to frame, and a button that does nothing when
            // pressed is worse than one that is not there.
            if viewModel.fogState.cellCount > 0 {
                CircleButton(systemImage: "arrow.down.left.and.arrow.up.right", small: true) {
                    Task {
                        if let bounds = await viewModel.exploredBounds() {
                            // An explicit fit should stick, so stop the next fix recentring.
                            followMe = false
                            command = .fit(bounds)
                        }
                    }
                }
                .accessibilityLabel("Fit everywhere I have been")
            }

            CircleButton(systemImage: "location", small: false) {
                if let fix = viewModel.fogState.lastFix {
                    command = .center(
                        CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
                    )
                } else {
                    followMe = true
                }
            }
            .accessibilityLabel("Centre on me")

            CircleButton(
                systemImage: settings.trackingEnabled ? "pause.fill" : "play.fill",
                small: false,
                tint: settings.trackingEnabled ? RoamedTheme.amber : RoamedTheme.accent
            ) {
                let turningOn = !settings.trackingEnabled
                if turningOn && !tracker.canTrack {
                    tracker.requestForegroundAuthorization()
                }
                settingsStore.setTrackingEnabled(turningOn)
            }
            .accessibilityLabel(settings.trackingEnabled ? "Pause tracking" : "Start tracking")
        }
    }
}

/// Something the SwiftUI side wants the map to do once, rather than on every redraw.
enum MapCommand: Equatable {
    case center(CLLocationCoordinate2D)
    case fit(GeoBounds)

    static func == (lhs: MapCommand, rhs: MapCommand) -> Bool {
        switch (lhs, rhs) {
        case (.center(let a), .center(let b)):
            return a.latitude == b.latitude && a.longitude == b.longitude
        case (.fit(let a), .fit(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// The map itself: MapKit underneath, the fog on top of it, the trail on top of that.
private struct FogMapView: UIViewRepresentable {

    let index: ExploredIndex
    let airIndex: ExploredIndex
    let settings: RoamedSettings
    let trail: [[TrailPoint]]
    let lastFix: Fix?
    /// Bumped by the repository on every change, which is what tells the renderer to redraw.
    let fogVersion: Int64
    @Binding var followMe: Bool
    @Binding var command: MapCommand?

    /// About a 1.2 km box, which is roughly the Android build's "zoom 15".
    static let followSpanMeters: CLLocationDistance = 1_200

    /// Breathing room around the fitted box, so the fog edge is not flush against the screen.
    static let fitPadding = UIEdgeInsets(top: 72, left: 48, bottom: 112, right: 48)

    func makeCoordinator() -> Coordinator {
        Coordinator(index: index, airIndex: airIndex)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.isRotateEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.setCameraZoomRange(
            MKMapView.CameraZoomRange(minCenterCoordinateDistance: 150),
            animated: false
        )
        context.coordinator.attach(to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.redraw(ifChangedFrom: fogVersion)
        context.coordinator.apply(settings: settings, to: mapView)
        context.coordinator.apply(trail: trail, to: mapView)

        if let lastFix, followMe {
            mapView.setRegion(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: lastFix.latitude, longitude: lastFix.longitude),
                    latitudinalMeters: FogMapView.followSpanMeters,
                    longitudinalMeters: FogMapView.followSpanMeters
                ),
                animated: true
            )
            DispatchQueue.main.async { self.followMe = false }
        }

        if let command {
            context.coordinator.run(command, on: mapView)
            DispatchQueue.main.async { self.command = nil }
        }
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.detach(from: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {

        private let index: ExploredIndex
        private let airIndex: ExploredIndex
        private var fogOverlay: FogOverlay?
        private weak var fogRenderer: FogOverlayRenderer?
        private var trailOverlays: [MKPolyline] = []
        private var lastFogVersion: Int64 = -1
        private var lastTrailSignature = ""
        private var lastOpacity: Double = -1
        private var lastStyle: RoamedMapStyle?

        init(index: ExploredIndex, airIndex: ExploredIndex) {
            self.index = index
            self.airIndex = airIndex
            super.init()
        }

        func attach(to mapView: MKMapView) {
            let overlay = FogOverlay(index: index, airIndex: airIndex)
            fogOverlay = overlay
            mapView.addOverlay(overlay, level: .aboveRoads)
        }

        func detach(from mapView: MKMapView) {
            mapView.delegate = nil
        }

        /**
         Redraws the fog, but only when it has actually changed.

         MapKit has no idea a fix arrived, so something has to tell the renderer. The version
         counter is what makes that cheap: SwiftUI re-runs this view on every published change,
         and all but the ones that moved the fog return here immediately.
         */
        func redraw(ifChangedFrom version: Int64) {
            guard version != lastFogVersion else { return }
            lastFogVersion = version
            fogRenderer?.setNeedsDisplay()
        }

        func apply(settings: RoamedSettings, to mapView: MKMapView) {
            if lastStyle != settings.mapStyle {
                lastStyle = settings.mapStyle
                switch settings.mapStyle {
                case .standard:
                    mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
                case .satellite:
                    mapView.preferredConfiguration = MKImageryMapConfiguration()
                case .hybrid:
                    mapView.preferredConfiguration = MKHybridMapConfiguration()
                }
            }
            if lastOpacity != settings.fogOpacity {
                lastOpacity = settings.fogOpacity
                fogOverlay?.opacity = settings.fogOpacity
                fogRenderer?.setNeedsDisplay()
            }
        }

        func apply(trail: [[TrailPoint]], to mapView: MKMapView) {
            let signature = trail.reduce(into: "") { text, run in
                text += "\(run.count):\(run.last?.timestamp ?? 0)|"
            }
            guard signature != lastTrailSignature else { return }
            lastTrailSignature = signature

            mapView.removeOverlays(trailOverlays)
            trailOverlays = trail.map { run in
                var coordinates = run.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                return MKPolyline(coordinates: &coordinates, count: coordinates.count)
            }
            if !trailOverlays.isEmpty {
                mapView.addOverlays(trailOverlays, level: .aboveLabels)
            }
        }

        func run(_ command: MapCommand, on mapView: MKMapView) {
            switch command {
            case .center(let coordinate):
                mapView.setRegion(
                    MKCoordinateRegion(
                        center: coordinate,
                        latitudinalMeters: FogMapView.followSpanMeters,
                        longitudinalMeters: FogMapView.followSpanMeters
                    ),
                    animated: true
                )
            case .fit(let bounds):
                mapView.setVisibleMapRect(
                    Coordinator.mapRect(for: bounds),
                    edgePadding: FogMapView.fitPadding,
                    animated: true
                )
            }
        }

        /**
         A map rectangle for a box that may run off the eastern edge of the world and back in from
         the west.

         MapKit is happy with a rect that extends past the world's width; what it will not do is
         guess that a box from +139 to -122 means the Pacific rather than everywhere else.
         */
        static func mapRect(for bounds: GeoBounds) -> MKMapRect {
            let topLeft = MKMapPoint(
                CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west)
            )
            var bottomRight = MKMapPoint(
                CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.east)
            )
            if bounds.crossesAntimeridian { bottomRight.x += MKMapSize.world.width }
            // A single uncovered cell is 300 m across; without a floor, fitting one would slam to
            // maximum zoom and show a single square.
            let minimum = MKMapSize.world.width / 8_192
            return MKMapRect(
                x: topLeft.x,
                y: topLeft.y,
                width: max(bottomRight.x - topLeft.x, minimum),
                height: max(bottomRight.y - topLeft.y, minimum)
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let fog = overlay as? FogOverlay {
                let renderer = FogOverlayRenderer(overlay: fog)
                fogRenderer = renderer
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor(RoamedTheme.trail).withAlphaComponent(0.8)
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

private struct FogSummaryCard: View {
    let cellCount: Int
    let areaSquareMeters: Double

    var body: some View {
        HStack(spacing: 24) {
            Stat(
                value: ExplorationStats.formatPercent(
                    ExplorationStats.percentOfEarthLand(areaSquareMeters)
                ),
                label: "of Earth's land"
            )
            Stat(value: ExplorationStats.formatArea(areaSquareMeters), label: "uncovered")
            Stat(value: "\(cellCount)", label: "squares")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 6, y: 2)
    }

    private struct Stat: View {
        let value: String
        let label: String

        var body: some View {
            VStack(spacing: 2) {
                Text(value).font(.headline).monospacedDigit()
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NoticeCard: View {
    let title: String
    let message: String
    let actionLabel: String?
    let onAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            if let actionLabel, let onAction {
                Button(actionLabel, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 8, y: 2)
    }
}

private struct CircleButton: View {
    let systemImage: String
    let small: Bool
    var tint: Color = RoamedTheme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: small ? 16 : 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: small ? 40 : 56, height: small ? 40 : 56)
                .background(tint, in: Circle())
                .shadow(radius: 6, y: 2)
        }
    }
}
