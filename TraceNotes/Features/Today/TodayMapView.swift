import MapKit
import SwiftUI

/// MKMapView wrapper (D27). Moves are drawn by `TrackOverlay` as smooth curves in screen-pixel
/// widths from the render cache (VS3); each stay is one marker at its centre, so drift while still
/// never shows as a scribble (F3). Everything is drawn in display coordinates (D31).
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
    map.pointOfInterestFilter = .excludingAll
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
    /// The overlays now on the map: the background-coloured outline below the line, and the
    /// render-cache level they were built from.
    private var trackOverlays: (casing: MKMultiPolyline, line: MKMultiPolyline, level: Int)?
    private var hasFramedDay = false
    private var shownFocus: UUID?
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
      case stay(MKPointAnnotation)
    }

    /// Screen points, the same at every zoom level (F7).
    private static let lineWidth: CGFloat = 5
    private static let casingWidth: CGFloat = 8

    func attach(to map: MKMapView) {
      // Light and dark mode resolve the colours differently (D23).
      map.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (map: MKMapView, _) in
        guard let overlays = self?.trackOverlays else { return }
        for (overlay, isCasing) in [(overlays.casing, true), (overlays.line, false)] {
          guard let renderer = map.renderer(for: overlay) as? MKMultiPolylineRenderer else { continue }
          renderer.strokeColor = Self.color(casing: isCasing, on: map)
          renderer.setNeedsDisplay()
        }
      }
    }

    /// Replaces the track overlays when the tracks changed or the zoom needs another level.
    private func redrawTracks(on map: MKMapView, force: Bool) {
      let level = Self.level(on: map)
      guard force || trackOverlays.map({ $0.level != level }) ?? true else { return }
      let old = trackOverlays
      trackOverlays = nil
      let polylines = tracks.polylines(atLevel: level)
      if !polylines.isEmpty {
        let casing = MKMultiPolyline(polylines)
        let line = MKMultiPolyline(polylines)
        // Set first: the delegate tells the two apart while they are added. Added in this order at
        // the same level, the line is drawn over its outline.
        trackOverlays = (casing, line, level)
        map.addOverlays([casing, line], level: .aboveRoads)
      }
      if let old { map.removeOverlays([old.casing, old.line]) }
    }

    func show(segments: [Segment], points: [RawPoint], renderCache: [Int64: [[RenderCache.Coordinate]]], on map: MKMapView, bottomInset: CGFloat) {
      var changes: [Date: TrackGeometry.Track?] = [:]
      let wanted = Dictionary(segments.map { ($0.start, $0) }, uniquingKeysWith: { _, newer in newer })
      for (start, entry) in drawn where wanted[start].map({ Self.signature(of: $0) != entry.signature }) ?? true {
        switch entry.item {
        case .track: changes[start] = .some(nil)
        case .stay(let marker): map.removeAnnotation(marker)
        }
        drawn[start] = nil
      }
      for segment in segments where drawn[segment.start] == nil {
        switch segment.kind {
        case .move:
          // Completed moves come from the render cache; the open one (or one whose cache has not
          // arrived yet) is simplified here.
          let levels = segment.id.flatMap { renderCache[$0] }
            ?? RenderCache.levels(of: RenderCache.drawablePoints(MapFocus.points(of: segment, in: points)))
          guard let track = TrackGeometry.Track(levels: levels.map { $0.map(DisplayProjection.shared.mapPoint) }) else { continue }
          changes[segment.start] = .some(track)
          drawn[segment.start] = (Self.signature(of: segment), .track(track.boundingRect))
        case .stay:
          guard let latitude = segment.centerLatitude, let longitude = segment.centerLongitude else { continue }
          let marker = MKPointAnnotation()
          marker.coordinate = DisplayProjection.shared.mapPoint((latitude, longitude)).coordinate
          map.addAnnotation(marker)
          drawn[segment.start] = (Self.signature(of: segment), .stay(marker))
        case .gap:
          continue  // VS6 explains gaps (and draws the dashed subway link)
        }
      }
      if !changes.isEmpty {
        tracks.update(changes)
        redrawTracks(on: map, force: true)
      }

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
        case .stay(let marker): MapFocus.around(marker.coordinate).rect
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

    /// Opaque colours: the accent for the line, the background colour as its outline, so the
    /// track reads on both light and dark maps (D23).
    private static func color(casing: Bool, on map: MKMapView) -> UIColor {
      casing
        ? UIColor.systemBackground.resolvedColor(with: map.traitCollection)
        : map.tintColor.resolvedColor(with: map.traitCollection)
    }

    /// The render-cache level whose simplification stays under half a screen point here.
    private static func level(on map: MKMapView) -> Int {
      let visible = map.visibleMapRect
      guard map.bounds.width > 0, visible.width > 0 else { return 0 }
      let latitude = MKMapPoint(x: visible.midX, y: visible.midY).coordinate.latitude
      let metresPerPoint = visible.width / map.bounds.width / MKMapPointsPerMeterAtLatitude(latitude)
      return RenderCache.level(forMetresPerPoint: metresPerPoint)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
      guard let multiPolyline = overlay as? MKMultiPolyline else { return MKOverlayRenderer(overlay: overlay) }
      let isCasing = multiPolyline === trackOverlays?.casing
      let renderer = MKMultiPolylineRenderer(multiPolyline: multiPolyline)
      renderer.strokeColor = Self.color(casing: isCasing, on: mapView)
      renderer.lineWidth = isCasing ? Self.casingWidth : Self.lineWidth
      renderer.lineCap = .round
      renderer.lineJoin = .round
      return renderer
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
      redrawTracks(on: mapView, force: false)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
      guard annotation is MKPointAnnotation else { return nil }  // keeps the system user-location view
      let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
      view.markerTintColor = .tintColor
      view.glyphImage = UIImage(systemName: "mappin")
      view.displayPriority = .required
      return view
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
