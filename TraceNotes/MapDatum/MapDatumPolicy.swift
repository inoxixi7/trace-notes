import CoreLocation

/// The datum a base map draws in at some place.
nonisolated enum MapDatum: Sendable, Equatable {
  case wgs84
  case gcj02
}

/// Decides, per point, which datum the MapKit base map uses there and returns the coordinate to
/// draw. Display layer only: inputs are stored WGS-84 points, outputs are never written back (D16).
///
/// Rule (D26): a point is drawn in GCJ-02 only when it is inside mainland China (excluding Hong
/// Kong, Macau and Taiwan) **and** MapKit is serving the China base map; every other point is drawn
/// as stored. The decision is per point, so a track that crosses the border is converted only on
/// the mainland side. How to detect the China base map is still open (docs/spikes/S2-result.md §6);
/// until then callers pass `chinaBaseMapServed: false`.
nonisolated struct MapDatumPolicy: Sendable {
  let mainland: ChinaMainlandRegion
  /// Whether the base map currently drawn is Apple's China (GCJ-02) map.
  let chinaBaseMapServed: Bool

  func datum(at coordinate: CLLocationCoordinate2D) -> MapDatum {
    chinaBaseMapServed && mainland.contains(coordinate) ? .gcj02 : .wgs84
  }

  func displayCoordinate(for stored: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
    switch datum(at: stored) {
    case .gcj02: GCJ02.fromWGS84(stored)
    case .wgs84: stored
    }
  }

  func displayCoordinates(for stored: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    stored.map(displayCoordinate(for:))
  }
}
