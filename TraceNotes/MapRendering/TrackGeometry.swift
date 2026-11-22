import MapKit

/// The day's moves as map geometry (ARCHITECTURE §6.3), keyed by segment start.
///
/// Drawn with MapKit's own multi-polyline renderer, the only kind MapKit draws as vectors: its
/// width stays in screen points while zooming (F7). A custom overlay renderer is rasterised per
/// tile level and shown at up to half or double that scale, so its width jumped between 2.5 and
/// 5 points (VS3 simulator finding). The smooth curve is therefore flattened into a polyline
/// finely enough for the zoom level.
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

  /// All tracks at a render-cache level, for one multi-polyline per layer, so crossings and repeated
  /// routes are stroked once and never darken.
  func polylines(atLevel level: Int) -> [MKPolyline] {
    let tolerance = RenderCache.tolerances[min(level, RenderCache.tolerances.count - 1)]
    return tracks.keys.sorted().compactMap { key -> MKPolyline? in
      guard let track = tracks[key] else { return nil }
      let points = track.levels[min(level, track.levels.count - 1)].map { CGPoint(x: $0.x, y: $0.y) }
      let curve = CatmullRom.polyline(
        through: points, metresPerUnit: track.metresPerMapPoint, tolerance: tolerance / track.metresPerMapPoint)
      let mapPoints = curve.map { MKMapPoint(x: $0.x, y: $0.y) }
      return MKPolyline(points: mapPoints, count: mapPoints.count)
    }
  }
}
