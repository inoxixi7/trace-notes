import MapKit
import SwiftUI

/// MKMapView wrapper (D27). Moves are drawn by `TrackCanvas` as smooth curves in screen-point
/// widths from the render cache (VS3, D39); each stay is one dot at its centre, so drift while
/// still never shows as a scribble (F3); each gap is a dashed link (F6, D42). Everything is drawn
/// in display coordinates (D31).
///
/// The overview (D44) shows every completed move of every day instead, one colour, without stays
/// or gaps; it reads only the tracks on screen, at the level for the zoom.
struct TodayMapView: UIViewRepresentable {
  /// The day shown; a new day is framed afresh.
  let day: LocalDay
  let segments: [Segment]
  /// The day's points, oldest first; the open move takes its points from here by time.
  let points: [RawPoint]
  /// Simplified levels of completed moves, by segment ID.
  let renderCache: [Int64: [[RenderCache.Coordinate]]]
  /// Set when the user picks a timeline row; a new value moves the map there.
  let focus: MapFocus?
  /// Height covered by the timeline panel at the bottom, in points.
  let bottomInset: CGFloat
  /// Set while the overview is on.
  let overview: Overview?
  /// The overview needs the tracks for a new viewport or zoom level.
  let onOverviewRequest: (OverviewRequest) -> Void
  /// The user started panning or zooming the map (not a move the app made).
  let onUserMove: () -> Void

  struct Overview {
    /// The box around all completed moves; nil before the first one.
    var bounds: GeoBox?
    /// The tracks read for `request`, by segment ID; nil before the first read.
    var request: OverviewRequest?
    var tracks: [Int64: [RenderCache.Coordinate]]
  }

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
    // Watch the user's own gestures alongside MapKit's, without taking any touches from them.
    for recognizer in [UIPanGestureRecognizer(), UIPinchGestureRecognizer()] {
      recognizer.addTarget(context.coordinator, action: #selector(Coordinator.userGesture(_:)))
      recognizer.cancelsTouchesInView = false
      recognizer.delegate = context.coordinator
      map.addGestureRecognizer(recognizer)
    }
    return map
  }

  func updateUIView(_ map: MKMapView, context: Context) {
    context.coordinator.onOverviewRequest = onOverviewRequest
    context.coordinator.onUserMove = onUserMove
    if let overview {
      context.coordinator.showOverview(overview, on: map, bottomInset: bottomInset)
      return
    }
    context.coordinator.show(day: day, segments: segments, points: points, renderCache: renderCache, on: map, bottomInset: bottomInset)
    if let focus { context.coordinator.move(to: focus, on: map, bottomInset: bottomInset) }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
    /// What is drawn for each segment, keyed by its start, so unchanged segments are kept.
    private var drawn: [Date: (signature: Signature, item: Drawn)] = [:]
    private var tracks = TrackGeometry<Date>()
    /// The render-cache level the canvas's path was built from.
    private var drawnLevel: Int?
    private var hasFramedDay = false
    private var shownDay: LocalDay?
    private var shownFocus: UUID?
    private let canvas = TrackCanvas()
    private var isShowingOverview = false
    private var hasFramedOverview = false
    /// The read whose tracks are drawn, and the newest one asked for.
    private var drawnOverview: OverviewRequest?
    private var askedOverview: OverviewRequest?
    var onOverviewRequest: ((OverviewRequest) -> Void)?
    var onUserMove: (() -> Void)?

    @objc func userGesture(_ recognizer: UIGestureRecognizer) {
      guard recognizer.state == .began else { return }
      onUserMove?()
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
    /// Room around framed content, in points (plus the panel's height at the bottom).
    private static let padding = UIEdgeInsets(top: 120, left: 40, bottom: 40, right: 40)

    private struct Signature: Equatable {
      var kind: Segment.Kind
      var end: Date
      var pointCount: Int
      /// Moves only: what the track was built from. The day's segments, points and render cache
      /// arrive separately, in no fixed order; a move drawn before its points or cache came would
      /// otherwise keep that drawing (device finding: straight lines between stays).
      var source: Source?
    }

    private enum Source: Equatable {
      case renderCache
      /// Simplified here from this many of the day's points.
      case points(Int)
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

    func show(day: LocalDay, segments: [Segment], points: [RawPoint], renderCache: [Int64: [[RenderCache.Coordinate]]], on map: MKMapView, bottomInset: CGFloat) {
      if isShowingOverview {
        // Back from the overview: draw the day afresh and frame it again.
        isShowingOverview = false
        drawn = [:]
        tracks = TrackGeometry()
        drawnLevel = nil
        hasFramedDay = false
        canvas.setTracks(nil, origin: MKMapPoint(x: 0, y: 0))
      }
      if day != shownDay {
        shownDay = day
        hasFramedDay = false
      }
      var changes: [Date: TrackGeometry<Date>.Track?] = [:]
      let wanted = Dictionary(segments.map { ($0.start, $0) }, uniquingKeysWith: { _, newer in newer })
      let signature = { (segment: Segment) in Self.signature(of: segment, points: points, renderCache: renderCache) }
      for (start, entry) in drawn where wanted[start].map({ signature($0) != entry.signature }) ?? true {
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
          // arrived yet) is simplified here, once its points have arrived: without them the track
          // would be just the line between the neighbouring stays.
          let levels: [[RenderCache.Coordinate]]
          if let cached = segment.id.flatMap({ renderCache[$0] }) {
            levels = cached
          } else {
            let movePoints = MapFocus.points(of: segment, in: points)
            if movePoints.isEmpty, segment.pointCount > 0 { continue }
            levels = RenderCache.levels(
              of: RenderCache.track(
                of: segment, previous: index > 0 ? segments[index - 1] : nil,
                next: index + 1 < segments.count ? segments[index + 1] : nil, points: points))
          }
          guard let track = TrackGeometry<Date>.Track(levels: levels.map { $0.map(DisplayProjection.shared.mapPoint) }) else { continue }
          changes[segment.start] = .some(track)
          drawn[segment.start] = (signature(segment), .track(track.boundingRect))
        case .stay:
          guard let latitude = segment.centerLatitude, let longitude = segment.centerLongitude else { continue }
          drawn[segment.start] = (signature(segment), .stay(DisplayProjection.shared.mapPoint((latitude, longitude))))
        case .gap:
          continue  // drawn as a link, below
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
      canvas.setLinks(Self.links(of: segments, points: points))
      canvas.redraw(on: map)
      canvas.keepAnchorsNearCentre(on: map)

      // Frame the day once, when everything drawable is drawn (segments can arrive before their
      // points); afterwards the user's own panning and zooming wins.
      let waitingForPoints = segments.contains { $0.kind == .move && $0.pointCount > 1 && drawn[$0.start] == nil }
      if !hasFramedDay, !waitingForPoints, let rect = boundingRect() {
        hasFramedDay = true
        map.setVisibleMapRect(rect, edgePadding: Self.edgePadding(bottomInset), animated: false)
        // The path above was built for the zoom before framing (far out after a launch, so the
        // coarsest level); a jump without animation reports no visible-region change, so pick the
        // level for the new zoom now.
        redrawTracks(on: map, force: false)
        canvas.redraw(on: map)
      }
    }

    /// Replaces the day with the overview's tracks; frames all of them once per opening.
    func showOverview(_ overview: Overview, on map: MKMapView, bottomInset: CGFloat) {
      if !isShowingOverview {
        isShowingOverview = true
        hasFramedOverview = false
        drawnOverview = nil
        askedOverview = nil
        canvas.setTracks(nil, origin: MKMapPoint(x: 0, y: 0))
        canvas.setStays([])
        canvas.setLinks([])
        canvas.redraw(on: map)
      }
      if !hasFramedOverview, let bounds = overview.bounds, let rect = Self.rect(of: bounds) {
        hasFramedOverview = true
        // Without animation the visible rect is final at once (and no region change is reported).
        map.setVisibleMapRect(rect, edgePadding: Self.edgePadding(bottomInset), animated: false)
        canvas.keepAnchorsNearCentre(on: map)
        requestOverview(on: map)
      }
      guard let request = overview.request, request != drawnOverview else { return }
      drawnOverview = request
      var geometry = TrackGeometry<Int64>()
      geometry.update(overview.tracks.mapValues { TrackGeometry<Int64>.Track(levels: [$0.map(DisplayProjection.shared.mapPoint)]) })
      let origin = geometry.origin ?? MKMapPoint(x: 0, y: 0)
      canvas.setTracks(geometry.origin.map { geometry.path(atLevel: 0, origin: $0) }, origin: origin)
      canvas.redraw(on: map)
    }

    /// Asks for the tracks of the visible area unless the last read already covers it.
    private func requestOverview(on map: MKMapView) {
      let level = Self.level(on: map)
      let visible = map.visibleMapRect
      guard visible.width > 0, askedOverview?.covers(visible, level: level) != true else { return }
      let request = OverviewRequest(visible: visible, level: level)
      askedOverview = request
      // Called while SwiftUI updates the view (framing), so the state change waits for the next turn.
      let onOverviewRequest = onOverviewRequest
      Task { @MainActor in onOverviewRequest?(request) }
    }

    /// The display rect of a stored box, at least `MapFocus.minimumSpan` across.
    private static func rect(of box: GeoBox) -> MKMapRect? {
      let corners = box.longitudes.flatMap { longitudes in
        [(box.latitudes.upperBound, longitudes.lowerBound), (box.latitudes.lowerBound, longitudes.upperBound)]
      }
      return MapFocus.enclosing(corners.map { DisplayProjection.shared.mapPoint($0).coordinate })?.rect
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

    /// A gap links the ends of the lines either side of it: a stay's centre (where moves end, D38)
    /// or the nearest point. Gaps without a position on both sides are not drawn.
    private static func links(of segments: [Segment], points: [RawPoint]) -> [TrackCanvas.Link] {
      segments.indices.compactMap { index in
        let gap = segments[index]
        guard gap.kind == .gap else { return nil }
        let before = index > 0 ? segments[index - 1].stayCenter : nil
        let after = index + 1 < segments.count ? segments[index + 1].stayCenter : nil
        guard
          let from = before.map(DisplayProjection.shared.mapPoint)
            ?? points.last(where: { $0.timestamp <= gap.start && !$0.flags.contains(.replayed) }).map({ MKMapPoint($0.displayCoordinate) }),
          let to = after.map(DisplayProjection.shared.mapPoint)
            ?? points.first(where: { $0.timestamp >= gap.end && !$0.flags.contains(.replayed) }).map({ MKMapPoint($0.displayCoordinate) })
        else { return nil }
        return TrackCanvas.Link(from: from, to: to, isTravelled: gap.gapTravelMode != nil)
      }
    }

    private static func signature(of segment: Segment, points: [RawPoint], renderCache: [Int64: [[RenderCache.Coordinate]]]) -> Signature {
      var source: Source?
      if segment.kind == .move {
        source = segment.id.flatMap { renderCache[$0] } != nil ? .renderCache : .points(MapFocus.points(of: segment, in: points).count)
      }
      return Signature(kind: segment.kind, end: segment.end, pointCount: segment.pointCount, source: source)
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
      if !isShowingOverview { redrawTracks(on: mapView, force: false) }
      canvas.keepAnchorsNearCentre(on: mapView)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
      // Any camera change ends here, including ones that reported no visible-region change.
      if isShowingOverview { requestOverview(on: mapView) } else { redrawTracks(on: mapView, force: false) }
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

  static func enclosing(_ coordinates: [CLLocationCoordinate2D]) -> MapFocus? {
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
