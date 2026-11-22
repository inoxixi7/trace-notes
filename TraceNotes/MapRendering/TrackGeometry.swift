import MapKit

/// The day's moves as map geometry (ARCHITECTURE §6.3), keyed by segment start.
///
/// Drawn as one Bézier path in screen space by `TrackCanvas`, so the smooth curve (D30, D38) stays
/// smooth at every zoom and its width stays in screen points (F7). MapKit's own polyline renderer
/// (D33) needed the curve flattened into straight pieces, which showed as facets when zoomed in all
/// the way (device finding, D39).
nonisolated struct TrackGeometry {
  /// One move, already in display coordinates (D31), at every render-cache level, finest first.
  struct Track {
    let levels: [[MKMapPoint]]
    let boundingRect: MKMapRect
    /// Metres per map point at the track's latitude, for the spline's corner test.
    let metresPerMapPoint: Double

    init?(levels: [[MKMapPoint]]) {
      guard let finest = levels.first, finest.count > 1 else { return nil }
      self.levels = levels
      let xs = finest.map(\.x)
      let ys = finest.map(\.y)
      let minX = xs.min() ?? 0
      let minY = ys.min() ?? 0
      boundingRect = MKMapRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
      metresPerMapPoint = 1 / MKMapPointsPerMeterAtLatitude(MKMapPoint(x: boundingRect.midX, y: boundingRect.midY).coordinate.latitude)
    }
  }

  private(set) var tracks: [Date: Track] = [:]

  /// Replaces the tracks with these keys (nil removes).
  mutating func update(_ changes: [Date: Track?]) {
    for (key, track) in changes { tracks[key] = track }
  }

  /// The top-left corner of all tracks: paths are built relative to it so their numbers stay small.
  var origin: MKMapPoint? {
    guard let first = tracks.values.first else { return nil }
    let rect = tracks.values.dropFirst().reduce(first.boundingRect) { $0.union($1.boundingRect) }
    return MKMapPoint(x: rect.minX, y: rect.minY)
  }

  /// All tracks at a render-cache level as one path in map points relative to `origin`, so
  /// crossings and repeated routes are stroked once and never darken.
  func path(atLevel level: Int, origin: MKMapPoint) -> CGPath {
    let path = CGMutablePath()
    for key in tracks.keys.sorted() {
      guard let track = tracks[key] else { continue }
      let points = track.levels[min(level, track.levels.count - 1)].map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
      for element in CatmullRom.elements(through: points, metresPerUnit: track.metresPerMapPoint) {
        switch element {
        case .move(let to): path.move(to: to)
        case .line(let to): path.addLine(to: to)
        case .curve(let to, let control1, let control2): path.addCurve(to: to, control1: control1, control2: control2)
        }
      }
    }
    return path
  }
}
