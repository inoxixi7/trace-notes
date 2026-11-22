import MapKit
import os

/// Stored WGS-84 coordinates → where to draw them (ARCHITECTURE §6.4, D16, D31). Display only:
/// results are never written to any layer.
nonisolated struct DisplayProjection: Sendable {
  private let policy: MapDatumPolicy?

  /// Loaded once. Until the China base-map signal is known (S2 §6), D31 converts nothing, so a
  /// missing region file changes no output; it is still reported because it would matter then.
  static let shared: DisplayProjection = {
    do {
      return DisplayProjection(policy: MapDatumPolicy(mainland: try .bundled(), chinaBaseMapServed: false))
    } catch {
      AppLog.rendering.fault("mainland region unavailable, drawing WGS-84: \(error.localizedDescription, privacy: .public)")
      return DisplayProjection(policy: nil)
    }
  }()

  func mapPoint(_ coordinate: RenderCache.Coordinate) -> MKMapPoint {
    let stored = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    return MKMapPoint(policy?.displayCoordinate(for: stored) ?? stored)
  }
}
