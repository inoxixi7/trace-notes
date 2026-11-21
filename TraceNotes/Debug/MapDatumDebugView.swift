#if DEBUG
import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

/// S2 debug page (Debug builds only): draws a stored WGS-84 track as-is (red) and as the display
/// layer would draw it (blue, `MapDatumPolicy`), and lists every candidate datum signal next to
/// the final decision. Used for the mainland-China device test in docs/spikes/S2-result.md.
/// Nothing here is logged; on-screen device position is reduced to inside/outside and distances.
struct MapDatumDebugView: View {
  @State private var model = MapDatumDebugModel()

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        MapDatumDebugMap(
          raw: model.rawPoints,
          display: model.displayPoints,
          revision: model.revision,
          onSignals: { model.mapSignals = $0 }
        )
        Form {
          sourceSection
          signalsSection
        }
        .frame(height: 360)
      }
      .navigationTitle(Text(verbatim: "S2 · Map datum"))
      .navigationBarTitleDisplayMode(.inline)
    }
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }

  private var sourceSection: some View {
    Section {
      Picker(selection: $model.source) {
        ForEach(MapDatumPresetRoutes.all) { route in
          Text(verbatim: route.title).tag(MapDatumDebugModel.Source.preset(route.id))
        }
        Text(verbatim: "Manual coordinates").tag(MapDatumDebugModel.Source.manual)
      } label: {
        Text(verbatim: "Track")
      }
      if model.source == .manual {
        TextField(
          text: $model.manualText,
          prompt: Text(verbatim: "lat, lon — one point per line"),
          axis: .vertical
        ) {
          Text(verbatim: "Coordinates")
        }
        .lineLimit(2...5)
        .font(.footnote.monospaced())
        .keyboardType(.numbersAndPunctuation)
        .autocorrectionDisabled()
        Button { model.applyManual() } label: { Text(verbatim: "Draw") }
        if let manualError = model.manualError {
          Text(verbatim: manualError).foregroundStyle(.red)
        }
      }
    } header: {
      Text(verbatim: "Red = stored WGS-84 · Blue = displayed")
    }
  }

  private var signalsSection: some View {
    Section {
      if let loadError = model.loadError {
        Text(verbatim: loadError).foregroundStyle(.red)
      }
      row("Decision (polygon, per point)", model.decisionSummary)
      row("Device location in mainland", model.deviceInMainlandSummary)
      row("Locale region", model.localeRegion)
      row("MapKit attribution", "read the logo at the map's bottom left")
      row("MapKit userLocation − Core Location", model.userLocationSummary)
    } header: {
      Text(verbatim: "Signals")
    } footer: {
      Text(
        verbatim:
          "Only the polygon decides. The other rows are evidence for the mainland device test."
      )
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    LabeledContent {
      Text(verbatim: value).multilineTextAlignment(.trailing).textSelection(.enabled)
    } label: {
      Text(verbatim: title)
    }
    .font(.footnote)
  }
}

// MARK: - Model

@Observable
final class MapDatumDebugModel: NSObject, CLLocationManagerDelegate {
  enum Source: Hashable {
    case preset(String)
    case manual
  }

  var source: Source = .preset(MapDatumPresetRoutes.all[0].id) {
    didSet { recompute() }
  }
  var manualText = ""
  private(set) var manualError: String?
  private(set) var loadError: String?
  private(set) var rawPoints: [CLLocationCoordinate2D] = []
  private(set) var displayPoints: [CLLocationCoordinate2D] = []
  /// Bumped whenever the drawn track changes, so the map only redraws then.
  private(set) var revision = 0
  private(set) var deviceLocation: CLLocation?
  private(set) var locationError: String?
  var mapSignals = MapDatumDebugMap.Signals()

  @ObservationIgnored private var policy: MapDatumPolicy?
  @ObservationIgnored private var manualPoints: [CLLocationCoordinate2D] = []
  @ObservationIgnored private let locationManager = CLLocationManager()

  /// Loads the boundary once and follows the device location while the page is visible.
  func start() {
    if policy == nil, loadError == nil {
      do {
        policy = MapDatumPolicy(mainland: try ChinaMainlandRegion.bundled())
      } catch {
        loadError = "Boundary data failed to load: \(error)"
      }
      locationManager.delegate = self
      recompute()
    }
    startLocationUpdates()
  }

  func stop() {
    locationManager.stopUpdatingLocation()
  }

  func applyManual() {
    var points: [CLLocationCoordinate2D] = []
    for (index, line) in manualText.split(whereSeparator: \.isNewline).enumerated() {
      let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2,
        let latitude = Double(parts[0]), let longitude = Double(parts[1]),
        CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
      else {
        manualError = "Line \(index + 1): expected \"latitude, longitude\""
        return
      }
      points.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }
    guard !points.isEmpty else {
      manualError = "Enter at least one point"
      return
    }
    manualError = nil
    manualPoints = points
    recompute()
  }

  private func startLocationUpdates() {
    switch locationManager.authorizationStatus {
    case .notDetermined:
      locationManager.requestWhenInUseAuthorization()
    case .denied, .restricted:
      locationError = "Location permission denied"
    case .authorizedAlways, .authorizedWhenInUse:
      locationManager.startUpdatingLocation()
    @unknown default:
      locationError = "Unknown authorization status"
    }
  }

  private func recompute() {
    switch source {
    case .preset(let id):
      let route = MapDatumPresetRoutes.all.first { $0.id == id }
      rawPoints = (route?.points ?? []).map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
    case .manual:
      rawPoints = manualPoints
    }
    displayPoints = policy?.displayCoordinates(for: rawPoints) ?? rawPoints
    revision += 1
  }

  // MARK: Signal summaries

  var decisionSummary: String {
    guard let policy else { return "unavailable" }
    guard !rawPoints.isEmpty else { return "no points" }
    let converted = rawPoints.filter { policy.datum(at: $0) == .gcj02 }.count
    switch converted {
    case 0: return "WGS-84 (0/\(rawPoints.count) converted)"
    case rawPoints.count: return "GCJ-02 (\(converted)/\(rawPoints.count) converted)"
    default: return "Mixed (\(converted)/\(rawPoints.count) converted)"
    }
  }

  var deviceInMainlandSummary: String {
    if let locationError { return locationError }
    guard let deviceLocation else { return "waiting" }
    guard let policy else { return "unavailable" }
    let inside = policy.datum(at: deviceLocation.coordinate) == .gcj02
    return "\(inside ? "yes" : "no") (±\(Int(deviceLocation.horizontalAccuracy)) m)"
  }

  var localeRegion: String {
    Locale.current.region?.identifier ?? "none"
  }

  /// Compares the latest fixes from both sides; both follow the same device location while the
  /// page is visible, so a large value right after a jump settles once both have updated.
  var userLocationSummary: String {
    guard let mapLocation = mapSignals.userLocation, let deviceLocation else { return "waiting" }
    let delta = mapLocation.distance(from: deviceLocation)
    let gcjOffset = deviceLocation.distance(
      from: CLLocation(coordinate: GCJ02.fromWGS84(deviceLocation.coordinate)))
    return "\(Int(delta)) m (GCJ offset here \(Int(gcjOffset)) m)"
  }

  // MARK: CLLocationManagerDelegate

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      locationError = nil
      manager.startUpdatingLocation()
    case .denied, .restricted:
      locationError = "Location permission denied"
    case .notDetermined:
      break
    @unknown default:
      locationError = "Unknown authorization status"
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    locationError = nil
    deviceLocation = location
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    locationError = "Location failed: \(error.localizedDescription)"
  }
}

private extension CLLocation {
  convenience init(coordinate: CLLocationCoordinate2D) {
    self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
  }
}

// MARK: - Map

struct MapDatumDebugMap: UIViewRepresentable {
  struct Signals: Equatable {
    /// MapKit's user-location annotation, compared with Core Location's fix by the model.
    var userLocation: CLLocation?
  }

  let raw: [CLLocationCoordinate2D]
  let display: [CLLocationCoordinate2D]
  let revision: Int
  let onSignals: (Signals) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> MKMapView {
    let mapView = MKMapView()
    mapView.delegate = context.coordinator
    mapView.showsUserLocation = true
    return mapView
  }

  func updateUIView(_ mapView: MKMapView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onSignals = onSignals
    guard coordinator.drawnRevision != revision else { return }
    coordinator.drawnRevision = revision

    mapView.removeOverlays(mapView.overlays)
    guard !raw.isEmpty else { return }
    let rawLine = MKPolyline(coordinates: raw, count: raw.count)
    rawLine.title = Coordinator.rawTitle
    let displayLine = MKPolyline(coordinates: display, count: display.count)
    displayLine.title = Coordinator.displayTitle
    mapView.addOverlays([rawLine, displayLine])
    mapView.setVisibleMapRect(
      rawLine.boundingMapRect.union(displayLine.boundingMapRect),
      edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 40, right: 40),
      animated: false
    )
  }

  final class Coordinator: NSObject, MKMapViewDelegate {
    static let rawTitle = "raw"
    static let displayTitle = "display"

    var onSignals: (Signals) -> Void = { _ in }
    var drawnRevision: Int?
    private var signals = Signals()

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
      guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
      let renderer = MKPolylineRenderer(polyline: line)
      let isRaw = line.title == Self.rawTitle
      renderer.strokeColor = isRaw ? .systemRed : .systemBlue
      renderer.lineWidth = isRaw ? 5 : 3
      renderer.alpha = 0.85
      return renderer
    }

    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
      guard let location = userLocation.location else { return }
      update { $0.userLocation = location }
    }

    private func update(_ change: (inout Signals) -> Void) {
      var next = signals
      change(&next)
      guard next != signals else { return }
      signals = next
      onSignals(next)
    }
  }
}
#endif
