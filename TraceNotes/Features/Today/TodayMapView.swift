import MapKit
import SwiftUI

/// MKMapView wrapper (D27). Moves are drawn by `TrackCanvas` as smooth curves in screen-point
/// widths from the render cache (VS3, D39); each stay is one dot at its centre, so drift while
/// still never shows as a scribble (F3). Everything is drawn in display coordinates (D31).
struct TodayMapView: UIViewRepresentable {
  let segments: [Segment]
  /// The day's points, oldest first; the open move takes its points from here by time.
  let points: [RawPoint]
  /// Simplified levels of completed moves, by segment ID.
  let renderCache: [Int64: [[RenderCache.Coordinate]]]
  /// Set when the user picks a timeline row; a new value moves the map there.
  let focus: MapFocus?
  /// Height covered by the timeline panel at the bottom, in points.
  let bottomInset: CGFloat

  func makeUIView(context: Context) -> MKMapView {
    let map = MKMapView()
    map.delegate = context.coordinator
    map.showsUserLocation = true
    // Muted (near-monochrome) base map, so the coloured track stands out, with increased contrast
    // so roads and names stay readable (D35).
    let configuration = MKStandardMapConfiguration(emphasisStyle: .muted)
    configuration.pointOfInterestFilter = .excludingAll
    map.preferredConfiguration = configuration
    map.traitOverrides.accessibilityContrast = .high
    // The canvas draws the day with one flat map-to-screen transform (D39).
    map.isPitchEnabled = false
    context.coordinator.attach(to: map)
    return map
  }

  func updateUIView(_ map: MKMapView, context: Context) {
    context.coordinator.show(segments: segments, points: points, renderCache: renderCache, on: map, bottomInset: bottomInset)
    if let focus { context.coordinator.move(to: focus, on: map, bottomInset: bottomInset) }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator: NSObject, MKMapViewDelegate {
    /// What is drawn for each segment, keyed by its start, so unchanged segments are kept.
    private var drawn: [Date: (signature: Signature, item: Drawn)] = [:]
    private var tracks = TrackGeometry()
    /// The render-cache level the canvas's path was built from.
    private var drawnLevel: Int?
    private var hasFramedDay = false
    private var shownFocus: UUID?
    private let canvas = TrackCanvas()
    /// Room around framed content, in points (plus the panel's height at the bottom).
    private static let padding = UIEdgeInsets(top: 120, left: 40, bottom: 40, right: 40)

    private struct Signature: Equatable {
      var kind: Segment.Kind
      var end: Date
      var pointCount: Int
    }

    private enum Drawn {
      /// Lives in `tracks` under the segment's start.
      case track(MKMapRect)
      case stay(MKMapPoint)
    }

    func attach(to map: MKMapView) {
      // Light and dark mode resolve the colours differently (D23).
      map.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [canvas] (map: MKMapView, _) in
        canvas.redraw(on: map)
      }
    }

    /// Rebuilds the canvas's path when the tracks changed or the zoom needs another level.
    private func redrawTracks(on map: MKMapView, force: Bool) {
      let level = Self.level(on: map)
      guard force || drawnLevel != level else { return }
      drawnLevel = level
      let origin = tracks.origin
      canvas.setTracks(origin.map { tracks.path(atLevel: level, origin: $0) }, origin: origin ?? MKMapPoint(x: 0, y: 0))
    }

    func show(segments: [Segment], points: [RawPoint], renderCache: [Int64: [[RenderCache.Coordinate]]], on map: MKMapView, bottomInset: CGFloat) {
      var changes: [Date: TrackGeometry.Track?] = [:]
      let wanted = Dictionary(segments.map { ($0.start, $0) }, uniquingKeysWith: { _, newer in newer })
      for (start, entry) in drawn where wanted[start].map({ Self.signature(of: $0) != entry.signature }) ?? true {
        switch entry.item {
        case .track: changes[start] = .some(nil)
        case .stay: break
        }
        drawn[start] = nil
      }
      for (index, segment) in segments.enumerated() where drawn[segment.start] == nil {
        switch segment.kind {
        case .move:
          // Completed moves come from the render cache; the open one (or one whose cache has not
          // arrived yet) is simplified here.
          let levels = segment.id.flatMap { renderCache[$0] }
            ?? RenderCache.levels(
              of: RenderCache.track(
                ofMove: MapFocus.points(of: segment, in: points), isComplete: segment.isComplete,
                from: index > 0 ? segments[index - 1].stayCenter : nil,
                to: index + 1 < segments.count ? segments[index + 1].stayCenter : nil))
          guard let track = TrackGeometry.Track(levels: levels.map { $0.map(DisplayProjection.shared.mapPoint) }) else { continue }
          changes[segment.start] = .some(track)
          drawn[segment.start] = (Self.signature(of: segment), .track(track.boundingRect))
        case .stay:
          guard let latitude = segment.centerLatitude, let longitude = segment.centerLongitude else { continue }
          drawn[segment.start] = (Self.signature(of: segment), .stay(DisplayProjection.shared.mapPoint((latitude, longitude))))
        case .gap:
          continue  // VS6 explains gaps (and draws the dashed subway link)
        }
      }
      if !changes.isEmpty {
        tracks.update(changes)
        redrawTracks(on: map, force: true)
      }
      canvas.setStays(segments.compactMap { segment in
        guard case .stay(let point)? = drawn[segment.start]?.item else { return nil }
        return point
      })
      canvas.redraw(on: map)
      canvas.keepAnchorsNearCentre(on: map)

      // Frame the day once, when everything drawable is drawn (segments can arrive before their
      // points); afterwards the user's own panning and zooming wins.
      let waitingForPoints = segments.contains { $0.kind == .move && $0.pointCount > 1 && drawn[$0.start] == nil }
      if !hasFramedDay, !waitingForPoints, let rect = boundingRect() {
        hasFramedDay = true
        map.setVisibleMapRect(rect, edgePadding: Self.edgePadding(bottomInset), animated: false)
      }
    }

    func move(to focus: MapFocus, on map: MKMapView, bottomInset: CGFloat) {
      guard focus.id != shownFocus else { return }
      shownFocus = focus.id
      hasFramedDay = true
      map.setVisibleMapRect(focus.rect, edgePadding: Self.edgePadding(bottomInset), animated: true)
    }

    private func boundingRect() -> MKMapRect? {
      let rects = drawn.values.map { entry -> MKMapRect in
        switch entry.item {
        case .track(let rect): rect
        case .stay(let point): MapFocus.around(point.coordinate).rect
        }
      }
      guard let first = rects.first else { return nil }
      return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func signature(of segment: Segment) -> Signature {
      Signature(kind: segment.kind, end: segment.end, pointCount: segment.pointCount)
    }

    private static func edgePadding(_ bottomInset: CGFloat) -> UIEdgeInsets {
      var padding = padding
      padding.bottom += bottomInset
      return padding
    }

    /// The render-cache level whose simplification stays under half a screen point here.
    private static func level(on map: MKMapView) -> Int {
      let visible = map.visibleMapRect
      guard map.bounds.width > 0, visible.width > 0 else { return 0 }
      let latitude = MKMapPoint(x: visible.midX, y: visible.midY).coordinate.latitude
      let metresPerPoint = visible.width / map.bounds.width / MKMapPointsPerMeterAtLatitude(latitude)
      return RenderCache.level(forMetresPerPoint: metresPerPoint)
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
      redrawTracks(on: mapView, force: false)
      canvas.keepAnchorsNearCentre(on: mapView)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
      canvas.mapDidSettle(mapView)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
      // nil keeps the system user-location view.
      (annotation as? TrackCanvas.Anchor).map(canvas.view(for:))
    }

    func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
      for view in views { canvas.adopt(view, on: mapView) }
    }
  }
}

/// Where the map should go when a timeline row is picked.
struct MapFocus: Equatable {
  let id = UUID()
  let rect: MKMapRect

  static func == (lhs: MapFocus, rhs: MapFocus) -> Bool { lhs.id == rhs.id }

  /// Smallest span shown around a single place, in metres.
  static let minimumSpan: CLLocationDistance = 400

  static func around(_ coordinate: CLLocationCoordinate2D, radius: CLLocationDistance = 0) -> MapFocus {
    let span = max(minimumSpan, radius * 2.5)
    let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: span, longitudinalMeters: span)
    let topLeft = MKMapPoint(CLLocationCoordinate2D(
      latitude: region.center.latitude + region.span.latitudeDelta / 2,
      longitude: region.center.longitude - region.span.longitudeDelta / 2))
    let bottomRight = MKMapPoint(CLLocationCoordinate2D(
      latitude: region.center.latitude - region.span.latitudeDelta / 2,
      longitude: region.center.longitude + region.span.longitudeDelta / 2))
    return MapFocus(rect: MKMapRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y))
  }

  /// A stay: its centre and radius. A move: its points. A gap: the points on either side of it.
  static func of(_ segment: Segment, in points: [RawPoint]) -> MapFocus? {
    switch segment.kind {
    case .stay:
      guard let latitude = segment.centerLatitude, let longitude = segment.centerLongitude else { return nil }
      return around(DisplayProjection.shared.mapPoint((latitude, longitude)).coordinate, radius: segment.radius ?? 0)
    case .move:
      return enclosing(self.points(of: segment, in: points).map(\.displayCoordinate))
    case .gap:
      let before = points.last { $0.timestamp <= segment.start && !$0.flags.contains(.replayed) }
      let after = points.first { $0.timestamp >= segment.end && !$0.flags.contains(.replayed) }
      return enclosing([before, after].compactMap { $0?.displayCoordinate })
    }
  }

  /// The non-replayed points with `start <= timestamp <= end`, found by binary search.
  static func points(of segment: Segment, in points: [RawPoint]) -> [RawPoint] {
    let lower = points.partitioningIndex { $0.timestamp >= segment.start }
    let upper = points.partitioningIndex { $0.timestamp > segment.end }
    guard lower < upper else { return [] }
    return points[lower..<upper].filter { !$0.flags.contains(.replayed) }
  }

  private static func enclosing(_ coordinates: [CLLocationCoordinate2D]) -> MapFocus? {
    guard let first = coordinates.first else { return nil }
    guard coordinates.count > 1 else { return around(first) }
    let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
    let rect = line.boundingMapRect
    let minimum = around(first).rect
    guard rect.size.width < minimum.size.width, rect.size.height < minimum.size.height else { return MapFocus(rect: rect) }
    return around(MKMapPoint(x: rect.midX, y: rect.midY).coordinate)
  }
}

extension RawPoint {
  /// Where the point is drawn (D31); never stored.
  var displayCoordinate: CLLocationCoordinate2D {
    DisplayProjection.shared.mapPoint((latitude, longitude)).coordinate
  }
}

extension Array {
  /// The first index whose element satisfies `belongsInSecondPartition`, for an array already
  /// partitioned by it (false…false, true…true).
  fileprivate func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Int {
    var low = startIndex
    var high = endIndex
    while low < high {
      let middle = low + (high - low) / 2
      if belongsInSecondPartition(self[middle]) { high = middle } else { low = middle + 1 }
    }
    return low
  }
}
