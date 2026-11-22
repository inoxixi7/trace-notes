import MapKit
import SwiftUI

/// MKMapView wrapper (D27). VS2 draws each move as a plain polyline and each stay as one marker
/// at its centre, so drift while still never shows as a scribble (F3). Smoothing, LOD, pixel line
/// widths and GCJ-02 display arrive with VS3.
struct TodayMapView: UIViewRepresentable {
  let segments: [Segment]
  /// The day's points, oldest first; moves take theirs by time.
  let points: [RawPoint]
  /// Set when the user picks a timeline row; a new value moves the map there.
  let focus: MapFocus?
  /// Height covered by the timeline panel at the bottom, in points.
  let bottomInset: CGFloat

  func makeUIView(context: Context) -> MKMapView {
    let map = MKMapView()
    map.delegate = context.coordinator
    map.showsUserLocation = true
    map.pointOfInterestFilter = .excludingAll
    return map
  }

  func updateUIView(_ map: MKMapView, context: Context) {
    context.coordinator.show(segments: segments, points: points, on: map, bottomInset: bottomInset)
    if let focus { context.coordinator.move(to: focus, on: map, bottomInset: bottomInset) }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator: NSObject, MKMapViewDelegate {
    /// What is drawn for each segment, keyed by its start, so unchanged segments are kept.
    private var drawn: [Date: (signature: Signature, item: Drawn)] = [:]
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
      case line(MKPolyline)
      case stay(MKPointAnnotation)
    }

    func show(segments: [Segment], points: [RawPoint], on map: MKMapView, bottomInset: CGFloat) {
      let wanted = Dictionary(segments.map { ($0.start, $0) }, uniquingKeysWith: { _, newer in newer })
      for (start, entry) in drawn where wanted[start].map({ Self.signature(of: $0) != entry.signature }) ?? true {
        remove(entry.item, from: map)
        drawn[start] = nil
      }
      for segment in segments where drawn[segment.start] == nil {
        guard let item = makeItem(for: segment, points: points) else { continue }
        add(item, to: map)
        drawn[segment.start] = (Self.signature(of: segment), item)
      }
      // Frame the day once, when everything drawable is drawn (segments can arrive before their
      // points); afterwards the user's own panning and zooming wins.
      let waitingForPoints = segments.contains { $0.kind == .move && $0.pointCount > 1 && drawn[$0.start] == nil }
      if !hasFramedDay, !waitingForPoints, let rect = Self.boundingRect(of: drawn.values.map(\.item)) {
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

    private func makeItem(for segment: Segment, points: [RawPoint]) -> Drawn? {
      switch segment.kind {
      case .move:
        let coordinates = MapFocus.points(of: segment, in: points).map(\.coordinate)
        guard coordinates.count > 1 else { return nil }
        return .line(MKPolyline(coordinates: coordinates, count: coordinates.count))
      case .stay:
        guard let latitude = segment.centerLatitude, let longitude = segment.centerLongitude else { return nil }
        let marker = MKPointAnnotation()
        marker.coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return .stay(marker)
      case .gap:
        return nil  // VS6 explains gaps (and draws the dashed subway link)
      }
    }

    private func add(_ item: Drawn, to map: MKMapView) {
      switch item {
      case .line(let line): map.addOverlay(line)
      case .stay(let marker): map.addAnnotation(marker)
      }
    }

    private func remove(_ item: Drawn, from map: MKMapView) {
      switch item {
      case .line(let line): map.removeOverlay(line)
      case .stay(let marker): map.removeAnnotation(marker)
      }
    }

    private static func signature(of segment: Segment) -> Signature {
      Signature(kind: segment.kind, end: segment.end, pointCount: segment.pointCount)
    }

    private static func edgePadding(_ bottomInset: CGFloat) -> UIEdgeInsets {
      var padding = padding
      padding.bottom += bottomInset
      return padding
    }

    private static func boundingRect(of items: [Drawn]) -> MKMapRect? {
      let rects = items.map { item -> MKMapRect in
        switch item {
        case .line(let line): line.boundingMapRect
        case .stay(let marker): MapFocus.around(marker.coordinate).rect
        }
      }
      guard let first = rects.first else { return nil }
      return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
      guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
      let renderer = MKPolylineRenderer(polyline: line)
      renderer.strokeColor = .tintColor
      renderer.lineWidth = 4
      renderer.lineCap = .round
      renderer.lineJoin = .round
      return renderer
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
      return around(CLLocationCoordinate2D(latitude: latitude, longitude: longitude), radius: segment.radius ?? 0)
    case .move:
      return enclosing(self.points(of: segment, in: points).map(\.coordinate))
    case .gap:
      let before = points.last { $0.timestamp <= segment.start && !$0.flags.contains(.replayed) }
      let after = points.first { $0.timestamp >= segment.end && !$0.flags.contains(.replayed) }
      return enclosing([before, after].compactMap { $0?.coordinate })
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
  var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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
